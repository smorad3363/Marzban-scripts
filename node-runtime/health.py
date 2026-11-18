#!/usr/bin/env python3
"""Record bounded, host-local Marzban node performance history."""
import argparse
import datetime
import errno
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import time


LOG_DIR = Path("/var/log/marzban-node-health")
LOG_NAME = "samples.jsonl"
FILE_BYTES = 8 * 1024**2
FILE_COUNT = 8  # Includes the current file.
FREE_RESERVE = 512 * 1024**2
PAIRS = Path("/etc/gremgr/pairs")
GRE_TOOL = "/usr/local/sbin/gremgr-pair"
NET = Path("/sys/class/net")
TICKS = os.sysconf("SC_CLK_TCK")
PROTOCOL_FIELDS = {
    "Ip": "InDiscards OutDiscards OutNoRoutes ReasmReqds ReasmOKs ReasmFails FragOKs FragFails FragCreates",
    "Icmp": "InDestUnreachs OutDestUnreachs InErrors OutErrors",
    "Tcp": "ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts",
    "TcpExt": "ListenOverflows ListenDrops TCPTimeouts TCPBacklogDrop TCPRcvQDrop TCPSynRetrans TCPMTUPFail TCPMTUPSuccess TCPMemoryPressures",
    "Udp": "InDatagrams OutDatagrams NoPorts InErrors RcvbufErrors SndbufErrors",
}
LINK_FIELDS = {0: "rx_bytes", 1: "rx_packets", 2: "rx_errors", 3: "rx_dropped",
               8: "tx_bytes", 9: "tx_packets", 10: "tx_errors", 11: "tx_dropped"}


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return ""


def number(path):
    value = read(path)
    return int(value) if value.isdigit() else None


def output(args):
    try:
        result = subprocess.run(args, text=True, capture_output=True, timeout=2)
        return result.stdout if result.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def json_input(raw, default):
    try:
        return json.loads(raw)
    except ValueError:
        return default


def paired_counters(raw):
    result = {}
    lines = raw.splitlines()
    for header, values in zip(lines[::2], lines[1::2]):
        names, counts = header.split(), values.split()
        group = names[0].rstrip(":")
        if group in PROTOCOL_FIELDS and counts and names[0] == counts[0]:
            selected = PROTOCOL_FIELDS[group].split()
            result[group] = {k: int(v) for k, v in zip(names[1:], counts[1:]) if k in selected}
    return result


def interfaces():
    result = {}
    for line in read("/proc/net/dev").splitlines()[2:]:
        device, fields = line.split(":", 1)
        device = device.strip()
        values = fields.split()
        stats = {key: int(values[i]) for i, key in LINK_FIELDS.items()}
        stats["mtu"] = number(NET / device / "mtu")
        stats["rps_masks"] = [read(p) for p in sorted((NET / device / "queues").glob("rx-*/rps_cpus"))]
        result[device] = stats
    for q in json_input(output(["tc", "-j", "-s", "qdisc", "show"]), []):
        if q.get("dev") in result:
            fields = ("kind", "handle", "drops", "overlimits", "requeues", "backlog", "qlen")
            result[q["dev"]].setdefault("qdiscs", []).append({k: q[k] for k in fields if k in q})
    return result


def managed_path(identity):
    if not re.fullmatch(r"[0-9a-f]{10}", identity):
        raise ValueError("Invalid GRE pair ID")
    cfg = json_input(read(PAIRS / (identity + ".json")), {})
    device = "gmp-" + identity
    if cfg.get("id") != identity or cfg.get("tunnel") != device or cfg.get("role") not in ("foreign", "iran"):
        raise ValueError("Unknown managed GRE pair")
    peer = str(ipaddress.IPv4Address(cfg["peer_tun"]))
    routes = json_input(output(["ip", "-j", "-4", "route", "get", peer]), [])
    route = routes[0] if routes and routes[0].get("dev") == device else {}
    metrics = route.get("metrics", [])
    if isinstance(metrics, dict):
        metrics = [metrics]
    pmtu = next((int(m["mtu"]) for m in metrics if str(m.get("mtu", "")).isdigit()), None)
    mtu = number(NET / device / "mtu")
    return {"role": cfg["role"], "configured_mtu": cfg["mtu"], "link_mtu": mtu,
            "route_matches": bool(route), "route_mtu": pmtu,
            "mtu_mismatch": bool(mtu and pmtu and pmtu < mtu)}


