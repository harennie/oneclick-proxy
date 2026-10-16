# ============================================================
# 回程线路检测（proxy route）
# 只读：不改代理配置，不重启服务，不测流媒体。
# 只测本机发向大陆的回程：电信 / 联通 / 移动 × 北京 / 上海 / 广州。
# 节点用 nexttrace 快速测试同一套终点（nxtrace endpoint），
# 默认 TCP SYN（--tcp -q 1）；这一次没有回应再试 ICMP。
# 线路名称按路径里的 ASN 和骨干地址判断，规则对齐
# lemtr / zq BestTrace / 本脚本原来的回国分类，不打国际线路。
# ============================================================

OPT_ROUTE_FAM=""
OPT_ROUTE_PROTO=""
OPT_ROUTE_VERBOSE=0
ROUTE_NT_HELP=""
ROUTE_ARG_STYLE="full"
ROUTE_WALL=22
ROUTE_ARGS=()
ROUTE_ASNS=()
ROUTE_HOPS=()
ROUTE_ROWS=()
ROUTE_LAST_RTT=""
ROUTE_RESP=0
ROUTE_TRACE_OUT=""
ROUTE_SEEN_5943=0
ROUTE_SEEN_20297=0
ROUTE_SEEN_218105=0
ROUTE_SEEN_219158=0
ROUTE_SEEN_CMI=0
ROUTE_PATH_SEEN=0
ROUTE_TARGET_IP=""
ROUTE_ICMP_FALLBACK=0
ROUTE_LABEL=""
ROUTE_LAT=""

route_carrier_zh() {
  case $1 in
    telecom) printf '电信' ;;
    unicom) printf '联通' ;;
    mobile) printf '移动' ;;
    *) printf '%s' "$1" ;;
  esac
}

# 与 nexttrace --fast-trace、besttrace -i nt 相同的三网北上广终点。教育网、科技网不测，避免表格拉长。
route_nodes() { # 地址族 →「运营商 城市 主机」
  local p=ipv4
  [[ $1 == 6 ]] && p=ipv6
  printf '%s\n' \
    "telecom 北京 ${p}.pek-4134.endpoint.nxtrace.org" \
    "telecom 上海 ${p}.sha-4134.endpoint.nxtrace.org" \
    "telecom 广州 ${p}.can-4134.endpoint.nxtrace.org" \
    "unicom 北京 ${p}.pek-4837.endpoint.nxtrace.org" \
    "unicom 上海 ${p}.sha-4837.endpoint.nxtrace.org" \
    "unicom 广州 ${p}.can-4837.endpoint.nxtrace.org" \
    "mobile 北京 ${p}.pek-9808.endpoint.nxtrace.org" \
    "mobile 上海 ${p}.sha-9808.endpoint.nxtrace.org" \
    "mobile 广州 ${p}.can-9808.endpoint.nxtrace.org"
}

route_timeout() { # 秒 命令… 到点送 TERM，返回 124
  local secs=$1
  shift
  if have timeout; then
    timeout --signal=TERM "$secs" "$@" || return $?
    return 0
  fi
  "$@" &
  local pid=$! waited=0
  while (( waited < secs )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || return $?
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 124
}

route_install_binary() {
  local arch url dest=/usr/local/bin/nexttrace
  case $(uname -m) in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l|armv7) arch=armv7 ;;
    *) return 1 ;;
  esac
  url="https://github.com/nxtrace/NTrace-core/releases/latest/download/nexttrace_linux_${arch}"
  info "官方安装脚本没装上，改下 GitHub 发布包。"
  curl -fsSL --connect-timeout 15 --max-time 90 -o "$dest" "$url" || { rm -f "$dest"; return 1; }
  local magic
  magic=$(od -An -t x1 -N 4 "$dest" 2>/dev/null || true)
  [[ $magic == *7f*45*4c*46* ]] || { rm -f "$dest"; return 1; }
  chmod +x "$dest" || { rm -f "$dest"; return 1; }
  hash -r
  have nexttrace || return 1
  return 0
}

