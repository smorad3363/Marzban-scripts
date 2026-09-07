#!/usr/bin/env bash
set -uo pipefail

BASE="${BASE_DIR:-/root/reality-scans}"
PIDF="${PID_FILE:-/run/reality-scan.pid}"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

latest_run() { readlink -f "$BASE/latest" 2>/dev/null || true; }

fmt_elapsed() {
    local s="${1:-0}" h m
    [[ "$s" =~ ^[0-9]+$ ]] || s=0
    h=$((s/3600)); m=$(((s%3600)/60)); s=$((s%60))
    if [ "$h" -gt 0 ]; then printf '%dh %02dm %02ds' "$h" "$m" "$s"
    elif [ "$m" -gt 0 ]; then printf '%dm %02ds' "$m" "$s"
    else printf '%ds' "$s"; fi
}

show_status() {
    local p="" l started="" elapsed=0
    l="$(latest_run)"
    [ -f "$PIDF" ] && p="$(cat "$PIDF" 2>/dev/null || true)"

    echo "============================================================"
    echo " REALITY Target Scanner"
    echo "============================================================"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
        echo "State       : RUNNING"
        echo "PID         : $p"
    else
        echo "State       : NOT RUNNING"
    fi

    if [ -n "$l" ]; then
        echo "Run         : $l"
        if [ -f "$l/started.epoch" ]; then
            started="$(cat "$l/started.epoch" 2>/dev/null || true)"
            if [[ "$started" =~ ^[0-9]+$ ]]; then
                elapsed=$(( $(date +%s) - started ))
                echo "Elapsed     : $(fmt_elapsed "$elapsed")"
            fi
        fi
        if [ -f "$l/progress.txt" ]; then
            echo "------------------------------------------------------------"
            cat "$l/progress.txt"
        fi
        echo "------------------------------------------------------------"
        echo "Log         : $l/reality-scan.log"
        echo "Results     : $l/reality-ranked.txt"
        echo "CSV         : $l/reality-ranked.csv"

        if { [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; } && [ -f "$l/reality-scan.log" ]; then
            echo "------------------------------------------------------------"
            echo "Last log lines:"
            tail -n 12 "$l/reality-scan.log" 2>/dev/null || true
        fi
    fi
}

show_results() {
    local l
    l="$(latest_run)"
    [ -n "$l" ] || { echo "No scan found yet."; return 1; }

    if [ -s "$l/reality-ranked.txt" ]; then
        cat "$l/reality-ranked.txt"
        if [ -f "$l/progress.txt" ]; then
            echo
            grep -E '^(Phase|Perfect|Benchmarked|Note)' "$l/progress.txt" 2>/dev/null || true
        fi
        return 0
    fi

    echo "No ranked results yet."
    [ -f "$l/progress.txt" ] && cat "$l/progress.txt"
}

case "${1:-}" in
    status) show_status; exit 0 ;;
    logs|log)
        L="$(latest_run)"
        [ -f "$L/reality-scan.log" ] || { echo "No log yet."; exit 1; }
        tail -f "$L/reality-scan.log"
        exit 0
        ;;
    results|result) show_results; exit $? ;;
    stop)
        P=""
        [ -f "$PIDF" ] && P="$(cat "$PIDF" 2>/dev/null || true)"
        if [ -n "$P" ] && kill -0 "$P" 2>/dev/null; then
            kill "$P"
            echo "Stop signal sent to pid=$P"
            exit 0
        fi
        echo "No running scan."
        exit 0
        ;;
    ""|[1-9][0-9]*) ;;
    *) echo "Usage: reality-scan [NUMBER|status|logs|results|stop]"; exit 1 ;;
esac

