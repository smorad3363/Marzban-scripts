#!/usr/bin/env bash
# Master DNS SSL - DNS-01 certificate manager for Debian/Ubuntu
set -Eeuo pipefail
umask 077

ACME_HOME="/root/.acme.sh"
ACME="$ACME_HOME/acme.sh"
CERT_BASE="/var/lib/marzban/certs"
LEGACY_BASE="/etc/ssl/master-dns-ssl"
STATE_DIR="/etc/master-dns-ssl/domains"
SETTINGS_DIR="/etc/master-dns-ssl/settings"
PENDING_FILE="/etc/master-dns-ssl/pending-domain"
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

# Settings are only asked for in the Advanced menu.
load_settings() {
  local v
  DEFAULT_BASE="$CERT_BASE"
  RELOAD_CMD=":"
  ACCOUNT_EMAIL=""
  WILDCARD=1
  if [[ -f "$SETTINGS_DIR/base" ]]; then
    IFS= read -r v < "$SETTINGS_DIR/base" || true
    if [[ "$v" == /* && "$v" != "/" ]]; then DEFAULT_BASE="$v"; fi
  fi
  if [[ -f "$SETTINGS_DIR/reload" ]]; then
    IFS= read -r v < "$SETTINGS_DIR/reload" || true
    if [[ -n "$v" ]]; then RELOAD_CMD="$v"; fi
  fi
  if [[ -f "$SETTINGS_DIR/email" ]]; then
    IFS= read -r ACCOUNT_EMAIL < "$SETTINGS_DIR/email" || true
  fi
  if [[ -f "$SETTINGS_DIR/wildcard" ]]; then
    IFS= read -r v < "$SETTINGS_DIR/wildcard" || true
    [[ "$v" == 0 ]] && WILDCARD=0
  fi
}
save_setting() {
  local file="$1" value="$2"
  install -d -m 700 "$SETTINGS_DIR"
  printf '%s\n' "$value" > "$SETTINGS_DIR/$file"
  chmod 600 "$SETTINGS_DIR/$file"
}
valid_dir() {
  local p="$1"
  [[ "$p" == /* && "$p" != "/" && "$p" != */../* &&
     "$p" != */./* && "$p" != */.. && "$p" != */. &&
     "$p" != *$'\n'* && "$p" != *$'\r'* ]]
}
show_settings() {
  load_settings
  say "  Default cert parent: $DEFAULT_BASE"
  say "  Wildcard: $( ((WILDCARD)) && printf 'yes' || printf 'no')"
  say "  Reload command: $RELOAD_CMD"
  say "  Account email: ${ACCOUNT_EMAIL:-not set (optional)}"
}
settings_menu() {
  local opt value
  while true; do
    banner
    say "╭─ Advanced settings (optional) ────────────────────╮"
    show_settings
    say ""
    say "  1) Default certificate parent directory"
    say "  2) Default post-renew reload action"
    say "  3) Optional ACME account email (real email recommended)"
    say "  4) Toggle root + wildcard vs root only"
    say "  0) Back"
    read -r -p "Choice [0-4]: " opt || return 0
    case "$opt" in
      1)
        read -r -p "Parent directory [$DEFAULT_BASE]: " value
        if [[ -n "$value" ]]; then
          if valid_dir "$value"; then
            save_setting base "${value%/}"
            good "Default parent saved. Domain subdirectory is created automatically."
          else
            fail "Enter a valid absolute directory."
          fi
        fi
        pause ;;
      2)
        choose_reload || { pause; continue; }
        save_setting reload "$RELOAD_CMD"
        good "Saved for future certificate installs."
        pause ;;
      3)
        read -r -p "Real email, or blank to disable: " value
        if [[ -z "$value" || "$value" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
          save_setting email "$value"
          good "Email setting saved (used when acme.sh is newly installed)."
        else
          fail "Invalid email."
        fi
        pause ;;
      4)
        if (( WILDCARD )); then save_setting wildcard 0; else save_setting wildcard 1; fi
        good "Wildcard selection updated."
        pause ;;
      0) return 0 ;;
      *) warn "Choose 0-4."; pause ;;
    esac
  done
}