route_install_nexttrace() {
  have nexttrace && return 0
  have curl || die "没有 curl，装不了 nexttrace。"
  info "没有 nexttrace，正在安装。"
  local installer='set -o pipefail; curl -fsSL --connect-timeout 15 --max-time 60 https://nxtrace.org/nt | bash'
  if have timeout; then
    timeout 90 bash -c "$installer" >/dev/null 2>&1 || true
  else
    bash -c "$installer" >/dev/null 2>&1 || true
  fi
  hash -r
  if ! have nexttrace; then
    route_install_binary || die "nexttrace 安装失败。"
  fi
  hash -r
  route_timeout 8 nexttrace -V >/dev/null 2>&1 || route_timeout 8 nexttrace --version >/dev/null 2>&1 \
    || die "nexttrace 装上了，但是跑不起来。"
  return 0
}

route_nt_prepare() {
  ROUTE_NT_HELP=$(route_timeout 10 nexttrace --help 2>&1 || true)
  if [[ $ROUTE_NT_HELP == *"--parallel-requests"* ]]; then ROUTE_WALL=22
  else ROUTE_WALL=32; fi
}

route_nt_args() { # 地址族 tcp|icmp
  local fam=$1 proto=$2
  ROUTE_ARGS=()
  if [[ $ROUTE_ARG_STYLE == simple ]]; then
    ROUTE_ARGS=(-q 1 -m 16 -n)
    if [[ $fam == 6 ]]; then ROUTE_ARGS+=(-6); else ROUTE_ARGS+=(-4); fi
    [[ $proto == tcp ]] && ROUTE_ARGS+=(-T)
    return 0
  fi
  local h=$ROUTE_NT_HELP
  [[ $h == *"--traceroute"* ]] && ROUTE_ARGS+=(--traceroute)
  [[ $h == *"--raw"* ]] && ROUTE_ARGS+=(--raw)
  if [[ $proto == tcp ]]; then
    if [[ $h == *"--tcp"* ]]; then ROUTE_ARGS+=(--tcp); else ROUTE_ARGS+=(-T); fi
    [[ $h == *"--port"* ]] && ROUTE_ARGS+=(--port 80)
  fi
  if [[ $fam == 6 ]]; then
    if [[ $h == *"--ipv6"* ]]; then ROUTE_ARGS+=(--ipv6); else ROUTE_ARGS+=(-6); fi
  else
    if [[ $h == *"--ipv4"* ]]; then ROUTE_ARGS+=(--ipv4); else ROUTE_ARGS+=(-4); fi
  fi
  if [[ $h == *"--queries"* ]]; then ROUTE_ARGS+=(--queries 1); else ROUTE_ARGS+=(-q 1); fi
  if [[ $h == *"--max-hops"* ]]; then ROUTE_ARGS+=(--max-hops 16); else ROUTE_ARGS+=(-m 16); fi
  [[ $h == *"--timeout"* ]] && ROUTE_ARGS+=(--timeout 1200)
  [[ $h == *"--max-attempts"* ]] && ROUTE_ARGS+=(--max-attempts 1)
  [[ $h == *"--parallel-requests"* ]] && ROUTE_ARGS+=(--parallel-requests 8)
  [[ $h == *"--no-rdns"* ]] && ROUTE_ARGS+=(--no-rdns)
  [[ $h == *"--no-color"* ]] && ROUTE_ARGS+=(--no-color)
  [[ $h == *"Disable Print Trace Map"* ]] && ROUTE_ARGS+=(-M)
  return 0
}

route_bad_args() { # 退出码 输出
  (( $1 == 2 )) && return 0
  [[ $2 == *unknown\ flag* || $2 == *flag\ provided* || $2 == *Usage:* || $2 == *unknown\ command* ]] && return 0
  return 1
}

route_reset_obs() {
  ROUTE_ASNS=()
  ROUTE_HOPS=()
  ROUTE_LAST_RTT=""
  ROUTE_RESP=0
  ROUTE_SEEN_5943=0
  ROUTE_SEEN_20297=0
  ROUTE_SEEN_218105=0
  ROUTE_SEEN_219158=0
  ROUTE_SEEN_CMI=0
  ROUTE_PATH_SEEN=0
  ROUTE_TARGET_IP=""
}

