#!/usr/bin/env python3
import concurrent.futures
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


def load(name):
    path = Path(__file__).resolve().parents[1] / "node-runtime" / (name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


health = load("health")
idle = load("idle_guard")
manager = load("manager")


class HealthTests(unittest.TestCase):
    def test_container_log_cap_respects_driver_and_existing_rotation(self):
        service = {}
        manager.bound_container_log(service, {"Type": "json-file", "Config": {}})
        self.assertEqual(service["logging"]["options"], {"max-size": "8m", "max-file": "3"})
        for base in ({"Type": "journald"}, {"Type": "json-file", "Config": {"max-size": "2m"}}):
            untouched = {}
            manager.bound_container_log(untouched, base)
            self.assertEqual(untouched, {})
        service = {"logging": {"driver": "local"}}
        manager.bound_container_log(service, {"Type": "json-file"})
        self.assertEqual(service, {"logging": {"driver": "local"}})
        service = {"logging": {"options": {"max-file": "2", "labels": "service"}}}
        manager.bound_container_log(service, {"Type": "json-file"})
        self.assertEqual(service["logging"]["options"], {"max-size": "8m", "max-file": "2", "labels": "service"})

    def test_rotation_is_bounded_under_concurrent_appends_and_low_disk(self):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
                self.assertTrue(all(pool.map(lambda i: health.append_record(directory, {"number": i}, 48, 3, 0), range(120))))
            paths = list(directory.iterdir())
            self.assertEqual(len(paths), 3)
            self.assertLessEqual(sum(p.stat().st_size for p in paths), 144)
            before = {p.name: p.read_bytes() for p in paths}
            for raw in before.values():
                for line in raw.splitlines():
                    self.assertIn("number", json.loads(line))
            with mock.patch.object(health, "disk_space", return_value={"free_bytes": 50, "free_inodes": 20}):
                self.assertFalse(health.append_record(directory, {}, 48, 3, 50))
            self.assertEqual(before, {p.name: p.read_bytes() for p in directory.iterdir()})

    def test_network_counters_and_rates(self):
        self.assertEqual(health.paired_counters("Ip: InReceives FragFails\nIp: 140 3\n"), {"Ip": {"FragFails": 3}})
        def sample(t, count):
            return {"boot_id": "test", "monotonic_s": t, "cpu_ticks": {"cpu": [t, 0, 0, t, 0, 0, 0, 0]},
                    "links": {"eth0": {"rx_bytes": count, "tx_bytes": count}},
                    "xray": {"23": {"start_ticks": 10, "cpu_ticks": t * health.TICKS}},
                    "protocols": {"Ip": {"FragFails": t}}}
        first, last = sample(1, 0), sample(3, 1_000_000)
        rates = health.interval(first, last)
        self.assertEqual(rates["protocol_delta"]["FragFails"], 2)
        self.assertEqual(rates["link_mbps"]["eth0"], {"rx": 4, "tx": 4})
        self.assertEqual(rates["cpu_pct"]["cpu"]["busy"], 50)
        self.assertEqual(rates["xray_cpu_pct"]["23"], 100)
        last["boot_id"] = "next"
        self.assertEqual(health.interval(first, last), {})

    def test_only_selected_foreign_pair_with_matching_route_can_be_lowered(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            key = "1122334455"
            dev = "gmp-" + key
            mtu = root / dev / "mtu"
            mtu.parent.mkdir()
            mtu.write_text("1400")
            path = root / (key + ".json")
            cfg = {"id": key, "tunnel": dev, "role": "foreign", "mtu": 1400, "peer_tun": "10.0.0.1"}
            path.write_text(json.dumps(cfg))
            route = [{"dev": dev, "metrics": [{"mtu": 1280}]}]
            def apply(args, **kwargs):
                self.assertEqual(args, [health.GRE_TOOL, "set-mtu", key, "1280"])
                self.assertTrue(kwargs["check"])
                cfg["mtu"] = 1280
                mtu.write_text("1280")
                path.write_text(json.dumps(cfg))
            with mock.patch.object(health, "PAIRS", root), mock.patch.object(health, "NET", root), \
                    mock.patch.object(health, "output", side_effect=lambda _: json.dumps(route)), \
                    mock.patch.object(health.subprocess, "run", side_effect=apply) as command:
                self.assertTrue(health.managed_path(key)["mtu_mismatch"])
                for change in ({"dev": "eth0"}, {"dev": dev, "metrics": [{"mtu": 900}]}):
                    route[0] = change
                    with self.assertRaises(ValueError):
                        health.repair_path(key)
                route[0] = {"dev": dev}
                health.repair_path(key)
                command.assert_not_called()
                route[0] = {"dev": dev, "metrics": {"mtu": 1280}}
                health.repair_path(key)
                health.repair_path(key)
                command.assert_called_once()

    def test_port_summary_contains_only_aggregate_owned_data_on_listeners(self):
        s = {"state": "established", "local": ("10.0.0.1", 8080), "peer": ("192.0.2.3", 1001),
             "queues": [1, 2], "bytes": [400, 120]}
        old = dict(s, bytes=[300, 50])
        current = {"44": s, "2": s, "3": dict(s, local=("10.0.0.1", 22)), "4": s}
        summary = idle.port_summary(current, {"44": old, "4": dict(old, peer=("192.0.2.3", 999))},
                                    {"44", "3", "4"}, {8080}, 60)
        row = summary["ports"][8080]
        self.assertEqual(row["states"]["established"], 2)
        self.assertEqual((row["matched"], row["matched_tx_bytes"], row["matched_rx_bytes"]), (1, 100, 70))
        self.assertNotIn("192.0.2.3", json.dumps(summary))


if __name__ == "__main__":
    unittest.main()
