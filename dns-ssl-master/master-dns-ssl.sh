#!/usr/bin/env bash
# Master DNS SSL - DNS-01 certificate manager for Debian/Ubuntu
set -Eeuo pipefail
umask 077

MASTER_DNS_SSL_VERSION="2026.10.08-ux5"
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
  say "  Version: $MASTER_DNS_SSL_VERSION"
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
    if [[ "$v" == 0 ]]; then WILDCARD=0; fi
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
  # Legacy certificates may have used privkey.pem.
  if [[ ! -f "$key" && -f "$dir/privkey.pem" ]]; then
    key="$dir/privkey.pem"
  fi
  say ""
  printf '%s\n' "============================================================"
  say "  SSL CERTIFICATE PATHS  --  COPY ONE FULL LINE AT A TIME"
  printf '%s\n' "============================================================"
  say "CERTIFICATE FILE (certificateFile):"
  printf '%s\n' "$dir/fullchain.pem"
  say ""
  say "PRIVATE KEY FILE (keyFile):"
  printf '%s\n' "$key"
  printf '%s\n' "============================================================"
  if [[ -s "$dir/fullchain.pem" ]]; then
    show_expiry "$dir/fullchain.pem" || true
  fi
}

# Show expiry from the fullchain file installed for the user's service.
show_expiry() {
  local cert="$1" end_label end_epoch now_epoch days_left
  [[ -s "$cert" ]] || { warn "Missing certificate: $cert"; return 1; }
  end_label="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null)" ||
    { fail "Cannot read expiration date: $cert"; return 1; }
  end_label="${end_label#notAfter=}"
  say ""
  say "CERTIFICATE EXPIRES (UTC):"
  printf '%s\n' "$end_label"
  if end_epoch="$(date -u -d "$end_label" +%s 2>/dev/null)"; then
    now_epoch="$(date -u +%s)"
    days_left=$(( (end_epoch - now_epoch) / 86400 ))
    if (( days_left < 0 )); then
      warn "CERTIFICATE EXPIRED: $((-days_left)) days ago"
    else
      printf 'DAYS REMAINING: %s\n' "$days_left"
    fi
  fi
}

# A no-TXT successful ACME response is only accepted when a valid newly
# issued certificate covers both the apex and wildcard if requested.
cert_is_current() {
  local cert="$1" name="$2" want_wildcard="$3" parsed
  [[ -s "$cert" ]] || return 1
  openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1 || return 1
  parsed="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null |
    tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" || return 1
  grep -Fxq "DNS:$name" <<< "$parsed" || return 1
  if (( want_wildcard )); then
    grep -Fxq "DNS:*.$name" <<< "$parsed" || return 1
  fi
  return 0
}
manual_issue_completed() {
  local rc="$1" logfile="$2" cert="$3" domain="$4" wildcard="$5"
  (( rc == 0 )) || return 1
  grep -Fq 'Cert success.' "$logfile" || return 1
  cert_is_current "$cert" "$domain" "$wildcard"
}

# Print clean, copy-ready records from acme.sh manual mode.
# Each saved record is a tab-separated FQDN and TXT value.
show_txt_records() {
  local records="$1" fqdn value count=0
  if [[ ! -s "$records" ]]; then
    warn "No TXT records saved to display."
    return 1
  fi
  say ""
  printf '%s\n' "============================================================"
  say "   DNS TXT RECORDS FOR $DOMAIN  --  COPY THE VALUES BELOW"
  printf '%s\n' "============================================================"
  while IFS=$'\t' read -r fqdn value; do
    [[ -n "$fqdn" && -n "$value" ]] || continue
    count=$((count+1))
    printf '\n%s\n' "------------------ TXT RECORD $count ------------------"
    say "TYPE:"
    say "TXT"
    say "NAME (FULL DNS NAME):"
    printf '%s\n' "$fqdn"
    if [[ "$fqdn" == "_acme-challenge.$DOMAIN" ]]; then
      say "CLOUDFLARE NAME (only if the DNS zone itself is $DOMAIN):"
      say "_acme-challenge"
    fi
    say "CONTENT / TXT VALUE (copy the next line exactly):"
    printf '%s\n' "$value"
  done < "$records"
  printf '\n%s\n' "============================================================"
  if (( count > 1 )); then
    say "IMPORTANT: Add ALL $count TXT values, even when the NAME is identical."
  fi
  say "Cloudflare: DNS > Records > Add record > TXT; TTL: Auto."
  say "Do not alter the current A/AAAA records."
  return 0
}

