# ============================================================
#                        环境预检
# ============================================================
reinstall_hint() {
  cat >&2 <<HINT
${C_YELLOW}建议将系统重装为 Debian 12（最稳定、本脚本测试最充分）：${C_NONE}
    可使用 bin456789/reinstall 一键重装脚本：
    curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh || wget -O reinstall.sh https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh
    bash reinstall.sh debian 12
${C_RED}警告：重装会清空整块硬盘上的所有数据！请先备份；重装过程中若出现问题，需要通过服务商的 VNC / 串口控制台处理。${C_NONE}
HINT
}
refuse_os() { printf '%s[错误]%s %s\n' "$C_RED" "$C_NONE" "$1" >&2; reinstall_hint; exit 1; }

osr_get() {
  awk -F= -v k="$1" '$1==k { v=substr($0, index($0, "=") + 1); gsub(/^["\047]|["\047]$/, "", v); print v; exit }' /etc/os-release 2>/dev/null || true
}

detect_os() {
  [[ -r /etc/os-release ]] || refuse_os "无法读取 /etc/os-release，无法识别系统。"
  # 不直接 source，逐行解析，避免格式异常的文件导致脚本出错
  local ID VERSION_ID PRETTY_NAME ID_LIKE
  ID=$(osr_get ID) VERSION_ID=$(osr_get VERSION_ID) PRETTY_NAME=$(osr_get PRETTY_NAME) ID_LIKE=$(osr_get ID_LIKE)
  OS_ID=${ID,,} OS_VER=${VERSION_ID:-0} OS_NAME=${PRETTY_NAME:-$ID}
  local major=${OS_VER%%.*}
  [[ $major =~ ^[0-9]+$ ]] || major=0

  detect_init
  if [[ $OS_ID == alpine ]]; then
    alpine_check
  elif [[ $INIT_SYS != systemd ]]; then
    refuse_os "当前系统未使用 systemd 作为 init（${OS_NAME}），本脚本不支持（Debian/Ubuntu/RHEL 需 systemd；非 systemd 环境仅支持 Alpine + OpenRC 且需使用 --nat）。"
  fi
  case $OS_ID in
    debian)
      (( major >= 11 )) || refuse_os "Debian ${OS_VER} 版本过旧，仅支持 Debian 11/12/13。"
      PKG=apt ;;
    ubuntu)
      ver_ge "$OS_VER" "20.04" || refuse_os "Ubuntu ${OS_VER} 版本过旧，仅支持 Ubuntu 20.04 及以上。"
      PKG=apt ;;
    rocky|almalinux|centos|rhel|ol|cloudlinux)
      if [[ $OS_ID == centos && $major -le 7 ]] || (( major < 8 )); then
        refuse_os "${OS_NAME} 已停止维护（CentOS 7 等），不受支持。"
      fi
      PKG=dnf ;;
    fedora)
      PKG=dnf ;;
    alpine)
      PKG=apk ;;
    *)
      if [[ " ${ID_LIKE,,} " == *" debian "* ]] && have apt-get; then
        warn "未经测试的 Debian 系发行版: ${OS_NAME}，将按 Debian 方式尝试。"; PKG=apt
      elif [[ " ${ID_LIKE,,} " =~ (rhel|fedora|centos) ]] && have dnf; then
        warn "未经测试的 RHEL 系发行版: ${OS_NAME}，将按 RHEL 方式尝试。"; PKG=dnf
      else
        refuse_os "不支持的系统: ${OS_NAME}"
      fi ;;
  esac
  [[ $PKG == dnf ]] && ! have dnf && refuse_os "未找到 dnf，本脚本不支持使用 yum 的旧系统。"

  case $(uname -m) in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7*|armv8l)
      ARCH=armv7 ;;   # 普通模式不支持：在 preflight 确定 NAT 模式后检查
    *) die "不支持的 CPU 架构: $(uname -m)（仅支持 amd64 / arm64$(direct_mode && echo ' / armv7')）" ;;
  esac
}

