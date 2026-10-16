# ============================================================
#              网络调优（v1.2.0 起为独立功能：proxy tune）
# ============================================================
# 设计要点：
#  · 先探测：虚拟化 / init / 内核 / 可用拥塞控制与队列算法 / 内存 / 每个参数是否真的可写
#    （把当前值原样写回去测试，不靠猜；容器里很多参数只读或按网络命名空间隔离）
#  · 预设只决定 拥塞控制 + 队列算法；缓冲区按内存自动分档（可覆盖，或按带宽×延迟计算 BDP）
#  · 先预览（当前值 → 目标值），确认后只写可写的参数，跳过的逐条说明原因
#  · 只维护一个文件 ${SYSCTL_FILE}；首次应用前备份原值，restore 可完整还原
# 管理的参数（顺序与 v1.1.x 写入的文件一致，保证普通模式默认结果不变）
TUNE_KEYS=(net.core.default_qdisc net.ipv4.tcp_congestion_control
  net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default
  net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min
  net.core.netdev_max_backlog net.core.somaxconn net.ipv4.tcp_max_syn_backlog
  net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_notsent_lowat
  net.ipv4.tcp_fin_timeout net.ipv4.tcp_keepalive_time fs.file-max fs.nr_open vm.swappiness)
# 全局（不按网络命名空间隔离）的参数：容器里即使可写，修改的也是宿主机，默认跳过
TUNE_GLOBAL_KEYS=" net.core.default_qdisc net.core.netdev_max_backlog fs.file-max fs.nr_open vm.swappiness "
TUNE_PRESETS=(bbr-fq bbr-fq_codel bbr-cake cubic-fq_codel keep custom)
TUNE_QDISC_CAND=(fq fq_codel cake fq_pie sfq pfifo_fast)
declare -A TUNE_NOW=() TUNE_ST=() TUNE_WANT=() TUNE_RES=()
TUNE_DETECTED=0 TUNE_IFACE="" TUNE_MEM=0 TUNE_CC_AVAIL="" TUNE_QD_AVAIL="" TUNE_BBR_VER=""
TUNE_PRESET="" TUNE_CC="" TUNE_QD="" TUNE_BUF="" TUNE_BUF_EFF="" TUNE_BDP_NOTE=""
TUNE_NOCONFIRM=0 TUNE_COMPACT=0

tcol() { # 按显示宽度补齐（中文等宽字符算 2 列）：tcol 文本 宽度
  local s=$1 a; a=${s//[ -~]/}
  local pad=$(( $2 - ${#s} - ${#a} )); (( pad > 0 )) || pad=0
  printf '%s%*s' "$s" "$pad" ''
}
trow() { # trow 文本1 文本2 文本3 状态   （34/22/22 列）
  printf '  %s %s %s %s\n' "$(tcol "$1" 34)" "$(tcol "$2" 22)" "$(tcol "$3" 22)" "$4"
}
tune_path() { printf '/proc/sys/%s' "${1//.//}"; }
tune_get() { # 读取当前值（多个数字统一用单个空格分隔）
  local f v=""; f=$(tune_path "$1")
  [[ -r $f ]] || return 1
  read -r v 2>/dev/null <"$f" || [[ -n $v ]] || return 1
  v=${v//$'\t'/ }
  while [[ $v == *'  '* ]]; do v=${v//'  '/ }; done
  printf '%s' "$v"
}
tune_write() { local f; f=$(tune_path "$1"); { printf '%s\n' "$2" >"$f"; } 2>/dev/null; }
tune_probe() { # 把当前值原样写回，判断是否可写：ok / ro / absent
  local k=$1 f v
  f=$(tune_path "$k")
  if [[ ! -e $f ]]; then TUNE_ST[$k]=absent; TUNE_NOW[$k]="-"; return 0; fi
  v=$(tune_get "$k") || v=""
  TUNE_NOW[$k]=${v:--}
  if [[ -n $v ]] && tune_write "$k" "$v"; then TUNE_ST[$k]=ok; else TUNE_ST[$k]=ro; fi
  # 特权容器里全局参数可能可写，但改的是宿主机（影响所有容器），不碰
  if [[ ${TUNE_ST[$k]} == ok && $TUNE_GLOBAL_KEYS == *" $k "* ]] && is_container; then TUNE_ST[$k]=host; fi
  return 0
}
tune_skip_reason() { # $1 key
  case ${TUNE_ST[$1]-} in
    absent) if is_container; then echo "跳过：容器内不可见（宿主机控制）"; else echo "跳过：内核无此参数"; fi ;;
    ro) if is_container; then echo "跳过：容器内只读（宿主机控制）"; else echo "跳过：只读（无权限）"; fi ;;
    host) echo "跳过：全局参数，容器内修改会影响宿主机" ;;
    *) echo "跳过" ;;
  esac
}
tune_iface() {
  local d
  d=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}') || d=""
  [[ -n $d ]] || d=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}') || d=""
  printf '%s' "$d"
}
tune_root_qdisc() { # $1 网卡 → 根队列类型；多队列网卡输出 mq(子队列类型)
  local out root child
  if ! have tc || [[ -z $1 ]]; then printf '%s' "-"; return 0; fi
  out=$(tc qdisc show dev "$1" 2>/dev/null) || out=""
  root=$(awk '/ root /{print $2; exit}' <<<"$out") || root=""
  if [[ $root == mq || $root == mqprio ]]; then
    child=$(awk -v r="$root" '$2 != r && / parent / && !s[$2]++ {printf "%s%s", (n++ ? "," : ""), $2}' <<<"$out") || child=""
    printf '%s(%s)' "$root" "${child:-?}"
  else
    printf '%s' "${root:--}"
  fi
}
tune_qdisc_label() { # $1 网卡 → 实际生效的队列：优先读 tc；容器内 default_qdisc 常不可见，不再显示「-」
  local ifc=${1:-} d="" q=""
  d=$(tune_get net.core.default_qdisc 2>/dev/null) || d=""
  if [[ -n $ifc ]] && have tc; then q=$(tune_root_qdisc "$ifc"); [[ $q == - ]] && q=""; fi
  if [[ -z $q && ${TUNE_RES[qdisc]-} == ok && ${TUNE_QD:-keep} != keep && -n $ifc ]]; then q=$TUNE_QD; fi
  if [[ -n $q ]]; then
    printf '%s（网卡 %s%s）' "$q" "$ifc" "$([[ -n $d && $d != "$q" && $q != "mq($d)" ]] && printf '；default_qdisc %s' "$d")"
  elif [[ -n $d ]]; then printf '%s（default_qdisc）' "$d"
  else printf '未知'; fi
}
tune_iface_uses() { # $1 网卡 $2 队列算法：根队列（或 mq 的全部子队列）已是该算法
  local r; r=$(tune_root_qdisc "$1")
  [[ $r == "$2" || $r == "mq($2)" || $r == "mqprio($2)" ]]
}
tune_qdisc_ok() { # 队列算法是否可用（已加载 / 内置 / 可加载 / 实测）
  local q=$1 mdir
  [[ $q == pfifo_fast ]] && return 0
  [[ -d /sys/module/sch_$q ]] && return 0
  mdir="/lib/modules/$(uname -r)"
  [[ -r $mdir/modules.builtin ]] && grep -q "/sch_${q}\.ko" "$mdir/modules.builtin" 2>/dev/null && return 0
  if ! is_container && have modprobe && modprobe -nq "sch_${q}" 2>/dev/null; then return 0; fi
  if have tc && tc qdisc show 2>/dev/null | grep -q "^qdisc ${q} "; then return 0; fi
  # 最后在临时网络命名空间里实测（需要 unshare；容器里通常无权限，失败即视为不可用）
  if have unshare && have tc && unshare -n sh -c "ip link set lo up 2>/dev/null; tc qdisc add dev lo root ${q}" >/dev/null 2>&1; then return 0; fi
  return 1
}
tune_cc_ok() { [[ " ${TUNE_CC_AVAIL} " == *" $1 "* ]]; }
tune_qd_ok() { [[ " ${TUNE_QD_AVAIL} " == *" $1 "* ]]; }
tune_bbr_label() {
  tune_cc_ok bbr || { echo "不可用"; return 0; }
  case $TUNE_BBR_VER in
    3*) echo "可用（BBRv3，第三方内核如 XanMod）" ;;
    2*) echo "可用（BBRv2，第三方内核）" ;;
    *) echo "可用（BBRv1，主线内核）" ;;
  esac
}
tune_detect() {
  (( TUNE_DETECTED )) && return 0
  [[ -n $INIT_SYS ]] || detect_init
  detect_virt
  TUNE_MEM=$(mem_limit_mb)
  TUNE_IFACE=$(tune_iface)
  TUNE_CC_AVAIL=$(tune_get net.ipv4.tcp_available_congestion_control) || TUNE_CC_AVAIL=""
  # 主机（非容器）上 tcp_bbr 未加载但模块存在时也视为可用（应用时再加载）；容器内只能用宿主机已加载的
  if ! tune_cc_ok bbr && ! is_container && have modprobe && kernel_ge 4.9 && modprobe -nq tcp_bbr 2>/dev/null; then
    TUNE_CC_AVAIL+="${TUNE_CC_AVAIL:+ }bbr"
  fi
  TUNE_BBR_VER=""
  if [[ -r /sys/module/tcp_bbr/version ]]; then TUNE_BBR_VER=$(cat /sys/module/tcp_bbr/version 2>/dev/null) || TUNE_BBR_VER=""
  elif have modinfo; then TUNE_BBR_VER=$(modinfo -F version tcp_bbr 2>/dev/null) || TUNE_BBR_VER=""; fi
  local q; TUNE_QD_AVAIL=""
  for q in "${TUNE_QDISC_CAND[@]}"; do tune_qdisc_ok "$q" && TUNE_QD_AVAIL+="${TUNE_QD_AVAIL:+ }$q"; done
  local k; for k in "${TUNE_KEYS[@]}"; do tune_probe "$k"; done
  TUNE_DETECTED=1
}
tune_writable_count() { local k n=0; for k in "${TUNE_KEYS[@]}"; do [[ ${TUNE_ST[$k]} == ok ]] && n=$((n + 1)); done; echo "$n"; }

