#!/usr/bin/env bash
#
# proxy.sh —— VLESS + REALITY + Vision (ML-DSA-65) & Hysteria2 一键安装 / 管理脚本
#
# 用法:
#   bash proxy.sh                 # 交互式菜单
#   bash proxy.sh --auto          # 全部默认值自动安装
#   bash proxy.sh --help          # 查看全部参数
# 安装完成后可直接使用命令: proxy
#
# 支持: Debian 11/12/13, Ubuntu 20.04+, Rocky/Alma/CentOS Stream 8/9(+), RHEL, Fedora (systemd, amd64/arm64)
#
# shellcheck disable=SC2317  # 通过 trap / 菜单间接调用的函数

set -o errexit -o pipefail -o errtrace
umask 022
export LC_ALL=C.UTF-8 2>/dev/null || true
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

readonly SCRIPT_VERSION="1.0.1"
# 发布后请把这里改成你仓库的 raw 地址（用于 `proxy update-script` 及 bash <(curl ...) 安装时自我安装）
readonly SCRIPT_URL="https://raw.githubusercontent.com/harennie/oneclick-proxy/main/proxy.sh"

# ----------------------------- 路径 -----------------------------
readonly STATE_DIR="/root/.proxy-oneclick"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly USERS_FILE="${STATE_DIR}/users.txt"
readonly BACKUP_DIR="${STATE_DIR}/backup"
readonly INFO_FILE="/root/proxy-info.txt"
readonly BIN_PATH="/usr/local/bin/proxy"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONF="/usr/local/etc/xray/config.json"
readonly HY_BIN="/usr/local/bin/hysteria"
readonly HY_DIR="/etc/hysteria"
readonly HY_CONF="${HY_DIR}/config.yaml"
readonly HY_CRT="${HY_DIR}/server.crt"
readonly HY_KEY="${HY_DIR}/server.key"
readonly FW_FILE="${STATE_DIR}/firewall.nft"
readonly FW_UNIT="/etc/systemd/system/proxy-oneclick-fw.service"
readonly SYSCTL_FILE="/etc/sysctl.d/99-proxy-tune.conf"
readonly LIMITS_FILE="/etc/security/limits.d/99-proxy-tune.conf"
readonly SYSTEMD_LIMITS_FILE="/etc/systemd/system.conf.d/99-proxy-tune.conf"
readonly JOURNALD_FILE="/etc/systemd/journald.conf.d/99-proxy-tune.conf"
readonly F2B_JAIL="/etc/fail2ban/jail.d/99-proxy-sshd.local"
readonly SCANNER_BIN="/usr/local/share/proxy-oneclick/RealiTLScanner"
readonly XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
readonly HY_INSTALL_URL="https://get.hy2.sh/"
readonly SCANNER_VER="v0.2.3"
readonly NFT_TABLE="proxy_oneclick"
readonly UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36"

# ----------------------------- 默认值 / 运行参数 -----------------------------
OPT_AUTO=0
OPT_SNI=""
OPT_FORCE_SNI=0
OPT_PORT=""
OPT_HY2=""          # 空=询问(交互)/默认启用(auto); 1/0
OPT_HY2_PORT=""
OPT_HOP=""          # "20000-50000" 或 "none"
OPT_FIREWALL=1
OPT_UPGRADE=1
OPT_TUNE=1
OPT_SCAN=0
OPT_NAME=""
OPT_ACTION=""

# 运行时变量（部分持久化到 STATE_FILE）
OS_ID="" OS_VER="" OS_NAME="" PKG="" ARCH=""
PUBLIC_IP4="" PUBLIC_IP6="" GEO_CC="" GEO_REGION="" GEO_CITY="" GEO_ORG=""
TMP_DIR=""

# ----------------------------- 输出 -----------------------------
if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_GREEN=$'\e[92m' C_YELLOW=$'\e[93m' C_BLUE=$'\e[94m' C_CYAN=$'\e[96m' C_MAG=$'\e[95m' C_BOLD=$'\e[1m' C_NONE=$'\e[0m'
else
  C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_MAG="" C_BOLD="" C_NONE=""
fi
_red()    { printf '%s%s%s\n' "$C_RED" "$*" "$C_NONE"; }
_green()  { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_NONE"; }
_yellow() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_NONE"; }
_cyan()   { printf '%s%s%s\n' "$C_CYAN" "$*" "$C_NONE"; }
info()  { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_NONE" "$*"; }
ok()    { printf '%s[完成]%s %s\n' "$C_GREEN" "$C_NONE" "$*"; }
warn()  { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_NONE" "$*" >&2; }
die()   { printf '%s[错误]%s %s\n' "$C_RED" "$C_NONE" "$*" >&2; exit 1; }
step()  { printf '\n%s==>%s %s%s%s\n' "$C_MAG" "$C_NONE" "$C_BOLD" "$*" "$C_NONE"; }
hr()    { printf '%s\n' "------------------------------------------------------------"; }

on_error() {
  local rc=$? line=$1 cmd=$2
  trap - ERR
  printf '\n%s[错误]%s 脚本在第 %s 行执行失败 (退出码 %s)：\n    %s\n' "$C_RED" "$C_NONE" "$line" "$rc" "$cmd" >&2
  printf '%s如需帮助，请带上以上信息及 journalctl -xe 输出反馈。重新运行本脚本是安全的（幂等）。%s\n' "$C_YELLOW" "$C_NONE" >&2
  exit "$rc"
}
cleanup() { [[ -n ${TMP_DIR} && -d ${TMP_DIR} ]] && rm -rf "${TMP_DIR}"; return 0; }
trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT
trap 'printf "\n"; die "已被用户中断。"' INT TERM

# ----------------------------- 交互 -----------------------------
TTY_EOF=0
_tty_read() { # _tty_read VAR prompt   （读取失败/EOF 时设置 TTY_EOF=1）
  local __tr_var=$1 __tr_prompt=$2 __tr_ans=""
  if [[ -t 0 ]]; then
    read -r -p "$__tr_prompt" __tr_ans || TTY_EOF=1
  elif ! { read -r -p "$__tr_prompt" __tr_ans </dev/tty; } 2>/dev/null; then
    # 没有可用终端（例如自动化测试）：从标准输入读取
    read -r __tr_ans || TTY_EOF=1
  fi
  printf -v "$__tr_var" '%s' "$__tr_ans"
}
# ask VAR "提示" "默认值"
ask() {
  local __var=$1 __prompt=$2 __def=${3-} __ans=""
  if (( OPT_AUTO )); then printf -v "$__var" '%s' "$__def"; return 0; fi
  if [[ -n $__def ]]; then
    _tty_read __ans "${C_CYAN}${__prompt}${C_NONE} [默认: ${__def}]: "
  else
    _tty_read __ans "${C_CYAN}${__prompt}${C_NONE}: "
  fi
  [[ -z $__ans ]] && __ans=$__def
  printf -v "$__var" '%s' "$__ans"
}
# confirm "提示" y|n  -> 返回 0 表示 yes
confirm() {
  local prompt=$1 def=${2:-y} ans=""
  if (( OPT_AUTO )); then [[ $def == y ]]; return; fi
  local hint="[Y/n]"; [[ $def == n ]] && hint="[y/N]"
  _tty_read ans "${C_CYAN}${prompt}${C_NONE} ${hint}: "
  ans=${ans:-$def}
  [[ $ans =~ ^[Yy]([Ee][Ss])?$ ]]
}
pause() { (( OPT_AUTO )) && return 0; local _x; _tty_read _x "按回车键继续..."; }

# ----------------------------- 工具函数 -----------------------------
have() { command -v "$1" >/dev/null 2>&1; }
mktmp() { [[ -n $TMP_DIR && -d $TMP_DIR ]] || TMP_DIR=$(mktemp -d /tmp/proxy-oneclick.XXXXXX); }
is_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
is_range() { # 20000-50000
  [[ $1 =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
  local a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
  is_port "$a" && is_port "$b" && (( a < b ))
}
urlencode() {
  local s=$1 out="" c i
  local LC_ALL=C
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    case $c in
      [a-zA-Z0-9.~_-]) out+=$c ;;
      *) printf -v c '%%%02X' "'$c"; out+=$c ;;
    esac
  done
  printf '%s' "$out"
}
rand_hex() { openssl rand -hex "$1"; }
rand_pass() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-24; }
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }
fetch() { curl -fsSL --connect-timeout 10 --retry 2 --retry-delay 2 "$@"; }
svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
host_fmt() { [[ $1 == *:* ]] && printf '[%s]' "$1" || printf '%s' "$1"; }

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户运行本脚本（例如: sudo -i 后再执行）。"; }

take_lock() {
  have flock || return 0
  exec 9>/run/proxy-oneclick.lock
  flock -n 9 || die "另一个 proxy 脚本实例正在运行，请稍后再试。"
}

# ----------------------------- 状态持久化 -----------------------------
# 持久化的键
STATE_KEYS=(INSTALLED XRAY_PORT UUID PRIV_KEY PUB_KEY SHORT_ID MLDSA_SEED MLDSA_VERIFY SNI SNI_TARGET
            HY2_ENABLED HY2_PORT HY2_PASS HY2_PIN HOP_RANGE NODE_NAME FW_ENABLED SSH_PORTS
            EXTRA_TCP EXTRA_UDP DISABLED_FW SWAP_CREATED SERVER_ADDR)
INSTALLED=0 XRAY_PORT=443 UUID="" PRIV_KEY="" PUB_KEY="" SHORT_ID="" MLDSA_SEED="" MLDSA_VERIFY="" SNI="" SNI_TARGET=""
HY2_ENABLED=1 HY2_PORT=443 HY2_PASS="" HY2_PIN="" HOP_RANGE="20000-50000" NODE_NAME="" FW_ENABLED=1 SSH_PORTS=""
EXTRA_TCP="" EXTRA_UDP="" DISABLED_FW="" SWAP_CREATED=0 SERVER_ADDR=""

load_state() {
  [[ -f $STATE_FILE ]] || return 0
  local line k v
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^([A-Z0-9_]+)=(.*)$ ]] || continue
    k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
    local known=0 key
    for key in "${STATE_KEYS[@]}"; do [[ $key == "$k" ]] && known=1 && break; done
    (( known )) || continue
    # 值以 printf %q 格式保存，这里只允许安全字符集后再还原
    if [[ $v =~ ^\'(.*)\'$ ]]; then v=${BASH_REMATCH[1]}; fi
    printf -v "$k" '%s' "$v"
  done <"$STATE_FILE"
}
save_state() {
  mkdir -p "$STATE_DIR" "$BACKUP_DIR"; chmod 700 "$STATE_DIR" "$BACKUP_DIR"
  local k tmp="${STATE_FILE}.tmp"
  : >"$tmp"; chmod 600 "$tmp"
  for k in "${STATE_KEYS[@]}"; do
    local v=${!k-}
    [[ $v == *$'\n'* || $v == *"'"* ]] && die "内部错误: 状态值 $k 含非法字符"
    printf "%s='%s'\n" "$k" "$v" >>"$tmp"
  done
  mv -f "$tmp" "$STATE_FILE"
}

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

  if [[ ! -d /run/systemd/system ]] || ! have systemctl; then
    refuse_os "当前系统未使用 systemd 作为 init（${OS_NAME}），本脚本不支持（例如 OpenVZ/LXC 精简容器、Alpine/OpenRC）。"
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
      refuse_os "不支持 Alpine（musl + OpenRC）。" ;;
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
    *) die "不支持的 CPU 架构: $(uname -m)（仅支持 amd64 / arm64）" ;;
  esac
}

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

show_sysinfo() {
  hr
  printf '  系统:     %s (%s)\n' "$OS_NAME" "$ARCH"
  printf '  内核:     %s\n' "$(uname -r)"
  printf '  内存:     %s MB   Swap: %s MB\n' "$(mem_mb)" "$(swap_mb)"
  printf '  IPv4:     %s\n' "${PUBLIC_IP4:-无}"
  printf '  IPv6:     %s\n' "${PUBLIC_IP6:-无（不影响使用）}"
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
  if [[ $PKG == apt ]]; then
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
  if [[ $PKG == apt ]]; then
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

# ---------- 时间同步（REALITY 对时间误差敏感，全新 DD 镜像常常没有时间同步服务） ----------
TIME_SYNC_SVCS=(systemd-timesyncd chronyd chrony ntpsec ntp ntpd openntpd)
time_sync_svc() { # 输出正在运行的时间同步服务名，没有则返回 1
  local s
  for s in "${TIME_SYNC_SVCS[@]}"; do svc_active "$s" && { printf '%s' "$s"; return 0; }; done
  return 1
}
time_synced() { [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]]; }
time_sync_status() { # 供状态页显示
  local svc; svc=$(time_sync_svc) || svc=""
  if time_synced; then printf '%s已同步%s%s' "$C_GREEN" "$C_NONE" "${svc:+（${svc}）}"
  elif [[ -n $svc ]]; then printf '%s同步中/未同步%s（%s）' "$C_YELLOW" "$C_NONE" "$svc"
  else printf '%s未启用时间同步服务%s（重新运行安装可自动配置）' "$C_RED" "$C_NONE"; fi
}
ensure_time_sync() {
  step "时间同步（REALITY 需要准确的系统时间）"
  local svc
  if svc=$(time_sync_svc); then ok "时间同步服务已在运行：${svc}"; return 0; fi
  if systemd-detect-virt -cq 2>/dev/null; then
    info "容器环境，系统时间由宿主机管理，跳过。"; return 0
  fi
  info "未检测到时间同步服务，正在安装并启用 ..."
  if [[ $PKG == apt ]]; then
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
  timedatectl set-ntp true >/dev/null 2>&1 || true
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
  have curl || pkg_bootstrap_curl
  info "系统: ${OS_NAME} / 架构: ${ARCH} / 包管理: ${PKG}"
}
pkg_bootstrap_curl() {
  if [[ $PKG == apt ]]; then apt-get update -qq && pkg_install curl ca-certificates; else pkg_install curl ca-certificates; fi
}

