#!/usr/bin/env bash
# 可选实测：只起回环服务，使用已有内核与 CN 数据，不修改系统服务或正式配置。
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SINGBOX_TEST_BIN:?请指定临时 sing-box 二进制}"
: "${HYSTERIA_TEST_BIN:?请指定已有 Hysteria2 二进制}"
: "${REALITY_TEST_SNI:?请指定可用的 REALITY 目标域名}"
: "${REALITY_TEST_TARGET:?请指定该域名的 HTTPS 后端地址}"
# shellcheck disable=SC1091
source src/xray.sh
# shellcheck disable=SC1091
source src/singbox.sh
# shellcheck disable=SC1091
source src/land.sh
# shellcheck disable=SC1091
source src/hy2.sh
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
die() { echo "FAIL $*" >&2; exit 1; }
is_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 > 0 && $1 < 65536 )); }
port_in_use() { local flag=t; [[ $1 == udp ]] && flag=u; [[ -n $(ss -H -ln"$flag" "sport = :$2") ]]; }
port_owner() { local flag=t; [[ $1 == udp ]] && flag=u; ss -H -lnp"$flag" "sport = :$2" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n 1; }
ensure_cn_geodata() { [[ -s $XRAY_ASSET_DIR/$CN_IP_FILE && -s $XRAY_ASSET_DIR/$CN_SITE_FILE ]]; }
ensure_proto_secrets() { :; }
ensure_outbound_ip() { OUTBOUND_EFFECTIVE=46; }
own_svc_config() { chmod 600 "$1"; }
selinux_fix() { :; }
svc_active() { [[ $1 == xray ]] && kill -0 "$server_pid"; }
write_xray_config() { die 'fixture attempted to regenerate the production gateway'; }
restart_xray() { die 'fixture attempted to restart a system service'; }
save_state() { die 'fixture attempted to write persistent state'; }
pqv_active() { return 1; }
XRAY_BIN=${XRAY_TEST_BIN:-/usr/local/bin/xray}
XRAY_ASSET_DIR=${XRAY_TEST_ASSET_DIR:-/usr/local/share/xray}
CN_IP_FILE=proxy-cn-geoip.dat CN_SITE_FILE=proxy-cn-geosite.dat
SB_BIN=$SINGBOX_TEST_BIN HY_BIN=$HYSTERIA_TEST_BIN
XRAY_CONF="$work/xray.json" HY_DIR="$work/hy" SB_DIR="$work/sb"
mkdir -p "$HY_DIR" "$SB_DIR"
HY_CONF="$HY_DIR/config.yaml" HY_CRT="$HY_DIR/server.crt" HY_KEY="$HY_DIR/server.key"
SB_CONF="$SB_DIR/config.json" SB_CRT="$SB_DIR/server.crt" SB_KEY="$SB_DIR/server.key"
LAND_MODE=0 RELAY_ON=0 CERT_ON=0 CERT_PUBLIC=1 CERT_CA=letsencrypt
HY2_ENABLED=1 TUIC_ENABLED=1 ANYTLS_ENABLED=1 RELAY_SOCKS=61003
HY2_PORT=61006 TUIC_PORT=61004 ANYTLS_PORT=61005
SNI=$REALITY_TEST_SNI UUID=00000000-0000-4000-8000-000000000001 SHORT_ID=abcd XHTTP_PATH=/test
HY2_PASS=fixture-hy TUIC_PASS=fixture-tuic ANYTLS_PASS=fixture-any
for p in 61001 61002 61003 61004 61005 61006 61008; do
  if port_in_use tcp "$p" || port_in_use udp "$p"; then die "测试端口 $p 已占用"; fi
done
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout "$HY_KEY" -out "$HY_CRT" -days 1 -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1
HY2_PIN=$(openssl x509 -in "$HY_CRT" -noout -fingerprint -sha256 | cut -d= -f2)
keys=$("$XRAY_BIN" x25519)
PRIV_KEY=$(awk -F': *' 'tolower($1) ~ /^private ?key/ {print $NF; exit}' <<<"$keys")
PUB_KEY=$(awk -F': *' 'tolower($1) ~ /^(public ?key|password)/ {print $NF; exit}' <<<"$keys")
[[ -n $PRIV_KEY && -n $PUB_KEY ]] || die 'cannot generate fixture keys'
jq -n --arg priv "$PRIV_KEY" --arg id "$UUID" --arg sni "$SNI" --arg sid "$SHORT_ID" --arg log "$work/access.log" --arg target "$REALITY_TEST_TARGET" '
  def reality: {network:"raw",security:"reality",realitySettings:{target:$target,serverNames:[$sni],privateKey:$priv,shortIds:[$sid]}};
  {log:{loglevel:"warning",access:$log},dns:{servers:["localhost"],hosts:{"cn-probe.invalid":["1.2.4.8","2400:3200::1"]}},
    inbounds:[
      {tag:"reality",listen:"127.0.0.1",port:61001,protocol:"vless",settings:{clients:[{id:$id,flow:"xtls-rprx-vision"}],decryption:"none"},streamSettings:reality},
      {tag:"xhttp",listen:"127.0.0.1",port:61002,protocol:"vless",settings:{clients:[{id:$id}],decryption:"none"},streamSettings:(reality|.network="xhttp"|.xhttpSettings={path:"/test",mode:"stream-one"})}
    ],outbounds:[{tag:"direct",protocol:"freedom"},{tag:"block",protocol:"blackhole"}],routing:{rules:[]}}
