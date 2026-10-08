#!/usr/bin/env bash
# Master DNS SSL - DNS-01 certificate manager for Debian/Ubuntu
set -Eeuo pipefail
umask 077

ACME_HOME="/root/.acme.sh"
ACME="$ACME_HOME/acme.sh"
CERT_BASE="/etc/ssl/master-dns-ssl"
CRON_FILE="/etc/cron.d/master-dns-ssl"

if [[ -t 1 ]]; then
  RESET=$'\033[0m'; BOLD=$'\033[1m'; CYAN=$'\033[96m'
  GREEN=$'\033[92m'; YELLOW=$'\033[93m'; RED=$'\033[91m'; BLUE=$'\033[94m'
else
  RESET=""; BOLD=""; CYAN=""; GREEN=""; YELLOW=""; RED=""; BLUE=""
fi

say()  { printf '%s\n' "$*"; }
good() { printf '%s✔ %s%s\n' "$GREEN" "$*" "$RESET"; }
warn() { printf '%s! %s%s\n' "$YELLOW" "$*" "$RESET"; }
fail() { printf '%s✘ %s%s\n' "$RED" "$*" "$RESET" >&2; }
pause() { read -r -p "Press Enter to continue... " _ || true; }

if (( EUID != 0 )); then
  fail "Run as root: sudo master-dns-ssl"
  exit 1
fi
if [[ ! -t 0 ]]; then
  fail "An interactive terminal is required."
  exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
  fail "Only Debian / Ubuntu with apt-get is supported."
  exit 1
fi

banner() {
  if [[ -t 1 ]]; then printf '\033[2J\033[H'; fi
  printf '%s%s' "$BOLD" "$CYAN"
  cat <<'ART'
╔══════════════════════════════════════════════════╗
║         MASTER DNS SSL  •  Zero Open Ports        ║
║         Cloudflare DNS-01  |  Auto Renewal        ║
╚══════════════════════════════════════════════════╝
ART
  printf '%s\n' "$RESET"
  say "  Domain may point to your NODE, not this MASTER."
  say "  No inbound 80/443 needed for certificate issuance."
  say ""
}

valid_domain() {
  [[ $# -eq 1 && ${#1} -le 253 && "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}

ask_domain() {
  local answer
  read -r -p "Domain (e.g. panel.example.com): " answer
  DOMAIN=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
  if ! valid_domain "$DOMAIN"; then
    fail "Invalid domain. Enter a hostname without https://, paths, or *."
    return 1
  fi
}

ask_email() {
  read -r -p "Let's Encrypt account email: " EMAIL
  if [[ ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    fail "Invalid email."
    return 1
  fi
}

ensure_cron() {
  # Respect an existing acme.sh root cron job; do not schedule the same home twice.
  if crontab -l 2>/dev/null | grep -Eq 'acme\.sh.*--cron'; then
    if [[ -f "$CRON_FILE" ]]; then rm -f "$CRON_FILE"; fi
    good "Existing root acme.sh cron detected (kept as-is)."
  else
    cat > "$CRON_FILE" <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
23 3 * * * root /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >> /var/log/master-dns-ssl.log 2>&1
CRON
    chmod 644 "$CRON_FILE"
    good "Daily cron installed: 03:23 server time."
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now cron >/dev/null 2>&1 || warn "Could not enable cron service. Check your init system."
  else
    service cron start >/dev/null 2>&1 || warn "Could not start cron service."
  fi
}

ensure_acme() {
  local tmp
  if [[ ! -x "$ACME" ]]; then
    say "Installing prerequisites and acme.sh..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl git cron openssl
    tmp=$(mktemp -d)
    if ! git clone -q --depth 1 https://github.com/acmesh-official/acme.sh.git "$tmp/src"; then
      rm -rf "$tmp"
      fail "Could not download acme.sh."
      return 1
    fi
    if ! "$tmp/src/acme.sh" --install --nocron --home "$ACME_HOME" --accountemail "$EMAIL"; then
      rm -rf "$tmp"
      fail "acme.sh installation failed."
      return 1
    fi
    rm -rf "$tmp"
  else
    # Cron might not exist on machines where acme.sh was installed previously.
    if ! command -v crontab >/dev/null 2>&1; then
      apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cron
    fi
  fi
  "$ACME" --set-default-ca --server letsencrypt
}

choose_reload() {
  say ""
  say "After renewal, how should the app load the updated certificate?"
  say "  1) No reload (certificate files still renew automatically)"
  say "  2) Reload Nginx (systemd)"
  say "  3) Reload Caddy (systemd)"
  say "  4) Restart Docker container named marzban"
  say "  5) Restart marzban systemd service"
  say "  6) Enter my own command (runs as root after each renewal)"
  local opt custom
  read -r -p "Choice [1]: " opt
  case "$opt" in
    ""|1) RELOAD_CMD=":" ;;
    2) RELOAD_CMD="systemctl reload nginx" ;;
    3) RELOAD_CMD="systemctl reload caddy" ;;
    4) RELOAD_CMD="docker restart marzban" ;;
    5) RELOAD_CMD="systemctl restart marzban" ;;
    6)
      read -r -p "Reload command: " custom
      if [[ -z "$custom" || "$custom" == *$'\n'* || "$custom" == *$'\r'* ]]; then
        fail "Invalid reload command."
        return 1
      fi
      RELOAD_CMD="$custom"
      ;;
    *) fail "Invalid choice."; return 1 ;;
  esac
}

