# ============================================================
#          可选：证书（默认 Let's Encrypt 单域名）与订阅 HTTPS
# ============================================================
# 默认不申请。没有域名时 REALITY、以及 Hysteria2 / TUIC / AnyTLS 的自签证书都保持原样。
# 不写种类时仍是 Let's Encrypt 单域名 HTTP-01。其它种类：通配符（DNS-01）、多域名、
# ZeroSSL（同样三种公开证书）、Cloudflare 源站证书（只有 Cloudflare 信任，只给 CDN）。
# 公开证书申请之后：
#   · HTTP-01 只用 TCP 80，不碰 REALITY 所在端口；通配符改走 DNS-01，不占 80；
#   · 订阅只在 HTTPS 上提供，明文 HTTP 不返回订阅内容；
#   · Hysteria2 / TUIC / AnyTLS 出示这张证书，链接改用自有域名，不再带 insecure / pin；
#   · REALITY 继续借用伪装站点，配置里不写入这张证书。
#   · 可选的 CDN 线路（XHTTP+TLS / WebSocket+TLS）可以使用公开证书或源站证书。
#     续期钩子只在 /etc/proxy-oneclick/cdn-xray 存在时才把证书拷给 Xray 并重启 Xray。
# 源站证书不会打开订阅，也不会交给 Hysteria2 / TUIC / AnyTLS。
# 换种类时先关掉旧证书再申请新的，不改 REALITY。
# NAT 模式拒绝全部种类。公开证书的续期：systemd timer 或 OpenRC daily cron。

cert_cli_requested() {
  [[ -n ${OPT_CERT_DOMAIN:-} || ${OPT_CERT:-} == 1 || -n ${OPT_CERT_KIND:-} || -n ${OPT_CERT_NAMES:-} || -n ${OPT_CF_ORIGIN_KEY:-} || -n ${OPT_ZEROSSL_KID:-} ]]
}
# 公开可信：Let's Encrypt / ZeroSSL。旧状态没有 CERT_PUBLIC 时默认就是这种。
cert_is_public() {
  [[ ${CERT_ON:-0} == 1 && ${CERT_PUBLIC:-1} == 1 && ${CERT_CA:-letsencrypt} != cloudflare ]]
}
# Hysteria2 / TUIC / AnyTLS / 订阅。Cloudflare 源站证书不算。
tls_present_real() {
  cert_is_public && [[ -n ${CERT_DOMAIN:-} && -s ${CERT_FULLCHAIN:-} && -s ${CERT_PRIVKEY:-} ]]
}
# CDN 两条线路。公开证书和 Cloudflare 源站证书都可以。
tls_for_cdn() {
  [[ ${CERT_ON:-0} == 1 && -n ${CERT_DOMAIN:-} && -s ${CERT_FULLCHAIN:-} && -s ${CERT_PRIVKEY:-} ]]
}
cert_http_open() { [[ ${CERT_ON:-0} == 1 && ${CERT_CHALLENGE:-http} == http ]]; }
cert_port_owned() {
  cert_http_open && [[ $1 == 80 ]] && return 0
  cert_is_public && [[ $1 == "${SUB_PORT:-}" ]] && return 0
  return 1
}
tls_link_host() {
  if tls_present_real; then printf '%s' "$CERT_DOMAIN"; else server_addr; fi
}
tls_link_sni() {
  if tls_present_real; then printf '%s' "$CERT_DOMAIN"; else printf '%s' "$SNI"; fi
}
sub_url_raw() { printf 'https://%s:%s/sub/%s' "$CERT_DOMAIN" "$SUB_PORT" "$SUB_TOKEN"; }
sub_clash_url_raw() { printf 'https://%s:%s/sub/%s/clash' "$CERT_DOMAIN" "$SUB_PORT" "$SUB_TOKEN"; }
sub_url() { printf '%s\n' "$(sub_url_raw)"; }
sub_clash_url() { printf '%s\n' "$(sub_clash_url_raw)"; }