tune_env_lines() {
  printf '  内核:       %s（%s）\n' "$(uname -r)" "$(uname -m)"
  printf '  虚拟化:     %s   init: %s   内存: %s MB\n' "${VIRT:-未知}" "${INIT_SYS:-未知}" "$TUNE_MEM"
  printf '  拥塞控制:   当前 %s   可用: %s   BBR: %s\n' "${TUNE_NOW[net.ipv4.tcp_congestion_control]}" "${TUNE_CC_AVAIL:-未知}" "$(tune_bbr_label)"
  printf '  队列算法:   默认 %s   网卡 %s: %s   可用: %s\n' "${TUNE_NOW[net.core.default_qdisc]}" "${TUNE_IFACE:-?}" "$(tune_root_qdisc "$TUNE_IFACE")" "${TUNE_QD_AVAIL:-未知}"
  printf '  可写参数:   %s / %s%s\n' "$(tune_writable_count)" "${#TUNE_KEYS[@]}" "$(is_container && echo "（容器环境：只读/不可见的参数会自动跳过）")"
}

# ---------- 预设 / 缓冲区档位 ----------
tune_preset_desc() {
  case $1 in
    bbr-fq) echo "BBR + fq（默认，推荐；fq 为 BBR 提供高效 pacing）" ;;
    bbr-fq_codel) echo "BBR + fq_codel（内核 4.20+ 由 TCP 自身 pacing；兼顾本机多业务/路由场景）" ;;
    bbr-cake) echo "BBR + cake（需内核支持 sch_cake；CPU 开销略高）" ;;
    cubic-fq_codel) echo "保守：cubic + fq_codel（不启用 BBR，与多数发行版默认接近）" ;;
    keep) echo "只调缓冲区/连接参数（不改拥塞控制与队列算法）" ;;
    custom) echo "自定义：分别选择拥塞控制与队列算法" ;;
  esac
}
tune_preset_cc_qd() { # $1 预设 → "cc qdisc"（keep 表示不修改）
  case $1 in
    bbr-fq) echo "bbr fq" ;;
    bbr-fq_codel) echo "bbr fq_codel" ;;
    bbr-cake) echo "bbr cake" ;;
    cubic-fq_codel) echo "cubic fq_codel" ;;
    custom) echo "${OPT_TUNE_CC:-keep} ${OPT_TUNE_QDISC:-keep}" ;;
    *) echo "keep keep" ;;
  esac
}
tune_preset_missing() { # 输出预设缺少的组件（为空表示可用）
  local cc qd m=""
  read -r cc qd <<<"$(tune_preset_cc_qd "$1")"
  [[ $cc == keep ]] || tune_cc_ok "$cc" || m+="${m:+、}拥塞控制 ${cc}"
  [[ $qd == keep ]] || tune_qd_ok "$qd" || m+="${m:+、}队列 ${qd}"
  printf '%s' "$m"
}
tune_auto_buf() { # 按内存自动分档
  if (( TUNE_MEM > 0 && TUNE_MEM <= 300 )); then echo small
  elif (( TUNE_MEM >= 1800 )); then echo large
  else echo medium; fi
}
tune_buf_desc() {
  case $1 in
    small) echo "小（≤256MB 级：TCP 缓冲区上限 4MB，UDP/QUIC 8MB）" ;;
    medium) echo "中（TCP/UDP 缓冲区上限 16MB，与 v1.1.x 一致）" ;;
    large) echo "大（≥2GB：缓冲区上限 64MB，适合高带宽长距离线路）" ;;
    bdp) echo "按带宽×延迟计算（BDP）" ;;
    auto) echo "自动（按内存）" ;;
  esac
}
tune_set_buffers() { # $1 档位 small|medium|large ；BDP 在其基础上覆盖上限
  local p=$1
  local core_max tcp_max def backlog somax syn rdef wdef
  case $p in
    small)  core_max=8388608  tcp_max=4194304  rdef="4096 87380 4194304"   wdef="4096 16384 4194304"  def=131072 backlog=4096  somax=4096 syn=4096 ;;
    large)  core_max=67108864 tcp_max=67108864 rdef="4096 131072 67108864" wdef="4096 65536 67108864" def=262144 backlog=32768 somax=8192 syn=16384 ;;
    *)      core_max=16777216 tcp_max=16777216 rdef="4096 131072 16777216" wdef="4096 65536 16777216" def=262144 backlog=16384 somax=4096 syn=8192 ;;
  esac
  TUNE_BDP_NOTE=""
  if [[ $TUNE_BUF == bdp && -n $OPT_TUNE_BW && -n $OPT_TUNE_RTT ]]; then
    # 目标 = 2 × BDP（接收窗口约占缓冲区一半），向上取整到 MB；下限 4MB，上限按内存
    local bdp want cap
    bdp=$(( OPT_TUNE_BW * OPT_TUNE_RTT * 125 ))
    want=$(( (bdp * 2 + 1048575) / 1048576 * 1048576 ))
    if (( TUNE_MEM <= 300 )); then cap=8388608; elif (( TUNE_MEM <= 1024 )); then cap=33554432
    elif (( TUNE_MEM <= 4096 )); then cap=67108864; else cap=134217728; fi
    (( want < 4194304 )) && want=4194304
    (( want > cap )) && want=$cap
    tcp_max=$want
    core_max=$want; (( core_max < 8388608 )) && core_max=8388608   # quic-go(Hysteria2) 需要 ≥7MB 的 UDP 缓冲区
    rdef="${rdef% *} ${tcp_max}" wdef="${wdef% *} ${tcp_max}"
    TUNE_BDP_NOTE="带宽 ${OPT_TUNE_BW} Mbps × 延迟 ${OPT_TUNE_RTT} ms ≈ BDP $(( bdp / 1024 )) KB → 缓冲区上限 $(( tcp_max / 1048576 )) MB（2×BDP，受内存上限 $(( cap / 1048576 )) MB 约束）"
  fi
  TUNE_WANT[net.core.rmem_max]=$core_max TUNE_WANT[net.core.wmem_max]=$core_max
  TUNE_WANT[net.core.rmem_default]=$def TUNE_WANT[net.core.wmem_default]=$def
  TUNE_WANT[net.ipv4.tcp_rmem]=$rdef TUNE_WANT[net.ipv4.tcp_wmem]=$wdef
  TUNE_WANT[net.ipv4.udp_rmem_min]=8192 TUNE_WANT[net.ipv4.udp_wmem_min]=8192
  TUNE_WANT[net.core.netdev_max_backlog]=$backlog TUNE_WANT[net.core.somaxconn]=$somax TUNE_WANT[net.ipv4.tcp_max_syn_backlog]=$syn
  return 0
}
# 生成计划：$1 预设 $2 缓冲区档位(auto|small|medium|large|bdp)
tune_plan() {
  local preset=$1 buf=${2:-auto} cc qd
  TUNE_WANT=()
  TUNE_PRESET=$preset
  read -r cc qd <<<"$(tune_preset_cc_qd "$preset")"
  if [[ $cc != keep ]] && ! tune_cc_ok "$cc"; then
    if [[ $cc == bbr ]]; then
      warn "内核 $(uname -r) 当前不可用 BBR（可用: ${TUNE_CC_AVAIL:-未知}$(is_container && echo '；容器内无法加载内核模块，需宿主机加载 tcp_bbr')），拥塞控制与队列算法保持不变，仅应用缓冲区等参数。"
      cc=keep qd=keep
    else
      warn "拥塞控制 ${cc} 不可用（可用: ${TUNE_CC_AVAIL:-未知}），保持不变。"; cc=keep
    fi
  fi
  if [[ $qd != keep ]] && ! tune_qd_ok "$qd"; then
    warn "队列算法 ${qd} 不可用（可用: ${TUNE_QD_AVAIL:-未知}），保持不变。"; qd=keep
  fi
  TUNE_CC=$cc TUNE_QD=$qd
  [[ $qd == keep ]] || TUNE_WANT[net.core.default_qdisc]=$qd
  [[ $cc == keep ]] || TUNE_WANT[net.ipv4.tcp_congestion_control]=$cc
  # 「保持不变」= 系统原来的设置：如果之前由本脚本改过，则改回备份的原值（否则重启后与当前运行值不一致）
  local k0 v0 prev
  for k0 in net.ipv4.tcp_congestion_control net.core.default_qdisc; do
    [[ -z ${TUNE_WANT[$k0]-} ]] || continue
    if [[ $k0 == net.core.default_qdisc ]]; then prev=$(tune_cur_get QDISC); else prev=$(tune_cur_get CC); fi
    [[ -n $prev && $prev != keep ]] || continue
    v0=$(tune_backup_get "$k0" 2>/dev/null) || continue
    [[ $v0 == "@default" ]] && v0=$(tune_kernel_default "$k0")
    [[ -n $v0 && $v0 != "${TUNE_NOW[$k0]}" ]] || continue
    TUNE_WANT[$k0]=$v0
    if [[ $k0 == net.core.default_qdisc ]]; then TUNE_QD=$v0; else TUNE_CC=$v0; fi
    info "「保持不变」指系统原来的设置：${k0} 将恢复为调优前的 ${v0}。"
  done
  TUNE_BUF=$buf
  if [[ $buf == bdp && ( -z $OPT_TUNE_BW || -z $OPT_TUNE_RTT ) ]]; then warn "BDP 需要同时给出带宽与延迟，改用自动档位。"; TUNE_BUF=auto; fi
  case $TUNE_BUF in auto|bdp) TUNE_BUF_EFF=$(tune_auto_buf) ;; *) TUNE_BUF_EFF=$TUNE_BUF ;; esac
  tune_set_buffers "$TUNE_BUF_EFF"
  TUNE_WANT[net.ipv4.tcp_fastopen]=3
  TUNE_WANT[net.ipv4.tcp_mtu_probing]=1
  TUNE_WANT[net.ipv4.tcp_slow_start_after_idle]=0
  TUNE_WANT[net.ipv4.tcp_notsent_lowat]=131072
  TUNE_WANT[net.ipv4.tcp_fin_timeout]=30
  TUNE_WANT[net.ipv4.tcp_keepalive_time]=600
  TUNE_WANT[fs.file-max]=1048576
  TUNE_WANT[fs.nr_open]=1048576
  (( SWAP_CREATED )) && TUNE_WANT[vm.swappiness]=10
  return 0
}
tune_status_of() { # 预览中的状态文字
  local k=$1 w=${TUNE_WANT[$1]-}
  if [[ -z $w ]]; then echo "保持"; return 0; fi
  if [[ ${TUNE_ST[$k]} != ok && ${TUNE_NOW[$k]} == "$w" ]]; then echo "不变（只读）"; return 0; fi
  [[ ${TUNE_ST[$k]} == ok ]] || { tune_skip_reason "$k"; return 0; }
  if [[ ${TUNE_NOW[$k]} == "$w" ]]; then echo "不变"; else echo "${C_YELLOW}将修改${C_NONE}"; fi
}
tune_preview() {
  local k w n_ch=0 n_skip=0
  echo; hr
  _green "  调优预览：$(tune_preset_desc "$TUNE_PRESET")"
  printf '  缓冲区:   %s%s\n' "$(tune_buf_desc "$TUNE_BUF_EFF")" "$([[ $TUNE_BUF == auto || $TUNE_BUF == bdp ]] && echo "  ← 内存 ${TUNE_MEM}MB 自动选择")"
  [[ -n $TUNE_BDP_NOTE ]] && printf '  BDP:      %s\n' "$TUNE_BDP_NOTE"
  hr
  trow "参数" "当前值" "目标值" "状态"
  for k in "${TUNE_KEYS[@]}"; do
    w=${TUNE_WANT[$k]-}
    [[ -z $w && $k == vm.swappiness ]] && continue
    [[ -n $w ]] || w="(不修改)"
    trow "$k" "${TUNE_NOW[$k]}" "$w" "$(tune_status_of "$k")"
    if [[ -n ${TUNE_WANT[$k]-} ]]; then
      if [[ ${TUNE_NOW[$k]} == "${TUNE_WANT[$k]}" ]]; then :
      elif [[ ${TUNE_ST[$k]} != ok ]]; then n_skip=$((n_skip + 1)); elif [[ ${TUNE_NOW[$k]} != "${TUNE_WANT[$k]}" ]]; then n_ch=$((n_ch + 1)); fi
    fi
  done
  if [[ $TUNE_QD != keep ]]; then
    local r; r=$(tune_root_qdisc "$TUNE_IFACE")
    if [[ -z $TUNE_IFACE || $r == - ]]; then
      trow "网卡队列(tc)" "-" "$TUNE_QD" "跳过：未找到默认网卡或 tc 命令（将在重启后按默认队列生效）"
    elif tune_iface_uses "$TUNE_IFACE" "$TUNE_QD"; then
      trow "网卡 ${TUNE_IFACE} 队列(tc)" "$r" "$TUNE_QD" "不变"
    else
      trow "网卡 ${TUNE_IFACE} 队列(tc)" "$r" "$TUNE_QD" "${C_YELLOW}将立即切换${C_NONE}"
      n_ch=$((n_ch + 1))
    fi
  fi
  hr
  printf '  将修改 %s 项，跳过 %s 项（只读/不可见的参数不会写入配置文件）。\n' "$n_ch" "$n_skip"
  printf '  配置文件: %s   原值备份: %s\n' "$SYSCTL_FILE" "$([[ -f $TUNE_BACKUP ]] && echo "已存在（保留首次应用前的原值）" || echo "首次应用时自动创建 ${TUNE_BACKUP}")"
  return 0
}

