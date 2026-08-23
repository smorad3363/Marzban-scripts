#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
function_source="$(awk '
  /^set_owner_command\(\)/ { capture = 1 }
  capture { print }
  capture && /^}$/ { exit }
' "$repo_root/marzban.sh")"

eval "$function_source"

colorized_echo() { :; }
cli_command() { printf '%s\n' "$*"; }

test "$(set_owner_command)" = "admin set-owner"
test "$(set_owner_command demo-owner)" = "admin set-owner --username demo-owner"
test "$(set_owner_command --username demo-owner)" = "admin set-owner --username demo-owner"
test "$(set_owner_command --help)" = "admin set-owner --help"

echo "set-owner wrapper contract: PASS"