cert_domain_syntax() {
  local d=${1,,}
  [[ -n $d && ${#d} -le 253 ]] || return 1
  [[ $d =~ ^[0-9.]+$ || $d == *:* ]] && return 1
  [[ $d =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}
cert_email_syntax() { [[ $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

cert_resolved_ips() {
  local d=$1 ip out=""
  if have getent; then
    while read -r ip _; do
      ip=${ip,,}
      [[ $ip =~ ^[0-9.]+$ || $ip == *:* ]] || continue
      [[ " $out " == *" $ip "* ]] || out+="$ip "
    done < <(getent ahosts "$d" 2>/dev/null || true)
  fi
  if [[ -z ${out// /} ]] && have dig; then
    while read -r ip; do
      ip=${ip,,}
      [[ $ip =~ ^[0-9.]+$ || $ip == *:* ]] || continue
      [[ " $out " == *" $ip "* ]] || out+="$ip "
    done < <({ dig +short "$d" A; dig +short "$d" AAAA; } 2>/dev/null || true)
  fi
  printf '%s' "${out% }"
}
cert_ip_ours() {
  local a out=""
  [[ -n $PUBLIC_IP4 ]] && out+="$PUBLIC_IP4 "
  [[ -n $PUBLIC_IP6 ]] && out+="${PUBLIC_IP6,,} "
  if [[ ${SERVER_ADDR:-} =~ ^[0-9.]+$ || ${SERVER_ADDR:-} == *:* ]]; then out+="${SERVER_ADDR,,} "; fi
  if have ip; then
    while read -r a; do
      a=${a%%/*}; a=${a,,}
      [[ -z $a || $a == 127.* || $a == ::1 || $a == fe80:* || $a == fc* || $a == fd* ]] && continue
      [[ " $out " == *" $a "* ]] || out+="$a "
    done < <(ip -o addr show scope global 2>/dev/null | awk '{print $4}')
  fi
  printf '%s' "${out% }"
}
cert_domain_points_here() {
  local d=$1 ips ours ip missing=""
  ips=$(cert_resolved_ips "$d")
  if [[ -z $ips ]]; then warn "域名 ${d} 没有解析出地址。"; return 1; fi
  ours=$(cert_ip_ours)
  if [[ -z $ours ]]; then warn "没有检测到本机地址，无法确认域名指向这里。"; return 1; fi
  for ip in $ips; do
    [[ " $ours " == *" ${ip,,} "* ]] || missing+="${ip} "
  done
  if [[ -n $missing ]]; then
    warn "域名 ${d} 解析到 ${missing}，其中有不是本机的地址（本机: ${ours}）。"
    return 1
  fi
  info "域名 ${d} 已解析到本机（${ips}）。"
  return 0
}
cert_normalize_domain() {
  CERT_DOMAIN=${CERT_DOMAIN,,}
  CERT_DOMAIN=${CERT_DOMAIN%.}
  CERT_DOMAIN=${CERT_DOMAIN// /}
}

sub_port_blocked() {
  local p=$1
  [[ $p == 80 ]] && return 0
  (( ${REALITY_ENABLED:-0} == 1 )) && [[ $p == "$XRAY_PORT" ]] && return 0
  (( ${XHTTP_ENABLED:-0} == 1 )) && [[ $p == "$XHTTP_PORT" ]] && return 0
  (( ${TROJAN_ENABLED:-0} == 1 )) && [[ $p == "$TROJAN_PORT" ]] && return 0
  (( ${ANYTLS_ENABLED:-0} == 1 )) && [[ $p == "$ANYTLS_PORT" ]] && return 0
  (( ${XHTTP_TLS_ENABLED:-0} == 1 )) && [[ $p == "$XHTTP_TLS_PORT" ]] && return 0
  (( ${WS_ENABLED:-0} == 1 )) && [[ $p == "$WS_PORT" ]] && return 0
  return 1
}
choose_sub_port() {
  local p=${SUB_PORT:-8447}
  [[ -n $OPT_SUB_PORT ]] && p=$OPT_SUB_PORT
  while :; do
    if [[ -z $OPT_SUB_PORT ]]; then
      ask p "订阅 HTTPS 端口（TCP，不要用 80，也不要占用 REALITY）" "${p:-8447}"
      p=${p// /}
    fi
    if ! is_port "$p" || sub_port_blocked "$p"; then
      warn "端口 ${p:-空} 不能用于订阅。80 只留给证书申请；已开启协议的 TCP 端口也不能占用。"
      (( OPT_AUTO )) || [[ -n $OPT_SUB_PORT ]] && die "订阅端口不可用: ${p:-空}"
      p=8447
      continue
    fi
    if check_port_free tcp "$p" 'python3(\.[0-9]+)?'; then SUB_PORT=$p; return 0; fi
    (( OPT_AUTO )) || [[ -n $OPT_SUB_PORT ]] && die "订阅端口 ${p} 已被占用。"
    p=8447
  done
}

cert_ensure_group() {
  getent group "$CERT_GROUP" >/dev/null 2>&1 && return 0
  if have groupadd; then groupadd --system "$CERT_GROUP" >/dev/null 2>&1 || true
  elif have addgroup; then addgroup -S "$CERT_GROUP" >/dev/null 2>&1 || true
  fi
  getent group "$CERT_GROUP" >/dev/null 2>&1 || die "无法创建组 ${CERT_GROUP}。"
}
cert_add_member() {
  local u=$1
  id "$u" >/dev/null 2>&1 || return 0
  if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx "$CERT_GROUP"; then return 0; fi
  if have usermod; then usermod -aG "$CERT_GROUP" "$u" >/dev/null 2>&1 || true
  elif have addgroup; then addgroup "$u" "$CERT_GROUP" >/dev/null 2>&1 || true
  fi
}
cert_ensure_sub_user() {
  cert_ensure_group
  if id "$SUB_USER" >/dev/null 2>&1; then cert_add_member "$SUB_USER"; return 0; fi
  local sh; sh=$(command -v nologin 2>/dev/null || true)
  [[ -n $sh ]] || sh=/usr/sbin/nologin
  if have useradd; then
    useradd --system --no-create-home --shell "$sh" --gid "$CERT_GROUP" "$SUB_USER" >/dev/null 2>&1 || \
      useradd --system -M -s "$sh" -g "$CERT_GROUP" "$SUB_USER" >/dev/null 2>&1 || true
  elif have adduser; then
    adduser -S -D -H -h /var/empty -s /sbin/nologin -G "$CERT_GROUP" "$SUB_USER" >/dev/null 2>&1 || true
  fi
  id "$SUB_USER" >/dev/null 2>&1 || die "无法创建用户 ${SUB_USER}，不能启动订阅 HTTPS。"
}
cert_grant_readers() {
  cert_ensure_group
  cert_ensure_sub_user
  cert_add_member hysteria
  cert_add_member sing-box
  cert_add_member "$SUB_USER"
  if [[ -d $CERT_DIR ]]; then
    chown "root:${CERT_GROUP}" "$CERT_DIR" 2>/dev/null || true
    chmod 750 "$CERT_DIR" 2>/dev/null || true
  fi
  if [[ -s $CERT_PRIVKEY ]]; then
    chown "root:${CERT_GROUP}" "$CERT_FULLCHAIN" "$CERT_PRIVKEY" 2>/dev/null || true
    chmod 644 "$CERT_FULLCHAIN" 2>/dev/null || true
    chmod 640 "$CERT_PRIVKEY" 2>/dev/null || true
  fi
}

cert_regex_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//./\\.}
  s=${s//\*/\\*}
  s=${s//\[/\\[}
  s=${s//\]/\\]}
  printf '%s' "$s"
}
cert_name_covered() { # $1 证书文件 $2 名字。*.example.com 只覆盖一级，不覆盖根域名。
  local file=$1 name=$2 san esc wild w p left
  [[ -s $file ]] || return 1
  san=$(openssl x509 -in "$file" -noout -ext subjectAltName 2>/dev/null || true)
  [[ -n $san ]] || return 1
  esc=$(cert_regex_escape "$name")
  grep -Eq "DNS:${esc}(,|[[:space:]]|$)" <<<"$san" && return 0
  [[ $name == \*.* ]] && return 1
  wild=$(grep -Eo 'DNS:\*\.[A-Za-z0-9.-]+' <<<"$san" || true)
  while read -r w; do
    [[ -n $w ]] || continue
    w=${w#DNS:}
    p=${w#\*.}
    [[ $name == *".${p}" ]] || continue
    left=${name%".$p"}
    [[ -n $left && $left != '*' && $left != *.* ]] && return 0
  done <<<"$wild"
  return 1
}
cert_san_ok() {
  local f=$1 n names
  [[ -s $f ]] || return 1
  [[ -n ${CERT_DOMAIN:-} ]] || return 1
  cert_name_covered "$f" "$CERT_DOMAIN" || return 1
  names=${CERT_NAMES:-$CERT_DOMAIN}
  local -a arr=()
  IFS=',' read -ra arr <<< "$names"
  for n in "${arr[@]}"; do
    [[ -n $n ]] || continue
    cert_name_covered "$f" "$n" || return 1
  done
}
cert_issuer_ok() {
  local iss
  iss=$(openssl x509 -in "$1" -noout -issuer 2>/dev/null || true)
  iss=${iss,,}
  case ${CERT_CA:-letsencrypt} in
    letsencrypt) [[ $iss == *"let's encrypt"* || $iss == *"lets encrypt"* ]] ;;
    zerossl) [[ $iss == *zerossl* ]] ;;
    cloudflare) [[ $iss == *cloudflare* ]] ;;
    *) return 1 ;;
  esac
}
cert_current_ok() {
  local f live="/etc/letsencrypt/live/${CERT_NAME}/fullchain.pem"
  if [[ ${CERT_CA:-letsencrypt} == cloudflare ]]; then
    [[ -s $CERT_FULLCHAIN ]] || return 1
    cert_san_ok "$CERT_FULLCHAIN" || return 1
    cert_issuer_ok "$CERT_FULLCHAIN" || return 1
    openssl x509 -checkend 2592000 -noout -in "$CERT_FULLCHAIN" >/dev/null 2>&1 || return 1
    return 0
  fi
  for f in "$CERT_FULLCHAIN" "$live"; do
    [[ -s $f ]] || continue
    cert_san_ok "$f" || continue
    cert_issuer_ok "$f" || continue
    openssl x509 -checkend 2592000 -noout -in "$f" >/dev/null 2>&1 || continue
    return 0
  done
  return 1
}
cert_lineage_reusable() {
  local live="/etc/letsencrypt/live/${CERT_NAME}/fullchain.pem"
  [[ -s $live ]] || return 1
  cert_san_ok "$live" || return 1
  cert_issuer_ok "$live" || return 1
}
cert_expiry_text() {
  local end
  [[ -s $CERT_FULLCHAIN ]] || { printf '未知'; return 0; }
  end=$(openssl x509 -enddate -noout -in "$CERT_FULLCHAIN" 2>/dev/null | cut -d= -f2 || true)
  if [[ -n $end ]]; then date -d "$end" '+%F' 2>/dev/null || printf '%s' "$end"
  else printf '未知'; fi
}

install_certbot_pkg() {
  have certbot && have python3 && return 0
  step "安装 certbot 与 python3"
  if [[ $PKG == dnf && $OS_ID != fedora ]] && ! rpm -q epel-release >/dev/null 2>&1; then
    pkg_install epel-release 2>/dev/null || true
  fi
  if ! pkg_install certbot python3; then
    die "无法安装 certbot 或 python3，不能申请证书。Debian/Ubuntu 用 apt；RHEL 系需要 EPEL 里的 certbot；Alpine 用 apk（需启用 community）。本次没有改动 REALITY。"
  fi
  if ! have certbot || ! have python3; then
    die "certbot 或 python3 安装后仍不可用，不能申请证书。"
  fi
}
cert_allow_80_now() {
  (( ${FW_ENABLED:-0} == 1 )) || return 0
  have nft || return 0
  nft list table inet "$NFT_TABLE" >/dev/null 2>&1 || return 0
  if nft list chain inet "$NFT_TABLE" input 2>/dev/null | grep -Eq 'tcp dport \{[^}]*\b80\b|tcp dport 80( |$)'; then
    return 0
  fi
  nft insert rule inet "$NFT_TABLE" input tcp dport 80 accept comment "acme-http-01" >/dev/null 2>&1 || \
    warn "没能在现有防火墙里放行 TCP 80。若申请失败，请在防火墙和云安全组放行 80 后重试。"
}

write_sub_python() {
  mkdir -p "$CERT_LIB"
  cat >"$SUB_PY" <<'PY'
#!/usr/bin/env python3
"""HTTPS-only subscription listener. Never binds port 80 and never answers plain HTTP."""
import json
import socket
import ssl
import sys
from http.server import BaseHTTPRequestHandler

try:
    from http.server import ThreadingHTTPServer as _HTTPServer
except ImportError:  # Python 3.6
    from socketserver import ThreadingMixIn
    from http.server import HTTPServer

    class _HTTPServer(ThreadingMixIn, HTTPServer):
        daemon_threads = True


def load_conf(path):
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    for key in ("port", "cert", "key", "token", "body", "clash"):
        if key not in data:
            raise SystemExit("missing config field")
    token = str(data["token"])
    if not token or "/" in token or ".." in token:
        raise SystemExit("invalid token")
    data["token"] = token
    return data


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self._reply(True)

    def do_HEAD(self):
        self._reply(False)

    def do_POST(self):
        self._empty(404)

    def _reply(self, send_body):
        path = self.path.split("?", 1)[0]
        if path.endswith("/") and path != "/":
            path = path[:-1]
        conf = self.server.conf
        token = conf["token"]
        target = None
        ctype = "text/plain; charset=utf-8"
        if path == "/sub/" + token:
            target = conf["body"]
        elif path == "/sub/" + token + "/clash":
            target = conf["clash"]
            ctype = "text/yaml; charset=utf-8"
        if target is None:
            self._empty(404)
            return
        try:
            with open(target, "rb") as fh:
                data = fh.read()
        except OSError:
            self._empty(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        if send_body:
            self.wfile.write(data)

    def _empty(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()

    def log_message(self, fmt, *args):
        code = args[1] if len(args) > 1 else "-"
        sys.stderr.write("proxy-oneclick-sub %s %s\n" % (self.command, code))


class TLSServer(_HTTPServer):
    allow_reuse_address = True

    def __init__(self, addr, handler, context):
        super().__init__(addr, handler)
        self.socket = context.wrap_socket(self.socket, server_side=True)


def make_server(port, context):
    last_err = None
    try:
        class V6(TLSServer):
            address_family = socket.AF_INET6

            def server_bind(self):
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                super(TLSServer, self).server_bind()

        return V6(("::", port), Handler, context)
    except OSError as exc:
        last_err = exc

    class V4(TLSServer):
        address_family = socket.AF_INET

    try:
        return V4(("0.0.0.0", port), Handler, context)
    except OSError:
        raise last_err


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: sub_https.py config.json")
    conf = load_conf(sys.argv[1])
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    if hasattr(ssl, "TLSVersion"):
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    else:
        ctx.options |= getattr(ssl, "OP_NO_TLSv1", 0) | getattr(ssl, "OP_NO_TLSv1_1", 0)
    ctx.load_cert_chain(conf["cert"], conf["key"])
    httpd = make_server(int(conf["port"]), ctx)
    httpd.conf = conf
    httpd.serve_forever()


if __name__ == "__main__":
    main()
PY
  chmod 755 "$SUB_PY"
}
write_cert_hook() {
  mkdir -p "$CERT_LIB"
  cat >"$CERT_HOOK" <<EOF
#!/bin/sh
# 由 proxy-oneclick 生成。certbot 续期成功后调用。
# 只更新证书并重启 Hysteria2 / sing-box / 订阅服务。
# REALITY 入站不使用这张证书。仅当 CDN 的 XHTTP/WS 已打开时，才把证书拷给 Xray 并重启 Xray。
src="/etc/letsencrypt/live/${CERT_NAME}"
dst="${CERT_DIR}"
grp="${CERT_GROUP}"
case \${RENEWED_LINEAGE:-} in
  "") ;;
  */${CERT_NAME}|*/${CERT_NAME}/) ;;
  *) exit 0 ;;
esac
[ -f "\$src/fullchain.pem" ] && [ -f "\$src/privkey.pem" ] || exit 0
mkdir -p "\$dst"
if ! getent group "\$grp" >/dev/null 2>&1; then
  if command -v groupadd >/dev/null 2>&1; then groupadd --system "\$grp" >/dev/null 2>&1 || true
  elif command -v addgroup >/dev/null 2>&1; then addgroup -S "\$grp" >/dev/null 2>&1 || true
  fi
fi
cp -f "\$src/fullchain.pem" "\$dst/fullchain.pem.new"
cp -f "\$src/privkey.pem" "\$dst/privkey.pem.new"
chown "root:\${grp}" "\$dst/fullchain.pem.new" "\$dst/privkey.pem.new" 2>/dev/null || chown root "\$dst/fullchain.pem.new" "\$dst/privkey.pem.new"
chmod 644 "\$dst/fullchain.pem.new"
chmod 640 "\$dst/privkey.pem.new"
mv -f "\$dst/fullchain.pem.new" "\$dst/fullchain.pem"
mv -f "\$dst/privkey.pem.new" "\$dst/privkey.pem"
chmod 750 "\$dst" 2>/dev/null || true
chown "root:\${grp}" "\$dst" 2>/dev/null || true
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  systemctl try-restart hysteria-server.service >/dev/null 2>&1 || true
  systemctl try-restart sing-box.service >/dev/null 2>&1 || true
  systemctl try-restart proxy-oneclick-sub.service >/dev/null 2>&1 || true
elif command -v rc-service >/dev/null 2>&1; then
  for s in hysteria-server sing-box proxy-oneclick-sub; do
    if [ -x "/etc/init.d/\$s" ]; then rc-service "\$s" restart >/dev/null 2>&1 || true; fi
  done
fi
if [ -f "${CDN_FLAG}" ]; then
  xdir="${XRAY_CERT_DIR}"
  mkdir -p "\$xdir"
  cp -f "\$dst/fullchain.pem" "\$xdir/fullchain.pem"
  cp -f "\$dst/privkey.pem" "\$xdir/privkey.pem"
  xgrp=\$(id -gn nobody 2>/dev/null || echo nogroup)
  chown "root:\$xgrp" "\$xdir/fullchain.pem" "\$xdir/privkey.pem" 2>/dev/null || true
  chmod 644 "\$xdir/fullchain.pem"
  chmod 640 "\$xdir/privkey.pem"
  chmod 750 "\$xdir" 2>/dev/null || true
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    systemctl try-restart xray.service >/dev/null 2>&1 || true
  elif command -v rc-service >/dev/null 2>&1; then
    if [ -x /etc/init.d/xray ]; then rc-service xray restart >/dev/null 2>&1 || true; fi
  fi
fi
exit 0
EOF
  chmod 755 "$CERT_HOOK"
}
write_cert_helpers() { write_sub_python; write_cert_hook; }

cert_install_material() {
  if [[ ${CERT_CA:-letsencrypt} == cloudflare ]]; then
    [[ -s $CERT_FULLCHAIN && -s $CERT_PRIVKEY ]] || die "源站证书文件不在。"
    cert_grant_readers
    mkdir -p "$CERT_LIB" "$(dirname "$SUB_LOG")"
    chmod 755 "$CERT_BASE" 2>/dev/null || true
    chmod 750 "$CERT_DIR"
    chown "root:${CERT_GROUP}" "$CERT_DIR"
    selinux_fix "$CERT_BASE" "$CERT_LIB"
    return 0
  fi
  local live="/etc/letsencrypt/live/${CERT_NAME}"
  if [[ ! -s ${live}/fullchain.pem || ! -s ${live}/privkey.pem ]]; then
    [[ -s $CERT_FULLCHAIN && -s $CERT_PRIVKEY ]] || die "certbot 没有留下证书文件。"
    cert_grant_readers
    mkdir -p "$CERT_LIB" "$(dirname "$SUB_LOG")"
    chmod 755 "$CERT_BASE" 2>/dev/null || true
    chmod 750 "$CERT_DIR"
    chown "root:${CERT_GROUP}" "$CERT_DIR"
    selinux_fix "$CERT_BASE" "$CERT_LIB"
    return 0
  fi
  cert_grant_readers
  mkdir -p "$CERT_DIR" "$CERT_LIB" "$(dirname "$SUB_LOG")"
  cp -f "${live}/fullchain.pem" "${CERT_FULLCHAIN}.new"
  cp -f "${live}/privkey.pem" "${CERT_PRIVKEY}.new"
  chown "root:${CERT_GROUP}" "${CERT_FULLCHAIN}.new" "${CERT_PRIVKEY}.new"
  chmod 644 "${CERT_FULLCHAIN}.new"
  chmod 640 "${CERT_PRIVKEY}.new"
  mv -f "${CERT_FULLCHAIN}.new" "$CERT_FULLCHAIN"
  mv -f "${CERT_PRIVKEY}.new" "$CERT_PRIVKEY"
  chmod 755 "$CERT_BASE" 2>/dev/null || true
  chmod 750 "$CERT_DIR"
  chown "root:${CERT_GROUP}" "$CERT_DIR"
  selinux_fix "$CERT_BASE" "$CERT_LIB"
}
certbot_issue() {
  local log live="/etc/letsencrypt/live/${CERT_NAME}/fullchain.pem"
  local -a args=() dargs=() arr=()
  local n who="Let's Encrypt"
  mktmp
  log="${TMP_DIR}/certbot-issue.log"
  if [[ -s $live ]] && ! cert_lineage_reusable; then
    info "已有证书的名字或签发机构与这次不一致，先删除再申请。"
    certbot delete --cert-name "$CERT_NAME" --non-interactive >/dev/null 2>&1 || true
  fi
  if [[ -n $CERT_EMAIL ]]; then args=(--email "$CERT_EMAIL" --no-eff-email)
  else args=(--register-unsafely-without-email); fi
  if [[ ${CERT_CA:-letsencrypt} == zerossl ]]; then
    who="ZeroSSL"
    cert_load_eab || die "没有 ZeroSSL 的 EAB 凭据。"
    args+=(--server "$ZEROSSL_SERVER" --eab-kid "$ZEROSSL_KID" --eab-hmac-key "$ZEROSSL_HMAC")
  fi
  IFS=',' read -ra arr <<< "${CERT_NAMES:-$CERT_DOMAIN}"
  for n in "${arr[@]}"; do
    [[ -n $n ]] || continue
    dargs+=(-d "$n")
  done
  # 默认路径保持原来的 Let's Encrypt 单域名 HTTP-01，参数顺序不改。
  if [[ ${CERT_CA:-letsencrypt} == letsencrypt && ${CERT_SCOPE:-single} == single && ${CERT_CHALLENGE:-http} == http ]]; then
    info "向 Let's Encrypt 申请 ${CERT_DOMAIN}（HTTP-01，端口 80）。不会改动 REALITY 的 TCP ${XRAY_PORT}。"
    if ! certbot certonly --non-interactive --agree-tos \
        --cert-name "$CERT_NAME" \
        --standalone --preferred-challenges http --http-01-port 80 \
        --keep-until-expiring \
        --deploy-hook "$CERT_HOOK" \
        -d "$CERT_DOMAIN" \
        "${args[@]}" >"$log" 2>&1; then
      tail -n 30 "$log" >&2 || true
      cert_fail_explain "$log"
      die "申请证书失败。REALITY（TCP ${XRAY_PORT}）没有改动，也没有改用这张证书。"
    fi
    ok "证书已签发: ${CERT_DOMAIN}"
    return 0
  fi
  if [[ ${CERT_CHALLENGE:-http} == dns ]]; then
    info "向 ${who} 申请通配符（DNS-01）：${CERT_NAMES}。不占用 80，也不改 REALITY 的 TCP ${XRAY_PORT}。"
    if ! certbot certonly --non-interactive --agree-tos \
        --cert-name "$CERT_NAME" \
        --manual --preferred-challenges dns \
        --manual-auth-hook "$CERT_DNS_AUTH" \
        --manual-cleanup-hook "$CERT_DNS_CLEAN" \
        --manual-public-ip-logging-ok \
        --keep-until-expiring \
        --deploy-hook "$CERT_HOOK" \
        "${dargs[@]}" \
        "${args[@]}" >"$log" 2>&1; then
      tail -n 40 "$log" >&2 || true
      cert_fail_explain "$log"
      die "申请证书失败。REALITY（TCP ${XRAY_PORT}）没有改动，也没有改用这张证书。"
    fi
  else
    info "向 ${who} 申请证书（HTTP-01，端口 80）：${CERT_NAMES:-$CERT_DOMAIN}。不会改动 REALITY 的 TCP ${XRAY_PORT}。"
    if ! certbot certonly --non-interactive --agree-tos \
        --cert-name "$CERT_NAME" \
        --standalone --preferred-challenges http --http-01-port 80 \
        --keep-until-expiring \
        --deploy-hook "$CERT_HOOK" \
        "${dargs[@]}" \
        "${args[@]}" >"$log" 2>&1; then
      tail -n 40 "$log" >&2 || true
      cert_fail_explain "$log"
      die "申请证书失败。REALITY（TCP ${XRAY_PORT}）没有改动，也没有改用这张证书。"
    fi
  fi
  ok "证书已签发: ${CERT_NAMES:-$CERT_DOMAIN}"
}

cert_b64() {
  if printf '' | base64 -w 0 >/dev/null 2>&1; then base64 -w 0
  else base64 | tr -d '\n'; fi
  printf '\n'
}
cert_render_links() {
  local u r
  if (( REALITY_ENABLED )); then
    printf '%s\n' "$(vless_link "$UUID" "${NODE_NAME}-Reality" 1)"
    if [[ -s $USERS_FILE ]]; then
      while IFS=$'\t' read -r u r; do
        [[ -n $u ]] || continue
        printf '%s\n' "$(vless_link "$u" "${NODE_NAME}-${r}" 0)"
      done <"$USERS_FILE"
    fi
  fi
  if (( XHTTP_ENABLED )); then
    printf '%s\n' "$(vless_xhttp_link "$UUID" "${NODE_NAME}-XHTTP" 1)"
    if [[ -s $USERS_FILE ]]; then
      while IFS=$'\t' read -r u r; do
        [[ -n $u ]] || continue
        printf '%s\n' "$(vless_xhttp_link "$u" "${NODE_NAME}-XHTTP-${r}" 0)"
      done <"$USERS_FILE"
    fi
  fi
  (( HY2_ENABLED )) && printf '%s\n' "$(hy2_link)"
  (( TROJAN_ENABLED )) && printf '%s\n' "$(trojan_link)"
  (( TUIC_ENABLED )) && printf '%s\n' "$(tuic_link)"
  (( ANYTLS_ENABLED )) && printf '%s\n' "$(anytls_link)"
  cdn_render_links
}
cert_write_bodies() {
  tls_present_real || return 0
  [[ -n $SUB_TOKEN ]] || return 0
  cert_grant_readers
  mkdir -p "$CERT_DIR"
  cert_render_links | cert_b64 >"${SUB_BODY}.tmp"
  mihomo_yaml >"${SUB_CLASH}.tmp"
  chown "root:${CERT_GROUP}" "${SUB_BODY}.tmp" "${SUB_CLASH}.tmp" 2>/dev/null || true
  chmod 640 "${SUB_BODY}.tmp" "${SUB_CLASH}.tmp"
  mv -f "${SUB_BODY}.tmp" "$SUB_BODY"
  mv -f "${SUB_CLASH}.tmp" "$SUB_CLASH"
}
cert_write_sub_conf() {
  mkdir -p "$CERT_DIR"
  jq -n --arg token "$SUB_TOKEN" --argjson port "$SUB_PORT" \
    --arg cert "$CERT_FULLCHAIN" --arg key "$CERT_PRIVKEY" \
    --arg body "$SUB_BODY" --arg clash "$SUB_CLASH" \
    '{port: $port, cert: $cert, key: $key, token: $token, body: $body, clash: $clash}' \
    >"${SUB_CONF}.tmp"
  chown "root:${CERT_GROUP}" "${SUB_CONF}.tmp" 2>/dev/null || true
  chmod 640 "${SUB_CONF}.tmp"
  mv -f "${SUB_CONF}.tmp" "$SUB_CONF"
}

write_sub_service() {
  local user=$SUB_USER py
  id "$user" >/dev/null 2>&1 || user=root
  py=$(command -v python3)
  [[ -n $py ]] || die "未找到 python3，无法启动订阅 HTTPS。"
  mkdir -p "$(dirname "$SUB_LOG")"
  if is_openrc; then
    cat >"$SUB_RC" <<RC
#!/sbin/openrc-run
# 由 proxy-oneclick 生成。只提供订阅 HTTPS，不监听 80。
name="proxy-oneclick-sub"
description="proxy-oneclick subscription HTTPS"
supervisor=supervise-daemon
command="${py}"
command_args="${SUB_PY} ${SUB_CONF}"
command_user="${user}:${CERT_GROUP}"
output_log="${SUB_LOG}"
error_log="${SUB_LOG}"
respawn_delay=3
respawn_max=0
supervise_daemon_args="--env PYTHONUNBUFFERED=1"
$(need_bind_cap "$SUB_PORT" && echo 'capabilities="^cap_net_bind_service"')

depend() {
  want net
  after net
}

start_pre() {
  checkpath -d -m 0755 -o "\${command_user}" "$(dirname "$SUB_LOG")"
  checkpath -f -m 0644 -o "\${command_user}" "${SUB_LOG}"
}
RC
    chmod 755 "$SUB_RC"
  else
    {
      echo "# 由 proxy-oneclick 生成。只提供订阅 HTTPS，不监听 80。"
      echo "[Unit]"
      echo "Description=proxy-oneclick subscription HTTPS"
      echo "After=network-online.target"
      echo "Wants=network-online.target"
      echo
      echo "[Service]"
      echo "User=${user}"
      echo "Group=${CERT_GROUP}"
      echo "WorkingDirectory=${CERT_DIR}"
      echo "NoNewPrivileges=true"
      if need_bind_cap "$SUB_PORT"; then
        echo "CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
        echo "AmbientCapabilities=CAP_NET_BIND_SERVICE"
      fi
      echo "Environment=PYTHONUNBUFFERED=1"
      echo "ExecStart=${py} ${SUB_PY} ${SUB_CONF}"
      echo "Restart=on-failure"
      echo "RestartSec=3"
      echo
      echo "[Install]"
      echo "WantedBy=multi-user.target"
    } >"$SUB_UNIT"
    systemctl daemon-reload
  fi
}
write_renew_job() {
  local bin; bin=$(command -v certbot)
  [[ -n $bin ]] || die "未找到 certbot，无法安排续期。"
  if is_openrc; then
    mkdir -p "$(dirname "$CERT_CRON")"
    cat >"$CERT_CRON" <<EOF
#!/bin/sh
# 由 proxy-oneclick 生成。每天检查一次，临近到期才真正续期。
exec ${bin} renew --quiet --cert-name ${CERT_NAME}
EOF
    chmod 755 "$CERT_CRON"
    if have rc-update; then
      rc-update add crond default >/dev/null 2>&1 || rc-update add cron default >/dev/null 2>&1 || true
      rc-service crond start >/dev/null 2>&1 || rc-service cron start >/dev/null 2>&1 || true
    fi
    ok "证书续期已交给 OpenRC 的每日任务（${CERT_CRON}）。"
  else
    cat >"$CERT_RENEW_UNIT" <<EOF
[Unit]
Description=Renew proxy-oneclick certificate
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${bin} renew --quiet --cert-name ${CERT_NAME}
EOF
    cat >"$CERT_TIMER_UNIT" <<EOF
[Unit]
Description=Daily proxy-oneclick certificate renewal check

[Timer]
OnCalendar=*-*-* 03:17:00
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now proxy-oneclick-cert.timer >/dev/null 2>&1 || warn "证书续期定时器未能启用，请稍后执行 systemctl enable --now proxy-oneclick-cert.timer。"
    ok "证书续期已交给 systemd 定时器（每天检查，到期前约 30 天续期）。"
  fi
}

cert_selfcheck() {
  local got="" want tmp httpbody
  want=$(openssl x509 -in "$CERT_FULLCHAIN" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true)
  got=$( { echo | openssl s_client -connect "127.0.0.1:${SUB_PORT}" -servername "$CERT_DOMAIN" 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2; } || true)
  if [[ -z $got || $got != "$want" ]]; then
    warn "订阅 HTTPS 自检未通过：TCP ${SUB_PORT} 上没有出示 ${CERT_DOMAIN} 的证书。可查看 proxy status。"
    return 0
  fi
  tmp=$(mktemp)
  if curl -fsS --insecure --resolve "${CERT_DOMAIN}:${SUB_PORT}:127.0.0.1" --max-time 10 -o "$tmp" "$(sub_url_raw)"; then
    if cmp -s "$tmp" "$SUB_BODY"; then ok "订阅 HTTPS 自检通过（${CERT_DOMAIN}:${SUB_PORT}）。"
    else warn "订阅 HTTPS 已连通，但内容和当前节点列表不一致。"; fi
  else
    warn "订阅 HTTPS 握手正常，但拉取订阅失败。"
  fi
  httpbody=$(mktemp)
  if curl -fsS --max-time 3 -o "$httpbody" "http://127.0.0.1:${SUB_PORT}/sub/${SUB_TOKEN}" 2>/dev/null \
      && cmp -s "$httpbody" "$SUB_BODY"; then
    rm -f "$tmp" "$httpbody"
    die "订阅端口以明文 HTTP 返回了订阅内容，已中止。"
  fi
  rm -f "$tmp" "$httpbody"
  return 0
}
cert_start_sub() {
  tls_present_real || return 0
  cert_grant_readers
  write_cert_helpers
  cert_write_sub_conf
  cert_write_bodies
  write_sub_service
  if cert_renew_unattended; then write_renew_job
  else
    cert_drop_renew_job
    warn "没有保存 Cloudflare DNS 令牌，定时任务没法自己添加 TXT。到期前请运行 proxy cert 再添加一次，或重新申请时加上 --cf-dns-token。"
  fi
  sd_reload
  svc_enable proxy-oneclick-sub
  svc_restart proxy-oneclick-sub || true
  sleep 1
  if ! svc_active proxy-oneclick-sub; then
    svc_logs proxy-oneclick-sub 30 >&2 || true
    die "订阅 HTTPS 服务启动失败。REALITY 没有改动。"
  fi
  ok "订阅 HTTPS 已监听 TCP ${SUB_PORT}（只接受 TLS；明文 HTTP 不提供订阅）。"
  cert_selfcheck
}

cert_kind_id() {
  case ${CERT_CA:-letsencrypt}:${CERT_SCOPE:-single} in
    letsencrypt:single) printf 'le' ;;
    letsencrypt:wildcard) printf 'wildcard' ;;
    letsencrypt:multi) printf 'multi' ;;
    zerossl:single) printf 'zerossl' ;;
    zerossl:wildcard) printf 'zerossl-wildcard' ;;
    zerossl:multi) printf 'zerossl-multi' ;;
    cloudflare:*) printf 'cf-origin' ;;
    *) printf 'le' ;;
  esac
}
cert_kind_label_of() {
  case $1 in
    le) printf "Let's Encrypt 单域名" ;;
    wildcard) printf "Let's Encrypt 通配符" ;;
    multi) printf "Let's Encrypt 多域名" ;;
    zerossl) printf "ZeroSSL 单域名" ;;
    zerossl-wildcard) printf "ZeroSSL 通配符" ;;
    zerossl-multi) printf "ZeroSSL 多域名" ;;
    cf-origin) printf "Cloudflare 源站证书" ;;
    *) printf '证书' ;;
  esac
}
cert_kind_label() { cert_kind_label_of "$(cert_kind_id)"; }
cert_normalize_kind() {
  local k=${1,,}
  k=${k// /}
  case $k in
    le|letsencrypt|single|http|http-01|http01) printf 'le' ;;
    wildcard|wild|dns|dns-01|dns01) printf 'wildcard' ;;
    multi|san|names) printf 'multi' ;;
    zerossl|zero|zerossl-single|zerossl-http) printf 'zerossl' ;;
    zerossl-wildcard|zerossl-wild|zerossl-dns) printf 'zerossl-wildcard' ;;
    zerossl-multi|zerossl-san) printf 'zerossl-multi' ;;
    cf-origin|cf|cloudflare|origin|origin-ca|cf-origin-ca) printf 'cf-origin' ;;
    *) return 1 ;;
  esac
}
cert_kind_apply() {
  case $1 in
    le) CERT_CA=letsencrypt; CERT_SCOPE=single; CERT_PUBLIC=1; CERT_CHALLENGE=http ;;
    wildcard) CERT_CA=letsencrypt; CERT_SCOPE=wildcard; CERT_PUBLIC=1; CERT_CHALLENGE=dns ;;
    multi) CERT_CA=letsencrypt; CERT_SCOPE=multi; CERT_PUBLIC=1; CERT_CHALLENGE=http ;;
    zerossl) CERT_CA=zerossl; CERT_SCOPE=single; CERT_PUBLIC=1; CERT_CHALLENGE=http ;;
    zerossl-wildcard) CERT_CA=zerossl; CERT_SCOPE=wildcard; CERT_PUBLIC=1; CERT_CHALLENGE=dns ;;
    zerossl-multi) CERT_CA=zerossl; CERT_SCOPE=multi; CERT_PUBLIC=1; CERT_CHALLENGE=http ;;
    cf-origin)
      CERT_CA=cloudflare; CERT_PUBLIC=0; CERT_CHALLENGE=none
      if [[ ${PLAN_NAMES:-} == *'*'* ]]; then CERT_SCOPE=wildcard
      elif [[ ${PLAN_NAMES:-} == *,* ]]; then CERT_SCOPE=multi
      else CERT_SCOPE=single; fi
      ;;
    *) return 1 ;;
  esac
}
cert_renew_unattended() {
  [[ ${CERT_CA:-letsencrypt} == cloudflare ]] && return 1
  [[ ${CERT_CHALLENGE:-http} == http ]] && return 0
  [[ ${CERT_CHALLENGE:-} == dns && -s ${CERT_DNS_TOKEN:-} ]]
}
cert_drop_renew_job() {
  if [[ ${INIT_SYS:-} == systemd ]] && have systemctl; then
    systemctl disable --now proxy-oneclick-cert.timer >/dev/null 2>&1 || true
  fi
  rm -f "$CERT_TIMER_UNIT" "$CERT_RENEW_UNIT" "$CERT_CRON"
  sd_reload
}
cert_name_syntax() {
  local d=${1,,}
  d=${d%.}
  if [[ $d == \*.* ]]; then cert_domain_syntax "${d#\*.}"; return; fi
  cert_domain_syntax "$d"
}
cert_norm_names() {
  local raw=$1 n out=""
  local -a arr=()
  raw=${raw// /}
  raw=${raw,,}
  raw=${raw//，/,}
  IFS=',' read -ra arr <<< "$raw"
  for n in "${arr[@]}"; do
    n=${n%.}
    [[ -n $n ]] || continue
    cert_name_syntax "$n" || return 1
    [[ ",${out}," == *",${n},"* ]] && continue
    out+="${out:+,}${n}"
  done
  [[ -n $out ]] || return 1
  printf '%s' "$out"
}
cert_ensure_apex_for_wild() {
  local names=$1 n parent out
  local -a arr=()
  out=$names
  IFS=',' read -ra arr <<< "$names"
  for n in "${arr[@]}"; do
    [[ $n == \*.* ]] || continue
    parent=${n#\*.}
    [[ ",${out}," == *",${parent},"* ]] && continue
    out="${out},${parent}"
  done
  printf '%s' "$out"
}
cert_link_covered_by_names() {
  local link=$1 names=$2 n parent left
  local -a arr=()
  [[ -n $link && $link != \*.* ]] || return 1
  IFS=',' read -ra arr <<< "$names"
  for n in "${arr[@]}"; do
    [[ $n == "$link" ]] && return 0
    if [[ $n == \*.* ]]; then
      parent=${n#\*.}
      [[ $link == *".${parent}" ]] || continue
      left=${link%".${parent}"}
      [[ -n $left && $left != '*' && $left != *.* ]] && return 0
    fi
  done
  return 1
}
cert_names_json() {
  local n out=""
  local -a arr=()
  IFS=',' read -ra arr <<< "${CERT_NAMES:-}"
  for n in "${arr[@]}"; do
    [[ -n $n ]] || continue
    out+="${out:+,}\"${n}\""
  done
  printf '[%s]' "$out"
}
cert_write_secret() {
  local path=$1 body=$2 old
  mkdir -p "$(dirname "$path")"
  chmod 755 "$CERT_BASE" 2>/dev/null || true
  old=$(umask)
  umask 077
  printf '%s\n' "$body" >"${path}.new"
  umask "$old"
  chmod 600 "${path}.new"
  mv -f "${path}.new" "$path"
}
cert_load_eab() {
  [[ -s $CERT_ZEROSSL_EAB ]] || return 1
  ZEROSSL_KID=$(sed -n 's/^kid=//p' "$CERT_ZEROSSL_EAB" | head -n1)
  ZEROSSL_HMAC=$(sed -n 's/^hmac=//p' "$CERT_ZEROSSL_EAB" | head -n1)
  [[ -n $ZEROSSL_KID && -n $ZEROSSL_HMAC ]]
}
cert_explain() {
  case $1 in
    dns_not_here)
      cat >&2 <<'EOF'
域名没有全部指向这台机器，HTTP-01 不会成功。
Let's Encrypt / ZeroSSL 会从公网访问本机的 80 端口。A 和 AAAA 里只要有一条不是本机，验证就会失败。
若开着橙色云朵，访问会先到 Cloudflare，而不是这台机器。申请和续期时请改成灰色云朵（仅 DNS）。
等解析生效后再试。不要把 REALITY 用来伪装的网站填到这里。REALITY 本身不用改。
EOF
      ;;
    txt_timeout|txt_missing)
      cat >&2 <<'EOF'
DNS-01 没有完成。通配符不能用 HTTP-01，只能靠 TXT 证明你能改这个域名的 DNS。
请检查 _acme-challenge 这条 TXT：
1. 类型是 TXT，云朵必须是灰色。橙色云朵会让 1.1.1.1 和 8.8.8.8 看不到它。
2. 在 Cloudflare 里名称只填 _acme-challenge，不要写成 _acme-challenge.example.com.example.com。
3. 内容不要自己再加一层引号。
4. 通配符会同时要 *.域名 和根域名，这是两条内容不同的 TXT，都要留下，不要互相覆盖。
5. 刚改完可能要等一两分钟。没有 API 令牌时，到期前要再添加一次；想自动续期就重新申请并加上 --cf-dns-token。
REALITY 没有改动。
EOF
      ;;
    dns_token)
      cat >&2 <<'EOF'
Cloudflare 没有接受这个 DNS 令牌。
通配符要用的是 API 令牌，不是源站证书的 Origin CA Key。两把钥匙不能混用。
创建令牌时权限选：Zone → DNS → 编辑，以及 Zone → Zone → 读取。区域选你的域名，或所有区域。
令牌复制错一位、过期、或只给了读取权限，都会在这里失败。到 Cloudflare 控制台重新建一把，用 --cf-dns-token 传入。
脚本不会把令牌写进 state.env。REALITY 没有改动。
EOF
      ;;
    dns_zone)
      cat >&2 <<'EOF'
这个令牌能登录 Cloudflare，但找不到域名所在的区域。
请先把域名添加到这个 Cloudflare 账号，并确认令牌的区域范围包含它。
域名还在别的注册商、或令牌属于另一个账号时，TXT 加不上去。REALITY 没有改动。
EOF
      ;;
    eab)
      cat >&2 <<'EOF'