# ============================================================
#                        系统调优
# ============================================================
apply_tuning() {
  step "系统网络调优（保守参数，不更换内核）"
  local bbr=0
  if kernel_ge 4.9; then
    modprobe tcp_bbr 2>/dev/null || true
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || [[ -d /sys/module/tcp_bbr ]]; then bbr=1; fi
  fi
  mkdir -p "$(dirname "$SYSCTL_FILE")"
  {
    echo "# 由 proxy-oneclick 生成，卸载时会删除"
    if (( bbr )); then
      echo "net.core.default_qdisc = fq"
      echo "net.ipv4.tcp_congestion_control = bbr"
    fi
    cat <<'SYSCTL'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
fs.file-max = 1048576
fs.nr_open = 1048576
SYSCTL
  } >"$SYSCTL_FILE"
  if (( SWAP_CREATED )); then echo "vm.swappiness = 10" >>"$SYSCTL_FILE"; fi
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || warn "部分 sysctl 参数未能生效（容器/受限虚拟化中属正常）。"

  mkdir -p "$(dirname "$LIMITS_FILE")" "$(dirname "$SYSTEMD_LIMITS_FILE")" "$(dirname "$JOURNALD_FILE")"
  printf '%s\n' "# proxy-oneclick" "* soft nofile 1048576" "* hard nofile 1048576" "root soft nofile 1048576" "root hard nofile 1048576" >"$LIMITS_FILE"
  printf '%s\n' "# proxy-oneclick" "[Manager]" "DefaultLimitNOFILE=1048576" >"$SYSTEMD_LIMITS_FILE"
  printf '%s\n' "# proxy-oneclick" "[Journal]" "SystemMaxUse=100M" "RuntimeMaxUse=50M" >"$JOURNALD_FILE"
  systemctl daemon-reexec >/dev/null 2>&1 || true
  systemctl restart systemd-journald >/dev/null 2>&1 || true

  if (( bbr )); then
    ok "已启用 BBR + fq（当前: $(sysval net.ipv4.tcp_congestion_control) / $(sysval net.core.default_qdisc)）"
  else
    warn "内核 $(uname -r) 不支持 BBR，已跳过（仅应用缓冲区等参数）。"
  fi
  ok "调优配置已写入 ${SYSCTL_FILE}，journald 日志上限 100M。"
}

# ============================================================
#                 REALITY 目标网站 (SNI) 自动优选
# ============================================================
# 规则：与 VPS 同国家/地区（最好同城/同 ASN）；TLS1.3 + X25519 + ALPN h2 + HSTS；
#       证书链有效；不在 Cloudflare 后面；不是被墙网站/大厂默认域名。
# 候选列表按地区组织（以大学及本地中型网站为主），运行时在 VPS 上逐一实测。
sni_candidates() { # $1 = 地区键
  case $1 in
    US-CA)  echo "www.usc.edu www.ucla.edu www.caltech.edu www.csulb.edu www.csun.edu www.calstatela.edu www.cpp.edu www.ucr.edu www.uci.edu www.ucsd.edu www.sdsu.edu www.stanford.edu www.berkeley.edu www.sjsu.edu www.ucsf.edu www.ucdavis.edu www.ucsb.edu www.chapman.edu www.lmu.edu www.pepperdine.edu" ;;
    US-NW)  echo "www.washington.edu www.uw.edu www.wsu.edu www.pdx.edu www.oregonstate.edu www.uoregon.edu www.seattleu.edu www.gonzaga.edu www.unlv.edu www.unr.edu www.utah.edu www.byu.edu www.boisestate.edu" ;;
    US-SW)  echo "www.asu.edu www.arizona.edu www.nau.edu www.unm.edu www.utah.edu www.unlv.edu www.colorado.edu www.du.edu www.colostate.edu" ;;
    US-TX)  echo "www.utexas.edu www.rice.edu www.tamu.edu www.uh.edu www.smu.edu www.tcu.edu www.baylor.edu www.utdallas.edu www.unt.edu www.utsa.edu www.ou.edu www.okstate.edu" ;;
    US-OH)  echo "www.case.edu www.ohio.edu www.osu.edu www.uc.edu www.kent.edu www.miamioh.edu www.bgsu.edu www.utoledo.edu www.wright.edu www.umich.edu www.msu.edu www.wayne.edu www.purdue.edu www.iu.edu www.pitt.edu www.cmu.edu www.louisville.edu" ;;
    US-IL)  echo "www.uchicago.edu www.northwestern.edu www.uic.edu www.luc.edu www.depaul.edu www.iit.edu www.wisc.edu www.umn.edu www.wustl.edu www.slu.edu www.uiowa.edu www.ku.edu www.unl.edu" ;;
    US-EAST) echo "www.virginia.edu www.vt.edu www.gmu.edu www.jhu.edu www.umd.edu www.georgetown.edu www.gwu.edu www.american.edu www.vcu.edu www.odu.edu www.jmu.edu www.udel.edu www.unc.edu www.duke.edu www.ncsu.edu www.wm.edu" ;;
    US-NE)  echo "www.nyu.edu www.columbia.edu www.cornell.edu www.rutgers.edu www.princeton.edu www.fordham.edu www.stonybrook.edu www.rochester.edu www.syracuse.edu www.upenn.edu www.temple.edu www.drexel.edu www.bu.edu www.northeastern.edu www.tufts.edu www.brown.edu www.yale.edu www.umass.edu" ;;
    US-SE)  echo "www.gatech.edu www.emory.edu www.gsu.edu www.uga.edu www.ufl.edu www.fsu.edu www.miami.edu www.usf.edu www.ucf.edu www.fiu.edu www.vanderbilt.edu www.utk.edu www.sc.edu www.clemson.edu www.ua.edu www.tulane.edu www.lsu.edu" ;;
    CA)     echo "www.utoronto.ca www.yorku.ca www.torontomu.ca www.mcmaster.ca www.uwaterloo.ca www.queensu.ca www.uottawa.ca www.carleton.ca www.mcgill.ca www.concordia.ca www.umontreal.ca www.ulaval.ca www.ubc.ca www.sfu.ca www.uvic.ca www.ualberta.ca www.ucalgary.ca www.umanitoba.ca www.usask.ca www.dal.ca" ;;
    MX)     echo "www.unam.mx www.tec.mx www.ipn.mx www.udg.mx www.uanl.mx www.ibero.mx" ;;
    BR)     echo "www.usp.br www.unicamp.br www.ufrj.br www.unesp.br www.ufmg.br www.puc-rio.br www.ufsc.br" ;;
    JP)     echo "www.u-tokyo.ac.jp www.kyoto-u.ac.jp www.osaka-u.ac.jp www.titech.ac.jp www.isct.ac.jp www.keio.ac.jp www.waseda.jp www.tohoku.ac.jp www.nagoya-u.ac.jp www.kyushu-u.ac.jp www.hokudai.ac.jp www.tsukuba.ac.jp www.hit-u.ac.jp www.sophia.ac.jp www.meiji.ac.jp www.ritsumei.ac.jp www.doshisha.ac.jp www.kobe-u.ac.jp www.chiba-u.ac.jp www.ynu.ac.jp" ;;
    KR)     echo "www.snu.ac.kr www.kaist.ac.kr www.yonsei.ac.kr www.korea.ac.kr www.postech.ac.kr www.skku.edu www.hanyang.ac.kr www.kyunghee.ac.kr www.ewha.ac.kr www.sogang.ac.kr www.cau.ac.kr www.pusan.ac.kr www.unist.ac.kr" ;;
    HK)     echo "www.hku.hk www.cuhk.edu.hk www.hkust.edu.hk www.polyu.edu.hk www.cityu.edu.hk www.hkbu.edu.hk www.eduhk.hk www.ln.edu.hk www.hkmu.edu.hk www.hsu.edu.hk" ;;
    TW)     echo "www.ntu.edu.tw www.nthu.edu.tw www.nycu.edu.tw www.ncku.edu.tw www.nccu.edu.tw www.ntnu.edu.tw www.ncu.edu.tw www.ntust.edu.tw www.fju.edu.tw www.tku.edu.tw" ;;
    SG)     echo "www.nus.edu.sg www.ntu.edu.sg www.smu.edu.sg www.sutd.edu.sg www.suss.edu.sg www.singaporetech.edu.sg www.np.edu.sg www.sp.edu.sg www.tp.edu.sg www.rp.edu.sg" ;;
    MY)     echo "www.um.edu.my www.ukm.my www.upm.edu.my www.usm.my www.utm.my www.taylors.edu.my www.sunway.edu.my" ;;
    TH)     echo "www.chula.ac.th www.mahidol.ac.th www.ku.ac.th www.tu.ac.th www.cmu.ac.th www.kmutt.ac.th" ;;
    VN)     echo "www.hust.edu.vn www.vnu.edu.vn www.hcmus.edu.vn www.ueh.edu.vn www.fpt.edu.vn" ;;
    ID)     echo "www.ui.ac.id www.itb.ac.id www.ugm.ac.id www.binus.ac.id www.its.ac.id www.unair.ac.id" ;;
    PH)     echo "www.up.edu.ph www.ateneo.edu www.dlsu.edu.ph www.ust.edu.ph www.mapua.edu.ph" ;;
    IN)     echo "www.iitb.ac.in www.iitd.ac.in www.iitm.ac.in www.iisc.ac.in www.iitk.ac.in www.du.ac.in www.jnu.ac.in www.bits-pilani.ac.in www.amity.edu" ;;
    AU)     echo "www.sydney.edu.au www.unsw.edu.au www.uts.edu.au www.mq.edu.au www.unimelb.edu.au www.monash.edu www.rmit.edu.au www.deakin.edu.au www.anu.edu.au www.uq.edu.au www.qut.edu.au www.adelaide.edu.au www.uwa.edu.au www.griffith.edu.au" ;;
    NZ)     echo "www.auckland.ac.nz www.aut.ac.nz www.otago.ac.nz www.canterbury.ac.nz www.wgtn.ac.nz www.massey.ac.nz www.waikato.ac.nz" ;;
    DE)     echo "www.tum.de www.lmu.de www.uni-heidelberg.de www.fu-berlin.de www.hu-berlin.de www.tu-berlin.de www.kit.edu www.rwth-aachen.de www.uni-frankfurt.de www.goethe-university-frankfurt.de www.tu-darmstadt.de www.uni-mainz.de www.uni-koeln.de www.uni-bonn.de www.uni-hamburg.de www.uni-stuttgart.de www.tu-dresden.de www.uni-muenster.de www.uni-freiburg.de www.uni-goettingen.de" ;;
    NL)     echo "www.uva.nl www.vu.nl www.tudelft.nl www.uu.nl www.universiteitleiden.nl www.rug.nl www.ru.nl www.tue.nl www.utwente.nl www.eur.nl www.maastrichtuniversity.nl www.wur.nl www.tilburguniversity.edu" ;;
    GB)     echo "www.ucl.ac.uk www.imperial.ac.uk www.kcl.ac.uk www.lse.ac.uk www.qmul.ac.uk www.city.ac.uk www.westminster.ac.uk www.gre.ac.uk www.ox.ac.uk www.cam.ac.uk www.ed.ac.uk www.gla.ac.uk www.manchester.ac.uk www.leeds.ac.uk www.sheffield.ac.uk www.bristol.ac.uk www.birmingham.ac.uk www.nottingham.ac.uk www.warwick.ac.uk www.soton.ac.uk" ;;
    FR)     echo "www.sorbonne-universite.fr www.u-paris.fr www.universite-paris-saclay.fr www.psl.eu www.ens.psl.eu www.polytechnique.edu www.sciencespo.fr www.univ-lyon1.fr www.univ-grenoble-alpes.fr www.unistra.fr www.univ-amu.fr www.u-bordeaux.fr www.univ-lille.fr www.univ-tlse3.fr www.insa-lyon.fr www.centralesupelec.fr" ;;
    IE)     echo "www.tcd.ie www.ucd.ie www.dcu.ie www.tudublin.ie www.universityofgalway.ie www.ucc.ie www.ul.ie" ;;
    BE)     echo "www.kuleuven.be www.ugent.be www.uantwerpen.be www.ulb.be www.uclouvain.be www.vub.be www.uliege.be" ;;
    CH)     echo "www.ethz.ch www.epfl.ch www.uzh.ch www.unibe.ch www.unibas.ch www.unige.ch www.unil.ch www.zhaw.ch" ;;
    AT)     echo "www.univie.ac.at www.tuwien.at www.meduniwien.ac.at www.uibk.ac.at www.tugraz.at www.uni-graz.at www.jku.at" ;;
    IT)     echo "www.unimi.it www.polimi.it www.unibocconi.it www.uniroma1.it www.unibo.it www.unipd.it www.unito.it www.polito.it www.unina.it www.unifi.it" ;;
    ES)     echo "www.uam.es www.ucm.es www.upm.es www.uc3m.es www.ub.edu www.uab.cat www.upc.edu www.upf.edu www.uv.es www.us.es" ;;
    PL)     echo "www.uw.edu.pl www.pw.edu.pl www.uj.edu.pl www.agh.edu.pl www.put.poznan.pl www.pwr.edu.pl www.umk.pl" ;;
    SE)     echo "www.kth.se www.su.se www.ki.se www.uu.se www.lu.se www.chalmers.se www.gu.se www.liu.se" ;;
    FI)     echo "www.helsinki.fi www.aalto.fi www.tuni.fi www.utu.fi www.oulu.fi www.jyu.fi" ;;
    NO)     echo "www.uio.no www.ntnu.no www.uib.no www.oslomet.no www.uit.no" ;;
    DK)     echo "www.ku.dk www.dtu.dk www.au.dk www.sdu.dk www.aau.dk www.cbs.dk" ;;
    CZ)     echo "www.cuni.cz www.cvut.cz www.muni.cz www.vutbr.cz www.vse.cz" ;;
    RU)     echo "www.msu.ru www.hse.ru www.spbu.ru www.itmo.ru www.mipt.ru www.bmstu.ru" ;;
    TR)     echo "www.boun.edu.tr www.metu.edu.tr www.itu.edu.tr www.bilkent.edu.tr www.sabanciuniv.edu www.ku.edu.tr" ;;
    AE)     echo "www.uaeu.ac.ae www.ku.ac.ae www.aus.edu www.zu.ac.ae www.hct.ac.ae" ;;
    IL)     echo "www.tau.ac.il www.huji.ac.il www.technion.ac.il www.weizmann.ac.il www.bgu.ac.il" ;;
    ZA)     echo "www.uct.ac.za www.wits.ac.za www.up.ac.za www.sun.ac.za www.uj.ac.za" ;;
    *)      echo "" ;;
  esac
}

