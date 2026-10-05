# oneclick proxy

单文件 Bash 脚本，一键在 VPS 上安装代理节点，不需要自己的域名。有已经解析到本机的自有域名时，可以另外申请证书；不申请时，安装方式和现在一样。默认是 Let's Encrypt 单域名。也可以改成通配符、多域名、ZeroSSL，或只给 CDN 用的 Cloudflare 源站证书。证书签好之后，还可以另开两条给 CDN 用的线路（XHTTP+TLS、WebSocket+TLS），默认关闭，不替换 REALITY。

## 一键安装

**推荐**：先下载再运行（可以看到交互菜单）

```bash
curl -fsSLo proxy.sh https://raw.githubusercontent.com/harennie/oneclick-proxy/main/proxy.sh && bash proxy.sh
```

**没有 curl 时用 wget**

```bash
wget -O proxy.sh https://raw.githubusercontent.com/harennie/oneclick-proxy/main/proxy.sh && bash proxy.sh
```

**全自动**（全部使用默认值，无任何交互）

```bash
curl -fsSLo proxy.sh https://raw.githubusercontent.com/harennie/oneclick-proxy/main/proxy.sh && bash proxy.sh --auto
```

> 最小化安装的 Debian（例如 bin456789/reinstall 重装的系统）可能 curl 和 wget 都没有，请先执行 `apt-get update && apt-get install -y curl`（RHEL 系：`dnf install -y curl`）。脚本运行后会自动安装其余依赖，包括时间同步服务。
>
> **Alpine 没有自带 bash**，请先安装依赖并运行安装命令，且必须带 `--nat`（见下文「NAT 小鸡模式」）：
> 
> ```bash
> apk add bash curl && curl -fsSLo proxy.sh https://raw.githubusercontent.com/harennie/oneclick-proxy/main/proxy.sh && bash proxy.sh --nat
> ```

安装完成后输入 `proxy` 即可打开管理菜单，`proxy info` 随时查看链接 / 二维码 / Clash 配置。
节点信息同时保存在 `/root/proxy-info.txt`（权限 600）。

双栈（同时能用 IPv4 和 IPv6 出站）在安装、重装或改写节点配置时会询问一次出站策略：IPv4优先、IPv6优先、仅IPv4、仅IPv6，并记在 `state.env`，之后沿用。`--auto` 还没保存过选择时使用 IPv4优先。只有一种地址时不询问。

### 命令行参数

