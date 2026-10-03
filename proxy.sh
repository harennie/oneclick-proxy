#!/usr/bin/env bash
#
# proxy.sh —— VLESS + REALITY + Vision、VLESS + XHTTP + REALITY、Hysteria2 一键安装 / 管理脚本
# 可选（默认不装）：Trojan + REALITY、TUIC v5、AnyTLS。Shadowsocks 2022 仅用于落地机。
#
# 用法:
#   bash proxy.sh                 # 交互式菜单
#   bash proxy.sh --auto          # 全部默认值自动安装
#   bash proxy.sh --nat           # NAT 小鸡模式（端口映射 / LXC / OpenVZ / Alpine）
#   bash proxy.sh tune            # 网络调优（BBR / 队列算法 / 缓冲区；可单独使用，NAT/容器也可用）
#   bash proxy.sh --land          # 落地机：只运行 Shadowsocks 2022（给中转机做出口，可设来源 IP 白名单）
#   proxy land-add 'ss://...'     # 中转机：把出口切换到落地机
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

readonly SCRIPT_VERSION="1.3.0"
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
readonly SB_BIN="/usr/local/bin/sing-box"
readonly SB_DIR="/etc/sing-box"
readonly SB_CONF="${SB_DIR}/config.json"
readonly SB_CRT="${SB_DIR}/server.crt"
readonly SB_KEY="${SB_DIR}/server.key"
readonly SB_UNIT="/etc/systemd/system/sing-box.service"
readonly SB_RC="/etc/init.d/sing-box"
readonly SB_LOG="/var/log/sing-box/sing-box.log"
readonly FW_FILE="${STATE_DIR}/firewall.nft"
readonly FW_UNIT="/etc/systemd/system/proxy-oneclick-fw.service"
readonly SYSCTL_FILE="/etc/sysctl.d/99-proxy-tune.conf"
readonly LIMITS_FILE="/etc/security/limits.d/99-proxy-tune.conf"
readonly SYSTEMD_LIMITS_FILE="/etc/systemd/system.conf.d/99-proxy-tune.conf"
readonly JOURNALD_FILE="/etc/systemd/journald.conf.d/99-proxy-tune.conf"
readonly TUNE_DIR="${STATE_DIR}/tune"
readonly TUNE_BACKUP="${TUNE_DIR}/backup.env"
readonly TUNE_CUR="${TUNE_DIR}/current.env"
readonly TUNE_BOOT="${TUNE_DIR}/boot.sh"
readonly TUNE_UNIT="/etc/systemd/system/proxy-oneclick-tune.service"
readonly TUNE_RC="/etc/init.d/proxy-oneclick-tune"
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
readonly LAND_NFT_TABLE="proxy_oneclick_land"
readonly LAND_FW_FILE="${STATE_DIR}/land-fw.nft"
readonly LAND_FW_UNIT="/etc/systemd/system/proxy-oneclick-land-fw.service"
readonly LAND_FW_RC="/etc/init.d/proxy-oneclick-land-fw"
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
OPT_REALITY=""      # 空=沿用（默认开）; 1/0
OPT_XHTTP=""        # 空=安装时默认开（状态里已有则沿用）; 1/0
OPT_XHTTP_PORT=""
OPT_TROJAN=""       # 空=默认关; 1/0
OPT_TROJAN_PORT=""
OPT_TUIC=""         # 空=默认关; 1/0
OPT_TUIC_PORT=""
OPT_ANYTLS=""       # 空=默认关; 1/0
OPT_ANYTLS_PORT=""
OPT_HOP=""          # "20000-50000" 或 "none"
OPT_FIREWALL=1
OPT_UPGRADE=""      # 空=默认（普通模式 1，NAT 模式 0）
OPT_TUNE=""         # 空=默认（普通模式 1；NAT 模式 2 = 交互询问，--auto 时跳过）
OPT_TUNE_ACT=""     # proxy tune 子命令: status | preview | apply | restore
OPT_TUNE_PRESET=""  # bbr-fq | bbr-fq_codel | bbr-cake | cubic-fq_codel | keep | custom
OPT_TUNE_BUF=""     # auto | small | medium | large | bdp
OPT_TUNE_CC=""      # 自定义拥塞控制
OPT_TUNE_QDISC=""   # 自定义队列算法
OPT_TUNE_BW=""      # BDP：带宽 Mbps
OPT_TUNE_RTT=""     # BDP：延迟 ms
OPT_SCAN=0
OPT_NAME=""
OPT_ACTION=""
OPT_NAT=""          # 空=沿用已安装的模式; 1/0
OPT_NAT_ADDR=""
OPT_NAT_EXT=""      # 映射端口列表 --nat-ports（外部[:内部]，逗号分隔；或整段 a-b[:c-d]）
OPT_NAT_EXCLUDE=""  # 端口段内需要排除的外部端口（例如 SSH 映射）
OPT_NAT_SHARE=""    # 1 = Reality(TCP) 与 Hy2(UDP) 共用一个外部端口；0 = 分开
OPT_DNS64=0
OPT_LAND=""         # 1 = 安装为落地机（Shadowsocks 2022）；0 = 改回节点模式；空 = 沿用
OPT_LAND_METHOD=""  # 落地机加密方式 aes-128 | aes-256 | chacha20
OPT_LAND_ALLOW=""   # 落地机来源 IP 白名单（逗号分隔，none 清空）
OPT_LAND_LINK=""    # 中转机 land-add 的 ss:// 链接
OPT_LAND_ACT=""     # 中转机落地转发子命令: add | on | off | del | test
OPT_FORCE=0         # land-add 测试不通过也强制启用
XRAY_LABEL=""       # 端口提示中的协议名（落地机为 Shadowsocks 2022）

# 运行时变量（部分持久化到 STATE_FILE）
OS_ID="" OS_VER="" OS_NAME="" PKG="" ARCH=""
PUBLIC_IP4="" PUBLIC_IP6="" GEO_CC="" GEO_REGION="" GEO_CITY="" GEO_ORG=""
TMP_DIR=""
INIT_SYS=""         # systemd | openrc | none
NO_V4=0             # 1 = 没有 IPv4 出口（IPv6-only / NAT64）
IPFAM=4             # 探测 / 测速使用的地址族
FETCH_IP=()         # 传给 curl 的地址族参数（IPv6-only 时为 -6）

# ----------------------------- 输出 -----------------------------
# 只用三种颜色：标题、成功、警告。终端不支持颜色、TERM=dumb 或设置了 NO_COLOR 时退回纯文本。
if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-} != dumb ]]; then
  C_TITLE=$'\e[36m' C_OK=$'\e[32m' C_WARN=$'\e[33m' C_DIM=$'\e[2m' C_BOLD=$'\e[1m' C_NONE=$'\e[0m'
else
  C_TITLE="" C_OK="" C_WARN="" C_DIM="" C_BOLD="" C_NONE=""