# 根据 VPS 位置返回地区键（主）与同国家其它地区键（次）
sni_region_keys() {
  local cc=$GEO_CC region=${GEO_REGION,,}
  if [[ $cc == US ]]; then
    local main
    case $region in
      california) main=US-CA ;;
      washington|oregon|idaho|nevada|montana|alaska) main=US-NW ;;
      arizona|"new mexico"|utah|colorado|wyoming) main=US-SW ;;
      texas|oklahoma|arkansas) main=US-TX ;;
      ohio|michigan|indiana|kentucky|pennsylvania|"west virginia") main=US-OH ;;
      illinois|wisconsin|minnesota|missouri|iowa|kansas|nebraska|"north dakota"|"south dakota") main=US-IL ;;
      virginia|"district of columbia"|maryland|delaware|"north carolina") main=US-EAST ;;
      "new york"|"new jersey"|massachusetts|connecticut|"rhode island"|vermont|"new hampshire"|maine) main=US-NE ;;
      georgia|florida|"south carolina"|alabama|tennessee|mississippi|louisiana) main=US-SE ;;
      *) main=US-EAST ;;
    esac
    local k others=""
    for k in US-CA US-NW US-SW US-TX US-OH US-IL US-EAST US-NE US-SE; do [[ $k == "$main" ]] || others+="$k "; done
    echo "$main|$others"
    return
  fi
  case $cc in
    UK) cc=GB ;;
    MO) cc=HK ;;
  esac
  if [[ -n $cc && -n $(sni_candidates "$cc") ]]; then
    # 邻近地区作为次选
    local near=""
    case $cc in
      JP) near="KR TW" ;; KR) near="JP" ;; HK) near="TW SG" ;; TW) near="HK JP" ;; SG) near="MY HK" ;;
      MY) near="SG" ;; TH|VN|ID|PH) near="SG" ;; IN) near="SG" ;; AU) near="NZ" ;; NZ) near="AU" ;;
      DE) near="NL AT CH" ;; NL) near="DE BE" ;; BE) near="NL FR" ;; FR) near="BE DE" ;; GB) near="IE NL" ;; IE) near="GB" ;;
      CH|AT) near="DE" ;; IT) near="CH" ;; ES) near="FR" ;; PL|CZ) near="DE" ;; SE|FI|NO|DK) near="SE FI NO DK" ;;
      CA) near="US-NE US-NW" ;; MX) near="US-TX" ;; BR) near="" ;; RU) near="FI" ;; TR) near="DE" ;;
      AE|IL|ZA) near="" ;;
    esac
    echo "$cc|$near"
  else
    echo "|US-EAST US-CA JP SG HK DE GB NL"
  fi
}

# 大厂/被墙/CDN 默认域名黑名单（按域名标签精确匹配）
SNI_BLACK_LABELS=" google googleapis gstatic googlevideo youtube ytimg gmail blogspot yahoo apple icloud mzstatic microsoft msn bing live office office365 microsoftonline azure azureedge windowsupdate xbox skype amazon amazonaws cloudfront cloudflare workers facebook fbcdn instagram whatsapp twitter twimg telegram github githubusercontent netflix nflxvideo akamai akamaized akamaihd edgekey fastly wikipedia wikimedia openai chatgpt discord tiktok bytedance speedtest paypal dropbox reddit pinterest linkedin tesla nvidia samsung "
SNI_BLACK_DOMAINS=" x.com t.co vercel.app vercel.com vercel-infra.com netlify.app herokuapp.com pages.dev workers.dev "
sni_blacklisted() {
  local h=${1,,} l
  h=${h%.}
  [[ $SNI_BLACK_DOMAINS == *" $h "* ]] && return 0
  local d
  for d in $SNI_BLACK_DOMAINS; do [[ $h == *".$d" ]] && return 0; done
  local IFS=.
  for l in $h; do [[ $SNI_BLACK_LABELS == *" $l "* ]] && return 0; done
  [[ $h == *.cn ]] && return 0
  return 1
}