# Interactive launcher: detach so SSH disconnect does not stop the scan.
if [ "${REALITY_SCAN_WORKER:-0}" != "1" ]; then
    mkdir -p "$BASE"

    if [ -f "$PIDF" ]; then
        P="$(cat "$PIDF" 2>/dev/null || true)"
        if [ -n "$P" ] && kill -0 "$P" 2>/dev/null; then
            echo "[!] A scan is already running (pid=$P)."
            echo "    reality-scan status"
            exit 1
        fi
        rm -f "$PIDF"
    fi

    DEFAULT_N="${NEEDED:-50}"
    if [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; then
        N="$1"
    else
        while :; do
            printf 'How many healthy REALITY targets do you want? [%s]: ' "$DEFAULT_N"
            IFS= read -r N
            N="${N:-$DEFAULT_N}"
            [[ "$N" =~ ^[1-9][0-9]*$ ]] && break
            echo "Please enter a positive integer."
        done
    fi

    RUN="$BASE/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$RUN"
    ln -sfn "$RUN" "$BASE/latest"
    date +%s > "$RUN/started.epoch"

    nohup env \
        REALITY_SCAN_WORKER=1 \
        NEEDED="$N" \
        OUT_DIR="$RUN" \
        BASE_DIR="$BASE" \
        PID_FILE="$PIDF" \
        bash "$SELF" >"$RUN/reality-scan.log" 2>&1 </dev/null &

    P=$!
    printf '%s\n' "$P" > "$PIDF"
    printf '%s\n' "$P" > "$RUN/reality-scan.pid"

    echo
    echo "============================================================"
    echo " Scan started"
    echo "============================================================"
    echo "Requested   : $N healthy targets"
    echo "PID         : $P"
    echo "Run dir     : $RUN"
    echo "Log         : $RUN/reality-scan.log"
    echo "Results     : $RUN/reality-ranked.txt"
    echo
    echo "SSH may disconnect; the scan will continue."
    echo "Status      : reality-scan status"
    echo "Live log    : reality-scan logs"
    echo "Results     : reality-scan results"
    exit 0
fi

N="${NEEDED:-50}"
OUT="${OUT_DIR:?OUT_DIR is required}"
MAXC="${MAX_CANDIDATES:-1000000}"
PREFILTER_BATCH="${PREFILTER_BATCH:-500}"
STRICT_TESTS="${STRICT_TESTS:-2}"
QUALITY_RUNS="${QUALITY_RUNS:-20}"
MAX_MEDIAN_MS="${MAX_MEDIAN_MS:-1000}"
MIN_CERT_LENGTH="${MIN_CERT_LENGTH:-3500}"

CPU="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
[[ "$CPU" =~ ^[0-9]+$ ]] || CPU=2

DEFAULT_FAST=$((CPU * 12)); [ "$DEFAULT_FAST" -lt 24 ] && DEFAULT_FAST=24; [ "$DEFAULT_FAST" -gt 64 ] && DEFAULT_FAST=64
DEFAULT_STRICT=$((CPU * 3)); [ "$DEFAULT_STRICT" -lt 8 ] && DEFAULT_STRICT=8; [ "$DEFAULT_STRICT" -gt 24 ] && DEFAULT_STRICT=24
DEFAULT_QUALITY=$((CPU * 2)); [ "$DEFAULT_QUALITY" -lt 4 ] && DEFAULT_QUALITY=4; [ "$DEFAULT_QUALITY" -gt 12 ] && DEFAULT_QUALITY=12

FAST_WORKERS="${FAST_WORKERS:-$DEFAULT_FAST}"
STRICT_WORKERS="${STRICT_WORKERS:-$DEFAULT_STRICT}"
QUALITY_WORKERS="${QUALITY_WORKERS:-$DEFAULT_QUALITY}"

EXTRA=$((N / 2)); [ "$EXTRA" -lt 10 ] && EXTRA=10; [ "$EXTRA" -gt 50 ] && EXTRA=50
TARGET_POOL=$((N + EXTRA))

REP="$OUT/reality-scan-report.txt"
PRE="$OUT/reality-prefilter.raw"
STRICT="$OUT/reality-strict.raw"
BENCH="$OUT/reality-benchmark.raw"
RANKED="$OUT/reality-ranked.txt"
CSVOUT="$OUT/reality-ranked.csv"
PROGRESS="$OUT/progress.txt"

W="$(mktemp -d)"
LOCK_PRE="$W/pre.lock"
LOCK_STRICT="$W/strict.lock"
LOCK_BENCH="$W/bench.lock"

: > "$REP"
: > "$PRE"
: > "$STRICT"
: > "$BENCH"
: > "$RANKED"
: > "$CSVOUT"

cleanup() {
    rm -rf "$W"
    if [ -f "$PIDF" ] && [ "$(cat "$PIDF" 2>/dev/null || true)" = "$$" ]; then
        rm -f "$PIDF"
    fi
}
trap cleanup EXIT INT TERM

log() { printf '%s\n' "$*"; }

progress() {
    local phase="$1" scanned="${2:-0}" total="${3:-0}" pre="${4:-0}" strict="${5:-0}" bench="${6:-0}" perfect="${7:-0}" note="${8:-}"
    {
        printf 'Phase       : %s\n' "$phase"
        printf 'Requested   : %s\n' "$N"
        printf 'Quality pool: %s\n' "$TARGET_POOL"
        printf 'Scanned     : %s / %s\n' "$scanned" "$total"
        printf 'Prefilter   : %s\n' "$pre"
        printf 'Strict      : %s\n' "$strict"
        printf 'Benchmarked : %s\n' "$bench"
        printf 'Perfect     : %s / %s\n' "$perfect" "$N"
        printf 'Workers     : fast=%s strict=%s quality=%s\n' "$FAST_WORKERS" "$STRICT_WORKERS" "$QUALITY_WORKERS"
        [ -n "$note" ] && printf 'Note        : %s\n' "$note"
    } > "$PROGRESS.tmp"
    mv -f "$PROGRESS.tmp" "$PROGRESS"
}

for c in docker curl unzip awk grep shuf dig openssl timeout getent sort sed flock wc xargs head tail tr getconf date; do
    command -v "$c" >/dev/null 2>&1 || { log "[!] Missing command: $c"; exit 1; }
done
docker info >/dev/null 2>&1 || { log "[!] Docker unavailable."; exit 1; }

version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

detect_xray() {
    local cid n im p v line bv="" bc="" bn="" bi="" bp=""
    log "[SETUP] Detecting Xray in running Docker containers..." >&2
    while IFS='|' read -r cid n im; do
        [ -n "$cid" ] || continue
        p="$(docker exec "$cid" sh -lc 'command -v xray 2>/dev/null || { [ -x /usr/local/bin/xray ] && echo /usr/local/bin/xray; }' 2>/dev/null | head -1)"
        [ -n "$p" ] || continue
        line="$(docker exec "$cid" "$p" version 2>/dev/null | head -1)"
        v="$(sed -nE 's/^Xray[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' <<<"$line")"
        [ -n "$v" ] || continue
        printf '        found %-22s %-34s Xray %s\n' "$n" "$im" "$v" >&2
        if [ -z "$bv" ] || version_ge "$v" "$bv"; then
            bv="$v"; bc="$cid"; bn="$n"; bi="$im"; bp="$p"
        fi
    done <<< "$(docker ps --format '{{.ID}}|{{.Names}}|{{.Image}}')"
    [ -n "$bc" ] && printf '%s|%s|%s|%s|%s\n' "$bc" "$bn" "$bi" "$bp" "$bv"
}

D="$(detect_xray)" || { log "[!] No Xray Docker container found."; exit 1; }
IFS='|' read -r CID CNAME CIMAGE XPATH XVER <<< "$D"

log
log "============================================================"
log " REALITY Target Scanner - turbo + ranked"
log "============================================================"
log "Docker      : $CNAME"
log "Image       : $CIMAGE"
log "Xray        : $XVER"
log "Wanted      : $N"
log "Pool target : $TARGET_POOL"
log "Workers     : fast=$FAST_WORKERS strict=$STRICT_WORKERS quality=$QUALITY_WORKERS"
log "Benchmark   : $QUALITY_RUNS fresh TLS connections / target"
log "============================================================"

xping() { timeout 12 docker exec "$CID" "$XPATH" tls ping "$1" 2>&1; }

CAP="$(xping github.com)"; CAPRC=$?
SNI_CAP="$(awk '/Pinging with SNI/{f=1;next} f{print}' <<< "$CAP")"
if [ "$CAPRC" -ne 0 ] || ! grep -Eqi 'tls ping finished' <<< "$CAP" || ! grep -Eqi 'handshake succeeded' <<< "$SNI_CAP"; then
    log "[!] Xray tls ping SNI capability test failed."
    printf '%s\n' "$CAP" | tail -n 20
    exit 1
fi

if grep -q "Certificate chain's total length:" <<< "$CAP"; then CMODE=XRAY_NATIVE; else CMODE=OPENSSL_COMPAT; fi
if grep -q 'TLS Post-Quantum key exchange:' <<< "$CAP"; then PMODE=XRAY_NATIVE; else PMODE=UNAVAILABLE_ON_THIS_CORE; fi
log "tls ping    : supported"
log "Cert size   : $CMODE"
log "PQ report   : $PMODE"

asn() {
    local ip="$1" r a
    r="$(awk -F. '{print $4"."$3"."$2"."$1}' <<< "$ip")"
    a="$(dig +time=2 +tries=1 +short TXT "$r.origin.asn.cymru.com" 2>/dev/null | tr -d '"' | head -1)"
    awk -F'|' '{gsub(/[[:space:]]/,"",$1);print $1}' <<< "$a"
}

asname() {
    [[ "$1" =~ ^[0-9]+$ ]] || return
    dig +time=2 +tries=1 +short TXT "AS$1.asn.cymru.com" 2>/dev/null | tr -d '"' | head -1 |
        awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$5);print $5}'
}

