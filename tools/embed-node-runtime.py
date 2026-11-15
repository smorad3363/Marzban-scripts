#!/usr/bin/env python3
"""Keep the standalone CLI and the tested runtime manager identical."""
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / "marzban-node.sh"
current = path.read_text()
manager_path = root / "node-runtime/manager.py"
manager = manager_path.read_text()
guard_begin = "# BEGIN EMBEDDED IDLE GUARD\n"
guard_end = "# END EMBEDDED IDLE GUARD"
guard_before, guard_rest = manager.split(guard_begin, 1)
_, guard_after = guard_rest.split(guard_end, 1)
manager_expected = guard_before + guard_begin + "IDLE_GUARD_SOURCE = " + repr((root / "node-runtime/idle_guard.py").read_text()) + "\n" + guard_end + guard_after
connection_begin = '# BEGIN EMBEDDED CONNECTION GUARD\n'
connection_end = '# END EMBEDDED CONNECTION GUARD'
connection_before, connection_rest = manager_expected.split(connection_begin, 1)
_, connection_after = connection_rest.split(connection_end, 1)
manager_expected = connection_before + connection_begin + 'CONNECTION_GUARD_SOURCE = ' + repr((root / 'node-runtime/connection_guard.py').read_text()) + '\n' + connection_end + connection_after
if "--check" in sys.argv:
    if manager != manager_expected:
        sys.exit("Run python3 tools/embed-node-runtime.py before committing")
else:
    manager_path.write_text(manager_expected)
begin = "# BEGIN EMBEDDED NODE RUNTIME MANAGER\n"
end = "# END EMBEDDED NODE RUNTIME MANAGER"
before, rest = current.split(begin, 1)
_, after = rest.split(end, 1)
expected = before + begin + manager_expected + end + after
if "--check" in sys.argv:
    if expected != current:
        sys.exit("Run python3 tools/embed-node-runtime.py before committing")
else:
    path.write_text(expected)
