# ============================================================
#       落地机（Shadowsocks 2022 出口）/ 中转机的落地转发
# ============================================================
# 落地机：本机只运行 Xray 的 Shadowsocks 2022 入站（TCP+UDP），不装 Reality / Hysteria2 / fail2ban，
#         可选来源 IP 白名单（Xray 路由 + nftables 双重限制），仅允许中转机连接。
#         出口三选一：本机直连、加密转发（再拨一跳 SS2022）、原样转发（DNAT，不解密）。
# 中转机：普通 / NAT 模式安装的节点，把 Xray 的默认出站改为落地机（ss:// 链接），
#         内网 / BT 屏蔽规则仍在最前；Hysteria2 经本机 127.0.0.1 的 socks 入站同样走落地机。
#         节点上的 land-add / land-on / land-off / land-del 不改成落地机的下一跳。
land_norm_method() {
  case ${1,,} in
    1|aes-128|aes128|aes-128-gcm|2022-blake3-aes-128-gcm) echo 2022-blake3-aes-128-gcm ;;
    2|aes-256|aes256|aes-256-gcm|2022-blake3-aes-256-gcm) echo 2022-blake3-aes-256-gcm ;;
    3|chacha|chacha20|chacha20-poly1305|2022-blake3-chacha20-poly1305) echo 2022-blake3-chacha20-poly1305 ;;
    *) return 1 ;;
  esac
}
land_key_len() { if [[ $1 == *aes-128* ]]; then echo 16; else echo 32; fi; }
land_gen_key() { openssl rand -base64 "$(land_key_len "$1")"; }
b64d() { # 兼容 URL-safe 与缺少填充的 base64
  local s=${1//-/+}; s=${s//_//}
  while (( ${#s} % 4 )); do s+="="; done
  printf '%s' "$s" | base64 -d 2>/dev/null
}
land_key_ok() { # $1 方法 $2 密钥（多用户 iPSK 写法 k1:k2 逐段检查）
  local want part n; want=$(land_key_len "$1")
  [[ -n $2 && $2 =~ ^[A-Za-z0-9+/=:]+$ ]] || return 1
  local IFS=:
  for part in $2; do
    n=$( { printf '%s' "$part" | base64 -d 2>/dev/null || true; } | wc -c | tr -d ' ')
    [[ $n == "$want" ]] || return 1
  done
}
urldecode() { local s=${1//\\/\\\\}; printf '%b' "${s//%/\\x}"; }

# ---------- 来源 IP 白名单 ----------
valid_cidr() {
  local a=$1 ip pfx="" x
  if [[ $a == */* ]]; then ip=${a%/*}; pfx=${a##*/}; else ip=$a; fi
  [[ -z $pfx || $pfx =~ ^[0-9]{1,3}$ ]] || return 1
  if is_ipv4 "$ip"; then
    local IFS=.; for x in $ip; do (( 10#$x <= 255 )) || return 1; done
    [[ -z $pfx ]] || (( 10#$pfx <= 32 ))
    return
  fi
  if [[ $ip == *:* && $ip =~ ^[0-9A-Fa-f:.]+$ && $ip != *:::* ]]; then
    [[ -z $pfx ]] || (( 10#$pfx <= 128 ))
    return
  fi
  return 1
}
land_norm_allow() { # 逗号/空格分隔 → LAND_NORM（空格分隔、去重）；有无效项时 LAND_BAD=该项并返回 1
  local s x out=""
  LAND_NORM="" LAND_BAD=""
  s=$(sanitize_port_input "$1"); s=${s//,/ }
  for x in $s; do
    valid_cidr "$x" || { LAND_BAD=$x; return 1; }
    [[ " $out " == *" $x "* ]] || out+="${out:+ }$x"
  done
  LAND_NORM=$out
}
land_allow_json() { # 白名单 + 本机回环（自检用）→ JSON 数组
  local x list='["127.0.0.1/32","::1/128"]'
  for x in $LAND_ALLOW; do list=$(jq -c --arg x "$x" '. + [$x]' <<<"$list"); done
  printf '%s' "$list"
}

# ---------- 落地机 Xray 配置 ----------
# 无下一跳、无原样转发时走 land_xray_json_base，与直连落地机相同。
land_xray_json() {
  # 原样转发或加密转发的链接坏了时不要退回直连，否则白名单流量会从本机漏出去。
  if (( LAND_MODE )) && [[ ${FWD_ON:-0} == 1 && -n ${FWD_LINK:-} ]]; then
    land_raw_active || die "原样转发链接无法解析，拒绝按直连生成配置。"
    land_xray_hold_json
    return
  fi
  if (( LAND_MODE )) && [[ ${RELAY_ON:-0} == 1 && -n ${RELAY_LINK:-} ]]; then
    land_relay_active || die "下一跳链接无法解析，拒绝按直连生成配置。"
    land_xray_json_base | land_xray_attach_relay
    return
  fi
  land_xray_json_base
}
land_xray_json_base() {
  local ds
  ds=$(xray_domain_strategy)
  jq -n --argjson port "$XRAY_PORT" --arg method "$LAND_METHOD" --arg key "$LAND_KEY" \
    --arg ds "$ds" \
    --argjson privnets "$PRIV_NETS_JSON" --argjson allow "$(land_allow_json)" --argjson wl "$([[ -n $LAND_ALLOW ]] && echo 1 || echo 0)" '
  {
    log: {loglevel: "warning", access: "none"},
    inbounds: [{
      tag: "ss-in",
      port: $port,
      protocol: "shadowsocks",
      settings: {method: $method, password: $key, network: "tcp,udp"},
      sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
    }],
    outbounds: [
      ({tag: "direct", protocol: "freedom"}
        + (if $ds != "" then {settings: {domainStrategy: $ds}} else {} end)),
      {tag: "block", protocol: "blackhole"}
    ],
    routing: {
      domainStrategy: (if $ds != "" then $ds else "AsIs" end),
      rules: ([
        {type: "field", ip: $privnets, outboundTag: "block"},
        {type: "field", protocol: ["bittorrent"], outboundTag: "block"}
      ] + (if $wl == 1 then [
        {type: "field", source: $allow, outboundTag: "direct"},
        {type: "field", inboundTag: ["ss-in"], outboundTag: "block"}
      ] else [] end))
    }
  }'
}

ss_link_build() { # $1 方法 $2 密钥 $3 地址 $4 端口 $5 名称（SIP002；2022 方法使用 百分号编码的 method:password）
  printf 'ss://%s:%s@%s:%s#%s' "$(urlencode "$1")" "$(urlencode "$2")" "$(host_fmt "$3")" "$4" "$(urlencode "$5")"
}
land_link() { ss_link_build "$LAND_METHOD" "$LAND_KEY" "$(server_addr)" "$(pub_xray_port)" "${NODE_NAME}"; }
land_tag_of() { # $1 名称 $2 地址
  local t; t=$(printf '%s' "${1:-$2}" | tr -cd 'A-Za-z0-9_.-' | cut -c1-32)
  [[ -n $t ]] || t=$(printf '%s' "$2" | tr -cd 'A-Za-z0-9_.-' | cut -c1-32)
  printf 'land-%s' "${t:-1}"
}
land_outbound_json() { # $1 方法 $2 密钥 $3 地址 $4 端口 $5 tag [$6 domainStrategy，仅落地机加密转发]
  if [[ -n ${6:-} ]]; then
    jq -n --arg m "$1" --arg k "$2" --arg a "$3" --argjson p "$4" --arg t "$5" --arg ds "$6" \
      '{tag: $t, protocol: "shadowsocks", settings: {servers: [{address: $a, port: $p, method: $m, password: $k}]}, streamSettings: {sockopt: {domainStrategy: $ds}}}'
  else
    jq -n --arg m "$1" --arg k "$2" --arg a "$3" --argjson p "$4" --arg t "$5" \
      '{tag: $t, protocol: "shadowsocks", settings: {servers: [{address: $a, port: $p, method: $m, password: $k}]}}'
  fi
}

land_print_links() { # $1=1 屏幕着色
  local paint=${1:-0} link
  if land_raw_active; then land_print_links_raw "$paint"; return; fi
  link=$(land_link)
  node_link_head "$paint" "Shadowsocks 2022" "$NODE_NAME" "$(server_addr)" "$(pub_xray_port)  TCP+UDP"
  node_link_note "$paint" "$LAND_METHOD"
  if [[ -n $LAND_ALLOW ]]; then node_link_note "$paint" "来源白名单  ${LAND_ALLOW}"
  else node_link_note "$paint" "来源白名单未设置，建议 proxy allow 只允许中转机"; fi
  node_link_uri "$link"
  echo
  ui_bar '─' 62 "$paint"
  if (( paint )); then printf '%s中转机命令%s\n' "$C_TITLE" "$C_NONE"; else echo "中转机命令"; fi
  printf "proxy land-add '%s'\n" "$link"
  echo
  ui_bar '─' 62 "$paint"
  if (( paint )); then printf '%sXray 出站%s\n' "$C_TITLE" "$C_NONE"; else echo "Xray 出站"; fi
  land_outbound_json "$LAND_METHOD" "$LAND_KEY" "$(server_addr)" "$(pub_xray_port)" "$(land_tag_of "$NODE_NAME" "$(server_addr)")"
  echo
  ui_bar '─' 62 "$paint"
  if (( paint )); then printf '%smihomo / Clash.Meta%s\n' "$C_TITLE" "$C_NONE"; else echo "mihomo / Clash.Meta"; fi
  cat <<Y
proxies:
  - name: "${NODE_NAME}"
    type: ss
    server: $(server_addr)
    port: $(pub_xray_port)
    cipher: ${LAND_METHOD}
    password: "${LAND_KEY}"
    udp: true
Y
  if land_relay_active; then
    echo
    ui_bar '─' 62 "$paint"
    if (( paint )); then printf '%s下一跳（不要交给上一台）%s\n' "$C_TITLE" "$C_NONE"; else echo "下一跳（不要交给上一台）"; fi
    echo "上一台请用上面的本机 ss://。下面这串只保存在本机："
    printf '%s\n' "$RELAY_LINK"
  fi
}
land_build_info() {
  echo "proxy-oneclick 落地机信息"
  echo "生成时间  $(date '+%F %T %Z')"
  echo "服务器    $(server_addr)"
  land_print_links 0
  echo
  ui_bar '─' 62 0
}
land_show_info() {
  load_state
  (( INSTALLED && LAND_MODE )) || die "本机尚未安装为落地机。"
  land_build_info >"${INFO_FILE}.tmp"; chmod 600 "${INFO_FILE}.tmp"; mv -f "${INFO_FILE}.tmp" "$INFO_FILE"
  echo
  ui_logo
  land_print_links 1
  echo
  ui_bar '═' 62
  printf '以上信息已保存到 %s（权限 600）。再次查看：proxy info\n' "$INFO_FILE"
  ui_bar '═' 62
}

# ---------- 落地机 nftables 白名单（非 NAT 容器且有 nft 时） ----------
land_fw_active() { have nft && nft list table inet "$LAND_NFT_TABLE" >/dev/null 2>&1; }
land_fw_remove() {
  if [[ -f $LAND_FW_UNIT || -f $LAND_FW_RC ]]; then svc_disable_stop proxy-oneclick-land-fw; fi
  have nft && { nft delete table inet "$LAND_NFT_TABLE" >/dev/null 2>&1 || true; }
  rm -f "$LAND_FW_UNIT" "$LAND_FW_RC" "$LAND_FW_FILE"
  sd_reload
}
land_fw_render() {
  local v4="" v6="" x
  for x in $LAND_ALLOW; do if [[ $x == *:* ]]; then v6+="${v6:+, }$x"; else v4+="${v4:+, }$x"; fi; done
  {
    echo "#!/usr/sbin/nft -f"
    echo "# 由 proxy-oneclick 生成（落地机来源 IP 白名单）；卸载时删除"
    echo "table inet ${LAND_NFT_TABLE}"
    echo "delete table inet ${LAND_NFT_TABLE}"
    echo "table inet ${LAND_NFT_TABLE} {"
    [[ -n $v4 ]] && printf '  set allow4 {\n    type ipv4_addr; flags interval; auto-merge\n    elements = { %s }\n  }\n' "$v4"
    [[ -n $v6 ]] && printf '  set allow6 {\n    type ipv6_addr; flags interval; auto-merge\n    elements = { %s }\n  }\n' "$v6"
    echo "  chain input {"
    echo "    type filter hook input priority -10; policy accept;"
    echo "    iif \"lo\" accept"
    [[ -n $v4 ]] && echo "    meta l4proto { tcp, udp } th dport ${XRAY_PORT} ip saddr @allow4 accept"
    [[ -n $v6 ]] && echo "    meta l4proto { tcp, udp } th dport ${XRAY_PORT} ip6 saddr @allow6 accept"
    echo "    meta l4proto { tcp, udp } th dport ${XRAY_PORT} counter drop comment \"not in whitelist\""
    echo "  }"
    echo "}"
  } >"${LAND_FW_FILE}.tmp"
}
land_fw_apply() {
  if [[ -z $LAND_ALLOW ]] || (( ! LAND_MODE )); then land_fw_remove; return 0; fi
  [[ -n $VIRT ]] || detect_virt
  if (( NAT_MODE )) && is_container; then
    land_fw_remove
    if land_raw_active; then info "NAT 容器（${VIRT}）：原样转发的来源限制写在 DNAT 上，不靠 Xray 路由。"
    else info "NAT 容器（${VIRT}）：来源白名单仅由 Xray 路由实现（非白名单连接被丢弃）。"; fi
    return 0
  fi
  have nft || { [[ -n $PKG ]] && pkg_try nftables; }
  if ! have nft; then
    land_fw_remove
    if land_raw_active; then info "未安装 nftables 过滤表。原样转发的来源限制在 DNAT 规则上。"
    else info "未安装 nftables：来源白名单仅由 Xray 路由实现。"; fi
    return 0
  fi
  mkdir -p "$STATE_DIR"
  land_fw_render
  if ! nft -c -f "${LAND_FW_FILE}.tmp" >/dev/null 2>&1; then
    rm -f "${LAND_FW_FILE}.tmp"; land_fw_remove
    warn "nftables 不支持白名单规则（内核/容器限制），来源白名单仅由 Xray 路由实现。"; return 0
  fi
  mv -f "${LAND_FW_FILE}.tmp" "$LAND_FW_FILE"; chmod 600 "$LAND_FW_FILE"
  local nftbin; nftbin=$(command -v nft)
  if is_openrc; then
    cat >"$LAND_FW_RC" <<RC
#!/sbin/openrc-run
# 由 proxy-oneclick 生成（落地机来源 IP 白名单）
description="proxy-oneclick landing whitelist"
depend() {
  want net
  after firewall
  before xray
}
start() {
  ebegin "Loading proxy-oneclick landing whitelist"
  ${nftbin} -f "${LAND_FW_FILE}"
  eend \$?
}
stop() {
  ebegin "Removing proxy-oneclick landing whitelist"
  ${nftbin} delete table inet ${LAND_NFT_TABLE} 2>/dev/null
  eend 0
}
RC
    chmod 755 "$LAND_FW_RC"
  else
    cat >"$LAND_FW_UNIT" <<UNIT
[Unit]
Description=proxy-oneclick landing whitelist (nftables)
After=network-pre.target nftables.service
Before=xray.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${nftbin} -f ${LAND_FW_FILE}
ExecStop=-${nftbin} delete table inet ${LAND_NFT_TABLE}

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
  fi
  svc_enable proxy-oneclick-land-fw
  svc_restart proxy-oneclick-land-fw >/dev/null 2>&1 || true
  if land_fw_active; then ok "nftables 白名单已加载：端口 ${XRAY_PORT} (TCP+UDP) 只允许 ${LAND_ALLOW}"
  else land_fw_remove; warn "nftables 白名单加载失败，来源白名单仅由 Xray 路由实现。"; fi
}

# ---------- 经 SS2022 服务器的真实请求测试（落地机自检 / 中转机添加落地前） ----------
LAND_EXIT_IP=""
ss_probe() { # $1 地址 $2 端口 $3 方法 $4 密钥 [$5=1 优先查 IPv6 出口]；成功时 LAND_EXIT_IP=出口 IP
  LAND_EXIT_IP=""
  [[ -x $XRAY_BIN ]] || { warn "未找到 xray，无法测试。"; return 1; }
  mktmp
  local dir port="" i pid url ip="" rc=1
  local -a urls
  if [[ ${5:-} == 1 ]]; then
    urls=(https://api64.ipify.org https://ipv6.icanhazip.com https://api.ipify.org https://ifconfig.co/ip https://icanhazip.com)
  else
    urls=(https://api.ipify.org https://api64.ipify.org https://ifconfig.co/ip https://icanhazip.com)
  fi
  dir=$(mktemp -d "${TMP_DIR}/ssprobe.XXXXXX") || return 1
  for i in 1 2 3 4 5 6 7 8 9 10; do
    port=$(( 20000 + RANDOM % 40000 ))
    [[ $port == "$XRAY_PORT" || $port == "${HY2_PORT:-}" || $port == "${RELAY_SOCKS:-}" ]] && continue
    port_in_use tcp "$port" || break
  done
  jq -n --argjson sport "$port" --argjson ob "$(land_outbound_json "$3" "$4" "$1" "$2" probe)" \
    '{log: {loglevel: "warning"}, inbounds: [{listen: "127.0.0.1", port: $sport, protocol: "socks", settings: {udp: false}}], outbounds: [$ob]}' \
    >"${dir}/client.json" 2>/dev/null || { rm -rf "$dir"; return 1; }
  chmod 600 "${dir}/client.json"
  env GOMEMLIMIT=24MiB GOGC=50 "$XRAY_BIN" run -config "${dir}/client.json" >"${dir}/client.log" 2>&1 &
  pid=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    kill -0 "$pid" 2>/dev/null || break
    port_in_use tcp "$port" && break
  done
  if kill -0 "$pid" 2>/dev/null; then
    for url in "${urls[@]}"; do
      ip=$(curl -s --connect-timeout 8 -m 12 --socks5-hostname "127.0.0.1:${port}" "$url" 2>/dev/null | tr -d '[:space:]') || ip=""
      if [[ $ip =~ ^[0-9A-Fa-f:.]{3,45}$ ]] && { is_ipv4 "$ip" || [[ $ip == *:* ]]; }; then rc=0; break; fi
    done
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  (( rc == 0 )) && LAND_EXIT_IP=$ip
  (( rc == 0 )) || grep -vi 'password' "${dir}/client.log" 2>/dev/null | tail -n 3 | sed 's/^/    /' >&2 || true
  rm -rf "$dir"
  return $rc
}
tcp_probe() { # $1 地址 $2 端口
  local h=$1
  if have timeout; then timeout 6 bash -c "exec 3<>/dev/tcp/${h}/$2" 2>/dev/null
  else bash -c "exec 3<>/dev/tcp/${h}/$2" 2>/dev/null; fi
}

land_selftest() {
  local prefer6=0 fam="IPv4"
  [[ ${OUTBOUND_EFFECTIVE:-} == 64 || ${OUTBOUND_EFFECTIVE:-} == 6 ]] && prefer6=1
  info "落地机自检：临时客户端 → 本机 127.0.0.1:${XRAY_PORT}（SS2022）→ 外网 ..."
  if ss_probe 127.0.0.1 "$XRAY_PORT" "$LAND_METHOD" "$LAND_KEY" "$prefer6"; then
    [[ $LAND_EXIT_IP == *:* ]] && fam="IPv6"
    ok "落地机自检通过：出口 ${fam} ${LAND_EXIT_IP}（$(outbound_label "${OUTBOUND_EFFECTIVE:-}")）"
  else
    warn "落地机自检未通过（经本机 SS2022 访问外网失败）。可查看: proxy status"
  fi
  return 0
}

# ---------- 落地机安装 ----------
land_choose_method() {
  local m=${OPT_LAND_METHOD:-} c def=1
  if [[ -z $m ]]; then
    case $LAND_METHOD in *aes-256*) def=2 ;; *chacha20*) def=3 ;; esac
    if (( OPT_AUTO )); then m=$def
    else
      echo "   加密方式（均为 Shadowsocks 2022，客户端/中转需支持 SS2022）："
      echo "     1) 2022-blake3-aes-128-gcm        （默认，最轻量，CPU 有 AES 指令时最快）"
      echo "     2) 2022-blake3-aes-256-gcm"
      echo "     3) 2022-blake3-chacha20-poly1305  （无 AES 硬件加速的 ARM 小鸡）"
      ask c "请选择" "$def"; m=$c
    fi
  fi
  m=$(land_norm_method "$m") || { warn "加密方式无效，使用默认 2022-blake3-aes-128-gcm。"; m=2022-blake3-aes-128-gcm; }
  if [[ $m != "$LAND_METHOD" ]] || ! land_key_ok "$m" "$LAND_KEY"; then
    LAND_METHOD=$m; LAND_KEY=$(land_gen_key "$m")
    info "已生成新的 ${m} 密钥（$(land_key_len "$m") 字节）。"
  fi
}
land_choose_allow() {
  local r
  if [[ -n $OPT_LAND_ALLOW ]]; then r=$OPT_LAND_ALLOW
  elif (( OPT_AUTO )); then r=${LAND_ALLOW:-none}
  else
    echo "   来源 IP 白名单：只允许这些中转机连接（IPv4 / IPv6 / CIDR，逗号或空格分隔）。"
    echo "   不确定中转机出口 IP 时可先留空（none），之后用 proxy allow 修改。"
    ask r "允许的来源 IP" "${LAND_ALLOW:-none}"
  fi
  [[ ${r,,} == none || ${r,,} == all || $r == 无 ]] && r=""
  while :; do
    if land_norm_allow "$r"; then LAND_ALLOW=$LAND_NORM; break; fi
    { [[ -n $OPT_LAND_ALLOW ]] || (( OPT_AUTO )); } && die "白名单中有无效地址: ${LAND_BAD}（例如 1.2.3.4、1.2.3.0/24、2001:db8::1）"
    warn "无效地址: ${LAND_BAD}"
    ask r "允许的来源 IP（none 为不限制）" "none"
    [[ ${r,,} == none ]] && r=""
  done
  if [[ -n $LAND_ALLOW ]]; then info "来源白名单: ${LAND_ALLOW}"
  else warn "未设置来源白名单：任何拿到链接的人都能使用本落地机（建议之后用 proxy allow 设置）。"; fi
}
land_pick_default_port() {
  local p i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    p=$(( 20000 + RANDOM % 40000 ))
    port_in_use tcp "$p" || port_in_use udp "$p" || { printf '%s' "$p"; return 0; }
  done
  printf '%s' 34567
}

do_install_land() {
  load_state
  local was_land=$LAND_MODE was_inst=$INSTALLED
  LAND_MODE=1
  preflight      # 同上：Alpine 落地机也强制 NAT 模式（v1.2.0 在这里漏掉了，导致走了普通端口流程并自动调优）
  resolve_mode
  take_lock
  if (( was_inst )) && (( ! was_land )); then
    warn "本机已安装 Reality / Hysteria2 节点。改装为落地机将移除 Reality 入站、Hysteria2、本脚本防火墙与 fail2ban 规则（密钥保留在状态文件中）。"
    (( OPT_AUTO )) || confirm "确认改装为落地机？" n || return 0
  elif (( was_inst )) && (( ! OPT_AUTO )); then
    warn "检测到已安装落地机。重新安装将保留现有端口/密钥/白名单（除非另行修改）。"
    confirm "继续重新安装？" y || return 0
  fi

  pkg_update_upgrade
  step "安装依赖"
  install_deps_nat
  detect_virt
  ensure_time_sync      # SS2022 校验时间戳，时间误差 > 30 秒会被拒绝
  mktmp
  step "获取服务器信息"
  detect_ip; detect_geo; show_sysinfo
  if (( NAT_MODE )); then
    nat_net_check
    nat_tune
  else
    SERVER_ADDR=${PUBLIC_IP4:-$PUBLIC_IP6}
    if (( OPT_TUNE == 1 )); then apply_tuning; fi
  fi

  step "端口设置"
  HY2_ENABLED=0
  if (( ! was_land )) && [[ -z $OPT_PORT ]]; then XRAY_PORT=$(land_pick_default_port); XRAY_EXT_PORT=""; fi
  XRAY_LABEL="Shadowsocks 2022"
  if (( NAT_MODE )); then
    choose_nat_addr
    choose_nat_ports
  else
    choose_ports
    NAT_PORTS="" NAT_EXCLUDE="" XRAY_EXT_PORT="" HY2_EXT_PORT="" HOP_EXT_RANGE="" HOP_BACKEND=""
  fi
  HY2_ENABLED=0 HOP_RANGE="" HOP_EXT_RANGE="" HY2_EXT_PORT="" HOP_BACKEND=""
  [[ -n $OPT_NAME ]] && NODE_NAME=$OPT_NAME
  if [[ -z $NODE_NAME ]] || (( ! was_land )) && [[ -z $OPT_NAME ]]; then NODE_NAME="$(default_node_name)-land"; fi

  step "Shadowsocks 2022 设置"
  land_choose_method
  land_choose_allow

  # 与节点安装相同：检测地址族（含 NAT66）、询问或采用 --outbound，并记住 OUTBOUND_IP。
  step "出站地址"
  OUTBOUND_IP_DONE=0
  ensure_outbound_ip

  # 从节点改装时丢掉节点的落地链接，避免 land-on 把它当成落地机的下一跳。
  # 重装已经是落地机的机器时保留下一跳（RELAY_*）和原样转发目标（FWD_*）。
  if (( ! was_land )); then
    RELAY_LINK="" RELAY_ON=0 RELAY_SOCKS=""
    FWD_LINK="" FWD_ON=0
  fi
  [[ -x $HY_BIN || -f $HY_UNIT || -f $HY_RC ]] && { info "移除 Hysteria2 ..."; remove_hysteria purge; }
  [[ -x $SB_BIN || -f $SB_UNIT || -f $SB_RC ]] && { info "移除 sing-box（TUIC / AnyTLS）..."; remove_singbox; }
  remove_nat_hop
  if [[ -f $FW_FILE || -f $FW_UNIT || -s ${FW_HOST_FILE:-} ]]; then info "移除节点模式的 nftables 规则 ..."; remove_firewall; fi
  if [[ -f $F2B_JAIL ]]; then rm -f "$F2B_JAIL"; systemctl restart fail2ban >/dev/null 2>&1 || true; fi
  FW_ENABLED=0
  FW_MODE=off
  FW_HOST_SYNC=0

  install_xray
  INSTALLED=1
  # 原样转发先校验白名单和目标地址族，通过后 land_apply 才停 Xray、装 DNAT。
  if land_raw_active; then land_fwd_check; fi
  land_apply
  self_install
  if land_raw_active; then
    info "原样转发已启用，跳过本机 Shadowsocks 自检（本机不解密）。"
  else
    ( trap - ERR; set +e; land_selftest ) || true
  fi
  land_show_info
  if (( ! NAT_MODE )); then
    echo
    warn "如果云服务商有安全组 / 防火墙，请放行 TCP 和 UDP ${XRAY_PORT}$([[ -n $LAND_ALLOW ]] && echo "（可只允许中转机 IP）")。"
  fi
  echo
  _green "落地机安装完成！在中转机上执行上面的 proxy land-add 命令即可；管理菜单：proxy"
}

# ---------- 落地机管理 ----------
need_land() { need_installed; (( LAND_MODE )) || die "本机不是落地机（此功能仅用于 --land 安装的落地机）。"; }
need_node() { need_installed; (( ! LAND_MODE )) || die "本机是落地机（Shadowsocks 2022），没有 Reality / Hysteria2 节点功能。菜单中可管理白名单、端口与密钥。"; }

land_apply() {
  [[ -n $INIT_SYS ]] || detect_init
  [[ -n $PKG ]] || detect_os
  # 原样转发先校验（白名单地址族、出站策略、nat 能力）。失败时还没写状态、也没停 Xray。
  if land_raw_active; then land_fwd_check; fi
  save_state
  if land_raw_active; then
    write_xray_service
    write_xray_config
    restart_xray
    land_fwd_install
  else
    land_fwd_remove
    write_xray_service
    write_xray_config
    restart_xray
  fi
  land_fw_apply
  save_state
  land_build_info >"${INFO_FILE}.tmp" && chmod 600 "${INFO_FILE}.tmp" && mv -f "${INFO_FILE}.tmp" "$INFO_FILE"
}
land_menu_allow() {
  need_land
  [[ -n $PKG ]] || detect_os
  echo "  当前白名单: ${LAND_ALLOW:-未设置（不限制）}"
  local s=$OPT_LAND_ALLOW
  land_choose_allow
  OPT_LAND_ALLOW=$s
  land_apply
  ok "白名单已更新: ${LAND_ALLOW:-不限制}"
}
land_menu_port() {
  need_land
  nat_pref_guard || return 0
  detect_os; detect_virt
  local old; old=$(pub_xray_port)
  local s1=$OPT_PORT s3=$OPT_NAT_EXT s4=$OPT_NAT_ADDR
  XRAY_LABEL="Shadowsocks 2022"
  if (( NAT_MODE )); then
    OPT_PORT="" OPT_NAT_EXT="" OPT_NAT_ADDR=""
    choose_nat_addr; choose_nat_ports
  else
    OPT_PORT=${s1:-}
    choose_ports
  fi
  OPT_PORT=$s1 OPT_NAT_EXT=$s3 OPT_NAT_ADDR=$s4
  HY2_ENABLED=0 HOP_RANGE="" HOP_EXT_RANGE="" HY2_EXT_PORT=""
  land_apply
  ok "端口已更新：${old} -> $(pub_xray_port)。中转机需要重新执行 land-add（新链接见下方）。"
  land_show_info
}
land_menu_key() {
  need_land
  echo "  当前加密方式: ${LAND_METHOD}"
  local old=$LAND_METHOD
  land_choose_method
  if [[ $LAND_METHOD == "$old" ]]; then
    (( OPT_AUTO )) || confirm "加密方式未变，是否重新生成密钥（旧链接失效）？" y || return 0
    LAND_KEY=$(land_gen_key "$LAND_METHOD")
  fi
  land_apply
  ok "已更换为 ${LAND_METHOD} 新密钥。中转机需要重新执行 land-add（新链接见下方）。"
  land_show_info
}

# ---------- 落地机出口：直连 / 加密转发 / 原样转发（三者互斥） ----------
# 节点菜单 12 仍是「本机是客户端入口，下一跳是一台落地」。这里只给落地机用。
# 加密转发复用 RELAY_LINK / RELAY_ON，但不装 hy2-relay。原样转发用 FWD_LINK / FWD_ON。
FWD_M="" FWD_K="" FWD_H="" FWD_P="" FWD_N="" FWD_IP="" FWD_FAM="" FWD_BACKEND=""

fwd_load() { # $1 ss:// ；成功时写入 FWD_*，并还原 RELAY_*（ss_parse 会改它们）
  local om=$RELAY_M ok=$RELAY_K oh=$RELAY_H op=$RELAY_P on=$RELAY_N rc=0
  ss_parse "$1" || rc=$?
  if (( rc == 0 )); then
    FWD_M=$RELAY_M FWD_K=$RELAY_K FWD_H=$RELAY_H FWD_P=$RELAY_P FWD_N=$RELAY_N
  fi
  RELAY_M=$om RELAY_K=$ok RELAY_H=$oh RELAY_P=$op RELAY_N=$on
  return $rc
}
land_raw_active() {
  (( ${LAND_MODE:-0} )) || return 1
  [[ ${FWD_ON:-0} == 1 && -n ${FWD_LINK:-} ]] || return 1
  fwd_load "$FWD_LINK"
}
land_relay_active() { # 落地机上的加密转发。节点的 relay_active 仍要求 !LAND_MODE。
  (( ${LAND_MODE:-0} )) || return 1
  [[ ${FWD_ON:-0} == 1 ]] && return 1
  [[ ${RELAY_ON:-0} == 1 && -n ${RELAY_LINK:-} ]] || return 1
  ss_parse "$RELAY_LINK"
}
land_egress_label() {
  if [[ ${FWD_ON:-0} == 1 && -n ${FWD_LINK:-} ]]; then
    if land_raw_active; then printf '%s' "原样转发"; else printf '%s' "原样转发（链接无效）"; fi
    return
  fi
  if (( ${LAND_MODE:-0} )) && [[ ${RELAY_ON:-0} == 1 && -n ${RELAY_LINK:-} ]]; then
    if land_relay_active; then printf '%s' "加密转发"; else printf '%s' "加密转发（链接无效）"; fi
    return
  fi
  printf '%s' "本机直连"
}
land_hold_port() {
  if [[ ${XRAY_PORT:-0} != 39271 ]]; then printf '%s' 39271; else printf '%s' 39272; fi
}
# 原样转发时写一份不监听落地端口的配置。即使有人手动拉起 Xray，公网端口也仍留给 DNAT。
land_xray_hold_json() {
  local ds port
  ds=$(xray_domain_strategy)
  port=$(land_hold_port)
  jq -n --argjson port "$port" --arg method "$LAND_METHOD" --arg key "$LAND_KEY" --arg ds "$ds" \
    --argjson privnets "$PRIV_NETS_JSON" '
  {
    log: {loglevel: "warning", access: "none"},
    inbounds: [{
      tag: "fwd-hold",
      listen: "127.0.0.1",
      port: $port,
      protocol: "shadowsocks",
      settings: {method: $method, password: $key, network: "tcp"}
    }],
    outbounds: [
      ({tag: "direct", protocol: "freedom"}
        + (if $ds != "" then {settings: {domainStrategy: $ds}} else {} end)),
      {tag: "block", protocol: "blackhole"}
    ],
    routing: {
      domainStrategy: (if $ds != "" then $ds else "AsIs" end),
      rules: [
        {type: "field", ip: $privnets, outboundTag: "block"},
        {type: "field", inboundTag: ["fwd-hold"], outboundTag: "block"}
      ]
    }
  }'
}
# 在直连配置上插入 SS2022 出站。白名单来源改走下一跳；没有白名单时用入站兜底，不靠「第一条出站碰巧是默认」。
land_xray_attach_relay() {
  local ob tag ds
  tag=$(relay_tag)
  ds=$(xray_domain_strategy)
  ob=$(land_outbound_json "$RELAY_M" "$RELAY_K" "$RELAY_H" "$RELAY_P" "$tag" "$ds")
  jq --argjson ob "$ob" --arg tag "$tag" '
    .outbounds = [$ob] + .outbounds
    | .routing.rules |= (
        map(if .outboundTag == "direct" and (.source != null) then .outboundTag = $tag else . end)
        + (if any(.[]; .source != null) then []
           else [{type: "field", inboundTag: ["ss-in"], outboundTag: $tag}] end)
      )'
}

land_allow_has_fam() { # $1 = 4|6。白名单里是否有这一族的地址（含 CIDR）
  local want=$1 x ip
  [[ -n ${LAND_ALLOW:-} ]] || return 1
  for x in $LAND_ALLOW; do
    ip=${x%%/*}
    if [[ $want == 4 ]] && is_ipv4 "$ip"; then return 0; fi
    if [[ $want == 6 ]] && [[ $ip == *:* ]]; then return 0; fi
  done
  return 1
}
land_allow_fam_csv() { # $1 = 4|6 → nft / 规则用的逗号分隔列表。只含这一族，避免把另一族写进集合。
  local want=$1 x ip out=""
  for x in $LAND_ALLOW; do
    ip=${x%%/*}
    if [[ $want == 4 ]] && is_ipv4 "$ip"; then out+="${out:+, }$x"
    elif [[ $want == 6 ]] && [[ $ip == *:* ]]; then out+="${out:+, }$x"; fi
  done
  printf '%s' "$out"
}
land_resolve_fam() { # $1 主机名 $2 4|6。打印一个地址；没有则空。
  local host=$1 fam=$2 ip=""
  if [[ $fam == 4 ]]; then
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1; exit}') || true
    [[ -n $ip ]] || ip=$(getent ahosts "$host" 2>/dev/null | awk '$1 !~ /:/{print $1; exit}') || true
  else
    ip=$(getent ahostsv6 "$host" 2>/dev/null | awk 'NR==1{print $1; exit}') || true
    [[ -n $ip ]] || ip=$(getent ahosts "$host" 2>/dev/null | awk '$1 ~ /:/{print $1; exit}') || true
  fi
  ip=${ip%%%*}
  printf '%s' "$ip"
}
land_fwd_pick_ip() { # 按 OUTBOUND_EFFECTIVE 选定 DNAT 目标。字面地址不再解析。
  local host=$FWD_H pol=${OUTBOUND_EFFECTIVE:-} v4="" v6=""
  FWD_IP="" FWD_FAM=""
  if is_ipv4 "$host"; then
    [[ $pol == 6 ]] && die "出站策略是仅IPv6，不能原样转发到 IPv4 地址 ${host}。"
    FWD_IP=$host FWD_FAM=4
    return 0
  fi
  if [[ $host == *:* ]]; then
    [[ $pol == 4 ]] && die "出站策略是仅IPv4，不能原样转发到 IPv6 地址 ${host}。"
    FWD_IP=$host FWD_FAM=6
    return 0
  fi
  [[ $pol == 6 ]] || v4=$(land_resolve_fam "$host" 4)
  [[ $pol == 4 ]] || v6=$(land_resolve_fam "$host" 6)
  case $pol in
    6) FWD_IP=$v6; FWD_FAM=6 ;;
    64)
      if [[ -n $v6 ]]; then FWD_IP=$v6; FWD_FAM=6; else FWD_IP=$v4; FWD_FAM=4; fi ;;
    *)
      if [[ -n $v4 ]]; then FWD_IP=$v4; FWD_FAM=4; else FWD_IP=$v6; FWD_FAM=6; fi ;;
  esac
  [[ -n $FWD_IP ]] || die "按出站策略 $(outbound_label "$pol") 解析不到 ${host}。未安装 DNAT。"
}
land_fwd_probe() { # 打印 nft-inet | nft-ip | iptables。装不上带来源限制的 nat 就失败，不降级成开放 DNAT。
  local t="${LAND_FWD_TABLE}_probe" fam=$1
  if have nft; then
    if nft -f - >/dev/null 2>&1 <<NFT
table inet ${t} {
  chain pre {
    type nat hook prerouting priority dstnat; policy accept;
    ip saddr 203.0.113.1 tcp dport 9 dnat ip to 203.0.113.2:9
  }
  chain post {
    type nat hook postrouting priority srcnat; policy accept;
    ip daddr 203.0.113.2 tcp dport 9 masquerade
  }
}
NFT
    then
      nft delete table inet "$t" >/dev/null 2>&1 || true
      printf '%s' "nft-inet"; return 0
    fi
    nft delete table inet "$t" >/dev/null 2>&1 || true
    if [[ $fam == 4 ]] && nft -f - >/dev/null 2>&1 <<NFT
table ip ${t} {
  chain pre {
    type nat hook prerouting priority dstnat; policy accept;
    ip saddr 203.0.113.1 tcp dport 9 dnat to 203.0.113.2:9
  }
  chain post {
    type nat hook postrouting priority srcnat; policy accept;
    ip daddr 203.0.113.2 tcp dport 9 masquerade
  }
}
NFT
    then
      nft delete table ip "$t" >/dev/null 2>&1 || true
      printf '%s' "nft-ip"; return 0
    fi
    nft delete table ip "$t" >/dev/null 2>&1 || true
    if [[ $fam == 6 ]] && nft -f - >/dev/null 2>&1 <<NFT
table ip6 ${t} {
  chain pre {
    type nat hook prerouting priority dstnat; policy accept;
    ip6 saddr 2001:db8::1 tcp dport 9 dnat to [2001:db8::2]:9
  }
  chain post {
    type nat hook postrouting priority srcnat; policy accept;
    ip6 daddr 2001:db8::2 tcp dport 9 masquerade
  }
}
NFT
    then
      nft delete table ip6 "$t" >/dev/null 2>&1 || true
      printf '%s' "nft-ip"; return 0
    fi
    nft delete table ip6 "$t" >/dev/null 2>&1 || true
  fi
  if [[ $fam == 4 ]] && have iptables && iptables -t nat -N PROXY_OC_FWD_PROBE >/dev/null 2>&1; then
    local okk=0
    iptables -t nat -A PROXY_OC_FWD_PROBE -p tcp -s 203.0.113.1 --dport 9 -j DNAT --to-destination 203.0.113.2:9 >/dev/null 2>&1 && okk=1
    iptables -t nat -F PROXY_OC_FWD_PROBE >/dev/null 2>&1 || true
    iptables -t nat -X PROXY_OC_FWD_PROBE >/dev/null 2>&1 || true
    if (( okk )); then printf '%s' "iptables"; return 0; fi
  fi
  if [[ $fam == 6 ]] && have ip6tables && ip6tables -t nat -N PROXY_OC_FWD_PROBE >/dev/null 2>&1; then
    local okk=0
    ip6tables -t nat -A PROXY_OC_FWD_PROBE -p tcp -s 2001:db8::1 --dport 9 -j DNAT --to-destination "[2001:db8::2]:9" >/dev/null 2>&1 && okk=1
    ip6tables -t nat -F PROXY_OC_FWD_PROBE >/dev/null 2>&1 || true
    ip6tables -t nat -X PROXY_OC_FWD_PROBE >/dev/null 2>&1 || true
    if (( okk )); then printf '%s' "iptables"; return 0; fi
  fi
  return 1
}
land_fwd_check() { # 不改防火墙。失败则 die，调用方尚未把新模式写盘（或写盘前调用）。
  fwd_load "$FWD_LINK" || die "保存的原样转发链接无法解析，请重新 proxy land-forward。"
  [[ -n $LAND_ALLOW ]] || die "原样转发必须先设置来源白名单（proxy allow）。没有白名单就不会安装 DNAT，避免对公网开放。"
  ensure_outbound_ip
  land_fwd_pick_ip
  if ! land_allow_has_fam "$FWD_FAM"; then
    die "来源白名单里没有与目标 ${FWD_IP} 同族的地址（目标是 IPv${FWD_FAM}）。拒绝安装开放的 DNAT。请用 proxy allow 加入同族来源后再试。"
  fi
  [[ -n $(land_allow_fam_csv "$FWD_FAM") ]] || die "内部错误：同族白名单为空，已中止。"
  FWD_BACKEND=$(land_fwd_probe "$FWD_FAM") || die "当前环境无法安装带来源限制的 DNAT（nft/iptables nat 不可用，常见于无权限的容器）。未安装开放的转发。加密转发仍可用：proxy land-add。"
  if [[ $FWD_BACKEND == nft-inet || $FWD_BACKEND == nft-ip ]]; then
    local chk
    chk=$(mktemp) || die "无法创建临时文件。"
    land_fwd_nft_text >"$chk"
    if ! nft -c -f "$chk" >/dev/null 2>&1; then
      rm -f "$chk"
      die "DNAT 规则语法校验失败（nft -c），未安装。没有放行成开放转发。"
    fi
    rm -f "$chk"
  fi
  if (( NAT_MODE )); then
    info "NAT 模式：DNAT 做在本机端口 ${XRAY_PORT}，上一跳链接里的端口仍是外部端口 $(pub_xray_port)。"
  fi
}
land_fwd_nft_text() {
  local list fam=$FWD_FAM
  list=$(land_allow_fam_csv "$fam")
  [[ -n $list ]] || die "内部错误：DNAT 白名单为空，已中止。"
  {
    echo "#!/usr/sbin/nft -f"
    echo "# 由 proxy-oneclick 生成（落地机原样转发）。每条 DNAT 都匹配来源白名单。"
    if [[ $FWD_BACKEND == nft-inet ]]; then
      echo "table inet ${LAND_FWD_TABLE}"
      echo "delete table inet ${LAND_FWD_TABLE}"
      echo "table inet ${LAND_FWD_TABLE} {"
      if [[ $fam == 4 ]]; then
        printf '  set allow4 {\n    type ipv4_addr; flags interval; auto-merge\n    elements = { %s }\n  }\n' "$list"
        echo "  chain prerouting {"
        echo "    type nat hook prerouting priority dstnat; policy accept;"
        echo "    ip saddr @allow4 meta l4proto { tcp, udp } th dport ${XRAY_PORT} dnat ip to ${FWD_IP}:${FWD_P}"
        echo "  }"
        echo "  chain postrouting {"
        echo "    type nat hook postrouting priority srcnat; policy accept;"
        echo "    ip daddr ${FWD_IP} meta l4proto { tcp, udp } th dport ${FWD_P} masquerade"
        echo "  }"
      else
        printf '  set allow6 {\n    type ipv6_addr; flags interval; auto-merge\n    elements = { %s }\n  }\n' "$list"
        echo "  chain prerouting {"
        echo "    type nat hook prerouting priority dstnat; policy accept;"
        echo "    ip6 saddr @allow6 meta l4proto { tcp, udp } th dport ${XRAY_PORT} dnat ip6 to [${FWD_IP}]:${FWD_P}"
        echo "  }"
        echo "  chain postrouting {"
        echo "    type nat hook postrouting priority srcnat; policy accept;"
        echo "    ip6 daddr ${FWD_IP} meta l4proto { tcp, udp } th dport ${FWD_P} masquerade"
        echo "  }"
      fi
      echo "}"
    else
      local nf=ip
      [[ $fam == 6 ]] && nf=ip6
      echo "table ${nf} ${LAND_FWD_TABLE}"
      echo "delete table ${nf} ${LAND_FWD_TABLE}"
      echo "table ${nf} ${LAND_FWD_TABLE} {"
      if [[ $fam == 4 ]]; then
        printf '  set allow4 {\n    type ipv4_addr; flags interval; auto-merge\n    elements = { %s }\n  }\n' "$list"
        echo "  chain prerouting {"
        echo "    type nat hook prerouting priority dstnat; policy accept;"
        echo "    ip saddr @allow4 meta l4proto { tcp, udp } th dport ${XRAY_PORT} dnat to ${FWD_IP}:${FWD_P}"
        echo "  }"
        echo "  chain postrouting {"
        echo "    type nat hook postrouting priority srcnat; policy accept;"
        echo "    ip daddr ${FWD_IP} meta l4proto { tcp, udp } th dport ${FWD_P} masquerade"
        echo "  }"
      else
        printf '  set allow6 {\n    type ipv6_addr; flags interval; auto-merge\n    elements = { %s }\n  }\n' "$list"
        echo "  chain prerouting {"
        echo "    type nat hook prerouting priority dstnat; policy accept;"
        echo "    ip6 saddr @allow6 meta l4proto { tcp, udp } th dport ${XRAY_PORT} dnat to [${FWD_IP}]:${FWD_P}"
        echo "  }"
        echo "  chain postrouting {"
        echo "    type nat hook postrouting priority srcnat; policy accept;"
        echo "    ip6 daddr ${FWD_IP} meta l4proto { tcp, udp } th dport ${FWD_P} masquerade"
        echo "  }"
      fi
      echo "}"
    fi
  }
}
land_fwd_cleanup_rules() {
  if have nft; then
    nft delete table inet "$LAND_FWD_TABLE" >/dev/null 2>&1 || true
    nft delete table ip "$LAND_FWD_TABLE" >/dev/null 2>&1 || true
    nft delete table ip6 "$LAND_FWD_TABLE" >/dev/null 2>&1 || true
  fi
  local t
  for t in iptables ip6tables; do
    have "$t" || continue
    "$t" -t nat -D PREROUTING -j PROXY_OC_FWD >/dev/null 2>&1 || true
    "$t" -t nat -F PROXY_OC_FWD >/dev/null 2>&1 || true
    "$t" -t nat -X PROXY_OC_FWD >/dev/null 2>&1 || true
    "$t" -t nat -D POSTROUTING -j PROXY_OC_FWD_OUT >/dev/null 2>&1 || true
    "$t" -t nat -F PROXY_OC_FWD_OUT >/dev/null 2>&1 || true
    "$t" -t nat -X PROXY_OC_FWD_OUT >/dev/null 2>&1 || true
  done
}
land_fwd_forwarding() { # 只打开目标地址族的转发，并把改前的值记在 sysctl 文件里，卸规则时改回。
  local fam=$1 key prev
  if [[ $fam == 4 ]]; then key=net.ipv4.ip_forward; else key=net.ipv6.conf.all.forwarding; fi
  prev=$(sysctl -n "$key" 2>/dev/null || echo 0)
  [[ $prev == 1 ]] || sysctl -w "${key}=1" >/dev/null || die "无法打开 ${key}。原样转发需要内核转发，未安装 DNAT。"
  mkdir -p /etc/sysctl.d
  printf '# proxy-oneclick-fwd\n# prev=%s\n%s=1\n' "$prev" "$key" >"$LAND_FWD_SYSCTL"
}
land_fwd_forwarding_restore() {
  [[ -f $LAND_FWD_SYSCTL ]] || return 0
  local prev key
  prev=$(awk -F= '/^# prev=/{print $2; exit}' "$LAND_FWD_SYSCTL")
  key=$(awk -F= '/^[a-z]/{print $1; exit}' "$LAND_FWD_SYSCTL")
  if [[ $prev == 0 && -n $key ]]; then sysctl -w "${key}=0" >/dev/null 2>&1 || true; fi
  rm -f "$LAND_FWD_SYSCTL"
}
# shellcheck disable=SC2016  # 生成的脚本里 $1/$0 保持字面量
land_fwd_write_script() {
  local bin src
  mkdir -p "$STATE_DIR"
  {
    echo '#!/bin/sh'
    echo "# 由 proxy-oneclick 生成：落地机原样转发 ${XRAY_PORT} → ${FWD_IP}:${FWD_P}（${FWD_BACKEND}）"
    echo 'case "$1" in'
    echo '  start)'
    case $FWD_BACKEND in
      nft-inet|nft-ip)
        bin=$(command -v nft)
        land_fwd_nft_text >"${LAND_FWD_FILE}.tmp"
        mv -f "${LAND_FWD_FILE}.tmp" "$LAND_FWD_FILE"
        chmod 600 "$LAND_FWD_FILE"
        echo "    ${bin} -f ${LAND_FWD_FILE}"
        echo '    ;;' ;;
      iptables)
        if [[ $FWD_FAM == 4 ]]; then bin=$(command -v iptables); else bin=$(command -v ip6tables); fi
        echo "    ${bin} -t nat -N PROXY_OC_FWD >/dev/null 2>&1 || true"
        echo "    ${bin} -t nat -F PROXY_OC_FWD"
        for src in $LAND_ALLOW; do
          local ip=${src%%/*}
          if [[ $FWD_FAM == 4 ]] && is_ipv4 "$ip"; then
            echo "    ${bin} -t nat -A PROXY_OC_FWD -p tcp -s ${src} --dport ${XRAY_PORT} -j DNAT --to-destination ${FWD_IP}:${FWD_P}"
            echo "    ${bin} -t nat -A PROXY_OC_FWD -p udp -s ${src} --dport ${XRAY_PORT} -j DNAT --to-destination ${FWD_IP}:${FWD_P}"
          elif [[ $FWD_FAM == 6 ]] && [[ $ip == *:* ]]; then
            echo "    ${bin} -t nat -A PROXY_OC_FWD -p tcp -s ${src} --dport ${XRAY_PORT} -j DNAT --to-destination [${FWD_IP}]:${FWD_P}"
            echo "    ${bin} -t nat -A PROXY_OC_FWD -p udp -s ${src} --dport ${XRAY_PORT} -j DNAT --to-destination [${FWD_IP}]:${FWD_P}"
          fi
        done
        echo "    ${bin} -t nat -C PREROUTING -j PROXY_OC_FWD >/dev/null 2>&1 || ${bin} -t nat -A PREROUTING -j PROXY_OC_FWD"
        echo "    ${bin} -t nat -N PROXY_OC_FWD_OUT >/dev/null 2>&1 || true"
        echo "    ${bin} -t nat -F PROXY_OC_FWD_OUT"
        if [[ $FWD_FAM == 4 ]]; then
          echo "    ${bin} -t nat -A PROXY_OC_FWD_OUT -p tcp -d ${FWD_IP} --dport ${FWD_P} -j MASQUERADE"
          echo "    ${bin} -t nat -A PROXY_OC_FWD_OUT -p udp -d ${FWD_IP} --dport ${FWD_P} -j MASQUERADE"
        else
          echo "    ${bin} -t nat -A PROXY_OC_FWD_OUT -p tcp -d ${FWD_IP} --dport ${FWD_P} -j MASQUERADE"
          echo "    ${bin} -t nat -A PROXY_OC_FWD_OUT -p udp -d ${FWD_IP} --dport ${FWD_P} -j MASQUERADE"
        fi
        echo "    ${bin} -t nat -C POSTROUTING -j PROXY_OC_FWD_OUT >/dev/null 2>&1 || ${bin} -t nat -A POSTROUTING -j PROXY_OC_FWD_OUT"
        echo '    ;;' ;;
    esac
    echo '  stop)'
    if have nft; then
      bin=$(command -v nft)
      echo "    ${bin} delete table inet ${LAND_FWD_TABLE} >/dev/null 2>&1 || true"
      echo "    ${bin} delete table ip ${LAND_FWD_TABLE} >/dev/null 2>&1 || true"
      echo "    ${bin} delete table ip6 ${LAND_FWD_TABLE} >/dev/null 2>&1 || true"
    fi
    local t
    for t in iptables ip6tables; do
      have "$t" || continue
      bin=$(command -v "$t")
      echo "    ${bin} -t nat -D PREROUTING -j PROXY_OC_FWD >/dev/null 2>&1 || true"
      echo "    ${bin} -t nat -F PROXY_OC_FWD >/dev/null 2>&1 || true"
      echo "    ${bin} -t nat -X PROXY_OC_FWD >/dev/null 2>&1 || true"
      echo "    ${bin} -t nat -D POSTROUTING -j PROXY_OC_FWD_OUT >/dev/null 2>&1 || true"
      echo "    ${bin} -t nat -F PROXY_OC_FWD_OUT >/dev/null 2>&1 || true"
      echo "    ${bin} -t nat -X PROXY_OC_FWD_OUT >/dev/null 2>&1 || true"
    done
    echo '    exit 0 ;;'
    echo '  *) echo "usage: $0 start|stop"; exit 1 ;;'
    echo 'esac'
  } >"${LAND_FWD_SCRIPT}.tmp"
  # iptables 分支若一个来源都没写进去，就是开放 DNAT 的反面：空链不会转发，但也不符合「已启用」。
  if [[ $FWD_BACKEND == iptables ]] && ! grep -q -- '-j DNAT' "${LAND_FWD_SCRIPT}.tmp"; then
    rm -f "${LAND_FWD_SCRIPT}.tmp"
    die "内部错误：没有生成带来源限制的 DNAT 规则，已中止。"
  fi
  chmod 700 "${LAND_FWD_SCRIPT}.tmp"
  mv -f "${LAND_FWD_SCRIPT}.tmp" "$LAND_FWD_SCRIPT"
}
land_fwd_write_service() {
  local nftbin=""
  nftbin=$(command -v nft 2>/dev/null || true)
  if is_openrc; then
    cat >"$LAND_FWD_RC" <<RC
#!/sbin/openrc-run
# 由 proxy-oneclick 生成（落地机原样转发）
description="proxy-oneclick landing raw forward"
depend() {
  need net
  after firewall
  before xray
}
start() {
  ebegin "Applying proxy-oneclick landing DNAT"
  /bin/sh "${LAND_FWD_SCRIPT}" start
  eend \$?
}
stop() {
  ebegin "Removing proxy-oneclick landing DNAT"
  /bin/sh "${LAND_FWD_SCRIPT}" stop
  eend 0
}
RC
    chmod 755 "$LAND_FWD_RC"
  else
    cat >"$LAND_FWD_UNIT" <<UNIT
[Unit]
Description=proxy-oneclick landing raw forward (DNAT)
After=network-pre.target
Before=xray.service
$([[ -n $nftbin ]] && echo "After=nftables.service")

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh ${LAND_FWD_SCRIPT} start
ExecStop=/bin/sh ${LAND_FWD_SCRIPT} stop

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
  fi
  svc_enable proxy-oneclick-fwd
}
land_fwd_install() {
  land_fwd_forwarding "$FWD_FAM"
  if [[ $FWD_BACKEND == nft-inet || $FWD_BACKEND == nft-ip ]]; then
    land_fwd_nft_text >"${LAND_FWD_FILE}.tmp"
    if ! nft -c -f "${LAND_FWD_FILE}.tmp" >/dev/null 2>&1; then
      rm -f "${LAND_FWD_FILE}.tmp"
      die "DNAT 规则语法校验失败（nft -c），未安装。白名单与出站策略未放行成开放转发。"
    fi
  fi
  land_fwd_write_script
  if ! /bin/sh "$LAND_FWD_SCRIPT" start; then
    /bin/sh "$LAND_FWD_SCRIPT" stop >/dev/null 2>&1 || true
    land_fwd_cleanup_rules
    die "加载原样转发规则失败，已撤回。Xray 仍不监听落地端口，请改回本机直连：proxy land-direct。"
  fi
  land_fwd_write_service
  svc_restart proxy-oneclick-fwd >/dev/null 2>&1 || true
  ok "原样转发已加载：本机 TCP/UDP ${XRAY_PORT} → ${FWD_IP}:${FWD_P}（仅白名单来源，回程 masquerade）。"
}
land_fwd_remove() {
  if [[ -f $LAND_FWD_UNIT || -f $LAND_FWD_RC ]]; then svc_disable_stop proxy-oneclick-fwd || true; fi
  if [[ -f $LAND_FWD_SCRIPT ]]; then /bin/sh "$LAND_FWD_SCRIPT" stop >/dev/null 2>&1 || true; fi
  land_fwd_cleanup_rules
  land_fwd_forwarding_restore
  rm -f "$LAND_FWD_UNIT" "$LAND_FWD_RC" "$LAND_FWD_FILE" "$LAND_FWD_SCRIPT" "${LAND_FWD_FILE}.tmp" "${LAND_FWD_SCRIPT}.tmp"
  sd_reload
}
land_fwd_show() {
  if [[ -f $LAND_FWD_FILE ]] && have nft; then
    nft list table inet "$LAND_FWD_TABLE" 2>/dev/null || nft list table ip "$LAND_FWD_TABLE" 2>/dev/null || nft list table ip6 "$LAND_FWD_TABLE" 2>/dev/null || true
  fi
  if have iptables; then iptables -t nat -S PROXY_OC_FWD 2>/dev/null || true; fi
  if have ip6tables; then ip6tables -t nat -S PROXY_OC_FWD 2>/dev/null || true; fi
  [[ -f $LAND_FWD_SCRIPT ]] || warn "未启用原样转发规则。"
}

ss_parse_or_die() { # $1 链接。失败信息与中转 land-add 相同。
  local rc=0
  ss_parse "$1" || rc=$?
  case $rc in
    0) ;;
    2) die "只支持 Shadowsocks 2022 链接（2022-blake3-aes-128-gcm / aes-256-gcm / chacha20-poly1305）。" ;;
    3) die "密钥长度与加密方式不匹配（aes-128 需要 16 字节、其它需要 32 字节的 base64 密钥）。" ;;
    *) die "无法解析 ss:// 链接（格式: ss://方法:密钥@地址:端口#名称）。" ;;
  esac
}
land_direct() {
  need_land
  echo "  将清除已保存的下一跳、原样转发目标和 DNAT 规则，恢复本机 Shadowsocks 直连。"
  (( OPT_AUTO )) || confirm "确认改为本机直连？" y || return 0
  RELAY_LINK="" RELAY_ON=0 RELAY_SOCKS=""
  FWD_LINK="" FWD_ON=0
  land_apply
  ok "已恢复本机直连。下一跳、原样转发目标和 DNAT 已清除。"
}
land_relay_add() {
  need_land
  local link=${OPT_LAND_LINK:-} 
  if [[ -z $link ]]; then
    (( OPT_AUTO )) && die "请提供链接：proxy land-add 'ss://...'"
    echo "  加密转发：本机仍用自己的 SS2022 接上一跳，再拨到下一跳的 ss://。不会装 hy2-relay。"
    ask link "粘贴下一跳 ss:// 链接" "${RELAY_LINK}"
  fi
  ss_parse_or_die "$link"
  step "测试下一跳 ${RELAY_H}:${RELAY_P}（${RELAY_M}）"
  if ! relay_test; then
    if (( OPT_FORCE )); then warn "测试未通过，--force 强制启用。"
    elif (( OPT_AUTO )) || ! confirm "测试未通过，仍然保存并启用加密转发吗？" n; then
      die "未启用加密转发（配置未改变）。确认无误可加 --force 强制启用。"
    fi
  fi
  ensure_outbound_ip
  RELAY_LINK=$(ss_link_build "$RELAY_M" "$RELAY_K" "$RELAY_H" "$RELAY_P" "${RELAY_N:-land}")
  RELAY_ON=1
  FWD_ON=0
  land_apply
  ok "加密转发已启用：本机 SS2022 → $(relay_tag)（${RELAY_H}:${RELAY_P}）。上一跳使用本机自己的 ss://；下一跳链接见下方，不要交给上一台。"
  land_show_info
}
land_relay_on() {
  need_land
  [[ -n $RELAY_LINK ]] || die "没有保存的下一跳，请先 proxy land-add 'ss://...'"
  ss_parse "$RELAY_LINK" || die "保存的下一跳无法解析，请重新 land-add。"
  step "测试下一跳 ${RELAY_H}:${RELAY_P}"
  if ! relay_test && (( ! OPT_FORCE )); then
    { (( OPT_AUTO )) || ! confirm "测试未通过，仍然启用吗？" n; } && die "未启用加密转发。"
  fi
  RELAY_ON=1
  FWD_ON=0
  land_apply
  ok "已启用加密转发 → $(relay_tag)。DNAT 已移除。"
}
land_relay_del() {
  need_land
  [[ -n $RELAY_LINK || $RELAY_ON == 1 ]] || { info "没有设置加密转发。"; return 0; }
  (( OPT_AUTO )) || confirm "删除保存的下一跳？原样转发（若有）保持不动。" y || return 0
  RELAY_LINK="" RELAY_ON=0 RELAY_SOCKS=""
  land_apply
  ok "已删除加密转发的下一跳。原样转发目标未改动。"
}
land_egress_off() { # proxy land-off：停掉当前正在用的非直连出口，保留对应链接。
  need_land
  if land_raw_active; then land_forward_off; return; fi
  if [[ $RELAY_ON == 1 && -n $RELAY_LINK ]]; then
    RELAY_ON=0
    land_apply
    ok "已停用加密转发（恢复本机直连；下一跳已保留，可用 proxy land-on 重新启用）。"
    return 0
  fi
  info "当前已是本机直连。"
}
land_forward_add() {
  need_land
  local link=${OPT_LAND_LINK:-}
  if [[ -z $link ]]; then
    (( OPT_AUTO )) && die "请提供链接：proxy land-forward 'ss://...'（或 proxy land-raw）"
    echo "  原样转发：本机不解密、不再加密。DNAT 到链接里的地址和端口。"
    echo "  上一跳使用的链接是本机地址/端口加上最终落地的加密方式与密钥。"
    ask link "粘贴最终落地 ss:// 链接" "${FWD_LINK}"
  fi
  ss_parse_or_die "$link"
  fwd_load "$(ss_link_build "$RELAY_M" "$RELAY_K" "$RELAY_H" "$RELAY_P" "${RELAY_N:-land}")" || die "无法解析 ss:// 链接。"
  local normalized
  normalized=$(ss_link_build "$FWD_M" "$FWD_K" "$FWD_H" "$FWD_P" "${FWD_N:-land}")
  # 校验放在改 FWD_ON 之前，避免白名单不符时把「原样转发」写进状态。
  # 出站策略先定下来，再临时放上链接做校验。校验失败（die）时 FWD_ON 仍是旧值。
  ensure_outbound_ip
  local saved_link=$FWD_LINK
  FWD_LINK=$normalized
  land_fwd_check
  FWD_LINK=$saved_link
  info "测试 TCP 连接 ${FWD_H}:${FWD_P} ..."
  if tcp_probe "$FWD_H" "$FWD_P"; then ok "TCP 连接成功。"
  else
    warn "无法从本机建立 TCP 到 ${FWD_H}:${FWD_P}（最终落地的白名单可能还没包含本机出口，或端口未放行）。"
    if (( OPT_FORCE )); then warn "测试未通过，--force 强制启用。"
    elif (( OPT_AUTO )) || ! confirm "测试未通过，仍然启用原样转发吗？" n; then
      FWD_LINK=$saved_link
      die "未启用原样转发（配置未改变）。确认无误可加 --force 强制启用。"
    fi
  fi
  FWD_LINK=$normalized
  FWD_ON=1
  RELAY_ON=0
  land_apply
  ok "原样转发已启用：上一跳连本机 $(server_addr):$(pub_xray_port)，DNAT 到 ${FWD_IP}:${FWD_P}。两条链接已分开打印。"
  land_show_info
}
land_forward_off() {
  need_land
  [[ $FWD_ON == 1 ]] || { info "原样转发未启用。"; return 0; }
  FWD_ON=0
  land_apply
  ok "已停用原样转发（DNAT 已删除，恢复本机直连；目标已保留）。"
}
land_forward_del() {
  need_land
  [[ -n $FWD_LINK || $FWD_ON == 1 ]] || { info "没有设置原样转发。"; return 0; }
  (( OPT_AUTO )) || confirm "删除保存的原样转发目标并去掉 DNAT？加密转发的下一跳（若有）保持不动。" y || return 0
  FWD_LINK="" FWD_ON=0
  land_apply
  ok "已删除原样转发。加密转发的下一跳未改动。"
}
land_print_links_raw() {
  local paint=${1:-0} link
  fwd_load "$FWD_LINK" || die "保存的原样转发链接无法解析。"
  link=$(ss_link_build "$FWD_M" "$FWD_K" "$(server_addr)" "$(pub_xray_port)" "${NODE_NAME}")
  node_link_head "$paint" "上一跳使用（本机地址 + 最终密钥）" "$NODE_NAME" "$(server_addr)" "$(pub_xray_port)  TCP+UDP"
  node_link_note "$paint" "本机不解密。加密方式与密钥来自最终落地：${FWD_M}"
  node_link_note "$paint" "最终落地原地址  $(host_fmt "$FWD_H"):${FWD_P}（不要把这个地址交给上一台当入口）"
  if [[ -n $LAND_ALLOW ]]; then node_link_note "$paint" "来源白名单  ${LAND_ALLOW}"
  else node_link_note "$paint" "来源白名单未设置"; fi
  node_link_uri "$link"
  echo
  ui_bar '─' 62 "$paint"
  if (( paint )); then printf '%s上一跳命令%s\n' "$C_TITLE" "$C_NONE"; else echo "上一跳命令"; fi
  printf "proxy land-add '%s'\n" "$link"
  echo
  ui_bar '─' 62 "$paint"
  if (( paint )); then printf '%s最终落地原链接（仅供核对，不要交给上一台）%s\n' "$C_TITLE" "$C_NONE"
  else echo "最终落地原链接（仅供核对，不要交给上一台）"; fi
  printf '%s\n' "$FWD_LINK"
  echo
  ui_bar '─' 62 "$paint"
  if (( paint )); then printf '%sXray 出站（上一跳指向本机）%s\n' "$C_TITLE" "$C_NONE"; else echo "Xray 出站（上一跳指向本机）"; fi
  land_outbound_json "$FWD_M" "$FWD_K" "$(server_addr)" "$(pub_xray_port)" "$(land_tag_of "$NODE_NAME" "$(server_addr)")"
  echo
  ui_bar '─' 62 "$paint"
  if (( paint )); then printf '%smihomo / Clash.Meta（上一跳看到的本机）%s\n' "$C_TITLE" "$C_NONE"; else echo "mihomo / Clash.Meta（上一跳看到的本机）"; fi
  cat <<Y
proxies:
  - name: "${NODE_NAME}"
    type: ss
    server: $(server_addr)
    port: $(pub_xray_port)
    cipher: ${FWD_M}
    password: "${FWD_K}"
    udp: true
Y
}
menu_land_direct() { land_direct; }
menu_land_relay() {
  need_land
  echo; hr; _green "  加密转发（本机 SS2022 入站 → 下一跳 SS2022）"; hr
  echo "  当前出口: $(land_egress_label)"
  if [[ -n $RELAY_LINK ]] && ss_parse "$RELAY_LINK"; then
    echo "  下一跳: $(relay_tag) $(host_fmt "$RELAY_H"):${RELAY_P}（${RELAY_M}）$([[ $RELAY_ON == 1 ]] && echo "${C_GREEN}已启用${C_NONE}" || echo "${C_YELLOW}已停用${C_NONE}")"
  else
    echo "  下一跳: 未设置"
  fi
  echo "  上一跳使用本机自己的 ss://。下一跳链接只留在本机。不安装 hy2-relay。"
  hr
  echo "  1) 设置 / 更换下一跳（粘贴 ss://）  2) 停用（保留链接）  3) 重新启用  4) 删除下一跳  0) 返回"
  local c; ask c "请选择" "0"
  case $c in
    1) OPT_LAND_LINK=""; land_relay_add ;;
    2) if [[ $RELAY_ON == 1 ]]; then RELAY_ON=0; land_apply; ok "已停用加密转发（下一跳已保留，可用 proxy land-on 重新启用）。"; else info "加密转发未启用。"; fi ;;
    3) land_relay_on ;;
    4) land_relay_del ;;
    *) return 0 ;;
  esac
}
menu_land_raw() {
  need_land
  echo; hr; _green "  原样转发（不解密，DNAT 到最终落地）"; hr
  echo "  当前出口: $(land_egress_label)"
  if [[ -n $FWD_LINK ]] && fwd_load "$FWD_LINK"; then
    echo "  最终落地: $(host_fmt "$FWD_H"):${FWD_P}（${FWD_M}）$([[ $FWD_ON == 1 ]] && echo "${C_GREEN}已启用${C_NONE}" || echo "${C_YELLOW}已停用${C_NONE}")"
  else
    echo "  最终落地: 未设置"
  fi
  echo "  必须已有来源白名单，且其中有与目标同族的地址，否则不会安装 DNAT。"
  echo "  当前白名单: ${LAND_ALLOW:-未设置}"
  hr
  echo "  1) 设置 / 更换最终落地（粘贴 ss://）  2) 停用（保留目标，去掉 DNAT）  3) 删除目标  0) 返回"
  local c; ask c "请选择" "0"
  case $c in
    1) OPT_LAND_LINK=""; land_forward_add ;;
    2) land_forward_off ;;
    3) land_forward_del ;;
    *) return 0 ;;
  esac
}

# ---------- 中转机：落地转发 ----------
RELAY_M="" RELAY_K="" RELAY_H="" RELAY_P="" RELAY_N=""
ss_parse() { # $1 ss:// 链接；成功时设置 RELAY_M/K/H/P/N。返回 1 格式错误 2 非 SS2022 3 密钥长度不对
  local l rest ui hp name="" m k host port
  l=$(printf '%s' "$1" | tr -d '[:space:]')
  [[ $l == ss://* ]] || return 1
  rest=${l#ss://}
  if [[ $rest == *'#'* ]]; then name=${rest#*#}; rest=${rest%%#*}; fi
  rest=${rest%%\?*}; rest=${rest%/}
  [[ $rest == *@* ]] || rest=$(b64d "$rest") || return 1
  [[ $rest == *@* ]] || return 1
  ui=${rest%@*}; hp=${rest##*@}
  ui=$(urldecode "$ui")
  [[ $ui == *:* ]] || ui=$(b64d "$ui") || return 1
  [[ $ui == *:* ]] || return 1
  m=${ui%%:*}; k=${ui#*:}
  if [[ $hp =~ ^\[([0-9A-Fa-f:.]+)\]:([0-9]+)$ ]]; then host=${BASH_REMATCH[1]} port=${BASH_REMATCH[2]}
  elif [[ $hp =~ ^([^:/]+):([0-9]+)$ ]]; then host=${BASH_REMATCH[1]} port=${BASH_REMATCH[2]}
  else return 1; fi
  valid_addr "$host" && is_port "$port" || return 1
  [[ $m == 2022-blake3-* ]] || return 2
  m=$(land_norm_method "$m") || return 2
  land_key_ok "$m" "$k" || return 3
  name=$(urldecode "$name" | tr -cd 'A-Za-z0-9_.-')
  RELAY_M=$m RELAY_K=$k RELAY_H=$host RELAY_P=$port RELAY_N=$name
}
relay_active() { [[ $RELAY_ON == 1 && -n $RELAY_LINK ]] && (( ! LAND_MODE )) && ss_parse "$RELAY_LINK"; }
relay_tag() { land_tag_of "$RELAY_N" "$RELAY_H"; }
relay_inject() { # $1 Xray 配置文件（节点模式）：落地出站放在最前 + 路由最后一条兜底到落地
  relay_active || { [[ $RELAY_ON == 1 && -n $RELAY_LINK ]] && warn "保存的落地链接无法解析，已按直连生成配置。"; return 0; }
  local ob tag; tag=$(relay_tag)
  ob=$(land_outbound_json "$RELAY_M" "$RELAY_K" "$RELAY_H" "$RELAY_P" "$tag")
  if [[ -z $RELAY_SOCKS ]] || ! is_port "$RELAY_SOCKS"; then RELAY_SOCKS=$(land_pick_default_port); fi
  jq --argjson ob "$ob" --argjson sp "$RELAY_SOCKS" --argjson hy "${HY2_ENABLED:-0}" '
    .outbounds = [$ob] + .outbounds
    | (if $hy == 1 then .inbounds += [{tag: "hy2-relay", listen: "127.0.0.1", port: $sp, protocol: "socks",
          settings: {auth: "noauth", udp: true, ip: "127.0.0.1"}}] else . end)
    | .routing.rules += [{type: "field", network: "tcp,udp", outboundTag: $ob.tag}]' "$1" >"${1}.relay" &&
    mv -f "${1}.relay" "$1"
}
relay_hy2_yaml() { # 追加到 Hysteria2 配置：经本机 Xray socks 入站走落地
  relay_active || return 0
  (( HY2_ENABLED )) && is_port "${RELAY_SOCKS:-}" || return 0
  cat <<HY

# 落地转发：Hysteria2 流量经本机 Xray（127.0.0.1:${RELAY_SOCKS}）→ 落地机 ${RELAY_H}
outbounds:
  - name: land
    type: socks5
    socks5:
      addr: 127.0.0.1:${RELAY_SOCKS}
HY
}

relay_test() { # 使用 RELAY_M/K/H/P：TCP 连接 → 经落地的真实请求（检查出口 IP）
  local hip
  info "测试 TCP 连接 ${RELAY_H}:${RELAY_P} ..."
  if tcp_probe "$RELAY_H" "$RELAY_P"; then ok "TCP 连接成功。"
  else warn "无法建立 TCP 连接到 ${RELAY_H}:${RELAY_P}（落地机未运行 / 端口未放行 / 落地机白名单未包含本机 IP / 云安全组拦截）。"; return 1; fi
  info "经落地机发起真实请求（查询出口 IP）..."
  if ! ss_probe "$RELAY_H" "$RELAY_P" "$RELAY_M" "$RELAY_K"; then
    warn "经落地机的请求失败：可能是密钥/加密方式不对、落地机白名单未包含本机出口 IP $(curl -4 -s --connect-timeout 5 -m 8 https://api.ipify.org 2>/dev/null || true)，或两端时间相差超过 30 秒。"
    return 1
  fi
  hip=$RELAY_H
  if ! is_ipv4 "$hip" && [[ $hip != *:* ]]; then hip=$(getent ahosts "$hip" 2>/dev/null | awk 'NR==1{print $1}') || hip=""; fi
  if [[ -n $hip && $LAND_EXIT_IP == "$hip" ]]; then ok "经落地机访问正常：出口 IP ${LAND_EXIT_IP}（与落地机地址一致）"
  else ok "经落地机访问正常：出口 IP ${LAND_EXIT_IP}$([[ -n $hip ]] && echo "（落地机地址 ${hip}；多 IP / NAT 落地机出口不同属正常）")"; fi
  return 0
}

relay_add() {
  load_state
  if (( LAND_MODE )); then land_relay_add; return; fi
  need_node
  local link=${OPT_LAND_LINK:-} rc=0
  if [[ -z $link ]]; then
    (( OPT_AUTO )) && die "请提供链接：proxy land-add 'ss://...'"
    echo "  在落地机上执行 proxy info 可获得 ss:// 链接（Shadowsocks 2022）。"
    ask link "粘贴落地机 ss:// 链接" "${RELAY_LINK}"
  fi
  ss_parse "$link" || rc=$?
  case $rc in
    0) ;;
    2) die "只支持 Shadowsocks 2022 链接（2022-blake3-aes-128-gcm / aes-256-gcm / chacha20-poly1305）。" ;;
    3) die "密钥长度与加密方式不匹配（aes-128 需要 16 字节、其它需要 32 字节的 base64 密钥）。" ;;
    *) die "无法解析 ss:// 链接（格式: ss://方法:密钥@地址:端口#名称）。" ;;
  esac
  step "测试落地机 ${RELAY_H}:${RELAY_P}（${RELAY_M}）"
  if ! relay_test; then
    if (( OPT_FORCE )); then warn "测试未通过，--force 强制启用。"
    elif (( OPT_AUTO )) || ! confirm "测试未通过，仍然保存并启用落地转发吗？" n; then
      die "未启用落地转发（配置未改变）。确认无误可加 --force 强制启用。"
    fi
  fi
  RELAY_LINK=$(ss_link_build "$RELAY_M" "$RELAY_K" "$RELAY_H" "$RELAY_P" "${RELAY_N:-land}")
  RELAY_ON=1
  if [[ -z $RELAY_SOCKS ]] || port_in_use tcp "$RELAY_SOCKS"; then RELAY_SOCKS=$(land_pick_default_port); fi
  detect_os
  apply_all
  ok "落地转发已启用：本机 Xray 默认出站 → $(relay_tag)（${RELAY_H}:${RELAY_P}）$( ((HY2_ENABLED)) && echo '；Hysteria2 同样经落地机')"
  ( trap - ERR; set +e; reality_selftest ) || true
}
relay_off() {
  load_state
  if (( LAND_MODE )); then land_egress_off; return; fi
  need_node
  [[ -n $RELAY_LINK ]] || { warn "尚未设置落地转发。"; return 0; }
  [[ $RELAY_ON == 1 ]] || { info "落地转发已是停用状态。"; return 0; }
  RELAY_ON=0; detect_os; apply_all
  ok "已停用落地转发（恢复直连出站；落地链接已保留，可用 proxy land-on 重新启用）。"
}
relay_on() {
  load_state
  if (( LAND_MODE )); then land_relay_on; return; fi
  need_node
  [[ -n $RELAY_LINK ]] || die "没有保存的落地链接，请先 proxy land-add 'ss://...'"
  ss_parse "$RELAY_LINK" || die "保存的落地链接无法解析，请重新 land-add。"
  step "测试落地机 ${RELAY_H}:${RELAY_P}"
  if ! relay_test && (( ! OPT_FORCE )); then
    { (( OPT_AUTO )) || ! confirm "测试未通过，仍然启用吗？" n; } && die "未启用落地转发。"
  fi
  RELAY_ON=1; detect_os; apply_all
  ok "已启用落地转发 → $(relay_tag)"
  ( trap - ERR; set +e; reality_selftest ) || true
}
relay_del() {
  load_state
  if (( LAND_MODE )); then land_relay_del; return; fi
  need_node
  [[ -n $RELAY_LINK ]] || { info "没有设置落地转发。"; return 0; }
  (( OPT_AUTO )) || confirm "删除保存的落地链接并恢复直连？" y || return 0
  RELAY_LINK="" RELAY_ON=0 RELAY_SOCKS=""; detect_os; apply_all
  ok "已删除落地转发，恢复直连出站。"
}
relay_status_line() {
  if [[ -z $RELAY_LINK ]]; then echo "未设置"; return; fi
  if ss_parse "$RELAY_LINK"; then
    printf '%s %s:%s（%s）%s' "$(relay_tag)" "$(host_fmt "$RELAY_H")" "$RELAY_P" "$RELAY_M" "$([[ $RELAY_ON == 1 ]] && echo "${C_GREEN}已启用${C_NONE}" || echo "${C_YELLOW}已停用${C_NONE}")"
  else echo "链接无法解析"; fi
}
menu_relay() {
  need_node
  echo; hr; _green "  落地转发（中转机 → 落地机 Shadowsocks 2022）"; hr
  echo "  当前落地: $(relay_status_line)"
  echo "  本机出口 IP: $(curl -4 -s --connect-timeout 4 -m 6 https://api.ipify.org 2>/dev/null || echo 未知)（需在落地机白名单中: 落地机上 proxy allow）"
  echo "  启用后：客户端 → 本机 Reality/Hy2 → 落地机 → 目标网站；内网 / BT 屏蔽规则仍优先生效。"
  hr
  echo "  1) 添加 / 修改落地（粘贴 ss:// 链接）  2) 测试落地连通性  3) 停用（恢复直连，保留链接）"
  echo "  4) 重新启用  5) 删除落地  0) 返回"
  local c; ask c "请选择" "0"
  case $c in
    1) OPT_LAND_LINK=""; relay_add ;;
    2) if [[ -n $RELAY_LINK ]] && ss_parse "$RELAY_LINK"; then relay_test || true; else warn "尚未设置落地。"; fi ;;
    3) relay_off ;;
    4) relay_on ;;
    5) relay_del ;;
    *) return 0 ;;
  esac
}
do_land_cli() {
  case ${OPT_LAND_ACT:-menu} in
    add) relay_add ;;
    on) relay_on ;;
    off) relay_off ;;
    del) relay_del ;;
    direct|clear) land_direct ;;
    forward) land_forward_add ;;
    forward-off) land_forward_off ;;
    forward-del) land_forward_del ;;
    test)
      load_state
      if (( LAND_MODE )); then
        if [[ ${FWD_ON:-0} == 1 ]] && fwd_load "$FWD_LINK"; then
          info "测试 TCP 连接 ${FWD_H}:${FWD_P} ..."
          if tcp_probe "$FWD_H" "$FWD_P"; then ok "TCP 连接成功。"; else die "无法建立 TCP 到 ${FWD_H}:${FWD_P}。"; fi
        elif [[ -n $RELAY_LINK ]] && ss_parse "$RELAY_LINK"; then relay_test
        else die "尚未设置下一跳或原样转发。"; fi
      else
        need_node
        if [[ -z $RELAY_LINK ]] || ! ss_parse "$RELAY_LINK"; then die "尚未设置落地。"; fi
        relay_test
      fi ;;
    *) load_state; if (( LAND_MODE )); then land_show_info; else menu_relay; fi ;;
  esac
}

