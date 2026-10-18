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
  [[ -x $XRAY_BIN && -n $UUID && -n $PUB_KEY && -n $SNI && -n $XHTTP_PATH ]] || { warn "跳过 XHTTP 自检（缺少参数）。"; return 0; }
  local dest=${XHTTP_PORT:-}
  xhttp_shared && dest=$XRAY_PORT
  [[ -n $dest ]] || { warn "跳过 XHTTP 自检（缺少端口）。"; return 0; }
  mktmp
  local dir port="" i pid code="" url ok_url="" rc=1
  dir=$(mktemp -d "${TMP_DIR}/xhttp-self.XXXXXX") || { warn "跳过 XHTTP 自检（无法创建临时目录）。"; return 0; }
  for i in 1 2 3 4 5 6 7 8 9 10; do
    port=$(( 20000 + RANDOM % 40000 ))
    [[ $port == "$XRAY_PORT" || $port == "$XHTTP_PORT" || $port == "$dest" || $port == "${HY2_PORT:-}" ]] && continue
    port_in_use tcp "$port" || break
  done
  if ! jq -n --arg id "$UUID" --argjson sport "$port" --argjson port "$dest" --arg sni "$SNI" \
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
  if xhttp_shared; then
    info "XHTTP 自检：临时客户端 127.0.0.1:${port} → 本机 127.0.0.1:${dest}（与 Vision 共用，mode stream-one，SNI ${SNI}）..."
  else
    info "XHTTP 自检：临时客户端 127.0.0.1:${port} → 本机 127.0.0.1:${dest}（mode stream-one，SNI ${SNI}）..."
  fi
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