# ---------- 备份 / 应用 / 持久化 ----------
tune_backup_save() {
  [[ -f $TUNE_BACKUP ]] && return 0
  mkdir -p "$TUNE_DIR"; chmod 700 "$STATE_DIR" "$TUNE_DIR" 2>/dev/null || true
  local k v legacy=0 tmp="${TUNE_BACKUP}.tmp"
  # v1.1.x 安装时已写入过调优文件：其中的参数当前已是调优值，原值记为 @default（恢复时回退到系统默认）
  [[ -f $SYSCTL_FILE ]] && legacy=1
  {
    echo "# proxy-oneclick 调优前的原始值（$(date '+%F %T')）"
    echo "@time=$(date '+%F %T')"
    echo "@legacy=${legacy}"
    echo "@iface=${TUNE_IFACE}"
    echo "@root_qdisc=$(tune_root_qdisc "$TUNE_IFACE")"
    for k in "${TUNE_KEYS[@]}"; do
      [[ ${TUNE_ST[$k]} == absent ]] && continue
      v=${TUNE_NOW[$k]}
      if (( legacy )) && grep -Eq "^[[:space:]]*${k//./\\.}[[:space:]]*=" "$SYSCTL_FILE" 2>/dev/null; then v="@default"; fi
      echo "${k}=${v}"
    done
  } >"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$TUNE_BACKUP"
  ok "已备份调优前的原始值：${TUNE_BACKUP}"
}
tune_backup_get() { # $1 key → 备份值（没有返回 1）
  [[ -f $TUNE_BACKUP ]] || return 1
  local line
  line=$(grep -m1 "^${1//./\\.}=" "$TUNE_BACKUP" 2>/dev/null) || return 1
  printf '%s' "${line#*=}"
}
tune_boot_needed() { is_container || [[ $TUNE_QD != keep && ${TUNE_ST[net.core.default_qdisc]} != ok ]]; }
tune_write_boot() { # 容器内 systemd-sysctl 常被跳过（/proc/sys 只读挂载），且网卡队列只能用 tc 设置：用开机服务补上
  local qd_line=""
  if [[ $TUNE_QD != keep && -n $TUNE_IFACE && ${TUNE_RES[qdisc]-} == ok ]]; then
    qd_line="tc qdisc replace dev ${TUNE_IFACE} root ${TUNE_QD} 2>/dev/null || true"
  fi
  mkdir -p "$TUNE_DIR"
  cat >"$TUNE_BOOT" <<BOOT
#!/bin/sh
# 由 proxy-oneclick 生成：开机时重新应用网络调优（容器内 sysctl 服务可能被跳过）
[ -f ${SYSCTL_FILE} ] && sysctl -p ${SYSCTL_FILE} >/dev/null 2>&1
${qd_line}
exit 0
BOOT
  chmod 700 "$TUNE_BOOT"
  if is_openrc; then
    cat >"$TUNE_RC" <<RC
#!/sbin/openrc-run
# 由 proxy-oneclick 生成（网络调优）
description="proxy-oneclick network tuning"
depend() {
  want net
  after net sysctl
}
start() {
  ebegin "Applying proxy-oneclick network tuning"
  /bin/sh "${TUNE_BOOT}"
  eend 0
}
RC
    chmod 755 "$TUNE_RC"
  elif [[ $INIT_SYS == systemd ]]; then
    cat >"$TUNE_UNIT" <<UNIT
[Unit]
Description=proxy-oneclick network tuning (sysctl + qdisc)
After=network.target systemd-sysctl.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh ${TUNE_BOOT}

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload >/dev/null 2>&1 || true
  else
    return 0
  fi
  svc_enable proxy-oneclick-tune
  ok "已添加开机服务 proxy-oneclick-tune（容器/受限环境下开机重新应用）"
}
tune_remove_boot() {
  if [[ -f $TUNE_UNIT || -f $TUNE_RC ]]; then svc_disable_stop proxy-oneclick-tune; fi
  rm -f "$TUNE_UNIT" "$TUNE_RC" "$TUNE_BOOT"
  sd_reload
}
tune_apply_qdisc() { # 立即把默认网卡切换到目标队列算法
  TUNE_RES[qdisc]=skip
  [[ $TUNE_QD != keep && -n $TUNE_IFACE ]] && have tc || return 0
  if tune_iface_uses "$TUNE_IFACE" "$TUNE_QD"; then TUNE_RES[qdisc]=ok; return 0; fi
  local r; r=$(tune_root_qdisc "$TUNE_IFACE")
  if [[ $r == mq* && ${TUNE_NOW[net.core.default_qdisc]} == "$TUNE_QD" ]]; then
    # 多队列网卡：删除根队列后内核会按新的 default_qdisc 重新挂 mq + 子队列
    tc qdisc del dev "$TUNE_IFACE" root >/dev/null 2>&1 || true
  fi
  tune_iface_uses "$TUNE_IFACE" "$TUNE_QD" || tc qdisc replace dev "$TUNE_IFACE" root "$TUNE_QD" >/dev/null 2>&1 || true
  if tune_iface_uses "$TUNE_IFACE" "$TUNE_QD"; then TUNE_RES[qdisc]=ok; else TUNE_RES[qdisc]=fail; fi
  return 0
}
tune_write_extras() { # 文件句柄上限 / journald（与 v1.1.x 相同；仅 systemd 写 systemd 相关文件）
  [[ -d /etc/security ]] && { mkdir -p "$(dirname "$LIMITS_FILE")"
    printf '%s\n' "# proxy-oneclick" "* soft nofile 1048576" "* hard nofile 1048576" "root soft nofile 1048576" "root hard nofile 1048576" >"$LIMITS_FILE"; }
  if [[ $INIT_SYS == systemd ]]; then
    mkdir -p "$(dirname "$SYSTEMD_LIMITS_FILE")" "$(dirname "$JOURNALD_FILE")"
    printf '%s\n' "# proxy-oneclick" "[Manager]" "DefaultLimitNOFILE=1048576" >"$SYSTEMD_LIMITS_FILE"
    printf '%s\n' "# proxy-oneclick" "[Journal]" "SystemMaxUse=100M" "RuntimeMaxUse=50M" >"$JOURNALD_FILE"
    systemctl daemon-reexec >/dev/null 2>&1 || true
    systemctl restart systemd-journald >/dev/null 2>&1 || true
  fi
  return 0
}
tune_commit() {
  local k w n_ok=0 n_fail=0 n_skip=0 persist=()
  tune_backup_save
  TUNE_RES=()
  if [[ $TUNE_CC != keep ]] && ! is_container && have modprobe; then modprobe -q "tcp_${TUNE_CC}" 2>/dev/null || true; fi
  if [[ $TUNE_QD != keep && $TUNE_QD != pfifo_fast ]] && ! is_container && have modprobe; then modprobe -q "sch_${TUNE_QD}" 2>/dev/null || true; fi
  for k in "${TUNE_KEYS[@]}"; do
    w=${TUNE_WANT[$k]-}
    [[ -n $w ]] || continue
    if [[ ${TUNE_ST[$k]} != ok ]]; then
      [[ ${TUNE_NOW[$k]} == "$w" ]] || { TUNE_RES[$k]=skip; n_skip=$((n_skip + 1)); }
      continue
    fi
    if [[ ${TUNE_NOW[$k]} == "$w" ]] || tune_write "$k" "$w"; then
      # 部分参数写入成功但被内核截断/拒绝，以回读为准
      if [[ $(tune_get "$k" 2>/dev/null) == "$w" ]]; then TUNE_RES[$k]=ok; n_ok=$((n_ok + 1)); persist+=("$k"); TUNE_NOW[$k]=$w
      else TUNE_RES[$k]=fail; n_fail=$((n_fail + 1)); TUNE_NOW[$k]=$(tune_get "$k" 2>/dev/null || echo "-"); fi
    else
      TUNE_RES[$k]=fail; n_fail=$((n_fail + 1))
    fi
  done
  tune_apply_qdisc
  # 写入唯一的配置文件（只包含成功应用的参数）
  if (( ${#persist[@]} )); then
    mkdir -p "$(dirname "$SYSCTL_FILE")"
    {
      echo "# 由 proxy-oneclick 生成，卸载时会删除"
      echo "# v${SCRIPT_VERSION} 网络调优：预设 ${TUNE_PRESET} / 缓冲区 ${TUNE_BUF_EFF}$([[ $TUNE_BUF != "$TUNE_BUF_EFF" ]] && echo "（${TUNE_BUF}）") / $(date '+%F %T')"
      echo "# 恢复原值: proxy tune restore"
      for k in "${persist[@]}"; do echo "${k} = ${TUNE_WANT[$k]}"; done
    } >"${SYSCTL_FILE}.tmp"
    mv -f "${SYSCTL_FILE}.tmp" "$SYSCTL_FILE"
  else
    rm -f "$SYSCTL_FILE"
  fi
  # OpenRC：确保开机执行 sysctl 服务（Alpine 默认在 boot 运行级）
  if is_openrc && [[ -x /etc/init.d/sysctl ]] && (( ${#persist[@]} )); then
    rc-update add sysctl boot >/dev/null 2>&1 || true
  fi
  if tune_boot_needed && { (( ${#persist[@]} )) || [[ ${TUNE_RES[qdisc]} == ok ]]; }; then tune_write_boot; else tune_remove_boot; fi
  if (( ! NAT_MODE )) || ! is_container; then tune_write_extras; fi
  if (( ! ${#persist[@]} )) && [[ ${TUNE_RES[qdisc]} != ok ]]; then
    # 什么都没改成：不留下备份/状态文件，避免显示为「已应用」
    rm -rf "$TUNE_DIR"; tune_remove_boot
    warn "没有任何参数被修改（$(is_container && echo '容器内内核参数由宿主机控制' || echo '无权限')）。"
    return 0
  fi
  mkdir -p "$TUNE_DIR"
  {
    echo "PRESET=${TUNE_PRESET}"; echo "BUFFER=${TUNE_BUF}"; echo "BUFFER_EFF=${TUNE_BUF_EFF}"
    echo "CC=${TUNE_CC}"; echo "QDISC=${TUNE_QD}"; echo "IFACE=${TUNE_IFACE}"
    echo "QDISC_TC=$([[ ${TUNE_RES[qdisc]} == ok ]] && echo 1 || echo 0)"
    echo "TIME=$(date '+%F %T')"; echo "VERSION=${SCRIPT_VERSION}"
  } >"$TUNE_CUR"
  # 结果
  if (( ! TUNE_COMPACT )); then
    echo; _cyan "  应用结果："
    for k in "${TUNE_KEYS[@]}"; do
      case ${TUNE_RES[$k]-} in
        fail) printf '   %s✗%s %s 写入失败（值不被内核接受），当前 %s\n' "$C_RED" "$C_NONE" "$(tcol "$k" 34)" "${TUNE_NOW[$k]}" ;;
        skip) printf '   %s-%s %s %s\n' "$C_YELLOW" "$C_NONE" "$(tcol "$k" 34)" "$(tune_skip_reason "$k")" ;;
      esac
    done
  fi
  case ${TUNE_RES[qdisc]} in
    ok) [[ $TUNE_QD != keep ]] && info "网卡 ${TUNE_IFACE} 队列: $(tune_root_qdisc "$TUNE_IFACE")" ;;
    fail) warn "网卡 ${TUNE_IFACE} 队列切换为 ${TUNE_QD} 失败（容器内通常无权限；default_qdisc 可写时重启后生效）。" ;;
  esac
  if (( n_skip )) && (( TUNE_COMPACT )); then
    info "跳过 ${n_skip} 项只读/不可见参数（$(is_container && echo '容器内由宿主机控制' || echo '无权限')）。"
  fi
  ok "调优已应用：成功 ${n_ok} 项，跳过 ${n_skip} 项，失败 ${n_fail} 项。拥塞控制 $(tune_get net.ipv4.tcp_congestion_control || echo '未知') / 队列 $(tune_qdisc_label "$TUNE_IFACE")"
  if (( ${#persist[@]} )); then ok "已写入 ${SYSCTL_FILE}（恢复: proxy tune restore）"; else warn "没有可写的参数，未写入配置文件（容器内内核参数由宿主机控制）。"; fi
  return 0
}

# ---------- 恢复 ----------
# 与系统无关的内核默认值（仅在没有精确备份时使用；与内存相关的参数重启后自然恢复）
tune_kconf() { # 读取内核编译配置（/boot/config-* 或 /proc/config.gz），例如 CONFIG_DEFAULT_NET_SCH
  local f line=""; f="/boot/config-$(uname -r)"
  if [[ -r $f ]]; then line=$(grep -m1 "^${1}=" "$f" 2>/dev/null) || line=""
  elif [[ -r /proc/config.gz ]] && have zcat; then line=$(zcat /proc/config.gz 2>/dev/null | grep -m1 "^${1}=") || line=""; fi
  line=${line#*=}; line=${line//\"/}
  printf '%s' "$line"
}
tune_kernel_default() {
  local v
  case $1 in
    net.core.default_qdisc) v=$(tune_kconf CONFIG_DEFAULT_NET_SCH); echo "${v:-pfifo_fast}" ;;
    net.ipv4.tcp_congestion_control) v=$(tune_kconf CONFIG_DEFAULT_TCP_CONG); v=${v:-cubic}; tune_cc_ok "$v" && echo "$v" ;;
    net.core.rmem_max|net.core.wmem_max|net.core.rmem_default|net.core.wmem_default) echo 212992 ;;
    net.ipv4.tcp_rmem) echo "4096 131072 6291456" ;;
    net.ipv4.tcp_wmem) echo "4096 16384 4194304" ;;
    net.ipv4.udp_rmem_min|net.ipv4.udp_wmem_min) echo 4096 ;;
    net.core.netdev_max_backlog) echo 1000 ;;
    net.core.somaxconn) if kernel_ge 5.4; then echo 4096; else echo 128; fi ;;
    net.ipv4.tcp_fastopen) echo 1 ;;
    net.ipv4.tcp_mtu_probing) echo 0 ;;
    net.ipv4.tcp_slow_start_after_idle) echo 1 ;;
    net.ipv4.tcp_notsent_lowat) echo 4294967295 ;;
    net.ipv4.tcp_fin_timeout) echo 60 ;;
    net.ipv4.tcp_keepalive_time) echo 7200 ;;
    fs.nr_open) echo 1048576 ;;
    vm.swappiness) echo 60 ;;
  esac
  return 0
}
tune_key_in_other_conf() { # 其它 sysctl 配置文件是否设置了该参数
  local f
  for f in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf; do
    [[ -f $f && $f != "$SYSCTL_FILE" ]] || continue
    grep -Eq "^[[:space:]]*-?${1//./[./]}[[:space:]]*=" "$f" 2>/dev/null && return 0
  done
  return 1
}
tune_sysctl_system() { # 重新加载系统 sysctl 配置（busybox sysctl 不支持 --system）
  sysctl --system >/dev/null 2>&1 && return 0
  local f
  for f in /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf /run/sysctl.d/*.conf /etc/sysctl.d/*.conf /etc/sysctl.conf; do
    [[ -f $f ]] && { sysctl -p "$f" >/dev/null 2>&1 || true; }
  done
  return 0
}
tune_has_config() { [[ -f $SYSCTL_FILE || -f $TUNE_BACKUP || -f $TUNE_CUR || -f $TUNE_BOOT || -f $TUNE_UNIT || -f $TUNE_RC || -f $LIMITS_FILE || -f $SYSTEMD_LIMITS_FILE || -f $JOURNALD_FILE ]]; }
tune_restore() { # $1 = quiet（卸载时调用，不询问）
  local quiet=${1:-} k v cur legacy_keys=() n=0
  tune_detect
  if ! tune_has_config; then info "当前没有由本脚本应用的调优，无需恢复。"; return 0; fi
  declare -A old=()
  if [[ -f $TUNE_BACKUP ]]; then
    for k in "${TUNE_KEYS[@]}"; do v=$(tune_backup_get "$k") && old[$k]=$v; done
  elif [[ -f $SYSCTL_FILE ]]; then
    # 旧版本（v1.1.x）写入的文件，没有备份：回退到系统默认
    for k in "${TUNE_KEYS[@]}"; do grep -Eq "^[[:space:]]*${k//./\\.}[[:space:]]*=" "$SYSCTL_FILE" 2>/dev/null && old[$k]="@default"; done
  fi
  if [[ $quiet != quiet ]]; then
    echo; hr; _green "  恢复调优前的设置"; hr
    printf '  %s %s %s\n' "$(tcol "参数" 34)" "$(tcol "当前值" 22)" "恢复为"
    for k in "${TUNE_KEYS[@]}"; do
      [[ -n ${old[$k]-} ]] || continue
      v=${old[$k]}; [[ $v == "@default" ]] && v="系统默认（sysctl --system）"
      [[ ${TUNE_NOW[$k]} == "${old[$k]}" ]] && continue
      printf '  %s %s %s\n' "$(tcol "$k" 34)" "$(tcol "${TUNE_NOW[$k]}" 22)" "$v"
    done
    hr
    echo "  将删除: ${SYSCTL_FILE}、文件句柄/journald 调优文件、开机服务 proxy-oneclick-tune（如有）"
    confirm "确认恢复？" y || return 0
  fi
  rm -f "$SYSCTL_FILE"
  tune_remove_boot
  for k in "${TUNE_KEYS[@]}"; do
    v=${old[$k]-}; [[ -n $v ]] || continue
    if [[ $v == "@default" ]]; then legacy_keys+=("$k"); continue; fi
    [[ ${TUNE_ST[$k]} == ok ]] || continue
    cur=$(tune_get "$k" 2>/dev/null) || cur=""
    [[ $cur == "$v" ]] && continue
    if tune_write "$k" "$v"; then n=$((n + 1)); else warn "恢复 ${k}=${v} 失败"; fi
  done
  if (( ${#legacy_keys[@]} )); then
    tune_sysctl_system
    for k in "${legacy_keys[@]}"; do
      [[ ${TUNE_ST[$k]} == ok ]] || continue
      tune_key_in_other_conf "$k" && continue
      v=$(tune_kernel_default "$k"); [[ -n $v ]] || continue
      cur=$(tune_get "$k" 2>/dev/null) || cur=""
      [[ $cur == "$v" ]] && continue
      tune_write "$k" "$v" && n=$((n + 1))
    done
  fi
  # 网卡队列：恢复为（新的）默认队列
  local iface root0 qd_now
  iface=$(tune_backup_get "@iface" 2>/dev/null) || iface=""
  [[ -n $iface ]] || iface=$TUNE_IFACE
  root0=$(tune_backup_get "@root_qdisc" 2>/dev/null) || root0=""
  qd_now=$(tune_get net.core.default_qdisc 2>/dev/null) || qd_now=""
  if have tc && [[ -n $iface ]]; then
    local r; r=$(tune_root_qdisc "$iface")
    if [[ -n $root0 && $root0 != - && $r != "$root0" ]] || { [[ -z $root0 ]] && [[ $r == fq || $r == "mq(fq)" ]] && [[ $qd_now != fq ]]; }; then
      tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
      r=$(tune_root_qdisc "$iface")
      if [[ -n $root0 && $root0 != - && $root0 != mq* && $root0 != noqueue && $r != "$root0" ]]; then
        tc qdisc replace dev "$iface" root "$root0" >/dev/null 2>&1 || true
      fi
      info "网卡 ${iface} 队列: $(tune_root_qdisc "$iface")"
    fi
  fi
  if [[ -f $LIMITS_FILE || -f $SYSTEMD_LIMITS_FILE || -f $JOURNALD_FILE ]]; then
    rm -f "$LIMITS_FILE" "$SYSTEMD_LIMITS_FILE" "$JOURNALD_FILE"
    if [[ $INIT_SYS == systemd ]]; then
      systemctl daemon-reexec >/dev/null 2>&1 || true
      systemctl restart systemd-journald >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$TUNE_DIR"
  TUNE_DETECTED=0
  ok "已恢复调优前的设置（还原 ${n} 项；拥塞控制 $(tune_get net.ipv4.tcp_congestion_control || echo '未知') / 队列 $(tune_qdisc_label "$iface")）"
  (( ${#legacy_keys[@]} )) && info "旧版本写入的参数已回退到系统默认；与内存相关的少数参数（如 tcp_max_syn_backlog、fs.file-max）重启后完全恢复。"
  return 0
}

# ---------- 状态 ----------
tune_cur_get() { [[ -f $TUNE_CUR ]] && awk -F= -v k="$1" '$1==k{print substr($0, index($0,"=")+1); exit}' "$TUNE_CUR"; return 0; }
tune_status() {
  tune_detect
  echo; hr; _green "  网络调优状态"; hr
  tune_env_lines
  if [[ -f $TUNE_CUR ]]; then
    printf '  本脚本调优: %s已应用%s（预设 %s，缓冲区 %s，%s）\n' "$C_GREEN" "$C_NONE" "$(tune_cur_get PRESET)" "$(tune_cur_get BUFFER_EFF)" "$(tune_cur_get TIME)"
  elif [[ -f $SYSCTL_FILE ]]; then
    printf '  本脚本调优: 已应用（v1.1.x 安装时写入：BBR + fq / 中档缓冲区）\n'
  else
    printf '  本脚本调优: 未应用\n'
  fi
  printf '  原值备份:   %s\n' "$([[ -f $TUNE_BACKUP ]] && echo "$TUNE_BACKUP" || echo 无)"
  hr
  local k
  for k in "${TUNE_KEYS[@]}"; do
    [[ $k == vm.swappiness ]] && continue
    printf '  %s %s %s\n' "$(tcol "$k" 34)" "$(tcol "${TUNE_NOW[$k]}" 24)" "$(case ${TUNE_ST[$k]} in ok) echo 可写 ;; ro) echo "${C_YELLOW}只读${C_NONE}" ;; host) echo "${C_YELLOW}宿主机全局参数（不修改）${C_NONE}" ;; *) echo "${C_YELLOW}不可见${C_NONE}" ;; esac)"
  done
  local cnt max
  cnt=$(tune_get net.netfilter.nf_conntrack_count 2>/dev/null) || cnt=""
  max=$(tune_get net.netfilter.nf_conntrack_max 2>/dev/null) || max=""
  if [[ $cnt =~ ^[0-9]+$ && $max =~ ^[0-9]+$ ]] && (( max > 0 )); then
    printf '  %s %s / %s（%s%%）\n' "$(tcol "conntrack 连接跟踪" 34)" "$cnt" "$max" "$(( cnt * 100 / max ))"
    (( cnt * 100 / max >= 80 )) && warn "conntrack 表使用率超过 80%，连接数很多时可能丢包（可调大 net.netfilter.nf_conntrack_max，宿主机控制时需联系服务商）。"
  fi
  hr
  return 0
}

# ---------- 交互 ----------
tune_ask_buffer() {
  local c auto; auto=$(tune_auto_buf)
  echo
  echo "  缓冲区档位（当前内存 ${TUNE_MEM}MB）："
  echo "   1) $(tune_buf_desc auto) → $(tune_buf_desc "$auto")"
  echo "   2) $(tune_buf_desc small)"
  echo "   3) $(tune_buf_desc medium)"
  echo "   4) $(tune_buf_desc large)"
  echo "   5) $(tune_buf_desc bdp)：输入 VPS 带宽与到客户端的延迟"
  ask c "请选择" "1"
  case $c in
    2) OPT_TUNE_BUF=small ;; 3) OPT_TUNE_BUF=medium ;; 4) OPT_TUNE_BUF=large ;;
    5) local bw rtt
       ask bw "VPS 带宽（Mbps，例如 1000）" "${OPT_TUNE_BW:-1000}"
       ask rtt "到客户端的往返延迟（ms，例如 180）" "${OPT_TUNE_RTT:-180}"
       bw=$(sanitize_port_input "$bw"); rtt=$(sanitize_port_input "$rtt")
       if [[ $bw =~ ^[0-9]{1,6}$ && $rtt =~ ^[0-9]{1,5}$ ]] && (( 10#$bw >= 1 && 10#$bw <= 100000 && 10#$rtt >= 1 && 10#$rtt <= 2000 )); then
         OPT_TUNE_BW=$((10#$bw)) OPT_TUNE_RTT=$((10#$rtt)) OPT_TUNE_BUF=bdp
       else warn "输入无效，改用自动档位。"; OPT_TUNE_BUF=auto; fi ;;
    *) OPT_TUNE_BUF=auto ;;
  esac
}
tune_pick() { # $1 类型 cc|qd → 从可用列表中选择（0 = 保持当前）
  local list i=1 c item arr=()
  if [[ $1 == cc ]]; then list=$TUNE_CC_AVAIL; else list=$TUNE_QD_AVAIL; fi
  for item in $list; do arr+=("$item"); done
  echo "   0) 保持当前（$( [[ $1 == cc ]] && echo "${TUNE_NOW[net.ipv4.tcp_congestion_control]}" || echo "${TUNE_NOW[net.core.default_qdisc]}")）" >&2
  for item in "${arr[@]}"; do echo "   ${i}) ${item}" >&2; i=$((i + 1)); done
  ask c "请选择" "0"
  if [[ $c =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#arr[@]} )); then echo "${arr[c-1]}"; else echo keep; fi
}
tune_run() { # $1 预设 $2 缓冲区档位；按 TUNE_NOCONFIRM 决定是否询问
  tune_detect
  tune_plan "$1" "${2:-auto}"
  if (( TUNE_COMPACT )); then
    info "预设: $(tune_preset_desc "$TUNE_PRESET")；缓冲区: $(tune_buf_desc "$TUNE_BUF_EFF")"
  else
    tune_preview
  fi
  local k nw=0
  for k in "${!TUNE_WANT[@]}"; do [[ ${TUNE_ST[$k]} == ok ]] && nw=$((nw + 1)); done
  if (( nw == 0 )) && { [[ $TUNE_QD == keep || -z $TUNE_IFACE ]] || ! have tc; }; then
    warn "当前环境没有可写的目标参数（$(is_container && echo "容器 ${VIRT}：内核参数由宿主机控制" || echo '无权限')），未做任何修改。"
    return 0
  fi
  if (( ! TUNE_NOCONFIRM )); then
    confirm "确认应用以上调优？" y || { info "已取消，未做任何修改。"; return 0; }
  fi
  tune_commit
}
menu_tune() {
  local c p miss i=2 map=()
  tune_detect
  echo; hr; _green "  网络调优（独立功能，NAT / 容器也可使用）"; hr
  tune_env_lines
  if [[ -f $TUNE_CUR ]]; then printf '  已应用:     预设 %s / 缓冲区 %s（%s）\n' "$(tune_cur_get PRESET)" "$(tune_cur_get BUFFER_EFF)" "$(tune_cur_get TIME)"
  elif [[ -f $SYSCTL_FILE ]]; then printf '  已应用:     v1.1.x 安装时的默认调优（BBR + fq）\n'; fi
  hr
  echo "   1) 查看当前状态 / 全部参数"
  for p in bbr-fq bbr-fq_codel bbr-cake cubic-fq_codel custom keep; do
    miss=""; [[ $p == custom || $p == keep ]] || miss=$(tune_preset_missing "$p")
    printf '   %s) %s%s\n' "$i" "$(tune_preset_desc "$p")" "${miss:+  ${C_YELLOW}[不可用：缺少 ${miss}]${C_NONE}}"
    map[i]=$p; i=$((i + 1))
  done
  echo "   ${i}) 恢复调优前的设置（删除 ${SYSCTL_FILE}）"
  echo "   0) 返回"
  ask c "请选择" "0"
  [[ $c =~ ^[0-9]+$ ]] || return 0
  if (( c == 1 )); then tune_status; return 0; fi
  if (( c == i )); then tune_restore; return 0; fi
  p=${map[c]-}; [[ -n $p ]] || return 0
  if [[ $p != custom && $p != keep ]]; then
    miss=$(tune_preset_missing "$p")
    if [[ -n $miss ]]; then warn "当前内核/环境缺少 ${miss}，无法使用该预设（请选择其它预设或「自定义」）。"; return 0; fi
  fi
  if [[ $p == custom ]]; then
    echo; echo "  拥塞控制算法（仅列出内核当前可用的）："; OPT_TUNE_CC=$(tune_pick cc)
    echo; echo "  队列算法（qdisc）："; OPT_TUNE_QDISC=$(tune_pick qd)
  fi
  tune_ask_buffer
  TUNE_NOCONFIRM=0
  tune_run "$p" "$OPT_TUNE_BUF"
}
tune_opt_preset() { # 命令行指定的预设；给了 --tune-cc / --tune-qdisc 时为 custom；否则用 $1
  if [[ -n $OPT_TUNE_CC || -n $OPT_TUNE_QDISC ]]; then echo custom; else echo "${OPT_TUNE_PRESET:-$1}"; fi
}
# proxy tune [status|preview|apply|restore]
do_tune() {
  require_root
  load_state
  local preset; preset=$(tune_opt_preset bbr-fq)
  [[ -n $OPT_TUNE_BW && -n $OPT_TUNE_RTT && -z $OPT_TUNE_BUF ]] && OPT_TUNE_BUF=bdp
  case ${OPT_TUNE_ACT:-} in
    status) tune_status ;;
    restore) tune_restore ;;
    preview) tune_detect; tune_plan "$preset" "${OPT_TUNE_BUF:-auto}"; tune_preview ;;
    apply) TUNE_NOCONFIRM=$OPT_AUTO; tune_run "$preset" "${OPT_TUNE_BUF:-auto}" ;;
    *)
      if [[ -n $OPT_TUNE_PRESET$OPT_TUNE_CC$OPT_TUNE_QDISC$OPT_TUNE_BUF ]]; then
        TUNE_NOCONFIRM=$OPT_AUTO; tune_run "$preset" "${OPT_TUNE_BUF:-auto}"
      elif [[ -t 0 || -r /dev/tty ]] && (( ! OPT_AUTO )); then
        menu_tune
      else
        tune_status
      fi ;;
  esac
}

# 安装流程调用：普通模式 = 默认预设 BBR + fq、中档缓冲区（与 v1.1.x 结果一致），不询问
apply_tuning() {
  step "系统网络调优（保守参数，不更换内核）"
  TUNE_NOCONFIRM=1 TUNE_COMPACT=1
  [[ -n $OPT_TUNE_BW && -n $OPT_TUNE_RTT && -z $OPT_TUNE_BUF ]] && OPT_TUNE_BUF=bdp
  tune_run "$(tune_opt_preset bbr-fq)" "${OPT_TUNE_BUF:-medium}"
  TUNE_COMPACT=0
  [[ $INIT_SYS == systemd ]] && ok "journald 日志上限 100M。"
  return 0
}
# NAT 模式：默认询问（只应用可写参数）；--auto 时仅在给了 --tune / --tune-preset 等参数时执行
nat_tune() {
  local preset
  case ${OPT_TUNE:-2} in
    0) return 0 ;;
    1) : ;;
    *) (( OPT_AUTO )) && return 0 ;;
  esac
  step "网络调优（可选，只应用本机/容器内可写的参数）"
  tune_detect
  tune_env_lines
  if (( $(tune_writable_count) == 0 )); then
    info "当前环境没有可写的内核网络参数（容器内由宿主机控制），跳过。"; return 0
  fi
  if [[ ${OPT_TUNE:-2} != 1 ]]; then
    echo "   将按内存自动选择 TCP 缓冲区档位$(tune_cc_ok bbr && [[ ${TUNE_ST[net.ipv4.tcp_congestion_control]} == ok ]] && echo '，并启用 BBR + fq（网卡队列用 tc 设置）')；"
    echo "   容器内只读 / 宿主机控制的参数自动跳过，会先显示预览；之后可随时用 proxy tune 调整或恢复。"
  fi
  if [[ ${OPT_TUNE:-2} != 1 ]] && ! confirm "是否进行网络调优？" y; then
    info "已跳过网络调优（之后可运行: proxy tune）。"; return 0
  fi
  preset=$(tune_opt_preset "")
  [[ -n $OPT_TUNE_BW && -n $OPT_TUNE_RTT && -z $OPT_TUNE_BUF ]] && OPT_TUNE_BUF=bdp
  if [[ -z $preset ]]; then
    if tune_cc_ok bbr && [[ ${TUNE_ST[net.ipv4.tcp_congestion_control]} == ok ]]; then preset=bbr-fq
    else preset=keep; fi
  fi
  TUNE_NOCONFIRM=$(( OPT_TUNE == 1 || OPT_AUTO ))
  tune_run "$preset" "${OPT_TUNE_BUF:-auto}"
}

