# ============================================================
#                        管理功能
# ============================================================
need_installed() {
  load_state
  (( INSTALLED )) || die "尚未安装，请先选择「安装」。"
  [[ -n $INIT_SYS ]] || detect_init
  [[ -x $XRAY_BIN ]] || die "未找到 Xray，请重新安装。"
}

apply_all() { # 重新生成配置并重启（在修改参数后调用）
  if (( LAND_MODE )); then land_apply; return; fi
  save_state
  apply_proto_services
}

menu_change_sni() {
  need_node; mktmp
  detect_ip; detect_geo
  (( NAT_MODE )) || SERVER_ADDR=${PUBLIC_IP4:-$PUBLIC_IP6}
  local old=$SNI
  select_sni
  [[ $SNI == "$old" ]] && { info "SNI 未变化。"; return 0; }
  SNI_TARGET="${SNI}:443"
  mldsa_decide
  apply_all
  ( trap - ERR; set +e; reality_selftest ) || true
  if tls_present_real; then
    ok "SNI 已由 ${old} 更换为 ${SNI}。REALITY / XHTTP / Trojan 需要更新链接。Hysteria2 / TUIC / AnyTLS 仍使用 ${CERT_DOMAIN} 的证书。"
  else
    ok "SNI 已由 ${old} 更换为 ${SNI}。客户端需要更新链接（Hysteria2 证书指纹也已变化）。"
  fi
  show_info
}

menu_regen_keys() {
  need_installed
  if (( LAND_MODE )); then land_menu_key; return; fi
  warn "将重新生成 UUID、x25519 密钥、ShortId、ML-DSA-65 密钥、XHTTP 路径、CDN 路径、CDN 的 VLESS Encryption 密钥，以及 Hysteria2 / Trojan / TUIC / AnyTLS 密码。所有旧客户端将失效。已关闭的协议也会换新密钥，但不会被重新打开。"
  (( OPT_AUTO )) || confirm "确认重新生成？" n || return 0
  gen_xray_keys
  HY2_PASS=$(rand_pass)
  XHTTP_PATH="/$(rand_hex 8)"
  XHTTP_TLS_PATH="/xhttp-$(rand_hex 8)"
  WS_PATH="/ws-$(rand_hex 8)"
  VLESS_ENC_SEED="" VLESS_ENC_CLIENT=""
  TROJAN_PASS=$(rand_pass)
  TUIC_PASS=$(rand_pass)
  ANYTLS_PASS=$(rand_pass)
  if (( HY2_ENABLED || TUIC_ENABLED || ANYTLS_ENABLED )) && ! tls_present_real; then gen_hy2_cert; fi
  apply_all
  ok "已重新生成全部密钥。"
  show_info
}

menu_change_ports() {
  need_installed
  if (( LAND_MODE )); then land_menu_port; return; fi
  nat_pref_guard || return 0
  if (( NAT_MODE )); then menu_change_ports_nat; return; fi
  local oldx=$XRAY_PORT oldh=$HY2_PORT oldxh=${XHTTP_PORT:-}
  choose_ports_interactive
  if (( HY2_ENABLED )) && [[ ! -x $HY_BIN ]]; then install_hysteria; fi
  if (( ! HY2_ENABLED )) && [[ -x $HY_BIN ]]; then remove_hysteria; fi
  if sb_needed && [[ ! -x $SB_BIN ]]; then install_singbox; fi
  if ! sb_needed && [[ -x $SB_BIN ]]; then svc_disable_stop sing-box; fi
  apply_all
  local extra=""
  if (( HY2_ENABLED )); then extra+="，UDP ${oldh} -> ${HY2_PORT}，跳跃 ${HOP_RANGE:-关闭}"; fi
  if (( XHTTP_ENABLED )) && ! xhttp_shared; then extra+="，XHTTP TCP ${oldxh} -> ${XHTTP_PORT}"; fi
  ok "端口已更新：TCP ${oldx} -> ${XRAY_PORT}${extra}"
  cloud_fw_reminder
}
menu_change_ports_nat() {
  local oldx=$XRAY_EXT_PORT oldh=$HY2_EXT_PORT oldxh=${XHTTP_EXT_PORT:-}
  detect_os; detect_virt
  local s3=$OPT_NAT_EXT s4=$OPT_NAT_ADDR
  # 保留 --port / --hy2-port / --xhttp-port，命令行可以直接改。映射列表仍按已保存的重新确认。
  OPT_NAT_EXT="" OPT_NAT_ADDR=""
  choose_nat_addr
  choose_nat_ports
  OPT_NAT_EXT=$s3 OPT_NAT_ADDR=$s4
  if (( HY2_ENABLED )) && [[ ! -x $HY_BIN ]]; then install_hysteria; fi
  if (( ! HY2_ENABLED )) && [[ -x $HY_BIN ]]; then remove_hysteria; fi
  if sb_needed && [[ ! -x $SB_BIN ]]; then install_singbox; fi
  if ! sb_needed && [[ -x $SB_BIN ]]; then svc_disable_stop sing-box; fi
  apply_all
  local extra=""
  if (( HY2_ENABLED )); then extra+="，Hy2 外部端口 ${oldh:-无} -> ${HY2_EXT_PORT}，跳跃 ${HOP_EXT_RANGE:-关闭}"; fi
  if (( XHTTP_ENABLED )) && ! xhttp_shared; then extra+="，XHTTP 外部端口 ${oldxh:-无} -> ${XHTTP_EXT_PORT}"; fi
  ok "已更新：Reality 外部端口 ${oldx} -> ${XRAY_EXT_PORT}${extra}"
  cloud_fw_reminder
}
choose_ports_interactive() {
  # 保留 --port / --hy2-port / --xhttp-port。没写的那些会在 choose_ports 里询问。
  choose_ports
}

