#!/usr/bin/env bash
# 规则更新只使用临时目录、假服务和假下载，不改系统或访问网络。
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source src/xray.sh
real_download=$(declare -f cn_geodata_download)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL $*" >&2; exit 1; }
die() { echo "FAIL $*" >&2; exit 1; }
ok() { echo "OK $*"; }
warn() { echo "WARN $*"; }
info() { echo "INFO $*"; }
have() { command -v "$1" >/dev/null 2>&1; }
CN_IP_FILE=proxy-cn-geoip.dat CN_SITE_FILE=proxy-cn-geosite.dat
XRAY_ASSET_DIR="$work/assets" XRAY_CONF="$work/config.json" XRAY_BIN="$work/xray"
RULE_UPDATE_UNIT="$work/rules.service" RULE_UPDATE_TIMER="$work/rules.timer" RULE_UPDATE_CRON="$work/periodic/rules"
STATE_DIR="$work/state" STATE_FILE="$STATE_DIR/state.env" BACKUP_DIR="$work/backups" BIN_PATH="$work/proxy"
TMP_DIR="$work/tmp" INSTALLED=1 MODE=systemd RAW=0 ACTIVE=1 RESTART_FAIL=0 CHECK_BAD=0
export CHECK_BAD
mkdir -p "$XRAY_ASSET_DIR" "$STATE_DIR" "$TMP_DIR"
cat >"$XRAY_BIN" <<'EOF'
#!/bin/sh
[ "$CHECK_BAD" != 1 ] && [ -s "$XRAY_LOCATION_ASSET/geoip.dat" ]
EOF
printf '#!/bin/bash\ndo_update_rules() { :; }\n' >"$BIN_PATH"
chmod 755 "$XRAY_BIN" "$BIN_PATH"
jq -n --arg ip "ext:$CN_IP_FILE:cn" --arg site "ext:$CN_SITE_FILE:cn" '{outbounds:[{tag:"block",protocol:"blackhole"}],routing:{domainStrategy:"IPOnDemand",rules:[{domain:[$site],outboundTag:"block"},{ip:[$ip],outboundTag:"block"}]}}' >"$XRAY_CONF"
printf original-geo >"$XRAY_ASSET_DIR/geoip.dat"
load_state() { INSTALLED=1; }
take_lock() { :; }
mktmp() { mkdir -p "$TMP_DIR"; }
land_only() { [[ $RAW == 1 ]]; }
land_raw_active() { [[ $RAW == 1 ]]; }
is_openrc() { [[ $MODE == openrc ]]; }
sd_reload() { printf 'reload\n' >>"$work/jobs"; }
systemctl() {
  printf '%s\n' "$*" >>"$work/jobs"
  case $1 in
    is-enabled|is-active) [[ -f $work/job-ready ]] ;;
    enable) touch "$work/job-ready" ;;
    show) printf '%s\n' "${JOB_RESULT:-success}" ;;
  esac
}
svc_exists() { return 0; }
svc_active() { if [[ $1 == xray ]]; then [[ -f $work/running ]]; else [[ -f $work/cron-running ]]; fi; }
svc_restart() {
  echo restart >>"$work/restarts"
  if [[ $RESTART_FAIL == 1 && $(wc -l <"$work/restarts") == 1 ]]; then rm -f "$work/running"; return 1; fi
  touch "$work/running"
}
rc-update() { printf '%s\n' "$*" >>"$work/jobs"; }
rc-service() { touch "$work/cron-running"; }
cn_rules_install_job
grep -q '^OnCalendar=' "$RULE_UPDATE_TIMER"; grep -q '^Persistent=true' "$RULE_UPDATE_TIMER"
grep -q '^ExecStart=.* update-rules --auto' "$RULE_UPDATE_UNIT"
count=$(wc -l <"$work/jobs")
cn_rules_install_job
[[ $(wc -l <"$work/jobs") == $(( count + 2 )) ]] || fail 'systemd job was recreated'
MODE=openrc
cn_rules_install_job
[[ -x $RULE_UPDATE_CRON && -f $work/cron-running ]] || fail 'OpenRC daily task missing'
grep -q 'rule-update.log' "$RULE_UPDATE_CRON"
cn_rules_remove_job
[[ ! -e $RULE_UPDATE_CRON && ! -e $RULE_UPDATE_TIMER && ! -e $RULE_UPDATE_UNIT ]] || fail 'scheduler uninstall left files'
MODE=systemd
cn_rules_install_job
echo 'ok systemd/OpenRC daily scheduling, idempotence and cleanup'