provider_from_asn() {
    case "$1" in
        54113) echo FASTLY ;;
        13335) echo CLOUDFLARE ;;
        20940) echo AKAMAI ;;
        16509|14618) echo AWS ;;
        15169) echo GOOGLE ;;
        8075) echo MICROSOFT ;;
        *) echo OTHER ;;
    esac
}

median() {
    printf '%s\n' "$@" | sort -n |
        awk '{a[NR]=$1} END{if(!NR)exit 1;if(NR%2)print a[(NR+1)/2];else printf "%.0f\n",(a[NR/2]+a[NR/2+1])/2}'
}

certlen_from_tlsout() {
    local tls="$1" t f b sum=0 cnt=0
    t="$(mktemp -d "$W/cert.XXXXXX")" || return 1
    printf '%s\n' "$tls" |
        awk -v z="$t" '
            /BEGIN CERTIFICATE/ {n++;f=sprintf("%s/c%03d.pem",z,n);x=1}
            x {print > f}
            /END CERTIFICATE/ {close(f);x=0}
        '
    for f in "$t"/c*.pem; do
        [ -e "$f" ] || continue
        b="$(openssl x509 -in "$f" -outform DER 2>/dev/null | wc -c | tr -d ' ')"
        if [[ "$b" =~ ^[0-9]+$ ]]; then sum=$((sum+b)); cnt=$((cnt+1)); fi
    done
    rm -rf "$t"
    [ "$cnt" -gt 0 ] && echo "$sum"
}

