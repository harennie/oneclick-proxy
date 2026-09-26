#!/usr/bin/env bash
#
# proxy.sh —— VLESS + REALITY + Vision (ML-DSA-65) & Hysteria2 一键安装 / 管理脚本
#
# 用法:
#   bash proxy.sh                 # 交互式菜单
#   bash proxy.sh --auto          # 全部默认值自动安装
#   bash proxy.sh --nat           # NAT 小鸡模式（端口映射 / LXC / OpenVZ / Alpine）
#   bash proxy.sh --help          # 查看全部参数
# 安装完成后可直接使用命令: proxy
#
# 支持: Debian 11/12/13, Ubuntu 20.04+, Rocky/Alma/CentOS Stream 8/9(+), RHEL, Fedora (systemd, amd64/arm64)
#       NAT 模式 (--nat) 另支持 Alpine 3.18+ (OpenRC) 及 armv7
#
# shellcheck disable=SC2317  # 通过 trap / 菜单间接调用的函数

set -o errexit -o pipefail -o errtrace
umask 022
export LC_ALL=C.UTF-8 2>/dev/null || true
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

readonly SCRIPT_VERSION="1.1.1"
# 发布后请把这里改成你仓库的 raw 地址（用于 `proxy update-script` 及 bash <(curl ...) 安装时自我安装）
# 可用环境变量 PROXY_SCRIPT_URL 覆盖（镜像 / 测试用）
readonly SCRIPT_URL="${PROXY_SCRIPT_URL:-https://raw.githubusercontent.com/harennie/oneclick-proxy/main/proxy.sh}"

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
# NAT 模式
readonly XRAY_ASSET_DIR="/usr/local/share/xray"
readonly XRAY_UNIT="/etc/systemd/system/xray.service"
readonly HY_UNIT="/etc/systemd/system/hysteria-server.service"
readonly XRAY_RC="/etc/init.d/xray"
readonly HY_RC="/etc/init.d/hysteria-server"
readonly XRAY_LOG="/var/log/xray/xray.log"
readonly HY_LOG="/var/log/hysteria/hysteria.log"
readonly HOP_SCRIPT="${STATE_DIR}/nat-hop.sh"
readonly HOP_UNIT="/etc/systemd/system/proxy-oneclick-hop.service"
readonly HOP_RC="/etc/init.d/proxy-oneclick-hop"
readonly HOP_TABLE="proxy_oneclick_hop"
readonly RESOLV_BAK="${STATE_DIR}/resolv.conf.bak"
# 公共 DNS64 服务器（nat64.net / Trex），仅在 IPv6-only 且用户同意时写入 /etc/resolv.conf
readonly DNS64_SERVERS="2a00:1098:2b::1 2a00:1098:2c::1 2a01:4f8:c2c:123f::1"
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
OPT_UPGRADE=""      # 空=默认（普通模式 1，NAT 模式 0）
OPT_TUNE=""         # 空=默认（普通模式 1，NAT 模式 0）
OPT_SCAN=0
OPT_NAME=""
OPT_ACTION=""
OPT_NAT=""          # 空=沿用已安装的模式; 1/0
OPT_NAT_ADDR=""
OPT_NAT_EXT=""      # 映射端口列表 --nat-ports（外部[:内部]，逗号分隔；或整段 a-b[:c-d]）
OPT_NAT_EXCLUDE=""  # 端口段内需要排除的外部端口（例如 SSH 映射）
OPT_NAT_SHARE=""    # 1 = Reality(TCP) 与 Hy2(UDP) 共用一个外部端口；0 = 分开
OPT_DNS64=0

# 运行时变量（部分持久化到 STATE_FILE）
OS_ID="" OS_VER="" OS_NAME="" PKG="" ARCH=""
PUBLIC_IP4="" PUBLIC_IP6="" GEO_CC="" GEO_REGION="" GEO_CITY="" GEO_ORG=""
TMP_DIR=""
INIT_SYS=""         # systemd | openrc | none
NO_V4=0             # 1 = 没有 IPv4 出口（IPv6-only / NAT64）
IPFAM=4             # 探测 / 测速使用的地址族
FETCH_IP=()         # 传给 curl 的地址族参数（IPv6-only 时为 -6）

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
  printf '%s如需帮助，请带上以上信息及服务日志（journalctl -xe 或 /var/log/xray、/var/log/hysteria）反馈。重新运行本脚本是安全的（幂等）。%s\n' "$C_YELLOW" "$C_NONE" >&2
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
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | awk 'NR==1')" == "$2" ]]; }
fetch() { curl -fsSL "${FETCH_IP[@]}" --connect-timeout 10 --retry 2 --retry-delay 2 "$@"; }
host_fmt() { [[ $1 == *:* ]] && printf '[%s]' "$1" || printf '%s' "$1"; }

# ----------------------------- 服务管理（systemd / OpenRC 抽象） -----------------------------
detect_init() {
  if [[ -d /run/systemd/system ]] && have systemctl; then INIT_SYS=systemd
  elif have openrc-run || have rc-service; then INIT_SYS=openrc
  else INIT_SYS=none; fi
}
is_openrc() { [[ $INIT_SYS == openrc ]]; }
openrc_ready() { # 非 OpenRC 引导的精简容器缺少 softlevel 时 rc-service 会拒绝工作
  is_openrc || return 0
  if [[ ! -e /run/openrc/softlevel ]]; then
    warn "OpenRC 尚未初始化（/run/openrc/softlevel 不存在），已自动补齐；建议确认容器以 /sbin/init 启动，否则重启后服务可能不会自启。"
    mkdir -p /run/openrc && touch /run/openrc/softlevel
  fi
}
svc_log_file() { case $1 in xray) printf '%s' "$XRAY_LOG" ;; hysteria-server) printf '%s' "$HY_LOG" ;; esac; }
svc_exists() {
  if is_openrc; then [[ -x /etc/init.d/$1 ]]; else systemctl cat "$1" >/dev/null 2>&1; fi
}
svc_active() {
  if is_openrc; then [[ -x /etc/init.d/$1 ]] && rc-service --quiet "$1" status >/dev/null 2>&1
  else systemctl is-active --quiet "$1" 2>/dev/null; fi
}
svc_state() { # 输出 active / inactive / failed ... ；未安装输出 none
  svc_exists "$1" || { echo none; return 0; }
  if is_openrc; then
    if svc_active "$1"; then echo active
    else rc-service "$1" status 2>/dev/null | awk -F': *' '/status/{print $NF; f=1} END{if(!f) print "inactive"}' | tail -n1; fi
  else
    systemctl is-active "$1" 2>/dev/null || true
  fi
}
sd_reload() { [[ $INIT_SYS == systemd ]] && systemctl daemon-reload >/dev/null 2>&1; return 0; }
svc_enable() {
  if is_openrc; then rc-update add "$1" default >/dev/null 2>&1 || true
  else systemctl enable "$1" >/dev/null 2>&1 || true; fi
}
svc_restart() {
  # 9>&- ：不要把脚本的锁文件描述符继承给常驻的 supervise-daemon（否则锁永远不会释放）
  if is_openrc; then rc-service "$1" restart >/dev/null 2>&1 9>&- || rc-service "$1" start >/dev/null 2>&1 9>&-
  else systemctl restart "$1"; fi
}
svc_disable_stop() { # 停止并取消开机自启（不存在时静默）
  if is_openrc; then
    [[ -x /etc/init.d/$1 ]] || return 0
    rc-service "$1" stop >/dev/null 2>&1 || true
    rc-update del "$1" default >/dev/null 2>&1 || true
  elif have systemctl; then
    systemctl disable --now "$1" >/dev/null 2>&1 || true
  fi
  return 0
}
svc_logs() { # $1 服务 $2 行数
  if is_openrc; then
    local f; f=$(svc_log_file "$1")
    if [[ -n $f && -s $f ]]; then tail -n "${2:-80}" "$f"; else warn "暂无日志（${f:-$1}）。"; fi
  else
    journalctl -u "$1" -n "${2:-80}" --no-pager
  fi
}
svc_follow() {
  if is_openrc; then
    local f; f=$(svc_log_file "$1"); [[ -n $f ]] || return 0
    info "按 Ctrl+C 退出（日志文件 ${f}）"; tail -n 20 -f "$f"
  else
    journalctl -u "$1" -f
  fi
}

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户运行本脚本（例如: sudo -i 后再执行）。"; }

take_lock() {
  have flock || return 0
  exec 9>/run/proxy-oneclick.lock
  flock -n 9 || die "另一个 proxy 脚本实例正在运行，请稍后再试。"
}

# ----------------------------- 状态持久化 -----------------------------
# 持久化的键
STATE_KEYS=(INSTALLED XRAY_PORT UUID PRIV_KEY PUB_KEY SHORT_ID MLDSA_SEED MLDSA_VERIFY MLDSA_ON SNI SNI_TARGET
            HY2_ENABLED HY2_PORT HY2_PASS HY2_PIN HOP_RANGE NODE_NAME FW_ENABLED SSH_PORTS
            EXTRA_TCP EXTRA_UDP DISABLED_FW SWAP_CREATED SERVER_ADDR
            NAT_MODE NAT_PORTS NAT_EXCLUDE XRAY_EXT_PORT HY2_EXT_PORT HOP_EXT_RANGE
            HOP_BACKEND VIRT DNS64_SET)
INSTALLED=0 XRAY_PORT=443 UUID="" PRIV_KEY="" PUB_KEY="" SHORT_ID="" MLDSA_SEED="" MLDSA_VERIFY="" MLDSA_ON=1 SNI="" SNI_TARGET=""
HY2_ENABLED=1 HY2_PORT=443 HY2_PASS="" HY2_PIN="" HOP_RANGE="20000-50000" NODE_NAME="" FW_ENABLED=1 SSH_PORTS=""
EXTRA_TCP="" EXTRA_UDP="" DISABLED_FW="" SWAP_CREATED=0 SERVER_ADDR=""
NAT_MODE=0 NAT_PORTS="" NAT_EXCLUDE="" XRAY_EXT_PORT="" HY2_EXT_PORT="" HOP_EXT_RANGE=""
HOP_BACKEND="" VIRT="" DNS64_SET=0

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
      direct_mode || die "不支持的 CPU 架构: $(uname -m)（普通模式仅支持 amd64 / arm64；armv7 请使用 --nat）"
      ARCH=armv7 ;;
    *) die "不支持的 CPU 架构: $(uname -m)（仅支持 amd64 / arm64$(direct_mode && echo ' / armv7')）" ;;
  esac
}

# Alpine：仅 NAT 模式支持（musl + OpenRC，官方安装脚本不支持，改为直接下载二进制）
alpine_check() {
  ver_ge "$OS_VER" "3.18" || refuse_os "Alpine ${OS_VER} 版本过旧，NAT 模式需要 Alpine 3.18 及以上。"
  [[ $INIT_SYS == openrc ]] || refuse_os "Alpine 未检测到 OpenRC（缺少 openrc-run / rc-service），请先执行: apk add openrc"
  if (( ! NAT_MODE )); then
    warn "Alpine（musl + OpenRC）只支持 NAT / 精简模式（--nat）：直接下载官方二进制、使用 OpenRC 服务、跳过调优/防火墙/fail2ban。"
    if [[ $OPT_NAT == 0 ]] || (( OPT_AUTO )) || ! confirm "是否以 NAT 模式继续安装？" y; then
      printf '%s[错误]%s Alpine 请使用: bash proxy.sh --nat（自动安装: bash proxy.sh --nat --auto --nat-ports 公网端口[:内部端口]）\n' "$C_RED" "$C_NONE" >&2
      exit 1
    fi
    NAT_MODE=1
  fi
}

