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
pub_xhttp_port() {
  if xhttp_shared; then pub_xray_port; return; fi
  if (( NAT_MODE )) && [[ -n $XHTTP_EXT_PORT ]]; then printf '%s' "$XHTTP_EXT_PORT"; else printf '%s' "$XHTTP_PORT"; fi
}
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
  local addr q sni
  addr=$(host_fmt "$(tls_link_host)")
  sni=$(tls_link_sni)
  if tls_present_real; then q="sni=${sni}"
  else q="sni=${sni}&insecure=1&pinSHA256=${HY2_PIN}"; fi
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
  local addr q sni
  addr=$(host_fmt "$(tls_link_host)")
  sni=$(tls_link_sni)
  if tls_present_real; then q="congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${sni}"
  else q="congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${sni}&allow_insecure=1&insecure=1"; fi
  printf 'tuic://%s:%s@%s:%s?%s#%s' "$(urlencode "$UUID")" "$(urlencode "$TUIC_PASS")" "$addr" "$(pub_tuic_port)" "$q" "$(urlencode "${NODE_NAME}-TUIC")"
}
anytls_link() {
  local addr q sni
  addr=$(host_fmt "$(tls_link_host)")
  sni=$(tls_link_sni)
  if tls_present_real; then q="security=tls&type=tcp&sni=${sni}&fp=chrome"
  else q="security=tls&type=tcp&sni=${sni}&fp=chrome&insecure=1&allowInsecure=1"; fi
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
    local hy_host hy_sni
    hy_host=$(tls_link_host)
    hy_sni=$(tls_link_sni)
    cat <<Y
  - name: "${NODE_NAME}-Hy2"
    type: hysteria2
    server: ${hy_host}
    port: $(pub_hy2_port)
Y
    if [[ -n $(pub_hop) ]]; then
      if [[ $(pub_hop) == *,* ]]; then printf '    ports: "%s"\n    hop-interval: 30\n' "$(pub_hop)"
      else printf '    ports: %s\n    hop-interval: 30\n' "$(pub_hop)"; fi
    fi
    if tls_present_real; then
      cat <<Y
    password: "${HY2_PASS}"
    sni: ${hy_sni}
    alpn:
      - h3
Y
    else
      cat <<Y
    password: "${HY2_PASS}"
    sni: ${hy_sni}
    fingerprint: ${pin_hex}
    alpn:
      - h3
Y
    fi
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
    local tu_host tu_sni
    tu_host=$(tls_link_host)
    tu_sni=$(tls_link_sni)
    cat <<Y
  - name: "${NODE_NAME}-TUIC"
    type: tuic
    server: ${tu_host}
    port: $(pub_tuic_port)
    uuid: ${UUID}
    password: "${TUIC_PASS}"
    sni: ${tu_sni}
    alpn: [h3]
    congestion-controller: bbr
    udp-relay-mode: native
Y
    if tls_present_real; then printf '    udp: true\n'
    else printf '    skip-cert-verify: true\n    udp: true\n'; fi
  fi
  if (( ANYTLS_ENABLED )); then
    local at_host at_sni
    at_host=$(tls_link_host)
    at_sni=$(tls_link_sni)
    cat <<Y
  - name: "${NODE_NAME}-AnyTLS"
    type: anytls
    server: ${at_host}
    port: $(pub_anytls_port)
    password: "${ANYTLS_PASS}"
    sni: ${at_sni}
    client-fingerprint: chrome
Y
    if tls_present_real; then printf '    udp: true\n'
    else printf '    skip-cert-verify: true\n    udp: true\n'; fi
  fi
  cdn_mihomo
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
    node_link_head "$paint" "Hysteria2" "${NODE_NAME}-Hy2" "$(tls_link_host)" "$(pub_hy2_port)  UDP${hp:+  跳跃 ${hp}}"
    if tls_present_real; then node_link_note "$paint" "证书 ${CERT_DOMAIN}，按正常校验，不要开 insecure"; fi
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
    node_link_head "$paint" "TUIC v5" "${NODE_NAME}-TUIC" "$(tls_link_host)" "$(pub_tuic_port)  UDP"
    node_link_note "$paint" "v2rayNG 不能导入，请用 v2rayN / sing-box / mihomo"
    if tls_present_real; then node_link_note "$paint" "证书 ${CERT_DOMAIN}，按正常校验，不要开 insecure"; fi
    qr=$(tuic_link)
    node_link_uri "$qr"
    (( paint )) && { echo; print_qr "$qr"; }
    node_link_end "$paint"
  fi
  if (( ANYTLS_ENABLED )); then
    node_link_head "$paint" "AnyTLS" "${NODE_NAME}-AnyTLS" "$(tls_link_host)" "$(pub_anytls_port)  TCP"
    node_link_note "$paint" "v2rayNG 不能导入，请用 v2rayN / sing-box / mihomo"
    if tls_present_real; then node_link_note "$paint" "证书 ${CERT_DOMAIN}，按正常校验，不要开 insecure"; fi
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
  cdn_print_links "$paint"
  print_sub_block "$paint"
  if land_in_on; then
    echo
    land_print_links "$paint"
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
  if tls_present_real; then cert_write_bodies || warn "订阅文件写入失败。"; fi
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

