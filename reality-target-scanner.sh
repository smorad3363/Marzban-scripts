#!/usr/bin/env bash
set -uo pipefail

# Strict REALITY target scanner for Marzban/Xray in Docker.
# Interactive launches detach with nohup so scans survive SSH disconnects.
# Worker mode randomly samples public domains and stops after the requested
# number of targets pass REALITY-oriented TLS, PQ, certificate-size and
# stability checks.

BASE_DIR="${BASE_DIR:-/root/reality-scans}"
GLOBAL_PID_FILE="${GLOBAL_PID_FILE:-/run/reality-scan.pid}"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

show_status() {
    local latest="$BASE_DIR/latest" pid=""
    if [ -f "$GLOBAL_PID_FILE" ]; then
        pid="$(cat "$GLOBAL_PID_FILE" 2>/dev/null || true)"
    fi
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "RUNNING pid=$pid"
    else
        echo "NOT RUNNING"
    fi
    if [ -L "$latest" ] || [ -d "$latest" ]; then
        echo "Latest run : $(readlink -f "$latest" 2>/dev/null || echo "$latest")"
        [ -f "$latest/reality-scan.log" ] && echo "Log        : $latest/reality-scan.log"
        [ -f "$latest/reality-healthy.txt" ] && echo "Healthy    : $latest/reality-healthy.txt"
    fi
}

case "${1:-}" in
    status)
        show_status
        exit 0
        ;;
    log|logs)
        if [ -f "$BASE_DIR/latest/reality-scan.log" ]; then
            tail -f "$BASE_DIR/latest/reality-scan.log"
        else
            echo "No scan log found yet."
            exit 1
        fi
        ;;
    results|result)
        if [ -f "$BASE_DIR/latest/reality-healthy.txt" ]; then
            cat "$BASE_DIR/latest/reality-healthy.txt"
        else
            echo "No healthy-target file found yet."
            exit 1
        fi
        ;;
    stop)
        if [ -f "$GLOBAL_PID_FILE" ]; then
            pid="$(cat "$GLOBAL_PID_FILE" 2>/dev/null || true)"
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid"
                echo "Stop signal sent to scan pid=$pid"
                exit 0
            fi
        fi
        echo "No running scan found."
        exit 0
        ;;
esac