ZeroSSL 没有接受 EAB 凭据。
打开 https://app.zerossl.com/developer ，生成一对 EAB KID 和 HMAC Key。必须是同一对，不能把两个填反，也不能少一位。
用 --zerossl-kid 和 --zerossl-hmac 一起传入。HMAC 里的 + / = 要原样保留。
这和 Let's Encrypt 不一样：ZeroSSL 的 ACME 注册必须有这对钥匙。凭据放在 /etc/proxy-oneclick/zerossl.eab（权限 600），不写入 state.env。
REALITY 没有改动。
EOF
      ;;
    rate_zero)
      cat >&2 <<'EOF'
ZeroSSL 拒绝签发：这个域名最近申请次数太多。
等限制过去，或换一个还没申请过的名字。这不是 REALITY 的问题，REALITY 不使用这张证书。
EOF
      ;;
    multi_fail)
      cat >&2 <<'EOF'
多域名证书没有签发。名单里只要有一个名字失败，整张证书都不会下来。
请逐个检查：每个名字的 A/AAAA 都指向本机，并且是灰色云朵。橙色云朵期间，验证请求打到 Cloudflare，80 端口对不上。
不能在这张 HTTP-01 证书里写 *.example.com。通配符请改用 wildcard 或 zerossl-wildcard。
REALITY 没有改动。
EOF
      ;;
    origin_auth)
      cat >&2 <<'EOF'