# Stage 1: cheap filter. One TLS handshake, no curl, no cert parsing.
fast_probe() {
    local d="$1" ip a p tls
    ip="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u | head -1)"
    [ -n "$ip" ] || return 0

    a="$(asn "$ip")"; [[ "$a" =~ ^[0-9]+$ ]] || return 0
    p="$(provider_from_asn "$a")"
    [ "$p" != CLOUDFLARE ] || return 0
    [ "$p" != FASTLY ] || return 0
    [ "$p" != GOOGLE ] || return 0

    tls="$(timeout 4 openssl s_client -connect "$ip:443" -servername "$d" -alpn h2 -tls1_3 -verify_return_error </dev/null 2>&1)"
    grep -Eqi 'TLSv1\.3|Protocol *: TLSv1\.3' <<< "$tls" || return 0
    grep -Eqi 'ALPN protocol: h2' <<< "$tls" || return 0
    grep -Eqi 'Verify return code: 0 \(ok\)' <<< "$tls" || return 0

    { flock 9; printf '%s|%s|%s|%s\n' "$d" "$ip" "$a" "$p" >> "$PRE"; } 9>"$LOCK_PRE"
}

# Stage 2: expensive REALITY checks only for fast-pass candidates.
strict_probe() {
    local line="$1" d ip a p tls cert xo rc sni pq=UNKNOWN pqrank=1 i t ms pass=0 med same=NO samerank=1
    local times=()
    IFS='|' read -r d ip a p <<< "$line"

    tls="$(timeout 7 openssl s_client -showcerts -connect "$ip:443" -servername "$d" -alpn h2 -tls1_3 -verify_return_error </dev/null 2>&1)"
    grep -Eqi 'TLSv1\.3|Protocol *: TLSv1\.3' <<< "$tls" || return 0
    grep -Eqi 'ALPN protocol: h2' <<< "$tls" || return 0
    grep -Eqi 'Verify return code: 0 \(ok\)' <<< "$tls" || return 0

    cert="$(certlen_from_tlsout "$tls" || true)"
    [[ "$cert" =~ ^[0-9]+$ ]] || return 0
    [ "$cert" -gt "$MIN_CERT_LENGTH" ] || return 0

    xo="$(xping "$d")"; rc=$?
    [ "$rc" -eq 0 ] || return 0
    grep -Eqi 'tls ping finished' <<< "$xo" || return 0
    sni="$(awk '/Pinging with SNI/{f=1;next} f{print}' <<< "$xo")"
    grep -Eqi 'handshake succeeded' <<< "$sni" || return 0

    if grep -q 'TLS Post-Quantum key exchange:' <<< "$xo"; then
        if grep -Eqi 'TLS Post-Quantum key exchange:.*true.*X25519MLKEM768' <<< "$xo"; then pq=YES; pqrank=0; else pq=NO; pqrank=2; fi
    fi

    for ((i=1;i<=STRICT_TESTS;i++)); do
        t="$(curl -4 -sS -o /dev/null --connect-timeout 3 --max-time 7 -H 'Connection: close' -w '%{time_appconnect}' "https://$d/" 2>/dev/null)"; rc=$?
        if [ "$rc" -eq 0 ] && [ -n "$t" ] && [ "$t" != 0.000000 ]; then
            ms="$(awk -v x="$t" 'BEGIN{printf "%.0f",x*1000}')"; times+=("$ms"); pass=$((pass+1))
        fi
    done
    [ "$pass" -eq "$STRICT_TESTS" ] || return 0
    med="$(median "${times[@]}")"; [[ "$med" =~ ^[0-9]+$ ]] || return 0
    [ "$med" -le "$MAX_MEDIAN_MS" ] || return 0

    if [ -n "$SASN" ] && [ "$a" = "$SASN" ]; then same=YES; samerank=0; fi

    {
        flock 9
        printf '%d|%d|%s|%s|AS%s|%s|%s|%s|%s|%s\n' "$samerank" "$pqrank" "$d" "$ip" "$a" "$p" "$cert" "$med" "$pq" "$same" >> "$STRICT"
        printf 'STRICT PASS  %-32s %-10s cert=%s med=%sms pq=%s same_asn=%s\n' "$d" "$p" "$cert" "$med" "$pq" "$same" >> "$REP"
    } 9>"$LOCK_STRICT"
}

