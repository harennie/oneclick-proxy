#!/usr/bin/env bash
# 不安装服务、不访问网络；覆盖 NAT 落地端口与菜单 22 的启停流程。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./proxy.sh
trap - ERR INT TERM

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

NAT_MODE=1 LAND_MODE=0 LAND_IN=1
REALITY_ENABLED=1 XRAY_PORT=1443 XRAY_EXT_PORT=20443
HY2_ENABLED=0 XHTTP_ENABLED=0 TROJAN_ENABLED=0 ANYTLS_ENABLED=0 TUIC_ENABLED=0
NAT_PORTS=20443:1443,20444:8388,20445:8389
NAT_EXCLUDE=20444
land_seed_used_ports
[[ $(land_nat_first_both) == 20445 ]] || fail '推荐了已排除的映射端口'
NAT_EXCLUDE='20444 20445'
if land_nat_first_both >/dev/null; then fail '全部占用或排除时应返回无可用端口'; fi
printf 'ok NAT landing defaults skip excluded ports\n'

NAT_EXCLUDE=''
NAT_PORTS=20443:1443,20444:1443,20445:8389
[[ $(land_nat_first_both) == 20445 ]] || fail '推荐的映射内部端口与 Reality 冲突'
printf 'ok NAT landing defaults skip internal port conflicts\n'
(
  OPT_AUTO=1 OPT_LAND_PORT='' LAND_EXT_PORT=20444
  check_port_free() { return 0; }
  land_choose_node_port_nat >"$work/saved.log"
  [[ $LAND_EXT_PORT == 20445 ]] || fail '保留的旧端口冲突时没有重新选择'
)
printf 'ok stale saved landing ports fall back to a usable mapping\n'

HY2_ENABLED=1 HOP_RANGE='8388-8389,9000'
for p in 8388 8389 9000; do
  land_reserved_port "$p" || fail '落地端口不能使用 Hysteria2 跳跃端口'
done
if land_nat_first_both >/dev/null; then fail '跳跃范围内的 UDP 映射不能给落地入站'; fi
HY2_ENABLED=0 HOP_RANGE=''
printf 'ok landing ports cannot be redirected into Hysteria2 hopping\n'

OPT_PORT=20443:1443 OPT_LAND_PORT=20444:8388
[[ $(nat_ports_from_opts) == 20443:1443,20444:8388 ]] || fail '--land-port 未加入推导的 NAT 映射'
printf 'ok NAT mappings include --land-port\n'

# 只屏蔽系统写入和网络探测，保留菜单、端口选择、JSON 注入及 OpenRC 服务分派。
load_state() { :; }
need_installed() { :; }
detect_os() { OS_ID=alpine PKG=apk INIT_SYS=openrc; }
detect_virt() { VIRT=lxc; }
ensure_outbound_ip() { OUTBOUND_EFFECTIVE=4; }
save_state() { printf '%s\n' "$LAND_IN" >"$work/state"; }
save_info() { :; }
land_fwd_remove() { :; }
apply_firewall() { :; }
land_print_links() { :; }
land_selftest() { :; }
write_xray_service() {
  printf 'service\n' >>"$work/calls"
  if xray_need_cap; then printf 'bind-cap\n' >>"$work/calls"; fi
}
write_xray_config() {
  printf 'config\n' >>"$work/calls"
  jq -n '{inbounds:[], outbounds:[{tag:"direct",protocol:"freedom"}],routing:{rules:[]}}' >"$work/config.json"
  land_in_attach "$work/config.json"
}
sd_reload() { :; }
svc_enable() { :; }
svc_active() { return 0; }
rc-service() { printf 'openrc:%s\n' "$*" >>"$work/calls"; }
systemctl() { fail 'Alpine 不能调用 systemctl'; }
sleep() { :; }
ask() {
  local reply
  IFS= read -r reply <&3 || fail '出现了多余的提示'
  printf -v "$1" '%s' "${reply:-${3-}}"
}

OPT_AUTO=0 OPT_LAND_PORT='' OPT_LAND_METHOD='' OPT_LAND_ALLOW=''
PKG='' VIRT='' INIT_SYS=''
NAT_PORTS=20443:1443,20444:80,20445:8389 NAT_EXCLUDE=''
LAND_IN=0 LAND_KEY='' LAND_PORT='' LAND_EXT_PORT=''
menu_land_in 3<<<$'1\n1\n203.0.113.10\n\n' >"$work/menu.log"
[[ $LAND_IN == 1 && $LAND_PORT == 80 && $LAND_EXT_PORT == 20444 ]] || fail '菜单 22 未启用 NAT 落地入站'
grep -qx 1 "$work/state" || fail '落地开关未保存'
jq -e '.inbounds[] | select(.tag=="ss-in") | .port==80' "$work/config.json" >/dev/null || fail '未生成 ss-in'
[[ $(head -n2 "$work/calls") == $'service\nbind-cap' ]] || fail '写配置前未刷新低端口所需的服务权限'
grep -qx 'openrc:xray restart' "$work/calls" || fail '未使用 OpenRC 重启'
printf 'ok Alpine menu 22 enables landing with low-port capabilities\n'

OPT_AUTO=1 OPT_LAND_PORT=20445
land_menu_port >"$work/port.log"
[[ $LAND_PORT == 8389 && $LAND_EXT_PORT == 20445 ]] || fail '修改落地端口未生效'
jq -e '.inbounds[] | select(.tag=="ss-in") | .port==8389' "$work/config.json" >/dev/null || fail '修改端口后 ss-in 不正确'
land_disable >"$work/disable.log"
[[ $LAND_IN == 0 && -n $LAND_KEY ]] || fail '停用落地入站应保留密钥'
jq -e '.inbounds | length==0' "$work/config.json" >/dev/null || fail '停用后仍有 ss-in'
printf 'ok NAT landing port changes and disable preserve keys\n'

NAT_PORTS=20443:1443 LAND_EXT_PORT='' OPT_LAND_PORT=''
if ( land_enable ) >"$work/no-port.log" 2>&1; then fail '没有额外映射时不应启用'; fi
grep -q 'proxy nat' "$work/no-port.log" || fail '缺少登记服务商映射的提示'
grep -qx 0 "$work/state" || fail '端口不足时不应改写已保存的开关'
printf 'ok missing mappings report the next step without saving changes\n'