# 直接从 GitHub Releases 下载二进制（NAT 模式或 Alpine）
direct_mode() { (( NAT_MODE )) || [[ $OS_ID == alpine ]]; }

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
# 总预算约为内存上限的 60%，启用 Hysteria2 时由 xray / hysteria 平分（软限制，超出时只是更积极地 GC）
go_mem_env() {
  local m n=1; m=$(mem_limit_mb)
  (( m > 0 && m < 256 )) || return 0
  (( HY2_ENABLED )) && n=2
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
  ok "依赖安装完成（NAT 精简模式）。"
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
  step "时间同步（REALITY 需要准确的系统时间）"
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
  info "系统: ${OS_NAME} / 架构: ${ARCH} / 包管理: ${PKG} / init: ${INIT_SYS}$( ((NAT_MODE)) && echo ' / NAT 模式')"
}
pkg_bootstrap_curl() {
  if [[ $PKG == apk ]]; then apk add --no-cache curl ca-certificates >/dev/null
  elif [[ $PKG == apt ]]; then apt-get update -qq && pkg_install curl ca-certificates; else pkg_install curl ca-certificates; fi
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
#       证书链有效；不在 CDN / WAF 后面（Cloudflare、Imperva、Fastly、Akamai、CloudFront、Azure Front Door 等）；
#       不是被墙网站/大厂默认域名。支持 X25519MLKEM768（后量子）的目标优先，但不是硬性要求。
# 候选列表按地区组织（以大学及本地中型网站为主），运行时在 VPS 上逐一实测。
# v1.1.1：已剔除响应头显示使用 CDN/WAF 的候选；SG / PH 本地自建站点很少，合格数不足时自动扩大到邻近地区。
sni_candidates() { # $1 = 地区键
  case $1 in
    US-CA)  echo "www.csun.edu www.cpp.edu www.uci.edu www.ucsd.edu www.stanford.edu www.sjsu.edu www.chapman.edu www.lmu.edu" ;;
    US-NW)  echo "www.washington.edu www.uw.edu www.wsu.edu www.unr.edu www.utah.edu" ;;
    US-SW)  echo "www.nau.edu www.unm.edu www.utah.edu www.colorado.edu" ;;
    US-TX)  echo "www.uh.edu www.smu.edu www.tcu.edu www.utdallas.edu www.unt.edu www.utsa.edu www.ou.edu" ;;
    US-OH)  echo "www.miamioh.edu www.bgsu.edu www.utoledo.edu www.wayne.edu www.purdue.edu www.iu.edu www.pitt.edu www.cmu.edu www.louisville.edu" ;;
    US-IL)  echo "www.uchicago.edu www.northwestern.edu www.uic.edu www.depaul.edu www.slu.edu www.ku.edu www.unl.edu" ;;
    US-EAST) echo "www.virginia.edu www.vcu.edu www.jmu.edu www.udel.edu www.duke.edu" ;;
    US-NE)  echo "www.cornell.edu www.rutgers.edu www.rochester.edu www.temple.edu www.drexel.edu www.bu.edu www.northeastern.edu www.tufts.edu www.yale.edu" ;;
    US-SE)  echo "www.emory.edu www.ufl.edu www.miami.edu www.usf.edu www.fiu.edu www.sc.edu www.clemson.edu www.lsu.edu" ;;
    CA)     echo "www.yorku.ca www.torontomu.ca www.mcmaster.ca www.queensu.ca www.carleton.ca www.mcgill.ca www.concordia.ca www.umontreal.ca www.ulaval.ca www.sfu.ca www.uvic.ca www.ucalgary.ca www.umanitoba.ca www.usask.ca" ;;
    MX)     echo "www.tec.mx www.ipn.mx www.udg.mx www.uanl.mx www.ibero.mx" ;;
    BR)     echo "www.usp.br www.ufrj.br www.unesp.br www.ufmg.br www.puc-rio.br www.ufsc.br" ;;
    JP)     echo "www.u-tokyo.ac.jp www.osaka-u.ac.jp www.titech.ac.jp www.isct.ac.jp www.tohoku.ac.jp www.nagoya-u.ac.jp www.kyushu-u.ac.jp www.hokudai.ac.jp www.hit-u.ac.jp www.ritsumei.ac.jp www.kobe-u.ac.jp www.chiba-u.ac.jp www.ynu.ac.jp" ;;
    KR)     echo "www.snu.ac.kr www.kaist.ac.kr www.yonsei.ac.kr www.korea.ac.kr www.postech.ac.kr www.skku.edu www.hanyang.ac.kr www.kyunghee.ac.kr www.ewha.ac.kr www.sogang.ac.kr www.cau.ac.kr www.pusan.ac.kr www.unist.ac.kr" ;;
    HK)     echo "my.hkust.edu.hk factsfigures.cuhk.edu.hk dsbs.cuhk.edu.hk rmda.cuhk.edu.hk" ;; # 后两个 HSTS 仅 300s，放最后
    TW)     echo "www.ntu.edu.tw www.nthu.edu.tw www.ncku.edu.tw www.nccu.edu.tw www.ntnu.edu.tw www.ncu.edu.tw www.ntust.edu.tw www.fju.edu.tw www.tku.edu.tw" ;;
    SG)     echo "www.ntuc.org.sg www.uob.com.sg www.sgnog.org www.curtin.edu.sg" ;;
    MY)     echo "www.um.edu.my www.ukm.my www.upm.edu.my www.usm.my www.utm.my www.taylors.edu.my www.sunway.edu.my" ;;
    TH)     echo "www.mahidol.ac.th www.ku.ac.th www.tu.ac.th www.cmu.ac.th www.kmutt.ac.th" ;;
    VN)     echo "www.hust.edu.vn www.vnu.edu.vn www.hcmus.edu.vn www.ueh.edu.vn" ;;
    ID)     echo "www.ui.ac.id www.itb.ac.id www.ugm.ac.id www.binus.ac.id www.its.ac.id www.unair.ac.id" ;;
    PH)     echo "www.pup.edu.ph www.upd.edu.ph www.feu.edu.ph" ;;
    IN)     echo "www.iitb.ac.in www.iitd.ac.in www.iitm.ac.in www.iisc.ac.in www.iitk.ac.in www.du.ac.in www.jnu.ac.in www.bits-pilani.ac.in www.amity.edu" ;;
    AU)     echo "www.rmit.edu.au www.anu.edu.au www.uq.edu.au" ;;
    NZ)     echo "www.wgtn.ac.nz" ;;
    DE)     echo "www.tum.de www.lmu.de www.uni-heidelberg.de www.fu-berlin.de www.hu-berlin.de www.tu-berlin.de www.kit.edu www.rwth-aachen.de www.goethe-university-frankfurt.de www.tu-darmstadt.de www.uni-mainz.de www.uni-koeln.de www.uni-bonn.de www.uni-hamburg.de www.tu-dresden.de www.uni-muenster.de www.uni-goettingen.de" ;;
    NL)     echo "www.uva.nl www.vu.nl www.uu.nl www.universiteitleiden.nl www.rug.nl www.ru.nl www.utwente.nl www.eur.nl www.maastrichtuniversity.nl" ;;
    GB)     echo "www.imperial.ac.uk www.kcl.ac.uk www.lse.ac.uk www.gre.ac.uk www.gla.ac.uk www.leeds.ac.uk www.sheffield.ac.uk www.bristol.ac.uk www.birmingham.ac.uk www.nottingham.ac.uk www.warwick.ac.uk www.soton.ac.uk" ;;
    FR)     echo "www.u-paris.fr www.universite-paris-saclay.fr www.psl.eu www.ens.psl.eu www.polytechnique.edu www.sciencespo.fr www.univ-lyon1.fr www.univ-grenoble-alpes.fr www.unistra.fr www.univ-amu.fr www.u-bordeaux.fr www.univ-lille.fr www.univ-tlse3.fr www.insa-lyon.fr www.centralesupelec.fr" ;;
    IE)     echo "www.tudublin.ie www.ucc.ie" ;;
    BE)     echo "www.kuleuven.be www.uantwerpen.be www.ulb.be www.uclouvain.be www.vub.be www.uliege.be" ;;
    CH)     echo "www.ethz.ch www.uzh.ch www.unibe.ch www.unibas.ch www.unige.ch www.unil.ch www.zhaw.ch" ;;
    AT)     echo "www.univie.ac.at www.tuwien.at www.meduniwien.ac.at www.uibk.ac.at www.tugraz.at www.uni-graz.at www.jku.at" ;;
    IT)     echo "www.polimi.it www.uniroma1.it www.unibo.it www.polito.it www.unina.it" ;;
    ES)     echo "www.uam.es www.ucm.es www.upm.es www.uc3m.es www.ub.edu www.uab.cat www.upc.edu www.uv.es www.us.es" ;;
    PL)     echo "www.uw.edu.pl www.pw.edu.pl www.uj.edu.pl www.agh.edu.pl www.put.poznan.pl www.pwr.edu.pl www.umk.pl" ;;
    SE)     echo "www.kth.se www.su.se www.ki.se www.uu.se www.lu.se www.gu.se www.liu.se" ;;
    FI)     echo "www.tuni.fi www.utu.fi www.oulu.fi www.jyu.fi" ;;
    NO)     echo "www.uio.no www.ntnu.no www.uib.no www.oslomet.no www.uit.no" ;;
    DK)     echo "www.dtu.dk www.sdu.dk www.aau.dk www.cbs.dk" ;;
    CZ)     echo "www.cuni.cz www.cvut.cz www.muni.cz www.vutbr.cz www.vse.cz" ;;
    RU)     echo "www.msu.ru www.hse.ru www.spbu.ru www.itmo.ru www.mipt.ru www.bmstu.ru" ;;
    TR)     echo "www.boun.edu.tr www.metu.edu.tr www.itu.edu.tr www.bilkent.edu.tr www.sabanciuniv.edu" ;;
    AE)     echo "www.uaeu.ac.ae www.ku.ac.ae www.zu.ac.ae www.hct.ac.ae" ;;
    IL)     echo "www.tau.ac.il www.huji.ac.il www.technion.ac.il www.weizmann.ac.il www.bgu.ac.il" ;;
    ZA)     echo "www.wits.ac.za www.sun.ac.za" ;;
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

# 根据响应头识别 CDN / WAF（$1 = curl -D 保存的响应头文件，可含多次跳转）。
# 命中时输出 CDN 名称并返回 0。只用 tr + grep -iE，兼容 busybox（Alpine / NAT 模式）。
SNI_CDN_RULES=(
  'Cloudflare|^(server:[[:space:]]*cloudflare|cf-ray:|cf-cache-status:|cf-mitigated:)'
  'Imperva/Incapsula|^(x-iinfo:|x-cdn:[[:space:]]*(imperva|incapsula)|set-cookie:.*(incap_ses|visid_incap))'
  'Fastly|^(x-served-by:.*cache-|x-fastly-|fastly-|via:.*varnish)'
  'Akamai|^(server:[[:space:]]*akamai|x-akamai-|akamai-)'
  'CloudFront|^(via:.*cloudfront|x-amz-cf-|x-cache:.*cloudfront)'
  'Azure Front Door|^(x-azure-ref|x-msedge-ref)'
  'Sucuri|^(server:[[:space:]]*sucuri|x-sucuri-)'
  'BunnyCDN|^(server:[[:space:]]*bunnycdn|cdn-pullzone:)'
)
sni_cdn_detect() { # $1 响应头文件
  [[ -s $1 ]] || return 1
  local h rule
  h=$(tr -d '\r' <"$1" 2>/dev/null) || return 1
  for rule in "${SNI_CDN_RULES[@]}"; do
    if printf '%s\n' "$h" | grep -qiE "${rule#*|}"; then echo "${rule%%|*}"; return 0; fi
  done
  return 1
}

# 目标是否支持后量子密钥交换 X25519MLKEM768（新版 Xray 客户端的 uTLS 指纹默认携带）。
# 这是「优先」条件而非硬性要求：支持的目标排在前面；不支持的目标只给出警告，仍可使用。
# 用已安装的 xray 自带的 `xray tls ping` 检测；返回 0=支持 1=明确不支持 2=无法判断（xray 未安装/网络失败）
# 同时记录证书链总长度到全局 SNI_CHAIN_LEN（ML-DSA-65 需要 ≥ 3500 字节，见 mldsa_decide）。
SNI_CHAIN_LEN=""
sni_pq_check() { # $1 域名 [$2 IP]
  SNI_CHAIN_LEN=""
  [[ -x $XRAY_BIN ]] || return 2
  local out pq
  out=$(timeout 12 "$XRAY_BIN" tls ping ${2:+-ip "$2"} "$1" 2>&1) || true
  SNI_CHAIN_LEN=$(awk '/Pinging with SNI/{f=1} f && /total length:/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}' <<<"$out")
  pq=$(awk '/Pinging with SNI/{f=1} f && /Post-Quantum key exchange:/{print; exit}' <<<"$out")
  [[ -n $pq ]] || return 2
  [[ $pq == *true* ]] && return 0
  return 1
}

