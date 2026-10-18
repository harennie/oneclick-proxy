# oneclick proxy

单文件 Bash 脚本，一键在 VPS 上安装代理节点，不需要自己的域名。

- 默认装好 VLESS + REALITY + Vision、VLESS + XHTTP + REALITY 和 Hysteria2，可选 Trojan、TUIC、AnyTLS 与 CDN 线路
- 自动优选 REALITY 伪装站点，Hysteria2 支持端口跳跃；有域名时可以另外申请证书
- 防火墙可严格默认拒绝，也可只放行代理端口；检测到 Docker 等环境时默认用温和模式，避免挡住现有服务
- 支持 Debian / Ubuntu / RHEL 系（systemd）和 Alpine NAT（OpenRC），装完用 `proxy` 菜单管理
- 可安装为落地机（Shadowsocks 2022），并用 `proxy route` 检测回程线路

## 一键安装

**交互安装**（推荐，先下载再运行，可以看到菜单）

```bash
curl -fsSLo proxy.sh https://raw.githubusercontent.com/harennie/oneclick-proxy/main/proxy.sh && bash proxy.sh
```

**全自动**（全部使用默认值，无任何交互）

```bash
curl -fsSLo proxy.sh https://raw.githubusercontent.com/harennie/oneclick-proxy/main/proxy.sh && bash proxy.sh --auto
```

**Alpine NAT**（Alpine 没有自带 bash，必须带 `--nat`）

```bash
apk add bash curl && curl -fsSLo proxy.sh https://raw.githubusercontent.com/harennie/oneclick-proxy/main/proxy.sh && bash proxy.sh --nat
```

装完后执行 `proxy` 打开管理菜单，`proxy info` 查看链接 / 二维码 / Clash 配置。节点信息同时保存在 `/root/proxy-info.txt`（权限 600）。

下面各节是完整说明，默认折叠。

<details>
<summary>一键安装</summary>

## 一键安装

单文件 Bash 脚本，一键在 VPS 上安装代理节点，不需要自己的域名。有已经解析到本机的自有域名时，可以另外申请证书；不申请时，安装方式和现在一样。默认是 Let's Encrypt 单域名。也可以改成通配符、多域名、ZeroSSL，或只给 CDN 用的 Cloudflare 源站证书。证书签好之后，还可以另开两条给 CDN 用的线路（XHTTP+TLS、WebSocket+TLS），默认关闭，不替换 REALITY。

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

双栈（同时能用 IPv4 和 IPv6 出站）在安装、重装或改写节点配置时会询问一次出站策略：IPv4优先（`46`）、IPv6优先（`64`）、仅IPv4（`4`）、仅IPv6（`6`），并记在 `state.env` 的 `OUTBOUND_IP`，之后沿用。`--auto` 还没保存过选择时使用 IPv4优先。只有一种地址时按那一种出站。

本机 IPv6 只有内网 ULA（`fc00::/7`，例如 `fd42::`）时，会用 `curl -6` 探测。回显是公网 IPv6（NAT66）就按双栈，可以选 IPv6优先。回显仍是 ULA 或探测失败，则当作没有 IPv6。这个选择只影响代理出站（Xray 的 `domainStrategy`、Hysteria2 的 `direct.mode`、sing-box 的地址策略）。落地机用同一套；原样转发按它重选 DNAT 目标。查看和修改见下方「常用维护」里的 `proxy outbound`。

### 命令行参数