fi
C_GREEN=$C_OK C_YELLOW=$C_WARN C_RED=$C_WARN C_BLUE="" C_CYAN=$C_TITLE C_MAG=$C_TITLE
_red()    { printf '%s%s%s\n' "$C_WARN" "$*" "$C_NONE"; }
_green()  { printf '%s%s%s\n' "$C_TITLE" "$*" "$C_NONE"; }
_yellow() { printf '%s%s%s\n' "$C_WARN" "$*" "$C_NONE"; }
_cyan()   { printf '%s%s%s\n' "$C_TITLE" "$*" "$C_NONE"; }
info()  { printf '[信息] %s\n' "$*"; }
ok()    { printf '%s[完成]%s %s\n' "$C_OK" "$C_NONE" "$*"; }
warn()  { printf '%s[警告]%s %s\n' "$C_WARN" "$C_NONE" "$*" >&2; }
die()   { printf '%s[错误]%s %s\n' "$C_WARN" "$C_NONE" "$*" >&2; exit 1; }
step()  { printf '\n%s==>%s %s%s%s\n' "$C_TITLE" "$C_NONE" "$C_BOLD" "$*" "$C_NONE"; }
# 终端列宽：ASCII 计 1，汉字计 2；制表符和箭头按 1 计，避免把细线画得过长
ui_dw() {
  local s=$1 i=0 c w=0 o
  local n=${#s}
  while (( i < n )); do
    c=${s:i:1}
    o=$(printf '%d' "'$c")
    if (( o < 128 )); then w=$((w + 1))
    elif (( o >= 0x2E80 && o <= 0xA4CF || o >= 0xAC00 && o <= 0xD7A3 || o >= 0xF900 && o <= 0xFAFF || o >= 0xFE10 && o <= 0xFE6F || o >= 0xFF00 && o <= 0xFF60 || o >= 0xFFE0 && o <= 0xFFE6 )); then w=$((w + 2))
    else w=$((w + 1)); fi
    i=$((i + 1))
  done
  printf '%s' "$w"
}
ui_pad() { # $1 文本 $2 目标列宽（已经更宽则原样返回，不截断）
  local s=$1 w=$2 dw=$(( $2 - $(ui_dw "$1") ))
  (( dw > 0 )) && printf '%s%*s' "$s" "$dw" "" || printf '%s' "$s"
}
ui_repeat() {
  local ch=$1 n=$2 i s=""
  for (( i = 0; i < n; i++ )); do s+=$ch; done
  printf '%s' "$s"
}
ui_bar() { # $1 字符 $2 列数 $3=1 着色（写入文件时传 0）
  local s; s=$(ui_repeat "$1" "$2")
  if (( ${3:-1} )) && [[ -n $C_TITLE ]]; then printf '%s%s%s\n' "$C_TITLE" "$s" "$C_NONE"
  else printf '%s\n' "$s"; fi
}
ui_center() { # $1 文本 $2 总列数 $3=1 着色
  local t=$1 W=$2 dw left
  dw=$(ui_dw "$t"); left=$(( (W - dw) / 2 )); (( left < 0 )) && left=0
  if (( ${3:-1} )) && [[ -n $C_TITLE ]]; then printf '%s%*s%s%s\n' "$C_TITLE" "$left" "" "$t" "$C_NONE"
  else printf '%*s%s\n' "$left" "" "$t"; fi
}
hr() { ui_bar '─' 62 1; }
ui_logo() {
  printf '%s' "$C_TITLE"
  printf '%s\n' '█▀▀▀█ █▀▀▀█'
  printf '%s\n' '█ 哈 █ █ 人 █'
  printf '%s\n' '█▄▄▄█ █▄▄▄█'
  printf '%s' "$C_NONE"
  printf '%soneclick proxy%s  %s·····%s  %sv%s%s\n' "$C_BOLD" "$C_NONE" "$C_DIM" "$C_NONE" "$C_TITLE" "$SCRIPT_VERSION" "$C_NONE"
}
ui_ver_plain() { # $1 二进制 $2 xray|hy2|sb
  local v=""
  [[ -x $1 ]] || { printf '未安装'; return 0; }
  case $2 in
    xray) v=$("$1" version 2>/dev/null | awk 'NR==1{print $2}') || true ;;
    hy2) v=$("$1" version 2>/dev/null | awk '/^Version:/{print $2}') || true ;;
    sb) v=$("$1" version 2>/dev/null | awk 'NR==1{print $NF}') || true ;;
  esac
  printf '%s' "${v:-未知}"
}
ui_stat_row() { # 左标签 左值 右标签 右值；▶ 分隔，未安装用淡色
  local show1 show2
  if [[ $2 == 未安装 || $2 == 未检测 || $2 == 未设置 ]]; then show1=$(printf '%s%s%s' "$C_DIM" "$(ui_pad "$2" 16)" "$C_NONE")
  elif [[ $2 == 运行中 ]]; then show1=$(printf '%s%s%s' "$C_OK" "$(ui_pad "$2" 16)" "$C_NONE")
  else show1=$(ui_pad "$2" 16); fi
  printf '%s%s%s %s▶%s %s' "$C_TITLE" "$(ui_pad "$1" 10)" "$C_NONE" "$C_OK" "$C_NONE" "$show1"
  if [[ -n ${3-} ]]; then
    if [[ $4 == 未安装 || $4 == 未检测 || $4 == 未设置 ]]; then show2=$(printf '%s%s%s' "$C_DIM" "$4" "$C_NONE")
    elif [[ $4 == 运行中 ]]; then show2=$(printf '%s%s%s' "$C_OK" "$4" "$C_NONE")
    else show2=$4; fi
    printf '  %s%s%s %s▶%s %s' "$C_TITLE" "$(ui_pad "$3" 10)" "$C_NONE" "$C_OK" "$C_NONE" "$show2"
  fi
  printf '\n'
}
# 主菜单：全部项目两列排开。$1 标题，$2 末行（退出/返回），其后按顺序传项目文字
ui_columns() {
  local title=$1 zero=$2
  shift 2
  local -a items=("$@") lines=() out=()
  local n=${#items[@]} lefts i j L R line lw=0 w maxw=62
  lefts=$(( (n + 1) / 2 ))
  for (( i = 0; i < lefts; i++ )); do
    L=$(printf '%2d. %s' "$((i + 1))" "${items[i]}")
    j=$(( i + lefts ))
    if (( j < n )); then lines+=("$L"$'\t'"$(printf '%2d. %s' "$((j + 1))" "${items[j]}")")
    else lines+=("$L"); fi
    w=$(ui_dw "$L"); (( w > lw )) && lw=$w
  done
  lw=$(( lw + 2 ))
  for line in "${lines[@]}"; do
    if [[ $line == *$'\t'* ]]; then
      L=${line%%$'\t'*}; R=${line#*$'\t'}
      line=$(printf '  %s  %s' "$(ui_pad "$L" "$lw")" "$R")
    else line=$(printf '  %s' "$line"); fi
    out+=("$line")
    w=$(ui_dw "$line"); (( w > maxw )) && maxw=$w
  done
  local zline; zline=$(printf '  %2d. %s' 0 "$zero")
  w=$(ui_dw "$zline"); (( w > maxw )) && maxw=$w
  w=$(ui_dw "$title"); (( w + 4 > maxw )) && maxw=$(( w + 4 ))
  echo
  ui_bar '═' "$maxw"
  ui_center "$title" "$maxw"
  ui_bar '═' "$maxw"
  for line in "${out[@]}"; do printf '%s\n' "$line"; done
  ui_bar '─' "$maxw"
  printf '%s\n' "$zline"
  ui_bar '═' "$maxw"
}
ui_proto_line() { # $1=1 已开启 $2 名称 $3 说明
  if (( $1 )); then printf '%s▶ %s%s\n' "$C_OK" "$(ui_pad "$2" 28)$3" "$C_NONE"
  else printf '%s  %s%s\n' "$C_DIM" "$(ui_pad "$2" 28)未开启" "$C_NONE"; fi
}

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
    _tty_read __ans "${C_TITLE}${__prompt}${C_NONE} ${C_DIM}[默认: ${__def}]${C_NONE}: "
  else
    _tty_read __ans "${C_TITLE}${__prompt}${C_NONE}: "
  fi
  [[ -z $__ans ]] && __ans=$__def
  printf -v "$__var" '%s' "$__ans"
}
# confirm "提示" y|n  -> 返回 0 表示 yes
confirm() {
  local prompt=$1 def=${2:-y} ans=""
  if (( OPT_AUTO )); then [[ $def == y ]]; return; fi
  local hint="[Y/n]"; [[ $def == n ]] && hint="[y/N]"
  _tty_read ans "${C_TITLE}${prompt}${C_NONE} ${C_DIM}${hint}${C_NONE}: "
  ans=${ans:-$def}
  [[ $ans =~ ^[Yy]([Ee][Ss])?$ ]]
}
pause() { (( OPT_AUTO )) && return 0; local _x; _tty_read _x "按回车键继续..."; }

# ----------------------------- 工具函数 -----------------------------
have() { command -v "$1" >/dev/null 2>&1; }
mktmp() { [[ -n $TMP_DIR && -d $TMP_DIR ]] || TMP_DIR=$(mktemp -d /tmp/proxy-oneclick.XXXXXX); }
is_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
# 端口类输入容错：去掉不可见/控制字符（退格、DEL、回车、ANSI 转义、零宽字符），
# 全角冒号/逗号/顿号/数字/连字符 → 半角，~ 视为 -，合并多余空格
sanitize_port_input() {
  local s=$1 re i c
  re=$'\e''\[[0-9;?]*[@-~]'
  while [[ $s =~ $re ]]; do s=${s/"${BASH_REMATCH[0]}"/}; done
  re=$'\e''[@-_]'
  while [[ $s =~ $re ]]; do s=${s/"${BASH_REMATCH[0]}"/}; done
  # 零宽字符 / 软连字符（U+200B-200D U+2060 U+FEFF U+00AD）
  for c in $'\xe2\x80\x8b' $'\xe2\x80\x8c' $'\xe2\x80\x8d' $'\xe2\x81\xa0' $'\xef\xbb\xbf' $'\xc2\xad'; do s=${s//"$c"/}; done
  # 全角空格 / 不换行空格 / 制表符 → 空格
  for c in $'\xe3\x80\x80' $'\xc2\xa0' $'\t'; do s=${s//"$c"/ }; done
  s=${s//：/:}; s=${s//，/,}; s=${s//、/,}; s=${s//；/,}
  for c in － — – ‐ − ～ '~'; do s=${s//"$c"/-}; done
  local fw=(０ １ ２ ３ ４ ５ ６ ７ ８ ９)
  for i in "${!fw[@]}"; do s=${s//"${fw[i]}"/$i}; done
  s=${s//[[:cntrl:]]/}
  while [[ $s == *'  '* ]]; do s=${s//'  '/ }; done
  s=${s# }; s=${s% }
  printf '%s' "$s"
}
# 以可见形式显示原始输入（控制字符显示为转义序列；含非 ASCII 字符时附 cat -v 逐字节形式）
show_raw_input() {
  printf '%q' "$1"
  local LC_ALL=C v
  if [[ $1 == *[!\ -~]* ]]; then
    v=$(printf '%s' "$1" | cat -v 2>/dev/null) || v=""
    [[ -n $v ]] && printf '（逐字节: %s）' "$v"
  fi
  return 0
}
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
svc_log_file() { case $1 in xray) printf '%s' "$XRAY_LOG" ;; hysteria-server) printf '%s' "$HY_LOG" ;; sing-box) printf '%s' "$SB_LOG" ;; esac; }
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
            HOP_BACKEND VIRT DNS64_SET
            LAND_MODE LAND_METHOD LAND_KEY LAND_ALLOW RELAY_LINK RELAY_ON RELAY_SOCKS NAT_PREF
            REALITY_ENABLED XHTTP_ENABLED XHTTP_PORT XHTTP_PATH XHTTP_EXT_PORT
            TROJAN_ENABLED TROJAN_PORT TROJAN_PASS TROJAN_EXT_PORT
            TUIC_ENABLED TUIC_PORT TUIC_PASS TUIC_EXT_PORT
            ANYTLS_ENABLED ANYTLS_PORT ANYTLS_PASS ANYTLS_EXT_PORT
            OUTBOUND_IP)
INSTALLED=0 XRAY_PORT=443 UUID="" PRIV_KEY="" PUB_KEY="" SHORT_ID="" MLDSA_SEED="" MLDSA_VERIFY="" MLDSA_ON=1 SNI="" SNI_TARGET=""
HY2_ENABLED=1 HY2_PORT=443 HY2_PASS="" HY2_PIN="" HOP_RANGE="20000-50000" NODE_NAME="" FW_ENABLED=1 SSH_PORTS=""
# 默认一键：Reality + XHTTP + Hy2。XHTTP_ENABLED 初始为 0，避免旧状态文件在「改 SNI」时被意外打开；
# 安装流程里若状态没有这一项，再按默认打开。可选协议初始关闭。
REALITY_ENABLED=1
XHTTP_ENABLED=0 XHTTP_PORT=8443 XHTTP_PATH="" XHTTP_EXT_PORT=""
TROJAN_ENABLED=0 TROJAN_PORT=8444 TROJAN_PASS="" TROJAN_EXT_PORT=""
TUIC_ENABLED=0 TUIC_PORT=8446 TUIC_PASS="" TUIC_EXT_PORT=""
ANYTLS_ENABLED=0 ANYTLS_PORT=8445 ANYTLS_PASS="" ANYTLS_EXT_PORT=""
STATE_HAS_XHTTP=0
EXTRA_TCP="" EXTRA_UDP="" DISABLED_FW="" SWAP_CREATED=0 SERVER_ADDR=""
NAT_MODE=0 NAT_PORTS="" NAT_EXCLUDE="" XRAY_EXT_PORT="" HY2_EXT_PORT="" HOP_EXT_RANGE=""
HOP_BACKEND="" VIRT="" DNS64_SET=0
LAND_MODE=0 LAND_METHOD="2022-blake3-aes-128-gcm" LAND_KEY="" LAND_ALLOW="" RELAY_LINK="" RELAY_ON=0 RELAY_SOCKS=""
NAT_PREF=auto       # 菜单「切换 NAT 模式」：auto = 自动检测；on = 强制 NAT（同 --nat）；off = 强制普通模式（同 --no-nat）
NAT_SRC=""          # 本次安装 NAT_MODE 的来源：cli | manual | alpine | state | auto | detect
# 已记住的出站策略：46 IPv4优先 / 64 IPv6优先 / 4 仅IPv4 / 6 仅IPv6。空 = 还没问过。
# 双栈且为空时保持原来的 AsIs / Hy2 happy eyeballs，直到交互询问或 --auto（默认 46）。
OUTBOUND_IP=""
OUTBOUND_EFFECTIVE=""   # 本次写配置实际使用的策略（单栈会强制 4 或 6，不覆盖 OUTBOUND_IP）
OUTBOUND_IP_DONE=0      # 本次进程只决定一次

load_state() {
  [[ -f $STATE_FILE ]] || { STATE_HAS_XHTTP=0; return 0; }
  STATE_HAS_XHTTP=0
  local line k v
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^([A-Z0-9_]+)=(.*)$ ]] || continue
    k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
    local known=0 key
    for key in "${STATE_KEYS[@]}"; do [[ $key == "$k" ]] && known=1 && break; done
    (( known )) || continue
    [[ $k == XHTTP_ENABLED ]] && STATE_HAS_XHTTP=1
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
  # proxy sni 不经过 preflight，ARCH 仍为空时下载地址会变成 RealiTLScanner-linux- 并 404
  [[ -n $ARCH ]] || detect_os
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
    [[ $1 == tcp && $2 == "$XHTTP_PORT" && ${XHTTP_ENABLED:-0} == 1 && xray =~ ^($3)$ ]] && svc_active xray && return 0
    [[ $1 == tcp && $2 == "$TROJAN_PORT" && ${TROJAN_ENABLED:-0} == 1 && xray =~ ^($3)$ ]] && svc_active xray && return 0
    [[ $1 == tcp && $2 == "$ANYTLS_PORT" && ${ANYTLS_ENABLED:-0} == 1 && sing-box =~ ^($3)$ ]] && svc_active sing-box && return 0
    [[ $1 == udp && $2 == "$HY2_PORT" && hysteria =~ ^($3)$ ]] && svc_active hysteria-server && return 0
    [[ $1 == udp && $2 == "$TUIC_PORT" && ${TUIC_ENABLED:-0} == 1 && sing-box =~ ^($3)$ ]] && svc_active sing-box && return 0
    [[ $1 == udp && $2 == "$XRAY_PORT" && ${LAND_MODE:-0} == 1 && xray =~ ^($3)$ ]] && svc_active xray && return 0
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
  local elo=32768 ehi=60999
  read -r elo ehi </proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || true
  ss "$flag" 2>/dev/null | awk '{print $4, $NF}' | while read -r addr users; do
    local port=${addr##*:} ip=${addr%:*}
    # 看不到进程名（容器内缺少权限）的临时端口 UDP 套接字多为客户端连接（如 Hysteria2 经 socks5 转发落地的 UDP 会话），不是服务
    [[ $1 == udp && $users != *users:* && $port =~ ^[0-9]+$ ]] && (( port >= elo && port <= ehi )) && continue
    [[ $ip =~ ^(127\.|\[::1\]|::1|\[?fe80) ]] && continue
    [[ $ip == "127.0.0.53%lo" || $ip == 127.0.0.54 ]] && continue
    [[ $users =~ \"(xray|hysteria|sing-box|sshd|systemd-resolve|chronyd|dhclient|systemd-network)\" ]] && continue
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
  # 之前以 NAT / 落地机模式安装过：删除本脚本自建的服务文件，让官方脚本重新安装它的 xray.service
  # （自建服务只在端口 < 1024 时才有 CAP_NET_BIND_SERVICE，官方脚本不会覆盖已存在的服务文件）
  local force=()
  if [[ -f $XRAY_UNIT ]] && grep -q '由 proxy-oneclick 生成' "$XRAY_UNIT"; then
    systemctl stop xray >/dev/null 2>&1 || true
    rm -f "$XRAY_UNIT"; systemctl daemon-reload
  fi
  # 已有 xray 但没有服务文件时，官方脚本会因「版本相同」直接退出而不安装服务：强制重装
  [[ ! -f $XRAY_UNIT && -x $XRAY_BIN ]] && force=(--force)
  fetch -o "${TMP_DIR}/xray-install.sh" "$XRAY_INSTALL_URL" || die "下载 Xray 安装脚本失败，请检查网络（GitHub 可达性）。"
  if ! TERM=${TERM:-dumb} bash "${TMP_DIR}/xray-install.sh" install "${force[@]}" >"${TMP_DIR}/xray-install.log" 2>&1; then
    # GitHub API 限流(403)时：通过 releases/latest 跳转获取版本号后重试
    local tag
    tag=$(latest_tag XTLS/Xray-core)
    if [[ -n $tag ]]; then
      warn "官方脚本获取版本列表失败（可能是 GitHub API 限流），改为指定版本 ${tag} 重试 ..."
      TERM=${TERM:-dumb} bash "${TMP_DIR}/xray-install.sh" install --version "$tag" "${force[@]}" >"${TMP_DIR}/xray-install.log" 2>&1 || {
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
  if [[ -n $cur && "v${cur#v}" == "$tag" ]] && { (( NAT_MODE || LAND_MODE )) || [[ -f ${XRAY_ASSET_DIR}/geoip.dat ]]; }; then
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
    # NAT 小鸡 / 落地机：只解压 xray 本体（配置不使用 geoip/geosite，内网段直接写 CIDR），解压后立即删除压缩包
    if (( NAT_MODE || LAND_MODE )); then
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
xray_need_cap() {
  if (( ${LAND_MODE:-0} )); then need_bind_cap "$XRAY_PORT"; return; fi
  (( ${REALITY_ENABLED:-1} )) && need_bind_cap "$XRAY_PORT" && return 0
  (( ${XHTTP_ENABLED:-0} )) && need_bind_cap "$XHTTP_PORT" && return 0
  (( ${TROJAN_ENABLED:-0} )) && need_bind_cap "$TROJAN_PORT" && return 0
  return 1
}
sb_needed() { (( ${TUIC_ENABLED:-0} || ${ANYTLS_ENABLED:-0} )); }

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
$(xray_need_cap && echo 'capabilities="^cap_net_bind_service"')

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
      if xray_need_cap; then
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

xray_clients_json() { # $1 = flow（默认 xtls-rprx-vision；XHTTP 传空字符串）
  local flow=${1-xtls-rprx-vision} list
  list=$(jq -n --arg id "$UUID" --arg flow "$flow" '[{id:$id, flow:$flow, email:"main"}]')
  if [[ -s $USERS_FILE ]]; then
    local u r
    while IFS=$'\t' read -r u r; do
      [[ -n $u ]] || continue
      list=$(jq --arg id "$u" --arg e "$r" --arg flow "$flow" '. + [{id:$id, flow:$flow, email:$e}]' <<<"$list")
    done <"$USERS_FILE"
  fi
  printf '%s' "$list"
}

# ----------------------------- 出站地址族 -----------------------------
# 双栈（同时能用 IPv4 和 IPv6 出站）在写节点配置时询问一次：IPv4优先 / IPv6优先 / 仅IPv4 / 仅IPv6。
# 只有一种地址族时不询问，Xray 用 UseIPv4 或 UseIPv6。选择记在 OUTBOUND_IP，之后重配沿用。
# IPv4：默认路由的源地址不是回环 / 链路本地（NAT 内网地址算有 IPv4）。IPv6：全球单播（2000::/3），不算 fe80 和 ULA。
outbound_ipv4_ok() {
  local a=$1 o1 o2 o3 o4
  [[ $a =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  o1=$((10#${BASH_REMATCH[1]})) o2=$((10#${BASH_REMATCH[2]})) o3=$((10#${BASH_REMATCH[3]})) o4=$((10#${BASH_REMATCH[4]}))
  (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 )) || return 1
  (( o1 == 0 || o1 == 127 )) && return 1
  (( o1 == 169 && o2 == 254 )) && return 1
  return 0
}
outbound_ipv6_global() { # 2000::/3；排除 ::1、fe80::/10、ULA fc00::/7
  local a=${1,,}
  [[ $a == *:* ]] || return 1
  [[ $a == ::1 || $a == fe80:* || $a == fc* || $a == fd* ]] && return 1
  [[ $a == [23]* ]]
}
outbound_detect_families_ip() {
  local s4="" s6=""
  s4=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || s4=""
  s6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || s6=""
  if outbound_ipv4_ok "$s4"; then OB_HAS_V4=1; fi
  if outbound_ipv6_global "$s6"; then OB_HAS_V6=1; fi
  return 0
}
outbound_detect_families_proc() {
  local a
  if awk 'NR>1 && $2=="00000000" && $1!="lo" {found=1} END{exit !found}' /proc/net/route 2>/dev/null; then
    while IFS= read -r a; do
      if outbound_ipv4_ok "$a"; then OB_HAS_V4=1; break; fi
    done < <(awk '/32 host LOCAL/{print prev} {prev=$2}' /proc/net/fib_trie 2>/dev/null)
  fi
  if awk '$1=="00000000000000000000000000000000" && $2=="00" && $NF!="lo" {found=1} END{exit !found}' /proc/net/ipv6_route 2>/dev/null; then
    while IFS= read -r a; do
      # /proc/net/if_inet6 是 32 位十六进制；2000::/3 的首位为 2 或 3
      if [[ ${a,,} == [23]* ]]; then OB_HAS_V6=1; break; fi
    done < <(awk '{print $1}' /proc/net/if_inet6 2>/dev/null)
  fi
  return 0
}
outbound_detect_families() {
  OB_HAS_V4=0 OB_HAS_V6=0
  if have ip; then outbound_detect_families_ip; else outbound_detect_families_proc; fi
  return 0
}
xray_domain_strategy() {
  case ${OUTBOUND_EFFECTIVE:-} in
    46) printf '%s' UseIPv4v6 ;;
    64) printf '%s' UseIPv6v4 ;;
    4) printf '%s' UseIPv4 ;;
    6) printf '%s' UseIPv6 ;;
    *) printf '%s' "" ;;
  esac
}
hy2_direct_mode() {
  case ${OUTBOUND_EFFECTIVE:-} in
    46|64|4|6) printf '%s' "$OUTBOUND_EFFECTIVE" ;;
    *) printf '%s' "" ;;
  esac
}
hy2_outbound_name() {
  case $1 in
    46) printf '%s' ipv4-first ;;
    64) printf '%s' ipv6-first ;;
    4) printf '%s' ipv4-only ;;
    6) printf '%s' ipv6-only ;;
    *) printf '%s' direct ;;
  esac
}
sb_ip_strategy() {
  case ${OUTBOUND_EFFECTIVE:-} in
    46) printf '%s' prefer_ipv4 ;;
    64) printf '%s' prefer_ipv6 ;;
    4) printf '%s' ipv4_only ;;
    6) printf '%s' ipv6_only ;;
    *) printf '%s' "" ;;
  esac
}
# sing-box 1.12 起 domain_strategy 废弃，1.14 移除；新版本用 domain_resolver.strategy
sb_resolver_is_new() {
  local v
  [[ -x $SB_BIN ]] || return 0
  v=$("$SB_BIN" version 2>/dev/null | awk 'NR==1{print $NF}') || v=""
  v=${v#v}
  [[ $v =~ ^[0-9] ]] || return 0
  ver_ge "$v" "1.12.0"
}
outbound_can_ask() { [[ -t 0 || -r /dev/tty ]]; }
outbound_apply_code() { OUTBOUND_IP=$1 OUTBOUND_EFFECTIVE=$1 OUTBOUND_IP_CHANGED=1; }
outbound_ask() {
  local c def=1
  echo "   出站地址（本机同时有 IPv4 和 IPv6；只影响代理出站，不会关闭系统 IPv6）："
  echo "     1) IPv4优先"
  echo "     2) IPv6优先"
  echo "     3) 仅IPv4"
  echo "     4) 仅IPv6"
  while :; do
    ask c "请选择" "$def"
    case $c in
      1) outbound_apply_code 46; break ;;
      2) outbound_apply_code 64; break ;;
      3) outbound_apply_code 4; break ;;
      4) outbound_apply_code 6; break ;;
      *) warn "请输入 1-4。" ;;
    esac
  done
}
outbound_use_saved_or_default() { # 双栈或检测不到时：沿用已保存的选择；--auto 且未保存则 IPv4优先
  if [[ $OUTBOUND_IP =~ ^(46|64|4|6)$ ]]; then
    OUTBOUND_EFFECTIVE=$OUTBOUND_IP
    return 0
  fi
  if (( OPT_AUTO )); then
    outbound_apply_code 46
    info "自动模式：出站使用 IPv4优先。"
    return 0
  fi
  if (( OB_HAS_V4 && OB_HAS_V6 )) && outbound_can_ask; then
    outbound_ask
    return 0
  fi
  # 还没问过，且这次不能问：保持原行为（Xray AsIs，Hy2 不写出站 mode）
  OUTBOUND_EFFECTIVE=""
}
ensure_outbound_ip() {
  (( OUTBOUND_IP_DONE )) && return 0
  OUTBOUND_IP_DONE=1
  OUTBOUND_IP_CHANGED=0
  outbound_detect_families
  if (( OB_HAS_V4 && ! OB_HAS_V6 )); then
    OUTBOUND_EFFECTIVE=4
    info "本机只有 IPv4，出站使用仅IPv4。"
  elif (( OB_HAS_V6 && ! OB_HAS_V4 )); then
    OUTBOUND_EFFECTIVE=6
    info "本机只有 IPv6，出站使用仅IPv6。"
  else
    outbound_use_saved_or_default
  fi
  if (( OUTBOUND_IP_CHANGED )); then save_state; fi
}
xray_apply_ip_strategy() { # $1 临时配置。未选择时不改（freedom 无 domainStrategy，routing 保持 AsIs）
  local ds f=$1
  ds=$(xray_domain_strategy)
  [[ -n $ds ]] || return 0
  jq --arg ds "$ds" '
    .routing.domainStrategy = $ds
    | .outbounds |= map(
        if .tag == "direct" and .protocol == "freedom"
        then .settings.domainStrategy = $ds
        else . end)
  ' "$f" >"${f}.ip" && mv -f "${f}.ip" "$f"
}
hy2_outbound_yaml() { # 无落地转发时追加。Hy2 是静态 Go 程序，只用 direct.mode，不改系统解析
  local mode name
  mode=$(hy2_direct_mode)
  [[ -n $mode ]] || return 0
  name=$(hy2_outbound_name "$mode")
  cat <<HY

outbounds:
  - name: ${name}
    type: direct
    direct:
      mode: ${mode}
HY
}
singbox_apply_ip_strategy() { # $1 临时配置。TUIC / AnyTLS 走 sing-box 的同一选择
  local st f=$1
  st=$(sb_ip_strategy)
  [[ -n $st ]] || return 0
  if sb_resolver_is_new; then
    jq --arg st "$st" '
      .dns = {servers: [{type: "local", tag: "local"}]}
      | .outbounds |= map(
          if .tag == "direct" and .type == "direct"
          then .domain_resolver = {server: "local", strategy: $st}
          else . end)
    ' "$f" >"${f}.ip" && mv -f "${f}.ip" "$f"
  else
    jq --arg st "$st" '
      .outbounds |= map(
          if .tag == "direct" and .type == "direct"
          then .domain_strategy = $st
          else . end)
    ' "$f" >"${f}.ip" && mv -f "${f}.ip" "$f"
  fi
}