# ML-DSA-65 (pqv) 要求目标证书链总长度 ≥ 3500 字节，否则服务端 REALITY 握手失败（所有客户端都连不上，
# 与客户端是否填写 pqv 无关）。按当前 SNI 决定是否启用：不满足时仅对该目标关闭 pqv，REALITY 本身照常。
MLDSA_MIN_CHAIN=3500
mldsa_decide() {
  MLDSA_ON=1
  [[ -n $MLDSA_SEED && -n $SNI ]] || return 0
  sni_pq_check "$SNI" || true
  if [[ $SNI_CHAIN_LEN =~ ^[0-9]+$ ]] && (( SNI_CHAIN_LEN < MLDSA_MIN_CHAIN )); then
    MLDSA_ON=0
    warn "目标 ${SNI} 证书链总长度 ${SNI_CHAIN_LEN} 字节 < ${MLDSA_MIN_CHAIN}，无法使用 ML-DSA-65 后量子签名，已对该目标关闭 pqv（REALITY 本身不受影响）。"
  fi
  return 0
}
# 当前是否在链接 / 配置中使用 pqv
pqv_active() { [[ -n $MLDSA_VERIFY && -n $MLDSA_SEED && ${MLDSA_ON:-1} != 0 ]]; }

# 探测单个候选域名。输出一行:
#   PASS|域名|TCP延迟ms|TLS握手完成ms|IP|国家|城市|ASN|PQ|证书链长度
#   （PQ: Y=支持 X25519MLKEM768 N=不支持 ?=无法判断；证书链长度 ≥ 3500 才能启用 ML-DSA-65 pqv，?=无法判断）
#   FAIL|域名|原因
sni_probe() {
  local host=${1,,} ip4s ip6s ip first out hdr w ver tconn tapp code best=999999 tls_ms geo cc="" city="" org=""
  host=${host%.}
  [[ $host =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || { echo "FAIL|$host|域名格式无效"; return; }
  if sni_blacklisted "$host"; then echo "FAIL|$host|大厂/被墙/CDN/国内域名（黑名单）"; return; fi
  ip4s=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u) || true
  ip6s=$(getent ahostsv6 "$host" 2>/dev/null | awk '$1 ~ /:/ && $1 !~ /^::ffff:/ {print $1}' | sort -u) || true
  if (( IPFAM == 6 )); then
    [[ -n $ip6s ]] || { echo "FAIL|$host|无 IPv6 解析（IPv6-only 机器需目标支持 IPv6 或配置 DNS64）"; return; }
  else
    [[ -n $ip4s ]] || { echo "FAIL|$host|无 IPv4 解析"; return; }
  fi
  for ip in $ip4s; do in_cf_v4 "$ip" && { echo "FAIL|$host|解析到 Cloudflare IP ($ip)"; return; }; done
  for ip in $ip6s; do in_cf_v6 "$ip" && { echo "FAIL|$host|解析到 Cloudflare IPv6 ($ip)"; return; }; done
  local conn
  if (( IPFAM == 6 )); then first=$(head -n1 <<<"$ip6s"); conn="[${first}]:443"
  else first=$(head -n1 <<<"$ip4s"); conn="${first}:443"; fi

  out=$(timeout 12 openssl s_client -connect "$conn" -servername "$host" -tls1_3 -groups X25519 -alpn h2 \
        -verify_return_error -verify_hostname "$host" </dev/null 2>&1) || true
  grep -q 'TLSv1.3' <<<"$out" || { echo "FAIL|$host|不支持 TLS1.3 / X25519"; return; }
  grep -q 'ALPN protocol: h2' <<<"$out" || { echo "FAIL|$host|不支持 ALPN h2"; return; }
  grep -q 'Verify return code: 0 (ok)' <<<"$out" || { echo "FAIL|$host|证书链/域名校验失败"; return; }

  hdr=$(mktemp)
  w=$(curl "-${IPFAM}" -sS -o /dev/null -D "$hdr" --http2 -L --max-redirs 3 --connect-timeout 5 -m 15 -A "$UA" \
        -w '%{http_version} %{time_connect} %{time_appconnect} %{http_code}' "https://${host}/" 2>/dev/null) || true
  read -r ver tconn tapp code <<<"$w"
  if [[ -z $code || $code == 000 ]]; then rm -f "$hdr"; echo "FAIL|$host|HTTPS 请求失败"; return; fi
  local cdn=""
  cdn=$(sni_cdn_detect "$hdr") || cdn=""
  if [[ -n $cdn ]]; then rm -f "$hdr"; echo "FAIL|$host|响应头显示使用 CDN/WAF（${cdn}）"; return; fi
  if ! grep -qi '^strict-transport-security:' "$hdr"; then rm -f "$hdr"; echo "FAIL|$host|无 HSTS 响应头"; return; fi
  rm -f "$hdr"
  [[ $ver == 2 ]] || { echo "FAIL|$host|HTTP/2 协商失败 (HTTP/$ver)"; return; }

  # 后量子 X25519MLKEM768：仅作排序偏好，不再因此淘汰
  local pqrc=0 pq="?"
  sni_pq_check "$host" "$first" || pqrc=$?
  case $pqrc in 0) pq=Y ;; 1) pq=N ;; esac

  # 延迟：TCP 建连 (≈1 RTT) 与 TLS 握手完成时间，各取 3 次中的最小值
  local i best_tls=999999 t_ms a_ms
  for i in 0 1 2; do
    if (( i > 0 )); then
      w=$(curl "-${IPFAM}" -sS -o /dev/null -I --http2 --connect-timeout 5 -m 8 -A "$UA" -w '%{time_connect} %{time_appconnect}' "https://${host}/" 2>/dev/null) || true
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
  echo "PASS|$host|$best|$tls_ms|$first|$cc|$city|$org|$pq|${SNI_CHAIN_LEN:-?}"
}

# NAT 模式（小内存）降低并发并减少候选数量
SNI_PAR=10
sni_cap() { # 输出候选列表（NAT 模式最多 12 个）
  if (( NAT_MODE )); then tr ' ' '\n' <<<"$*" | awk 'NF && ++n <= 12' | tr '\n' ' '; else printf '%s' "$*"; fi
}
# 并发测试一组域名，结果写入 $1 文件
sni_test_list() {
  local outfile=$1; shift
  local h n=0 total=$#
  mktmp
  load_cf_ranges
  local dir; dir=$(mktemp -d "${TMP_DIR}/probe.XXXXXX")
  for h in "$@"; do
    n=$((n + 1))
    while (( $(jobs -rp | wc -l) >= SNI_PAR )); do wait -n 2>/dev/null || true; done
    ( trap - ERR; set +e; sni_probe "$h" >"${dir}/${n}.res" 2>/dev/null ) &
    printf '\r  正在检测 %d/%d ...' "$n" "$total"
  done
  wait || true
  printf '\r%-40s\r' " "
  cat "${dir}"/*.res 2>/dev/null >"$outfile" || : >"$outfile"
}

# 排序：同国家优先，其次支持 X25519MLKEM768 优先（Y > ? > N），再证书链 ≥ 3500（可用 pqv）优先，最后按 TLS 握手 / TCP 延迟
sni_sorted_pass() { # $1 结果文件
  awk -F'|' -v cc="$GEO_CC" -v min="$MLDSA_MIN_CHAIN" '$1=="PASS"{s=($6==cc || cc=="")?0:1; p=($9=="Y")?0:(($9=="N")?2:1)
      c=($10 ~ /^[0-9]+$/ && $10+0 < min+0)?1:0; print s"|"p"|"c"|"$0}' "$1" |
    sort -t'|' -k1,1n -k2,2n -k3,3n -k7,7n -k6,6n | cut -d'|' -f4-
}
# PQ 字段显示文字
sni_pq_label() { case $1 in Y) echo "支持" ;; N) echo "不支持" ;; *) echo "未知" ;; esac; }
# 选定的 SNI 不支持 X25519MLKEM768 时的提示（$1 域名 $2 PQ 字段）
sni_pq_warn() {
  [[ $2 == N ]] || return 0
  warn "${1} 不支持后量子密钥交换 X25519MLKEM768：其余检测均通过，REALITY 可正常使用，只是没有后量子密钥交换保护。"
  warn "  以后可用 proxy sni 换成支持 MLKEM 的目标（安装后的 REALITY 自检会验证实际可用性）。"
}

sni_print_table() { # $1 = 已排序 PASS 列表文件, $2 = 显示条数
  local i=0 line host rtt tls ip cc city org pq chain
  printf '  %-4s %-30s %-9s %-9s %-6s %-6s %-16s %s\n' "No." "Domain(域名)" "TCP-RTT" "TLS-HS" "MLKEM" "Chain" "IP" "位置 / ASN"
  while IFS='|' read -r _ host rtt tls ip cc city org pq chain; do
    i=$((i + 1)); (( i > $2 )) && break
    local mark=""; [[ -n $GEO_CC && -n $cc && $cc != "$GEO_CC" ]] && mark="${C_YELLOW}(异国)${C_NONE}"
    local pqm="?"; [[ $pq == Y ]] && pqm="yes"; [[ $pq == N ]] && pqm="no"
    printf '  %-4s %-30s %-9s %-9s %-6s %-6s %-16s %s %s %s\n' "$i)" "$host" "${rtt}ms" "${tls}ms" "$pqm" "${chain:-?}" "$ip" "${cc}/${city}" "${org:0:28}" "$mark"
  done <"$1"
}

# 解析 RealiTLScanner CSV：按表头定位列，筛选 TLS1.3 + h2，去掉通配符/黑名单域名
scanner_parse() {
  local dom
  awk -F',' 'NR==1{for(i=1;i<=NF;i++){gsub(/"/,"",$i); c[$i]=i}; next}
    { tls=(c["TLS"] ? $(c["TLS"]) : "TLS 1.3"); alpn=(c["ALPN"] ? $(c["ALPN"]) : "h2"); d=$(c["CERT_DOMAIN"]); gsub(/"/,"",d)
      if (tls ~ /1\.3/ && alpn=="h2" && d !~ /^\*/ && d ~ /\./) print tolower(d) }' "$1" | sort -u |
    while read -r dom; do sni_blacklisted "$dom" || echo "$dom"; done | awk 'NR <= 40'
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
      SNI=${OPT_SNI,,}; ok "SNI ${SNI} 通过检测（TLS 握手 $(cut -d'|' -f4 <<<"$r")ms，X25519MLKEM768: $(sni_pq_label "$(cut -d'|' -f9 <<<"$r")")）。"
      sni_pq_warn "$SNI" "$(cut -d'|' -f9 <<<"$r")"
      return 0
    fi
    warn "SNI ${OPT_SNI} 未通过检测：$(cut -d'|' -f3 <<<"$r")"
    if (( OPT_FORCE_SNI )); then warn "已指定 --force-sni，仍然使用。"; SNI=${OPT_SNI,,}; return 0; fi
    (( OPT_AUTO )) && die "指定的 SNI 不合格。如确认要使用，请追加 --force-sni。"
  fi

  keys=$(sni_region_keys)
  main=${keys%%|*} near=${keys#*|}
  step "自动优选 REALITY 目标网站 (SNI)"
  if (( NAT_MODE )); then
    SNI_PAR=3
    (( OPT_SCAN )) && { warn "NAT 模式不支持 --scan（节省资源，且 NAT 机器扫描邻居 IP 意义不大），已忽略。"; OPT_SCAN=0; }
    info "NAT 精简模式：每个地区最多测试 12 个候选，并发 3。"
  fi
  info "VPS 位置: ${GEO_CC:-未知} ${GEO_REGION} ${GEO_CITY}  ${GEO_ORG}"
  info "筛选规则: 同地区 · TLS1.3+X25519 · ALPN h2 · HSTS · 证书有效 · 非 CDN/WAF · 非大厂/被墙域名（支持 X25519MLKEM768 者优先）"

  if (( OPT_SCAN )); then
    local scanned="${TMP_DIR}/scan.list"
    if scanner_collect "$scanned"; then
      # shellcheck disable=SC2046
      sni_test_list "$res" $(cat "$scanned")
      sni_sorted_pass "$res" >"$sorted"
    fi
  fi
  if [[ ! -s ${sorted} ]]; then
    [[ -n $main ]] && cands=$(sni_cap "$(sni_candidates "$main")")
    info "测试 ${main:-通用} 地区候选（$(wc -w <<<"$cands") 个）..."
    # shellcheck disable=SC2086
    [[ -n $cands ]] && sni_test_list "$res" $cands
    [[ -f $res ]] || : >"$res"
    sni_sorted_pass "$res" >"$sorted"
    if (( $(wc -l <"$sorted") < 3 )) && [[ -n $near ]]; then
      cands=""
      for k in $near; do cands+=" $(sni_candidates "$k")"; done
      cands=$(sni_cap "$cands")
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
    awk -F'|' '$1=="FAIL" && ++n <= 15 {printf "    %s: %s\n", $2, $3}' "$res"
    (( OPT_AUTO )) && die "自动模式下无法确定 SNI，请用 --sni 指定（或 --force-sni）。"
    manual_sni && return 0
    die "未选择 SNI。"
  fi
  echo
  _green "通过检测的候选（按 同国家优先 + 支持 MLKEM 优先 + TLS 握手延迟 排序）："
  sni_print_table "$sorted" 8
  local fails; fails=$(grep -c '^FAIL' "$res" || true)
  printf '  （另有 %s 个候选未通过，已排除）\n\n' "$fails"
  if ! cut -d'|' -f9 "$sorted" | grep -q '^Y$'; then
    warn "通过检测的候选均不支持（或无法确认支持）X25519MLKEM768，已放宽为偏好条件，仍从中选择。"
  fi
  local best; best=$(head -n1 "$sorted" | cut -d'|' -f2)
  if (( OPT_AUTO )); then
    SNI=$best; ok "自动选择: ${SNI}"
    sni_pq_warn "$SNI" "$(head -n1 "$sorted" | cut -d'|' -f9)"
    return 0
  fi
  local choice
  while :; do
    ask choice "请选择序号，或输入 m 手动填写域名" "1"
    if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= npass && choice <= 8 )); then
      SNI=$(sed -n "${choice}p" "$sorted" | cut -d'|' -f2)
      sni_pq_warn "$SNI" "$(sed -n "${choice}p" "$sorted" | cut -d'|' -f9)"
      break
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
      local pq
      IFS='|' read -r _ _ _ rtt ip cc city org pq _ <<<"$r"
      ok "${d} 通过检测：TLS 握手 ${rtt}ms，IP ${ip} (${cc} ${city} ${org})，X25519MLKEM768: $(sni_pq_label "$pq")"
      [[ -n $GEO_CC && $cc != "$GEO_CC" ]] && warn "该网站 IP 与 VPS 不在同一国家，不推荐。"
      sni_pq_warn "$d" "$pq"
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
  # 容器内缺少 CAP_SYS_PTRACE 时 ss 看不到进程名：若本脚本服务正在运行且配置的就是该端口，视为自身占用
  if [[ -z $owner ]]; then
    [[ $1 == tcp && $2 == "$XRAY_PORT" && xray =~ ^($3)$ ]] && svc_active xray && return 0
    [[ $1 == udp && $2 == "$HY2_PORT" && hysteria =~ ^($3)$ ]] && svc_active hysteria-server && return 0
  fi
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
  if direct_mode; then install_xray_direct; return; fi
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
  ok "Xray 已安装: $("$XRAY_BIN" version | awk 'NR==1{print $2}')"
}