cert_dir_for_domain() {
  local saved=""
  if [[ -f "$STATE_DIR/$DOMAIN.path" ]]; then
    IFS= read -r saved < "$STATE_DIR/$DOMAIN.path" || true
    if [[ "$saved" == /* && "$saved" != "/" ]]; then
      printf '%s\n' "$saved"
      return
    fi
  fi
  # Backward compatible with installations from previous versions.
  if [[ -f "$LEGACY_BASE/$DOMAIN/fullchain.pem" ]]; then
    printf '%s\n' "$LEGACY_BASE/$DOMAIN"
  else
    printf '%s\n' "$DEFAULT_BASE/$DOMAIN"
  fi
}

cert_mode_for_domain() {
  if [[ -f "$STATE_DIR/$DOMAIN.mode" ]]; then
    head -n 1 "$STATE_DIR/$DOMAIN.mode"
  elif [[ -f "$LEGACY_BASE/$DOMAIN/.mode" ]]; then
    head -n 1 "$LEGACY_BASE/$DOMAIN/.mode"
  else
    printf 'unknown\n'
  fi
}

ask_cert_path() {
  local suggested="${1:-$DEFAULT_BASE/$DOMAIN}" entered
  say ""
  say "Where should fullchain.pem and key.pem be saved?"
  read -r -p "Certificate directory [$suggested]: " entered
  CERT_DIR="${entered:-$suggested}"
  CERT_DIR="${CERT_DIR%/}"
  if [[ "$CERT_DIR" != /* || "$CERT_DIR" == "" ||
        "$CERT_DIR" == *$'\n'* || "$CERT_DIR" == *$'\r'* ||
        "$CERT_DIR" == *"/../"* || "$CERT_DIR" == *"/./"* ||
        "$CERT_DIR" == *"/.." || "$CERT_DIR" == *"/." ||
        "$CERT_DIR" == "/" ]]; then
    fail "Enter a valid absolute directory path."
    return 1
  fi
  say "  Cert: $CERT_DIR/fullchain.pem"
  say "  Key:  $CERT_DIR/key.pem"
}

check_destination() {
  local previous="${1:-}"
  if [[ "$CERT_DIR" == "$previous" ]]; then return 0; fi
  if [[ -e "$CERT_DIR/fullchain.pem" || -e "$CERT_DIR/key.pem" ||
        -L "$CERT_DIR/fullchain.pem" || -L "$CERT_DIR/key.pem" ]]; then
    fail "Files already exist there. Choose another directory to avoid overwriting."
    return 1
  fi
}

show_cert_paths() {
  local dir="$1" key="$1/key.pem"
  # Files from earlier versions used privkey.pem instead of key.pem.
  if [[ ! -f "$key" && -f "$dir/privkey.pem" ]]; then
    key="$dir/privkey.pem"
  fi
  say ""
  printf '%sCertificate file (fullchain):%s %s\n' "$GREEN" "$RESET" "$dir/fullchain.pem"
  printf '%sPrivate key file:%s %s\n' "$GREEN" "$RESET" "$key"
  say "Use these paths in the certificateFile and keyFile fields for VLESS TCP TLS."
}

install_cert_files() {
  local cert_mode="$1" out="$CERT_DIR"
  install -d -m 700 "$out"
  # acme.sh persists install locations and reload hook for future renewals.
  if ! "$ACME" --install-cert -d "$DOMAIN" --key-file "$out/key.pem" \
    --fullchain-file "$out/fullchain.pem" --reloadcmd "$RELOAD_CMD"; then
    fail "Failed to install certificate into $out. Check acme.sh logs."
    return 1
  fi
  chmod 600 "$out/key.pem"
  chmod 644 "$out/fullchain.pem"
  install -d -m 700 "$STATE_DIR"
  printf '%s\n' "$out" > "$STATE_DIR/$DOMAIN.path"
  printf '%s\n' "$cert_mode" > "$STATE_DIR/$DOMAIN.mode"
  chmod 600 "$STATE_DIR/$DOMAIN.path" "$STATE_DIR/$DOMAIN.mode"
  good "Certificate saved."
  show_cert_paths "$out"
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
    local install_opts=(--install --nocron --home "$ACME_HOME")
    if [[ -n "$ACCOUNT_EMAIL" ]]; then install_opts+=(--accountemail "$ACCOUNT_EMAIL"); fi
    if ! "$tmp/src/acme.sh" "${install_opts[@]}"; then
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
  local manual_reissue=0 existing
  existing="$(cert_dir_for_domain)"
  if [[ -f "$existing/fullchain.pem" ]]; then
    if [[ "$(cert_mode_for_domain)" == manual ]]; then
      warn "This domain uses MANUAL TXT. New TXT records are required to renew."
      read -r -p "Start manual renewal with fresh TXT values? [y/N]: " yes
      [[ "$yes" == [yY] ]] || return 0
      manual_reissue=1
    else
      warn "Already installed: $existing"
      say "Use option 4 to renew, or option 7 to change certificate paths."
      return
    fi
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
  if (( manual_reissue == 1 )) && [[ "$mode" != 2 ]]; then
    fail "This is a manual TXT renewal. Choose option 2."
    return 1
  fi

  local wildcard
  read -r -p "Also include *.$DOMAIN (wildcard)? [Y/n]: " wildcard
  local args=(-d "$DOMAIN")
  if [[ "$wildcard" != [nN] ]]; then
    args+=(-d "*.$DOMAIN")
  fi
  ask_cert_path "$existing" || return
  check_destination "$existing" || return
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
    local force_issue=()
    if (( manual_reissue == 1 )); then force_issue=(--force); fi
    "$ACME" --issue --server letsencrypt --dns --keylength 2048 \
      "${args[@]}" "${force_issue[@]}" \
      --yes-I-know-dns-manual-mode-enough-go-ahead-please || true
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
    local force_renew=()
    if (( manual_reissue == 1 )); then force_renew=(--force); fi
    if ! "$ACME" --renew --server letsencrypt -d "$DOMAIN" \
      "${force_renew[@]}" --yes-I-know-dns-manual-mode-enough-go-ahead-please; then
      fail "Validation failed. Check TXT names/values and DNS propagation."
      warn "Use the manual option again to generate fresh challenges if necessary."
      return 1
    fi
  fi

  if [[ "$mode" == 1 ]]; then
    install_cert_files auto || return 1
    ensure_cron
    good "Automatic DNS API renewal enabled for $DOMAIN"
  else
    install_cert_files manual || return 1
    warn "MANUAL TXT: fresh TXT values are needed before each renewal."
  fi
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
  local force_pending=()
  if [[ "$(cert_mode_for_domain)" == manual ]]; then
    force_pending=(--force)
  fi
  if ! "$ACME" --renew --server letsencrypt -d "$DOMAIN" \
    "${force_pending[@]}" --yes-I-know-dns-manual-mode-enough-go-ahead-please; then
    fail "DNS verification failed. Verify TXT records and propagation."
    return 1
  fi
  local previous
  previous="$(cert_dir_for_domain)"
  ask_cert_path "$previous" || return
  check_destination "$previous" || return
  choose_reload || return
  install_cert_files manual || return 1
  good "Manual TXT certificate installed for $DOMAIN"
  warn "Manual TXT certificates do NOT auto-renew; create fresh TXT records at renewal."
}

list_certs() {
  banner
  say "╭─ Managed certificates ────────────────────────────╮"
  local dom dir marker found=0
  local -A seen=()
  for marker in "$STATE_DIR"/*.path; do
    [[ -f "$marker" ]] || continue
    dom="${marker##*/}"; dom="${dom%.path}"
    valid_domain "$dom" || continue
    DOMAIN="$dom"
    dir="$(cert_dir_for_domain)"
    if [[ -f "$dir/fullchain.pem" ]]; then
      seen["$dom"]=1; found=1
      printf '\n%s%s%s\n' "$GREEN" "$dom" "$RESET"
      openssl x509 -in "$dir/fullchain.pem" -noout -enddate 2>/dev/null || true
      show_cert_paths "$dir"
    fi
  done
  for dir in "$CERT_BASE"/* "$LEGACY_BASE"/*; do
    [[ -f "$dir/fullchain.pem" ]] || continue
    dom="${dir##*/}"
    [[ -n "${seen[$dom]:-}" ]] && continue
    seen["$dom"]=1; found=1
    printf '\n%s%s%s\n' "$GREEN" "$dom" "$RESET"
    openssl x509 -in "$dir/fullchain.pem" -noout -enddate 2>/dev/null || true
    show_cert_paths "$dir"
  done
  (( found == 1 )) || warn "No installed certificates found."
}