route_ip_private() {
  local ip=$1
  [[ $ip == 10.* || $ip == 192.168.* || $ip == 127.* || $ip == 169.254.* ]] && return 0
  [[ $ip == 172.1[6-9].* || $ip == 172.2[0-9].* || $ip == 172.3[0-1].* ]] && return 0
  [[ $ip == fe80:* || $ip == ::1 ]] && return 0
  return 1
}

route_note_ip() {
  local ip=$1
  [[ $ip == 59.43.* ]] && ROUTE_SEEN_5943=1
  [[ $ip == 202.97.* ]] && ROUTE_SEEN_20297=1
  [[ $ip == 218.105.* ]] && ROUTE_SEEN_218105=1
  [[ $ip == 219.158.* ]] && ROUTE_SEEN_219158=1
  [[ $ip == 223.120.* || $ip == 223.118.* || $ip == 223.119.* ]] && ROUTE_SEEN_CMI=1
  return 0
}

route_is_ip() {
  local ip=$1
  [[ $ip =~ ^[0-9]{1,3}([.][0-9]{1,3}){3}$ ]] && return 0
  [[ $ip =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f:]+$ ]] && return 0
  return 1
}

route_record_hop() { # ttl ip asn rtt
  local ttl=$1 ip=$2 asn=$3 rtt=$4
  route_is_ip "$ip" || return 0
  [[ $asn =~ ^[0-9]+$ ]] || asn=""
  [[ $asn == 0 ]] && asn=""
  ROUTE_RESP=1
  # 终点自己的地址、内网地址不算回程骨干，避免把测试目标的 ASN 当成线路。
  if [[ $ip != "${ROUTE_TARGET_IP:-}" ]] && ! route_ip_private "$ip"; then
    ROUTE_PATH_SEEN=1
    route_note_ip "$ip"
    [[ -n $asn ]] && ROUTE_ASNS+=("$asn")
  fi
  ROUTE_HOPS+=("${ttl} ${ip} ${asn:-?} ${rtt:-*}")
  if [[ $rtt =~ ^[0-9]+([.][0-9]+)?$ && $ttl =~ ^[0-9]+$ ]]; then
    if [[ -z ${ROUTE_HOPS_TTL:-} || $ttl -ge ${ROUTE_HOPS_TTL:-0} ]]; then
      ROUTE_HOPS_TTL=$ttl
      ROUTE_LAST_RTT=$rtt
    fi
  fi
  return 0
}

