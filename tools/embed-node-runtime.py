#!/usr/bin/env python3
"""Keep the standalone CLI and the tested runtime manager identical."""
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / "marzban-node.sh"
current = path.read_text()
manager_path = root / "node-runtime/manager.py"
manager = manager_path.read_text()
manager_expected = manager
for module in ("idle_guard", "connection_guard", "health"):
    marker = module.upper().replace("_", " ")
    begin, end = "# BEGIN EMBEDDED " + marker + "\n", "# END EMBEDDED " + marker
    before, rest = manager_expected.split(begin, 1)
    _, after = rest.split(end, 1)
    source = (root / "node-runtime" / (module + ".py")).read_text()
    manager_expected = before + begin + module.upper() + "_SOURCE = " + repr(source) + "\n" + end + after
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