menu_users() {
  need_node
  while :; do
    echo; hr; _green "  用户管理（VLESS 额外用户）"; hr
    echo "  主用户: ${UUID}  (main)"
    local i=0 u r
    if [[ -s $USERS_FILE ]]; then
      while IFS=$'\t' read -r u r; do i=$((i + 1)); printf '  %d) %s  (%s)\n' "$i" "$u" "$r"; done <"$USERS_FILE"
    else
      echo "  （暂无额外用户）"
    fi
    hr
    echo "  1) 添加用户    2) 删除用户    3) 查看某用户链接    0) 返回"
    local c; ask c "请选择" "0"
    case $c in
      1)
        local remark nu
        ask remark "备注名（字母/数字/-/_）" "user$((i + 1))"
        remark=$(tr -cd 'A-Za-z0-9_-' <<<"$remark"); [[ -n $remark ]] || remark="user$((i + 1))"
        if [[ -s $USERS_FILE ]] && cut -f2 "$USERS_FILE" | grep -qx "$remark"; then warn "备注名已存在。"; continue; fi
        ask nu "UUID（留空自动生成）" ""
        [[ -n $nu ]] || nu=$("$XRAY_BIN" uuid)
        [[ $nu =~ ^[0-9a-fA-F-]{36}$ ]] || { warn "UUID 格式无效。"; continue; }
        printf '%s\t%s\n' "$nu" "$remark" >>"$USERS_FILE"; chmod 600 "$USERS_FILE"
        if xray_inbound_needed; then write_xray_config; restart_xray; fi
        save_info
        ok "已添加用户 ${remark}"
        if (( REALITY_ENABLED )); then
          node_link_head 1 "额外用户 ${remark} · Reality" "${NODE_NAME}-${remark}" "$(server_addr)" "$(pub_xray_port)  TCP"
          node_link_uri "$(vless_link "$nu" "${NODE_NAME}-${remark}" 0)"
          echo; print_qr "$(vless_link "$nu" "${NODE_NAME}-${remark}" 0)"
        fi
        if (( XHTTP_ENABLED )); then
          node_link_head 1 "额外用户 ${remark} · XHTTP" "${NODE_NAME}-XHTTP-${remark}" "$(server_addr)" "$(pub_xhttp_port)  TCP"
          node_link_uri "$(vless_xhttp_link "$nu" "${NODE_NAME}-XHTTP-${remark}" 0)"
          echo; print_qr "$(vless_xhttp_link "$nu" "${NODE_NAME}-XHTTP-${remark}" 0)"
        fi
        if (( XHTTP_TLS_ENABLED )) && tls_for_cdn; then
          node_link_head 1 "额外用户 ${remark} · XHTTP+TLS" "${NODE_NAME}-XHTTP-TLS-${remark}" "$CERT_DOMAIN" "${XHTTP_TLS_PORT}  TCP"
          node_link_uri "$(cdn_xhttp_link "$nu" "${NODE_NAME}-XHTTP-TLS-${remark}")"
          echo; print_qr "$(cdn_xhttp_link "$nu" "${NODE_NAME}-XHTTP-TLS-${remark}")"
        fi
        if (( WS_ENABLED )) && tls_for_cdn; then
          node_link_head 1 "额外用户 ${remark} · WebSocket+TLS" "${NODE_NAME}-WS-TLS-${remark}" "$CERT_DOMAIN" "${WS_PORT}  TCP"
          node_link_uri "$(cdn_ws_link "$nu" "${NODE_NAME}-WS-TLS-${remark}")"
          echo; print_qr "$(cdn_ws_link "$nu" "${NODE_NAME}-WS-TLS-${remark}")"
        fi ;;
      2)
        (( i > 0 )) || { warn "没有可删除的用户。"; continue; }
        local n; ask n "输入要删除的序号" ""
        if ! [[ $n =~ ^[0-9]+$ ]] || (( n < 1 || n > i )); then warn "序号无效。"; continue; fi
        sed -i "${n}d" "$USERS_FILE"
        if xray_inbound_needed; then write_xray_config; restart_xray; fi
        save_info
        ok "已删除。" ;;
      3)
        (( i > 0 )) || { warn "没有额外用户。"; continue; }
        local n; ask n "输入序号" "1"
        if ! [[ $n =~ ^[0-9]+$ ]] || (( n < 1 || n > i )); then warn "序号无效。"; continue; fi
        IFS=$'\t' read -r u r < <(sed -n "${n}p" "$USERS_FILE")
        if (( REALITY_ENABLED )); then
          vless_link "$u" "${NODE_NAME}-${r}" 1; echo; echo
          print_qr "$(vless_link "$u" "${NODE_NAME}-${r}" 0)"
        fi
        if (( XHTTP_ENABLED )); then
          echo; vless_xhttp_link "$u" "${NODE_NAME}-XHTTP-${r}" 0; echo
        fi
        if (( XHTTP_TLS_ENABLED )) && tls_for_cdn; then
          echo; cdn_xhttp_link "$u" "${NODE_NAME}-XHTTP-TLS-${r}"; echo
        fi
        if (( WS_ENABLED )) && tls_for_cdn; then
          echo; cdn_ws_link "$u" "${NODE_NAME}-WS-TLS-${r}"; echo
        fi ;;
      *) return 0 ;;
    esac
  done
}

