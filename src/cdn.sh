# ============================================================
#     可选：VLESS + XHTTP + TLS / VLESS + WebSocket + TLS（CDN）
# ============================================================
# 默认关闭，也不替换 REALITY、XHTTP+REALITY、Hysteria2、Trojan、TUIC、AnyTLS。
# 两条都不是 REALITY：客户端连自己的域名，CDN 再回源到本机的独立端口。
# 本机用已申请的公开证书终止 TLS。REALITY 继续占用自己的端口，配置里不写这张证书。
# 默认端口 2083 / 2087，是 Cloudflare 允许代理的 HTTPS 端口，避开 443。

cdn_wanted() { (( ${XHTTP_TLS_ENABLED:-0} == 1 || ${WS_ENABLED:-0} == 1 )); }
cdn_cli_requested() { [[ ${OPT_XHTTP_TLS:-} == 1 || ${OPT_WS:-} == 1 ]]; }
cdn_cf_port() { case $1 in 443|2053|2083|2087|2096|8443) return 0 ;; *) return 1 ;; esac; }

cdn_explain() { # $1 情形。$2 占用者或端口或路径；$3 在 port_busy 时是端口
  local tag=$1 who=${2:-未知} port=${3:-${2:-}} path=${2:-}
  case $tag in
    dns)
      cat >&2 <<'EOF'
域名没有解析到这台机器。
Let's Encrypt 和 CDN 回源都要顺着这个域名找到本机的公网地址。现在查到的地址里有不是本机的，或者根本没查到。
常见原因：A/AAAA 还没填、填成了别的服务器、只改了一边、或者刚改完还没生效。
请到域名服务商把记录改成这台机器的公网 IP，等几分钟后再试。不要填 REALITY 用来伪装的那个网站。
EOF
      ;;
    port80)
      cat >&2 <<EOF
80 端口被占用（${who}），证书申请停住了。
申请或续期 HTTP-01（Let's Encrypt 或 ZeroSSL 的单域名、多域名）时，要暂时独占 80 做验证，验证完就放开。通配符走 DNS-01，不占用 80。80 上不提供订阅，也不跑代理。
常见占用是 Nginx、Caddy、Apache 或另一个网站。先执行 ss -Htlnp 'sport = :80' 看是谁，停掉它再申请。
REALITY 的端口没有改。不要把 REALITY 挪到 80，也不要把 REALITY 放进 CDN。
EOF
      ;;
    port443)
      cat >&2 <<'EOF'
不能占用 REALITY 正在听的端口（默认就是 443）。
REALITY 必须由客户端直连本机，不能套在 Cloudflare 这类 CDN 后面。CDN 会拆掉 TLS，伪装站点对不上，客户端握手会失败。
CDN 线路请改用 Cloudflare 允许回源的其它 HTTPS 端口：2083、2087、2096、2053、8443。8443 如果已经被 XHTTP+REALITY 占用，就不要用。
客户端连接「域名:这个端口」，Cloudflare 再连回本机的同一个端口。443 继续留给 REALITY 直连。
EOF
      ;;
    port_busy)
      cat >&2 <<EOF
端口 ${port} 已经被「${who}」占用，这条 CDN 线路不能听在这里。
Cloudflare 要连到本机这个端口。端口上是别的程序时，Xray 起不来，CDN 会显示 521（连不上）或 522（超时）。
请换一个空着的端口：2083、2087、2096、2053、8443。可以执行 ss -Htlnp 'sport = :${port}' 看是谁。不要停掉 REALITY 来腾出 443，也不要把 REALITY 放进 CDN。
EOF
      ;;
    port_cf)
      cat >&2 <<EOF
端口 ${port} 不能当作这条 CDN 线路的回源端口。
Cloudflare 免费代理只把 HTTPS 转到这几个端口：443、2053、2083、2087、2096、8443。其它端口橙色云朵不会帮你转发，表现就是连不上，或者 521/522。
请改成上面其中一个空闲端口。不要占用 REALITY 正在听的端口，也不要把 REALITY 放进 CDN。
EOF
      ;;
    port_taken)
      cat >&2 <<EOF
端口和已有的「${who}」撞车了。
这条 CDN 线路要单独听一个 TCP 端口，不能和 REALITY、XHTTP+REALITY、Trojan、AnyTLS、另一条 CDN 线路或订阅共用。
请换一个 Cloudflare 允许的 HTTPS 端口。原来的协议保持不动。
EOF
      ;;
    cert_required)
      cat >&2 <<'EOF'
这条线路需要你自己的域名，以及一张证书。
它走的是普通 TLS，不是 REALITY。默认用公开证书（Let's Encrypt 单域名）。只给这两条 CDN 线路、并且域名开着橙色云朵时，也可以改用 Cloudflare 源站证书。源站证书只有 Cloudflare 信任，不能给 Hysteria2、TUIC、AnyTLS 或订阅。
自签证书会被当成证书不匹配。请先申请证书（--cert-domain，或菜单「申请证书」）。REALITY、XHTTP+REALITY、Hysteria2 不会被关掉，REALITY 也不会改用这张证书。
EOF
      ;;
    cert_fail)
      cat >&2 <<'EOF'
证书没有签发成功，CDN 线路还不能开。
常见原因：域名没有解析到本机；80 端口被别的网站占用；云安全组没放行 80，Let's Encrypt 从公网访问不到；同一域名签发太频繁，触发了速率限制。
请按日志里的具体原因处理。REALITY 的端口没有改，也没有改用这张证书。
EOF
      ;;
    cert_rate)
      cat >&2 <<'EOF'
Let's Encrypt 拒绝签发：这个域名最近申请次数太多（速率限制）。
同一张域名一周内能成功签发的次数有限。等限制过去，或换一个还没申请过的子域名再试。
这不是 REALITY 坏了。REALITY 不使用这张证书。
EOF
      ;;
    cert_unreachable)
      cat >&2 <<'EOF'
Let's Encrypt 没能从公网访问到本机的 80 端口，验证失败。
域名要解析到这台机器，云安全组要放行 TCP 80，本机 80 上不能有别的程序抢着回答。验证只在申请那一会儿占用 80。
请放行 80 后重试。不要改 REALITY 的监听端口。
EOF
      ;;
    nat)
      cat >&2 <<'EOF'
NAT 模式不能开这两条 CDN 线路。
Cloudflare 要能直接连到本机的回源端口，证书的 HTTP-01 也要能从公网访问 80。NAT 小鸡通常没有这些映射。
不带 --xhttp-tls / --ws-tls 时，安装方式和原来一样。REALITY 仍然直连，不要把 REALITY 放进 CDN。
EOF
      ;;
    land)
      cat >&2 <<'EOF'
落地机只跑 Shadowsocks 2022，没有给客户端直连的 CDN 入站。
请在中转机（装了 REALITY 的那台）上打开这两条线路。落地机不用改。
EOF
      ;;
    521)
      cat >&2 <<'EOF'
Cloudflare 返回 521：它连不上源站。
橙色云朵已经生效，但 Cloudflare 访问本机这个端口失败。常见原因：
1. 源站上的 Xray 没在听这个端口。
2. 本机防火墙或云安全组没放行这个 TCP 端口。
3. DNS 指到了错误的 IP。
4. 回源端口不是 Cloudflare 支持的 443、2053、2083、2087、2096、8443。
请在本机用 ss 确认端口正在监听，并在云控制台放行。不要把 REALITY 的 443 指到 Cloudflare 后面来凑这个端口。
EOF
      ;;
    522)
      cat >&2 <<'EOF'
