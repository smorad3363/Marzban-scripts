#!/usr/bin/env python3
"""Reap confirmed idle TCP sockets owned by one selected node container.

Kernel data-idle timers, two byte-counter snapshots, inode ownership and a final
rescan are required. No conntrack table is flushed and no process is killed.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

SOCKET_STATES = ("fin-wait-2", "close-wait", "established")
# Inodes and TCP counters come from ss; owners() verifies process ownership.
SOCKET_DETAILS = ["ss", "-HtnieO"]


def command(args):
    return subprocess.run(args, text=True, capture_output=True, check=True, timeout=20).stdout


def endpoint(value):
    host, port = value.rsplit(":", 1)
    return host.strip("[]"), int(port)


def parse_sockets(output):
    result = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        try:
            queues = [int(parts[0]), int(parts[1])]
            local, peer = endpoint(parts[2]), endpoint(parts[3])
        except ValueError:
            continue
        values = {k: int(v) for k, v in re.findall(r"\b(ino|bytes_sent|bytes_received|lastsnd|lastrcv):(\d+)", line)}
        if not values.get("ino") or "lastsnd" not in values or "lastrcv" not in values:
            continue
        inode = str(values["ino"])
        result[inode] = {"local": local, "peer": peer, "bytes": [values.get("bytes_sent", 0), values.get("bytes_received", 0)],
                         "idle_ms": min(values["lastsnd"], values["lastrcv"]), "queues": queues}
    return result


def snapshot():
    result = {}
    # An application-owned half-close is not covered by the kernel's orphaned
    # FIN-WAIT timeout. Reap confirmed idle half-closes before open sessions.
    for state in SOCKET_STATES:
        sockets = parse_sockets(command([*SOCKET_DETAILS, "state", state]))
        for item in sockets.values():
            item["state"] = state
        result.update(sockets)
    return result


def socket_filter(item):
    host, port = item["local"]
    peer, peer_port = item["peer"]
    # iproute2 treats an unbracketed IPv6 suffix as a port, including
    # IPv4-mapped addresses returned for dual-stack Xray listeners.
    host = "[" + host + "]" if ":" in host else host
    peer = "[" + peer + "]" if ":" in peer else peer
    return ["src", host, "sport", "=", ":" + str(port), "dst", peer, "dport", "=", ":" + str(peer_port)]


def batch_filter(items):
    result = []
    for item in items:
        if result:
            result.append("or")
        result.extend(["("] + socket_filter(item) + [")"])
    return result


def owners(container):
    inspected = json.loads(command(["docker", "inspect", container]))[0]
    if inspected["Config"].get("Labels", {}).get("com.docker.compose.service") != "marzban-node":
        raise RuntimeError("Selected container is not a Marzban node")
    env = dict(x.split("=", 1) for x in inspected["Config"].get("Env", []) if "=" in x)
    protected = {22, 6111, int(env.get("SERVICE_PORT", 62050)), int(env.get("XRAY_API_PORT", 62051))}
    inodes = set()
    for line in command(["docker", "top", container, "-eo", "pid,comm"]).splitlines()[1:]:
        parts = line.split()
        if len(parts) != 2 or parts[1] != "xray":
            continue
        try:
            for descriptor in Path("/proc", parts[0], "fd").iterdir():
                try:
                    link = os.readlink(descriptor)
                    match = re.fullmatch(r"socket:\[(\d+)\]", link)
                    if match:
                        inodes.add(match[1])
                except OSError:
                    pass
        except OSError:
            pass
    return inodes, protected


def eligible(current, previous, owned, protected, idle_seconds):
    selected = {}
    for inode, item in current.items():
        before = previous.get(inode)
        receive, send = item["queues"]
        # CLOSE-WAIT's final FIN can occupy one sequence byte without payload.
        empty = send == 0 and (receive == 0 or item.get("state") == "close-wait" and receive == 1)
        if inode not in owned or before is None or not empty:
            continue
        if item["local"][1] in protected or item["peer"][1] in protected:
            continue
        if item["idle_ms"] < idle_seconds * 1000:
            continue
        if any(item[k] != before[k] for k in ("local", "peer", "bytes")):
            continue
        selected[inode] = item
    return selected


def save_state(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(data, stream)
    os.replace(temporary, path)


def run(container, state_path, idle_seconds=300, apply=False, limit=2000):
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    previous = {}
    now = time.monotonic()
    if state_path.exists():
        state = json.loads(state_path.read_text())
        # JSON round trips lists; normalise addresses before comparisons.
        if state.get("boot") == boot and state.get("container") == container and 30 <= now - state.get("time", now) <= 180:
            previous = state.get("sockets", {})
            for value in previous.values():
                value["local"] = tuple(value["local"])
                value["peer"] = tuple(value["peer"])
    current = snapshot()
    owned, protected = owners(container)
    selected = eligible(current, previous, owned, protected, idle_seconds)
    attempted = 0
    if apply and selected:
        # Recheck data progress and ownership immediately before socket destroy.
        fresh = snapshot()
        fresh_owned, protected = owners(container)
        selected = eligible(fresh, selected, fresh_owned, protected, idle_seconds)
        targets = list(selected.items())[:limit]
        for state in SOCKET_STATES:
            state_targets = [(inode, item) for inode, item in targets if item["state"] == state]
            for offset in range(0, len(state_targets), 64):
                batch = dict(state_targets[offset:offset + 64])
                filters = batch_filter(batch.values())
                # Fail closed if iproute2 matches an unexpected socket inode.
                matches = parse_sockets(command([*SOCKET_DETAILS, "state", state, *filters]))
                for item in matches.values(): item["state"] = state
                if set(matches) - set(batch):
                    raise RuntimeError("Socket batch filter matched an unexpected inode")
                confirmed = eligible(matches, batch, fresh_owned, protected, idle_seconds)
                if confirmed:
                    command(["ss", "-Knt", "state", state] + batch_filter(confirmed.values()))
                    attempted += len(confirmed)
        remaining = snapshot()
        closed = sum(inode not in remaining for inode in list(selected)[:limit])
        current = remaining
    else:
        closed = 0
    # Store node sockets only. Never retain other services' endpoint inventory.
    save_state(state_path, {"boot": boot, "container": container, "time": now, "sockets": {k: v for k, v in current.items() if k in owned}})
    return {"container": container, "apply": apply, "idle_seconds": idle_seconds, "owned_tcp": len(set(current) & owned),
            "confirmed_idle": len(selected), "attempted": attempted, "closed": closed}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", required=True)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--idle-seconds", type=int, default=300)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if args.idle_seconds < 300:
        parser.error("Production idle timeout must be at least 300 seconds")
    print(json.dumps(run(args.container, args.state, args.idle_seconds, args.apply)))