menu_update() {
  if [[ -n ${OPT_ROLLBACK:-} ]]; then
    [[ -n ${OPT_XRAY_VER:-}${OPT_HY2_VER:-}${OPT_SINGBOX_VER:-} ]] && die "回滚和指定版本不能一起用。"
    do_rollback "$OPT_ROLLBACK"
    return 0
  fi
  need_installed
  if [[ -n ${OPT_XRAY_VER:-}${OPT_HY2_VER:-}${OPT_SINGBOX_VER:-} ]]; then
    do_pinned_update
    return 0
  fi
  preflight
  echo "  1) 更新 Xray-core    2) 更新 Hysteria2    3) 更新本脚本"
  echo "  4) 全部更新（含 sing-box）    5) 回滚到备份    0) 返回"
  echo "  指定版本: proxy update --xray-ver <版本>  --hy2-ver <版本>  --singbox-ver <版本>"
  local c; ask c "请选择" "4"
  case $c in
    1) install_xray; if xray_inbound_needed; then write_xray_config; restart_xray; else info "当前没有 Xray 入站，已跳过。"; fi ;;
    2) (( HY2_ENABLED )) || { warn "未启用 Hysteria2。"; return 0; }; install_hysteria; write_hy2_config; restart_hy2 ;;
    3) update_script ;;
    4) install_xray
       if xray_inbound_needed; then write_xray_config; restart_xray; fi
       if (( HY2_ENABLED )); then install_hysteria; write_hy2_config; restart_hy2; fi
       if sb_needed; then install_singbox; write_singbox_config; restart_singbox; fi
       update_script ;;
    5) echo "  1) Xray    2) Hysteria2    3) sing-box    4) 全部    0) 返回"
       local w; ask w "回滚哪一个" "0"
       case $w in
         1) do_rollback xray ;;
         2) do_rollback hy2 ;;
         3) do_rollback singbox ;;
         4) do_rollback all ;;
         *) return 0 ;;
       esac ;;
    *) return 0 ;;
  esac
}
do_pinned_update() { # proxy update --xray-ver / --hy2-ver / --singbox-ver，不进菜单
  need_installed
  preflight
  local did=0
  if [[ -n ${OPT_XRAY_VER:-} ]]; then
    install_xray
    if xray_inbound_needed; then write_xray_config; restart_xray
    else info "当前没有 Xray 入站，已跳过重启。"; fi
    did=1
  fi
  if [[ -n ${OPT_HY2_VER:-} ]]; then
    (( HY2_ENABLED )) || die "未启用 Hysteria2，不能用 --hy2-ver 更新。请先打开 Hysteria2。"
    install_hysteria
    write_hy2_config
    restart_hy2
    did=1
  fi
  if [[ -n ${OPT_SINGBOX_VER:-} ]]; then
    sb_needed || die "未启用 TUIC / AnyTLS，不能用 --singbox-ver 更新。请先打开其中一项。"
    install_singbox
    write_singbox_config
    restart_singbox
    did=1
  fi
  (( did )) || die "没有要更新的组件。"
}

