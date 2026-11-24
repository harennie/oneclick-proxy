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
  unset TEST_RESULTS_FILE TEST_CATALOG TEST_SCAN_HOSTS TEST_SCAN_FAIL
  TMP_DIR="$work/$1"
  mkdir -p "$TMP_DIR"
  OPT_AUTO=0 OPT_SNI="" OPT_SCAN=0 NAT_MODE=0 SNI=""
  GEO_CC=US GEO_REGION="" GEO_CITY="" GEO_ORG=""
  TEST_RESULT='PASS|manual.example.com|10|20|192.0.2.1|US|Test|AS1|Y|4000'
  TEST_RC=0
}
mktmp() { :; }
load_cf_ranges() { :; }
cert_resolved_ips() { printf '%s' 192.0.2.1; }
cert_ip_ours() { printf '%s' 192.0.2.3; }
confirm() { fail 'SNI 检测不通过时不应要求确认'; }
scanner_collect() { fail '不应执行扫描'; }
ask() {
  local reply
  printf '%s\n' "$2" >>"$TMP_DIR/prompts"
  IFS= read -r reply <&3 || fail '出现了多余的交互提示'
  printf -v "$1" '%s' "${reply:-${3-}}"
}
sni_probe() {
  printf '%s\n' "$1" >>"$TMP_DIR/probes"
  local line result
  line=$(wc -l <"$TMP_DIR/probes")
  if [[ -s ${TEST_RESULTS_FILE:-} ]]; then result=$(sed -n "${line}p" "$TEST_RESULTS_FILE")
  else result=$TEST_RESULT; fi
  printf '%s\n' "$result"
  return "$TEST_RC"
}
sni_region_keys() { printf 'TEST|'; }
sni_candidates() { if [[ $1 == TEST ]]; then printf 'best.example.com\n'; fi; }

sni_catalog >"$work/catalog"
awk -F'|' 'NF != 3 || $1 !~ /^[A-Z][A-Z]$/ || seen[$1]++ { exit 1 }' "$work/catalog" || fail '全球候选库有重复或无效国家代码'
[[ $(wc -l <"$work/catalog") -eq 249 ]] || fail '全球候选库未包含全部 ISO 3166-1 条目'
grep -q '^KE|014|[^ ]' "$work/catalog" || fail '全球候选库缺少肯尼亚的本地条目'
grep -q '^PE|005|[^ ]' "$work/catalog" || fail '全球候选库缺少秘鲁的本地条目'
sni_catalog() { printf '%s\n' "${TEST_CATALOG:-}"; }
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
select_sni 3<<<$'manual.example.com\n2' >"$TMP_DIR/log" 2>&1
[[ $SNI == manual.example.com ]] || fail '检测不通过阻止了手填选择'
grep -q '不支持 ALPN h2' "$TMP_DIR/log" || fail '未说明检测失败原因'
grep -q '1) 重新填写  2) 继续使用 manual.example.com' "$TMP_DIR/prompts" || fail '未提供重填/继续选择'
printf 'ok failed checks offer re-entry or continue\n'

setup_case retry
TEST_RESULTS_FILE="$TMP_DIR/results"
printf '%s\n' 'FAIL|manual.example.com|证书链/域名校验失败' 'PASS|second.example.com|10|20|192.0.2.1|US|Test|AS1|Y|4000' >"$TEST_RESULTS_FILE"
select_sni 3<<<$'manual.example.com\n1\nsecond.example.com' >"$TMP_DIR/log" 2>&1
[[ $SNI == second.example.com ]] || fail '选择重填没有重新检测新域名'
[[ $(wc -l <"$TMP_DIR/probes") == 2 ]] || fail '重填后的域名未重新检测'
printf 'ok choosing re-entry checks the new SNI\n'

setup_case no_result
TEST_RESULT="" TEST_RC=1
select_sni 3<<<$'manual.example.com\n2' >"$TMP_DIR/log" 2>&1
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
select_sni 3<<<$'\nm\nother.example.com\n2' >"$TMP_DIR/log" 2>&1
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
menu_change_sni 3<<<$'manual.example.com\n2' >"$TMP_DIR/log" 2>&1
[[ $SNI == manual.example.com && $(cat "$TMP_DIR/applied") == manual.example.com:443 ]] || fail '安装后更换 SNI 未应用手填域名'
printf 'ok installed-node SNI changes use the same manual flow\n'

