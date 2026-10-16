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
# TUIC v5 / AnyTLS 由 sing-box 提供。默认自签证书（CN = 所选 SNI），不要求自有域名。
# 申请了公开证书时，这两个协议和 Hysteria2 改用那张证书，链接里的地址和 SNI 换成自有域名。
# Trojan 走 Xray + REALITY。Shadowsocks 2022 只存在于落地机，这里不加直连入站。
xray_inbound_needed() {
  (( ${REALITY_ENABLED:-0} || ${XHTTP_ENABLED:-0} || ${TROJAN_ENABLED:-0} || ${XHTTP_TLS_ENABLED:-0} || ${WS_ENABLED:-0} )) && return 0
  relay_active && (( ${HY2_ENABLED:-0} )) && return 0
  return 1
}
proto_xray_brief() {
  local s=""
  (( REALITY_ENABLED )) && s+="REALITY TCP ${XRAY_PORT}"
  (( XHTTP_ENABLED )) && s+="${s:+ / }XHTTP TCP ${XHTTP_PORT}"
  (( XHTTP_TLS_ENABLED )) && s+="${s:+ / }XHTTP+TLS TCP ${XHTTP_TLS_PORT}"
  (( WS_ENABLED )) && s+="${s:+ / }WS+TLS TCP ${WS_PORT}"
  (( TROJAN_ENABLED )) && s+="${s:+ / }Trojan TCP ${TROJAN_PORT}"
  [[ -n $s ]] || s="无入站"
  printf '%s' "$s"
}
ensure_proto_secrets() {
  [[ $XHTTP_PATH == /* && $XHTTP_PATH =~ ^/[A-Za-z0-9_-]+$ ]] || XHTTP_PATH="/$(rand_hex 8)"
  [[ -n $TROJAN_PASS ]] || TROJAN_PASS=$(rand_pass)
  [[ -n $TUIC_PASS ]] || TUIC_PASS=$(rand_pass)
  [[ -n $ANYTLS_PASS ]] || ANYTLS_PASS=$(rand_pass)
  cdn_ensure_paths
}
resolve_install_protos() {
  if [[ -n $OPT_REALITY ]]; then REALITY_ENABLED=$OPT_REALITY; fi
  if [[ -n $OPT_XHTTP ]]; then XHTTP_ENABLED=$OPT_XHTTP
  elif (( ! STATE_HAS_XHTTP )); then XHTTP_ENABLED=1
  fi
  if [[ -n $OPT_TROJAN ]]; then TROJAN_ENABLED=$OPT_TROJAN; fi
  if [[ -n $OPT_TUIC ]]; then TUIC_ENABLED=$OPT_TUIC; fi
  if [[ -n $OPT_ANYTLS ]]; then ANYTLS_ENABLED=$OPT_ANYTLS; fi
  local had_cdn=0
  cdn_wanted && had_cdn=1
  if [[ -n $OPT_XHTTP_TLS ]]; then XHTTP_TLS_ENABLED=$OPT_XHTTP_TLS; fi
  if [[ -n $OPT_WS ]]; then WS_ENABLED=$OPT_WS; fi
  if [[ -n $OPT_VLESS_ENC ]]; then VLESS_ENC=$OPT_VLESS_ENC
  else vless_enc_default "$(( INSTALLED && had_cdn ))"; fi
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
proto_any_enabled() { (( REALITY_ENABLED || XHTTP_ENABLED || HY2_ENABLED || TROJAN_ENABLED || TUIC_ENABLED || ANYTLS_ENABLED || XHTTP_TLS_ENABLED || WS_ENABLED )); }

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
  if (( XHTTP_TLS_ENABLED )); then
    cdn_choose_port XHTTP_TLS_PORT "$OPT_XHTTP_TLS_PORT" "VLESS + XHTTP + TLS（CDN）" "${XHTTP_TLS_PORT:-2083}" || die "XHTTP+TLS 的端口不可用，见上方说明。REALITY 没有改动。"
  fi
  if (( WS_ENABLED )); then
    cdn_choose_port WS_PORT "$OPT_WS_PORT" "VLESS + WebSocket + TLS（CDN）" "${WS_PORT:-2087}" || die "WebSocket+TLS 的端口不可用，见上方说明。REALITY 没有改动。"
  fi
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
  if tls_present_real; then
    cert_grant_readers
    return 0
  fi
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
  local tmp="${SB_CONF}.tmp" crt=$SB_CRT key=$SB_KEY
  if tls_present_real; then crt=$CERT_FULLCHAIN; key=$CERT_PRIVKEY; fi
  # sing-box 1.11 起不写 listen 时默认只绑 127.0.0.1。文档中的双栈地址是 "::"。
  jq -n \
    --argjson tuic "${TUIC_ENABLED:-0}" --argjson any "${ANYTLS_ENABLED:-0}" \
    --argjson tport "${TUIC_PORT:-0}" --argjson aport "${ANYTLS_PORT:-0}" \
    --arg uuid "$UUID" --arg tpw "$TUIC_PASS" --arg apw "$ANYTLS_PASS" \
    --arg crt "$crt" --arg key "$key" --argjson nets "$PRIV_NETS_JSON" '
    {
      log: {level: "warn"},
      inbounds: (
        []
        + (if $tuic == 1 then [{
            type: "tuic", tag: "tuic-in", listen: "::", listen_port: $tport,
            users: [{name: "main", uuid: $uuid, password: $tpw}],
            congestion_control: "bbr", zero_rtt_handshake: false,
            tls: {enabled: true, certificate_path: $crt, key_path: $key, alpn: ["h3"]}
          }] else [] end)
        + (if $any == 1 then [{
            type: "anytls", tag: "anytls-in", listen: "::", listen_port: $aport,
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
  local sb_user=root
  id sing-box >/dev/null 2>&1 && sb_user=sing-box
  own_svc_config "$tmp" "$sb_user"
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
  cdn_sync_flag
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