issue_cert() {
  banner
  say "╭─ Issue a new certificate ─────────────────────────╮"
  ask_domain || return
  if [[ -f "$CERT_BASE/$DOMAIN/fullchain.pem" ]]; then
    warn "Already installed: $CERT_BASE/$DOMAIN"
    say "Certificate already exists. Use the renew option."
    return
  fi
  ask_email || return

  say ""
  say "How do you want to prove domain ownership?"
  say "  1) Cloudflare auto (one API Token, NO Zone ID) - renews automatically"
  say "  2) Manual DNS TXT (NO API Token) - renew each time manually"
  local mode
  read -r -p "Choose [1/2]: " mode
  if [[ "$mode" != 1 && "$mode" != 2 ]]; then
    fail "Choose 1 or 2."
    return 1
  fi

  local wildcard
  read -r -p "Also include *.$DOMAIN (wildcard)? [Y/n]: " wildcard
  local args=(-d "$DOMAIN")
  if [[ "$wildcard" != [nN] ]]; then
    args+=(-d "*.$DOMAIN")
  fi
  choose_reload || return

  if [[ "$mode" == 1 ]]; then
    say ""
    say "Cloudflare API Token permission: Zone/DNS/Edit and Zone/Zone/Read."
    say "Restrict token scope to the DNS zone containing $DOMAIN."
    read -r -s -p "Cloudflare API Token (hidden): " CF_Token
    printf '\n'
    if [[ -z "$CF_Token" ]]; then
      fail "API Token cannot be empty."
      return 1
    fi
    warn "acme.sh stores DNS credentials in /root/.acme.sh for unattended renewal."
  else
    say ""
    warn "MANUAL TXT: Every renewal needs NEW TXT records. Cron CANNOT renew this certificate automatically."
    say "The next command prints TXT names and values; copy ALL of them to your DNS provider."
    say "If you requested the domain + wildcard, you may need TWO TXT values with the same record name."
  fi

  say "No A/AAAA change and no inbound port opening is needed."
  local confirm
  read -r -p "Continue? [y/N]: " confirm
  [[ "$confirm" == [yY] ]] || { say "Cancelled."; return; }
  ensure_acme || return 1

  if [[ "$mode" == 1 ]]; then
    # Let acme.sh discover Cloudflare Zone ID automatically.
    export CF_Token
    unset CF_Zone_ID CF_Account_ID || true
    if ! "$ACME" --issue --server letsencrypt --dns dns_cf --keylength 2048 "${args[@]}"; then
      unset CF_Token
      fail "Issuance failed. Check Cloudflare permissions and outbound HTTPS/DNS."
      return 1
    fi
    unset CF_Token
  else
    say ""
    say "STEP 1: Generate manual challenge. Save the displayed TXT record(s)."
    say "--------------------------------------------------------------------"
    # Manual --issue normally exits before obtaining a cert; the operator
    # must add the challenge TXT records and then complete with --renew.
    "$ACME" --issue --server letsencrypt --dns --keylength 2048 \
      "${args[@]}" --yes-I-know-dns-manual-mode-enough-go-ahead-please || true
    say "--------------------------------------------------------------------"
    say ""
    warn "Add the displayed TXT records in your authoritative DNS panel."
    say "Wait until they are publicly visible (DNS propagation)."
    say "TXT record name usually starts with _acme-challenge.$DOMAIN."
    local proceed
    read -r -p "I have created ALL TXT records and they have propagated. Verify now? [y/N]: " proceed
    [[ "$proceed" == [yY] ]] || {
      warn "Challenge remains pending. Select menu option 6 to finish once TXT is public."
      return 0
    }
    say "STEP 2: Verify the existing manual DNS challenge."
    if ! "$ACME" --renew --server letsencrypt -d "$DOMAIN" \
      --yes-I-know-dns-manual-mode-enough-go-ahead-please; then
      fail "Validation failed. Check TXT names/values and DNS propagation."
      warn "Use the manual option again to generate fresh challenges if necessary."
      return 1
    fi
  fi

  local out="$CERT_BASE/$DOMAIN"
  install -d -m 700 "$out"
  if ! "$ACME" --install-cert -d "$DOMAIN" --key-file "$out/privkey.pem" \
     --fullchain-file "$out/fullchain.pem" --reloadcmd "$RELOAD_CMD"; then
    fail "Certificate issued but installation failed. Check acme.sh logs."
    return 1
  fi
  chmod 600 "$out/privkey.pem"
  if [[ "$mode" == 1 ]]; then
    ensure_cron
    good "SSL installed with automatic cron renewal! $DOMAIN"
  else
    good "SSL installed! $DOMAIN"
    warn "MANUAL MODE: update DNS TXT and renew manually before expiration."
  fi
  say "  Full chain: $out/fullchain.pem"
  say "  Private key: $out/privkey.pem"
  warn "If clients connect to NODE, configure TLS on the NODE as well."
}

