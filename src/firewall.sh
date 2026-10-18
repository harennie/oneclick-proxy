# ============================================================
#                        防火墙 (nftables)
# ============================================================
# 三种模式，都只动本脚本自己的表 inet proxy_oneclick（以及旧内核端口跳跃用的
# ip/ip6 proxy_oneclick_nat）。不 flush 全表，不改 Docker / Podman 的表和链。
#   strict  入站默认拒绝（干净机器上的原有行为）
#   allow   只给代理端口和端口跳跃写 accept，策略保持 accept，不接管入站
#   off     不写 nftables（--no-firewall）
fw_norm_mode() { # 输出 strict|allow|off；无法识别返回 1
  case ${1,,} in
    strict|drop|hard) printf 'strict' ;;
    allow|allow-only|allowonly|gentle|soft) printf 'allow' ;;
    off|none|disable|no) printf 'off' ;;
    on|enable) printf 'strict' ;;
    *) return 1 ;;
  esac
}
fw_mode_label() {
  case ${1:-${FW_MODE:-}} in
    strict) printf '严格（入站默认拒绝）' ;;
    allow) printf '只放行（不接管入站策略）' ;;
    off) printf '关闭' ;;
    *) printf '未设置' ;;
  esac
}
# 旧 state.env 只有 FW_ENABLED。1 视为严格，0 视为关闭。
fw_migrate_saved_mode() {
  case ${FW_MODE:-} in
    strict|allow|off) ;;
    *)
      if [[ ${FW_ENABLED:-1} == 0 ]]; then FW_MODE=off; else FW_MODE=strict; fi
      ;;
  esac
  return 0
}
fw_table_loaded() { have nft && nft list table inet "$NFT_TABLE" >/dev/null 2>&1; }

