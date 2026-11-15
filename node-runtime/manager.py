#!/usr/bin/env python3
"""Embedded installer support; never reads or rewrites node certificates or users."""

import ast
import copy
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import urllib.request
import zipfile
import io


ORIGINAL_MODULE_SHA256 = "12757c9b4f97095992f0b2dac5615e56317b047b382d34ef5a6e19484c22c83f"
ORIGINAL_REST_SHA256 = "0bd9a6bab39d52f46e2070f4b1488a0428c43a2ffce5fdc7c7c1e8e031b26a55"
PATCHED_MODULE_SHA256 = "6217af10d9b6b4353bcf53ede335d9cd4b8ebbe48475cabef194b862e2eb75b2"
MEMORY_BUDGET_PERCENT = 75
SS2022_POLICY_CORE_VERSION = (26, 10, 31)
PINNED_CORE_VERSION = "26.3.27"
PINNED_CORE_ASSETS = {
    "x86_64": ("64", "23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae", "8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed"),
    "aarch64": ("arm64-v8a", "4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c", "c2d20a7045250497083afea0d79db0672f6c89a25aaaf37c92de034d6b764b04"),
}

# BEGIN EMBEDDED IDLE GUARD
IDLE_GUARD_SOURCE = '#!/usr/bin/env python3\n"""Reap confirmed idle TCP sockets owned by one selected node container.\n\nKernel data-idle timers, two byte-counter snapshots, inode ownership and a final\nrescan are required. No conntrack table is flushed and no process is killed.\n"""\nimport argparse\nimport json\nimport os\nfrom pathlib import Path\nimport re\nimport subprocess\nimport time\n\n\ndef command(args):\n    return subprocess.run(args, text=True, capture_output=True, check=True, timeout=20).stdout\n\n\ndef endpoint(value):\n    host, port = value.rsplit(":", 1)\n    return host.strip("[]"), int(port)\n\n\ndef parse_sockets(output):\n    result = {}\n    for line in output.splitlines():\n        parts = line.split()\n        if len(parts) < 4:\n            continue\n        try:\n            queues = [int(parts[0]), int(parts[1])]\n            local, peer = endpoint(parts[2]), endpoint(parts[3])\n        except ValueError:\n            continue\n        values = {k: int(v) for k, v in re.findall(r"\\b(ino|bytes_sent|bytes_received|lastsnd|lastrcv):(\\d+)", line)}\n        if not values.get("ino") or "lastsnd" not in values or "lastrcv" not in values:\n            continue\n        inode = str(values["ino"])\n        result[inode] = {"local": local, "peer": peer, "bytes": [values.get("bytes_sent", 0), values.get("bytes_received", 0)],\n                         "idle_ms": min(values["lastsnd"], values["lastrcv"]), "queues": queues}\n    return result\n\n\ndef snapshot():\n    return parse_sockets(command(["ss", "-HtniepO", "state", "established"]))\n\n\ndef owners(container):\n    inspected = json.loads(command(["docker", "inspect", container]))[0]\n    if inspected["Config"].get("Labels", {}).get("com.docker.compose.service") != "marzban-node":\n        raise RuntimeError("Selected container is not a Marzban node")\n    env = dict(x.split("=", 1) for x in inspected["Config"].get("Env", []) if "=" in x)\n    protected = {22, 6111, int(env.get("SERVICE_PORT", 62050)), int(env.get("XRAY_API_PORT", 62051))}\n    inodes = set()\n    for line in command(["docker", "top", container, "-eo", "pid,comm"]).splitlines()[1:]:\n        parts = line.split()\n        if len(parts) != 2 or parts[1] != "xray":\n            continue\n        try:\n            for descriptor in Path("/proc", parts[0], "fd").iterdir():\n                try:\n                    link = os.readlink(descriptor)\n                    match = re.fullmatch(r"socket:\\[(\\d+)\\]", link)\n                    if match:\n                        inodes.add(match[1])\n                except OSError:\n                    pass\n        except OSError:\n            pass\n    return inodes, protected\n\n\ndef eligible(current, previous, owned, protected, idle_seconds):\n    selected = {}\n    for inode, item in current.items():\n        before = previous.get(inode)\n        if inode not in owned or before is None or any(item["queues"]):\n            continue\n        if item["local"][1] in protected or item["peer"][1] in protected:\n            continue\n        if item["idle_ms"] < idle_seconds * 1000:\n            continue\n        if any(item[k] != before[k] for k in ("local", "peer", "bytes")):\n            continue\n        selected[inode] = item\n    return selected\n\n\ndef save_state(path, data):\n    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)\n    temporary = path.with_name(path.name + ".tmp")\n    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)\n    with os.fdopen(descriptor, "w") as stream:\n        json.dump(data, stream)\n    os.replace(temporary, path)\n\n\ndef run(container, state_path, idle_seconds=300, apply=False, limit=100):\n    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()\n    previous = {}\n    now = time.monotonic()\n    if state_path.exists():\n        state = json.loads(state_path.read_text())\n        # JSON round trips lists; normalise addresses before comparisons.\n        if state.get("boot") == boot and state.get("container") == container and 30 <= now - state.get("time", now) <= 180:\n            previous = state.get("sockets", {})\n            for value in previous.values():\n                value["local"] = tuple(value["local"])\n                value["peer"] = tuple(value["peer"])\n    current = snapshot()\n    owned, protected = owners(container)\n    selected = eligible(current, previous, owned, protected, idle_seconds)\n    attempted = 0\n    if apply and selected:\n        # Recheck data progress and ownership immediately before socket destroy.\n        fresh = snapshot()\n        fresh_owned, protected = owners(container)\n        selected = eligible(fresh, selected, fresh_owned, protected, idle_seconds)\n        for inode, item in list(selected.items())[:limit]:\n            host, port = item["local"]\n            peer, peer_port = item["peer"]\n            command(["ss", "-Knt", "src", host, "sport", "=", ":" + str(port), "dst", peer, "dport", "=", ":" + str(peer_port)])\n            attempted += 1\n        remaining = snapshot()\n        closed = sum(inode not in remaining for inode in list(selected)[:limit])\n        current = remaining\n    else:\n        closed = 0\n    # Store node sockets only. Never retain other services\' endpoint inventory.\n    save_state(state_path, {"boot": boot, "container": container, "time": now, "sockets": {k: v for k, v in current.items() if k in owned}})\n    return {"container": container, "apply": apply, "idle_seconds": idle_seconds, "owned_tcp": len(set(current) & owned),\n            "confirmed_idle": len(selected), "attempted": attempted, "closed": closed}\n\n\nif __name__ == "__main__":\n    parser = argparse.ArgumentParser(description=__doc__)\n    parser.add_argument("--container", required=True)\n    parser.add_argument("--state", required=True, type=Path)\n    parser.add_argument("--idle-seconds", type=int, default=300)\n    parser.add_argument("--apply", action="store_true")\n    args = parser.parse_args()\n    if args.idle_seconds < 300:\n        parser.error("Production idle timeout must be at least 300 seconds")\n    print(json.dumps(run(args.container, args.state, args.idle_seconds, args.apply)))\n'
# END EMBEDDED IDLE GUARD