# Extract TXT values from ACME output without timestamps/repetitive prose.
extract_txt_records() {
  local logfile="$1" out="$2" n v i
  local -a names=() values=()
  mapfile -t names < <(sed -n "s/.*Domain: '\\([^']*\\)'.*/\\1/p" "$logfile")
  mapfile -t values < <(sed -n "s/.*TXT value: '\\([^']*\\)'.*/\\1/p" "$logfile")
  if (( ${#names[@]} == 0 || ${#names[@]} != ${#values[@]} )); then
    return 1
  fi
  : > "$out"
  chmod 600 "$out"
  for ((i=0; i<${#names[@]}; i++)); do
    n="${names[i]}" v="${values[i]}"
    if [[ ! "$n" =~ ^_acme-challenge\.[a-zA-Z0-9.-]+$ ||
          ! "$v" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      rm -f "$out"
      return 1
    fi
    printf '%s\t%s\n' "$n" "$v" >> "$out"
  done
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
    # Avoid upstream --install, which copies ./acme.sh relative to its own CWD
    # and has failed on some systems. Install from verified ABSOLUTE paths.
    if [[ ! -s "$tmp/src/acme.sh" || ! -f "$tmp/src/dnsapi/dns_cf.sh" ]]; then
      rm -rf "$tmp"
      fail "Incomplete acme.sh download (missing script or Cloudflare DNS API)."
      return 1
    fi
    if ! (install -d -m 700 "$ACME_HOME" &&
          install -m 755 "$tmp/src/acme.sh" "$ACME" &&
          cp -a "$tmp/src/dnsapi" "$ACME_HOME/" &&
          cp -a "$tmp/src/deploy" "$ACME_HOME/" &&
          cp -a "$tmp/src/notify" "$ACME_HOME/"); then
      rm -rf "$tmp"
      fail "Unable to copy acme.sh files into $ACME_HOME."
      return 1
    fi
    rm -rf "$tmp"
    if [[ ! -x "$ACME" ]]; then
      fail "acme.sh installation incomplete: $ACME is not executable."
      return 1
    fi
    # Preserve existing account details when recovering a partial install.
    # Account email is optional; a fake/random address must not be generated.
    if [[ -n "$ACCOUNT_EMAIL" ]]; then
      "$ACME" --register-account --server letsencrypt -m "$ACCOUNT_EMAIL" ||
        warn "Account email registration failed; continuing to CA setup."
    fi
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

# Issue without redundant questions: only domain, and TXT verification when manual.
issue_cert() {
  local mode="$1" existing manual_reissue=0
  load_settings
  banner
  if [[ "$mode" == manual ]]; then
    say "╭─ Manual TXT SSL: root + wildcard ─────────────────╮"
  else
    say "╭─ Cloudflare automatic SSL: root + wildcard ───────╮"
  fi
  ask_domain || return
  existing="$(cert_dir_for_domain)"
  CERT_DIR="$existing"

  if [[ -f "$existing/fullchain.pem" ]]; then
    if [[ "$mode" == manual && "$(cert_mode_for_domain)" == manual ]]; then
      # Do not unnecessarily reissue (or reuse ACME auth) for a currently
      # valid certificate; repeated issuance can hit rate limits.
      if cert_is_current "$existing/fullchain.pem" "$DOMAIN" "$WILDCARD" &&
         openssl x509 -in "$existing/fullchain.pem" -noout -checkend 2592000 >/dev/null 2>&1; then
        good "Certificate is already installed and valid for at least 30 days."
        show_cert_paths "$existing"
        say "No new DNS TXT values are needed now."
        return 0
      fi
      manual_reissue=1
      warn "Certificate expires soon or needs replacing. New TXT records may be required."
    else
      warn "Certificate already exists at $existing"
      show_cert_paths "$existing"
      return 0
    fi
  fi

  local args=(-d "$DOMAIN")
  if (( WILDCARD )); then args+=(-d "*.$DOMAIN"); fi
  say "  Domains: $DOMAIN$( ((WILDCARD)) && printf ', *.%s' "$DOMAIN" || true)"
  say "  Save directory: $CERT_DIR"
  say "  No incoming ports or DNS A/AAAA changes required."
  ensure_acme || return 1

  if [[ "$mode" == auto ]]; then
    local reused_token=0
    if [[ -f "$ACME_HOME/account.conf" ]] &&
       grep -q '^SAVED_CF_Token=' "$ACME_HOME/account.conf"; then
      good "Reusing Cloudflare API Token stored by acme.sh."
      reused_token=1
    else
      say "Cloudflare token: Zone/DNS/Edit + Zone/Zone/Read for this zone."
      read -r -s -p "Cloudflare API Token: " CF_Token
      printf '\n'
      if [[ -z "$CF_Token" ]]; then fail "API Token required."; return 1; fi
      export CF_Token
    fi
    unset CF_Zone_ID CF_Account_ID || true
    if ! "$ACME" --issue --server letsencrypt --dns dns_cf --keylength 2048 "${args[@]}"; then
      unset CF_Token || true
      fail "Issuance failed. Check DNS permissions and outward HTTPS access."
      if (( reused_token )); then
        warn "To use a different Cloudflare zone token, rerun with a token after clearing the old acme.sh token."
      fi
      return 1
    fi
    unset CF_Token || true
    install_cert_files auto || return 1
    ensure_cron
    good "Automatic renewal enabled. Files will stay at the same paths."
    if [[ "$RELOAD_CMD" == ":" ]]; then
      warn "Reload is set to none. Set a reload hook in Advanced Settings if your service needs one."
    fi
    return 0
  fi

  say ""
  say "Preparing DNS-01 TXT values for $DOMAIN ..."
  local log rc=0 records
  log="$(mktemp)"
  local force_issue=()
  if (( manual_reissue )); then force_issue=(--force); fi
  "$ACME" --issue --server letsencrypt --dns --keylength 2048 \
    "${args[@]}" "${force_issue[@]}" \
    --yes-I-know-dns-manual-mode-enough-go-ahead-please > "$log" 2>&1 || rc=$?
  install -d -m 700 "$STATE_DIR"
  records="$STATE_DIR/$DOMAIN.txt-records"
  # Reuse of a still-valid ACME authorization can allow the CA to
  # sign immediately, without requiring any new DNS TXT challenges.
  if manual_issue_completed "$rc" "$log" "$ACME_HOME/$DOMAIN/fullchain.cer" "$DOMAIN" "$WILDCARD"; then
    rm -f "$log"
    good "Certificate issued directly using existing ACME authorization: no TXT needed."
    install_cert_files manual || return 1
    if [[ -f "$PENDING_FILE" ]]; then
      local pending
      IFS= read -r pending < "$PENDING_FILE" || true
      if [[ "$pending" == "$DOMAIN" ]]; then
        rm -f "$PENDING_FILE" "$STATE_DIR/$DOMAIN.txt-records"
      fi
    fi
    warn "Future manual renewals can require new TXT values; DNS API is needed for unattended renewals."
    return 0
  fi
  if ! extract_txt_records "$log" "$records"; then
    tail -n 32 "$log"
    rm -f "$log"
    fail "No TXT records and no newly issued certificate were confirmed."
    return 1
  fi
  rm -f "$log"
  printf '%s\n' "$DOMAIN" > "$PENDING_FILE"
  chmod 600 "$PENDING_FILE"
  show_txt_records "$records" || return 1
  say ""
  warn "Wait until ALL TXT values are publicly visible. Do not verify too early."
  local ready
  read -r -p "Press ENTER to verify or q to finish later: " ready
  if [[ "$ready" == [qQ] ]]; then
    say "Saved TXT values for $DOMAIN. Menu option 6 can show them again."
    return 0
  fi
  complete_manual
}

complete_manual() {
  load_settings
  if [[ -f "$PENDING_FILE" ]]; then
    IFS= read -r DOMAIN < "$PENDING_FILE" || true
    valid_domain "$DOMAIN" || { fail "Invalid pending domain file."; return 1; }
  else
    warn "No saved pending domain from the current version."
    ask_domain || return 1
  fi

  if [[ ! -x "$ACME" ]]; then
    fail "acme.sh is not installed."
    return 1
  fi
  say "Verifying DNS TXT records for $DOMAIN ..."
  local force_pending=() verify_log
  if [[ "$(cert_mode_for_domain)" == manual ]]; then force_pending=(--force); fi
  verify_log="$(mktemp)"
  if ! "$ACME" --renew --server letsencrypt -d "$DOMAIN" \
    "${force_pending[@]}" --yes-I-know-dns-manual-mode-enough-go-ahead-please \
    > "$verify_log" 2>&1; then
    tail -n 35 "$verify_log"
    rm -f "$verify_log"
    fail "Validation failed. Check TXT values and propagation."
    say "Menu option 6 displays the SAME pending TXT values without reissuing."
    return 1
  fi
  rm -f "$verify_log"
  good "Let's Encrypt issued your certificate successfully."

  CERT_DIR="$(cert_dir_for_domain)"
  install_cert_files manual || return 1
  if [[ -f "$PENDING_FILE" ]]; then
    local pending
    IFS= read -r pending < "$PENDING_FILE" || true
    if [[ "$pending" == "$DOMAIN" ]]; then
      rm -f "$PENDING_FILE" "$STATE_DIR/$DOMAIN.txt-records"
    fi
  fi
  warn "Manual DNS certificates require NEW TXT records for every renewal."
  return 0
}

finish_manual() {
  banner
  say "╭─ Finish pending TXT verification ────────────────╮"
  if [[ -f "$PENDING_FILE" ]]; then
    local pending ready
    IFS= read -r pending < "$PENDING_FILE" || true
    if ! valid_domain "$pending"; then fail "Invalid pending domain."; return 1; fi
    DOMAIN="$pending"
    say "Pending domain: $DOMAIN"
    if [[ -f "$STATE_DIR/$DOMAIN.txt-records" ]]; then
      show_txt_records "$STATE_DIR/$DOMAIN.txt-records" || return 1
    fi
    say ""
    read -r -p "Press ENTER to verify, or q to return to menu: " ready
    [[ "$ready" == [qQ] ]] && return 0
  fi
  complete_manual
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
      show_cert_paths "$dir"
    fi
  done
  for dir in "$CERT_BASE"/* "$LEGACY_BASE"/*; do
    [[ -f "$dir/fullchain.pem" ]] || continue
    dom="${dir##*/}"
    [[ -n "${seen[$dom]:-}" ]] && continue
    seen["$dom"]=1; found=1
    printf '\n%s%s%s\n' "$GREEN" "$dom" "$RESET"
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
  load_settings
  while true; do
    banner
    printf '%s  1%s  Manual TXT SSL (root + wildcard) [simple]\n' "$BLUE" "$RESET"
    printf '%s  2%s  Cloudflare SSL + auto-renewal\n' "$BLUE" "$RESET"
    printf '%s  3%s  List certificates and file paths\n' "$BLUE" "$RESET"
    printf '%s  4%s  Certificate details\n' "$BLUE" "$RESET"
    printf '%s  5%s  Force renew an API certificate\n' "$BLUE" "$RESET"
    printf '%s  6%s  Finish pending manual TXT verification\n' "$BLUE" "$RESET"
    printf '%s  7%s  Show cron and renewal logs\n' "$BLUE" "$RESET"
    printf '%s  8%s  Advanced settings (paths / reload / email)\n' "$BLUE" "$RESET"
    printf '%s  9%s  Change an existing certificate directory\n' "$BLUE" "$RESET"
    printf '%s  0%s  Exit\n\n' "$BLUE" "$RESET"
    read -r -p "  Select [0-9]: " choice || exit 0
    case "$choice" in
      1) issue_cert manual || true; pause ;;
      2) issue_cert auto || true; pause ;;
      3) list_certs || true; pause ;;
      4) inspect_cert || true; pause ;;
      5) renew_now || true; pause ;;
      6) finish_manual || true; pause ;;
      7) cron_status || true; pause ;;
      8) settings_menu || true ;;
      9) load_settings; change_cert_path || true; pause ;;
      0) say "Bye!"; break ;;
      *) warn "Choose a number from 0 to 9."; pause ;;
    esac
  done
}

main "$@"