update_script() {
  load_state
  mktmp
  if [[ $SCRIPT_URL == *YOUR_GITHUB* ]]; then warn "脚本中 SCRIPT_URL 仍为占位符，无法在线更新脚本。"; return 0; fi
  if fetch -o "${TMP_DIR}/proxy.sh" "$SCRIPT_URL" && bash -n "${TMP_DIR}/proxy.sh"; then
    local newv; newv=$(grep -m1 '^readonly SCRIPT_VERSION=' "${TMP_DIR}/proxy.sh" | cut -d'"' -f2)
    if [[ -n $newv ]] && ! ver_ge "$newv" "$SCRIPT_VERSION"; then
      warn "在线版本 ${newv} 低于当前版本 ${SCRIPT_VERSION}。"
      if (( NAT_MODE )) && ! grep -q 'NAT_MODE' "${TMP_DIR}/proxy.sh"; then
        warn "在线版本不支持 NAT 模式，更新后将无法管理当前安装，已取消。"; return 0
      fi
      if { (( LAND_MODE )) || [[ -n $RELAY_LINK ]]; } && ! grep -q 'LAND_MODE' "${TMP_DIR}/proxy.sh"; then
        warn "在线版本不支持落地机 / 落地转发，更新后将无法管理当前配置，已取消。"; return 0
      fi
      (( OPT_AUTO )) && { warn "自动模式下不降级，已取消。"; return 0; }
      confirm "仍要降级吗？" n || return 0
    fi
    install -m 755 "${TMP_DIR}/proxy.sh" "$BIN_PATH"
    ok "脚本已更新为 $(grep -m1 '^readonly SCRIPT_VERSION=' "$BIN_PATH" | cut -d'"' -f2)"
  else
    warn "脚本更新失败。"
  fi
}