# Interactive launcher. Ask how many healthy targets are wanted, then launch
# the real worker detached from the SSH session.
if [ "${REALITY_SCAN_WORKER:-0}" != "1" ]; then
    mkdir -p "$BASE_DIR"

    if [ -f "$GLOBAL_PID_FILE" ]; then
        old_pid="$(cat "$GLOBAL_PID_FILE" 2>/dev/null || true)"
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            echo "[!] A scan is already running (pid=$old_pid)."
            show_status
            echo "Use: reality-scan logs"
            exit 1
        fi
        rm -f "$GLOBAL_PID_FILE"
    fi

    default_needed="${NEEDED:-50}"
    if [ -n "${1:-}" ] && [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; then
        wanted="$1"
    elif [ -t 0 ]; then
        while true; do
            printf 'How many healthy REALITY targets do you want? [%s]: ' "$default_needed"
            IFS= read -r wanted
            wanted="${wanted:-$default_needed}"
            if [[ "$wanted" =~ ^[1-9][0-9]*$ ]]; then
                break
            fi
            echo "Please enter a positive integer."
        done
    else
        wanted="$default_needed"
    fi

    run_id="$(date +%Y%m%d-%H%M%S)"
    run_dir="$BASE_DIR/$run_id"
    mkdir -p "$run_dir"
    ln -sfn "$run_dir" "$BASE_DIR/latest"

    log_file="$run_dir/reality-scan.log"
    healthy_file="$run_dir/reality-healthy.txt"
    report_file="$run_dir/reality-scan-report.txt"

    nohup env \
        REALITY_SCAN_WORKER=1 \
        NEEDED="$wanted" \
        OUT_DIR="$run_dir" \
        BASE_DIR="$BASE_DIR" \
        GLOBAL_PID_FILE="$GLOBAL_PID_FILE" \
        bash "$SCRIPT_PATH" \
        >"$log_file" 2>&1 </dev/null &

    worker_pid=$!
    printf '%s\n' "$worker_pid" > "$GLOBAL_PID_FILE"
    printf '%s\n' "$worker_pid" > "$run_dir/reality-scan.pid"

    echo
    echo "[+] Scan started in background."
    echo "    Requested : $wanted healthy targets"
    echo "    PID       : $worker_pid"
    echo "    Run dir   : $run_dir"
    echo "    Log       : $log_file"
    echo "    Results   : $healthy_file"
    echo "    Report    : $report_file"
    echo
    echo "SSH can be disconnected; the scan will keep running."
    echo "Check status : reality-scan status"
    echo "Watch log    : reality-scan logs"
    echo "Show results : reality-scan results"
    exit 0
fi

NEEDED="${NEEDED:-50}"
POOL_SIZE="${POOL_SIZE:-1000000}"
BATCH_SIZE="${BATCH_SIZE:-500}"
WORKERS="${WORKERS:-8}"
STABILITY_TESTS="${STABILITY_TESTS:-3}"
MAX_MEDIAN_MS="${MAX_MEDIAN_MS:-1000}"
MIN_CERT_LENGTH="${MIN_CERT_LENGTH:-3500}"
REQUIRE_PQ="${REQUIRE_PQ:-1}"
EXCLUDE_CLOUDFLARE="${EXCLUDE_CLOUDFLARE:-1}"
EXCLUDE_FASTLY="${EXCLUDE_FASTLY:-1}"
MIN_XRAY_VERSION="${MIN_XRAY_VERSION:-25.7.26}"
MAX_CANDIDATES="${MAX_CANDIDATES:-1000000}"

OUT_DIR="${OUT_DIR:-/root/reality-scans/manual-$(date +%Y%m%d-%H%M%S)}"
OUT="$OUT_DIR/reality-scan-report.txt"
HEALTHY="$OUT_DIR/reality-healthy.txt"

WORK="$(mktemp -d)"
ZIP="$WORK/tranco.zip"
RAW="$WORK/tranco.csv"
CANDS="$WORK/candidates.txt"
GOOD_RAW="$WORK/good.raw"
LOCK="$WORK/lock"

mkdir -p "$OUT_DIR"
: > "$OUT"
: > "$HEALTHY"
: > "$GOOD_RAW"

cleanup() {
    rm -rf "$WORK"
    if [ -f "$GLOBAL_PID_FILE" ]; then
        current="$(cat "$GLOBAL_PID_FILE" 2>/dev/null || true)"
        [ "$current" = "$$" ] && rm -f "$GLOBAL_PID_FILE"
    fi
}
trap cleanup EXIT INT TERM

log() { printf '%s\n' "$*"; }

version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

install_deps_if_needed() {
    local missing=()
    local c
    for c in docker curl unzip awk grep shuf dig openssl timeout getent sort sed flock; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if ((${#missing[@]} == 0)); then return 0; fi

    log "[!] Missing commands: ${missing[*]}"
    if [ "$(id -u)" -eq 0 ] && command -v apt-get >/dev/null 2>&1; then
        log "[+] Installing dependencies..."
        apt-get update -qq || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            docker.io curl unzip dnsutils openssl coreutils util-linux >/dev/null || return 1
    else
        log "[!] Install dependencies manually (Debian/Ubuntu):"
        log "    apt update && apt install -y docker.io curl unzip dnsutils openssl coreutils util-linux"
        return 1
    fi
}

find_xray_container() {
    local rows cid name image path line ver best_ver="" best_cid="" best_name="" best_image="" best_path=""
    rows="$(docker ps --format '{{.ID}}|{{.Names}}|{{.Image}}' 2>/dev/null)"
    [ -n "$rows" ] || return 1

    log "[+] Detecting Xray inside running Docker containers..." >&2
    while IFS='|' read -r cid name image; do
        [ -n "$cid" ] || continue
        path="$(docker exec "$cid" sh -lc 'command -v xray 2>/dev/null || { [ -x /usr/local/bin/xray ] && echo /usr/local/bin/xray; }' 2>/dev/null | head -n1)"
        [ -n "$path" ] || continue
        line="$(docker exec "$cid" "$path" version 2>/dev/null | head -n1)"
        ver="$(sed -nE 's/^Xray[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' <<<"$line")"
        [ -n "$ver" ] || continue
        printf '    found: %-24s %-34s Xray %s\n' "$name" "$image" "$ver" >&2

        if [ -z "$best_ver" ] || version_ge "$ver" "$best_ver"; then
            best_ver="$ver"
            best_cid="$cid"
            best_name="$name"
            best_image="$image"
            best_path="$path"
        fi
    done <<< "$rows"

    [ -n "$best_cid" ] || return 1
    printf '%s|%s|%s|%s|%s\n' "$best_cid" "$best_name" "$best_image" "$best_path" "$best_ver"
}

get_asn() {
    local ip="$1" rev ans
    rev="$(awk -F. '{print $4"."$3"."$2"."$1}' <<<"$ip")"
    ans="$(dig +short TXT "${rev}.origin.asn.cymru.com" 2>/dev/null | tr -d '"' | head -n1)"
    awk -F'|' '{gsub(/[[:space:]]/, "", $1); print $1}' <<<"$ans"
}

get_asname() {
    local asn="$1"
    [ -n "$asn" ] || return 0
    dig +short TXT "AS${asn}.asn.cymru.com" 2>/dev/null | tr -d '"' | head -n1 |
        awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $5); print $5}'
}

provider_name() {
    local asn="$1" cname="$2" asname="$3" all="$cname $asname"
    if [ "$asn" = "54113" ] || grep -Eqi 'fastly' <<<"$all"; then echo FASTLY
    elif [ "$asn" = "13335" ] || grep -Eqi 'cloudflare' <<<"$all"; then echo CLOUDFLARE
    elif [ "$asn" = "20940" ] || grep -Eqi 'akamai' <<<"$all"; then echo AKAMAI
    elif [ "$asn" = "16509" ] || [ "$asn" = "14618" ] || grep -Eqi 'amazon|aws' <<<"$all"; then echo AWS
    elif [ "$asn" = "8075" ] || grep -Eqi 'microsoft' <<<"$all"; then echo MICROSOFT
    elif [ "$asn" = "15169" ] || grep -Eqi 'google' <<<"$all"; then echo GOOGLE
    else echo OTHER
    fi
}

median_ms() {
    printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {if (NR%2) print a[(NR+1)/2]; else printf "%.0f\n", (a[NR/2]+a[NR/2+1])/2}'
}

probe_domain() {
    local D="$1" ip asn asname cname provider tlsout xout sni certlen pq pass=0 res rc ms median same_asn same_rank
    local times=()

    ip="$(getent ahostsv4 "$D" 2>/dev/null | awk '{print $1}' | sort -u | head -n1)"
    [ -n "$ip" ] || return 0

    asn="$(get_asn "$ip")"
    [[ "$asn" =~ ^[0-9]+$ ]] || return 0
    asname="$(get_asname "$asn")"
    cname="$(dig +short CNAME "$D" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    provider="$(provider_name "$asn" "$cname" "$asname")"

    [ "$EXCLUDE_CLOUDFLARE" -eq 0 ] || [ "$provider" != "CLOUDFLARE" ] || return 0
    [ "$EXCLUDE_FASTLY" -eq 0 ] || [ "$provider" != "FASTLY" ] || return 0
    [ "$provider" != "GOOGLE" ] || return 0

    tlsout="$(timeout 6 openssl s_client -connect "$D:443" -servername "$D" -alpn h2 -tls1_3 </dev/null 2>&1)"
    grep -Eqi 'TLSv1\.3|Protocol *: TLSv1\.3' <<<"$tlsout" || return 0
    grep -Eqi 'ALPN protocol: h2' <<<"$tlsout" || return 0
    grep -Eqi 'Verify return code: 0 \(ok\)' <<<"$tlsout" || return 0

    xout="$(timeout 12 docker exec "$XRAY_CID" "$XRAY_PATH" tls ping "$D:443" 2>&1)"
    rc=$?
    [ "$rc" -eq 0 ] || return 0
    grep -q 'TLS ping finished' <<<"$xout" || return 0

    sni="$(awk '/Pinging with SNI/{f=1; next} f{print}' <<<"$xout")"
    grep -q 'Handshake succeeded' <<<"$sni" || return 0
    grep -Eq 'TLS Version:[[:space:]]+TLS 1\.3' <<<"$sni" || return 0

    certlen="$(grep -Eo "Certificate chain's total length:[[:space:]]*[0-9]+" <<<"$sni" | head -n1 | grep -Eo '[0-9]+$')"
    [[ "$certlen" =~ ^[0-9]+$ ]] || return 0
    [ "$certlen" -gt "$MIN_CERT_LENGTH" ] || return 0

    pq=NO
    if grep -Eqi 'TLS Post-Quantum key exchange:[[:space:]]+true.*X25519MLKEM768' <<<"$sni"; then pq=YES; fi
    [ "$REQUIRE_PQ" -eq 0 ] || [ "$pq" = YES ] || return 0

    for ((i=1; i<=STABILITY_TESTS; i++)); do
        res="$(curl -4 -sS -o /dev/null --connect-timeout 3 --max-time 7 -H 'Connection: close' -w '%{time_appconnect}' "https://$D/" 2>/dev/null)"
        rc=$?
        if [ "$rc" -eq 0 ] && [ -n "$res" ] && [ "$res" != "0.000000" ]; then
            ms="$(awk -v x="$res" 'BEGIN {printf "%.0f", x*1000}')"
            times+=("$ms")
            pass=$((pass+1))
        fi
    done
    [ "$pass" -eq "$STABILITY_TESTS" ] || return 0

    median="$(median_ms "${times[@]}")"
    [ "$median" -le "$MAX_MEDIAN_MS" ] || return 0

    same_asn=NO
    if [ -n "$SERVER_ASN" ] && [ "$asn" = "$SERVER_ASN" ]; then same_asn=YES; fi
    same_rank=1; [ "$same_asn" = YES ] && same_rank=0

    {
        flock 9
        printf '%d|%06d|%s|%s|AS%s|%s|%s|%s|%s\n' \
            "$same_rank" "$median" "$D" "$ip" "$asn" "$provider" "$same_asn" "$pq" "$certlen" >> "$GOOD_RAW"
        {
            echo "DOMAIN      : $D"
            echo "IP          : $ip"
            echo "ASN         : AS$asn"
            echo "AS NAME     : ${asname:-UNKNOWN}"
            echo "PROVIDER    : $provider"
            echo "CNAME       : ${cname:-NONE}"
            echo "SAME ASN    : $same_asn"
            echo "TLS         : TLS 1.3"
            echo "ALPN        : h2"
            echo "CERT LENGTH : $certlen"
            echo "PQ          : $pq"
            echo "STABILITY   : $pass/$STABILITY_TESTS"
            echo "TLS TIMES   : ${times[*]} ms"
            echo "MEDIAN      : ${median}ms"
            echo "XRAY        : PASS ($XRAY_NAME / $XRAY_VERSION)"
            echo "------------------------------------------------------------"
        } >> "$OUT"
    } 9>"$LOCK"
}

export -f get_asn get_asname provider_name median_ms probe_domain

install_deps_if_needed || exit 1

if ! docker info >/dev/null 2>&1; then
    log "[!] Docker is not available or this user cannot access the Docker daemon."
    exit 1
fi

DETECTED="$(find_xray_container)" || {
    log "[!] No running Docker container with an Xray binary was found."
    exit 1
}
IFS='|' read -r XRAY_CID XRAY_NAME XRAY_IMAGE XRAY_PATH XRAY_VERSION <<<"$DETECTED"

log
log "[+] Selected Xray container:"
log "    Name    : $XRAY_NAME"
log "    Image   : $XRAY_IMAGE"
log "    ID      : $XRAY_CID"
log "    Binary  : $XRAY_PATH"
log "    Version : $XRAY_VERSION"

if ! version_ge "$XRAY_VERSION" "$MIN_XRAY_VERSION"; then
    log "[!] Xray $XRAY_VERSION is too old for this strict scanner."
    log "    Required: >= $MIN_XRAY_VERSION"
    exit 1
fi

if ! docker exec "$XRAY_CID" "$XRAY_PATH" tls ping github.io:443 >/dev/null 2>&1; then
    log "[!] The selected Xray core does not pass a tls ping capability test."
    exit 1
fi

SERVER_IP="$(curl -4 -fsS --connect-timeout 4 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
SERVER_ASN=""; SERVER_ASNAME=""
if [ -n "$SERVER_IP" ]; then
    SERVER_ASN="$(get_asn "$SERVER_IP")"
    SERVER_ASNAME="$(get_asname "$SERVER_ASN")"
fi

log "    Server IP/ASN: ${SERVER_IP:-UNKNOWN} ${SERVER_ASN:+AS$SERVER_ASN} ${SERVER_ASNAME:-}"
log
log "[+] Downloading randomized public-domain source..."

curl -fsSL --connect-timeout 10 --max-time 120 \
    'https://tranco-list.eu/top-1m.csv.zip' -o "$ZIP" || {
        log "[!] Failed to download Tranco Top 1M."
        exit 1
    }
unzip -t "$ZIP" >/dev/null 2>&1 || { log "[!] Invalid Tranco ZIP."; exit 1; }
unzip -p "$ZIP" | tr -d '\r' > "$RAW"

head -n "$POOL_SIZE" "$RAW" |
    awk -F',' 'NF>=2 {d=$2; gsub(/^[[:space:]\"]+|[[:space:]\"]+$/, "", d); print tolower(d)}' |
    grep -E '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$' |
    grep -Evi '(^|\.)apple\.com$|(^|\.)icloud\.com$|(^|\.)google\.|(^|\.)googleapis\.com$|(^|\.)googleusercontent\.com$|(^|\.)gstatic\.com$|(^|\.)youtube\.com$|(^|\.)youtu\.be$|(^|\.)doubleclick\.net$' |
    sort -u | shuf | head -n "$MAX_CANDIDATES" > "$CANDS"

TOTAL_CANDS="$(wc -l < "$CANDS")"
[ "$TOTAL_CANDS" -gt 0 ] || { log "[!] Candidate generation returned 0 domains."; exit 1; }

export XRAY_CID XRAY_NAME XRAY_IMAGE XRAY_PATH XRAY_VERSION SERVER_ASN \
    EXCLUDE_CLOUDFLARE EXCLUDE_FASTLY REQUIRE_PQ MIN_CERT_LENGTH \
    STABILITY_TESTS MAX_MEDIAN_MS GOOD_RAW OUT LOCK

log "[+] Candidates ready: $TOTAL_CANDS"
log "[+] Need at least $NEEDED strict REALITY targets. Scanning in random batches..."
log

OFFSET=1
while [ "$OFFSET" -le "$TOTAL_CANDS" ]; do
    FOUND="$(wc -l < "$GOOD_RAW")"
    [ "$FOUND" -ge "$NEEDED" ] && break

    END=$((OFFSET + BATCH_SIZE - 1))
    [ "$END" -gt "$TOTAL_CANDS" ] && END="$TOTAL_CANDS"
    log "[*] Batch $OFFSET-$END | healthy so far: $FOUND/$NEEDED"

    sed -n "${OFFSET},${END}p" "$CANDS" | xargs -r -P "$WORKERS" -n 1 bash -c 'probe_domain "$1"' _
    OFFSET=$((END + 1))
done

FOUND="$(wc -l < "$GOOD_RAW")"

if [ -s "$GOOD_RAW" ]; then
    sort -t'|' -k1,1n -k2,2n "$GOOD_RAW" |
        awk -F'|' '{printf "%-32s IP=%-15s %-10s PROVIDER=%-11s SAME_ASN=%-3s PQ=%-3s CERT=%-5s LAT=%dms\n", $3,$4,$5,$6,$7,$8,$9,$2+0}' |
        tee "$HEALTHY"
else
    : > "$HEALTHY"
fi

# Compatibility copies for quick access to the latest completed/partial scan.
cp -f "$HEALTHY" /root/reality-healthy.txt 2>/dev/null || true
cp -f "$OUT" /root/reality-scan-report.txt 2>/dev/null || true

log
log "======================================================================"
log "Selected Docker : $XRAY_NAME ($XRAY_IMAGE)"
log "Xray version    : $XRAY_VERSION"
log "Requested       : $NEEDED"
log "Healthy found   : $FOUND"
log "Healthy list    : $HEALTHY"
log "Detailed report : $OUT"
log "======================================================================"

if [ "$FOUND" -lt "$NEEDED" ]; then
    log "[!] Only $FOUND targets passed every strict requirement in the scanned pool."
    log "    No weak/partial targets were added just to reach $NEEDED."
    exit 2
fi