| 参数 | 说明 |
|---|---|
| `--auto` | 全部默认值、非交互安装 |
| `--sni <域名>` | 指定 REALITY 目标网站（依然会做合规检测，不合格则拒绝） |
| `--force-sni` | 配合 `--sni`，检测不通过也强制使用 |
| `--scan` | 高级：用 [RealiTLScanner](https://github.com/XTLS/RealiTLScanner) 扫描 VPS 附近 IP 寻找同机房目标（约 60 秒） |
| `--port <N>` | VLESS-REALITY TCP 端口，默认 443（NAT 模式可写 `外部:内部`，如 `59221:443`） |
| `--no-hy2` / `--hy2` | 不安装 / 安装 Hysteria2（默认安装） |
| `--hy2-port <N>` | Hysteria2 UDP 端口，默认 443（NAT 模式可写 `外部:内部`） |
| `--no-reality` / `--reality` | 关闭 / 开启 VLESS + REALITY + Vision（默认开启） |
| `--no-xhttp` / `--xhttp` | 关闭 / 开启 VLESS + XHTTP + REALITY（默认开启，不需要自己的域名） |
| `--xhttp-port <N>` | XHTTP 的 TCP 端口，默认 8443（NAT 模式为外部端口，可写 `外部:内部`） |
| `--trojan` / `--no-trojan` | 额外启用 / 关闭 Trojan + REALITY（默认不装） |
| `--trojan-port <N>` | Trojan TCP 端口，默认 8444 |
| `--tuic` / `--no-tuic` | 额外启用 / 关闭 TUIC v5（sing-box，自签证书，默认不装） |
| `--tuic-port <N>` | TUIC UDP 端口，默认 8446 |
| `--anytls` / `--no-anytls` | 额外启用 / 关闭 AnyTLS（sing-box，自签证书，默认不装） |
| `--anytls-port <N>` | AnyTLS TCP 端口，默认 8445 |
| `--xhttp-tls` / `--no-xhttp-tls` | 额外启用 / 关闭 VLESS + XHTTP + TLS（放在 CDN 后面，默认不装）。需要 `--cert-domain`。不是 REALITY，也不替换原来的 XHTTP+REALITY |
| `--xhttp-tls-port <N>` | 这条线路的回源 TCP 端口，默认 2083。须是 Cloudflare 允许代理的 HTTPS 端口：443、2053、2083、2087、2096、8443。不要占用 REALITY |
| `--ws-tls` / `--no-ws-tls` | 额外启用 / 关闭 VLESS + WebSocket + TLS（放在 CDN 后面，默认不装）。需要 `--cert-domain` |
| `--ws-port <N>` | 这条线路的回源 TCP 端口，默认 2087。端口范围同上 |
| `--hop <a-b\|none>` | Hysteria2 端口跳跃范围，默认 `20000-50000`，`none` 关闭（NAT 模式默认关闭，可写多段 `a-b,c-d`） |
| `--name <名称>` | 节点名称（默认「国家-城市」） |
| `--cert-domain <域名>` | 可选：申请证书。不写 `--cert-kind` 时是 Let's Encrypt 单域名 HTTP-01。订阅只走 HTTPS；Hysteria2 / TUIC / AnyTLS 改用该证书和域名。REALITY 仍借用伪装站点。NAT 模式不可用 |
| `--cert-kind <种类>` | `le`（默认）\| `wildcard` \| `multi` \| `zerossl` \| `zerossl-wildcard` \| `zerossl-multi` \| `cf-origin`。通配符走 DNS-01。`cf-origin` 是 Cloudflare 源站证书，只有 Cloudflare 信任，只能给两条 CDN 线路 |
| `--cert-names <列表>` | 多域名或源站证书的名字，逗号分隔 |
| `--cert-link <主机名>` | 通配符证书写进链接的具体名字，默认是根域名 |
| `--cert-email <邮箱>` | 可选，登记给证书机构；不填则不登记邮箱 |
| `--cf-dns-token <令牌>` | Cloudflare API 令牌，只用于通配符的 DNS-01。权限要有 Zone → DNS → 编辑，以及 Zone → Zone → 读取。不是 Origin CA Key |
| `--cf-origin-key <钥匙>` | Cloudflare Origin CA Key。写了就申请源站证书 |
| `--zerossl-kid <id>` / `--zerossl-hmac <key>` | ZeroSSL 的 EAB 凭据，必须成对。在 <https://app.zerossl.com/developer> 生成 |
| `--sub-port <端口>` | 订阅 HTTPS 端口，默认 8447（不能是 80，也不能占用已开启协议的 TCP 端口）。源站证书不会打开订阅 |
| `--no-cert` | 关闭已申请的证书，Hysteria2 / TUIC / AnyTLS 改回自签。开着的 CDN 线路一并关掉（不能改用自签） |
| `--no-firewall` | 不配置 nftables 防火墙 |
| `--no-upgrade` | 跳过系统软件包升级 |
| `--no-tune` | 跳过 sysctl 调优 |
| `--tune-preset <名>` | 安装时使用的调优预设（默认 `bbr-fq`），见「网络调优」 |
| `--nat` / `--no-nat` | 启用 / 关闭 NAT 小鸡模式（记录在 state.env，之后 `proxy` 命令自动沿用）。不指定时：Alpine 自动启用 NAT；LXC / OpenVZ 容器首次安装时询问（公网 IP 不在本机网卡上时默认「是」，`--auto` 直接按此判断）；交互菜单第 15 项可手动切换 |
| `--nat-addr <地址>` | 链接里使用的公网（入口）IP 或域名，即商家面板端口映射里显示的地址。交互安装时必须手动填写（检测到的出口 IP 只作提示）；`--auto` 未指定时暂用出口 IP 并给出警告 |
| `--nat-ports <列表>` / `--nat-port` | 服务商已映射的端口，逗号分隔，每项 `外部[:内部]`：`52430`、`59221:443`、整段 `10001-10020`、`10001-10020:20001-20020` |
| `--nat-exclude <端口>` | 整段转发时需要排除的外部端口（例如已映射给 SSH 的端口），逗号分隔 |
| `--nat-share` / `--nat-no-share` | Reality(TCP) 与 Hysteria2(UDP) 共用 / 不共用一个外部端口（默认共用） |
| `--dns64` | IPv6-only 且无法访问 GitHub 时，写入公共 DNS64 服务器（卸载时恢复） |
| `--tune` / `--upgrade` | NAT 模式下执行网络调优（只写可写的参数）/ 系统升级。NAT 交互安装会询问是否调优，`--auto` 时默认跳过 |
| `--land` / `--no-land` | 安装为落地机（只运行 Xray Shadowsocks 2022，TCP+UDP）/ 落地机改装回 Reality + Hysteria2 节点。可与 `--nat`、`--port`、`--name`、`--auto` 组合，见「落地机 / 落地转发」 |
| `--land-method <m>` | 落地机加密方式：`aes-128`（默认，`2022-blake3-aes-128-gcm`）、`aes-256`、`chacha20` |
| `--land-allow <列表>` | 落地机来源 IP 白名单（只允许中转机连接）：IPv4 / IPv6 / CIDR，逗号分隔；`none` 为不限制 |
| `--force` | `proxy land-add` 连通性测试失败时仍然启用 |

示例：`bash proxy.sh --auto --sni www.case.edu --port 443 --hop 30000-40000`

NAT 示例：`bash proxy.sh --nat --auto --nat-port 59221:443 --nat-addr 156.239.14.191`

落地机示例：`bash proxy.sh --land --auto --land-allow 203.0.113.10`（只允许中转机 203.0.113.10 连接）

申请证书示例：`bash proxy.sh --auto --cert-domain example.com`（默认 Let's Encrypt 单域名，解析必须全部指向这台机器；见「申请证书」）

通配符示例：`bash proxy.sh --cert-kind wildcard --cert-domain example.com --cf-dns-token <令牌>`

源站证书示例：`bash proxy.sh --cert-kind cf-origin --cf-origin-key <钥匙> --cert-domain cdn.example.com --xhttp-tls`

CDN 线路示例：`bash proxy.sh --auto --cert-domain example.com --xhttp-tls --ws-tls`（两条都可选，也可以只开一条。见「经过 CDN 的两条线路」）

管理子命令：`proxy info | proto | sni | regen | port | user | update | status | speed | firewall | nat | cert | cdn | tune | route | land | land-add | land-test | land-off | land-on | land-del | allow | uninstall`（加 `--auto` 可在脚本/自动化里免确认，例如 `proxy uninstall --auto`）。`proxy route` 只做线路检测，不改配置。

装完之后改协议（不删除已有 UUID、Reality 密钥、XHTTP 路径和各协议密码）：

```bash
proxy proto
```

菜单第 16 项「协议开关」作用相同。命令行也可以直接带开关重跑安装，例如 `proxy --no-xhttp`、`proxy --tuic`、`proxy --no-hy2`。关闭只停止对应监听，密钥留在 `state.env`。

---

## 默认协议

默认一次装好三个，都不需要自己的域名：

- **VLESS + REALITY + XTLS-Vision**（含后量子签名 ML-DSA-65）
- **VLESS + XHTTP + REALITY**（与 Vision 共用同一把 Reality 密钥和 SNI，单独 TCP 端口）
- **Hysteria2**（端口跳跃 + 证书指纹固定）

可选协议默认不装：Trojan + REALITY、TUIC v5、AnyTLS，以及两条 CDN 线路（VLESS + XHTTP + TLS、VLESS + WebSocket + TLS）。安装时加 `--trojan`、`--tuic`、`--anytls`、`--xhttp-tls`、`--ws-tls`，或装完后用上面的 `proxy proto`。CDN 这两条还要有已经解析到本机的自有域名和公开证书。Shadowsocks 2022 只出现在落地机模式里。

---

## 功能

- **环境预检**：必须 root；识别发行版与架构（amd64 / arm64）；显示 IP、城市、ASN、内存；内存 < 1G 且无 Swap 时自动加 1G Swap；自动更新系统并安装依赖（RHEL 系自动启用 EPEL）；未检测到时间同步服务时自动安装并启用 systemd-timesyncd / chrony（REALITY 要求系统时间准确）。
- **系统调优（保守，不换内核）**：普通模式安装时默认启用 BBR + fq；TCP/UDP 缓冲区（满足 Hysteria2 建议的 16MB）、文件句柄上限；journald 日志上限 100M。配置写入 `/etc/sysctl.d/99-proxy-tune.conf`，卸载时恢复原值。也可以用 `proxy tune` 单独调整 / 恢复，见下文「网络调优」。
- **Xray（官方 XTLS/Xray-install 安装最新版）**：
  - VLESS + REALITY + `xtls-rprx-vision`，默认 TCP 443；
  - 自动生成 UUID、x25519 密钥、ShortId（`openssl rand -hex 4`）、**ML-DSA-65**（服务端 `mldsa65Seed`，客户端链接 `pqv=`）；ML-DSA-65 要求目标网站证书链总长度 ≥ 3500 字节，不满足时脚本会自动对该目标关闭 pqv（REALITY 本身照常可用）；
  - 客户端指纹 `fp=chrome`（实测 `randomized` 生成的随机 ClientHello 会被部分目标网站拒绝，导致 REALITY 握手失败）；
  - 每次写配置前先 `xray run -test` 校验，失败不会覆盖旧配置；
  - 以 `nobody` 运行，配置文件 `root:nogroup 640`，私钥/种子只保存在 `/root/.proxy-oneclick/state.env`（600），不会在屏幕上显示；
  - 屏蔽访问服务器内网（geoip:private）与 BT。
  - 官方脚本遇到 GitHub API 限流（403）时，会自动改为“指定最新版本号”重试。
  - **安装后 REALITY 自检**：用已安装的 xray 在 127.0.0.1 随机端口起一个临时客户端，按生成的链接参数连接本机节点并访问外网，打印通过 / 未通过（不影响安装；更换 SNI 后也会自动自检）。临时客户端限制 `GOMEMLIMIT`，128MB 的 NAT 小鸡也能跑。
- **REALITY 目标网站自动优选**（见下文「为什么 SNI 规则很重要」）。
- **Hysteria2（可选，默认启用，官方 get.hy2.sh 安装）**：自签 EC 证书（CN = 所选 SNI），客户端使用 `pinSHA256` 固定证书指纹；随机密码；监听 UDP 443；伪装为反向代理 `https://<SNI>`；nftables 实现 UDP 20000-50000 → 443 端口跳跃。申请公开证书后，Hysteria2 改为出示那张证书，链接地址和 SNI 换成自有域名，不再带 `insecure` 或 `pinSHA256`。Cloudflare 源站证书不会交给 Hysteria2。
- **防火墙（nftables）**：独立表 `inet proxy_oneclick`，入站默认拒绝；放行 lo、已建立连接、ICMP/ICMPv6、DHCPv6 回包、**自动探测的 SSH 端口**（`sshd -T`、配置文件、监听进程、ssh.socket 及当前 SSH 会话端口）、当前已开启协议的 TCP/UDP 端口及 Hysteria2 跳跃范围；检测到其它对外服务时会询问是否一并放行。只有 HTTP-01（Let's Encrypt / ZeroSSL 的单域名或多域名）才额外放行 TCP 80。只有公开证书才放行订阅 HTTPS 端口。通配符 DNS-01 和 Cloudflare 源站证书不放行 80，源站证书也不开订阅。应用前先 `nft -c` 校验并备份原规则；由 systemd 单元 `proxy-oneclick-fw.service` 开机加载。检测到 firewalld / ufw 时询问是否停用（卸载时可恢复）。不会关闭 SELinux（写入文件后执行 `restorecon`）。防火墙菜单、运行状态和安装结束时会逐行列出已经放行的端口，以及每一条属于哪个协议（Reality、XHTTP、Hysteria2、Trojan、TUIC、AnyTLS、CDN 的 XHTTP 与 WebSocket、订阅、证书申请的 TCP 80、SSH、端口跳跃，以及额外放行）。没写出来的新连接仍然拒绝。
- **fail2ban**：sshd 监狱，10 分钟内失败 5 次封禁 1 小时（systemd 日志后端 + nftables 动作）。
- **XHTTP（默认开启）**：VLESS + XHTTP + REALITY。与 Vision 共用同一把 x25519、ShortId、SNI 和 ML-DSA-65 种子，单独监听 TCP 8443，`flow` 必须为空，路径为随机 `/` + 十六进制。服务端和客户端链接的 `mode` 都是 `stream-one`（REALITY 直连；客户端用 `auto` 时有已知握手失败）。不需要自己的域名，也不把自己的证书挂到 XHTTP 上。这条和下面的「XHTTP + TLS（CDN）」是两条入站，互不替换。
- **可选协议（默认关闭，安装时不会询问）**：Trojan + REALITY（Xray，TCP 8444，同一把 Reality 密钥）；TUIC v5（sing-box，UDP 8446，BBR，ALPN h3）和 AnyTLS（sing-box，TCP 8445）。后两个默认复用 Hysteria2 的自签证书（CN = 所选 SNI），客户端需要允许不安全证书。申请公开证书后，这两条改为出示该证书，客户端按正常校验。Cloudflare 源站证书不会交给它们。当前 v2rayNG 不能导入 `tuic://` 和 `anytls://`，请用 v2rayN / sing-box / mihomo。
- **CDN 上的两条线路（默认关闭）**：VLESS + XHTTP + TLS（TCP 2083，`mode=packet-up`）和 VLESS + WebSocket + TLS（TCP 2087）。用公开证书，或只用这两条时改用 Cloudflare 源站证书。都不是 REALITY。打开时脚本会打印 DNS、橙色云朵、回源端口、加密模式和客户端链接该怎么填。详见「经过 CDN 的两条线路」。
- **输出**：每个已开启协议单独一块：名称、地址、端口各一行，链接本身最后单独一行。vless://（含 / 不含 pqv）、xhttp 的 vless://（`mode=stream-one`，无 flow）、hysteria2://（未申请证书时带 `mport`、`sni`、`insecure=1`、`pinSHA256`；申请之后地址和 SNI 为自有域名，不再带 insecure / pin）、可选的 trojan:// / tuic:// / anytls://。打开 CDN 线路后另有两条 vless://（`security=tls`，没有 flow / pbk / sid / pqv / insecure）。终端二维码，mihomo（Clash.Meta）YAML 片段。申请公开证书后另有仅 HTTPS 的订阅地址。源站证书没有订阅。
- **管理菜单**：顶部字符 Logo 是「哈人」，正下方小标题和菜单框标题是 `oneclick proxy`。主菜单两列编号，第 16 项是「协议开关」，第 17 项是「申请证书」，第 18 项是「线路检测」。其余是：安装/重装、查看链接和二维码、更换 SNI、重新生成密钥、修改端口、添加/删除用户（UUID + 备注）、更新 Xray/Hysteria2/脚本、状态与日志、测速与延迟提示、防火墙管理、网络调优、落地转发、安装为落地机、卸载、切换 NAT 模式。
- **线路检测**：`proxy route` 从本机向外看路由。回国只测回程（VPS → 电信 / 联通 / 移动），国际拆成「国际线路」（上游、Tier1、交换中心）和「国际互联」（到常用目标的路径和时延）两项，三份分数不合成一个总分。IPv4 和 IPv6 各一份报告。不改代理配置，不重启，也不测流媒体。去程要在自己的电脑上跑，报告末尾给出现成命令。详见「线路检测」。
- **落地机 / 落地转发**：`--land` 把本机装成只跑 Shadowsocks 2022 的出口（落地机）；已安装的节点用 `proxy land-add 'ss://...'` 把出口切到落地机（中转），见下文。
- **健壮性**：`set -o errexit -o pipefail -o errtrace` + 错误陷阱提示出错行；可重复运行（保留已有密钥，只更新组件与配置）；安装前检查端口占用；没有 IPv6 也能正常工作（链接使用 IPv4）；通过 shellcheck 检查。

---

## 支持的系统

| 系统 | 版本 |
|---|---|
| Debian | 11 / 12 / 13（推荐 Debian 12） |
| Ubuntu | 20.04 及以上 |
| RHEL 系 | Rocky / AlmaLinux / CentOS Stream 8、9（及更新），RHEL，Oracle Linux，Fedora（使用 dnf） |
| Alpine | 3.18 及以上，OpenRC，**仅 NAT 模式**（`--nat`，需先 `apk add bash curl`） |

架构：amd64、arm64（NAT / Alpine 模式另支持 armv7）。Debian / Ubuntu / RHEL 系须使用 systemd；Alpine 使用 OpenRC。

**不支持**：CentOS 7 及更老系统、既没有 systemd 又不是 Alpine 的环境。独立 IP 的普通 VPS 如果系统不合适，建议用 [bin456789/reinstall](https://github.com/bin456789/reinstall) 重装为 Debian 12：

下载并运行重装脚本：

```bash
curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh && bash reinstall.sh debian 12
```

> ⚠️ 重装会**清空整块硬盘**；重装过程出现问题时需要通过服务商的 **VNC / 串口控制台** 处理，请提前确认能登录控制台并备份数据。

---

## NAT 小鸡模式（`--nat`）

适用于没有独立公网 IPv4、只能在面板里添加少量「端口映射」的机器（常见于 LXC / OpenVZ / Incus 容器、Alpine 小内存小硬盘机型）。

### 端口映射怎么填

服务商面板里的每条映射是「公网端口 → 内部端口」。脚本的 `--nat-ports`（或交互时的「公网端口 / 内部端口」提问）按同样的格式填写：

| 写法 | 含义 |
|---|---|
| `52430` | 公网 52430 → 内部 52430 |
| `59221:443` | 公网 59221 → 内部 443（服务在容器内监听 443，链接里写 59221） |
| `10001-10020` | 整段转发，内外端口相同 |
| `10001-10020:20001-20020` | 整段转发，内外端口不同（长度必须一致） |

**示例：只有一条「协议 = 全部（TCP+UDP）」的映射，公网 59221 → 内部 443**

Alpine 才需要先安装依赖：

```bash
apk add bash curl && bash proxy.sh --nat --auto --nat-port 59221:443 --nat-addr 156.239.14.191
```

结果：容器内 Xray Reality（TCP）与 Hysteria2（UDP）都监听 443，分享链接为 `vless://…@156.239.14.191:59221…`、`hysteria2://…@156.239.14.191:59221/…`。`--port 59221:443` 效果相同。

XHTTP 还需要第二条外部 TCP 端口（默认 8443，不能和 Vision 共用 TCP 443）。只有这一条映射时，脚本会警告并跳过 XHTTP，安装仍然成功（Reality + Hysteria2），不会整次失败。要装上 XHTTP，再映射一个 TCP 端口后执行 `proxy --xhttp`，或安装时写上 `--xhttp-port`。只要 Reality + Hysteria2 时加 `--no-xhttp`。

### 默认行为

- **Reality 与 Hysteria2 默认共用一个外部端口**（TCP 走 Reality、UDP 走 Hysteria2），因为很多服务商只给 5 条左右的映射。前提是该映射**同时转发 TCP 和 UDP**；若只转发 TCP，请加 `--nat-no-share` 并再提供一个 UDP 端口（例如 `--nat-ports 52430,52431`），或 `--no-hy2`。
- **端口跳跃默认关闭**。只有在「整段转发」且机器有 DNAT 能力（nftables 或 iptables 可用、容器有 NET_ADMIN）时才能开启，例如 `--nat-ports 10001-10020 --hop 10003-10020`；Reality 端口和 `--nat-exclude` 排除的端口会被自动剔除，范围会被拆成多段（如 `10003-10009,10011-10020`）。探测失败会自动回落为不跳跃并给出提示。规则由 `proxy-oneclick-hop` 服务开机加载。
- **`--nat-exclude`**：整段转发里已经给别的用途（例如 SSH 的 52429）的端口。当前被占用的端口也会自动排除。
- **地址**：交互安装时**必须填写入口地址**（商家面板「端口映射 / NAT 转发」条目里显示的 IP 或域名）。外部查询服务检测到的只是**出口 IP**，只作为提示「检测到的出口 IP: x（NAT 机入口地址可能不同）」显示；直接回车时需要再明确确认「出口 IP 同时也是入口地址」才会使用。填写后会做一次提示性自检（入口 ≠ 出口且不在本机网卡上时给出说明，不阻止）。IPv6 地址在链接中自动加方括号，私有地址会提醒；`--nat-addr` 可直接指定；`--auto` 未指定 `--nat-addr` 时暂用出口 IP 并警告。
- **何时进入 NAT 模式**（菜单 1 / 13、`--land`、改装都一样，在「端口设置」之前确定）：`--nat` / `--no-nat` > 菜单第 15 项手动设置 > Alpine 强制 NAT > 已安装的模式 > 自动检测（LXC / OpenVZ 容器询问「是否为 NAT 机（只有服务商映射的端口可用）？」，公网 IP 不在本机网卡上时默认「是」）。

### NAT 模式跳过的组件（以及原因）

| 跳过 | 原因 |
|---|---|
| nftables 防火墙、fail2ban | 入口由服务商的端口映射控制，容器里通常也没有权限改防火墙；fail2ban 占内存 |
| Swap | 容器里无法创建 / 启用 Swap |
| sysctl 调优（BBR 等）——改为可选 | 容器共享宿主机内核，很多参数只读或由宿主机控制。交互安装时会询问，只应用容器内实际可写的参数（不强制 BBR）；`--auto` 时默认跳过，加 `--tune` 启用；之后也可随时 `proxy tune` |
| 系统升级 | 节省时间与磁盘；需要时加 `--upgrade` |
| geoip / geosite 数据文件 | 节省约 20MB 磁盘；内网屏蔽改为内置的私有网段列表 |
| 时间同步服务 | 容器使用宿主机时钟（Alpine 虚拟机会安装 chrony） |
| `--scan`、大规模 SNI 检测 | 小内存机器上 SNI 候选限制为 12 个、并发 3 |
| 申请证书、CDN 上的 XHTTP+TLS / WebSocket+TLS | 证书和 CDN 都要能从公网访问到这台机器。NAT 小鸡通常没有这些映射。通配符、ZeroSSL 和源站证书同样不在 NAT 上申请。不带证书参数、`--xhttp-tls`、`--ws-tls` 时安装方式不变 |

### 小内存 / 小硬盘

- 内存上限按 **cgroup 限制** 计算（LXC 里 `free` 显示的是宿主机内存，不准）。可用内存 < 256MB 时，为 Xray 与 Hysteria2 设置 `GOMEMLIMIT`（合计约为上限的 60%）和 `GOGC=50`。
- Xray / Hysteria2 直接从 GitHub Release 下载单个二进制并校验 SHA256（Xray `.dgst`，Hysteria2 `hashes.txt`），不使用官方安装脚本；下载包用完即删；已是最新版时不重复下载。
- Alpine 只安装必需的包：bash、ca-certificates、curl、openssl、jq、unzip、iproute2、grep、gawk、musl-utils（以及可选的 libqrencode-tools 用于二维码）。

### 其它

- **虚拟化识别**：自动识别 LXC / OpenVZ / KVM / Docker / Podman 等，显示在预检信息中。
- **IPv6-only / DNS64**：机器只有 IPv6 出口时，GitHub 需要 DNS64/NAT64 才能访问。脚本会检测并提示，`--dns64` 会写入公共 DNS64 服务器（原 `/etc/resolv.conf` 备份，卸载时恢复）。
- **OpenRC（Alpine）**：服务由 `supervise-daemon` 托管（崩溃自动重启），以 `nobody` / `hysteria` 用户运行；监听 1024 以下端口时只授予 `cap_net_bind_service`。日志在 `/var/log/xray/xray.log` 与 `/var/log/hysteria/hysteria.log`（超过 2MB 在启动时截断），`proxy status` 中可直接查看。
- **管理**：菜单第 10 项（或 `proxy nat`）为「NAT 信息 / 端口跳跃」，可查看映射关系、修改映射端口、开关端口跳跃；`proxy port` 会按映射端口重新询问。
- 已安装为 NAT 模式后，再次运行脚本或 `proxy` 会自动沿用 NAT 模式；`--no-nat` 可切回普通模式。
- **申请证书不可用，CDN 上的两条线路也不可用**。不管是 Let's Encrypt、ZeroSSL、通配符还是 Cloudflare 源站证书，都要求公网能访问到这台机器；NAT 小鸡通常没有这些映射。Alpine 在本脚本里始终是 NAT，因此也不能申请、也不能开这两条。已经申请过证书再切到 NAT 时，证书会关掉，CDN 线路停止，Hysteria2 / TUIC / AnyTLS 改回自签。不带证书参数、`--xhttp-tls`、`--ws-tls` 时不会询问，安装输出与现在相同。

---

## 网络调优（`proxy tune`）

独立功能：不安装代理也能用（`bash proxy.sh tune`），NAT / LXC / OpenVZ / Alpine 下同样可用。菜单第 11 项，或命令行：

**交互菜单**：查看状态 / 选择预设 / 恢复

```bash
proxy tune
```

**查看当前拥塞控制、队列算法、关键参数及是否可写**

```bash
proxy tune status
```

**只预览**（当前值 → 目标值），不做任何修改

```bash
proxy tune preview
```

**预览后确认应用**；加 `--auto` 不询问

```bash
proxy tune apply
```

**恢复调优前的原值并删除配置文件**

```bash
proxy tune restore
```

**使用指定预设并自动确认**

```bash
proxy tune apply --tune-preset bbr-fq_codel --auto
```

**自定义拥塞控制、队列算法、带宽和延迟**

```bash
proxy tune apply --tune-cc bbr --tune-qdisc cake --tune-bw 1000 --tune-rtt 180
```

**先探测再修改**：虚拟化类型、init（systemd / OpenRC）、内核版本、`tcp_available_congestion_control` 中实际可用的拥塞控制（BBR 显示版本：主线 v1，XanMod 等第三方内核的 v3）、可用的队列算法模块、内存（按 cgroup 限制）、默认网卡当前队列；每个目标参数都会**把当前值原样写回去测试是否可写**，而不是靠猜。脚本不会安装或更换内核。

**预设（只决定拥塞控制 + 队列算法）**：

| 预设 | 说明 |
|---|---|
| `bbr-fq`（默认） | BBR + fq。fq 为 BBR 提供高效的 pacing，服务器端首选；普通模式安装默认使用 |
| `bbr-fq_codel` | BBR + fq_codel。内核 4.20+ BBR 在非 fq 队列下由 TCP 自身做 pacing；适合本机还有其它业务 / 做路由的机器 |
| `bbr-cake` | BBR + cake（需内核有 `sch_cake`），CPU 开销略高 |
| `cubic-fq_codel`（保守） | 不启用 BBR，cubic + fq_codel，与多数发行版默认接近 |
| `keep` | 只调缓冲区 / 连接参数，拥塞控制与队列保持系统原来的设置（之前由本脚本改过的会改回原值） |
| `custom` | 从本机可用的算法里分别选择拥塞控制与队列算法（`--tune-cc` / `--tune-qdisc`） |

内核缺少预设需要的组件时，菜单中会标注「不可用：缺少 …」；非交互模式下会保持该项不变并给出提示（例如没有 BBR 时只应用缓冲区等参数）。

**缓冲区档位**（`--tune-buffer`，独立调优默认 `auto` 按内存；安装时默认 `medium`）：

| 档位 | TCP 缓冲区上限 | 说明 |
|---|---|---|
| `small` | 4MB（UDP/core 8MB） | ≤256MB 小鸡；UDP 仍保留 8MB，满足 quic-go（Hysteria2）约 7MB 的接收缓冲区需求 |
| `medium` | 16MB | 普通 VPS 的默认档 |
| `large` | 64MB | 约 2GB 及以上内存，高带宽长距离线路 |
| `bdp` | 2 × 带宽 × 延迟 | `--tune-bw <Mbps> --tune-rtt <ms>`，下限 4MB，上限按内存（≤256MB 8MB、≤1GB 32MB、≤4GB 64MB、更大 128MB） |

其余参数：`tcp_fastopen=3`、`tcp_mtu_probing=1`、`tcp_slow_start_after_idle=0`、`tcp_notsent_lowat=131072`、`tcp_fin_timeout=30`、`tcp_keepalive_time=600`、`somaxconn` / `tcp_max_syn_backlog` / `netdev_max_backlog` 按档位、文件句柄上限。`ip_local_port_range` 和 conntrack 不修改（`status` 中显示 conntrack 使用率，超过 80% 会提醒）。

**应用流程**：先显示预览表（参数 / 当前值 / 目标值 / 状态），确认后只写可写的参数，跳过的逐条说明原因，例如「跳过：容器内只读（宿主机控制）」「跳过：容器内不可见」「跳过：全局参数，容器内修改会影响宿主机」（特权容器里 `fs.file-max`、`default_qdisc` 等全局参数即使可写也不碰）。队列算法会立即应用到默认网卡（`tc`，多队列网卡重建 mq），并通过 `net.core.default_qdisc` 持久化。

**持久化与恢复**：
- 只维护一个文件 `/etc/sysctl.d/99-proxy-tune.conf`，只包含成功应用的参数；OpenRC 下会确保 `sysctl` 服务在 boot 运行级。
- 容器内 `systemd-sysctl` 常因 `/proc/sys` 只读挂载而被跳过，且网卡队列只能用 `tc` 设置，因此容器中额外添加开机服务 `proxy-oneclick-tune`（systemd 单元或 OpenRC 脚本）重新应用。
- 首次应用前把所有相关参数的原值备份到 `/root/.proxy-oneclick/tune/backup.env`（之后换预设不会覆盖备份）；`proxy tune restore` 还原原值、网卡队列，删除配置文件与开机服务。卸载时自动执行同样的恢复。没有备份时，恢复会删掉该配置文件并重新加载系统 sysctl，其余参数回到内核默认值。

---

## 落地机 / 落地转发

常见用法：客户端连一台线路好的 **中转机**（本脚本安装的 Reality / Hysteria2 节点），中转机再把流量交给另一台 **落地机** 出去，目标网站看到的是落地机的 IP（例如需要特定地区 IP、或中转机 IP 不干净）。

```
客户端 ──Reality / Hy2──▶ 中转机（proxy land-add）──Shadowsocks 2022──▶ 落地机（--land）──▶ 目标网站
```

### 1. 在落地机上安装（`--land`）

**交互安装**：询问端口（默认随机 20000-60000）、加密方式、来源 IP 白名单

```bash
bash proxy.sh --land
```

**全自动**：只允许中转机 203.0.113.10 连接（IPv4 / IPv6 / CIDR，逗号分隔）

```bash
bash proxy.sh --land --auto --land-allow 203.0.113.10
```

**指定端口与加密方式**

```bash
bash proxy.sh --land --auto --port 8388 --land-method chacha20 --land-allow 203.0.113.10,2001:db8::/64
```

**NAT 小鸡 / Alpine 做落地机**：公网 52430 → 内部 8388（映射需同时包含 TCP+UDP 才能转发 UDP）

```bash
apk add bash curl && bash proxy.sh --land --nat --auto --port 52430:8388 --nat-addr 1.2.3.4 --land-allow 203.0.113.10
```

- **尽量轻**：只装 Xray 一个程序（直接下载官方 Release 并校验 SHA256，只解压 `xray` 本体，不带 geo 数据文件），不装 Reality / Hysteria2 / fail2ban / 默认拒绝防火墙；Xray 以 `nobody` 运行、日志 warning 且关闭访问日志，内存 < 256MB 时自动设置 `GOMEMLIMIT`（128MB 的 Alpine 容器实测 Xray 常驻约 30MB）。支持 Debian / Ubuntu / RHEL 系（systemd）以及 Alpine（OpenRC），NAT 映射端口写法与 NAT 模式相同。
- **协议**：Shadowsocks 2022（SIP022），`network: tcp,udp`。默认 `2022-blake3-aes-128-gcm`（16 字节密钥），可选 `2022-blake3-aes-256-gcm` / `2022-blake3-chacha20-poly1305`（32 字节密钥，无 AES 硬件加速的 ARM 机器选 chacha20）；密钥用 `openssl rand -base64 <长度>` 生成。SS2022 会校验时间戳，两端时间相差超过 30 秒会被拒绝，脚本会检查 / 启用时间同步。
- **出站限制**：与节点模式一样屏蔽访问内网 / 保留地址段与 BT。
- **来源 IP 白名单**（可选，强烈建议）：只允许列出的中转机 IP。实现为两层：
  - Xray 路由：来源在白名单内 → 直连，否则 → blackhole（任何环境都有效，本机回环始终允许，用于自检）；
  - nftables：非 NAT 容器且有 nft 时，额外加一张独立的表 `inet proxy_oneclick_land`，只在 SS 端口上丢弃非白名单来源（不影响其它端口，不是默认拒绝防火墙），开机由 `proxy-oneclick-land-fw` 服务加载。NAT 容器（LXC / OpenVZ 等）只用 Xray 路由。
  - 注意：NAT 小鸡经服务商端口映射进来的连接，来源 IP 可能被改成服务商网关地址；中转机测试失败时，看落地机的实际来源 IP 再加进白名单。
- **安装结束输出**：`ss://` 链接（SIP002，2022 加密使用百分号编码的 `方法:密钥`，不用 base64）、**中转机一键命令** `proxy land-add 'ss://...'`、可直接粘贴到其它 Xray 配置的 **outbound JSON 片段**、mihomo 片段；并做一次落地机自检（临时客户端 → 本机 SS2022 → 外网，显示出口 IP）。
- **落地机菜单**（`proxy`）：

```
 1) 安装 / 重新安装（落地机）
 2) 查看 ss:// 链接 / 中转机命令 / Xray 出站片段
 3) 修改来源 IP 白名单
 4) 修改端口
 5) 更换密钥 / 加密方式
 6) 更新 Xray / 脚本
 7) 运行状态 / 日志
 8) 网络调优（BBR / 队列算法 / 缓冲区 / 恢复）
 9) 改装为 Reality / Hysteria2 节点
10) 卸载
11) 切换 NAT 模式（当前: 自动/开/关）
```

命令行：`proxy info`（链接）、`proxy allow --land-allow 1.2.3.4,5.6.7.0/24`（改白名单，`none` 不限制）、`proxy port --port 9388`、`proxy regen [--land-method aes-256]`（换密钥 / 加密方式）、`proxy uninstall`。改端口或密钥后需要在中转机上重新 `land-add`。

### 2. 在中转机上添加落地（`proxy land-add`）

中转机需要先用本脚本正常安装（普通模式或 NAT 模式均可），然后：

```bash
proxy land-add 'ss://2022-blake3-aes-128-gcm:xxxx%3D%3D@1.2.3.4:8388#HK-land'
```

也可以使用菜单第 12 项「添加 / 修改落地转发」，粘贴链接。

- 解析 `ss://` 链接（也接受 base64 形式的 userinfo），只接受 SS2022 三种加密，并检查密钥长度。
- **先测试再启用**：① TCP 连接落地机端口；② 用临时 Xray 客户端经落地机发起真实请求并显示出口 IP（与落地机地址比较）。不测速。测试失败默认不改配置（交互时可选择仍然启用，命令行可加 `--force`），并提示常见原因（密钥错误 / 白名单未包含本机出口 IP / 时间误差）。
- 启用后：落地出站（tag `land-名称`）放在 Xray 出站列表第一位，路由最后加一条兜底规则指向它；**内网 / BT 屏蔽规则仍在最前**。Hysteria2 也走落地机：Xray 额外监听一个只绑定 `127.0.0.1` 的 socks 入站，Hysteria2 配置里加 `outbounds: socks5` 指向它（TCP 与 UDP 都经过落地机）。
- 落地设置保存在 `/root/.proxy-oneclick/state.env`（`RELAY_LINK` / `RELAY_ON` / `RELAY_SOCKS`），**每次重新生成配置都会重新加入**（`proxy sni`、`proxy port`、`proxy regen`、用户管理、更新、重新安装都不会把它覆盖掉）。
- 管理：

**落地转发菜单**：添加/修改、测试、停用、重新启用、删除

```bash
proxy land
```

**只测试当前落地**

```bash
proxy land-test
```

**停用**：恢复直连出站，保留链接

```bash
proxy land-off
```

**重新启用**（先测试）

```bash
proxy land-on
```

**删除落地链接并恢复直连**

```bash
proxy land-del
```

`proxy status` 会显示当前落地（tag、地址、加密、启用 / 停用）。安装完成后 REALITY 自检也会显示经落地后的出口 IP。

### 3. 手动配置其它 Xray 中转

落地机输出的 outbound 片段可以直接放进任意 Xray 配置的 `outbounds`（放第一位即成为默认出站，或在 `routing` 里按需引用 tag）：

```json
{
  "tag": "land-HK-land",
  "protocol": "shadowsocks",
  "settings": {"servers": [{"address": "1.2.3.4", "port": 8388, "method": "2022-blake3-aes-128-gcm", "password": "xxxx=="}]}
}
```

> 提示：Xray 26.x 启动时会对所有 Shadowsocks 配置（包括 SS2022）打印一条 “deprecated … migrate to VLESS Encryption” 警告，目前只是提示，不影响使用。

---

## 为什么 SNI（REALITY 目标网站）规则很重要

REALITY 会把未通过认证的连接原样转发给「目标网站」，同时借用它的 TLS 特征。选错目标会让节点更容易被识别或者干脆不可用。脚本按以下规则在 **VPS 上实时检测** 每个候选：

1. **与 VPS 同国家/地区（最好同城、同 ASN）**：一台洛杉矶 VPS 却“访问”东京网站，流量路径和延迟都不自然。候选列表按地区组织（例如洛杉矶 → www.csun.edu、www.cpp.edu…；香港 → my.hkust.edu.hk、factsfigures.cuhk.edu.hk…；另有 JP / KR / TW / SG / DE / NL / GB / FR / CA / AU 等数十个地区），不足时自动扩展到邻近地区；结果同国家优先，其次支持 X25519MLKEM768 的优先，再按 TLS 握手延迟排序。
2. **TLS 1.3 + X25519 + ALPN h2**：REALITY 要求目标支持 TLS 1.3；h2 是现代浏览器的常态，缺失会显得异常。
   **后量子密钥交换 X25519MLKEM768 为优先项（不是硬性要求）**：用已安装的 `xray tls ping` 检测，支持的目标排在前面；若本地区没有支持的候选，仍会选用其余检测全部通过的目标，并给出一行警告（REALITY 可正常使用，只是没有后量子密钥交换保护）。`--sni` / 手动输入的域名同样只警告不拒绝。
   **ML-DSA-65（pqv）需要目标证书链总长度 ≥ 3500 字节**（同样由 `xray tls ping` 检测，列表中的 Chain 列）：不满足时服务端带 `mldsa65Seed` 会导致所有客户端 REALITY 握手失败（`handshake did not complete successfully`），因此脚本会自动对该目标关闭 pqv；满足的目标排序时也会优先。
3. **HSTS**：说明是认真维护 HTTPS 的正规网站。
4. **证书链有效**（`openssl s_client -verify_return_error -verify_hostname`）。
5. **不在 CDN / WAF 后面**：解析 IP 对照 <https://www.cloudflare.com/ips-v4>、ips-v6，并按响应头识别 Cloudflare（`server: cloudflare`、`cf-ray`）、Imperva/Incapsula（`x-iinfo`、`x-cdn: Imperva`、`incap_ses` / `visid_incap` Cookie）、Fastly（`x-served-by: cache-…`、`x-fastly-*`、`via: … varnish`）、Akamai（`server: AkamaiGHost`、`x-akamai-*`）、CloudFront（`via: … cloudfront`、`x-amz-cf-*`）、Azure Front Door（`x-azure-ref`）以及 Sucuri、BunnyCDN。CDN 节点与你的 VPS 明显不属于同一网络，且这类站点被大量滥用做 REALITY 目标（只用 `tr` + `grep -iE`，Alpine / busybox 下同样可用）。
6. **不是被墙网站或大厂默认域名**：google / yahoo / apple / microsoft / amazon / cloudflare / github / 各大社交平台等被列入黑名单（这些域名要么被墙，要么是所有人都在用的“默认值”，特征明显）；`.cn` 域名也会被排除。

检测通过的候选会列出前几名（TCP 延迟、TLS 握手时间、IP 归属），默认选第一名，也可以手动输入域名（同样会检测，不合格时需二次确认）。高级选项 `--scan` 会下载官方 RealiTLScanner，对 VPS 附近 IP 做 60 秒低并发扫描，找出同机房的 TLS1.3 + h2 站点后再走同样的检测流程；扫描可能被少数服务商视为端口扫描，请自行权衡。

---

## 客户端配置

安装结束或执行 `proxy info` 会给出所有链接和二维码。

### v2rayN（Windows）/ v2rayNG（Android）

- 复制 `vless://` 链接 → 「从剪贴板导入」。新版 v2rayN 支持 `pqv`（ML-DSA-65 验证），旧版如果导入失败，请使用「不含 pqv」的那条链接（或扫描二维码，二维码默认就是不含 pqv 的版本，因为 pqv 太长放不进终端二维码）。
- XHTTP 也是 `vless://`，参数里有 `type=xhttp`、`path=`、`mode=stream-one`，没有 `flow`。不要改成 `auto`，也不要填 `xtls-rprx-vision`。
- Trojan + REALITY 是 `trojan://`，`security=reality`，v2rayNG 可以导入。
- `hysteria2://` 链接同样可以直接导入，`mport` 参数即端口跳跃范围。
- **当前 v2rayNG 不能导入 `tuic://` 和 `anytls://`。** 这两条给 v2rayN、sing-box 或 mihomo 用。
- 核心请使用较新的 Xray-core（≥ 25.7，支持 mldsa65；XHTTP + REALITY 需要带 XHTTP 的版本）。

### mihomo / Clash Verge Rev / Clash Meta for Android

把输出的 `proxies:` 片段粘贴进配置文件，并在 `proxy-groups` 里引用节点名称。要点：

- VLESS：`reality-opts.public-key`、`reality-opts.short-id`，`client-fingerprint: chrome`，`flow: xtls-rprx-vision`；
- XHTTP + REALITY：`network: xhttp`，`xhttp-opts.path` / `mode: stream-one`，同样带 `reality-opts`，不要写 flow；
- 打开了 CDN 线路时另有两条：`network: xhttp` 且 `mode: packet-up`，或 `network: ws`，`tls: true`，`servername` 是自有域名，没有 `reality-opts`，也不要 `skip-cert-verify`；
- Trojan：`type: trojan`，`network: tcp`，`reality-opts` 与 Vision 相同；
- TUIC：`type: tuic`，`udp: true`，`alpn: [h3]`，`skip-cert-verify: true`；
- AnyTLS：`type: anytls`，`skip-cert-verify: true`，`client-fingerprint: chrome`；
- Hysteria2：`ports: 20000-50000` 端口跳跃，`fingerprint:` 为证书 SHA256 指纹（固定证书，无需跳过证书验证）；
- mihomo 目前不支持 REALITY 的 ML-DSA-65 验证（`pqv`），不影响连接（pqv 只是额外的可选校验）。

### Shadowrocket（iOS）

- 直接扫描二维码或复制 `vless://`（不含 pqv 版）导入，确认「XTLS: xtls-rprx-vision」「REALITY 公钥 / ShortId」已自动填好，指纹选 chrome。
- Hysteria2 链接可直接导入；若版本不支持 `mport` 端口跳跃，节点仍可通过主端口 443 使用；证书处开启「允许不安全」并确保指纹（pinSHA256）已填入。

### 官方 Hysteria2 客户端 / sing-box

`/root/proxy-info.txt` 中额外提供了官方多端口写法：`hysteria2://密码@IP:443,20000-50000/?sni=...&insecure=1&pinSHA256=...`。

没有自有域名时，Hysteria2 / TUIC / AnyTLS 仍是上面的自签证书（`insecure`、`pinSHA256`、`skip-cert-verify`）。申请公开证书之后，这三条的地址和 SNI 改为你的域名，按正常证书校验，不要再开允许不安全。Cloudflare 源站证书不会交给这三条，它们仍用自签。REALITY / XHTTP / Trojan 始终借用伪装站点，不使用这张证书。CDN 上的 XHTTP+TLS / WebSocket+TLS 使用公开证书或源站证书。见下文「申请证书」和「经过 CDN 的两条线路」。

---

## 申请证书

默认不申请，也不需要域名。REALITY 继续借用伪装站点；Hysteria2 / TUIC / AnyTLS 继续用自签证书（CN = 所选 SNI）。

不写种类时，仍是 Let's Encrypt 单域名，走 HTTP-01：

```bash
bash proxy.sh --auto --cert-domain example.com
```

已安装之后：

```bash
proxy cert
```

菜单第 17 项作用相同。里面先选种类，再按该种类的说明往下做。交互安装只会问一次要不要申请默认的 Let's Encrypt 单域名，默认「否」。`--auto` 不带域名、也不带 `--cert-kind` 时不会申请。已经申请过的，重装时如果没有写 `--cert-kind`、`--cert-domain` 或 `--cert-names`，种类不变；证书还有效就跳过重新申请。只写了 `--cert-domain`、没写 `--cert-kind` 时，按默认的 Let's Encrypt 单域名处理。`proxy --no-cert` 用来关闭。

换一种证书：在 `proxy cert` 里另选种类，或带上新的 `--cert-kind`。脚本会先关掉旧的那张，再申请新的。Hysteria2 / TUIC / AnyTLS 在新证书签下来之前先回到自签。已经打开的 CDN 线路开关留着，但中间会停掉监听，新证书好了再挂上。REALITY 的端口、密钥和伪装站点不动。

继续申请 Let's Encrypt 即表示同意其服务条款（<https://letsencrypt.org/repository/>）。邮箱可选（`--cert-email`），不填则不登记。

### Let's Encrypt 单域名（默认）

适合订阅 HTTPS，以及 Hysteria2、TUIC、AnyTLS。不适合通配符：HTTP-01 证明不了 `*.example.com`。

域名的全部 A/AAAA 必须指向本机。申请和续期时关掉橙色云朵（灰色，仅 DNS），否则验证请求会打到 Cloudflare，本机 80 收不到。80 被占用时不会申请。只暂时占用 TCP 80，不改 REALITY 的端口。

签好之后：

- 订阅只提供 HTTPS：`https://域名:8447/sub/<token>`（v2rayN / v2rayNG / Shadowrocket，内容是分享链接的 base64）和同路径下的 `/clash`（mihomo）。明文 HTTP 不返回订阅内容。端口用 `--sub-port` 修改，不能是 80，也不能占用 REALITY / XHTTP / Trojan / AnyTLS / CDN 线路的 TCP 端口。
- Hysteria2、TUIC、AnyTLS 出示这张证书。分享链接和 mihomo 配置里的地址、SNI 改为该域名，不再带 `insecure`、`allowInsecure`、`pinSHA256` 或 `skip-cert-verify`，也不再固定证书指纹。客户端按正常校验即可。
- REALITY、XHTTP、Trojan 仍使用服务器地址和伪装 SNI，配置里不写入这张证书。
- 若另外打开了 CDN 上的 XHTTP+TLS 或 WebSocket+TLS，这两条入站也出示这张证书。见下一节。
- 伪装站点（`--sni`）只影响 REALITY。换 SNI 时，这三条协议的证书和链接不用跟着换。

续期由 systemd timer（每天）或 OpenRC 的 `/etc/periodic/daily` 完成，大约 90 天一轮，到期前约 30 天续。续期成功后重启 Hysteria2、sing-box 和订阅服务。只有打开了 CDN 线路（存在 `/etc/proxy-oneclick/cdn-xray`）时，才把证书复制给 Xray 并重启 Xray。REALITY 入站不使用这张证书。

### 通配符（DNS-01）

HTTP-01 不能签发通配符。选 `wildcard`（Let's Encrypt）或 `zerossl-wildcard`。证书里同时有 `*.example.com` 和 `example.com`。星号只覆盖一级子域名，不覆盖 `a.b.example.com`。

```bash
bash proxy.sh --cert-kind wildcard --cert-domain example.com --cf-dns-token <令牌>
```

`--cert-domain` 写根域名，不要写成 `*.example.com`。链接默认用根域名。要写进链接的是另一个被这张证书覆盖的名字时，加 `--cert-link cdn.example.com`。

DNS：在 Cloudflare 给 `_acme-challenge` 添加 TXT，云朵必须是灰色。通配符和根域名是两条内容不同的 TXT，都要留下。名称只填 `_acme-challenge`，不要再套一层域名。API 令牌的权限是 Zone → DNS → 编辑，以及 Zone → Zone → 读取。这不是 Origin CA Key。令牌放在 `/etc/proxy-oneclick/cf-dns.token`（权限 600），不写入 `state.env`；命令行参数会出现在进程列表里。

没有令牌时，脚本把 TXT 内容打在屏幕上，并等待 1.1.1.1 和 8.8.8.8 能查到。这种方式不能自动续期，到期前要再运行 `proxy cert` 添加一次。保存了令牌才会交给定时任务，而且续期不占用 80。

这是公开证书。Hysteria2 / TUIC / AnyTLS 和订阅的变化与单域名相同。REALITY 不变。这个名字若开了橙色云朵，那几条直连协议不能再靠它，请改用服务器 IP，或用 `--cert-link` 指定一个仍是灰色云朵的子域名。

### 多域名

选 `multi` 或 `zerossl-multi`。几个名字在同一张证书上，走 HTTP-01。每个名字的 A/AAAA 都要指向本机，并且是灰色云朵。有一个失败，整张都不会下来。不能写 `*.域名`。

```bash
bash proxy.sh --cert-kind multi --cert-names www.example.com,api.example.com
```

链接和订阅用名单里的第一个名字。要用其中另一个，加上 `--cert-domain`，它必须出现在名单里。协议变化与单域名公开证书相同。REALITY 不变。

### ZeroSSL

`zerossl`、`zerossl-wildcard`、`zerossl-multi` 和上面三种 Let's Encrypt 证书是同一类公开证书，只是换了一家 CA。客户端仍按正常校验。

必须有一对 EAB 凭据，在 <https://app.zerossl.com/developer> 生成，用 `--zerossl-kid` 和 `--zerossl-hmac` 一起传入。KID 和 HMAC 必须是同一对，HMAC 里的 `+` `/` `=` 要原样保留。凭据在 `/etc/proxy-oneclick/zerossl.eab`（权限 600），不写入 `state.env`。

单域名和多域名仍要灰色云朵和 TCP 80。通配符仍要 DNS-01。建议加上 `--cert-email`；不填则不登记，若 ZeroSSL 拒绝注册，补上邮箱再试。

### Cloudflare 源站证书

选 `cf-origin`。只有 Cloudflare 信任它。浏览器直接打开会报不安全。Hysteria2、TUIC、AnyTLS 的客户端会拒绝。订阅 HTTPS 也不能用。

只适合两条 CDN 线路（XHTTP+TLS、WebSocket+TLS），并且域名开着橙色云朵，加密模式选「完全（严格）」。脚本不会把这张证书装进 Hysteria2、TUIC、AnyTLS，也不会打开订阅。REALITY 不动。

```bash
bash proxy.sh --cert-kind cf-origin --cf-origin-key <钥匙> --cert-domain cdn.example.com --xhttp-tls
```

钥匙是 Origin CA Key：<https://dash.cloudflare.com/profile/api-tokens> 页面最下面。不是普通 API 令牌，也不是添加 TXT 的 DNS 令牌。保存在 `/etc/proxy-oneclick/cf-origin.key`（权限 600）。主机名必须属于这个账号里的区域。写了 `*.example.com` 时，根域名会一并放进证书。不占用 80，不走 certbot。有效期大约 15 年，不会自动续期；要换种类就重新申请，脚本会先关掉这一张。

CDN 线路还没打开时，证书签好也不会被任何协议使用。到协议开关里打开 XHTTP+TLS 或 WebSocket+TLS。

### 关闭

`proxy --no-cert`，或在 `proxy cert` 里选择关闭。公开证书关掉后，Hysteria2 / TUIC / AnyTLS 改回自签，订阅停止，当时开着的 CDN 线路也会关掉。源站证书关掉后，CDN 线路停止；那三个协议本来就是自签。REALITY 不变。关闭时令牌和 EAB 文件先留着，方便下次再申请。卸载才会删掉。

NAT 模式和落地机不能申请任何一种。不带证书参数时，这些环境的安装与现在相同。

申请或续期失败时，脚本用中文说明该先改哪里：域名没指到本机、80 被占用、橙色云朵挡了 HTTP-01、TXT 没被公共 DNS 看到、令牌和 Origin CA Key 用反了、ZeroSSL 的 EAB 不成对、多域名里有一个名字失败、源站证书的主机名不在这个 Cloudflare 账号里。REALITY 不会因此改掉。

---

## 经过 CDN 的两条线路

默认关闭，也不替换 REALITY、XHTTP+REALITY、Hysteria2、Trojan、TUIC、AnyTLS。两条都不是 REALITY：客户端连你自己的域名，CDN 再回源到本机的独立端口，本机用已经签好的证书终止 TLS。默认是公开证书。只给这两条用、并且开着橙色云朵时，可以改成 Cloudflare 源站证书；那张证书不能给 Hysteria2、TUIC、AnyTLS 或订阅。

| 线路 | 默认端口 | 路径 | 客户端要点 |
|---|---|---|---|
| VLESS + XHTTP + TLS | TCP 2083 | `/xhttp-` + 随机十六进制 | `security=tls`，`type=xhttp`，`mode=packet-up`，`sni` 和 `host` 都是自有域名 |
| VLESS + WebSocket + TLS | TCP 2087 | `/ws-` + 随机十六进制 | `security=tls`，`type=ws`，`sni` 和 `host` 都是自有域名 |

安装时加上参数（域名必须已经解析到本机）：

```bash
bash proxy.sh --auto --cert-domain example.com --xhttp-tls
bash proxy.sh --auto --cert-domain example.com --ws-tls
```

两条可以一起开。端口用 `--xhttp-tls-port`、`--ws-port` 修改。已安装之后，在 `proxy proto`（菜单第 16 项「协议开关」）里选第 7、第 8 项。打开时会先确认证书，再打印一份中文教程：DNS 怎么填、橙色云朵、回源端口、加密模式「完全（严格）」、链接里必须有什么、以及不要把 REALITY 放进 CDN。装完想再看一遍：

```bash
proxy cdn
```

Cloudflare 免费代理只转发这几个 HTTPS 端口：443、2053、2083、2087、2096、8443。默认避开 443，把 443 留给 REALITY 直连。8443 若已被 XHTTP+REALITY 占用，就不能再给 CDN。80 只留给证书申请，不能当回源端口。

面板里建议这样填：

1. A 记录（子域名就填主机名，根域名填 `@`）指向本机公网 IP，代理打开（橙色云朵）。有 IPv6 再加 AAAA。
2. SSL/TLS 加密模式选「完全（严格）」。不要选「灵活」。
3. 源站端口填 2083 或 2087（和链接里的端口相同）。云安全组放行这个 TCP。
4. 给该路径加一条绕过缓存，不要改写路径。
5. WebSocket 这一条还要在 Cloudflare「网络」里打开 WebSockets。

链接里不要出现 `flow`、`security=reality`、`pbk`、`sid`、`pqv`、`insecure`。XHTTP 这一条不要用 `stream-one`（那是直连 REALITY 的 XHTTP）。不要把地址改成 IP。

这个域名开了橙色云朵之后，Hysteria2、TUIC、AnyTLS 和订阅不能再靠它连接：Cloudflare 不转发 UDP，也不转发订阅端口 8447。那几条继续用服务器 IP，或另做一个灰色云朵的名字。脚本不会因此关掉它们。

对不上号时，脚本用中文说明该先改哪里，而不是只丢一行命令失败。至少包括：域名没有解析到这台机器、80 或 443 被占用、证书没有签发、Cloudflare 521/522、回源证书和域名不一致、路径不一致、WebSocket 升级被拒绝。本机检查没过时，REALITY 和原来的协议保持原样。

NAT 模式和落地机不能开。没有证书（公开证书或源站证书），或和 `--no-cert` 一起用时，也不会开。

---

## ⚠️ 云服务商防火墙

脚本只能管理系统内的 nftables。安装结束、修改端口、`proxy firewall` 和 `proxy status` 会列出本机已经放行的端口，以及每一条属于哪个协议。云安全组要放行同一份。**AWS EC2 / Lightsail、Google Cloud、Oracle Cloud、Azure、阿里云、腾讯云** 等还有控制台层面的安全组 / 防火墙，请手动放行：

- TCP 443（或你设置的 VLESS-REALITY 端口）
- TCP 8443（XHTTP，若已开启）
- UDP 443 以及 UDP 20000-50000（Hysteria2 + 端口跳跃）
- 若打开了可选协议：TCP 8444（Trojan）、TCP 8445（AnyTLS）、UDP 8446（TUIC）
- 若打开了 CDN 线路：TCP 2083（XHTTP+TLS）、TCP 2087（WebSocket+TLS），或你改过的回源端口。这是给 Cloudflare 回源用的，不是 REALITY
- HTTP-01 的单域名或多域名另外放行：TCP 80（只给证书续期，不提供订阅）、以及公开证书的 TCP 8447（订阅 HTTPS，或你设置的 `--sub-port`）。通配符 DNS-01 不需要 80。源站证书既不需要 80，也不开订阅

Oracle Cloud 的官方镜像还自带 iptables 规则，如仍不通请一并检查。

NAT 小鸡不需要放行这些端口：只要在服务商面板里建好对应的端口映射（Reality + Hysteria2 共用端口时协议选「全部 / TCP+UDP」），脚本结束时会列出「公网端口 → 本机端口」对照表。

---

## 线路检测

`proxy route`（菜单第 18 项，落地机菜单第 12 项）只看路由。不改 Xray、Hysteria2、sing-box 和防火墙，不重启，也不测流媒体解锁。没装节点、NAT 模式、落地机都可以跑。需要本机有 `curl`；路径探测用已安装的 `traceroute`、`mtr`、`nexttrace` 或 `ping`（调用 nexttrace 时带 `--traceroute`，不和 `--mtr` 混用）。TCP/8080 没有往返时会改用 ICMP traceroute、ICMP mtr 和 ping。没有这些命令时，对应的探测会写成无法打分，而不是编一个分数。缺 `jq` 时会尝试安装；装不上就用 `python3` 读 JSON。

报告按 IPv4、IPv6 各一份，里面是中文说明，不是一行口号。每一份都有：

- **本机接入**：公网地址、源 ASN、Cloudflare `cdn-cgi/trace` 看到的位置和 colo。这个位置用来估算理论往返下限（球面距离的公里数除以 100）。
- **回国回程**：电信、联通、移动分开。只测从 VPS 发向运营商地址的回程，不把结果说成从家里到 VPS 的去程。电信按 CN2 GIA（AS4809 且 59.43，不夹 AS4134 / 202.97）高于 CTG→CN2（AS23764 再到 4809），再高于 CN2 GT，再高于 CTG→163 和普通 163。59.43 和 202.97 同时出现是 CN2 GT，只有 202.97 是普通 163。电信 IPv4 会测河南、福建、江苏里挂在 CN2（AS4809）上的地址，以及广东电信 DNS。每个目标的档次都会写出来；档次不一致时取看到的最低档，避免把普通 163 标成 GIA 或 GT。递归 DNS 经常进 163，不能单靠它判断业务是不是 CN2 GIA。回程探测目标可能与业务流量路径不同。联通按 9929 高于 10099，再高于 4837。移动按 CMIN2（AS58807）高于 CMI（AS58453），再高于普通 CMNET。普通 163 和 4837 各 15 分，CMI 和 10099 各 45 分。每家先算线路档次、延迟、丢包，再三家平均。某一家测试地址都测不通时记 0，并且算进平均。延迟或丢包没测到时写成「未测」，按已经测到的项目折算，不把缺测当成 0 分。到北京的理论下限不到 40 毫秒时，延迟按绝对毫秒分档，避免近距离几十毫秒被比例压得很低。只有星号、解析不出自治系统时写成测不通，不写成未能识别。
- **国际线路**：这台机器和谁互联。上游先取 RIPEstat looking-glass 里、紧挨在本 ASN 前面的 ASN。采集点很少时，只把探测路径上紧挨本机的下一跳并进去（例如实际走了 PCCW）。本机 ASN 不在路径里时也只取这一跳，中国电信、联通、移动和目标自己的 ASN 不算上游。IP 反查走 bgp.tools（或 Team Cymru）的 whois 43 端口，不抓网页。left 邻居超过 12 个时不当成上游。交换中心用 PeeringDB 的不重复 `ix_id`。权重是上游 30、Tier1 40、IX 30。三项有一项接口失败就写「国际线路无法打分」，不把失败当成 0 分的很差。PeeringDB 查询包了一层超时，失败就停，不会一直卡住。
- **国际互联**：到亚太、北美、欧洲目标的 traceroute / mtr / ping。路径分成直连/对等、Tier1 中转、Tier2/3、多跳、绕路、不可达。直连要求路径里只剩下目标自己的 ASN，中间不能再有别的运营商；两条 Tier1 不算直连，AS0 不算一跳。延迟没测到时只按路径档折算，不记 0 分。本机在亚太时权重是亚太 50、北美 25、欧洲 25；在北美是 20 / 50 / 30；在欧洲是 20 / 30 / 50。绕路看往返是否超过理论下限的两倍，并且多出不少于 30 毫秒。路径上出现不该出现的北美或欧洲骨干时写成绕美或绕欧；没有这些运营商、但时延仍然明显偏高，也按绕路计。没有往返时间时不判绕路。没有解析出自治系统的探测不计入平均。上游名单里有、但这条路径没经过的运营商会单独点出来：有 Cogent、NTT 不等于去欧洲时真的走了它们。
- **总评**：回国回程、国际线路、国际互联三个分数并排。90–100 顶级，80–89 优秀，65–79 良好，45–64 一般，低于 45 很差。没有第四个合成总分。

档次是 100 分制。回国每一家是线路最多 60、延迟最多 25、丢包最多 15，例如 `移动回程 88/100（线路 CMIN2 60、延迟 20、丢包 8）`。三项都测到时才是这个满分结构；缺了延迟或丢包就按剩下的折算，并标明未测。

电信 IPv4 样本是河南、福建、江苏的 CN2 地址（AS4809），外加广东电信 DNS。联通样本是天津、广东、湖南，已经去掉不回应的北京联通 DNS。东京用仍会回应探测的 WIDE 地址，阿姆斯特丹用 Leaseweb AMS，不再用已经不回应的 RIPE 地址。改完这套计分后，在 VPS 上重新跑一次 `proxy route`。如果延迟仍是未测，先确认这台机器的 `ping` 能通。

去程不会在 VPS 上测。报告最后给出可以复制的命令，在你自己的电脑上跑：Linux / macOS 是 `traceroute -n -w 1 -q 1 <地址>` 和 `nexttrace --traceroute <地址>`，Windows 是 `tracert -d <地址>`。

局限也写在报告里：只覆盖回程和从本机向外的国际路径；晚高峰和白天可能差很多；traceroute 中间的星号不等于丢包；Telegram 等任播落点不一定是标出来的城市。IPv6 上如果同时看到 Hurricane Electric（AS6939）和 Cogent（AS174），会说明这两家长期不交换 IPv6 路由。

---

## 常用维护

**菜单**

```bash
proxy
```

```
█▀▀▀█ █▀▀▀█
█ 哈 █ █ 人 █
█▄▄▄█ █▄▄▄█
oneclick proxy  ·····  v1.3.0

IP        ▶ …              Xray      ▶ …
Hysteria2 ▶ …              sing-box  ▶ 未安装
状态      ▶ 运行中          模式      ▶ 普通

════════════════════════════════
         oneclick proxy
════════════════════════════════
 1. 安装 / 重新安装                   10. 防火墙管理
 2. 查看链接 / 二维码 / Clash 配置    11. 网络调优（BBR / 队列算法 / 缓冲区 / 恢复）
 3. 更换 SNI（重新优选目标网站）      12. 添加 / 修改落地转发（本机作中转，出口走落地机）
 4. 重新生成密钥 / UUID               13. 安装为落地机（Shadowsocks 2022 出口，给其它中转机用）
 5. 修改端口 / 端口跳跃               14. 卸载
 6. 用户管理（添加 / 删除）           15. 切换 NAT 模式（当前: 自动/开/关）
 7. 更新 Xray / Hysteria2 / 脚本      16. 协议开关
 8. 运行状态 / 日志                   17. 申请证书
 9. 网络测速 / 延迟提示               18. 线路检测（回程 / 国际线路 / 国际互联）
────────────────────────────────
  0. 退出
════════════════════════════════
```

NAT 模式下第 10 项显示为「NAT 信息 / 端口跳跃」。落地机菜单是 12 项（没有客户端直连协议，第 12 项仍是线路检测），框标题同样是 `oneclick proxy`。

**协议开关**（第 16 项，或 `proxy proto`）：逐个打开 / 关闭 Reality、XHTTP、Hysteria2、Trojan、TUIC、AnyTLS，以及 CDN 上的 XHTTP+TLS（第 7 项）、WebSocket+TLS（第 8 项）。关掉只停止监听，UUID、x25519、ShortId、ML-DSA 种子、XHTTP 路径、CDN 路径和各协议密码都留着。至少保留一个协议。重新生成密钥（第 4 项）会换掉这些密钥和 CDN 路径，但不会把已关闭的协议重新打开。已申请公开证书时，重新生成密钥不会把 Hysteria2 / TUIC / AnyTLS 换回自签证书。打开 CDN 线路时会打印教程并做一次检查。想再看教程：`proxy cdn`。

**申请证书**（第 17 项，或 `proxy cert`）：选择种类并申请、续期、查看链接，或关闭证书。默认仍是 Let's Encrypt 单域名。见「申请证书」。

**线路检测**（第 18 项，落地机菜单第 12 项，或 `proxy route`）：见「线路检测」。只探测，不改已经装好的协议。

**切换 NAT 模式**（第 15 项，落地机菜单为第 11 项）：`自动`（默认：Alpine 强制 NAT、LXC/OpenVZ 容器安装时询问、已安装的沿用原模式）/ `开`（强制 NAT 映射端口流程，等同 `--nat`）/ `关`（强制普通模式，等同 `--no-nat`；Alpine 不可用）。在第 1 或 13 项安装前选择即可；设置保存在 `state.env`（`NAT_PREF`），之后的修改端口等操作都按它执行。已安装时切换到不同模式会提示立即重新安装（保留密钥 / UUID）；命令行 `--nat` / `--no-nat` 优先并同步该设置。

**链接 / 二维码 / mihomo 配置**

```bash
proxy info
```

**重新优选或手动更换 SNI**（未申请证书时，Hysteria2 证书与指纹会同步更新；已申请时 Hysteria2 / TUIC / AnyTLS 仍用域名证书）

```bash
proxy sni
```

**添加 / 删除额外用户**（UUID + 备注）

```bash
proxy user
```

**更新 Xray / Hysteria2 / 脚本**

```bash
proxy update
```

**只更新本脚本**（proxy 命令）

```bash
proxy update-script
```

**服务状态、时间同步、日志、防火墙放行了哪些端口、fail2ban**

```bash
proxy status
proxy firewall
```

`proxy firewall` 先列出每个已放行端口和它的协议，再提供放行、重载或停用。`proxy status` 里是同一份列表；选「查看 nftables 原文」才是规则原文。入站仍然默认拒绝。

**BBR 状态、到 SNI 的延迟、下载测速**（Cloudflare / CacheFly / OVH 自动切换）

```bash
proxy speed
```

**线路检测**（回程、国际线路、国际互联，三项分开；不改配置）

```bash
proxy route
proxy route ipv4
proxy route ipv6
```

见「线路检测」。

**网络调优**：状态 / 预设 / 恢复（见「网络调优」）

```bash
proxy tune
```

**落地转发**（中转机）/ 落地机链接（落地机）

```bash
proxy land
```

**中转机添加 / 替换落地**

```bash
proxy land-add 'ss://...'
```

**落地机：修改来源 IP 白名单**

```bash
proxy allow
```

主要文件：

| 路径 | 说明 |
|---|---|
| `/root/.proxy-oneclick/state.env` | 全部参数与密钥（600） |
| `/root/.proxy-oneclick/users.txt` | 额外用户 |
| `/root/.proxy-oneclick/backup/` | 安装前的 nftables / iptables 规则备份 |
| `/root/proxy-info.txt` | 节点信息（600） |
| `/usr/local/etc/xray/config.json` | Xray 配置 |
| `/etc/hysteria/config.yaml` | Hysteria2 配置 |
| `/usr/local/bin/sing-box` | TUIC / AnyTLS 核心（未启用时不安装） |
| `/etc/sing-box/config.json` | sing-box 配置（未申请公开证书时用 Hysteria2 的自签证书，CN = 所选 SNI；公开证书申请之后用那张证书。源站证书不写到这里） |
| `/etc/letsencrypt/live/proxy-oneclick/` | Let's Encrypt 或 ZeroSSL 证书（仅 ACME 申请之后；源站证书不在这里） |
| `/etc/proxy-oneclick/certs/` | 复制出来的 `fullchain.pem` / `privkey.pem`（私钥 640，组 `proxy-cert`），以及订阅文件 `sub.json`、`sub.txt`、`sub-clash.yaml` |
| `/etc/proxy-oneclick/cf-dns.token` | Cloudflare DNS 令牌（600，仅通配符保存过令牌时）。不写入 `state.env` |
| `/etc/proxy-oneclick/zerossl.eab` | ZeroSSL 的 EAB KID 和 HMAC（600） |
| `/etc/proxy-oneclick/cf-origin.key` | Cloudflare Origin CA Key（600） |
| `/usr/local/lib/proxy-oneclick/sub_https.py` | 订阅 HTTPS（只监听订阅端口，不监听 80；源站证书不会启动它） |
| `/usr/local/lib/proxy-oneclick/cert-deploy.sh` | 续期后复制证书，并重启 Hysteria2、sing-box、订阅服务。仅当存在下面的标记文件时，才把证书拷给 Xray 并重启 Xray |
| `/usr/local/lib/proxy-oneclick/dns-auth.sh` | 通配符 DNS-01：添加 TXT，或提示手工添加并等待公共 DNS |
| `/usr/local/lib/proxy-oneclick/dns-cleanup.sh` | 删掉这次添加的那一条 TXT |
| `/etc/proxy-oneclick/cdn-xray` | CDN 线路已打开的标记。没有这个文件时，续期不会重启 Xray |
| `/usr/local/etc/xray/certs/` | 给 XHTTP+TLS / WebSocket+TLS 用的证书副本（私钥 640，组为 `nobody` 所在组）。REALITY 不读这里 |
| `/etc/systemd/system/proxy-oneclick-sub.service` / `/etc/init.d/proxy-oneclick-sub` | 订阅 HTTPS 服务 |
| `/etc/systemd/system/proxy-oneclick-cert.timer` | systemd 每日续期 |
| `/etc/periodic/daily/proxy-oneclick-cert` | OpenRC 每日续期 |
| `/var/log/proxy-oneclick/sub.log` | 订阅访问日志（只记状态码，不记路径和 token） |
| `/root/.proxy-oneclick/firewall.nft` | 本脚本的 nftables 规则 |
| `/root/.proxy-oneclick/nat-hop.sh` | NAT 模式端口跳跃规则脚本（仅开启跳跃时） |
| `/etc/systemd/system/proxy-oneclick-hop.service` / `/etc/init.d/proxy-oneclick-hop` | 开机加载端口跳跃规则（仅开启跳跃时） |
| `/etc/init.d/xray`、`/etc/init.d/hysteria-server` | OpenRC 服务脚本（Alpine） |
| `/etc/sysctl.d/99-proxy-tune.conf` | 网络调优参数（唯一的 sysctl 文件） |
| `/root/.proxy-oneclick/tune/` | 调优前原值备份 `backup.env`、当前预设 `current.env`、容器开机脚本 `boot.sh` |
| `/etc/systemd/system/proxy-oneclick-tune.service` / `/etc/init.d/proxy-oneclick-tune` | 容器内开机重新应用调优（仅容器环境） |
| `/root/.proxy-oneclick/land-fw.nft` | 落地机来源白名单 nftables 规则（表 `inet proxy_oneclick_land`，仅启用白名单且非 NAT 容器时） |
| `/etc/systemd/system/proxy-oneclick-land-fw.service` / `/etc/init.d/proxy-oneclick-land-fw` | 开机加载落地机白名单 |
| `/var/log/xray/`、`/var/log/hysteria/` | OpenRC 下的服务日志（systemd 下用 `journalctl -u xray` / `-u hysteria-server`） |

---

## 卸载

**交互确认**

```bash
proxy uninstall
```

**免确认**

```bash
proxy uninstall --auto
```

会移除：Xray、Hysteria2（含 hysteria 用户）、sing-box（若装过 TUIC / AnyTLS）、nftables 表与 systemd 单元、sysctl / limits / journald 配置（并恢复调优前的参数值）、fail2ban 规则、`proxy` 命令、节点信息；可选择是否删除密钥与备份目录；安装时被停用的 firewalld / ufw 会询问是否恢复。安装时创建的 `/swapfile` 会保留（附删除方法）。NAT 模式还会移除 OpenRC 服务脚本、日志目录、端口跳跃规则，并恢复 `--dns64` 修改前的 `/etc/resolv.conf`。落地机还会移除白名单规则表与开机服务。若申请过证书，还会停掉订阅和续期、删除证书副本与订阅文件、CDN 标记和交给 Xray 的那份证书副本，并删除 certbot 里名为 `proxy-oneclick` 的那张证书；不卸载 certbot 软件包。最后别忘了在云控制台关闭不再需要的端口。

---

## 已知限制

- 候选 SNI 列表是人工整理的，网站配置会变化；脚本每次都会实测，但某些地区可能全部不合格，此时请手动输入或使用 `--scan`。SG / PH 本地自建（非 CDN）的站点很少，通常会扩大到邻近地区。
- 在容器 / OpenVZ 等环境中 BBR、Swap 及部分 sysctl 可能无法生效（脚本会逐项检测并说明跳过原因）。容器无法加载内核模块：BBR / fq 等需要宿主机已加载；OpenVZ 7 容器通常完全不能修改拥塞控制。
- 不会安装第三方内核（如 XanMod 的 BBRv3）；已经在用这类内核时，脚本只识别并使用其提供的算法。
- Hysteria2 目前只有一个共享密码，「用户管理」只给 VLESS Reality / XHTTP 加用户，不含 Trojan、TUIC、AnyTLS。
- 没有加入 NaiveProxy：它要单独的 naive 程序，并且需要一个能签发证书的自有域名（通常还要 Caddy 或 Nginx）。这和本脚本「不要求自己的域名、用 REALITY / 自签证书」的做法差得太远。
- Shadowsocks 2022 不是主机上的客户端直连协议，只在落地机模式里作为出口。
- 只有一条 NAT 映射时默认装不上 XHTTP（需要第二个外部 TCP 端口），脚本会跳过它并继续安装 Reality + Hysteria2。
- TUIC / AnyTLS 的链接当前 v2rayNG 不能导入。
- NAT 模式下端口跳跃需要整段转发 + DNAT 能力；只有零散几条映射或容器里没有 nftables/iptables 时无法跳跃（此时只用主端口）。
- NAT 模式 Hysteria2 的逗号多段 `mport`（如 `10003-10009,10011-10020`）并非所有客户端都支持；不支持时可只使用主端口。
- 服务商映射如果只转发 TCP，Hysteria2 必须另配一个 UDP 映射端口（`--nat-no-share`）。
- 落地转发只改变本机 Xray / Hysteria2 代理流量的出口，本机系统自身的流量（apt、脚本下载等）仍然直连。
- 落地机只支持 Shadowsocks 2022；中转机 `land-add` 只接受 SS2022 链接。Xray 26.x 会对 Shadowsocks 打印弃用提示（官方推荐 VLESS Encryption），将来如被移除需要改用其它协议。
- NAT 容器落地机的白名单只由 Xray 路由实现（非白名单连接会被接受后丢弃，而不是在防火墙层拒绝）。
- Let's Encrypt / ZeroSSL 的单域名和多域名需要公网能访问本机 TCP 80（HTTP-01）。通配符改走 DNS-01，不占用 80，但 TXT 必须是灰色云朵。NAT / Alpine 不能申请任何一种。HTTP-01 续期同样需要 80 空闲。没有保存 DNS 令牌的通配符不能自动续期。
- 订阅只走 HTTPS，不在 80 上提供内容。token 放在路径里，请把订阅地址当作密钥。Cloudflare 源站证书不会打开订阅。
- 公开证书大约 90 天轮换一次，所以 Hysteria2 / TUIC / AnyTLS 在使用这张证书时不固定指纹。没有域名时仍用自签证书和 `pinSHA256`。源站证书大约 15 年，而且不会交给这三个协议。
- REALITY 不使用这张证书，继续借用伪装站点。不要把 REALITY 放进 CDN。换证书种类也不会改 REALITY。
- CDN 上的 XHTTP+TLS / WebSocket+TLS 需要自有域名，以及公开证书或 Cloudflare 源站证书，还有 Cloudflare 允许代理的回源端口。源站证书只有 Cloudflare 信任，不能给浏览器和直连客户端。NAT / Alpine / 落地机不能开。域名开了橙色云朵后，不要再用这个名字连接 Hysteria2、TUIC 或订阅。
- XHTTP 走 CDN 时用 `packet-up`。`stream-one` 只用于直连的 XHTTP+REALITY。WebSocket 需要 CDN 打开 WebSockets，路径必须和链接里逐字相同。
- `proxy route` 只测从 VPS 出发的回程和向外的国际路径。它不能代替在自己电脑上做的去程，也不能把国际线路和国际互联合成一个分数。测试地址会失效，任播目标的时延下限只是参照。
