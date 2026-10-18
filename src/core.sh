#!/usr/bin/env bash
# 本文件由 build.sh 从 src/ 拼接生成。请改 src/ 后执行 ./build.sh，不要直接改本文件。
#
# proxy.sh —— VLESS + REALITY + Vision、VLESS + XHTTP + REALITY、Hysteria2 一键安装 / 管理脚本
# 可选（默认不装）：Trojan + REALITY、TUIC v5、AnyTLS，以及需要自有域名和公开证书的
# VLESS + XHTTP + TLS、VLESS + WebSocket + TLS（放在 CDN 后面，不是 REALITY）。Shadowsocks 2022 仅用于落地机。
#
# 用法:
#   bash proxy.sh                 # 交互式菜单
#   bash proxy.sh --auto          # 全部默认值自动安装
#   bash proxy.sh --firewall allow   # 只放行代理端口，不把入站改成默认拒绝（strict|allow|off）
#   bash proxy.sh --nat           # NAT 小鸡模式（端口映射 / LXC / OpenVZ / Alpine）
#   bash proxy.sh tune            # 网络调优（BBR / 队列算法 / 缓冲区；可单独使用，NAT/容器也可用）
#   bash proxy.sh --land          # 落地机：只运行 Shadowsocks 2022（给中转机做出口，可设来源 IP 白名单）
#   proxy land-add 'ss://...'     # 中转机：出口改到落地机；落地机：加密转发到下一跳
#   proxy land-direct | land-clear    # 落地机：本机直连，清除下一跳、原样转发和 DNAT
#   proxy land-forward 'ss://...' | land-raw 'ss://...'
#                                 # 落地机：原样转发（不解密，DNAT 到最终落地）
#   bash proxy.sh --cert-domain example.com   # 可选：默认 Let's Encrypt 单域名 HTTP-01
#   bash proxy.sh --cert-kind wildcard --cert-domain example.com --cf-dns-token <令牌>
#   bash proxy.sh --cert-kind cf-origin --cf-origin-key <钥匙> --cert-domain cdn.example.com
#   bash proxy.sh --xhttp-tls --ws-tls --cert-domain example.com
#                                 # 可选：CDN 上的 XHTTP+TLS / WebSocket+TLS（默认不装，不替换 REALITY）
#                                 # 这两条默认带 VLESS Encryption；--no-vless-enc 不加，proxy vless-enc on|off|rotate
#   bash proxy.sh route           # 回程线路检测（不改配置）
#   bash proxy.sh outbound        # 出站地址族；内网 ULA 会探测 NAT66。--outbound 46|64|4|6|auto
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