Cloudflare 没有接受这把源站证书钥匙。
要用的是 Origin CA Key：打开 https://dash.cloudflare.com/profile/api-tokens ，拉到页面最下面，复制 Origin CA Key。
这不是普通 API 令牌，也不是用来添加 TXT 的 DNS 令牌。把 DNS 令牌填到 --cf-origin-key 会在这里失败。
用 --cf-origin-key 传入。钥匙只保存在 /etc/proxy-oneclick/cf-origin.key（权限 600）。REALITY 没有改动。
EOF
      ;;
    origin_host)
      cat >&2 <<'EOF'
Cloudflare 没有给这些主机名签发源站证书。
每个名字都必须属于这个 Origin CA Key 所在账号里的某个区域，例如 example.com 或 *.example.com。
域名还没加到 Cloudflare、写错了别的账号的域名、或钥匙属于另一个账号，都会失败。
源站证书只有 Cloudflare 信任。不要拿它给 Hysteria2、TUIC、AnyTLS 或订阅。REALITY 没有改动。
EOF
      ;;
    *)
      cdn_explain cert_fail
      ;;
  esac
}
cert_print_tutorial() {
  echo
  ui_bar '═' 62
  ui_center "证书：$(cert_kind_label)" 62
  ui_bar '─' 62
  case $(cert_kind_id) in
    le)
      cat <<EOF
这张是 Let's Encrypt 单域名证书，也是脚本的默认种类。只包含 ${CERT_DOMAIN}。
适合：订阅 HTTPS，以及 Hysteria2、TUIC、AnyTLS。客户端按正常证书校验，链接改用这个域名，不再使用 insecure 或 pin。
不适合：不能签发 *.${CERT_DOMAIN}。HTTP-01 证明不了通配符。要通配符请改用 wildcard。

申请前：
1. ${CERT_DOMAIN} 的全部 A/AAAA 指向本机。
2. 关掉橙色云朵，改成灰色（仅 DNS）。橙云时验证会打到 Cloudflare，本机 80 收不到。
3. 云安全组放行 TCP 80。80 只在申请和续期时短暂占用，不提供订阅，也不跑代理。
4. 不要占用 REALITY 的端口。REALITY 继续借用伪装站点 ${SNI:-（安装时选的站点）}，配置里不写这张证书。

签好之后：Hysteria2 / TUIC / AnyTLS 出示这张证书。REALITY、XHTTP+REALITY、Trojan 不变。
若另外打开了 CDN 上的 XHTTP+TLS 或 WebSocket+TLS，那两条也用这张证书。
这个名字一旦开了橙色云朵，Hysteria2、TUIC、AnyTLS 和订阅就不能再靠它连接（Cloudflare 不转发 UDP，也不转发订阅端口）。那几条请改用服务器 IP，或另做一个灰色云朵的名字。脚本不会因此改掉 REALITY。
续期由系统定时任务完成，大约 90 天一轮，到期前约 30 天自动续。续期同样需要 80 能从公网访问。
继续即表示同意 Let's Encrypt 服务条款：https://letsencrypt.org/repository/
EOF
      ;;
    zerossl)
      cat <<EOF
这张是 ZeroSSL 单域名证书，公开信任，作用和 Let's Encrypt 单域名一样，只是换了一家 CA。只包含 ${CERT_DOMAIN}。
适合：订阅 HTTPS，以及 Hysteria2、TUIC、AnyTLS。不适合：不能签发通配符。

和 Let's Encrypt 的差别：必须有一对 EAB 凭据。打开 https://app.zerossl.com/developer 生成 EAB KID 和 HMAC Key，用 --zerossl-kid 和 --zerossl-hmac 传入。KID 和 HMAC 必须是同一对。
域名、灰色云朵、TCP 80 的要求和 Let's Encrypt 单域名相同。橙云期间不要申请。
签好之后协议怎么变，也和 Let's Encrypt 单域名相同。REALITY 不变。
建议加上 --cert-email。不填则不登记邮箱；若 ZeroSSL 拒绝注册，补上邮箱再试。
EOF
      ;;
    wildcard|zerossl-wildcard)
      cat <<EOF
这张是通配符证书，名字是 ${CERT_NAMES}。
星号只覆盖一级子域名，不覆盖 a.b.根域名。根域名会单独写上，所以根域名本身也能用。
链接里的主机名是 ${CERT_DOMAIN}。

