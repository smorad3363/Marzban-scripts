#!/usr/bin/env bash
set -uo pipefail
BASE="${BASE_DIR:-/root/reality-scans}"; PIDF="${PID_FILE:-/run/reality-scan.pid}"; SELF="$(readlink -f "${BASH_SOURCE[0]}")"
latest(){ readlink -f "$BASE/latest" 2>/dev/null || true; }
status(){
  local p="" l="$(latest)"; [ -f "$PIDF" ] && p="$(cat "$PIDF" 2>/dev/null||true)"
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "RUNNING pid=$p"; else echo "NOT RUNNING"; fi
  [ -n "$l" ] && { echo "Latest run : $l"; echo "Log        : $l/reality-scan.log"; echo "Healthy    : $l/reality-healthy.txt"; }
  if { [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; } && [ -f "$l/reality-scan.log" ]; then echo; echo "Last log lines:"; tail -n10 "$l/reality-scan.log"; fi
}
case "${1:-}" in
 status) status; exit;;
 logs|log) L="$(latest)"; [ -f "$L/reality-scan.log" ]||{ echo "No log yet.";exit 1;}; tail -f "$L/reality-scan.log"; exit;;
 results|result) L="$(latest)"; [ -f "$L/reality-healthy.txt" ]&&cat "$L/reality-healthy.txt"||echo "No results yet."; exit;;
 stop) [ -f "$PIDF" ]&&P="$(cat "$PIDF" 2>/dev/null||true)"||P=""; [ -n "$P" ]&&kill -0 "$P" 2>/dev/null&&{ kill "$P";echo "Stop signal sent to pid=$P";exit;}; echo "No running scan."; exit;;
 ""|[1-9][0-9]*) ;;
 *) echo "Usage: reality-scan [NUMBER|status|logs|results|stop]"; exit 1;;
esac

