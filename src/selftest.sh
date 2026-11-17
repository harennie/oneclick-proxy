# ============================================================
#        本机代理自检：临时客户端完成握手后，再经节点访问外网
# ============================================================
selftest_urls() {
  printf '%s\n' https://www.gstatic.com/generate_204 https://cp.cloudflare.com/generate_204 https://www.apple.com/library/test/success.html
}
selftest_socks_port() {
  local i port reserved=" ${1:-} ${XRAY_PORT:-} ${XHTTP_PORT:-} ${HY2_PORT:-} ${TUIC_PORT:-} ${ANYTLS_PORT:-} ${LAND_PORT:-} "
  for (( i=0; i<10; i++ )); do
    port=$(( 20000 + RANDOM % 40000 ))
    [[ $reserved == *" $port "* ]] && continue
    if ! port_in_use tcp "$port"; then printf '%s' "$port"; return 0; fi
  done
  return 1
}
selftest_client_config() { # $1 协议 $2 socks 端口 $3 目标端口 $4 文件
  local kind=$1 sport=$2 dest=$3 file=$4 sni=${SNI:-} ca="" pin="" pass="" pqv=""
  case $kind in
    reality|xhttp) if pqv_active; then pqv=$MLDSA_VERIFY; fi ;;
    hy2|tuic|anytls)
      sni=$(tls_link_sni)
      if ! tls_present_real; then
        if [[ $kind == hy2 ]]; then ca=$HY_CRT; pin=${HY2_PIN:-}; else ca=$SB_CRT; fi
      fi
      case $kind in hy2) pass=$HY2_PASS ;; tuic) pass=$TUIC_PASS ;; anytls) pass=$ANYTLS_PASS ;; esac
      ;;
  esac
  jq -n --arg kind "$kind" --argjson sport "$sport" --argjson port "$dest" \
    --arg id "${UUID:-}" --arg sni "$sni" --arg pbk "${PUB_KEY:-}" --arg sid "${SHORT_ID:-}" \
    --arg pqv "$pqv" --arg path "${XHTTP_PATH:-}" --arg ca "$ca" --arg pin "$pin" --arg pass "$pass" '
    if $kind == "hy2" then {
      server: ("127.0.0.1:" + ($port|tostring)), auth: $pass,
      tls: ({sni: $sni, insecure: false} + (if $ca != "" then {ca: $ca} else {} end)
        + (if $pin != "" then {pinSHA256: $pin} else {} end)),
      socks5: {listen: ("127.0.0.1:" + ($sport|tostring)), disableUDP: true}
    } elif $kind == "reality" or $kind == "xhttp" then {
      log: {loglevel: "warning"},
      inbounds: [{listen: "127.0.0.1", port: $sport, protocol: "socks", settings: {udp: false}}],
      outbounds: [{protocol: "vless", settings: {vnext: [{address: "127.0.0.1", port: $port,
        users: [{id: $id, encryption: "none", flow: (if $kind == "reality" then "xtls-rprx-vision" else "" end)}]}]},
        streamSettings: ({network: (if $kind == "reality" then "raw" else "xhttp" end), security: "reality",
          realitySettings: ({serverName: $sni, fingerprint: "chrome", publicKey: $pbk, shortId: $sid}
            + (if $pqv != "" then {mldsa65Verify: $pqv} else {} end))}
          + (if $kind == "xhttp" then {xhttpSettings: {path: $path, mode: "stream-one"}} else {} end))}]
    } else {
      log: {level: "warn"},
      inbounds: [{type: "socks", listen: "127.0.0.1", listen_port: $sport}],
      outbounds: [({type: $kind, server: "127.0.0.1", server_port: $port, password: $pass,
        tls: ({enabled: true, server_name: $sni} + (if $ca != "" then {certificate_path: $ca} else {} end))}
        + (if $kind == "tuic" then {uuid: $id, congestion_control: "bbr", tls:
            ({enabled: true, server_name: $sni, alpn: ["h3"]} + (if $ca != "" then {certificate_path: $ca} else {} end))} else {} end))]
    } end' >"$file" || return 1
  chmod 600 "$file"
}
selftest_probe() ( # $1 目录 $2 socks 端口 $3 协议；其余为客户端命令。
  local dir=$1 port=$2 kind=$3 pid="" i url code eip
  shift 3
  trap - ERR
  trap 'if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; rm -rf "$dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  env GOMEMLIMIT=24MiB GOGC=50 "$@" >"${dir}/client.log" 2>&1 &
  pid=$!
  for (( i=0; i<10; i++ )); do
    sleep 0.5
    kill -0 "$pid" 2>/dev/null || break
    port_in_use tcp "$port" && break
  done
  if ! kill -0 "$pid" 2>/dev/null || ! port_in_use tcp "$port"; then
    warn "临时客户端未能启动，请核对内核版本、证书和参数。"
    exit 1
  fi
  while IFS= read -r url; do
    code=$(curl --noproxy '' -s -o /dev/null --connect-timeout 8 -m 12 --socks5-hostname "127.0.0.1:${port}" -w '%{http_code}' "$url" 2>/dev/null) || code=""
    if [[ $code == 204 || $code == 200 ]]; then
      ok "本机节点请求 ${url#https://} 返回 HTTP ${code}。"
      if [[ $kind == reality ]] && relay_active; then
        eip=$(curl --noproxy '' -s --connect-timeout 8 -m 12 --socks5-hostname "127.0.0.1:${port}" https://api64.ipify.org 2>/dev/null | tr -d '[:space:]') || eip=""
        if [[ -n $eip ]]; then ok "已配置落地 $(relay_tag)，经节点查询的出口 IP：${eip}。"
        else warn "经落地转发查询出口 IP 失败。"; fi
      fi
      exit 0
    fi
  done < <(selftest_urls)
  # 测试站本身不可达时，不把外网故障误报为握手失败。
  while IFS= read -r url; do
    code=$(curl --noproxy '*' -s -o /dev/null --connect-timeout 3 -m 5 -w '%{http_code}' "$url" 2>/dev/null) || code=""
    if [[ $code == 204 || $code == 200 ]]; then
      warn "本机直连外网正常，经节点失败；请核对认证、TLS 和服务日志（proxy status）。"
      exit 1
    fi
  done < <(selftest_urls)
  warn "本机直连测试站也失败，无法确定协议握手状态；请先检查外网连通性。"
  exit 2
)
protocol_selftest() { # 在原有各协议入口中共用临时客户端流程，不修改正式配置。
  local kind=$1 label result binary dest rc dir port
  case $kind in
    reality) label=REALITY; result=REALITY_SELFTEST; binary=$XRAY_BIN; dest=${XRAY_PORT:-}; [[ ${REALITY_ENABLED:-1} == 1 ]] || return 0 ;;
    xhttp) label=XHTTP; result=XHTTP_SELFTEST; binary=$XRAY_BIN; dest=${XHTTP_PORT:-}; xhttp_shared && dest=$XRAY_PORT; [[ ${XHTTP_ENABLED:-0} == 1 ]] || return 0 ;;
    hy2) label=Hysteria2; result=HY2_SELFTEST; binary=$HY_BIN; dest=${HY2_PORT:-}; [[ ${HY2_ENABLED:-0} == 1 ]] || return 0 ;;
    tuic) label=TUIC; result=TUIC_SELFTEST; binary=$SB_BIN; dest=${TUIC_PORT:-}; [[ ${TUIC_ENABLED:-0} == 1 ]] || return 0 ;;
    anytls) label=AnyTLS; result=ANYTLS_SELFTEST; binary=$SB_BIN; dest=${ANYTLS_PORT:-}; [[ ${ANYTLS_ENABLED:-0} == 1 ]] || return 0 ;;
    *) return 1 ;;
  esac
  printf -v "$result" skip
  if [[ ! -x $binary ]] || ! is_port "$dest"; then warn "跳过 ${label} 自检（缺少内核或有效端口）。"; return 0; fi
  case $kind in
    reality|xhttp) [[ -n ${UUID:-} && -n ${PUB_KEY:-} && -n ${SNI:-} && -n ${SHORT_ID:-} ]] || return 0 ;;
    hy2) [[ -n ${HY2_PASS:-} ]] || return 0 ;;
    tuic) [[ -n ${UUID:-} && -n ${TUIC_PASS:-} ]] || return 0 ;;
    anytls) [[ -n ${ANYTLS_PASS:-} ]] || return 0 ;;
  esac
  mktmp
  dir=$(mktemp -d "${TMP_DIR}/${kind}-self.XXXXXX") || return 0
  if ! port=$(selftest_socks_port "$dest"); then rm -rf "$dir"; warn "跳过 ${label} 自检（没有空闲的临时端口）。"; return 0; fi
  if ! selftest_client_config "$kind" "$port" "$dest" "${dir}/client.json"; then rm -rf "$dir"; warn "跳过 ${label} 自检（生成临时配置失败）。"; return 0; fi
  info "${label} 自检：临时客户端 127.0.0.1:${port} → 本机 127.0.0.1:${dest} ..."
  local -a args
  case $kind in
    reality|xhttp) args=("$binary" run -config "${dir}/client.json") ;;
    hy2) args=("$binary" client -c "${dir}/client.json") ;;
    *) args=("$binary" run -c "${dir}/client.json") ;;
  esac
  if selftest_probe "$dir" "$port" "$kind" "${args[@]}"; then printf -v "$result" ok
  else
    rc=$?
    if (( rc == 1 )); then
      printf -v "$result" fail
      [[ $kind != xhttp ]] || warn "XHTTP 客户端 mode 应为 stream-one，path 必须与服务端一致。"
    elif (( rc == 130 || rc == 143 )); then return "$rc"
    fi
  fi
  return 0
}
reality_selftest() { REALITY_SELFTEST=skip; protocol_selftest reality; }
xhttp_selftest() { XHTTP_SELFTEST=skip; protocol_selftest xhttp; }
hy2_selftest() { HY2_SELFTEST=skip; protocol_selftest hy2; }
tuic_selftest() { TUIC_SELFTEST=skip; protocol_selftest tuic; }
anytls_selftest() { ANYTLS_SELFTEST=skip; protocol_selftest anytls; }