menu_status() {
  load_state
  [[ -n $INIT_SYS ]] || detect_init
  echo; hr; _green "  服务状态$( ((LAND_MODE)) && echo '（落地机）')$( ((NAT_MODE)) && echo '（NAT 模式）')"; hr
  local s svcs="xray hysteria-server sing-box proxy-oneclick-fw fail2ban"
  if (( NAT_MODE )); then svcs="xray hysteria-server sing-box"; [[ -n $HOP_RANGE ]] && svcs+=" proxy-oneclick-hop"; fi
  if (( LAND_MODE )); then svcs="xray"; [[ -f $LAND_FW_UNIT || -f $LAND_FW_RC ]] && svcs+=" proxy-oneclick-land-fw"; fi
  cert_is_public && svcs+=" proxy-oneclick-sub"
  for s in $svcs; do
    local st; st=$(svc_state "$s")
    [[ -z $st ]] && st="unknown"
    if [[ $st == active ]]; then printf '  %-22s %s\n' "$s" "${C_GREEN}运行中${C_NONE}"
    elif [[ $st != none ]]; then printf '  %-22s %s\n' "$s" "${C_RED}${st}${C_NONE}"
    else printf '  %-22s %s\n' "$s" "未安装"; fi
  done
  [[ -x $XRAY_BIN ]] && printf '  Xray 版本:      %s\n' "$("$XRAY_BIN" version | awk 'NR==1{print $2}')"
  [[ -x $HY_BIN ]] && printf '  Hysteria2 版本: %s\n' "$("$HY_BIN" version 2>/dev/null | awk '/^Version:/{print $2}')"
  [[ -x $SB_BIN ]] && printf '  sing-box 版本:  %s\n' "$("$SB_BIN" version 2>/dev/null | awk 'NR==1{print $NF}')"
  if (( ! LAND_MODE )); then
    echo
    printf '%s已装协议%s\n' "$C_TITLE" "$C_NONE"
    ui_proto_line "$REALITY_ENABLED" "VLESS + REALITY + Vision" "TCP $(pub_xray_port)"
    ui_proto_line "$XHTTP_ENABLED" "VLESS + XHTTP + REALITY" "TCP $(pub_xhttp_port)$(xhttp_shared && echo '（与 Vision 共用）')"
    ui_proto_line "$HY2_ENABLED" "Hysteria2" "UDP $(pub_hy2_port)"
    hr
    printf '%s可选协议%s\n' "$C_TITLE" "$C_NONE"
    ui_proto_line "$TROJAN_ENABLED" "Trojan + REALITY" "TCP $(pub_trojan_port)"
    ui_proto_line "$TUIC_ENABLED" "TUIC v5" "UDP $(pub_tuic_port)"
    ui_proto_line "$ANYTLS_ENABLED" "AnyTLS" "TCP $(pub_anytls_port)"
    ui_proto_line "$XHTTP_TLS_ENABLED" "VLESS + XHTTP + TLS（CDN）" "TCP ${XHTTP_TLS_PORT}"
    ui_proto_line "$WS_ENABLED" "VLESS + WebSocket + TLS（CDN）" "TCP ${WS_PORT}"
    if cdn_wanted; then printf '  %s\n' "$(ui_pad "CDN 的 VLESS Encryption" 28)$(vless_enc_label)"; fi
  fi
  if (( LAND_MODE )); then
    printf '  落地机:         Shadowsocks 2022 %s，端口 %s (TCP+UDP)%s\n' "$LAND_METHOD" "$(pub_xray_port)" "$( ((NAT_MODE)) && echo " → 本机 ${XRAY_PORT}")"
    printf '  出口:           %s\n' "$(land_egress_label)"
    if land_raw_active; then
      printf '  原样转发:       本机 %s → %s:%s（Xray 不监听该端口）\n' "$XRAY_PORT" "$(host_fmt "$FWD_H")" "$FWD_P"
    elif land_relay_active; then
      printf '  加密转发:       下一跳 %s:%s（%s）\n' "$(host_fmt "$RELAY_H")" "$RELAY_P" "$RELAY_M"
    fi
    printf '  来源白名单:     %s\n' "${LAND_ALLOW:-未设置（不限制）}$([[ -n $LAND_ALLOW ]] && { land_fw_active && echo '（Xray 路由 + nftables）' || echo '（Xray 路由）'; })"
  else
    printf '  落地转发:       %s\n' "$(relay_status_line)"
    (( NAT_MODE )) && nat_status_lines
  fi
  printf '  拥塞控制:       %s / %s\n' "$(sysval net.ipv4.tcp_congestion_control)" "$(sysval net.core.default_qdisc)"
  if [[ -f $TUNE_CUR ]]; then printf '  网络调优:       预设 %s / 缓冲区 %s（详情: proxy tune status）\n' "$(tune_cur_get PRESET)" "$(tune_cur_get BUFFER_EFF)"
  elif [[ -f $SYSCTL_FILE ]]; then printf '  网络调优:       v1.1.x 默认（BBR + fq）\n'
  else printf '  网络调优:       未应用（proxy tune）\n'; fi
  printf '  时间同步:       %s\n' "$(time_sync_status)"
  if (( ${CERT_ON:-0} == 1 )) || svc_exists proxy-oneclick-sub; then
    printf '  证书:           %s  %s  到期 %s\n' "$(cert_kind_label)" "${CERT_DOMAIN:-未设置}" "$(cert_expiry_text)"
    if [[ ${CERT_CA:-letsencrypt} == cloudflare || ${CERT_PUBLIC:-1} != 1 ]]; then
      printf '  订阅 HTTPS:     未开启。源站证书只有 Cloudflare 信任，不能给浏览器和直连客户端。\n'
    elif svc_active proxy-oneclick-sub; then printf '  订阅 HTTPS:     运行中（TCP %s，明文 HTTP 不提供）\n' "$SUB_PORT"
    else printf '  订阅 HTTPS:     未运行（TCP %s）\n' "$SUB_PORT"; fi
  fi
  echo
  fw_print_allows
  echo
  _cyan "  监听端口："
  local lx lh
  lx=$(ss -Htlnp 2>/dev/null | awk '/xray/{print "   TCP "$4"  xray"}') || true
  lh=$(ss -Hulnp 2>/dev/null | awk '/hysteria/{print "   UDP "$4"  hysteria"}') || true
  if (( LAND_MODE )); then
    lh=$(ss -Hulnp 2>/dev/null | awk '/xray/{print "   UDP "$4"  xray"}') || true
    [[ -n $lh ]] || { lh=$(ss -Huln "sport = :${XRAY_PORT}" 2>/dev/null | awk '{print "   UDP "$4"  (xray)"}') || true; }
  fi
  # 看不到进程名时（容器权限受限）按配置端口显示
  if [[ -z $lx ]]; then lx=$(ss -Htln "sport = :${XRAY_PORT}" 2>/dev/null | awk '{print "   TCP "$4"  (xray)"}') || true; fi
  (( HY2_ENABLED )) && [[ -z $lh ]] && { lh=$(ss -Huln "sport = :${HY2_PORT}" 2>/dev/null | awk '{print "   UDP "$4"  (hysteria)"}') || true; }
  [[ -n $lx ]] && echo "$lx"
  [[ -n $lh ]] && echo "$lh"
  if (( ! NAT_MODE )) && have fail2ban-client && svc_active fail2ban; then
    echo; _cyan "  fail2ban (sshd)："
    fail2ban-client status sshd 2>/dev/null | sed 's/^/   /' || true
  fi
  echo
  if (( LAND_MODE )); then
    echo "  1) 查看 Xray 日志   3) 查看 nftables 白名单规则   4) 实时跟踪 Xray 日志   0) 返回"
  elif (( NAT_MODE )) && [[ -z $HOP_RANGE ]]; then
    echo "  1) 查看 Xray 日志   2) 查看 Hysteria2 日志   4) 实时跟踪 Xray 日志   0) 返回"
  elif (( NAT_MODE )); then
    echo "  1) 查看 Xray 日志   2) 查看 Hysteria2 日志   3) 查看端口跳跃规则   4) 实时跟踪 Xray 日志   0) 返回"
  else
    echo "  1) 查看 Xray 日志   2) 查看 Hysteria2 日志   3) 查看 nftables 原文   4) 实时跟踪 Xray 日志   0) 返回"
  fi
  local c; ask c "请选择" "0"
  case $c in
    1) svc_logs xray 80 ;;
    2) svc_logs hysteria-server 80 ;;
    3) if (( NAT_MODE )); then if [[ -n $HOP_RANGE ]]; then show_hop_rules; fi
       elif (( LAND_MODE )); then
         nft list table inet "$LAND_NFT_TABLE" 2>/dev/null || warn "未启用 nftables 白名单。"
         if [[ ${FWD_ON:-0} == 1 ]]; then echo; land_fwd_show; fi
       else
         echo "下面是 nftables 原文。哪一端口属于哪个协议，看上面的中文列表。"
         nft list table inet "$NFT_TABLE" 2>/dev/null || warn "未找到本脚本的防火墙表。"
         nft list table ip "${NFT_TABLE}_nat" 2>/dev/null || true
       fi ;;
    4) svc_follow xray ;;
    *) return 0 ;;
  esac
}

