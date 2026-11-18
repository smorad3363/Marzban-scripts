#!/usr/bin/env python3
"""Pause new node TCP sessions under local conntrack or memory pressure.

Only public TCP listeners owned by Xray in Marzban-node containers are gated.
This is local admission control, not a limit on a provider's upstream table.
"""
import argparse
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

POLICY = Path('/etc/marzban-node/connection-budget.json')
STATUS = Path('/run/marzban-node-admission.json')
CHAIN = 'MZN_ADMIT'
MARKER = 'marzban-node-budget-v1'
HOOK = ['-m', 'comment', '--comment', MARKER, '-j', CHAIN]
MEMORY_HOLD_SECONDS = 8


def run(args, check=True, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, check=check, timeout=15, **kwargs)


def default_budget():
    memory = next(int(line.split()[1]) * 1024 for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemTotal:'))
    return 32768 if memory < 3 * 1024**3 else 65536 if memory < 7 * 1024**3 else 131072


def read_policy(path=POLICY):
    value = json.loads(path.read_text()) if path.exists() else {}
    if not isinstance(value, dict) or set(value) - {'tracked_budget', 'pause_percent', 'resume_percent', 'memory'}:
        raise ValueError('Unknown connection-budget setting')
    budget = value['tracked_budget'] if 'tracked_budget' in value else default_budget()
    pause, resume = value.get('pause_percent', 75), value.get('resume_percent', 60)
    if type(budget) is not int or not 1024 <= budget <= 1048576:
        raise ValueError('tracked_budget must be an integer from 1024 to 1048576')
    if any(type(x) is not int for x in (pause, resume)) or not 10 <= resume < pause <= 90:
        raise ValueError('Require 10 <= resume_percent < pause_percent <= 90')
    memory = value.get('memory')
    if memory is not None:
        keys = ('pause_available_mib', 'resume_available_mib')
        if not isinstance(memory, dict) or set(memory) != set(keys):
            raise ValueError('Memory admission needs pause_available_mib and resume_available_mib')
        memory = tuple(memory[key] for key in keys)
        if any(type(x) is not int for x in memory) or not 128 <= memory[0] < memory[1]:
            raise ValueError('Memory admission requires integer MiB limits with 128 <= pause < resume')
    return (budget, pause, resume), memory


def policy(path=POLICY):
    return read_policy(path)[0]


def memory_available():
    for line in Path('/proc/meminfo').read_text().splitlines():
        if line.startswith('MemAvailable:'):
            return int(line.split()[1]) // 1024
    return None


def memory_gate(available, limits, paused, pending_since, now):
    if limits is None or available is None:
        return False, None
    pause, resume = limits
    should_pause = available < resume if paused else available <= pause
    if should_pause == paused:
        return paused, None
    if pending_since is None:
        return paused, now
    if now - pending_since >= MEMORY_HOLD_SECONDS:
        return should_pause, None
    return paused, pending_since


def pressure(count, maximum, settings, paused=False):
    budget, high, low = settings
    budget = min(maximum, budget)
    if count < 0 or budget < 1:
        raise ValueError('Invalid conntrack counters')
    paused = count > budget * low // 100 if paused else count >= budget * high // 100
    return paused, budget


def listener_ports(output, pids, protected):
    ports = set()
    for line in output.splitlines():
        if not (pids & {int(v) for v in re.findall(r'pid=(\d+)', line)}):
            continue
        parts = line.split()
        if len(parts) < 5:
            continue
        try:
            host, port = parts[3].rsplit(':', 1)
            port = int(port)
            host = host.strip('[]').split('%', 1)[0]
            if host != '*':
                address = ipaddress.ip_address(host)
                if address.is_loopback or getattr(address, 'ipv4_mapped', None) and address.ipv4_mapped.is_loopback:
                    continue
            if 1 <= port <= 65535 and port not in protected:
                ports.add(port)
        except ValueError:
            continue
    return ports


def discover_ports():
    names = run(['docker', 'ps', '--filter', 'label=com.docker.compose.service=marzban-node', '--format', '{{.Names}}']).stdout.splitlines()
    pids, protected = set(), {22, 6111}
    for name in names:
        info = json.loads(run(['docker', 'inspect', name]).stdout)[0]
        # Bridge-mode container ports do not traverse the host INPUT chain.
        if info.get('HostConfig', {}).get('NetworkMode') != 'host':
            continue
        env = dict(x.split('=', 1) for x in info['Config'].get('Env', []) if '=' in x)
        protected.update(int(env.get(key, default)) for key, default in [('SERVICE_PORT', '62050'), ('XRAY_API_PORT', '62051')])
        top = run(['docker', 'top', name, '-eo', 'pid,comm']).stdout
        for line in top.splitlines()[1:]:
            parts = line.split()
            if len(parts) == 2 and parts[1] == 'xray':
                pids.add(int(parts[0]))
    # Protect SSH even when its configured port differs from 22 or 6111.
    output = run(['ss', '-Hlntp']).stdout
    for line in output.splitlines():
        if '"sshd"' in line or '"sshd-session"' in line:
            try: protected.add(int(line.split()[3].rsplit(':', 1)[1]))
            except (IndexError, ValueError): pass
    return listener_ports(output, pids, protected)


def rules(ports, paused):
    lines = ['*filter', ':' + CHAIN + ' - [0:0]', '-F ' + CHAIN]
    ports = sorted(set(ports) - {22, 6111})
    if any(type(p) is not int or not 1 <= p <= 65535 for p in ports):
        raise ValueError('Invalid data port')
    if paused:
        for offset in range(0, len(ports), 15):
            selected = ','.join(map(str, ports[offset:offset + 15]))
            lines.append('-A ' + CHAIN + ' ! -i lo -p tcp --syn -m conntrack --ctstate NEW -m multiport --dports ' + selected + ' -j REJECT --reject-with tcp-reset')
    lines += ['-A ' + CHAIN + ' -m comment --comment ' + MARKER + ' -j RETURN', 'COMMIT', '']
    return '\n'.join(lines)


class Firewall:
    def __init__(self, families=None):
        if families is None:
            families = ['iptables']
            if Path('/proc/net/if_inet6').exists() and Path('/proc/net/if_inet6').read_text().strip():
                families.append('ip6tables')
        self.families = families
        self.last = None

    def check_owner(self, binary):
        result = run([binary, '-w', '5', '-S', CHAIN], check=False)
        if result.returncode == 0 and MARKER not in result.stdout:
            raise RuntimeError('Refusing to change an unowned firewall chain')
        return result.returncode == 0

    def apply(self, ports, paused):
        key = (tuple(sorted(ports)), paused)
        if self.last == key:
            return
        for binary in self.families:
            if not shutil.which(binary) or not shutil.which(binary + '-restore'):
                raise RuntimeError('Node admission needs ' + binary)
            self.check_owner(binary)
            # --noflush leaves every other chain, table and rule unchanged.
            run([binary + '-restore', '-w', '5', '--noflush'], input=rules(ports, paused))
            if run([binary, '-w', '5', '-C', 'INPUT'] + HOOK, check=False).returncode:
                run([binary, '-w', '5', '-I', 'INPUT', '1'] + HOOK)
        self.last = key

    def clear(self):
        errors = []
        for binary in dict.fromkeys(self.families + ['iptables', 'ip6tables']):
            try:
                if not shutil.which(binary) or not self.check_owner(binary):
                    continue
                while run([binary, '-w', '5', '-C', 'INPUT'] + HOOK, check=False).returncode == 0:
                    run([binary, '-w', '5', '-D', 'INPUT'] + HOOK)
                run([binary, '-w', '5', '-F', CHAIN])
                run([binary, '-w', '5', '-X', CHAIN])
            except Exception as exc:
                errors.append(str(exc))
        self.last = None
        if errors:
            raise RuntimeError('; '.join(errors))


def counters():
    root = Path('/proc/sys/net/netfilter')
    return int((root / 'nf_conntrack_count').read_text()), int((root / 'nf_conntrack_max').read_text())


def serve():
    firewall = Firewall()
    conn_paused, mem_paused, pending = False, False, None
    previous_memory, reasons, ports, refresh = None, [], set(), 0
    def stop(*_): raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        while True:
            now = time.monotonic()
            settings, memory = read_policy()
            count, maximum = counters()
            conn_paused, budget = pressure(count, maximum, settings, conn_paused)
            available = memory_available() if memory is not None else None
            if memory != previous_memory:
                pending = None
                previous_memory = memory
            mem_paused, pending = memory_gate(available, memory, mem_paused, pending, now)
            next_reasons = [name for name, paused in (('conntrack', conn_paused), ('memory', mem_paused)) if paused]
            if now >= refresh or bool(next_reasons) != bool(reasons):
                ports = discover_ports()
                refresh = now + 15
            firewall.apply(ports, bool(next_reasons))
            state = {'pid': os.getpid(), 'count': count, 'kernel_max': maximum, 'budget': budget, 'paused': bool(ports and next_reasons),
                     'reasons': next_reasons, 'memory_available_mib': available,
                     'data_ports': sorted(ports), 'pause_at': budget * settings[1] // 100,
                     'resume_at': budget * settings[2] // 100, 'sample_unix': time.time()}
            if next_reasons != reasons:
                print(json.dumps(state), flush=True)
            STATUS.write_text(json.dumps(state) + '\n')
            STATUS.chmod(0o600)
            reasons = next_reasons
            time.sleep(2)
    except KeyboardInterrupt:
        pass
    finally:
        firewall.clear()
        STATUS.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--clear', action='store_true')
    args = parser.parse_args()
    # A second service/installer must not replace a gate while the daemon runs.
    with open('/run/marzban-node-admission.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.clear:
            Firewall().clear()
            STATUS.unlink(missing_ok=True)
        else:
            serve()


if __name__ == '__main__':
    main()