finish_manual() {
  banner
  say "╭─ Complete pending manual TXT challenge ───────────╮"
  ask_domain || return
  if [[ ! -x "$ACME" ]]; then
    fail "acme.sh is not installed. Start by choosing Issue SSL."
    return 1
  fi
  say "All previously displayed _acme-challenge TXT records must be public."
  read -r -p "I have added the TXT record(s). Continue? [y/N]: " proceed
  [[ "$proceed" == [yY] ]] || return 0
  if ! "$ACME" --renew --server letsencrypt -d "$DOMAIN" \
    --yes-I-know-dns-manual-mode-enough-go-ahead-please; then
    fail "DNS verification failed. Verify TXT records and propagation."
    return 1
  fi
  choose_reload || return
  local out="$CERT_BASE/$DOMAIN"
  install -d -m 700 "$out"
  "$ACME" --install-cert -d "$DOMAIN" --key-file "$out/privkey.pem" \
    --fullchain-file "$out/fullchain.pem" --reloadcmd "$RELOAD_CMD" || return 1
  chmod 600 "$out/privkey.pem"
  good "Certificate installed: $DOMAIN"
  warn "Manual TXT certificates do NOT auto-renew; create fresh TXT records at renewal."
}

list_certs() {
  banner
  say "╭─ Managed certificates ────────────────────────────╮"
  local dir found=0
  for dir in "$CERT_BASE"/*; do
    [[ -d "$dir" && -f "$dir/fullchain.pem" ]] || continue
    found=1
    printf '%s%s%s\n' "$GREEN" "${dir##*/}" "$RESET"
    openssl x509 -in "$dir/fullchain.pem" -noout -enddate 2>/dev/null || true
    say "  $dir"
  done
  (( found == 1 )) || warn "No installed certificates found."
}

inspect_cert() {
  banner
  ask_domain || return
  local cert="$CERT_BASE/$DOMAIN/fullchain.pem"
  if [[ ! -f "$cert" ]]; then fail "Certificate not found."; return 1; fi
  openssl x509 -in "$cert" -noout -subject -issuer -dates
  if openssl x509 -checkend 2592000 -noout -in "$cert" >/dev/null; then
    good "Certificate is valid for at least another 30 days."
  else
    warn "Certificate expires within 30 days (or has expired)."
  fi
}

renew_now() {
  banner
  ask_domain || return
  if [[ ! -x "$ACME" || ! -f "$CERT_BASE/$DOMAIN/fullchain.pem" ]]; then
    fail "This domain is not installed."
    return 1
  fi
  warn "Force renewal may trigger Let's Encrypt rate limits. Use only when necessary."
  read -r -p "Force renewal now? [y/N]: " yes
  [[ "$yes" == [yY] ]] || return 0
  "$ACME" --renew -d "$DOMAIN" --server letsencrypt --force
  good "Renewal completed (configured install/reload hook runs on successful renewal)."
}

cron_status() {
  banner
  say "╭─ Auto-renewal status ─────────────────────────────╮"
  if [[ -f "$CRON_FILE" ]]; then
    say "Dedicated cron job:"
    cat "$CRON_FILE"
  else
    say "Root user's crontab:"
    crontab -l 2>/dev/null | grep 'acme.sh.*--cron' || warn "No acme.sh cron found."
  fi
  say ""
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active cron 2>/dev/null || true
  fi
  if [[ -f /var/log/master-dns-ssl.log ]]; then
    say "Recent renewal log:"
    tail -n 12 /var/log/master-dns-ssl.log
  fi
}

main() {
  local choice
  while true; do
    banner
    printf '%s  1%s  Issue SSL (Auto Cloudflare / Manual TXT)\n' "$BLUE" "$RESET"
    printf '%s  2%s  List certificates\n' "$BLUE" "$RESET"
    printf '%s  3%s  View certificate details\n' "$BLUE" "$RESET"
    printf '%s  4%s  Force renew a domain\n' "$BLUE" "$RESET"
    printf '%s  5%s  Show cron & renewal logs\n' "$BLUE" "$RESET"
    printf '%s  6%s  Finish pending manual TXT challenge\n' "$BLUE" "$RESET"
    printf '%s  0%s  Exit\n\n' "$BLUE" "$RESET"
    read -r -p "  Select [0-6]: " choice || exit 0
    case "$choice" in
      1) issue_cert || true; pause ;;
      2) list_certs; pause ;;
      3) inspect_cert || true; pause ;;
      4) renew_now || true; pause ;;
      5) cron_status; pause ;;
      6) finish_manual || true; pause ;;
      0) say "Bye!"; break ;;
      *) warn "Choose a number from 0 to 5."; pause ;;
    esac
  done
}

main "$@"