CF_V4_DEFAULT="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
CF_V6_DEFAULT="2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32"
CF_V4="" CF_V6=""
load_cf_ranges() {
  [[ -n $CF_V4 ]] && return 0
  local v4 v6
  v4=$(curl -fsS --connect-timeout 5 -m 8 https://www.cloudflare.com/ips-v4 2>/dev/null | tr -d '\r' | grep -E '^[0-9.]+/[0-9]+$' | tr '\n' ' ') || true
  v6=$(curl -fsS --connect-timeout 5 -m 8 https://www.cloudflare.com/ips-v6 2>/dev/null | tr -d '\r' | grep -E '^[0-9a-fA-F:]+/[0-9]+$' | tr '\n' ' ') || true
  CF_V4=${v4:-$CF_V4_DEFAULT} CF_V6=${v6:-$CF_V6_DEFAULT}
}
ip4_to_int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a << 24) | (b << 16) | (c << 8) | d )); }
in_cf_v4() {
  local ip=$1 n cidr net bits mask
  n=$(ip4_to_int "$ip")
  for cidr in $CF_V4; do
    net=${cidr%/*} bits=${cidr#*/}
    mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    (( (n & mask) == ($(ip4_to_int "$net") & mask) )) && return 0
  done
  return 1
}
ip6_prefix32() { # 返回 IPv6 前 32 位整数
  local a=${1,,} head g1 g2
  head=${a%%::*}
  IFS=: read -r g1 g2 _ <<<"$head"
  [[ $a == *::* && $head != *:* ]] && g2=0
  echo $(( (16#${g1:-0} << 16) | 16#${g2:-0} ))
}
in_cf_v6() {
  local n cidr bits mask
  n=$(ip6_prefix32 "$1")
  for cidr in $CF_V6; do
    bits=${cidr#*/}; (( bits > 32 )) && bits=32
    mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    (( (n & mask) == ($(ip6_prefix32 "${cidr%/*}") & mask) )) && return 0
  done
  return 1
}

# 探测单个候选域名。输出一行:
#   PASS|域名|TCP延迟ms|TLS握手完成ms|IP|国家|城市|ASN
#   FAIL|域名|原因
sni_probe() {
  local host=${1,,} ip4s ip6s ip first out hdr w ver tconn tapp code best=999999 tls_ms geo cc="" city="" org=""
  host=${host%.}
  [[ $host =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || { echo "FAIL|$host|域名格式无效"; return; }
  if sni_blacklisted "$host"; then echo "FAIL|$host|大厂/被墙/CDN/国内域名（黑名单）"; return; fi
  ip4s=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u) || true
  [[ -n $ip4s ]] || { echo "FAIL|$host|无 IPv4 解析"; return; }
  for ip in $ip4s; do in_cf_v4 "$ip" && { echo "FAIL|$host|解析到 Cloudflare IP ($ip)"; return; }; done
  ip6s=$(getent ahostsv6 "$host" 2>/dev/null | awk '$1 ~ /:/ && $1 !~ /^::ffff:/ {print $1}' | sort -u) || true
  for ip in $ip6s; do in_cf_v6 "$ip" && { echo "FAIL|$host|解析到 Cloudflare IPv6 ($ip)"; return; }; done
  first=$(head -n1 <<<"$ip4s")

  out=$(timeout 12 openssl s_client -connect "${first}:443" -servername "$host" -tls1_3 -groups X25519 -alpn h2 \
        -verify_return_error -verify_hostname "$host" </dev/null 2>&1) || true
  grep -q 'TLSv1.3' <<<"$out" || { echo "FAIL|$host|不支持 TLS1.3 / X25519"; return; }
  grep -q 'ALPN protocol: h2' <<<"$out" || { echo "FAIL|$host|不支持 ALPN h2"; return; }
  grep -q 'Verify return code: 0 (ok)' <<<"$out" || { echo "FAIL|$host|证书链/域名校验失败"; return; }

  hdr=$(mktemp)
  w=$(curl -4 -sS -o /dev/null -D "$hdr" --http2 -L --max-redirs 3 --connect-timeout 5 -m 15 -A "$UA" \
        -w '%{http_version} %{time_connect} %{time_appconnect} %{http_code}' "https://${host}/" 2>/dev/null) || true
  read -r ver tconn tapp code <<<"$w"
  if [[ -z $code || $code == 000 ]]; then rm -f "$hdr"; echo "FAIL|$host|HTTPS 请求失败"; return; fi
  if grep -qiE '^(server:[[:space:]]*cloudflare|cf-ray:)' "$hdr"; then rm -f "$hdr"; echo "FAIL|$host|响应头显示使用 Cloudflare"; return; fi
  if ! grep -qi '^strict-transport-security:' "$hdr"; then rm -f "$hdr"; echo "FAIL|$host|无 HSTS 响应头"; return; fi
  rm -f "$hdr"
  [[ $ver == 2 ]] || { echo "FAIL|$host|HTTP/2 协商失败 (HTTP/$ver)"; return; }

  # 延迟：TCP 建连 (≈1 RTT) 与 TLS 握手完成时间，各取 3 次中的最小值
  local i best_tls=999999 t_ms a_ms
  for i in 0 1 2; do
    if (( i > 0 )); then
      w=$(curl -4 -sS -o /dev/null -I --http2 --connect-timeout 5 -m 8 -A "$UA" -w '%{time_connect} %{time_appconnect}' "https://${host}/" 2>/dev/null) || true
      read -r tconn tapp <<<"$w"
    fi
    t_ms=$(awk -v t="${tconn:-0}" 'BEGIN{printf "%d", t*1000}')
    a_ms=$(awk -v t="${tapp:-0}" 'BEGIN{printf "%d", t*1000}')
    (( t_ms > 0 && t_ms < best )) && best=$t_ms
    (( a_ms > 0 && a_ms < best_tls )) && best_tls=$a_ms
  done
  (( best == 999999 )) && best=0
  (( best_tls == 999999 )) && best_tls=9999
  tls_ms=$best_tls

  geo=$(curl -fsS --connect-timeout 4 -m 6 "https://ipinfo.io/${first}/json" 2>/dev/null) || true
  if [[ -n $geo ]]; then
    cc=$(jq -r '.country // ""' <<<"$geo" 2>/dev/null) || cc=""
    city=$(jq -r '.city // ""' <<<"$geo" 2>/dev/null) || city=""
    org=$(jq -r '.org // ""' <<<"$geo" 2>/dev/null | tr '|' ' ') || org=""
  fi
  echo "PASS|$host|$best|$tls_ms|$first|$cc|$city|$org"
}

# 并发测试一组域名，结果写入 $1 文件
sni_test_list() {
  local outfile=$1; shift
  local h n=0 total=$#
  mktmp
  load_cf_ranges
  local dir; dir=$(mktemp -d "${TMP_DIR}/probe.XXXX")
  for h in "$@"; do
    n=$((n + 1))
    while (( $(jobs -rp | wc -l) >= 10 )); do wait -n 2>/dev/null || true; done
    ( trap - ERR; set +e; sni_probe "$h" >"${dir}/${n}.res" 2>/dev/null ) &
    printf '\r  正在检测 %d/%d ...' "$n" "$total"
  done
  wait || true
  printf '\r%-40s\r' " "
  cat "${dir}"/*.res 2>/dev/null >"$outfile" || : >"$outfile"
}

# 排序：同国家优先，其次延迟
sni_sorted_pass() { # $1 结果文件
  awk -F'|' -v cc="$GEO_CC" '$1=="PASS"{s=($6==cc || cc=="")?0:1; print s"|"$0}' "$1" | sort -t'|' -k1,1n -k5,5n -k4,4n | cut -d'|' -f2-
}

sni_print_table() { # $1 = 已排序 PASS 列表文件, $2 = 显示条数
  local i=0 line host rtt tls ip cc city org
  printf '  %-4s %-30s %-9s %-9s %-16s %s\n' "No." "Domain(域名)" "TCP-RTT" "TLS-HS" "IP" "位置 / ASN"
  while IFS='|' read -r _ host rtt tls ip cc city org; do
    i=$((i + 1)); (( i > $2 )) && break
    local mark=""; [[ -n $GEO_CC && $cc != "$GEO_CC" ]] && mark="${C_YELLOW}(异国)${C_NONE}"
    printf '  %-4s %-30s %-9s %-9s %-16s %s %s %s\n' "$i)" "$host" "${rtt}ms" "${tls}ms" "$ip" "${cc}/${city}" "${org:0:28}" "$mark"
  done <"$1"
}

# 解析 RealiTLScanner CSV：按表头定位列，筛选 TLS1.3 + h2，去掉通配符/黑名单域名
scanner_parse() {
  local dom
  awk -F',' 'NR==1{for(i=1;i<=NF;i++){gsub(/"/,"",$i); c[$i]=i}; next}
    { tls=(c["TLS"] ? $(c["TLS"]) : "TLS 1.3"); alpn=(c["ALPN"] ? $(c["ALPN"]) : "h2"); d=$(c["CERT_DOMAIN"]); gsub(/"/,"",d)
      if (tls ~ /1\.3/ && alpn=="h2" && d !~ /^\*/ && d ~ /\./) print tolower(d) }' "$1" | sort -u |
    while read -r dom; do sni_blacklisted "$dom" || echo "$dom"; done | head -n 40
}

# 使用 RealiTLScanner 扫描 VPS 附近 IP（同 ASN / 同机房）的可用目标
scanner_collect() { # $1 输出候选列表文件
  local out=$1 url csv secs=${SCAN_SECS:-60}
  [[ -n $PUBLIC_IP4 ]] || { warn "无 IPv4，无法扫描。"; return 1; }
  if [[ ! -x $SCANNER_BIN ]]; then
    url="https://github.com/XTLS/RealiTLScanner/releases/download/${SCANNER_VER}/RealiTLScanner-linux-${ARCH}"
    info "下载 RealiTLScanner ${SCANNER_VER} ..."
    mkdir -p "$(dirname "$SCANNER_BIN")"
    fetch -o "${SCANNER_BIN}.tmp" "$url" || { warn "RealiTLScanner 下载失败。"; rm -f "${SCANNER_BIN}.tmp"; return 1; }
    chmod 755 "${SCANNER_BIN}.tmp"; mv -f "${SCANNER_BIN}.tmp" "$SCANNER_BIN"
  fi
  mktmp
  csv="${TMP_DIR}/scan.csv"
  warn "在 VPS 上扫描可能被服务商视为端口扫描（少数商家会警告），将以低并发扫描 ${secs} 秒。"
  info "正在扫描 ${PUBLIC_IP4} 附近的 IP ..."
  ( cd "$TMP_DIR" && timeout "$secs" "$SCANNER_BIN" -addr "$PUBLIC_IP4" -port 443 -thread 4 -timeout 4 -out "$csv" >/dev/null 2>&1 ) || true
  [[ -s $csv ]] || { warn "扫描未得到结果。"; return 1; }
  scanner_parse "$csv" >"$out"
  [[ -s $out ]] || { warn "扫描结果中没有符合 TLS1.3 + h2 的域名。"; return 1; }
  info "扫描得到 $(wc -l <"$out") 个候选域名，开始逐一验证 ..."
}

# 主流程：自动优选 SNI。结果写入全局 SNI
select_sni() {
  mktmp
  local keys main near cands="" k res="${TMP_DIR}/sni.res" sorted="${TMP_DIR}/sni.sorted"
  # 1) 命令行指定
  if [[ -n $OPT_SNI ]]; then
    info "验证指定的 SNI: ${OPT_SNI} ..."
    load_cf_ranges
    local r; r=$( ( trap - ERR; set +e; sni_probe "$OPT_SNI" ) )
    if [[ $r == PASS* ]]; then
      SNI=${OPT_SNI,,}; ok "SNI ${SNI} 通过检测（TLS 握手 $(cut -d'|' -f4 <<<"$r")ms）。"; return 0
    fi
    warn "SNI ${OPT_SNI} 未通过检测：$(cut -d'|' -f3 <<<"$r")"
    if (( OPT_FORCE_SNI )); then warn "已指定 --force-sni，仍然使用。"; SNI=${OPT_SNI,,}; return 0; fi
    (( OPT_AUTO )) && die "指定的 SNI 不合格。如确认要使用，请追加 --force-sni。"
  fi

  keys=$(sni_region_keys)
  main=${keys%%|*} near=${keys#*|}
  step "自动优选 REALITY 目标网站 (SNI)"
  info "VPS 位置: ${GEO_CC:-未知} ${GEO_REGION} ${GEO_CITY}  ${GEO_ORG}"
  info "筛选规则: 同地区 · TLS1.3+X25519 · ALPN h2 · HSTS · 证书有效 · 非 Cloudflare · 非大厂/被墙域名"

  if (( OPT_SCAN )); then
    local scanned="${TMP_DIR}/scan.list"
    if scanner_collect "$scanned"; then
      # shellcheck disable=SC2046
      sni_test_list "$res" $(cat "$scanned")
      sni_sorted_pass "$res" >"$sorted"
    fi
  fi
  if [[ ! -s ${sorted} ]]; then
    [[ -n $main ]] && cands=$(sni_candidates "$main")
    info "测试 ${main:-通用} 地区候选（$(wc -w <<<"$cands") 个）..."
    # shellcheck disable=SC2086
    [[ -n $cands ]] && sni_test_list "$res" $cands
    [[ -f $res ]] || : >"$res"
    sni_sorted_pass "$res" >"$sorted"
    if (( $(wc -l <"$sorted") < 3 )) && [[ -n $near ]]; then
      cands=""
      for k in $near; do cands+=" $(sni_candidates "$k")"; done
      info "本地区合格数量不足，扩大到邻近地区（$(wc -w <<<"$cands") 个）..."
      # shellcheck disable=SC2086
      sni_test_list "${res}.2" $cands
      cat "${res}.2" >>"$res"
      sni_sorted_pass "$res" >"$sorted"
    fi
  fi

  local npass; npass=$(wc -l <"$sorted")
  if (( npass == 0 )); then
    warn "没有候选域名通过全部检测。"
    awk -F'|' '$1=="FAIL"{printf "    %s: %s\n", $2, $3}' "$res" | head -n 15
    (( OPT_AUTO )) && die "自动模式下无法确定 SNI，请用 --sni 指定（或 --force-sni）。"
    manual_sni && return 0
    die "未选择 SNI。"
  fi
  echo
  _green "通过检测的候选（按 同国家优先 + TLS 握手延迟 排序）："
  sni_print_table "$sorted" 8
  local fails; fails=$(grep -c '^FAIL' "$res" || true)
  printf '  （另有 %s 个候选未通过，已排除）\n\n' "$fails"
  local best; best=$(head -n1 "$sorted" | cut -d'|' -f2)
  if (( OPT_AUTO )); then SNI=$best; ok "自动选择: ${SNI}"; return 0; fi
  local choice
  while :; do
    ask choice "请选择序号，或输入 m 手动填写域名" "1"
    if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= npass && choice <= 8 )); then
      SNI=$(sed -n "${choice}p" "$sorted" | cut -d'|' -f2); break
    elif [[ $choice == [mM] ]]; then
      manual_sni && break
    else
      warn "输入无效。"
    fi
  done
  ok "已选择 SNI: ${SNI}"
}

manual_sni() {
  local d r
  while :; do
    ask d "请输入目标域名（例如 www.example.edu，留空返回）" ""
    [[ -z $d ]] && return 1
    d=${d#https://}; d=${d%%/*}; d=${d,,}
    info "正在检测 ${d} ..."
    load_cf_ranges
    r=$( ( trap - ERR; set +e; sni_probe "$d" ) )
    if [[ $r == PASS* ]]; then
      IFS='|' read -r _ _ _ rtt ip cc city org <<<"$r"
      ok "${d} 通过检测：TLS 握手 ${rtt}ms，IP ${ip} (${cc} ${city} ${org})"
      [[ -n $GEO_CC && $cc != "$GEO_CC" ]] && warn "该网站 IP 与 VPS 不在同一国家，不推荐。"
      SNI=$d; return 0
    fi
    warn "${d} 未通过检测：$(cut -d'|' -f3 <<<"$r")"
    if confirm "仍然坚持使用 ${d} 吗？（不推荐）" n; then SNI=$d; return 0; fi
  done
}

# ============================================================
#                        端口 / SSH 检测
# ============================================================
# 返回占用某端口的进程名（空=未占用）。$1=tcp|udp $2=端口
port_owner() {
  local flag=-Htlnp; [[ $1 == udp ]] && flag=-Hulnp
  ss "$flag" "sport = :$2" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -n1 | sed -E 's/^users:\(\("//; s/"$//' || true
}
port_in_use() { [[ -n $(ss "$([[ $1 == udp ]] && echo -Huln || echo -Htln)" "sport = :$2" 2>/dev/null) ]]; }

# 检查端口是否可用（被自己的服务占用视为可用）
check_port_free() { # $1 proto $2 port $3 允许的进程名(正则)
  local owner
  port_in_use "$1" "$2" || return 0
  owner=$(port_owner "$1" "$2")
  [[ -n $owner && $owner =~ ^($3)$ ]] && return 0
  warn "${1^^} 端口 $2 已被占用（进程: ${owner:-未知}）。"
  return 1
}

detect_ssh_ports() {
  local ports="" p
  if have sshd; then
    ports+=" $(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | tr '\n' ' ')" || true
  fi
  if [[ -z ${ports// /} ]]; then
    ports+=" $(cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk 'tolower($1)=="port"{print $2}' | tr '\n' ' ')" || true
  fi
  # 监听中的 sshd / ssh.socket
  ports+=" $(ss -Htlnp 2>/dev/null | awk '/"sshd"|sshd:/{n=split($4,a,":"); print a[n]}' | tr '\n' ' ')" || true
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    ports+=" $(systemctl show ssh.socket -p Listen 2>/dev/null | grep -oE '[0-9]+ \(Stream\)' | awk '{print $1}' | tr '\n' ' ')" || true
  fi
  # 当前 SSH 会话实际使用的端口
  if [[ -n ${SSH_CONNECTION:-} ]]; then ports+=" $(awk '{print $4}' <<<"$SSH_CONNECTION")"; fi
  local uniq=""
  for p in $ports; do is_port "$p" && [[ " $uniq " != *" $p "* ]] && uniq+="$p "; done
  [[ -n $uniq ]] || uniq="22 "
  SSH_PORTS=${uniq% }
}

# 列出除本脚本服务 / SSH 外其它对外监听的端口
other_listen_ports() { # $1 = tcp|udp
  local flag=-Htlnp; [[ $1 == udp ]] && flag=-Hulnp
  ss "$flag" 2>/dev/null | awk '{print $4, $NF}' | while read -r addr users; do
    local port=${addr##*:} ip=${addr%:*}
    [[ $ip =~ ^(127\.|\[::1\]|::1|\[?fe80) ]] && continue
    [[ $ip == "127.0.0.53%lo" || $ip == 127.0.0.54 ]] && continue
    [[ $users =~ \"(xray|hysteria|sshd|systemd-resolve|chronyd|dhclient|systemd-network)\" ]] && continue
    [[ " $SSH_PORTS " == *" $port "* ]] && continue
    echo "$port"
  done | sort -un | tr '\n' ' ' || true
}

# ============================================================
#                        Xray 安装与配置
# ============================================================
install_xray() {
  step "安装 / 更新 Xray-core（官方 XTLS/Xray-install 脚本）"
  mktmp
  fetch -o "${TMP_DIR}/xray-install.sh" "$XRAY_INSTALL_URL" || die "下载 Xray 安装脚本失败，请检查网络（GitHub 可达性）。"
  if ! TERM=${TERM:-dumb} bash "${TMP_DIR}/xray-install.sh" install >"${TMP_DIR}/xray-install.log" 2>&1; then
    # GitHub API 限流(403)时：通过 releases/latest 跳转获取版本号后重试
    local tag
    tag=$(latest_tag XTLS/Xray-core)
    if [[ -n $tag ]]; then
      warn "官方脚本获取版本列表失败（可能是 GitHub API 限流），改为指定版本 ${tag} 重试 ..."
      TERM=${TERM:-dumb} bash "${TMP_DIR}/xray-install.sh" install --version "$tag" >"${TMP_DIR}/xray-install.log" 2>&1 || {
        tail -n 20 "${TMP_DIR}/xray-install.log" >&2; die "Xray 安装失败。"; }
    else
      tail -n 20 "${TMP_DIR}/xray-install.log" >&2; die "Xray 安装失败。"
    fi
  fi
  [[ -x $XRAY_BIN ]] || die "未找到 ${XRAY_BIN}，Xray 安装可能失败。"
  ok "Xray 已安装: $("$XRAY_BIN" version | head -n1 | awk '{print $2}')"
}

# 不依赖 GitHub API，从 releases/latest 的跳转地址解析最新版本号
latest_tag() {
  curl -fsSI --connect-timeout 10 -m 15 "https://github.com/$1/releases/latest" 2>/dev/null |
    awk -F'/tag/' 'tolower($0) ~ /^location:/ {gsub(/[\r\n]/, "", $2); print $2; exit}' || true
}

gen_xray_keys() { # 生成/重新生成全部 Xray 密钥
  local out
  UUID=$("$XRAY_BIN" uuid)
  out=$("$XRAY_BIN" x25519)
  PRIV_KEY=$(awk -F': *' 'tolower($1) ~ /^private ?key/ {print $NF; exit}' <<<"$out")
  PUB_KEY=$(awk -F': *' 'tolower($1) ~ /^(public ?key|password)/ {print $NF; exit}' <<<"$out")
  [[ -n $PRIV_KEY && -n $PUB_KEY ]] || die "无法解析 xray x25519 输出。"
  SHORT_ID=$(rand_hex 4)
  MLDSA_SEED="" MLDSA_VERIFY=""
  if out=$("$XRAY_BIN" mldsa65 2>/dev/null); then
    MLDSA_SEED=$(awk -F': *' '$1=="Seed"{print $NF; exit}' <<<"$out")
    MLDSA_VERIFY=$(awk -F': *' '$1=="Verify"{print $NF; exit}' <<<"$out")
  fi
  if [[ -z $MLDSA_SEED || -z $MLDSA_VERIFY ]]; then
    MLDSA_SEED="" MLDSA_VERIFY=""
    warn "当前 Xray 版本不支持 mldsa65，已跳过后量子签名 (pqv)。"
  fi
}

xray_clients_json() {
  local list
  list=$(jq -n --arg id "$UUID" '[{id:$id, flow:"xtls-rprx-vision", email:"main"}]')
  if [[ -s $USERS_FILE ]]; then
    local u r
    while IFS=$'\t' read -r u r; do
      [[ -n $u ]] || continue
      list=$(jq --arg id "$u" --arg e "$r" '. + [{id:$id, flow:"xtls-rprx-vision", email:$e}]' <<<"$list")
    done <"$USERS_FILE"
  fi
  printf '%s' "$list"
}

write_xray_config() {
  local clients tmp
  clients=$(xray_clients_json)
  mkdir -p "$(dirname "$XRAY_CONF")"
  tmp=$(mktemp --suffix=.json "$(dirname "$XRAY_CONF")/.config.XXXXXX")
  jq -n \
    --argjson port "$XRAY_PORT" --argjson clients "$clients" \
    --arg target "${SNI_TARGET:-$SNI:443}" --arg sni "$SNI" \
    --arg priv "$PRIV_KEY" --arg sid "$SHORT_ID" --arg seed "$MLDSA_SEED" '
  {
    log: {loglevel: "warning"},
    inbounds: [{
      tag: "vless-reality",
      port: $port,
      protocol: "vless",
      settings: {clients: $clients, decryption: "none"},
      streamSettings: {
        network: "raw",
        security: "reality",
        realitySettings: ({
          show: false,
          target: $target,
          xver: 0,
          serverNames: [$sni],
          privateKey: $priv,
          shortIds: [$sid]
        } + (if $seed != "" then {mldsa65Seed: $seed} else {} end))
      },
      sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
    }],
    outbounds: [
      {tag: "direct", protocol: "freedom"},
      {tag: "block", protocol: "blackhole"}
    ],
    routing: {
      domainStrategy: "AsIs",
      rules: [
        {type: "field", ip: ["geoip:private"], outboundTag: "block"},
        {type: "field", protocol: ["bittorrent"], outboundTag: "block"}
      ]
    }
  }' >"$tmp"
  if ! "$XRAY_BIN" run -test -config "$tmp" >"${tmp}.log" 2>&1; then
    cat "${tmp}.log" >&2; rm -f "$tmp" "${tmp}.log"
    die "Xray 配置校验失败（xray run -test），未应用新配置。"
  fi
  rm -f "${tmp}.log"
  # xray 以 nobody 运行：root 所有、nobody 组可读
  local grp; grp=$(id -gn nobody 2>/dev/null || echo nogroup)
  chown "root:${grp}" "$tmp"; chmod 640 "$tmp"
  if [[ -f $XRAY_CONF ]]; then mkdir -p "$BACKUP_DIR"; cp -a "$XRAY_CONF" "${BACKUP_DIR}/xray-config.json.bak" 2>/dev/null || true; fi
  mv -f "$tmp" "$XRAY_CONF"
  selinux_fix "$(dirname "$XRAY_CONF")"
  ok "Xray 配置已生成并通过校验: ${XRAY_CONF}"
}

restart_xray() {
  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true
  systemctl restart xray
  sleep 1
  if ! svc_active xray; then
    journalctl -u xray -n 20 --no-pager >&2 || true
    die "Xray 启动失败，请查看上方日志。"
  fi
  ok "Xray 运行中 (TCP ${XRAY_PORT})"
}

selinux_fix() {
  have selinuxenabled && selinuxenabled 2>/dev/null || return 0
  if have restorecon; then restorecon -R "$@" >/dev/null 2>&1 || true; fi
}

# ============================================================
#                        Hysteria2
# ============================================================
install_hysteria() {
  step "安装 / 更新 Hysteria2（官方 get.hy2.sh 脚本）"
  mktmp
  fetch -o "${TMP_DIR}/hy2-install.sh" "$HY_INSTALL_URL" || die "下载 Hysteria2 安装脚本失败。"
  TERM=${TERM:-dumb} bash "${TMP_DIR}/hy2-install.sh" >"${TMP_DIR}/hy2-install.log" 2>&1 || {
    tail -n 20 "${TMP_DIR}/hy2-install.log" >&2; die "Hysteria2 安装失败。"; }
  [[ -x $HY_BIN ]] || die "未找到 ${HY_BIN}，Hysteria2 安装可能失败。"
  ok "Hysteria2 已安装: $("$HY_BIN" version 2>/dev/null | awk '/^Version:/{print $2}')"
}

gen_hy2_cert() {
  mkdir -p "$HY_DIR"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "${HY_KEY}.tmp" -out "${HY_CRT}.tmp" -days 3650 -subj "/CN=${SNI}" \
    -addext "subjectAltName=DNS:${SNI}" >/dev/null 2>&1 || die "生成 Hysteria2 自签证书失败。"
  mv -f "${HY_KEY}.tmp" "$HY_KEY"; mv -f "${HY_CRT}.tmp" "$HY_CRT"
  HY2_PIN=$(openssl x509 -noout -fingerprint -sha256 -in "$HY_CRT" | cut -d= -f2)
}

write_hy2_config() {
  [[ -n $HY2_PASS ]] || HY2_PASS=$(rand_pass)
  [[ -f $HY_CRT && -f $HY_KEY ]] || gen_hy2_cert
  # 证书 CN 与当前 SNI 不一致时重新生成
  if ! openssl x509 -noout -subject -in "$HY_CRT" 2>/dev/null | grep -q "CN *= *${SNI}\$"; then gen_hy2_cert; fi
  HY2_PIN=$(openssl x509 -noout -fingerprint -sha256 -in "$HY_CRT" | cut -d= -f2)
  cat >"${HY_CONF}.tmp" <<HY
# 由 proxy-oneclick 生成
listen: :${HY2_PORT}

tls:
  cert: ${HY_CRT}
  key: ${HY_KEY}

auth:
  type: password
  password: "${HY2_PASS}"

masquerade:
  type: proxy
  proxy:
    url: https://${SNI}/
    rewriteHost: true
HY
  local grp="root"; id hysteria >/dev/null 2>&1 && grp=hysteria
  chown "root:${grp}" "${HY_CONF}.tmp" "$HY_KEY" "$HY_CRT"
  chmod 640 "${HY_CONF}.tmp" "$HY_KEY"; chmod 644 "$HY_CRT"
  mv -f "${HY_CONF}.tmp" "$HY_CONF"
  selinux_fix "$HY_DIR"
  ok "Hysteria2 配置已生成: ${HY_CONF}"
}

restart_hy2() {
  systemctl daemon-reload
  systemctl enable hysteria-server >/dev/null 2>&1 || true
  systemctl restart hysteria-server
  sleep 2
  if ! svc_active hysteria-server; then
    journalctl -u hysteria-server -n 20 --no-pager >&2 || true
    die "Hysteria2 启动失败，请查看上方日志。"
  fi
  ok "Hysteria2 运行中 (UDP ${HY2_PORT}${HOP_RANGE:+，端口跳跃 ${HOP_RANGE}})"
}

remove_hysteria() {
  systemctl disable --now hysteria-server >/dev/null 2>&1 || true
  systemctl disable --now 'hysteria-server@*' >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-server@.service
  rm -rf /etc/systemd/system/hysteria-server.service.d
  rm -f "$HY_BIN"; rm -rf "$HY_DIR"
  if id hysteria >/dev/null 2>&1; then userdel hysteria >/dev/null 2>&1 || true; fi
  systemctl daemon-reload
}

# ============================================================
#                        防火墙 (nftables)
# ============================================================
handle_other_firewalls() {
  local fw
  for fw in firewalld ufw; do
    if svc_active "$fw" || { [[ $fw == ufw ]] && have ufw && ufw status 2>/dev/null | grep -q 'Status: active'; }; then
      warn "检测到 ${fw} 正在运行，与本脚本的 nftables 规则同时使用会互相干扰。"
      if confirm "是否停用 ${fw}（本脚本会接管防火墙，放行 SSH 与现有监听端口）？" y; then
        [[ $fw == ufw ]] && { ufw --force disable >/dev/null 2>&1 || true; }
        systemctl disable --now "$fw" >/dev/null 2>&1 || true
        [[ " $DISABLED_FW " == *" $fw "* ]] || DISABLED_FW="${DISABLED_FW:+$DISABLED_FW }$fw"
        ok "已停用 ${fw}（卸载本脚本时可恢复）。"
      else
        warn "保留 ${fw}，本脚本将不配置防火墙。请自行在 ${fw} 中放行 TCP ${XRAY_PORT}、UDP ${HY2_PORT} 及端口跳跃范围。"
        FW_ENABLED=0
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
  tcp_ports="$XRAY_PORT"
  for p in $EXTRA_TCP; do [[ ",$tcp_ports,$ssh_set," == *",$p,"* ]] || tcp_ports+=",$p"; done
  udp_ports=""
  (( HY2_ENABLED )) && udp_ports="$HY2_PORT"
  for p in $EXTRA_UDP; do [[ ",$udp_ports," == *",$p,"* ]] || udp_ports+="${udp_ports:+,}$p"; done
  local hop=""
  (( HY2_ENABLED )) && [[ -n $HOP_RANGE ]] && hop=$HOP_RANGE
  {
    echo "#!/usr/sbin/nft -f"
    echo "# 由 proxy-oneclick 生成；卸载时删除。原有规则备份在 ${BACKUP_DIR}"
    echo "table inet ${NFT_TABLE}"
    echo "delete table inet ${NFT_TABLE}"
    echo "table inet ${NFT_TABLE} {"
    echo "  chain input {"
    echo "    type filter hook input priority filter; policy drop;"
    echo "    iif \"lo\" accept"
    echo "    ct state established,related accept"
    echo "    ct state invalid drop"
    echo "    meta l4proto 1 accept comment \"ICMP\""
    echo "    meta l4proto 58 accept comment \"ICMPv6\""
    echo "    ip6 saddr fe80::/10 udp sport 547 udp dport 546 accept comment \"DHCPv6\""
    echo "    tcp dport { ${ssh_set} } accept comment \"SSH\""
    echo "    tcp dport { ${tcp_ports} } accept"
    [[ -n $udp_ports ]] && echo "    udp dport { ${udp_ports} } accept"
    [[ -n $hop ]] && echo "    udp dport ${hop} accept comment \"hy2 port hopping\""
    echo "    ct status dnat accept"
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
  (( FW_ENABLED )) || { warn "已跳过防火墙配置（--no-firewall 或保留了其它防火墙）。"; return 0; }
  step "配置 nftables 防火墙"
  have nft || die "未安装 nftables。"
  detect_ssh_ports
  mkdir -p "$STATE_DIR"
  render_firewall
  if ! render_firewall_compat; then
    nft -c -f "${FW_FILE}.tmp" >&2 || true
    rm -f "${FW_FILE}.tmp"
    die "防火墙规则语法校验失败（nft -c），未应用任何更改。"
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
  ok "nftables 规则已加载（入站默认拒绝）。已放行 SSH 端口: ${SSH_PORTS}；TCP ${XRAY_PORT}${EXTRA_TCP:+ $EXTRA_TCP}$( ((HY2_ENABLED)) && echo "；UDP ${HY2_PORT}${HOP_RANGE:+ + ${HOP_RANGE}}")${EXTRA_UDP:+；UDP $EXTRA_UDP}"
}

remove_firewall() {
  systemctl disable --now proxy-oneclick-fw >/dev/null 2>&1 || true
  nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
  nft delete table ip "${NFT_TABLE}_nat" >/dev/null 2>&1 || true
  nft delete table ip6 "${NFT_TABLE}_nat" >/dev/null 2>&1 || true
  rm -f "$FW_UNIT" "$FW_FILE"
  systemctl daemon-reload
}

ask_extra_ports() {
  local t u
  detect_ssh_ports
  t=$(other_listen_ports tcp); u=$(other_listen_ports udp)
  # 排除自身端口
  t=$(for p in $t; do [[ $p == "$XRAY_PORT" ]] || echo "$p"; done | tr '\n' ' ')
  u=$(for p in $u; do [[ $p == "$HY2_PORT" ]] || echo "$p"; done | tr '\n' ' ')
  t=${t% } u=${u% }
  if [[ -n $t || -n $u ]]; then
    warn "检测到本机还有其它服务在对外监听：${t:+TCP [$t] }${u:+UDP [$u]}"
    if confirm "是否在防火墙中放行这些端口（避免影响现有服务）？" y; then
      EXTRA_TCP="$(tr ' ' '\n' <<<"$EXTRA_TCP $t" | awk 'NF' | sort -un | tr '\n' ' ')"; EXTRA_TCP=${EXTRA_TCP% }
      EXTRA_UDP="$(tr ' ' '\n' <<<"$EXTRA_UDP $u" | awk 'NF' | sort -un | tr '\n' ' ')"; EXTRA_UDP=${EXTRA_UDP% }
    fi
  fi
}

cloud_fw_reminder() {
  echo
  _yellow "【重要】请同时在云服务商控制台的安全组 / 防火墙中放行以下端口，否则无法连接："
  printf '   TCP %s（VLESS-REALITY）\n' "$XRAY_PORT"
  (( HY2_ENABLED )) && printf '   UDP %s%s（Hysteria2）\n' "$HY2_PORT" "${HOP_RANGE:+ 以及 UDP ${HOP_RANGE}（端口跳跃）}"
  echo "   常见位置：AWS EC2 安全组 / Lightsail 网络 / GCP VPC 防火墙 / Oracle Cloud 安全列表 / Azure NSG / 阿里云·腾讯云 安全组"
  echo "   （Oracle Cloud 镜像还自带 iptables 规则，如有需要请一并检查）"
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

# ============================================================
#                        链接 / 二维码 / 客户端配置
# ============================================================
server_addr() {
  if [[ -n $SERVER_ADDR ]]; then printf '%s' "$SERVER_ADDR"; return; fi
  [[ -n $PUBLIC_IP4 || -n $PUBLIC_IP6 ]] || detect_ip
  printf '%s' "${PUBLIC_IP4:-$PUBLIC_IP6}"
}

vless_link() { # $1 uuid $2 名称 $3 是否包含 pqv(1/0)
  local addr q
  addr=$(host_fmt "$(server_addr)")
  q="encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=randomized&pbk=${PUB_KEY}&sid=${SHORT_ID}"
  [[ ${3:-1} == 1 && -n $MLDSA_VERIFY ]] && q+="&pqv=${MLDSA_VERIFY}"
  q+="&type=tcp&headerType=none"
  printf 'vless://%s@%s:%s?%s#%s' "$1" "$addr" "$XRAY_PORT" "$q" "$(urlencode "$2")"
}

hy2_link() {
  local addr q
  addr=$(host_fmt "$(server_addr)")
  q="sni=${SNI}&insecure=1&pinSHA256=${HY2_PIN}"
  [[ -n $HOP_RANGE ]] && q+="&mport=${HOP_RANGE}"
  printf 'hysteria2://%s@%s:%s/?%s#%s' "$(urlencode "$HY2_PASS")" "$addr" "$HY2_PORT" "$q" "$(urlencode "${NODE_NAME}-Hy2")"
}

mihomo_yaml() {
  local addr pin_hex
  addr=$(server_addr)
  pin_hex=$(tr -d ':' <<<"$HY2_PIN" | tr 'A-F' 'a-f')
  echo "proxies:"
  cat <<Y
  - name: "${NODE_NAME}-Reality"
    type: vless
    server: ${addr}
    port: ${XRAY_PORT}
    uuid: ${UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${SNI}
    client-fingerprint: random
    reality-opts:
      public-key: ${PUB_KEY}
      short-id: ${SHORT_ID}
Y
  if [[ -s $USERS_FILE ]]; then
    local u r
    while IFS=$'\t' read -r u r; do
      [[ -n $u ]] || continue
      cat <<Y
  - name: "${NODE_NAME}-Reality-${r}"
    type: vless
    server: ${addr}
    port: ${XRAY_PORT}
    uuid: ${u}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${SNI}
    client-fingerprint: random
    reality-opts:
      public-key: ${PUB_KEY}
      short-id: ${SHORT_ID}
Y
    done <"$USERS_FILE"
  fi
  if (( HY2_ENABLED )); then
    cat <<Y
  - name: "${NODE_NAME}-Hy2"
    type: hysteria2
    server: ${addr}
    port: ${HY2_PORT}
Y
    [[ -n $HOP_RANGE ]] && printf '    ports: %s\n    hop-interval: 30\n' "$HOP_RANGE"
    cat <<Y
    password: "${HY2_PASS}"
    sni: ${SNI}
    fingerprint: ${pin_hex}
    alpn:
      - h3
Y
  fi
}

print_qr() { # $1 链接
  if have qrencode; then
    qrencode -t ansiutf8 -m 1 -l L "$1" 2>/dev/null || warn "链接过长，无法生成终端二维码。"
  else
    warn "未安装 qrencode，无法显示二维码。"
  fi
}

build_info() { # 输出完整信息（无颜色），用于保存文件
  local vl vl_short hy
  vl=$(vless_link "$UUID" "${NODE_NAME}-Reality" 1)
  echo "================ proxy-oneclick 节点信息 ================"
  echo "生成时间: $(date '+%F %T %Z')"
  echo "服务器:   $(server_addr)"
  echo "SNI:      ${SNI}"
  echo
  echo "---------- VLESS + REALITY + Vision ----------"
  echo "地址: $(server_addr)   端口: ${XRAY_PORT} (TCP)"
  echo "UUID: ${UUID}"
  echo "流控: xtls-rprx-vision    传输: tcp    安全: reality"
  echo "SNI:  ${SNI}    指纹(fp): randomized"
  echo "公钥(pbk): ${PUB_KEY}"
  echo "ShortId(sid): ${SHORT_ID}"
  [[ -n $MLDSA_VERIFY ]] && echo "ML-DSA-65 验证公钥(pqv): 已包含在链接中（很长，可选，客户端不支持时可删除 &pqv=... 部分）"
  echo
  echo "链接（含 pqv 后量子签名验证）:"
  echo "$vl"
  if [[ -n $MLDSA_VERIFY ]]; then
    vl_short=$(vless_link "$UUID" "${NODE_NAME}-Reality" 0)
    echo
    echo "链接（不含 pqv，兼容性更好 / 二维码使用此链接）:"
    echo "$vl_short"
  fi
  if [[ -s $USERS_FILE ]]; then
    echo
    echo "---------- 额外用户 ----------"
    local u r
    while IFS=$'\t' read -r u r; do
      [[ -n $u ]] || continue
      echo "[$r] $(vless_link "$u" "${NODE_NAME}-${r}" 0)"
    done <"$USERS_FILE"
  fi
  if (( HY2_ENABLED )); then
    hy=$(hy2_link)
    echo
    echo "---------- Hysteria2 ----------"
    echo "地址: $(server_addr)   端口: ${HY2_PORT} (UDP)${HOP_RANGE:+   端口跳跃: ${HOP_RANGE}}"
    echo "密码: ${HY2_PASS}"
    echo "SNI:  ${SNI}   (自签证书，insecure=1 + pinSHA256 证书指纹校验)"
    echo "pinSHA256: ${HY2_PIN}"
    echo
    echo "$hy"
    if [[ -n $HOP_RANGE ]]; then
      echo
      echo "官方 Hysteria2 客户端 / sing-box 多端口写法（端口跳跃写在地址里）:"
      hy2_link | sed -E "s#@([^/]+):${HY2_PORT}/#@\\1:${HY2_PORT},${HOP_RANGE}/#; s#&mport=[0-9-]+##"
      echo
    fi
  fi
  echo
  echo "---------- mihomo (Clash.Meta / Clash Verge Rev) ----------"
  mihomo_yaml
  echo
  echo "========================================================"
}

save_info() {
  build_info >"${INFO_FILE}.tmp"
  chmod 600 "${INFO_FILE}.tmp"; mv -f "${INFO_FILE}.tmp" "$INFO_FILE"
}

show_info() {
  load_state
  (( INSTALLED )) || die "尚未安装，请先执行安装。"
  save_info
  local vl vl_qr
  vl=$(vless_link "$UUID" "${NODE_NAME}-Reality" 1)
  vl_qr=$(vless_link "$UUID" "${NODE_NAME}-Reality" 0)
  echo
  hr; _green "  VLESS + REALITY + Vision   (${SNI})"; hr
  printf '  地址: %s  端口: %s  UUID: %s\n' "$(server_addr)" "$XRAY_PORT" "$UUID"
  printf '  pbk: %s  sid: %s  fp: randomized\n' "$PUB_KEY" "$SHORT_ID"
  echo
  _cyan "  链接（含 pqv）："
  echo "$vl"
  if [[ -n $MLDSA_VERIFY ]]; then
    echo; _cyan "  链接（不含 pqv，兼容性更好）："; echo "$vl_qr"
  fi
  echo; _cyan "  二维码（不含 pqv，pqv 太长无法放入终端二维码）："
  print_qr "$vl_qr"
  if (( HY2_ENABLED )); then
    local hy; hy=$(hy2_link)
    echo; hr; _green "  Hysteria2   (UDP ${HY2_PORT}${HOP_RANGE:+，跳跃 ${HOP_RANGE}})"; hr
    echo "$hy"
    echo; print_qr "$hy"
  fi
  echo; hr; _green "  mihomo / Clash.Meta 配置片段"; hr
  mihomo_yaml
  echo; hr
  printf '  以上信息已保存到 %s（权限 600）。随时执行 %sproxy info%s 再次查看。\n' "$INFO_FILE" "$C_GREEN" "$C_NONE"
  hr
}

# ============================================================
#                        安装主流程
# ============================================================
self_install() {
  local src=${BASH_SOURCE[0]:-$0}
  if [[ -f $src && -r $src ]]; then
    if [[ $(readlink -f "$src") != "$(readlink -f "$BIN_PATH" 2>/dev/null)" ]]; then
      install -m 755 "$src" "$BIN_PATH"
    fi
  elif [[ ! -x $BIN_PATH ]]; then
    if fetch -o "${BIN_PATH}.tmp" "$SCRIPT_URL" 2>/dev/null && bash -n "${BIN_PATH}.tmp"; then
      install -m 755 "${BIN_PATH}.tmp" "$BIN_PATH"
    else
      warn "无法安装管理命令 proxy（请用 'curl -o proxy.sh URL && bash proxy.sh' 方式运行）。"
    fi
    rm -f "${BIN_PATH}.tmp"
  fi
  [[ -x $BIN_PATH ]] && ok "管理命令已安装：${BIN_PATH}（直接输入 proxy 即可打开菜单）"
  return 0
}

default_node_name() {
  local n="${GEO_CC:-VPS}"
  [[ -n $GEO_CITY ]] && n+="-${GEO_CITY// /}"
  printf '%s' "$n" | tr -cd 'A-Za-z0-9_.-'
}

choose_ports() {
  local p
  # Xray 端口
  p=${OPT_PORT:-$XRAY_PORT}
  while :; do
    if [[ -z $OPT_PORT ]]; then ask p "VLESS-REALITY 监听端口 (TCP)" "$p"; fi
    if ! is_port "$p"; then
      (( OPT_AUTO )) && die "端口无效: $p"; warn "端口无效。"; p=443; continue
    fi
    if check_port_free tcp "$p" "xray"; then XRAY_PORT=$p; break; fi
    (( OPT_AUTO )) || [[ -n $OPT_PORT ]] && die "TCP 端口 $p 已被占用，请释放或使用 --port 指定其它端口。"
  done
  # Hysteria2
  if [[ -n $OPT_HY2 ]]; then HY2_ENABLED=$OPT_HY2
  elif (( ! OPT_AUTO )); then
    if confirm "是否同时安装 Hysteria2（UDP，弱网/高丢包下表现更好）？" "$([[ $HY2_ENABLED == 1 ]] && echo y || echo n)"; then HY2_ENABLED=1; else HY2_ENABLED=0; fi
  fi
  (( HY2_ENABLED )) || return 0
  p=${OPT_HY2_PORT:-$HY2_PORT}
  while :; do
    [[ -z $OPT_HY2_PORT ]] && ask p "Hysteria2 监听端口 (UDP)" "$p"
    is_port "$p" || { (( OPT_AUTO )) && die "端口无效: $p"; warn "端口无效。"; p=443; continue; }
    if check_port_free udp "$p" "hysteria"; then HY2_PORT=$p; break; fi
    (( OPT_AUTO )) || [[ -n $OPT_HY2_PORT ]] && die "UDP 端口 $p 已被占用，请使用 --hy2-port 指定其它端口。"
  done
  # 端口跳跃
  local hop=${OPT_HOP:-${HOP_RANGE:-none}}
  [[ -z $OPT_HOP && -z $HOP_RANGE && $INSTALLED != 1 ]] && hop="20000-50000"
  while :; do
    [[ -z $OPT_HOP ]] && ask hop "Hysteria2 端口跳跃范围（UDP，输入 none 关闭）" "$hop"
    if [[ $hop == none || $hop == no || -z $hop ]]; then HOP_RANGE=""; break; fi
    if is_range "$hop"; then
      local a=${hop%-*}
      if (( a < 1024 )); then warn "跳跃范围起始端口应 ≥ 1024。"; else HOP_RANGE=$hop; break; fi
    else
      warn "范围格式无效，例如 20000-50000。"
    fi
    (( OPT_AUTO )) || [[ -n $OPT_HOP ]] && die "端口跳跃范围无效: $hop"
  done
}

do_install() {
  preflight
  load_state
  take_lock
  if (( INSTALLED )) && (( ! OPT_AUTO )); then
    warn "检测到已安装。重新安装将保留现有密钥/UUID/密码，仅更新组件与配置。"
    confirm "继续重新安装？" y || return 0
  fi

  pkg_update_upgrade
  install_deps
  ensure_time_sync
  mktmp
  step "获取服务器信息"
  detect_ip; detect_geo; show_sysinfo
  SERVER_ADDR=${PUBLIC_IP4:-$PUBLIC_IP6}
  ensure_swap
  (( OPT_TUNE )) && apply_tuning

  step "端口设置"
  choose_ports
  [[ -n $OPT_NAME ]] && NODE_NAME=$OPT_NAME
  [[ -n $NODE_NAME ]] || NODE_NAME=$(default_node_name)
  (( OPT_FIREWALL )) || FW_ENABLED=0
  if (( OPT_FIREWALL )); then
    FW_ENABLED=1
    handle_other_firewalls
    (( FW_ENABLED )) && ask_extra_ports
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

  if [[ -z $SNI || -n $OPT_SNI ]] || { (( ! OPT_AUTO )) && confirm "是否重新优选 SNI（当前: ${SNI}）？" n; }; then
    select_sni
  fi
  SNI_TARGET="${SNI}:443"
  save_state

  write_xray_config
  restart_xray

  if (( HY2_ENABLED )); then
    install_hysteria
    write_hy2_config
    save_state
    restart_hy2
  elif [[ -x $HY_BIN ]]; then
    info "已关闭 Hysteria2，移除相关组件 ..."
    remove_hysteria
  fi

  apply_firewall
  setup_fail2ban
  INSTALLED=1
  save_state
  self_install
  show_info
  cloud_fw_reminder
  echo
  _green "安装完成！客户端配置方法见 README；管理菜单：proxy"
}

# ============================================================
#                        管理功能
# ============================================================
need_installed() {
  load_state
  (( INSTALLED )) || die "尚未安装，请先选择「安装」。"
  [[ -x $XRAY_BIN ]] || die "未找到 Xray，请重新安装。"
}

apply_all() { # 重新生成配置并重启（在修改参数后调用）
  save_state
  write_xray_config
  restart_xray
  if (( HY2_ENABLED )); then write_hy2_config; restart_hy2; fi
  apply_firewall
  save_state
  save_info
}

menu_change_sni() {
  need_installed; mktmp
  detect_ip; detect_geo
  SERVER_ADDR=${PUBLIC_IP4:-$PUBLIC_IP6}
  local old=$SNI
  select_sni
  [[ $SNI == "$old" ]] && { info "SNI 未变化。"; return 0; }
  SNI_TARGET="${SNI}:443"
  apply_all
  ok "SNI 已由 ${old} 更换为 ${SNI}。客户端需要更新链接（Hysteria2 证书指纹也已变化）。"
  show_info
}

menu_regen_keys() {
  need_installed
  warn "将重新生成 UUID、x25519 密钥、ShortId、ML-DSA-65 密钥及 Hysteria2 密码/证书，所有旧客户端将失效！"
  (( OPT_AUTO )) || confirm "确认重新生成？" n || return 0
  gen_xray_keys
  HY2_PASS=$(rand_pass)
  if (( HY2_ENABLED )); then gen_hy2_cert; fi
  apply_all
  ok "已重新生成全部密钥。"
  show_info
}

menu_change_ports() {
  need_installed
  local oldx=$XRAY_PORT oldh=$HY2_PORT
  choose_ports_interactive
  if (( HY2_ENABLED )) && [[ ! -x $HY_BIN ]]; then install_hysteria; fi
  if (( ! HY2_ENABLED )) && [[ -x $HY_BIN ]]; then remove_hysteria; fi
  apply_all
  ok "端口已更新：TCP ${oldx} -> ${XRAY_PORT}$( ((HY2_ENABLED)) && echo "，UDP ${oldh} -> ${HY2_PORT}，跳跃 ${HOP_RANGE:-关闭}")"
  cloud_fw_reminder
}
choose_ports_interactive() {
  # 修改端口时允许当前服务占用自身端口
  local save_opt=$OPT_PORT save_h=$OPT_HY2_PORT
  OPT_PORT="" OPT_HY2_PORT=""
  choose_ports
  OPT_PORT=$save_opt OPT_HY2_PORT=$save_h
}

menu_users() {
  need_installed
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
        write_xray_config; restart_xray; save_info
        ok "已添加用户 ${remark}"
        vless_link "$nu" "${NODE_NAME}-${remark}" 0; echo
        print_qr "$(vless_link "$nu" "${NODE_NAME}-${remark}" 0)" ;;
      2)
        (( i > 0 )) || { warn "没有可删除的用户。"; continue; }
        local n; ask n "输入要删除的序号" ""
        if ! [[ $n =~ ^[0-9]+$ ]] || (( n < 1 || n > i )); then warn "序号无效。"; continue; fi
        sed -i "${n}d" "$USERS_FILE"
        write_xray_config; restart_xray; save_info
        ok "已删除。" ;;
      3)
        (( i > 0 )) || { warn "没有额外用户。"; continue; }
        local n; ask n "输入序号" "1"
        if ! [[ $n =~ ^[0-9]+$ ]] || (( n < 1 || n > i )); then warn "序号无效。"; continue; fi
        IFS=$'\t' read -r u r < <(sed -n "${n}p" "$USERS_FILE")
        vless_link "$u" "${NODE_NAME}-${r}" 1; echo; echo
        print_qr "$(vless_link "$u" "${NODE_NAME}-${r}" 0)" ;;
      *) return 0 ;;
    esac
  done
}

menu_update() {
  need_installed
  preflight
  echo "  1) 更新 Xray-core   2) 更新 Hysteria2   3) 更新本脚本   4) 全部更新   0) 返回"
  local c; ask c "请选择" "4"
  case $c in
    1) install_xray; write_xray_config; restart_xray ;;
    2) (( HY2_ENABLED )) || { warn "未启用 Hysteria2。"; return 0; }; install_hysteria; write_hy2_config; restart_hy2 ;;
    3) update_script ;;
    4) install_xray; write_xray_config; restart_xray
       if (( HY2_ENABLED )); then install_hysteria; write_hy2_config; restart_hy2; fi
       update_script ;;
    *) return 0 ;;
  esac
}

update_script() {
  mktmp
  if [[ $SCRIPT_URL == *YOUR_GITHUB* ]]; then warn "脚本中 SCRIPT_URL 仍为占位符，无法在线更新脚本。"; return 0; fi
  if fetch -o "${TMP_DIR}/proxy.sh" "$SCRIPT_URL" && bash -n "${TMP_DIR}/proxy.sh"; then
    install -m 755 "${TMP_DIR}/proxy.sh" "$BIN_PATH"
    ok "脚本已更新为 $(grep -m1 '^readonly SCRIPT_VERSION=' "$BIN_PATH" | cut -d'"' -f2)"
  else
    warn "脚本更新失败。"
  fi
}

menu_status() {
  load_state
  echo; hr; _green "  服务状态"; hr
  local s
  for s in xray hysteria-server proxy-oneclick-fw fail2ban; do
    local st; st=$(systemctl is-active "$s" 2>/dev/null || true)
    [[ -z $st ]] && st="unknown"
    if [[ $st == active ]]; then printf '  %-22s %s\n' "$s" "${C_GREEN}运行中${C_NONE}"
    elif systemctl cat "$s" >/dev/null 2>&1; then printf '  %-22s %s\n' "$s" "${C_RED}${st}${C_NONE}"
    else printf '  %-22s %s\n' "$s" "未安装"; fi
  done
  [[ -x $XRAY_BIN ]] && printf '  Xray 版本:      %s\n' "$("$XRAY_BIN" version | head -n1 | awk '{print $2}')"
  [[ -x $HY_BIN ]] && printf '  Hysteria2 版本: %s\n' "$("$HY_BIN" version 2>/dev/null | awk '/^Version:/{print $2}')"
  printf '  拥塞控制:       %s / %s\n' "$(sysval net.ipv4.tcp_congestion_control)" "$(sysval net.core.default_qdisc)"
  printf '  时间同步:       %s\n' "$(time_sync_status)"
  echo; _cyan "  监听端口："
  ss -Htlnp 2>/dev/null | awk '/xray/{print "   TCP "$4"  xray"}' || true
  ss -Hulnp 2>/dev/null | awk '/hysteria/{print "   UDP "$4"  hysteria"}' || true
  if have fail2ban-client && svc_active fail2ban; then
    echo; _cyan "  fail2ban (sshd)："
    fail2ban-client status sshd 2>/dev/null | sed 's/^/   /' || true
  fi
  echo
  echo "  1) 查看 Xray 日志   2) 查看 Hysteria2 日志   3) 查看防火墙规则   4) 实时跟踪 Xray 日志   0) 返回"
  local c; ask c "请选择" "0"
  case $c in
    1) journalctl -u xray -n 80 --no-pager ;;
    2) journalctl -u hysteria-server -n 80 --no-pager ;;
    3) nft list table inet "$NFT_TABLE" 2>/dev/null || warn "未找到本脚本的防火墙表。"
       nft list table ip "${NFT_TABLE}_nat" 2>/dev/null || true ;;
    4) journalctl -u xray -f ;;
    *) return 0 ;;
  esac
}

