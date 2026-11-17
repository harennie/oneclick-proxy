#!/usr/bin/env bash
# 只使用临时证书、替身命令和临时客户端，不访问网络、不管理正式服务。
# Fixtures provide globals and callbacks consumed by the sourced modules.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source src/cert.sh
# shellcheck disable=SC1091
source src/selftest.sh
# shellcheck disable=SC1091
source src/doctor.sh
# shellcheck disable=SC1091
source src/cli.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL $*" >&2; exit 1; }
warn() { echo "WARN $*"; }
info() { echo "INFO $*"; }
ok() { echo "OK $*"; }
have() { command -v "$1" >/dev/null 2>&1; }
UUID=00000000-0000-4000-8000-000000000001 PUB_KEY=fake SHORT_ID=abcd
SNI=node.example.test XHTTP_PATH=/test HY2_PASS=fake-hy-pass TUIC_PASS=fake-tuic-pass ANYTLS_PASS=fake-any-pass
HY_CRT="$work/hy.crt" SB_CRT="$work/sb.crt" HY2_PIN=AB:CD
CERT_ON=0 CERT_PUBLIC=1 CERT_CA=letsencrypt CERT_DOMAIN=cert.example.test
pqv_active() { return 1; }
for kind in reality xhttp hy2 tuic anytls; do
  selftest_client_config "$kind" 30000 443 "$work/$kind.json"
  jq -e . "$work/$kind.json" >/dev/null || fail "$kind client JSON"
  [[ $(stat -c %a "$work/$kind.json") == 600 ]] || fail "$kind config permissions"
done
jq -e '.outbounds[0].streamSettings.network == "raw" and .outbounds[0].settings.vnext[0].users[0].flow == "xtls-rprx-vision"' "$work/reality.json" >/dev/null
jq -e '.outbounds[0].streamSettings.xhttpSettings.mode == "stream-one"' "$work/xhttp.json" >/dev/null
jq -e --arg ca "$HY_CRT" '.tls.ca == $ca and .tls.insecure == false and .tls.pinSHA256 == "AB:CD" and .auth == "fake-hy-pass"' "$work/hy2.json" >/dev/null
jq -e --arg ca "$SB_CRT" '.outbounds[0].type == "tuic" and .outbounds[0].tls.certificate_path == $ca and .outbounds[0].tls.alpn == ["h3"]' "$work/tuic.json" >/dev/null
jq -e '.outbounds[0].type == "anytls" and .outbounds[0].password == "fake-any-pass"' "$work/anytls.json" >/dev/null
CERT_ON=1 CERT_FULLCHAIN="$work/cert.pem" CERT_PRIVKEY="$work/key.pem"
touch "$CERT_FULLCHAIN" "$CERT_PRIVKEY"; printf x >"$CERT_FULLCHAIN"; printf x >"$CERT_PRIVKEY"
selftest_client_config hy2 30000 443 "$work/public.json"
jq -e '.tls.sni == "cert.example.test" and .tls.insecure == false and (.tls|has("ca")|not) and (.tls|has("pinSHA256")|not)' "$work/public.json" >/dev/null
echo 'ok five client configs, private credentials, and public/self-signed TLS'

port_in_use() { return 0; }
if selftest_socks_port 443 >/dev/null; then fail 'occupied temporary ports accepted'; fi
selftest_urls() { echo https://test.example/generate_204; }
port_in_use() { [[ -f $work/pid ]]; }
MOCK_CURL_MODE=ok
MOCK_RELAY=0
relay_active() { [[ $MOCK_RELAY == 1 ]]; }
relay_tag() { echo fixture-relay; }
curl() {
  if [[ " $* " == *' --socks5-hostname '* ]]; then
    [[ $1 == --noproxy && $2 == '' ]] || fail 'proxy test may be bypassed by NO_PROXY'
    if [[ $MOCK_CURL_MODE == ok ]]; then
      if [[ ${!#} == https://api64.ipify.org ]]; then printf 198.51.100.10; else printf 204; fi
      return 0
    fi
  elif [[ $MOCK_CURL_MODE == direct ]]; then printf 204; return 0
  fi
  return 1
}
for mode in ok direct offline relay; do
  MOCK_CURL_MODE=$mode
  if [[ $mode == relay ]]; then MOCK_RELAY=1 MOCK_CURL_MODE=ok; else MOCK_RELAY=0; fi
  dir=$(mktemp -d "$work/client.XXXXXX")
  rc=0
  # shellcheck disable=SC2016
  selftest_probe "$dir" 30000 reality bash -c 'echo $$ > "$1"; exec sleep 60' sh "$work/pid" >"$work/$mode.log" || rc=$?
  case $mode in ok|relay) expected=0 ;; direct) expected=1 ;; offline) expected=2 ;; esac
  [[ $rc == "$expected" && ! -d $dir ]] || fail "$mode result or cleanup"
  if kill -0 "$(cat "$work/pid")" 2>/dev/null; then fail 'temporary client leaked'; fi
  if [[ $mode == relay ]]; then grep -q '198.51.100.10' "$work/$mode.log" || fail 'relay egress report lost'; fi
  rm "$work/pid"
done
echo 'ok handshake failure vs offline state, occupied ports, NO_PROXY, and process cleanup'

ss() {
  case " $* " in
    *' -4 '*) return 0 ;;
    *' -6 '*) printf 'LISTEN 0 4096 *:443 *:* %s\n' "${V6ONLY:-v6only:0}" ;;
  esac
}
[[ $(doctor_listen_families tcp 443) == *'IPv4 双栈监听 / IPv6 已监听'* ]] || fail 'dual stack socket classified as v6 only'
V6ONLY=v6only:1
[[ $(doctor_listen_families tcp 443) == *'IPv4 未监听 / IPv6 已监听'* ]] || fail 'IPv6-only socket classified as dual stack'
V6ONLY=unknown
[[ $(doctor_listen_families tcp 443) == *'IPv4 未确认'* ]] || fail 'unknown socket declared IPv4 capable'
echo 'ok IPv4/IPv6 and unknown socket classification'