fw_container_runtime() {
  [[ -S /var/run/docker.sock || -S /run/docker.sock ]] && return 0
  [[ -S /run/podman/podman.sock || -S /var/run/podman/podman.sock ]] && return 0
  [[ -d /sys/class/net/docker0 || -d /sys/class/net/podman0 || -d /sys/class/net/cni-podman0 ]] && return 0
  if have systemctl; then
    systemctl is-active --quiet docker 2>/dev/null && return 0
    systemctl is-active --quiet docker.socket 2>/dev/null && return 0
    systemctl is-active --quiet podman 2>/dev/null && return 0
    systemctl is-active --quiet podman.socket 2>/dev/null && return 0
  fi
  if have iptables; then
    iptables -S 2>/dev/null | grep -Eq 'DOCKER|PODMAN' && return 0
    iptables -t nat -S 2>/dev/null | grep -Eq 'DOCKER|PODMAN' && return 0
  fi
  if have nft; then
    nft list chains 2>/dev/null | grep -Eq 'DOCKER|PODMAN' && return 0
  fi
  if have pgrep; then
    pgrep -x dockerd >/dev/null 2>&1 && return 0
    pgrep -x podman >/dev/null 2>&1 && return 0
  fi
  return 1
}
fw_wireguard_present() {
  local d
  for d in /sys/class/net/*; do
    [[ -e $d/wireguard ]] && return 0
  done
  if have wg && [[ -n $(wg show interfaces 2>/dev/null || true) ]]; then return 0; fi
  if have ip && ip -d link show 2>/dev/null | grep -q wireguard; then return 0; fi
  return 1
}
fw_ufw_active() {
  svc_active ufw && return 0
  have ufw && ufw status 2>/dev/null | grep -q 'Status: active'
}
fw_firewalld_active() {
  svc_active firewalld && return 0
  have firewall-cmd && firewall-cmd --state >/dev/null 2>&1
}
# 除本脚本的表以外，规则集里还有实际规则（空表、只有 chain 类型声明的不算）
fw_foreign_nft() {
  local rs
  have nft || return 1
  rs=$(nft -s list ruleset 2>/dev/null || true)
  [[ -n $rs ]] || return 1
  awk '
    $1 == "table" { skip = ($0 ~ /proxy_oneclick/); next }
    skip { next }
    /^[[:space:]]*(type |chain |}|table )/ { next }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    { found = 1 }
    END { exit found ? 0 : 1 }
  ' <<<"$rs"
}
# 有不是 Docker/Podman 的 iptables 规则。ufw / firewalld 另计，避免同一件事说两遍。
fw_foreign_iptables() {
  local bin line hit=0
  for bin in iptables ip6tables; do
    have "$bin" || continue
    while IFS= read -r line; do
      [[ $line == -A\ * || $line == -I\ * ]] || continue
      [[ $line =~ DOCKER|PODMAN|CNI- ]] && continue
      hit=1
    done < <("$bin" -S 2>/dev/null || true)
  done
  (( hit == 1 ))
}
fw_collect_foreign() {
  local t u p
  detect_ssh_ports
  t=$(other_listen_ports tcp)
  u=$(other_listen_ports udp)
  FW_FOREIGN_TCP=""
  FW_FOREIGN_UDP=""
  for p in $t; do
    if [[ $p == "$XRAY_PORT" || $p == "$XHTTP_PORT" || $p == "$TROJAN_PORT" || $p == "$ANYTLS_PORT" || $p == "$XHTTP_TLS_PORT" || $p == "$WS_PORT" || $p == "${SUB_PORT:-}" ]]; then
      continue
    fi
    cert_port_owned "$p" && continue
    FW_FOREIGN_TCP+="$p "
  done
  for p in $u; do
    [[ $p == "$HY2_PORT" || $p == "$TUIC_PORT" || $p == "$XRAY_PORT" ]] && continue
    FW_FOREIGN_UDP+="$p "
  done
  FW_FOREIGN_TCP=${FW_FOREIGN_TCP% }
  FW_FOREIGN_UDP=${FW_FOREIGN_UDP% }
}
fw_print_risk() { [[ -n ${FW_RISK_TEXT:-} ]] && printf '%s' "$FW_RISK_TEXT"; return 0; }
# 会把「入站默认拒绝」弄坏现有服务的信号。只读，不改任何规则。
fw_detect_risk() {
  local p nstd=0 udp_note
  FW_RISK=0
  FW_RISK_TEXT=""
  fw_collect_foreign
  if fw_container_runtime; then
    FW_RISK=1
    FW_RISK_TEXT+="  · Docker 或 Podman 在用（发布端口 / iptables-nft 转发）。默认拒绝会挡住容器端口，本脚本也不会去改它们自己的表。"$'\n'
  fi
  if fw_wireguard_present; then
    FW_RISK=1
    FW_RISK_TEXT+="  · 检测到 WireGuard。默认拒绝会丢掉它的 UDP 握手。"$'\n'
  fi
  if [[ -n $FW_FOREIGN_UDP ]]; then
    FW_RISK=1
    udp_note=$FW_FOREIGN_UDP
    FW_RISK_TEXT+="  · 还有其它 UDP 端口在监听：${udp_note}。"$'\n'
  fi
  for p in $FW_FOREIGN_TCP; do
    [[ $p == 80 || $p == 443 || $p == 53 ]] && continue
    nstd=$((nstd + 1))
  done
  if (( nstd >= 2 )); then
    FW_RISK=1
    FW_RISK_TEXT+="  · 有多个非标准端口在对外监听：${FW_FOREIGN_TCP}。"$'\n'
  fi
  if fw_firewalld_active; then
    FW_RISK=1
    FW_RISK_TEXT+="  · firewalld 正在运行。"$'\n'
  fi
  if fw_ufw_active; then
    FW_RISK=1
    FW_RISK_TEXT+="  · ufw 正在运行。"$'\n'
  fi
  if ! fw_firewalld_active && fw_foreign_nft; then
    FW_RISK=1
    FW_RISK_TEXT+="  · 已经有不是本脚本的 nftables 规则。"$'\n'
  fi
  if ! fw_ufw_active && ! fw_container_runtime && fw_foreign_iptables; then
    FW_RISK=1
    FW_RISK_TEXT+="  · 已经有 iptables 规则。"$'\n'
  fi
  return 0
}
fw_prompt_mode() {
  local def=1 c prev
  prev=${FW_MODE:-}
  fw_detect_risk
  echo
  if (( FW_RISK )); then
    warn "这台机器若使用入站默认拒绝，可能会打断已经在跑的服务："
    fw_print_risk
    echo "推荐「只放行」：只给本脚本的端口和端口跳跃加 accept，不把入站改成默认拒绝，也不改 Docker 或其它防火墙的表。"
    def=2
  else
    info "没有发现 Docker、Podman、WireGuard、已有防火墙规则，也没有多个非标准端口在监听。"
    echo "推荐「严格」：入站默认拒绝，并放行 SSH 和代理端口。"
    def=1
  fi
  [[ -n $prev && ${INSTALLED:-0} == 1 ]] && echo "当前已保存：$(fw_mode_label "$prev")"
  echo "  1) 严格 — 入站默认拒绝（一定会放行 SSH）"
  echo "  2) 只放行 — 不接管入站策略"
  echo "  3) 关闭 — 不写 nftables"
  ask c "防火墙模式" "$def"
  case $c in
    1|strict) FW_MODE=strict ;;
    2|allow|allow-only) FW_MODE=allow ;;
    3|off|none) FW_MODE=off ;;
    *)
      warn "没有识别「${c}」，改用推荐项。"
      if (( FW_RISK )); then FW_MODE=allow; else FW_MODE=strict; fi
      ;;
  esac
}
# 安装时决定 FW_MODE / FW_ENABLED。NAT 模式不配置这套防火墙。
fw_decide_install() {
  if (( NAT_MODE )); then
    if [[ -f $FW_FILE || -f $FW_UNIT ]] || fw_table_loaded; then
      info "NAT 模式不管理防火墙，移除之前安装的本脚本 nftables 规则 ..."
      remove_firewall
    fi
    FW_MODE=off
    FW_ENABLED=0
    return 0
  fi
  if [[ -n $OPT_FW_MODE ]]; then
    FW_MODE=$OPT_FW_MODE
    if [[ $FW_MODE == strict ]]; then
      fw_detect_risk
      if (( FW_RISK )); then
        warn "已按指定使用严格模式（入站默认拒绝）。下面这些情况仍可能受影响："
        fw_print_risk
        warn "SSH 会放行。若要改为只放行：proxy firewall allow"
      fi
    elif [[ $FW_MODE == allow ]]; then
      info "防火墙使用只放行模式（不把入站改成默认拒绝）。"
    else
      info "已按指定跳过 nftables 防火墙。"
    fi
  elif (( OPT_AUTO )) || { [[ ! -t 0 && ! -r /dev/tty ]]; }; then
    fw_detect_risk
    if (( FW_RISK )); then
      FW_MODE=allow
      warn "未指定 --firewall。检测到可能被默认拒绝打断的环境，非交互安装改用只放行模式："
      fw_print_risk
      info "确认要入站默认拒绝时，请使用 --firewall strict，或之后执行 proxy firewall strict。"
    else
      FW_MODE=strict
      info "未指定 --firewall，也没有发现 Docker、已有防火墙或额外的非标准监听，使用严格模式（入站默认拒绝）。"
    fi
  else
    fw_prompt_mode
  fi
  case $FW_MODE in
    off)
      FW_ENABLED=0
      FW_HOST_SYNC=0
      if [[ -f $FW_FILE || -f $FW_UNIT || -s ${FW_HOST_FILE:-} ]] || fw_table_loaded; then
        info "不配置防火墙，移除本脚本已有的 nftables 规则 ..."
        remove_firewall
      fi
      ;;
    allow)
      FW_ENABLED=1
      if fw_ufw_active || fw_firewalld_active; then
        FW_HOST_SYNC=1
        info "检测到 ufw 或 firewalld。只放行模式会把代理端口写进去，否则它们的默认拒绝仍会挡住这些端口。"
      else
        FW_HOST_SYNC=0
      fi
      ;;
    *)
      FW_MODE=strict
      FW_ENABLED=1
      handle_other_firewalls
      if (( FW_ENABLED )); then
        ask_extra_ports
      else
        FW_MODE=off
      fi
      ;;
  esac
  return 0
}
fw_switch_mode() { # strict|allow|off。已安装后从菜单或 proxy firewall 调用
  case $1 in
    off)
      FW_HOST_SYNC=0
      remove_firewall
      FW_MODE=off
      FW_ENABLED=0
      save_state
      ok "已关闭本脚本防火墙（没有改系统其它规则，写入 ufw / firewalld 的放行也已去掉）。"
      ;;
    allow)
      FW_MODE=allow
      FW_ENABLED=1
      if fw_ufw_active || fw_firewalld_active; then FW_HOST_SYNC=1; else FW_HOST_SYNC=0; fi
      save_state
      apply_firewall
      save_state
      ;;
    strict)
      FW_MODE=strict
      FW_ENABLED=1
      handle_other_firewalls
      if (( ! FW_ENABLED )); then
        FW_MODE=off
        save_state
        fw_host_sync
        fw_print_allows
        save_state
        return 0
      fi
      FW_HOST_SYNC=0
      ask_extra_ports
      save_state
      apply_firewall
      save_state
      ;;
    *) die "未知防火墙模式: $1" ;;
  esac
}
# strict 的规则文件必须包含每一个已探测的 SSH 端口，否则拒绝加载。
fw_rules_cover_ssh() { # $1 nft 文件
  local f=$1 line ports p cur
  line=$(grep -F 'comment "SSH"' "$f" || true)
  [[ -n $line ]] || return 1
  ports=$(sed -n 's/.*tcp dport {[[:space:]]*\([^}]*\)}.*/\1/p' <<<"$line" | tr -d ' ')
  [[ -n $ports ]] || return 1
  for p in $SSH_PORTS; do
    [[ ",${ports}," == *",${p},"* ]] || return 1
  done
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    cur=$(awk '{print $4}' <<<"$SSH_CONNECTION")
    if is_port "$cur"; then
      [[ ",${ports}," == *",${cur},"* ]] || return 1
    fi
  fi
  return 0
}