def repair_path(identity):
    path = managed_path(identity)
    mtu, learned = path["link_mtu"], path["route_mtu"]
    if path["role"] != "foreign" or not path["route_matches"] or not mtu or path["configured_mtu"] != mtu:
        raise ValueError("Expected an active, consistent node-side GRE pair")
    if not learned or learned >= mtu:
        print("No smaller route MTU observed for " + identity)
        return
    if learned < 1280:
        raise ValueError("Observed MTU below 1280 requires manual investigation")
    subprocess.run([GRE_TOOL, "set-mtu", identity, str(learned)], check=True, timeout=90)
    updated = managed_path(identity)
    if updated["link_mtu"] != learned or updated["configured_mtu"] != learned:
        raise RuntimeError("GRE MTU change did not take effect")
    print(f"Set the matching ingress pair {identity} to {learned} using gremgr-pair set-mtu.")


def xray_processes():
    result = {}
    for comm in Path("/proc").glob("[0-9]*/comm"):
        if read(comm).lower() != "xray":
            continue
        proc = comm.parent
        fields = read(proc / "stat").rpartition(") ")[2].split()
        if len(fields) < 22:
            continue
        status = dict(line.split(":", 1) for line in read(proc / "status").splitlines() if ":" in line)
        entry = {"start_ticks": int(fields[19]), "cpu_ticks": int(fields[11]) + int(fields[12]),
                 "threads": int(fields[17]), "rss_kib": int(status.get("VmRSS", "0").split()[0])}
        group = next((s[3:] for s in read(proc / "cgroup").splitlines() if s.startswith("0::/")), "")
        if group:
            cgroup = Path("/sys/fs/cgroup") / group.lstrip("/")
            entry["cgroup_memory_bytes"] = number(cgroup / "memory.current")
            entry["cgroup_memory_max"] = read(cgroup / "memory.max")
            for file in ("cpu.stat", "memory.events"):
                entry[file] = {k: int(v) for k, v in (l.split() for l in read(cgroup / file).splitlines())}
        result[proc.name] = entry
    return result


def disk_space(directory):
    stat = os.statvfs(directory)
    return {"free_bytes": stat.f_bavail * stat.f_frsize, "total_bytes": stat.f_blocks * stat.f_frsize,
            "free_inodes": stat.f_favail}