export MSYS_NO_PATHCONV=1
command openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout "$CERT_PRIVKEY" -out "$CERT_FULLCHAIN" -days 30 -subj /CN=cert.example.test -addext subjectAltName=DNS:cert.example.test >/dev/null 2>&1
cp "$CERT_FULLCHAIN" "$work/live.pem"
CERT_NAME=proxy-oneclick CERT_RENEW_CONF="$work/renew.conf" CERT_HOOK="$work/deploy.sh" CERT_CHALLENGE=http FW_MODE=strict NFT_TABLE=proxy_test
CERT_DNS_TOKEN="$work/token" CERT_DNS_AUTH="$work/auth.sh" CERT_DNS_CLEAN="$work/clean.sh" CERT_CRON="$work/daily"
HY2_ENABLED=1 TUIC_ENABLED=0 ANYTLS_ENABLED=0
TIMER_UP=1 PORT80_BUSY=0 READABLE=0 OPENRC=0
is_openrc() { [[ $OPENRC == 1 ]]; }
svc_exists() { return 0; }
svc_active() { [[ $1 == crond ]]; }
sb_needed() { return 1; }
cdn_wanted() { return 1; }
doctor_service_user() { echo fixture; }
doctor_files_readable() { return "$READABLE"; }
cert_expiry_text() { echo fixture-date; }
certbot() { fail 'doctor attempted a renewal'; }
systemctl() {
  case $1 in is-enabled|is-active) [[ $TIMER_UP == 1 ]] ;; *) fail "unexpected systemctl mutation: $1" ;; esac
}
nft() { echo 'tcp dport { 80, 443 } accept'; }
port_in_use() { [[ $2 == 80 && $PORT80_BUSY == 1 ]]; }
printf '#!/bin/sh\nexit 0\n' >"$CERT_HOOK"; chmod 755 "$CERT_HOOK"
printf 'authenticator = standalone\nfullchain = %s\ndeploy_hook = %s\n' "$work/live.pem" "$CERT_HOOK" >"$CERT_RENEW_CONF"
before=$(sha256sum "$CERT_FULLCHAIN" "$CERT_PRIVKEY" "$CERT_RENEW_CONF" "$CERT_HOOK")
DOCTOR_FAIL=0 DOCTOR_WARN=0
doctor_cert >"$work/cert-good.log"
[[ $DOCTOR_FAIL == 0 && $DOCTOR_WARN == 0 ]] || { cat "$work/cert-good.log"; fail 'healthy certificate rejected'; }
[[ $before == "$(sha256sum "$CERT_FULLCHAIN" "$CERT_PRIVKEY" "$CERT_RENEW_CONF" "$CERT_HOOK")" ]] || fail 'doctor modified certificate files'
TIMER_UP=0 PORT80_BUSY=1 READABLE=1
DOCTOR_FAIL=0 DOCTOR_WARN=0
doctor_cert >"$work/cert-bad.log"
[[ $DOCTOR_FAIL == 1 && $DOCTOR_WARN -ge 2 ]] || fail 'timer/port/permission failure missed'
grep -q 'timer' "$work/cert-bad.log"; grep -q '父目录权限' "$work/cert-bad.log"; grep -q 'TCP 80 已被占用' "$work/cert-bad.log"
READABLE=0 PORT80_BUSY=0 TIMER_UP=1
command openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "$work/wrong.key" >/dev/null 2>&1
saved_key=$CERT_PRIVKEY CERT_PRIVKEY="$work/wrong.key" DOCTOR_FAIL=0
doctor_cert >"$work/key.log"
[[ $DOCTOR_FAIL == 1 ]] || fail 'mismatched private key accepted'
CERT_PRIVKEY=$saved_key CERT_DOMAIN=wrong.example.test DOCTOR_FAIL=0
doctor_cert >"$work/name.log"
[[ $DOCTOR_FAIL == 1 ]] || fail 'wrong certificate hostname accepted'
CERT_DOMAIN=cert.example.test CERT_CHALLENGE=dns TIMER_UP=0 DOCTOR_FAIL=0 DOCTOR_WARN=0
doctor_cert >"$work/manual.log"
grep -q '手工 DNS 验证' "$work/manual.log"
if grep -q 'timer 未启用' "$work/manual.log"; then fail 'manual DNS falsely requires timer'; fi
CERT_CA=cloudflare CERT_PUBLIC=0 DOCTOR_WARN=0
doctor_cert >"$work/origin.log"
grep -q '源站证书不使用 ACME' "$work/origin.log"
[[ $DOCTOR_WARN == 0 ]] || fail 'origin certificate requires ACME renewal'
CERT_CA=letsencrypt CERT_PUBLIC=1 CERT_CHALLENGE=dns TIMER_UP=1
printf fixture-token >"$CERT_DNS_TOKEN"
cp "$CERT_HOOK" "$CERT_DNS_AUTH"; cp "$CERT_HOOK" "$CERT_DNS_CLEAN"
chmod 755 "$CERT_DNS_AUTH" "$CERT_DNS_CLEAN"
printf 'manual_auth_hook = %s\nmanual_cleanup_hook = %s\n' "$CERT_DNS_AUTH" "$CERT_DNS_CLEAN" >>"$CERT_RENEW_CONF"
OPENRC=1
cp "$CERT_HOOK" "$CERT_CRON"; chmod 755 "$CERT_CRON"
DOCTOR_FAIL=0 DOCTOR_WARN=0
doctor_cert >"$work/cron.log"
[[ $DOCTOR_FAIL == 0 && $DOCTOR_WARN == 0 ]] || fail 'OpenRC DNS renewal rejected'
chmod 644 "$CERT_DNS_AUTH"
doctor_cert >"$work/dns-hook.log"
grep -q 'DNS-01 验证或清理钩子' "$work/dns-hook.log" || fail 'broken DNS hook missed'
chmod 755 "$CERT_DNS_AUTH"
mv "$CERT_HOOK" "$CERT_HOOK.saved"
doctor_cert >"$work/deploy-hook.log"
grep -q '部署钩子不存在' "$work/deploy-hook.log" || fail 'missing deploy hook missed'
mv "$CERT_HOOK.saved" "$CERT_HOOK"
expiry=valid
openssl() {
  if [[ $* == *'-checkend 0 '* && $expiry == expired ]]; then return 1; fi
  if [[ $* == *'-checkend 604800 '* && $expiry != valid ]]; then return 1; fi
  command openssl "$@"
}
expiry=expired DOCTOR_FAIL=0
doctor_cert >"$work/expired.log"
[[ $DOCTOR_FAIL == 1 ]] || fail 'expired certificate accepted'
expiry=soon DOCTOR_FAIL=0 DOCTOR_WARN=0
doctor_cert >"$work/soon.log"
[[ $DOCTOR_FAIL == 0 && $DOCTOR_WARN == 1 ]] || fail 'near expiry reminder missed'
grep -q '每日续期脚本' "$work/soon.log" || fail 'near expiry skipped renewal checks'
expiry=valid
saved_cert=$CERT_FULLCHAIN CERT_FULLCHAIN="$work/missing.pem" DOCTOR_FAIL=0
doctor_cert >"$work/missing.log"
[[ $DOCTOR_FAIL == 1 ]] || fail 'missing certificate accepted'
CERT_FULLCHAIN=$saved_cert
echo 'ok certificate/key/domain/reader checks, timer/HTTP-01/manual DNS/origin handling, and read-only operation'

OPT_LAND='' BIN_PATH="$work/proxy" STATE_FILE="$work/state"
on_error() { echo UNEXPECTED >&2; exit 1; }
trap on_error ERR
menu_doctor() { echo 'FAIL expected check'; exit 1; }
run_menu_act menu_doctor >"$work/menu.log" 2>&1
if grep -q UNEXPECTED "$work/menu.log"; then fail 'expected diagnostic failure produced crash stack'; fi
menu_doctor() { false; }
run_menu_act menu_doctor >"$work/bug.log" 2>&1
grep -q UNEXPECTED "$work/bug.log" || fail 'unexpected script error was hidden'
trap - ERR
echo 'ok menu keeps expected doctor failures clean and retains unexpected error reporting'