score_calc() {
    local success="$1" runs="$2" med="$3" p95="$4" jit="$5" cert="$6" pq="$7" same="$8"
    awk -v ok="$success" -v n="$runs" -v med="$med" -v p95="$p95" -v jit="$jit" -v cert="$cert" -v pq="$pq" -v same="$same" '
        BEGIN {
            rel = (n>0 ? (ok/n)*400 : 0)
            lm = 220 - med*1.20; if(lm>200)lm=200; if(lm<0)lm=0
            lp = 220 - p95; if(lp>200)lp=200; if(lp<0)lp=0
            j = 110 - jit*1.50; if(j>100)j=100; if(j<0)j=0
            c = (cert>=6500 ? 40 : (cert>=5000 ? 34 : (cert>=4000 ? 27 : 20)))
            q = (pq=="YES" ? 30 : (pq=="UNKNOWN" ? 15 : 0))
            s = (same=="YES" ? 30 : 0)
            total = int(rel+lm+lp+j+c+q+s+0.5)
            if(total<1)total=1; if(total>1000)total=1000
            print total
        }'
}

benchmark_one() {
    local line="$1" samerank pqrank d ip aas p cert strictmed pq same i rc t ok=0 ms med avg p95 min max jit score
    local tmp
    IFS='|' read -r samerank pqrank d ip aas p cert strictmed pq same <<< "$line"
    tmp="$(mktemp "$W/times.XXXXXX")" || return 0

    for ((i=1;i<=QUALITY_RUNS;i++)); do
        t="$(curl -4 -sS -o /dev/null --connect-timeout 3 --max-time 8 -H 'Connection: close' -w '%{time_appconnect}' "https://$d/" 2>/dev/null)"; rc=$?
        if [ "$rc" -eq 0 ] && [ -n "$t" ] && [ "$t" != 0.000000 ]; then
            ms="$(awk -v x="$t" 'BEGIN{printf "%.0f",x*1000}')"; echo "$ms" >> "$tmp"; ok=$((ok+1))
        fi
    done

    [ "$ok" -gt 0 ] || { rm -f "$tmp"; return 0; }
    sort -n "$tmp" -o "$tmp"
    min="$(head -1 "$tmp")"; max="$(tail -1 "$tmp")"
    avg="$(awk '{s+=$1}END{if(NR)printf "%.0f",s/NR}' "$tmp")"
    med="$(awk '{a[NR]=$1}END{if(NR%2)printf "%.0f",a[(NR+1)/2];else printf "%.0f",(a[NR/2]+a[NR/2+1])/2}' "$tmp")"
    p95="$(awk '{a[NR]=$1}END{n=int(NR*.95+.999999);if(n<1)n=1;print a[n]}' "$tmp")"
    jit=$((max-min))
    score="$(score_calc "$ok" "$QUALITY_RUNS" "$med" "$p95" "$jit" "$cert" "$pq" "$same")"
    rm -f "$tmp"

    {
        flock 9
        printf '%04d|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$score" "$d" "$ip" "$aas" "$p" "$same" "$pq" "$cert" "$ok" "$QUALITY_RUNS" "$med" "$p95" "$avg" "$jit" "$max" >> "$BENCH"
        printf 'BENCH       %-32s score=%4s success=%s/%s med=%sms p95=%sms jitter=%sms\n' "$d" "$score" "$ok" "$QUALITY_RUNS" "$med" "$p95" "$jit" >> "$REP"
    } 9>"$LOCK_BENCH"
}