setup_case menu_blank
SNI=old.example.com
menu_change_sni 3<<<$'\n1' >"$TMP_DIR/log"
[[ $SNI == best.example.com && $(cat "$TMP_DIR/applied") == best.example.com:443 ]] || fail '安装后留空更换没有进入优选'
printf 'ok installed-node blank input selects and applies a candidate\n'

sni_region_keys() { printf '|'; }
sni_test_list() {
  local output=$1 host country
  shift
  : >"$output"
  for host in "$@"; do
    country=KE
    printf '%s\n' "$host" >>"$TMP_DIR/tested"
    case $host in
      bad*) printf 'FAIL|%s|test failure\n' "$host" >>"$output"; continue ;;
      *.tz.example) country=TZ ;;
      *.ug.example) country=UG ;;
      *.fr.example) country=FR ;;
    esac
    printf 'PASS|%s|10|20|192.0.2.2|%s|Test|AS1|Y|4000\n' "$host" "$country" >>"$output"
  done
}

setup_case local_catalog
OPT_AUTO=1 GEO_CC=KE
TEST_CATALOG=$'KE|014|k1.example k2.example k3.example k4.example k5.example k6.example k7.example\nTZ|014|t1.tz.example\nFR|155|f1.fr.example'
select_sni >"$TMP_DIR/log"
[[ $SNI == k1.example && $(wc -l <"$TMP_DIR/tested") -eq 6 ]] || fail '本国满六个候选后仍扩大探测'
grep -q '其中 6 个的 IP 位于 KE' "$TMP_DIR/log" || fail '未报告本国通过数'
printf 'ok global catalog uses six local results before expanding\n'

setup_case nearby_catalog
OPT_AUTO=1 GEO_CC=KE
TEST_CATALOG=$'KE|014|k1.example k2.example k3.example\nTZ|014|k1.example t1.tz.example t2.tz.example\nUG|014|u1.ug.example u2.ug.example\nFR|155|f1.fr.example'
select_sni >"$TMP_DIR/log"
[[ $(cat "$TMP_DIR/tested") == $'k1.example\nk2.example\nk3.example\nu1.ug.example\nt1.tz.example\nu2.ug.example\nt2.tz.example' ]] ||
  fail '本国只有三个时应继续扩选，且邻区轮询应跳过重复域名'
printf 'ok nearby catalog interleaves countries and deduplicates names\n'

setup_case empty_country
OPT_AUTO=1 GEO_CC=KE
TEST_CATALOG=$'KE|014|\nTZ|014|t1.tz.example\nFR|155|f1.fr.example'
select_sni >"$TMP_DIR/log"
[[ $(cat "$TMP_DIR/tested") == $'t1.tz.example\nf1.fr.example' ]] || fail '空本国池应该先用邻区再使用全球池'
printf 'ok an empty catalog entry still has regional and global fallback\n'

scanner_collect() {
  printf 'scan\n' >>"$TMP_DIR/scans"
  [[ ${TEST_SCAN_FAIL:-0} != 1 ]] || return 1
  printf '%s\n' "${TEST_SCAN_HOSTS:-$'k1.example\nscanned.tz.example'}" >"$1"
}
setup_case scan_catalog
OPT_AUTO=1 OPT_SCAN=1 GEO_CC=KE
TEST_CATALOG='KE|014|k1.example k2.example k3.example k4.example k5.example k6.example'
select_sni >"$TMP_DIR/log"
[[ $(grep -c '^k1.example$' "$TMP_DIR/tested") -eq 1 && $(wc -l <"$TMP_DIR/tested") -eq 7 ]] ||
  fail '扫描只有少量结果时应保留结果，再补充本国候选'
printf 'ok a partial scan preserves results and continues into the catalog\n'

setup_case scanner_pick
GEO_CC=KE SNI=old.example.com
TEST_CATALOG='KE|014|k1.example k2.example'
TEST_SCAN_HOSTS=scanned.tz.example
menu_change_sni 3<<<$'\ns\n1' >"$TMP_DIR/log"
[[ $(cat "$TMP_DIR/tested") == $'k1.example\nk2.example\nscanned.tz.example' ]] || fail '交互模式应先探测自动池再扫描'
[[ $SNI == scanned.tz.example && $(cat "$TMP_DIR/applied") == scanned.tz.example:443 ]] || fail '扫描结果没有通过菜单生效'
grep -q 's 扫描器优选' "$TMP_DIR/prompts" || fail '自动结果页缺少扫描入口'
grep -q 'a 返回自动优选' "$TMP_DIR/prompts" || fail '扫描结果页缺少返回入口'
printf 'ok installed-node menu offers scanning after automatic results\n'

