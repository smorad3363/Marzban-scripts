#!/usr/bin/env python3
"""Keep the standalone CLI and the tested runtime manager identical."""
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / "marzban-node.sh"
current = path.read_text()
begin = "# BEGIN EMBEDDED NODE RUNTIME MANAGER\n"
end = "# END EMBEDDED NODE RUNTIME MANAGER"
before, rest = current.split(begin, 1)
_, after = rest.split(end, 1)
expected = before + begin + (root / "node-runtime/manager.py").read_text() + end + after
if "--check" in sys.argv:
    if expected != current:
        sys.exit("Run python3 tools/embed-node-runtime.py before committing")
else:
    path.write_text(expected)
