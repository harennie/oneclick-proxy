#!/usr/bin/env bash
# 只使用替身 TLS/DNS，不安装服务、不访问网络。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./proxy.sh
trap - ERR INT TERM
pq_definition=$(declare -f sni_pq_check)
mldsa_definition=$(declare -f mldsa_decide)
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cert_resolved_ips() {
  case $1 in own.example.com) echo 192.0.2.10 ;; own6.example.com) echo 2001:db8::10 ;; *) echo 192.0.2.20 ;; esac
}
cert_ip_ours() { echo '192.0.2.10 2001:db8::10'; }
port_owner() { [[ $2 != 9555 ]] || echo xray; }
outbound_can_ask() { return 0; }
ask() { local answer; IFS= read -r answer <&3 || fail 'unexpected prompt'; printf -v "$1" '%s' "$answer"; }
TLS_OK=127.0.0.1:9443
sni_local_tls_ok() { [[ $1 == "$TLS_OK" ]] && ! sni_target_is_loop "$1"; }
OPT_AUTO=1 REALITY_ENABLED=1 XRAY_PORT=443 XHTTP_ENABLED=1 XHTTP_PORT=8443 TROJAN_ENABLED=0

SNI=own.example.com SNI_TARGET=own.example.com:443
sni_assign_target "$SNI" "$SNI_TARGET" >"$work/log"
[[ $SNI_TARGET == 127.0.0.1:9443 ]] || fail 'same-host SNI targets its own public inbound'
printf 'ok local-domain reinstall repairs a previously recursive target\n'

SNI=own.example.com SNI_TARGET=127.0.0.1:9443
sni_assign_target "$SNI" "$SNI_TARGET"
[[ $SNI_TARGET == 127.0.0.1:9443 ]] || fail 'reinstall discarded an explicit backend'
printf 'ok unchanged SNI preserves its explicit target\n'

SNI=outside.example.com
sni_assign_target own.example.com 127.0.0.1:9443
[[ $SNI_TARGET == outside.example.com:443 ]] || fail 'external SNI retained the old backend'
printf 'ok changed external SNI resets the target\n'

SNI=own6.example.com SNI_TARGET=own6.example.com:443 TLS_OK='[::1]:9443'
sni_assign_target "$SNI" "$SNI_TARGET" >"$work/v6.log"
[[ $SNI_TARGET == '[::1]:9443' ]] || fail 'IPv6 self-hosted SNI was not recognized'
printf 'ok IPv6 self-hosted names use a validated IPv6 loopback backend\n'

SNI=own.example.com SNI_TARGET=own.example.com:443 TLS_OK='unavailable'
if (sni_assign_target "$SNI" "$SNI_TARGET") >"$work/fail.log" 2>&1; then fail 'missing backend was accepted'; fi
grep -q '拒绝生成自回环配置' "$work/fail.log" || fail 'missing backend error is not actionable'
printf 'ok unattended installation rejects a missing backend\n'

OPT_AUTO=0 TLS_OK=127.0.0.1:9444
sni_assign_target "$SNI" "$SNI_TARGET" 3<<<$'8443\n9444' >"$work/port.log" 2>&1
[[ $SNI_TARGET == 127.0.0.1:9444 ]] || fail 'interactive custom backend was not selected'
printf 'ok interactive backend selection rejects an Xray port and accepts a valid TLS port\n'

for target in own.example.com:443 127.0.0.1:443 127.0.0.1:0443 '[::1]:8443' 127.0.0.1:9555; do
  sni_target_is_loop "$target" || fail "loop not rejected: $target"
done
if sni_target_is_loop outside.example.com:443; then fail 'external site rejected'; fi
if sni_target_is_loop 127.remote.example.com:443; then fail '127-prefixed external hostname rejected'; fi
printf 'ok all local Xray listeners are protected from recursive targets\n'

SNI=own.example.com SNI_TARGET=own.example.com:443 LAND_MODE=0
if (write_xray_config) >"$work/write.log" 2>&1; then fail 'writer accepted a recursive target'; fi
grep -q '拒绝覆盖可用配置' "$work/write.log" || fail 'writer did not fail before building config'
printf 'ok the config writer independently blocks a recursive target\n'

SNI=old.example.com SNI_TARGET=old.example.com:443 TLS_OK=127.0.0.1:9443
sni_probe() { fail 'own-domain selection must not probe the public recursive port'; }
manual_sni own.example.com >"$work/manual.log" 2>&1
[[ $SNI == own.example.com && $SNI_TARGET == 127.0.0.1:9443 ]] || fail 'manual own-domain selection discarded its backend'
printf 'ok manual own-domain selection validates the independent backend directly\n'

# Same-SNI menu repairs must be applied, not treated as a no-op.
need_node() { :; }; mktmp() { :; }; detect_ip() { :; }; detect_geo() { :; }
select_sni() { :; }; mldsa_decide() { :; }; reality_selftest() { :; }; show_info() { :; }
TLS_OK=127.0.0.1:9443
SNI_TARGET=own.example.com:443
apply_all() { echo "$SNI_TARGET" >"$work/applied"; }
menu_change_sni >"$work/menu.log" 2>&1
[[ $(cat "$work/applied") == 127.0.0.1:9443 ]] || fail 'same-SNI target repair was not applied'
printf 'ok installed-node menu applies same-SNI target repairs\n'

# PQ/ML-DSA checks must use the local backend before the public node is started.
fake_xray="$work/xray"
cat >"$fake_xray" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${0}.args"
printf 'Pinging with SNI\nCertificate chain total length: 3387\nTLS Post-Quantum key exchange: true (X25519MLKEM768)\n'
STUB
chmod +x "$fake_xray"
# Run the real function definitions in a clean shell; the production binary path is readonly.
probe="$pq_definition"$'\n'"$mldsa_definition"
probe+=$'\nset -euo pipefail\nXRAY_BIN=$1\nSNI=own.example.com\nSNI_TARGET=127.0.0.1:9443\n'
probe+=$'sni_pq_check "$SNI"\n[[ $SNI_CHAIN_LEN == 3387 ]]\ngrep -q -- "-ip 127.0.0.1 own.example.com:9443" "$XRAY_BIN.args"\n'
probe+=$'warn() { :; }\nMLDSA_SEED=keep-key\nMLDSA_MIN_CHAIN=3500\nmldsa_decide\n[[ $MLDSA_ON == 0 ]]\n'
bash -c "$probe" -- "$fake_xray" || fail 'local-backend PQ / ML-DSA check failed'
printf 'ok local-backend PQ checks retain SNI and certificate-chain checks\n'