# Alpine：仅 NAT 模式支持（musl + OpenRC，官方安装脚本不支持，改为直接下载二进制）
alpine_check() {
  ver_ge "$OS_VER" "3.18" || refuse_os "Alpine ${OS_VER} 版本过旧，NAT 模式需要 Alpine 3.18 及以上。"
  [[ $INIT_SYS == openrc ]] || refuse_os "Alpine 未检测到 OpenRC（缺少 openrc-run / rc-service），请先执行: apk add openrc"
  # v1.2.1：NAT 模式统一在 decide_nat_mode（安装入口）中确定；这里只做系统检查
  return 0
}

# ---------- v1.2.1：安装前统一确定 NAT_MODE（菜单 1 / 13 / --land / 改装 共用） ----------
# 本机网卡上的全部地址（不依赖 iproute2：精简容器装依赖前可能没有 ip 命令）
local_addrs() {
  if have ip; then
    ip addr show 2>/dev/null | awk '$1=="inet"||$1=="inet6"{sub(/\/.*/, "", $2); print $2}'
  else
    awk '/32 host LOCAL/{print prev} {prev=$2}' /proc/net/fib_trie 2>/dev/null | sort -u
    awk '{print $1}' /proc/net/if_inet6 2>/dev/null   # 32 位十六进制（不含冒号）
  fi
}
ip6_hex() { # IPv6 → 32 位十六进制小写（用于与 /proc/net/if_inet6 比较）
  local a=${1,,} head tail h="" g n i
  if [[ $a == *::* ]]; then head=${a%%::*} tail=${a#*::}; else head=$a tail=""; fi
  local -a H T; IFS=: read -ra H <<<"$head"; IFS=: read -ra T <<<"$tail"
  n=$(( 8 - ${#H[@]} - ${#T[@]} )); (( n >= 0 )) || return 1
  for g in "${H[@]}"; do h+=$(printf '%04x' "0x${g:-0}"); done
  for (( i = 0; i < n; i++ )); do h+="0000"; done
  for g in "${T[@]}"; do h+=$(printf '%04x' "0x${g:-0}"); done
  printf '%s' "$h"
}
ip_is_local() { # $1 IP 是否配置在本机网卡上
  local a x=${1,,} xh=""
  [[ -n $x ]] || return 1
  [[ $x == *:* ]] && xh=$(ip6_hex "$x" 2>/dev/null)
  while IFS= read -r a; do
    a=${a,,}
    [[ $a == "$x" || ( -n $xh && $a == "$xh" ) ]] && return 0
  done < <(local_addrs)
  return 1
}
nat_probe_pubip() { # 快速获取公网 IP（不中断安装）；输出 IP，失败为空
  local ip=""
  ip=$(curl -4 -fsS --connect-timeout 4 -m 6 https://api.ipify.org 2>/dev/null | tr -d '[:space:]') || ip=""
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || ip=$(curl -4 -fsS --connect-timeout 4 -m 6 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]') || ip=""
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || ip=""
  if [[ -z $ip ]]; then
    ip=$(curl -6 -fsS --connect-timeout 4 -m 6 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]') || ip=""
    [[ $ip == *:* ]] || ip=""
  fi
  printf '%s' "$ip"
}
nat_virt_ask() { [[ $VIRT =~ ^(lxc|lxc-libvirt|openvz)$ ]]; }  # 需要询问是否 NAT 的容器类型
# 仅按本机信息（不联网）判断的倾向：用于菜单标题
nat_guess_local() {
  [[ ${OS_ID:-$(osr_get ID)} == alpine ]] && return 0
  [[ -n $VIRT ]] || detect_virt
  nat_virt_ask || return 1
  # 网卡上没有任何公网 IPv4 → 多半是 NAT
  ! local_addrs | grep -Evq '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|169\.254\.|::1$|fe80:|f[cd][0-9a-f]{2}:|[^.:]*$)'
}
nat_pref_text() { case $NAT_PREF in on) echo 开 ;; off) echo 关 ;; *) echo 自动 ;; esac; }
nat_mode_label() { # 菜单标题：普通 / NAT（自动检测）/ NAT（手动）
  local pend=""
  if (( INSTALLED )) && [[ $NAT_PREF == on && $NAT_MODE != 1 || $NAT_PREF == off && $NAT_MODE == 1 ]]; then pend="，重新安装后生效"; fi
  case $NAT_PREF in
    on) echo "NAT（手动${pend}）" ;;
    off) echo "普通（手动${pend}）" ;;
    *) if (( INSTALLED )); then
         if (( NAT_MODE )); then echo "NAT（自动检测）"; else echo "普通"; fi
       elif nat_guess_local; then echo "NAT（自动检测）"
       else echo "普通"; fi ;;
  esac
}
# 优先级：--nat/--no-nat > 菜单手动设置（NAT_PREF） > Alpine 强制 NAT > 已安装的模式 > 自动检测（LXC/OpenVZ 询问）
decide_nat_mode() {
  local want="" src=""
  if [[ -n $OPT_NAT ]]; then want=$OPT_NAT src=cli
    # 命令行与菜单手动设置冲突时，以命令行为准并同步保存，避免之后的菜单操作按旧设置走
    if [[ $NAT_PREF == on && $OPT_NAT == 0 ]]; then NAT_PREF=off; info "命令行 --no-nat 覆盖菜单中的 NAT 模式设置（已改为：关）。"
    elif [[ $NAT_PREF == off && $OPT_NAT == 1 ]]; then NAT_PREF=on; info "命令行 --nat 覆盖菜单中的 NAT 模式设置（已改为：开）。"; fi
  elif [[ $NAT_PREF == on ]]; then want=1 src=manual
  elif [[ $NAT_PREF == off ]]; then want=0 src=manual
  fi
  if [[ $OS_ID == alpine ]]; then
    if [[ $want == 0 ]]; then
      printf '%s[错误]%s Alpine（musl + OpenRC）只支持 NAT / 精简模式，不能使用普通模式（%s）。\n' "$C_RED" "$C_NONE" "$([[ $src == cli ]] && echo '去掉 --no-nat' || echo '请在菜单 15 中把 NAT 模式改为「自动」或「开」')" >&2
      printf '        Alpine 请使用: bash proxy.sh --nat（自动安装: bash proxy.sh --nat --auto --nat-ports 公网端口[:内部端口]）；或落地机: bash proxy.sh --land\n' >&2
      exit 1
    fi
    if [[ -z $want ]]; then
      want=1 src=alpine
      info "Alpine（musl + OpenRC）只支持 NAT / 精简模式：已自动启用 NAT 模式（公网端口 → 内部端口映射；直接下载官方二进制、OpenRC 服务、不装防火墙/fail2ban，网络调优会先询问）。"
    fi
  fi
  if [[ -z $want ]] && { (( INSTALLED )) || [[ $NAT_MODE == 1 ]]; }; then
    want=$([[ $NAT_MODE == 1 ]] && echo 1 || echo 0) src=state
  fi
  if [[ -z $want ]]; then
    detect_virt
    if nat_virt_ask; then
      local pub def=n why
      pub=$(nat_probe_pubip)
      if [[ -z $pub ]]; then why="无法获取公网 IP"
      elif ip_is_local "$pub"; then why="公网 IP ${pub} 配置在本机网卡上，多半不是 NAT"
      else def=y why="公网 IP ${pub} 不在本机网卡上（本机: $(local_addrs | grep -Ev '^(127\.|::1$|fe80:)' | head -n 3 | tr '\n' ' ')），多半是 NAT"; fi
      info "检测到 ${VIRT} 容器：${why}。"
      if (( OPT_AUTO )); then
        want=$([[ $def == y ]] && echo 1 || echo 0) src=detect
        info "自动模式：$([[ $want == 1 ]] && echo '按 NAT 模式安装（如判断有误请加 --no-nat）' || echo '按普通模式安装（NAT 机请加 --nat）')。"
      else
        if confirm "是否为 NAT 机（只有服务商映射的端口可用）？" "$def"; then want=1; else want=0; fi
        src=auto
      fi
    else
      want=0 src=auto
    fi
  fi
  NAT_MODE=$want NAT_SRC=$src
  return 0
}
# 已安装的模式与菜单手动设置不一致时（例如刚切换了 NAT 模式）：提示重新安装
nat_pref_mismatch() {
  (( INSTALLED )) || return 1
  [[ $NAT_PREF == on && $NAT_MODE != 1 || $NAT_PREF == off && $NAT_MODE == 1 ]]
}
nat_pref_guard() { # 端口等操作前调用；不一致时询问是否立即重新安装，返回 1 表示调用方不要继续
  nat_pref_mismatch || return 0
  warn "当前已安装为$( ((NAT_MODE)) && echo ' NAT ' || echo '普通')模式，但菜单中的 NAT 模式设置为「$(nat_pref_text)」。切换模式需要重新安装（保留密钥 / UUID）。"
  if (( ! OPT_AUTO )) && confirm "是否现在重新安装以切换模式？" y; then
    OPT_LAND=$( ((LAND_MODE)) && echo 1 || echo 0 ); do_install
  else
    info "未修改。可在菜单 $( ((LAND_MODE)) && echo 11 || echo 15) 改回「自动」，或用菜单 1$( ((LAND_MODE)) || echo ' / 13') 重新安装。"
  fi
  return 1
}
menu_nat_pref() {
  load_state
  [[ -n $OS_ID ]] || OS_ID=$(osr_get ID); OS_ID=${OS_ID,,}
  echo; hr; _green "  切换 NAT 模式（当前: $(nat_pref_text)，模式: $(nat_mode_label)）"; hr
  echo "   1) 自动：Alpine 强制 NAT；LXC/OpenVZ 容器安装时询问（公网 IP 不在本机网卡上默认「是」）；已安装的沿用原模式"
  echo "   2) 开：强制 NAT 映射端口流程（公网端口 → 内部端口），等同 --nat"
  echo "   3) 关：强制普通模式（直接监听端口），等同 --no-nat$([[ $OS_ID == alpine ]] && echo "  ${C_YELLOW}[Alpine 不可用]${C_NONE}")"
  echo "   0) 返回"
  local c def new
  case $NAT_PREF in on) def=2 ;; off) def=3 ;; *) def=1 ;; esac
  ask c "请选择" "$def"
  case $c in 1) new=auto ;; 2) new=on ;; 3) new=off ;; *) return 0 ;; esac
  if [[ $new == off && $OS_ID == alpine ]]; then warn "Alpine（musl + OpenRC）只支持 NAT / 精简模式，不能切换为普通模式。"; return 0; fi
  NAT_PREF=$new
  save_state
  ok "NAT 模式设置已保存：$(nat_pref_text)（模式: $(nat_mode_label)）"
  if nat_pref_mismatch; then
    nat_pref_guard || true
  elif (( ! INSTALLED )); then
    info "将在安装时生效：菜单 1（Reality / Hysteria2）或 13（落地机）。"
  fi
  return 0
}