Cloudflare 返回 522：连接源站超时。
请求到了 Cloudflare，但它一直等不到本机应答。常见是云安全组把这个端口丢了，或本机防火墙默认拒绝且没放行。
到云控制台放行对应的 TCP 端口。证书续期还需要 TCP 80。源站用 ss 看这个端口是否在听。
EOF
      ;;
    526)
      cat >&2 <<'EOF'
回源证书和域名对不上。Cloudflare 上这通常显示为 526，或提示 origin certificate 无效。
加密模式请用「完全（严格）」。源站必须出示这张证书，名字就是这个域名。公开证书和 Cloudflare 源站证书都可以过「完全（严格）」。源站证书不能拿去给浏览器、Hysteria2、TUIC、AnyTLS 或订阅。
自签证书、证书写成别的域名、或把 REALITY 的伪装站证书拿来回源，都会失败。
不要改成「灵活」。灵活会让 Cloudflare 用明文连源站，这条 TLS 线路对不上。
EOF
      ;;
    path)
      cat >&2 <<EOF
路径不一致。
客户端、Cloudflare 和源站三处的路径必须逐字相同，当前源站路径是 ${path}。
多一个或少一个斜杠、用了另一条 XHTTP+REALITY 的路径、或在 Cloudflare 规则里改写了路径，都会 404，节点连不上。
请把链接里的 path 原样填进客户端，不要手改。缓存规则里把这个路径设为绕过缓存。
EOF
      ;;
    ws)
      cat >&2 <<'EOF'
WebSocket 升级被拒绝。
连接没有变成 WebSocket。常见原因：
1. Cloudflare「网络 → WebSockets」没打开。
2. 路径不对，升级请求打到了别的地址。
3. 中间的反代丢掉了 Connection 和 Upgrade 头。
4. 客户端误用了 REALITY 或 XHTTP 的链接，类型不是 ws。
请打开 WebSockets，确认链接里是 type=ws、security=tls，path 和这里一致。不要填 pbk、sid、flow，也不要开 insecure。
EOF
      ;;
    origin_down)
      cat >&2 <<EOF
本机端口 ${port} 没有在听。
CDN 回源连过来时，Cloudflare 会显示 521（连不上）或 522（超时）。
请确认 Xray 已启动，并且防火墙和云安全组放行了这个 TCP 端口。不要改用 REALITY 的端口来顶替。
EOF
      ;;
    xray_config)
      cat >&2 <<'EOF'
Xray 没有接受这份配置，新配置没有写进去。
若日志提到证书或 private key：CDN 这两条入站要读已签发的证书，运行 Xray 的 nobody 必须能读私钥。REALITY 那几条入站不使用这张证书。
请先确认证书已申请成功，再重试。原来的 REALITY 配置不会被换成这张证书。
EOF
      ;;
  esac
}

cert_fail_explain() { # $1 日志
  local log=$1 low
  low=$(tr '[:upper:]' '[:lower:]' <"$log" 2>/dev/null || true)
  if [[ $low == *'acme-txt-timeout'* ]]; then cert_explain txt_timeout; return 0; fi
  if [[ $low == *'acme-dns-auth-failed'* || $low == *'invalid api token'* || $low == *'authentication error'* ]]; then
    cert_explain dns_token; return 0
  fi
  if [[ $low == *'acme-dns-zone-missing'* ]]; then cert_explain dns_zone; return 0; fi
  if [[ $low == *'cf-origin-auth'* ]]; then cert_explain origin_auth; return 0; fi
  if [[ $low == *'cf-origin-host'* ]]; then cert_explain origin_host; return 0; fi
  if [[ $low == *'address already in use'* || $low == *'eaddrinuse'* ]]; then
    cdn_explain port80 "$(port_owner tcp 80)"; return 0
  fi
  if [[ $low == *'too many certificates'* || $low == *'rate limit'* || $low == *'ratelimited'* ]]; then
    if [[ ${CERT_CA:-letsencrypt} == zerossl ]]; then cert_explain rate_zero; else cdn_explain cert_rate; fi
    return 0
  fi
  if [[ ${CERT_CA:-} == zerossl && ( $low == *'external account'* || $low == *'eab credential'* || $low == *'invalid eab'* ) ]]; then
    cert_explain eab; return 0
  fi
  if [[ ${CERT_CHALLENGE:-} == dns ]]; then cert_explain txt_missing; return 0; fi
  if [[ ${CERT_SCOPE:-} == multi ]]; then cert_explain multi_fail; return 0; fi
  if [[ $low == *'nxdomain'* || $low == *'dns problem'* || $low == *'no valid a'* || $low == *'servfail'* ]]; then
    cert_explain dns_not_here; return 0
  fi
  if [[ $low == *'timeout'* || $low == *'timed out'* || $low == *'connection refused'* || $low == *'firewall'* || $low == *'unauthorized'* ]]; then
    cdn_explain cert_unreachable; return 0
  fi
  cdn_explain cert_fail
}

