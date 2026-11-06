#!/usr/bin/env python3
"""Embedded installer support; never reads or rewrites node certificates or users."""

import ast
import copy
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


ORIGINAL_MODULE_SHA256 = "12757c9b4f97095992f0b2dac5615e56317b047b382d34ef5a6e19484c22c83f"
PATCHED_MODULE_SHA256 = "0656179bcb654f98ccd3b8d190f70d3bcb51a05d2dcc4979c8ac1e81e396ed37"

RUNTIME_METHOD = '''    def _apply_runtime_limits(self):
        if os.getenv("XRAY_NODE_MEMORY_PROFILE", "") == "balanced":
            levels = self.setdefault("policy", {}).setdefault("levels", {})
            levels.setdefault("0", {})
            for values in levels.values():
                for key, limit in (("handshake", 15), ("connIdle", 120), ("bufferSize", 64)):
                    current = values.get(key)
                    values[key] = min(current, limit) if isinstance(current, (int, float)) and current >= 0 else limit

        listen = os.getenv("XRAY_NODE_METRICS_LISTEN", "")
        if listen:
            host, port = listen.rsplit(":", 1)
            if host != "127.0.0.1" or not port.isdigit() or not 1 <= int(port) <= 65535:
                raise ValueError("Node diagnostics must listen on an IPv4 loopback port")
            metrics = self.setdefault("metrics", {})
            metrics.setdefault("tag", "NodeDiagnostics")
            metrics["listen"] = listen

'''


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def patch_module(source):
    digest = sha256(source.encode())
    if digest == PATCHED_MODULE_SHA256:
        return source
    if digest != ORIGINAL_MODULE_SHA256:
        raise RuntimeError("Unsupported node runtime module; existing services were not stopped")
    edits = [
        ("import atexit\n", "import atexit\nimport os\n"),
        ("        self._apply_api()\n", "        self._apply_api()\n        self._apply_runtime_limits()\n"),
        ("    def to_json(self, **json_kwargs):\n", RUNTIME_METHOD + "    def to_json(self, **json_kwargs):\n"),
        (
            "        atexit.register(lambda: self.stop() if self.started else None)\n",
            "        for name in (\"GOGC\", \"GOMEMLIMIT\"):\n"
            "            value = os.getenv(name)\n"
            "            if value:\n"
            "                self._env[name] = value\n\n"
            "        atexit.register(lambda: self.stop() if self.started else None)\n",
        ),
    ]
    for before, after in edits:
        if source.count(before) != 1:
            raise RuntimeError("Unexpected node module layout")
        source = source.replace(before, after, 1)
    ast.parse(source)
    if sha256(source.encode()) != PATCHED_MODULE_SHA256:
        raise RuntimeError("Node runtime patch checksum mismatch")
    return source


def memory_bytes(value):
    match = re.fullmatch(r"([0-9]+)(B|KiB|MiB|GiB|TiB)", str(value))
    if not match:
        return 0
    return int(match[1]) * {"B": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3, "TiB": 1024**4}[match[2]]


def effective_memory():
    total = int(next(line.split()[1] for line in Path("/proc/meminfo").read_text().splitlines() if line.startswith("MemTotal:"))) * 1024
    for filename in ("/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes"):
        try:
            value = Path(filename).read_text().strip()
            if value.isdigit() and int(value) > 0:
                total = min(total, int(value))
        except OSError:
            pass
    return total


