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
      xhttp-tls|ws) cdn_explain nat; return 1 ;;
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
      xhttp-tls) cdn_choose_port XHTTP_TLS_PORT "" "VLESS + XHTTP + TLS（CDN）" "${XHTTP_TLS_PORT:-2083}" ;;
      ws) cdn_choose_port WS_PORT "" "VLESS + WebSocket + TLS（CDN）" "${WS_PORT:-2087}" ;;
    esac
  fi
}
xhttp_443_apply() { # $1 = 1 共用，0 分开
  local on=$1
  (( REALITY_ENABLED && XHTTP_ENABLED )) || { warn "共用端口需要同时打开 Vision 和 XHTTP。"; return 1; }
  if [[ $on == 1 ]]; then
    XHTTP_ON_443=1
    XHTTP_EXT_PORT=""
  else
    XHTTP_ON_443=0
    proto_ensure_port xhttp || { XHTTP_ON_443=1; warn "没有单独的端口，仍与 Vision 共用。"; return 1; }
  fi
  apply_proto_services
  if [[ $on == 1 ]]; then ok "XHTTP 与 Vision 共用 TCP $(pub_xray_port)。"
  else ok "XHTTP 使用单独端口 $(pub_xhttp_port)。"; fi
  show_info
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
      "AnyTLS  $([[ $ANYTLS_ENABLED == 1 ]] && echo "$on" || echo "$off")" \
      "VLESS + XHTTP + TLS（CDN）  $([[ $XHTTP_TLS_ENABLED == 1 ]] && echo "$on" || echo "$off")" \
      "VLESS + WebSocket + TLS（CDN）  $([[ $WS_ENABLED == 1 ]] && echo "$on" || echo "$off")" \
      "CDN 的 VLESS Encryption  $(vless_enc_label)"
    printf '%s第 9 项只给第 7、8 项加密，不影响 REALITY 和 Hysteria2。sing-box 内核的客户端可能不支持。%s\n' "$C_DIM" "$C_NONE"
    if (( REALITY_ENABLED && XHTTP_ENABLED )); then
      printf '  s) XHTTP 与 Vision 共用 TCP %s    当前: %s\n' "$(pub_xray_port)" "$(xhttp_shared && echo 开 || echo 关)"
    fi
    if [[ -n $OPT_XHTTP_ON_443 ]]; then
      xhttp_443_apply "$OPT_XHTTP_ON_443" || true
      OPT_XHTTP_ON_443=""
      return 0
    fi
    local c kind var
    ask c "请选择" "0"
    if [[ $c == s || $c == S ]]; then xhttp_443_apply "$(xhttp_shared && echo 0 || echo 1)"; continue; fi
    if [[ $c == 9 ]]; then
      menu_vless_enc
      continue
    fi
    case $c in
      1) kind=reality; var=REALITY_ENABLED ;;
      2) kind=xhttp; var=XHTTP_ENABLED ;;
      3) kind=hy2; var=HY2_ENABLED ;;
      4) kind=trojan; var=TROJAN_ENABLED ;;
      5) kind=tuic; var=TUIC_ENABLED ;;
      6) kind=anytls; var=ANYTLS_ENABLED ;;
      7) kind=xhttp-tls; var=XHTTP_TLS_ENABLED ;;
      8) kind=ws; var=WS_ENABLED ;;
      *) return 0 ;;
    esac
    if (( ${!var} )); then
      if [[ $kind == reality ]] && xhttp_shared; then
        XHTTP_ON_443=0
        if ! proto_ensure_port xhttp; then
          XHTTP_ON_443=1
          warn "没有单独的端口给 XHTTP，Vision 保持打开。"
          continue
        fi
      fi
      printf -v "$var" 0
      if ! proto_any_enabled; then
        printf -v "$var" 1
        warn "至少保留一个协议。"
        continue
      fi
      info "已关闭（密钥保留）。"
    else
      printf -v "$var" 1
      if [[ $kind == xhttp-tls || $kind == ws ]]; then
        if ! cdn_prepare_enable "$kind"; then
          printf -v "$var" 0
          cdn_sync_flag
          save_state
          warn "没有打开。REALITY 和原来的协议保持原样。"
          continue
        fi
      elif [[ $kind == xhttp ]] && (( REALITY_ENABLED )) && confirm "与 Vision 共用 TCP $(pub_xray_port)？" n; then
        XHTTP_ON_443=1
        XHTTP_EXT_PORT=""
      elif ! proto_ensure_port "$kind"; then
        printf -v "$var" 0
        [[ $kind == xhttp ]] && XHTTP_ON_443=0
        warn "没有可用端口，保持关闭。"
        continue
      else
        [[ $kind == xhttp ]] && XHTTP_ON_443=0
      fi
      info "已开启。"
    fi
    if [[ $kind == hy2 && $HY2_ENABLED == 1 && ! -x $HY_BIN ]]; then install_hysteria; fi
    if [[ $kind == hy2 && $HY2_ENABLED == 0 ]]; then svc_disable_stop hysteria-server; remove_nat_hop; fi
    apply_proto_services
    ok "协议状态已更新。"
    if [[ $kind == xhttp-tls || $kind == ws ]] && (( ${!var} == 1 )); then
      cdn_print_tutorial "$kind"
      cdn_run_checks "$kind" || warn "检查没有全部通过。按上面的说明改完后执行 proxy cdn。"
    fi
    show_info
  done
}
menu_vless_enc() { # 协议开关第 9 项：开 / 关 CDN 线路的 VLESS Encryption
  local act=on rc=0
  [[ ${VLESS_ENC:-} == 1 ]] && act=off
  vless_enc_print_status
  if [[ $act == off ]]; then
    confirm "关闭 CDN 线路的 VLESS Encryption？链接改回 encryption=none，Cloudflare 能看到明文 VLESS。" n || return 0
  else
    confirm "开启 CDN 线路的 VLESS Encryption？CDN 链接会变，要重新导入；sing-box 内核的客户端可能连不上。" y || return 0
  fi
  set +e
  ( set -e; OPT_VENC_ACT=$act; do_vless_enc )
  rc=$?
  set -e
  (( rc == 0 )) || warn "VLESS Encryption 没有改动（退出码 ${rc}）。"
  load_state
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
  if land_in_on; then ui_stat_row "落地入站" "TCP+UDP $(pub_land_port)" "出口" "$(land_in_egress_label)"; fi
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
    "协议开关" \
    "申请证书" \
    "回程线路检测" \
    "导出配置（迁到另一台机器）" \
    "导入配置" \
    "健康检查" \
    "落地入站（与本机节点同时开启）"
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
    17) act=menu_cert ;;
    18) act=do_route ;;
    19) act=menu_export ;;
    20) act=menu_import ;;
    21) act=menu_doctor ;;
    22) act=menu_land_in ;;
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
  ui_stat_row "出口" "$(land_egress_label)"
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
    "切换 NAT 模式（当前: $(nat_pref_text)）" \
    "回程线路检测" \
    "出口：本机直连（清除下一跳与原样转发）" \
    "出口：加密转发（SS2022 再加密到下一跳）" \
    "出口：原样转发（不解密，DNAT 到最终落地）" \
    "导出配置（迁到另一台机器）" \
    "导入配置" \
    "健康检查"
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
    12) act=do_route ;;
    13) act=menu_land_direct ;;
    14) act=menu_land_relay ;;
    15) act=menu_land_raw ;;
    16) act=menu_export ;;
    17) act=menu_import ;;
    18) act=menu_doctor ;;
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
  --outbound <策略>   出站：46 IPv4优先 / 64 IPv6优先 / 4 仅IPv4 / 6 仅IPv6 / auto 按检测
                      内网 ULA（fc00::/7）若 NAT66 到公网 IPv6，按双栈，可选 IPv6优先
  --sni <域名>        指定 REALITY 目标网站（会进行合规检测）
  --force-sni         与 --sni 一起使用：检测不通过也强制使用
  --scan              使用 RealiTLScanner 扫描 VPS 附近 IP 寻找 SNI（高级，约 60 秒）
  --port <端口>       VLESS-REALITY TCP 端口（默认 443）
  --hy2 / --no-hy2    安装 / 不安装 Hysteria2（默认安装）
  --hy2-port <端口>   Hysteria2 UDP 端口（默认 443）
  --reality / --no-reality
                      开启 / 关闭 VLESS + REALITY + Vision（默认开启）
  --xhttp / --no-xhttp
                      开启 / 关闭 VLESS + XHTTP + REALITY（默认开启，免自己的域名）
  --xhttp-port <端口> XHTTP 的 TCP 端口（默认 8443；NAT 模式为外部端口）
  --xhttp-on-443      XHTTP 与 Vision 共用同一个 TCP 端口（默认仍是分开的 8443）
  --no-xhttp-on-443   XHTTP 使用单独端口
  --trojan            额外启用 Trojan + REALITY（默认不装）
  --no-trojan         关闭 Trojan
  --trojan-port <端口> Trojan TCP 端口（默认 8444）
  --tuic              额外启用 TUIC v5（sing-box，自签证书，默认不装）
  --no-tuic           关闭 TUIC
  --tuic-port <端口>  TUIC UDP 端口（默认 8446）
  --anytls            额外启用 AnyTLS（sing-box，自签证书，默认不装）
  --no-anytls         关闭 AnyTLS
  --anytls-port <端口> AnyTLS TCP 端口（默认 8445）
  --xhttp-tls         额外启用 VLESS + XHTTP + TLS（放在 CDN 后面，默认不装）
                      需要 --cert-domain。不替换 REALITY，也不要把 REALITY 放进 CDN
  --no-xhttp-tls      关闭这条 CDN 线路
  --xhttp-tls-port <端口>  回源端口（默认 2083，须是 Cloudflare 允许的 HTTPS 端口）
  --ws-tls / --ws     额外启用 VLESS + WebSocket + TLS（放在 CDN 后面，默认不装）
  --no-ws-tls / --no-ws
                      关闭这条 CDN 线路
  --ws-port <端口>    回源端口（默认 2087）
  --vless-enc         两条 CDN 线路加 VLESS Encryption（默认就是加，ML-KEM-768 + X25519）
  --no-vless-enc      不加。sing-box 内核的客户端可能不支持时用它；不加时 Cloudflare 能看到明文 VLESS
  --hop <a-b|none>    Hysteria2 端口跳跃范围（默认 20000-50000，none 关闭）
  --no-hop            关闭端口跳跃（同 --hop none）
  --name <名称>       节点名称（默认 国家-城市）
  --cert-domain <域名>  可选：为自有域名申请证书。不写 --cert-kind 时是
                      Let's Encrypt 单域名 HTTP-01（默认）。订阅只走 HTTPS；
                      Hysteria2 / TUIC / AnyTLS 改用该证书和域名。
                      REALITY 仍借用伪装站点。NAT 模式不可用
  --cert-kind <种类>  le（默认）| wildcard | multi | zerossl | zerossl-wildcard
                      | zerossl-multi | cf-origin
                      通配符走 DNS-01。cf-origin 是 Cloudflare 源站证书，
                      只有 Cloudflare 信任，只能给两条 CDN 线路
  --cert-names <列表> 多域名或源站证书的名字，逗号分隔
  --cert-link <主机名> 通配符证书写进链接的具体名字，默认是根域名
  --cert-email <邮箱> 可选，登记给证书机构；不填则不登记邮箱
  --cf-dns-token <令牌>  Cloudflare API 令牌，只用于通配符的 DNS-01
                      权限要有 Zone.DNS 编辑和 Zone 读取。不是 Origin CA Key
  --cf-origin-key <钥匙> Cloudflare Origin CA Key。写了就申请源站证书
  --zerossl-kid <id>  ZeroSSL 的 EAB KID，须和 --zerossl-hmac 成对
  --zerossl-hmac <key> ZeroSSL 的 EAB HMAC
  --sub-port <端口>   订阅 HTTPS 端口（默认 8447，不能是 80，也不能占用 REALITY）
                      源站证书不会打开订阅
  --no-cert           关闭已申请的证书，Hysteria2 / TUIC / AnyTLS 改回自签
                      开着的 CDN 线路一并关掉（不能改用自签）
  --firewall <模式>   strict 入站默认拒绝 | allow 只放行（不接管入站）| off 不写 nftables
                      不写时：干净机器默认 strict；检测到 Docker/Podman、WireGuard、
                      已有防火墙或多个非标准端口时，交互安装默认推荐 allow，
                      非交互安装直接用 allow。allow 时若 ufw 或 firewalld 正在运行，
                      会把代理端口写进它们。--no-firewall 同 off
  --no-firewall       不配置 nftables 防火墙（同 --firewall off）
  --no-upgrade        跳过系统软件包升级
  --xray-ver <版本>   安装指定的 Xray 发布标签（例如 v26.3.27）。直接下载该版本，校验通过后才替换
  --hy2-ver <版本>    安装指定的 Hysteria2 发布标签（例如 v2.6.1 或 app/v2.6.1）
  --singbox-ver <版本> 安装指定的 sing-box 发布标签（例如 v1.11.0）
  --no-tune           跳过 sysctl 网络调优
  --tune-preset <名>  安装/调优使用的预设（默认 bbr-fq，见下方「网络调优」）
  -h, --help          显示帮助

