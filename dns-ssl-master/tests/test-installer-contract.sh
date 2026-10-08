#!/usr/bin/env bash
# This contract is intentionally immutable. AI tools must not edit it.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

CANONICAL='curl -fsSL https://raw.githubusercontent.com/smorad3363/Marzban-scripts/master/dns-ssl-master/install.sh -o /tmp/master-dns-ssl-install.sh && sudo bash /tmp/master-dns-ssl-install.sh'
BOOTSTRAP_SHA='c02543c05514b59e5617ba6aed1864200e81d8c2'

die() { printf 'FAIL - INSTALL COMMAND CONTRACT: %s\n' "$*" >&2; exit 1; }

[[ -f dns-ssl-master/INSTALL_COMMAND.txt ]] || die "Canonical command file is missing."
[[ -f dns-ssl-master/install.sh ]] || die "Stable installer is missing."
[[ -f dns-ssl-master/README.md ]] || die "README is missing."
[[ -f dns-ssl-master/master-dns-ssl.sh ]] || die "Runtime manager is missing."
[[ -f AGENTS.md && -f .github/copilot-instructions.md && -f .github/CODEOWNERS ]] || die "AI protections or CODEOWNERS missing."

actual="$(cat dns-ssl-master/INSTALL_COMMAND.txt)"
[[ "$actual" == "$CANONICAL" ]] || die "Public installation/update command changed."

grep -Fxq "    $CANONICAL" dns-ssl-master/README.md ||
  die "README must contain the exact immutable install/update command."
grep -Fq "$CANONICAL" AGENTS.md ||
  die "AI agent protections no longer mention the exact command."
grep -Fq "$CANONICAL" .github/copilot-instructions.md ||
  die "Copilot protections no longer mention the exact command."
grep -Fq '/dns-ssl-master/install.sh @smorad3363' .github/CODEOWNERS ||
  die "Bootstrap CODEOWNER entry is missing."

# Git blob identity catches ANY change to the fixed installer, including changes to URL.
current_sha="$(git hash-object dns-ssl-master/install.sh)"
[[ "$current_sha" == "$BOOTSTRAP_SHA" ]] ||
  die "Bootstrap changed ($current_sha). Revert it. Only a human repo owner can intentionally change this locked contract."

bash -n dns-ssl-master/install.sh ||
  die "Installer no longer passes Bash syntax check."

echo 'PASS: stable installer command, bootstrap hash, documentation, and AI rules.'