' >"$XRAY_CONF"
local_policy_attach "$XRAY_CONF"
cn_policy_inject "$XRAY_CONF"
XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" "$XRAY_BIN" run -test -c "$XRAY_CONF" >"$work/xray-check.log" 2>&1 || die 'Xray fixture invalid'
env XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" GOMEMLIMIT=32MiB GOGC=50 "$XRAY_BIN" run -c "$XRAY_CONF" >"$work/xray.log" 2>&1 &
server_pid=$!; pids+=("$server_pid")
sleep 1
code=$(curl --noproxy '' --socks5-hostname 127.0.0.1:61003 --connect-timeout 4 -m 10 -sS -o /dev/null -w '%{http_code}' https://cp.cloudflare.com/generate_204) || { cat "$work/xray.log"; die 'policy gateway foreign request failed'; }
[[ $code == 204 ]] || die "policy gateway foreign response $code"
echo 'ok live shared gateway allows foreign TCP'
write_hy2_config
write_singbox_config
# The writers retain their real outbound logic; fixtures bind public listeners to loopback.
sed -i "s/^listen: :/listen: 127.0.0.1:/" "$HY_CONF"
jq '.inbounds[].listen="127.0.0.1"' "$SB_CONF" >"$SB_CONF.loop"; mv "$SB_CONF.loop" "$SB_CONF"
env GOMEMLIMIT=32MiB GOGC=50 "$HY_BIN" server -c "$HY_CONF" >"$work/hy.log" 2>&1 &
pids+=("$!")
env GOMEMLIMIT=32MiB GOGC=50 "$SB_BIN" run -c "$SB_CONF" >"$work/sb.log" 2>&1 &
pids+=("$!")
sleep 1
assert_block() {
  local host=$1 start=$2
  sleep 0.1
  if ! tail -n +"$start" "$work/access.log" | grep -F "$host" | grep -q -- '-> block]'; then
    cat "$work/access.log" >&2
    die "$host did not reach the block outbound"
  fi
}
for kind in hy2 tuic anytls reality xhttp; do
  case $kind in reality) port=61001 ;; xhttp) port=61002 ;; hy2) port=$HY2_PORT ;; tuic) port=$TUIC_PORT ;; anytls) port=$ANYTLS_PORT ;; esac
  selftest_client_config "$kind" 61008 "$port" "$work/client.json"
  case $kind in
    reality|xhttp) cmd=("$XRAY_BIN" run -c "$work/client.json") ;;
    hy2) cmd=("$HY_BIN" client -c "$work/client.json") ;;
    *) cmd=("$SB_BIN" run -c "$work/client.json") ;;
  esac
  env GOMEMLIMIT=32MiB GOGC=50 "${cmd[@]}" >"$work/client.log" 2>&1 &
  client=$!; pids+=("$client")
  sleep 0.8
  code=$(curl --noproxy '' --socks5-hostname 127.0.0.1:61008 --connect-timeout 4 -m 10 -sS -o /dev/null -w '%{http_code}' https://cp.cloudflare.com/generate_204) || { cat "$work/client.log" "$work/xray.log" "$work/access.log"; die "$kind foreign request failed"; }
  [[ $code == 204 ]] || die "$kind foreign response $code"
  for host in "probe-$kind.baidu.com" '1.2.4.8' '[2400:3200::1]' cn-probe.invalid; do
    start=$(( $(wc -l <"$work/access.log") + 1 ))
    if curl --noproxy '' --socks5-hostname 127.0.0.1:61008 --connect-timeout 2 -m 3 -ks -o /dev/null "https://$host/"; then die "$kind allowed $host"; fi
    assert_block "$host" "$start"
  done
  kill "$client"; wait "$client" 2>/dev/null || true
  echo "ok live $kind: foreign allowed; CN domain, IPv4, IPv6 and DNS-resolved CN IP blocked"
done
start=$(( $(wc -l <"$work/access.log") + 1 ))
python3 - <<'PY'
import socket, struct, time
for family, kind, host in [(socket.AF_INET, 1, '1.2.4.8'), (socket.AF_INET6, 4, '2400:3200::1')]:
    with socket.create_connection(('127.0.0.1', 61003)) as control:
        control.sendall(b'\x05\x01\x00')
        assert control.recv(2) == b'\x05\x00'
        control.sendall(b'\x05\x03\x00\x01\x7f\x00\x00\x01\x00\x00')
        reply = control.recv(64)
        assert reply[:4] == b'\x05\x00\x00\x01', reply
        endpoint = socket.inet_ntoa(reply[4:8]), struct.unpack('!H', reply[8:10])[0]
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            udp.sendto(b'\x00\x00\x00' + bytes([kind]) + socket.inet_pton(family, host) + struct.pack('!H', 53) + b'fixture-dns', endpoint)
            time.sleep(0.5)
PY
assert_block 'udp:1.2.4.8:53' "$start"
assert_block 'udp:[2400:3200::1]:53' "$start"
echo 'ok live shared policy rejects UDP to mainland IPv4 and IPv6'