# NAT 模式不下载 geoip.dat：直接列出内网 / 保留地址段
PRIV_NETS_JSON='["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.0.0.0/24","192.168.0.0/16","198.18.0.0/15","224.0.0.0/3","::/127","fc00::/7","fe80::/10","ff00::/8"]'
write_xray_config() {
  local clients tmp seed="" cplain tclients
  clients=$(xray_clients_json)
  cplain=$(xray_clients_json "")
  tclients=$(jq -n --arg p "${TROJAN_PASS:-}" '[{password:$p, email:"main"}]')
  pqv_active && seed=$MLDSA_SEED
  mkdir -p "$(dirname "$XRAY_CONF")"
  tmp=$(mktemp "$(dirname "$XRAY_CONF")/.config.XXXXXX"); mv -f "$tmp" "${tmp}.json"; tmp="${tmp}.json"
  if (( LAND_MODE )); then
    land_xray_json >"$tmp"
  else
  jq -n \
    --argjson port "$XRAY_PORT" --argjson clients "$clients" --argjson cplain "$cplain" --argjson tclients "$tclients" \
    --argjson reality "${REALITY_ENABLED:-0}" --argjson xhttp "${XHTTP_ENABLED:-0}" --argjson trojan "${TROJAN_ENABLED:-0}" \
    --argjson xport "${XHTTP_PORT:-0}" --argjson tport "${TROJAN_PORT:-0}" --arg xpath "${XHTTP_PATH:-/xhttp}" \
    --arg target "${SNI_TARGET:-$SNI:443}" --arg sni "$SNI" \
    --arg priv "$PRIV_KEY" --arg sid "$SHORT_ID" --arg seed "$seed" --argjson nat "${NAT_MODE:-0}" --argjson privnets "$PRIV_NETS_JSON" '
  def reality: {
    show: false, target: $target, xver: 0,
    serverNames: [$sni], privateKey: $priv, shortIds: [$sid]
  } + (if $seed != "" then {mldsa65Seed: $seed} else {} end);
  def sniff: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true};
  {
    log: ({loglevel: "warning"} + (if $nat == 1 then {access: "none"} else {} end)),
    inbounds: (
      []
      + (if $reality == 1 then [{
          tag: "vless-reality", port: $port, protocol: "vless",
          settings: {clients: $clients, decryption: "none"},
          streamSettings: {network: "raw", security: "reality", realitySettings: reality},
          sniffing: sniff
        }] else [] end)
      + (if $xhttp == 1 then [{
          tag: "vless-xhttp", port: $xport, protocol: "vless",
          settings: {clients: $cplain, decryption: "none"},
          streamSettings: {
            network: "xhttp", security: "reality",
            xhttpSettings: {path: $xpath, mode: "stream-one"},
            realitySettings: reality
          },
          sniffing: sniff
        }] else [] end)
      + (if $trojan == 1 then [{
          tag: "trojan-reality", port: $tport, protocol: "trojan",
          settings: {clients: $tclients},
          streamSettings: {network: "raw", security: "reality", realitySettings: reality},
          sniffing: sniff
        }] else [] end)
    ),
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
    relay_inject "$tmp"   # 中转机：落地出站（保存在状态文件中，每次重新生成配置都会重新加入）
    if [[ $(jq '.inbounds | length' "$tmp") == 0 ]]; then
      rm -f "$tmp"
      return 2
    fi
  fi
  ensure_outbound_ip
  xray_apply_ip_strategy "$tmp" || die "写入 Xray 出站地址族失败。"
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
  if (( LAND_MODE )); then
    ok "Xray 运行中 (Shadowsocks 2022 TCP+UDP ${XRAY_PORT}$( ((NAT_MODE)) && [[ $XRAY_EXT_PORT != "$XRAY_PORT" ]] && echo "，外部端口 ${XRAY_EXT_PORT}"))"
  else
    ok "Xray 运行中 ($(proto_xray_brief))"
  fi
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
  ensure_outbound_ip
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
  # 落地转发时第一条 outbound 必须是 socks5（否则 Hy2 会改走直连）。直连时用 direct.mode。
  if relay_active; then
    relay_hy2_yaml >>"${HY_CONF}.tmp"
  else
    hy2_outbound_yaml >>"${HY_CONF}.tmp"
  fi
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

remove_hysteria() { # $1 = purge：连证书目录一起删（卸载）。TUIC/AnyTLS 还在用时保留证书
  svc_disable_stop hysteria-server
  if have systemctl; then systemctl disable --now 'hysteria-server@*' >/dev/null 2>&1 || true; fi
  rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-server@.service "$HY_RC"
  rm -rf /etc/systemd/system/hysteria-server.service.d /var/log/hysteria
  rm -f "$HY_BIN" "$HY_CONF"
  if [[ $1 == purge ]] || ! sb_needed; then rm -rf "$HY_DIR"; fi
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
  for p in $EXTRA_TCP; do fw_add_port tcp_ports "$p"; done
  udp_ports=""
  (( HY2_ENABLED )) && udp_ports="$HY2_PORT"
  (( ${TUIC_ENABLED:-0} )) && fw_add_port udp_ports "$TUIC_PORT"
  for p in $EXTRA_UDP; do fw_add_port udp_ports "$p"; done
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
    [[ -n $tcp_ports ]] && echo "    tcp dport { ${tcp_ports} } accept"
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
  if (( LAND_MODE )); then land_fw_apply; return; fi
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
  ok "nftables 规则已加载（入站默认拒绝）。已放行 SSH 端口: ${SSH_PORTS}；TCP ${XRAY_PORT}${EXTRA_TCP:+ $EXTRA_TCP}$( ((HY2_ENABLED)) && echo "；UDP ${HY2_PORT}${HOP_RANGE:+ + ${HOP_RANGE}}")${EXTRA_UDP:+；UDP $EXTRA_UDP}$(proto_fw_extra)"
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
  t=$(for p in $t; do [[ $p == "$XRAY_PORT" || $p == "$XHTTP_PORT" || $p == "$TROJAN_PORT" || $p == "$ANYTLS_PORT" ]] || echo "$p"; done | tr '\n' ' ')
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
  printf '%s请在云服务商安全组放行%s\n' "$C_WARN" "$C_NONE"
  (( REALITY_ENABLED )) && printf 'TCP   %-7s  VLESS-REALITY\n' "$XRAY_PORT"
  (( XHTTP_ENABLED )) && printf 'TCP   %-7s  VLESS-XHTTP\n' "$XHTTP_PORT"
  (( TROJAN_ENABLED )) && printf 'TCP   %-7s  Trojan\n' "$TROJAN_PORT"
  (( ANYTLS_ENABLED )) && printf 'TCP   %-7s  AnyTLS\n' "$ANYTLS_PORT"
  (( HY2_ENABLED )) && printf 'UDP   %-7s  Hysteria2%s\n' "$HY2_PORT" "${HOP_RANGE:+  以及 UDP ${HOP_RANGE}}"
  (( TUIC_ENABLED )) && printf 'UDP   %-7s  TUIC v5\n' "$TUIC_PORT"
  echo "位置：云控制台安全组。Oracle Cloud 镜像可能还有自带 iptables。"
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
pub_xhttp_port() { if (( NAT_MODE )) && [[ -n $XHTTP_EXT_PORT ]]; then printf '%s' "$XHTTP_EXT_PORT"; else printf '%s' "$XHTTP_PORT"; fi; }
pub_trojan_port() { if (( NAT_MODE )) && [[ -n $TROJAN_EXT_PORT ]]; then printf '%s' "$TROJAN_EXT_PORT"; else printf '%s' "$TROJAN_PORT"; fi; }
pub_tuic_port() { if (( NAT_MODE )) && [[ -n $TUIC_EXT_PORT ]]; then printf '%s' "$TUIC_EXT_PORT"; else printf '%s' "$TUIC_PORT"; fi; }
pub_anytls_port() { if (( NAT_MODE )) && [[ -n $ANYTLS_EXT_PORT ]]; then printf '%s' "$ANYTLS_EXT_PORT"; else printf '%s' "$ANYTLS_PORT"; fi; }
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

vless_xhttp_link() { # $1 uuid $2 名称 $3 是否包含 pqv(1/0)
  local addr q
  addr=$(host_fmt "$(server_addr)")
  q="encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}"
  [[ ${3:-1} == 1 ]] && pqv_active && q+="&pqv=${MLDSA_VERIFY}"
  q+="&type=xhttp&path=$(urlencode "$XHTTP_PATH")&mode=stream-one"
  printf 'vless://%s@%s:%s?%s#%s' "$1" "$addr" "$(pub_xhttp_port)" "$q" "$(urlencode "$2")"
}
trojan_link() {
  local addr q
  addr=$(host_fmt "$(server_addr)")
  q="security=reality&sni=${SNI}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none"
  pqv_active && q+="&pqv=${MLDSA_VERIFY}"
  printf 'trojan://%s@%s:%s?%s#%s' "$(urlencode "$TROJAN_PASS")" "$addr" "$(pub_trojan_port)" "$q" "$(urlencode "${NODE_NAME}-Trojan")"
}
tuic_link() {
  local addr q
  addr=$(host_fmt "$(server_addr)")
  q="congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${SNI}&allow_insecure=1&insecure=1"
  printf 'tuic://%s:%s@%s:%s?%s#%s' "$(urlencode "$UUID")" "$(urlencode "$TUIC_PASS")" "$addr" "$(pub_tuic_port)" "$q" "$(urlencode "${NODE_NAME}-TUIC")"
}
anytls_link() {
  local addr q
  addr=$(host_fmt "$(server_addr)")
  q="security=tls&type=tcp&sni=${SNI}&fp=chrome&insecure=1&allowInsecure=1"
  printf 'anytls://%s@%s:%s?%s#%s' "$(urlencode "$ANYTLS_PASS")" "$addr" "$(pub_anytls_port)" "$q" "$(urlencode "${NODE_NAME}-AnyTLS")"
}

mihomo_yaml() {
  local addr pin_hex
  addr=$(server_addr)
  pin_hex=$(tr -d ':' <<<"$HY2_PIN" | tr 'A-F' 'a-f')
  echo "proxies:"
  if (( REALITY_ENABLED )); then
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
  if (( XHTTP_ENABLED )); then
    cat <<Y
  - name: "${NODE_NAME}-XHTTP"
    type: vless
    server: ${addr}
    port: $(pub_xhttp_port)
    uuid: ${UUID}
    network: xhttp
    tls: true
    udp: true
    servername: ${SNI}
    client-fingerprint: chrome
    xhttp-opts:
      path: ${XHTTP_PATH}
      mode: stream-one
    reality-opts:
      public-key: ${PUB_KEY}
      short-id: ${SHORT_ID}
Y
  fi
  if (( TROJAN_ENABLED )); then
    cat <<Y
  - name: "${NODE_NAME}-Trojan"
    type: trojan
    server: ${addr}
    port: $(pub_trojan_port)
    password: "${TROJAN_PASS}"
    network: tcp
    udp: true
    sni: ${SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUB_KEY}
      short-id: ${SHORT_ID}
Y
  fi
  if (( TUIC_ENABLED )); then
    cat <<Y
  - name: "${NODE_NAME}-TUIC"
    type: tuic
    server: ${addr}
    port: $(pub_tuic_port)
    uuid: ${UUID}
    password: "${TUIC_PASS}"
    sni: ${SNI}
    alpn: [h3]
    congestion-controller: bbr
    udp-relay-mode: native
    skip-cert-verify: true
    udp: true
Y
  fi
  if (( ANYTLS_ENABLED )); then
    cat <<Y
  - name: "${NODE_NAME}-AnyTLS"
    type: anytls
    server: ${addr}
    port: $(pub_anytls_port)
    password: "${ANYTLS_PASS}"
    sni: ${SNI}
    client-fingerprint: chrome
    skip-cert-verify: true
    udp: true
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

# 一块协议信息：标题、名称、地址、端口各一行，链接单独占最后一行（整行都是链接，方便复制）。
# $1=1 时标题用标题色、说明用淡色；写入文件时传 0，不夹带转义序列。
node_link_head() { # $1=1 着色 $2 标题 $3 名称 $4 地址 $5 端口
  local W=62
  echo
  ui_bar '═' "$W" "$1"
  ui_center "$2" "$W" "$1"
  ui_bar '─' "$W" "$1"
  printf '名称  %s\n' "$3"
  printf '地址  %s\n' "$4"
  printf '端口  %s\n' "$5"
}
node_link_end() { ui_bar '═' 62 "$1"; }
node_link_note() {
  [[ -n $2 ]] || return 0
  if (( $1 )); then printf '%s%s%s\n' "$C_DIM" "$2" "$C_NONE"; else printf '%s\n' "$2"; fi
}
node_link_uri() { printf '%s\n' "$1"; }
print_node_links() { # $1=1 屏幕着色并附二维码；$1=0 纯文本
  local paint=${1:-0} hp qr
  if (( REALITY_ENABLED )); then
    node_link_head "$paint" "VLESS + REALITY + Vision" "${NODE_NAME}-Reality" "$(server_addr)" "$(pub_xray_port)  TCP"
    if pqv_active; then
      node_link_note "$paint" "含 pqv"
      node_link_uri "$(vless_link "$UUID" "${NODE_NAME}-Reality" 1)"
      node_link_note "$paint" "不含 pqv"
      qr=$(vless_link "$UUID" "${NODE_NAME}-Reality" 0)
      node_link_uri "$qr"
    else
      qr=$(vless_link "$UUID" "${NODE_NAME}-Reality" 1)
      node_link_uri "$qr"
    fi
    (( paint )) && { echo; print_qr "$qr"; }
    node_link_end "$paint"
  fi
  if (( XHTTP_ENABLED )); then
    node_link_head "$paint" "VLESS + XHTTP + REALITY" "${NODE_NAME}-XHTTP" "$(server_addr)" "$(pub_xhttp_port)  TCP"
    node_link_note "$paint" "mode stream-one，不要填 flow"
    if pqv_active; then
      node_link_note "$paint" "含 pqv"
      node_link_uri "$(vless_xhttp_link "$UUID" "${NODE_NAME}-XHTTP" 1)"
      node_link_note "$paint" "不含 pqv"
      qr=$(vless_xhttp_link "$UUID" "${NODE_NAME}-XHTTP" 0)
      node_link_uri "$qr"
    else
      qr=$(vless_xhttp_link "$UUID" "${NODE_NAME}-XHTTP" 1)
      node_link_uri "$qr"
    fi
    (( paint )) && { echo; print_qr "$qr"; }
    node_link_end "$paint"
  fi
  if (( HY2_ENABLED )); then
    hp=$(pub_hop)
    node_link_head "$paint" "Hysteria2" "${NODE_NAME}-Hy2" "$(server_addr)" "$(pub_hy2_port)  UDP${hp:+  跳跃 ${hp}}"
    qr=$(hy2_link)
    node_link_uri "$qr"
    if [[ -n $hp ]]; then
      node_link_note "$paint" "官方客户端 / sing-box 多端口写法"
      hy2_link | sed -E "s#@([^/]+):$(pub_hy2_port)/#@\\1:$(pub_hy2_port),${hp}/#; s#&mport=[0-9,-]+##"
    fi
    (( paint )) && { echo; print_qr "$qr"; }
    node_link_end "$paint"
  fi
  if (( TROJAN_ENABLED )); then
    node_link_head "$paint" "Trojan + REALITY" "${NODE_NAME}-Trojan" "$(server_addr)" "$(pub_trojan_port)  TCP"
    qr=$(trojan_link)
    node_link_uri "$qr"
    (( paint )) && { echo; print_qr "$qr"; }
    node_link_end "$paint"
  fi
  if (( TUIC_ENABLED )); then
    node_link_head "$paint" "TUIC v5" "${NODE_NAME}-TUIC" "$(server_addr)" "$(pub_tuic_port)  UDP"
    node_link_note "$paint" "v2rayNG 不能导入，请用 v2rayN / sing-box / mihomo"
    qr=$(tuic_link)
    node_link_uri "$qr"
    (( paint )) && { echo; print_qr "$qr"; }
    node_link_end "$paint"
  fi
  if (( ANYTLS_ENABLED )); then
    node_link_head "$paint" "AnyTLS" "${NODE_NAME}-AnyTLS" "$(server_addr)" "$(pub_anytls_port)  TCP"
    node_link_note "$paint" "v2rayNG 不能导入，请用 v2rayN / sing-box / mihomo"
    qr=$(anytls_link)
    node_link_uri "$qr"
    (( paint )) && { echo; print_qr "$qr"; }
    node_link_end "$paint"
  fi
  if [[ -s $USERS_FILE ]]; then
    local u r
    while IFS=$'\t' read -r u r; do
      [[ -n $u ]] || continue
      if (( REALITY_ENABLED )); then
        node_link_head "$paint" "额外用户 ${r} · Reality" "${NODE_NAME}-${r}" "$(server_addr)" "$(pub_xray_port)  TCP"
        qr=$(vless_link "$u" "${NODE_NAME}-${r}" 0)
        node_link_uri "$qr"
        (( paint )) && { echo; print_qr "$qr"; }
    node_link_end "$paint"
      fi
      if (( XHTTP_ENABLED )); then
        node_link_head "$paint" "额外用户 ${r} · XHTTP" "${NODE_NAME}-XHTTP-${r}" "$(server_addr)" "$(pub_xhttp_port)  TCP"
        qr=$(vless_xhttp_link "$u" "${NODE_NAME}-XHTTP-${r}" 0)
        node_link_uri "$qr"
        (( paint )) && { echo; print_qr "$qr"; }
    node_link_end "$paint"
      fi
    done <"$USERS_FILE"
  fi
}

build_info() { # 输出完整信息（无颜色），用于保存文件
  echo "proxy-oneclick 节点信息"
  echo "生成时间  $(date '+%F %T %Z')"
  echo "服务器    $(server_addr)"
  echo "SNI       ${SNI}"
  if (( NAT_MODE )); then
    echo "NAT       ${NAT_PORTS}（外部[:内部]）  虚拟化 ${VIRT:-未知}"
  fi
  print_node_links 0
  echo
  ui_bar '─' 62 0
  echo "mihomo / Clash.Meta"
  mihomo_yaml
  echo
  ui_bar '─' 62 0
}

save_info() {
  if (( LAND_MODE )); then land_build_info >"${INFO_FILE}.tmp"; else build_info >"${INFO_FILE}.tmp"; fi
  chmod 600 "${INFO_FILE}.tmp"; mv -f "${INFO_FILE}.tmp" "$INFO_FILE"
}

show_info() {
  load_state
  (( INSTALLED )) || die "尚未安装，请先执行安装。"
  if (( LAND_MODE )); then land_show_info; return; fi
  save_info
  echo
  ui_logo
  print_node_links 1
  echo
  ui_bar '═' 62
  ui_center "mihomo / Clash.Meta" 62
  ui_bar '─' 62
  mihomo_yaml
  echo
  ui_bar '─' 62
  printf '以上信息已保存到 %s（权限 600）。再次查看：proxy info\n' "$INFO_FILE"
  ui_bar '═' 62
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

# ============================================================
#     协议：默认 Reality + XHTTP + Hy2；可选 Trojan / TUIC / AnyTLS
# ============================================================
# XHTTP 采用 Xray 官方「VLESS + XHTTP + REALITY」：与 Vision 共用同一把 Reality 密钥和 SNI，
# 单独 TCP 端口，不需要自己的域名。mode 固定 stream-one（REALITY 直连；避免客户端 auto 握手失败）。
# TUIC v5 / AnyTLS 由 sing-box 提供，自签证书（CN = 所选 SNI），不要求自有域名。
# Trojan 走 Xray + REALITY。Shadowsocks 2022 只存在于落地机，这里不加直连入站。
xray_inbound_needed() {
  (( ${REALITY_ENABLED:-0} || ${XHTTP_ENABLED:-0} || ${TROJAN_ENABLED:-0} )) && return 0
  relay_active && (( ${HY2_ENABLED:-0} )) && return 0
  return 1
}
proto_xray_brief() {
  local s=""
  (( REALITY_ENABLED )) && s+="REALITY TCP ${XRAY_PORT}"
  (( XHTTP_ENABLED )) && s+="${s:+ / }XHTTP TCP ${XHTTP_PORT}"
  (( TROJAN_ENABLED )) && s+="${s:+ / }Trojan TCP ${TROJAN_PORT}"
  [[ -n $s ]] || s="无入站"
  printf '%s' "$s"
}
proto_fw_extra() {
  local s=""
  (( XHTTP_ENABLED )) && s+="；TCP ${XHTTP_PORT}（XHTTP）"
  (( TROJAN_ENABLED )) && s+="；TCP ${TROJAN_PORT}（Trojan）"
  (( ANYTLS_ENABLED )) && s+="；TCP ${ANYTLS_PORT}（AnyTLS）"
  (( TUIC_ENABLED )) && s+="；UDP ${TUIC_PORT}（TUIC）"
  printf '%s' "$s"
}
ensure_proto_secrets() {
  [[ $XHTTP_PATH == /* && $XHTTP_PATH =~ ^/[A-Za-z0-9_-]+$ ]] || XHTTP_PATH="/$(rand_hex 8)"
  [[ -n $TROJAN_PASS ]] || TROJAN_PASS=$(rand_pass)
  [[ -n $TUIC_PASS ]] || TUIC_PASS=$(rand_pass)
  [[ -n $ANYTLS_PASS ]] || ANYTLS_PASS=$(rand_pass)
}
resolve_install_protos() {
  if [[ -n $OPT_REALITY ]]; then REALITY_ENABLED=$OPT_REALITY; fi
  if [[ -n $OPT_XHTTP ]]; then XHTTP_ENABLED=$OPT_XHTTP
  elif (( ! STATE_HAS_XHTTP )); then XHTTP_ENABLED=1
  fi
  if [[ -n $OPT_TROJAN ]]; then TROJAN_ENABLED=$OPT_TROJAN; fi
  if [[ -n $OPT_TUIC ]]; then TUIC_ENABLED=$OPT_TUIC; fi
  if [[ -n $OPT_ANYTLS ]]; then ANYTLS_ENABLED=$OPT_ANYTLS; fi
  return 0
}
confirm_xhttp() {
  if [[ -n $OPT_XHTTP ]]; then XHTTP_ENABLED=$OPT_XHTTP; return 0; fi
  (( OPT_AUTO )) && return 0
  if confirm "是否安装 VLESS + XHTTP（REALITY，不需要自己的域名）？" "$([[ ${XHTTP_ENABLED:-0} == 1 ]] && echo y || echo n)"; then
    XHTTP_ENABLED=1
  else
    XHTTP_ENABLED=0
  fi
}
proto_any_enabled() { (( REALITY_ENABLED || XHTTP_ENABLED || HY2_ENABLED || TROJAN_ENABLED || TUIC_ENABLED || ANYTLS_ENABLED )); }

NAT_USED_TCP="" NAT_USED_UDP=""
LOCAL_USED_TCP="" LOCAL_USED_UDP=""
nat_mark_used() { if [[ $1 == tcp ]]; then NAT_USED_TCP+=" $2 "; else NAT_USED_UDP+=" $2 "; fi; }
local_mark_used() { if [[ $1 == tcp ]]; then LOCAL_USED_TCP+=" $2 "; else LOCAL_USED_UDP+=" $2 "; fi; }
nat_used_hit() { local bag; [[ $1 == tcp ]] && bag=$NAT_USED_TCP || bag=$NAT_USED_UDP; [[ " $bag " == *" $2 "* ]]; }
local_used_hit() { local bag; [[ $1 == tcp ]] && bag=$LOCAL_USED_TCP || bag=$LOCAL_USED_UDP; [[ " $bag " == *" $2 "* ]]; }
nat_seed_used() {
  NAT_USED_TCP="" NAT_USED_UDP=""
  if (( REALITY_ENABLED )) && [[ -n $XRAY_EXT_PORT ]]; then nat_mark_used tcp "$XRAY_EXT_PORT"; fi
  if (( HY2_ENABLED )) && [[ -n $HY2_EXT_PORT ]]; then nat_mark_used udp "$HY2_EXT_PORT"; fi
  return 0
}
local_seed_used() {
  LOCAL_USED_TCP="" LOCAL_USED_UDP=""
  if (( REALITY_ENABLED )) && [[ -n $XRAY_PORT ]]; then local_mark_used tcp "$XRAY_PORT"; fi
  if (( HY2_ENABLED )) && [[ -n $HY2_PORT ]]; then local_mark_used udp "$HY2_PORT"; fi
  return 0
}
nat_first_for() { # $1 tcp|udp；后面的参数是额外跳过的端口
  local p x skip
  while read -r p; do
    nat_used_hit "$1" "$p" && continue
    skip=0
    for x in "${@:2}"; do [[ -n $x && $p == "$x" ]] && skip=1; done
    (( skip )) && continue
    echo "$p"; return 0
  done < <(nat_all_ext)
  return 1
}
nat_pick_mapped() { # $1 proto $2 ext变量 $3 内部端口变量 $4 --xx-port $5 名称 $6 允许占用的进程名
  local proto=$1 ext_var=$2 int_var=$3 opt=$4 label=$5 allow=$6
  local p def="" saved=${!ext_var-}
  if [[ -n $opt ]]; then def=$(opt_ext "$opt")
  elif [[ -n $saved ]] && nat_usable "$saved" && ! nat_used_hit "$proto" "$saved"; then def=$saved
  else def=$(nat_first_for "$proto") || def=""; fi
  if [[ -z $def ]]; then
    if [[ -n $opt ]]; then die "无法使用外部端口 $(opt_ext "$opt") 作为 ${label}（需包含在 --nat-ports 中，且不能与已占用的 ${proto^^} 端口相同）。"; fi
    warn "没有空闲的映射端口给 ${label}，本次不启用（已有密钥保留）。请再映射一个 ${proto^^} 端口后，用菜单「协议开关」或对应参数打开。"
    return 1
  fi
  while :; do
    if [[ -n $opt ]] || (( OPT_AUTO )); then p=$def
    else
      ask p "${label} 使用的外部端口（${proto^^}，可选: $(nat_ext_list)）" "$def"
      p=$(sanitize_port_input "$p"); p=${p// /}
    fi
    if nat_usable "$p" && ! nat_used_hit "$proto" "$p"; then
      local ip; ip=$(ext2int "$p")
      if check_port_free "$proto" "$ip" "$allow"; then
        printf -v "$ext_var" '%s' "$p"
        printf -v "$int_var" '%s' "$ip"
        nat_mark_used "$proto" "$p"
        return 0
      fi
    else
      warn "端口 ${p:-空} 不可用（不在映射中、已排除，或该 ${proto^^} 端口已被其它协议占用）。"
    fi
    { [[ -n $opt ]] || (( OPT_AUTO )); } && die "无法使用外部端口 ${p:-空} 作为 ${label}。"
    def=$(nat_first_for "$proto" "$p") || { warn "没有其它可用端口，已跳过 ${label}。"; return 1; }
  done
}
local_pick() { # $1 proto $2 变量 $3 --xx-port $4 名称 $5 允许的进程名 $6 默认端口
  local proto=$1 var=$2 opt=$3 label=$4 allow=$5 def=$6
  local p
  p=$(opt_ext "${opt:-${!var:-$def}}")
  while :; do
    if [[ -z $opt ]] && (( ! OPT_AUTO )); then
      ask p "${label} 监听端口 (${proto^^})" "$p"
      p=$(sanitize_port_input "$p"); p=${p// /}
    fi
    if ! is_port "$p"; then
      { [[ -n $opt ]] || (( OPT_AUTO )); } && die "端口无效: ${p:-空}"
      warn "端口无效。"; p=$def; continue
    fi
    if local_used_hit "$proto" "$p"; then
      { [[ -n $opt ]] || (( OPT_AUTO )); } && die "端口 ${p} 与其它协议冲突。"
      warn "端口 ${p} 已被其它协议占用。"; continue
    fi
    if ! check_port_free "$proto" "$p" "$allow"; then
      { [[ -n $opt ]] || (( OPT_AUTO )); } && die "${proto^^} 端口 ${p} 已被占用。"
      continue
    fi
    printf -v "$var" '%s' "$p"
    local_mark_used "$proto" "$p"
    return 0
  done
}
choose_extra_local() {
  confirm_xhttp
  local_seed_used
  if (( XHTTP_ENABLED )); then local_pick tcp XHTTP_PORT "$OPT_XHTTP_PORT" "VLESS-XHTTP（REALITY）" "xray" "${XHTTP_PORT:-8443}"; fi
  if (( TROJAN_ENABLED )); then local_pick tcp TROJAN_PORT "$OPT_TROJAN_PORT" "Trojan（REALITY）" "xray" "${TROJAN_PORT:-8444}"; fi
  if (( ANYTLS_ENABLED )); then local_pick tcp ANYTLS_PORT "$OPT_ANYTLS_PORT" "AnyTLS" "sing-box" "${ANYTLS_PORT:-8445}"; fi
  if (( TUIC_ENABLED )); then local_pick udp TUIC_PORT "$OPT_TUIC_PORT" "TUIC v5" "sing-box" "${TUIC_PORT:-8446}"; fi
  proto_any_enabled || die "至少需要启用一个协议（Reality / XHTTP / Hysteria2 / Trojan / TUIC / AnyTLS）。"
}
choose_extra_nat() {
  confirm_xhttp
  nat_seed_used
  if (( XHTTP_ENABLED )); then nat_pick_mapped tcp XHTTP_EXT_PORT XHTTP_PORT "$OPT_XHTTP_PORT" "VLESS-XHTTP（REALITY）" "xray" || XHTTP_ENABLED=0; fi
  if (( TROJAN_ENABLED )); then nat_pick_mapped tcp TROJAN_EXT_PORT TROJAN_PORT "$OPT_TROJAN_PORT" "Trojan（REALITY）" "xray" || TROJAN_ENABLED=0; fi
  if (( ANYTLS_ENABLED )); then nat_pick_mapped tcp ANYTLS_EXT_PORT ANYTLS_PORT "$OPT_ANYTLS_PORT" "AnyTLS" "sing-box" || ANYTLS_ENABLED=0; fi
  if (( TUIC_ENABLED )); then nat_pick_mapped udp TUIC_EXT_PORT TUIC_PORT "$OPT_TUIC_PORT" "TUIC v5" "sing-box" || TUIC_ENABLED=0; fi
  if (( HY2_ENABLED )) && [[ -n $HOP_EXT_RANGE ]]; then
    local filtered; filtered=$(nat_hop_filter "$HOP_EXT_RANGE")
    if (( $(segs_count "$filtered") >= 2 )); then
      [[ $filtered != "$HOP_EXT_RANGE" ]] && info "端口跳跃已避开其它协议占用的端口: ${filtered}"
      HOP_EXT_RANGE=$filtered; HOP_RANGE=$(nat_segs_ext2int "$filtered")
    else
      warn "其它协议占用后，跳跃范围不足 2 个端口，端口跳跃已关闭。"
      HOP_RANGE="" HOP_EXT_RANGE="" HOP_BACKEND=""
    fi
  fi
  proto_any_enabled || die "至少需要启用一个协议。NAT 只有一个映射端口时放不下 XHTTP，请再加一条映射，或先用 Reality + Hysteria2（--no-xhttp）。"
}

ensure_sb_user() {
  id sing-box >/dev/null 2>&1 && return 0
  if have useradd; then
    useradd -r -M -s "$(command -v nologin 2>/dev/null || echo /bin/false)" sing-box >/dev/null 2>&1 || true
  elif have adduser; then
    addgroup -S sing-box >/dev/null 2>&1 || true
    adduser -S -D -H -h /var/empty -s /sbin/nologin -G sing-box sing-box >/dev/null 2>&1 || true
  fi
  id sing-box >/dev/null 2>&1 || warn "无法创建 sing-box 用户，将以 root 运行。"
}
sb_asset_name() { # $1 版本号（不含 v）
  local ver=$1 libc="" arch
  [[ $OS_ID == alpine ]] && libc="-musl"
  case $ARCH in
    amd64) arch=amd64 ;;
    arm64) arch=arm64 ;;
    armv7) arch=armv7 ;;
    *) die "当前架构 ${ARCH} 没有对应的 sing-box 安装包。" ;;
  esac
  printf 'sing-box-%s-linux-%s%s.tar.gz' "$ver" "$arch" "$libc"
}
sb_need_cap() {
  (( TUIC_ENABLED )) && need_bind_cap "$TUIC_PORT" && return 0
  (( ANYTLS_ENABLED )) && need_bind_cap "$ANYTLS_PORT" && return 0
  return 1
}
write_singbox_service() {
  local envs user="root" grp="root"; envs=$(go_mem_env)
  if id sing-box >/dev/null 2>&1; then user=sing-box; grp=$(id -gn sing-box); fi
  if is_openrc; then
    local sargs="" e
    for e in $envs; do sargs+=" --env ${e}"; done
    cat >"$SB_RC" <<RC
#!/sbin/openrc-run
# 由 proxy-oneclick 生成
name="sing-box"
description="sing-box (TUIC / AnyTLS)"
supervisor=supervise-daemon
command="${SB_BIN}"
command_args="run -c ${SB_CONF}"
command_user="${user}:${grp}"
directory="${SB_DIR}"
output_log="${SB_LOG}"
error_log="${SB_LOG}"
respawn_delay=3
respawn_max=0
supervise_daemon_args="${sargs}"
$(sb_need_cap && echo 'capabilities="^cap_net_bind_service"')

depend() {
  want net
  after net firewall
}

start_pre() {
  checkpath -d -m 0755 -o "\${command_user}" /var/log/sing-box
  checkpath -f -m 0644 -o "\${command_user}" "${SB_LOG}"
  if [ "\$(wc -c <"${SB_LOG}")" -gt 2097152 ]; then
    tail -n 500 "${SB_LOG}" >"${SB_LOG}.tmp" && cat "${SB_LOG}.tmp" >"${SB_LOG}"; rm -f "${SB_LOG}.tmp"
  fi
}
RC
    chmod 755 "$SB_RC"
  else
    rm -rf /etc/systemd/system/sing-box.service.d
    {
      echo "# 由 proxy-oneclick 生成"
      echo "[Unit]"
      echo "Description=sing-box (TUIC / AnyTLS)"
      echo "After=network-online.target"
      echo "Wants=network-online.target"
      echo
      echo "[Service]"
      echo "User=${user}"
      echo "Group=${grp}"
      echo "WorkingDirectory=${SB_DIR}"
      echo "NoNewPrivileges=true"
      if sb_need_cap; then
        echo "CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
        echo "AmbientCapabilities=CAP_NET_BIND_SERVICE"
      fi
      local e; for e in $envs; do echo "Environment=${e}"; done
      echo "ExecStart=${SB_BIN} run -c ${SB_CONF}"
      echo "Restart=on-failure"
      echo "RestartSec=3"
      echo "LimitNOFILE=65535"
      echo
      echo "[Install]"
      echo "WantedBy=multi-user.target"
    } >"$SB_UNIT"
    systemctl daemon-reload
  fi
}
install_singbox() {
  step "安装 / 更新 sing-box（TUIC v5 / AnyTLS）"
  mktmp
  local tag ver asset url sum want cur="" bin dg
  tag=$(gh_latest_tag SagerNet/sing-box)
  [[ -n $tag ]] || { github_hint; die "获取 sing-box 最新版本号失败。"; }
  ver=${tag#v}
  [[ -x $SB_BIN ]] && cur=$("$SB_BIN" version 2>/dev/null | awk 'NR==1{print $NF}')
  if [[ $cur == "$ver" ]]; then
    ok "sing-box 已是最新版本 ${ver}，跳过下载。"
  else
    asset=$(sb_asset_name "$ver")
    url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${asset}"
    info "下载 ${asset} ..."
    fetch -o "${TMP_DIR}/${asset}" "$url" || { github_hint; die "下载 sing-box 失败。"; }
    want=$(curl -fsSL "${FETCH_IP[@]}" --connect-timeout 10 -m 20 -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/SagerNet/sing-box/releases/tags/${tag}" 2>/dev/null \
      | jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .digest // empty' 2>/dev/null) || want=""
    want=${want#sha256:}
    sum=$(sha256sum "${TMP_DIR}/${asset}" | awk '{print $1}')
    if [[ -n $want && $want != null ]]; then
      [[ $want == "$sum" ]] || die "sing-box SHA256 校验失败（期望 ${want}，实际 ${sum}），已中止。"
      ok "SHA256 校验通过。"
    else
      warn "未能取得 sing-box 的 SHA256，跳过校验。"
    fi
    dg="${TMP_DIR}/sb-unpack"; rm -rf "$dg"; mkdir -p "$dg"
    tar -xzf "${TMP_DIR}/${asset}" -C "$dg" || die "解压 sing-box 失败。"
    bin=$(find "$dg" -type f -name sing-box | head -n1)
    [[ -n $bin ]] || die "压缩包中没有 sing-box 可执行文件。"
    chmod 755 "$bin"
    "$bin" version >/dev/null 2>&1 || die "下载的 sing-box 无法运行（架构或 musl/glibc 不匹配？当前 ${ARCH} / ${OS_ID:-未知}）。"
    install -m 755 "$bin" "${SB_BIN}.new" && mv -f "${SB_BIN}.new" "$SB_BIN"
  fi
  ensure_sb_user
  write_singbox_service
  ok "sing-box 已安装: $("$SB_BIN" version 2>/dev/null | awk 'NR==1{print $NF}')"
}
sb_copy_cert() {
  mkdir -p "$HY_DIR" "$SB_DIR"
  [[ -f $HY_CRT && -f $HY_KEY ]] || gen_hy2_cert
  if ! openssl x509 -noout -subject -in "$HY_CRT" 2>/dev/null | grep -q "CN *= *${SNI}\$"; then gen_hy2_cert; fi
  cp -f "$HY_CRT" "$SB_CRT"
  cp -f "$HY_KEY" "$SB_KEY"
  local grp="root"
  id sing-box >/dev/null 2>&1 && grp=$(id -gn sing-box)
  chown "root:${grp}" "$SB_CRT" "$SB_KEY" 2>/dev/null || true
  chmod 644 "$SB_CRT"; chmod 640 "$SB_KEY"
}
write_singbox_config() {
  sb_needed || return 0
  [[ -x $SB_BIN ]] || die "未找到 sing-box，无法写入 TUIC / AnyTLS 配置。"
  ensure_proto_secrets
  sb_copy_cert
  local tmp="${SB_CONF}.tmp"
  jq -n \
    --argjson tuic "${TUIC_ENABLED:-0}" --argjson any "${ANYTLS_ENABLED:-0}" \
    --argjson tport "${TUIC_PORT:-0}" --argjson aport "${ANYTLS_PORT:-0}" \
    --arg uuid "$UUID" --arg tpw "$TUIC_PASS" --arg apw "$ANYTLS_PASS" \
    --arg crt "$SB_CRT" --arg key "$SB_KEY" --argjson nets "$PRIV_NETS_JSON" '
    {
      log: {level: "warn"},
      inbounds: (
        []
        + (if $tuic == 1 then [{
            type: "tuic", tag: "tuic-in", listen_port: $tport,
            users: [{name: "main", uuid: $uuid, password: $tpw}],
            congestion_control: "bbr", zero_rtt_handshake: false,
            tls: {enabled: true, certificate_path: $crt, key_path: $key, alpn: ["h3"]}
          }] else [] end)
        + (if $any == 1 then [{
            type: "anytls", tag: "anytls-in", listen_port: $aport,
            users: [{name: "main", password: $apw}],
            tls: {enabled: true, certificate_path: $crt, key_path: $key}
          }] else [] end)
      ),
      outbounds: [
        {type: "direct", tag: "direct"}
      ],
      route: {
        rules: [
          {action: "sniff"},
          {ip_cidr: $nets, action: "reject"},
          {protocol: "bittorrent", action: "reject"}
        ],
        final: "direct"
      }
    }' >"$tmp" || die "生成 sing-box 配置失败。"
  ensure_outbound_ip
  singbox_apply_ip_strategy "$tmp" || die "写入 sing-box 出站地址族失败。"
  if ! "$SB_BIN" check -c "$tmp" >"${tmp}.log" 2>&1; then
    cat "${tmp}.log" >&2; rm -f "$tmp" "${tmp}.log"
    die "sing-box 配置校验失败，未应用新配置。"
  fi
  rm -f "${tmp}.log"
  chmod 640 "$tmp"
  mv -f "$tmp" "$SB_CONF"
  selinux_fix "$SB_DIR"
  ok "sing-box 配置已生成: ${SB_CONF}"
}
restart_singbox() {
  sb_needed || return 0
  sd_reload
  svc_enable sing-box
  svc_restart sing-box || true
  sleep 1
  if ! svc_active sing-box; then
    svc_logs sing-box 20 >&2 || true
    die "sing-box 启动失败，请查看上方日志。"
  fi
  ok "sing-box 运行中 ($( ((TUIC_ENABLED)) && echo -n "TUIC UDP $([[ -n $TUIC_EXT_PORT && $NAT_MODE == 1 ]] && echo "$TUIC_EXT_PORT" || echo "$TUIC_PORT")")$( ((TUIC_ENABLED && ANYTLS_ENABLED)) && echo -n " / ")$( ((ANYTLS_ENABLED)) && echo -n "AnyTLS TCP $([[ -n $ANYTLS_EXT_PORT && $NAT_MODE == 1 ]] && echo "$ANYTLS_EXT_PORT" || echo "$ANYTLS_PORT")"))"
}
remove_singbox() {
  svc_disable_stop sing-box
  rm -f "$SB_UNIT" "$SB_RC" "$SB_BIN"
  rm -rf "$SB_DIR" /etc/systemd/system/sing-box.service.d /var/log/sing-box
  if id sing-box >/dev/null 2>&1; then userdel sing-box >/dev/null 2>&1 || deluser sing-box >/dev/null 2>&1 || true; fi
  if getent group sing-box >/dev/null 2>&1; then groupdel sing-box >/dev/null 2>&1 || delgroup sing-box >/dev/null 2>&1 || true; fi
  sd_reload
}
apply_proto_services() { # 按开关写配置并启停。不删除已有密钥。
  ensure_proto_secrets
  if direct_mode; then
    xray_inbound_needed && write_xray_service
    (( HY2_ENABLED )) && [[ -x $HY_BIN ]] && write_hy2_service
  fi
  if xray_inbound_needed; then
    local rc=0
    write_xray_config || rc=$?
    if (( rc == 2 )); then
      svc_disable_stop xray
      warn "Xray 没有需要监听的入站，已停止（密钥保留）。"
    elif (( rc != 0 )); then
      exit "$rc"
    else
      restart_xray
    fi
  else
    svc_disable_stop xray
  fi
  if (( HY2_ENABLED )); then
    [[ -x $HY_BIN ]] || install_hysteria
    write_hy2_config
    restart_hy2
  else
    svc_disable_stop hysteria-server
    remove_nat_hop
  fi
  if sb_needed; then
    [[ -x $SB_BIN ]] || install_singbox
    write_singbox_service
    write_singbox_config
    restart_singbox
  else
    svc_disable_stop sing-box
  fi
  apply_firewall
  save_state
  save_info
}


choose_ports() {
  local p
  # Xray / 落地机端口（关掉 Reality 时保留原端口，方便以后再打开）
  if (( LAND_MODE || REALITY_ENABLED )); then
  p=${OPT_PORT:-$XRAY_PORT}
  while :; do
    if [[ -z $OPT_PORT ]]; then ask p "${XRAY_LABEL:-VLESS-REALITY} 监听端口 ($( ((LAND_MODE)) && echo TCP+UDP || echo TCP))" "$p"; p=$(sanitize_port_input "$p"); p=${p// /}; fi
    if ! is_port "$p"; then
      (( OPT_AUTO )) && die "端口无效: $p"; warn "端口无效。"; p=443; continue
    fi
    if check_port_free tcp "$p" "xray" && { (( ! LAND_MODE )) || check_port_free udp "$p" "xray"; }; then XRAY_PORT=$p; break; fi
    (( OPT_AUTO )) || [[ -n $OPT_PORT ]] && die "端口 $p 已被占用，请释放或使用 --port 指定其它端口。"
  done
  fi
  (( ! LAND_MODE )) || { HY2_ENABLED=0; return 0; }
  # Hysteria2
  if [[ -n $OPT_HY2 ]]; then HY2_ENABLED=$OPT_HY2
  elif (( ! OPT_AUTO )); then
    if confirm "是否同时安装 Hysteria2（UDP，弱网/高丢包下表现更好）？" "$([[ $HY2_ENABLED == 1 ]] && echo y || echo n)"; then HY2_ENABLED=1; else HY2_ENABLED=0; fi
  fi
  if (( ! HY2_ENABLED )); then HOP_RANGE=""; else
  p=${OPT_HY2_PORT:-$HY2_PORT}
  while :; do
    [[ -z $OPT_HY2_PORT ]] && { ask p "Hysteria2 监听端口 (UDP)" "$p"; p=$(sanitize_port_input "$p"); p=${p// /}; }
    is_port "$p" || { (( OPT_AUTO )) && die "端口无效: $p"; warn "端口无效。"; p=443; continue; }
    if check_port_free udp "$p" "hysteria"; then HY2_PORT=$p; break; fi
    (( OPT_AUTO )) || [[ -n $OPT_HY2_PORT ]] && die "UDP 端口 $p 已被占用，请使用 --hy2-port 指定其它端口。"
  done
  # 端口跳跃
  local hop=${OPT_HOP:-${HOP_RANGE:-none}}
  [[ -z $OPT_HOP && -z $HOP_RANGE && $INSTALLED != 1 ]] && hop="20000-50000"
  while :; do
    [[ -z $OPT_HOP ]] && { ask hop "Hysteria2 端口跳跃范围（UDP，输入 none 关闭）" "$hop"; hop=$(sanitize_port_input "$hop"); hop=${hop// /}; }
    if [[ $hop == none || $hop == no || -z $hop ]]; then HOP_RANGE=""; break; fi
    if is_range "$hop"; then
      local a=${hop%-*}
      if (( a < 1024 )); then warn "跳跃范围起始端口应 ≥ 1024。"; else HOP_RANGE=$hop; break; fi
    else
      warn "范围格式无效，例如 20000-50000。"
    fi
    (( OPT_AUTO )) || [[ -n $OPT_HOP ]] && die "端口跳跃范围无效: $hop"
  done
  fi
  choose_extra_local
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
  # 落地机：--land，或已安装为落地机且未指定 --no-land
  if [[ $OPT_LAND == 1 ]] || { [[ $LAND_MODE == 1 && $OPT_LAND != 0 ]]; }; then do_install_land; return; fi
  local was_land=$LAND_MODE
  LAND_MODE=0
  preflight      # decide_nat_mode：命令行 / 菜单设置 / Alpine / 已安装 / 自动检测，端口设置前确定 NAT_MODE
  resolve_mode
  take_lock
    if (( was_land )); then
    info "由落地机改装为 Reality / XHTTP / Hysteria2 节点：移除落地机白名单规则，停止 Shadowsocks，重新生成节点配置。"
    land_fw_remove
    if is_openrc; then rc-service xray stop >/dev/null 2>&1 9>&- || true   # 避免旧的 SS 端口被当作「其它已监听端口」放行
    else systemctl stop xray >/dev/null 2>&1 || true; fi
    HY2_ENABLED=1
    REALITY_ENABLED=1
    [[ -n $OPT_XHTTP ]] || XHTTP_ENABLED=1
    if (( ! NAT_MODE )); then XRAY_PORT=443 HY2_PORT=443 HOP_RANGE="20000-50000"; fi
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

  ensure_proto_secrets
  save_state
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

  if (( HY2_ENABLED )); then
    install_hysteria
    write_hy2_config
    save_state
    restart_hy2
  elif [[ -x $HY_BIN || -f $HY_UNIT || -f $HY_RC ]]; then
    info "已关闭 Hysteria2，移除相关组件 ..."
    remove_hysteria
  fi
  if sb_needed; then
    install_singbox
    write_singbox_config
    save_state
    restart_singbox
  elif [[ -x $SB_BIN || -f $SB_UNIT || -f $SB_RC ]]; then
    info "已关闭 TUIC / AnyTLS，停止 sing-box（密码保留）。"
    svc_disable_stop sing-box
  fi

  apply_firewall
  (( NAT_MODE )) || setup_fail2ban
  INSTALLED=1
  save_state
  self_install
  ( trap - ERR; set +e; reality_selftest; xhttp_selftest ) || true
  show_info
  cloud_fw_reminder
  echo
  echo
  ui_bar '═' 62
  ui_center "安装完成" 62
  printf '%s管理菜单：proxy%s\n' "$C_OK" "$C_NONE"
  ui_bar '═' 62
}

# ============================================================
#               REALITY 自检（安装 / 更换 SNI 后）
# ============================================================
# 用已安装的 xray 在 127.0.0.1 的随机端口起一个临时 socks 客户端，按生成的链接参数
# （VLESS + Vision + REALITY + pqv）连接本机 127.0.0.1:XRAY_PORT，再经它访问外网。
# 只打印结果，不影响安装；客户端限制 GOMEMLIMIT，128MB 小鸡也可运行。
reality_selftest() {
  (( ${REALITY_ENABLED:-1} )) || return 0
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
  local eip=""
  if (( rc == 0 )) && relay_active; then
    eip=$(curl -s --connect-timeout 8 -m 12 --socks5-hostname "127.0.0.1:${port}" https://api64.ipify.org 2>/dev/null | tr -d '[:space:]') || eip=""
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if (( rc == 0 )); then
    local h=${ok_url#https://}; h=${h%%/*}
    ok "REALITY 自检通过：经本机节点访问 ${h} 返回 HTTP ${code}。"
    if relay_active; then
      if [[ -n $eip ]]; then ok "落地转发生效：客户端 → 本机 Reality → $(relay_tag) → 出口 IP ${eip}"
      else warn "经落地转发查询出口 IP 失败。"; fi
    fi
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

xhttp_selftest() {
  (( ${XHTTP_ENABLED:-0} )) || return 0
  [[ -x $XRAY_BIN && -n $UUID && -n $PUB_KEY && -n $SNI && -n $XHTTP_PORT && -n $XHTTP_PATH ]] || { warn "跳过 XHTTP 自检（缺少参数）。"; return 0; }
  mktmp
  local dir port="" i pid code="" url ok_url="" rc=1
  dir=$(mktemp -d "${TMP_DIR}/xhttp-self.XXXXXX") || { warn "跳过 XHTTP 自检（无法创建临时目录）。"; return 0; }
  for i in 1 2 3 4 5 6 7 8 9 10; do
    port=$(( 20000 + RANDOM % 40000 ))
    [[ $port == "$XRAY_PORT" || $port == "$XHTTP_PORT" || $port == "${HY2_PORT:-}" ]] && continue
    port_in_use tcp "$port" || break
  done
  if ! jq -n --arg id "$UUID" --argjson sport "$port" --argjson port "$XHTTP_PORT" --arg sni "$SNI" \
      --arg pbk "$PUB_KEY" --arg sid "$SHORT_ID" --arg path "$XHTTP_PATH" \
      --arg pqv "$(pqv_active && printf '%s' "$MLDSA_VERIFY")" '
    {
      log: {loglevel: "warning"},
      inbounds: [{listen: "127.0.0.1", port: $sport, protocol: "socks", settings: {udp: false}}],
      outbounds: [{
        protocol: "vless",
        settings: {vnext: [{address: "127.0.0.1", port: $port, users: [{id: $id, encryption: "none", flow: ""}]}]},
        streamSettings: {network: "xhttp", security: "reality",
          xhttpSettings: {path: $path, mode: "stream-one"},
          realitySettings: ({serverName: $sni, fingerprint: "chrome", publicKey: $pbk, shortId: $sid}
            + (if $pqv != "" then {mldsa65Verify: $pqv} else {} end))}
      }]
    }' >"${dir}/client.json" 2>/dev/null; then
    rm -rf "$dir"; warn "跳过 XHTTP 自检（生成临时配置失败）。"; return 0
  fi
  chmod 600 "${dir}/client.json"
  info "XHTTP 自检：临时客户端 127.0.0.1:${port} → 本机 127.0.0.1:${XHTTP_PORT}（mode stream-one，SNI ${SNI}）..."
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
    ok "XHTTP 自检通过：经本机节点访问 ${h} 返回 HTTP ${code}。"
  else
    warn "XHTTP 自检未通过。可查看 proxy status；客户端链接里的 mode 必须是 stream-one，path 必须与服务端一致。"
    grep -vi 'privatekey\|seed' "${dir}/client.log" 2>/dev/null | tail -n 3 | sed 's/^/    /' || true
  fi
  rm -rf "$dir"
  return 0
}

# ============================================================
#       落地机（Shadowsocks 2022 出口）/ 中转机的落地转发
# ============================================================
# 落地机：本机只运行 Xray 的 Shadowsocks 2022 入站（TCP+UDP），不装 Reality / Hysteria2 / fail2ban，
#         可选来源 IP 白名单（Xray 路由 + nftables 双重限制），仅允许中转机连接。
# 中转机：普通 / NAT 模式安装的节点，把 Xray 的默认出站改为落地机（ss:// 链接），
#         内网 / BT 屏蔽规则仍在最前；Hysteria2 经本机 127.0.0.1 的 socks 入站同样走落地机。
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
land_xray_json() {
  jq -n --argjson port "$XRAY_PORT" --arg method "$LAND_METHOD" --arg key "$LAND_KEY" \
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
      {tag: "direct", protocol: "freedom"},
      {tag: "block", protocol: "blackhole"}
    ],
    routing: {
      domainStrategy: "AsIs",
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
land_outbound_json() { # $1 方法 $2 密钥 $3 地址 $4 端口 $5 tag
  jq -n --arg m "$1" --arg k "$2" --arg a "$3" --argjson p "$4" --arg t "$5" \
    '{tag: $t, protocol: "shadowsocks", settings: {servers: [{address: $a, port: $p, method: $m, password: $k}]}}'
}

land_print_links() { # $1=1 屏幕着色
  local paint=${1:-0} link
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
    land_fw_remove; info "NAT 容器（${VIRT}）：来源白名单仅由 Xray 路由实现（非白名单连接被丢弃）。"; return 0
  fi
  have nft || { [[ -n $PKG ]] && pkg_try nftables; }
  if ! have nft; then land_fw_remove; info "未安装 nftables：来源白名单仅由 Xray 路由实现。"; return 0; fi
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
ss_probe() { # $1 地址 $2 端口 $3 方法 $4 密钥；成功时 LAND_EXIT_IP=出口 IP
  LAND_EXIT_IP=""
  [[ -x $XRAY_BIN ]] || { warn "未找到 xray，无法测试。"; return 1; }
  mktmp
  local dir port="" i pid url ip="" rc=1
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
    for url in "https://api.ipify.org" "https://api64.ipify.org" "https://ifconfig.co/ip" "https://icanhazip.com"; do
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
  info "落地机自检：临时客户端 → 本机 127.0.0.1:${XRAY_PORT}（SS2022）→ 外网 ..."
  if ss_probe 127.0.0.1 "$XRAY_PORT" "$LAND_METHOD" "$LAND_KEY"; then
    ok "落地机自检通过：出口 IP ${LAND_EXIT_IP}"
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

  # 清理节点模式的组件（若之前装过）
  RELAY_ON=0
  [[ -x $HY_BIN || -f $HY_UNIT || -f $HY_RC ]] && { info "移除 Hysteria2 ..."; remove_hysteria purge; }
  [[ -x $SB_BIN || -f $SB_UNIT || -f $SB_RC ]] && { info "移除 sing-box（TUIC / AnyTLS）..."; remove_singbox; }
  remove_nat_hop
  if [[ -f $FW_FILE || -f $FW_UNIT ]]; then info "移除节点模式的 nftables 规则 ..."; remove_firewall; fi
  if [[ -f $F2B_JAIL ]]; then rm -f "$F2B_JAIL"; systemctl restart fail2ban >/dev/null 2>&1 || true; fi
  FW_ENABLED=0

  install_xray
  save_state
  write_xray_config
  restart_xray
  land_fw_apply
  INSTALLED=1
  save_state
  self_install
  ( trap - ERR; set +e; land_selftest ) || true
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
  save_state
  write_xray_service
  write_xray_config
  restart_xray
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
  need_node
  [[ -n $RELAY_LINK ]] || { warn "尚未设置落地转发。"; return 0; }
  [[ $RELAY_ON == 1 ]] || { info "落地转发已是停用状态。"; return 0; }
  RELAY_ON=0; detect_os; apply_all
  ok "已停用落地转发（恢复直连出站；落地链接已保留，可用 proxy land-on 重新启用）。"
}
relay_on() {
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
    test) need_node; if [[ -z $RELAY_LINK ]] || ! ss_parse "$RELAY_LINK"; then die "尚未设置落地。"; fi; relay_test ;;
    *) load_state; if (( LAND_MODE )); then land_show_info; else menu_relay; fi ;;
  esac
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
  ok "SNI 已由 ${old} 更换为 ${SNI}。客户端需要更新链接（Hysteria2 证书指纹也已变化）。"
  show_info
}

menu_regen_keys() {
  need_installed
  if (( LAND_MODE )); then land_menu_key; return; fi
  warn "将重新生成 UUID、x25519 密钥、ShortId、ML-DSA-65 密钥、XHTTP 路径，以及 Hysteria2 / Trojan / TUIC / AnyTLS 密码。所有旧客户端将失效。已关闭的协议也会换新密钥，但不会被重新打开。"
  (( OPT_AUTO )) || confirm "确认重新生成？" n || return 0
  gen_xray_keys
  HY2_PASS=$(rand_pass)
  XHTTP_PATH="/$(rand_hex 8)"
  TROJAN_PASS=$(rand_pass)
  TUIC_PASS=$(rand_pass)
  ANYTLS_PASS=$(rand_pass)
  if (( HY2_ENABLED || TUIC_ENABLED || ANYTLS_ENABLED )); then gen_hy2_cert; fi
  apply_all
  ok "已重新生成全部密钥。"
  show_info
}

menu_change_ports() {
  need_installed
  if (( LAND_MODE )); then land_menu_port; return; fi
  nat_pref_guard || return 0
  if (( NAT_MODE )); then menu_change_ports_nat; return; fi
  local oldx=$XRAY_PORT oldh=$HY2_PORT
  choose_ports_interactive
  if (( HY2_ENABLED )) && [[ ! -x $HY_BIN ]]; then install_hysteria; fi
  if (( ! HY2_ENABLED )) && [[ -x $HY_BIN ]]; then remove_hysteria; fi
  if sb_needed && [[ ! -x $SB_BIN ]]; then install_singbox; fi
  if ! sb_needed && [[ -x $SB_BIN ]]; then svc_disable_stop sing-box; fi
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
  if sb_needed && [[ ! -x $SB_BIN ]]; then install_singbox; fi
  if ! sb_needed && [[ -x $SB_BIN ]]; then svc_disable_stop sing-box; fi
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
    1) install_xray; if xray_inbound_needed; then write_xray_config; restart_xray; else info "当前没有 Xray 入站，已跳过。"; fi ;;
    2) (( HY2_ENABLED )) || { warn "未启用 Hysteria2。"; return 0; }; install_hysteria; write_hy2_config; restart_hy2 ;;
    3) update_script ;;
    4) install_xray
       if xray_inbound_needed; then write_xray_config; restart_xray; fi
       if (( HY2_ENABLED )); then install_hysteria; write_hy2_config; restart_hy2; fi
       if sb_needed; then install_singbox; write_singbox_config; restart_singbox; fi
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
    ui_proto_line "$XHTTP_ENABLED" "VLESS + XHTTP + REALITY" "TCP $(pub_xhttp_port)"
    ui_proto_line "$HY2_ENABLED" "Hysteria2" "UDP $(pub_hy2_port)"
    hr
    printf '%s可选协议%s\n' "$C_TITLE" "$C_NONE"
    ui_proto_line "$TROJAN_ENABLED" "Trojan + REALITY" "TCP $(pub_trojan_port)"
    ui_proto_line "$TUIC_ENABLED" "TUIC v5" "UDP $(pub_tuic_port)"
    ui_proto_line "$ANYTLS_ENABLED" "AnyTLS" "TCP $(pub_anytls_port)"
  fi
  if (( LAND_MODE )); then
    printf '  落地机:         Shadowsocks 2022 %s，端口 %s (TCP+UDP)%s\n' "$LAND_METHOD" "$(pub_xray_port)" "$( ((NAT_MODE)) && echo " → 本机 ${XRAY_PORT}")"
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
  echo; _cyan "  监听端口："
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
    echo "  1) 查看 Xray 日志   2) 查看 Hysteria2 日志   3) 查看防火墙规则   4) 实时跟踪 Xray 日志   0) 返回"
  fi
  local c; ask c "请选择" "0"
  case $c in
    1) svc_logs xray 80 ;;
    2) svc_logs hysteria-server 80 ;;
    3) if (( NAT_MODE )); then if [[ -n $HOP_RANGE ]]; then show_hop_rules; fi
       elif (( LAND_MODE )); then nft list table inet "$LAND_NFT_TABLE" 2>/dev/null || warn "未启用 nftables 白名单。"
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
   · 查看回程路由：在 VPS 上运行 nexttrace（https://github.com/nxtrace/NTrace-core）
   · 晚高峰丢包严重时优先使用 Hysteria2；TCP 稳定时 REALITY 延迟更低
   · SNI 目标延迟过高（> 100ms）时，可在菜单中「更换 SNI」重新优选
TIP
}

menu_firewall() {
  need_installed
  if (( LAND_MODE )); then land_menu_allow; return; fi
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
  rm -f "$XRAY_BIN"; rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  sd_reload
  ok "Xray 已移除"
  remove_hysteria purge; ok "Hysteria2 已移除"
  remove_singbox; ok "sing-box 已移除"
  remove_nat_hop
  remove_firewall; land_fw_remove; ok "防火墙 / 端口跳跃 / 落地机白名单规则已移除"
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
proto_ensure_port() { # $1 reality|xhttp|hy2|trojan|tuic|anytls ；失败时调用方应把开关改回
  local kind=$1
  if (( NAT_MODE )); then
    nat_seed_used
    case $kind in
      reality) NAT_USED_TCP=${NAT_USED_TCP// $XRAY_EXT_PORT /}; nat_pick_mapped tcp XRAY_EXT_PORT XRAY_PORT "" "VLESS-REALITY" "xray" ;;
      xhttp) NAT_USED_TCP=${NAT_USED_TCP// $XHTTP_EXT_PORT /}; nat_pick_mapped tcp XHTTP_EXT_PORT XHTTP_PORT "" "VLESS-XHTTP（REALITY）" "xray" ;;
      trojan) NAT_USED_TCP=${NAT_USED_TCP// $TROJAN_EXT_PORT /}; nat_pick_mapped tcp TROJAN_EXT_PORT TROJAN_PORT "" "Trojan（REALITY）" "xray" ;;
      anytls) NAT_USED_TCP=${NAT_USED_TCP// $ANYTLS_EXT_PORT /}; nat_pick_mapped tcp ANYTLS_EXT_PORT ANYTLS_PORT "" "AnyTLS" "sing-box" ;;
      hy2) NAT_USED_UDP=${NAT_USED_UDP// $HY2_EXT_PORT /}; nat_pick_mapped udp HY2_EXT_PORT HY2_PORT "" "Hysteria2" "hysteria" ;;
      tuic) NAT_USED_UDP=${NAT_USED_UDP// $TUIC_EXT_PORT /}; nat_pick_mapped udp TUIC_EXT_PORT TUIC_PORT "" "TUIC v5" "sing-box" ;;
    esac
  else
    local_seed_used
    case $kind in
      reality) LOCAL_USED_TCP=${LOCAL_USED_TCP// $XRAY_PORT /}; local_pick tcp XRAY_PORT "" "VLESS-REALITY" "xray" "${XRAY_PORT:-443}" ;;
      xhttp) LOCAL_USED_TCP=${LOCAL_USED_TCP// $XHTTP_PORT /}; local_pick tcp XHTTP_PORT "" "VLESS-XHTTP（REALITY）" "xray" "${XHTTP_PORT:-8443}" ;;
      trojan) LOCAL_USED_TCP=${LOCAL_USED_TCP// $TROJAN_PORT /}; local_pick tcp TROJAN_PORT "" "Trojan（REALITY）" "xray" "${TROJAN_PORT:-8444}" ;;
      anytls) LOCAL_USED_TCP=${LOCAL_USED_TCP// $ANYTLS_PORT /}; local_pick tcp ANYTLS_PORT "" "AnyTLS" "sing-box" "${ANYTLS_PORT:-8445}" ;;
      hy2) LOCAL_USED_UDP=${LOCAL_USED_UDP// $HY2_PORT /}; local_pick udp HY2_PORT "" "Hysteria2" "hysteria" "${HY2_PORT:-443}" ;;
      tuic) LOCAL_USED_UDP=${LOCAL_USED_UDP// $TUIC_PORT /}; local_pick udp TUIC_PORT "" "TUIC v5" "sing-box" "${TUIC_PORT:-8446}" ;;
    esac
  fi
}
menu_proto() {
  need_node
  [[ -n $OS_ID ]] || detect_os
  [[ -n $VIRT ]] || detect_virt
  while :; do
    local on=开 off=关
    echo
    ui_logo
    printf '%s关闭只停止监听，不删除 UUID、密钥和密码。%s\n' "$C_DIM" "$C_NONE"
    ui_columns "oneclick proxy" "返回" \
      "VLESS + REALITY + Vision  $([[ $REALITY_ENABLED == 1 ]] && echo "$on" || echo "$off")" \
      "VLESS + XHTTP + REALITY  $([[ $XHTTP_ENABLED == 1 ]] && echo "$on" || echo "$off")" \
      "Hysteria2  $([[ $HY2_ENABLED == 1 ]] && echo "$on" || echo "$off")" \
      "Trojan + REALITY  $([[ $TROJAN_ENABLED == 1 ]] && echo "$on" || echo "$off")" \
      "TUIC v5  $([[ $TUIC_ENABLED == 1 ]] && echo "$on" || echo "$off")" \
      "AnyTLS  $([[ $ANYTLS_ENABLED == 1 ]] && echo "$on" || echo "$off")"
    local c kind var
    ask c "请选择" "0"
    case $c in
      1) kind=reality; var=REALITY_ENABLED ;;
      2) kind=xhttp; var=XHTTP_ENABLED ;;
      3) kind=hy2; var=HY2_ENABLED ;;
      4) kind=trojan; var=TROJAN_ENABLED ;;
      5) kind=tuic; var=TUIC_ENABLED ;;
      6) kind=anytls; var=ANYTLS_ENABLED ;;
      *) return 0 ;;
    esac
    if (( ${!var} )); then
      printf -v "$var" 0
      if ! proto_any_enabled; then
        printf -v "$var" 1
        warn "至少保留一个协议。"
        continue
      fi
      info "已关闭（密钥保留）。"
    else
      printf -v "$var" 1
      if ! proto_ensure_port "$kind"; then
        printf -v "$var" 0
        warn "没有可用端口，保持关闭。"
        continue
      fi
      info "已开启。"
    fi
    if [[ $kind == hy2 && $HY2_ENABLED == 1 && ! -x $HY_BIN ]]; then install_hysteria; fi
    if [[ $kind == hy2 && $HY2_ENABLED == 0 ]]; then svc_disable_stop hysteria-server; remove_nat_hop; fi
    apply_proto_services
    ok "协议状态已更新。"
    show_info
  done
}

show_menu() {
  load_state
  clear 2>/dev/null || true
  [[ -n $INIT_SYS ]] || detect_init
  if (( LAND_MODE )); then show_land_menu; return; fi
  local menu10="防火墙管理"; (( NAT_MODE )) && menu10="NAT 信息 / 端口跳跃"
  local mode_lbl; mode_lbl=$(nat_mode_label)
  local st_word
  if (( ! INSTALLED )); then st_word="未安装"
  elif svc_active xray || { (( HY2_ENABLED )) && svc_active hysteria-server; } || { sb_needed && svc_active sing-box; }; then
    st_word="运行中"
  else st_word="已安装"; fi
  echo
  ui_logo
  echo
  ui_stat_row "IP" "${SERVER_ADDR:-${PUBLIC_IP4:-${PUBLIC_IP6:-未检测}}}" "Xray" "$(ui_ver_plain "$XRAY_BIN" xray)"
  ui_stat_row "Hysteria2" "$(ui_ver_plain "$HY_BIN" hy2)" "sing-box" "$(ui_ver_plain "$SB_BIN" sb)"
  ui_stat_row "状态" "$st_word" "模式" "$mode_lbl"
  [[ -n $SNI ]] && ui_stat_row "SNI" "$SNI"
  (( NAT_MODE && INSTALLED )) && ui_stat_row "地址" "${SERVER_ADDR:-未设置}" "映射" "${NAT_PORTS:-未设置}"
  ui_columns "oneclick proxy" "退出" \
    "安装 / 重新安装" \
    "查看链接 / 二维码 / Clash 配置" \
    "更换 SNI（重新优选目标网站）" \
    "重新生成密钥 / UUID" \
    "修改端口 / 端口跳跃" \
    "用户管理（添加 / 删除）" \
    "更新 Xray / Hysteria2 / 脚本" \
    "运行状态 / 日志" \
    "网络测速 / 延迟提示" \
    "$menu10" \
    "网络调优（BBR / 队列算法 / 缓冲区 / 恢复）" \
    "添加 / 修改落地转发（本机作中转，出口走落地机）" \
    "安装为落地机（Shadowsocks 2022 出口，给其它中转机用）" \
    "卸载" \
    "切换 NAT 模式（当前: $(nat_pref_text)）" \
    "协议开关"
  local c act=""; ask c "请选择" ""
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
    11) act=menu_tune ;;
    12) act=menu_relay ;;
    13) OPT_LAND=1; act=do_install ;;
    14) act=do_uninstall ;;
    15) act=menu_nat_pref ;;
    16) act=menu_proto ;;
    0|q|Q) exit 0 ;;
    *) warn "请输入正确的数字。"; return 0 ;;
  esac
  run_menu_act "$act"
}
run_menu_act() {
  local act=$1
  # 在子 shell 中执行：出错时返回菜单而不是直接退出
  local rc=0
  set +e
  ( set -e; "$act" )
  rc=$?
  set -e
  OPT_LAND=""
  (( rc == 0 )) || warn "操作未完成（退出码 ${rc}）。"
  [[ $act == do_uninstall && ! -x $BIN_PATH && ! -f $STATE_FILE ]] && exit 0
  return 0
}

show_land_menu() {
  local st_word
  if (( ! INSTALLED )); then st_word="未安装"
  elif svc_active xray; then st_word="运行中"
  else st_word="已安装"; fi
  echo
  ui_logo
  echo
  ui_stat_row "IP" "${SERVER_ADDR:-${PUBLIC_IP4:-${PUBLIC_IP6:-未检测}}}" "Xray" "$(ui_ver_plain "$XRAY_BIN" xray)"
  ui_stat_row "状态" "$st_word" "模式" "$(nat_mode_label)"
  ui_stat_row "加密" "${LAND_METHOD#2022-blake3-}" "白名单" "${LAND_ALLOW:-未设置}"
  (( NAT_MODE )) && ui_stat_row "地址" "${SERVER_ADDR:-未设置}" "映射" "${NAT_PORTS:-未设置}"
  ui_columns "oneclick proxy" "退出" \
    "安装 / 重新安装（落地机）" \
    "查看 ss:// 链接 / 中转机命令 / Xray 出站片段" \
    "修改来源 IP 白名单" \
    "修改端口" \
    "更换密钥 / 加密方式" \
    "更新 Xray / 脚本" \
    "运行状态 / 日志" \
    "网络调优（BBR / 队列算法 / 缓冲区 / 恢复）" \
    "改装为 Reality / Hysteria2 节点" \
    "卸载" \
    "切换 NAT 模式（当前: $(nat_pref_text)）"
  local c act=""; ask c "请选择" ""
  (( TTY_EOF )) && { echo; exit 0; }
  case $c in
    1) act=do_install ;;
    2) act=show_info ;;
    3) act=land_menu_allow ;;
    4) act=land_menu_port ;;
    5) act=land_menu_key ;;
    6) act=menu_update ;;
    7) act=menu_status ;;
    8) act=menu_tune ;;
    9) OPT_LAND=0; act=do_install ;;
    10) act=do_uninstall ;;
    11) act=menu_nat_pref ;;
    0|q|Q) exit 0 ;;
    *) warn "请输入正确的数字。"; return 0 ;;
  esac
  run_menu_act "$act"
}

usage() {
  cat <<USAGE
哈人 / oneclick proxy v${SCRIPT_VERSION} —— VLESS + REALITY + XHTTP + Hysteria2

用法: bash proxy.sh [选项]        （安装后可直接使用 proxy [命令/选项]）

安装选项:
  --auto              使用全部默认值自动安装（非交互）
  --sni <域名>        指定 REALITY 目标网站（会进行合规检测）
  --force-sni         与 --sni 一起使用：检测不通过也强制使用
  --scan              使用 RealiTLScanner 扫描 VPS 附近 IP 寻找 SNI（高级，约 60 秒）
  --port <端口>       VLESS-REALITY TCP 端口（默认 443）
  --no-hy2            不安装 Hysteria2
  --hy2-port <端口>   Hysteria2 UDP 端口（默认 443）
  --no-reality        不启用 VLESS + REALITY + Vision（默认启用）
  --no-xhttp          不启用 VLESS + XHTTP + REALITY（默认启用，免自己的域名）
  --xhttp-port <端口> XHTTP 的 TCP 端口（默认 8443；NAT 模式为外部端口）
  --trojan            额外启用 Trojan + REALITY（默认不装）
  --no-trojan         关闭 Trojan
  --trojan-port <端口> Trojan TCP 端口（默认 8444）
  --tuic              额外启用 TUIC v5（sing-box，自签证书，默认不装）
  --no-tuic           关闭 TUIC
  --tuic-port <端口>  TUIC UDP 端口（默认 8446）
  --anytls            额外启用 AnyTLS（sing-box，自签证书，默认不装）
  --no-anytls         关闭 AnyTLS
  --anytls-port <端口> AnyTLS TCP 端口（默认 8445）
  --hop <a-b|none>    Hysteria2 端口跳跃范围（默认 20000-50000，none 关闭）
  --name <名称>       节点名称（默认 国家-城市）
  --no-firewall       不配置 nftables 防火墙
  --no-upgrade        跳过系统软件包升级
  --no-tune           跳过 sysctl 网络调优
  --tune-preset <名>  安装/调优使用的预设（默认 bbr-fq，见下方「网络调优」）
  -h, --help          显示帮助

双栈（同时有 IPv4 和 IPv6）写入节点配置时询问出站策略：IPv4优先 / IPv6优先 / 仅IPv4 / 仅IPv6（记在 state.env，之后沿用；--auto 默认 IPv4优先；只有一种地址时不询问）。

NAT 小鸡模式（端口映射 / LXC / OpenVZ / Alpine，自动跳过防火墙·fail2ban·Swap；调优可选）:
  --nat               启用 NAT 模式（Alpine 自动启用；LXC/OpenVZ 未指定时询问；之后 proxy 命令自动沿用）
  --no-nat            切换回普通模式
  --nat-addr <地址>   链接中使用的入口 IP 或域名（商家端口映射地址；交互时必填，--auto 未指定时暂用出口 IP）
  --nat-ports <列表>  服务商已映射的端口，逗号分隔，每项 外部[:内部]
                      例: 52430,52431   52430:8443   整段转发: 10001-10020 或 10001-10020:20001-20020
  --port <外部[:内部]>      NAT 模式下为 Reality 外部端口（未给 --nat-ports 时自动加入映射列表）
  --hy2-port <外部[:内部]>  NAT 模式下为 Hysteria2 外部端口（可与 --port 相同 = TCP+UDP 共用）
  --nat-share         Reality(TCP) 与 Hysteria2(UDP) 共用一个外部端口（需服务商同时映射 TCP+UDP）
  --nat-no-share      Reality 与 Hysteria2 使用不同端口
  --nat-exclude <端口> 整段转发时需要排除的外部端口（如映射给 SSH 的端口），逗号分隔
  --hop <段>          NAT 模式默认关闭；仅整段转发时可用，例如 10003-10020（自动跳过 Reality/排除端口）
  --dns64             IPv6-only 机器无法访问 GitHub 时写入公共 DNS64 服务器
  --tune / --upgrade  NAT 模式下执行网络调优（只写可写参数）/ 系统升级（交互安装会询问调优，--auto 默认跳过）
  例: bash proxy.sh --nat --auto --nat-addr 1.2.3.4 --nat-ports 52430,52431
      bash proxy.sh --nat --auto --port 52430 --nat-share      # 只有一个 TCP+UDP 映射端口
      bash proxy.sh --nat --auto --nat-port 59221:443        # 公网 59221 → 内部 443（TCP+UDP 同一条映射）

网络调优（独立功能，未安装代理也可用；NAT / LXC / Alpine 自动跳过只读参数）:
  proxy tune                  交互菜单（查看状态 / 选择预设 / 恢复）
  proxy tune status           当前拥塞控制、队列算法、关键参数及是否可写
  proxy tune preview          只预览（当前值 → 目标值），不修改
  proxy tune apply            应用（先预览再确认；加 --auto 不询问）
  proxy tune restore          恢复调优前的原值并删除配置文件
  --tune-preset <名>  bbr-fq（默认）| bbr-fq_codel | bbr-cake | cubic-fq_codel（保守）| keep（只调缓冲区）| custom
  --tune-cc <算法>    自定义拥塞控制（须在 tcp_available_congestion_control 中），例如 bbr / cubic
  --tune-qdisc <算法> 自定义队列算法：fq | fq_codel | cake | fq_pie | sfq | pfifo_fast
  --tune-buffer <档>  auto（按内存，默认）| small | medium | large | bdp
  --tune-bw <Mbps> --tune-rtt <ms>   按带宽×延迟（BDP）计算缓冲区上限
  例: proxy tune apply --tune-preset bbr-fq_codel --auto
      proxy tune apply --tune-cc bbr --tune-qdisc cake --tune-bw 1000 --tune-rtt 180

落地机 / 落地转发（中转机 → 落地机，出口 IP 为落地机）:
  --land              安装为落地机：只运行 Xray Shadowsocks 2022（TCP+UDP），无 Reality/Hy2，内存占用最低
                      可与 --nat（NAT 映射端口 / Alpine）、--port、--name、--auto 组合
  --land-method <m>   aes-128（默认 2022-blake3-aes-128-gcm）| aes-256 | chacha20
  --land-allow <列表> 来源 IP 白名单（只允许中转机；IPv4/IPv6/CIDR，逗号分隔；none = 不限制）
  --no-land           落地机改装回 Reality / Hysteria2 节点
  例: bash proxy.sh --land --auto --land-allow 203.0.113.10          # 落地机，只允许中转机 203.0.113.10
      bash proxy.sh --land --nat --auto --port 52430:8388            # NAT 落地机：公网 52430 → 内部 8388
  proxy allow [--land-allow 列表]   （落地机）修改来源白名单
  proxy land-add 'ss://...'         （中转机）添加 / 替换落地：测试连通后设为默认出站（--force 测试失败也启用）
  proxy land-test | land-off | land-on | land-del   （中转机）测试 / 停用（恢复直连，保留链接）/ 重新启用 / 删除
  proxy land                        菜单（落地机上显示 ss:// 链接）

管理命令:
  proxy               打开交互菜单
  proxy info          查看链接 / 二维码 / mihomo 配置
  proxy proto         单独打开或关闭协议（不删除已有密钥）
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
  proxy tune          网络调优（见上）
  proxy land          落地转发 / 落地机信息（见上）
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
      --hy2-port=*) OPT_HY2_PORT=${1#*=}; is_port_opt "$OPT_HY2_PORT" || die "--hy2-port 参数无效" ;;
      --reality) OPT_REALITY=1 ;;
      --no-reality) OPT_REALITY=0 ;;
      --xhttp) OPT_XHTTP=1 ;;
      --no-xhttp) OPT_XHTTP=0 ;;
      --xhttp-port) is_port_opt "${2-}" || die "--xhttp-port 参数无效"; OPT_XHTTP_PORT=$2; shift ;;
      --xhttp-port=*) OPT_XHTTP_PORT=${1#*=}; is_port_opt "$OPT_XHTTP_PORT" || die "--xhttp-port 参数无效" ;;
      --trojan) OPT_TROJAN=1 ;;
      --no-trojan) OPT_TROJAN=0 ;;
      --trojan-port) is_port_opt "${2-}" || die "--trojan-port 参数无效"; OPT_TROJAN_PORT=$2; shift ;;
      --trojan-port=*) OPT_TROJAN_PORT=${1#*=}; is_port_opt "$OPT_TROJAN_PORT" || die "--trojan-port 参数无效" ;;
      --tuic) OPT_TUIC=1 ;;
      --no-tuic) OPT_TUIC=0 ;;
      --tuic-port) is_port_opt "${2-}" || die "--tuic-port 参数无效"; OPT_TUIC_PORT=$2; shift ;;
      --tuic-port=*) OPT_TUIC_PORT=${1#*=}; is_port_opt "$OPT_TUIC_PORT" || die "--tuic-port 参数无效" ;;
      --anytls) OPT_ANYTLS=1 ;;
      --no-anytls) OPT_ANYTLS=0 ;;
      --anytls-port) is_port_opt "${2-}" || die "--anytls-port 参数无效"; OPT_ANYTLS_PORT=$2; shift ;;
      --anytls-port=*) OPT_ANYTLS_PORT=${1#*=}; is_port_opt "$OPT_ANYTLS_PORT" || die "--anytls-port 参数无效" ;;
      --hop) [[ ${2-} == none ]] || is_range "${2-}" || valid_segs "${2-}" || die "--hop 参数无效（例如 20000-50000 或 none）"; OPT_HOP=$2; shift ;;
      --no-hop) OPT_HOP=none ;;
      --name) [[ -n ${2-} ]] || die "--name 需要参数"; OPT_NAME=$(tr -cd 'A-Za-z0-9_.-' <<<"$2"); shift ;;
      --no-firewall) OPT_FIREWALL=0 ;;
      --no-upgrade) OPT_UPGRADE=0 ;;
      --no-tune) OPT_TUNE=0 ;;
      --tune) OPT_TUNE=1 ;;
      --upgrade) OPT_UPGRADE=1 ;;
      --tune-preset|--tune-preset=*)
        local tp; if [[ $1 == *=* ]]; then tp=${1#*=}; else tp=${2-}; shift; fi
        OPT_TUNE_PRESET=$(tune_norm_preset "$tp") || die "--tune-preset 参数无效: ${tp}（可选 ${TUNE_PRESETS[*]}）" ;;
      --tune-buffer|--tune-buf)
        case ${2-} in auto|small|medium|large|bdp) OPT_TUNE_BUF=$2 ;; *) die "--tune-buffer 参数无效（auto|small|medium|large|bdp）" ;; esac; shift ;;
      --tune-cc) [[ ${2-} =~ ^[a-z0-9_]{1,16}$ ]] || die "--tune-cc 参数无效"; OPT_TUNE_CC=$2; shift ;;
      --tune-qdisc) [[ ${2-} =~ ^(fq|fq_codel|cake|fq_pie|sfq|pfifo_fast|keep)$ ]] || die "--tune-qdisc 参数无效（fq|fq_codel|cake|fq_pie|sfq|pfifo_fast）"; OPT_TUNE_QDISC=$2; shift ;;
      --tune-bw) [[ ${2-} =~ ^[0-9]{1,6}$ ]] || die "--tune-bw 需要 1-100000 的整数（Mbps）"
        OPT_TUNE_BW=$((10#$2)); (( OPT_TUNE_BW >= 1 && OPT_TUNE_BW <= 100000 )) || die "--tune-bw 需要 1-100000 的整数（Mbps）"; shift ;;
      --tune-rtt) [[ ${2-} =~ ^[0-9]{1,5}$ ]] || die "--tune-rtt 需要 1-2000 的整数（ms）"
        OPT_TUNE_RTT=$((10#$2)); (( OPT_TUNE_RTT >= 1 && OPT_TUNE_RTT <= 2000 )) || die "--tune-rtt 需要 1-2000 的整数（ms）"; shift ;;
      tune|tuning)
        OPT_ACTION=tune
        case ${2-} in
          status|show) OPT_TUNE_ACT=status; shift ;;
          preview|diff|dry-run) OPT_TUNE_ACT=preview; shift ;;
          apply|set) OPT_TUNE_ACT=apply; shift ;;
          restore|reset|revert) OPT_TUNE_ACT=restore; shift ;;
        esac ;;
      --nat) OPT_NAT=1 ;;
      --no-nat) OPT_NAT=0 ;;
      --nat-addr|--addr) [[ -n ${2-} ]] || die "$1 需要参数"; OPT_NAT_ADDR=$2; shift ;;
      --nat-ports|--nat-port) [[ -n ${2-} ]] || die "--nat-ports 需要参数（例如 52430,52431）"; nat_norm_list "$2" >/dev/null || die "--nat-ports 参数无效: $2"; OPT_NAT_EXT=$2; shift ;;
      --nat-exclude) [[ -n ${2-} ]] || die "--nat-exclude 需要参数"; OPT_NAT_EXCLUDE=$2; shift ;;
      --nat-share) OPT_NAT_SHARE=1 ;;
      --nat-no-share) OPT_NAT_SHARE=0 ;;
      --dns64) OPT_DNS64=1 ;;
      --land) OPT_LAND=1 ;;
      --no-land) OPT_LAND=0 ;;
      --land-method) land_norm_method "${2-}" >/dev/null || die "--land-method 参数无效（aes-128 | aes-256 | chacha20）"; OPT_LAND_METHOD=$2; shift ;;
      --land-allow)
        [[ -n ${2-} ]] || die "--land-allow 需要参数（例如 1.2.3.4,2001:db8::/64，或 none）"
        if [[ ${2,,} == none ]]; then OPT_LAND_ALLOW=none; else land_norm_allow "$2" || die "--land-allow 中有无效地址: ${LAND_BAD}"; OPT_LAND_ALLOW=$2; fi
        shift ;;
      --force) OPT_FORCE=1 ;;
      land-add|relay-add)
        OPT_ACTION=land; OPT_LAND_ACT=add
        if [[ ${2-} == ss://* ]]; then OPT_LAND_LINK=$2; shift; fi ;;
      ss://*) OPT_LAND_LINK=$1; [[ -n $OPT_ACTION ]] || { OPT_ACTION=land; OPT_LAND_ACT=add; } ;;
      land-on|relay-on) OPT_ACTION=land; OPT_LAND_ACT=on ;;
      land-off|relay-off) OPT_ACTION=land; OPT_LAND_ACT=off ;;
      land-del|land-rm|land-remove|relay-del) OPT_ACTION=land; OPT_LAND_ACT=del ;;
      land-test|relay-test) OPT_ACTION=land; OPT_LAND_ACT="test" ;;
      land|relay) OPT_ACTION=land ;;
      allow|whitelist) OPT_ACTION=allow ;;
      -h|--help|help) usage; exit 0 ;;
      -v|--version|version) echo "$SCRIPT_VERSION"; exit 0 ;;
      install) OPT_ACTION=install ;;
      info|link|links|qr) OPT_ACTION=info ;;
      proto|protos|protocol) OPT_ACTION=proto ;;
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
  if [[ -z $OPT_ACTION ]] && { (( OPT_AUTO )) || [[ -n $OPT_SNI || -n $OPT_PORT || -n $OPT_HY2 || -n $OPT_HOP || -n $OPT_NAT || -n $OPT_NAT_EXT || -n $OPT_LAND || -n $OPT_REALITY || -n $OPT_XHTTP || -n $OPT_XHTTP_PORT || -n $OPT_TROJAN || -n $OPT_TROJAN_PORT || -n $OPT_TUIC || -n $OPT_TUIC_PORT || -n $OPT_ANYTLS || -n $OPT_ANYTLS_PORT ]]; }; then
    OPT_ACTION=install
  fi
  # 只给了 --land-allow：修改落地机白名单
  [[ -z $OPT_ACTION && -n $OPT_LAND_ALLOW ]] && OPT_ACTION=allow
  # 只给了调优参数（或单独的 --tune）：执行独立调优
  if [[ -z $OPT_ACTION ]] && { [[ -n $OPT_TUNE_PRESET$OPT_TUNE_CC$OPT_TUNE_QDISC$OPT_TUNE_BUF$OPT_TUNE_BW$OPT_TUNE_RTT ]] || [[ $OPT_TUNE == 1 ]]; }; then
    OPT_ACTION=tune
  fi
  [[ -n $OPT_TUNE_BW && -z $OPT_TUNE_RTT || -z $OPT_TUNE_BW && -n $OPT_TUNE_RTT ]] && die "--tune-bw 与 --tune-rtt 需要同时使用"
  # 普通模式下 --port / --hy2-port 只接受单个端口；NAT 模式的 外部:内部 写法在安装时再校验
  if [[ $OPT_NAT != 1 ]]; then
    [[ -z $OPT_PORT || $OPT_PORT != *:* || -f $STATE_FILE ]] || die "--port 的 外部:内部 写法仅用于 NAT 模式（--nat）。"
    local _po
    for _po in "$OPT_HY2_PORT" "$OPT_XHTTP_PORT" "$OPT_TROJAN_PORT" "$OPT_TUIC_PORT" "$OPT_ANYTLS_PORT"; do
      [[ -z $_po || $_po != *:* || -f $STATE_FILE ]] || die "外部:内部 端口写法仅用于 NAT 模式（--nat）。"
    done
  fi
  return 0
}
tune_norm_preset() { # 预设名（含别名）→ 标准名
  case ${1,,} in
    bbr-fq|bbr|default|fq) echo bbr-fq ;;
    bbr-fq_codel|bbr-fqcodel|fq_codel) echo bbr-fq_codel ;;
    bbr-cake|cake) echo bbr-cake ;;
    cubic-fq_codel|cubic|conservative|safe) echo cubic-fq_codel ;;
    keep|buffers|buffer|none) echo keep ;;
    custom) echo custom ;;
    *) return 1 ;;
  esac
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
    proto) menu_proto ;;
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
    tune) do_tune ;;
    land) do_land_cli ;;
    allow) land_menu_allow ;;
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