inspect_cert() {
  banner
  ask_domain || return
  local dir cert
  dir="$(cert_dir_for_domain)"
  cert="$dir/fullchain.pem"
  if [[ ! -f "$cert" ]]; then fail "Certificate not found."; return 1; fi
  openssl x509 -in "$cert" -noout -subject -issuer -dates
  if openssl x509 -checkend 2592000 -noout -in "$cert" >/dev/null; then
    good "Certificate is valid for at least another 30 days."
  else
    warn "Certificate expires within 30 days (or has expired)."
  fi
  show_cert_paths "$dir"
}

change_cert_path() {
  banner
  say "╭─ Set or change certificate storage path ──────────╮"
  ask_domain || return
  local previous mode
  previous="$(cert_dir_for_domain)"
  if [[ ! -f "$previous/fullchain.pem" || ! -x "$ACME" ]]; then
    fail "No installed certificate for this domain."
    return 1
  fi
  mode="$(cert_mode_for_domain)"
  say "Currently installed: $previous"
  ask_cert_path "$CERT_BASE/$DOMAIN" || return
  check_destination "$previous" || return
  choose_reload || return
  install_cert_files "$mode" || return 1
  if [[ "$mode" == auto ]]; then ensure_cron; fi
  say "Old files at $previous were left untouched. Remove them manually if unused."
}

