# proxy 一键脚本 · VLESS-REALITY-Vision (ML-DSA-65) + Hysteria2

> 当前版本：**v1.1.0**（新增 NAT 小鸡 / Alpine / OpenRC 模式，见下文「NAT 小鸡模式」）

单文件 Bash 脚本，一键部署 **VLESS + REALITY + XTLS-Vision**（含后量子签名 ML-DSA-65）和 **Hysteria2**（端口跳跃 + 证书指纹固定），自动优选 REALITY 目标网站（SNI），自带 nftables 防火墙、fail2ban 与保守的网络调优。交互风格参考 [233boy/v2ray](https://github.com/233boy/v2ray)：数字菜单、彩色输出、安装后可用 `proxy` 命令管理。

---

## 一键安装

```bash
# 推荐：先下载再运行（可以看到交互菜单）
curl -fsSLo proxy.sh https://raw.githubusercontent.com/harennie/oneclick-proxy/main/proxy.sh && bash proxy.sh

# 没有 curl 时用 wget
wget -O proxy.sh https://raw.githubusercontent.com/harennie/oneclick-proxy/main/proxy.sh && bash proxy.sh

# 全自动（全部使用默认值，无任何交互）
curl -fsSLo proxy.sh https://raw.githubusercontent.com/harennie/oneclick-proxy/main/proxy.sh && bash proxy.sh --auto
```

> 最小化安装的 Debian（例如 bin456789/reinstall 重装的系统）可能 curl 和 wget 都没有，请先执行 `apt-get update && apt-get install -y curl`（RHEL 系：`dnf install -y curl`）。脚本运行后会自动安装其余依赖，包括时间同步服务。
>
> **Alpine 没有自带 bash**，请先执行 `apk add bash curl`，并且必须带 `--nat`（见下文「NAT 小鸡模式」）：
> ```bash
> apk add bash curl
> curl -fsSLo proxy.sh https://raw.githubusercontent.com/harennie/oneclick-proxy/main/proxy.sh && bash proxy.sh --nat
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
| `--nat` / `--no-nat` | 启用 / 关闭 NAT 小鸡模式（记录在 state.env，之后 `proxy` 命令自动沿用） |
| `--nat-addr <地址>` | 链接里使用的公网 IP 或域名（默认自动检测：IPv4 → IPv6 → 手动输入） |
| `--nat-ports <列表>` / `--nat-port` | 服务商已映射的端口，逗号分隔，每项 `外部[:内部]`：`52430`、`59221:443`、整段 `10001-10020`、`10001-10020:20001-20020` |
| `--nat-exclude <端口>` | 整段转发时需要排除的外部端口（例如已映射给 SSH 的端口），逗号分隔 |
| `--nat-share` / `--nat-no-share` | Reality(TCP) 与 Hysteria2(UDP) 共用 / 不共用一个外部端口（默认共用） |
| `--dns64` | IPv6-only 且无法访问 GitHub 时，写入公共 DNS64 服务器（卸载时恢复） |
| `--tune` / `--upgrade` | NAT 模式下仍执行 sysctl 调优 / 系统升级（NAT 模式默认跳过） |

示例：`bash proxy.sh --auto --sni www.case.edu --port 443 --hop 30000-40000`

NAT 示例：`bash proxy.sh --nat --auto --nat-port 59221:443 --nat-addr 156.239.14.191`

管理子命令：`proxy info | sni | regen | port | user | update | status | speed | firewall | nat | uninstall`（加 `--auto` 可在脚本/自动化里免确认，例如 `proxy uninstall --auto`）。

---

## 功能

- **环境预检**：必须 root；识别发行版与架构（amd64 / arm64）；显示 IP、城市、ASN、内存；内存 < 1G 且无 Swap 时自动加 1G Swap；自动更新系统并安装依赖（RHEL 系自动启用 EPEL）；未检测到时间同步服务时自动安装并启用 systemd-timesyncd / chrony（REALITY 要求系统时间准确）。
- **系统调优（保守，不换内核）**：内核 ≥ 4.9 启用 BBR + fq；TCP/UDP 缓冲区（满足 Hysteria2 建议的 16MB）、文件句柄上限；journald 日志上限 100M。配置写入 `/etc/sysctl.d/99-proxy-tune.conf`，卸载时删除。
- **Xray（官方 XTLS/Xray-install 安装最新版）**：
  - VLESS + REALITY + `xtls-rprx-vision`，默认 TCP 443；
  - 自动生成 UUID、x25519 密钥、ShortId（`openssl rand -hex 4`）、**ML-DSA-65**（服务端 `mldsa65Seed`，客户端链接 `pqv=`）；
  - 客户端指纹 `fp=chrome`（实测 `randomized` 生成的随机 ClientHello 会被部分目标网站拒绝，导致 REALITY 握手失败）；
  - 每次写配置前先 `xray run -test` 校验，失败不会覆盖旧配置；
  - 以 `nobody` 运行，配置文件 `root:nogroup 640`，私钥/种子只保存在 `/root/.proxy-oneclick/state.env`（600），不会在屏幕上显示；
  - 屏蔽访问服务器内网（geoip:private）与 BT。
  - 官方脚本遇到 GitHub API 限流（403）时，会自动改为“指定最新版本号”重试。
- **REALITY 目标网站自动优选**（见下文「为什么 SNI 规则很重要」）。
- **Hysteria2（可选，默认启用，官方 get.hy2.sh 安装）**：自签 EC 证书（CN = 所选 SNI），客户端使用 `pinSHA256` 固定证书指纹；随机密码；监听 UDP 443；伪装为反向代理 `https://<SNI>`；nftables 实现 UDP 20000-50000 → 443 端口跳跃。
- **防火墙（nftables）**：独立表 `inet proxy_oneclick`，入站默认拒绝；放行 lo、已建立连接、ICMP/ICMPv6、DHCPv6 回包、**自动探测的 SSH 端口**（`sshd -T`、配置文件、监听进程、ssh.socket 及当前 SSH 会话端口）、Xray/Hysteria2 端口及跳跃范围；检测到其它对外服务时会询问是否一并放行。应用前先 `nft -c` 校验并备份原规则；由 systemd 单元 `proxy-oneclick-fw.service` 开机加载。检测到 firewalld / ufw 时询问是否停用（卸载时可恢复）。不会关闭 SELinux（写入文件后执行 `restorecon`）。
- **fail2ban**：sshd 监狱，10 分钟内失败 5 次封禁 1 小时（systemd 日志后端 + nftables 动作）。
- **输出**：vless:// 链接（含 / 不含 pqv 两个版本）、hysteria2:// 链接（`mport`、`sni`、`insecure=1`、`pinSHA256`），终端二维码，mihomo（Clash.Meta）YAML 片段。
- **管理菜单**：安装/重装、查看链接和二维码、更换 SNI、重新生成密钥、修改端口、添加/删除用户（UUID + 备注）、更新 Xray/Hysteria2/脚本、状态与日志、测速与延迟提示、防火墙管理、卸载。
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

```bash
curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh
bash reinstall.sh debian 12
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

```bash
apk add bash curl        # Alpine 才需要
bash proxy.sh --nat --auto --nat-port 59221:443 --nat-addr 156.239.14.191
```

结果：容器内 Xray（TCP）与 Hysteria2（UDP）都监听 443，分享链接为 `vless://…@156.239.14.191:59221…`、`hysteria2://…@156.239.14.191:59221/…`。`--port 59221:443` 效果相同。

### 默认行为

- **Reality 与 Hysteria2 默认共用一个外部端口**（TCP 走 Reality、UDP 走 Hysteria2），因为很多服务商只给 5 条左右的映射。前提是该映射**同时转发 TCP 和 UDP**；若只转发 TCP，请加 `--nat-no-share` 并再提供一个 UDP 端口（例如 `--nat-ports 52430,52431`），或 `--no-hy2`。
- **端口跳跃默认关闭**。只有在「整段转发」且机器有 DNAT 能力（nftables 或 iptables 可用、容器有 NET_ADMIN）时才能开启，例如 `--nat-ports 10001-10020 --hop 10003-10020`；Reality 端口和 `--nat-exclude` 排除的端口会被自动剔除，范围会被拆成多段（如 `10003-10009,10011-10020`）。探测失败会自动回落为不跳跃并给出提示。规则由 `proxy-oneclick-hop` 服务开机加载。
- **`--nat-exclude`**：整段转发里已经给别的用途（例如 SSH 的 52429）的端口。当前被占用的端口也会自动排除。
- **地址**：默认自动检测公网 IPv4，没有 IPv4 出口时使用 IPv6（链接中自动加方括号），检测到的是私有地址时会提醒；也可以用 `--nat-addr` 指定 IP 或域名。

### NAT 模式跳过的组件（以及原因）

| 跳过 | 原因 |
|---|---|
| nftables 防火墙、fail2ban | 入口由服务商的端口映射控制，容器里通常也没有权限改防火墙；fail2ban 占内存 |
| Swap | 容器里无法创建 / 启用 Swap |
| sysctl 调优（BBR 等） | 容器共享宿主机内核，通常无权修改；需要时加 `--tune` |
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

## 为什么 SNI（REALITY 目标网站）规则很重要

REALITY 会把未通过认证的连接原样转发给「目标网站」，同时借用它的 TLS 特征。选错目标会让节点更容易被识别或者干脆不可用。脚本按以下规则在 **VPS 上实时检测** 每个候选：

1. **与 VPS 同国家/地区（最好同城、同 ASN）**：一台洛杉矶 VPS 却“访问”东京网站，流量路径和延迟都不自然。候选列表按地区组织（例如洛杉矶 → www.usc.edu、www.ucla.edu…；俄亥俄 → www.case.edu、www.ohio.edu…；另有 JP / KR / HK / TW / SG / DE / NL / GB / FR / CA / AU 等数十个地区），不足时自动扩展到邻近地区；结果同国家优先，再按 TLS 握手延迟排序。
2. **TLS 1.3 + X25519 + ALPN h2**：REALITY 要求目标支持 TLS 1.3；h2 是现代浏览器的常态，缺失会显得异常。
   另外要求目标支持**后量子密钥交换 X25519MLKEM768**（用已安装的 `xray tls ping` 检测）：新版 Xray 客户端的指纹默认带它，目标不支持时 REALITY 握手会失败（服务端日志 `handshake did not complete successfully`）。重新运行脚本时若发现已保存的 SNI 不满足此条，会自动重新优选。
3. **HSTS**：说明是认真维护 HTTPS 的正规网站。
4. **证书链有效**（`openssl s_client -verify_return_error -verify_hostname`）。
5. **不在 Cloudflare 后面**：解析 IP 对照 <https://www.cloudflare.com/ips-v4>、ips-v6，并检查 `server: cloudflare` / `cf-ray` 响应头。Cloudflare 站点被大量滥用做 REALITY 目标，且 CF 的 IP 与你的 VPS 明显不属于同一网络。
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

```bash
proxy               # 菜单
proxy info          # 链接 / 二维码 / mihomo 配置
proxy sni           # 重新优选或手动更换 SNI（Hysteria2 证书与指纹会同步更新）
proxy user          # 添加 / 删除额外用户（UUID + 备注）
proxy update        # 更新 Xray / Hysteria2 / 脚本
proxy update-script # 只更新本脚本（proxy 命令）
proxy status        # 服务状态、时间同步、日志、防火墙规则、fail2ban
proxy speed         # BBR 状态、到 SNI 的延迟、下载测速（Cloudflare / CacheFly / OVH 自动切换）
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
| `/var/log/xray/`、`/var/log/hysteria/` | OpenRC 下的服务日志（systemd 下用 `journalctl -u xray` / `-u hysteria-server`） |

---

## 卸载

```bash
proxy uninstall          # 交互确认
proxy uninstall --auto   # 免确认
```

会移除：Xray、Hysteria2（含 hysteria 用户）、nftables 表与 systemd 单元、sysctl / limits / journald 配置、fail2ban 规则、`proxy` 命令、节点信息；可选择是否删除密钥与备份目录；安装时被停用的 firewalld / ufw 会询问是否恢复。安装时创建的 `/swapfile` 会保留（附删除方法）。NAT 模式还会移除 OpenRC 服务脚本、日志目录、端口跳跃规则，并恢复 `--dns64` 修改前的 `/etc/resolv.conf`。最后别忘了在云控制台关闭不再需要的端口。

---

## 已知限制

- 候选 SNI 列表是人工整理的，网站配置会变化；脚本每次都会实测，但某些地区可能全部不合格，此时请手动输入或使用 `--scan`。
- 在容器 / OpenVZ 等环境中 BBR、Swap 及部分 sysctl 可能无法生效（脚本会提示并继续）。
- Hysteria2 目前只有一个共享密码，「用户管理」仅针对 VLESS。
- NAT 模式下端口跳跃需要整段转发 + DNAT 能力；只有零散几条映射或容器里没有 nftables/iptables 时无法跳跃（此时只用主端口）。
- NAT 模式 Hysteria2 的逗号多段 `mport`（如 `10003-10009,10011-10020`）并非所有客户端都支持；不支持时可只使用主端口。
- 服务商映射如果只转发 TCP，Hysteria2 必须另配一个 UDP 映射端口（`--nat-no-share`）。