为什么用 DNS-01：HTTP-01 不能证明你拥有星号开头的名字。不占用 80 端口。
不适合拿来代替 REALITY。REALITY 仍然借用伪装站点，不读这张证书。

DNS 要做的事：
1. 域名放在 Cloudflare。
2. 添加 TXT，名称是 _acme-challenge，云朵必须是灰色。橙色云朵会让公共 DNS 看不到 TXT。
3. 通配符和根域名是两条内容不同的 TXT，都要留下，不要互相覆盖。名称不要写成带两层域名的样子。
4. 有 API 令牌时，脚本自己添加。令牌权限：Zone → DNS → 编辑，以及 Zone → Zone → 读取。这不是 Origin CA Key。用 --cf-dns-token 传入。令牌只放在权限 600 的文件里，不进 state.env，但会出现在进程列表里。
5. 没有令牌时，脚本把要添加的内容打在屏幕上，并等待 1.1.1.1 和 8.8.8.8 能查到。这种方式不能自动续期。

签好之后：这是公开证书。Hysteria2 / TUIC / AnyTLS 改用它，订阅走 HTTPS。REALITY 不变。
若 ${CERT_DOMAIN} 要开橙色云朵给 CDN，直连的 Hysteria2、TUIC、AnyTLS 和订阅不要再用这个名字，请改用服务器 IP，或用 --cert-link 指定一个仍是灰色云朵、且被这张通配符覆盖的子域名。
EOF
      if [[ $(cert_kind_id) == zerossl-wildcard ]]; then
        echo "签发机构是 ZeroSSL，还需要 https://app.zerossl.com/developer 的 EAB KID 和 HMAC。公开信任，客户端不用改校验方式。"
      else
        echo "签发机构是 Let's Encrypt。继续即表示同意其服务条款：https://letsencrypt.org/repository/"
      fi
      ;;
    multi|zerossl-multi)
      cat <<EOF
这张证书上有多个名字：${CERT_NAMES}。链接和订阅使用 ${CERT_DOMAIN}。
适合：几个主机名共用一张公开证书，给订阅 HTTPS 以及 Hysteria2、TUIC、AnyTLS。
不适合：不能写 *.域名。通配符请改用 wildcard。REALITY 不用这张证书。

每个名字都要满足：
1. A/AAAA 全部指向本机。有一个不对，整张证书都失败。
2. 申请时是灰色云朵。橙色云朵会把验证请求带到 Cloudflare。
3. 云安全组放行 TCP 80。不改 REALITY 的端口。

签好之后协议变化与单域名公开证书相同。续期同样走 HTTP-01。
EOF
      if [[ $(cert_kind_id) == zerossl-multi ]]; then
        echo "签发机构是 ZeroSSL，需要成对的 EAB KID 和 HMAC（https://app.zerossl.com/developer）。"
      else
        echo "签发机构是 Let's Encrypt。继续即表示同意其服务条款：https://letsencrypt.org/repository/"
      fi
      ;;
    cf-origin)
      cat <<EOF
这是 Cloudflare 源站证书，名字是 ${CERT_NAMES}。CDN 链接使用 ${CERT_DOMAIN}。
只有 Cloudflare 信任它。浏览器直接打开会报不安全。Hysteria2、TUIC、AnyTLS 的客户端会拒绝。订阅 HTTPS 也不能用它。
只适合两条 CDN 线路：XHTTP+TLS 和 WebSocket+TLS，并且域名开着橙色云朵，加密模式选「完全（严格）」。
不要用于 Hysteria2、TUIC、AnyTLS、订阅，也不要用于 REALITY。脚本不会把这张证书装进那三个协议，也不会打开订阅。它们继续用自签证书或服务器 IP。

申请步骤：
1. 域名已经在这个 Cloudflare 账号里。
2. 打开 https://dash.cloudflare.com/profile/api-tokens ，拉到最下面，复制 Origin CA Key。
3. 这不是普通 API 令牌，也不是添加 TXT 用的 DNS 令牌。用 --cf-origin-key 传入。
4. 不需要开放 80，也不走 certbot。有效期大约 15 年，不会自动续期。要换种类，先关掉这张再申请另一种。
5. 主机名必须属于你的区域。写了 *.根域名 时，脚本会把根域名一并放进证书。*.根域名 不覆盖二级名字，例如 a.b.根域名。