双栈（同时有 IPv4 和 IPv6）写入节点配置时询问出站策略：IPv4优先 / IPv6优先 / 仅IPv4 / 仅IPv6（记在 state.env，之后沿用；--auto 默认 IPv4优先；只有一种地址时不询问）。
本机 IPv6 只有内网 ULA（fc00::/7，例如 fd42::）时，会用 curl -6 探测。若回显是公网 IPv6（NAT66），按双栈处理，可以选 IPv6优先。回显仍是 ULA 或探测失败，则当作没有 IPv6。
落地机（--land）和节点上的落地入站使用同一套出站策略，写进 Xray freedom 的 domainStrategy。加密下一跳另外带 sockopt.domainStrategy。
  --outbound 46|64|4|6|auto    直接指定。auto 清掉已记住的选择，再按本次检测决定。可与 --land 一起用。
  proxy outbound                  查看检测结果
  proxy outbound 64               设为 IPv6优先；节点或落地机已安装时重写配置并重启

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
  --land              安装为纯落地机：只运行 Xray Shadowsocks 2022（TCP+UDP），无 Reality/Hy2，内存占用最低
                      可与 --nat（NAT 映射端口 / Alpine）、--port、--name、--auto、--outbound 组合
                      若同时写上 --reality / --hy2 / --xhttp / --trojan / --tuic / --anytls / --xhttp-tls / --ws，
                      则是普通节点再加一条落地入站（与 --with-land 相同）。--no-hy2 这种关闭不算
  --with-land         普通节点同时开落地入站（自己的端口、密钥、白名单）。不关掉 Reality / Hy2
  --no-with-land      重装时关掉落地入站（密钥保留）。--no-land 且不带 --with-land 也会关掉
  --land-port <端口>  落地入站端口（随机或指定；NAT 可写 外部:内部）。纯 --land 且没写 --port 时当作落地端口
  --land-method <m>   aes-128（默认 2022-blake3-aes-128-gcm）| aes-256 | chacha20
  --land-allow <列表> 来源 IP 白名单（只允许中转机；IPv4/IPv6/CIDR，逗号分隔；none = 不限制）
  --no-land           纯落地机改装回 Reality / Hysteria2 节点。不带 --with-land 时不保留落地入站
  例: bash proxy.sh --land --auto --land-allow 203.0.113.10          # 纯落地机，只允许中转机 203.0.113.10
      bash proxy.sh --land --nat --auto --port 52430:8388            # NAT 落地机：公网 52430 → 内部 8388
      bash proxy.sh --with-land --auto --land-port 8388              # 节点 + 落地入站
      bash proxy.sh --land --reality --hy2 --auto --land-port 8388   # 同上，--land 与节点协议一起写
  proxy land-enable [--land-port 端口] [--land-method m] [--land-allow 列表]
                                    已安装的节点上补开落地入站。不重装，不改 Reality / Hy2 的密钥和链接
  proxy land-disable                关掉落地入站（密钥、白名单、下一跳留着）。节点和 land-add 不动
  proxy allow [--land-allow 列表]   修改落地来源白名单（纯落地机，或已开启落地入站的节点）
  proxy land-add 'ss://...'         节点：添加 / 替换本机出站的落地，测试后设为默认出站（--force 测试失败也启用）
                                    纯落地机：加密转发。本机 SS2022 入站，再 SS2022 到下一跳。不装 hy2-relay
                                    节点上另有落地入站时，land-add 不改变那条入站的出口
  proxy land-next 'ss://...'        节点上落地入站自己的加密下一跳（出站 tag ss-out）。不改本机 land-add
                                    纯落地机上与 land-add 相同
  proxy land-next-on | land-next-off | land-next-del
                                    重新启用 / 停用 / 删除落地入站的下一跳。纯落地机上分别等于 land-on / land-off / land-del
  proxy land-on                     节点：重新启用已保存的 land-add。纯落地机：重新启用已保存的下一跳（并去掉 DNAT）
  proxy land-off                    节点：停用 land-add，保留链接。纯落地机：停用当前的加密转发或原样转发，保留链接
                                    节点上的落地入站不受影响；停它的出口用 land-next-off 或 land-direct
  proxy land-del                    节点：删除 land-add 链接。纯落地机：只删除加密转发的下一跳
  proxy land-direct | land-clear    纯落地机：本机直连。清除下一跳、原样转发目标和 DNAT
                                    节点上的落地入站：只清这条入站自己的下一跳和原样转发，不改 land-add
  proxy land-forward 'ss://...'     原样转发，同 land-raw。不解密，DNAT 到链接里的主机和端口
  proxy land-raw 'ss://...'         上一跳链接 = 本机地址/对外端口 + 最终落地的加密方式与密钥
                                    最终落地原地址单独标出。白名单里没有目标地址族时拒绝，不装开放 DNAT
                                    节点同时开着时，DNAT 只占落地端口，不停 Xray
  proxy land-forward-off | land-raw-off   只停用原样转发（去掉 DNAT，保留目标）
  proxy land-forward-del | land-raw-del   只删除原样转发目标
  proxy land-test                   节点：测试 land-add。纯落地机：测试下一跳或最终落地的 TCP
                                    节点上没有 land-add、但落地入站有自己的出口时，测试那条出口
  proxy land                        菜单（纯落地机上显示链接；节点进入 land-add 菜单。落地入站是菜单第 22 项）