setup_case scanner_navigation
GEO_CC=KE
TEST_CATALOG='KE|014|k1.example'
TEST_SCAN_HOSTS=scanned.tz.example
select_sni 3<<<$'\ns\na\ns\nm\n\n1' >"$TMP_DIR/log"
[[ $SNI == k1.example && $(cat "$TMP_DIR/scans") == scan ]] || fail '来回切换时应保留两份检测结果'
[[ $(cat "$TMP_DIR/tested") == $'k1.example\nscanned.tz.example' ]] || fail '返回结果页重复探测了候选'
printf 'ok both result pages are reused and blank manual input returns to automatic results\n'

setup_case scanner_manual
GEO_CC=KE
TEST_CATALOG='KE|014|k1.example'
TEST_SCAN_HOSTS=scanned.tz.example
select_sni 3<<<$'\ns\nm\nmanual.example.com' >"$TMP_DIR/log"
[[ $SNI == manual.example.com && $(cat "$TMP_DIR/probes") == manual.example.com ]] || fail '从扫描结果页手填时没有验证并选择域名'
printf 'ok scanner results allow manual entry\n'

setup_case scanner_failed
GEO_CC=KE TEST_SCAN_FAIL=1
TEST_CATALOG='KE|014|k1.example'
select_sni 3<<<$'\ns\na\n1' >"$TMP_DIR/log"
[[ $SNI == k1.example && $(cat "$TMP_DIR/scans") == scan ]] || fail '扫描失败后无法返回已有的自动结果'
printf 'ok scanner failure still allows returning to automatic results\n'

setup_case auto_empty
GEO_CC=KE
TEST_CATALOG='KE|014|bad-auto.example'
TEST_SCAN_HOSTS=scanned.tz.example
select_sni 3<<<$'\ns\n1' >"$TMP_DIR/log"
[[ $SNI == scanned.tz.example ]] || fail '没有自动候选时应仍能选择扫描'
printf 'ok an empty automatic result still offers scanning\n'

setup_case scanner_default
GEO_CC=KE OPT_SCAN=1
TEST_CATALOG='KE|014|k1.example'
TEST_SCAN_HOSTS=scanned.tz.example
select_sni 3<<<$'\n\n1' >"$TMP_DIR/log"
[[ $SNI == scanned.tz.example && $(cat "$TMP_DIR/tested") == $'k1.example\nscanned.tz.example' ]] ||
  fail '交互式 --scan 应先显示自动结果，再默认进入扫描'
printf 'ok interactive --scan sets the first automatic result page default\n'

setup_case scanner_nat
GEO_CC=KE NAT_MODE=1
TEST_CATALOG='KE|014|k1.example'
select_sni 3<<<$'\ns\n1' >"$TMP_DIR/log"
[[ $SNI == k1.example && ! -f $TMP_DIR/scans ]] || fail 'NAT 模式不应执行扫描'
if grep -q 's 扫描器优选' "$TMP_DIR/prompts"; then fail 'NAT 模式不应提供扫描入口'; fi
printf 'ok NAT selection omits the scanner action\n'

setup_case nat_budget
OPT_AUTO=1 NAT_MODE=1 GEO_CC=KE
printf -v local_hosts 'bad%d.example ' {1..18}
printf -v near_hosts 'bad%d.tz.example ' {1..16}
printf -v world_hosts 'f%d.fr.example ' {1..16}
TEST_CATALOG=$(printf 'KE|014|%s\nTZ|014|%s\nFR|155|%s\n' "$local_hosts" "$near_hosts" "$world_hosts")
select_sni >"$TMP_DIR/log"
[[ $(wc -l <"$TMP_DIR/tested") -eq 24 ]] || fail 'NAT 模式应遵守 24 个候选的总预算'
[[ $(grep -c '^f' "$TMP_DIR/tested") -eq 6 ]] || fail 'NAT 模式应为全球候选保留探测名额'
printf 'ok NAT probe budget reserves space for global fallback\n'
