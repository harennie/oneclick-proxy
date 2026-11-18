#!/usr/bin/env bash
# 验证默认协议和共享策略配置，不安装服务、不下载规则。
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./proxy.sh
trap - ERR INT TERM
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL $*" >&2; exit 1; }
[[ $HY2_ENABLED == 0 ]] || fail 'fresh HY2 is enabled'
resolve_install_protos
[[ $REALITY_ENABLED == 1 && $XHTTP_ENABLED == 1 && $HY2_ENABLED == 0 ]] || fail 'fresh defaults'
OPT_AUTO=0
confirm() { printf '%s' "$2" >"$work/default"; return 1; }
confirm_hy2
[[ $(cat "$work/default") == n && $HY2_ENABLED == 0 ]] || fail 'HY2 prompt is not default-no'
INSTALLED=1 STATE_HAS_XHTTP=1 XHTTP_ENABLED=0 HY2_ENABLED=1 OPT_AUTO=1
resolve_install_protos; confirm_hy2
[[ $XHTTP_ENABLED == 0 && $HY2_ENABLED == 1 ]] || fail 'reinstall changed saved flags'
HY2_ENABLED=0
resolve_install_protos; confirm_hy2
[[ $HY2_ENABLED == 0 ]] || fail 'reinstall enabled HY2'
STATE_HAS_XHTTP=0
resolve_install_protos
[[ $XHTTP_ENABLED == 0 ]] || fail 'legacy install silently gained XHTTP'
OPT_HY2=1
resolve_install_protos; confirm_hy2
[[ $HY2_ENABLED == 1 ]] || fail 'explicit --hy2 ignored'
OPT_HY2=0
resolve_install_protos; confirm_hy2
[[ $HY2_ENABLED == 0 ]] || fail 'explicit --no-hy2 ignored'
echo 'ok fresh protocol defaults, explicit HY2 consent and saved installation choices'

ensure_cn_geodata() { return 0; }
config="$work/server.json"
cat >"$config" <<'JSON'
{"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}],"routing":{"domainStrategy":"AsIs","rules":[{"type":"field","source":["203.0.113.1"],"outboundTag":"direct"},{"type":"field","network":"tcp,udp","outboundTag":"land-test"}]}}
JSON
OUTBOUND_EFFECTIVE=64
xray_apply_ip_strategy "$config"
cn_policy_inject "$config"
cn_policy_config_valid "$config" || fail 'CN policy validation failed'
jq -e --arg ip "ext:${CN_IP_FILE}:cn" --arg site "ext:${CN_SITE_FILE}:cn" '
  .routing.domainStrategy == "IPOnDemand" and .routing.rules[0].domain == [$site] and .routing.rules[1].ip == [$ip]
  and .routing.rules[2].source == ["203.0.113.1"] and .routing.rules[-1].outboundTag == "land-test"
  and .outbounds[0].settings.domainStrategy == "UseIPv6v4"
' "$config" >/dev/null || fail 'rules bypassed by whitelist/relay or outbound preference lost'
cn_policy_inject "$config"
[[ $(jq '.routing.rules|length' "$config") == 4 ]] || fail 'CN rules duplicated'
echo 'ok CN rules precede allow/relay rules, cover resolved domains and retain outbound preference'

LAND_MODE=0 REALITY_ENABLED=0 XHTTP_ENABLED=0 TROJAN_ENABLED=0 XHTTP_TLS_ENABLED=0 WS_ENABLED=0 LAND_IN=0 RELAY_ON=0
HY2_ENABLED=1 TUIC_ENABLED=0 ANYTLS_ENABLED=0 RELAY_SOCKS=31080
xray_inbound_needed || fail 'HY2-only installation bypasses Xray'
local_policy_attach "$config"; local_policy_attach "$config"
jq -e '.inbounds|length == 1 and .[0].listen == "127.0.0.1" and .[0].port == 31080 and .[0].settings.udp == true and .[0].sniffing.routeOnly == true' "$config" >/dev/null || fail 'policy socket public, duplicated, or sniffing/UDP disabled'
hy2_outbound_yaml >"$work/hy.yaml"
grep -q 'type: socks5' "$work/hy.yaml"; grep -q 'addr: 127.0.0.1:31080' "$work/hy.yaml"
if grep -q 'type: direct' "$work/hy.yaml"; then fail 'HY2 can bypass policy'; fi
jq '.inbounds += [{tag:"public",port:31080}]' "$config" >"$config.next"; mv "$config.next" "$config"
land_pick_default_port() { echo 31081; }
local_policy_attach "$config"
[[ $RELAY_SOCKS == 31081 ]] || fail 'policy socket collided with a public inbound'
HY2_ENABLED=0 ANYTLS_ENABLED=1
xray_inbound_needed || fail 'sing-box-only installation bypasses Xray'
echo 'ok optional protocols require the same loopback-only TCP/UDP policy gateway'

TMP_DIR="$work/tmp"; mkdir -p "$TMP_DIR"
before=$(sha256sum "$config")
# A fresh shell keeps the real downloader and the script's readonly globals intact.
if bash -c '
  source ./proxy.sh
  trap - ERR INT TERM
  TMP_DIR=$1 CN_DATA_REFRESH=1
  gh_latest_tag() { echo fixture; }
  fetch() { return 1; }
  cn_policy_inject "$2"
' _ "$TMP_DIR" "$config" >"$work/fetch.log" 2>&1; then fail 'missing rules were silently ignored'; fi
[[ $before == "$(sha256sum "$config")" ]] || fail 'failed data fetch modified config'
echo 'ok missing geography data aborts before replacing policy configuration'