def snapshot(directory):
    cpu = {p[0]: list(map(int, p[1:9])) for p in (line.split() for line in read("/proc/stat").splitlines())
           if p and p[0].startswith("cpu")}
    memory = {k.rstrip(":"): int(v) for k, v, *_ in (l.split() for l in read("/proc/meminfo").splitlines())
              if k.rstrip(":") in ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree", "Slab", "SReclaimable", "Dirty")}
    disk = {}
    for path in Path("/sys/block").glob("*/stat"):
        if path.parent.name.startswith(("loop", "ram")):
            continue
        values = read(path).split()
        if len(values) >= 11:
            disk[path.parent.name] = {k: int(values[i]) for i, k in ((0, "reads"), (2, "sectors_read"), (4, "writes"),
                                                                     (6, "sectors_written"), (8, "in_flight"), (9, "io_ms"))}
    tcp = paired_counters(read("/proc/net/snmp"))
    tcp.update(paired_counters(read("/proc/net/netstat")))
    paths = {}
    for path in PAIRS.glob("*.json"):
        try:
            paths[path.stem] = managed_path(path.stem)
        except (KeyError, ValueError, TypeError):
            paths[path.stem] = {"error": "invalid GRE profile"}
    table = Path("/proc/sys/net/netfilter")
    conntrack = {k: number(table / ("nf_conntrack_" + k)) for k in ("count", "max", "tcp_timeout_established")}
    if shutil.which("conntrack"):
        for key, count in re.findall(r"\b(insert_failed|drop|early_drop|search_restart)=(\d+)", output(["conntrack", "-S"])):
            conntrack[key] = conntrack.get(key, 0) + int(count)
    admission = json_input(read("/run/marzban-node-admission.json"), {})
    instances = {}
    for file in Path("/run/marzban-node-health-ports").glob("*.json"):
        summary = json_input(read(file), {})
        if 0 <= time.time() - summary.get("sample_unix", 0) <= 180:
            instances[file.stem] = summary
    pressure = {k: read("/proc/pressure/" + k).splitlines() for k in ("cpu", "io", "memory")}
    return {"utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
            "boot_id": read("/proc/sys/kernel/random/boot_id"), "monotonic_s": time.monotonic(),
            "load": read("/proc/loadavg").split()[:3], "cpu_ticks": cpu, "memory_kib": memory, "pressure": pressure,
            "disk_space": disk_space(directory), "disk_io": disk, "links": interfaces(), "protocols": tcp,
            "softnet": [[int(x, 16) for x in l.split()[:3]] for l in read("/proc/net/softnet_stat").splitlines()],
            "sockets": (read("/proc/net/sockstat") + "\n" + read("/proc/net/sockstat6")).strip().splitlines(),
            "conntrack": conntrack, "admission": {k: admission[k] for k in ("paused", "reasons", "memory_available_mib", "budget", "pause_at", "resume_at", "sample_unix") if k in admission},
            "gre": paths, "xray": xray_processes(), "port_samples": instances}


def interval(previous, current):
    seconds = current["monotonic_s"] - previous["monotonic_s"]
    if current["boot_id"] != previous["boot_id"] or seconds <= 0:
        return {}
    result = {"seconds": round(seconds, 2), "cpu_pct": {}, "link_mbps": {}, "xray_cpu_pct": {}}
    for name, values in current["cpu_ticks"].items():
        if name in previous["cpu_ticks"]:
            diff = [a - b for a, b in zip(values, previous["cpu_ticks"][name])]
            total = sum(diff)
            if total > 0 and min(diff) >= 0:
                result["cpu_pct"][name] = {"busy": round(100 * (total - diff[3] - diff[4]) / total, 1),
                                           "softirq": round(100 * diff[6] / total, 1), "steal": round(100 * diff[7] / total, 1)}
    for name, values in current["links"].items():
        old = previous["links"].get(name, {})
        if all(key in old and values[key] >= old[key] for key in ("rx_bytes", "tx_bytes")):
            result["link_mbps"][name] = {k: round((values[k + "_bytes"] - old[k + "_bytes"]) * 8 / (1e6 * seconds), 3) for k in ("rx", "tx")}
    for pid, entry in current["xray"].items():
        old = previous["xray"].get(pid, {})
        if old.get("start_ticks") == entry["start_ticks"]:
            result["xray_cpu_pct"][pid] = round(100 * (entry["cpu_ticks"] - old["cpu_ticks"]) / (TICKS * seconds), 1)
    result["protocol_delta"] = {}
    for group, keys in {"Ip": ("FragFails", "ReasmFails"), "Tcp": ("OutSegs", "RetransSegs"),
                        "TcpExt": ("ListenDrops", "TCPTimeouts"), "Udp": ("RcvbufErrors", "SndbufErrors")}.items():
        old, now = previous["protocols"].get(group, {}), current["protocols"].get(group, {})
        for key in keys:
            if key in old and key in now and now[key] >= old[key]:
                result["protocol_delta"][key] = now[key] - old[key]
    return result


def append_record(directory, record, limit=FILE_BYTES, files=FILE_COUNT, reserve=FREE_RESERVE):
    data = (json.dumps(record, separators=(",", ":"), allow_nan=False) + "\n").encode()
    if len(data) > limit:
        raise ValueError("Sample exceeds a complete log segment")
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        space = disk_space(directory)
        if space["free_bytes"] < reserve + len(data) or space["free_inodes"] < 2:
            return False
        active = directory / LOG_NAME
        if active.exists() and active.stat().st_size + len(data) > limit:
            for suffix in range(files - 1, 0, -1):
                src = active if suffix == 1 else directory / f"{LOG_NAME}.{suffix - 1}"
                if src.exists():
                    src.replace(directory / f"{LOG_NAME}.{suffix}")
        with active.open("ab", buffering=0) as stream:
            offset = stream.tell()
            try:
                if stream.write(data) != len(data):
                    raise OSError("Incomplete health sample")
            except OSError:
                stream.truncate(offset)
                raise
        return True
    finally:
        os.close(fd)


def notify(message):
    address = os.environ.get("NOTIFY_SOCKET")
    if address:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
            sock.sendto(message.encode(), "\0" + address[1:] if address.startswith("@") else address)


def serve():
    os.umask(0o077)
    LOG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    previous = None
    while True:
        started = time.monotonic()
        current = snapshot(LOG_DIR)
        if previous:
            current["interval"] = interval(previous, current)
        try:
            written = append_record(LOG_DIR, current)
        except OSError as error:
            if error.errno not in (errno.ENOSPC, errno.EDQUOT):
                raise
            written = False
        status = "Recorded sample" if written else "History paused: insufficient free space"
        notify(("READY=1\n" if previous is None else "") + f"STATUS={status} at {current['utc']}")
        previous = current
        time.sleep(max(1, 60 - (time.monotonic() - started)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--serve", action="store_true")
    mode.add_argument("--once", action="store_true")
    mode.add_argument("--apply-gre-pmtu", metavar="PAIR_ID")
    args = parser.parse_args()
    if args.serve:
        serve()
    elif args.once:
        directory = next(p for p in (LOG_DIR, *LOG_DIR.parents) if p.is_dir())
        print(json.dumps(snapshot(directory)))
    else:
        repair_path(args.apply_gre_pmtu)


if __name__ == "__main__":
    main()
