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
  local crt=$HY_CRT key=$HY_KEY
  if tls_present_real; then
    # 公开证书的 CN 是自有域名，不能按伪装 SNI 重新生成自签证书。
    cert_grant_readers
    crt=$CERT_FULLCHAIN
    key=$CERT_PRIVKEY
  else
    [[ -f $HY_CRT && -f $HY_KEY ]] || gen_hy2_cert
    # 证书 CN 与当前 SNI 不一致时重新生成
    if ! openssl x509 -noout -subject -in "$HY_CRT" 2>/dev/null | grep -q "CN *= *${SNI}\$"; then gen_hy2_cert; fi
    HY2_PIN=$(openssl x509 -noout -fingerprint -sha256 -in "$HY_CRT" | cut -d= -f2)
  fi
  cat >"${HY_CONF}.tmp" <<HY
# 由 proxy-oneclick 生成
listen: :${HY2_PORT}

tls:
  cert: ${crt}
  key: ${key}

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
  if tls_present_real; then
    chown "root:${grp}" "${HY_CONF}.tmp"
    chmod 640 "${HY_CONF}.tmp"
  else
    chown "root:${grp}" "${HY_CONF}.tmp" "$HY_KEY" "$HY_CRT"
    chmod 640 "${HY_CONF}.tmp" "$HY_KEY"; chmod 644 "$HY_CRT"
  fi
  mv -f "${HY_CONF}.tmp" "$HY_CONF"
  selinux_fix "$HY_DIR"
  if tls_present_real; then ok "Hysteria2 配置已生成: ${HY_CONF}（证书 ${CERT_DOMAIN}）"
  else ok "Hysteria2 配置已生成: ${HY_CONF}"; fi
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