签好之后：REALITY 的端口、密钥和伪装站点都不变。
若 CDN 线路已经打开，会改用这张证书。还没打开的话，到协议开关里打开 XHTTP+TLS 或 WebSocket+TLS。不要把 REALITY 放进橙色云朵后面。
EOF
      ;;
  esac
  ui_bar '═' 62
  echo
}
cert_need_domain_die() {
  case ${PLAN_KIND:-le} in
    wildcard|zerossl-wildcard)
      die "通配符证书需要根域名。例如：--cert-kind ${PLAN_KIND} --cert-domain example.com（会申请 *.example.com 和 example.com）。HTTP-01 做不到通配符。REALITY 未改动。" ;;
    multi|zerossl-multi)
      die "多域名证书需要 --cert-names a.example.com,b.example.com。每个名字都要解析到本机。REALITY 未改动。" ;;
    cf-origin)
      die "Cloudflare 源站证书需要 --cert-domain 或 --cert-names，以及 --cf-origin-key。例如 --cert-kind cf-origin --cf-origin-key <钥匙> --cert-domain cdn.example.com。REALITY 未改动。" ;;
    *)
      die "申请证书需要 --cert-domain <域名>。REALITY 未改动。" ;;
  esac
}
cert_require_eab() {
  local kid="" hmac=""
  if [[ -n ${OPT_ZEROSSL_KID:-} || -n ${OPT_ZEROSSL_HMAC:-} ]]; then
    if [[ -z ${OPT_ZEROSSL_KID:-} || -z ${OPT_ZEROSSL_HMAC:-} ]]; then
      cert_explain eab
      die "ZeroSSL 的 EAB 要成对提供。REALITY 未改动。"
    fi
    cert_write_secret "$CERT_ZEROSSL_EAB" "kid=${OPT_ZEROSSL_KID}"$'\n'"hmac=${OPT_ZEROSSL_HMAC}"
    return 0
  fi
  cert_load_eab && return 0
  if (( OPT_AUTO )); then
    cert_explain eab
    die "自动申请 ZeroSSL 需要 --zerossl-kid 和 --zerossl-hmac。REALITY 未改动。"
  fi
  cert_explain eab
  ask kid "ZeroSSL EAB KID" ""
  ask hmac "ZeroSSL EAB HMAC Key" ""
  if [[ -z $kid || -z $hmac ]]; then die "没有 EAB 凭据，已取消。REALITY 未改动。"; fi
  cert_write_secret "$CERT_ZEROSSL_EAB" "kid=${kid}"$'\n'"hmac=${hmac}"
}
cert_require_dns_token() {
  local tok=""
  if [[ -n ${OPT_CF_DNS_TOKEN:-} ]]; then
    cert_write_secret "$CERT_DNS_TOKEN" "$OPT_CF_DNS_TOKEN"
    return 0
  fi
  if [[ -s $CERT_DNS_TOKEN ]]; then return 0; fi
  if (( OPT_AUTO )); then
    cert_explain dns_token
    die "自动申请通配符需要 --cf-dns-token。没有令牌时无法自己添加 TXT。REALITY 未改动。"
  fi
  if confirm "是否已有 Cloudflare API 令牌，让脚本自动添加 TXT？选否会把记录内容打在屏幕上，等你手工添加。" y; then
    ask tok "Cloudflare API 令牌（Zone.DNS 编辑 + Zone 读取，不是 Origin CA Key）" ""
    if [[ -z $tok ]]; then die "没有令牌，已取消。REALITY 未改动。"; fi
    cert_write_secret "$CERT_DNS_TOKEN" "$tok"
  else
    info "改为手工 TXT。记录必须是灰色云朵。这次不保存令牌，以后不能自动续期。"
  fi
}
cert_require_origin_key() {
  local k=""
  if [[ -n ${OPT_CF_ORIGIN_KEY:-} ]]; then
    cert_write_secret "$CERT_ORIGIN_KEY" "$OPT_CF_ORIGIN_KEY"
    return 0
  fi
  if [[ -s $CERT_ORIGIN_KEY ]]; then return 0; fi
  if (( OPT_AUTO )); then
    cert_explain origin_auth
    die "自动申请源站证书需要 --cf-origin-key。这是 Origin CA Key，不是 DNS 令牌。REALITY 未改动。"
  fi
  cert_explain origin_auth
  ask k "Cloudflare Origin CA Key" ""
  if [[ -z $k ]]; then die "没有 Origin CA Key，已取消。REALITY 未改动。"; fi
  cert_write_secret "$CERT_ORIGIN_KEY" "$k"
}
cert_plan_single() {
  local d=${OPT_CERT_DOMAIN:-} def=""
  if [[ -z $d && -n ${OPT_CERT_NAMES:-} && ${OPT_CERT_NAMES} != *,* && ${OPT_CERT_NAMES} != \*.* ]]; then d=$OPT_CERT_NAMES; fi
  if [[ -z $d && -n ${CERT_DOMAIN:-} ]]; then def=$CERT_DOMAIN; fi
  while :; do
    if [[ -z $d ]]; then
      (( OPT_AUTO )) && cert_need_domain_die
      ask d "域名（已解析到本机，例如 example.com）" "$def"
      d=${d,,}; d=${d%.}; d=${d// /}
    fi
    if ! cert_domain_syntax "$d"; then
      warn "域名无效: ${d:-空}。需要像 example.com 这样的域名，不能是 IP。"
      { (( OPT_AUTO )) || [[ -n ${OPT_CERT_DOMAIN:-} ]]; } && die "域名无效，已取消申请证书。REALITY 未改动。"
      d=""; OPT_CERT_DOMAIN=""; continue
    fi
    [[ -n ${PUBLIC_IP4:-} || -n ${PUBLIC_IP6:-} ]] || detect_ip
    if cert_domain_points_here "$d"; then break; fi
    cert_explain dns_not_here
    { (( OPT_AUTO )) || [[ -n ${OPT_CERT_DOMAIN:-} ]]; } && die "域名 ${d} 没有全部解析到本机，已取消申请证书。REALITY 未改动。"
    confirm "重新填写域名？" y || die "已取消申请证书。REALITY 未改动。"
    d=""; OPT_CERT_DOMAIN=""
  done
  PLAN_DOMAIN=$d
  PLAN_NAMES=$d
}
cert_plan_wildcard() {
  local apex=${OPT_CERT_DOMAIN:-} link=${OPT_CERT_LINK:-} def=""
  if [[ -z $apex && -n ${CERT_DOMAIN:-} && ${CERT_DOMAIN} != \*.* ]]; then def=$CERT_DOMAIN; fi
  while :; do
    if [[ -z $apex ]]; then
      (( OPT_AUTO )) && cert_need_domain_die
      ask apex "根域名（例如 example.com，将申请 *.example.com 和 example.com）" "$def"
      apex=${apex,,}; apex=${apex%.}; apex=${apex// /}
      apex=${apex#\*.}
    fi
    if ! cert_domain_syntax "$apex"; then
      warn "根域名无效: ${apex:-空}。请写 example.com，不要写成 *.example.com。"
      { (( OPT_AUTO )) || [[ -n ${OPT_CERT_DOMAIN:-} ]]; } && die "根域名无效。REALITY 未改动。"
      apex=""; OPT_CERT_DOMAIN=""; continue
    fi
    break
  done
  PLAN_NAMES="*.${apex},${apex}"
  if [[ -z $link ]]; then link=$apex; else link=${link,,}; link=${link%.}; fi
  if ! cert_link_covered_by_names "$link" "$PLAN_NAMES"; then
    die "链接用的名字 ${link} 不在这张通配符证书里。*.${apex} 只覆盖一级子域名。根域名已经包含在内。请改 --cert-link，或留空用 ${apex}。REALITY 未改动。"
  fi
  PLAN_DOMAIN=$link
  info "通配符证书包含 ${PLAN_NAMES}。客户端链接使用 ${PLAN_DOMAIN}。DNS-01 不要求 A 记录已经指向本机，也不占用 80。"
}
cert_plan_multi() {
  local raw=${OPT_CERT_NAMES:-} names="" n link="" failed=0
  local -a arr=()
  while :; do
    if [[ -z $raw ]]; then
      (( OPT_AUTO )) && cert_need_domain_die
      ask raw "多个域名，逗号分隔（每个都必须解析到本机）" "${CERT_NAMES:-}"
    fi
    if ! names=$(cert_norm_names "$raw"); then
      warn "域名列表无效。例如 a.example.com,b.example.com。不能写 IP，也不能写 *.example.com。"
      { (( OPT_AUTO )) || [[ -n ${OPT_CERT_NAMES:-} ]]; } && die "多域名列表无效。REALITY 未改动。"
      raw=""; OPT_CERT_NAMES=""; continue
    fi
    if [[ $names == *'*'* ]]; then
      die "多域名的 HTTP-01 不能包含通配符。请改用 --cert-kind wildcard。REALITY 未改动。"
    fi
    if [[ $names != *,* ]]; then
      warn "多域名至少要两个名字。只有一个时用单域名即可。"
      { (( OPT_AUTO )) || [[ -n ${OPT_CERT_NAMES:-} ]]; } && die "多域名至少两个名字。REALITY 未改动。"
      raw=""; OPT_CERT_NAMES=""; continue
    fi
    break
  done
  [[ -n ${PUBLIC_IP4:-} || -n ${PUBLIC_IP6:-} ]] || detect_ip
  IFS=',' read -ra arr <<< "$names"
  for n in "${arr[@]}"; do
    cert_domain_points_here "$n" || failed=1
  done
  if (( failed )); then
    cert_explain dns_not_here
    die "上面有域名没有全部解析到本机，多域名证书没有申请。REALITY 未改动。"
  fi
  link=${OPT_CERT_LINK:-}
  [[ -n $link ]] || link=${OPT_CERT_DOMAIN:-}
  [[ -n $link ]] || link=${names%%,*}
  link=${link,,}; link=${link%.}
  if [[ ",${names}," != *",${link},"* ]]; then
    die "链接主机名 ${link} 不在名单里。它必须是证书上的其中一个名字。REALITY 未改动。"
  fi
  PLAN_NAMES=$names
  PLAN_DOMAIN=$link
}
cert_plan_origin() {
  local raw=${OPT_CERT_NAMES:-} names="" link="" n
  local -a arr=()
  if [[ -z $raw && -n ${OPT_CERT_DOMAIN:-} ]]; then raw=$OPT_CERT_DOMAIN; fi
  while :; do
    if [[ -z $raw ]]; then
      (( OPT_AUTO )) && cert_need_domain_die
      ask raw "源站证书上的名字（cdn.example.com，或 *.example.com,example.com）" "${CERT_NAMES:-${CERT_DOMAIN:-}}"
    fi
    if ! names=$(cert_norm_names "$raw"); then
      warn "名字无效。可以写 cdn.example.com，或 *.example.com。"
      { (( OPT_AUTO )) || [[ -n ${OPT_CERT_NAMES:-} || -n ${OPT_CERT_DOMAIN:-} ]]; } && die "源站证书的域名无效。REALITY 未改动。"
      raw=""; continue
    fi
    break
  done
  names=$(cert_ensure_apex_for_wild "$names")
  link=${OPT_CERT_LINK:-}
  if [[ -z $link && -n ${OPT_CERT_DOMAIN:-} && ${OPT_CERT_DOMAIN} != \*.* ]]; then link=$OPT_CERT_DOMAIN; fi
  if [[ -z $link ]]; then
    IFS=',' read -ra arr <<< "$names"
    for n in "${arr[@]}"; do
      [[ $n == \*.* ]] && continue
      link=$n
      break
    done
  fi
  link=${link,,}; link=${link%.}
  if [[ -z $link || $link == \*.* ]]; then
    die "源站证书需要一个具体主机名给 CDN 链接使用。加上 --cert-link cdn.example.com，或把根域名也写上。REALITY 未改动。"
  fi
  if ! cert_link_covered_by_names "$link" "$names"; then
    die "链接主机名 ${link} 不在源站证书的名字里。REALITY 未改动。"
  fi
  PLAN_NAMES=$names
  PLAN_DOMAIN=$link
  info "源站证书只给 CDN。Hysteria2 / TUIC / AnyTLS / 订阅不会使用它。不检查这个名字是否解析到本机（橙色云朵时解析到的是 Cloudflare）。"
}
cert_plan_existing() {
  # 重装或再次进入申请、但没有指定新种类时，沿用已经保存的种类和名字。
  local kind n failed=0
  local -a arr=()
  kind=$(cert_kind_id)
  PLAN_KIND=$kind
  PLAN_DOMAIN=$CERT_DOMAIN
  if [[ -n ${CERT_NAMES:-} ]]; then PLAN_NAMES=$CERT_NAMES
  elif [[ ${CERT_SCOPE:-single} == wildcard ]]; then PLAN_NAMES="*.${CERT_DOMAIN},${CERT_DOMAIN}"
  else PLAN_NAMES=$CERT_DOMAIN; fi
  if cert_current_ok; then return 0; fi
  case $kind in
    le|zerossl|multi|zerossl-multi)
      [[ -n ${PUBLIC_IP4:-} || -n ${PUBLIC_IP6:-} ]] || detect_ip
      IFS=',' read -ra arr <<< "$PLAN_NAMES"
      for n in "${arr[@]}"; do cert_domain_points_here "$n" || failed=1; done
      if (( failed )); then
        cert_explain dns_not_here
        die "原来的证书需要重新申请，但有域名没有全部解析到本机。REALITY 未改动。"
      fi
      ;;
  esac
  case $kind in
    zerossl|zerossl-wildcard|zerossl-multi) cert_require_eab ;;
  esac
  case $kind in
    wildcard|zerossl-wildcard) cert_require_dns_token ;;
  esac
  if [[ $kind == cf-origin ]]; then cert_require_origin_key; fi
}
cert_plan_request() {
  local kind=""
  PLAN_KIND="" PLAN_DOMAIN="" PLAN_NAMES=""
  if [[ -n ${OPT_CF_ORIGIN_KEY:-} && -z ${OPT_CERT_KIND:-} ]]; then OPT_CERT_KIND=cf-origin; fi
  if [[ -n ${OPT_ZEROSSL_KID:-}${OPT_ZEROSSL_HMAC:-} && -z ${OPT_CERT_KIND:-} ]]; then OPT_CERT_KIND=zerossl; fi
  if [[ -z ${OPT_CERT_KIND:-} && -z ${OPT_CERT_DOMAIN:-} && -z ${OPT_CERT_NAMES:-} && -z ${OPT_CERT_LINK:-} ]] \
     && (( ${CERT_ON:-0} == 1 )) && [[ -n ${CERT_DOMAIN:-} ]]; then
    cert_plan_existing
    return 0
  fi
  if [[ -n ${OPT_CERT_KIND:-} ]]; then
    kind=$(cert_normalize_kind "$OPT_CERT_KIND") || die "不认识的证书种类: ${OPT_CERT_KIND}。可选 le、wildcard、multi、zerossl、zerossl-wildcard、zerossl-multi、cf-origin。"
  elif [[ ${OPT_CERT_NAMES:-} == *,* ]]; then kind=multi
  else kind=le; fi
  PLAN_KIND=$kind
  if [[ -n ${OPT_CERT_EMAIL:-} ]]; then CERT_EMAIL=$OPT_CERT_EMAIL; fi
  if [[ -n ${CERT_EMAIL:-} ]] && ! cert_email_syntax "$CERT_EMAIL"; then
    die "邮箱格式无效: ${CERT_EMAIL}"
  fi
  case $kind in
    le|zerossl) cert_plan_single ;;
    wildcard|zerossl-wildcard) cert_plan_wildcard ;;
    multi|zerossl-multi) cert_plan_multi ;;
    cf-origin) cert_plan_origin ;;
  esac
  case $kind in
    zerossl|zerossl-wildcard|zerossl-multi) cert_require_eab ;;
  esac
  case $kind in
    wildcard|zerossl-wildcard) cert_require_dns_token ;;
  esac
  if [[ $kind == cf-origin ]]; then cert_require_origin_key; fi
}
cert_switch_needed() {
  (( ${CERT_ON:-0} == 1 )) || return 1
  [[ -s $CERT_FULLCHAIN || -d /etc/letsencrypt/live/${CERT_NAME} ]] || return 1
  [[ $(cert_kind_id) != "$PLAN_KIND" ]]
}
cert_retire_for_switch() {
  info "正在关闭当前证书，随后申请另一种。REALITY 的端口、密钥和伪装站点都不变。"
  svc_disable_stop proxy-oneclick-sub || true
  cert_drop_renew_job
  if have certbot; then certbot delete --cert-name "$CERT_NAME" --non-interactive >/dev/null 2>&1 || true; fi
  rm -f "$CERT_FULLCHAIN" "$CERT_PRIVKEY" "$SUB_CONF" "$SUB_BODY" "$SUB_CLASH" "$XRAY_CERT_FULL" "$XRAY_CERT_KEY"
  CERT_ON=0
  if (( HY2_ENABLED )) && [[ -x $HY_BIN ]]; then
    gen_hy2_cert
    write_hy2_config
    restart_hy2
  fi
  if sb_needed && [[ -x $SB_BIN ]]; then
    write_singbox_config
    restart_singbox
  fi
  if cdn_wanted && [[ -x $XRAY_BIN ]] && xray_inbound_needed; then
    write_xray_config
    restart_xray
  fi
  if (( ! NAT_MODE && ${FW_ENABLED:-0} == 1 )); then apply_firewall; fi
  save_state
  ok "旧证书已关闭。CDN 线路的开关还留着，但在新证书签下来之前不会监听。REALITY 仍在原来的端口上。"
}
cert_ensure_dig() {
  have dig && return 0
  if [[ ${PKG:-} == apk ]]; then pkg_try bind-tools
  elif [[ ${PKG:-} == apt ]]; then
    pkg_try dnsutils
    have dig || pkg_try bind9-dnsutils
  else
    pkg_try bind-utils
  fi
  have dig || die "需要 dig 来确认 TXT。Debian/Ubuntu 安装 dnsutils 或 bind9-dnsutils，RHEL 安装 bind-utils，Alpine 安装 bind-tools。装好后重试。REALITY 未改动。"
}
write_dns_hooks() {
  mkdir -p "$CERT_LIB" "$CERT_TXT_DIR"
  chmod 700 "$CERT_TXT_DIR" 2>/dev/null || true
  cat >"$CERT_DNS_AUTH" <<'EOF'
#!/bin/sh
# 由 proxy-oneclick 生成。certbot DNS-01 时调用。不打印令牌。
set -u
token_file="__TOKEN__"
txt_dir="__TXTDIR__"
dom="${CERTBOT_DOMAIN:-}"
val="${CERTBOT_VALIDATION:-}"
say() { printf '%s\n' "$1" >&2; }
if [ -z "$dom" ] || [ -z "$val" ]; then
  say "acme-dns-auth-failed 缺少域名或校验值。"
  exit 1
fi
name="_acme-challenge.${dom}"
mkdir -p "$txt_dir"
chmod 700 "$txt_dir" 2>/dev/null || true
poll_txt() {
  if ! command -v dig >/dev/null 2>&1; then
    say "acme-txt-timeout 本机没有 dig，无法向 1.1.1.1 和 8.8.8.8 确认 TXT。请安装 dnsutils、bind9-dnsutils 或 bind-utils 后重试。"
    exit 1
  fi
  i=0
  while [ "$i" -lt 30 ]; do
    got=$( { dig +short TXT "$name" @1.1.1.1; dig +short TXT "$name" @8.8.8.8; } 2>/dev/null || true)
    if printf '%s\n' "$got" | grep -F -q -- "$val"; then sleep 15; return 0; fi
    i=$((i + 1))
    sleep 10
  done
  say "acme-txt-timeout"
  say "公共 DNS 大约五分钟内没有看到 ${name} 的 TXT。请确认为灰色云朵，名称只填 _acme-challenge，内容不要额外加引号。通配符的两条 TXT 都要留下。"
  say "$val"
  return 1
}
if [ -s "$token_file" ]; then
  command -v curl >/dev/null 2>&1 || { say "acme-dns-auth-failed 没有 curl。"; exit 1; }
  command -v jq >/dev/null 2>&1 || { say "acme-dns-auth-failed 没有 jq。"; exit 1; }
  token=$(cat "$token_file")
  token=$(printf '%s' "$token" | tr -d '\r\n ')
  host=$dom
  zone=""
  while :; do
    resp=$(curl -sS -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" "https://api.cloudflare.com/client/v4/zones?name=${host}" || true)
    ok=$(printf '%s' "$resp" | jq -r '.success // false' 2>/dev/null || echo false)
    if [ "$ok" != "true" ]; then
      say "acme-dns-auth-failed"
      say "Cloudflare 拒绝了这个 API 令牌。请使用 Zone.DNS 编辑和 Zone 读取权限的令牌，不要使用 Origin CA Key。"
      printf '%s' "$resp" | jq -r '.errors[]? | "\(.code) \(.message)"' >&2 || true
      exit 1
    fi
    zone=$(printf '%s' "$resp" | jq -r '.result[0].id // empty')
    if [ -n "$zone" ]; then break; fi
    case "$host" in
      *.*) host=${host#*.} ;;
      *) break ;;
    esac
  done
  if [ -z "$zone" ]; then
    say "acme-dns-zone-missing"
    say "找不到 ${dom} 所在的 Cloudflare 区域。请先把域名加到这个账号，并让令牌能看这个区域。"
    exit 1
  fi
  body=$(jq -n --arg name "$name" --arg content "$val" '{type:"TXT",name:$name,content:$content,ttl:60}')
  resp=$(curl -sS -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" --data "$body" "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records" || true)
  id=$(printf '%s' "$resp" | jq -r '.result.id // empty')
  if [ -z "$id" ]; then
    say "acme-dns-auth-failed"
    say "TXT 没有添加成功。若是认证错误，就是令牌不对，或误用了 Origin CA Key。"
    printf '%s' "$resp" | jq -r '.errors[]? | "\(.code) \(.message)"' >&2 || true
    exit 1
  fi
  hash=$(printf '%s' "$val" | sha256sum | awk '{print $1}')
  printf '%s\n' "$id" > "${txt_dir}/${hash}"
  printf '%s\n' "$zone" > "${txt_dir}/${hash}.zone"
  chmod 600 "${txt_dir}/${hash}" "${txt_dir}/${hash}.zone" 2>/dev/null || true
  say "已添加 TXT：${name} 。等待公共 DNS。通配符的另一条会再添加一次，不要删掉这一条。"
  poll_txt
else
  say "请手工添加 DNS TXT（灰色云朵，仅 DNS）："
  say "  名称: _acme-challenge"
  say "  完整名字: ${name}"
  say "  内容: ${val}"
  say "通配符会有两条不同内容，都要保留。添加后保持这个窗口，脚本会自己复查。"
  poll_txt
fi
EOF
  cat >"$CERT_DNS_CLEAN" <<'EOF'
#!/bin/sh
set -u
token_file="__TOKEN__"
txt_dir="__TXTDIR__"
val="${CERTBOT_VALIDATION:-}"
[ -n "$val" ] || exit 0
hash=$(printf '%s' "$val" | sha256sum | awk '{print $1}')
id=""
zone=""
[ -f "${txt_dir}/${hash}" ] && id=$(cat "${txt_dir}/${hash}")
[ -f "${txt_dir}/${hash}.zone" ] && zone=$(cat "${txt_dir}/${hash}.zone")
if [ -n "$id" ] && [ -n "$zone" ] && [ -s "$token_file" ] && command -v curl >/dev/null 2>&1; then
  token=$(cat "$token_file")
  token=$(printf '%s' "$token" | tr -d '\r\n ')
  curl -sS -X DELETE -H "Authorization: Bearer ${token}" "https://api.cloudflare.com/client/v4/zones/${zone}/dns_records/${id}" >/dev/null 2>&1 || true
fi
rm -f "${txt_dir}/${hash}" "${txt_dir}/${hash}.zone"
exit 0
EOF
  sed -i "s|__TOKEN__|${CERT_DNS_TOKEN}|g; s|__TXTDIR__|${CERT_TXT_DIR}|g" "$CERT_DNS_AUTH" "$CERT_DNS_CLEAN"
  chmod 755 "$CERT_DNS_AUTH" "$CERT_DNS_CLEAN"
}
cert_origin_root_pem() {
  cat <<'PEM'
-----BEGIN CERTIFICATE-----
MIICiTCCAi6gAwIBAgIUXZP3MWb8MKwBE1Qbawsp1sfA/Y4wCgYIKoZIzj0EAwIw
gY8xCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpDYWxpZm9ybmlhMRYwFAYDVQQHEw1T
YW4gRnJhbmNpc2NvMRkwFwYDVQQKExBDbG91ZEZsYXJlLCBJbmMuMTgwNgYDVQQL
Ey9DbG91ZEZsYXJlIE9yaWdpbiBTU0wgRUNDIENlcnRpZmljYXRlIEF1dGhvcml0
eTAeFw0xOTA4MjMyMTA4MDBaFw0yOTA4MTUxNzAwMDBaMIGPMQswCQYDVQQGEwJV
UzETMBEGA1UECBMKQ2FsaWZvcm5pYTEWMBQGA1UEBxMNU2FuIEZyYW5jaXNjbzEZ
MBcGA1UEChMQQ2xvdWRGbGFyZSwgSW5jLjE4MDYGA1UECxMvQ2xvdWRGbGFyZSBP
cmlnaW4gU1NMIEVDQyBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkwWTATBgcqhkjOPQIB
BggqhkjOPQMBBwNCAASR+sGALuaGshnUbcxKry+0LEXZ4NY6JUAtSeA6g87K3jaA
xpIg9G50PokpfWkhbarLfpcZu0UAoYy2su0EhN7wo2YwZDAOBgNVHQ8BAf8EBAMC
AQYwEgYDVR0TAQH/BAgwBgEB/wIBAjAdBgNVHQ4EFgQUhTBdOypw1O3VkmcH/es5
tBoOOKcwHwYDVR0jBBgwFoAUhTBdOypw1O3VkmcH/es5tBoOOKcwCgYIKoZIzj0E
AwIDSQAwRgIhAKilfntP2ILGZjwajktkBtXE1pB4Y/fjAfLkIRUzrI15AiEA5UCL
XYZZ9m2c3fKwIenMMojL1eqydsgqj/wK4p5kagQ=
-----END CERTIFICATE-----
PEM
}
cert_issue_origin() {
  local key csr body resp ok cert san n okey elow
  local -a arr=()
  mktmp
  key="${TMP_DIR}/origin.key"
  csr="${TMP_DIR}/origin.csr"
  san=""
  IFS=',' read -ra arr <<< "$CERT_NAMES"
  for n in "${arr[@]}"; do
    [[ -n $n ]] || continue
    san+="${san:+,}DNS:${n}"
  done
  if ! openssl ecparam -name prime256v1 -genkey -noout -out "$key" 2>"${TMP_DIR}/origin.err"; then
    die "没能在本机生成源站证书的私钥。REALITY 未改动。"
  fi
  if ! openssl req -new -key "$key" -subj "/CN=${CERT_DOMAIN}" -addext "subjectAltName=${san}" -out "$csr" 2>>"${TMP_DIR}/origin.err"; then
    die "没能生成证书请求。REALITY 未改动。"
  fi
  have curl || die "需要 curl 才能向 Cloudflare 申请源站证书。REALITY 未改动。"
  have jq || die "需要 jq 才能读取 Cloudflare 的返回。REALITY 未改动。"
  okey=$(<"$CERT_ORIGIN_KEY")
  okey=${okey//$'\r'/}
  okey=${okey//$'\n'/}
  okey=${okey// /}
  body=$(jq -n --rawfile csr "$csr" --argjson hosts "$(cert_names_json)" \
    '{hostnames:$hosts, requested_validity:5475, request_type:"origin-ecc", csr:$csr}')
  resp=$(curl -sS -X POST "$CF_ORIGIN_API" \
    -H "Content-Type: application/json" \
    -H "X-Auth-User-Service-Key: ${okey}" \
    --data "$body" 2>"${TMP_DIR}/origin.err" || true)
  printf '%s\n' "$resp" >"${TMP_DIR}/origin.json"
  ok=$(jq -r '.success // false' <<<"$resp" 2>/dev/null || echo false)
  if [[ $ok != true ]]; then
    jq -r '.errors[]? | "\(.code) \(.message)"' <<<"$resp" >&2 || true
    elow=$(tr '[:upper:]' '[:lower:]' <<<"$resp" 2>/dev/null || true)
    if [[ $elow == *authentication* || $elow == *'10000'* || $elow == *unauthorized* || $elow == *'invalid request headers'* || $elow == *'9109'* || -z $resp ]]; then
      printf '\ncf-origin-auth\n' >>"${TMP_DIR}/origin.json"
      cert_explain origin_auth
    else
      printf '\ncf-origin-host\n' >>"${TMP_DIR}/origin.json"
      cert_explain origin_host
    fi
    die "Cloudflare 没有签发源站证书。REALITY 未改动。"
  fi
  cert=$(jq -r '.result.certificate // empty' <<<"$resp")
  if [[ $cert != *'BEGIN CERTIFICATE'* ]]; then
    cert_explain origin_host
    die "Cloudflare 的返回里没有证书。REALITY 未改动。"
  fi
  cert_grant_readers
  mkdir -p "$CERT_DIR"
  {
    printf '%s\n' "$cert"
    cert_origin_root_pem
  } >"${CERT_FULLCHAIN}.new"
  cp -f "$key" "${CERT_PRIVKEY}.new"
  chown "root:${CERT_GROUP}" "${CERT_FULLCHAIN}.new" "${CERT_PRIVKEY}.new"
  chmod 644 "${CERT_FULLCHAIN}.new"
  chmod 640 "${CERT_PRIVKEY}.new"
  mv -f "${CERT_FULLCHAIN}.new" "$CERT_FULLCHAIN"
  mv -f "${CERT_PRIVKEY}.new" "$CERT_PRIVKEY"
  chmod 755 "$CERT_BASE" 2>/dev/null || true
  chmod 750 "$CERT_DIR"
  chown "root:${CERT_GROUP}" "$CERT_DIR"
  if ! cert_san_ok "$CERT_FULLCHAIN"; then
    cert_explain origin_host
    die "签下来的源站证书里没有 ${CERT_DOMAIN}。REALITY 未改动。"
  fi
  ok "Cloudflare 源站证书已保存。只有 Cloudflare 信任它。"
}
cert_issue_flow() {
  step "申请证书"
  local old_label switching=0
  local keep_ca keep_scope keep_pub keep_ch keep_names keep_dom
  old_label=$(cert_kind_label)
  cert_plan_request
  cert_switch_needed && switching=1
  cert_kind_apply "$PLAN_KIND"
  CERT_NAMES=$PLAN_NAMES
  CERT_DOMAIN=$PLAN_DOMAIN
  cert_normalize_domain
  keep_ca=$CERT_CA
  keep_scope=$CERT_SCOPE
  keep_pub=$CERT_PUBLIC
  keep_ch=$CERT_CHALLENGE
  keep_names=$CERT_NAMES
  keep_dom=$CERT_DOMAIN
  if (( ! switching )) && cert_current_ok; then
    info "证书仍有效（${CERT_DOMAIN}，到期 $(cert_expiry_text)），跳过重新申请。"
    if [[ $CERT_CA != cloudflare && -n ${OPT_SUB_PORT:-} ]]; then choose_sub_port; fi
  else
    cert_print_tutorial
    if (( ! OPT_AUTO )); then
      if (( switching )); then
        confirm "将关闭现在的${old_label}，再申请$(cert_kind_label)。Hysteria2 / TUIC / AnyTLS 会先改回自签。已经打开的 CDN 线路会先停掉监听，新证书签好后再挂上，开关本身保留。请先按上面的说明准备好。REALITY 不变。输入 y 继续。" n \
          || die "已取消。原来的证书还在。REALITY 未改动。"
      else
        confirm "请先按上面的说明准备好，再继续申请。选 n 取消。REALITY 不变。" y \
          || die "已取消。REALITY 未改动。"
      fi
    elif (( switching )); then
      info "证书种类从 ${old_label} 换成 $(cert_kind_label)。先关闭旧证书再申请。REALITY 不变。"
    fi
    if (( switching )); then cert_retire_for_switch; fi
    CERT_CA=$keep_ca
    CERT_SCOPE=$keep_scope
    CERT_PUBLIC=$keep_pub
    CERT_CHALLENGE=$keep_ch
    CERT_NAMES=$keep_names
    CERT_DOMAIN=$keep_dom
    if [[ $CERT_CA != cloudflare ]]; then
      choose_sub_port
      [[ -n $SUB_TOKEN ]] || SUB_TOKEN=$(rand_hex 16)
    fi
    if [[ $CERT_CA == cloudflare ]]; then
      cert_issue_origin
    else
      install_certbot_pkg
      write_cert_helpers
      if [[ $CERT_CHALLENGE == http ]]; then
        cert_allow_80_now
        if port_in_use tcp 80; then
          cdn_explain port80 "$(port_owner tcp 80)"
          die "80 端口被占用，证书没有申请。REALITY 的端口没有改。"
        fi
      else
        cert_ensure_dig
        write_dns_hooks
      fi
      certbot_issue
    fi
  fi
  cert_install_material
  CERT_ON=1
  if [[ $CERT_CA == cloudflare ]]; then
    svc_disable_stop proxy-oneclick-sub || true
    cert_drop_renew_job
    if ! cdn_wanted; then
      info "源站证书还不会被任何协议使用。请到协议开关打开 XHTTP+TLS 或 WebSocket+TLS。不要把它用于 Hysteria2、TUIC、AnyTLS 或订阅。"
    fi
  else
    cert_write_sub_conf
    cert_write_bodies
  fi
  save_state
  ok "证书已就绪：$(cert_kind_label) ${CERT_DOMAIN}"
}
cert_refresh_cdn() {
  cdn_wanted || return 0
  tls_for_cdn || return 0
  cdn_install_xray_certs || warn "证书已就绪，但没能交给 Xray。REALITY 没有改用这张证书。"
  cdn_sync_flag
  if [[ -d $CERT_LIB || -f $CERT_HOOK ]]; then write_cert_hook; fi
  if [[ -x $XRAY_BIN ]] && xray_inbound_needed; then
    write_xray_config
    restart_xray
  fi
}
cert_after_issue() {
  cert_rewire_protocols
  if (( FW_ENABLED )); then apply_firewall; fi
  cert_start_sub
  cert_refresh_cdn
  save_state
  if (( INSTALLED )); then save_info || true; show_info; fi
}

cert_rewire_protocols() {
  # 只改能出示这张证书的协议。不调用 write_xray_config，REALITY 继续借用伪装站点。
  if (( HY2_ENABLED )) && [[ -x $HY_BIN ]]; then
    write_hy2_config
    restart_hy2
  fi
  if sb_needed && [[ -x $SB_BIN ]]; then
    write_singbox_config
    restart_singbox
  fi
}
cert_turn_off() {
  local quiet=${1-} had_cdn=0
  if cdn_wanted; then
    had_cdn=1
    XHTTP_TLS_ENABLED=0
    WS_ENABLED=0
  fi
  rm -f "$CDN_FLAG" "$XRAY_CERT_FULL" "$XRAY_CERT_KEY"
  CERT_ON=0
  CERT_CA=letsencrypt
  CERT_SCOPE=single
  CERT_NAMES=""
  CERT_PUBLIC=1
  CERT_CHALLENGE=http
  svc_disable_stop proxy-oneclick-sub || true
  if [[ ${INIT_SYS:-} == systemd ]] && have systemctl; then
    systemctl disable --now proxy-oneclick-cert.timer >/dev/null 2>&1 || true
  fi
  rm -f "$SUB_UNIT" "$SUB_RC" "$CERT_TIMER_UNIT" "$CERT_RENEW_UNIT" "$CERT_CRON"
  sd_reload
  if have certbot; then certbot delete --cert-name "$CERT_NAME" --non-interactive >/dev/null 2>&1 || true; fi
  rm -rf "$CERT_DIR" "$CERT_LIB"
  if (( HY2_ENABLED )) && [[ -x $HY_BIN ]]; then
    gen_hy2_cert
    write_hy2_config
    restart_hy2
  fi
  if sb_needed && [[ -x $SB_BIN ]]; then
    write_singbox_config
    restart_singbox
  fi
  if (( had_cdn )) && [[ -x $XRAY_BIN ]]; then
    if xray_inbound_needed; then write_xray_config; restart_xray
    else svc_disable_stop xray; fi
  fi
  if (( ! NAT_MODE && ${FW_ENABLED:-0} == 1 )); then apply_firewall; fi
  save_state
  if (( INSTALLED )); then save_info || true; fi
  if [[ $quiet != quiet ]]; then
    if (( had_cdn )); then
      ok "已关闭证书。CDN 上的 XHTTP / WebSocket 已停止（不能改用自签证书）。Hysteria2 / TUIC / AnyTLS 改回自签。REALITY 未改动。"
    else
      ok "已关闭证书。Hysteria2 / TUIC / AnyTLS 改回自签证书。订阅已停止。REALITY 未改动。"
    fi
  fi
}
cert_remove_files() {
  local had=0
  [[ -d $CERT_DIR || -d $CERT_LIB || -f $SUB_UNIT || -f $SUB_RC || -f $CERT_TIMER_UNIT || -d /etc/letsencrypt/live/${CERT_NAME} ]] && had=1
  svc_disable_stop proxy-oneclick-sub || true
  if have systemctl; then systemctl disable --now proxy-oneclick-cert.timer >/dev/null 2>&1 || true; fi
  rm -f "$SUB_UNIT" "$SUB_RC" "$CERT_TIMER_UNIT" "$CERT_RENEW_UNIT" "$CERT_CRON"
  sd_reload
  if have certbot; then certbot delete --cert-name "$CERT_NAME" --non-interactive >/dev/null 2>&1 || true; fi
  rm -f "$CDN_FLAG" "$XRAY_CERT_FULL" "$XRAY_CERT_KEY"
  rm -f "$CERT_DNS_TOKEN" "$CERT_ZEROSSL_EAB" "$CERT_ORIGIN_KEY"
  rm -rf "$CERT_DIR" "$CERT_LIB" "$CERT_TXT_DIR" /var/log/proxy-oneclick
  if id "$SUB_USER" >/dev/null 2>&1; then userdel "$SUB_USER" >/dev/null 2>&1 || deluser "$SUB_USER" >/dev/null 2>&1 || true; fi
  if getent group "$CERT_GROUP" >/dev/null 2>&1; then groupdel "$CERT_GROUP" >/dev/null 2>&1 || delgroup "$CERT_GROUP" >/dev/null 2>&1 || true; fi
  CERT_ON=0
  CERT_CA=letsencrypt
  CERT_SCOPE=single
  CERT_NAMES=""
  CERT_PUBLIC=1
  CERT_CHALLENGE=http
  (( had )) && ok "证书与订阅 HTTPS 已移除。"
  return 0
}

setup_cert() {
  (( LAND_MODE )) && return 0
  if (( NAT_MODE )); then
    if (( CERT_ON == 1 )) || cdn_wanted; then
      warn "NAT 模式无法在公网 80 上续期，也不能开 CDN 线路。证书已关闭，CDN 上的 XHTTP / WebSocket 已停止。REALITY 未改用该证书。"
      cert_turn_off quiet
    fi
    return 0
  fi
  if cdn_wanted && [[ $OPT_CERT == 0 ]]; then
    cdn_explain cert_required
    die "CDN 线路需要证书，不能和 --no-cert 一起使用。公开证书或 Cloudflare 源站证书都可以。REALITY 未改动。"
  fi
  if [[ $OPT_CERT == 0 ]]; then
    if (( CERT_ON == 1 )); then cert_turn_off; fi
    return 0
  fi
  local want=0
  if [[ -n $OPT_CERT_DOMAIN || -n $OPT_CERT_KIND || -n $OPT_CERT_NAMES || -n $OPT_CF_ORIGIN_KEY || -n $OPT_ZEROSSL_KID || $OPT_CERT == 1 ]]; then want=1
  elif cdn_wanted; then
    if (( CERT_ON != 1 )) || [[ -z $CERT_DOMAIN ]]; then
      info "CDN 上的 XHTTP / WebSocket 需要证书。默认是 Let's Encrypt 单域名；只给 CDN 用时可以选 Cloudflare 源站证书。REALITY 仍然借用伪装站点。"
    fi
    want=1
  elif (( CERT_ON == 1 )) && [[ -n $CERT_DOMAIN ]]; then want=1
  elif (( OPT_AUTO )); then return 0
  elif confirm "是否申请公开可信证书（Let's Encrypt）？需要自有域名已解析到本机。用于订阅 HTTPS，以及 Hysteria2 / TUIC / AnyTLS（链接改用该域名，不再使用 insecure）。REALITY 仍借用伪装站点。默认不申请。" n; then
    info "继续申请即表示同意 Let’s Encrypt 服务条款（https://letsencrypt.org/repository/）。"
    want=1
  fi
  (( want )) || return 0
  cert_issue_flow
}

cert_menu_pick_kind() {
  echo
  echo "默认是 Let's Encrypt 单域名。其它种类是可选项，签好之前 REALITY 不变。"
  ui_columns "oneclick proxy" "返回" \
    "Let's Encrypt 单域名（默认，HTTP-01）" \
    "Let's Encrypt 通配符（DNS-01）" \
    "Let's Encrypt 多域名（HTTP-01）" \
    "ZeroSSL 单域名（HTTP-01）" \
    "ZeroSSL 通配符（DNS-01）" \
    "ZeroSSL 多域名（HTTP-01）" \
    "Cloudflare 源站证书（只给 CDN）"
  local c
  ask c "请选择" "0"
  case $c in
    1) OPT_CERT_KIND=le ;;
    2) OPT_CERT_KIND=wildcard ;;
    3) OPT_CERT_KIND=multi ;;
    4) OPT_CERT_KIND=zerossl ;;
    5) OPT_CERT_KIND=zerossl-wildcard ;;
    6) OPT_CERT_KIND=zerossl-multi ;;
    7) OPT_CERT_KIND=cf-origin ;;
    *) return 1 ;;
  esac
}
cert_menu_issue() {
  cert_menu_pick_kind || return 0
  OPT_CERT_DOMAIN=""
  OPT_CERT_NAMES=""
  OPT_CERT_LINK=""
  cert_issue_flow
  OPT_CERT_KIND=""
  cert_after_issue
}
cert_menu_renew() {
  tls_for_cdn || { warn "尚未申请证书。"; return 0; }
  if [[ ${CERT_CA:-letsencrypt} == cloudflare ]]; then
    cat <<EOF
这是 Cloudflare 源站证书，不是 Let's Encrypt，不会自动续期。
有效期大约 15 年（到 $(cert_expiry_text)）。只有 Cloudflare 信任它。
要换成别的种类，请重新选择种类：脚本会先关掉这一张，再签新的。REALITY 不动。
不要把这张证书用于 Hysteria2、TUIC、AnyTLS 或订阅。
EOF
    return 0
  fi
  if [[ ${CERT_CHALLENGE:-http} == dns ]]; then
    cert_ensure_dig
    write_dns_hooks
    if [[ ! -s $CERT_DNS_TOKEN ]]; then
      cat <<'EOF'
上次没有保存 Cloudflare DNS 令牌。
续期还是要在 _acme-challenge 上添加 TXT，而且必须是灰色云朵。
脚本会打印要添加的内容，并等待公共 DNS 能查到。这次不需要开放 80 端口。
如果希望以后自动续期，请重新申请并加上 --cf-dns-token。
EOF
    else
      info "将用已保存的 Cloudflare DNS 令牌续期，不占用 80 端口。"
    fi
  else
    local owner=""
    if port_in_use tcp 80; then
      owner=$(port_owner tcp 80)
      cdn_explain port80 "${owner:-未知}"
      return 0
    fi
    cert_allow_80_now
  fi
  local renew_args=(renew --cert-name "$CERT_NAME")
  if openssl x509 -checkend 2592000 -noout -in "$CERT_FULLCHAIN" >/dev/null 2>&1; then
    info "证书尚未进入续期窗口（到期前 30 天才续）。当前到期 $(cert_expiry_text)。"
    confirm "仍然向 $(cert_kind_label) 强制续期？" n || return 0
    renew_args+=(--force-renewal)
  fi
  if certbot "${renew_args[@]}"; then
    cert_install_material
    cert_rewire_protocols
    cert_refresh_cdn
    cert_start_sub
    ok "续期检查完成。到期 $(cert_expiry_text)。"
  else
    if [[ ${CERT_CHALLENGE:-http} == dns ]]; then cert_explain txt_missing
    elif [[ ${CERT_SCOPE:-} == multi ]]; then cert_explain multi_fail
    else cdn_explain cert_fail; fi
    warn "续期失败。REALITY 未改动。"
  fi
}
menu_cert() {
  need_node
  [[ -n $OS_ID ]] || detect_os
  if (( NAT_MODE )); then
    die "NAT 模式不能申请证书，也不能使用 Cloudflare 源站证书：公网访问不到这台机器，CDN 也无法回源。不申请时 REALITY 和自签证书保持原样。"
  fi
  while :; do
    echo
    if tls_for_cdn; then
      printf '证书  %s\n' "$(cert_kind_label)"
      printf '名字  %s\n' "${CERT_NAMES:-$CERT_DOMAIN}"
      printf '链接  %s\n' "$CERT_DOMAIN"
      printf '到期  %s\n' "$(cert_expiry_text)"
      if cert_is_public; then
        printf '订阅  HTTPS %s:%s（完整链接在查看里，明文 HTTP 不提供）\n' "$CERT_DOMAIN" "$SUB_PORT"
      else
        echo "订阅  未开启。这张只有 Cloudflare 信任，不能给浏览器、Hysteria2、TUIC、AnyTLS。"
      fi
    else
      echo "当前未申请证书。不申请时 REALITY 与自签的 Hysteria2 / TUIC / AnyTLS 保持原样。"
    fi
    ui_columns "oneclick proxy" "返回" \
      "选择证书种类并申请" \
      "立即续期" \
      "查看链接" \
      "关闭证书"
    local c
    ask c "请选择" "0"
    case $c in
      1) cert_menu_issue ;;
      2) cert_menu_renew ;;
      3) if tls_for_cdn; then show_info; else warn "尚未申请证书。"; fi ;;
      4) if ! tls_for_cdn; then info "当前没有证书。"; continue; fi
         if cert_is_public; then
           confirm "关闭证书后，Hysteria2 / TUIC / AnyTLS 改回自签，订阅 HTTPS 停止。开着的 CDN 线路也会关掉。REALITY 不变。确认？" n || continue
         else
           confirm "关闭 Cloudflare 源站证书后，CDN 上的 XHTTP+TLS / WebSocket+TLS 会停。Hysteria2 / TUIC / AnyTLS 本来就是自签，订阅本来就没开。REALITY 不变。确认？" n || continue
         fi
         cert_turn_off ;;
      *) return 0 ;;
    esac
  done
}
do_cert() {
  load_state
  [[ -n $INIT_SYS ]] || detect_init
  [[ -n $OS_ID ]] || detect_os
  if [[ $OPT_CERT == 0 ]]; then
    (( INSTALLED )) || die "尚未安装。"
    if (( CERT_ON != 1 )); then info "当前没有证书。"; return 0; fi
    cert_turn_off
    return 0
  fi
  need_node
  if (( NAT_MODE )); then
    die "NAT 模式不能申请证书，也不能使用 Cloudflare 源站证书：公网访问不到这台机器，CDN 也无法回源。不申请时 REALITY 和自签证书保持原样。"
  fi
  if cert_cli_requested; then
    cert_issue_flow
    cert_after_issue
    return 0
  fi
  if [[ ! -t 0 && ! -r /dev/tty ]]; then die "非交互环境请使用 --cert-domain 或 --cert-kind。"; fi
  menu_cert
}

print_sub_block() {
  tls_present_real || return 0
  [[ -n $SUB_TOKEN ]] || return 0
  local paint=${1:-0} W=62
  echo
  ui_bar '═' "$W" "$paint"
  ui_center "订阅（仅 HTTPS）" "$W" "$paint"
  ui_bar '─' "$W" "$paint"
  printf '域名  %s\n' "$CERT_DOMAIN"
  printf '端口  %s  TCP\n' "$SUB_PORT"
  node_link_note "$paint" "明文 HTTP 不提供订阅。Hysteria2 / TUIC / AnyTLS 使用这张证书。"
  node_link_note "$paint" "REALITY 仍借用伪装站点 ${SNI}，不使用这张证书。"
  echo "v2rayN / v2rayNG / Shadowrocket"
  sub_url
  echo "mihomo"
  sub_clash_url
  if (( paint )); then echo; print_qr "$(sub_url_raw)"; fi
  ui_bar '═' "$W" "$paint"
}

