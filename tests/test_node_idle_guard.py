import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("idle_guard", ROOT / "node-runtime/idle_guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class IdleGuardTests(unittest.TestCase):
    def test_ipv4_mapped_and_native_ipv6_filters_are_bracketed(self):
        item = {"local": ("::ffff:192.0.2.1", 8086), "peer": ("::ffff:198.51.100.2", 50000)}
        result = guard.socket_filter(item)
        self.assertEqual(result[1], "[::ffff:192.0.2.1]")
        self.assertEqual(result[6], "[::ffff:198.51.100.2]")
        item["local"] = ("::1", 8086)
        self.assertEqual(guard.socket_filter(item)[1], "[::1]")

    def sample(self, port=8086, inode=42, received=500, idle=610000, queue=0):
        return guard.parse_sockets(f"0 {queue} [::ffff:192.0.2.1]:{port} [::ffff:198.51.100.2]:54321 users:((\"xray\",pid=100,fd=10)) ino:{inode} bytes_sent:100 bytes_received:{received} lastsnd:{idle} lastrcv:{idle} lastack:5")

    def test_idle_data_socket_is_selected_even_if_keepalive_ack_is_recent(self):
        current = self.sample()
        self.assertEqual(set(guard.eligible(current, current, {"42"}, {22, 62050, 62051}, 300)), {"42"})

    def test_ssh_and_control_ports_are_never_selected(self):
        for port in [22, 6111, 62050, 62051]:
            current = self.sample(port=port)
            self.assertFalse(guard.eligible(current, current, {"42"}, {22, 6111, 62050, 62051}, 300))

    def test_progress_pending_data_new_sockets_and_other_processes_are_kept(self):
        previous = self.sample()
        for current, owned in [(self.sample(received=501), {"42"}), (self.sample(idle=100), {"42"}),
                               (self.sample(queue=1), {"42"}), (self.sample(inode=43), {"43"}), (self.sample(), {"99"})]:
            self.assertFalse(guard.eligible(current, previous, owned, set(), 300))

    def test_missing_idle_measurements_are_not_guessed(self):
        self.assertFalse(guard.parse_sockets('0 0 192.0.2.1:80 198.51.100.2:1234 ino:42 bytes_sent:100'))


if __name__ == "__main__":
    unittest.main(verbosity=2)