write_ranked() {
    {
        printf '%-5s %-32s %-9s %-8s %-8s %-8s %-6s %-8s %-8s %-11s\n' SCORE DOMAIN SUCCESS MEDIAN P95 JITTER CERT PQ SAME_ASN PROVIDER
        printf '%-5s %-32s %-9s %-8s %-8s %-8s %-6s %-8s %-8s %-11s\n' ----- -------------------------------- --------- -------- -------- -------- ------ -------- -------- -----------
        awk -F'|' '$9==$10' "$BENCH" | sort -t'|' -k1,1nr -k11,11n -k12,12n |
            head -n "$N" |
            awk -F'|' '{printf "%5d %-32s %2s/%-6s %5sms %5sms %5sms %6s %-8s %-8s %-11s\n",$1+0,$2,$9,$10,$11,$12,$14,$8,$7,$6,$5}'
    } > "$RANKED.tmp"
    mv -f "$RANKED.tmp" "$RANKED"

    {
        echo 'score,domain,ip,asn,provider,same_asn,pq,cert_bytes,success,runs,median_ms,p95_ms,avg_ms,jitter_ms,max_ms'
        awk -F'|' '$9==$10' "$BENCH" | sort -t'|' -k1,1nr -k11,11n -k12,12n | head -n "$N" |
            awk -F'|' 'BEGIN{OFS=","}{print $1+0,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15}'
    } > "$CSVOUT.tmp"
    mv -f "$CSVOUT.tmp" "$CSVOUT"
}