if [ "${REALITY_SCAN_WORKER:-0}" != 1 ]; then
 mkdir -p "$BASE"
 if [ -f "$PIDF" ]; then P="$(cat "$PIDF" 2>/dev/null||true)"; if [ -n "$P" ]&&kill -0 "$P" 2>/dev/null; then echo "[!] Scan already running pid=$P";exit 1; fi; rm -f "$PIDF"; fi
 D="${NEEDED:-50}"
 if [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; then N="$1"; else while :; do printf 'How many healthy REALITY targets do you want? [%s]: ' "$D"; read -r N; N="${N:-$D}"; [[ "$N" =~ ^[1-9][0-9]*$ ]]&&break; done; fi
 R="$BASE/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$R"; ln -sfn "$R" "$BASE/latest"
 nohup env REALITY_SCAN_WORKER=1 NEEDED="$N" OUT_DIR="$R" BASE_DIR="$BASE" PID_FILE="$PIDF" bash "$SELF" >"$R/reality-scan.log" 2>&1 </dev/null &
 P=$!; echo "$P" >"$PIDF"; echo "$P" >"$R/reality-scan.pid"
 echo; echo "[+] Scan started in background."; echo "    Requested : $N healthy targets"; echo "    PID       : $P"; echo "    Run dir   : $R"; echo "    Log       : $R/reality-scan.log"; echo "    Results   : $R/reality-healthy.txt"
 echo; echo "SSH may disconnect; scan continues."; echo "status: reality-scan status"; echo "logs: reality-scan logs"; echo "results: reality-scan results"; exit
fi

N="${NEEDED:-50}"; OUT="${OUT_DIR:?}"; BATCH="${BATCH_SIZE:-250}"; WORKERS="${WORKERS:-8}"; TESTS="${STABILITY_TESTS:-3}"
MAXMS="${MAX_MEDIAN_MS:-1000}"; MINCERT="${MIN_CERT_LENGTH:-3500}"; MAXC="${MAX_CANDIDATES:-1000000}"
REP="$OUT/reality-scan-report.txt"; GOOD="$OUT/reality-healthy.raw"; HEALTH="$OUT/reality-healthy.txt"; W="$(mktemp -d)"; LOCK="$W/lock"
:>"$REP";:>"$GOOD";:>"$HEALTH"
cleanup(){ rm -rf "$W"; [ -f "$PIDF" ]&&[ "$(cat "$PIDF" 2>/dev/null||true)" = "$$" ]&&rm -f "$PIDF"; }; trap cleanup EXIT INT TERM
for c in docker curl unzip awk grep shuf dig openssl timeout getent sort sed flock wc xargs;do command -v "$c">/dev/null||{ echo "[!] missing $c";exit 1;};done
docker info>/dev/null 2>&1||{ echo "[!] Docker unavailable";exit 1;}

verge(){ [ "$(printf '%s\n%s\n' "$2" "$1"|sort -V|head -1)" = "$2" ]; }
detect(){
 local cid n im p v line bv="" bc="" bn="" bi="" bp=""
 echo "[+] Detecting Xray inside running Docker containers..." >&2
 while IFS='|' read -r cid n im;do
  p="$(docker exec "$cid" sh -lc 'command -v xray 2>/dev/null||{ [ -x /usr/local/bin/xray ]&&echo /usr/local/bin/xray; }' 2>/dev/null|head -1)";[ -n "$p" ]||continue
  line="$(docker exec "$cid" "$p" version 2>/dev/null|head -1)";v="$(sed -nE 's/^Xray[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+).*/\1/p'<<<"$line")";[ -n "$v" ]||continue
  printf '    found: %-22s %-32s Xray %s\n' "$n" "$im" "$v" >&2
  if [ -z "$bv" ]||verge "$v" "$bv";then bv="$v";bc="$cid";bn="$n";bi="$im";bp="$p";fi
 done<<<"$(docker ps --format '{{.ID}}|{{.Names}}|{{.Image}}')"
 [ -n "$bc" ]&&echo "$bc|$bn|$bi|$bp|$bv"
}
D="$(detect)"||{ echo "[!] No Xray container found";exit 1;}; IFS='|' read -r CID CNAME CIMAGE XPATH XVER<<<"$D"
echo;echo "[+] Selected Xray container:";echo "    Name    : $CNAME";echo "    Image   : $CIMAGE";echo "    Version : $XVER"

xping(){ timeout 12 docker exec "$CID" "$XPATH" tls ping "$1" 2>&1; }
CAP="$(xping github.com)";RC=$?
SNI="$(awk '/Pinging with SNI/{f=1;next}f{print}'<<<"$CAP")"
if [ "$RC" -ne 0 ]||! grep -Eqi 'tls ping finished'<<<"$CAP"||! grep -Eqi 'handshake succeeded'<<<"$SNI";then
 echo "[!] Xray tls ping SNI test failed (version $XVER)";printf '%s\n' "$CAP"|tail -n20;exit 1
fi
grep -q "Certificate chain's total length:"<<<"$CAP"&&CMODE=XRAY_NATIVE||CMODE=OPENSSL_COMPAT
grep -q 'TLS Post-Quantum key exchange:'<<<"$CAP"&&PMODE=XRAY_NATIVE||PMODE=UNAVAILABLE_ON_THIS_CORE
echo "    tls ping : supported";echo "    Cert size: $CMODE";echo "    PQ report: $PMODE"

asn(){ local ip="$1" r a;r="$(awk -F. '{print $4"."$3"."$2"."$1}'<<<"$ip")";a="$(dig +short TXT "$r.origin.asn.cymru.com" 2>/dev/null|tr -d '"'|head -1)";awk -F'|' '{gsub(/[[:space:]]/,"",$1);print $1}'<<<"$a"; }
asname(){ [[ "$1" =~ ^[0-9]+$ ]]||return;dig +short TXT "AS$1.asn.cymru.com" 2>/dev/null|tr -d '"'|head -1|awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$5);print $5}';}
provider(){ local a="$1" s="$2 $3";if [ "$a" = 54113 ]||grep -Eqi fastly<<<"$s";then echo FASTLY;elif [ "$a" = 13335 ]||grep -Eqi cloudflare<<<"$s";then echo CLOUDFLARE;elif [ "$a" = 20940 ]||grep -Eqi akamai<<<"$s";then echo AKAMAI;elif [ "$a" = 16509 ]||[ "$a" = 14618 ]||grep -Eqi 'amazon|aws'<<<"$s";then echo AWS;elif [ "$a" = 15169 ]||grep -Eqi google<<<"$s";then echo GOOGLE;else echo OTHER;fi;}
median(){ printf '%s\n' "$@"|sort -n|awk '{a[NR]=$1}END{if(NR%2)print a[(NR+1)/2];else printf "%.0f\n",(a[NR/2]+a[NR/2+1])/2}';}
certlen(){
 local d="$1" t="$W/cert.$RANDOM.$$" f b sum=0 cnt=0;mkdir -p "$t"
 timeout 8 openssl s_client -showcerts -connect "$d:443" -servername "$d"</dev/null 2>/dev/null|awk -v z="$t" '/BEGIN CERTIFICATE/{n++;f=sprintf("%s/c%03d.pem",z,n);x=1}x{print>f}/END CERTIFICATE/{close(f);x=0}'
 for f in "$t"/c*.pem;do [ -e "$f" ]||continue;b="$(openssl x509 -in "$f" -outform DER 2>/dev/null|wc -c|tr -d ' ')";[[ "$b" =~ ^[0-9]+$ ]]&&sum=$((sum+b))&&cnt=$((cnt+1));done;rm -rf "$t";[ "$cnt" -gt 0 ]&&echo "$sum"
}
fmt(){ sort -t'|' -k1,1n -k2,2n -k3,3n "$GOOD"|head -n "$N"|awk -F'|' '{printf "%-32s IP=%-15s %-10s PROVIDER=%-10s SAME_ASN=%-3s PQ=%-7s CERT=%-5s LAT=%dms\n",$4,$5,$6,$7,$8,$9,$10,$3+0}';}

SIP="$(curl -4 -fsS --connect-timeout 4 --max-time 8 https://api.ipify.org 2>/dev/null||true)";SASN="$(asn "$SIP")";echo "    Server   : ${SIP:-UNKNOWN} ${SASN:+AS$SASN}"
ZIP="$W/t.zip";CSV="$W/t.csv";CANDS="$W/candidates"
echo;echo "[+] Downloading Tranco Top 1M..."
curl -fsSL --connect-timeout 10 --max-time 120 https://tranco-list.eu/top-1m.csv.zip -o "$ZIP"||{ echo "[!] Tranco download failed";exit 1;};unzip -p "$ZIP"|tr -d '\r'>"$CSV"
awk -F',' 'NF>=2{d=tolower($2);gsub(/^[[:space:]\"]+|[[:space:]\"]+$/,"",d);print d}' "$CSV"|grep -E '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$'|grep -Evi '(^|\.)apple\.com$|(^|\.)icloud\.com$|(^|\.)google\.|(^|\.)googleapis\.com$|(^|\.)googleusercontent\.com$|(^|\.)gstatic\.com$|(^|\.)youtube\.com$|(^|\.)youtu\.be$|(^|\.)doubleclick\.net$'|sort -u|shuf|head -n "$MAXC">"$CANDS"
TOTAL="$(wc -l<"$CANDS")";echo "[+] Candidates: $TOTAL";echo "[+] Need $N strict healthy targets."

probe(){
 local d="$1" ip a an cn pr t xo s cl pq=UNKNOWN pqr=1 pass=0 r ms med same=NO sr=1;local tt=()
 ip="$(getent ahostsv4 "$d" 2>/dev/null|awk '{print $1}'|sort -u|head -1)";[ -n "$ip" ]||return
 a="$(asn "$ip")";an="$(asname "$a")";cn="$(dig +short CNAME "$d" 2>/dev/null|tr '\n' ' ')";pr="$(provider "$a" "$cn" "$an")"
 [ "$pr" != CLOUDFLARE ]&&[ "$pr" != FASTLY ]&&[ "$pr" != GOOGLE ]||return
 t="$(timeout 8 openssl s_client -connect "$d:443" -servername "$d" -alpn h2 -tls1_3 </dev/null 2>&1)"
 grep -Eqi 'TLSv1\.3|Protocol *: TLSv1\.3'<<<"$t"&&grep -Eqi 'ALPN protocol: h2'<<<"$t"&&grep -Eqi 'Verify return code: 0 \(ok\)'<<<"$t"||return
 xo="$(xping "$d")";[ $? -eq 0 ]||return;s="$(awk '/Pinging with SNI/{f=1;next}f{print}'<<<"$xo")";grep -Eqi 'tls ping finished'<<<"$xo"&&grep -Eqi 'handshake succeeded'<<<"$s"||return
 if grep -Eqi 'TLS Version:'<<<"$s";then grep -Eqi 'TLS Version:[[:space:]]+TLS 1\.3'<<<"$s"||return;fi
 cl="$(certlen "$d")";[[ "$cl" =~ ^[0-9]+$ ]]&&[ "$cl" -gt "$MINCERT" ]||return
 if grep -q 'TLS Post-Quantum key exchange:'<<<"$s";then if grep -Eqi 'true.*X25519MLKEM768'<<<"$s";then pq=YES;pqr=0;else pq=NO;pqr=2;fi;fi
 for((i=0;i<TESTS;i++));do r="$(curl -4 -sS -o /dev/null --connect-timeout 3 --max-time 7 -H 'Connection: close' -w '%{time_appconnect}' "https://$d/" 2>/dev/null)";if [ $? -eq 0 ]&&[ "$r" != 0.000000 ];then ms="$(awk -v x="$r" 'BEGIN{printf "%.0f",x*1000}')";tt+=("$ms");pass=$((pass+1));fi;done
 [ "$pass" -eq "$TESTS" ]||return;med="$(median "${tt[@]}")";[ "$med" -le "$MAXMS" ]||return
 [ -n "$SASN" ]&&[ "$a" = "$SASN" ]&&same=YES&&sr=0
 { flock 9;printf '%d|%d|%06d|%s|%s|AS%s|%s|%s|%s|%s\n' "$sr" "$pqr" "$med" "$d" "$ip" "${a:-?}" "$pr" "$same" "$pq" "$cl">>"$GOOD";fmt>"$HEALTH.tmp";mv "$HEALTH.tmp" "$HEALTH";printf 'DOMAIN=%s IP=%s ASN=AS%s PROVIDER=%s SAME_ASN=%s PQ=%s CERT=%s LAT=%sms\n' "$d" "$ip" "${a:-?}" "$pr" "$same" "$pq" "$cl" "$med">>"$REP"; } 9>"$LOCK"
}
export -f xping asn asname provider median certlen fmt probe
export CID XPATH W GOOD HEALTH REP LOCK N TESTS MAXMS MINCERT SASN

O=1
while [ "$O" -le "$TOTAL" ];do F="$(wc -l<"$GOOD")";[ "$F" -ge "$N" ]&&break;E=$((O+BATCH-1));[ "$E" -gt "$TOTAL" ]&&E="$TOTAL";echo "[*] Batch $O-$E | healthy $F/$N";sed -n "${O},${E}p" "$CANDS"|xargs -r -P "$WORKERS" -n1 bash -c 'probe "$1"' _;O=$((E+1));done
fmt>"$HEALTH";F="$(wc -l<"$HEALTH")";cp -f "$HEALTH" /root/reality-healthy.txt 2>/dev/null||true
echo;echo "======================================================================";echo "Docker         : $CNAME ($CIMAGE)";echo "Xray version   : $XVER";echo "Cert check     : $CMODE";echo "PQ visibility  : $PMODE";echo "Healthy found  : $F / $N";echo "Healthy list   : $HEALTH";echo "Report         : $REP";echo "======================================================================"
[ "$F" -ge "$N" ]||exit 2
