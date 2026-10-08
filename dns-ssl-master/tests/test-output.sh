#!/usr/bin/env bash
set -Eeuo pipefail

# Test formatter and TXT parser without network, DNS, root, or live issuance.
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_file="$repo_dir/master-dns-ssl.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for func in show_cert_paths show_expiry cert_is_current manual_issue_completed show_txt_records extract_txt_records; do
  awk -v func="$func" '
    $0 == func "() {" {printing=1}
    printing {print}
    printing && /^}$/ {printing=0}
  ' "$source_file" >> "$tmp/functions.sh"
done

# The actual project functions, not rewritten test copies.
source "$tmp/functions.sh"
say() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
GREEN='' RESET='' DOMAIN="drwsh.org"

cat > "$tmp/mock-acme.log" <<'MOCK'
[Thu Oct 8 02:42:11 PM UTC 2026] Add the following TXT record:
[Thu Oct 8 02:42:11 PM UTC 2026] Domain: '_acme-challenge.drwsh.org'
[Thu Oct 8 02:42:11 PM UTC 2026] TXT value: 'xiCEOmawJd34A5ujg0LSZtX-b_oB5gQFim9UNOTGKVU'
[Thu Oct 8 02:42:11 PM UTC 2026] Add the following TXT record:
[Thu Oct 8 02:42:11 PM UTC 2026] Domain: '_acme-challenge.drwsh.org'
[Thu Oct 8 02:42:11 PM UTC 2026] TXT value: '_jN1glPMpYLtHY7w-Gx0urq1UgWtndh-7K2VRJZ66v8'
MOCK

extract_txt_records "$tmp/mock-acme.log" "$tmp/records"
[[ "$(wc -l < "$tmp/records")" -eq 2 ]]
records_output="$(show_txt_records "$tmp/records")"
grep -Fxq '_acme-challenge.drwsh.org' <<< "$records_output"
grep -Fxq '_acme-challenge' <<< "$records_output"
grep -Fxq 'xiCEOmawJd34A5ujg0LSZtX-b_oB5gQFim9UNOTGKVU' <<< "$records_output"
grep -Fxq '_jN1glPMpYLtHY7w-Gx0urq1UgWtndh-7K2VRJZ66v8' <<< "$records_output"
grep -Fq 'TXT RECORD 1' <<< "$records_output"
grep -Fq 'TXT RECORD 2' <<< "$records_output"

paths_output="$(show_cert_paths /var/lib/marzban/certs/drwsh.org)"
grep -Fxq '/var/lib/marzban/certs/drwsh.org/fullchain.pem' <<< "$paths_output"
grep -Fxq '/var/lib/marzban/certs/drwsh.org/key.pem' <<< "$paths_output"
grep -Fq 'CERTIFICATE FILE (certificateFile):' <<< "$paths_output"
grep -Fq 'PRIVATE KEY FILE (keyFile):' <<< "$paths_output"

# A domain that was already validated by ACME can be signed immediately.
# Generate a real short-lived test certificate and verify exact SAN coverage,
# no-TXT success detection, date output, and mismatched/failed cases.
mkdir -p "$tmp/active"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -keyout "$tmp/key.pem" -out "$tmp/active/fullchain.pem" \
  -subj '/CN=drwsh.org' \
  -addext 'subjectAltName=DNS:drwsh.org,DNS:*.drwsh.org' >/dev/null 2>&1
cp "$tmp/key.pem" "$tmp/active/key.pem"
printf '%s\n' 'Cert success.' > "$tmp/mock-success.log"
manual_issue_completed 0 "$tmp/mock-success.log" "$tmp/active/fullchain.pem" drwsh.org 1
if manual_issue_completed 1 "$tmp/mock-success.log" "$tmp/active/fullchain.pem" drwsh.org 1; then
  echo 'FAIL: nonzero ACME return code treated as success' >&2; exit 1
fi
if manual_issue_completed 0 "$tmp/mock-success.log" "$tmp/active/fullchain.pem" other.org 1; then
  echo 'FAIL: nonmatching certificate treated as success' >&2; exit 1
fi
actual="$(show_cert_paths "$tmp/active")"
grep -Fq 'CERTIFICATE EXPIRES (UTC):' <<< "$actual"
grep -Fq 'DAYS REMAINING:' <<< "$actual"
grep -Fxq "$tmp/active/fullchain.pem" <<< "$actual"
grep -Fxq "$tmp/active/key.pem" <<< "$actual"

echo "PASS: TXT parsing, reused ACME validation, certificate expiry and copyable paths"