管理命令:
  proxy               打开交互菜单（节点菜单第 22 项是落地入站，不改 1–21）
  proxy info          查看链接 / 二维码 / mihomo 配置
  proxy cert          选择证书种类 / 续期 / 关闭（默认 Let's Encrypt 单域名）
  proxy cdn           查看 CDN 线路教程并复查（XHTTP+TLS / WebSocket+TLS）
  proxy vless-enc     查看 CDN 线路的 VLESS Encryption。on / off 开关，rotate 换新钥匙
                      只重写 Xray 并刷新链接和订阅，不重装；REALITY 等不变
  proxy proto         协议开关（菜单第 16 项）。逐个开/关，不删除已有密钥
                      默认开：Vision、XHTTP+REALITY、Hysteria2
                      默认关：Trojan、TUIC、AnyTLS，以及 CDN 的 XHTTP+TLS / WebSocket+TLS
                      关闭只停止监听。这里关掉 Hysteria2 不删除程序；
                      重新安装时 --no-hy2 会移除它（密码仍留在 state.env）
                      Vision 和 XHTTP 都开着时，菜单里的 s 切换是否共用 TCP 端口
  proxy proto xhttp-443 on|off
                      XHTTP 与 Vision 共用 / 分开 TCP 端口（Xray fallbacks）
  proxy sni           重新优选 / 更换 SNI
  proxy regen         重新生成全部密钥
  proxy port          修改端口。可带 --port、--hy2-port、--xhttp-port；同步开启时 ufw/firewalld 跟着改
  proxy user          用户管理
  proxy update        更新组件。菜单里可以回滚到 .bak
  proxy update --xray-ver <版本> [--hy2-ver <版本>] [--singbox-ver <版本>]
                      只把写出的内核换成这个已经发布的版本
  proxy update --rollback [xray|hy2|singbox|all]
                      用 <程序>.bak 换回并重启服务，打印 旧版本 -> 新版本
                      不写目标时回滚这三个，没有 .bak 的跳过。点名某一个却没有 .bak 时失败退出
                      systemd 和 OpenRC 都用同一套重启
  proxy update-script 只更新本脚本
  proxy export [文件]  导出密钥和证书（权限 600）。--password 加密；没有终端时请设置 PROXY_EXPORT_PASS
  proxy import <文件>  导入后重新检测 IP、NAT、SNI 和防火墙
  bash proxy.sh --import <文件> [--auto]   同上，可加原来的安装参数
  proxy status        运行状态 / 日志 / 防火墙放行了哪些端口
  proxy doctor        只读健康检查（时间、服务、端口、nftables、ufw/firewalld 同步、
                      端口跳跃计数、SNI、回环自检、证书到期）。有失败项时退出码非 0
  proxy doctor --fix  只做安全修复：拉起已停止的服务、对时、按清单重写防火墙同步、
                      把 state.env 改为 600。这次有过失败项时会再查一遍。
                      没有失败项时退出码为 0
  proxy speed         测速 / 延迟提示
  proxy firewall      查看已放行端口并管理防火墙（NAT 模式为端口映射）
  proxy firewall strict|allow|off
                      切换防火墙模式，不重装。strict 默认拒绝，allow 只放行，off 关闭
  proxy nat           NAT 信息 / 修改映射端口 / 端口跳跃
  proxy tune          网络调优（见上）
  proxy route         回程线路检测（电信 / 联通 / 移动，北京 / 上海 / 广州；不改配置、不重启）
  proxy route ipv4    只测 IPv4（默认就是 IPv4）
  proxy route ipv6    只测 IPv6
  proxy route all     IPv4 和 IPv6 都测
  proxy route icmp    改用 ICMP（默认先 TCP，没有回应再试 ICMP）
  proxy route verbose 多打出每一跳。可与 ipv4 / ipv6 / icmp 一起写
  proxy outbound      查看出站地址族（含 NAT66）。proxy outbound 46|64|4|6|auto 设置并应用
  proxy land          落地转发 / 落地机信息（见上）
  proxy uninstall     卸载