readonly SCRIPT_VERSION="1.6.0"
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
# 写进 ufw / firewalld 的条目。只删除这份清单里的规则，不动用户原来就有的放行。
readonly FW_HOST_FILE="${STATE_DIR}/fw-host.list"
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
# 落地机原样转发：单独的 nat 表，不并进来源白名单那张 filter 表（白名单为空时会删 filter 表）。
readonly LAND_FWD_TABLE="proxy_oneclick_fwd"
readonly LAND_FWD_FILE="${STATE_DIR}/land-fwd.nft"
readonly LAND_FWD_SCRIPT="${STATE_DIR}/land-fwd.sh"
readonly LAND_FWD_UNIT="/etc/systemd/system/proxy-oneclick-fwd.service"
readonly LAND_FWD_RC="/etc/init.d/proxy-oneclick-fwd"
readonly LAND_FWD_SYSCTL="/etc/sysctl.d/99-proxy-oneclick-fwd.conf"
readonly RESOLV_BAK="${STATE_DIR}/resolv.conf.bak"
# 可选的公开证书（Let's Encrypt）。不申请时下面的目录不会被创建，节点仍用自签证书。
readonly CERT_NAME="proxy-oneclick"
readonly CERT_BASE="/etc/proxy-oneclick"
readonly CERT_DIR="${CERT_BASE}/certs"
readonly CERT_FULLCHAIN="${CERT_DIR}/fullchain.pem"
readonly CERT_PRIVKEY="${CERT_DIR}/privkey.pem"
readonly CERT_LIB="/usr/local/lib/proxy-oneclick"
readonly SUB_PY="${CERT_LIB}/sub_https.py"
readonly CERT_HOOK="${CERT_LIB}/cert-deploy.sh"
readonly SUB_CONF="${CERT_DIR}/sub.json"
readonly SUB_BODY="${CERT_DIR}/sub.txt"
readonly SUB_CLASH="${CERT_DIR}/sub-clash.yaml"
readonly SUB_UNIT="/etc/systemd/system/proxy-oneclick-sub.service"
readonly SUB_RC="/etc/init.d/proxy-oneclick-sub"
readonly SUB_LOG="/var/log/proxy-oneclick/sub.log"
readonly CERT_TIMER_UNIT="/etc/systemd/system/proxy-oneclick-cert.timer"
readonly CERT_RENEW_UNIT="/etc/systemd/system/proxy-oneclick-cert.service"
readonly CERT_CRON="/etc/periodic/daily/proxy-oneclick-cert"
readonly CERT_GROUP="proxy-cert"
readonly SUB_USER="proxy-sub"
# CDN 上的 XHTTP+TLS / WebSocket+TLS 读这份证书副本（nobody 能读）。REALITY 入站不引用它。
readonly XRAY_CERT_DIR="/usr/local/etc/xray/certs"
readonly XRAY_CERT_FULL="${XRAY_CERT_DIR}/fullchain.pem"
readonly XRAY_CERT_KEY="${XRAY_CERT_DIR}/privkey.pem"
readonly CDN_FLAG="${CERT_BASE}/cdn-xray"
# VLESS Encryption：xray vlessenc 和现在的字符串格式从 Xray-core 25.9.5 开始。
# native 外观 + 服务端票据 600s（300~600 秒随机）+ 客户端 0rtt，与 xray vlessenc 的默认输出一致。
readonly VLESS_ENC_MIN_XRAY="25.9.5"
readonly VLESS_ENC_HEAD="mlkem768x25519plus"
readonly VLESS_ENC_MODE="native"
readonly VLESS_ENC_TICKET="600s"
readonly VLESS_ENC_RTT="0rtt"
# 令牌和 EAB 只放在这些 600 文件里，不写入 state.env。
readonly CERT_DNS_TOKEN="${CERT_BASE}/cf-dns.token"
readonly CERT_ZEROSSL_EAB="${CERT_BASE}/zerossl.eab"
readonly CERT_ORIGIN_KEY="${CERT_BASE}/cf-origin.key"
readonly CERT_DNS_AUTH="${CERT_LIB}/dns-auth.sh"
readonly CERT_DNS_CLEAN="${CERT_LIB}/dns-cleanup.sh"
readonly CERT_TXT_DIR="/var/lib/proxy-oneclick/acme-txt"
readonly ZEROSSL_SERVER="https://acme.zerossl.com/v2/DV90"
readonly CF_ORIGIN_API="https://api.cloudflare.com/client/v4/certificates"
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
OPT_XHTTP_ON_443="" # 空=默认分开（8443）；1=与 Vision 共用 TCP 端口；0=强制分开
OPT_TROJAN=""       # 空=默认关; 1/0
OPT_TROJAN_PORT=""
OPT_TUIC=""         # 空=默认关; 1/0
OPT_TUIC_PORT=""
OPT_ANYTLS=""       # 空=默认关; 1/0
OPT_ANYTLS_PORT=""
OPT_XHTTP_TLS=""    # 空=默认关。VLESS + XHTTP + TLS，给 CDN，不是 REALITY 那条 XHTTP
OPT_XHTTP_TLS_PORT=""
OPT_WS=""           # 空=默认关。VLESS + WebSocket + TLS，给 CDN
OPT_WS_PORT=""
OPT_VLESS_ENC=""    # 空=沿用（新开 CDN 线路时默认开）; 1/0。只作用于两条 CDN 线路
OPT_VENC_ACT=""     # proxy vless-enc 子命令: on | off | rotate；空=查看
OPT_HOP=""          # "20000-50000" 或 "none"
OPT_FW_MODE=""      # 空=按环境决定；strict 默认拒绝 | allow 只放行 | off 不写规则
OPT_FW_SET=0        # 1 = 命令行显式写了 --firewall（--no-firewall 只记模式，不单独触发安装）
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
OPT_OUTBOUND=""     # 46 IPv4优先 | 64 IPv6优先 | 4 仅IPv4 | 6 仅IPv6 | auto 按检测；空=未指定
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
OPT_IMPORT=""       # --import / proxy import 的文件
OPT_EXPORT_PATH=""  # proxy export 的输出路径，空则用默认
OPT_EXPORT_ENC=0    # 1 = 导出时用 openssl 加密
IMPORT_MODE=0       # 1 = 本次安装来自导入，要重新检测 IP / NAT / SNI / 防火墙
OPT_CERT=""         # 空=沿用已有或在交互安装时询问；1=申请；0=--no-cert 关闭
OPT_CERT_DOMAIN=""  # 申请证书的自有域名（须解析到本机）
OPT_CERT_EMAIL=""   # 可选，交给 Let's Encrypt；空则不登记邮箱
OPT_SUB_PORT=""     # 订阅 HTTPS 端口，默认 8447
OPT_CERT_KIND=""    # 空=Let's Encrypt 单域名。le|wildcard|multi|zerossl|zerossl-wildcard|zerossl-multi|cf-origin
OPT_CERT_NAMES=""   # 多域名或源站证书的名字，逗号分隔
OPT_CERT_LINK=""    # 通配符证书写进链接的具体主机名，默认为根域名
OPT_CF_DNS_TOKEN="" # Cloudflare API 令牌，只用于 DNS-01。不写入 state.env
OPT_CF_ORIGIN_KEY="" # Cloudflare Origin CA Key。出现即表示申请源站证书
OPT_ZEROSSL_KID=""
OPT_ZEROSSL_HMAC=""
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
# 旧调用点留下的别名。颜色只实际使用 C_TITLE / C_OK / C_WARN / C_DIM / C_BOLD。
# shellcheck disable=SC2034
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