route_parse_trace() {
  local raw=$1 line ttl ip rtt asn
  local -a fields=()
  route_reset_obs
  ROUTE_HOPS_TTL=""
  raw=$(printf '%s\n' "$raw" | sed $'s/\x1b\\[[0-9;]*[[:alpha:]]//g') || true
  if [[ $raw =~ -\>[[:space:]]*([0-9]{1,3}([.][0-9]{1,3}){3}) ]]; then
    ROUTE_TARGET_IP=${BASH_REMATCH[1]}
  elif [[ $raw =~ -\>[[:space:]]*([0-9A-Fa-f:]+:[0-9A-Fa-f:]+) ]]; then
    ROUTE_TARGET_IP=${BASH_REMATCH[1]}
  fi
  while IFS= read -r line; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    [[ -z $line ]] && continue
    if [[ $line =~ ^[0-9]+[|] ]]; then
      IFS='|' read -r -a fields <<<"$line"
      ttl=${fields[0]:-}
      ip=${fields[1]:-}
      rtt=${fields[3]:-}
      asn=${fields[4]:-}
      rtt=${rtt%ms}; rtt=${rtt%MS}
      [[ $ip == '*' || -z $ip ]] && continue
      asn=${asn#AS}; asn=${asn#as}; asn=${asn#As}
      route_record_hop "$ttl" "$ip" "$asn" "$rtt"
      continue
    fi
    [[ $line =~ ^[0-9]+[[:space:]] ]] || continue
    ttl=""; ip=""; asn=""; rtt=""
    [[ $line =~ ^([0-9]+) ]] && ttl=${BASH_REMATCH[1]}
    if [[ $line =~ ([0-9]{1,3}([.][0-9]{1,3}){3}) ]]; then ip=${BASH_REMATCH[1]}
    elif [[ $line =~ ([0-9A-Fa-f:]*:[0-9A-Fa-f:]+) ]]; then ip=${BASH_REMATCH[1]}; fi
    if [[ $line =~ [Aa][Ss]([0-9]+) ]]; then asn=${BASH_REMATCH[1]}; fi
    if [[ $line =~ ([0-9]+([.][0-9]+)?)[[:space:]]*ms ]]; then rtt=${BASH_REMATCH[1]}; fi
    [[ -n $ip ]] || continue
    route_record_hop "$ttl" "$ip" "$asn" "$rtt"
  done <<<"$raw"
  return 0
}

route_has_asn() {
  local n=$1 x
  for x in "${ROUTE_ASNS[@]}"; do [[ $x == "$n" ]] && return 0; done
  return 1
}
route_asn_before() { # A 出现在某个 B 之前
  local a=$1 b=$2 seen=0 x
  for x in "${ROUTE_ASNS[@]}"; do
    [[ $x == "$a" ]] && seen=1
    [[ $x == "$b" && $seen == 1 ]] && return 0
  done
  return 1
}
route_asn_any() {
  local x n
  for x in "${ROUTE_ASNS[@]}"; do
    for n in "$@"; do [[ $x == "$n" ]] && return 0; done
  done
  return 1
}

route_classify() { # 运营商。只看这一家的回程特征
  local carrier=$1
  case $carrier in
    telecom)
      # 59.43 且没有 202.97 记 CN2 GIA。终点自己的 163 地址不参与，避免每条都变成 GT。
      if (( ROUTE_SEEN_5943 && ROUTE_SEEN_20297 )); then printf 'CN2 GT'; return 0; fi
      if (( ROUTE_SEEN_5943 )); then printf 'CN2 GIA'; return 0; fi
      if route_has_asn 4809 && { route_has_asn 4134 || (( ROUTE_SEEN_20297 )); }; then printf 'CN2 GT'; return 0; fi
      if route_asn_before 23764 4809; then printf 'CTG→CN2'; return 0; fi
      if route_has_asn 4809; then printf 'CN2'; return 0; fi
      if route_asn_before 23764 4134 || { route_has_asn 23764 && route_has_asn 4134; }; then printf 'CTG→163'; return 0; fi
      if route_has_asn 4134 || (( ROUTE_SEEN_20297 )); then printf '163'; return 0; fi
      if route_asn_any 4811 4812 4813 4816 4847 58466; then printf '163'; return 0; fi
      ;;
    unicom)
      if route_has_asn 9929 || (( ROUTE_SEEN_218105 )); then printf '9929'; return 0; fi
      if route_has_asn 10099; then printf 'CUG'; return 0; fi
      if route_has_asn 4837 || (( ROUTE_SEEN_219158 )); then printf '4837'; return 0; fi
      if route_asn_any 4808 17816 17621 17622 17623; then printf '4837'; return 0; fi
      ;;
    mobile)
      if route_has_asn 58807; then printf 'CMIN2'; return 0; fi
      if route_has_asn 58453 || (( ROUTE_SEEN_CMI )); then printf 'CMI'; return 0; fi
      if route_asn_any 9808 56040 56041 56042 56044 56046 56047 56048; then printf 'CMNET'; return 0; fi
      ;;
  esac
  if (( ! ROUTE_RESP )); then printf '未能识别'; return 0; fi
  if (( ! ROUTE_PATH_SEEN )); then printf '未看到路径'; return 0; fi
  printf '未能识别'
  return 0
}