def guard_paths(data, name):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", name):
        raise RuntimeError("Invalid node name for a system service")
    unit = "marzban-idle-" + name
    return {"guard": Path(data) / "node-runtime-patch/idle_guard.py",
            "guard_service": Path("/etc/systemd/system") / (unit + ".service"),
            "guard_timer": Path("/etc/systemd/system") / (unit + ".timer")}


def install_idle_guard(state):
    if not Path("/run/systemd/system").is_dir() or not shutil.which("ss"):
        raise RuntimeError("Idle guard needs systemd and iproute2; previous node will be restored")
    paths = guard_paths(state["data"], state["name"])
    unit = paths["guard_service"].stem
    atomic_write(paths["guard"], IDLE_GUARD_SOURCE, 0o700)
    arguments = " ".join('"' + str(v).replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%") + '"' for v in [paths["guard"], "--container", state["name"], "--state", Path(state["data"]) / "node-runtime-idle-state.json", "--apply"])
    atomic_write(paths["guard_service"], "[Unit]\nDescription=Reap confirmed idle TCP sockets for Marzban node\nAfter=docker.service\n[Service]\nType=oneshot\nExecStart=/usr/bin/python3 " + arguments + "\nTimeoutStartSec=45\nUMask=0077\n", 0o644)
    atomic_write(paths["guard_timer"], "[Unit]\nDescription=Marzban idle TCP cleanup\n[Timer]\nOnBootSec=60\nOnUnitActiveSec=60\nAccuracySec=5\n[Install]\nWantedBy=timers.target\n", 0o644)
    command(["systemctl", "daemon-reload"])
    command(["systemctl", "enable", "--now", unit + ".timer"])


def remove_idle_guard(name):
    paths = guard_paths("/var/lib/" + name, name)
    command(["systemctl", "disable", "--now", paths["guard_timer"].name], check=False)
    for label in ("guard_timer", "guard_service"):
        paths[label].unlink(missing_ok=True)
    command(["systemctl", "daemon-reload"], check=False)


def network_plan():
    """Conservative host defaults; leave UDP, routes, MTU and firewall intact."""
    limits = {"net.ipv4.tcp_keepalive_time": 120, "net.ipv4.tcp_keepalive_intvl": 30,
              "net.ipv4.tcp_keepalive_probes": 4, "net.netfilter.nf_conntrack_tcp_timeout_established": 7200}
    requested = dict(limits, **{"net.ipv4.tcp_mtu_probing": 1,
                               "net.ipv4.conf.all.send_redirects": 0,
                               "net.ipv4.conf.default.send_redirects": 0})
    requested["net.netfilter.nf_conntrack_max"] = min(262144, max(32768, effective_memory() // (1024**3) * 32768))
    old, new = {}, {}
    for key, value in requested.items():
        probe = command(["sysctl", "-n", key], check=False)
        if probe.returncode or not probe.stdout.strip().isdigit():
            continue
        current = int(probe.stdout.strip())
        old[key] = str(current)
        new[key] = str(min(current, value) if key in limits else max(current, value) if key in ("net.netfilter.nf_conntrack_max", "net.ipv4.tcp_mtu_probing") else value)
    return old, new

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
    # Capture a particular child, rather than following self.process across a
    # restart. Merge stderr so an unread pipe cannot block the core.
    start = source.index("    def __capture_process_logs(self):\n")
    end = source.index("    @contextmanager\n", start)
    source = source[:start] + '''    def __capture_process_logs(self):
        process = self.process
        def capture():
            try:
                for output in process.stdout:
                    output = output.strip()
                    if output:
                        self._logs_buffer.append(output)
                        for buf in list(self._temp_log_buffers.values()):
                            buf.append(output)
                        if DEBUG:
                            logger.debug(output)
            finally:
                process.stdout.close()
        threading.Thread(target=capture, daemon=True).start()

''' + source[end:]
    source = source.replace("        self.restarting = False\n", "        self.restarting = False\n        self._process_lock = threading.RLock()\n", 1)
    source = source.replace("            stderr=subprocess.PIPE,\n", "            stderr=subprocess.STDOUT,\n", 1)
    start = source.index("    def stop(self):\n")
    end = source.index("    def on_start(self,", start)
    source = source[:start] + '''    def stop(self):
        with self._process_lock:
            process = self.process
            if process is None:
                return
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            else:
                process.wait()
            self.process = None
            logger.warning("Xray core stopped")
            for func in self._on_stop_funcs:
                threading.Thread(target=func, daemon=True).start()

    def restart(self, config: XRayConfig):
        with self._process_lock:
            if self.restarting:
                return
            self.restarting = True
            try:
                logger.warning("Restarting Xray core...")
                self.stop()
                self.start(config)
            finally:
                self.restarting = False

''' + source[end:]
    # Serialise direct start calls with stop/restart, including RPyC callers.
    start = source.index("    def start(self, config: XRayConfig):\n")
    end = source.index("    def stop(self):\n", start)
    lines = source[start:end].splitlines(True)
    source = source[:start] + lines[0] + "        with self._process_lock:\n" + "".join("    " + line if line.strip() else line for line in lines[1:]) + source[end:]
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


def choose_budget(total):
    # Recompute on upgrades too, so an old 50% budget cannot retain the old policy.
    return str(max(1, total * MEMORY_BUDGET_PERCENT // (100 * 1024**2))) + "MiB"


def stage_pinned_core(data):
    """Verify the official binary before touching a running service."""
    architecture = platform.machine().lower()
    architecture = {"amd64": "x86_64", "arm64": "aarch64"}.get(architecture, architecture)
    if architecture not in PINNED_CORE_ASSETS:
        raise RuntimeError("Pinned Xray core is not verified for architecture: " + architecture)
    asset, archive_digest, binary_digest = PINNED_CORE_ASSETS[architecture]
    target = Path(data) / "node-runtime-core" / PINNED_CORE_VERSION / "xray"
    if target.is_file() and sha256(target.read_bytes()) == binary_digest:
        return target
    url = "https://github.com/XTLS/Xray-core/releases/download/v" + PINNED_CORE_VERSION + "/Xray-linux-" + asset + ".zip"
    with urllib.request.urlopen(url, timeout=45) as response:
        archive = response.read(80 * 1024**2 + 1)
    if sha256(archive) != archive_digest:
        raise RuntimeError("Official Xray archive checksum mismatch; node was not stopped")
    binary = zipfile.ZipFile(io.BytesIO(archive)).read("xray")
    if sha256(binary) != binary_digest:
        raise RuntimeError("Official Xray binary checksum mismatch; node was not stopped")
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".xray-", dir=target.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(binary)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o755)
        result = command([temporary, "version"], timeout=10)
        if not result.stdout.startswith("Xray " + PINNED_CORE_VERSION + " "):
            raise RuntimeError("Unexpected pinned Xray version")
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return target


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


def runtime_override(previous, image, module, budget, core=None):
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
    if core is not None:
        env["XRAY_EXECUTABLE_PATH"] = "/opt/marzban-runtime/xray"
        service["volumes"] = [value for value in service["volumes"] if target(value) != "/opt/marzban-runtime/xray"]
        service["volumes"].append({"type": "bind", "source": str(core), "target": "/opt/marzban-runtime/xray", "read_only": True})
    # Diagnostics remain opt-in; a fixed metrics port would break multiple instances.
    return result


def configured_image(compose, base, name):
    probe = "node-runtime-probe-" + uuid.uuid4().hex[:12]
    try:
        command(compose + ["-f", str(base), "-p", name, "run", "-d", "--rm", "--no-deps", "-T", "--name", probe,
                           "--entrypoint", "python", "marzban-node", "-c", "import time; time.sleep(60)"])
        # Inspect the configured executable with its existing mounts. Updating
        # the node image does not update a separately installed Xray binary.
        result = command(["docker", "exec", probe, "python", "-c",
                          "import os,subprocess,json; "
                          "p=os.getenv('XRAY_EXECUTABLE_PATH','/usr/local/bin/xray'); "
                          "r=subprocess.run([p,'version'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,universal_newlines=True,timeout=10); "
                          "print(json.dumps({'version':r.stdout.splitlines()[0] if r.returncode==0 and r.stdout else '', 'executable':p}))"],
                         timeout=15)
        return {"image": inspect_container(probe)["Image"], "core": json.loads(result.stdout)}
    finally:
        command(["docker", "rm", "-f", probe], check=False, timeout=15)


def report_core_compatibility(core, name):
    version = core.get("version", "")
    print("Runtime core: " + (version or "version unavailable") + " (previous executable preserved for rollback)", file=sys.stderr)
    match = re.match(r"^Xray ([0-9]+)\.([0-9]+)\.([0-9]+)\b", version)
    if not match or tuple(map(int, match.groups())) < SS2022_POLICY_CORE_VERSION:
        print("Warning: this legacy or unrecognized core may ignore the SS2022 idle and buffer policy. "
              "GOMEMLIMIT alone cannot prevent connection accumulation or GC CPU pressure. "
              "Official v26.3.27 is pinned by this installer. An external per-process idle guard or a separately reviewed core fix is needed for affected transports; "
              "'" + name + " core-update' does not remove this install/update pin.", file=sys.stderr)


def image_module(image):
    result = command(["docker", "run", "--rm", "--network", "none", "--entrypoint", "python", image,
                      "-c", "from pathlib import Path; print(Path('/code/xray.py').read_text(), end='')"])
    return patch_module(result.stdout)


def patch_rest_module(source):
    if sha256(source.encode()) != ORIGINAL_REST_SHA256:
        raise RuntimeError("Unsupported REST module; existing services were not stopped")
    before = "if f'Xray {self.core_version} started' in log:\n                            break"
    if source.count(before) != 2:
        raise RuntimeError("Unexpected REST startup wait loop")
    result = source.replace(before, "if f'Xray {self.core_version} started' in log:\n                            return self.response()")
    ast.parse(result)
    return result


def image_rest_module(image):
    result = command(["docker", "run", "--rm", "--network", "none", "--entrypoint", "python", image,
                      "-c", "from pathlib import Path; print(Path('/code/rest_service.py').read_text(), end='')"])
    return patch_rest_module(result.stdout)


def prepare(base, overlay, data, name, compose_string):
    base, overlay, data = Path(base), Path(overlay), Path(data)
    compose = shlex.split(compose_string)
    initial_base_hash = sha256(base.read_bytes())
    command(compose + ["-f", str(base), "-p", name, "config", "-q"])
    old_container = inspect_container(name)
    if old_container and old_container["Config"].get("Labels", {}).get("com.docker.compose.service") != "marzban-node":
        raise RuntimeError("The container name belongs to another service")
    previous = json.loads(overlay.read_text()) if overlay.exists() else {}
    budget = choose_budget(effective_memory())
    configured = configured_image(compose, base, name)
    image = configured["image"]
    report_core_compatibility(configured["core"], name)
    source = image_module(image)
    rest_source = image_rest_module(image)
    core = stage_pinned_core(data)
    module = data / "node-runtime-patch" / "xray.py"
    updated = runtime_override(previous, image, module, budget, core)
    rest_module = data / "node-runtime-patch/rest_service.py"
    service = updated["services"]["marzban-node"]
    service["volumes"] = [v for v in service["volumes"] if not (isinstance(v, dict) and v.get("target") == "/code/rest_service.py") and not (isinstance(v, str) and v.split(":")[1:2] == ["/code/rest_service.py"])]
    service["volumes"].append({"type": "bind", "source": str(rest_module), "target": "/code/rest_service.py", "read_only": True})
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
    backups = data / "node-runtime-backups"
    backups.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup = Path(tempfile.mkdtemp(prefix=stamp, dir=backups))
    state = {"base": str(base), "overlay": str(overlay), "module": str(module), "name": name, "data": str(data),
             "old_image": old_container["Image"] if old_container else None,
             "old_id": old_container["Id"] if old_container else None,
             "old_restart_count": old_container["RestartCount"] if old_container else 0,
             "was_running": bool(old_container and old_container["State"]["Running"]),
             "budget": budget, "image": image, "backup": str(backup)}
    paths = dict(guard_paths(data, name), rest_module=rest_module, network_profile=Path("/etc/sysctl.d/93-marzban-node-network.conf"))
    state.update({key: str(value) for key, value in paths.items()})
    state["network_old"], state["network_new"] = network_plan()
    state["guard_enabled"] = command(["systemctl", "is-enabled", paths["guard_timer"].name], check=False).returncode == 0
    state["guard_active"] = command(["systemctl", "is-active", paths["guard_timer"].name], check=False).returncode == 0
    for label, path in [("overlay", overlay), ("module", module)] + list(paths.items()):
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
        atomic_write(rest_module, rest_source, 0o644)
        atomic_write(overlay, json.dumps(updated, indent=2) + "\n")
    except BaseException:
        restore_files(state)
        raise
    print("Runtime profile: balanced; Go memory budget: " + budget, file=sys.stderr)
    print(statefile)


def restore_files(state):
    for label in ("module", "overlay", "guard", "guard_service", "guard_timer", "rest_module", "network_profile"):
        target = Path(state[label])
        if state[label + "_existed"]:
            backup = Path(state["backup"]) / label
            atomic_write(target, backup.read_text(), backup.stat().st_mode & 0o777)
        elif target.exists():
            try:
                target.unlink()
            except FileNotFoundError:
                pass


def rollback(statefile, compose_string):
    state = json.loads(Path(statefile).read_text())
    timer = Path(state["guard_timer"]).name
    command(["systemctl", "stop", timer], check=False)
    if not state["guard_enabled"]:
        command(["systemctl", "disable", timer], check=False)
    restore_files(state)
    for key, value in state["network_old"].items():
        command(["sysctl", "-w", key + "=" + value], check=False)
    command(["systemctl", "daemon-reload"], check=False)
    if state["guard_active"]:
        command(["systemctl", "start", timer], check=False)
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
    version = command(["docker", "exec", state["name"], "/opt/marzban-runtime/xray", "version"], timeout=15).stdout
    if not version.startswith("Xray " + PINNED_CORE_VERSION + " "):
        raise RuntimeError("Running node core does not match the verified version pin")
    install_idle_guard(state)
    if state["network_new"]:
        atomic_write(state["network_profile"], "# Marzban defaults; installation rollback retains prior values.\n" + "".join(key + " = " + value + "\n" for key, value in state["network_new"].items()), 0o644)
        command(["sysctl", "-p", state["network_profile"]])


def main(args):
    try:
        if args[0] == "prepare":
            prepare(*args[1:])
        elif args[0] == "rollback":
            rollback(*args[1:])
        elif args[0] == "verify":
            verify(*args[1:])
        elif args[0] == "remove-idle":
            remove_idle_guard(*args[1:])
        else:
            raise RuntimeError("Unknown runtime operation")
    except Exception as error:
        print("Node runtime error: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
