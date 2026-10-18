# ============================================================
#                    proxy doctor 健康检查
# ============================================================
# 不加 --fix 时只读。--fix 只做这几件：拉起已停止的服务、步进对时、
# 按清单重写 ufw/firewalld、把 state.env 改为 600。
DOCTOR_FIX=0
DOCTOR_FAIL=0
DOCTOR_FIXED=""
doc_line() { printf '  %-6s %s\n' "$1" "$2"; }
doc_ok() { doc_line OK "$*"; }
doc_warn() { doc_line WARN "$*"; }
doc_fail() { doc_line FAIL "$*"; DOCTOR_FAIL=1; }
doc_info() { doc_line INFO "$*"; }
doc_fixed() { DOCTOR_FIXED+="${DOCTOR_FIXED:+$'\n'}$*"; }
doctor_fix_time() {
  if have chronyc && chronyc makestep >/dev/null 2>&1; then
    doc_ok "已执行 chronyc makestep。"
    doc_fixed "已步进对时（chronyc makestep）"
    return 0
  fi
  if [[ $INIT_SYS == systemd ]] && systemctl cat systemd-timesyncd >/dev/null 2>&1; then
    if systemctl restart systemd-timesyncd >/dev/null 2>&1; then
      doc_ok "已重启 systemd-timesyncd。"
      doc_fixed "已重启 systemd-timesyncd"
      return 0
    fi
  fi
  if is_openrc && [[ -x /etc/init.d/chronyd ]]; then
    if rc-service chronyd restart >/dev/null 2>&1 9>&-; then
      doc_ok "已重启 OpenRC chronyd。"
      doc_fixed "已重启 OpenRC chronyd"
      return 0
    fi
  fi
  doc_warn "没有可用的对时命令（chronyc / timesyncd / chronyd）。"
}
doctor_clock() {
  local body="" ts="" now off
  body=$(curl -fsS --connect-timeout 5 -m 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null) || body=""
  [[ $body == *ts=* ]] || body=$(curl -fsS --connect-timeout 5 -m 8 https://1.1.1.1/cdn-cgi/trace 2>/dev/null) || body=""
  ts=$(sed -n 's/^ts=\([0-9][0-9]*\).*/\1/p' <<<"$body" | head -n1)
  if [[ -z $ts ]]; then
    doc_warn "对不上时间：Cloudflare trace 不可达，已跳过。"
    return 0
  fi
  now=$(date +%s)
  off=$(( now - ts ))
  (( off < 0 )) && off=$(( -off ))
  if (( off > 15 )); then
    doc_warn "本机时间与 Cloudflare 相差 ${off} 秒（超过 15 秒）。REALITY 可能握手失败。"
    if (( DOCTOR_FIX )); then doctor_fix_time; else echo "        可执行: proxy doctor --fix"; fi
  else
    doc_ok "时间偏差 ${off} 秒。"
  fi
}
doctor_crash_scan() {
  local svc=$1 hits="" log
  if have journalctl; then
    hits=$(journalctl -u "$svc" --since "24 hours ago" -n 300 --no-pager 2>/dev/null | grep -Ei 'out of memory|oom-kill|segfault|panic' | tail -n 3) || true
  fi
  log=$(svc_log_file "$svc" 2>/dev/null || true)
  if [[ -n $log && -f $log ]]; then
    hits+=$'\n'$(grep -Ei 'out of memory|oom-kill|segfault|panic' "$log" 2>/dev/null | tail -n 3 || true)
  fi
  hits=$(printf '%s\n' "$hits" | sed '/^$/d')
  if [[ -n $hits ]]; then
    doc_warn "${svc} 最近日志里有崩溃或内存不足记录。"
    printf '%s\n' "$hits" | sed 's/^/        /'
  fi
}
doctor_one_svc() { # $1 服务名 $2 是否必须（1/0）
  local svc=$1 must=$2
  if ! svc_exists "$svc"; then
    if (( must )); then doc_fail "没有 ${svc} 服务。"; else return 0; fi
    return 0
  fi
  if svc_active "$svc"; then
    doc_ok "${svc} 正在运行。"
  else
    doc_fail "${svc} 没有在运行（$(svc_state "$svc")）。"
    if (( DOCTOR_FIX )); then
      if svc_restart "$svc" && sleep 1 && svc_active "$svc"; then
        doc_ok "已重新拉起 ${svc}。"
        doc_fixed "已重新拉起 ${svc}"
      else doc_fail "重新拉起 ${svc} 失败。可查看: proxy status"; fi
    else
      echo "        可执行: proxy doctor --fix"
    fi
  fi
  doctor_crash_scan "$svc"
}
doctor_port() { # $1 tcp|udp $2 port $3 名称
  local proto=$1 port=$2 name=$3
  [[ -n $port && $port != 0 ]] || return 0
  if port_in_use "$proto" "$port"; then doc_ok "${name} 正在监听 ${proto^^}/${port}。"
  else doc_fail "${name} 没有监听 ${proto^^}/${port}。可查看: proxy status"; fi
}
doctor_services() {
  local need_x=0
  if declare -F xray_inbound_needed >/dev/null && xray_inbound_needed; then need_x=1; fi
  (( LAND_MODE )) && need_x=1
  doctor_one_svc xray "$need_x"
  if (( need_x )); then doctor_port tcp "$XRAY_PORT" "Xray"; fi
  if (( HY2_ENABLED )); then
    doctor_one_svc hysteria-server 1
    doctor_port udp "$HY2_PORT" "Hysteria2"
  fi
  if sb_needed; then
    doctor_one_svc sing-box 1
    (( TUIC_ENABLED )) && doctor_port udp "$TUIC_PORT" "TUIC"
    (( ANYTLS_ENABLED )) && doctor_port tcp "$ANYTLS_PORT" "AnyTLS"
  fi
  if (( XHTTP_ENABLED )) && ! xhttp_shared; then doctor_port tcp "$XHTTP_PORT" "XHTTP"; fi
  if [[ -f $STATE_FILE ]]; then
    local mode
    mode=$(stat -c %a "$STATE_FILE" 2>/dev/null || true)
    if [[ $mode == 600 ]]; then doc_ok "state.env 权限是 600。"
    elif [[ -n $mode ]]; then
      doc_warn "state.env 权限是 ${mode}，应为 600。"
      if (( DOCTOR_FIX )); then
        if chmod 600 "$STATE_FILE"; then
          doc_ok "已把 state.env 改为 600。"
          doc_fixed "已把 state.env 改为 600"
        fi
      fi
    fi
  fi
}
doctor_fw_ports_present() {
  local text=$1 miss=0 p
  if (( REALITY_ENABLED )); then
    grep -Eq "dport .*${XRAY_PORT}([^0-9]|$)" <<<"$text" || miss=1
  fi
  if (( XHTTP_ENABLED )) && ! xhttp_shared; then
    grep -Eq "dport .*${XHTTP_PORT}([^0-9]|$)" <<<"$text" || miss=1
  fi
  if (( HY2_ENABLED )); then
    grep -Eq "dport .*${HY2_PORT}([^0-9]|$)" <<<"$text" || miss=1
  fi
  (( miss )) && return 1
  return 0
}
doctor_host_sync() {
  if ! fw_ufw_active && ! fw_firewalld_active; then
    doc_ok "本机没有正在运行的 ufw 或 firewalld。"
    return 0
  fi
  if [[ ${FW_HOST_SYNC:-0} != 1 ]]; then
    doc_warn "ufw 或 firewalld 正在运行，当前没有同步代理端口。只放行模式可执行: proxy firewall allow"
    return 0
  fi
  local kind a b c miss=0
  if [[ ! -s $FW_HOST_FILE ]]; then
    doc_fail "应该同步到 ufw/firewalld，但 fw-host.list 是空的。"
    miss=1
  else
    while read -r kind a b c _; do
      [[ -n $kind ]] || continue
      case $kind in
        ufw) fw_ufw_ours_present "${b}/${a}" || miss=1 ;;
        firewalld)
          firewall-cmd --zone="$a" --query-port="${c}/${b}" >/dev/null 2>&1 || miss=1
          ;;
      esac
    done <"$FW_HOST_FILE"
    if (( miss )); then doc_fail "ufw/firewalld 里缺了已记录的放行。"
    else doc_ok "ufw/firewalld 的同步记录还在。"; fi
  fi
  if (( miss && DOCTOR_FIX )); then
    fw_host_sync || true
    doc_ok "已按清单重新同步 ufw/firewalld。"
    doc_fixed "已重新同步 ufw/firewalld"
  elif (( miss )); then
    echo "        可执行: proxy doctor --fix"
  fi
}
doctor_hop() {
  (( HY2_ENABLED )) || return 0
  [[ -n ${HOP_RANGE:-} ]] || return 0
  local rules pkts
  rules=$(nft list ruleset 2>/dev/null | grep -F 'redirect' | grep -F ":${HY2_PORT}" || true)
  if [[ -z $rules ]]; then
    doc_fail "没有找到 Hysteria2 端口跳跃的 DNAT（UDP ${HOP_RANGE} → ${HY2_PORT}）。"
    return 0
  fi
  doc_ok "端口跳跃 DNAT 已加载。"
  if [[ $rules == *counter* ]]; then
    pkts=$(sed -n 's/.*counter packets \([0-9][0-9]*\).*/\1/p' <<<"$rules" | head -n1)
    if [[ ${pkts:-0} == 0 ]]; then doc_warn "端口跳跃计数器仍是 0，还没有流量经过。"
    else doc_ok "端口跳跃计数器 packets=${pkts}。"; fi
  else
    doc_info "这条跳跃规则没有计数器（旧规则）。重新应用防火墙后会带上计数。"
  fi
}
doctor_firewall() {
  if (( NAT_MODE )); then
    doc_ok "NAT 模式不写本机入站默认拒绝。外部是否通，看服务商的端口映射。"
    doctor_hop
    return 0
  fi
  if (( LAND_MODE )); then
    doc_ok "落地机使用单独的来源白名单，不走节点这套默认拒绝。"
    return 0
  fi
  if [[ ${FW_MODE:-off} == off || ${FW_ENABLED:-0} == 0 ]]; then
    doc_warn "本脚本没有接管 nftables。系统防火墙和云安全组需要自己放行。"
  elif have nft && nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
    local text
    text=$(nft list table inet "$NFT_TABLE" 2>/dev/null || true)
    doc_ok "nftables 表 inet ${NFT_TABLE} 已加载（$(fw_mode_label)）。"
    if doctor_fw_ports_present "$text"; then doc_ok "表里能看到当前协议端口。"
    else doc_fail "表已加载，但没有看到当前协议端口。可执行: proxy firewall ${FW_MODE}"; fi
  else
    doc_fail "防火墙模式是 $(fw_mode_label)，但表 inet ${NFT_TABLE} 没有加载。"
    echo "        可执行: proxy firewall ${FW_MODE:-allow}"
  fi
  doctor_host_sync
  doctor_hop
}
doctor_sni() {
  (( REALITY_ENABLED || XHTTP_ENABLED )) || return 0
  [[ -n $SNI ]] || { doc_fail "没有 SNI。可执行: proxy sni"; return 0; }
  local res
  res=$(sni_probe "$SNI") || true
  if [[ $res == PASS* ]]; then doc_ok "SNI ${SNI} 仍然可用。"
  elif [[ $res == FAIL* ]]; then
    doc_warn "SNI ${SNI} 现在不合格（${res##*|}）。建议: proxy sni"
  else
    doc_warn "SNI 检查没有得到结果。可稍后执行: proxy sni"
  fi
}
doctor_selftests() {
  if (( REALITY_ENABLED )); then
    reality_selftest || true
    case ${REALITY_SELFTEST:-skip} in
      ok) doc_ok "REALITY 回环自检通过。" ;;
      fail) doc_fail "REALITY 回环自检未通过。可看上面的原因，或执行 proxy sni。" ;;
      *) doc_warn "跳过了 REALITY 回环自检。" ;;
    esac
  fi
  if (( XHTTP_ENABLED )); then
    xhttp_selftest || true
    case ${XHTTP_SELFTEST:-skip} in
      ok) doc_ok "XHTTP 回环自检通过。" ;;
      fail) doc_fail "XHTTP 回环自检未通过。" ;;
      *) doc_warn "跳过了 XHTTP 回环自检。" ;;
    esac
  fi
  if (( HY2_ENABLED || TUIC_ENABLED || ANYTLS_ENABLED )); then
    doc_ok "Hysteria2 / TUIC / AnyTLS 只核对了本机是否在监听，没有单独的回环握手。"
  fi
}
doctor_reach() {
  local addr
  addr=$(server_addr 2>/dev/null || true)
  [[ -n $addr ]] || addr="<服务器地址>"
  doc_ok "外部是否通，需要在自己的电脑上检查。云安全组要放行同一批端口。"
  if (( REALITY_ENABLED )); then
    echo "        nc -vz ${addr} $(pub_xray_port)"
    echo "        curl -v --connect-timeout 5 telnet://${addr}:$(pub_xray_port)"
  fi
  if (( XHTTP_ENABLED )) && ! xhttp_shared; then
    echo "        nc -vz ${addr} $(pub_xhttp_port)"
  fi
  if (( HY2_ENABLED )); then
    echo "        nc -uvz ${addr} $(pub_hy2_port)"
  fi
}
doctor_cert() {
  cert_is_public || return 0
  [[ -s $CERT_FULLCHAIN ]] || { doc_fail "状态里开了公开证书，但文件不在。"; return 0; }
  if ! openssl x509 -checkend 0 -noout -in "$CERT_FULLCHAIN" >/dev/null 2>&1; then
    doc_fail "公开证书已经过期（$(cert_expiry_text 2>/dev/null || echo 未知)）。"
    return 0
  fi
  if ! openssl x509 -checkend $(( 7 * 86400 )) -noout -in "$CERT_FULLCHAIN" >/dev/null 2>&1; then
    doc_warn "公开证书不到 7 天就要过期（$(cert_expiry_text 2>/dev/null || echo 未知)）。可执行: proxy cert"
    return 0
  fi
  doc_ok "公开证书未过期（$(cert_expiry_text 2>/dev/null || echo 未知)）。"
}
doctor_run_checks() {
  doctor_clock
  doctor_services
  doctor_firewall
  doctor_sni
  doctor_selftests
  doctor_reach
  doctor_cert
}
do_doctor() {
  load_state
  (( INSTALLED )) || die "还没有安装。"
  [[ -n $INIT_SYS ]] || detect_init
  [[ -n $OS_ID ]] || detect_os
  DOCTOR_FAIL=0
  DOCTOR_FIXED=""
  [[ ${OPT_DOCTOR_FIX:-0} == 1 ]] && DOCTOR_FIX=1 || DOCTOR_FIX=0
  echo
  if (( DOCTOR_FIX )); then hr; _green "  健康检查（会做安全修复）"; hr
  else hr; _green "  健康检查（只读）"; hr; fi
  doctor_run_checks
  # 修复时第一次检查仍记着修复前的失败。复查时不再改系统，只看现在是否通过。
  if (( DOCTOR_FIX && DOCTOR_FAIL )); then
    echo
    info "正在复查刚才的修复 ..."
    DOCTOR_FAIL=0
    DOCTOR_FIX=0
    doctor_run_checks
  fi
  echo
  if [[ -n $DOCTOR_FIXED ]]; then
    info "这次修好了："
    local line
    while IFS= read -r line; do
      [[ -n $line ]] && printf '  - %s\n' "$line"
    done <<<"$DOCTOR_FIXED"
  fi
  if (( DOCTOR_FAIL )); then
    warn "有检查未通过。"
    exit 1
  fi
  if [[ -n $DOCTOR_FIXED ]]; then ok "检查完成。列出的项目已经修好。"
  else ok "检查完成，没有失败项。"; fi
}
menu_doctor() {
  need_installed
  if confirm "顺手做安全修复（拉起停止的服务、对时、同步防火墙、修正 state.env 权限）？" n; then
    OPT_DOCTOR_FIX=1
  else
    OPT_DOCTOR_FIX=0
  fi
  do_doctor
}
