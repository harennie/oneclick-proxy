# ============================================================
#                 导出 / 导入（换机器时带走密钥）
# ============================================================
# 导出的是重建同一批节点需要的密钥和证书。公网地址、网卡、NAT 映射、
# 虚拟化类型和内存档位不放进去，导入时在新机器上重新检测。
export_host_key() {
  case $1 in
    SERVER_ADDR|PUBLIC_IP4|PUBLIC_IP6|NAT_PORTS|NAT_EXCLUDE|XRAY_EXT_PORT|HY2_EXT_PORT|HOP_EXT_RANGE|HOP_BACKEND|\
    XHTTP_EXT_PORT|TROJAN_EXT_PORT|TUIC_EXT_PORT|ANYTLS_EXT_PORT|VIRT|SSH_PORTS|FW_HOST_SYNC|DISABLED_FW|\
    SWAP_CREATED|DNS64_SET) return 0 ;;
  esac
  return 1
}
export_stage_state() {
  local dest=$1 k v
  : >"$dest"
  chmod 600 "$dest"
  for k in "${STATE_KEYS[@]}"; do
    v=${!k-}
    if export_host_key "$k"; then v=""
    elif [[ $k == NAT_MODE ]]; then v=0
    elif [[ $k == NAT_PREF ]]; then v=auto
    elif [[ $k == INSTALLED ]]; then v=0
    fi
    [[ $v == *$'\n'* || $v == *"'"* ]] && die "内部错误: 状态值 $k 含非法字符"
    printf "%s='%s'\n" "$k" "$v" >>"$dest"
  done
}
export_put() { # $1 源文件 $2 包内相对路径
  [[ -s $1 ]] || return 0
  local dest="${EXPORT_STAGE}/$2"
  mkdir -p "$(dirname "$dest")"
  install -m 600 "$1" "$dest"
}
export_have_tty() { # /dev/tty 打得开、并且真是终端
  local fd
  [[ -r /dev/tty && -w /dev/tty ]] || return 1
  # 打开失败时 bash 会写「/dev/tty: No such device or address」。
  # 重定向从左到右生效，所以不能写成 exec {fd}</dev/tty 2>/dev/null。
  { exec {fd}</dev/tty; } 2>/dev/null || return 1
  if [[ -t $fd ]]; then
    exec {fd}<&-
    return 0
  fi
  exec {fd}<&-
  return 1
}
export_read_pass() { # $1 变量名 $2 提示。优先用环境变量，不回显。
  local __p=""
  if [[ -n ${PROXY_EXPORT_PASS:-} ]]; then
    printf -v "$1" '%s' "$PROXY_EXPORT_PASS"
    return 0
  fi
  if [[ -t 0 ]]; then
    read -r -s -p "$2" __p || true
    echo
  elif export_have_tty; then
    if ! read -r -s -p "$2" __p </dev/tty; then
      die "需要密码。请设置环境变量 PROXY_EXPORT_PASS。"
    fi
    echo
  else
    die "需要密码。请设置环境变量 PROXY_EXPORT_PASS。"
  fi
  [[ -n $__p ]] || die "密码不能为空。"
  printf -v "$1" '%s' "$__p"
}
export_is_enc() {
  local magic
  magic=$(head -c 8 "$1" 2>/dev/null || true)
  [[ $magic == "Salted__" ]]
}
export_default_path() {
  local host
  host=$(hostname -s 2>/dev/null || true)
  host=$(tr -cd 'A-Za-z0-9_.-' <<<"$host")
  [[ -n $host ]] || host=host
  local p
  p="/root/proxy-export-${host}-$(date +%Y%m%d).tar.gz"
  if (( OPT_EXPORT_ENC )); then p="${p}.enc"; fi
  if [[ -e $p ]]; then
    p="/root/proxy-export-${host}-$(date +%Y%m%d-%H%M%S).tar.gz"
    if (( OPT_EXPORT_ENC )); then p="${p}.enc"; fi
  fi
  printf '%s' "$p"
}
do_export() {
  load_state
  (( INSTALLED )) || die "还没有安装，不能导出。"
  require_root
  mktmp
  local stage="${TMP_DIR}/export" tar="${TMP_DIR}/export.tar.gz" out pass
  mkdir -p "$stage"
  chmod 700 "$stage"
  EXPORT_STAGE=$stage
  export_stage_state "${stage}/state.env"
  export_put "$USERS_FILE" "users.txt"
  export_put "$HY_CRT" "hysteria/server.crt"
  export_put "$HY_KEY" "hysteria/server.key"
  export_put "$SB_CRT" "singbox/server.crt"
  export_put "$SB_KEY" "singbox/server.key"
  export_put "$CERT_FULLCHAIN" "certs/fullchain.pem"
  export_put "$CERT_PRIVKEY" "certs/privkey.pem"
  export_put "$CERT_DNS_TOKEN" "certs/cf-dns.token"
  export_put "$CERT_ZEROSSL_EAB" "certs/zerossl.eab"
  export_put "$CERT_ORIGIN_KEY" "certs/cf-origin.key"
  if [[ -s $TUNE_CUR ]]; then
    mkdir -p "${stage}/tune"
    grep -Ev '^(IFACE|TIME)=' "$TUNE_CUR" >"${stage}/tune/current.env" || true
    chmod 600 "${stage}/tune/current.env"
  fi
  tar -C "$stage" -czf "$tar" .
  out=${OPT_EXPORT_PATH:-$(export_default_path)}
  mkdir -p "$(dirname "$out")"
  if (( OPT_EXPORT_ENC )); then
    export_read_pass pass "导出密码（不会回显）: "
    PROXY_EXPORT_PASS=$pass
    export PROXY_EXPORT_PASS
    openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:PROXY_EXPORT_PASS -in "$tar" -out "$out" \
      || die "加密失败。"
  else
    install -m 600 "$tar" "$out"
  fi
  chmod 600 "$out"
  ok "已导出到 ${out}（权限 600）。"
  info "包里有 UUID、Reality 私钥、ShortId、ML-DSA 种子、SNI、端口、XHTTP 路径、各协议密码、落地 / 中转配置、调优参数和证书。"
  info "没有放公网 IP、网卡、NAT 映射和虚拟化类型。导入时会在新机器上重新检测。"
  if (( OPT_EXPORT_ENC )); then
    info "文件已用 AES-256-CBC 加密。导入时会询问密码，或读取环境变量 PROXY_EXPORT_PASS。"
  fi
  return 0
}
export_restore_file() { # $1 包内路径 $2 目标
  [[ -s $1 ]] || return 0
  mkdir -p "$(dirname "$2")"
  install -m 600 "$1" "$2"
}
do_import() {
  local file=${OPT_IMPORT:-}
  [[ -n $file && -f $file ]] || die "找不到要导入的文件: ${file:-（未指定）}"
  require_root
  load_state
  if (( INSTALLED )) && (( ! OPT_AUTO )); then
    confirm "本机已有安装。导入会改用文件里的密钥并重新安装。继续？" n || return 0
  fi
  mktmp
  local tar="$file" work="${TMP_DIR}/import" pass
  mkdir -p "$work"
  if export_is_enc "$file"; then
    export_read_pass pass "导入密码（不会回显）: "
    PROXY_EXPORT_PASS=$pass
    export PROXY_EXPORT_PASS
    tar="${TMP_DIR}/import.tar.gz"
    openssl enc -d -aes-256-cbc -pbkdf2 -pass env:PROXY_EXPORT_PASS -in "$file" -out "$tar" \
      || die "解密失败。请核对密码。"
  fi
  tar -tzf "$tar" >/dev/null 2>&1 || die "不是有效的导出文件。"
  tar -xzf "$tar" -C "$work"
  [[ -s ${work}/state.env ]] || die "导出文件里没有 state.env。"
  mkdir -p "$STATE_DIR" "$HY_DIR" "$SB_DIR" "$CERT_DIR" "$TUNE_DIR"
  chmod 700 "$STATE_DIR"
  install -m 600 "${work}/state.env" "$STATE_FILE"
  export_restore_file "${work}/users.txt" "$USERS_FILE"
  export_restore_file "${work}/hysteria/server.crt" "$HY_CRT"
  export_restore_file "${work}/hysteria/server.key" "$HY_KEY"
  export_restore_file "${work}/singbox/server.crt" "$SB_CRT"
  export_restore_file "${work}/singbox/server.key" "$SB_KEY"
  export_restore_file "${work}/certs/fullchain.pem" "$CERT_FULLCHAIN"
  export_restore_file "${work}/certs/privkey.pem" "$CERT_PRIVKEY"
  export_restore_file "${work}/certs/cf-dns.token" "$CERT_DNS_TOKEN"
  export_restore_file "${work}/certs/zerossl.eab" "$CERT_ZEROSSL_EAB"
  export_restore_file "${work}/certs/cf-origin.key" "$CERT_ORIGIN_KEY"
  if [[ -s ${work}/tune/current.env && -z $OPT_TUNE_PRESET ]]; then
    install -m 600 "${work}/tune/current.env" "$TUNE_CUR"
    local preset buf cc qd
    preset=$(sed -n 's/^PRESET=//p' "$TUNE_CUR" | head -n1)
    buf=$(sed -n 's/^BUFFER=//p' "$TUNE_CUR" | head -n1)
    cc=$(sed -n 's/^CC=//p' "$TUNE_CUR" | head -n1)
    qd=$(sed -n 's/^QDISC=//p' "$TUNE_CUR" | head -n1)
    [[ -n $preset ]] && OPT_TUNE_PRESET=$preset
    [[ -n $buf ]] && OPT_TUNE_BUF=$buf
    [[ -n $cc && $cc != keep && -z $OPT_TUNE_CC ]] && OPT_TUNE_CC=$cc
    [[ -n $qd && $qd != keep && -z $OPT_TUNE_QDISC ]] && OPT_TUNE_QDISC=$qd
  fi
  if [[ -s $CERT_FULLCHAIN ]]; then
    if ! openssl x509 -noout -in "$CERT_FULLCHAIN" >/dev/null 2>&1; then
      warn "导入的公开证书无法读取，安装时会重新申请。"
      rm -f "$CERT_FULLCHAIN" "$CERT_PRIVKEY"
    elif ! openssl x509 -checkend 0 -noout -in "$CERT_FULLCHAIN" >/dev/null 2>&1; then
      warn "导入的公开证书已经过期，安装时会重新申请。"
      rm -f "$CERT_FULLCHAIN" "$CERT_PRIVKEY"
    else
      info "导入的公开证书可以读取，到期 $(openssl x509 -enddate -noout -in "$CERT_FULLCHAIN" | cut -d= -f2)。"
    fi
  fi
  info "已读入密钥。接下来重新检测 IP、NAT、SNI 和防火墙，并按原端口和协议装回去。"
  IMPORT_MODE=1
  do_install
}
menu_export() {
  need_installed
  local p
  ask p "导出文件路径（直接回车用默认路径）" ""
  OPT_EXPORT_PATH=$p
  if confirm "用密码加密这个文件？" n; then OPT_EXPORT_ENC=1; else OPT_EXPORT_ENC=0; fi
  do_export
}
menu_import() {
  local p
  ask p "导入文件路径" ""
  [[ -n $p ]] || { warn "没有填写路径。"; return 0; }
  OPT_IMPORT=$p
  confirm "导入会用文件里的密钥重新安装，并重新检测 IP、NAT 和防火墙。继续？" y || return 0
  do_import
}
