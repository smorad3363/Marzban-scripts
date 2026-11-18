#!/usr/bin/env python3
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("runtime_manager", ROOT / "node-runtime/manager.py")
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)
SOURCE = (ROOT / "tests/fixtures/node-xray.original.py").read_text()


class ModuleTests(unittest.TestCase):
    def load_runtime(self):
        config = types.ModuleType("config")
        for key, value in {"DEBUG": False, "SSL_CERT_FILE": "/cert.pem", "SSL_KEY_FILE": "/key.pem", "XRAY_API_HOST": "127.0.0.1", "XRAY_API_PORT": 62051, "INBOUNDS": []}.items():
            setattr(config, key, value)
        logger = types.ModuleType("logger")
        logger.logger = mock.Mock()
        module = types.ModuleType("patched_node")
        with mock.patch.dict(sys.modules, {"config": config, "logger": logger}):
            exec(compile(manager.patch_module(SOURCE), "patched_node.py", "exec"), module.__dict__)
        return module

    def test_exact_tested_module_and_idempotent_patch(self):
        self.assertEqual(manager.sha256(SOURCE.encode()), manager.ORIGINAL_MODULE_SHA256)
        patched = manager.patch_module(SOURCE)
        self.assertEqual(manager.sha256(patched.encode()), manager.PATCHED_MODULE_SHA256)
        self.assertEqual(manager.patch_module(patched), patched)
        with self.assertRaisesRegex(RuntimeError, "Unsupported"):
            manager.patch_module(SOURCE + "# unreviewed image\n")

    def test_policy_keeps_accounts_counters_and_stricter_limits(self):
        module = self.load_runtime()
        original = {"inbounds": [{"tag": "users", "port": 2053, "protocol": "vmess", "settings": {"clients": [{"id": "fixture-user", "level": 0}]}}],
                    "outbounds": [{"protocol": "freedom", "tag": "direct"}],
                    "policy": {"levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}, "3": {"handshake": 3, "connIdle": 30, "bufferSize": 16}}, "system": {"statsOutboundDownlink": True}}}
        with mock.patch.dict(os.environ, {"XRAY_NODE_MEMORY_PROFILE": "balanced"}, clear=True):
            result = module.XRayConfig(json.dumps(original), "192.0.2.1")
        self.assertEqual(next(i for i in result["inbounds"] if i["tag"] == "users"), original["inbounds"][0])
        self.assertEqual(result["outbounds"], original["outbounds"])
        self.assertTrue(result["policy"]["levels"]["0"]["statsUserUplink"])
        self.assertTrue(result["policy"]["levels"]["0"]["statsUserDownlink"])
        self.assertEqual(result["policy"]["levels"]["3"], original["policy"]["levels"]["3"])
        self.assertEqual(result["policy"]["system"], original["policy"]["system"])
        self.assertNotIn("metrics", result)

    def test_go_environment_reaches_child_without_copying_other_secrets(self):
        module = self.load_runtime()
        with mock.patch.dict(os.environ, {"GOGC": "50", "GOMEMLIMIT": "4096MiB", "UNRELATED_SECRET": "fixture"}, clear=True), mock.patch.object(module.XRayCore, "get_version", return_value="26.3.27"):
            core = module.XRayCore()
        self.assertEqual(core._env["GOGC"], "50")
        self.assertEqual(core._env["GOMEMLIMIT"], "4096MiB")
        self.assertNotIn("UNRELATED_SECRET", core._env)

    def test_diagnostics_remain_optional_and_loopback_only(self):
        module = self.load_runtime()
        with mock.patch.dict(os.environ, {"XRAY_NODE_METRICS_LISTEN": "0.0.0.0:25443"}, clear=True):
            with self.assertRaises(ValueError):
                module.XRayConfig("{}", "192.0.2.1")
        with mock.patch.dict(os.environ, {"XRAY_NODE_METRICS_LISTEN": "127.0.0.1:25443"}, clear=True):
            self.assertEqual(module.XRayConfig("{}", "192.0.2.1")["metrics"]["listen"], "127.0.0.1:25443")

    def test_restart_reaps_previous_child_and_drains_stderr(self):
        module = self.load_runtime()
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "fixture-xray"
            marker = Path(directory) / "ready"
            executable.write_text("#!" + sys.executable + "\nimport sys,time,pathlib\nif 'version' in sys.argv:\n print('Xray 26.3.27 fixture'); sys.exit()\nsys.stdin.read()\nsys.stderr.write('fixture warning\\n' * 12000); sys.stderr.flush()\npathlib.Path(" + repr(str(marker)) + ").write_text('ready')\nwhile True: time.sleep(.05)\n")
            executable.chmod(0o700)
            core = module.XRayCore(str(executable))
            config = module.XRayConfig("{}", "127.0.0.1")
            try:
                core.start(config)
                previous = core.process
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(marker.exists(), "stderr pipe blocked the core")
                core.restart(config)
                self.assertIsNotNone(previous.returncode, "previous core was not reaped")
                self.assertNotEqual(core.process.pid, previous.pid)
                current = core.process
                core.stop()
                self.assertIsNotNone(current.returncode)
                self.assertIsNone(core.process)
            finally:
                core.stop()


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base = self.root / "app/docker-compose.yml"
        self.base.parent.mkdir()
        self.base.write_text("# preserve this comment\nservices:\n  marzban-node:\n    image: example/node:latest\n    environment:\n      SERVICE_PROTOCOL: rpyc\n      SERVICE_PORT: '61050'\n      XRAY_API_PORT: '61051'\n      XRAY_EXECUTABLE_PATH: /var/lib/marzban-node/xray-core/xray\n")
        self.original_base = self.base.read_bytes()
        self.overlay = self.base.parent / "docker-compose.runtime.json"
        self.data = self.root / "data"
        self.data.mkdir()
        self.cert = self.data / "cert.pem"
        self.cert.write_text("fixture client certificate: must survive\n")
        self.core = self.data / "xray-core/xray"
        self.core.parent.mkdir()
        self.core.write_bytes(b"keep the installed core binary")
        self.old = {"Id": "old-container", "Image": "sha256:old-image", "RestartCount": 0, "State": {"Running": True}, "Config": {"Env": ["GOMEMLIMIT=4GiB", "SERVICE_PROTOCOL=rpyc"], "Labels": {"com.docker.compose.service": "marzban-node"}}}
        self.calls = []
        def run(args, **kwargs):
            self.calls.append(args)
            return subprocess.CompletedProcess(args, 0, "", "")
        for patch in [mock.patch.object(manager, "command", side_effect=run),
                      mock.patch.object(manager, "inspect_container", return_value=copy.deepcopy(self.old)),
                      mock.patch.object(manager, "configured_image", return_value={"image": "sha256:new-image", "core": {"version": "Xray 26.3.27", "executable": "/var/lib/marzban-node/xray-core/xray"}}),
                      mock.patch.object(manager, "image_module", return_value=manager.patch_module(SOURCE)),
                      mock.patch.object(manager, "image_rest_module", return_value=manager.patch_rest_module((ROOT / "tests/fixtures/node-rest.original.py").read_text())),
                      mock.patch.object(manager, "stage_pinned_core", return_value=self.data / "pinned/xray"),
                      mock.patch.object(manager, "guard_paths", return_value={"guard": self.data / "idle_guard.py", "guard_service": self.root / "idle.service", "guard_timer": self.root / "idle.timer"}),
                      mock.patch.object(manager, "network_plan", return_value=({}, {})),
                      mock.patch.object(manager, 'connection_paths', return_value={'admission_script': self.data / 'admission.py', 'admission_service': self.root / 'admission.service'}),
                      mock.patch.object(manager, "health_paths", return_value={"health_script": self.data / "health.py", "health_service": self.root / "health.service"}),
                      mock.patch.object(manager, "effective_memory", return_value=8 * 1024**3)]:
            patch.start()
            self.addCleanup(patch.stop)

    def prepare(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            manager.prepare(self.base, self.overlay, self.data, "master", "docker compose")
        return Path(output.getvalue().strip())

    def test_existing_node_migrates_without_rewriting_its_settings_or_data(self):
        statefile = self.prepare()
        overlay = json.loads(self.overlay.read_text())
        self.assertEqual(self.base.read_bytes(), self.original_base)
        self.assertEqual(self.cert.read_text(), "fixture client certificate: must survive\n")
        self.assertEqual(self.core.read_bytes(), b"keep the installed core binary")
        self.assertEqual(overlay["services"]["marzban-node"]["environment"]["GOMEMLIMIT"], "6144MiB")
        self.assertEqual(json.loads(statefile.read_text())["old_image"], "sha256:old-image")
        self.assertFalse(any("down" in call for call in self.calls))

    def test_overlay_keeps_custom_values_and_other_services(self):
        original = {"services": {"sidecar": {"image": "example/sidecar"}, "marzban-node": {"environment": ["CUSTOM=keep", "XRAY_NODE_METRICS_LISTEN=127.0.0.1:25443"], "volumes": ["/custom:/custom:ro", "/old:/code/xray.py:ro"]}}}
        self.overlay.write_text(json.dumps(original))
        self.prepare()
        updated = json.loads(self.overlay.read_text())
        self.assertEqual(updated["services"]["sidecar"], original["services"]["sidecar"])
        node = updated["services"]["marzban-node"]
        self.assertEqual(node["environment"]["CUSTOM"], "keep")
        self.assertEqual(node["environment"]["XRAY_NODE_METRICS_LISTEN"], "127.0.0.1:25443")
        self.assertIn("/custom:/custom:ro", node["volumes"])
        self.assertEqual(sum(isinstance(v, dict) and v.get("target") == "/code/xray.py" for v in node["volumes"]), 1)

    def test_previous_50_percent_runtime_budget_is_upgraded(self):
        self.overlay.write_text(json.dumps({"services": {"marzban-node": {"environment": {"GOMEMLIMIT": "4096MiB", "CUSTOM": "keep"}}}}))
        self.prepare()
        env = json.loads(self.overlay.read_text())["services"]["marzban-node"]["environment"]
        self.assertEqual(env["GOMEMLIMIT"], "6144MiB")
        self.assertEqual(env["CUSTOM"], "keep")
        self.assertEqual(self.base.read_bytes(), self.original_base)

    def test_target_container_memory_limit_bounds_the_go_budget(self):
        with mock.patch.object(manager, "configured_image", return_value={"image": "sha256:new-image", "core": {"version": "Xray 26.3.27"}, "memory_limit": 4 * 1024**3}):
            self.prepare()
        env = json.loads(self.overlay.read_text())["services"]["marzban-node"]["environment"]
        self.assertEqual(env["GOMEMLIMIT"], "3072MiB")
        self.assertEqual(self.base.read_bytes(), self.original_base)

    def test_failure_restores_old_overlay_module_and_pins_the_previous_image(self):
        self.overlay.write_text('{"services":{}}\n')
        module = self.data / "node-runtime-patch/xray.py"
        module.parent.mkdir()
        module.write_text("previous runtime module\n")
        statefile = self.prepare()
        manager.rollback(statefile, "docker compose")
        self.assertEqual(module.read_text(), "previous runtime module\n")
        self.assertEqual(self.overlay.read_text(), '{"services":{}}\n')
        recovery = json.loads((statefile.parent / "recovery.json").read_text())
        self.assertEqual(recovery["services"]["marzban-node"]["image"], "sha256:old-image")
        self.assertIn("--no-deps", self.calls[-1])
        self.assertEqual(self.base.read_bytes(), self.original_base)

    def test_image_preflight_failure_leaves_running_node_files_intact(self):
        with mock.patch.object(manager, "image_module", side_effect=RuntimeError("unsupported image")):
            with self.assertRaisesRegex(RuntimeError, "unsupported"):
                self.prepare()
        self.assertFalse(self.overlay.exists())
        self.assertEqual(self.base.read_bytes(), self.original_base)
        self.assertFalse(any("up" in call or "down" in call for call in self.calls))

    def test_concurrent_compose_edit_is_not_overwritten(self):
        def image(*args):
            self.base.write_text("a concurrent administrator edit\n")
            return {"image": "sha256:new-image", "core": {"version": "Xray 26.3.27"}}
        with mock.patch.object(manager, "configured_image", side_effect=image):
            with self.assertRaisesRegex(RuntimeError, "Compose changed"):
                self.prepare()
        self.assertEqual(self.base.read_text(), "a concurrent administrator edit\n")
        self.assertFalse(self.overlay.exists())


class ContractTests(unittest.TestCase):
    def test_version_display_prefers_the_active_pinned_core_to_a_legacy_binary(self):
        script = (ROOT / "marzban-node.sh").read_text()
        function = re.search(r"^get_current_xray_core_version\(\) \{\n.*?^\}\n", script, re.M | re.S)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "xray-core").mkdir()
            old = root / "xray-core/xray"
            old.write_text("#!/bin/sh\necho 'Xray 25.3.6 legacy'\n")
            old.chmod(0o700)
            (root / "overlay.json").write_text("{}")
            shell = function + '\ndocker() { echo "Xray 26.3.27 active"; }\nget_current_xray_core_version\n'
            env = dict(os.environ, DATA_MAIN_DIR=str(root), RUNTIME_COMPOSE_FILE=str(root / "overlay.json"), APP_NAME="master")
            result = subprocess.run(["bash", "-c", shell], env=env, capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.strip(), "26.3.27 (in container)")

    def test_docker_hub_failure_uses_official_mirror_without_rewriting_compose(self):
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            return subprocess.CompletedProcess(args, 1 if "pull" in args and args[0] == "docker" and args[1] == "compose" else 0, "", "rate limited")
        with mock.patch.object(manager, "command", side_effect=run), mock.patch.object(manager, "configured_node_image", return_value="gozargah/marzban-node:latest"):
            manager.pull_node_image("/opt/master/docker-compose.yml", "master", "docker compose")
        self.assertIn(["docker", "pull", "ghcr.io/gozargah/marzban-node:latest"], calls)
        self.assertIn(["docker", "tag", "ghcr.io/gozargah/marzban-node:latest", "gozargah/marzban-node:latest"], calls)

    def test_custom_registry_failure_is_not_replaced_with_a_different_image(self):
        with mock.patch.object(manager, "command", return_value=subprocess.CompletedProcess([], 1, "", "denied")) as run, mock.patch.object(manager, "configured_node_image", return_value="private.example/custom:stable"):
            with self.assertRaisesRegex(RuntimeError, "pull failed"):
                manager.pull_node_image("/opt/master/docker-compose.yml", "master", "docker compose")
        self.assertEqual(run.call_count, 1)

    def test_pin_rejects_download_tampering_before_creating_an_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            response = mock.MagicMock()
            response.__enter__.return_value.read.return_value = b"unverified archive"
            with mock.patch.object(manager.platform, "machine", return_value="x86_64"), mock.patch.object(manager.urllib.request, "urlopen", return_value=response):
                with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                    manager.stage_pinned_core(directory)
            self.assertFalse((Path(directory) / "node-runtime-core").exists())

    def test_network_profile_keeps_stricter_timeouts_but_bounds_oversized_tables(self):
        current = {"net.ipv4.tcp_keepalive_time": "60", "net.ipv4.tcp_keepalive_intvl": "10", "net.ipv4.tcp_keepalive_probes": "3",
                   "net.netfilter.nf_conntrack_tcp_timeout_established": "600", "net.netfilter.nf_conntrack_max": "524288", "net.ipv4.tcp_mtu_probing": "2"}
        def probe(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, current.get(args[-1], "1") + "\n", "")
        with mock.patch.object(manager, "command", side_effect=probe), mock.patch.object(manager, "effective_memory", return_value=2 * 1024**3):
            with mock.patch.object(manager, 'connection_settings', return_value=(32768, 75, 60)):
                old, new = manager.network_plan()
        for key, value in current.items():
            self.assertEqual(new[key], '32768' if key == 'net.netfilter.nf_conntrack_max' else value)
        self.assertEqual(new["net.ipv4.conf.all.send_redirects"], "0")

    def test_network_shrink_retains_headroom_for_busy_table(self):
        values = {'net.netfilter.nf_conntrack_max': '262144', 'net.netfilter.nf_conntrack_count': '150000'}
        def probe(args, **kwargs): return subprocess.CompletedProcess(args, 0, values.get(args[-1], '1'), '')
        with mock.patch.object(manager, 'command', side_effect=probe), mock.patch.object(manager, 'connection_settings', return_value=(65536, 75, 60)):
            _, new = manager.network_plan()
        self.assertEqual(new['net.netfilter.nf_conntrack_max'], '200000')

    def test_network_does_not_raise_an_existing_sensible_smaller_table(self):
        values = {'net.netfilter.nf_conntrack_max': '65536', 'net.netfilter.nf_conntrack_count': '1000'}
        def probe(args, **kwargs): return subprocess.CompletedProcess(args, 0, values.get(args[-1], '1'), '')
        with mock.patch.object(manager, 'command', side_effect=probe), mock.patch.object(manager, 'connection_settings', return_value=(131072, 75, 60)):
            _, new = manager.network_plan()
        self.assertEqual(new['net.netfilter.nf_conntrack_max'], '65536')

    def test_legacy_core_warning_does_not_claim_soft_memory_budget_fixes_ss2022(self):
        for version in ("Xray 26.3.27 (Xray)", "Xray 26.9.9", "Xray 1.8.24", "custom core", ""):
            output = io.StringIO()
            with contextlib.redirect_stderr(output):
                manager.report_core_compatibility({"version": version}, "node2")
            self.assertIn("Warning:", output.getvalue())
            self.assertIn("node2 core-update", output.getvalue())
            self.assertIn("previous executable preserved for rollback", output.getvalue())
        for version in ("Xray 26.10.31 (Xray)", "Xray 26.11.1", "Xray 27.1.1"):
            output = io.StringIO()
            with contextlib.redirect_stderr(output):
                manager.report_core_compatibility({"version": version}, "node2")
            self.assertNotIn("Warning:", output.getvalue())

    def test_memory_budgets_are_75_percent_at_different_server_sizes(self):
        for gib in (1, 2, 4, 8, 16, 32):
            total = gib * 1024**3
            self.assertEqual(manager.memory_bytes(manager.choose_budget(total)), total * 3 // 4)
        total = 7743 * 1024**2 + 512 * 1024
        budget = manager.memory_bytes(manager.choose_budget(total))
        self.assertLessEqual(budget, total * 3 // 4)
        self.assertLess(total * 3 // 4 - budget, 1024**2)

    def test_original_cli_parser_menus_and_fresh_install_prompts_are_unchanged(self):
        script = (ROOT / "marzban-node.sh").read_text()
        expected = json.loads((ROOT / "tests/fixtures/node-cli-contract.json").read_text())
        digest = lambda text: hashlib.sha256(text.encode()).hexdigest()
        self.assertEqual(digest(script.split("# Fetch IP address")[0]), expected["argument_parser"])
        for name, value in expected["functions"].items():
            function = re.search(r"^" + name + r"\(\) \{\n.*?^\}\n", script, re.M | re.S)
            self.assertIsNotNone(function)
            self.assertEqual(digest(function[0]), value, name)

    def test_standalone_script_contains_the_tested_manager(self):
        subprocess.run([sys.executable, str(ROOT / "tools/embed-node-runtime.py"), "--check"], check=True)
        subprocess.run(["bash", "-n", str(ROOT / "marzban-node.sh")], check=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
