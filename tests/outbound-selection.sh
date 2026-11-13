#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./proxy.sh
trap - ERR INT TERM
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
outbound_detect_families() { OB_HAS_V4=1 OB_HAS_V6=1 OB_NAT66=0; }
outbound_can_ask() { return 0; }
save_state() { printf '%s' "$OUTBOUND_IP" >"$work/state"; }
ask() {
  local answer
  printf '%s\n' "$3" >>"$work/defaults"
  IFS= read -r answer <&3 || fail 'unexpected outbound prompt'
  printf -v "$1" '%s' "$answer"
}
reset_case() { OUTBOUND_IP_DONE=0 OUTBOUND_IP_CHANGED=0 OPT_AUTO=0 OPT_OUTBOUND='' OUTBOUND_NO_ASK=0; rm -f "$work/defaults"; }

reset_case; OUTBOUND_IP=46
ensure_outbound_ip install 3<<<2 >"$work/reinstall.log"
[[ $OUTBOUND_IP == 64 && $OUTBOUND_EFFECTIVE == 64 && $(cat "$work/state") == 64 ]] || fail 'reinstall did not permit changing saved IPv4 preference'
[[ $(cat "$work/defaults") == 1 ]] || fail 'saved IPv4 preference was not the default'
ensure_outbound_ip install >"$work/once.log"
[[ $(wc -l <"$work/defaults") == 1 ]] || fail 'installation prompted more than once'
printf 'ok interactive reinstall can change a saved policy once\n'

reset_case; OUTBOUND_IP=64
ensure_outbound_ip install 3<<<2 >"$work/saved.log"
[[ $(cat "$work/defaults") == 2 && $OUTBOUND_EFFECTIVE == 64 ]] || fail 'saved IPv6 policy was not the default'
printf 'ok reinstall defaults to the current saved policy\n'

reset_case; OUTBOUND_IP=46 OPT_AUTO=1
ensure_outbound_ip install
[[ $OUTBOUND_EFFECTIVE == 46 && ! -f $work/defaults ]] || fail 'auto reinstall prompted or changed saved choice'
reset_case; OUTBOUND_IP='' OPT_AUTO=1
ensure_outbound_ip install >"$work/auto.log"
[[ $OUTBOUND_EFFECTIVE == 46 && ! -f $work/defaults ]] || fail 'fresh auto default changed'
printf 'ok unattended install remains noninteractive\n'

reset_case; OUTBOUND_IP=46 OPT_OUTBOUND=64
ensure_outbound_ip install >"$work/explicit.log"
[[ $OUTBOUND_EFFECTIVE == 64 && ! -f $work/defaults ]] || fail 'explicit CLI policy was ignored'
reset_case; OUTBOUND_IP=46
ensure_outbound_ip
[[ $OUTBOUND_EFFECTIVE == 46 && ! -f $work/defaults ]] || fail 'ordinary config regeneration started prompting'
printf 'ok explicit options win and ordinary regeneration preserves its policy\n'

reset_case; OUTBOUND_IP=46
outbound_detect_families() { OB_HAS_V4=1 OB_HAS_V6=0 OB_NAT66=0; }
ensure_outbound_ip install >"$work/v4.log"
[[ $OUTBOUND_EFFECTIVE == 4 && ! -f $work/defaults ]] || fail 'single-stack install prompted'
printf 'ok single-stack install keeps its existing behavior\n'
