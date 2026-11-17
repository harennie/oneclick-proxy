#!/usr/bin/env bash
# 可选实测：使用指定的官方内核，只起回环临时服务，不安装或修改系统服务。
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SINGBOX_TEST_BIN:?请指定临时 sing-box 二进制}"
: "${HYSTERIA_TEST_BIN:?请指定已有 Hysteria2 二进制}"
# shellcheck disable=SC1091
source src/cert.sh
# shellcheck disable=SC1091
source src/selftest.sh
work=$(mktemp -d)
pids=()
trap 'for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done; rm -rf "$work"' EXIT
umask 077
info() { echo "INFO $*"; }
ok() { echo "OK $*"; }
warn() { echo "WARN $*"; }
is_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 > 0 && $1 < 65536 )); }
port_in_use() { local flag=t; [[ $1 == udp ]] && flag=u; [[ -n $(ss -H -ln"$flag" "sport = :$2") ]]; }
mktmp() { TMP_DIR="$work/tmp"; mkdir -p "$TMP_DIR"; }
SB_BIN=$SINGBOX_TEST_BIN HY_BIN=$HYSTERIA_TEST_BIN
CERT_ON=0 CERT_PUBLIC=1 CERT_CA=letsencrypt SNI=selftest.invalid
UUID=00000000-0000-4000-8000-000000000001 TUIC_PASS=fixture-tuic ANYTLS_PASS=fixture-any HY2_PASS=fixture-hy
SB_CRT="$work/cert.pem" HY_CRT=$SB_CRT key="$work/key.pem"
TUIC_ENABLED=1 ANYTLS_ENABLED=1 HY2_ENABLED=1
TUIC_PORT=61001 ANYTLS_PORT=61002 HY2_PORT=61003
for p in "$TUIC_PORT" "$ANYTLS_PORT" "$HY2_PORT"; do
  if port_in_use tcp "$p" || port_in_use udp "$p"; then echo "端口 $p 已占用，未启动临时服务。"; exit 1; fi
done
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout "$key" -out "$SB_CRT" -days 1 -subj /CN=selftest.invalid -addext subjectAltName=DNS:selftest.invalid >/dev/null 2>&1
HY2_PIN=$(openssl x509 -in "$SB_CRT" -noout -fingerprint -sha256 | cut -d= -f2)
jq -n --arg crt "$SB_CRT" --arg key "$key" --arg uuid "$UUID" --arg tp "$TUIC_PASS" --arg ap "$ANYTLS_PASS" \
  --argjson tuic "$TUIC_PORT" --argjson any "$ANYTLS_PORT" '{log:{level:"warn"},inbounds:[
    {type:"tuic",listen:"127.0.0.1",listen_port:$tuic,users:[{uuid:$uuid,password:$tp}],tls:{enabled:true,certificate_path:$crt,key_path:$key,alpn:["h3"]}},
    {type:"anytls",listen:"127.0.0.1",listen_port:$any,users:[{password:$ap}],tls:{enabled:true,certificate_path:$crt,key_path:$key}}
  ],outbounds:[{type:"direct"}]}' >"$work/singbox.json"
"$SB_BIN" check -c "$work/singbox.json"
env GOMEMLIMIT=32MiB GOGC=50 "$SB_BIN" run -c "$work/singbox.json" >"$work/singbox.log" 2>&1 &
pids+=("$!")
jq -n --arg crt "$HY_CRT" --arg key "$key" --arg pass "$HY2_PASS" --arg port "127.0.0.1:$HY2_PORT" \
  '{listen:$port,tls:{cert:$crt,key:$key},auth:{type:"password",password:$pass}}' >"$work/hysteria.json"
env GOMEMLIMIT=32MiB GOGC=50 "$HY_BIN" server -c "$work/hysteria.json" >"$work/hysteria.log" 2>&1 &
pids+=("$!")
for (( i=0; i<20; i++ )); do
  if port_in_use tcp "$ANYTLS_PORT" && port_in_use udp "$HY2_PORT"; then break; fi
  sleep 0.2
done
tuic_selftest
[[ $TUIC_SELFTEST == ok ]] || { cat "$work/singbox.log"; exit 1; }
anytls_selftest
[[ $ANYTLS_SELFTEST == ok ]] || { cat "$work/singbox.log"; exit 1; }
hy2_selftest
[[ $HY2_SELFTEST == ok ]] || { cat "$work/hysteria.log"; exit 1; }
HY2_PASS=wrong-password
hy2_selftest
[[ $HY2_SELFTEST == fail ]] || { echo '错误的 Hysteria2 认证未被检出'; exit 1; }
echo 'ok live TUIC, AnyTLS, Hysteria2, and rejection of wrong authentication'