nat_status_lines() {
  printf '  公网地址:       %s\n' "${SERVER_ADDR:-未设置}"
  printf '  映射端口:       %s%s\n' "${NAT_PORTS:-未设置}" "${NAT_EXCLUDE:+（排除 ${NAT_EXCLUDE}）}"
  (( REALITY_ENABLED )) && printf '  Reality:        外部 TCP %s → 本机 %s\n' "${XRAY_EXT_PORT:-?}" "$XRAY_PORT"
  (( XHTTP_ENABLED )) && printf '  XHTTP:          外部 TCP %s → 本机 %s\n' "${XHTTP_EXT_PORT:-?}" "$XHTTP_PORT"
  (( TROJAN_ENABLED )) && printf '  Trojan:         外部 TCP %s → 本机 %s\n' "${TROJAN_EXT_PORT:-?}" "$TROJAN_PORT"
  (( ANYTLS_ENABLED )) && printf '  AnyTLS:         外部 TCP %s → 本机 %s\n' "${ANYTLS_EXT_PORT:-?}" "$ANYTLS_PORT"
  if (( HY2_ENABLED )); then
    printf '  Hysteria2:      外部 UDP %s → 本机 %s%s\n' "${HY2_EXT_PORT:-?}" "$HY2_PORT" "$([[ $HY2_EXT_PORT == "$XRAY_EXT_PORT" ]] && echo '（与 Reality 共用端口）')"
    if [[ -n $HOP_RANGE ]]; then printf '  端口跳跃:       外部 UDP %s → 本机 %s（%s）\n' "$HOP_EXT_RANGE" "$HOP_RANGE" "${HOP_BACKEND:-?}"
    else printf '  端口跳跃:       关闭\n'; fi
  fi
  (( TUIC_ENABLED )) && printf '  TUIC:           外部 UDP %s → 本机 %s\n' "${TUIC_EXT_PORT:-?}" "$TUIC_PORT"
  printf '  虚拟化 / init:  %s / %s\n' "${VIRT:-未知}" "${INIT_SYS:-未知}"
  local envs; envs=$(go_mem_env); envs=${envs//$'\n'/ }
  printf '  内存:           %s MB%s\n' "$(mem_limit_mb)" "${envs:+（${envs}）}"
}

show_hop_rules() {
  if [[ -z $HOP_RANGE ]]; then info "端口跳跃未启用。"; return 0; fi
  case $HOP_BACKEND in
    nft-inet) nft list table inet "$HOP_TABLE" 2>/dev/null || warn "未找到端口跳跃规则表。" ;;
    nft-ip) nft list table ip "$HOP_TABLE" 2>/dev/null || warn "未找到端口跳跃规则表。"; nft list table ip6 "$HOP_TABLE" 2>/dev/null || true ;;
    iptables) iptables -t nat -S PROXY_OC_HOP 2>/dev/null || warn "未找到端口跳跃规则链。" ;;
    *) warn "未知后端: ${HOP_BACKEND}" ;;
  esac
}

menu_nat() {
  need_installed
  if (( LAND_MODE )); then land_menu_port; return; fi
  (( NAT_MODE )) || { warn "当前不是 NAT 模式。"; return 0; }
  detect_virt
  echo; hr; _green "  NAT 信息 / 端口跳跃"; hr
  nat_status_lines
  hr
  if [[ -n $HOP_RANGE ]]; then
    echo "  1) 修改公网地址 / 映射端口 / 端口跳跃   2) 重新加载端口跳跃规则   3) 查看端口跳跃规则   0) 返回"
  else
    echo "  1) 修改公网地址 / 映射端口 / 端口跳跃   2) 重新加载端口跳跃规则   0) 返回"
  fi
  local c; ask c "请选择" "0"
  case $c in
    1) menu_change_ports_nat ;;
    2) apply_nat_hop; save_state; save_info ;;
    3) if [[ -n $HOP_RANGE ]]; then show_hop_rules; fi ;;
    *) return 0 ;;
  esac
}

