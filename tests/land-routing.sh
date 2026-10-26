#!/usr/bin/env bash
# 不装服务。检查：旧落地机状态仍是纯落地；节点上的 ss-in 不会掉进 land-add 兜底。
set -euo pipefail
cd "$(dirname "$0")/.."
bash build.sh >/dev/null
# shellcheck disable=SC1091
source ./proxy.sh
trap - ERR INT TERM

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

reset_opts() {
  OPT_LAND="" OPT_WITH_LAND="" OPT_REALITY="" OPT_HY2="" OPT_XHTTP="" OPT_TROJAN=""
  OPT_TUIC="" OPT_ANYTLS="" OPT_XHTTP_TLS="" OPT_WS=""
  OPT_ACTION="" OPT_AUTO=0 OPT_LAND_PORT="" OPT_PORT="" OPT_LAND_ACT="" OPT_LAND_LINK=""
  LAND_MODE=0 LAND_IN=0
  OPT_OWN_SNI="" OPT_SNI="" SELF_SNI=0
}

if [[ $SCRIPT_VERSION != 1.7.0 ]]; then fail "SCRIPT_VERSION=$SCRIPT_VERSION"; fi
usage | grep -q -- '--with-land' || fail "help missing --with-land"
usage | grep -q -- 'land-enable' || fail "help missing land-enable"
usage | grep -q -- 'land-next' || fail "help missing land-next"

unset LAND_IN
LAND_MODE=1
if ! land_only || ! land_ss_on || land_in_on; then fail "旧 state 没有 LAND_IN 时仍应是纯落地机"; fi
printf 'ok legacy land-only\n'

LAND_MODE=0
LAND_IN=1
if land_only || ! land_in_on || ! land_ss_on; then fail "LAND_IN=1 应是节点上的落地入站"; fi
printf 'ok dual flags\n'

reset_opts
OPT_LAND=1
if ! installing_land_only || install_wants_land_in; then fail "单独 --land 必须仍是纯落地安装"; fi
printf 'ok pure --land\n'

reset_opts
OPT_LAND=1
OPT_HY2=0
if ! installing_land_only; then fail "--no-hy2 不能把 --land 变成节点"; fi
printf 'ok --land --no-hy2\n'

reset_opts
OPT_LAND=1
OPT_REALITY=1
if installing_land_only || ! install_wants_land_in; then fail "--land --reality 应同时装节点和落地入站"; fi
printf 'ok --land --reality\n'

reset_opts
OPT_WITH_LAND=1
if installing_land_only || ! install_wants_land_in; then fail "--with-land 应走节点安装"; fi
printf 'ok --with-land\n'

reset_opts
LAND_MODE=1
unset LAND_IN
if ! installing_land_only; then fail "已有纯落地机重装应保持纯落地"; fi
printf 'ok existing land reinstall\n'

reset_opts
LAND_MODE=1
OPT_LAND=0
if installing_land_only || install_wants_land_in; then fail "--no-land 应改装为节点并关掉落地入站"; fi
printf 'ok --no-land\n'

reset_opts
LAND_IN=1
if ! install_wants_land_in; then fail "重装已有落地入站的节点应保留 LAND_IN"; fi
OPT_WITH_LAND=0
if install_wants_land_in; then fail "--no-with-land 应关掉落地入站"; fi
printf 'ok reinstall keeps or clears LAND_IN\n'

reset_opts
parse_args --land --auto
if [[ $OPT_ACTION != install || $OPT_LAND != 1 ]] || ! installing_land_only; then fail "parse --land --auto"; fi
printf 'ok parse --land --auto\n'

# 自有 SNI 只在显式参数时进入专用分支；参数解析不应混入普通 --sni。
reset_opts
parse_args --own-sni node.example.com --auto
if [[ $OPT_OWN_SNI != node.example.com || $OPT_AUTO != 1 || -n $OPT_SNI ]]; then
  fail "parse --own-sni"
fi
printf 'ok parse --own-sni\n'

reset_opts
parse_args --own-sni=https://NODE.example.com/path
if [[ $OPT_OWN_SNI != node.example.com || $OPT_ACTION != install ]]; then fail "normalize --own-sni URL"; fi
printf 'ok normalize --own-sni URL\n'

(
  NAT_MODE=0 INIT_SYS=systemd REALITY_ENABLED=1 PUBLIC_IP4=203.0.113.2 PUBLIC_IP6=""
  OPT_SNI="" OPT_CERT=1 OPT_CERT_DOMAIN="" OPT_CERT_NAMES="" OPT_CERT_KIND=""
  OPT_CF_ORIGIN_KEY="" OPT_ZEROSSL_KID="" OPT_ZEROSSL_HMAC=""
  SELF_SNI=0 SNI_TARGET=127.0.0.1:9443
  cert_domain_points_here() { [[ $1 == node.example.com ]]; }
  cert_is_public() { return 0; }
  cert_current_ok() { return 0; }
  cert_name_covered() { return 0; }
  svc_active() { [[ $1 == proxy-oneclick-reality-site ]]; }
  port_in_use() { return 1; }
  select_self_sni https://NODE.example.com/path
  [[ $SELF_SNI == 1 && $SNI == node.example.com && $SNI_TARGET == 127.0.0.1:9443 && $MLDSA_ON == 0 ]]
) || fail "select self SNI"
printf 'ok select self SNI\n'

