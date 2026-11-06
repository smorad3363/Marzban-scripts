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
                      mock.patch.object(manager, "configured_image", return_value="sha256:new-image"),
                      mock.patch.object(manager, "image_module", return_value=manager.patch_module(SOURCE)),
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
            return "sha256:new-image"
        with mock.patch.object(manager, "configured_image", side_effect=image):
            with self.assertRaisesRegex(RuntimeError, "Compose changed"):
                self.prepare()
        self.assertEqual(self.base.read_text(), "a concurrent administrator edit\n")
        self.assertFalse(self.overlay.exists())


class ContractTests(unittest.TestCase):
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