export -f asn asname provider_from_asn median certlen_from_tlsout fast_probe xping strict_probe score_calc benchmark_one
export CID XPATH W PRE STRICT BENCH REP LOCK_PRE LOCK_STRICT LOCK_BENCH MIN_CERT_LENGTH MAX_MEDIAN_MS STRICT_TESTS QUALITY_RUNS SASN

SIP="$(curl -4 -fsS --connect-timeout 4 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
SASN=""; [ -n "$SIP" ] && SASN="$(asn "$SIP")"
export SASN
log "Server      : ${SIP:-UNKNOWN} ${SASN:+AS$SASN}"

progress "SETUP" 0 0 0 0 0 0 "Preparing randomized source"
ZIP="$W/tranco.zip"; CSV="$W/tranco.csv"; CANDS="$W/candidates.txt"
log
log "[1/3] Preparing randomized candidate list..."
curl -fsSL --connect-timeout 10 --max-time 120 https://tranco-list.eu/top-1m.csv.zip -o "$ZIP" || { log "[!] Tranco download failed."; exit 1; }
unzip -t "$ZIP" >/dev/null 2>&1 || { log "[!] Invalid Tranco archive."; exit 1; }
unzip -p "$ZIP" | tr -d '\r' > "$CSV"

# Tranco is already rank-oriented; avoid an unnecessary sort -u over ~1M rows.
awk -F',' 'NF>=2{d=tolower($2);gsub(/^[[:space:]"]+|[[:space:]"]+$/,"",d);print d}' "$CSV" |
    grep -E '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$' |
    grep -Evi '(^|\.)apple\.com$|(^|\.)icloud\.com$|(^|\.)google\.|(^|\.)googleapis\.com$|(^|\.)googleusercontent\.com$|(^|\.)gstatic\.com$|(^|\.)youtube\.com$|(^|\.)youtu\.be$|(^|\.)doubleclick\.net$' |
    shuf | head -n "$MAXC" > "$CANDS"

TOTAL="$(wc -l < "$CANDS")"
[ "$TOTAL" -gt 0 ] || { log "[!] Candidate list is empty."; exit 1; }
log "      Candidates: $TOTAL"
progress "SCAN" 0 "$TOTAL" 0 0 0 0 "Starting fast prefilter"

log
log "[2/3] Fast prefilter + strict REALITY verification..."
OFFSET=1
PRE_DONE=0
BENCHED_STRICT=0
STRICT_GOAL="$TARGET_POOL"
PERFECT=0
ROUND=1

