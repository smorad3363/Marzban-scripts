#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('admission', ROOT / 'node-runtime/connection_guard.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class AdmissionTests(unittest.TestCase):
    def test_pressure_has_headroom_and_hysteresis(self):
        settings = (65536, 75, 60)
        self.assertEqual(guard.pressure(49151, 131072, settings), (False, 65536))
        self.assertTrue(guard.pressure(49152, 131072, settings)[0])
        self.assertTrue(guard.pressure(45000, 131072, settings, True)[0])
        self.assertFalse(guard.pressure(39321, 131072, settings, True)[0])
        self.assertEqual(guard.pressure(30000, 32768, settings), (True, 32768))

    def test_ram_defaults_are_bounded(self):
        for gib, expected in [(1,32768),(4,65536),(8,131072),(64,131072)]:
            with mock.patch.object(Path, 'read_text', return_value='MemTotal: '+str(gib*1024**2)+' kB\n'):
                self.assertEqual(guard.default_budget(), expected)

    def test_memory_reserve_defaults_scale_and_preserve_explicit_override(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'policy.json'
            for mib, expected in [(512,(128,256)), (2048,(307,512)), (3915,(587,978)), (8192,(1024,1536)), (65536,(1024,1536))]:
                with mock.patch.object(Path, 'read_text', return_value='MemTotal: '+str(mib*1024)+' kB\n'):
                    self.assertEqual(guard.default_memory_reserve(), expected)
                    self.assertEqual(guard.read_policy(path)[1], expected)
            with mock.patch.object(guard, 'default_memory_reserve', return_value=(587,978)):
                for config, expected in [({},(587,978)), ({'tracked_budget':32768},(587,978)), ({'memory':None},None), ({'memory':{'pause_available_mib':400,'resume_available_mib':800}},(400,800))]:
                    path.write_text(json.dumps(config))
                    self.assertEqual(guard.read_policy(path)[1], expected)

    def test_memory_reserve_invariants(self):
        for mib in range(512, 65537, 127):
            with mock.patch.object(Path, 'read_text', return_value='MemTotal: '+str(mib*1024)+' kB\n'):
                pause, resume = guard.default_memory_reserve()
                self.assertTrue(128 <= pause < resume <= 1536)
                self.assertLess(resume, mib)

    def test_memory_gate_debounces_both_transitions_and_keeps_hysteresis(self):
        limits = (1280, 2304)
        self.assertEqual(guard.memory_gate(1000, limits, False, None, 10), (False, 10))
        self.assertEqual(guard.memory_gate(1400, limits, False, 10, 12), (False, None))
        self.assertEqual(guard.memory_gate(1000, limits, False, 10, 17), (False, 10))
        self.assertEqual(guard.memory_gate(1200, limits, False, 10, 18), (True, None))
        self.assertEqual(guard.memory_gate(1800, limits, True, None, 22), (True, None))
        self.assertEqual(guard.memory_gate(2400, limits, True, None, 24), (True, 24))
        self.assertEqual(guard.memory_gate(2500, limits, True, 24, 32), (False, None))
        self.assertEqual(guard.memory_gate(500, None, True, 24, 32), (False, None))

    def test_optional_memory_settings_have_separate_validated_limits(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'policy.json'
            config = {'tracked_budget': 65536}
            for memory in ({'pause_available_mib': 1280}, {'pause_available_mib': 2304, 'resume_available_mib': 1280}):
                path.write_text(json.dumps(dict(config, memory=memory)))
                with self.assertRaises(ValueError):
                    guard.read_policy(path)
            path.write_text(json.dumps(dict(config, memory={'pause_available_mib': 1280, 'resume_available_mib': 2304})))
            self.assertEqual(guard.read_policy(path), ((65536, 75, 60), (1280, 2304)))

    def test_policy_rejects_typos_invalid_limits_and_wrong_types(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'policy.json'
            for value in [{'provider_limt': 10000}, {'tracked_budget': 0}, {'tracked_budget': True}, {'pause_percent': 99}, {'resume_percent': 80}, {'tracked_budget': '65536'}]:
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError): guard.policy(path)
            path.write_text(json.dumps({'tracked_budget': 50000}))
            self.assertEqual(guard.policy(path), (50000, 75, 60))

    def test_only_owned_public_listeners_are_selected(self):
        output='\n'.join([
            'LISTEN 0 4096 0.0.0.0:8085 0.0.0.0:* users:(("xray",pid=55,fd=1))',
            'LISTEN 0 4096 [::]:8443 [::]:* users:(("xray",pid=55,fd=2))',
            'LISTEN 0 4096 127.0.0.1:25443 0.0.0.0:* users:(("xray",pid=55,fd=3))',
            'LISTEN 0 4096 [::1]:25444 [::]:* users:(("xray",pid=55,fd=4))',
            'LISTEN 0 4096 *:62051 *:* users:(("xray",pid=55,fd=5))',
            'LISTEN 0 4096 *:22 *:* users:(("sshd",pid=1,fd=6))'])
        self.assertEqual(guard.listener_ports(output, {55}, {22,62051}), {8085,8443})

    def test_gate_preserves_established_udp_loopback_and_ssh(self):
        text=guard.rules({22,6111,8085,8443}, True)
        self.assertIn('--syn -m conntrack --ctstate NEW', text)
        self.assertIn('! -i lo', text)
        self.assertIn('--dports 8085,8443', text)
        self.assertNotIn('-p udp', text)
        self.assertNotIn('ESTABLISHED', text)
        self.assertIn('--reject-with tcp-reset', text)
        self.assertNotIn('-j REJECT', guard.rules({8085}, False))

    def test_many_ports_respect_multiport_kernel_limit(self):
        text=guard.rules(set(range(10000,10040)), True)
        entries=[x for x in text.splitlines() if '--dports' in x]
        self.assertEqual(len(entries), 3)
        for line in entries:self.assertLessEqual(len(line.split('--dports ')[1].split()[0].split(',')),15)

    def test_foreign_chain_is_never_replaced_or_removed(self):
        with mock.patch.object(guard, 'run', return_value=subprocess.CompletedProcess([],0,'-N MZN_ADMIT\n','')) as run, mock.patch.object(guard.shutil,'which',return_value='/sbin/fixture'):
            with self.assertRaisesRegex(RuntimeError, 'unowned'):guard.Firewall(['iptables']).apply({8085},True)
        self.assertEqual(run.call_count,1)

    def test_restore_is_scoped_and_never_flushes_all_rules(self):
        def command(args, **kwargs):
            return subprocess.CompletedProcess(args,1 if '-S' in args or '-C' in args else 0,'','')
        with mock.patch.object(guard, 'run', side_effect=command) as run, mock.patch.object(guard.shutil,'which',return_value='/sbin/fixture'):
            guard.Firewall(['iptables']).apply({8085},True)
        restores=[x for x in run.call_args_list if 'iptables-restore' in x.args[0]]
        self.assertEqual(len(restores),1)
        self.assertIn('--noflush',restores[0].args[0])
        self.assertIn('-F MZN_ADMIT', restores[0].kwargs['input'])
        self.assertFalse(any(x.args[0][-1:] == ['-F'] for x in run.call_args_list))


if __name__ == '__main__':unittest.main(verbosity=2)
