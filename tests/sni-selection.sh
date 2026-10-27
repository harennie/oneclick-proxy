#!/usr/bin/env bash
# 不安装服务、不访问网络；检查手填、留空优选和安装后的更换入口。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./proxy.sh
trap - ERR INT TERM

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

setup_case() {
  TMP_DIR="$work/$1"
  mkdir -p "$TMP_DIR"
  OPT_AUTO=0 OPT_SNI="" OPT_SCAN=0 NAT_MODE=0 SNI=""
  GEO_CC=US GEO_REGION="" GEO_CITY="" GEO_ORG=""
  TEST_RESULT='PASS|manual.example.com|10|20|192.0.2.1|US|Test|AS1|Y|4000'
  TEST_RC=0
}
mktmp() { :; }
load_cf_ranges() { :; }
confirm() { fail 'SNI 检测不通过时不应要求确认'; }
ask() {
  local reply
  printf '%s\n' "$2" >>"$TMP_DIR/prompts"
  IFS= read -r reply <&3 || fail '出现了多余的交互提示'
  printf -v "$1" '%s' "$reply"
}
sni_probe() {
  printf '%s\n' "$1" >>"$TMP_DIR/probes"
  printf '%s\n' "$TEST_RESULT"
  return "$TEST_RC"
}
sni_region_keys() { printf 'TEST|'; }
sni_candidates() { printf 'best.example.com'; }
sni_test_list() {
  printf 'PASS|best.example.com|10|20|192.0.2.2|US|Test|AS1|Y|4000\n' >"$1"
}

setup_case manual
select_sni 3<<<'  HTTPS://MANUAL.EXAMPLE.COM./path  ' >"$TMP_DIR/log"
[[ $SNI == manual.example.com ]] || fail '手填域名未正常写入'
[[ $(cat "$TMP_DIR/probes") == manual.example.com ]] || fail '手填域名没有使用原有检测'
[[ $(wc -l <"$TMP_DIR/probes") == 1 ]] || fail '手填域名重复检测'
grep -q '通过检测' "$TMP_DIR/log" || fail '缺少检测成功提示'
printf 'ok manual SNI is normalized and checked\n'

setup_case warning
TEST_RESULT='FAIL|manual.example.com|不支持 ALPN h2'
TEST_RC=1
select_sni 3<<<'manual.example.com' >"$TMP_DIR/log" 2>&1
[[ $SNI == manual.example.com ]] || fail '检测不通过阻止了手填选择'
grep -q '不支持 ALPN h2' "$TMP_DIR/log" || fail '未说明检测失败原因'
grep -q '仍使用此 SNI' "$TMP_DIR/log" || fail '未提示继续使用'
printf 'ok failed checks warn and keep the chosen SNI\n'

setup_case no_result
TEST_RESULT="" TEST_RC=1
select_sni 3<<<'manual.example.com' >"$TMP_DIR/log" 2>&1
[[ $SNI == manual.example.com ]] || fail '探测错误阻止了手填选择'
grep -q '未得到检测结果' "$TMP_DIR/log" || fail '探测错误未提示'
printf 'ok probe errors warn without discarding the SNI\n'

setup_case blank
select_sni 3<<<$'\n1' >"$TMP_DIR/log"
[[ $SNI == best.example.com ]] || fail '留空没有进入原有自动优选'
[[ $(wc -l <"$TMP_DIR/prompts") == 2 ]] || fail '留空优选流程提示不正确'
printf 'ok blank input enters the original candidate selection\n'

setup_case candidate_manual
TEST_RESULT='FAIL|other.example.com|证书链/域名校验失败'
select_sni 3<<<$'\nm\nother.example.com' >"$TMP_DIR/log" 2>&1
[[ $SNI == other.example.com ]] || fail '候选列表中的手填入口未继续使用不合格域名'
printf 'ok candidate manual override uses the same warning policy\n'

setup_case auto
OPT_AUTO=1
select_sni >"$TMP_DIR/log"
[[ $SNI == best.example.com && ! -f $TMP_DIR/prompts ]] || fail '自动模式不应等待输入'
printf 'ok unattended automatic selection is preserved\n'

setup_case cli
parse_args --auto --sni manual.example.com --force-sni
TEST_RESULT='FAIL|manual.example.com|无 IPv4 解析'
select_sni >"$TMP_DIR/log" 2>&1
[[ $SNI == manual.example.com && ! -f $TMP_DIR/prompts ]] || fail '--sni 应警告后继续且不要求 --force-sni'
printf 'ok explicit --sni warns and continues in auto mode\n'

# 使用真正的菜单函数，屏蔽服务与密钥操作。
need_node() { :; }
detect_ip() { PUBLIC_IP4=192.0.2.3; }
detect_geo() { :; }
mldsa_decide() { :; }
apply_all() { printf '%s\n' "$SNI_TARGET" >"$TMP_DIR/applied"; }
reality_selftest() { :; }
tls_present_real() { return 1; }
show_info() { :; }

setup_case menu_manual
SNI=old.example.com
TEST_RESULT='FAIL|manual.example.com|不支持 ALPN h2'
menu_change_sni 3<<<'manual.example.com' >"$TMP_DIR/log" 2>&1
[[ $SNI == manual.example.com && $(cat "$TMP_DIR/applied") == manual.example.com:443 ]] || fail '安装后更换 SNI 未应用手填域名'
printf 'ok installed-node SNI changes use the same manual flow\n'

setup_case menu_blank
SNI=old.example.com
menu_change_sni 3<<<$'\n1' >"$TMP_DIR/log"
[[ $SNI == best.example.com && $(cat "$TMP_DIR/applied") == best.example.com:443 ]] || fail '安装后留空更换没有进入优选'
printf 'ok installed-node blank input selects and applies a candidate\n'