while [ "$PERFECT" -lt "$N" ] && [ "$OFFSET" -le "$TOTAL" ]; do
    STRICT_COUNT="$(wc -l < "$STRICT")"
    log "      round=$ROUND  strict_goal=$STRICT_GOAL  perfect=$PERFECT/$N"

    while [ "$OFFSET" -le "$TOTAL" ] && [ "$STRICT_COUNT" -lt "$STRICT_GOAL" ]; do
        END=$((OFFSET + PREFILTER_BATCH - 1)); [ "$END" -gt "$TOTAL" ] && END="$TOTAL"
        PRE_NOW="$(wc -l < "$PRE")"
        progress "SCAN" "$((OFFSET-1))" "$TOTAL" "$PRE_NOW" "$STRICT_COUNT" "$BENCHED_STRICT" "$PERFECT" "Fast batch $OFFSET-$END"

        sed -n "${OFFSET},${END}p" "$CANDS" |
            xargs -r -P "$FAST_WORKERS" -n 1 bash -c 'fast_probe "$1"' _

        PRE_NOW="$(wc -l < "$PRE")"
        progress "VERIFY" "$END" "$TOTAL" "$PRE_NOW" "$STRICT_COUNT" "$BENCHED_STRICT" "$PERFECT" "Strict-checking new fast-pass targets"

        if [ "$PRE_NOW" -gt "$PRE_DONE" ]; then
            sed -n "$((PRE_DONE+1)),${PRE_NOW}p" "$PRE" |
                xargs -r -d '\n' -P "$STRICT_WORKERS" -I '{}' bash -c 'strict_probe "$1"' _ '{}'
            PRE_DONE="$PRE_NOW"
        fi

        STRICT_COUNT="$(wc -l < "$STRICT")"
        log "      scanned=$END/$TOTAL  prefilter=$PRE_NOW  strict=$STRICT_COUNT/$STRICT_GOAL"
        progress "SCAN" "$END" "$TOTAL" "$PRE_NOW" "$STRICT_COUNT" "$BENCHED_STRICT" "$PERFECT" "Next fast batch"
        OFFSET=$((END + 1))
    done

    STRICT_COUNT="$(wc -l < "$STRICT")"
    if [ "$STRICT_COUNT" -gt "$BENCHED_STRICT" ]; then
        NEW_BENCH=$((STRICT_COUNT - BENCHED_STRICT))
        log
        log "[3/3] Quality benchmark + score 1..1000..."
        log "      benchmarking $NEW_BENCH new strict targets x $QUALITY_RUNS fresh TLS connections"
        progress "BENCHMARK" "$((OFFSET-1))" "$TOTAL" "$(wc -l < "$PRE")" "$STRICT_COUNT" "$BENCHED_STRICT" "$PERFECT" "$QUALITY_RUNS fresh TLS connections per target"

        sed -n "$((BENCHED_STRICT+1)),${STRICT_COUNT}p" "$STRICT" |
            xargs -r -d '\n' -P "$QUALITY_WORKERS" -I '{}' bash -c 'benchmark_one "$1"' _ '{}'

        BENCHED_STRICT="$STRICT_COUNT"
        BENCH_COUNT="$(wc -l < "$BENCH")"
        PERFECT="$(awk -F'|' '$9==$10{n++}END{print n+0}' "$BENCH")"
        write_ranked
        progress "QUALITY" "$((OFFSET-1))" "$TOTAL" "$(wc -l < "$PRE")" "$STRICT_COUNT" "$BENCH_COUNT" "$PERFECT" "Perfect $QUALITY_RUNS/$QUALITY_RUNS targets: $PERFECT/$N"
        log "      benchmarked=$BENCH_COUNT  perfect=$PERFECT/$N"
    fi

    [ "$PERFECT" -ge "$N" ] && break
    [ "$OFFSET" -le "$TOTAL" ] || break

    STRICT_GOAL=$((STRICT_COUNT + EXTRA))
    ROUND=$((ROUND + 1))
done

STRICT_COUNT="$(wc -l < "$STRICT")"
BENCH_COUNT="$(wc -l < "$BENCH")"
PERFECT="$(awk -F'|' '$9==$10{n++}END{print n+0}' "$BENCH")"
write_ranked
progress "DONE" "$((OFFSET-1))" "$TOTAL" "$(wc -l < "$PRE")" "$STRICT_COUNT" "$BENCH_COUNT" "$PERFECT" "Ranked by score 1..1000"

cp -f "$RANKED" /root/reality-ranked.txt 2>/dev/null || true
cp -f "$CSVOUT" /root/reality-ranked.csv 2>/dev/null || true

log
log "============================================================"
log " FINAL"
log "============================================================"
log "Requested    : $N"
log "Perfect      : $PERFECT"
log "Strict       : $STRICT_COUNT"
log "Benchmarked  : $BENCH_COUNT"
log "Ranked       : $RANKED"
log "CSV          : $CSVOUT"
log "Report       : $REP"
log "============================================================"
cat "$RANKED"

if [ "$PERFECT" -lt "$N" ]; then
    log "[!] Only $PERFECT targets achieved perfect $QUALITY_RUNS/$QUALITY_RUNS quality before candidates were exhausted."
    exit 2
fi
