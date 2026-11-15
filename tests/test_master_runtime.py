import ast
import importlib.util
from pathlib import Path
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock
from functools import wraps
from contextlib import contextmanager

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("patches", ROOT / "master-runtime/patches.py")
patches = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patches)
sys_path = __import__("sys").path
sys_path.insert(0, str(ROOT / "master-runtime"))
apply_spec = importlib.util.spec_from_file_location("master_apply", ROOT / "master-runtime/apply.py")
master_apply = importlib.util.module_from_spec(apply_spec)
apply_spec.loader.exec_module(master_apply)


class MasterTests(unittest.TestCase):
    def test_compose_change_preserves_database_settings_and_other_mounts(self):
        original = "services:\n  marzban:\n    environment:\n      DATABASE_URL: fixture-unchanged\n    volumes:\n      - /opt/marzban/node.py:/code/app/xray/node.py\n      - /data:/var/lib/marzban\n  mysql:\n    image: mysql:8.0\n"
        result = master_apply.compose_text(original, Path("/opt/marzban/master-stability"))
        self.assertIn("DATABASE_URL: fixture-unchanged", result)
        self.assertIn("- /data:/var/lib/marzban", result)
        self.assertIn("mysql:\n    image: mysql:8.0", result)
        self.assertEqual(result.count(":/code/app/jobs/0_xray_core.py"), 1)

    def test_unknown_compose_mount_layout_is_rejected(self):
        with self.assertRaises(ValueError): master_apply.compose_text("services: {}\n", Path("/tmp/fixture"))

    def health(self, node):
        source = patches.patch_health((ROOT / "tests/fixtures/master-health.original.py").read_text())
        tree = ast.parse(source)
        selected = [n for n in tree.body if isinstance(n, ast.Assign) or isinstance(n, ast.FunctionDef) and n.name == "core_health_check"]
        operations = SimpleNamespace(restart_node=Mock(), connect_node=Mock())
        clock = SimpleNamespace(now=0)
        scope = {"time": SimpleNamespace(monotonic=lambda: clock.now), "xray": SimpleNamespace(core=SimpleNamespace(started=True), nodes={1: node}, config=SimpleNamespace(include_db_users=lambda: {}), operations=operations), "xray_exc": SimpleNamespace(XrayError=ConnectionError), "logger": Mock()}
        exec(compile(ast.Module(body=selected, type_ignores=[]), "health.py", "exec"), scope)
        return scope["core_health_check"], clock, operations

    def test_one_or_two_transient_api_failures_do_not_restart_data(self):
        api = SimpleNamespace(get_sys_stats=Mock(side_effect=[ConnectionError(), ConnectionError(), {}]))
        check, clock, operations = self.health(SimpleNamespace(connected=True, started=True, api=api))
        for now in [0, 15, 31]:
            clock.now = now; check()
        operations.restart_node.assert_not_called()
        operations.connect_node.assert_not_called()

    def test_repeated_failure_is_rechecked_and_has_a_recovery_cooldown(self):
        api = SimpleNamespace(get_sys_stats=Mock(side_effect=ConnectionError()))
        check, clock, operations = self.health(SimpleNamespace(connected=True, started=True, api=api))
        for now in [0, 15, 31, 40, 60, 70, 100]:
            clock.now = now; check()
        self.assertEqual(operations.restart_node.call_count, 1)

    def test_recovered_api_during_final_check_is_not_restarted(self):
        api = SimpleNamespace(get_sys_stats=Mock(side_effect=[ConnectionError(), ConnectionError(), ConnectionError(), {}]))
        check, clock, operations = self.health(SimpleNamespace(connected=True, started=True, api=api))
        for now in [0, 15, 31]:
            clock.now = now; check()
        operations.restart_node.assert_not_called()

    def test_confirmed_stopped_core_recovers_without_the_long_control_grace(self):
        check, clock, operations = self.health(SimpleNamespace(connected=True, started=False))
        check(); operations.restart_node.assert_not_called()
        clock.now = 5; check(); operations.restart_node.assert_called_once()

    def test_missing_control_channel_requires_repeated_failures(self):
        check, clock, operations = self.health(SimpleNamespace(connected=False))
        for now in [0, 15, 31]:
            clock.now = now; check()
        operations.connect_node.assert_called_once()

    def test_rest_session_requests_are_serialized(self):
        source = patches.patch_control((ROOT / "tests/fixtures/master-node.original.py").read_text())
        tree = ast.parse(source)
        nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "_serialized_node_control" or isinstance(n, ast.ClassDef) and n.name in ("ReSTXRayNode", "NodeAPIError")]
        scope = {"threading": threading, "wraps": wraps, "XRayConfig": object, "contextmanager": contextmanager}
        exec(compile(ast.Module(body=nodes, type_ignores=[]), "control.py", "exec"), scope)
        node = scope["ReSTXRayNode"].__new__(scope["ReSTXRayNode"])
        node._node_control_lock = threading.RLock(); node._rest_api_url = "https://fixture"; node._session_id = "fixture"
        active, peak = [0], [0]
        def post(*args, **kwargs):
            active[0] += 1; peak[0] = max(peak[0], active[0]); time.sleep(.03); active[0] -= 1
            return SimpleNamespace(status_code=200, json=lambda: {})
        node.session = SimpleNamespace(post=post)
        threads = [threading.Thread(target=node.make_request, args=("/ping", 1)) for _ in range(3)]
        for thread in threads: thread.start()
        for thread in threads: thread.join(timeout=2)
        self.assertEqual(peak[0], 1)
        self.assertFalse(any(thread.is_alive() for thread in threads))
        self.assertEqual(source.count("timeout=10)"), 2)

    def test_unknown_master_source_is_rejected_before_changes(self):
        for function in [patches.patch_control, patches.patch_health]:
            with self.assertRaises(ValueError): function("# unknown deployed version\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