| 参数 | 说明 |
|---|---|
| `--auto` | 全部默认值、非交互安装 |
| `--outbound <策略>` | 出站：`46` IPv4优先、`64` IPv6优先、`4` 仅IPv4、`6` 仅IPv6、`auto` 清掉已记住的选择再按本次检测。可与 `--land` 一起用。检测不到所写的地址族时只警告，仍按指定的写 |
| `--sni <域名>` | 指定 REALITY 目标网站（依然会做合规检测，不合格则拒绝） |
| `--force-sni` | 配合 `--sni`，检测不通过也强制使用 |
| `--scan` | 高级：用 [RealiTLScanner](https://github.com/XTLS/RealiTLScanner) 扫描 VPS 附近 IP 寻找同机房目标（约 60 秒） |
| `--port <N>` | VLESS-REALITY TCP 端口，默认 443（NAT 模式可写 `外部:内部`，如 `59221:443`） |
| `--no-hy2` / `--hy2` | 不安装 / 安装 Hysteria2（默认安装） |
| `--hy2-port <N>` | Hysteria2 UDP 端口，默认 443（NAT 模式可写 `外部:内部`） |
| `--no-reality` / `--reality` | 关闭 / 开启 VLESS + REALITY + Vision（默认开启） |
| `--no-xhttp` / `--xhttp` | 关闭 / 开启 VLESS + XHTTP + REALITY（默认开启，不需要自己的域名） |
| `--xhttp-port <N>` | XHTTP 的 TCP 端口，默认 8443（NAT 模式为外部端口，可写 `外部:内部`）。与 Vision 共用端口时这条不单独监听 |
| `--xhttp-on-443` / `--no-xhttp-on-443` | XHTTP 与 Vision 共用 / 分开同一个 TCP 端口。默认分开（8443）。已有安装保持原来的选择。`--auto` 且 NAT 只有一个 TCP 映射时会直接共用 |
| `--trojan` / `--no-trojan` | 额外启用 / 关闭 Trojan + REALITY（默认不装） |
| `--trojan-port <N>` | Trojan TCP 端口，默认 8444 |
| `--tuic` / `--no-tuic` | 额外启用 / 关闭 TUIC v5（sing-box，自签证书，默认不装） |
| `--tuic-port <N>` | TUIC UDP 端口，默认 8446 |
| `--anytls` / `--no-anytls` | 额外启用 / 关闭 AnyTLS（sing-box，自签证书，默认不装） |
| `--anytls-port <N>` | AnyTLS TCP 端口，默认 8445 |
| `--xhttp-tls` / `--no-xhttp-tls` | 额外启用 / 关闭 VLESS + XHTTP + TLS（放在 CDN 后面，默认不装）。需要 `--cert-domain`。不是 REALITY，也不替换原来的 XHTTP+REALITY |
| `--xhttp-tls-port <N>` | 这条线路的回源 TCP 端口，默认 2083。须是 Cloudflare 允许代理的 HTTPS 端口：443、2053、2083、2087、2096、8443。不要占用 REALITY |
| `--ws-tls` / `--no-ws-tls` | 额外启用 / 关闭 VLESS + WebSocket + TLS（放在 CDN 后面，默认不装）。`--ws` / `--no-ws` 相同。需要 `--cert-domain` |
| `--ws-port <N>` | 这条线路的回源 TCP 端口，默认 2087。端口范围同上 |
| `--vless-enc` / `--no-vless-enc` | 两条 CDN 线路加 / 不加 VLESS Encryption（默认加，ML-KEM-768 + X25519）。只影响 XHTTP+TLS 和 WebSocket+TLS |
| `--hop <a-b\|none>` / `--no-hop` | Hysteria2 端口跳跃范围，默认 `20000-50000`，`none` 或 `--no-hop` 关闭（NAT 模式默认关闭，可写多段 `a-b,c-d`） |
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
| `--firewall <模式>` | `strict` 入站默认拒绝；`allow` 只放行代理端口和端口跳跃，不把入站改成默认拒绝，也不改 Docker 的表；`off` 不写 nftables。不写时：干净机器默认 `strict`；检测到 Docker/Podman、WireGuard、已有防火墙或多个非标准端口时，交互安装默认推荐 `allow`，第一次非交互安装直接用 `allow`。已经装过又没写 `--firewall` 时，`--auto` 沿用保存的模式。`allow` 时若 ufw 或 firewalld 正在运行，会把同样的端口写进去 |
| `--no-firewall` | 不配置 nftables 防火墙（同 `--firewall off`） |
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

管理子命令：`proxy info | proto | sni | regen | port | user | update | status | doctor | speed | firewall | nat | cert | cdn | vless-enc | tune | route | outbound | export | import | land | land-add | land-test | land-off | land-on | land-del | land-direct | land-forward | allow | uninstall`（加 `--auto` 可在脚本/自动化里免确认，例如 `proxy uninstall --auto`）。`proxy route` 只做回程线路检测，不改配置。`land-direct` 与 `land-forward` 只在落地机上切换出口。`proxy outbound` 只改代理出站的地址族。`proxy doctor` 默认只读。

装完之后改协议（不删除已有 UUID、Reality 密钥、XHTTP 路径、CDN 路径和各协议密码）：

```bash
proxy proto
```

菜单第 16 项「协议开关」作用相同。前三项默认开着：VLESS + REALITY + Vision、VLESS + XHTTP + REALITY、Hysteria2。第 4–6 项默认关：Trojan + REALITY、TUIC v5、AnyTLS。第 7–8 项是默认关的 CDN 线路，第 9 项只给这两条做 VLESS Encryption。Vision 和 XHTTP 都开着时，菜单下方的 `s` 切换是否共用同一个 TCP 端口。在这个菜单里关掉，只停止对应监听，不卸载程序，至少留一个协议。

共用或分开端口：

```bash
proxy proto xhttp-443 on
```

```bash
proxy proto xhttp-443 off
```

带开关重跑安装也会保留这些密钥。已经装过时会先确认，加 `--auto` 跳过确认：

```bash
proxy --no-xhttp
```

```bash
proxy --tuic --auto
```

```bash
proxy --no-hy2 --auto
```

`--no-hy2` 这种重装会卸掉 Hysteria2 程序和服务，密码仍留在 `state.env`。关掉 TUIC / AnyTLS 时停止 sing-box，不删密码。之后用菜单或对应参数再打开，缺的程序会重新装上。

---

</details>

<details>
<summary>默认协议</summary>

## 默认协议

默认一次装好三个，都不需要自己的域名：

- **VLESS + REALITY + XTLS-Vision**（含后量子签名 ML-DSA-65）
- **VLESS + XHTTP + REALITY**（与 Vision 共用同一把 Reality 密钥和 SNI，单独 TCP 端口）
- **Hysteria2**（端口跳跃 + 证书指纹固定）

第一次交互安装会确认 XHTTP 和 Hysteria2，直接回车就是装上。已经装过再重装时，回车沿用现在的开关。`--auto` 第一次按这三个默认值安装；状态里已经记下的开关会沿用，除非写了 `--xhttp` / `--no-xhttp` 或 `--hy2` / `--no-hy2`。更早的状态文件里如果没有 `XHTTP_ENABLED` 这一项，下一次安装会按默认打开 XHTTP。

可选协议默认不装，安装时也不会询问：Trojan + REALITY、TUIC v5、AnyTLS，以及两条 CDN 线路（VLESS + XHTTP + TLS、VLESS + WebSocket + TLS）。安装时加 `--trojan`、`--tuic`、`--anytls`、`--xhttp-tls`、`--ws-tls`，或装完后用上面的 `proxy proto`。CDN 这两条还要有已经解析到本机的自有域名和公开证书（Let's Encrypt / ZeroSSL，或只给这两条用的 Cloudflare 源站证书）。Shadowsocks 2022 只出现在落地机模式里，节点菜单里没有这条直连入站。

---

</details>

<details>
<summary>功能</summary>

## 功能

- **环境预检**：必须 root；识别发行版与架构（amd64 / arm64）；显示 IP、城市、ASN、内存；内存 < 1G 且无 Swap 时自动加 1G Swap；自动更新系统并安装依赖（RHEL 系自动启用 EPEL）；未检测到时间同步服务时自动安装并启用 systemd-timesyncd / chrony（REALITY 要求系统时间准确）。
- **系统调优（保守，不换内核）**：普通模式安装时默认启用 BBR + fq；TCP/UDP 缓冲区（满足 Hysteria2 建议的 16MB）、文件句柄上限；journald 日志上限 100M。配置写入 `/etc/sysctl.d/99-proxy-tune.conf`，卸载时恢复原值。也可以用 `proxy tune` 单独调整 / 恢复，见下文「网络调优」。
- **Xray（普通模式用官方 XTLS/Xray-install 安装最新版；NAT、Alpine 和落地机直接下载 XTLS/Xray-core Release 并校验 SHA256）**：
  - VLESS + REALITY + `xtls-rprx-vision`，默认 TCP 443；
  - 自动生成 UUID、x25519 密钥、ShortId（`openssl rand -hex 4`）、**ML-DSA-65**（服务端 `mldsa65Seed`，客户端链接 `pqv=`）；ML-DSA-65 要求目标网站证书链总长度 ≥ 3500 字节，不满足时脚本会自动对该目标关闭 pqv（REALITY 本身照常可用）；
  - 客户端指纹 `fp=chrome`（实测 `randomized` 生成的随机 ClientHello 会被部分目标网站拒绝，导致 REALITY 握手失败）；
  - 每次写配置前先 `xray run -test` 校验，失败不会覆盖旧配置；
  - 以 `nobody` 运行，配置文件 `root:nogroup 640`，私钥/种子只保存在 `/root/.proxy-oneclick/state.env`（600），不会在屏幕上显示；
  - 屏蔽访问服务器内网（geoip:private）与 BT。
  - 官方脚本遇到 GitHub API 限流（403）时，会自动改为“指定最新版本号”重试。
  - 更新前把当前程序备份为 `/usr/local/bin/xray.bak`。该目录剩余空间不足 50 MB 时跳过备份并警告。直接下载时先在临时文件上跑 `version`，并对当前配置跑 `xray run -test`，通过后才替换。官方安装脚本会自己写入程序，脚本在写完后做同样的检查，不通过就恢复备份。可用 `--xray-ver <标签>` 安装指定的已发布版本。
  - **安装后 REALITY 自检**：用已安装的 xray 在 127.0.0.1 随机端口起一个临时客户端，按生成的链接参数连接本机节点并访问外网，打印通过 / 未通过（不影响安装；更换 SNI 后也会自动自检）。临时客户端限制 `GOMEMLIMIT`，128MB 的 NAT 小鸡也能跑。
- **REALITY 目标网站自动优选**（见下文「为什么 SNI 规则很重要」）。
- **Hysteria2（可选，默认启用）**：普通模式用官方 get.hy2.sh；NAT / Alpine 直接下载 apernet/hysteria Release 并校验 SHA256。落地机不装 Hysteria2。自签 EC 证书（CN = 所选 SNI），客户端使用 `pinSHA256` 固定证书指纹；随机密码；监听 UDP 443；伪装为反向代理 `https://<SNI>`；nftables 实现 UDP 20000-50000 → 443 端口跳跃。申请公开证书后，Hysteria2 改为出示那张证书，链接地址和 SNI 换成自有域名，不再带 `insecure` 或 `pinSHA256`。Cloudflare 源站证书不会交给 Hysteria2。更新前备份为 `hysteria.bak`（剩余空间不足 50 MB 时跳过并警告）。Hysteria2 没有配置检查命令，只确认新程序能跑 `version`。可用 `--hy2-ver <标签>`（例如 `v2.6.1`）安装指定版本。
- **防火墙（nftables）**：独立表 `inet proxy_oneclick`，不改 Docker / Podman 自己的表。模式为 `strict`（入站默认拒绝，干净机器的默认）、`allow`（只放行代理端口和端口跳跃，不接管入站策略；检测到 Docker/Podman、WireGuard 或其它 UDP、已有 nftables/iptables/ufw/firewalld，或多个非标准监听端口时，交互安装默认推荐它，非交互且未指定 `--firewall` 时直接用它；已经装过又没写 `--firewall` 则沿用保存的模式，fail2ban 的 nftables 表不算已有规则）或 `off`（`--no-firewall`，不写规则）。严格模式放行 lo、已建立连接、ICMP/ICMPv6、DHCPv6 回包、**自动探测的 SSH 端口**（`sshd -T`、配置文件、监听进程、ssh.socket 及当前 SSH 会话端口）、当前已开启协议的 TCP/UDP 端口及 Hysteria2 跳跃范围；检测到其它对外服务时会询问是否一并放行。只有 HTTP-01（Let's Encrypt / ZeroSSL 的单域名或多域名）才额外放行 TCP 80。只有公开证书才放行订阅 HTTPS 端口。通配符 DNS-01 和 Cloudflare 源站证书不放行 80，源站证书也不开订阅。应用前先 `nft -c` 校验并备份原规则；由 systemd 单元 `proxy-oneclick-fw.service` 开机加载。检测到 firewalld / ufw 时，严格模式会询问是否停用（卸载时可恢复）；只放行模式，或选择保留它们时，会把当前代理端口和 Hysteria2 跳跃范围写进正在运行的 ufw（注释 `proxy-oneclick`）或 firewalld 默认区域，并记在 `/root/.proxy-oneclick/fw-host.list`。已经存在的放行（不论原来的注释）不会改注释，也不会记进这份清单。SSH 不记进清单，清理时也不会删。改端口、关协议、切换模式和卸载时只按清单删除本脚本自己加的规则。本机没有 ufw 也没有 firewalld 时这一步不做。不会关闭 SELinux（写入文件后执行 `restorecon`）。防火墙菜单、运行状态和安装结束时会逐行列出已经放行的端口，以及每一条属于哪个协议（Reality、XHTTP、Hysteria2、Trojan、TUIC、AnyTLS、CDN 的 XHTTP 与 WebSocket、订阅、证书申请的 TCP 80、SSH、端口跳跃，以及额外放行），并写出已经同步到 ufw / firewalld 的条目。严格模式下，没写出来的新连接仍然拒绝；只放行模式不会丢掉其它端口。装好后可用 `proxy firewall strict`、`proxy firewall allow`、`proxy firewall off` 切换。
- **fail2ban**：sshd 监狱，10 分钟内失败 5 次封禁 1 小时（systemd 日志后端 + nftables 动作）。
- **XHTTP（默认开启）**：VLESS + XHTTP + REALITY。与 Vision 共用同一把 x25519、ShortId、SNI 和 ML-DSA-65 种子，默认单独监听 TCP 8443，`flow` 必须为空，路径为随机 `/` + 十六进制。服务端和客户端链接的 `mode` 都是 `stream-one`（REALITY 直连；客户端用 `auto` 时有已知握手失败）。不需要自己的域名，也不把自己的证书挂到 XHTTP 上。这条和下面的「XHTTP + TLS（CDN）」是两条入站，互不替换。加上 `--xhttp-on-443`（或 `proxy proto xhttp-443 on`）后，Vision 的入站用 Xray fallbacks 把非 Vision 流量交给本机的 XHTTP 入站（优先 `/dev/shm/xray-xhttp.sock`，没有则用 127.0.0.1），链接端口、SNI、公钥和 ShortId 与 Vision 相同，防火墙不再单独放行 8443。已有安装默认仍是分开的 8443。NAT 只有一个 TCP 映射时，安装会建议或直接启用共用。
- **可选协议（默认关闭，安装时不会询问）**：Trojan + REALITY（Xray，TCP 8444，同一把 Reality 密钥）；TUIC v5（sing-box，UDP 8446，BBR，ALPN h3）和 AnyTLS（sing-box，TCP 8445）。后两个默认复用 Hysteria2 的自签证书（CN = 所选 SNI），客户端需要允许不安全证书。申请公开证书后，这两条改为出示该证书，客户端按正常校验。Cloudflare 源站证书不会交给它们。当前 v2rayNG 不能导入 `tuic://` 和 `anytls://`，请用 v2rayN / sing-box / mihomo。更新 sing-box 时同样先备份为 `sing-box.bak`（空间不足 50 MB 则跳过），临时文件要通过 `version` 和 `sing-box check` 才替换。可用 `--singbox-ver <标签>` 安装指定版本。
- **CDN 上的两条线路（默认关闭）**：VLESS + XHTTP + TLS（TCP 2083，`mode=packet-up`）和 VLESS + WebSocket + TLS（TCP 2087）。用公开证书，或只用这两条时改用 Cloudflare 源站证书。都不是 REALITY。打开时脚本会打印 DNS、橙色云朵、回源端口、加密模式和客户端链接该怎么填。详见「经过 CDN 的两条线路」。
- **输出**：每个已开启协议单独一块：名称、地址、端口各一行，链接本身最后单独一行。vless://（含 / 不含 pqv）、xhttp 的 vless://（`mode=stream-one`，无 flow）、hysteria2://（未申请证书时带 `mport`、`sni`、`insecure=1`、`pinSHA256`；申请之后地址和 SNI 为自有域名，不再带 insecure / pin）、可选的 trojan:// / tuic:// / anytls://。打开 CDN 线路后另有两条 vless://（`security=tls`，没有 flow / pbk / sid / pqv / insecure）。终端二维码，mihomo（Clash.Meta）YAML 片段。申请公开证书后另有仅 HTTPS 的订阅地址。源站证书没有订阅。
- **管理菜单**：顶部字符 Logo 是「哈人」，正下方小标题和菜单框标题是 `oneclick proxy`。主菜单两列编号，第 16 项是「协议开关」，第 17 项是「申请证书」，第 18 项是「回程线路检测」，第 19 项是「导出配置」，第 20 项是「导入配置」，第 21 项是「健康检查」。其余是：安装/重装、查看链接和二维码、更换 SNI、重新生成密钥、修改端口、添加/删除用户（UUID + 备注，只写入已开启的 VLESS 入站）、更新 Xray/Hysteria2/脚本、状态与日志、测速与延迟提示、防火墙管理、网络调优、落地转发、安装为落地机、卸载、切换 NAT 模式。落地机是另一套 18 项的两列菜单，框标题同样是 `oneclick proxy`。
- **回程线路检测**：`proxy route` 只测从本机发向大陆的回程（电信 / 联通 / 移动，北京 / 上海 / 广州）。用 nexttrace 的 TCP，缺了会自动装。结果是一张短表和按运营商的汇总，不测国际线路，也不测从家里到本机的去程。不改配置，不重启。详见「回程线路检测」。
- **落地机 / 落地转发**：`--land` 把本机装成只跑 Shadowsocks 2022 的出口（落地机）；已安装的节点用 `proxy land-add 'ss://...'` 把出口切到落地机（中转），见下文。
- **健壮性**：`set -o errexit -o pipefail -o errtrace` + 错误陷阱提示出错行；可重复运行（保留已有密钥，只更新组件与配置）；安装前检查端口占用；没有 IPv6 也能正常工作（链接使用 IPv4）；通过 shellcheck 检查。

---

</details>

<details>
<summary>支持的系统</summary>

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

</details>

<details>
<summary>NAT 小鸡模式（`--nat`）</summary>

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

XHTTP 默认还要第二条外部 TCP 端口（8443，不能和 Vision 的 TCP 443 抢同一条映射）。只有一个 TCP 映射时，`--auto` 会让 XHTTP 与 Vision 共用这个外部端口；交互安装默认也选共用，选否才会跳过 XHTTP，安装仍然成功（Reality + Hysteria2）。安装时也可以直接写 `--xhttp-on-443`。有第二条映射时，默认仍是分开的端口，用 `--xhttp-port` 指定。只要 Reality + Hysteria2 时加 `--no-xhttp`。

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

</details>

<details>
<summary>网络调优（`proxy tune`）</summary>

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

</details>

<details>
<summary>落地机 / 落地转发</summary>

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
  - Xray 路由：来源在白名单内走当前出口（本机直连，或加密转发时的下一跳），否则 → blackhole（任何环境都有效，本机回环始终允许，用于自检）；
  - nftables：非 NAT 容器且有 nft 时，额外加一张独立的表 `inet proxy_oneclick_land`，只在 SS 端口上丢弃非白名单来源（不影响其它端口，不是默认拒绝防火墙），开机由 `proxy-oneclick-land-fw` 服务加载。NAT 容器（LXC / OpenVZ 等）只用 Xray 路由。原样转发不让 Xray 听这个端口，来源限制写在 DNAT 上。
  - 注意：NAT 小鸡经服务商端口映射进来的连接，来源 IP 可能被改成服务商网关地址；中转机测试失败时，看落地机的实际来源 IP 再加进白名单。
- **安装结束输出**：`ss://` 链接（SIP002，2022 加密使用百分号编码的 `方法:密钥`，不用 base64）、**中转机一键命令** `proxy land-add 'ss://...'`、可直接粘贴到其它 Xray 配置的 **outbound JSON 片段**、mihomo 片段；并做一次落地机自检（临时客户端 → 本机 SS2022 → 外网，显示出口 IP）。
- **出站地址族**：与节点相同，可用 `--outbound 46|64|4|6|auto` 或装完后的 `proxy outbound`。原样转发按这个策略重选 DNAT 目标。

**出站 IPv6优先的落地机**

```bash
bash proxy.sh --land --auto --outbound 64 --land-allow 203.0.113.10
```

- **落地机菜单**（`proxy`，两列，框标题 `oneclick proxy`，顶部同样是「哈人」）：

```
═══════════════════════════════════════════════════════════════════════════════════════════════════
                                          oneclick proxy
═══════════════════════════════════════════════════════════════════════════════════════════════════
   1. 安装 / 重新安装（落地机）                       10. 卸载
   2. 查看 ss:// 链接 / 中转机命令 / Xray 出站片段    11. 切换 NAT 模式（当前: 自动/开/关）
   3. 修改来源 IP 白名单                              12. 回程线路检测
   4. 修改端口                                        13. 出口：本机直连（清除下一跳与原样转发）
   5. 更换密钥 / 加密方式                             14. 出口：加密转发（SS2022 再加密到下一跳）
   6. 更新 Xray / 脚本                                15. 出口：原样转发（不解密，DNAT 到最终落地）
   7. 运行状态 / 日志                                 16. 导出配置（迁到另一台机器）
   8. 网络调优（BBR / 队列算法 / 缓冲区 / 恢复）      17. 导入配置
   9. 改装为 Reality / Hysteria2 节点                 18. 健康检查
───────────────────────────────────────────────────────────────────────────────────────────────────
   0. 退出
═══════════════════════════════════════════════════════════════════════════════════════════════════
```

同一时间只启用一种出口。没有设置下一跳、也没有原样转发时，就是以前的本机直连：Shadowsocks 2022 入站后直连，`--land` 仍可与 `--outbound` 一起用。

命令行：`proxy info`（链接）、`proxy allow --land-allow 1.2.3.4,5.6.7.0/24`（改白名单，`none` 不限制）、`proxy port --port 9388`、`proxy regen [--land-method aes-256]`（换密钥 / 加密方式）、`proxy uninstall`。本机直连或加密转发时，改端口或密钥后需要在上一台重新 `land-add`。

**出口（落地机菜单第 13–15 项）**

```bash
proxy land-direct          # 同 land-clear：本机直连，清除下一跳、原样转发目标和 DNAT
proxy land-add 'ss://...'  # 加密转发：本机仍用自己的 ss:// 接上一跳，白名单来源再拨到下一跳
proxy land-forward 'ss://...'   # 同 land-raw：不解密，DNAT 到链接里的主机和端口
proxy land-off             # 停用当前的加密转发或原样转发，保留链接
proxy land-forward-off     # 同 land-raw-off：只去掉 DNAT，保留目标
proxy land-forward-del     # 同 land-raw-del：只删除原样转发目标
```

加密转发不安装 hy2-relay。交给上一台的是本机自己的 `ss://`；下一跳链接单独打印，不要交给上一台。`land-on` 重新启用已保存的下一跳，`land-del` 只删除加密转发。从中转机改装成落地机时不会沿用原来的中转链接；已经是落地机时重新安装会保留下一跳和原样转发目标。

原样转发要求来源白名单里已有与目标同族的地址，否则拒绝安装，不会留下开放的 DNAT。上一跳链接用本机地址和对外端口，加上最终落地的加密方式与密钥；最终机器的地址单独标出。Xray 不监听这个端口。出站策略（`--outbound`）同样约束目标地址族。切回本机直连或加密转发时会去掉 DNAT。

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

</details>

<details>
<summary>为什么 SNI（REALITY 目标网站）规则很重要</summary>

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

</details>

<details>
<summary>客户端配置</summary>

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

</details>

<details>
<summary>申请证书</summary>

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

</details>

<details>
<summary>经过 CDN 的两条线路</summary>

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

这两条默认带 VLESS Encryption（ML-KEM-768 + X25519，`native`，0-RTT），链接里的 `encryption=` 是 `xray vlessenc` 生成的一长串，Cloudflare 解开 TLS 后只看到密文。REALITY、XHTTP+REALITY、Hysteria2 等不受影响。需要 Xray-core 25.9.5+ 内核的客户端或 mihomo v1.19.14+；sing-box 内核的客户端（NekoBox 等）可能不支持。安装时加 `--no-vless-enc` 不加；装好之后用下面的命令，或在「协议开关」里选第 9 项：

```bash
proxy vless-enc
proxy vless-enc on
proxy vless-enc off
proxy vless-enc rotate
```

不带参数是查看。`on` / `off` 只重写 Xray，并刷新链接、`/root/proxy-info.txt` 和订阅，不重装。钥匙存在 state.env，重装、`proxy sni`、换证书都不变；`rotate` 和 `proxy regen` 才换新钥匙。

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

</details>

<details>
<summary>防火墙模式</summary>

## 防火墙模式

普通模式会配置 nftables，表名固定为 `inet proxy_oneclick`。只删除和重写这张表，以及旧内核上端口跳跃用的 `ip` / `ip6` `proxy_oneclick_nat`。不会 `flush` 整个规则集，也不会改 Docker、Podman 自己的表和链。

| 模式 | 行为 |
|---|---|
| `strict` | 入站默认拒绝。放行回环、已建立连接、ICMP、探测到的 SSH 端口、当前协议端口和 Hysteria2 端口跳跃。干净机器上的默认，也是原来的行为。 |
| `allow` | 只放行。给代理端口、SSH 和端口跳跃写 accept，链策略保持 accept，优先级放在常见 filter 之后，不把入站改成默认拒绝。Docker 发布端口、WireGuard、其它 UDP 和已经存在的防火墙不会被这张表丢掉。 |
| `off` | 不写 nftables。`--no-firewall` 与此相同。 |

```bash
bash proxy.sh --auto --firewall strict
bash proxy.sh --auto --firewall allow
bash proxy.sh --firewall off
```

不写 `--firewall` 时，安装会先看这台机器：Docker 或 Podman（含 iptables-nft 里的转发链和发布端口）、WireGuard 或其它 UDP 监听、已经存在的 nftables / iptables / ufw / firewalld，以及多个非标准对外端口。fail2ban 自己的表（`f2b-table` 以及名字里带 fail2ban 的表）不算「已有 nftables 规则」，本脚本配置 fail2ban 时就会建这张表。有这些情况时，交互安装默认推荐「只放行」，并写明原因；干净机器默认仍是「严格」。`--auto` 且没有写 `--firewall` 时，发现上述情况就直接用 `allow`，否则用 `strict`。已经安装过再执行（重装或带 `--auto` 的更新）且没有写 `--firewall` 时，沿用 `state.env` 里保存的模式，不会因为 fail2ban 的表从严格改成只放行。显式写了 `--firewall strict` 时按严格模式执行，并提示可能受影响的服务。

SSH：严格模式在加载前探测 SSH 端口（`sshd -T`、配置文件、正在监听的 sshd、ssh.socket、当前会话端口）。探测不到时至少放行 22，并且先放行已建立连接。规则里如果缺了当前 SSH 端口，会改成只放行而不是加载默认拒绝。`allow` 和 `off` 不改入站策略，本来就不会把 SSH 关在外面。写进 ufw / firewalld 时也不记录、不删除 SSH 规则。重新启用被本脚本停掉的 ufw 之前，会先确认 SSH 端口已经放行。

检测到 firewalld / ufw 时，只有选择严格模式才会询问是否停用（卸载时可恢复）。Debian 上 fail2ban 带有 `PartOf=firewalld.service`，停用 firewalld 会把 fail2ban 一起停掉；若停用前 fail2ban 正在运行，脚本会再把它拉起来。ufw 也一样处理。只放行模式留着它们，并把当前代理端口和端口跳跃写进去：写入前先看 ufw 里有没有已经盖住该端口的放行（`ufw status numbered` / `ufw show added`，不看注释），有就跳过，避免 `ufw allow` 把用户原来的注释改成 `proxy-oneclick` 后再被清掉。本脚本新加的规则才写注释 `proxy-oneclick`（范围写成 `20000:50000/udp`）。firewalld 用 `--query-port`，已有端口不重复添加；范围写成 `20000-50000/udp`，写完重载一次。记录在 `/root/.proxy-oneclick/fw-host.list`。改端口、关协议、切到严格或关闭、卸载时，只按这份记录删除本脚本自己加的规则，不删用户自己加的，也不删 SSH。从严格切回只放行时，若严格模式停过 ufw，会先放行 SSH 再重新启用。选严格但选择保留 ufw / firewalld 时也走同一套同步。本机没有正在运行的 ufw 或 firewalld（例如 Alpine）时，这一步不做。`apt purge` 之后 systemd 里的 ufw.service / firewalld.service 仍可能显示 active (exited)；命令（`ufw` / `firewall-cmd`）或单元文件已经不在时，不再把它当成正在运行的防火墙。安装结束、`proxy firewall` 和 `proxy status` 会列出已经同步的条目。

装好之后切换，不重装：

```bash
proxy firewall
proxy firewall strict
proxy firewall allow
proxy firewall off
```

菜单「防火墙管理」里是同样的三项。`proxy firewall off` 会删掉本脚本写进 ufw / firewalld 的放行。这两个防火墙如果还开着，会额外警告：默认拒绝会挡住代理端口，可再执行 `proxy firewall allow`，或自行停用那个防火墙。卸载会删掉本脚本的表和 `proxy-oneclick-fw` 服务。NAT 模式不使用这套入站防火墙。落地机的来源白名单仍是单独的表 `inet proxy_oneclick_land`，只限制落地端口的来源，不是默认拒绝。

</details>

<details>
<summary>⚠️ 云服务商防火墙</summary>

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

</details>

<details>
<summary>回程线路检测</summary>

## 回程线路检测

`proxy route`（菜单第 18 项，落地机菜单第 12 项）只测从本机发向大陆的回程：电信、联通、移动，各看北京、上海、广州。不测国际线路，不测国际互联，也不测从家里到这台机器的去程。不改 Xray、Hysteria2、sing-box 和防火墙，不重启，也不测流媒体。没装节点、NAT 模式、落地机都可以跑。

缺 nexttrace 时会自动安装。先跑官方安装脚本 `https://nxtrace.org/nt`，失败再下载 GitHub 发布包里的二进制。探测默认用 TCP（`nexttrace --tcp`，每跳 1 次，单节点有时间上限）。TCP 很快结束但没有任何回应时，这一节点再试一次 ICMP。节点超时、解析失败或权限不够，只打一行原因。

```bash
proxy route            # IPv4 回程（默认；没有 IPv4 时改测 IPv6）
proxy route ipv6       # 只测 IPv6
proxy route all        # IPv4 和 IPv6 都测
proxy route icmp       # 改用 ICMP
proxy route verbose    # 额外打印每一跳。可以和上面几项写在一起
```

结果是一张短表：运营商、城市、线路、延迟，下面按运营商汇总。线路只看路径里的自治系统和骨干地址，不看终点自己的地址。例如 59.43 且没有 202.97 记为 CN2 GIA，59.43 和 202.97 同时出现记为 CN2 GT，AS9929 记为 9929，AS10099 记为 CUG，AS4837 记为 4837，AS58807 记为 CMIN2，AS58453 记为 CMI。中间跳都没回应、只看到终点时写成「未看到路径」。节点与 nexttrace 的 `--fast-trace` 相同（北京 / 上海 / 广州的电信 163、联通 4837、移动 CMNET 终点）。判定供参考，和业务流量不一定是同一条路。

---

</details>

<details>
<summary>常用维护</summary>

## 常用维护

**菜单**

```bash
proxy
```

```
█▀▀▀█ █▀▀▀█
█ 哈 █ █ 人 █
█▄▄▄█ █▄▄▄█
oneclick proxy  ·····  v1.6.0

IP        ▶ …              Xray      ▶ …
Hysteria2 ▶ …              sing-box  ▶ 未安装
状态      ▶ 运行中          模式      ▶ 普通

═════════════════════════════════════════════════════════════════════════════════════════════════════════════
                                               oneclick proxy
═════════════════════════════════════════════════════════════════════════════════════════════════════════════
   1. 安装 / 重新安装                               12. 添加 / 修改落地转发（本机作中转，出口走落地机）
   2. 查看链接 / 二维码 / Clash 配置                13. 安装为落地机（Shadowsocks 2022 出口，给其它中转机用）
   3. 更换 SNI（重新优选目标网站）                  14. 卸载
   4. 重新生成密钥 / UUID                           15. 切换 NAT 模式（当前: 自动/开/关）
   5. 修改端口 / 端口跳跃                           16. 协议开关
   6. 用户管理（添加 / 删除）                       17. 申请证书
   7. 更新 Xray / Hysteria2 / 脚本                  18. 回程线路检测
   8. 运行状态 / 日志                               19. 导出配置（迁到另一台机器）
   9. 网络测速 / 延迟提示                           20. 导入配置
  10. 防火墙管理                                    21. 健康检查
  11. 网络调优（BBR / 队列算法 / 缓冲区 / 恢复）
─────────────────────────────────────────────────────────────────────────────────────────────────────────────
   0. 退出
═════════════════════════════════════════════════════════════════════════════════════════════════════════════
```

NAT 模式下第 10 项显示为「NAT 信息 / 端口跳跃」。落地机菜单见「落地机 / 落地转发」：两列共 18 项，第 12 项是回程线路检测，第 13–15 项是出口（本机直连 / 加密转发 / 原样转发），第 16–17 项是导出和导入，第 18 项是健康检查，框标题同样是 `oneclick proxy`。

**修改端口**（第 5 项，或 `proxy port`）：可以改 Reality 的 TCP、Hysteria2 的 UDP，以及单独监听的 XHTTP 端口。命令行：

```bash
proxy port --xhttp-port 9443
```

也可同时写 `--port`、`--hy2-port`。XHTTP 与 Vision 共用端口时，改 Reality 的端口即可。改完会重写配置并重启；若安装时把代理端口同步进了正在运行的 ufw 或 firewalld，旧端口的本脚本规则会删掉，新端口会补上。NAT 模式改的是外部映射端口。

**协议开关**（第 16 项，或 `proxy proto`）。刚装好、还没开 CDN 时大致是这样（开/关跟着当前状态变）：

```
═══════════════════════════════════════════════════════════════════════════════════
                                  oneclick proxy
═══════════════════════════════════════════════════════════════════════════════════
   1. VLESS + REALITY + Vision  开     6. AnyTLS  关
   2. VLESS + XHTTP + REALITY  开      7. VLESS + XHTTP + TLS（CDN）  关
   3. Hysteria2  开                    8. VLESS + WebSocket + TLS（CDN）  关
   4. Trojan + REALITY  关             9. CDN 的 VLESS Encryption  开（密钥待生成）
   5. TUIC v5  关
───────────────────────────────────────────────────────────────────────────────────
   0. 返回
═══════════════════════════════════════════════════════════════════════════════════
```

第 9 项在新安装里先记为开，CDN 线路还没打开时密钥还没生成，所以显示「开（密钥待生成）」。打开第 7 或第 8 项时才会生成钥匙，链接里带上 `encryption=`。改成关之后显示「关」。这一项只加密第 7、第 8 项，Vision、XHTTP+REALITY 和 Hysteria2 不变。Vision 和 XHTTP 都开着时，菜单框下面还有一行 `s`，用来共用或分开 TCP 端口；命令是 `proxy proto xhttp-443 on` 和 `proxy proto xhttp-443 off`。默认仍是分开的 8443。

在这个菜单里关掉只停止监听，UUID、x25519、ShortId、ML-DSA 种子、XHTTP 路径、CDN 路径和各协议密码都留着，程序也不卸。至少保留一个协议。重新生成密钥（第 4 项）会换掉这些密钥、CDN 路径和 VLESS Encryption 钥匙，已关闭的协议也会换新密钥，但不会被重新打开。已申请公开证书时，重新生成密钥不会把 Hysteria2 / TUIC / AnyTLS 换回自签证书。打开 CDN 线路时会打印教程并做一次检查。想再看教程：`proxy cdn`。

**申请证书**（第 17 项，或 `proxy cert`）：选择种类并申请、续期、查看链接，或关闭证书。默认仍是 Let's Encrypt 单域名。见「申请证书」。

**回程线路检测**（第 18 项，落地机菜单第 12 项，或 `proxy route`）：见「回程线路检测」。只探测，不改已经装好的协议。

**导出 / 导入**（第 19、20 项，落地机菜单第 16、17 项）：把重建同一批节点需要的密钥打成权限 600 的 tar.gz。里面有 UUID、Reality 私钥、ShortId、ML-DSA-65 种子、SNI、监听端口、XHTTP 路径、各协议密码、Shadowsocks 2022 密钥、落地 / 中转配置、调优参数（不含网卡名），以及 Hysteria2 / TUIC / AnyTLS 的自签证书和已经申请的公开证书。不放公网 IPv4 / IPv6、NAT 地址和端口映射、虚拟化类型、内存档位。导入时重新检测这些，并重新检查 SNI、防火墙和证书。

```bash
proxy export
proxy export /root/node.tar.gz
proxy export --password
PROXY_EXPORT_PASS='...' proxy export /root/node.tar.gz.enc
proxy import /root/node.tar.gz
bash proxy.sh --import /root/node.tar.gz --auto
```

`--password` 会询问密码（不回显），用 `openssl enc -aes-256-cbc -pbkdf2` 加密。也可以把密码放在环境变量 `PROXY_EXPORT_PASS`。没有终端、也没有这个环境变量时，命令会直接退出并提示设置 `PROXY_EXPORT_PASS`，不会停在那里等输入。不会把密钥打成一行 base64 放在命令行里。NAT 机器导入后要重新填映射，例如再加上 `--nat-ports`。

**健康检查**（第 21 项，落地机菜单第 18 项，或 `proxy doctor`）：只读。依次看时间偏差（Cloudflare `cdn-cgi/trace` 的 `ts=`，超过 15 秒提醒）、服务是否在跑、端口是否在听、最近有没有内存不足或崩溃、nftables 表和已放行端口、ufw/firewalld 同步、Hysteria2 端口跳跃的 DNAT 和计数器（没有计数器的旧规则只记 INFO，重新应用防火墙后规则会带上 counter）、SNI 是否还合格、REALITY / XHTTP 回环自检、外部检查命令，以及公开证书是否快到期（不足 7 天提醒）。有失败项时退出码非 0。`proxy doctor --fix` 只做安全修复：拉起已停止的服务、`chronyc makestep` 或重启 timesyncd / OpenRC chronyd、按清单重写 ufw/firewalld、把 `state.env` 改成 600。修好之后会再查一遍，并列出这次修好的项目；原先失败的都已通过时退出码为 0。仍有失败则退出码非 0。不加 `--fix` 时不改任何配置。

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

**更新 Xray / Hysteria2 / sing-box / 脚本**

```bash
proxy update
proxy update --xray-ver v26.3.27
proxy update --hy2-ver v2.6.1
proxy update --singbox-ver v1.11.0
proxy update --rollback
proxy update --rollback xray
```

更新 Xray、Hysteria2 或 sing-box 之前，把正在用的程序复制为同目录的 `.bak`（例如 `/usr/local/bin/xray.bak`）。这个目录剩余空间不足 50 MB 时跳过备份，并给出警告。直接下载的新程序先放在临时路径：Xray 要能跑 `version`，并且对当前配置 `xray run -test` 通过；sing-box 要能跑 `version` 和 `sing-box check`；Hysteria2 没有配置检查，只跑 `version`。通过之后才替换原来的文件。未指定版本时，官方安装脚本会自己写入程序，脚本在它写完后立刻做同样的检查，不通过就恢复备份。指定 `--xray-ver` 时不走官方安装脚本：把该版本的发布包下载到临时目录，用当前配置跑过 `version` 和 `xray run -test` 之后，才备份程序和 `geoip.dat` / `geosite.dat` 并替换。校验失败不会改正在使用的文件，也不会用一份和当前程序相同的副本盖掉已有的 `.bak`。回滚 Xray 或启动失败自动换回时，地理数据文件一起恢复。换成新版本后如果服务没有起来，会自动恢复 `.bak`，并写明版本变化。

`--xray-ver`、`--hy2-ver`、`--singbox-ver` 在安装和 `proxy update` 里都能用。版本号必须是 GitHub 上已经发布的标签。Hysteria2 可以写 `v2.6.1` 或 `app/v2.6.1`。`--xray-ver` 下载的是该标签的官方 zip，不是安装脚本；临时程序没通过当前配置的检查时，现有程序、geo 文件和 `.bak` 都保持原样。`proxy update` 带了这些参数或 `--rollback` 时不再进入菜单，只处理写出的内核。

`--rollback` 用 `.bak` 换回程序并重启对应服务（systemd 和 OpenRC 都支持），打印 `旧版本 -> 新版本`。目标是 `xray`、`hy2`、`singbox` 或 `all`，不写就是 `all`。`all` 碰到没有 `.bak` 的组件会跳过并警告。点名了某一个（例如 `--rollback hy2`）但没有对应 `.bak` 时，命令失败退出。菜单第 7 项（落地机菜单第 6 项）里选「回滚到备份」是同一件事。

**只更新本脚本**（proxy 命令）

```bash
proxy update-script
```

**服务状态、时间同步、日志、防火墙放行了哪些端口、fail2ban**

```bash
proxy status
proxy firewall
```

`proxy firewall` 先列出每个已放行端口和它的协议，再提供放行、重载，或在严格 / 只放行 / 关闭之间切换。也可以直接：

```bash
proxy firewall strict
proxy firewall allow
proxy firewall off
```

`proxy status` 里是同一份列表；选「查看 nftables 原文」才是规则原文。严格模式入站默认拒绝。只放行模式只添加 accept，不把入站改成默认拒绝；ufw 或 firewalld 正在运行时，同一份端口会写进它们，并在列表下面标出已同步的条目。

**BBR 状态、到 SNI 的延迟、下载测速**（Cloudflare / CacheFly / OVH 自动切换）

```bash
proxy speed
```

**出站地址族**（只影响代理出站；不带参数只查看）

```bash
proxy outbound
```

**设为 IPv6优先**（已安装时重写 Xray / Hysteria2 / sing-box 并重启；落地机同样）

```bash
proxy outbound 64
```

**清掉已记住的选择，再按本次检测决定**（双栈且有终端时会询问）

```bash
proxy outbound auto
```

`46` 是 IPv4优先，`4` 是仅IPv4，`6` 是仅IPv6。见「一键安装」里的出站说明。

**回程线路检测**（只测回程，不改配置）

```bash
proxy route
proxy route ipv6
proxy route icmp
proxy route verbose
```

见「回程线路检测」。

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
| `/etc/sysctl.d/99-proxy-tune.conf` | 网络调优参数 |
| `/root/.proxy-oneclick/tune/` | 调优前原值备份 `backup.env`、当前预设 `current.env`、容器开机脚本 `boot.sh` |
| `/etc/systemd/system/proxy-oneclick-tune.service` / `/etc/init.d/proxy-oneclick-tune` | 容器内开机重新应用调优（仅容器环境） |
| `/root/.proxy-oneclick/land-fw.nft` | 落地机来源白名单 nftables 规则（表 `inet proxy_oneclick_land`，仅启用白名单且非 NAT 容器时） |
| `/etc/systemd/system/proxy-oneclick-land-fw.service` / `/etc/init.d/proxy-oneclick-land-fw` | 开机加载落地机白名单 |
| `/root/.proxy-oneclick/land-fwd.nft`、`/root/.proxy-oneclick/land-fwd.sh` | 原样转发 DNAT（表 `proxy_oneclick_fwd`，仅启用原样转发时） |
| `/etc/systemd/system/proxy-oneclick-fwd.service` / `/etc/init.d/proxy-oneclick-fwd` | 开机加载原样转发 |
| `/etc/sysctl.d/99-proxy-oneclick-fwd.conf` | 原样转发打开的 IP 转发（停用后恢复） |
| `/var/log/xray/`、`/var/log/hysteria/` | OpenRC 下的服务日志（systemd 下用 `journalctl -u xray` / `-u hysteria-server`） |

---

</details>

<details>
<summary>卸载</summary>

## 卸载

**交互确认**

```bash
proxy uninstall
```

**免确认**

```bash
proxy uninstall --auto
```

会移除：Xray、Hysteria2（含 hysteria 用户）、sing-box（若装过 TUIC / AnyTLS）、nftables 表与 systemd 单元、sysctl / limits / journald 配置（并恢复调优前的参数值）、fail2ban 规则、`proxy` 命令、节点信息；可选择是否删除密钥与备份目录；安装时被停用的 firewalld / ufw 会询问是否恢复；恢复 ufw 之前会先放行 SSH 端口。安装时创建的 `/swapfile` 会保留（附删除方法）。NAT 模式还会移除 OpenRC 服务脚本、日志目录、端口跳跃规则，并恢复 `--dns64` 修改前的 `/etc/resolv.conf`。落地机还会移除白名单规则表、原样转发 DNAT 与对应开机服务，并恢复原样转发改过的 IP 转发开关。若申请过证书，还会停掉订阅和续期、删除证书副本与订阅文件、CDN 标记和交给 Xray 的那份证书副本，并删除 certbot 里名为 `proxy-oneclick` 的那张证书；不卸载 certbot 软件包。最后别忘了在云控制台关闭不再需要的端口。

---

</details>

<details>
<summary>已知限制</summary>

## 已知限制

- 候选 SNI 列表是人工整理的，网站配置会变化；脚本每次都会实测，但某些地区可能全部不合格，此时请手动输入或使用 `--scan`。SG / PH 本地自建（非 CDN）的站点很少，通常会扩大到邻近地区。
- 在容器 / OpenVZ 等环境中 BBR、Swap 及部分 sysctl 可能无法生效（脚本会逐项检测并说明跳过原因）。容器无法加载内核模块：BBR / fq 等需要宿主机已加载；OpenVZ 7 容器通常完全不能修改拥塞控制。
- 不会安装第三方内核（如 XanMod 的 BBRv3）；已经在用这类内核时，脚本只识别并使用其提供的算法。
- Hysteria2、Trojan、TUIC、AnyTLS 各只有一个共享密码。「用户管理」添加的 UUID 会写进所有已开启的 VLESS 入站：Vision、XHTTP+REALITY，以及已经打开的 XHTTP+TLS 和 WebSocket+TLS。上面四个共享密码协议不加这个用户。
- 没有加入 NaiveProxy：它要单独的 naive 程序，并且需要一个能签发证书的自有域名（通常还要 Caddy 或 Nginx）。这和本脚本「不要求自己的域名、用 REALITY / 自签证书」的做法差得太远。
- Shadowsocks 2022 不是主机上的客户端直连协议，只在落地机模式里作为出口。
- 只有一条 NAT 的 TCP 映射时，XHTTP 默认与 Vision 共用这个外部端口（`--auto` 直接共用，交互安装默认选共用）。拒绝共用、又没有第二条 TCP 映射时，才会跳过 XHTTP 并继续安装 Reality + Hysteria2。
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
- `proxy route` 只测从本机发向大陆运营商的回程。它不能代替在自己电脑上做的去程。测试节点和骨干地址特征会变，线路名称只供参考。
- 严格防火墙会挡住没有写进放行列表的端口，包括 Docker / Podman 发布端口、WireGuard 和其它 UDP。这类机器用 `allow`（只放行）。只放行不修改入站默认策略，也不改 Docker / Podman 自己的表和链。ufw 或 firewalld 若正在运行，只放行模式会把代理端口写进它们；nftables 里的 accept 绕不过它们的默认拒绝。卸载会删掉本脚本的表 `inet proxy_oneclick`，并按记录删掉写进 ufw / firewalld 的条目，不会清空整个规则集。

---

</details>

<details>
<summary>更新日志</summary>

## 更新日志

### v1.6.0
- 菜单增加到 21 项。第 19 项导出配置（`proxy export`），第 20 项导入配置（`proxy import`），第 21 项健康检查（`proxy doctor`，`--fix` 只做安全修复）。落地机菜单对应第 16–18 项。
- Vision 和 XHTTP 可以共用同一个 TCP 端口：`--xhttp-on-443`，或 `proxy proto xhttp-443 on|off`。协议开关里 Vision 和 XHTTP 都开着时，按 `s` 切换。已有安装默认仍分开。NAT 只有一个 TCP 映射时，`--auto` 直接共用。
- 只放行模式会把代理端口同步进正在运行的 ufw / firewalld，清单在 `fw-host.list`。已经装过又没写 `--firewall` 时，非交互重装沿用保存的模式。
- 更新 Xray / Hysteria2 / sing-box 前备份为 `.bak`。`proxy update --rollback` 换回；`--xray-ver`、`--hy2-ver`、`--singbox-ver` 安装指定的已发布版本。

### v1.5.0
- 防火墙增加三种模式。`strict` 入站默认拒绝；`allow` 只给代理端口、SSH 和端口跳跃写 accept，不接管入站策略，也不改 Docker / Podman 的表；`off` 不写 nftables（`--no-firewall` 相同）。干净机器默认严格。检测到 Docker/Podman、WireGuard、已有防火墙或多个非标准端口时，交互安装默认推荐只放行；`--auto` 且没写 `--firewall` 时直接用只放行。装好后：`proxy firewall strict`、`proxy firewall allow`、`proxy firewall off`。
- 回程线路检测只测从本机发向大陆的回程（电信 / 联通 / 移动，北京 / 上海 / 广州），默认用 nexttrace 的 TCP。主菜单第 18 项、落地机菜单第 12 项是「回程线路检测」。不再测国际线路，也不打分。

### v1.4.0
- 落地机出口三选一，同一时间只启用一种。菜单第 13 / 14 / 15 项：本机直连、加密转发、原样转发。第 1–12 项不变。中转机菜单第 12 项仍是「本机作中转，出口走落地机」。
- 本机直连（`proxy land-direct` / `land-clear`）：与以前的落地机相同，Shadowsocks 2022 入站后直连，`--land` 仍可与 `--outbound` 一起用。会清掉已保存的下一跳、原样转发目标和 DNAT。
- 加密转发（落地机上的 `proxy land-add 'ss://...'`，以及 `land-on` / `land-off` / `land-del`）：本机仍用自己的 SS2022 接上一跳，白名单来源再拨到下一跳的 SS2022，不装 hy2-relay。交给上一台的是本机自己的 `ss://`；下一跳链接单独打印。中转机上的 `land-add` 行为不变。从中转机改装成落地机时不会沿用原来的中转链接；已经是落地机时重新安装会保留下一跳。
- 原样转发（`proxy land-forward 'ss://...'` / `land-raw`）：不解密、不再加密。把本机落地端口的 TCP 和 UDP DNAT 到链接里的主机和端口，回程做 masquerade。上一跳链接用本机地址和对外端口，加上最终落地的加密方式与密钥；最终机器的地址单独标出。白名单为空，或没有与目标同族的地址时拒绝安装，不会留下开放的 DNAT。Xray 不监听该端口。`land-forward-off` / `land-forward-del`（以及 `land-raw-off` / `land-raw-del`）只动这一项。出站策略（`--outbound`）同样约束目标地址族。
- `proxy land-off` 在落地机上停用当前的加密转发或原样转发，并保留链接。切回本机直连或另一种出口时，会拆掉当前这一种。

</details>