route_rtt_text() {
  local r=$ROUTE_LAST_RTT
  if [[ $r =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    awk -v t="$r" 'BEGIN{ if (t > 0 && t < 1) printf "<1 ms"; else printf "%d ms", t + 0.5 }'
  else
    printf '%s' '—'
  fi
}

route_reason() { # 退出码 输出
  local rc=$1 text=$2 low
  if (( rc == 124 )); then printf '超时'; return 0; fi
  low=${text,,}
  if [[ $low == *no\ such\ host* || $low == *name\ or\ service\ not\ known* || $low == *temporary\ failure\ in\ name\ resolution* \
        || $low == *could\ not\ resolve* || $low == *server\ misbehaving* || $text == *无法解析* \
        || ( $low == *lookup* && $low == *timeout* ) ]]; then
    printf '解析失败'
    return 0
  fi
  if [[ $low == *operation\ not\ permitted* || $low == *permission\ denied* ]]; then
    printf '权限不足'
    return 0
  fi
  printf '无响应'
  return 0
}

route_trace_run() { # 地址族 协议 主机。解析结果留在全局变量里，返回码是 nexttrace 的
  local fam=$1 proto=$2 host=$3 rc=0 out=""
  route_nt_args "$fam" "$proto"
  out=$(route_timeout "$ROUTE_WALL" nexttrace "${ROUTE_ARGS[@]}" "$host" 2>&1) || rc=$?
  if [[ $ROUTE_ARG_STYLE == full ]] && route_bad_args "$rc" "$out"; then
    ROUTE_ARG_STYLE=simple
    route_nt_args "$fam" "$proto"
    rc=0
    out=$(route_timeout "$ROUTE_WALL" nexttrace "${ROUTE_ARGS[@]}" "$host" 2>&1) || rc=$?
  fi
  ROUTE_TRACE_OUT=$out
  route_parse_trace "$out"
  return "$rc"
}

route_probe_node() { # 地址族 运营商 城市 主机。写入 ROUTE_LABEL / ROUTE_LAT
  local fam=$1 carrier=$2 city=$3 host=$4 proto=tcp rc=0 why
  [[ ${OPT_ROUTE_PROTO:-} == icmp ]] && proto=icmp
  route_trace_run "$fam" "$proto" "$host" || rc=$?
  if (( ROUTE_RESP )); then
    ROUTE_LABEL=$(route_classify "$carrier")
    ROUTE_LAT=$(route_rtt_text)
    return 0
  fi
  why=$(route_reason "$rc" "$ROUTE_TRACE_OUT")
  if [[ $proto == tcp && ${OPT_ROUTE_PROTO:-} != icmp && $rc -ne 124 && $why != 权限不足 ]]; then
    ROUTE_ICMP_FALLBACK=1
    rc=0
    route_trace_run "$fam" icmp "$host" || rc=$?
    if (( ROUTE_RESP )); then
      ROUTE_LABEL=$(route_classify "$carrier")
      ROUTE_LAT=$(route_rtt_text)
      return 0
    fi
    why=$(route_reason "$rc" "$ROUTE_TRACE_OUT")
  fi
  ROUTE_LABEL=$why
  ROUTE_LAT='—'
  ROUTE_HOPS=()
  return 0
}

route_label_cell() {
  local s=$1 color=$C_NONE
  case $s in
    "CN2 GIA"|9929|CMIN2) color=$C_OK ;;
    "CN2 GT"|CUG|CMI|"CTG→CN2") color=$C_TITLE ;;
    163|4837|CMNET|"CTG→163"|CN2) color=$C_WARN ;;
    超时|无响应|解析失败|权限不足|未看到路径|未能识别) color=$C_WARN ;;
  esac
  printf '%s%s%s' "$color" "$(ui_pad "$s" 12)" "$C_NONE"
}