回程线路检测（未安装节点也可以；NAT 模式也可以。不改代理、不重启、不测流媒体）:
  只测从本机发向大陆的回程。不测国际线路，也不测从家里到本机的去程。
  缺 nexttrace 时会自动安装。默认 TCP，单节点超时就停，不会一直等。
USAGE
}

parse_args() {
  while (( $# )); do
    case $1 in
      --auto|-y) OPT_AUTO=1 ;;
      --outbound)
        [[ -n ${2-} ]] || die "--outbound 需要参数：46、64、4、6 或 auto"
        case ${2,,} in
          46|64|4|6|auto) OPT_OUTBOUND=${2,,} ;;
          *) die "--outbound 参数无效: $2（可选 46、64、4、6、auto）" ;;
        esac
        shift ;;
      --outbound=*)
        OPT_OUTBOUND=${1#*=}
        case ${OPT_OUTBOUND,,} in
          46|64|4|6|auto) OPT_OUTBOUND=${OPT_OUTBOUND,,} ;;
          *) die "--outbound 参数无效: ${OPT_OUTBOUND}（可选 46、64、4、6、auto）" ;;
        esac
        ;;
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
      --xhttp-on-443) OPT_XHTTP_ON_443=1; OPT_XHTTP=1 ;;
      --no-xhttp-on-443) OPT_XHTTP_ON_443=0 ;;
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
      --xhttp-tls) OPT_XHTTP_TLS=1 ;;
      --no-xhttp-tls) OPT_XHTTP_TLS=0 ;;
      --xhttp-tls-port)
        is_port_opt "${2-}" || die "--xhttp-tls-port 参数无效"; OPT_XHTTP_TLS_PORT=$2; shift ;;
      --xhttp-tls-port=*) OPT_XHTTP_TLS_PORT=${1#*=}; is_port_opt "$OPT_XHTTP_TLS_PORT" || die "--xhttp-tls-port 参数无效" ;;
      --ws-tls|--ws) OPT_WS=1 ;;
      --no-ws-tls|--no-ws) OPT_WS=0 ;;
      --ws-port)
        is_port_opt "${2-}" || die "--ws-port 参数无效"; OPT_WS_PORT=$2; shift ;;
      --ws-port=*) OPT_WS_PORT=${1#*=}; is_port_opt "$OPT_WS_PORT" || die "--ws-port 参数无效" ;;
      --vless-enc) OPT_VLESS_ENC=1 ;;
      --no-vless-enc) OPT_VLESS_ENC=0 ;;
      vless-enc|vlessenc)
        OPT_ACTION=vless-enc
        case ${2-} in
          on|enable) OPT_VENC_ACT=on; shift ;;
          off|disable) OPT_VENC_ACT=off; shift ;;
          rotate|regen|rekey) OPT_VENC_ACT=rotate; shift ;;
          status|show) shift ;;
          ""|-*) ;;
          *) die "proxy vless-enc 的参数只能是 on、off 或 rotate（不带参数为查看）: $2" ;;
        esac ;;
      --hop) [[ ${2-} == none ]] || is_range "${2-}" || valid_segs "${2-}" || die "--hop 参数无效（例如 20000-50000 或 none）"; OPT_HOP=$2; shift ;;
      --no-hop) OPT_HOP=none ;;
      --name) [[ -n ${2-} ]] || die "--name 需要参数"; OPT_NAME=$(tr -cd 'A-Za-z0-9_.-' <<<"$2"); shift ;;
      --cert-domain)
        [[ -n ${2-} ]] || die "--cert-domain 需要域名"
        OPT_CERT_DOMAIN=${2,,}; OPT_CERT_DOMAIN=${OPT_CERT_DOMAIN%.}
        cert_domain_syntax "$OPT_CERT_DOMAIN" || die "--cert-domain 不是可用的域名: $2（不能是 IP）"
        OPT_CERT=1; shift ;;
      --cert-domain=*)
        OPT_CERT_DOMAIN=${1#*=}; OPT_CERT_DOMAIN=${OPT_CERT_DOMAIN,,}; OPT_CERT_DOMAIN=${OPT_CERT_DOMAIN%.}
        cert_domain_syntax "$OPT_CERT_DOMAIN" || die "--cert-domain 不是可用的域名: ${OPT_CERT_DOMAIN}（不能是 IP）"
        OPT_CERT=1 ;;
      --cert-email)
        [[ -n ${2-} ]] || die "--cert-email 需要邮箱"
        cert_email_syntax "$2" || die "--cert-email 格式无效: $2"
        OPT_CERT_EMAIL=$2; shift ;;
      --cert-email=*)
        cert_email_syntax "${1#*=}" || die "--cert-email 格式无效: ${1#*=}"
        OPT_CERT_EMAIL=${1#*=} ;;
      --cert-kind)
        [[ -n ${2-} ]] || die "--cert-kind 需要种类：le、wildcard、multi、zerossl、zerossl-wildcard、zerossl-multi、cf-origin"
        OPT_CERT_KIND=$(cert_normalize_kind "$2") || die "--cert-kind 无法识别: $2"
        OPT_CERT=1; shift ;;
      --cert-kind=*)
        OPT_CERT_KIND=$(cert_normalize_kind "${1#*=}") || die "--cert-kind 无法识别: ${1#*=}"
        OPT_CERT=1 ;;
      --cert-names)
        [[ -n ${2-} ]] || die "--cert-names 需要用逗号分隔的域名"
        OPT_CERT_NAMES=$(cert_norm_names "$2") || die "--cert-names 里有无效域名: $2"
        OPT_CERT=1; shift ;;
      --cert-names=*)
        OPT_CERT_NAMES=$(cert_norm_names "${1#*=}") || die "--cert-names 里有无效域名: ${1#*=}"
        OPT_CERT=1 ;;
      --cert-link)
        [[ -n ${2-} ]] || die "--cert-link 需要主机名"
        OPT_CERT_LINK=${2,,}; OPT_CERT_LINK=${OPT_CERT_LINK%.}
        cert_domain_syntax "$OPT_CERT_LINK" || die "--cert-link 不是可用的主机名: $2"
        shift ;;
      --cert-link=*)
        OPT_CERT_LINK=${1#*=}; OPT_CERT_LINK=${OPT_CERT_LINK,,}; OPT_CERT_LINK=${OPT_CERT_LINK%.}
        cert_domain_syntax "$OPT_CERT_LINK" || die "--cert-link 不是可用的主机名: ${OPT_CERT_LINK}" ;;
      --cf-dns-token)
        [[ -n ${2-} ]] || die "--cf-dns-token 需要 Cloudflare API 令牌"
        OPT_CF_DNS_TOKEN=$2; shift ;;
      --cf-dns-token=*) OPT_CF_DNS_TOKEN=${1#*=}; [[ -n $OPT_CF_DNS_TOKEN ]] || die "--cf-dns-token 需要 Cloudflare API 令牌" ;;
      --cf-origin-key)
        [[ -n ${2-} ]] || die "--cf-origin-key 需要 Origin CA Key"
        OPT_CF_ORIGIN_KEY=$2
        [[ -n $OPT_CERT_KIND ]] || OPT_CERT_KIND=cf-origin
        OPT_CERT=1; shift ;;
      --cf-origin-key=*)
        OPT_CF_ORIGIN_KEY=${1#*=}
        [[ -n $OPT_CF_ORIGIN_KEY ]] || die "--cf-origin-key 需要 Origin CA Key"
        [[ -n $OPT_CERT_KIND ]] || OPT_CERT_KIND=cf-origin
        OPT_CERT=1 ;;
      --zerossl-kid)
        [[ -n ${2-} ]] || die "--zerossl-kid 需要 EAB KID"
        OPT_ZEROSSL_KID=$2; OPT_CERT=1; shift ;;
      --zerossl-kid=*) OPT_ZEROSSL_KID=${1#*=}; [[ -n $OPT_ZEROSSL_KID ]] || die "--zerossl-kid 需要 EAB KID"; OPT_CERT=1 ;;
      --zerossl-hmac)
        [[ -n ${2-} ]] || die "--zerossl-hmac 需要 EAB HMAC"
        OPT_ZEROSSL_HMAC=$2; OPT_CERT=1; shift ;;
      --zerossl-hmac=*) OPT_ZEROSSL_HMAC=${1#*=}; [[ -n $OPT_ZEROSSL_HMAC ]] || die "--zerossl-hmac 需要 EAB HMAC"; OPT_CERT=1 ;;
      --sub-port)
        is_port "${2-}" || die "--sub-port 参数无效"
        [[ $2 == 80 ]] && die "--sub-port 不能是 80（80 只用于证书申请的 HTTP-01）"
        OPT_SUB_PORT=$2; shift ;;
      --sub-port=*)
        OPT_SUB_PORT=${1#*=}; is_port "$OPT_SUB_PORT" || die "--sub-port 参数无效"
        [[ $OPT_SUB_PORT == 80 ]] && die "--sub-port 不能是 80（80 只用于证书申请的 HTTP-01）" ;;
      --cert) OPT_CERT=1 ;;
      --no-cert) OPT_CERT=0 ;;
      --firewall)
        [[ -n ${2-} ]] || die "--firewall 需要参数：strict、allow 或 off"
        OPT_FW_MODE=$(fw_norm_mode "$2") || die "--firewall 参数无效: $2（strict、allow 或 off）"
        OPT_FW_SET=1
        shift ;;
      --firewall=*)
        OPT_FW_MODE=$(fw_norm_mode "${1#*=}") || die "--firewall 参数无效: ${1#*=}（strict、allow 或 off）"
        OPT_FW_SET=1 ;;
      --no-firewall) OPT_FW_MODE=off ;;
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
      --with-land) OPT_WITH_LAND=1 ;;
      --no-with-land) OPT_WITH_LAND=0 ;;
      --land-port)
        [[ -n ${2-} ]] || die "--land-port 需要端口"
        is_port_opt "$2" || die "--land-port 参数无效: $2"
        OPT_LAND_PORT=$2; shift ;;
      --land-port=*)
        is_port_opt "${1#*=}" || die "--land-port 参数无效: ${1#*=}"
        OPT_LAND_PORT=${1#*=} ;;
      --land-method) land_norm_method "${2-}" >/dev/null || die "--land-method 参数无效（aes-128 | aes-256 | chacha20）"; OPT_LAND_METHOD=$2; shift ;;
      --land-allow)
        [[ -n ${2-} ]] || die "--land-allow 需要参数（例如 1.2.3.4,2001:db8::/64，或 none）"
        if [[ ${2,,} == none ]]; then OPT_LAND_ALLOW=none; else land_norm_allow "$2" || die "--land-allow 中有无效地址: ${LAND_BAD}"; OPT_LAND_ALLOW=$2; fi
        shift ;;
          --import)
        [[ -n ${2-} && -f ${2-} ]] || die "--import 需要已存在的导出文件"
        OPT_IMPORT=$2; OPT_ACTION=import; shift ;;
      --import=*)
        OPT_IMPORT=${1#*=}; [[ -f $OPT_IMPORT ]] || die "--import 需要已存在的导出文件"
        OPT_ACTION=import ;;
      --password) OPT_EXPORT_ENC=1 ;;
      --force) OPT_FORCE=1 ;;
      land-enable) OPT_ACTION=land-enable ;;
      land-disable) OPT_ACTION=land-disable ;;
      land-next)
        OPT_ACTION=land; OPT_LAND_ACT=next
        if [[ ${2-} == ss://* ]]; then OPT_LAND_LINK=$2; shift; fi ;;
      land-next-on) OPT_ACTION=land; OPT_LAND_ACT=next-on ;;
      land-next-off) OPT_ACTION=land; OPT_LAND_ACT=next-off ;;
      land-next-del|land-next-rm|land-next-remove) OPT_ACTION=land; OPT_LAND_ACT=next-del ;;
      land-add|relay-add)
        OPT_ACTION=land; OPT_LAND_ACT=add
        if [[ ${2-} == ss://* ]]; then OPT_LAND_LINK=$2; shift; fi ;;
      land-forward|land-raw)
        OPT_ACTION=land; OPT_LAND_ACT=forward
        if [[ ${2-} == ss://* ]]; then OPT_LAND_LINK=$2; shift; fi ;;
      land-forward-off|land-raw-off)
        OPT_ACTION=land; OPT_LAND_ACT=forward-off ;;
      land-forward-del|land-raw-del|land-forward-rm|land-raw-rm|land-forward-remove|land-raw-remove)
        OPT_ACTION=land; OPT_LAND_ACT=forward-del ;;
      land-direct|land-clear)
        OPT_ACTION=land; OPT_LAND_ACT=direct ;;
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
      proto|protos|protocol)
        OPT_ACTION=proto
        if [[ ${2-} == xhttp-443 ]]; then
          case ${3-} in
            on|1|enable) OPT_XHTTP_ON_443=1 ;;
            off|0|disable) OPT_XHTTP_ON_443=0 ;;
            *) die "用法: proxy proto xhttp-443 on|off" ;;
          esac
          shift 2
        fi ;;
      sni) OPT_ACTION=sni ;;
      regen|rekey) OPT_ACTION=regen ;;
      port|ports) OPT_ACTION=port ;;
      user|users) OPT_ACTION=user ;;
      --xray-ver)
        [[ -n ${2-} && ${2} != -* ]] || die "--xray-ver 需要版本号（例如 v26.3.27）"
        OPT_XRAY_VER=$2; shift ;;
      --xray-ver=*)
        OPT_XRAY_VER=${1#*=}
        [[ -n $OPT_XRAY_VER && $OPT_XRAY_VER != -* ]] || die "--xray-ver 需要版本号（例如 v26.3.27）" ;;
      --hy2-ver)
        [[ -n ${2-} && ${2} != -* ]] || die "--hy2-ver 需要版本号（例如 v2.6.1）"
        OPT_HY2_VER=$2; shift ;;
      --hy2-ver=*)
        OPT_HY2_VER=${1#*=}
        [[ -n $OPT_HY2_VER && $OPT_HY2_VER != -* ]] || die "--hy2-ver 需要版本号（例如 v2.6.1）" ;;
      --singbox-ver)
        [[ -n ${2-} && ${2} != -* ]] || die "--singbox-ver 需要版本号（例如 v1.11.0）"
        OPT_SINGBOX_VER=$2; shift ;;
      --singbox-ver=*)
        OPT_SINGBOX_VER=${1#*=}
        [[ -n $OPT_SINGBOX_VER && $OPT_SINGBOX_VER != -* ]] || die "--singbox-ver 需要版本号（例如 v1.11.0）" ;;
      --rollback)
        OPT_ACTION=update
        if [[ -n ${2-} && ${2} != -* ]]; then OPT_ROLLBACK=${2,,}; shift
        else OPT_ROLLBACK=all; fi
        case $OPT_ROLLBACK in
          xray) ;;
          hy2|hysteria|hysteria2) OPT_ROLLBACK=hy2 ;;
          singbox|sing-box|sb) OPT_ROLLBACK=singbox ;;
          all) ;;
          *) die "proxy update --rollback 的参数只能是 xray、hy2、singbox 或 all: ${OPT_ROLLBACK}" ;;
        esac ;;
      --rollback=*)
        OPT_ACTION=update
        OPT_ROLLBACK=${1#*=}
        OPT_ROLLBACK=${OPT_ROLLBACK,,}
        case $OPT_ROLLBACK in
          xray) ;;
          hy2|hysteria|hysteria2) OPT_ROLLBACK=hy2 ;;
          singbox|sing-box|sb) OPT_ROLLBACK=singbox ;;
          all) ;;
          *) die "proxy update --rollback 的参数只能是 xray、hy2、singbox 或 all: ${OPT_ROLLBACK}" ;;
        esac ;;
      update|upgrade) OPT_ACTION=update ;;
      export)
        OPT_ACTION="export"
        if [[ ${2-} == --password ]]; then OPT_EXPORT_ENC=1; shift; fi
        if [[ -n ${2-} && ${2} != -* ]]; then OPT_EXPORT_PATH=$2; shift; fi ;;
      import)
        [[ -n ${2-} ]] || die "用法: proxy import 文件"
        OPT_IMPORT=$2; OPT_ACTION=import; shift ;;
      update-script) OPT_ACTION=update-script ;;
      status|log|logs) OPT_ACTION=status ;;
      doctor)
        OPT_ACTION=doctor
        if [[ ${2-} == --fix ]]; then OPT_DOCTOR_FIX=1; shift; fi ;;
      speed) OPT_ACTION=speed ;;
      firewall|fw)
        OPT_ACTION=firewall
        case ${2-} in
          strict|allow|allow-only|allowonly|gentle|off|none|disable|drop|on|enable)
            OPT_FW_MODE=$(fw_norm_mode "$2") || die "proxy firewall 的参数无效: $2（strict、allow 或 off）"
            shift ;;
          ""|-*) ;;
          *) die "proxy firewall 的参数只能是 strict、allow 或 off: $2" ;;
        esac ;;
      nat) OPT_ACTION=nat ;;
      route|routes)
        OPT_ACTION=route
        while [[ -n ${2-} ]]; do
          case ${2,,} in
            4|ipv4|v4) OPT_ROUTE_FAM=4; shift ;;
            6|ipv6|v6) OPT_ROUTE_FAM=6; shift ;;
            all|both) OPT_ROUTE_FAM=all; shift ;;
            icmp) OPT_ROUTE_PROTO=icmp; shift ;;
            tcp) OPT_ROUTE_PROTO=tcp; shift ;;
            verbose|-v|--verbose) OPT_ROUTE_VERBOSE=1; shift ;;
            *) break ;;
          esac
        done
        ;;
      outbound)
        OPT_ACTION=outbound
        if [[ -n ${2-} ]]; then
          case ${2,,} in
            46|64|4|6|auto) OPT_OUTBOUND=${2,,}; shift ;;
          esac
        fi
        ;;
      cert|acme) OPT_ACTION=cert ;;
      cdn) OPT_ACTION=cdn ;;
      uninstall|remove) OPT_ACTION=uninstall ;;
      *) usage; die "未知参数: $1" ;;
    esac
    shift
  done
  # 仅传了安装相关参数时默认执行安装
  if [[ -z $OPT_ACTION ]] && { (( OPT_AUTO )) || [[ ${OPT_FW_SET:-0} == 1 ]] || [[ -n $OPT_SNI || -n $OPT_PORT || -n $OPT_HY2 || -n $OPT_HOP || -n $OPT_NAT || -n $OPT_NAT_EXT || -n $OPT_LAND || -n $OPT_WITH_LAND || -n $OPT_LAND_PORT || -n $OPT_REALITY || -n $OPT_XHTTP || -n $OPT_XHTTP_ON_443 || -n $OPT_XHTTP_PORT || -n $OPT_TROJAN || -n $OPT_TROJAN_PORT || -n $OPT_TUIC || -n $OPT_TUIC_PORT || -n $OPT_ANYTLS || -n $OPT_ANYTLS_PORT || -n $OPT_XHTTP_TLS || -n $OPT_XHTTP_TLS_PORT || -n $OPT_WS || -n $OPT_WS_PORT || -n $OPT_VLESS_ENC || -n $OPT_CERT_DOMAIN || -n $OPT_CERT_KIND || -n $OPT_CERT_NAMES || -n $OPT_CF_ORIGIN_KEY || -n $OPT_ZEROSSL_KID || -n $OPT_XRAY_VER || -n $OPT_HY2_VER || -n $OPT_SINGBOX_VER || $OPT_CERT == 1 ]]; }; then
    OPT_ACTION=install
  fi
  [[ -z $OPT_ACTION && $OPT_CERT == 0 ]] && OPT_ACTION=cert
  # 只给了 --land-allow：修改落地机白名单
  [[ -z $OPT_ACTION && -n $OPT_LAND_ALLOW ]] && OPT_ACTION=allow
  # 只给了调优参数（或单独的 --tune）：执行独立调优
  if [[ -z $OPT_ACTION ]] && { [[ -n $OPT_TUNE_PRESET$OPT_TUNE_CC$OPT_TUNE_QDISC$OPT_TUNE_BUF$OPT_TUNE_BW$OPT_TUNE_RTT ]] || [[ $OPT_TUNE == 1 ]]; }; then
    OPT_ACTION=tune
  fi
  [[ -n $OPT_TUNE_BW && -z $OPT_TUNE_RTT || -z $OPT_TUNE_BW && -n $OPT_TUNE_RTT ]] && die "--tune-bw 与 --tune-rtt 需要同时使用"
  # 只给了 --outbound：查看或设置出站，不进入安装
  if [[ -z $OPT_ACTION && -n ${OPT_OUTBOUND:-} ]]; then OPT_ACTION=outbound; fi
  # 普通模式下 --port / --hy2-port 只接受单个端口；NAT 模式的 外部:内部 写法在安装时再校验
  if [[ $OPT_NAT != 1 ]]; then
    [[ -z $OPT_PORT || $OPT_PORT != *:* || -f $STATE_FILE ]] || die "--port 的 外部:内部 写法仅用于 NAT 模式（--nat）。"
    local _po
    for _po in "$OPT_HY2_PORT" "$OPT_XHTTP_PORT" "$OPT_TROJAN_PORT" "$OPT_TUIC_PORT" "$OPT_ANYTLS_PORT" "$OPT_XHTTP_TLS_PORT" "$OPT_WS_PORT" "$OPT_LAND_PORT"; do
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
    doctor) do_doctor ;;
    speed) menu_speed ;;
    firewall) menu_firewall ;;
    nat) menu_nat ;;
    cert) do_cert ;;
    cdn) do_cdn ;;
    vless-enc) do_vless_enc ;;
    tune) do_tune ;;
    route) do_route ;;
    outbound) do_outbound ;;
    land) do_land_cli ;;
    land-enable) land_enable ;;
    land-disable) land_disable ;;
    allow) land_menu_allow ;;
    uninstall) do_uninstall ;;
    export) do_export ;;
    import) do_import ;;
    "")
      if [[ ! -t 0 && ! -r /dev/tty ]]; then usage; die "非交互环境请使用 --auto。"; fi
      while :; do show_menu; pause; done ;;
  esac
}

# 允许被 source 用于测试
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" || "${BASH_SOURCE[0]}" == /dev/fd/* || "${BASH_SOURCE[0]}" == /proc/self/fd/* ]]; then
  main "$@"
fi