speed_try() { # $1 URL；成功时输出 "Mbps 已下载MB 秒数"，失败返回 1
  local out rc=0 code size t
  out=$(curl "-${IPFAM}" -so /dev/null --connect-timeout 8 -m 20 -w '%{http_code} %{size_download} %{time_total}' "$1" 2>/dev/null) || rc=$?
  read -r code size t <<<"$out"
  # 必须是 HTTP 200；正常结束 (0) 或到达 20 秒上限 (28) 都可以，只要下载量 ≥ 10MB
  [[ $code == 200 ]] || return 1
  (( rc == 0 || rc == 28 )) || return 1
  awk -v s="${size:-0}" -v t="${t:-0}" 'BEGIN{ if (s < 10000000 || t <= 0) exit 1; printf "%.1f %.0f %.1f", s*8/t/1000000, s/1000000, t }'
}

menu_speed() {
  load_state
  echo; hr; _green "  网络测速 / 延迟提示"; hr
  if (( NAT_MODE )) && ! curl -4 -fsS --connect-timeout 4 -m 6 -o /dev/null https://api.ipify.org 2>/dev/null; then
    IPFAM=6; info "无 IPv4 出口，使用 IPv6 测试。"
  fi
  printf '  拥塞控制: %s   队列: %s\n' "$(sysval net.ipv4.tcp_congestion_control)" "$(sysval net.core.default_qdisc)"
  if [[ -n $SNI ]]; then
    local w a="" b="" rc=0
    w=$(curl "-${IPFAM}" -so /dev/null --connect-timeout 5 -m 10 -w '%{time_connect} %{time_appconnect}' "https://${SNI}/" 2>/dev/null) || rc=$?
    read -r a b <<<"$w"
    if (( rc == 0 )) && awk -v t="${b:-0}" 'BEGIN{exit !(t > 0)}'; then
      printf '  到 SNI 目标 %s：TCP %s ms，TLS 握手完成 %s ms（越低越好，建议 < 50ms）\n' "$SNI" \
        "$(awk -v t="${a:-0}" 'BEGIN{printf "%d", t*1000}')" "$(awk -v t="${b:-0}" 'BEGIN{printf "%d", t*1000}')"
    else
      printf '  到 SNI 目标 %s：%s测试失败%s（curl 退出码 %s，目标不可达或 TLS 握手失败）\n' "$SNI" "$C_RED" "$C_NONE" "$rc"
    fi
  fi
  info "下载测速（约 100MB，最长 20 秒；Cloudflare → CacheFly → OVH 依次尝试）..."
  local res="" u mbps mb sec
  for u in "https://speed.cloudflare.com/__down?bytes=99000000" "http://cachefly.cachefly.net/100mb.test" "https://proof.ovh.net/files/100Mb.dat"; do
    res=$(speed_try "$u") && break
    res=""
  done
  if [[ -n $res ]]; then
    read -r mbps mb sec <<<"$res"
    printf '  下载速度: %s Mbps（%s，%s MB / %s 秒）\n' "$mbps" "$(cut -d/ -f3 <<<"$u")" "$mb" "$sec"
  else
    warn "下载测速失败（测速站点均不可达或被限制）。"
  fi
  cat <<TIP

  提示：
   · 在本地电脑上测试到 VPS 的延迟：tcping $(server_addr) $(pub_xray_port)（ICMP ping 可能被运营商限速，仅供参考）
   · 回程线路：proxy route（只检测回程，不改配置、不重启）
   · 晚高峰丢包严重时优先使用 Hysteria2；TCP 稳定时 REALITY 延迟更低
   · SNI 目标延迟过高（> 100ms）时，可在菜单中「更换 SNI」重新优选
TIP
}

