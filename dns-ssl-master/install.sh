#!/usr/bin/env bash
# One-command bootstrap. Installs the manager and starts its interactive menu.
set -Eeuo pipefail

if (( EUID != 0 )); then
  echo "Run this installer as root: sudo bash install.sh" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required. Install it: apt-get install -y curl" >&2
  exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

url="https://raw.githubusercontent.com/smorad3363/Marzban-scripts/master/dns-ssl-master/master-dns-ssl.sh"
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$url" -o "$tmp"
bash -n "$tmp"
install -m 0755 "$tmp" /usr/local/sbin/master-dns-ssl
echo "Installed: /usr/local/sbin/master-dns-ssl"
echo "Rerun later: sudo master-dns-ssl"

# Support pipe-based bootstrap on an interactive SSH terminal.
if [[ ! -t 0 && -r /dev/tty ]]; then
  exec /usr/local/sbin/master-dns-ssl </dev/tty
fi
exec /usr/local/sbin/master-dns-ssl