route_print_hops() {
  local rec ttl ip asn rtt
  (( ${#ROUTE_HOPS[@]} )) || return 0
  for rec in "${ROUTE_HOPS[@]}"; do
    read -r ttl ip asn rtt <<<"$rec"
    if [[ $asn == '?' || -z $asn ]]; then asn='—'
    else asn="AS${asn}"; fi
    if [[ $rtt =~ ^[0-9] ]]; then rtt="${rtt} ms"; else rtt='*'; fi
    printf '%s    %2s  %-22s %-10s %s%s\n' "$C_DIM" "$ttl" "$ip" "$asn" "$rtt" "$C_NONE"
  done
  return 0
}

route_summary_one() {
  local carrier=$1 row c city label _lat
  local -a labs=()
  local -A where=()
  for row in "${ROUTE_ROWS[@]}"; do
    IFS='|' read -r c city label _lat <<<"$row"
    [[ $c == "$carrier" ]] || continue
    if [[ -z ${where[$label]+x} ]]; then
      labs+=("$label")
      where[$label]=$city
    else
      where[$label]+="、$city"
    fi
  done
  local zh text="" lab first=1
  zh=$(route_carrier_zh "$carrier")
  if (( ${#labs[@]} == 0 )); then
    printf '%s  %s\n' "$(ui_pad "$zh" 6)" "未测"
    return 0
  fi
  if (( ${#labs[@]} == 1 )); then
    lab=${labs[0]}
    case $lab in
      超时|无响应|解析失败|权限不足|未能识别|未看到路径) text="${lab}（${where[$lab]}）" ;;
      *) text=$lab ;;
    esac
  else
    for lab in "${labs[@]}"; do
      if (( first )); then first=0; else text+="、"; fi
      text+="${lab}（${where[$lab]}）"
    done
  fi
  printf '%s  %s\n' "$(ui_pad "$zh" 6)" "$text"
  return 0
}

route_progress() {
  local zh=$1 city=$2
  if [[ -t 2 ]]; then
    printf '\r%s正在探测 %s %s …%s' "$C_DIM" "$zh" "$city" "$C_NONE" >&2
  else
    printf '%s正在探测 %s %s …%s\n' "$C_DIM" "$zh" "$city" "$C_NONE" >&2
  fi
}

route_report_family() { # 地址族
  local fam=$1 carrier city host mode=TCP
  [[ ${OPT_ROUTE_PROTO:-} == icmp ]] && mode=ICMP
  echo
  printf '%sIPv%s · %s%s\n' "$C_BOLD" "$fam" "$mode" "$C_NONE"
  printf '%s  %s  %s  %s\n' "$(ui_pad "运营商" 6)" "$(ui_pad "城市" 6)" "$(ui_pad "线路" 12)" "延迟"
  ROUTE_ROWS=()
  ROUTE_ICMP_FALLBACK=0
  while IFS=' ' read -r carrier city host; do
    [[ -n $host ]] || continue
    route_progress "$(route_carrier_zh "$carrier")" "$city"
    route_probe_node "$fam" "$carrier" "$city" "$host"
    [[ -t 2 ]] && printf '\r\033[K' >&2
    printf '%s  %s  %s  %s\n' \
      "$(ui_pad "$(route_carrier_zh "$carrier")" 6)" \
      "$(ui_pad "$city" 6)" \
      "$(route_label_cell "$ROUTE_LABEL")" \
      "$ROUTE_LAT"
    if (( OPT_ROUTE_VERBOSE )); then route_print_hops; fi
    ROUTE_ROWS+=("${carrier}|${city}|${ROUTE_LABEL}|${ROUTE_LAT}")
  done < <(route_nodes "$fam")
  echo
  printf '%s汇总%s\n' "$C_BOLD" "$C_NONE"
  local c
  for c in telecom unicom mobile; do route_summary_one "$c"; done
  if (( ROUTE_ICMP_FALLBACK )); then
    printf '%s有节点的 TCP 没有回应，这一次改用了 ICMP。%s\n' "$C_DIM" "$C_NONE"
  fi
  printf '%s线路按路径里的 ASN 和骨干地址判断，只供参考，和业务流量不一定是同一条。%s\n' "$C_DIM" "$C_NONE"
  return 0
}

do_route() {
  [[ -f $STATE_FILE ]] && load_state
  step "回程线路检测"
  printf '只测从本机发向大陆的回程（北京 / 上海 / 广州，电信 / 联通 / 移动）。\n'
  printf '不改配置，不重启，不测国际线路，也不测从家里到本机的去程。\n'
  route_install_nexttrace
  route_nt_prepare
  local -a fams=()
  case ${OPT_ROUTE_FAM:-} in
    4) fams=(4) ;;
    6) fams=(6) ;;
    all|both) fams=(4 6) ;;
    *)
      if ip -4 route get 1.1.1.1 >/dev/null 2>&1; then fams=(4)
      elif ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then fams=(6)
      else die "没有 IPv4 或 IPv6 出口，测不了回程。"; fi
      ;;
  esac
  local f
  for f in "${fams[@]}"; do route_report_family "$f"; done
  if [[ -z ${OPT_ROUTE_FAM:-} ]]; then
    printf '%sIPv6：proxy route ipv6。每一跳：proxy route verbose。只走 ICMP：proxy route icmp。%s\n' "$C_DIM" "$C_NONE"
  fi
  return 0
}