menu_firewall() {
  need_installed
  if (( LAND_MODE )); then
    if [[ -n $OPT_FW_MODE ]]; then
      warn "落地机不用这套入站防火墙（严格 / 只放行 / 关闭）。来源白名单请用 proxy allow。"
      return 0
    fi
    land_menu_allow
    return
  fi
  if (( NAT_MODE )); then warn "NAT 模式不管理防火墙（入站由服务商端口映射控制）。"; menu_nat; return; fi
  if [[ -n $OPT_FW_MODE ]]; then
    fw_switch_mode "$OPT_FW_MODE"
    return 0
  fi
  echo; hr; _green "  防火墙管理（当前：$(fw_mode_label)）"; hr
  fw_print_allows
  hr
  echo "  1) 放行额外 TCP 端口  2) 放行额外 UDP 端口  3) 取消额外放行  4) 重新检测 SSH 并重载"
  echo "  5) 切换为严格（入站默认拒绝）  6) 切换为只放行  7) 关闭本脚本防火墙  0) 返回"
  local c p x; ask c "请选择" "0"
  case $c in
    1) ask p "TCP 端口（空格分隔）" ""; for x in $p; do is_port "$x" && EXTRA_TCP="${EXTRA_TCP:+$EXTRA_TCP }$x"; done ;;
    2) ask p "UDP 端口（空格分隔）" ""; for x in $p; do is_port "$x" && EXTRA_UDP="${EXTRA_UDP:+$EXTRA_UDP }$x"; done ;;
    3) EXTRA_TCP="" EXTRA_UDP="" ;;
    4) ;;
    5) fw_switch_mode strict; return 0 ;;
    6) fw_switch_mode allow; return 0 ;;
    7) fw_switch_mode off; return 0 ;;
    *) return 0 ;;
  esac
  if [[ ${FW_MODE:-off} == off || ${FW_ENABLED:-0} == 0 ]]; then
    save_state
    if [[ ${FW_HOST_SYNC:-0} == 1 ]]; then
      fw_host_sync
      save_state
      fw_print_allows
      return 0
    fi
    warn "防火墙是关闭的，改动已记下，但还没写入 nftables。要生效请选严格或只放行。"
    return 0
  fi
  save_state
  apply_firewall
  save_state
}

do_uninstall() {
  require_root
  load_state
  [[ -n $INIT_SYS ]] || detect_init
  if (( LAND_MODE )); then
    warn "将卸载落地机：Xray（Shadowsocks 2022）、来源白名单规则、网络调优（如有）、服务脚本及管理命令。"
  elif (( NAT_MODE )); then
    warn "将卸载 Xray、Hysteria2、端口跳跃规则、网络调优（如有）、服务脚本及管理命令（NAT 模式）。"
  else
    warn "将卸载 Xray、Hysteria2、本脚本防火墙规则、调优配置、fail2ban 规则及管理命令。"
  fi
  (( OPT_AUTO )) || confirm "确认卸载？" n || return 0
  step "卸载"
  svc_disable_stop xray
  if have systemctl; then systemctl disable --now 'xray@*' >/dev/null 2>&1 || true; fi
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service "$XRAY_RC"
  rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
  rm -f "$XRAY_BIN" "${XRAY_BIN}.bak" "${XRAY_BIN}.prebak"; rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  sd_reload
  ok "Xray 已移除"
  remove_hysteria purge; ok "Hysteria2 已移除"
  remove_singbox; ok "sing-box 已移除"
  cert_remove_files
  remove_nat_hop
  remove_firewall; land_fw_remove; land_fwd_remove; ok "防火墙 / 端口跳跃 / 落地机白名单与原样转发规则已移除"
  if [[ -f $F2B_JAIL ]]; then rm -f "$F2B_JAIL"; systemctl restart fail2ban >/dev/null 2>&1 || true; ok "fail2ban 规则已移除（fail2ban 软件包保留）"; fi
  if tune_has_config; then
    ( trap - ERR; set +e; tune_restore quiet ) || warn "恢复调优设置时出现问题，请运行 sysctl --system 或重启。"
    ok "调优配置已移除（已恢复调优前的参数）"
  fi
  if (( DNS64_SET )) && [[ -f $RESOLV_BAK ]]; then
    if confirm "安装时写入了 DNS64 服务器，是否恢复原来的 /etc/resolv.conf？" y; then
      if cat "$RESOLV_BAK" >/etc/resolv.conf 2>/dev/null; then ok "已恢复 /etc/resolv.conf"; else warn "恢复 /etc/resolv.conf 失败，备份在 ${RESOLV_BAK}"; fi
    fi
  fi
  local fw
  for fw in $DISABLED_FW; do
    if confirm "安装时停用了 ${fw}，是否重新启用？" y; then
      if [[ $fw == ufw ]]; then
        if fw_ufw_enable_kept; then ok "已重新启用 ${fw}"; fi
      else
        systemctl enable --now "$fw" >/dev/null 2>&1 || true
        ok "已重新启用 ${fw}"
      fi
    fi
  done
  (( SWAP_CREATED )) && info "安装时创建的 /swapfile 已保留（如需删除: swapoff /swapfile && rm /swapfile 并编辑 /etc/fstab）。"
  rm -rf "$SCANNER_BIN" "$(dirname "$SCANNER_BIN")"
  rm -f "$INFO_FILE"
  if confirm "是否同时删除密钥与备份目录 ${STATE_DIR}？" y; then rm -rf "$STATE_DIR"; else
    sed -i "s/^INSTALLED=.*/INSTALLED='0'/" "$STATE_FILE" 2>/dev/null || true; fi
  rm -f "$BIN_PATH"
  ok "卸载完成。别忘了在云服务商控制台关闭不再需要的端口。"
}