if ! usage | grep -q -- '--own-sni'; then fail "help missing --own-sni"; fi

reset_opts
parse_args --with-land --land-port 8388 --auto
if [[ $OPT_ACTION != install || $OPT_WITH_LAND != 1 || $OPT_LAND_PORT != 8388 ]] || ! install_wants_land_in; then
  fail "parse --with-land"
fi
printf 'ok parse --with-land\n'

reset_opts
parse_args land-enable --land-port=9399
if [[ $OPT_ACTION != land-enable || $OPT_LAND_PORT != 9399 ]]; then fail "parse land-enable"; fi
printf 'ok parse land-enable\n'

reset_opts
parse_args land-disable
if [[ $OPT_ACTION != land-disable ]]; then fail "parse land-disable"; fi
printf 'ok parse land-disable\n'

reset_opts
parse_args land-next 'ss://example'
if [[ $OPT_ACTION != land || $OPT_LAND_ACT != next || $OPT_LAND_LINK != ss://example ]]; then fail "parse land-next"; fi
printf 'ok parse land-next\n'

if ! export_host_key LAND_EXT_PORT; then fail "LAND_EXT_PORT 应随机器走，不进导出"; fi
if export_host_key LAND_PORT; then fail "LAND_PORT 应随配置导出"; fi
if export_host_key LAND_NEXT; then fail "LAND_NEXT 应随配置导出"; fi
printf 'ok export keys\n'

key=$(openssl rand -base64 16 | tr -d '\n')
key2=$(openssl rand -base64 16 | tr -d '\n')
key3=$(openssl rand -base64 16 | tr -d '\n')
land_key_ok 2022-blake3-aes-128-gcm "$key" || fail "测试密钥长度不对"
NODE_NAME=node
REALITY_ENABLED=1
XRAY_PORT=443
HY2_ENABLED=0
XHTTP_ENABLED=0
TROJAN_ENABLED=0
TUIC_ENABLED=0
ANYTLS_ENABLED=0
XHTTP_TLS_ENABLED=0
WS_ENABLED=0
LAND_MODE=0
LAND_IN=1
LAND_PORT=8388
LAND_METHOD=2022-blake3-aes-128-gcm
LAND_KEY=$key
LAND_ALLOW="203.0.113.10"
LAND_NEXT=""
LAND_NEXT_ON=0
FWD_ON=0
FWD_LINK=""
OUTBOUND_EFFECTIVE=64
RELAY_ON=1
RELAY_SOCKS=31080
RELAY_LINK=$(ss_link_build 2022-blake3-aes-128-gcm "$key2" 198.51.100.8 9000 relay)
HOP_RANGE=""
EXTRA_TCP=""
EXTRA_UDP=""
SUB_PORT=""

fw_collect_want
printf '%s\n' "$FW_WANT" | grep -qx 'tcp 8388' || fail "防火墙清单缺落地 TCP"
printf '%s\n' "$FW_WANT" | grep -qx 'udp 8388' || fail "防火墙清单缺落地 UDP"
printf '%s\n' "$FW_WANT" | grep -qx 'tcp 443' || fail "防火墙清单缺 Reality"
printf 'ok firewall want list\n'

dir=$(mktemp -d)
cfg="$dir/xray.json"
base_cfg() {
  jq -n '{
    inbounds: [{tag:"vless-reality", port:443, protocol:"vless"}],
    outbounds: [
      {tag:"direct", protocol:"freedom"},
      {tag:"block", protocol:"blackhole"}
    ],
    routing: {
      domainStrategy: "AsIs",
      rules: [
        {type:"field", ip:["geoip:private"], outboundTag:"block"},
        {type:"field", protocol:["bittorrent"], outboundTag:"block"}
      ]
    }
  }' >"$cfg"
}
assert_order() { # $1 ss-in 出口 tag
  local exit_tag=$1
  jq -e --arg exit "$exit_tag" '
    def first(pred): [to_entries[] | select(.value | pred) | .key][0];
    .routing.rules
    | (first(.protocol == ["bittorrent"])) as $bt
    | (first(.inboundTag == ["ss-in"] and .outboundTag == $exit)) as $allow
    | (first(.network == "tcp,udp" and (.inboundTag | not))) as $catch
    | ($bt != null and $allow != null and $catch != null and ($bt < $allow) and ($allow < $catch))
  ' "$cfg" >/dev/null || fail "ss-in 规则没有排在私网/BT 之后、land-add 兜底之前"
}

base_cfg
land_in_attach "$cfg"
relay_inject "$cfg"
xray_apply_ip_strategy "$cfg"
jq -e '.inbounds[] | select(.tag=="vless-reality") | .port == 443' "$cfg" >/dev/null || fail "Reality 入站丢了"
jq -e '.inbounds[] | select(.tag=="ss-in") | .port == 8388 and .protocol == "shadowsocks"' "$cfg" >/dev/null || fail "没有 ss-in"
jq -e '[.outbounds[].tag] | index("ss-out") | not' "$cfg" >/dev/null || fail "直连落地入站不应有 ss-out"
jq -e '.routing.domainStrategy == "UseIPv6v4"' "$cfg" >/dev/null || fail "routing.domainStrategy"
jq -e '.outbounds[] | select(.tag=="direct" and .protocol=="freedom") | .settings.domainStrategy == "UseIPv6v4"' "$cfg" >/dev/null || fail "direct domainStrategy"
jq -e '
  .routing.rules[] | select(.inboundTag == ["ss-in"] and .outboundTag == "direct")
  | (.source | index("127.0.0.1/32")) and (.source | index("::1/128")) and (.source | index("203.0.113.10"))
' "$cfg" >/dev/null || fail "白名单没有限制在 ss-in，或没带上回环"
jq -e '[.routing.rules[] | select(.source != null) | .inboundTag[0]] | unique == ["ss-in"]' "$cfg" >/dev/null || fail "白名单规则影响了其它入站"
assert_order direct
catch=$(jq -r '.routing.rules[] | select(.network=="tcp,udp" and (.inboundTag|not)) | .outboundTag' "$cfg")
[[ $catch == land-relay ]] || fail "兜底出站应是本机 land-add（$catch）"
printf 'ok direct ss-in stays off the node relay\n'

base_cfg
LAND_NEXT=$(ss_link_build 2022-blake3-aes-128-gcm "$key3" 192.0.2.9 7000 nexthop)
LAND_NEXT_ON=1
saved_relay=$RELAY_LINK
land_in_attach "$cfg"
relay_inject "$cfg"
xray_apply_ip_strategy "$cfg"
[[ $RELAY_LINK == "$saved_relay" ]] || fail "land-next 改写了 RELAY_LINK"
jq -e '.inbounds[] | select(.tag=="ss-in") | .port == 8388' "$cfg" >/dev/null || fail "加密下一跳仍应有 ss-in"
jq -e '
  .outbounds[] | select(.tag=="ss-out")
  | .settings.servers[0].address == "192.0.2.9"
    and .settings.servers[0].port == 7000
    and .streamSettings.sockopt.domainStrategy == "UseIPv6v4"
' "$cfg" >/dev/null || fail "ss-out 地址或 domainStrategy 不对"
jq -e '.routing.rules[] | select(.inboundTag==["ss-in"] and .source != null) | .outboundTag == "ss-out"' "$cfg" >/dev/null || fail "落地入站没有走到 ss-out"
assert_order ss-out
catch=$(jq -r '.routing.rules[] | select(.network=="tcp,udp" and (.inboundTag|not)) | .outboundTag' "$cfg")
[[ $catch == land-relay ]] || fail "节点 land-add 兜底被落地入站换掉了（$catch）"
printf 'ok land-next uses ss-out, land-add stays catch-all\n'

base_cfg
LAND_NEXT_ON=0
FWD_ON=1
FWD_LINK=$(ss_link_build 2022-blake3-aes-128-gcm "$key3" 192.0.2.20 8000 raw)
land_in_attach "$cfg"
jq -e '[.inbounds[].tag] | index("ss-in") | not' "$cfg" >/dev/null || fail "原样转发不应再写 ss-in"
jq -e '.inbounds[] | select(.tag=="vless-reality")' "$cfg" >/dev/null || fail "原样转发不应拿掉 Reality"
printf 'ok raw forward omits ss-in\n'

base_cfg
FWD_ON=0
FWD_LINK=""
LAND_NEXT_ON=1
LAND_NEXT='ss://not-a-link'
if ( trap - ERR; land_in_attach "$cfg" ) >/dev/null 2>&1; then fail "坏掉的下一跳不应按直连生成"; fi
printf 'ok bad land-next is rejected\n'

# 回归：守卫函数在节点上不能返回非零。脚本开着 set -e，它作为独立命令调用时
# 返回 1 会直接终止整个流程（land-enable / land-disable 都被它带崩过）。
need_installed() { :; }
LAND_MODE=0 LAND_IN=0
need_node || fail "need_node 在节点上不应返回非零"
printf 'ok need_node returns 0 on a node\n'

# 回归：端口种子函数在没有证书时必须返回 0，否则 land-enable 会在选端口前退出。
LAND_MODE=0 LAND_IN=0 NAT_MODE=0 CERT_ON=0
land_seed_used_ports || fail "land_seed_used_ports 在无证书时应返回 0"
printf 'ok land_seed_used_ports returns 0 without cert\n'

rm -rf "$dir"
printf 'ok land routing\n'