handle_other_firewalls() {
  local fw
  FW_HOST_SYNC=0
  for fw in firewalld ufw; do
    if svc_active "$fw" || { [[ $fw == ufw ]] && have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; }; then
      warn "检测到 ${fw} 正在运行。严格模式会把入站改成默认拒绝，和它叠在一起容易互相挡住。"
      if confirm "是否停用 ${fw}（严格模式由本脚本放行 SSH 和现有端口；卸载时可恢复）？" y; then
        fw_host_clear
        [[ $fw == ufw ]] && { ufw --force disable >/dev/null 2>&1 || true; }
        systemctl disable --now "$fw" >/dev/null 2>&1 || true
        [[ " $DISABLED_FW " == *" $fw "* ]] || DISABLED_FW="${DISABLED_FW:+$DISABLED_FW }$fw"
        ok "已停用 ${fw}（卸载本脚本时可恢复）。"
      else
        warn "保留 ${fw}，已取消严格模式。代理端口会写入 ${fw}，否则它的默认拒绝会一直挡住这些端口。"
        remove_nft_rules
        FW_ENABLED=0
        FW_MODE=off
        FW_HOST_SYNC=1
        return 0
      fi
    fi
  done
}

backup_firewall() {
  mkdir -p "$BACKUP_DIR"
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  nft list ruleset >"${BACKUP_DIR}/nft-ruleset-${ts}.nft" 2>/dev/null || true
  if have iptables-save; then iptables-save >"${BACKUP_DIR}/iptables-${ts}.rules" 2>/dev/null || true; fi
  chmod 600 "${BACKUP_DIR}"/* 2>/dev/null || true
}

render_firewall() {
  local ssh_set tcp_ports udp_ports p
  ssh_set=$(tr ' ' ',' <<<"$SSH_PORTS")
  tcp_ports=""
  (( ${REALITY_ENABLED:-1} )) && tcp_ports="$XRAY_PORT"
  fw_add_port() { # $1 列表变量名 $2 端口；TCP 不重复放行 SSH 端口
    local cur=${!1-} p=$2
    [[ -n $p && $p != 0 ]] || return 0
    [[ ",$cur," == *",$p,"* ]] && return 0
    [[ $1 == tcp_ports && ",$ssh_set," == *",$p,"* ]] && return 0
    printf -v "$1" '%s' "${cur:+$cur,}$p"
  }
  (( ${XHTTP_ENABLED:-0} )) && fw_add_port tcp_ports "$XHTTP_PORT"
  (( ${TROJAN_ENABLED:-0} )) && fw_add_port tcp_ports "$TROJAN_PORT"
  (( ${ANYTLS_ENABLED:-0} )) && fw_add_port tcp_ports "$ANYTLS_PORT"
  (( ${XHTTP_TLS_ENABLED:-0} )) && fw_add_port tcp_ports "$XHTTP_TLS_PORT"
  (( ${WS_ENABLED:-0} )) && fw_add_port tcp_ports "$WS_PORT"
  if cert_http_open; then fw_add_port tcp_ports 80; fi
  if cert_is_public; then fw_add_port tcp_ports "${SUB_PORT:-8447}"; fi
  for p in $EXTRA_TCP; do fw_add_port tcp_ports "$p"; done
  udp_ports=""
  (( HY2_ENABLED )) && udp_ports="$HY2_PORT"
  (( ${TUIC_ENABLED:-0} )) && fw_add_port udp_ports "$TUIC_PORT"
  for p in $EXTRA_UDP; do fw_add_port udp_ports "$p"; done
  local hop="" mode=${FW_MODE:-strict}
  (( HY2_ENABLED )) && [[ -n $HOP_RANGE ]] && hop=$HOP_RANGE
  [[ $mode == allow ]] || mode=strict
  {
    echo "#!/usr/sbin/nft -f"
    if [[ $mode == allow ]]; then
      echo "# 由 proxy-oneclick 生成（只放行，policy accept，不接管入站）。卸载时删除。原有规则备份在 ${BACKUP_DIR}"
    else
      echo "# 由 proxy-oneclick 生成；卸载时删除。原有规则备份在 ${BACKUP_DIR}"
    fi
    echo "table inet ${NFT_TABLE}"
    echo "delete table inet ${NFT_TABLE}"
    echo "table inet ${NFT_TABLE} {"
    echo "  chain input {"
    # allow 用较晚的优先级，避免抢在 Docker / 已有防火墙前面把包判掉或截走。
    if [[ $mode == allow ]]; then
      echo "    type filter hook input priority 10; policy accept;"
    else
      echo "    type filter hook input priority filter; policy drop;"
      echo "    iif \"lo\" accept"
      echo "    ct state established,related accept"
      echo "    ct state invalid drop"
      echo "    meta l4proto 1 accept comment \"ICMP\""
      echo "    meta l4proto 58 accept comment \"ICMPv6\""
      echo "    ip6 saddr fe80::/10 udp sport 547 udp dport 546 accept comment \"DHCPv6\""
    fi
    [[ -n $ssh_set ]] && echo "    tcp dport { ${ssh_set} } accept comment \"SSH\""
    [[ -n $tcp_ports ]] && echo "    tcp dport { ${tcp_ports} } accept"
    [[ -n $udp_ports ]] && echo "    udp dport { ${udp_ports} } accept"
    [[ -n $hop ]] && echo "    udp dport ${hop} accept comment \"hy2 port hopping\""
    [[ $mode == strict ]] && echo "    ct status dnat accept"
    echo "  }"
    if [[ -n $hop ]]; then
      echo "  chain prerouting {"
      echo "    type nat hook prerouting priority dstnat; policy accept;"
      echo "    udp dport ${hop} redirect to :${HY2_PORT} comment \"hy2 port hopping\""
      echo "  }"
    fi
    echo "}"
  } >"${FW_FILE}.tmp"
}

# 旧内核 (<5.2) 不支持 inet 族 nat，改用 ip/ip6 两张表
render_firewall_compat() {
  local f="${FW_FILE}.tmp"
  nft -c -f "$f" >/dev/null 2>&1 && return 0
  if grep -q 'chain prerouting' "$f"; then
    awk '/  chain prerouting \{/{skip=1} skip&&/^  \}$/{skip=0; next} !skip' "$f" >"${f}.2"
    local fam
    for fam in ip ip6; do
      {
        echo "table ${fam} ${NFT_TABLE}_nat"
        echo "delete table ${fam} ${NFT_TABLE}_nat"
        echo "table ${fam} ${NFT_TABLE}_nat {"
        echo "  chain prerouting {"
        echo "    type nat hook prerouting priority dstnat; policy accept;"
        echo "    udp dport ${HOP_RANGE} redirect to :${HY2_PORT}"
        echo "  }"
        echo "}"
      } >>"${f}.2"
    done
    mv -f "${f}.2" "$f"
  fi
  nft -c -f "$f" >/dev/null 2>&1
}

apply_firewall() {
  if (( LAND_MODE )); then land_fw_apply; return; fi
  if (( NAT_MODE )); then apply_nat_hop; return; fi
  case ${FW_MODE:-} in
    off) FW_ENABLED=0 ;;
    allow|strict) FW_ENABLED=1 ;;
  esac
  if (( ! FW_ENABLED )); then
    if [[ ${FW_HOST_SYNC:-0} == 1 ]]; then
      fw_host_sync
      fw_print_allows
      return 0
    fi
    fw_host_clear
    warn "已跳过防火墙配置（--no-firewall、--firewall off，或保留了其它防火墙）。"
    return 0
  fi
  [[ ${FW_MODE:-strict} == allow ]] || FW_MODE=strict
  step "配置 nftables 防火墙（$(fw_mode_label)）"
  have nft || die "未安装 nftables。"
  detect_ssh_ports
  if [[ $FW_MODE == strict && -z ${SSH_PORTS// } ]]; then
    warn "没有检测到 SSH 端口，已改为只放行模式，避免把登录关在外面。"
    FW_MODE=allow
    if fw_ufw_active || fw_firewalld_active; then FW_HOST_SYNC=1; fi
  fi
  mkdir -p "$STATE_DIR"
  render_firewall
  if [[ $FW_MODE == strict ]] && ! fw_rules_cover_ssh "${FW_FILE}.tmp"; then
    warn "严格模式的规则没有包含全部 SSH 端口，已改为只放行模式，避免把登录关在外面。"
    FW_MODE=allow
    FW_ENABLED=1
    if fw_ufw_active || fw_firewalld_active; then FW_HOST_SYNC=1; fi
    render_firewall
  fi
  if ! render_firewall_compat; then
    nft -c -f "${FW_FILE}.tmp" >&2 || true
    rm -f "${FW_FILE}.tmp"
    die "防火墙规则语法校验失败（nft -c），未应用任何更改。"
  fi
  if grep -E 'flush ruleset|DOCKER|PODMAN|CNI-' "${FW_FILE}.tmp" >/dev/null 2>&1; then
    rm -f "${FW_FILE}.tmp"
    die "生成的防火墙规则碰到了其它组件的表，已中止且未加载。"
  fi
  backup_firewall
  mv -f "${FW_FILE}.tmp" "$FW_FILE"; chmod 600 "$FW_FILE"
  local nftbin; nftbin=$(command -v nft)
  cat >"$FW_UNIT" <<UNIT
[Unit]
Description=proxy-oneclick nftables rules
Wants=network-pre.target
Before=network-pre.target
After=nftables.service firewalld.service
PartOf=nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${nftbin} -f ${FW_FILE}
ExecStop=-${nftbin} delete table inet ${NFT_TABLE}
ExecStop=-${nftbin} delete table ip ${NFT_TABLE}_nat
ExecStop=-${nftbin} delete table ip6 ${NFT_TABLE}_nat

[Install]
WantedBy=multi-user.target nftables.service
UNIT
  systemctl daemon-reload
  systemctl enable proxy-oneclick-fw >/dev/null 2>&1 || true
  # 先删旧的兼容 nat 表，再加载
  nft delete table ip "${NFT_TABLE}_nat" >/dev/null 2>&1 || true
  nft delete table ip6 "${NFT_TABLE}_nat" >/dev/null 2>&1 || true
  systemctl restart proxy-oneclick-fw || { nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true; die "加载防火墙规则失败，已回滚。"; }
  if [[ $FW_MODE == allow ]]; then
    ok "nftables 规则已加载（只放行代理端口，入站策略仍为接受，没有默认拒绝）。"
  else
    ok "nftables 规则已加载（入站默认拒绝）。"
  fi
  if [[ ${FW_HOST_SYNC:-0} == 1 ]]; then fw_host_sync; else fw_host_clear; fi
  fw_print_allows
}

# 只卸 nftables 表和服务，不动 ufw / firewalld 里已经同步的放行
remove_nft_rules() {
  if [[ $INIT_SYS == systemd ]]; then systemctl disable --now proxy-oneclick-fw >/dev/null 2>&1 || true; fi
  if have nft; then
    nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
    nft delete table ip "${NFT_TABLE}_nat" >/dev/null 2>&1 || true
    nft delete table ip6 "${NFT_TABLE}_nat" >/dev/null 2>&1 || true
  fi
  rm -f "$FW_UNIT" "$FW_FILE"
  sd_reload
}
remove_firewall() {
  # 只删本脚本的表和服务。不 flush ruleset，不碰 Docker / Podman / 系统其它链。
  # 同时删掉曾经写入 ufw / firewalld 的放行（只删清单里的条目）。
  fw_host_clear
  FW_HOST_SYNC=0
  remove_nft_rules
}

# ============================================================
#     NAT 模式：Hysteria2 端口跳跃（容器内 DNAT/REDIRECT，能力不足时自动降级）
# ============================================================
# 探测能否在本机网络命名空间内添加 nat 规则。输出后端: nft-inet / nft-ip / iptables
nat_hop_probe() {
  local t="${HOP_TABLE}_probe" fam
  if have nft; then
    for fam in inet ip; do
      if nft -f - >/dev/null 2>&1 <<NFT
table ${fam} ${t} {
  chain p {
    type nat hook prerouting priority -100; policy accept;
    udp dport 65000-65001 redirect to :65002
  }
}
NFT
      then
        nft delete table "$fam" "$t" >/dev/null 2>&1 || true
        echo "nft-${fam}"; return 0
      fi
      nft delete table "$fam" "$t" >/dev/null 2>&1 || true
    done
  fi
  if have iptables && iptables -t nat -N PROXY_OC_PROBE >/dev/null 2>&1; then
    local okk=0
    iptables -t nat -A PROXY_OC_PROBE -p udp --dport 65000:65001 -j REDIRECT --to-ports 65002 >/dev/null 2>&1 && okk=1
    iptables -t nat -F PROXY_OC_PROBE >/dev/null 2>&1 || true
    iptables -t nat -X PROXY_OC_PROBE >/dev/null 2>&1 || true
    (( okk )) && { echo iptables; return 0; }
  fi
  return 1
}

# shellcheck disable=SC2016  # 生成的脚本中的 $1/$0 需保持字面量
render_hop_script() { # 根据 HOP_BACKEND / HOP_RANGE(内部端口段，可多段) / HY2_PORT 生成 start|stop 脚本
  local p=$HY2_PORT bin fam seg nftset
  nftset=${HOP_RANGE//,/, }
  {
    echo '#!/bin/sh'
    echo "# 由 proxy-oneclick 生成：NAT 模式 Hysteria2 端口跳跃（内部 UDP ${HOP_RANGE} -> ${p}，后端 ${HOP_BACKEND}）"
    echo 'case "$1" in'
    echo '  start)'
    case $HOP_BACKEND in
      nft-inet|nft-ip)
        bin=$(command -v nft)
        local fams="inet"; [[ $HOP_BACKEND == nft-ip ]] && fams="ip ip6"
        for fam in $fams; do
          echo "    ${bin} -f - <<'NFT' || [ ${fam} = ip6 ]"
          echo "table ${fam} ${HOP_TABLE}"
          echo "delete table ${fam} ${HOP_TABLE}"
          echo "table ${fam} ${HOP_TABLE} {"
          echo "  chain prerouting {"
          echo "    type nat hook prerouting priority -100; policy accept;"
          echo "    udp dport { ${nftset} } counter redirect to :${p}"
          echo "  }"
          echo "}"
          echo "NFT"
        done
        echo '    ;;'
        echo '  stop)'
        for fam in inet ip ip6; do echo "    ${bin} delete table ${fam} ${HOP_TABLE} >/dev/null 2>&1"; done
        echo '    exit 0 ;;' ;;
      iptables)
        local t
        for t in iptables ip6tables; do
          bin=$(command -v "$t" 2>/dev/null) || continue
          local q=""; [[ $t == ip6tables ]] && q=" 2>/dev/null || true"
          echo "    ${bin} -t nat -N PROXY_OC_HOP >/dev/null 2>&1; ${bin} -t nat -F PROXY_OC_HOP${q}"
          for seg in ${HOP_RANGE//,/ }; do
            echo "    ${bin} -t nat -A PROXY_OC_HOP -p udp --dport ${seg/-/:} -j REDIRECT --to-ports ${p}${q}"
          done
          echo "    ${bin} -t nat -C PREROUTING -j PROXY_OC_HOP >/dev/null 2>&1 || ${bin} -t nat -A PREROUTING -j PROXY_OC_HOP${q}"
        done
        echo '    ;;'
        echo '  stop)'
        for t in iptables ip6tables; do
          bin=$(command -v "$t" 2>/dev/null) || continue
          echo "    ${bin} -t nat -D PREROUTING -j PROXY_OC_HOP >/dev/null 2>&1; ${bin} -t nat -F PROXY_OC_HOP >/dev/null 2>&1; ${bin} -t nat -X PROXY_OC_HOP >/dev/null 2>&1"
        done
        echo '    exit 0 ;;' ;;
    esac
    echo '  *) echo "usage: $0 start|stop"; exit 1 ;;'
    echo 'esac'
  } >"${HOP_SCRIPT}.tmp"
  chmod 700 "${HOP_SCRIPT}.tmp"; mv -f "${HOP_SCRIPT}.tmp" "$HOP_SCRIPT"
}

write_hop_service() {
  if is_openrc; then
    cat >"$HOP_RC" <<RC
#!/sbin/openrc-run
# 由 proxy-oneclick 生成（NAT 模式 Hysteria2 端口跳跃）
description="proxy-oneclick NAT Hysteria2 port hopping"
depend() {
  want net
  after net firewall
  before hysteria-server
}
start() {
  ebegin "Applying proxy-oneclick port hopping rules"
  /bin/sh "${HOP_SCRIPT}" start
  eend \$?
}
stop() {
  ebegin "Removing proxy-oneclick port hopping rules"
  /bin/sh "${HOP_SCRIPT}" stop
  eend 0
}
RC
    chmod 755 "$HOP_RC"
  else
    cat >"$HOP_UNIT" <<UNIT
[Unit]
Description=proxy-oneclick NAT Hysteria2 port hopping
After=network.target
Before=hysteria-server.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh ${HOP_SCRIPT} start
ExecStop=/bin/sh ${HOP_SCRIPT} stop

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
  fi
}

apply_nat_hop() {
  if (( ! HY2_ENABLED )) || [[ -z $HOP_RANGE ]]; then remove_nat_hop; HOP_BACKEND=""; return 0; fi
  step "配置 Hysteria2 端口跳跃（NAT 端口范围内）"
  local be
  if ! be=$(nat_hop_probe); then
    warn "当前环境无法添加 NAT 转发规则（LXC/OpenVZ 容器通常没有 CAP_NET_ADMIN，或内核不支持 nat 表），已关闭端口跳跃，Hysteria2 仅使用单端口 ${HY2_EXT_PORT}。"
    HOP_RANGE="" HOP_EXT_RANGE="" HOP_BACKEND=""
    remove_nat_hop
    return 0
  fi
  HOP_BACKEND=$be
  mkdir -p "$STATE_DIR"
  render_hop_script
  write_hop_service
  svc_enable proxy-oneclick-hop
  svc_restart proxy-oneclick-hop >/dev/null 2>&1 || true
  if ! svc_active proxy-oneclick-hop; then
    warn "端口跳跃规则加载失败，已关闭端口跳跃（Hysteria2 仍可通过单端口 ${HY2_EXT_PORT} 使用）。"
    HOP_RANGE="" HOP_EXT_RANGE="" HOP_BACKEND=""
    remove_nat_hop
    return 0
  fi
  ok "端口跳跃已启用（${be}）：外部 UDP ${HOP_EXT_RANGE} → 内部 ${HOP_RANGE} → ${HY2_PORT}"
}

remove_nat_hop() {
  [[ -f $HOP_SCRIPT ]] && { sh "$HOP_SCRIPT" stop >/dev/null 2>&1 || true; }
  if [[ -f $HOP_UNIT || -f $HOP_RC ]]; then svc_disable_stop proxy-oneclick-hop; fi
  rm -f "$HOP_UNIT" "$HOP_RC" "$HOP_SCRIPT"
  sd_reload
}

ask_extra_ports() {
  local t u
  detect_ssh_ports
  t=$(other_listen_ports tcp); u=$(other_listen_ports udp)
  # 排除自身端口
  t=$(for p in $t; do
    if [[ $p == "$XRAY_PORT" || $p == "$XHTTP_PORT" || $p == "$TROJAN_PORT" || $p == "$ANYTLS_PORT" || $p == "$XHTTP_TLS_PORT" || $p == "$WS_PORT" ]] || cert_port_owned "$p"; then
      continue
    fi
    echo "$p"
  done | tr '\n' ' ')
  u=$(for p in $u; do [[ $p == "$HY2_PORT" || $p == "$TUIC_PORT" ]] || echo "$p"; done | tr '\n' ' ')
  t=${t% } u=${u% }
  if [[ -n $t || -n $u ]]; then
    warn "检测到本机还有其它服务在对外监听：${t:+TCP [$t] }${u:+UDP [$u]}"
    if confirm "是否在防火墙中放行这些端口（避免影响现有服务）？" y; then
      EXTRA_TCP="$(tr ' ' '\n' <<<"$EXTRA_TCP $t" | awk 'NF' | sort -un | tr '\n' ' ')"; EXTRA_TCP=${EXTRA_TCP% }
      EXTRA_UDP="$(tr ' ' '\n' <<<"$EXTRA_UDP $u" | awk 'NF' | sort -un | tr '\n' ' ')"; EXTRA_UDP=${EXTRA_UDP% }
    fi
  fi
}

# 只打印，不改规则。端口和 render_firewall 用同一套开关。
FW_ALLOW_SEEN=""
fw_allow_seen() { [[ " ${FW_ALLOW_SEEN} " == *" ${1,,}/$2 "* ]]; }
fw_allow_row() { # $1 协议名 $2 tcp|udp $3 端口或范围
  local name=$1 fam=$2 port=$3
  [[ -n $port && $port != 0 ]] || return 0
  FW_ALLOW_SEEN+=" ${fam,,}/${port}"
  printf '  %s  %s  %s\n' "$(ui_pad "$name" 22)" "$(ui_pad "${fam^^}" 4)" "$port"
}
# 收集当前要放行的端口。范围用短横线，后面按防火墙自己的写法转换。
fw_want_has() { printf '%s\n' "$FW_WANT" | grep -Fxq -- "$1"; }
fw_want_add() {
  local fam=$1 port=$2 key
  [[ -n $port && $port != 0 ]] || return 0
  fam=${fam,,}
  key="${fam} ${port}"
  fw_want_has "$key" && return 0
  if [[ -n $FW_WANT ]]; then FW_WANT+=$'\n'"$key"; else FW_WANT=$key; fi
}
fw_collect_want() {
  local p seg
  FW_WANT=""
  (( ${REALITY_ENABLED:-0} == 1 )) && fw_want_add tcp "$XRAY_PORT"
  (( ${XHTTP_ENABLED:-0} == 1 )) && fw_want_add tcp "$XHTTP_PORT"
  (( ${HY2_ENABLED:-0} == 1 )) && fw_want_add udp "$HY2_PORT"
  (( ${TROJAN_ENABLED:-0} == 1 )) && fw_want_add tcp "$TROJAN_PORT"
  (( ${TUIC_ENABLED:-0} == 1 )) && fw_want_add udp "$TUIC_PORT"
  (( ${ANYTLS_ENABLED:-0} == 1 )) && fw_want_add tcp "$ANYTLS_PORT"
  (( ${XHTTP_TLS_ENABLED:-0} == 1 )) && fw_want_add tcp "$XHTTP_TLS_PORT"
  (( ${WS_ENABLED:-0} == 1 )) && fw_want_add tcp "$WS_PORT"
  cert_is_public && fw_want_add tcp "$SUB_PORT"
  for p in $SSH_PORTS; do fw_want_add tcp "$p"; done
  if (( ${HY2_ENABLED:-0} == 1 )) && [[ -n ${HOP_RANGE:-} ]]; then
    for seg in ${HOP_RANGE//,/ }; do fw_want_add udp "$seg"; done
  fi
  for p in ${EXTRA_TCP-}; do fw_want_add tcp "$p"; done
  for p in ${EXTRA_UDP-}; do fw_want_add udp "$p"; done
}
# ufw 编号规则里，只删带本脚本注释的那一条
# 按整条端口匹配，避免 443 命中 8443
fw_ufw_line_ours() { # $1 = 443/tcp 或 20000:50000/udp
  grep -E "(^|[^0-9:])${1}([^0-9:]|$)" | grep -F 'proxy-oneclick'
}
fw_ufw_delete_ours() {
  local spec=$1 n i
  have ufw || return 0
  for i in 1 2 3 4 5 6 7 8; do
    n=$(ufw status numbered 2>/dev/null | fw_ufw_line_ours "$spec" | head -n1 | sed -n 's/^[[:space:]]*\[ *\([0-9][0-9]*\)\].*/\1/p') || true
    [[ -n $n ]] || return 0
    ufw --force delete "$n" >/dev/null 2>&1 || return 0
  done
}
fw_ufw_ours_present() {
  ufw status 2>/dev/null | fw_ufw_line_ours "$1" >/dev/null
}
fw_fwd_zone() {
  local z
  z=$(firewall-cmd --get-default-zone 2>/dev/null) || z=""
  [[ -n $z ]] || z=public
  printf '%s' "$z"
}
fw_fwd_reload() {
  firewall-cmd --reload >/dev/null 2>&1 || warn "firewalld 重载失败，刚写入的端口可能还没生效。"
}
fw_line_has() { printf '%s\n' "$1" | grep -Fxq -- "$2"; }
# 按记录文件删掉以前写进去的 ufw / firewalld 规则
fw_host_clear() {
  [[ -s ${FW_HOST_FILE:-} ]] || return 0
  local kind a b c reload=0
  while read -r kind a b c _; do
    [[ -n $kind ]] || continue
    case $kind in
      ufw) fw_ufw_delete_ours "${b}/${a}" ;;
      firewalld)
        have firewall-cmd || continue
        firewall-cmd --permanent --zone="$a" --remove-port="${c}/${b}" >/dev/null 2>&1 || true
        reload=1
        ;;
    esac
  done <"$FW_HOST_FILE"
  (( reload )) && fw_fwd_reload
  rm -f "$FW_HOST_FILE"
  return 0
}
# allow，或用户选择保留 ufw/firewalld 时，把代理端口写进正在运行的防火墙
fw_host_sync() {
  if ! fw_ufw_active && ! fw_firewalld_active; then
    [[ -s ${FW_HOST_FILE:-} ]] && fw_host_clear
    return 0
  fi
  if [[ ${FW_HOST_SYNC:-0} != 1 ]]; then
    fw_host_clear
    return 0
  fi
  fw_collect_want
  local old="" kind a b c key spec proto port uport line
  local new="" reload=0 ufw_on=0 fwd_on=0 zone=""
  [[ -f $FW_HOST_FILE ]] && old=$(cat "$FW_HOST_FILE")
  fw_ufw_active && ufw_on=1
  if fw_firewalld_active; then fwd_on=1; zone=$(fw_fwd_zone); fi
  if [[ -n $old ]]; then
    while read -r kind a b c _; do
      [[ -n $kind ]] || continue
      case $kind in
        ufw)
          key="${a} ${b//:/-}"
          if (( ! ufw_on )) || ! fw_want_has "$key"; then fw_ufw_delete_ours "${b}/${a}"; fi
          ;;
        firewalld)
          key="${b} ${c}"
          if (( ! fwd_on )) || [[ $a != "$zone" ]] || ! fw_want_has "$key"; then
            firewall-cmd --permanent --zone="$a" --remove-port="${c}/${b}" >/dev/null 2>&1 || true
            reload=1
          fi
          ;;
      esac
    done <<<"$old"
  fi
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    proto=${line%% *}
    port=${line#* }
    if (( ufw_on )); then
      uport=${port//-/:}
      spec="${uport}/${proto}"
      if fw_ufw_ours_present "$spec"; then
        new+="ufw ${proto} ${uport}"$'\n'
      elif ufw allow "$spec" comment proxy-oneclick >/dev/null 2>&1; then
        new+="ufw ${proto} ${uport}"$'\n'
      else
        warn "写入 ufw 失败：${spec}"
      fi
    fi
    if (( fwd_on )); then
      if firewall-cmd --permanent --zone="$zone" --query-port="${port}/${proto}" >/dev/null 2>&1; then
        fw_line_has "$old" "firewalld ${zone} ${proto} ${port}" && new+="firewalld ${zone} ${proto} ${port}"$'\n'
      elif firewall-cmd --permanent --zone="$zone" --add-port="${port}/${proto}" >/dev/null 2>&1; then
        new+="firewalld ${zone} ${proto} ${port}"$'\n'
        reload=1
      else
        warn "写入 firewalld 失败：${port}/${proto}"
      fi
    fi
  done <<<"$FW_WANT"
  (( reload )) && fw_fwd_reload
  mkdir -p "$STATE_DIR"
  if [[ -n $new ]]; then
    printf '%s' "$new" >"$FW_HOST_FILE"
    chmod 600 "$FW_HOST_FILE"
    ok "已把代理端口同步到正在运行的 ufw / firewalld。"
  else
    rm -f "$FW_HOST_FILE"
  fi
  return 0
}
fw_print_host_sync() {
  [[ -s ${FW_HOST_FILE:-} ]] || return 0
  local kind a b c ufw_s="" fwd_s="" zone=""
  while read -r kind a b c _; do
    case $kind in
      ufw) ufw_s+="${a^^} ${b}、" ;;
      firewalld) zone=$a; fwd_s+="${b^^} ${c}、" ;;
    esac
  done <"$FW_HOST_FILE"
  [[ -n $ufw_s ]] && printf '已同步到 ufw（注释 proxy-oneclick）：%s\n' "${ufw_s%、}"
  [[ -n $fwd_s ]] && printf '已同步到 firewalld（区域 %s）：%s\n' "$zone" "${fwd_s%、}"
  return 0
}