cdn_ensure_paths() {
  if (( ${XHTTP_TLS_ENABLED:-0} == 1 )); then
    [[ $XHTTP_TLS_PATH =~ ^/xhttp-[A-Za-z0-9]+$ ]] || XHTTP_TLS_PATH="/xhttp-$(rand_hex 8)"
  fi
  if (( ${WS_ENABLED:-0} == 1 )); then
    [[ $WS_PATH =~ ^/ws-[A-Za-z0-9]+$ ]] || WS_PATH="/ws-$(rand_hex 8)"
  fi
}
cdn_port_ok() { # $1 端口 $2 正在设置的变量名（跳过自己）。不合适时已经打印原因
  local p=$1 self=${2:-}
  if [[ $p == 80 ]]; then cdn_explain port80 "$(port_owner tcp 80)"; return 1; fi
  if (( ${REALITY_ENABLED:-0} == 1 )) && [[ $p == "$XRAY_PORT" ]]; then cdn_explain port443; return 1; fi
  if (( ${XHTTP_ENABLED:-0} == 1 )) && [[ $p == "$XHTTP_PORT" ]]; then cdn_explain port_taken "XHTTP + REALITY" "$p"; return 1; fi
  if (( ${TROJAN_ENABLED:-0} == 1 )) && [[ $p == "$TROJAN_PORT" ]]; then cdn_explain port_taken "Trojan" "$p"; return 1; fi
  if (( ${ANYTLS_ENABLED:-0} == 1 )) && [[ $p == "$ANYTLS_PORT" ]]; then cdn_explain port_taken "AnyTLS" "$p"; return 1; fi
  if [[ $self != XHTTP_TLS_PORT ]] && (( ${XHTTP_TLS_ENABLED:-0} == 1 )) && [[ -n $XHTTP_TLS_PORT && $p == "$XHTTP_TLS_PORT" ]]; then
    cdn_explain port_taken "XHTTP + TLS" "$p"; return 1
  fi
  if [[ $self != WS_PORT ]] && (( ${WS_ENABLED:-0} == 1 )) && [[ -n $WS_PORT && $p == "$WS_PORT" ]]; then
    cdn_explain port_taken "WebSocket + TLS" "$p"; return 1
  fi
  if cert_is_public && [[ $p == "$SUB_PORT" ]]; then cdn_explain port_taken "订阅 HTTPS" "$p"; return 1; fi
  if ! cdn_cf_port "$p"; then cdn_explain port_cf "$p"; return 1; fi
  return 0
}
cdn_mark_siblings() { # $1 正在改的变量名，避免把自己标成占用
  local skip=$1
  (( ${REALITY_ENABLED:-0} == 1 )) && [[ $skip != XRAY_PORT ]] && local_mark_used tcp "$XRAY_PORT"
  (( ${XHTTP_ENABLED:-0} == 1 )) && [[ $skip != XHTTP_PORT ]] && local_mark_used tcp "$XHTTP_PORT"
  (( ${TROJAN_ENABLED:-0} == 1 )) && [[ $skip != TROJAN_PORT ]] && local_mark_used tcp "$TROJAN_PORT"
  (( ${ANYTLS_ENABLED:-0} == 1 )) && [[ $skip != ANYTLS_PORT ]] && local_mark_used tcp "$ANYTLS_PORT"
  (( ${XHTTP_TLS_ENABLED:-0} == 1 )) && [[ $skip != XHTTP_TLS_PORT ]] && local_mark_used tcp "$XHTTP_TLS_PORT"
  (( ${WS_ENABLED:-0} == 1 )) && [[ $skip != WS_PORT ]] && local_mark_used tcp "$WS_PORT"
  cert_is_public && [[ -n $SUB_PORT ]] && local_mark_used tcp "$SUB_PORT"
  local_mark_used tcp 80
}
cdn_choose_port() { # $1 变量名 $2 命令行端口 $3 名称 $4 默认端口
  local var=$1 opt=$2 label=$3 def=$4 p cur
  cdn_mark_siblings "$var"
  cur=${!var:-$def}
  LOCAL_USED_TCP=${LOCAL_USED_TCP// $cur /}
  p=${opt:-$cur}
  while :; do
    if [[ -z $opt ]] && (( ! OPT_AUTO )); then
      ask p "${label} 的 TCP 端口（Cloudflare 用 2083、2087、2096、2053 或 8443，不要占 REALITY）" "$p"
      p=${p// /}
    fi
    if ! is_port "$p"; then
      cdn_explain port_cf "${p:-空}"
      { [[ -n $opt ]] || (( OPT_AUTO )); } && return 1
      p=$def
      continue
    fi
    if ! cdn_port_ok "$p" "$var"; then
      { [[ -n $opt ]] || (( OPT_AUTO )); } && return 1
      p=$def
      continue
    fi
    if local_used_hit tcp "$p"; then
      cdn_explain port_taken "其它协议" "$p"
      { [[ -n $opt ]] || (( OPT_AUTO )); } && return 1
      p=$def
      continue
    fi
    if ! check_port_free tcp "$p" 'xray'; then
      if [[ $p == 80 ]]; then cdn_explain port80 "$(port_owner tcp 80)"
      elif (( ${REALITY_ENABLED:-0} == 1 )) && [[ $p == "$XRAY_PORT" || $p == 443 ]]; then cdn_explain port443
      else cdn_explain port_busy "$(port_owner tcp "$p")" "$p"; fi
      { [[ -n $opt ]] || (( OPT_AUTO )); } && return 1
      p=$def
      continue
    fi
    printf -v "$var" '%s' "$p"
    local_mark_used tcp "$p"
    return 0
  done
}

cdn_install_xray_certs() {
  tls_for_cdn || { cdn_explain cert_required; return 1; }
  local grp
  grp=$(id -gn nobody 2>/dev/null || echo nogroup)
  mkdir -p "$XRAY_CERT_DIR"
  chmod 755 "$(dirname "$XRAY_CERT_DIR")" 2>/dev/null || true
  cp -f "$CERT_FULLCHAIN" "${XRAY_CERT_FULL}.new"
  cp -f "$CERT_PRIVKEY" "${XRAY_CERT_KEY}.new"
  chown "root:${grp}" "${XRAY_CERT_FULL}.new" "${XRAY_CERT_KEY}.new"
  chmod 644 "${XRAY_CERT_FULL}.new"
  chmod 640 "${XRAY_CERT_KEY}.new"
  mv -f "${XRAY_CERT_FULL}.new" "$XRAY_CERT_FULL"
  mv -f "${XRAY_CERT_KEY}.new" "$XRAY_CERT_KEY"
  chown "root:${grp}" "$XRAY_CERT_DIR"
  chmod 750 "$XRAY_CERT_DIR"
  selinux_fix "$XRAY_CERT_DIR"
}
cdn_sync_flag() {
  if cdn_wanted && tls_for_cdn; then
    mkdir -p "$(dirname "$CDN_FLAG")"
    printf '1\n' >"$CDN_FLAG"
    chmod 644 "$CDN_FLAG"
  else
    rm -f "$CDN_FLAG"
  fi
}

# ---------- VLESS Encryption：只用于两条 CDN 线路，REALITY / Hysteria2 等不变 ----------
# Cloudflare 在边缘解开 TLS，不加这一层时它能看到明文 VLESS。外面已经有 TLS，
# 所以外观选 native；xorpub / random 只在没有外层 TLS 时才有意义。不加 flow：
# CDN 中间断开了 TLS，Vision 不能 Splice，客户端兼容面也更窄。
vless_enc_default() { # $1=1 表示旧安装里已有 CDN 线路在用 none
  [[ -z ${VLESS_ENC:-} ]] || return 0
  if [[ ${1:-0} == 1 ]]; then
    VLESS_ENC=0
    info "已有的 CDN 线路保持 encryption=none，旧客户端不受影响。要打开 VLESS Encryption：proxy vless-enc on"
  else
    VLESS_ENC=1
  fi
}
vless_enc_keys_ok() {
  [[ ${VLESS_ENC_SEED:-} =~ ^[A-Za-z0-9_-]{86}$ && ${VLESS_ENC_CLIENT:-} =~ ^[A-Za-z0-9_-]{1579}$ ]]
}
vless_enc_active() { [[ ${VLESS_ENC:-} == 1 ]] && vless_enc_keys_ok; }
vless_enc_decryption() {
  if vless_enc_active; then printf '%s.%s.%s.%s' "$VLESS_ENC_HEAD" "$VLESS_ENC_MODE" "$VLESS_ENC_TICKET" "$VLESS_ENC_SEED"
  else printf 'none'; fi
}
vless_enc_encryption() {
  if vless_enc_active; then printf '%s.%s.%s.%s' "$VLESS_ENC_HEAD" "$VLESS_ENC_MODE" "$VLESS_ENC_RTT" "$VLESS_ENC_CLIENT"
  else printf 'none'; fi
}
xray_version_num() { # $1 xray 路径，默认 XRAY_BIN。输出 26.3.27 这样的版本号
  local b=${1:-$XRAY_BIN} v
  [[ -x $b ]] || return 1
  v=$("$b" version 2>/dev/null | awk 'NR==1{print $2; exit}') || return 1
  v=${v#v}
  [[ $v =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || return 1
  printf '%s' "$v"
}
xray_supports_vlessenc() {
  local v
  v=$(xray_version_num "${1:-$XRAY_BIN}") || return 1
  ver_ge "$v" "$VLESS_ENC_MIN_XRAY"
}
vless_enc_parse() { # 标准输入为 xray vlessenc 的输出。只取 ML-KEM-768 那一组，打印「种子 客户端公钥」
  local out d e seed client
  out=$(cat)
  d=$(awk '/^[[:space:]]*Authentication:/ {s = ($0 ~ /ML-KEM-768/)} s && /"decryption"/ {print; exit}' <<<"$out" |
      sed -E 's/.*"decryption"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
  e=$(awk '/^[[:space:]]*Authentication:/ {s = ($0 ~ /ML-KEM-768/)} s && /"encryption"/ {print; exit}' <<<"$out" |
      sed -E 's/.*"encryption"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
  [[ $d == "${VLESS_ENC_HEAD}."* && $e == "${VLESS_ENC_HEAD}."* ]] || return 1
  # 中间的外观 / 票据 / padding 由本脚本统一写，这里只要最后一块钥匙
  seed=${d##*.} client=${e##*.}
  [[ $seed =~ ^[A-Za-z0-9_-]{86}$ && $client =~ ^[A-Za-z0-9_-]{1579}$ ]] || return 1
  printf '%s %s\n' "$seed" "$client"
}
vless_enc_gen() { # 成功时写入 VLESS_ENC_SEED / VLESS_ENC_CLIENT
  local b=$XRAY_BIN out pair="" seed="" client="" check
  xray_supports_vlessenc "$b" || return 1
  if out=$("$b" vlessenc 2>/dev/null); then pair=$(vless_enc_parse <<<"$out") || pair=""; fi
  if [[ -z $pair ]] && out=$("$b" mlkem768 2>/dev/null); then
    seed=$(awk -F': *' '$1=="Seed"{print $NF; exit}' <<<"$out")
    client=$(awk -F': *' '$1=="Client"{print $NF; exit}' <<<"$out")
    pair="$seed $client"
  fi
  read -r seed client <<<"$pair"
  [[ $seed =~ ^[A-Za-z0-9_-]{86}$ && $client =~ ^[A-Za-z0-9_-]{1579}$ ]] || return 1
  # 用种子再推一次客户端公钥，对不上就不用这对钥匙
  if check=$("$b" mlkem768 -i "$seed" 2>/dev/null); then
    check=$(awk -F': *' '$1=="Client"{print $NF; exit}' <<<"$check")
    [[ $check == "$client" ]] || return 1
  fi
  VLESS_ENC_SEED=$seed VLESS_ENC_CLIENT=$client
}
vless_enc_persist() { if [[ -f $STATE_FILE ]]; then save_state; fi; return 0; }
vless_enc_ensure() { # 写 Xray 配置前调用。开着却用不了时退回 none 并说明原因
  [[ ${VLESS_ENC:-} == 1 ]] || return 0
  (( ${LAND_MODE:-0} )) && return 0
  cdn_wanted || return 0
  if ! xray_supports_vlessenc; then
    VLESS_ENC=0
    warn "当前 Xray $(xray_version_num || echo 版本未知) 不支持 VLESS Encryption（需要 ${VLESS_ENC_MIN_XRAY} 或更新）。CDN 线路先用 encryption=none。升级 Xray（proxy update）后执行 proxy vless-enc on。"
    vless_enc_persist
    return 0
  fi
  vless_enc_keys_ok && return 0
  if vless_enc_gen; then
    info "已用 xray vlessenc 生成 VLESS Encryption 密钥（ML-KEM-768）。"
  else
    VLESS_ENC=0
    warn "没能用 xray vlessenc 生成 VLESS Encryption 密钥，CDN 线路先用 encryption=none。"
  fi
  vless_enc_persist
}
vless_enc_need_xray() { # Xray 太旧时先升级一次。返回 0 表示可以用
  xray_supports_vlessenc && return 0
  warn "当前 Xray $(xray_version_num || echo 版本未知) 不支持 VLESS Encryption（需要 ${VLESS_ENC_MIN_XRAY} 或更新），先升级 Xray ..."
  ( install_xray ) || true
  xray_supports_vlessenc
}
vless_enc_label() {
  if vless_enc_active; then printf '开'
  elif [[ ${VLESS_ENC:-} == 1 ]]; then printf '开（密钥待生成）'
  else printf '关'; fi
}
vless_enc_client_note() { # $1=1 着色
  node_link_note "$1" "VLESS Encryption 已开启（ML-KEM-768 + X25519，native，0-RTT）。Cloudflare 只看到密文。"
  node_link_note "$1" "需要 Xray-core ${VLESS_ENC_MIN_XRAY}+ 内核的客户端（v2rayN、v2rayNG 新版），或 mihomo v1.19.14+（Clash Verge Rev、FlClash、Mihomo Party）。"
  node_link_note "$1" "sing-box 内核的客户端（NekoBox、Hiddify、Karing、sing-box 官方）可能不支持，连不上时执行 proxy vless-enc off。"
}

cdn_xhttp_inbound_json() {
  jq -n --argjson clients "$1" --argjson port "$XHTTP_TLS_PORT" \
    --arg path "$XHTTP_TLS_PATH" --arg host "$CERT_DOMAIN" --arg dec "$(vless_enc_decryption)" \
    --arg crt "$XRAY_CERT_FULL" --arg key "$XRAY_CERT_KEY" '{
      tag: "vless-xhttp-tls",
      port: $port,
      protocol: "vless",
      settings: {clients: $clients, decryption: $dec},
      streamSettings: {
        network: "xhttp",
        security: "tls",
        tlsSettings: {certificates: [{certificateFile: $crt, keyFile: $key}]},
        xhttpSettings: {path: $path, host: $host, mode: "packet-up"}
      },
      sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
    }'
}
cdn_ws_inbound_json() {
  jq -n --argjson clients "$1" --argjson port "$WS_PORT" \
    --arg path "$WS_PATH" --arg host "$CERT_DOMAIN" --arg dec "$(vless_enc_decryption)" \
    --arg crt "$XRAY_CERT_FULL" --arg key "$XRAY_CERT_KEY" '{
      tag: "vless-ws-tls",
      port: $port,
      protocol: "vless",
      settings: {clients: $clients, decryption: $dec},
      streamSettings: {
        network: "ws",
        security: "tls",
        tlsSettings: {certificates: [{certificateFile: $crt, keyFile: $key}]},
        wsSettings: {path: $path, host: $host}
      },
      sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
    }'
}
cdn_attach_inbounds() { # $1 配置文件 $2 无 flow 的客户端 JSON
  local f=$1 clients=$2 ib
  [[ -n $clients ]] || clients='[]'
  if cdn_wanted && ! tls_for_cdn; then
    info "CDN 线路要等证书就绪后再写入。这一步先保持 REALITY 原样，不会把证书写进 REALITY。"
    return 0
  fi
  vless_enc_ensure
  if (( ${XHTTP_TLS_ENABLED:-0} == 1 )); then
    cdn_install_xray_certs || return 1
    ib=$(cdn_xhttp_inbound_json "$clients") || return 1
    jq --argjson ib "$ib" '.inbounds += [$ib]' "$f" >"${f}.cdn" && mv -f "${f}.cdn" "$f"
  fi
  if (( ${WS_ENABLED:-0} == 1 )); then
    cdn_install_xray_certs || return 1
    ib=$(cdn_ws_inbound_json "$clients") || return 1
    jq --argjson ib "$ib" '.inbounds += [$ib]' "$f" >"${f}.cdn" && mv -f "${f}.cdn" "$f"
  fi
}

cdn_xhttp_link() { # $1 uuid $2 名称
  local addr q
  addr=$(host_fmt "$CERT_DOMAIN")
  q="encryption=$(urlencode "$(vless_enc_encryption)")&security=tls&sni=${CERT_DOMAIN}&fp=chrome&type=xhttp&path=$(urlencode "$XHTTP_TLS_PATH")&host=${CERT_DOMAIN}&mode=packet-up"
  printf 'vless://%s@%s:%s?%s#%s' "$1" "$addr" "$XHTTP_TLS_PORT" "$q" "$(urlencode "$2")"
}
cdn_ws_link() { # $1 uuid $2 名称
  local addr q
  addr=$(host_fmt "$CERT_DOMAIN")
  q="encryption=$(urlencode "$(vless_enc_encryption)")&security=tls&sni=${CERT_DOMAIN}&fp=chrome&type=ws&path=$(urlencode "$WS_PATH")&host=${CERT_DOMAIN}"
  printf 'vless://%s@%s:%s?%s#%s' "$1" "$addr" "$WS_PORT" "$q" "$(urlencode "$2")"
}
cdn_render_links() {
  local u r
  if (( XHTTP_TLS_ENABLED )) && tls_for_cdn; then
    printf '%s\n' "$(cdn_xhttp_link "$UUID" "${NODE_NAME}-XHTTP-TLS")"
    if [[ -s $USERS_FILE ]]; then
      while IFS=$'\t' read -r u r; do
        [[ -n $u ]] || continue
        printf '%s\n' "$(cdn_xhttp_link "$u" "${NODE_NAME}-XHTTP-TLS-${r}")"
      done <"$USERS_FILE"
    fi
  fi
  if (( WS_ENABLED )) && tls_for_cdn; then
    printf '%s\n' "$(cdn_ws_link "$UUID" "${NODE_NAME}-WS-TLS")"
    if [[ -s $USERS_FILE ]]; then
      while IFS=$'\t' read -r u r; do
        [[ -n $u ]] || continue
        printf '%s\n' "$(cdn_ws_link "$u" "${NODE_NAME}-WS-TLS-${r}")"
      done <"$USERS_FILE"
    fi
  fi
}
cdn_mihomo_enc() { # VLESS Encryption 开着时写进 mihomo 节点；旧版 mihomo 不认这一项，会连不上
  vless_enc_active || return 0
  printf '    # VLESS Encryption：需要 mihomo v1.19.14+；sing-box 内核不支持，关掉用 proxy vless-enc off\n'
  printf '    encryption: "%s"\n' "$(vless_enc_encryption)"
}
cdn_mihomo() {
  tls_for_cdn || return 0
  if (( XHTTP_TLS_ENABLED )); then
    cat <<Y
  - name: "${NODE_NAME}-XHTTP-TLS"
    type: vless
    server: ${CERT_DOMAIN}
    port: ${XHTTP_TLS_PORT}
    uuid: ${UUID}
    network: xhttp
    tls: true
    udp: true
    servername: ${CERT_DOMAIN}
    client-fingerprint: chrome
    xhttp-opts:
      path: ${XHTTP_TLS_PATH}
      mode: packet-up
      host: ${CERT_DOMAIN}
Y
    cdn_mihomo_enc
  fi
  if (( WS_ENABLED )); then
    cat <<Y
  - name: "${NODE_NAME}-WS-TLS"
    type: vless
    server: ${CERT_DOMAIN}
    port: ${WS_PORT}
    uuid: ${UUID}
    network: ws
    tls: true
    udp: true
    servername: ${CERT_DOMAIN}
    client-fingerprint: chrome
    ws-opts:
      path: ${WS_PATH}
      headers:
        Host: ${CERT_DOMAIN}
Y
    cdn_mihomo_enc
  fi
}
cdn_print_qr() { # 带 VLESS Encryption 的链接约 1.8 KB，终端二维码会比一屏还宽
  echo
  if vless_enc_active; then
    printf '%s链接里带 VLESS Encryption 公钥，二维码太大，没有显示。请复制上面的链接，或用订阅导入。%s\n' "$C_DIM" "$C_NONE"
  else
    print_qr "$1"
  fi
}
cdn_print_links() { # $1=1 着色
  local paint=${1:-0} u r qr
  if (( XHTTP_TLS_ENABLED )) && tls_for_cdn; then
    node_link_head "$paint" "VLESS + XHTTP + TLS（CDN）" "${NODE_NAME}-XHTTP-TLS" "$CERT_DOMAIN" "${XHTTP_TLS_PORT}  TCP"
    node_link_note "$paint" "不是 REALITY。path ${XHTTP_TLS_PATH}，mode=packet-up。不要套到 REALITY 上。"
    vless_enc_active && vless_enc_client_note "$paint"
    qr=$(cdn_xhttp_link "$UUID" "${NODE_NAME}-XHTTP-TLS")
    node_link_uri "$qr"
    (( paint )) && cdn_print_qr "$qr"
    node_link_end "$paint"
    if [[ -s $USERS_FILE ]]; then
      while IFS=$'\t' read -r u r; do
        [[ -n $u ]] || continue
        node_link_head "$paint" "额外用户 ${r} · XHTTP+TLS" "${NODE_NAME}-XHTTP-TLS-${r}" "$CERT_DOMAIN" "${XHTTP_TLS_PORT}  TCP"
        qr=$(cdn_xhttp_link "$u" "${NODE_NAME}-XHTTP-TLS-${r}")
        node_link_uri "$qr"
        (( paint )) && cdn_print_qr "$qr"
        node_link_end "$paint"
      done <"$USERS_FILE"
    fi
  fi
  if (( WS_ENABLED )) && tls_for_cdn; then
    node_link_head "$paint" "VLESS + WebSocket + TLS（CDN）" "${NODE_NAME}-WS-TLS" "$CERT_DOMAIN" "${WS_PORT}  TCP"
    node_link_note "$paint" "不是 REALITY。path ${WS_PATH}。Cloudflare 要打开 WebSockets。"
    vless_enc_active && vless_enc_client_note "$paint"
    qr=$(cdn_ws_link "$UUID" "${NODE_NAME}-WS-TLS")
    node_link_uri "$qr"
    (( paint )) && cdn_print_qr "$qr"
    node_link_end "$paint"
    if [[ -s $USERS_FILE ]]; then
      while IFS=$'\t' read -r u r; do
        [[ -n $u ]] || continue
        node_link_head "$paint" "额外用户 ${r} · WebSocket+TLS" "${NODE_NAME}-WS-TLS-${r}" "$CERT_DOMAIN" "${WS_PORT}  TCP"
        qr=$(cdn_ws_link "$u" "${NODE_NAME}-WS-TLS-${r}")
        node_link_uri "$qr"
        (( paint )) && cdn_print_qr "$qr"
        node_link_end "$paint"
      done <"$USERS_FILE"
    fi
  fi
}

cdn_tutorial_enc() {
  if vless_enc_active; then printf 'encryption=%s.%s.%s.…（整串，见下面的链接）' "$VLESS_ENC_HEAD" "$VLESS_ENC_MODE" "$VLESS_ENC_RTT"
  else printf 'encryption=none'; fi
}
cdn_print_tutorial() { # 可选 $1 = xhttp|ws，空则打印已开启的
  local which=${1:-} show_x=0 show_w=0
  case $which in
    xhttp) show_x=1 ;;
    ws) show_w=1 ;;
    *)
      (( XHTTP_TLS_ENABLED )) && show_x=1
      (( WS_ENABLED )) && show_w=1
      ;;
  esac
  (( show_x || show_w )) || return 0
  local cert_line
  if [[ ${CERT_CA:-letsencrypt} == cloudflare ]]; then
    cert_line="证书：Cloudflare 源站证书。只有 Cloudflare 信任它。浏览器、Hysteria2、TUIC、AnyTLS 和订阅都会拒绝。回源加密用「完全（严格）」，不要用「灵活」。"
  else
    cert_line="证书：已经签好的公开证书。回源加密用「完全（严格）」，不要用「灵活」，也不要改成自签。"
  fi
  echo
  ui_bar '═' 62
  ui_center "CDN 线路怎么接" 62
  ui_bar '─' 62
  cat <<EOF
这两条是普通 TLS，不是 REALITY。客户端先连 Cloudflare，Cloudflare 再连回本机。
不要把 REALITY、XHTTP+REALITY、Trojan 放进 CDN。它们要直连本机 IP，SNI 仍是伪装网站 ${SNI:-（安装时选的站点）}。
不要把 REALITY 的链接改成这个域名，也不要给 REALITY 开橙色云朵。

域名：${CERT_DOMAIN}
${cert_line}

DNS（Cloudflare 或同类的 HTTPS 反向代理）：
1. 添加 A 记录。域名是 example.com 时名称填 @；域名是 cdn.example.com 时名称填 cdn。不要把整段 ${CERT_DOMAIN} 再接到自己后面。内容填本机公网 IPv4。代理状态打开（橙色云朵）。
2. 有公网 IPv6 再加 AAAA，同样打开代理。
3. 这个名字一旦开了橙色云朵，Hysteria2、TUIC、AnyTLS 和订阅不能再靠它连接：Cloudflare 不转发 UDP，也不转发 ${SUB_PORT}。那几条请继续用服务器 IP，或另做一个灰色云朵的名字。脚本不会关掉它们。
4. SSL/TLS 加密模式选「完全（严格）」（Full strict）。不要选「灵活」：灵活会让 Cloudflare 用明文连源站，这条 TLS 线路对不上。
5. 源站端口填下面写的 TCP 端口。Cloudflare 连本机的同一个端口，云安全组要放行。不要把源站改成 443 来占用 REALITY。
6. 缓存：给下面的路径加一条绕过缓存。不要用规则改写路径。
EOF
  if vless_enc_active; then
    cat <<EOF
7. VLESS Encryption 已开启：链接里的 encryption= 是一长串 ${VLESS_ENC_HEAD}.${VLESS_ENC_MODE}.${VLESS_ENC_RTT}.…，要整串原样导入，不能改成 none。
   Cloudflare 解开 TLS 后只能看到这层密文。sing-box 内核的客户端可能不支持，需要时执行 proxy vless-enc off。
EOF
  else
    cat <<'EOF'
7. VLESS Encryption 没有开：Cloudflare 解开 TLS 后能看到明文 VLESS。要打开：proxy vless-enc on
EOF
  fi
  if (( show_x )); then
    cat <<EOF

—— VLESS + XHTTP + TLS ——
源站端口：TCP ${XHTTP_TLS_PORT}（Cloudflare 会连这个端口，请在云安全组放行）
路径：${XHTTP_TLS_PATH}
不需要打开 gRPC。mode 用 packet-up，不要用 stream-one（那是直连 REALITY 的 XHTTP）。
客户端链接里要有：地址 ${CERT_DOMAIN}，端口 ${XHTTP_TLS_PORT}，security=tls，sni=${CERT_DOMAIN}，type=xhttp，path=${XHTTP_TLS_PATH}，host=${CERT_DOMAIN}，mode=packet-up，$(cdn_tutorial_enc)。
链接里不要有：flow、security=reality、pbk、sid、pqv、insecure。不要把地址改成 IP。
$(cdn_xhttp_link "$UUID" "${NODE_NAME}-XHTTP-TLS")
EOF
  fi
  if (( show_w )); then
    cat <<EOF

—— VLESS + WebSocket + TLS ——
源站端口：TCP ${WS_PORT}（云安全组放行这个 TCP）
路径：${WS_PATH}
Cloudflare「网络」里打开 WebSockets。
客户端链接里要有：地址 ${CERT_DOMAIN}，端口 ${WS_PORT}，security=tls，sni=${CERT_DOMAIN}，type=ws，path=${WS_PATH}，host=${CERT_DOMAIN}，$(cdn_tutorial_enc)。
链接里不要有：flow、security=reality、pbk、sid、pqv、insecure。不要把地址改成 IP。
$(cdn_ws_link "$UUID" "${NODE_NAME}-WS-TLS")
EOF
  fi
  cat <<'EOF'

做完可以再运行 proxy cdn，会按本机和公网各查一次。
对不上号时常见的是：域名没指到这里、80/443 被占、证书没签下来、Cloudflare 521/522、回源证书不匹配、路径不一致、WebSocket 升级被拒绝。脚本会用中文说明该先改哪里。
EOF
  ui_bar '═' 62
}

cdn_judge_response() { # $1 HTTP 码 $2 头 $3 正文。输出 521|522|526|ok|ws|path|down|other
  local code=$1 headers=$2 body=$3 blob low
  blob="${headers}"$'\n'"${body}"
  low=$(printf '%s' "$blob" | tr '[:upper:]' '[:lower:]')
  if [[ $code == 521 || $low == *'error code: 521'* || $low == *'error 521'* ]]; then printf '521'; return 0; fi
  if [[ $code == 522 || $low == *'error code: 522'* || $low == *'error 522'* ]]; then printf '522'; return 0; fi
  if [[ $code == 526 || $low == *'error code: 526'* || $low == *'invalid ssl certificate'* || $low == *'origin certificate'* ]]; then printf '526'; return 0; fi
  if [[ $code == 101 || $low == *'101 switching'* ]]; then printf 'ok'; return 0; fi
  if [[ $low == *cloudflare* && ( $code == 400 || $code == 403 || $code == 426 ) ]]; then printf 'ws'; return 0; fi
  if [[ $code == 404 ]]; then printf 'path'; return 0; fi
  if [[ $code == 000 || $code == 0 || -z $code ]]; then
    if [[ $low == *'timed out'* || $low == *'timeout'* ]]; then printf '522'; return 0; fi
    if [[ $low == *'certificate'* || $low == *'ssl'* ]]; then printf '526'; return 0; fi
    if [[ $low == *'connection refused'* || $low == *'failed to connect'* || $low == *'could not connect'* || $low == *"couldn't connect"* ]]; then printf '521'; return 0; fi
    printf 'down'; return 0
  fi
  printf 'other'
}
cdn_curl_exchange() { # $1 port $2 path $3 ws|get $4 local|public。结果放 CDN_CODE/HDR/BODY
  local port=$1 path=$2 mode=$3 where=$4 hdr body err code
  hdr=$(mktemp)
  body=$(mktemp)
  err=$(mktemp)
  local -a args=(-sS --http1.1 --max-time 12 -D "$hdr" -o "$body" -w '%{http_code}' -H "Host: ${CERT_DOMAIN}")
  if [[ $where == local ]]; then
    args+=(-k --resolve "${CERT_DOMAIN}:${port}:127.0.0.1")
  fi
  if [[ $mode == ws ]]; then
    args+=(-H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==')
  fi
  code=$(curl "${args[@]}" "https://${CERT_DOMAIN}:${port}${path}" 2>"$err" || true)
  CDN_CODE=${code:-000}
  CDN_HDR=$(cat "$hdr" 2>/dev/null || true)
  CDN_BODY=$(cat "$body" "$err" 2>/dev/null || true)
  rm -f "$hdr" "$body" "$err"
  # curl 有时把 101 记成 000，状态行里仍有 Switching Protocols
  if [[ $CDN_CODE == 000 || $CDN_CODE == 0 ]]; then
    if [[ $CDN_HDR == *' 101 '* || $CDN_HDR == *'101 Switching'* ]]; then CDN_CODE=101; fi
  fi
}
cdn_origin_cert_ok() { # $1 端口
  local port=$1 pem rc=1
  pem=$(mktemp)
  echo | openssl s_client -connect "127.0.0.1:${port}" -servername "$CERT_DOMAIN" 2>/dev/null | openssl x509 -out "$pem" >/dev/null 2>&1 || true
  if [[ -s $pem ]] && cert_san_ok "$pem"; then rc=0; fi
  rm -f "$pem"
  return "$rc"
}
cdn_probe_public() { # $1 端口 $2 路径 $3 ws|get
  local port=$1 path=$2 mode=$3 tag low
  have curl || { info "本机没有 curl，跳过公网复查。"; return 0; }
  cdn_curl_exchange "$port" "$path" "$mode" public
  tag=$(cdn_judge_response "$CDN_CODE" "$CDN_HDR" "$CDN_BODY")
  low=$(printf '%s\n%s' "$CDN_HDR" "$CDN_BODY" | tr '[:upper:]' '[:lower:]')
  if [[ $low != *cf-ray* && $low != *cloudflare* ]]; then
    case $tag in
      521|522|526) cdn_explain "$tag" ;;
      *)
        info "从这里访问 ${CERT_DOMAIN}:${port} 还没有看到 Cloudflare（没有 cf-ray）。"
        info "橙色云朵还没开，或 DNS 还没生效时，这是正常的。源站检查做完就可以按教程去开代理，然后再运行 proxy cdn。"
        info "不要为了走 CDN 把 REALITY 的端口也指到橙色云朵后面。"
        ;;
    esac
    return 0
  fi
  case $tag in
    521|522|526) cdn_explain "$tag" ;;
    path) cdn_explain path "$path" ;;
    ws) cdn_explain ws ;;
    ok) ok "经 Cloudflare 访问 ${CERT_DOMAIN}:${port}${path} 已有响应。" ;;
    down) cdn_explain 522 ;;
    *)
      if [[ $mode == ws && $CDN_CODE != 101 ]]; then cdn_explain ws
      else info "Cloudflare 已在代理 ${CERT_DOMAIN}（有 cf-ray），HTTP 状态 ${CDN_CODE}。若客户端不通，对照路径和「完全（严格）」。"; fi
      ;;
  esac
  return 0
}
cdn_check_xhttp() {
  local wrong="/not-the-xhttp-path" right bad
  tls_for_cdn || { cdn_explain cert_required; return 1; }
  if ! port_in_use tcp "$XHTTP_TLS_PORT"; then cdn_explain origin_down "$XHTTP_TLS_PORT"; return 1; fi
  if ! cdn_origin_cert_ok "$XHTTP_TLS_PORT"; then cdn_explain 526; return 1; fi
  have curl || { warn "没有 curl，跳过路径探测。"; cdn_probe_public "$XHTTP_TLS_PORT" "$XHTTP_TLS_PATH" get; return 0; }
  cdn_curl_exchange "$XHTTP_TLS_PORT" "$XHTTP_TLS_PATH" get local
  right=$CDN_CODE
  cdn_curl_exchange "$XHTTP_TLS_PORT" "$wrong" get local
  bad=$CDN_CODE
  if [[ $right == 404 && $bad != 404 ]]; then
    cdn_explain path "$XHTTP_TLS_PATH"
    return 1
  fi
  if [[ $right == 404 && $bad == 404 ]]; then
    info "本机访问正确路径和错误路径目前都是 404。XHTTP 的 packet-up 不靠普通网页确认路径。"
    info "客户端若也是 404，就是路径不一致，必须使用 ${XHTTP_TLS_PATH}，不要用 REALITY 那条 XHTTP 的路径。"
  elif [[ $right != "$bad" && $bad == 404 ]]; then
    ok "XHTTP 源站能区分路径 ${XHTTP_TLS_PATH}。"
  else
    info "普通网页请求分不出这条 XHTTP 路径（packet-up 本来就不是网页）。客户端必须原样使用 ${XHTTP_TLS_PATH}。"
    info "路径不一致时客户端是 404。不要改成 REALITY 那条 XHTTP 的路径，也不要改成 stream-one。"
  fi
  cdn_probe_public "$XHTTP_TLS_PORT" "$XHTTP_TLS_PATH" get
  return 0
}
cdn_check_ws() {
  local wrong tag
  wrong="/not-${WS_PATH#/}"
  tls_for_cdn || { cdn_explain cert_required; return 1; }
  if ! port_in_use tcp "$WS_PORT"; then cdn_explain origin_down "$WS_PORT"; return 1; fi
  if ! cdn_origin_cert_ok "$WS_PORT"; then cdn_explain 526; return 1; fi
  have curl || { warn "没有 curl，跳过 WebSocket 探测。"; return 0; }
  cdn_curl_exchange "$WS_PORT" "$WS_PATH" ws local
  tag=$(cdn_judge_response "$CDN_CODE" "$CDN_HDR" "$CDN_BODY")
  if [[ $tag == ok ]]; then
    ok "WebSocket 路径 ${WS_PATH} 在本机可以升级。"
  elif [[ $tag == path || $CDN_CODE == 404 ]]; then
    cdn_explain path "$WS_PATH"
    return 1
  else
    cdn_explain ws
    return 1
  fi
  cdn_curl_exchange "$WS_PORT" "$wrong" ws local
  tag=$(cdn_judge_response "$CDN_CODE" "$CDN_HDR" "$CDN_BODY")
  if [[ $tag == ok ]]; then
    cdn_explain path "$WS_PATH"
    return 1
  fi
  cdn_probe_public "$WS_PORT" "$WS_PATH" ws
  return 0
}
cdn_run_checks() { # 可选 $1 = xhttp|ws
  local which=${1:-} rc=0
  cdn_wanted || return 0
  if [[ $which == xhttp ]] || { [[ -z $which ]] && (( XHTTP_TLS_ENABLED == 1 )); }; then
    cdn_check_xhttp || rc=1
  fi
  if [[ $which == ws ]] || { [[ -z $which ]] && (( WS_ENABLED == 1 )); }; then
    cdn_check_ws || rc=1
  fi
  return "$rc"
}

