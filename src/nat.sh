# ============================================================
#            NAT 模式：公网地址 / 映射端口
# ============================================================
# 映射端口列表 NAT_PORTS（逗号分隔），每项:
#   52430            外部 52430 → 内部 52430（TCP+UDP 或仅 TCP，取决于服务商）
#   52430:443        外部 52430 → 内部 443
#   50000-50100      整段 1:1 转发
#   50000-50100:20000-20100  整段按偏移转发（长度必须相同）
is_ipv4() { [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
valid_addr() {
  local a=$1
  is_ipv4 "$a" && return 0
  [[ $a == *:* && $a =~ ^[0-9A-Fa-f:.]+$ ]] && return 0
  [[ ${#a} -le 253 && $a =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}
is_private_v4() { [[ $1 =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|127\.|169\.254\.) ]]; }
# 接受 "a-b" 或单个端口，输出 "a b"
parse_port_span() {
  local r=$1
  if is_port "$r"; then printf '%s %s' "$r" "$r"; return 0; fi
  [[ $r =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
  local a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
  is_port "$a" && is_port "$b" && (( a <= b )) || return 1
  printf '%s %s' "$a" "$b"
}
# 单项 → "外部起 外部止 内部起"
nat_parse_item() {
  local it=${1// /} e i e1 e2 i1 i2
  [[ -n $it ]] || return 1
  e=${it%%:*}; i=$e; [[ $it == *:* ]] && i=${it#*:}
  local ps
  ps=$(parse_port_span "$e") || return 1
  read -r e1 e2 <<<"$ps"
  ps=$(parse_port_span "$i") || return 1
  read -r i1 i2 <<<"$ps"
  [[ -n $e1 && -n $i1 ]] || return 1
  (( e2 - e1 == i2 - i1 )) || return 1
  printf '%s %s %s' "$e1" "$e2" "$i1"
}
nat_fmt_item() { # $1 e1 $2 e2 $3 i1
  local e=$1 i=$3
  (( $2 > $1 )) && e="$1-$2" && i="$3-$(( $3 + $2 - $1 ))"
  if [[ $e == "$i" ]]; then printf '%s' "$e"; else printf '%s:%s' "$e" "$i"; fi
}
# 规范化用户输入的列表（逗号/空格分隔），失败返回 1
nat_norm_list() {
  local it out="" e1 e2 i1 f l
  l=$(sanitize_port_input "$1")
  for it in ${l//,/ }; do
    f=$(nat_parse_item "$it") || return 1
    read -r e1 e2 i1 <<<"$f"
    [[ -n $e1 ]] || return 1
    f=$(nat_fmt_item "$e1" "$e2" "$i1")
    [[ ",$out," == *",$f,"* ]] || out+="${out:+,}$f"
  done
  [[ -n $out ]] || return 1
  printf '%s' "$out"
}
# 解析结果缓存在数组中（端口段很大时避免反复 fork）
NI_KEY="" NI_E1=() NI_E2=() NI_I1=()
nat_items() {
  [[ -n $NI_KEY && $NI_KEY == "$NAT_PORTS" ]] && return 0
  NI_E1=() NI_E2=() NI_I1=()
  local it e1 e2 i1 f
  for it in ${NAT_PORTS//,/ }; do
    f=$(nat_parse_item "$it") || continue
    read -r e1 e2 i1 <<<"$f"
    [[ -n $e1 ]] || continue
    NI_E1+=("$e1") NI_E2+=("$e2") NI_I1+=("$i1")
  done
  NI_KEY=$NAT_PORTS
}
ext2int() { # 外部端口 → 内部端口；未映射返回 1
  nat_items
  local k
  for k in "${!NI_E1[@]}"; do
    (( $1 >= NI_E1[k] && $1 <= NI_E2[k] )) && { echo $(( NI_I1[k] + $1 - NI_E1[k] )); return 0; }
  done
  return 1
}
int2ext() {
  nat_items
  local k
  for k in "${!NI_E1[@]}"; do
    (( $1 >= NI_I1[k] && $1 <= NI_I1[k] + NI_E2[k] - NI_E1[k] )) && { echo $(( NI_E1[k] + $1 - NI_I1[k] )); return 0; }
  done
  return 1
}
nat_all_ext() { # 逐个输出全部外部端口
  nat_items
  local k q
  for k in "${!NI_E1[@]}"; do for (( q = NI_E1[k]; q <= NI_E2[k]; q++ )); do echo "$q"; done; done
}
nat_ext_list() { # 仅外部端口（逗号分隔，整段显示为 a-b），用于提示
  nat_items
  local k out=""
  for k in "${!NI_E1[@]}"; do
    if (( NI_E2[k] > NI_E1[k] )); then out+="${out:+,}${NI_E1[k]}-${NI_E2[k]}"; else out+="${out:+,}${NI_E1[k]}"; fi
  done
  printf '%s' "$out"
}
nat_has_span() { # 是否包含整段转发（≥2 个端口的项）
  nat_items
  local k
  for k in "${!NI_E1[@]}"; do (( NI_E2[k] > NI_E1[k] )) && return 0; done
  return 1
}
nat_excluded() { [[ " ${NAT_EXCLUDE} " == *" $1 "* ]]; }
nat_usable() { is_port "$1" && ! nat_excluded "$1" && ext2int "$1" >/dev/null; }
nat_first_usable() { # 第一个可用外部端口（跳过参数中列出的端口）
  local p
  while read -r p; do
    nat_excluded "$p" && continue
    [[ " $* " == *" $p "* ]] && continue
    echo "$p"; return 0
  done < <(nat_all_ext)
  return 1
}
# 本机其它程序已监听的内部端口（转换为外部端口输出）
nat_busy_ext_ports() {
  local p e out=""
  for p in $( { ss -Htlnp 2>/dev/null | awk '!/"xray"/{n=split($4,a,":"); print a[n]}'
               ss -Hulnp 2>/dev/null | awk '!/"hysteria"/{n=split($4,a,":"); print a[n]}'; } | sort -un); do
    [[ $p =~ ^[0-9]+$ ]] || continue
    # 本脚本自己的服务（ss 看不到进程名时也要识别出来）
    if [[ $p == "$XRAY_PORT" || $p == "$HY2_PORT" || $p == "$XHTTP_PORT" || $p == "$TROJAN_PORT" || $p == "$ANYTLS_PORT" || $p == "$TUIC_PORT" ]] && { svc_active xray || svc_active hysteria-server || svc_active sing-box; }; then continue; fi
    e=$(int2ext "$p") && out+="$e "
  done
  printf '%s' "${out% }"
}
# 端口段 "a-b,c"：逐个输出 / 压缩 / 计数
segs_expand() {
  local seg a b q
  for seg in ${1//,/ }; do
    a=${seg%-*} b=${seg#*-}
    for (( q = a; q <= b; q++ )); do echo "$q"; done
  done
}
segs_compress() {
  awk 'NF{ if (s == "") { s = $1; e = $1 } else if ($1 == e + 1) { e = $1 } else { out = out (out ? "," : "") (s == e ? s : s "-" e); s = $1; e = $1 } }
       END{ if (s != "") out = out (out ? "," : "") (s == e ? s : s "-" e); print out }'
}
segs_count() { [[ -n $1 ]] || { echo 0; return; }; segs_expand "$1" | wc -l; }
valid_segs() {
  local seg
  [[ -n $1 && $1 =~ ^[0-9,-]+$ ]] || return 1
  for seg in ${1//,/ }; do parse_port_span "$seg" >/dev/null || return 1; done
}
# 端口跳跃可用的外部端口：已映射、未排除、不是某个 TCP 协议独占的端口
# （Reality 与 Hy2 共用同一外部端口时仍可跳跃，与旧版一致）
nat_hop_ok() {
  nat_usable "$1" || return 1
  local blocked=0
  if (( REALITY_ENABLED )) && [[ -n ${XRAY_EXT_PORT:-} && $1 == "$XRAY_EXT_PORT" ]]; then blocked=1; fi
  if (( XHTTP_ENABLED )) && [[ -n ${XHTTP_EXT_PORT:-} && $1 == "$XHTTP_EXT_PORT" ]]; then blocked=1; fi
  if (( TROJAN_ENABLED )) && [[ -n ${TROJAN_EXT_PORT:-} && $1 == "$TROJAN_EXT_PORT" ]]; then blocked=1; fi
  if (( ANYTLS_ENABLED )) && [[ -n ${ANYTLS_EXT_PORT:-} && $1 == "$ANYTLS_EXT_PORT" ]]; then blocked=1; fi
  if (( ! blocked )); then return 0; fi
  if (( HY2_ENABLED )) && [[ $1 == "${HY2_EXT_PORT:-}" ]]; then return 0; fi
  if (( TUIC_ENABLED )) && [[ $1 == "${TUIC_EXT_PORT:-}" ]]; then return 0; fi
  return 1
}
nat_hop_filter() { # 输出过滤后的外部端口段（自动拆分）
  local q
  segs_expand "$1" | sort -un | while read -r q; do nat_hop_ok "$q" && echo "$q"; done | segs_compress
}
nat_segs_ext2int() { # 外部端口段 → 内部端口段
  local q
  segs_expand "$1" | while read -r q; do ext2int "$q"; done | sort -un | segs_compress
}

choose_nat_addr() {
  # v1.2.1：外部查询服务得到的是「出口 IP」；NAT 机的入口（商家端口映射地址）经常与出口不同，
  #         因此交互模式不再把出口 IP 作为默认值直接回车通过，必须手动填写或明确确认。
  # 只有上次在 NAT 模式下填写过的地址（NAT_PORTS 非空）才算「已确认的入口地址」；普通模式保存的是自动检测的 IP
  local a egress=${PUBLIC_IP4:-$PUBLIC_IP6} saved=""
  [[ -n $NAT_PORTS ]] && saved=${SERVER_ADDR:-}
  if [[ -n $OPT_NAT_ADDR ]]; then
    a=${OPT_NAT_ADDR#[}; a=${a%]}; a=${a// /}
    valid_addr "$a" || die "公网地址无效: ${a:-空}（请用 --nat-addr 指定 IP 或域名）"
    SERVER_ADDR=$a
  elif (( OPT_AUTO )); then
    if [[ -n $saved ]] && valid_addr "$saved"; then SERVER_ADDR=$saved
    elif [[ -n $egress ]]; then
      SERVER_ADDR=$egress
      warn "未指定 --nat-addr：暂用检测到的出口 IP ${egress} 作为链接地址。NAT 机入口地址可能不同，请以商家面板「端口映射」中的地址为准（proxy nat → 1 修改，或重新安装时加 --nat-addr）。"
    else
      die "无法确定公网地址，请用 --nat-addr 指定商家提供的入口 IP 或域名。"
    fi
  else
    [[ -n $egress ]] || egress=$(nat_probe_pubip)   # 修改端口等管理操作没有预先检测
    echo "   公网地址 = 客户端连接的入口地址：请填写商家面板「端口映射 / NAT 转发」条目中显示的 IP 或域名（写进分享链接）。"
    if [[ -n $egress ]]; then
      echo "   检测到的出口 IP: ${egress}（NAT 机入口地址可能不同）"
    else
      echo "   未能检测到出口 IP。"
    fi
    # 之前手动填写过（且与出口 IP 不同）的地址可回车沿用；与出口 IP 相同时同样需要明确确认
    local def=""; [[ -n $saved && $saved != "$egress" ]] && def=$saved
    while :; do
      ask a "公网地址（商家提供的入口 IP 或解析到它的域名$( [[ -n $def ]] && echo '，回车沿用当前' )）" "$def"
      (( TTY_EOF )) && die "未输入公网地址（可用 --nat-addr 指定）。"
      a=${a#[}; a=${a%]}; a=${a// /}
      if [[ -z $a ]]; then
        if [[ -n $egress ]] && confirm "确认出口 IP ${egress} 同时也是入口地址（商家面板端口映射里显示的就是它）？" n; then a=$egress
        else warn "请输入商家面板端口映射中的入口地址。"; continue; fi
      elif [[ ${a,,} == y || ${a,,} == yes ]] && [[ -n $egress ]]; then
        if confirm "使用出口 IP ${egress} 作为入口地址？" y; then a=$egress; else continue; fi
      fi
      if valid_addr "$a"; then SERVER_ADDR=$a; break; fi
      warn "地址格式无效，请输入 IPv4 / IPv6 / 域名。"
    done
  fi
  if is_ipv4 "$SERVER_ADDR" && is_private_v4 "$SERVER_ADDR"; then
    warn "${SERVER_ADDR} 是内网地址，客户端通常无法直接连接；请确认填写的是服务商提供的公网 IP / 域名。"
  fi
  nat_addr_selfcheck "$SERVER_ADDR" "$egress"
  [[ $SERVER_ADDR == *:* ]] && info "公网地址为 IPv6，链接中将写成 [${SERVER_ADDR}] 形式。"
  ok "公网地址: ${SERVER_ADDR}"
}
nat_addr_selfcheck() { # $1 入口地址 $2 出口 IP：只提示，不阻止
  local addr=$1 egress=$2 ip=""
  if is_ipv4 "$addr" || [[ $addr == *:* ]]; then ip=$addr
  elif have getent; then ip=$(getent ahosts "$addr" 2>/dev/null | awk 'NR==1{print $1}') || ip=""
    if [[ -n $ip ]]; then info "域名 ${addr} 解析到 ${ip}。"; else info "域名 ${addr} 暂时无法解析（客户端需能解析该域名）。"; return 0; fi
  fi
  [[ -n $ip ]] || return 0
  if ip_is_local "$ip"; then info "入口地址 ${ip} 配置在本机网卡上。"
  elif [[ -n $egress && $ip != "$egress" ]]; then
    info "入口地址 ${ip} 与出口 IP ${egress} 不同、也不在本机网卡上：NAT 机入口与出口不同很常见，只要与商家面板端口映射一致即可。"
  fi
  return 0
}

# 交互：为没有写 ":内部" 的每一项询问内部端口（默认沿用已保存的映射，否则与公网端口相同）
nat_ask_internal() {
  local it out="" in def m l
  l=$(sanitize_port_input "$1")
  for it in ${l//,/ }; do
    if [[ $it == *:* ]] || ! parse_port_span "$it" >/dev/null; then out+="${out:+,}$it"; continue; fi
    def=$it
    for m in ${NAT_PORTS//,/ }; do [[ $m == "${it}:"* ]] && def=${m#*:}; done
    ask in "公网端口 ${it} 对应的内部端口（本机监听端口，相同直接回车）" "$def" >&2
    in=$(sanitize_port_input "$in"); in=${in// /}
    if [[ -z $in || $in == "$it" ]]; then out+="${out:+,}$it"; else out+="${out:+,}${it}:${in}"; fi
  done
  printf '%s' "$out"
}

# 从 --port / --hy2-port（外部[:内部]）推导映射列表
nat_ports_from_opts() {
  local l="" x
  for x in "$OPT_PORT" "$OPT_HY2_PORT" "$OPT_XHTTP_PORT" "$OPT_TROJAN_PORT" "$OPT_TUIC_PORT" "$OPT_ANYTLS_PORT"; do
    [[ -n $x ]] || continue
    [[ ",$l," == *",$x,"* ]] && continue
    l+="${l:+,}$x"
  done
  printf '%s' "$l"
}
opt_ext() { printf '%s' "${1%%:*}"; }   # "52430:443" → 52430

choose_nat_ports() {
  local r p def raw
  # 1) 服务商映射给本机的端口
  def=${OPT_NAT_EXT:-$(nat_ports_from_opts)}
  local from_opt=0; [[ -n $def ]] && from_opt=1
  [[ -n $def ]] || def=$NAT_PORTS
  while :; do
    if (( from_opt )); then r=$def; raw=$r
    else
      echo "   NAT 机器只有服务商映射过的端口能从外部访问。常见两种："
      echo "     · 逐条映射（例如面板里只能加 5 条规则）：填写公网端口，如 59221 或 52430,52431"
      echo "     · 整段转发：填写范围，如 10001-10020"
      echo "   随后会逐个询问对应的内部端口（与公网端口相同直接回车）；也可直接写 公网:内部，如 59221:443"
      ask r "已映射的公网端口（逗号分隔）" "$def"
      raw=$r
      r=$(nat_ask_internal "$(sanitize_port_input "$r")")
    fi
    if r=$(nat_norm_list "$r"); then NAT_PORTS=$r; nat_items; break; fi
    { (( from_opt )) || (( OPT_AUTO )); } && die "NAT 映射端口无效或未指定: $(show_raw_input "$raw")。请使用 --nat-ports 52430,52431（外部[:内部]，或整段 a-b）或 --port 外部端口。"
    warn "格式无效。收到的输入: $(show_raw_input "$raw")（请检查是否含中文标点或不可见字符）"
    warn "正确示例: 52430,52431 或 52430:8443 或 10001-10020。"
  done
  info "映射端口: ${NAT_PORTS}"
  # 2) 排除端口（整段转发时范围内可能含 SSH 映射等）
  local busy x list=""
  busy=$(nat_busy_ext_ports)
  if nat_has_span; then
    detect_ssh_ports
    if [[ -z $OPT_NAT_EXCLUDE && -z $NAT_EXCLUDE ]]; then
      warn "本机 SSH 监听内部端口 ${SSH_PORTS}；若服务商把端口段内某个外部端口映射给了 SSH，请务必排除（--nat-exclude 端口）。"
    fi
  fi
  if [[ -n $OPT_NAT_EXCLUDE ]]; then def=$OPT_NAT_EXCLUDE
  else
    # 保存的排除项只对整段转发有意义；逐条映射时只按当前占用情况排除
    local keep=""; nat_has_span && keep=$NAT_EXCLUDE
    def=$(tr ' ' '\n' <<<"$keep $busy" | awk 'NF' | sort -un | tr '\n' ' '); def=${def% }
  fi
  [[ -n $busy ]] && info "映射端口中已被本机其它程序占用的（外部端口）: ${busy}（默认排除）"
  if [[ -n $OPT_NAT_EXCLUDE ]] || (( OPT_AUTO )) || ! nat_has_span; then r=$def
  else ask r "端口段内需要排除的外部端口（如映射给 SSH 的端口，空格/逗号分隔；没有请回车，none 清空）" "$def"; r=$(sanitize_port_input "$r"); fi
  [[ ${r,,} == none || $r == 无 ]] && r=""
  for x in ${r//,/ }; do
    if is_port "$x" && ext2int "$x" >/dev/null; then [[ " $list " == *" $x "* ]] || list+="$x "
    else warn "忽略不在映射端口内的排除项: ${x}"; fi
  done
  NAT_EXCLUDE=${list% }
  [[ -n $NAT_EXCLUDE ]] && info "排除的外部端口: ${NAT_EXCLUDE}"
  nat_first_usable >/dev/null || die "映射端口 ${NAT_PORTS} 中没有可用端口（全部被排除）。"

  # 3) VLESS-REALITY（TCP）。落地机始终走这里；节点模式在关掉 Reality 时跳过
  if (( ! LAND_MODE && ! REALITY_ENABLED )); then
    XRAY_EXT_PORT=""
  else
  def=$(opt_ext "${OPT_PORT:-}")
  if [[ -z $def ]]; then
    if nat_usable "${XRAY_EXT_PORT:-0}"; then def=$XRAY_EXT_PORT; else def=$(nat_first_usable); fi
  fi
  while :; do
    if [[ -n $OPT_PORT ]]; then p=$(opt_ext "$OPT_PORT"); else ask p "${XRAY_LABEL:-VLESS-REALITY} 使用的外部端口（$( ((LAND_MODE)) && echo 'TCP+UDP，映射需同时包含 UDP 才能转发 UDP' || echo TCP)，可选: $(nat_ext_list)）" "$def"; p=$(sanitize_port_input "$p"); p=${p// /}; fi
    if nat_usable "$p"; then
      if check_port_free tcp "$(ext2int "$p")" "xray"; then XRAY_EXT_PORT=$p; XRAY_PORT=$(ext2int "$p"); break; fi
    else
      warn "端口 ${p} 不在映射端口中或已被排除。"
    fi
    { [[ -n $OPT_PORT ]] || (( OPT_AUTO )); } && die "无法使用外部端口 ${p} 作为 ${XRAY_LABEL:-VLESS-REALITY} 端口（NAT 模式下 --port 表示外部端口，需包含在 --nat-ports 中）。"
    def=$(nat_first_usable "$p") || def=""
  done
  fi
  if (( LAND_MODE )); then # 落地机：只有一个 SS2022 端口（TCP+UDP）
    check_port_free udp "$XRAY_PORT" "xray" || warn "UDP ${XRAY_PORT} 已被占用，Shadowsocks 的 UDP 转发可能无法使用。"
    HY2_ENABLED=0 HOP_RANGE="" HOP_EXT_RANGE="" HY2_EXT_PORT="" HOP_BACKEND=""
    return 0
  fi

  # 4) Hysteria2（UDP）：可与 Reality 共用同一个端口号（服务商同时映射 TCP+UDP 时，节省映射名额）
  if [[ -n $OPT_HY2 ]]; then HY2_ENABLED=$OPT_HY2
  elif (( ! OPT_AUTO )); then
    if confirm "是否同时安装 Hysteria2（UDP；需要服务商映射 UDP）？" "$([[ $HY2_ENABLED == 1 ]] && echo y || echo n)"; then HY2_ENABLED=1; else HY2_ENABLED=0; fi
  fi
  if (( ! HY2_ENABLED )); then HOP_RANGE="" HOP_EXT_RANGE="" HY2_EXT_PORT="" HOP_BACKEND=""; else
  local other share
  other=$(nat_first_usable "$XRAY_EXT_PORT") || other=""
  if [[ -n $OPT_HY2_PORT ]]; then share=0; [[ $(opt_ext "$OPT_HY2_PORT") == "$XRAY_EXT_PORT" ]] && share=1
  elif [[ -n $OPT_NAT_SHARE ]]; then share=$OPT_NAT_SHARE
  elif [[ -z $other ]] || (( OPT_AUTO )); then share=1
  else
    local sdef=y; [[ -n $HY2_EXT_PORT && $HY2_EXT_PORT != "$XRAY_EXT_PORT" ]] && sdef=n
    if confirm "服务商的映射是否同时转发 TCP 和 UDP？是则 Hysteria2 与 Reality 共用外部端口 ${XRAY_EXT_PORT}（节省映射名额）" "$sdef"; then share=1; else share=0; fi
  fi
  if (( ! REALITY_ENABLED )); then share=0; [[ -n $other ]] || other=$(nat_first_usable || true); fi
  if (( share )); then
    def=$XRAY_EXT_PORT
    [[ -z $OPT_NAT_SHARE && -z $OPT_HY2_PORT ]] && info "默认 Hysteria2 与 Reality 共用外部端口 ${XRAY_EXT_PORT}（需服务商同时映射 TCP+UDP；如只映射 TCP，请加 --nat-no-share 并提供第二个端口）。"
  else
    if [[ -z $other ]]; then
      warn "没有第二个可用映射端口，且未确认 TCP+UDP 共用，已关闭 Hysteria2。"
      HY2_ENABLED=0 HOP_RANGE="" HOP_EXT_RANGE="" HY2_EXT_PORT="" HOP_BACKEND=""
    else
      def=$other
      nat_usable "${HY2_EXT_PORT:-0}" && [[ $HY2_EXT_PORT != "$XRAY_EXT_PORT" ]] && def=$HY2_EXT_PORT
    fi
  fi
  if (( HY2_ENABLED )); then
  [[ -n $OPT_HY2_PORT ]] && def=$(opt_ext "$OPT_HY2_PORT")
  while :; do
    if [[ -n $OPT_HY2_PORT ]] || (( OPT_AUTO )); then p=$def
    else ask p "Hysteria2 使用的外部端口（UDP，可选: $(nat_ext_list)）" "$def"; p=$(sanitize_port_input "$p"); p=${p// /}; fi
    if nat_usable "$p"; then
      if check_port_free udp "$(ext2int "$p")" "hysteria"; then HY2_EXT_PORT=$p; HY2_PORT=$(ext2int "$p"); break; fi
    else
      warn "端口 ${p} 不在映射端口中或已被排除。"
    fi
    { [[ -n $OPT_HY2_PORT ]] || (( OPT_AUTO )); } && die "无法使用外部端口 ${p} 作为 Hysteria2 端口。"
  done
  [[ $HY2_EXT_PORT == "$XRAY_EXT_PORT" ]] && info "Reality (TCP) 与 Hysteria2 (UDP) 共用外部端口 ${HY2_EXT_PORT}，请确认该映射同时包含 TCP 和 UDP。"

  # 5) 端口跳跃：NAT 模式默认关闭；只有整段转发时才可开启（自动跳过 Reality / 排除端口，必要时拆分为多段）
  local hop be="" filtered
  if [[ -n $OPT_HOP ]]; then hop=$OPT_HOP
  elif (( OPT_AUTO )) || ! nat_has_span; then hop=${HOP_EXT_RANGE:-none}
  else
    hop=${HOP_EXT_RANGE:-none}
    ask hop "Hysteria2 端口跳跃范围（外部端口，须是服务商整段转发的端口，如 10002-10020；默认关闭）" "$hop"
  fi
  hop=$(sanitize_port_input "$hop"); hop=${hop// /}
  HOP_RANGE="" HOP_EXT_RANGE=""
  if [[ -n $hop && $hop != none && $hop != no ]]; then
    if valid_segs "$hop"; then
      filtered=$(nat_hop_filter "$hop")
      if (( $(segs_count "$filtered") >= 2 )); then
        [[ $filtered != "$hop" ]] && info "已去掉未映射 / Reality 独占 / 排除的端口，跳跃范围调整为: ${filtered}"
        HOP_EXT_RANGE=$filtered; HOP_RANGE=$(nat_segs_ext2int "$filtered")
      else
        warn "跳跃范围 ${hop} 中已映射且可用的端口不足 2 个，端口跳跃保持关闭。"
      fi
    else
      warn "跳跃范围格式无效: ${hop}（例如 10002-10020 或 10002-10010,10012-10020），端口跳跃保持关闭。"
    fi
  fi
  if [[ -n $HOP_RANGE ]]; then
    have nft || have iptables || { info "安装 nftables（端口跳跃需要）..."; pkg_try nftables; }
    if be=$(nat_hop_probe); then
      HOP_BACKEND=$be
      info "可以添加 NAT 转发规则（${be}），启用端口跳跃：外部 UDP ${HOP_EXT_RANGE} → 内部 ${HOP_RANGE} → ${HY2_PORT}"
    else
      warn "当前环境（${VIRT:-未知}）无法添加 NAT 转发规则（LXC/OpenVZ 容器通常没有 CAP_NET_ADMIN），端口跳跃已关闭，Hysteria2 仅使用单端口 ${HY2_EXT_PORT}。"
      warn "（Hysteria2 服务端只能监听一个端口，端口跳跃必须依靠 DNAT 规则实现。）"
      HOP_RANGE="" HOP_EXT_RANGE="" HOP_BACKEND=""
    fi
  else
    HOP_BACKEND=""
  fi
  fi
  fi
  choose_extra_nat
}

# NAT 模式说明：为什么跳过调优 / 防火墙 / fail2ban / Swap
nat_skip_notice() {
  step "NAT 精简模式"
  info "已跳过：nftables 防火墙、fail2ban、Swap、$( ((OPT_UPGRADE)) || echo '系统升级、')RealiTLScanner。"
  case ${OPT_TUNE:-2} in
    1) echo "   网络调优：已用 --tune / --tune-preset 启用，只应用本机/容器内可写的参数（见下文）。" ;;
    0) echo "   网络调优：已用 --no-tune 跳过（之后可运行 proxy tune）。" ;;
    *) if (( OPT_AUTO )); then echo "   网络调优：--auto 下默认跳过（加 --tune 启用，或之后运行 proxy tune）。"
       else echo "   网络调优：稍后询问，只应用可写的参数（不强制 BBR）。"; fi ;;
  esac
  echo "   原因：NAT 小鸡多为 LXC / OpenVZ 容器（当前: ${VIRT:-未知}），很多内核参数与 Swap 由宿主机控制，修改通常无权限或无效；"
  echo "         入站只能经过服务商的端口映射，本机防火墙意义不大；fail2ban 常驻约 30~50MB 内存，对 64~256MB 的小鸡负担过重。"
  echo "   Xray 日志级别 warning 且关闭访问日志；Hysteria2 日志级别 warn。"
  local envs; envs=$(go_mem_env)
  envs=${envs//$'\n'/ }
  [[ -n $envs ]] && echo "   内存 $(mem_limit_mb)MB < 256MB：为 xray$( ((HY2_ENABLED)) && echo ' / hysteria') 设置 ${envs}（软限制，降低内存峰值）。"
  return 0
}

# IPv6-only / NAT64：GitHub 没有 IPv6，需要 DNS64 才能下载
nat_net_check() {
  (( NO_V4 )) || return 0
  warn "未检测到 IPv4 出口（IPv6-only 或 NAT64 环境），下载将优先使用 IPv6。"
  if curl -6 -fsSI --connect-timeout 6 -m 10 -o /dev/null https://github.com 2>/dev/null; then
    ok "可以通过 IPv6 访问 GitHub（DNS64/NAT64 可用）。"; return 0
  fi
  warn "无法通过 IPv6 访问 GitHub（GitHub 不支持 IPv6，需要 DNS64 + NAT64）。"
  echo "   可将 /etc/resolv.conf 改为公共 DNS64 服务器: ${DNS64_SERVERS}"
  if (( OPT_DNS64 )) || { (( ! OPT_AUTO )) && confirm "是否现在写入公共 DNS64 服务器（原文件备份到 ${RESOLV_BAK}，卸载时可恢复）？" y; }; then
    mkdir -p "$STATE_DIR"
    [[ -f $RESOLV_BAK ]] || cp -a /etc/resolv.conf "$RESOLV_BAK" 2>/dev/null || true
    local d; { echo "# 由 proxy-oneclick 写入（DNS64），原文件: ${RESOLV_BAK}"; for d in $DNS64_SERVERS; do echo "nameserver $d"; done; } >/etc/resolv.conf.proxytmp
    if cat /etc/resolv.conf.proxytmp >/etc/resolv.conf 2>/dev/null; then DNS64_SET=1; ok "已写入 DNS64 服务器。"; else warn "无法写入 /etc/resolv.conf（可能由宿主机管理）。"; fi
    rm -f /etc/resolv.conf.proxytmp
    if curl -6 -fsSI --connect-timeout 6 -m 10 -o /dev/null https://github.com 2>/dev/null; then ok "现在可以访问 GitHub。"
    else warn "仍无法访问 GitHub，后续下载可能失败。"; fi
  else
    warn "未配置 DNS64，后续从 GitHub 下载可能失败（可加 --dns64 重新运行）。"
  fi
}

# 确定运行模式：命令行 --nat / --no-nat 优先，否则沿用已安装的模式
resolve_mode() {
  [[ -n $OPT_NAT ]] && NAT_MODE=$OPT_NAT
  [[ $NAT_MODE == 1 ]] || NAT_MODE=0
  if [[ -z $OPT_UPGRADE ]]; then if (( NAT_MODE )); then OPT_UPGRADE=0; else OPT_UPGRADE=1; fi; fi
  if [[ -z $OPT_TUNE ]]; then
    if (( ! NAT_MODE )); then OPT_TUNE=1
    elif [[ -n $OPT_TUNE_PRESET$OPT_TUNE_CC$OPT_TUNE_QDISC$OPT_TUNE_BUF$OPT_TUNE_BW ]]; then OPT_TUNE=1
    else OPT_TUNE=2; fi
  fi
  return 0
}

do_install() {
  load_state
  # 纯 --land（以及已是落地机且没写 --no-land / --with-land）仍只装落地机。
  # --with-land，或 --land 再加某个节点协议的开启开关，走下面的节点安装并带上落地入站。
  if installing_land_only; then
    if cert_cli_requested; then
      die "落地机只运行 Shadowsocks 2022，不能申请证书，也不提供订阅。"
    fi
    if cdn_cli_requested; then
      cdn_explain land
      die "落地机不能打开 CDN 线路。"
    fi
    do_install_land
    return
  fi
  local was_land=$LAND_MODE want_in=0
  install_wants_land_in && want_in=1
  LAND_MODE=0
  preflight      # decide_nat_mode：命令行 / 菜单设置 / Alpine / 已安装 / 自动检测，端口设置前确定 NAT_MODE
  resolve_mode
  if (( NAT_MODE )) && cdn_cli_requested; then
    cdn_explain nat
    die "请去掉 --xhttp-tls / --ws-tls。不带这两个参数时，安装方式和现在相同。"
  fi
  if (( NAT_MODE )) && cert_cli_requested; then
    die "NAT 模式不能申请证书（含通配符、ZeroSSL 和 Cloudflare 源站证书）：公网访问不到这台机器，CDN 也无法回源。请去掉证书参数。不带这些参数时，安装方式与现在相同。"
  fi
  take_lock
  if (( was_land )); then
    info "由落地机改装为 Reality / XHTTP / Hysteria2 节点：移除落地机白名单规则，停止 Shadowsocks，重新生成节点配置。"
    land_fw_remove
    if (( want_in )); then
      info "保留落地密钥、白名单和原样转发。原来启用中的加密下一跳改记到落地入站自己的出口（land-next），不再当作节点的 land-add。"
      if [[ ${RELAY_ON:-0} == 1 && -n ${RELAY_LINK:-} ]]; then
        LAND_NEXT=$RELAY_LINK
        LAND_NEXT_ON=1
      fi
      RELAY_ON=0 RELAY_LINK="" RELAY_SOCKS=""
      if [[ -z ${OPT_LAND_PORT:-} ]]; then
        LAND_PORT=$XRAY_PORT
        if (( NAT_MODE )) && [[ -n ${XRAY_EXT_PORT:-} ]]; then LAND_EXT_PORT=$XRAY_EXT_PORT; fi
      fi
      LAND_IN=1
    else
      land_fwd_remove
      FWD_ON=0 FWD_LINK=""
      RELAY_ON=0 RELAY_LINK="" RELAY_SOCKS=""
      LAND_IN=0 LAND_NEXT="" LAND_NEXT_ON=0 LAND_PORT="" LAND_EXT_PORT=""
    fi
    if is_openrc; then rc-service xray stop >/dev/null 2>&1 9>&- || true   # 避免旧的 SS 端口被当作「其它已监听端口」放行
    else systemctl stop xray >/dev/null 2>&1 || true; fi
    HY2_ENABLED=1
    REALITY_ENABLED=1
    [[ -n $OPT_XHTTP ]] || XHTTP_ENABLED=1
    if (( ! NAT_MODE )); then XRAY_PORT=443 HY2_PORT=443 HOP_RANGE="20000-50000"; fi
  else
    LAND_IN=$want_in
  fi
  resolve_install_protos
  if (( INSTALLED )) && (( ! OPT_AUTO )); then
    warn "检测到已安装。重新安装将保留现有密钥/UUID/密码，仅更新组件与配置。"
    confirm "继续重新安装？" y || return 0
  fi

  pkg_update_upgrade
  install_deps
  detect_virt
  ensure_time_sync
  mktmp
  step "获取服务器信息"
  detect_ip; detect_geo; show_sysinfo
  if (( NAT_MODE )); then
    nat_net_check
    nat_skip_notice
    nat_tune
  else
    SERVER_ADDR=${PUBLIC_IP4:-$PUBLIC_IP6}
    ensure_swap
    if (( OPT_TUNE == 1 )); then apply_tuning; fi
  fi

  step "端口设置"
  if (( NAT_MODE )); then
    choose_nat_addr
    choose_nat_ports
  else
    choose_ports
    NAT_PORTS="" NAT_EXCLUDE="" XRAY_EXT_PORT="" HY2_EXT_PORT="" HOP_EXT_RANGE="" HOP_BACKEND=""
    XHTTP_EXT_PORT="" TROJAN_EXT_PORT="" TUIC_EXT_PORT="" ANYTLS_EXT_PORT=""
    remove_nat_hop
  fi
  [[ -n $OPT_NAME ]] && NODE_NAME=$OPT_NAME
  [[ -n $NODE_NAME ]] || NODE_NAME=$(default_node_name)
  fw_decide_install
  if land_in_on; then
    step "落地入站"
    land_choose_method
    land_choose_allow
  fi

  install_xray
  if [[ -z $UUID || -z $PRIV_KEY || -z $PUB_KEY || -z $SHORT_ID ]]; then
    info "生成 UUID / x25519 密钥 / ShortId / ML-DSA-65 密钥 ..."
    gen_xray_keys
  elif [[ -z $MLDSA_SEED ]]; then
    local out
    if out=$("$XRAY_BIN" mldsa65 2>/dev/null); then
      MLDSA_SEED=$(awk -F': *' '$1=="Seed"{print $NF; exit}' <<<"$out")
      MLDSA_VERIFY=$(awk -F': *' '$1=="Verify"{print $NF; exit}' <<<"$out")
    fi
  fi
  save_state

  if (( IMPORT_MODE && OPT_AUTO )) && [[ -n $SNI && -z $OPT_SNI ]]; then
    local sni_res=""
    sni_res=$(sni_probe "$SNI") || true
    if [[ $sni_res == FAIL* ]]; then
      warn "导入的 SNI ${SNI} 现在不可用（${sni_res##*|}）。将重新优选。"
      SNI=""
    else
      info "导入的 SNI ${SNI} 仍然可用。"
    fi
  fi
  if (( ! OPT_AUTO )) || [[ -z $SNI || -n $OPT_SNI ]]; then
    select_sni
  fi
  SNI_TARGET="${SNI}:443"
  mldsa_decide
  save_state

  ensure_proto_secrets
  save_state
  if land_in_on && [[ ${FWD_ON:-0} == 1 && -n ${FWD_LINK:-} ]]; then
    land_raw_active || die "原样转发链接无法解析，拒绝按直连安装。"
    land_fwd_check
  fi
  if xray_inbound_needed; then
    local rc=0
    write_xray_config || rc=$?
    if (( rc == 2 )); then svc_disable_stop xray
    elif (( rc != 0 )); then exit "$rc"
    else restart_xray; fi
  else
    info "未启用 Xray 入站，停止 Xray（UUID / 密钥保留）。"
    svc_disable_stop xray
  fi

  if (( HY2_ENABLED )); then install_hysteria
  elif [[ -x $HY_BIN || -f $HY_UNIT || -f $HY_RC ]]; then
    info "已关闭 Hysteria2，移除相关组件 ..."
    remove_hysteria
  fi
  if sb_needed; then install_singbox
  elif [[ -x $SB_BIN || -f $SB_UNIT || -f $SB_RC ]]; then
    info "已关闭 TUIC / AnyTLS，停止 sing-box（密码保留）。"
    svc_disable_stop sing-box
  fi
  setup_cert
  if (( HY2_ENABLED )); then
    write_hy2_config
    save_state
    restart_hy2
  fi
  if sb_needed; then
    write_singbox_config
    save_state
    restart_singbox
  fi

  apply_firewall
  land_sync_fwd_rules
  if tls_present_real; then cert_start_sub; fi
  cdn_after_cert
  (( NAT_MODE )) || setup_fail2ban
  INSTALLED=1
  save_state
  self_install
  ( trap - ERR; set +e; reality_selftest; xhttp_selftest; if land_in_on && ! land_raw_active; then land_selftest; fi ) || true
  show_info
  cloud_fw_reminder
  echo
  echo
  ui_bar '═' 62
  ui_center "安装完成" 62
  printf '%s管理菜单：proxy%s\n' "$C_OK" "$C_NONE"
  ui_bar '═' 62
}