fw_print_allows() {
  local p
  FW_ALLOW_SEEN=""
  if (( ${LAND_MODE:-0} )); then
    echo "本机防火墙：落地机不用这套默认拒绝规则。来源限制见白名单。"
    return 0
  fi
  if (( ${NAT_MODE:-0} )); then
    echo "本机防火墙：NAT 模式不设置。入站能不能进来，看服务商的端口映射。"
    return 0
  fi
  if [[ ${FW_MODE:-} == allow ]]; then
    echo "本机防火墙：只放行模式。没有把入站改成默认拒绝。"
    echo "下面这些端口写了 accept。其它端口仍按系统原来的策略处理，本脚本不会丢掉它们，也不会改 Docker 的表。"
    if have nft && ! nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
      echo "表 inet ${NFT_TABLE} 还没加载。下面是按配置应该放行的端口，重载后才生效。"
    fi
  elif (( ${FW_ENABLED:-0} == 1 )); then
    printf '%s本机防火墙：严格模式，入站默认拒绝。%s下面没有的端口，新连接会被丢掉。\n' "$C_WARN" "$C_NONE"
    echo "已建立的连接、本机回环和 ICMP 仍然放行。"
    if have nft && ! nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
      echo "表 inet ${NFT_TABLE} 还没加载。下面是按配置应该放行的端口，重载后才生效。"
    fi
  elif [[ ${FW_HOST_SYNC:-0} == 1 ]]; then
    echo "本机防火墙：没有写入 nftables 默认拒绝。代理端口写在正在运行的 ufw / firewalld 里。"
  else
    echo "本机防火墙：没有由本脚本接管，也没有做默认拒绝。"
    echo "下面是各协议要用的端口。系统防火墙和云安全组需要自己放行。"
  fi
  echo
  printf '  %s  %s  %s\n' "$(ui_pad "协议" 22)" "$(ui_pad "类型" 4)" "端口"
  (( ${REALITY_ENABLED:-0} == 1 )) && fw_allow_row "Reality" tcp "$XRAY_PORT"
  (( ${XHTTP_ENABLED:-0} == 1 )) && fw_allow_row "XHTTP" tcp "$XHTTP_PORT"
  (( ${HY2_ENABLED:-0} == 1 )) && fw_allow_row "Hysteria2" udp "$HY2_PORT"
  (( ${TROJAN_ENABLED:-0} == 1 )) && fw_allow_row "Trojan" tcp "$TROJAN_PORT"
  (( ${TUIC_ENABLED:-0} == 1 )) && fw_allow_row "TUIC" udp "$TUIC_PORT"
  (( ${ANYTLS_ENABLED:-0} == 1 )) && fw_allow_row "AnyTLS" tcp "$ANYTLS_PORT"
  (( ${XHTTP_TLS_ENABLED:-0} == 1 )) && fw_allow_row "CDN XHTTP" tcp "$XHTTP_TLS_PORT"
  (( ${WS_ENABLED:-0} == 1 )) && fw_allow_row "CDN WebSocket" tcp "$WS_PORT"
  if cert_is_public; then fw_allow_row "订阅" tcp "${SUB_PORT:-8447}"; fi
  if cert_http_open; then fw_allow_row "证书申请" tcp 80; fi
  if [[ -z ${SSH_PORTS// } ]]; then
    if [[ ${FW_MODE:-} == strict ]]; then
      printf '  %s  还没检测到。重载前先检测，避免把登录端口关在外面。\n' "$(ui_pad "SSH" 22)"
    else
      printf '  %s  未检测\n' "$(ui_pad "SSH" 22)"
    fi
  else
    for p in $SSH_PORTS; do fw_allow_row "SSH" tcp "$p"; done
  fi
  if (( ${HY2_ENABLED:-0} == 1 )) && [[ -n ${HOP_RANGE:-} ]]; then
    fw_allow_row "Hysteria2 端口跳跃" udp "$HOP_RANGE"
  fi
  for p in ${EXTRA_TCP-}; do fw_allow_seen tcp "$p" || fw_allow_row "额外放行" tcp "$p"; done
  for p in ${EXTRA_UDP-}; do fw_allow_seen udp "$p" || fw_allow_row "额外放行" udp "$p"; done
  echo
  if cert_http_open; then echo "证书申请的 TCP 80 只给 HTTP-01 续期，不提供订阅，也不跑代理。"; fi
  if cert_is_public; then echo "订阅是客户端拉取节点的 HTTPS，不是 Reality。"; fi
  (( ${XHTTP_TLS_ENABLED:-0} == 1 || ${WS_ENABLED:-0} == 1 )) && echo "CDN 这两行给 Cloudflare 回源，不是 Reality。"
  if (( ${HY2_ENABLED:-0} == 1 )) && [[ -n ${HOP_RANGE:-} ]]; then
    echo "端口跳跃的 UDP ${HOP_RANGE} 会转到 Hysteria2 的 UDP ${HY2_PORT}。"
  fi
  if [[ ${FW_MODE:-} == allow ]]; then
    echo "云安全组若有限制，仍要放行上面这些端口。Docker 自己的表没有改。"
    if ! fw_ufw_active && ! fw_firewalld_active; then
      echo "本机没有正在运行的 ufw 或 firewalld，不需要再同步端口。"
    fi
  elif [[ ${FW_HOST_SYNC:-0} == 1 ]]; then
    echo "云安全组若有限制，仍要放行上面这些端口。"
  elif (( ${FW_ENABLED:-0} == 1 )); then
    echo "云安全组要另外放行上面这些端口。脚本改不到云上的防火墙。"
  fi
  fw_print_host_sync
  return 0
}

cloud_fw_reminder() {
  echo
  hr
  if (( NAT_MODE )); then
    printf '%s请确认服务商端口映射%s  地址 %s\n' "$C_WARN" "$C_NONE" "$(server_addr)"
    (( REALITY_ENABLED )) && printf 'TCP   %-7s → 本机 %-7s  VLESS-REALITY\n' "$XRAY_EXT_PORT" "$XRAY_PORT"
    (( XHTTP_ENABLED )) && printf 'TCP   %-7s → 本机 %-7s  VLESS-XHTTP\n' "$XHTTP_EXT_PORT" "$XHTTP_PORT"
    (( TROJAN_ENABLED )) && printf 'TCP   %-7s → 本机 %-7s  Trojan\n' "$TROJAN_EXT_PORT" "$TROJAN_PORT"
    (( ANYTLS_ENABLED )) && printf 'TCP   %-7s → 本机 %-7s  AnyTLS\n' "$ANYTLS_EXT_PORT" "$ANYTLS_PORT"
    if (( HY2_ENABLED )); then
      printf 'UDP   %-7s → 本机 %-7s  Hysteria2\n' "$HY2_EXT_PORT" "$HY2_PORT"
      [[ -n $HOP_RANGE ]] && printf 'UDP   %-7s → 本机 %-7s  端口跳跃\n' "$HOP_EXT_RANGE" "$HOP_RANGE"
    fi
    (( TUIC_ENABLED )) && printf 'UDP   %-7s → 本机 %-7s  TUIC v5\n' "$TUIC_EXT_PORT" "$TUIC_PORT"
    if (( HY2_ENABLED )) && [[ $HY2_EXT_PORT == "$XRAY_EXT_PORT" ]]; then
      echo "Reality 与 Hysteria2 共用外部端口 ${XRAY_EXT_PORT}，该映射必须同时包含 TCP 和 UDP。"
    else
      echo "若服务商只映射 TCP，Hysteria2 将无法使用。"
    fi
    hr
    return 0
  fi
  fw_print_allows
  echo "Oracle Cloud 镜像可能还有自带 iptables。"
  hr
}

# ============================================================
#                        fail2ban
# ============================================================
setup_fail2ban() {
  have fail2ban-server || { warn "未安装 fail2ban，跳过 SSH 防爆破配置。"; return 0; }
  step "配置 fail2ban（SSH：10 分钟内失败 5 次封禁 1 小时）"
  detect_ssh_ports
  mkdir -p /etc/fail2ban/jail.d
  cat >"$F2B_JAIL" <<F2B
# 由 proxy-oneclick 生成
[sshd]
enabled   = true
port      = $(tr ' ' ',' <<<"$SSH_PORTS")
backend   = systemd
maxretry  = 5
findtime  = 10m
bantime   = 1h
banaction = nftables-multiport
banaction_allports = nftables-allports
F2B
  systemctl enable fail2ban >/dev/null 2>&1 || true
  if systemctl restart fail2ban >/dev/null 2>&1; then
    ok "fail2ban 已启用。"
  else
    warn "fail2ban 启动失败（可稍后执行 systemctl status fail2ban 排查），不影响代理使用。"
  fi
}