cdn_ensure_cert() {
  tls_for_cdn && return 0
  cdn_explain cert_required
  if [[ $OPT_CERT == 0 ]]; then
    die "CDN 线路需要证书，不能和 --no-cert 一起使用。公开证书或 Cloudflare 源站证书都可以。REALITY 未改动。"
  fi
  if (( OPT_AUTO )) && [[ -z $OPT_CERT_DOMAIN && -z $OPT_CERT_NAMES && -z $OPT_CERT_KIND && -z $OPT_CF_ORIGIN_KEY ]]; then
    die "请加上 --cert-domain <你的域名>。只给 CDN 用源站证书时再加上 --cert-kind cf-origin --cf-origin-key。REALITY 未改动。"
  fi
  if (( ! OPT_AUTO )) && [[ -z ${OPT_CERT_KIND:-} || ${OPT_CERT_KIND} == le ]]; then
    confirm "现在申请 Let's Encrypt 单域名证书？域名需要已经解析到本机。只想给 CDN 用源站证书时，请改走 proxy cert。" y || return 1
    info "继续申请即表示同意 Let’s Encrypt 服务条款（https://letsencrypt.org/repository/）。"
  fi
  cert_issue_flow
  cert_rewire_protocols
  if (( FW_ENABLED )); then apply_firewall; fi
  cert_start_sub
  save_state
  tls_for_cdn
}
cdn_prepare_enable() { # $1 xhttp|ws。失败返回 1，调用方保持关闭
  local kind=$1
  if (( LAND_MODE )); then cdn_explain land; return 1; fi
  if (( NAT_MODE )); then cdn_explain nat; return 1; fi
  cdn_ensure_cert || return 1
  cdn_ensure_paths
  local_seed_used
  if [[ $kind == xhttp ]]; then
    cdn_choose_port XHTTP_TLS_PORT "$OPT_XHTTP_TLS_PORT" "VLESS + XHTTP + TLS（CDN）" "${XHTTP_TLS_PORT:-2083}" || return 1
    vless_enc_default "$(( ${WS_ENABLED:-0} == 1 ))"
  else
    cdn_choose_port WS_PORT "$OPT_WS_PORT" "VLESS + WebSocket + TLS（CDN）" "${WS_PORT:-2087}" || return 1
    vless_enc_default "$(( ${XHTTP_TLS_ENABLED:-0} == 1 ))"
  fi
  if [[ $VLESS_ENC == 1 ]] && ! vless_enc_keys_ok; then vless_enc_need_xray || true; fi
  cdn_install_xray_certs || return 1
  cdn_sync_flag
  if [[ -f $CERT_HOOK || -d $CERT_LIB ]]; then write_cert_hook; fi
  return 0
}
cdn_after_cert() {
  cdn_wanted || return 0
  if (( NAT_MODE )); then
    cdn_explain nat
    die "NAT 模式下没有写入 CDN 线路。"
  fi
  if ! tls_for_cdn; then
    cdn_explain cert_required
    die "没有可用证书，CDN 线路没有开启。公开证书或 Cloudflare 源站证书都可以。REALITY 未改动。"
  fi
  cdn_ensure_paths
  cdn_install_xray_certs
  cdn_sync_flag
  write_cert_hook
  if xray_inbound_needed; then
    write_xray_config
    restart_xray
  fi
  cdn_print_tutorial
  cdn_run_checks || warn "CDN 线路的检查没有全部通过。REALITY、XHTTP+REALITY、Hysteria2、Trojan、TUIC、AnyTLS 不受影响。按上面的说明改完后执行 proxy cdn。"
}
do_cdn() {
  need_node
  if ! cdn_wanted; then
    info "还没有打开 CDN 线路。在协议开关里打开「VLESS + XHTTP + TLS（CDN）」或「VLESS + WebSocket + TLS（CDN）」，或安装时加 --xhttp-tls / --ws-tls，并带上 --cert-domain。"
    return 0
  fi
  cdn_print_tutorial
  cdn_run_checks || true
}