# 不依赖 GitHub API，从 releases/latest 的跳转地址解析最新版本号（跟随仓库改名等多次跳转）
latest_tag() {
  curl -fsSIL "${FETCH_IP[@]}" --connect-timeout 10 -m 20 "https://github.com/$1/releases/latest" 2>/dev/null |
    awk -F'/tag/' 'tolower($0) ~ /^location:/ && NF > 1 {gsub(/[\r\n]/, "", $2); t=$2} END{if (t != "") print t}' || true
}
# 最新版本号：先 GitHub API，失败（限流 / 不可达）时改用 releases/latest 跳转
gh_latest_tag() {
  local t=""
  t=$(curl -fsSL "${FETCH_IP[@]}" --connect-timeout 10 -m 20 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$1/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null) || t=""
  [[ -n $t ]] || t=$(latest_tag "$1")
  printf '%s' "$t"
}

# ============================================================
#          NAT 模式：直接下载官方二进制 + 自建 systemd / OpenRC 服务
# ============================================================
xray_asset_name() {
  case $ARCH in
    amd64) echo "Xray-linux-64.zip" ;;
    arm64) echo "Xray-linux-arm64-v8a.zip" ;;
    armv7) echo "Xray-linux-arm32-v7a.zip" ;;
  esac
}
hy_asset_name() {
  case $ARCH in
    amd64) echo "hysteria-linux-amd64" ;;
    arm64) echo "hysteria-linux-arm64" ;;
    armv7) echo "hysteria-linux-arm" ;;
  esac
}
github_hint() {
  warn "无法访问 GitHub。$( ((NO_V4)) && echo 'GitHub 不支持 IPv6，IPv6-only 机器请配置 DNS64/NAT64（重新运行并加 --dns64，或手动把 /etc/resolv.conf 改为 DNS64 服务器）。')"
}

install_xray_direct() {
  step "安装 / 更新 Xray-core（直接下载 XTLS/Xray-core 官方 Release）"
  mktmp
  local tag asset base cur="" want dg sum
  tag=$(gh_latest_tag XTLS/Xray-core)
  [[ -n $tag ]] || { github_hint; die "获取 Xray 最新版本号失败。"; }
  [[ -x $XRAY_BIN ]] && cur=$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}')
  if [[ -n $cur && "v${cur#v}" == "$tag" ]] && { (( NAT_MODE )) || [[ -f ${XRAY_ASSET_DIR}/geoip.dat ]]; }; then
    ok "Xray 已是最新版本 ${tag}，跳过下载。"
  else
    asset=$(xray_asset_name)
    base="https://github.com/XTLS/Xray-core/releases/download/${tag}"
    info "下载 ${asset} (${tag}) ..."
    fetch -o "${TMP_DIR}/${asset}" "${base}/${asset}" || { github_hint; die "下载 Xray 失败。"; }
    if fetch -o "${TMP_DIR}/${asset}.dgst" "${base}/${asset}.dgst" 2>/dev/null; then
      want=$(awk -F'= *' '/^SHA2-256/{print tolower($2); exit}' "${TMP_DIR}/${asset}.dgst" | tr -d '[:space:]')
      sum=$(sha256sum "${TMP_DIR}/${asset}" | awk '{print $1}')
      if [[ -n $want ]]; then
        [[ $want == "$sum" ]] || die "Xray 压缩包 SHA256 校验失败（期望 ${want}，实际 ${sum}），已中止。"
        ok "SHA256 校验通过。"
      else
        warn "无法解析 .dgst 文件，跳过 SHA256 校验。"
      fi
    else
      warn "未能下载 .dgst 校验文件，跳过 SHA256 校验。"
    fi
    dg="${TMP_DIR}/xray-unzip"; rm -rf "$dg"; mkdir -p "$dg"
    # NAT 小鸡磁盘很小：只解压 xray 本体（配置不使用 geoip/geosite，内网段直接写 CIDR），解压后立即删除压缩包
    if (( NAT_MODE )); then
      unzip -qo "${TMP_DIR}/${asset}" xray -d "$dg" || die "解压 Xray 失败。"
    else
      unzip -qo "${TMP_DIR}/${asset}" -d "$dg" || die "解压 Xray 失败。"
    fi
    rm -f "${TMP_DIR}/${asset}"
    [[ -f $dg/xray ]] || die "压缩包中没有 xray 可执行文件。"
    chmod 755 "$dg/xray"
    "$dg/xray" version >/dev/null 2>&1 || die "下载的 xray 无法运行（架构不匹配？当前 ${ARCH}）。"
    install -m 755 "$dg/xray" "${XRAY_BIN}.new" && mv -f "${XRAY_BIN}.new" "$XRAY_BIN"
    mkdir -p "$XRAY_ASSET_DIR"
    local f
    for f in geoip.dat geosite.dat; do [[ -f $dg/$f ]] && install -m 644 "$dg/$f" "${XRAY_ASSET_DIR}/$f"; done
    rm -rf "$dg"
  fi
  write_xray_service
  [[ -x $XRAY_BIN ]] || die "未找到 ${XRAY_BIN}，Xray 安装可能失败。"
  ok "Xray 已安装: $("$XRAY_BIN" version | awk 'NR==1{print $2}')"
}

install_hysteria_direct() {
  step "安装 / 更新 Hysteria2（直接下载 apernet/hysteria 官方 Release）"
  mktmp
  local tag asset base cur="" want sum
  tag=$(gh_latest_tag apernet/hysteria)
  [[ -n $tag ]] || { github_hint; die "获取 Hysteria2 最新版本号失败。"; }
  [[ -x $HY_BIN ]] && cur=$("$HY_BIN" version 2>/dev/null | awk '/^Version:/{print $2}')
  if [[ -n $cur && "app/${cur}" == "$tag" ]]; then
    ok "Hysteria2 已是最新版本 ${tag#app/}，跳过下载。"
  else
    asset=$(hy_asset_name)
    base="https://github.com/apernet/hysteria/releases/download/${tag}"
    info "下载 ${asset} (${tag#app/}) ..."
    fetch -o "${TMP_DIR}/${asset}" "${base}/${asset}" || { github_hint; die "下载 Hysteria2 失败。"; }
    if fetch -o "${TMP_DIR}/hy-hashes.txt" "${base}/hashes.txt" 2>/dev/null; then
      want=$(awk -v a="$asset" '{n=$2; sub(/^.*\//, "", n)} n==a {print tolower($1); exit}' "${TMP_DIR}/hy-hashes.txt")
      sum=$(sha256sum "${TMP_DIR}/${asset}" | awk '{print $1}')
      if [[ -n $want ]]; then
        [[ $want == "$sum" ]] || die "Hysteria2 SHA256 校验失败（期望 ${want}，实际 ${sum}），已中止。"
        ok "SHA256 校验通过。"
      else
        warn "hashes.txt 中未找到 ${asset}，跳过 SHA256 校验。"
      fi
    else
      warn "未能下载 hashes.txt，跳过 SHA256 校验。"
    fi
    chmod 755 "${TMP_DIR}/${asset}"
    "${TMP_DIR}/${asset}" version >/dev/null 2>&1 || die "下载的 hysteria 无法运行（架构不匹配？当前 ${ARCH}）。"
    install -m 755 "${TMP_DIR}/${asset}" "${HY_BIN}.new" && mv -f "${HY_BIN}.new" "$HY_BIN"
  fi
  ensure_hy_user
  write_hy2_service
  ok "Hysteria2 已安装: $("$HY_BIN" version 2>/dev/null | awk '/^Version:/{print $2}')"
}

ensure_hy_user() {
  id hysteria >/dev/null 2>&1 && return 0
  if have useradd; then
    useradd -r -M -s "$(command -v nologin 2>/dev/null || echo /bin/false)" hysteria >/dev/null 2>&1 || true
  elif have adduser; then
    addgroup -S hysteria >/dev/null 2>&1 || true
    adduser -S -D -H -h /var/empty -s /sbin/nologin -G hysteria hysteria >/dev/null 2>&1 || true
  fi
  id hysteria >/dev/null 2>&1 || warn "无法创建 hysteria 用户，将以 root 运行 Hysteria2。"
}

# 需要绑定 1024 以下端口时才申请 CAP_NET_BIND_SERVICE（老内核 / OpenVZ 不支持 ambient capabilities）
need_bind_cap() { (( ${1:-0} > 0 && ${1:-0} < 1024 )); }