def choose_budget(total, existing=None):
    # Keep a previously configured, usable budget, including the tested 4/8 GiB budgets.
    if 0 < memory_bytes(existing) <= total * 3 // 4:
        return existing
    return str(max(1, total // (2 * 1024**2))) + "MiB"


def command(args, check=True, timeout=300):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError("Command failed: " + " ".join(args[:4]) + "\n" + result.stderr[-1500:])
    return result


def inspect_container(name):
    result = command(["docker", "inspect", name], check=False, timeout=15)
    return json.loads(result.stdout)[0] if result.returncode == 0 else None


def atomic_write(path, content, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".node-runtime-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def environment(values):
    if isinstance(values, dict):
        return dict(values)
    return dict(value.split("=", 1) for value in (values or []) if "=" in value)


def runtime_override(previous, image, module, budget):
    result = copy.deepcopy(previous)
    service = result.setdefault("services", {}).setdefault("marzban-node", {})
    service["image"] = image
    env = environment(service.get("environment"))
    env.update(GOGC="50", GOMEMLIMIT=budget, XRAY_NODE_MEMORY_PROFILE="balanced", XRAY_NODE_RUNTIME_SHA256=PATCHED_MODULE_SHA256)
    service["environment"] = env
    def target(value):
        if isinstance(value, dict):
            return value.get("target")
        parts = value.split(":")
        return parts[1] if len(parts) > 1 else parts[0]
    service["volumes"] = [value for value in service.get("volumes", []) if target(value) != "/code/xray.py"]
    service["volumes"].append({"type": "bind", "source": str(module), "target": "/code/xray.py", "read_only": True})
    # Diagnostics remain opt-in; a fixed metrics port would break multiple instances.
    return result


def configured_image(compose, base, name):
    probe = "node-runtime-probe-" + uuid.uuid4().hex[:12]
    try:
        command(compose + ["-f", str(base), "-p", name, "run", "-d", "--rm", "--no-deps", "-T", "--name", probe,
                           "--entrypoint", "python", "marzban-node", "-c", "import time; time.sleep(60)"])
        return inspect_container(probe)["Image"]
    finally:
        command(["docker", "rm", "-f", probe], check=False, timeout=15)


def image_module(image):
    result = command(["docker", "run", "--rm", "--network", "none", "--entrypoint", "python", image,
                      "-c", "from pathlib import Path; print(Path('/code/xray.py').read_text(), end='')"])
    return patch_module(result.stdout)


def prepare(base, overlay, data, name, compose_string):
    base, overlay, data = Path(base), Path(overlay), Path(data)
    compose = shlex.split(compose_string)
    initial_base_hash = sha256(base.read_bytes())
    command(compose + ["-f", str(base), "-p", name, "config", "-q"])
    old_container = inspect_container(name)
    if old_container and old_container["Config"].get("Labels", {}).get("com.docker.compose.service") != "marzban-node":
        raise RuntimeError("The container name belongs to another service")
    previous = json.loads(overlay.read_text()) if overlay.exists() else {}
    old_env = environment(old_container["Config"].get("Env")) if old_container else {}
    previous_env = environment(previous.get("services", {}).get("marzban-node", {}).get("environment"))
    budget = choose_budget(effective_memory(), previous_env.get("GOMEMLIMIT", old_env.get("GOMEMLIMIT")))
    image = configured_image(compose, base, name)
    source = image_module(image)
    module = data / "node-runtime-patch" / "xray.py"
    updated = runtime_override(previous, image, module, budget)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
    backups = data / "node-runtime-backups"
    backups.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup = Path(tempfile.mkdtemp(prefix=stamp, dir=backups))
    state = {"base": str(base), "overlay": str(overlay), "module": str(module), "name": name,
             "old_image": old_container["Image"] if old_container else None,
             "old_id": old_container["Id"] if old_container else None,
             "old_restart_count": old_container["RestartCount"] if old_container else 0,
             "was_running": bool(old_container and old_container["State"]["Running"]),
             "budget": budget, "image": image, "backup": str(backup)}
    for label, path in (("overlay", overlay), ("module", module)):
        state[label + "_existed"] = path.exists()
        if path.exists():
            shutil.copy2(path, backup / label)
    if sha256(base.read_bytes()) != initial_base_hash:
        raise RuntimeError("Compose changed during preparation; retry with the new configuration")
    statefile = backup / "state.json"
    atomic_write(statefile, json.dumps(state, indent=2) + "\n")
    try:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", dir=base.parent) as candidate:
            json.dump(updated, candidate)
            candidate.flush()
            command(compose + ["-f", str(base), "-f", candidate.name, "-p", name, "config", "-q"])
        atomic_write(module, source, 0o644)
        atomic_write(overlay, json.dumps(updated, indent=2) + "\n")
    except BaseException:
        restore_files(state)
        raise
    print("Runtime profile: balanced; Go memory budget: " + budget, file=sys.stderr)
    print(statefile)


def restore_files(state):
    for label in ("module", "overlay"):
        target = Path(state[label])
        if state[label + "_existed"]:
            backup = Path(state["backup"]) / label
            atomic_write(target, backup.read_text(), backup.stat().st_mode & 0o777)
        else:
            try:
                target.unlink()
            except FileNotFoundError:
                pass


def rollback(statefile, compose_string):
    state = json.loads(Path(statefile).read_text())
    restore_files(state)
    compose = shlex.split(compose_string)
    if state["was_running"]:
        recovery = Path(state["backup"]) / "recovery.json"
        atomic_write(recovery, json.dumps({"services": {"marzban-node": {"image": state["old_image"]}}}))
        files = ["-f", state["base"]]
        if state["overlay_existed"]:
            files += ["-f", state["overlay"]]
        command(compose + files + ["-f", str(recovery), "-p", state["name"], "up", "-d", "--no-deps", "marzban-node"])
    else:
        current = inspect_container(state["name"])
        if current and current["Config"].get("Labels", {}).get("com.docker.compose.service") == "marzban-node":
            command(["docker", "rm", "-f", state["name"]])
    print("Previous node runtime restored", file=sys.stderr)


def verify(statefile):
    state = json.loads(Path(statefile).read_text())
    for _ in range(3):
        time.sleep(1)
        container = inspect_container(state["name"])
        previous_restarts = state["old_restart_count"] if container and container["Id"] == state["old_id"] else 0
        if not container or not container["State"]["Running"] or container["State"]["Restarting"] or container["RestartCount"] > previous_restarts:
            raise RuntimeError("Node container did not remain running")
        if container["Image"] != state["image"]:
            raise RuntimeError("Running node image differs from the prepared runtime")
        env = environment(container["Config"].get("Env"))
        if any(env.get(key) != value for key, value in {"GOGC": "50", "GOMEMLIMIT": state["budget"], "XRAY_NODE_MEMORY_PROFILE": "balanced"}.items()):
            raise RuntimeError("Node runtime environment was not applied")


def main(args):
    try:
        if args[0] == "prepare":
            prepare(*args[1:])
        elif args[0] == "rollback":
            rollback(*args[1:])
        elif args[0] == "verify":
            verify(*args[1:])
        else:
            raise RuntimeError("Unknown runtime operation")
    except Exception as error:
        print("Node runtime error: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
