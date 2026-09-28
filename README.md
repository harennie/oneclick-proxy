# proxy 一键脚本 · VLESS-REALITY-Vision (ML-DSA-65) + Hysteria2

> 当前版本：**v1.2.1**（修复 Alpine / LXC NAT 机上「安装为落地机」走了普通端口流程并自动调优的问题；菜单新增第 15 项「切换 NAT 模式」；NAT 模式不再把出口 IP 当作公网地址默认值。见文末「更新日志」）
>
> v1.2.0：新增独立的「网络调优」功能 `proxy tune`：多种 BBR / 队列算法预设、按内存或带宽×延迟自动计算缓冲区、预览后再应用、可一键恢复，NAT / LXC / Alpine 也能用；新增「落地机」模式 `--land`（Shadowsocks 2022 出口 + 来源 IP 白名单）与中转机的「落地转发」`proxy land-add`。见下文「网络调优」「落地机 / 落地转发」与文末「更新日志」）

单文件 Bash 脚本，一键部署 **VLESS + REALITY + XTLS-Vision**（含后量子签名 ML-DSA-65）和 **Hysteria2**（端口跳跃 + 证书指纹固定），自动优选 REALITY 目标网站（SNI），自带 nftables 防火墙、fail2ban 与保守的网络调优。交互风格参考 [233boy/v2ray](https://github.com/233boy/v2ray)：数字菜单、彩色输出、安装后可用 `proxy` 命令管理。

---

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

### 命令行参数

| 参数 | 说明 |
|---|---|
| `--auto` | 全部默认值、非交互安装 |
| `--sni <域名>` | 指定 REALITY 目标网站（依然会做合规检测，不合格则拒绝） |
| `--force-sni` | 配合 `--sni`，检测不通过也强制使用 |
| `--scan` | 高级：用 [RealiTLScanner](https://github.com/XTLS/RealiTLScanner) 扫描 VPS 附近 IP 寻找同机房目标（约 60 秒） |
| `--port <N>` | VLESS-REALITY TCP 端口，默认 443（NAT 模式可写 `外部:内部`，如 `59221:443`） |
| `--no-hy2` | 不安装 Hysteria2 |
| `--hy2-port <N>` | Hysteria2 UDP 端口，默认 443（NAT 模式可写 `外部:内部`） |
| `--hop <a-b\|none>` | Hysteria2 端口跳跃范围，默认 `20000-50000`，`none` 关闭（NAT 模式默认关闭，可写多段 `a-b,c-d`） |
| `--name <名称>` | 节点名称（默认「国家-城市」） |
| `--no-firewall` | 不配置 nftables 防火墙 |
| `--no-upgrade` | 跳过系统软件包升级 |
| `--no-tune` | 跳过 sysctl 调优 |
| `--tune-preset <名>` | 安装时使用的调优预设（默认 `bbr-fq`，与旧版相同），见「网络调优」 |
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

管理子命令：`proxy info | sni | regen | port | user | update | status | speed | firewall | nat | tune | land | land-add | land-test | land-off | land-on | land-del | allow | uninstall`（加 `--auto` 可在脚本/自动化里免确认，例如 `proxy uninstall --auto`）。

---

## 功能

- **环境预检**：必须 root；识别发行版与架构（amd64 / arm64）；显示 IP、城市、ASN、内存；内存 < 1G 且无 Swap 时自动加 1G Swap；自动更新系统并安装依赖（RHEL 系自动启用 EPEL）；未检测到时间同步服务时自动安装并启用 systemd-timesyncd / chrony（REALITY 要求系统时间准确）。
- **系统调优（保守，不换内核）**：普通模式安装时默认启用 BBR + fq；TCP/UDP 缓冲区（满足 Hysteria2 建议的 16MB）、文件句柄上限；journald 日志上限 100M（与 v1.1.x 结果完全相同）。配置写入 `/etc/sysctl.d/99-proxy-tune.conf`，卸载时恢复原值。v1.2.0 起也可以用 `proxy tune` 单独调整 / 恢复，见下文「网络调优」。
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
- **Hysteria2（可选，默认启用，官方 get.hy2.sh 安装）**：自签 EC 证书（CN = 所选 SNI），客户端使用 `pinSHA256` 固定证书指纹；随机密码；监听 UDP 443；伪装为反向代理 `https://<SNI>`；nftables 实现 UDP 20000-50000 → 443 端口跳跃。
- **防火墙（nftables）**：独立表 `inet proxy_oneclick`，入站默认拒绝；放行 lo、已建立连接、ICMP/ICMPv6、DHCPv6 回包、**自动探测的 SSH 端口**（`sshd -T`、配置文件、监听进程、ssh.socket 及当前 SSH 会话端口）、Xray/Hysteria2 端口及跳跃范围；检测到其它对外服务时会询问是否一并放行。应用前先 `nft -c` 校验并备份原规则；由 systemd 单元 `proxy-oneclick-fw.service` 开机加载。检测到 firewalld / ufw 时询问是否停用（卸载时可恢复）。不会关闭 SELinux（写入文件后执行 `restorecon`）。
- **fail2ban**：sshd 监狱，10 分钟内失败 5 次封禁 1 小时（systemd 日志后端 + nftables 动作）。
- **输出**：vless:// 链接（含 / 不含 pqv 两个版本）、hysteria2:// 链接（`mport`、`sni`、`insecure=1`、`pinSHA256`），终端二维码，mihomo（Clash.Meta）YAML 片段。
- **管理菜单**：安装/重装、查看链接和二维码、更换 SNI、重新生成密钥、修改端口、添加/删除用户（UUID + 备注）、更新 Xray/Hysteria2/脚本、状态与日志、测速与延迟提示、防火墙管理、网络调优、落地转发、安装为落地机、卸载。
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

结果：容器内 Xray（TCP）与 Hysteria2（UDP）都监听 443，分享链接为 `vless://…@156.239.14.191:59221…`、`hysteria2://…@156.239.14.191:59221/…`。`--port 59221:443` 效果相同。

### 默认行为

- **Reality 与 Hysteria2 默认共用一个外部端口**（TCP 走 Reality、UDP 走 Hysteria2），因为很多服务商只给 5 条左右的映射。前提是该映射**同时转发 TCP 和 UDP**；若只转发 TCP，请加 `--nat-no-share` 并再提供一个 UDP 端口（例如 `--nat-ports 52430,52431`），或 `--no-hy2`。
- **端口跳跃默认关闭**。只有在「整段转发」且机器有 DNAT 能力（nftables 或 iptables 可用、容器有 NET_ADMIN）时才能开启，例如 `--nat-ports 10001-10020 --hop 10003-10020`；Reality 端口和 `--nat-exclude` 排除的端口会被自动剔除，范围会被拆成多段（如 `10003-10009,10011-10020`）。探测失败会自动回落为不跳跃并给出提示。规则由 `proxy-oneclick-hop` 服务开机加载。
- **`--nat-exclude`**：整段转发里已经给别的用途（例如 SSH 的 52429）的端口。当前被占用的端口也会自动排除。
- **地址**：v1.2.1 起，交互安装时**必须填写入口地址**（商家面板「端口映射 / NAT 转发」条目里显示的 IP 或域名）。外部查询服务检测到的只是**出口 IP**，只作为提示「检测到的出口 IP: x（NAT 机入口地址可能不同）」显示；直接回车时需要再明确确认「出口 IP 同时也是入口地址」才会使用。填写后会做一次提示性自检（入口 ≠ 出口且不在本机网卡上时给出说明，不阻止）。IPv6 地址在链接中自动加方括号，私有地址会提醒；`--nat-addr` 可直接指定；`--auto` 未指定 `--nat-addr` 时暂用出口 IP 并警告。
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

---

## 网络调优（`proxy tune`，v1.2.0）

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
| `bbr-fq`（默认） | BBR + fq。fq 为 BBR 提供高效的 pacing，服务器端首选；普通模式安装默认使用，结果与 v1.1.x 相同 |
| `bbr-fq_codel` | BBR + fq_codel。内核 4.20+ BBR 在非 fq 队列下由 TCP 自身做 pacing；适合本机还有其它业务 / 做路由的机器 |
| `bbr-cake` | BBR + cake（需内核有 `sch_cake`），CPU 开销略高 |
| `cubic-fq_codel`（保守） | 不启用 BBR，cubic + fq_codel，与多数发行版默认接近 |
| `keep` | 只调缓冲区 / 连接参数，拥塞控制与队列保持系统原来的设置（之前由本脚本改过的会改回原值） |
| `custom` | 从本机可用的算法里分别选择拥塞控制与队列算法（`--tune-cc` / `--tune-qdisc`） |

内核缺少预设需要的组件时，菜单中会标注「不可用：缺少 …」；非交互模式下会保持该项不变并给出提示（例如没有 BBR 时只应用缓冲区等参数，和旧版行为一致）。

**缓冲区档位**（`--tune-buffer`，独立调优默认 `auto` 按内存；安装时默认 `medium` 以保持旧版结果）：

| 档位 | TCP 缓冲区上限 | 说明 |
|---|---|---|
| `small` | 4MB（UDP/core 8MB） | ≤256MB 小鸡；UDP 仍保留 8MB，满足 quic-go（Hysteria2）约 7MB 的接收缓冲区需求 |
| `medium` | 16MB | 与 v1.1.x 相同 |
| `large` | 64MB | 约 2GB 及以上内存，高带宽长距离线路 |
| `bdp` | 2 × 带宽 × 延迟 | `--tune-bw <Mbps> --tune-rtt <ms>`，下限 4MB，上限按内存（≤256MB 8MB、≤1GB 32MB、≤4GB 64MB、更大 128MB） |

其余参数：`tcp_fastopen=3`、`tcp_mtu_probing=1`、`tcp_slow_start_after_idle=0`、`tcp_notsent_lowat=131072`、`tcp_fin_timeout=30`、`tcp_keepalive_time=600`、`somaxconn` / `tcp_max_syn_backlog` / `netdev_max_backlog` 按档位、文件句柄上限（与旧版相同）。`ip_local_port_range` 和 conntrack 不修改（`status` 中显示 conntrack 使用率，超过 80% 会提醒）。

**应用流程**：先显示预览表（参数 / 当前值 / 目标值 / 状态），确认后只写可写的参数，跳过的逐条说明原因，例如「跳过：容器内只读（宿主机控制）」「跳过：容器内不可见」「跳过：全局参数，容器内修改会影响宿主机」（特权容器里 `fs.file-max`、`default_qdisc` 等全局参数即使可写也不碰）。队列算法会立即应用到默认网卡（`tc`，多队列网卡重建 mq），并通过 `net.core.default_qdisc` 持久化。

**持久化与恢复**：
- 只维护一个文件 `/etc/sysctl.d/99-proxy-tune.conf`（沿用旧版文件名，升级用户不会出现两份配置），只包含成功应用的参数；OpenRC 下会确保 `sysctl` 服务在 boot 运行级。
- 容器内 `systemd-sysctl` 常因 `/proc/sys` 只读挂载而被跳过，且网卡队列只能用 `tc` 设置，因此容器中额外添加开机服务 `proxy-oneclick-tune`（systemd 单元或 OpenRC 脚本）重新应用。
- 首次应用前把所有相关参数的原值备份到 `/root/.proxy-oneclick/tune/backup.env`（之后换预设不会覆盖备份）；`proxy tune restore` 还原原值、网卡队列，删除配置文件与开机服务。卸载时自动执行同样的恢复。
- 从 v1.1.x 升级的机器没有原值备份：恢复时删除旧文件并重新加载系统 sysctl 配置，其余参数回退到内核默认值（默认队列 / 拥塞控制按内核编译配置）；`tcp_max_syn_backlog`、`fs.file-max` 等与内存相关的少数参数重启后完全恢复。

---

## 落地机 / 落地转发（v1.2.0）

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
- `hysteria2://` 链接同样可以直接导入，`mport` 参数即端口跳跃范围。
- 核心请使用较新的 Xray-core（≥ 25.7，支持 mldsa65）。

### mihomo / Clash Verge Rev / Clash Meta for Android

把输出的 `proxies:` 片段粘贴进配置文件，并在 `proxy-groups` 里引用节点名称。要点：

- VLESS：`reality-opts.public-key`、`reality-opts.short-id`，`client-fingerprint: chrome`，`flow: xtls-rprx-vision`；
- Hysteria2：`ports: 20000-50000` 端口跳跃，`fingerprint:` 为证书 SHA256 指纹（固定证书，无需跳过证书验证）；
- mihomo 目前不支持 REALITY 的 ML-DSA-65 验证（`pqv`），不影响连接（pqv 只是额外的可选校验）。

### Shadowrocket（iOS）

- 直接扫描二维码或复制 `vless://`（不含 pqv 版）导入，确认「XTLS: xtls-rprx-vision」「REALITY 公钥 / ShortId」已自动填好，指纹选 chrome。
- Hysteria2 链接可直接导入；若版本不支持 `mport` 端口跳跃，节点仍可通过主端口 443 使用；证书处开启「允许不安全」并确保指纹（pinSHA256）已填入。

### 官方 Hysteria2 客户端 / sing-box

`/root/proxy-info.txt` 中额外提供了官方多端口写法：`hysteria2://密码@IP:443,20000-50000/?sni=...&insecure=1&pinSHA256=...`。

---

## ⚠️ 云服务商防火墙

脚本只能管理系统内的 nftables。**AWS EC2 / Lightsail、Google Cloud、Oracle Cloud、Azure、阿里云、腾讯云** 等还有控制台层面的安全组 / 防火墙，请手动放行：

- TCP 443（或你设置的 VLESS 端口）
- UDP 443 以及 UDP 20000-50000（Hysteria2 + 端口跳跃）

Oracle Cloud 的官方镜像还自带 iptables 规则，如仍不通请一并检查。

NAT 小鸡不需要放行这些端口：只要在服务商面板里建好对应的端口映射（Reality + Hysteria2 共用端口时协议选「全部 / TCP+UDP」），脚本结束时会列出「公网端口 → 本机端口」对照表。

---

## 常用维护

**菜单**

```bash
proxy
```

```
   状态: 运行中   SNI: …   模式: 普通 / NAT（自动检测）/ NAT（手动）
 1) 安装 / 重新安装              8) 运行状态 / 日志
 2) 查看链接 / 二维码 / Clash 配置  9) 网络测速 / 延迟提示
 3) 更换 SNI                   10) 防火墙管理（NAT 模式为「NAT 信息 / 端口跳跃」）
 4) 重新生成密钥 / UUID          11) 网络调优
 5) 修改端口 / 端口跳跃           12) 添加 / 修改落地转发
 6) 用户管理                    13) 安装为落地机
 7) 更新 Xray / Hysteria2 / 脚本 14) 卸载
                               15) 切换 NAT 模式（当前: 自动/开/关）
```

**切换 NAT 模式**（第 15 项，落地机菜单为第 11 项，v1.2.1）：`自动`（默认：Alpine 强制 NAT、LXC/OpenVZ 容器安装时询问、已安装的沿用原模式）/ `开`（强制 NAT 映射端口流程，等同 `--nat`）/ `关`（强制普通模式，等同 `--no-nat`；Alpine 不可用）。在第 1 或 13 项安装前选择即可；设置保存在 `state.env`（`NAT_PREF`），之后的修改端口等操作都按它执行。已安装时切换到不同模式会提示立即重新安装（保留密钥 / UUID）；命令行 `--nat` / `--no-nat` 优先并同步该设置。

**链接 / 二维码 / mihomo 配置**

```bash
proxy info
```

**重新优选或手动更换 SNI**（Hysteria2 证书与指纹会同步更新）

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

**服务状态、时间同步、日志、防火墙规则、fail2ban**

```bash
proxy status
```

**BBR 状态、到 SNI 的延迟、下载测速**（Cloudflare / CacheFly / OVH 自动切换）

```bash
proxy speed
```

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

会移除：Xray、Hysteria2（含 hysteria 用户）、nftables 表与 systemd 单元、sysctl / limits / journald 配置（并恢复调优前的参数值）、fail2ban 规则、`proxy` 命令、节点信息；可选择是否删除密钥与备份目录；安装时被停用的 firewalld / ufw 会询问是否恢复。安装时创建的 `/swapfile` 会保留（附删除方法）。NAT 模式还会移除 OpenRC 服务脚本、日志目录、端口跳跃规则，并恢复 `--dns64` 修改前的 `/etc/resolv.conf`。落地机还会移除白名单规则表与开机服务。最后别忘了在云控制台关闭不再需要的端口。

---

## 已知限制

- 候选 SNI 列表是人工整理的，网站配置会变化；脚本每次都会实测，但某些地区可能全部不合格，此时请手动输入或使用 `--scan`。SG / PH 本地自建（非 CDN）的站点很少，通常会扩大到邻近地区。
- 在容器 / OpenVZ 等环境中 BBR、Swap 及部分 sysctl 可能无法生效（脚本会逐项检测并说明跳过原因）。容器无法加载内核模块：BBR / fq 等需要宿主机已加载；OpenVZ 7 容器通常完全不能修改拥塞控制。
- 不会安装第三方内核（如 XanMod 的 BBRv3）；已经在用这类内核时，脚本只识别并使用其提供的算法。
- Hysteria2 目前只有一个共享密码，「用户管理」仅针对 VLESS。
- NAT 模式下端口跳跃需要整段转发 + DNAT 能力；只有零散几条映射或容器里没有 nftables/iptables 时无法跳跃（此时只用主端口）。
- NAT 模式 Hysteria2 的逗号多段 `mport`（如 `10003-10009,10011-10020`）并非所有客户端都支持；不支持时可只使用主端口。
- 服务商映射如果只转发 TCP，Hysteria2 必须另配一个 UDP 映射端口（`--nat-no-share`）。
- 落地转发只改变本机 Xray / Hysteria2 代理流量的出口，本机系统自身的流量（apt、脚本下载等）仍然直连。
- 落地机只支持 Shadowsocks 2022；中转机 `land-add` 只接受 SS2022 链接。Xray 26.x 会对 Shadowsocks 打印弃用提示（官方推荐 VLESS Encryption），将来如被移除需要改用其它协议。
- NAT 容器落地机的白名单只由 Xray 路由实现（非白名单连接会被接受后丢弃，而不是在防火墙层拒绝）。

---

## 更新日志

### v1.2.1
- 修复：Alpine（以及 NAT 机）上用菜单第 13 项「安装为落地机」（或 `--land` 不带 `--nat`）时，依赖按精简模式安装，但端口却走了普通流程（「Shadowsocks 2022 监听端口」而不是「公网端口 / 内部端口」映射流程），并且像普通 VPS 一样自动执行了网络调优。原因：Alpine 的 NAT 判断在落地机模式下被跳过（`LAND_MODE=1` 时不设置 `NAT_MODE`），落地机又总是使用精简依赖。现在所有安装入口（菜单 1 / 13、`--land`、落地机 ↔ 节点改装）在环境检测阶段统一确定 NAT 模式，之后的调优、端口设置都以它为准；环境检测一行显示「模式: NAT（Alpine 强制 / 命令行指定 / 菜单手动设置 / 沿用已安装 / 自动检测）」。
- Alpine 不再询问「是否以 NAT 模式继续」，直接启用 NAT 模式并说明原因；`--no-nat` 仍会拒绝。非 Alpine 的 LXC / OpenVZ 容器首次安装且未指定 `--nat` / `--no-nat` 时询问「是否为 NAT 机（只有服务商映射的端口可用）？」：检测到的公网 IP 不在本机任何网卡上时默认「是」；`--auto` 直接按该判断。普通 VPS（KVM 等）不受影响，仍为普通流程。
- NAT 模式的网络调优恢复为 v1.2.0 设计：交互时先说明将做什么（按内存选缓冲区，BBR 可用且可写时启用 BBR + fq）再询问，`--auto` 只在给了 `--tune` / `--tune-preset` 时执行。
- 修复调优结果一行在容器内显示「队列 -」：容器里 `net.core.default_qdisc` 通常不可见，现在优先用 `tc` 读取默认网卡实际生效的队列（例如「队列 fq（网卡 eth0）」），没有 `tc` 时显示刚应用的值或「未知」；`proxy tune restore` 同样处理。
- 新增菜单第 15 项「切换 NAT 模式（当前: 自动/开/关）」（落地机菜单第 11 项），菜单标题显示「模式: 普通 / NAT（自动检测）/ NAT（手动）」；设置持久化到 `state.env`，已安装时切换会提示重新安装，修改端口前若与已安装模式不一致也会提示。原有 0–14 项编号不变。
- NAT 模式的「公网地址」不再把外部服务检测到的出口 IP 作为默认值：只显示为「检测到的出口 IP: x（NAT 机入口地址可能不同）」，需要填写商家面板端口映射中的入口地址，直接回车须明确确认出口 IP 即入口；填写后做提示性自检（不阻止）。适用于安装、落地机、`proxy port`、`proxy nat`。之前在 NAT 模式下填写过的地址可回车沿用；`--auto` 未给 `--nat-addr` 时暂用出口 IP 并警告。
- 落地机在普通模式下的依赖提示改为「依赖安装完成（精简模式）」，避免误以为已处于 NAT 模式。

### v1.2.0
- 新增独立的「网络调优」功能：菜单第 11 项、`proxy tune [status|preview|apply|restore]`，未安装代理也可单独使用。
- 新增「落地机」模式 `--land`：只运行 Xray Shadowsocks 2022（TCP+UDP，默认 `2022-blake3-aes-128-gcm`，可选 aes-256 / chacha20），支持 Alpine / OpenRC 与 NAT 映射端口，低内存自动设置 `GOMEMLIMIT`；可选来源 IP 白名单（Xray 路由 + nftables）；输出 `ss://` 链接、Xray 出站片段与中转机一键命令；独立的落地机菜单（白名单 / 端口 / 密钥 / 改装回节点 / 卸载）。
- 新增中转机「落地转发」：菜单第 12 项、`proxy land-add 'ss://...'`，先测试 TCP 连通与经落地的真实请求（显示出口 IP）再启用；Reality 与 Hysteria2（经本机 socks）都走落地机，内网 / BT 屏蔽规则仍优先；`land-test` / `land-off` / `land-on` / `land-del`；设置持久化，重新生成配置不会丢失。
- 菜单：12 = 添加 / 修改落地转发，13 = 安装为落地机，14 = 卸载（v1.1.x 为 11 = 卸载）。
- 修复：从 NAT / 落地机模式改回普通模式时，删除脚本自建的 xray 服务文件并让官方脚本重新安装（否则 443 端口因缺少 `CAP_NET_BIND_SERVICE` 无法监听）；容器内看不到进程名的临时端口 UDP 套接字不再被当作「其它服务」自动放行。
- 预设：`bbr-fq`（默认）、`bbr-fq_codel`、`bbr-cake`、`cubic-fq_codel`（保守）、`keep`（只调缓冲区）、`custom`（从本机可用算法中分别选择拥塞控制与队列算法）；不再对所有人强制 BBR + fq。
- 自动探测虚拟化 / init / 内核 / 可用拥塞控制（含 BBR 版本）/ 可用队列算法 / 内存，并对每个参数实际测试是否可写；缓冲区按内存分 small / medium / large 三档，或输入带宽与延迟按 BDP 计算。
- 应用前显示「当前值 → 目标值」预览并确认；只写可写的参数，跳过项逐条说明原因；特权容器中不修改会影响宿主机的全局参数。队列算法立即应用到默认网卡。
- 首次应用前备份原值，`proxy tune restore` 可完整恢复；卸载时自动恢复（此前只删除文件，要等重启才恢复）。容器内添加开机服务重新应用调优；OpenRC 确保 sysctl 服务开机运行。
- 安装流程改为调用同一套调优代码：普通模式默认仍为 BBR + fq + 16MB 缓冲区，写入的参数与 v1.1.x 完全相同（新增：立即把默认网卡切换到 fq，旧版要重启后才生效）；新增 `--tune-preset` / `--tune-buffer` / `--tune-cc` / `--tune-qdisc` / `--tune-bw` / `--tune-rtt` 参数。
- NAT 模式：交互安装时询问是否调优（只应用可写参数，BBR 可用且可写时用 `bbr-fq`，否则 `keep`，缓冲区按内存）；`--auto` 默认仍跳过，加 `--tune` 或 `--tune-preset` 启用。
- `proxy status` 在 NAT 模式下也显示拥塞控制 / 队列，并显示当前调优预设。

### v1.1.2
- NAT 端口输入容错：映射端口、内部端口、排除端口、VLESS-REALITY / Hysteria2 外部端口及端口跳跃范围的输入，会先去掉不可见字符（退格 `^H`、DEL、回车、ANSI 转义序列、零宽字符），并把全角冒号 `：`、全角逗号 `，` / 顿号 `、`、全角数字、全角连字符 / 破折号 / `~` 转换为半角，合并多余空格。普通（非 NAT）模式的端口输入同样处理；域名、UUID、密码等输入不受影响。
- 映射端口「格式无效」时显示实际收到的原始输入（控制字符以转义形式显示，含非 ASCII 字符时附逐字节形式），并提示检查中文标点或不可见字符。
- VLESS-REALITY / Hysteria2 外部端口提示中的「可选」只列外部端口（如 `61573`、`10001-10020`），不再显示 `61573:443` 这样的映射写法。
- 分享链接客户端指纹保持 `fp=chrome`（确认没有使用 `randomized`）。

### v1.1.1
- SNI 优选：X25519MLKEM768 由硬性要求改为**优先项**——支持的候选排前面；本地区没有支持的候选时仍选用其余检测全部通过的目标，并打印警告。`--sni`、手动输入、重新安装时的检查同样只警告不拒绝（重新安装的交互确认默认改为「重新优选」）。
- 修复：ML-DSA-65 要求目标证书链总长度 ≥ 3500 字节，否则服务端 REALITY 握手全部失败（此前被误认为是 MLKEM 不兼容）。现在按所选 SNI 自动判断，不满足时对该目标关闭 pqv（链接不再带 `pqv=`），候选列表新增 Chain 列并优先证书链够长的目标。已安装用户执行 `proxy sni` 或重新安装即可自动判断。
- CDN / WAF 识别：除 Cloudflare 外，按响应头拒绝 Imperva/Incapsula、Fastly、Akamai、CloudFront、Azure Front Door、Sucuri、BunnyCDN（兼容 busybox）。
- 香港候选替换为 `my.hkust.edu.hk factsfigures.cuhk.edu.hk dsbs.cuhk.edu.hk rmda.cuhk.edu.hk`（原列表全部不合格；后两个 HSTS 仅 300 秒，排在最后）；其它地区剔除了实测走 CDN 的候选，SG / PH 改为少量自建站点，不足时扩展到邻近地区。
- 安装 / 更换 SNI 后自动进行 REALITY 自检（本机临时客户端 → 127.0.0.1 节点 → 外网），只打印结果，不影响安装。
- 端口跳跃未启用时，菜单中不再显示「查看端口跳跃规则」。

### v1.1.0
- 新增 NAT 小鸡 / Alpine / OpenRC 模式（`--nat`）。