renew_now() {
  banner
  ask_domain || return
  if [[ ! -x "$ACME" || ! -f "$(cert_dir_for_domain)/fullchain.pem" ]]; then
    fail "This domain is not installed."
    return 1
  fi
  if [[ "$(cert_mode_for_domain)" == manual ]]; then
    warn "Manual TXT cannot renew without new TXT values. Choose menu option 1, then manual TXT."
    return 0
  fi
  warn "Force renewal may trigger Let's Encrypt rate limits. Use only when necessary."
  read -r -p "Force renewal now? [y/N]: " yes
  [[ "$yes" == [yY] ]] || return 0
  "$ACME" --renew -d "$DOMAIN" --server letsencrypt --force || return 1
  good "Renewal completed (configured install/reload hook runs on successful renewal)."
  show_cert_paths "$(cert_dir_for_domain)"
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
    printf '%s  7%s  Change certificate save directory\n' "$BLUE" "$RESET"
    printf '%s  0%s  Exit\n\n' "$BLUE" "$RESET"
    read -r -p "  Select [0-7]: " choice || exit 0
    case "$choice" in
      1) issue_cert || true; pause ;;
      2) list_certs; pause ;;
      3) inspect_cert || true; pause ;;
      4) renew_now || true; pause ;;
      5) cron_status; pause ;;
      6) finish_manual || true; pause ;;
      7) change_cert_path || true; pause ;;
      0) say "Bye!"; break ;;
      *) warn "Choose a number from 0 to 7."; pause ;;
    esac
  done
}

main "$@"