# 直接从 GitHub Releases 下载二进制（NAT 模式或 Alpine）
direct_mode() { (( NAT_MODE )) || (( ${LAND_MODE:-0} )) || [[ $OS_ID == alpine ]]; }

# 虚拟化类型：kvm / lxc / openvz / docker / podman / none ...
detect_virt() {
  local v=""
  if have systemd-detect-virt; then v=$(systemd-detect-virt 2>/dev/null || true); fi
  if [[ -z $v || $v == none ]]; then
    if [[ -f /proc/user_beancounters ]] || { [[ -d /proc/vz ]] && [[ ! -d /proc/bc ]]; }; then v=openvz
    elif grep -qa 'container=lxc' /proc/1/environ 2>/dev/null || grep -qE '/lxc/|lxc\.payload' /proc/1/cgroup 2>/dev/null; then v=lxc
    elif [[ -f /run/.containerenv ]]; then v=podman
    elif [[ -f /.dockerenv ]]; then v=docker
    elif grep -qaE 'container=' /proc/1/environ 2>/dev/null; then v=container-other
    elif [[ -d /proc/xen ]]; then v=xen
    elif [[ -r /sys/class/dmi/id/sys_vendor ]] && grep -qiE 'qemu|kvm|vmware|microsoft|xen|virtualbox|amazon|google|alibaba|tencent' /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null; then v=vm
    elif grep -qw hypervisor /proc/cpuinfo 2>/dev/null; then v=vm
    else v=none; fi
  fi
  VIRT=$v
}
is_container() { [[ $VIRT =~ ^(lxc|lxc-libvirt|openvz|docker|podman|rkt|systemd-nspawn|wsl|container-other|proot|pouch)$ ]]; }