speed_try() { # $1 URL；成功时输出 "Mbps 已下载MB 秒数"，失败返回 1
  local out rc=0 code size t
  out=$(curl -4 -so /dev/null --connect-timeout 8 -m 20 -w '%{http_code} %{size_download} %{time_total}' "$1" 2>/dev/null) || rc=$?
  read -r code size t <<<"$out"
  # 必须是 HTTP 200；正常结束 (0) 或到达 20 秒上限 (28) 都可以，只要下载量 ≥ 10MB
  [[ $code == 200 ]] || return 1
  (( rc == 0 || rc == 28 )) || return 1
  awk -v s="${size:-0}" -v t="${t:-0}" 'BEGIN{ if (s < 10000000 || t <= 0) exit 1; printf "%.1f %.0f %.1f", s*8/t/1000000, s/1000000, t }'
}

menu_speed() {
  load_state
  echo; hr; _green "  网络测速 / 延迟提示"; hr
  printf '  拥塞控制: %s   队列: %s\n' "$(sysval net.ipv4.tcp_congestion_control)" "$(sysval net.core.default_qdisc)"
  if [[ -n $SNI ]]; then
    local w a="" b="" rc=0
    w=$(curl -4 -so /dev/null --connect-timeout 5 -m 10 -w '%{time_connect} %{time_appconnect}' "https://${SNI}/" 2>/dev/null) || rc=$?
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
   · 在本地电脑上测试到 VPS 的延迟：tcping $(server_addr) ${XRAY_PORT}（ICMP ping 可能被运营商限速，仅供参考）
   · 查看回程路由：在 VPS 上运行 nexttrace（https://github.com/nxtrace/NTrace-core）
   · 晚高峰丢包严重时优先使用 Hysteria2；TCP 稳定时 REALITY 延迟更低
   · SNI 目标延迟过高（> 100ms）时，可在菜单中「更换 SNI」重新优选
TIP
}