cn_geodata_download() { printf '%s' "$DATA-ip" >"$1/$CN_IP_FILE"; printf '%s' "$DATA-site" >"$1/$CN_SITE_FILE"; }
reset_data() {
  printf old-ip >"$XRAY_ASSET_DIR/$CN_IP_FILE"; printf old-site >"$XRAY_ASSET_DIR/$CN_SITE_FILE"
  : >"$work/restarts"; touch "$work/running"
  DATA=old RESTART_FAIL=0 CHECK_BAD=0
}
assert_old() { [[ $(cat "$XRAY_ASSET_DIR/$CN_IP_FILE") == old-ip && $(cat "$XRAY_ASSET_DIR/$CN_SITE_FILE") == old-site ]] || fail 'old dataset not retained'; }
reset_data
before=$(stat -c %Y "$XRAY_ASSET_DIR/$CN_IP_FILE")
do_update_rules >"$work/unchanged.log"
[[ ! -s $work/restarts && $(stat -c %Y "$XRAY_ASSET_DIR/$CN_IP_FILE") == "$before" ]] || fail 'unchanged data restarted or rewrote'
DATA=new
do_update_rules >"$work/changed.log"
[[ $(cat "$XRAY_ASSET_DIR/$CN_IP_FILE") == new-ip && $(cat "$XRAY_ASSET_DIR/$CN_SITE_FILE") == new-site && $(wc -l <"$work/restarts") == 1 ]] || fail 'changed data did not restart once'
echo 'ok unchanged data avoids writes/restart; changed data is validated and reloaded'

reset_data; DATA=new CHECK_BAD=1
if do_update_rules >"$work/invalid.log" 2>&1; then fail 'invalid complete config accepted'; fi
assert_old; [[ ! -s $work/restarts ]] || fail 'invalid staged data restarted service'
reset_data; DATA=new RESTART_FAIL=1
if do_update_rules >"$work/rollback.log" 2>&1; then fail 'failed restart accepted'; fi
assert_old; [[ $(wc -l <"$work/restarts") == 2 && -f $work/running ]] || fail 'old service was not recovered'
reset_data; DATA=new; rm "$work/running"
do_update_rules >"$work/stopped.log"
[[ ! -s $work/restarts && ! -f $work/running ]] || fail 'intentionally stopped service was started'
echo 'ok invalid config leaves data alone; restart failure rolls back; stopped services stay stopped'

reset_data; DATA=new
(
  cn_geodata_install() { printf partial >"$XRAY_ASSET_DIR/$CN_IP_FILE"; kill -TERM "$BASHPID"; }
  if do_update_rules >"$work/terminate.log" 2>&1; then fail 'terminated update succeeded'; fi
)
assert_old
reset_data
(
  eval "$real_download"
  gh_latest_tag() { echo fixture; }
  fetch() { if [[ $3 == *.sha256sum ]]; then printf '%064d' 0 >"$2"; else printf bad-data >"$2"; fi; }
  if do_update_rules >"$work/hash.log" 2>&1; then fail 'bad checksum accepted'; fi
)
assert_old; [[ ! -s $work/restarts ]] || fail 'bad checksum restarted service'
echo 'ok terminated replacement restores both files; invalid checksum never replaces data'

RAW=1
do_update_rules >"$work/raw.log"
[[ ! -s $work/restarts ]] || fail 'opaque forwarding restarted Xray'
if find "$BACKUP_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then fail 'completed updates left temporary backups'; fi
bash proxy.sh --help | grep -q 'proxy update-rules'
echo 'ok opaque forwarding skips local data updates; command is documented'

# Doctor reports failed tasks without changing scheduler or policy files.
# shellcheck disable=SC1091
source src/doctor.sh
RAW=0 HY2_ENABLED=0
xray_inbound_needed() { return 0; }
local_policy_needed() { return 1; }
sb_needed() { return 1; }
before=$(sha256sum "$XRAY_CONF" "$RULE_UPDATE_UNIT" "$RULE_UPDATE_TIMER")
doctor_cn_policy >"$work/doctor-ok.log"
[[ $DOCTOR_FAIL == 0 && $DOCTOR_WARN == 0 ]] || fail 'healthy scheduler rejected'
JOB_RESULT=exit-code DOCTOR_WARN=0
doctor_cn_policy >"$work/doctor-failed.log"
[[ $DOCTOR_WARN == 1 ]] || fail 'recent update failure not reported'
[[ $before == "$(sha256sum "$XRAY_CONF" "$RULE_UPDATE_UNIT" "$RULE_UPDATE_TIMER")" ]] || fail 'doctor modified files'
echo 'ok scheduler health and recent failure diagnostics remain read-only'