write_xray_service() {
  local envs; envs=$(go_mem_env)
  if is_openrc; then
    local sargs="--env XRAY_LOCATION_ASSET=${XRAY_ASSET_DIR}" e
    for e in $envs; do sargs+=" --env ${e}"; done
    cat >"$XRAY_RC" <<RC
#!/sbin/openrc-run
# 由 proxy-oneclick 生成（NAT 模式）
name="xray"
description="Xray (proxy-oneclick)"
supervisor=supervise-daemon
command="${XRAY_BIN}"
command_args="run -config ${XRAY_CONF}"
command_user="nobody:$(id -gn nobody 2>/dev/null || echo nobody)"
output_log="${XRAY_LOG}"
error_log="${XRAY_LOG}"
respawn_delay=3
respawn_max=0
supervise_daemon_args="${sargs}"
$(need_bind_cap "$XRAY_PORT" && echo 'capabilities="^cap_net_bind_service"')

depend() {
  want net
  after net firewall
}

start_pre() {
  checkpath -d -m 0755 -o "\${command_user}" /var/log/xray
  checkpath -f -m 0644 -o "\${command_user}" "${XRAY_LOG}"
  # 简单的日志大小控制：超过 2MB 时只保留最后 500 行
  if [ "\$(wc -c <"${XRAY_LOG}")" -gt 2097152 ]; then
    tail -n 500 "${XRAY_LOG}" >"${XRAY_LOG}.tmp" && cat "${XRAY_LOG}.tmp" >"${XRAY_LOG}"; rm -f "${XRAY_LOG}.tmp"
  fi
}
RC
    chmod 755 "$XRAY_RC"
  else
    rm -rf /etc/systemd/system/xray.service.d
    {
      echo "# 由 proxy-oneclick 生成（NAT 模式）"
      echo "[Unit]"
      echo "Description=Xray Service (proxy-oneclick)"
      echo "After=network-online.target nss-lookup.target"
      echo "Wants=network-online.target"
      echo
      echo "[Service]"
      echo "User=nobody"
      echo "NoNewPrivileges=true"
      if need_bind_cap "$XRAY_PORT"; then
        echo "CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
        echo "AmbientCapabilities=CAP_NET_BIND_SERVICE"
      fi
      echo "Environment=XRAY_LOCATION_ASSET=${XRAY_ASSET_DIR}"
      local e; for e in $envs; do echo "Environment=${e}"; done
      echo "ExecStart=${XRAY_BIN} run -config ${XRAY_CONF}"
      echo "Restart=on-failure"
      echo "RestartSec=3"
      echo "RestartPreventExitStatus=23"
      echo "LimitNOFILE=65535"
      echo
      echo "[Install]"
      echo "WantedBy=multi-user.target"
    } >"$XRAY_UNIT"
    systemctl daemon-reload
  fi
}

write_hy2_service() {
  local envs user="root" grp="root"; envs=$(go_mem_env)
  if id hysteria >/dev/null 2>&1; then user=hysteria; grp=$(id -gn hysteria); fi
  if is_openrc; then
    local sargs="--env HYSTERIA_LOG_LEVEL=warn --env HYSTERIA_DISABLE_UPDATE_CHECK=1" e
    for e in $envs; do sargs+=" --env ${e}"; done
    cat >"$HY_RC" <<RC
#!/sbin/openrc-run
# 由 proxy-oneclick 生成（NAT 模式）
name="hysteria-server"
description="Hysteria2 server (proxy-oneclick)"
supervisor=supervise-daemon
command="${HY_BIN}"
command_args="server --config ${HY_CONF}"
command_user="${user}:${grp}"
directory="${HY_DIR}"
output_log="${HY_LOG}"
error_log="${HY_LOG}"
respawn_delay=3
respawn_max=0
supervise_daemon_args="${sargs}"
$(need_bind_cap "$HY2_PORT" && echo 'capabilities="^cap_net_bind_service"')

depend() {
  want net
  after net firewall proxy-oneclick-hop
}

start_pre() {
  checkpath -d -m 0755 -o "\${command_user}" /var/log/hysteria
  checkpath -f -m 0644 -o "\${command_user}" "${HY_LOG}"
  if [ "\$(wc -c <"${HY_LOG}")" -gt 2097152 ]; then
    tail -n 500 "${HY_LOG}" >"${HY_LOG}.tmp" && cat "${HY_LOG}.tmp" >"${HY_LOG}"; rm -f "${HY_LOG}.tmp"
  fi
}
RC
    chmod 755 "$HY_RC"
  else
    rm -rf /etc/systemd/system/hysteria-server.service.d
    {
      echo "# 由 proxy-oneclick 生成（NAT 模式）"
      echo "[Unit]"
      echo "Description=Hysteria2 Server (proxy-oneclick)"
      echo "After=network-online.target"
      echo "Wants=network-online.target"
      echo
      echo "[Service]"
      echo "User=${user}"
      echo "Group=${grp}"
      echo "WorkingDirectory=${HY_DIR}"
      echo "NoNewPrivileges=true"
      if need_bind_cap "$HY2_PORT"; then
        echo "CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
        echo "AmbientCapabilities=CAP_NET_BIND_SERVICE"
      fi
      echo "Environment=HYSTERIA_LOG_LEVEL=warn"
      echo "Environment=HYSTERIA_DISABLE_UPDATE_CHECK=1"
      local e; for e in $envs; do echo "Environment=${e}"; done
      echo "ExecStart=${HY_BIN} server --config ${HY_CONF}"
      echo "Restart=on-failure"
      echo "RestartSec=3"
      echo "LimitNOFILE=65535"
      echo
      echo "[Install]"
      echo "WantedBy=multi-user.target"
    } >"$HY_UNIT"
    systemctl daemon-reload
  fi
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

# NAT 模式不下载 geoip.dat：直接列出内网 / 保留地址段
PRIV_NETS_JSON='["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.0.0.0/24","192.168.0.0/16","198.18.0.0/15","224.0.0.0/3","::/127","fc00::/7","fe80::/10","ff00::/8"]'
write_xray_config() {
  local clients tmp seed=""
  clients=$(xray_clients_json)
  pqv_active && seed=$MLDSA_SEED
  mkdir -p "$(dirname "$XRAY_CONF")"
  tmp=$(mktemp "$(dirname "$XRAY_CONF")/.config.XXXXXX"); mv -f "$tmp" "${tmp}.json"; tmp="${tmp}.json"
  jq -n \
    --argjson port "$XRAY_PORT" --argjson clients "$clients" \
    --arg target "${SNI_TARGET:-$SNI:443}" --arg sni "$SNI" \
    --arg priv "$PRIV_KEY" --arg sid "$SHORT_ID" --arg seed "$seed" --argjson nat "${NAT_MODE:-0}" --argjson privnets "$PRIV_NETS_JSON" '
  {
    log: ({loglevel: "warning"} + (if $nat == 1 then {access: "none"} else {} end)),
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
        {type: "field", ip: (if $nat == 1 then $privnets else ["geoip:private"] end), outboundTag: "block"},
        {type: "field", protocol: ["bittorrent"], outboundTag: "block"}
      ]
    }
  }' >"$tmp"
  if ! XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" "$XRAY_BIN" run -test -config "$tmp" >"${tmp}.log" 2>&1; then
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
  sd_reload
  svc_enable xray
  svc_restart xray || true
  sleep 1
  if ! svc_active xray; then
    svc_logs xray 20 >&2 || true
    die "Xray 启动失败，请查看上方日志。"
  fi
  ok "Xray 运行中 (TCP ${XRAY_PORT}$( ((NAT_MODE)) && [[ $XRAY_EXT_PORT != "$XRAY_PORT" ]] && echo "，外部端口 ${XRAY_EXT_PORT}"))"
}

selinux_fix() {
  have selinuxenabled && selinuxenabled 2>/dev/null || return 0
  if have restorecon; then restorecon -R "$@" >/dev/null 2>&1 || true; fi
}

# ============================================================
#                        Hysteria2
# ============================================================
install_hysteria() {
  if direct_mode; then install_hysteria_direct; return; fi
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
  sd_reload
  svc_enable hysteria-server
  svc_restart hysteria-server || true
  sleep 2
  if ! svc_active hysteria-server; then
    svc_logs hysteria-server 20 >&2 || true
    die "Hysteria2 启动失败，请查看上方日志。"
  fi
  if (( NAT_MODE )); then
    ok "Hysteria2 运行中 (UDP ${HY2_PORT}$([[ $HY2_EXT_PORT != "$HY2_PORT" ]] && echo "，外部端口 ${HY2_EXT_PORT}")${HOP_RANGE:+，端口跳跃 ${HOP_EXT_RANGE}})"
  else
    ok "Hysteria2 运行中 (UDP ${HY2_PORT}${HOP_RANGE:+，端口跳跃 ${HOP_RANGE}})"
  fi
}