menu_firewall() {
  need_installed
  echo; hr; _green "  防火墙管理"; hr
  echo "  当前状态: $( ((FW_ENABLED)) && echo 由本脚本管理 || echo 未启用)   SSH 端口: ${SSH_PORTS:-未检测}"
  echo "  额外放行: TCP [${EXTRA_TCP}]  UDP [${EXTRA_UDP}]"
  echo "  1) 放行额外 TCP 端口  2) 放行额外 UDP 端口  3) 取消额外放行  4) 重新检测 SSH 端口并重载  5) 停用本脚本防火墙  6) 启用本脚本防火墙  0) 返回"
  local c p; ask c "请选择" "0"
  case $c in
    1) ask p "TCP 端口（空格分隔）" ""; for x in $p; do is_port "$x" && EXTRA_TCP="${EXTRA_TCP:+$EXTRA_TCP }$x"; done ;;
    2) ask p "UDP 端口（空格分隔）" ""; for x in $p; do is_port "$x" && EXTRA_UDP="${EXTRA_UDP:+$EXTRA_UDP }$x"; done ;;
    3) EXTRA_TCP="" EXTRA_UDP="" ;;
    4) : ;;
    5) remove_firewall; FW_ENABLED=0; save_state; ok "已停用本脚本防火墙（入站不再过滤）。"; return 0 ;;
    6) FW_ENABLED=1; handle_other_firewalls ;;
    *) return 0 ;;
  esac
  save_state
  apply_firewall
  save_state
}