vless_enc_scope() {
  local s=""
  (( ${XHTTP_TLS_ENABLED:-0} == 1 )) && s+="VLESS + XHTTP + TLS（TCP ${XHTTP_TLS_PORT}）"
  (( ${WS_ENABLED:-0} == 1 )) && s+="${s:+、}VLESS + WebSocket + TLS（TCP ${WS_PORT}）"
  [[ -n $s ]] || s="还没打开 CDN 线路（打开时按这里的开关生效）"
  printf '%s' "$s"
}
vless_enc_print_status() {
  local v
  v=$(xray_version_num || echo 未安装)
  step "VLESS Encryption（只用于 CDN 线路）"
  printf '状态      %s\n' "$(vless_enc_label)"
  printf '作用于    %s\n' "$(vless_enc_scope)"
  if vless_enc_active; then
    printf '参数      %s.%s，服务端票据 %s，客户端 %s，认证 ML-KEM-768\n' "$VLESS_ENC_HEAD" "$VLESS_ENC_MODE" "$VLESS_ENC_TICKET" "$VLESS_ENC_RTT"
  fi
  if xray_supports_vlessenc; then printf 'Xray      %s（支持，需要 %s+）\n' "$v" "$VLESS_ENC_MIN_XRAY"
  else printf 'Xray      %s（不支持，需要 %s+）\n' "$v" "$VLESS_ENC_MIN_XRAY"; fi
  cat <<EOF
REALITY、XHTTP + REALITY、Hysteria2、Trojan、TUIC、AnyTLS 不受这个开关影响。
开着时 Cloudflare 解开 TLS 后只能看到密文；关掉时链接里是 encryption=none。
客户端：Xray-core ${VLESS_ENC_MIN_XRAY}+ 内核（v2rayN、v2rayNG 新版）和 mihomo v1.19.14+（Clash Verge Rev、FlClash、Mihomo Party）支持。
sing-box 内核（NekoBox、Hiddify、Karing、sing-box 官方）可能不支持，这类客户端请关掉。
用法：proxy vless-enc on | off | rotate（rotate 换新钥匙，旧的 CDN 链接失效）
EOF
}
vless_enc_apply() { # 只重写 Xray，刷新链接、信息文件和订阅
  local rc=0
  save_state
  if cdn_wanted && tls_for_cdn && xray_inbound_needed; then
    write_xray_config || rc=$?
    if (( rc == 0 )); then restart_xray
    elif (( rc != 2 )); then return "$rc"; fi
  fi
  save_state
  save_info
}
do_vless_enc() {
  need_node
  local act=${OPT_VENC_ACT:-}
  case $act in
    "") vless_enc_print_status; return 0 ;;
    on)
      if vless_enc_active; then
        ok "VLESS Encryption 已经开着。"
        vless_enc_print_status
        return 0
      fi
      if ! cdn_wanted; then
        VLESS_ENC=1
        if ! vless_enc_keys_ok && xray_supports_vlessenc; then vless_enc_gen || true; fi
        save_state
        ok "VLESS Encryption 已设为开启。还没打开 CDN 线路，打开 XHTTP+TLS 或 WebSocket+TLS 时生效。"
        return 0
      fi
      if ! vless_enc_need_xray; then
        VLESS_ENC=0; save_state
        die "Xray 仍不支持 VLESS Encryption（需要 ${VLESS_ENC_MIN_XRAY}+），CDN 线路保持 encryption=none。"
      fi
      VLESS_ENC=1
      if ! vless_enc_keys_ok && ! vless_enc_gen; then
        VLESS_ENC=0; save_state
        die "没能用 xray vlessenc 生成密钥，CDN 线路保持 encryption=none。"
      fi
      ;;
    off)
      if [[ ${VLESS_ENC:-} != 1 ]]; then
        VLESS_ENC=0; save_state
        ok "VLESS Encryption 已经关着。"
        vless_enc_print_status
        return 0
      fi
      # 钥匙留着，再打开时链接和原来一样
      VLESS_ENC=0
      ;;
    rotate)
      [[ ${VLESS_ENC:-} == 1 ]] || die "VLESS Encryption 没有开。先执行 proxy vless-enc on。"
      warn "换新钥匙后，两条 CDN 线路的旧链接全部失效，需要重新导入或更新订阅。REALITY 等其它协议不变。"
      (( OPT_AUTO )) || confirm "确认更换 VLESS Encryption 密钥？" n || return 0
      vless_enc_need_xray || die "Xray 不支持 VLESS Encryption（需要 ${VLESS_ENC_MIN_XRAY}+），没有更换。"
      vless_enc_gen || die "没能用 xray vlessenc 生成新钥匙，原来的钥匙没有改动。"
      ;;
    *) die "proxy vless-enc 的参数只能是 on、off 或 rotate。" ;;
  esac
  vless_enc_apply
  case $act in
    on) ok "VLESS Encryption 已开启。CDN 线路的链接已经更新，客户端需要重新导入或更新订阅。" ;;
    off) ok "VLESS Encryption 已关闭，CDN 线路改回 encryption=none。钥匙保留，再打开时链接不变。" ;;
    rotate) ok "已换新钥匙。CDN 线路的链接已经更新。" ;;
  esac
  cdn_wanted || info "还没打开 CDN 线路。这个设置会在打开 XHTTP+TLS 或 WebSocket+TLS 时生效。"
  if cdn_wanted && ! tls_for_cdn; then info "证书还没就绪，CDN 线路暂时没有写入 Xray。证书就绪后按这里的设置生效。"; fi
  if cdn_wanted && tls_for_cdn; then
    cdn_print_links 1
    print_sub_block 1
  fi
}