remove_hysteria() {
  svc_disable_stop hysteria-server
  if have systemctl; then systemctl disable --now 'hysteria-server@*' >/dev/null 2>&1 || true; fi
  rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-server@.service "$HY_RC"
  rm -rf /etc/systemd/system/hysteria-server.service.d /var/log/hysteria
  rm -f "$HY_BIN"; rm -rf "$HY_DIR"
  if id hysteria >/dev/null 2>&1; then userdel hysteria >/dev/null 2>&1 || deluser hysteria >/dev/null 2>&1 || true; fi
  if getent group hysteria >/dev/null 2>&1; then groupdel hysteria >/dev/null 2>&1 || delgroup hysteria >/dev/null 2>&1 || true; fi
  sd_reload
  remove_nat_hop
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
  if (( NAT_MODE )); then apply_nat_hop; return; fi
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
  if [[ $INIT_SYS == systemd ]]; then systemctl disable --now proxy-oneclick-fw >/dev/null 2>&1 || true; fi
  if have nft; then
    nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
    nft delete table ip "${NFT_TABLE}_nat" >/dev/null 2>&1 || true
    nft delete table ip6 "${NFT_TABLE}_nat" >/dev/null 2>&1 || true
  fi
  rm -f "$FW_UNIT" "$FW_FILE"
  sd_reload
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
  if (( NAT_MODE )); then
    _yellow "【重要】NAT 机器：请确认服务商面板中的端口映射包含以下外部端口（链接地址: $(server_addr)）："
    printf '   TCP %s → 本机 %s（VLESS-REALITY）\n' "$XRAY_EXT_PORT" "$XRAY_PORT"
    if (( HY2_ENABLED )); then
      printf '   UDP %s → 本机 %s（Hysteria2）\n' "$HY2_EXT_PORT" "$HY2_PORT"
      [[ -n $HOP_RANGE ]] && printf '   UDP %s → 本机 %s（端口跳跃）\n' "$HOP_EXT_RANGE" "$HOP_RANGE"
    fi
    if (( HY2_ENABLED )) && [[ $HY2_EXT_PORT == "$XRAY_EXT_PORT" ]]; then
      echo "   Reality 与 Hysteria2 共用外部端口 ${XRAY_EXT_PORT}：该映射必须同时包含 TCP 和 UDP。"
    else
      echo "   若服务商只映射 TCP，Hysteria2 将无法使用（Reality 不受影响）。"
    fi
    return 0
  fi
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

# 链接中使用的（外部）端口：NAT 模式为服务商映射的外部端口
pub_xray_port() { if (( NAT_MODE )) && [[ -n $XRAY_EXT_PORT ]]; then printf '%s' "$XRAY_EXT_PORT"; else printf '%s' "$XRAY_PORT"; fi; }
pub_hy2_port() { if (( NAT_MODE )) && [[ -n $HY2_EXT_PORT ]]; then printf '%s' "$HY2_EXT_PORT"; else printf '%s' "$HY2_PORT"; fi; }
pub_hop() { # NAT 模式只认实际生效的外部跳跃段，绝不回落到默认 HOP_RANGE
  if (( ${NAT_MODE:-0} )); then printf '%s' "${HOP_EXT_RANGE:-}"; return 0; fi
  printf '%s' "${HOP_RANGE:-}"
}

vless_link() { # $1 uuid $2 名称 $3 是否包含 pqv(1/0)
  local addr q
  addr=$(host_fmt "$(server_addr)")
  q="encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}"
  [[ ${3:-1} == 1 ]] && pqv_active && q+="&pqv=${MLDSA_VERIFY}"
  q+="&type=tcp&headerType=none"
  printf 'vless://%s@%s:%s?%s#%s' "$1" "$addr" "$(pub_xray_port)" "$q" "$(urlencode "$2")"
}

hy2_link() {
  local addr q
  addr=$(host_fmt "$(server_addr)")
  q="sni=${SNI}&insecure=1&pinSHA256=${HY2_PIN}"
  [[ -n $(pub_hop) ]] && q+="&mport=$(pub_hop)"
  printf 'hysteria2://%s@%s:%s/?%s#%s' "$(urlencode "$HY2_PASS")" "$addr" "$(pub_hy2_port)" "$q" "$(urlencode "${NODE_NAME}-Hy2")"
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
    port: $(pub_xray_port)
    uuid: ${UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${SNI}
    client-fingerprint: chrome
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
    port: $(pub_xray_port)
    uuid: ${u}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${SNI}
    client-fingerprint: chrome
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
    port: $(pub_hy2_port)
Y
    if [[ -n $(pub_hop) ]]; then
      if [[ $(pub_hop) == *,* ]]; then printf '    ports: "%s"\n    hop-interval: 30\n' "$(pub_hop)"
      else printf '    ports: %s\n    hop-interval: 30\n' "$(pub_hop)"; fi
    fi
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
  if (( NAT_MODE )); then
    echo "NAT 模式: 映射端口 ${NAT_PORTS}（外部[:内部]）   虚拟化: ${VIRT:-未知}"
  fi
  echo
  echo "---------- VLESS + REALITY + Vision ----------"
  echo "地址: $(server_addr)   端口: $(pub_xray_port) (TCP)$( ((NAT_MODE)) && echo "   本机监听: ${XRAY_PORT}")"
  echo "UUID: ${UUID}"
  echo "流控: xtls-rprx-vision    传输: tcp    安全: reality"
  echo "SNI:  ${SNI}    指纹(fp): chrome"
  echo "公钥(pbk): ${PUB_KEY}"
  echo "ShortId(sid): ${SHORT_ID}"
  if pqv_active; then echo "ML-DSA-65 验证公钥(pqv): 已包含在链接中（很长，可选，客户端不支持时可删除 &pqv=... 部分）"
  elif [[ -n $MLDSA_VERIFY ]]; then echo "ML-DSA-65 (pqv): 已关闭（目标 ${SNI} 证书链不足 3500 字节）"; fi
  echo
  if pqv_active; then echo "链接（含 pqv 后量子签名验证）:"; else echo "链接:"; fi
  echo "$vl"
  if pqv_active; then
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
    echo "地址: $(server_addr)   端口: $(pub_hy2_port) (UDP)$(hp=$(pub_hop); [[ -n $hp ]] && echo "   端口跳跃: $hp")$( ((NAT_MODE)) && echo "   本机监听: ${HY2_PORT}")"
    (( NAT_MODE )) && [[ -z $(pub_hop) ]] && echo "（NAT 模式：端口跳跃未启用）"
    echo "密码: ${HY2_PASS}"
    echo "SNI:  ${SNI}   (自签证书，insecure=1 + pinSHA256 证书指纹校验)"
    echo "pinSHA256: ${HY2_PIN}"
    echo
    echo "$hy"
    if [[ -n $(pub_hop) ]]; then
      echo
      echo "官方 Hysteria2 客户端 / sing-box 多端口写法（端口跳跃写在地址里）:"
      hy2_link | sed -E "s#@([^/]+):$(pub_hy2_port)/#@\\1:$(pub_hy2_port),$(pub_hop)/#; s#&mport=[0-9,-]+##"
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
  printf '  地址: %s  端口: %s  UUID: %s\n' "$(server_addr)" "$(pub_xray_port)" "$UUID"
  printf '  pbk: %s  sid: %s  fp: chrome\n' "$PUB_KEY" "$SHORT_ID"
  echo
  if pqv_active; then _cyan "  链接（含 pqv）："; else _cyan "  链接："; fi
  echo "$vl"
  if pqv_active; then
    echo; _cyan "  链接（不含 pqv，兼容性更好）："; echo "$vl_qr"
  fi
  if pqv_active; then echo; _cyan "  二维码（不含 pqv，pqv 太长无法放入终端二维码）："; else echo; _cyan "  二维码："; fi
  print_qr "$vl_qr"
  if (( HY2_ENABLED )); then
    local hy; hy=$(hy2_link)
    echo; hr; _green "  Hysteria2   (UDP $(pub_hy2_port)$(hp=$(pub_hop); [[ -n $hp ]] && echo "，跳跃 $hp"))"; hr
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
  local it out="" e1 e2 i1 f
  for it in ${1//,/ }; do
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
    if [[ $p == "$XRAY_PORT" || $p == "$HY2_PORT" ]] && { svc_active xray || svc_active hysteria-server; }; then continue; fi
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
# 端口跳跃可用的外部端口：已映射、未排除、不是 Reality 独占的端口
nat_hop_ok() { nat_usable "$1" && { (( $1 != XRAY_EXT_PORT )) || (( $1 == HY2_EXT_PORT )); }; }
nat_hop_filter() { # 输出过滤后的外部端口段（自动拆分）
  local q
  segs_expand "$1" | sort -un | while read -r q; do nat_hop_ok "$q" && echo "$q"; done | segs_compress
}
nat_segs_ext2int() { # 外部端口段 → 内部端口段
  local q
  segs_expand "$1" | while read -r q; do ext2int "$q"; done | sort -un | segs_compress
}

choose_nat_addr() {
  local a def=${OPT_NAT_ADDR:-${SERVER_ADDR:-${PUBLIC_IP4:-$PUBLIC_IP6}}}
  while :; do
    if [[ -n $OPT_NAT_ADDR ]]; then a=$OPT_NAT_ADDR; else ask a "公网地址（服务商提供的 IP 或解析到该 IP 的域名，用于分享链接）" "$def"; fi
    a=${a#[}; a=${a%]}; a=${a// /}
    if [[ -n $a ]] && valid_addr "$a"; then SERVER_ADDR=$a; break; fi
    { [[ -n $OPT_NAT_ADDR ]] || (( OPT_AUTO )); } && die "公网地址无效: ${a:-空}（请用 --nat-addr 指定 IP 或域名）"
    warn "地址格式无效，请输入 IPv4 / IPv6 / 域名。"
  done
  if is_ipv4 "$SERVER_ADDR" && is_private_v4 "$SERVER_ADDR"; then
    warn "${SERVER_ADDR} 是内网地址，客户端通常无法直接连接；请确认填写的是服务商提供的公网 IP / 域名。"
  fi
  [[ $SERVER_ADDR == *:* ]] && info "公网地址为 IPv6，链接中将写成 [${SERVER_ADDR}] 形式。"
  ok "公网地址: ${SERVER_ADDR}"
}

# 交互：为没有写 ":内部" 的每一项询问内部端口（默认沿用已保存的映射，否则与公网端口相同）
nat_ask_internal() {
  local it out="" in def m
  for it in ${1//,/ }; do
    if [[ $it == *:* ]] || ! parse_port_span "$it" >/dev/null; then out+="${out:+,}$it"; continue; fi
    def=$it
    for m in ${NAT_PORTS//,/ }; do [[ $m == "${it}:"* ]] && def=${m#*:}; done
    ask in "公网端口 ${it} 对应的内部端口（本机监听端口，相同直接回车）" "$def" >&2
    in=${in// /}
    if [[ -z $in || $in == "$it" ]]; then out+="${out:+,}$it"; else out+="${out:+,}${it}:${in}"; fi
  done
  printf '%s' "$out"
}

# 从 --port / --hy2-port（外部[:内部]）推导映射列表
nat_ports_from_opts() {
  local l=""
  [[ -n $OPT_PORT ]] && l=$OPT_PORT
  [[ -n $OPT_HY2_PORT && $OPT_HY2_PORT != "$OPT_PORT" ]] && l+="${l:+,}$OPT_HY2_PORT"
  printf '%s' "$l"
}
opt_ext() { printf '%s' "${1%%:*}"; }   # "52430:443" → 52430

choose_nat_ports() {
  local r p def
  # 1) 服务商映射给本机的端口
  def=${OPT_NAT_EXT:-$(nat_ports_from_opts)}
  local from_opt=0; [[ -n $def ]] && from_opt=1
  [[ -n $def ]] || def=$NAT_PORTS
  while :; do
    if (( from_opt )); then r=$def
    else
      echo "   NAT 机器只有服务商映射过的端口能从外部访问。常见两种："
      echo "     · 逐条映射（例如面板里只能加 5 条规则）：填写公网端口，如 59221 或 52430,52431"
      echo "     · 整段转发：填写范围，如 10001-10020"
      echo "   随后会逐个询问对应的内部端口（与公网端口相同直接回车）；也可直接写 公网:内部，如 59221:443"
      ask r "已映射的公网端口（逗号分隔）" "$def"
      r=$(nat_ask_internal "$r")
    fi
    if r=$(nat_norm_list "$r"); then NAT_PORTS=$r; nat_items; break; fi
    { (( from_opt )) || (( OPT_AUTO )); } && die "NAT 映射端口无效或未指定。请使用 --nat-ports 52430,52431（外部[:内部]，或整段 a-b）或 --port 外部端口。"
    warn "格式无效。例如 52430,52431 或 52430:8443 或 10001-10020。"
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
  else ask r "端口段内需要排除的外部端口（如映射给 SSH 的端口，空格/逗号分隔；没有请回车，none 清空）" "$def"; fi
  [[ ${r,,} == none || $r == 无 ]] && r=""
  for x in ${r//,/ }; do
    if is_port "$x" && ext2int "$x" >/dev/null; then [[ " $list " == *" $x "* ]] || list+="$x "
    else warn "忽略不在映射端口内的排除项: ${x}"; fi
  done
  NAT_EXCLUDE=${list% }
  [[ -n $NAT_EXCLUDE ]] && info "排除的外部端口: ${NAT_EXCLUDE}"
  nat_first_usable >/dev/null || die "映射端口 ${NAT_PORTS} 中没有可用端口（全部被排除）。"

  # 3) VLESS-REALITY（TCP）
  def=$(opt_ext "${OPT_PORT:-}")
  if [[ -z $def ]]; then
    if nat_usable "${XRAY_EXT_PORT:-0}"; then def=$XRAY_EXT_PORT; else def=$(nat_first_usable); fi
  fi
  while :; do
    if [[ -n $OPT_PORT ]]; then p=$(opt_ext "$OPT_PORT"); else ask p "VLESS-REALITY 使用的外部端口（TCP，可选: ${NAT_PORTS}）" "$def"; fi
    if nat_usable "$p"; then
      if check_port_free tcp "$(ext2int "$p")" "xray"; then XRAY_EXT_PORT=$p; XRAY_PORT=$(ext2int "$p"); break; fi
    else
      warn "端口 ${p} 不在映射端口中或已被排除。"
    fi
    { [[ -n $OPT_PORT ]] || (( OPT_AUTO )); } && die "无法使用外部端口 ${p} 作为 VLESS-REALITY 端口（NAT 模式下 --port 表示外部端口，需包含在 --nat-ports 中）。"
    def=$(nat_first_usable "$p") || def=""
  done

  # 4) Hysteria2（UDP）：可与 Reality 共用同一个端口号（服务商同时映射 TCP+UDP 时，节省映射名额）
  if [[ -n $OPT_HY2 ]]; then HY2_ENABLED=$OPT_HY2
  elif (( ! OPT_AUTO )); then
    if confirm "是否同时安装 Hysteria2（UDP；需要服务商映射 UDP）？" "$([[ $HY2_ENABLED == 1 ]] && echo y || echo n)"; then HY2_ENABLED=1; else HY2_ENABLED=0; fi
  fi
  (( HY2_ENABLED )) || { HOP_RANGE="" HOP_EXT_RANGE="" HY2_EXT_PORT=""; return 0; }
  local other share
  other=$(nat_first_usable "$XRAY_EXT_PORT") || other=""
  if [[ -n $OPT_HY2_PORT ]]; then share=0; [[ $(opt_ext "$OPT_HY2_PORT") == "$XRAY_EXT_PORT" ]] && share=1
  elif [[ -n $OPT_NAT_SHARE ]]; then share=$OPT_NAT_SHARE
  elif [[ -z $other ]] || (( OPT_AUTO )); then share=1
  else
    local sdef=y; [[ -n $HY2_EXT_PORT && $HY2_EXT_PORT != "$XRAY_EXT_PORT" ]] && sdef=n
    if confirm "服务商的映射是否同时转发 TCP 和 UDP？是则 Hysteria2 与 Reality 共用外部端口 ${XRAY_EXT_PORT}（节省映射名额）" "$sdef"; then share=1; else share=0; fi
  fi
  if (( share )); then
    def=$XRAY_EXT_PORT
    [[ -z $OPT_NAT_SHARE && -z $OPT_HY2_PORT ]] && info "默认 Hysteria2 与 Reality 共用外部端口 ${XRAY_EXT_PORT}（需服务商同时映射 TCP+UDP；如只映射 TCP，请加 --nat-no-share 并提供第二个端口）。"
  else
    if [[ -z $other ]]; then
      warn "没有第二个可用映射端口，且未确认 TCP+UDP 共用，已关闭 Hysteria2。"
      HY2_ENABLED=0 HOP_RANGE="" HOP_EXT_RANGE="" HY2_EXT_PORT=""; return 0
    fi
    def=$other
    nat_usable "${HY2_EXT_PORT:-0}" && [[ $HY2_EXT_PORT != "$XRAY_EXT_PORT" ]] && def=$HY2_EXT_PORT
  fi
  [[ -n $OPT_HY2_PORT ]] && def=$(opt_ext "$OPT_HY2_PORT")
  while :; do
    if [[ -n $OPT_HY2_PORT ]] || (( OPT_AUTO )); then p=$def
    else ask p "Hysteria2 使用的外部端口（UDP，可选: ${NAT_PORTS}）" "$def"; fi
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
  hop=${hop// /}
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
}

# NAT 模式说明：为什么跳过调优 / 防火墙 / fail2ban / Swap
nat_skip_notice() {
  step "NAT 精简模式"
  info "已跳过：sysctl/BBR 调优$( ((OPT_TUNE)) && echo '（已用 --tune 强制启用，见下文）')、nftables 防火墙、fail2ban、Swap、$( ((OPT_UPGRADE)) || echo '系统升级、')RealiTLScanner。"
  echo "   原因：NAT 小鸡多为 LXC / OpenVZ 容器（当前: ${VIRT:-未知}），内核参数与 Swap 由宿主机控制，修改通常无权限或无效；"
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
  if [[ -z $OPT_TUNE ]]; then if (( NAT_MODE )); then OPT_TUNE=0; else OPT_TUNE=1; fi; fi
  return 0
}

do_install() {
  load_state
  [[ -n $OPT_NAT ]] && NAT_MODE=$OPT_NAT
  preflight      # Alpine 可能在此切换为 NAT 模式
  resolve_mode
  take_lock
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
    (( OPT_TUNE )) && apply_tuning
  else
    SERVER_ADDR=${PUBLIC_IP4:-$PUBLIC_IP6}
    ensure_swap
    (( OPT_TUNE )) && apply_tuning
  fi

  step "端口设置"
  if (( NAT_MODE )); then
    choose_nat_addr
    choose_nat_ports
  else
    choose_ports
    NAT_PORTS="" NAT_EXCLUDE="" XRAY_EXT_PORT="" HY2_EXT_PORT="" HOP_EXT_RANGE="" HOP_BACKEND=""
    remove_nat_hop
  fi
  [[ -n $OPT_NAME ]] && NODE_NAME=$OPT_NAME
  [[ -n $NODE_NAME ]] || NODE_NAME=$(default_node_name)
  if (( NAT_MODE )); then
    if [[ -f $FW_FILE || -f $FW_UNIT ]]; then info "NAT 模式不管理防火墙，移除之前安装的本脚本 nftables 规则 ..."; remove_firewall; fi
    FW_ENABLED=0
  else
    (( OPT_FIREWALL )) || FW_ENABLED=0
    if (( OPT_FIREWALL )); then
      FW_ENABLED=1
      handle_other_firewalls
      (( FW_ENABLED )) && ask_extra_ports
    fi
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

  local pqrc=0 redo=n
  [[ -n $SNI && -z $OPT_SNI ]] && { sni_pq_check "$SNI" || pqrc=$?; }
  if (( pqrc == 1 )); then
    # 不支持 MLKEM 只是偏好问题：给出警告，交互模式默认建议重新优选，自动模式保留原 SNI
    warn "当前 SNI ${SNI} 不支持 X25519MLKEM768（后量子密钥交换），可继续使用，但建议优先选择支持 MLKEM 的目标。"
    redo=y
  fi
  if [[ -z $SNI || -n $OPT_SNI ]] || { (( ! OPT_AUTO )) && confirm "是否重新优选 SNI（当前: ${SNI}）？" "$redo"; }; then
    select_sni
  fi
  SNI_TARGET="${SNI}:443"
  mldsa_decide
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
  (( NAT_MODE )) || setup_fail2ban
  INSTALLED=1
  save_state
  self_install
  ( trap - ERR; set +e; reality_selftest ) || true
  show_info
  cloud_fw_reminder
  echo
  _green "安装完成！客户端配置方法见 README；管理菜单：proxy"
}

# ============================================================
#               REALITY 自检（安装 / 更换 SNI 后）
# ============================================================
# 用已安装的 xray 在 127.0.0.1 的随机端口起一个临时 socks 客户端，按生成的链接参数
# （VLESS + Vision + REALITY + pqv）连接本机 127.0.0.1:XRAY_PORT，再经它访问外网。
# 只打印结果，不影响安装；客户端限制 GOMEMLIMIT，128MB 小鸡也可运行。
reality_selftest() {
  [[ -x $XRAY_BIN && -n $UUID && -n $PUB_KEY && -n $SNI && -n $XRAY_PORT ]] || { warn "跳过 REALITY 自检（缺少 xray 或参数）。"; return 0; }
  mktmp
  local dir port="" i pid code="" url ok_url="" rc=1
  dir=$(mktemp -d "${TMP_DIR}/selftest.XXXXXX") || { warn "跳过 REALITY 自检（无法创建临时目录）。"; return 0; }
  for i in 1 2 3 4 5 6 7 8 9 10; do
    port=$(( 20000 + RANDOM % 40000 ))
    [[ $port == "$XRAY_PORT" || $port == "${HY2_PORT:-}" ]] && continue
    port_in_use tcp "$port" || break
  done
  if ! jq -n --arg id "$UUID" --argjson sport "$port" --argjson port "$XRAY_PORT" --arg sni "$SNI" \
      --arg pbk "$PUB_KEY" --arg sid "$SHORT_ID" --arg pqv "$(pqv_active && printf '%s' "$MLDSA_VERIFY")" '
    {
      log: {loglevel: "warning"},
      inbounds: [{listen: "127.0.0.1", port: $sport, protocol: "socks", settings: {udp: false}}],
      outbounds: [{
        protocol: "vless",
        settings: {vnext: [{address: "127.0.0.1", port: $port, users: [{id: $id, encryption: "none", flow: "xtls-rprx-vision"}]}]},
        streamSettings: {network: "raw", security: "reality",
          realitySettings: ({serverName: $sni, fingerprint: "chrome", publicKey: $pbk, shortId: $sid}
            + (if $pqv != "" then {mldsa65Verify: $pqv} else {} end))}
      }]
    }' >"${dir}/client.json" 2>/dev/null; then
    rm -rf "$dir"; warn "跳过 REALITY 自检（生成临时配置失败）。"; return 0
  fi
  chmod 600 "${dir}/client.json"
  info "REALITY 自检：临时客户端 127.0.0.1:${port} → 本机 127.0.0.1:${XRAY_PORT}（SNI ${SNI}）..."
  env GOMEMLIMIT=24MiB GOGC=50 "$XRAY_BIN" run -config "${dir}/client.json" >"${dir}/client.log" 2>&1 &
  pid=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    kill -0 "$pid" 2>/dev/null || break
    port_in_use tcp "$port" && break
  done
  if kill -0 "$pid" 2>/dev/null; then
    for url in "https://www.gstatic.com/generate_204" "https://cp.cloudflare.com/generate_204" "https://www.apple.com/library/test/success.html"; do
      code=$(curl -s -o /dev/null --connect-timeout 8 -m 12 --socks5-hostname "127.0.0.1:${port}" -w '%{http_code}' "$url" 2>/dev/null) || true
      if [[ $code =~ ^[23][0-9][0-9]$ ]]; then rc=0 ok_url=$url; break; fi
    done
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if (( rc == 0 )); then
    local h=${ok_url#https://}; h=${h%%/*}
    ok "REALITY 自检通过：经本机节点访问 ${h} 返回 HTTP ${code}。"
  else
    local direct=""
    direct=$(curl -s -o /dev/null --connect-timeout 8 -m 12 -w '%{http_code}' "https://www.gstatic.com/generate_204" 2>/dev/null) || true
    if [[ ! $direct =~ ^[23][0-9][0-9]$ ]]; then
      warn "REALITY 自检无法判断：服务器本身访问外网失败（直连也不通），请稍后检查网络。"
    else
      warn "REALITY 自检未通过（本机直连外网正常，经节点失败）。可能原因：目标网站 ${SNI} 暂时不可达 / 握手不兼容，或 Xray 未正常运行。"
      warn "  可查看: proxy status（Xray 日志），或更换 SNI: proxy sni"
      grep -vi 'privatekey\|seed' "${dir}/client.log" 2>/dev/null | tail -n 3 | sed 's/^/    /' || true
    fi
  fi
  rm -rf "$dir"
  return 0
}

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
  save_state
  if direct_mode; then
    write_xray_service
    (( HY2_ENABLED )) && [[ -x $HY_BIN ]] && write_hy2_service
  fi
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
  (( NAT_MODE )) || SERVER_ADDR=${PUBLIC_IP4:-$PUBLIC_IP6}
  local old=$SNI
  select_sni
  [[ $SNI == "$old" ]] && { info "SNI 未变化。"; return 0; }
  SNI_TARGET="${SNI}:443"
  mldsa_decide
  apply_all
  ( trap - ERR; set +e; reality_selftest ) || true
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
  if (( NAT_MODE )); then menu_change_ports_nat; return; fi
  local oldx=$XRAY_PORT oldh=$HY2_PORT
  choose_ports_interactive
  if (( HY2_ENABLED )) && [[ ! -x $HY_BIN ]]; then install_hysteria; fi
  if (( ! HY2_ENABLED )) && [[ -x $HY_BIN ]]; then remove_hysteria; fi
  apply_all
  ok "端口已更新：TCP ${oldx} -> ${XRAY_PORT}$( ((HY2_ENABLED)) && echo "，UDP ${oldh} -> ${HY2_PORT}，跳跃 ${HOP_RANGE:-关闭}")"
  cloud_fw_reminder
}
menu_change_ports_nat() {
  local oldx=$XRAY_EXT_PORT oldh=$HY2_EXT_PORT
  detect_os; detect_virt
  local s1=$OPT_PORT s2=$OPT_HY2_PORT s3=$OPT_NAT_EXT s4=$OPT_NAT_ADDR
  OPT_PORT="" OPT_HY2_PORT="" OPT_NAT_EXT="" OPT_NAT_ADDR=""
  choose_nat_addr
  choose_nat_ports
  OPT_PORT=$s1 OPT_HY2_PORT=$s2 OPT_NAT_EXT=$s3 OPT_NAT_ADDR=$s4
  if (( HY2_ENABLED )) && [[ ! -x $HY_BIN ]]; then install_hysteria; fi
  if (( ! HY2_ENABLED )) && [[ -x $HY_BIN ]]; then remove_hysteria; fi
  apply_all
  ok "已更新：Reality 外部端口 ${oldx} -> ${XRAY_EXT_PORT}$( ((HY2_ENABLED)) && echo "，Hy2 外部端口 ${oldh:-无} -> ${HY2_EXT_PORT}，跳跃 ${HOP_EXT_RANGE:-关闭}")"
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
  echo; hr; _green "  服务状态$( ((NAT_MODE)) && echo '（NAT 模式）')"; hr
  local s svcs="xray hysteria-server proxy-oneclick-fw fail2ban"
  if (( NAT_MODE )); then svcs="xray hysteria-server"; [[ -n $HOP_RANGE ]] && svcs+=" proxy-oneclick-hop"; fi
  for s in $svcs; do
    local st; st=$(svc_state "$s")
    [[ -z $st ]] && st="unknown"
    if [[ $st == active ]]; then printf '  %-22s %s\n' "$s" "${C_GREEN}运行中${C_NONE}"
    elif [[ $st != none ]]; then printf '  %-22s %s\n' "$s" "${C_RED}${st}${C_NONE}"
    else printf '  %-22s %s\n' "$s" "未安装"; fi
  done
  [[ -x $XRAY_BIN ]] && printf '  Xray 版本:      %s\n' "$("$XRAY_BIN" version | awk 'NR==1{print $2}')"
  [[ -x $HY_BIN ]] && printf '  Hysteria2 版本: %s\n' "$("$HY_BIN" version 2>/dev/null | awk '/^Version:/{print $2}')"
  if (( NAT_MODE )); then
    nat_status_lines
  else
    printf '  拥塞控制:       %s / %s\n' "$(sysval net.ipv4.tcp_congestion_control)" "$(sysval net.core.default_qdisc)"
  fi
  printf '  时间同步:       %s\n' "$(time_sync_status)"
  echo; _cyan "  监听端口："
  local lx lh
  lx=$(ss -Htlnp 2>/dev/null | awk '/xray/{print "   TCP "$4"  xray"}') || true
  lh=$(ss -Hulnp 2>/dev/null | awk '/hysteria/{print "   UDP "$4"  hysteria"}') || true
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
  if (( NAT_MODE )) && [[ -z $HOP_RANGE ]]; then
    echo "  1) 查看 Xray 日志   2) 查看 Hysteria2 日志   4) 实时跟踪 Xray 日志   0) 返回"
  elif (( NAT_MODE )); then
    echo "  1) 查看 Xray 日志   2) 查看 Hysteria2 日志   3) 查看端口跳跃规则   4) 实时跟踪 Xray 日志   0) 返回"
  else
    echo "  1) 查看 Xray 日志   2) 查看 Hysteria2 日志   3) 查看防火墙规则   4) 实时跟踪 Xray 日志   0) 返回"
  fi
  local c; ask c "请选择" "0"
  case $c in
    1) svc_logs xray 80 ;;
    2) svc_logs hysteria-server 80 ;;
    3) if (( NAT_MODE )); then if [[ -n $HOP_RANGE ]]; then show_hop_rules; fi
       else
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
  printf '  Reality:        外部 TCP %s → 本机 %s\n' "${XRAY_EXT_PORT:-?}" "$XRAY_PORT"
  if (( HY2_ENABLED )); then
    printf '  Hysteria2:      外部 UDP %s → 本机 %s%s\n' "${HY2_EXT_PORT:-?}" "$HY2_PORT" "$([[ $HY2_EXT_PORT == "$XRAY_EXT_PORT" ]] && echo '（与 Reality 共用端口）')"
    if [[ -n $HOP_RANGE ]]; then printf '  端口跳跃:       外部 UDP %s → 本机 %s（%s）\n' "$HOP_EXT_RANGE" "$HOP_RANGE" "${HOP_BACKEND:-?}"
    else printf '  端口跳跃:       关闭\n'; fi
  fi
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
   · 查看回程路由：在 VPS 上运行 nexttrace（https://github.com/nxtrace/NTrace-core）
   · 晚高峰丢包严重时优先使用 Hysteria2；TCP 稳定时 REALITY 延迟更低
   · SNI 目标延迟过高（> 100ms）时，可在菜单中「更换 SNI」重新优选
TIP
}

menu_firewall() {
  need_installed
  if (( NAT_MODE )); then warn "NAT 模式不管理防火墙（入站由服务商端口映射控制）。"; menu_nat; return; fi
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
  [[ -n $INIT_SYS ]] || detect_init
  if (( NAT_MODE )); then
    warn "将卸载 Xray、Hysteria2、端口跳跃规则、服务脚本及管理命令（NAT 模式）。"
  else
    warn "将卸载 Xray、Hysteria2、本脚本防火墙规则、调优配置、fail2ban 规则及管理命令。"
  fi
  (( OPT_AUTO )) || confirm "确认卸载？" n || return 0
  step "卸载"
  svc_disable_stop xray
  if have systemctl; then systemctl disable --now 'xray@*' >/dev/null 2>&1 || true; fi
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service "$XRAY_RC"
  rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
  rm -f "$XRAY_BIN"; rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  sd_reload
  ok "Xray 已移除"
  remove_hysteria; ok "Hysteria2 已移除"
  remove_nat_hop
  remove_firewall; ok "防火墙 / 端口跳跃规则已移除"
  if [[ -f $F2B_JAIL ]]; then rm -f "$F2B_JAIL"; systemctl restart fail2ban >/dev/null 2>&1 || true; ok "fail2ban 规则已移除（fail2ban 软件包保留）"; fi
  if [[ -f $SYSCTL_FILE || -f $LIMITS_FILE || -f $SYSTEMD_LIMITS_FILE || -f $JOURNALD_FILE ]]; then
    rm -f "$SYSCTL_FILE" "$LIMITS_FILE" "$SYSTEMD_LIMITS_FILE" "$JOURNALD_FILE"
    sysctl --system >/dev/null 2>&1 || true
    if [[ $INIT_SYS == systemd ]]; then
      systemctl daemon-reexec >/dev/null 2>&1 || true
      systemctl restart systemd-journald >/dev/null 2>&1 || true
    fi
    ok "调优配置已移除（BBR 等将在重启后恢复系统默认）"
  fi
  if (( DNS64_SET )) && [[ -f $RESOLV_BAK ]]; then
    if confirm "安装时写入了 DNS64 服务器，是否恢复原来的 /etc/resolv.conf？" y; then
      if cat "$RESOLV_BAK" >/etc/resolv.conf 2>/dev/null; then ok "已恢复 /etc/resolv.conf"; else warn "恢复 /etc/resolv.conf 失败，备份在 ${RESOLV_BAK}"; fi
    fi
  fi
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
  [[ -n $INIT_SYS ]] || detect_init
  local menu10="防火墙管理"; (( NAT_MODE )) && menu10="NAT 信息 / 端口跳跃"
  local st="${C_RED}未安装${C_NONE}"
  if (( INSTALLED )); then
    if svc_active xray; then st="${C_GREEN}运行中${C_NONE}"; else st="${C_YELLOW}已安装 (Xray 未运行)${C_NONE}"; fi
  fi
  cat <<MENU
${C_CYAN}============================================================${C_NONE}
   ${C_BOLD}proxy 一键脚本 v${SCRIPT_VERSION}${C_NONE}  VLESS-REALITY-Vision + Hysteria2
   状态: ${st}${SNI:+   SNI: ${C_GREEN}${SNI}${C_NONE}}$( ((NAT_MODE)) && printf '\n   %sNAT 模式%s  地址: %s  映射: %s' "$C_YELLOW" "$C_NONE" "${SERVER_ADDR:-?}" "${NAT_PORTS:-?}")
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
  ${C_GREEN}10)${C_NONE} ${menu10}
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
    10) if (( NAT_MODE )); then act=menu_nat; else act=menu_firewall; fi ;;
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

NAT 小鸡模式（端口映射 / LXC / OpenVZ / Alpine，自动跳过调优·防火墙·fail2ban·Swap）:
  --nat               启用 NAT 模式（Alpine 必须使用；之后 proxy 命令自动沿用）
  --no-nat            切换回普通模式
  --nat-addr <地址>   链接中使用的公网 IP 或域名（默认自动检测，IPv4 优先）
  --nat-ports <列表>  服务商已映射的端口，逗号分隔，每项 外部[:内部]
                      例: 52430,52431   52430:8443   整段转发: 10001-10020 或 10001-10020:20001-20020
  --port <外部[:内部]>      NAT 模式下为 Reality 外部端口（未给 --nat-ports 时自动加入映射列表）
  --hy2-port <外部[:内部]>  NAT 模式下为 Hysteria2 外部端口（可与 --port 相同 = TCP+UDP 共用）
  --nat-share         Reality(TCP) 与 Hysteria2(UDP) 共用一个外部端口（需服务商同时映射 TCP+UDP）
  --nat-no-share      Reality 与 Hysteria2 使用不同端口
  --nat-exclude <端口> 整段转发时需要排除的外部端口（如映射给 SSH 的端口），逗号分隔
  --hop <段>          NAT 模式默认关闭；仅整段转发时可用，例如 10003-10020（自动跳过 Reality/排除端口）
  --dns64             IPv6-only 机器无法访问 GitHub 时写入公共 DNS64 服务器
  --tune / --upgrade  NAT 模式下仍执行 sysctl 调优 / 系统升级（默认跳过）
  例: bash proxy.sh --nat --auto --nat-addr 1.2.3.4 --nat-ports 52430,52431
      bash proxy.sh --nat --auto --port 52430 --nat-share      # 只有一个 TCP+UDP 映射端口
      bash proxy.sh --nat --auto --nat-port 59221:443        # 公网 59221 → 内部 443（TCP+UDP 同一条映射）

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
  proxy firewall      防火墙管理（NAT 模式为 NAT 信息 / 端口跳跃）
  proxy nat           NAT 信息 / 修改映射端口 / 端口跳跃
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
      --port) is_port_opt "${2-}" || die "--port 参数无效"; OPT_PORT=$2; shift ;;
      --port=*) OPT_PORT=${1#*=}; is_port_opt "$OPT_PORT" || die "--port 参数无效" ;;
      --no-hy2) OPT_HY2=0 ;;
      --hy2) OPT_HY2=1 ;;
      --hy2-port) is_port_opt "${2-}" || die "--hy2-port 参数无效"; OPT_HY2_PORT=$2; shift ;;
      --hop) [[ ${2-} == none ]] || is_range "${2-}" || valid_segs "${2-}" || die "--hop 参数无效（例如 20000-50000 或 none）"; OPT_HOP=$2; shift ;;
      --no-hop) OPT_HOP=none ;;
      --name) [[ -n ${2-} ]] || die "--name 需要参数"; OPT_NAME=$(tr -cd 'A-Za-z0-9_.-' <<<"$2"); shift ;;
      --no-firewall) OPT_FIREWALL=0 ;;
      --no-upgrade) OPT_UPGRADE=0 ;;
      --no-tune) OPT_TUNE=0 ;;
      --tune) OPT_TUNE=1 ;;
      --upgrade) OPT_UPGRADE=1 ;;
      --nat) OPT_NAT=1 ;;
      --no-nat) OPT_NAT=0 ;;
      --nat-addr|--addr) [[ -n ${2-} ]] || die "$1 需要参数"; OPT_NAT_ADDR=$2; shift ;;
      --nat-ports|--nat-port) [[ -n ${2-} ]] || die "--nat-ports 需要参数（例如 52430,52431）"; nat_norm_list "$2" >/dev/null || die "--nat-ports 参数无效: $2"; OPT_NAT_EXT=$2; shift ;;
      --nat-exclude) [[ -n ${2-} ]] || die "--nat-exclude 需要参数"; OPT_NAT_EXCLUDE=$2; shift ;;
      --nat-share) OPT_NAT_SHARE=1 ;;
      --nat-no-share) OPT_NAT_SHARE=0 ;;
      --dns64) OPT_DNS64=1 ;;
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
      nat) OPT_ACTION=nat ;;
      uninstall|remove) OPT_ACTION=uninstall ;;
      *) usage; die "未知参数: $1" ;;
    esac
    shift
  done
  # 仅传了安装相关参数时默认执行安装
  if [[ -z $OPT_ACTION ]] && { (( OPT_AUTO )) || [[ -n $OPT_SNI || -n $OPT_PORT || -n $OPT_HY2 || -n $OPT_HOP || -n $OPT_NAT || -n $OPT_NAT_EXT ]]; }; then
    OPT_ACTION=install
  fi
  # 普通模式下 --port / --hy2-port 只接受单个端口；NAT 模式的 外部:内部 写法在安装时再校验
  if [[ $OPT_NAT != 1 ]]; then
    [[ -z $OPT_PORT || $OPT_PORT != *:* || -f $STATE_FILE ]] || die "--port 的 外部:内部 写法仅用于 NAT 模式（--nat）。"
  fi
  return 0
}
is_port_opt() { # 端口，或 NAT 模式的 公网:内部（例如 59221:443）
  is_port "$1" && return 0
  [[ $1 =~ ^([0-9]+):([0-9]+)$ ]] || return 1
  local e=${BASH_REMATCH[1]} i=${BASH_REMATCH[2]} # is_port 内部的 =~ 会覆盖 BASH_REMATCH，先保存
  is_port "$e" && is_port "$i"
}

main() {
  parse_args "$@"
  require_root
  detect_init
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
    nat) menu_nat ;;
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