do_uninstall() {
  require_root
  load_state
  warn "将卸载 Xray、Hysteria2、本脚本防火墙规则、调优配置、fail2ban 规则及管理命令。"
  (( OPT_AUTO )) || confirm "确认卸载？" n || return 0
  step "卸载"
  systemctl disable --now xray >/dev/null 2>&1 || true
  systemctl disable --now 'xray@*' >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
  rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
  rm -f "$XRAY_BIN"; rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  ok "Xray 已移除"
  remove_hysteria; ok "Hysteria2 已移除"
  remove_firewall; ok "防火墙规则已移除"
  if [[ -f $F2B_JAIL ]]; then rm -f "$F2B_JAIL"; systemctl restart fail2ban >/dev/null 2>&1 || true; ok "fail2ban 规则已移除（fail2ban 软件包保留）"; fi
  rm -f "$SYSCTL_FILE" "$LIMITS_FILE" "$SYSTEMD_LIMITS_FILE" "$JOURNALD_FILE"
  sysctl --system >/dev/null 2>&1 || true
  systemctl daemon-reexec >/dev/null 2>&1 || true
  systemctl restart systemd-journald >/dev/null 2>&1 || true
  ok "调优配置已移除（BBR 等将在重启后恢复系统默认）"
  local fw
  for fw in $DISABLED_FW; do
    if confirm "安装时停用了 ${fw}，是否重新启用？" y; then
      systemctl enable --now "$fw" >/dev/null 2>&1 || true
      [[ $fw == ufw ]] && { ufw --force enable >/dev/null 2>&1 || true; }
      ok "已重新启用 ${fw}"
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

# ============================================================
#                        菜单 / 参数
# ============================================================
show_menu() {
  load_state
  clear 2>/dev/null || true
  local st="${C_RED}未安装${C_NONE}"
  if (( INSTALLED )); then
    if svc_active xray; then st="${C_GREEN}运行中${C_NONE}"; else st="${C_YELLOW}已安装 (Xray 未运行)${C_NONE}"; fi
  fi
  cat <<MENU
${C_CYAN}============================================================${C_NONE}
   ${C_BOLD}proxy 一键脚本 v${SCRIPT_VERSION}${C_NONE}  VLESS-REALITY-Vision + Hysteria2
   状态: ${st}${SNI:+   SNI: ${C_GREEN}${SNI}${C_NONE}}
${C_CYAN}============================================================${C_NONE}
   ${C_GREEN}1)${C_NONE} 安装 / 重新安装
   ${C_GREEN}2)${C_NONE} 查看链接 / 二维码 / Clash 配置
   ${C_GREEN}3)${C_NONE} 更换 SNI（重新优选目标网站）
   ${C_GREEN}4)${C_NONE} 重新生成密钥 / UUID
   ${C_GREEN}5)${C_NONE} 修改端口 / 端口跳跃
   ${C_GREEN}6)${C_NONE} 用户管理（添加 / 删除）
   ${C_GREEN}7)${C_NONE} 更新 Xray / Hysteria2 / 脚本
   ${C_GREEN}8)${C_NONE} 运行状态 / 日志
   ${C_GREEN}9)${C_NONE} 网络测速 / 延迟提示
  ${C_GREEN}10)${C_NONE} 防火墙管理
  ${C_GREEN}11)${C_NONE} 卸载
   ${C_GREEN}0)${C_NONE} 退出
