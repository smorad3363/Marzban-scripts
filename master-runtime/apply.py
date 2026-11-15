#!/usr/bin/env python3
"""Apply the reviewed legacy-master patch; preserve all existing data and mounts."""
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from patches import patch_control, patch_health, digest


def compose_text(source, directory):
    lines = source.splitlines(True)
    matches = [i for i, line in enumerate(lines) if ":/code/app/xray/node.py" in line and line.lstrip().startswith("-")]
    if len(matches) > 1 or ":/code/app/jobs/0_xray_core.py" in source:
        raise ValueError("Unrecognized master mounts; existing configuration was not changed")
    if matches:
        index = matches[0]
        indent = lines[index][:len(lines[index]) - len(lines[index].lstrip())]
        remove = 1
    else:
        services = [i for i, line in enumerate(lines) if line.strip() == 'marzban:' and line.startswith('  ') and not line.startswith('   ')]
        if len(services) != 1:
            raise ValueError('Unrecognized master service')
        begin = services[0] + 1
        end = next((i for i in range(begin, len(lines)) if lines[i].strip() and not lines[i].lstrip().startswith('#') and len(lines[i]) - len(lines[i].lstrip()) <= 2), len(lines))
        volumes = [i for i in range(begin, end) if lines[i].strip() == 'volumes:' and lines[i].startswith('    ') and not lines[i].startswith('     ')]
        if len(volumes) != 1:
            raise ValueError('Unrecognized master volumes')
        index, indent, remove = volumes[0] + 1, '      ', 0
    lines[index:index + remove] = [indent + "- " + str(directory / "node.py") + ":/code/app/xray/node.py:ro\n",
                                  indent + "- " + str(directory / "health.py") + ":/code/app/jobs/0_xray_core.py:ro\n"]
    return "".join(lines)


def run(args):
    return subprocess.run(args, capture_output=True, text=True, check=True, timeout=120)


def atomic(path, text, mode=0o600):
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".master-stability-")
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def apply(root):
    root = Path(root)
    base = root / "docker-compose.yml"
    before = base.read_text()
    node = run(['docker', 'exec', 'marzban-marzban-1', 'cat', '/code/app/xray/node.py']).stdout
    health = run(["docker", "exec", "marzban-marzban-1", "cat", "/code/app/jobs/0_xray_core.py"]).stdout
    patched_node, patched_health = patch_control(node), patch_health(health)
    directory = root / "master-stability"
    directory.mkdir(mode=0o700, exist_ok=True)
    candidate = compose_text(before, directory)
    compile(patched_node, "node.py", "exec"); compile(patched_health, "health.py", "exec")
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = Path("/root") / ("marzban-master-patch-" + stamp)
    backup.mkdir(mode=0o700)
    (backup / "docker-compose.yml").write_text(before)
    (backup / "node.py").write_text(node)
    (backup / "health.py").write_text(health)
    manifest = {"node_before": digest(node), "health_before": digest(health), "node_after": digest(patched_node), "health_after": digest(patched_health)}
    (backup / "manifest.json").write_text(json.dumps(manifest, indent=2))
    atomic(directory / "node.py", patched_node)
    atomic(directory / "health.py", patched_health)
    fd, temporary = tempfile.mkstemp(dir=root, suffix=".yml", prefix=".master-check-")
    os.close(fd)
    try:
        Path(temporary).write_text(candidate)
        run(["docker", "compose", "-p", "marzban", "-f", temporary, "config", "-q"])
    finally:
        Path(temporary).unlink(missing_ok=True)
    if base.read_text() != before:
        raise RuntimeError("Compose was edited concurrently; restart was not attempted")
    try:
        atomic(base, candidate)
        run(["docker", "compose", "-p", "marzban", "-f", str(base), "up", "-d", "--no-deps", "--force-recreate", "marzban"])
        inspected = json.loads(run(["docker", "inspect", "marzban-marzban-1"]).stdout)[0]
        if not inspected["State"]["Running"]:
            raise RuntimeError("Patched master did not start")
    except BaseException:
        atomic(base, before)
        run(["docker", "compose", "-p", "marzban", "-f", str(base), "up", "-d", "--no-deps", "--force-recreate", "marzban"])
        raise
    print(json.dumps({"applied": True, "backup": str(backup), "database_modified": False, "manifest": manifest}))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 master-runtime/apply.py /opt/marzban")
    apply(sys.argv[1])