# build.sh 把这一行换成「生成文件行号:源文件:源文件行号」，前后行号不变。
# 占位符还在时表示没构建，映射直接跳过。
readonly __MODULE_MAP="__BUILD_MODULE_MAP__"
err_from_map() { # $1 合并后的行号；成功时打印 src/file.sh:行
  local line=$1 ent p f s best_p=0 best_f="" best_s=0
  [[ $line =~ ^[0-9]+$ ]] || return 1
  [[ -n ${__MODULE_MAP:-} && $__MODULE_MAP != *__BUILD_MODULE_MAP__* ]] || return 1
  local IFS=';'
  local -a ents=()
  read -r -a ents <<<"$__MODULE_MAP"
  for ent in "${ents[@]}"; do
    p=${ent%%:*}; s=${ent##*:}; f=${ent#*:}; f=${f%:*}
    [[ $p =~ ^[0-9]+$ && $s =~ ^[0-9]+$ && -n $f ]] || continue
    if (( 10#$p <= 10#$line && 10#$p >= best_p )); then best_p=$p; best_f=$f; best_s=$s; fi
  done
  (( best_p > 0 )) || return 1
  printf '%s:%s' "$best_f" $(( 10#$best_s + 10#$line - 10#$best_p ))
}
err_from_file() { # 读 $0 里的 # @module。管道运行时文件不可读，交给调用方退回行号。
  local line=$1 n=0 row mark="" start=0 src
  [[ $line =~ ^[0-9]+$ && -r $0 && -f $0 ]] || return 1
  while IFS= read -r row || [[ -n $row ]]; do
    n=$(( n + 1 ))
    if [[ $row == '# @module '* ]]; then
      if (( n == 10#$line )); then printf '%s:1' "${row#\# @module }"; return 0; fi
      if (( n < 10#$line )); then mark=${row#\# @module }; start=$n; fi
    fi
    (( n >= 10#$line )) && break
  done <"$0"
  [[ -n $mark && start -gt 0 ]] || return 1
  if [[ $mark == src/core.sh ]]; then src=$(( 10#$line - start + 1 ))
  else src=$(( 10#$line - start )); fi
  (( src > 0 )) || return 1
  printf '%s:%s' "$mark" "$src"
}
err_loc() { # $1 合并后的行号
  local loc=""
  loc=$(err_from_map "$1" 2>/dev/null) || loc=""
  [[ -n $loc ]] || loc=$(err_from_file "$1" 2>/dev/null) || loc=""
  if [[ -n $loc ]]; then printf '%s' "$loc"; else printf '第 %s 行' "$1"; fi
}
err_print_stack() {
  local i fn bl loc n=0
  (( ${#FUNCNAME[@]} > 1 )) || return 0
  printf '%s调用栈：%s\n' "$C_YELLOW" "$C_NONE" >&2
  for (( i=1; i<${#FUNCNAME[@]}; i++ )); do
    fn=${FUNCNAME[$i]}
    [[ $fn == on_error || $fn == err_print_stack || $fn == main || $fn == err_loc ]] && continue
    bl=${BASH_LINENO[$(( i - 1 ))]:-0}
    [[ $bl =~ ^[0-9]+$ ]] || bl=0
    loc=$(err_loc "$bl")
    n=$(( n + 1 ))
    printf '  [%s] %s() <- %s\n' "$n" "$fn" "$loc" >&2
  done
  return 0
}
on_error() {
  local rc=$? line=$1 cmd=$2 where
  trap - ERR
  if [[ -n ${GITHUB_TOKEN:-} ]]; then cmd=${cmd//${GITHUB_TOKEN}/***}; fi
  if [[ -n ${PROXY_EXPORT_PASS:-} ]]; then cmd=${cmd//${PROXY_EXPORT_PASS}/***}; fi
  cmd=${cmd//Authorization: Bearer */Authorization: Bearer ***}
  where=$(err_loc "$line")
  printf '\n%s[错误]%s 脚本在 %s 执行失败 (退出码 %s)：\n    %s\n' "$C_RED" "$C_NONE" "$where" "$rc" "$cmd" >&2
  err_print_stack
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
  local s=$1 enc="" c i
  local LC_ALL=C
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    case $c in
      [a-zA-Z0-9.~_-]) enc+=$c ;;
      *) printf -v c '%%%02X' "'$c"; enc+=$c ;;
    esac
  done
  printf '%s' "$enc"
}
rand_hex() { openssl rand -hex "$1"; }
rand_pass() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-24; }
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | awk 'NR==1')" == "$2" ]]; }
fetch() { curl -fsSL "${FETCH_IP[@]}" --connect-timeout 10 --retry 2 --retry-delay 2 "$@"; }
# 访问 api.github.com。设置了 GITHUB_TOKEN 时带上，令牌不出现在命令行里，也不写进日志。
gh_curl() {
  if [[ -z ${GITHUB_TOKEN:-} ]]; then curl "$@"; return; fi
  local rc=0 cfg
  cfg=$(mktemp)
  chmod 600 "$cfg"
  awk 'BEGIN{t=ENVIRON["GITHUB_TOKEN"]; printf "header = \"Authorization: Bearer %s\"\n", t}' >"$cfg"
  curl --config "$cfg" "$@" || rc=$?
  rm -f "$cfg"
  return "$rc"
}
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
svc_log_file() { case $1 in xray) printf '%s' "$XRAY_LOG" ;; hysteria-server) printf '%s' "$HY_LOG" ;; sing-box) printf '%s' "$SB_LOG" ;; proxy-oneclick-sub) printf '%s' "$SUB_LOG" ;; esac; }
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
            HY2_ENABLED HY2_PORT HY2_PASS HY2_PIN HOP_RANGE NODE_NAME FW_ENABLED FW_MODE FW_HOST_SYNC SSH_PORTS
            EXTRA_TCP EXTRA_UDP DISABLED_FW SWAP_CREATED SERVER_ADDR
            NAT_MODE NAT_PORTS NAT_EXCLUDE XRAY_EXT_PORT HY2_EXT_PORT HOP_EXT_RANGE
            HOP_BACKEND VIRT DNS64_SET
            LAND_MODE LAND_METHOD LAND_KEY LAND_ALLOW RELAY_LINK RELAY_ON RELAY_SOCKS FWD_LINK FWD_ON NAT_PREF
            REALITY_ENABLED XHTTP_ENABLED XHTTP_PORT XHTTP_PATH XHTTP_EXT_PORT XHTTP_ON_443
            TROJAN_ENABLED TROJAN_PORT TROJAN_PASS TROJAN_EXT_PORT
            TUIC_ENABLED TUIC_PORT TUIC_PASS TUIC_EXT_PORT
            ANYTLS_ENABLED ANYTLS_PORT ANYTLS_PASS ANYTLS_EXT_PORT
            XHTTP_TLS_ENABLED XHTTP_TLS_PORT XHTTP_TLS_PATH
            WS_ENABLED WS_PORT WS_PATH
            VLESS_ENC VLESS_ENC_SEED VLESS_ENC_CLIENT
            OUTBOUND_IP
            CERT_ON CERT_DOMAIN CERT_EMAIL SUB_PORT SUB_TOKEN
            CERT_CA CERT_SCOPE CERT_NAMES CERT_PUBLIC CERT_CHALLENGE)
INSTALLED=0 XRAY_PORT=443 UUID="" PRIV_KEY="" PUB_KEY="" SHORT_ID="" MLDSA_SEED="" MLDSA_VERIFY="" MLDSA_ON=1 SNI="" SNI_TARGET=""
HY2_ENABLED=1 HY2_PORT=443 HY2_PASS="" HY2_PIN="" HOP_RANGE="20000-50000" NODE_NAME="" FW_ENABLED=1 FW_MODE="" FW_HOST_SYNC=0 SSH_PORTS=""
# 默认一键：Reality + XHTTP + Hy2。XHTTP_ENABLED 初始为 0，避免旧状态文件在「改 SNI」时被意外打开；
# 安装流程里若状态没有这一项，再按默认打开。可选协议初始关闭。
REALITY_ENABLED=1
XHTTP_ENABLED=0 XHTTP_PORT=8443 XHTTP_PATH="" XHTTP_EXT_PORT="" XHTTP_ON_443=0
TROJAN_ENABLED=0 TROJAN_PORT=8444 TROJAN_PASS="" TROJAN_EXT_PORT=""
TUIC_ENABLED=0 TUIC_PORT=8446 TUIC_PASS="" TUIC_EXT_PORT=""
ANYTLS_ENABLED=0 ANYTLS_PORT=8445 ANYTLS_PASS="" ANYTLS_EXT_PORT=""
# CDN 线路默认关闭。2083 / 2087 是 Cloudflare 允许回源的 HTTPS 端口，避开 REALITY 的 443。
XHTTP_TLS_ENABLED=0 XHTTP_TLS_PORT=2083 XHTTP_TLS_PATH=""
WS_ENABLED=0 WS_PORT=2087 WS_PATH=""
# 两条 CDN 线路的 VLESS Encryption（ML-KEM-768 + X25519）。空 = 旧状态文件里没有这一项：
# 已经开着 CDN 的旧安装保持 none，免得旧客户端失效；新开 CDN 线路时默认开。
# SEED 是服务端 ML-KEM-768 种子，CLIENT 是对应的客户端公钥，只在明确轮换时重新生成。
VLESS_ENC="" VLESS_ENC_SEED="" VLESS_ENC_CLIENT=""
STATE_HAS_XHTTP=0
EXTRA_TCP="" EXTRA_UDP="" DISABLED_FW="" SWAP_CREATED=0 SERVER_ADDR=""
NAT_MODE=0 NAT_PORTS="" NAT_EXCLUDE="" XRAY_EXT_PORT="" HY2_EXT_PORT="" HOP_EXT_RANGE=""
HOP_BACKEND="" VIRT="" DNS64_SET=0
LAND_MODE=0 LAND_METHOD="2022-blake3-aes-128-gcm" LAND_KEY="" LAND_ALLOW="" RELAY_LINK="" RELAY_ON=0 RELAY_SOCKS=""
# 落地机出口。FWD_* 只在落地机上使用：FWD_ON=1 为原样转发（DNAT）。节点不读这两项。
# 旧状态文件没有这两项时保持关闭，落地机仍是直连。
FWD_LINK="" FWD_ON=0
NAT_PREF=auto       # 菜单「切换 NAT 模式」：auto = 自动检测；on = 强制 NAT（同 --nat）；off = 强制普通模式（同 --no-nat）
NAT_SRC=""          # 本次安装 NAT_MODE 的来源：cli | manual | alpine | state | auto | detect
# 已记住的出站策略：46 IPv4优先 / 64 IPv6优先 / 4 仅IPv4 / 6 仅IPv6。空 = 还没问过。
# 双栈且为空时保持原来的 AsIs / Hy2 happy eyeballs，直到交互询问或 --auto（默认 46）。
# --outbound auto 清掉已记住的选择，再按本次检测决定。
OUTBOUND_IP=""
CERT_ON=0 CERT_DOMAIN="" CERT_EMAIL="" SUB_PORT=8447 SUB_TOKEN=""
# 旧状态文件没有这几项时保持 Let's Encrypt 单域名 HTTP-01，已经签好的公开证书行为不变。
CERT_CA=letsencrypt CERT_SCOPE=single CERT_NAMES="" CERT_PUBLIC=1 CERT_CHALLENGE=http
OUTBOUND_EFFECTIVE=""   # 本次写配置实际使用的策略（单栈会强制 4 或 6，不覆盖 OUTBOUND_IP）
OUTBOUND_IP_DONE=0      # 本次进程只决定一次
OUTBOUND_IP_CHANGED=0
OB_HAS_V4=0
OB_HAS_V6=0
OB_HAS_ULA=0            # 出站源是 ULA（fc00::/7），还没证明有公网 IPv6
OB_ULA_SRC=""           # 路由选中的 ULA 源地址
OB_NAT66=0              # 1 = ULA 源，但 curl -6 看到公网 IPv6
OB_NAT66_PUB=""

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
  fw_migrate_saved_mode
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