${C_CYAN}------------------------------------------------------------${C_NONE}
MENU
  local c act=""; ask c "请输入数字" ""
  (( TTY_EOF )) && { echo; exit 0; }
  case $c in
    1) act=do_install ;;
    2) act=show_info ;;
    3) act=menu_change_sni ;;
    4) act=menu_regen_keys ;;
    5) act=menu_change_ports ;;
    6) act=menu_users ;;
    7) act=menu_update ;;
    8) act=menu_status ;;
    9) act=menu_speed ;;
    10) act=menu_firewall ;;
    11) act=do_uninstall ;;
    0|q|Q) exit 0 ;;
    *) warn "请输入正确的数字。"; return 0 ;;
  esac
  # 在子 shell 中执行：出错时返回菜单而不是直接退出
  local rc=0
  set +e
  ( set -e; "$act" )
  rc=$?
  set -e
  (( rc == 0 )) || warn "操作未完成（退出码 ${rc}）。"
  [[ $act == do_uninstall && ! -x $BIN_PATH && ! -f $STATE_FILE ]] && exit 0
  return 0
}

usage() {
  cat <<USAGE
proxy 一键脚本 v${SCRIPT_VERSION} —— VLESS + REALITY + Vision (ML-DSA-65) & Hysteria2

用法: bash proxy.sh [选项]        （安装后可直接使用 proxy [命令/选项]）

安装选项:
  --auto              使用全部默认值自动安装（非交互）
  --sni <域名>        指定 REALITY 目标网站（会进行合规检测）
  --force-sni         与 --sni 一起使用：检测不通过也强制使用
  --scan              使用 RealiTLScanner 扫描 VPS 附近 IP 寻找 SNI（高级，约 60 秒）
  --port <端口>       VLESS-REALITY TCP 端口（默认 443）
  --no-hy2            不安装 Hysteria2
  --hy2-port <端口>   Hysteria2 UDP 端口（默认 443）
  --hop <a-b|none>    Hysteria2 端口跳跃范围（默认 20000-50000，none 关闭）
  --name <名称>       节点名称（默认 国家-城市）
  --no-firewall       不配置 nftables 防火墙
  --no-upgrade        跳过系统软件包升级
  --no-tune           跳过 sysctl 网络调优
  -h, --help          显示帮助

管理命令:
  proxy               打开交互菜单
  proxy info          查看链接 / 二维码 / mihomo 配置
  proxy sni           重新优选 / 更换 SNI
  proxy regen         重新生成全部密钥
  proxy port          修改端口
  proxy user          用户管理
  proxy update        更新组件
  proxy update-script 只更新本脚本
  proxy status        运行状态 / 日志
  proxy speed         测速 / 延迟提示
  proxy firewall      防火墙管理
  proxy uninstall     卸载
USAGE
}

parse_args() {
  while (( $# )); do
    case $1 in
      --auto|-y) OPT_AUTO=1 ;;
      --sni) [[ -n ${2-} ]] || die "--sni 需要参数"; OPT_SNI=$2; shift ;;
      --sni=*) OPT_SNI=${1#*=} ;;
      --force-sni) OPT_FORCE_SNI=1 ;;
      --scan) OPT_SCAN=1 ;;
      --port) is_port "${2-}" || die "--port 参数无效"; OPT_PORT=$2; shift ;;
      --port=*) OPT_PORT=${1#*=}; is_port "$OPT_PORT" || die "--port 参数无效" ;;
      --no-hy2) OPT_HY2=0 ;;
      --hy2) OPT_HY2=1 ;;
      --hy2-port) is_port "${2-}" || die "--hy2-port 参数无效"; OPT_HY2_PORT=$2; shift ;;
      --hop) [[ ${2-} == none ]] || is_range "${2-}" || die "--hop 参数无效（例如 20000-50000 或 none）"; OPT_HOP=$2; shift ;;
      --no-hop) OPT_HOP=none ;;
      --name) [[ -n ${2-} ]] || die "--name 需要参数"; OPT_NAME=$(tr -cd 'A-Za-z0-9_.-' <<<"$2"); shift ;;
      --no-firewall) OPT_FIREWALL=0 ;;
      --no-upgrade) OPT_UPGRADE=0 ;;
      --no-tune) OPT_TUNE=0 ;;
      -h|--help|help) usage; exit 0 ;;
      -v|--version|version) echo "$SCRIPT_VERSION"; exit 0 ;;
      install) OPT_ACTION=install ;;
      info|link|links|qr) OPT_ACTION=info ;;
      sni) OPT_ACTION=sni ;;
      regen|rekey) OPT_ACTION=regen ;;
      port|ports) OPT_ACTION=port ;;
      user|users) OPT_ACTION=user ;;
      update|upgrade) OPT_ACTION=update ;;
      update-script) OPT_ACTION=update-script ;;
      status|log|logs) OPT_ACTION=status ;;
      speed) OPT_ACTION=speed ;;
      firewall|fw) OPT_ACTION=firewall ;;
      uninstall|remove) OPT_ACTION=uninstall ;;
      *) usage; die "未知参数: $1" ;;
    esac
    shift
  done
  # 仅传了安装相关参数时默认执行安装
  if [[ -z $OPT_ACTION ]] && { (( OPT_AUTO )) || [[ -n $OPT_SNI || -n $OPT_PORT || -n $OPT_HY2 || -n $OPT_HOP ]]; }; then
    OPT_ACTION=install
  fi
}

main() {
  parse_args "$@"
  require_root
  mktmp
  case $OPT_ACTION in
    install) do_install ;;
    info) show_info ;;
    sni) menu_change_sni ;;
    regen) menu_regen_keys ;;
    port) menu_change_ports ;;
    user) menu_users ;;
    update) menu_update ;;
    update-script) update_script ;;
    status) menu_status ;;
    speed) menu_speed ;;
    firewall) menu_firewall ;;
    uninstall) do_uninstall ;;
    "")
      if [[ ! -t 0 && ! -r /dev/tty ]]; then usage; die "非交互环境请使用 --auto。"; fi
      while :; do show_menu; pause; done ;;
  esac
}

# 允许被 source 用于测试
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" || "${BASH_SOURCE[0]}" == /dev/fd/* || "${BASH_SOURCE[0]}" == /proc/self/fd/* ]]; then
  main "$@"
fi