sysval() { sysctl -n "$1" 2>/dev/null || echo "-"; }
kernel_ge() { ver_ge "$(uname -r | cut -d- -f1)" "$1"; }

detect_ip() {
  local u
  PUBLIC_IP4="" PUBLIC_IP6=""
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip https://ipinfo.io/ip https://4.ipw.cn; do
    PUBLIC_IP4=$(curl -4 -fsS --connect-timeout 5 -m 8 "$u" 2>/dev/null | tr -d '[:space:]') || true
    [[ $PUBLIC_IP4 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && break
    PUBLIC_IP4=""
  done
  for u in https://api64.ipify.org https://ipv6.icanhazip.com https://6.ipw.cn; do
    PUBLIC_IP6=$(curl -6 -fsS --connect-timeout 4 -m 6 "$u" 2>/dev/null | tr -d '[:space:]') || true
    [[ $PUBLIC_IP6 == *:* ]] && break
    PUBLIC_IP6=""
  done
  NO_V4=0
  [[ -z $PUBLIC_IP4 && -n $PUBLIC_IP6 ]] && NO_V4=1
  if (( NAT_MODE && NO_V4 )); then IPFAM=6; FETCH_IP=(-6); fi
  if [[ -z $PUBLIC_IP4 && -z $PUBLIC_IP6 ]]; then
    PUBLIC_IP4=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true
    [[ -n $PUBLIC_IP4 ]] || die "无法获取本机公网 IP，请检查网络连接。"
    warn "无法通过外部服务获取公网 IP，使用本地地址 ${PUBLIC_IP4}（NAT 机器请手动修改链接中的地址）。"
  fi
}

detect_geo() {
  local j="" ip=${PUBLIC_IP4:-$PUBLIC_IP6}
  GEO_CC="" GEO_REGION="" GEO_CITY="" GEO_ORG=""
  j=$(curl -fsS --connect-timeout 5 -m 8 "https://ipinfo.io/${ip}/json" 2>/dev/null) || true
  if [[ -n $j ]] && jq -e '.country' >/dev/null 2>&1 <<<"$j"; then
    GEO_CC=$(jq -r '.country // ""' <<<"$j"); GEO_REGION=$(jq -r '.region // ""' <<<"$j")
    GEO_CITY=$(jq -r '.city // ""' <<<"$j"); GEO_ORG=$(jq -r '.org // ""' <<<"$j")
  else
    j=$(curl -fsS --connect-timeout 5 -m 8 "http://ip-api.com/json/${ip}?fields=status,countryCode,region,regionName,city,as" 2>/dev/null) || true
    if [[ -n $j ]] && [[ $(jq -r '.status // ""' <<<"$j" 2>/dev/null) == success ]]; then
      GEO_CC=$(jq -r '.countryCode' <<<"$j"); GEO_REGION=$(jq -r '.regionName' <<<"$j")
      GEO_CITY=$(jq -r '.city' <<<"$j"); GEO_ORG=$(jq -r '.as' <<<"$j")
    else
      j=$(curl -fsS --connect-timeout 5 -m 8 "https://ipapi.co/${ip}/json/" 2>/dev/null) || true
      if [[ -n $j ]] && jq -e '.country_code' >/dev/null 2>&1 <<<"$j"; then
        GEO_CC=$(jq -r '.country_code // ""' <<<"$j"); GEO_REGION=$(jq -r '.region // ""' <<<"$j")
        GEO_CITY=$(jq -r '.city // ""' <<<"$j"); GEO_ORG="$(jq -r '.asn // ""' <<<"$j") $(jq -r '.org // ""' <<<"$j")"
      fi
    fi
  fi
  GEO_CC=${GEO_CC^^}
  [[ -n $GEO_CC ]] || warn "无法获取 IP 地理位置信息，SNI 优选将测试全部候选。"
}

mem_mb() { awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo; }
swap_mb() { awk '/^SwapTotal:/{printf "%d", $2/1024}' /proc/meminfo; }
# 实际可用内存上限（容器内取 cgroup 限制与 /proc/meminfo 的较小值）
mem_limit_mb() {
  local m c=""
  m=$(mem_mb)
  if [[ -r /sys/fs/cgroup/memory.max ]]; then c=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then c=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null); fi
  if [[ $c =~ ^[0-9]+$ ]]; then c=$(( c / 1048576 )); (( c > 0 && c < m )) && m=$c; fi
  printf '%s' "$m"
}
# 低内存（< 256MB）时为 Go 程序设置 GOMEMLIMIT / GOGC，输出 "KEY=VAL" 行。
# 总预算约为内存上限的 60%。只开 Hysteria2 时由 xray / hysteria 平分（与旧版相同）；
# 另外启用了 sing-box（TUIC / AnyTLS）时再多算一份（软限制，超出时只是更积极地 GC）
go_mem_env() {
  local m n=1; m=$(mem_limit_mb)
  (( m > 0 && m < 256 )) || return 0
  (( HY2_ENABLED )) && n=$((n + 1))
  sb_needed && n=$((n + 1))
  local lim=$(( m * 60 / 100 / n )); (( lim < 24 )) && lim=24
  printf 'GOMEMLIMIT=%sMiB\nGOGC=50\n' "$lim"
}

show_sysinfo() {
  hr
  printf '  系统:     %s (%s)\n' "$OS_NAME" "$ARCH"
  printf '  内核:     %s\n' "$(uname -r)"
  printf '  内存:     %s MB   Swap: %s MB\n' "$(mem_limit_mb)" "$(swap_mb)"
  printf '  虚拟化:   %s   init: %s\n' "${VIRT:-未知}" "${INIT_SYS:-未知}"
  printf '  IPv4:     %s\n' "${PUBLIC_IP4:-无}"
  printf '  IPv6:     %s\n' "${PUBLIC_IP6:-无（不影响使用）}"
  (( NO_V4 )) && printf '  %s注意:     无 IPv4 出口（IPv6-only / NAT64）%s\n' "$C_YELLOW" "$C_NONE"
  printf '  位置:     %s %s %s\n' "${GEO_CC:-未知}" "${GEO_REGION}" "${GEO_CITY}"
  printf '  ASN:      %s\n' "${GEO_ORG:-未知}"
  hr
}

ensure_swap() {
  local mem swap
  mem=$(mem_mb); swap=$(swap_mb)
  if (( mem < 1000 && swap == 0 )); then
    info "内存小于 1G 且无 Swap，创建 1G Swap 文件 /swapfile ..."
    if [[ -e /swapfile ]]; then warn "/swapfile 已存在，跳过创建。"; return 0; fi
    if ! { { fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none; } &&
           chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile 2>/dev/null; }; then
      warn "Swap 启用失败（容器/某些虚拟化不支持），已跳过。"; rm -f /swapfile; return 0
    fi
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
    SWAP_CREATED=1
    ok "已创建并启用 1G Swap。"
  fi
}

pkg_update_upgrade() {
  if [[ $PKG == apk ]]; then
    info "更新软件包索引 (apk update) ..."
    apk update >/dev/null || warn "apk update 失败，继续尝试。"
    if (( OPT_UPGRADE )); then
      info "升级系统软件包 (apk upgrade) ..."
      apk upgrade --no-cache >/dev/null || warn "系统升级出现问题，继续安装。"
    fi
  elif [[ $PKG == apt ]]; then
    info "更新软件包索引 (apt-get update) ..."
    apt-get update -qq || apt-get update
    if (( OPT_UPGRADE )); then
      info "升级系统软件包 (apt-get upgrade)，可能需要几分钟 ..."
      apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade >/dev/null ||
        warn "系统升级出现问题，继续安装。"
    fi
  else
    info "刷新软件包缓存 (dnf makecache) ..."
    dnf -y -q makecache >/dev/null || true
    if (( OPT_UPGRADE )); then
      info "升级系统软件包 (dnf upgrade)，可能需要几分钟 ..."
      dnf -y -q upgrade >/dev/null || warn "系统升级出现问题，继续安装。"
    fi
  fi
}

pkg_install() { # 必需包，失败则退出
  if [[ $PKG == apk ]]; then
    apk add --no-cache "$@" >/dev/null
  elif [[ $PKG == apt ]]; then
    apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install --no-install-recommends "$@" >/dev/null
  else
    dnf -y -q --setopt=install_weak_deps=False install "$@" >/dev/null
  fi
}
pkg_try() { # 可选包，逐个安装，失败只警告
  local p
  for p in "$@"; do pkg_install "$p" 2>/dev/null || warn "可选组件 ${p} 安装失败，已跳过。"; done
}

install_deps() {
  step "安装依赖"
  if (( NAT_MODE )); then install_deps_nat; return; fi
  if [[ $PKG == apt ]]; then
    pkg_install ca-certificates curl openssl nftables jq unzip tar iproute2 procps gawk netbase
    pkg_try qrencode fail2ban python3-systemd
  else
    if [[ $OS_ID != fedora ]] && ! rpm -q epel-release >/dev/null 2>&1; then
      info "启用 EPEL 软件源 ..."
      local major=${OS_VER%%.*}
      pkg_install epel-release 2>/dev/null ||
        pkg_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${major}.noarch.rpm" 2>/dev/null ||
        warn "EPEL 启用失败，fail2ban / qrencode 可能无法安装。"
      if have crb; then crb enable >/dev/null 2>&1 || true; fi
    fi
    # 只安装缺失的命令，避免与 curl-minimal / coreutils-single 等精简包冲突
    local need=(ca-certificates) cmd pkgname
    for cmd in curl:curl openssl:openssl nft:nftables jq:jq unzip:unzip tar:tar ss:iproute ps:procps-ng awk:gawk flock:util-linux; do
      have "${cmd%%:*}" || need+=("${cmd#*:}")
    done
    rpm -q nftables >/dev/null 2>&1 || need+=(nftables)
    pkg_install "${need[@]}"
    for pkgname in qrencode fail2ban-server python3-systemd policycoreutils; do
      rpm -q "$pkgname" >/dev/null 2>&1 || pkg_try "$pkgname"
    done
  fi
  ok "依赖安装完成。"
}

# NAT 模式：只装必需组件（不装 fail2ban；nftables 仅用于 Hysteria2 端口跳跃，可选）
install_deps_nat() {
  if [[ $PKG == apk ]]; then
    # bash/curl 必须事先安装；coreutils/grep/gawk 替换 busybox 中功能不全的同名命令
    # 磁盘很小：只装必需包（busybox 已提供其余命令）；gawk/grep 替换功能不全的 busybox 版本
    pkg_install bash ca-certificates curl openssl jq unzip iproute2 grep gawk musl-utils
    pkg_try libqrencode-tools
  elif [[ $PKG == apt ]]; then
    pkg_install ca-certificates curl openssl jq unzip iproute2 procps gawk netbase
    pkg_try qrencode
  else
    local need=(ca-certificates) cmd
    for cmd in curl:curl openssl:openssl jq:jq unzip:unzip tar:tar ss:iproute ps:procps-ng awk:gawk flock:util-linux; do
      have "${cmd%%:*}" || need+=("${cmd#*:}")
    done
    pkg_install "${need[@]}"
    [[ $OS_ID == fedora ]] || rpm -q epel-release >/dev/null 2>&1 || pkg_try epel-release
    pkg_try qrencode
  fi
  ok "依赖安装完成（$( ((NAT_MODE)) && echo "NAT ")精简模式）。"
}

# ---------- 时间同步（REALITY 对时间误差敏感，全新 DD 镜像常常没有时间同步服务） ----------
TIME_SYNC_SVCS=(systemd-timesyncd chronyd chrony ntpsec ntp ntpd openntpd)
time_sync_svc() { # 输出正在运行的时间同步服务名，没有则返回 1
  local s
  for s in "${TIME_SYNC_SVCS[@]}"; do svc_active "$s" && { printf '%s' "$s"; return 0; }; done
  return 1
}
time_synced() { have timedatectl && [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]]; }
time_sync_status() { # 供状态页显示
  local svc; svc=$(time_sync_svc) || svc=""
  if (( NAT_MODE )) && [[ -z $svc ]] && { [[ -n $VIRT ]] || detect_virt; is_container; }; then
    printf '由宿主机管理（容器 %s）' "$VIRT"; return 0
  fi
  if time_synced; then printf '%s已同步%s%s' "$C_GREEN" "$C_NONE" "${svc:+（${svc}）}"
  elif [[ -n $svc ]]; then printf '%s同步中/未同步%s（%s）' "$C_YELLOW" "$C_NONE" "$svc"
  else printf '%s未启用时间同步服务%s（重新运行安装可自动配置）' "$C_RED" "$C_NONE"; fi
}
ensure_time_sync() {
  step "时间同步（$( ((LAND_MODE)) && echo 'Shadowsocks 2022' || echo 'REALITY') 需要准确的系统时间）"
  local svc
  if svc=$(time_sync_svc); then ok "时间同步服务已在运行：${svc}"; return 0; fi
  [[ -n $VIRT ]] || detect_virt
  if is_container || { have systemd-detect-virt && systemd-detect-virt -cq 2>/dev/null; }; then
    info "容器环境（${VIRT}），系统时间由宿主机管理，跳过。当前时间 $(date '+%F %T %Z')"; return 0
  fi
  info "未检测到时间同步服务，正在安装并启用 ..."
  if [[ $PKG == apk ]]; then
    if pkg_install chrony 2>/dev/null; then
      rc-update add chronyd default >/dev/null 2>&1 || true
      rc-service chronyd start >/dev/null 2>&1 9>&- || true
    fi
  elif [[ $PKG == apt ]]; then
    if pkg_install systemd-timesyncd 2>/dev/null; then
      systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
    fi
    if ! time_sync_svc >/dev/null; then
      info "systemd-timesyncd 不可用，改用 chrony ..."
      if pkg_install chrony 2>/dev/null; then systemctl enable --now chrony >/dev/null 2>&1 || true; fi
    fi
  else
    if pkg_install chrony 2>/dev/null; then systemctl enable --now chronyd >/dev/null 2>&1 || true; fi
  fi
  have timedatectl && { timedatectl set-ntp true >/dev/null 2>&1 || true; }
  if svc=$(time_sync_svc); then
    ok "已启用时间同步服务：${svc}（当前时间 $(date '+%F %T %Z')）"
  else
    warn "时间同步服务启用失败，请手动安装 chrony 或 systemd-timesyncd；系统时间误差过大会导致 REALITY 连接失败。"
  fi
  return 0
}

preflight() {
  step "环境检测"
  require_root
  detect_os
  openrc_ready
  have curl || pkg_bootstrap_curl
  decide_nat_mode
  [[ $ARCH == armv7 ]] && ! direct_mode && die "不支持的 CPU 架构: $(uname -m)（普通模式仅支持 amd64 / arm64；armv7 请使用 --nat）"
  info "系统: ${OS_NAME} / 架构: ${ARCH} / 包管理: ${PKG} / init: ${INIT_SYS} / 模式: $( ((NAT_MODE)) && echo NAT || echo 普通)$(case $NAT_SRC in cli) echo '（命令行指定）' ;; manual) echo '（菜单手动设置）' ;; alpine) echo '（Alpine 强制）' ;; state) echo '（沿用已安装）' ;; auto|detect) ((NAT_MODE)) && echo '（自动检测）' ;; esac)"
}
pkg_bootstrap_curl() {
  if [[ $PKG == apk ]]; then apk add --no-cache curl ca-certificates >/dev/null
  elif [[ $PKG == apt ]]; then apt-get update -qq && pkg_install curl ca-certificates; else pkg_install curl ca-certificates; fi
}

