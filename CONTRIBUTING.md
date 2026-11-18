# 开发说明

用户安装用的仍是仓库根目录的 `proxy.sh`：

```bash
curl -fsSLo proxy.sh https://raw.githubusercontent.com/harennie/oneclick-proxy/main/proxy.sh && bash proxy.sh
```

所以根目录的 `proxy.sh` 要提交，并且必须和 `src/` 拼出来的文件一致。不要只改其中一边。

## 改代码

1. 只编辑 `src/` 里的模块。根目录的 `proxy.sh` 开头写了「由 build.sh 拼接生成」，直接改它会在下次构建时被覆盖。
2. 运行 `./build.sh`（或 `make`）重新拼接。
3. 提交前跑 `make check`：检查生成文件一致性、ShellCheck、Bash 语法，以及 `tests/` 中的落地路由、SNI 选择、本机 REALITY 目标防回环、重装出站选择、NAT 落地入站、诊断和证书续期、协议默认值和禁回国策略、规则定时更新及失败回滚回归测试。GitHub Actions 也会跑同样的检查，拼出来的内容和已提交的 `proxy.sh` 不同就会失败。

`build.sh` 按写死的顺序拼接，不用通配符排序，同一份 `src/` 每次得到同一个 `proxy.sh`。每个模块前写一行 `# @module`，并把「生成文件行号:源文件:源文件行号」填进 `src/core.sh` 的 `__MODULE_MAP`。脚本出错时用这张对照把 `proxy.sh` 的行号映回 `src/*.sh`（管道失败也算），对照读不到再扫这些标记，并打印调用栈。占位符还在、说明还没构建时，映射直接跳过。

可选实机验证 `tests/cn-policy-live.sh` 需要 root、现成的 CN 数据和官方内核。通过环境变量 `SINGBOX_TEST_BIN`、`HYSTERIA_TEST_BIN` 指定已有二进制，`REALITY_TEST_SNI`、`REALITY_TEST_TARGET` 指定可用的 HTTPS 目标（可为自有域名和回环后端）。它只启动回环临时服务，验证五种协议的国外访问、CN 域名 / IPv4 / IPv6 / DNS 解析结果拦截，以及策略入口的 UDP 拦截；退出时清理进程和测试文件，不安装服务或改正式配置。固定测试端口 61001–61006、61008 已被占用时直接退出。

## 模块

| 文件 | 内容 |
|---|---|
| `src/core.sh` | 启动参数、界面、状态文件 |
| `src/os.sh` | 发行版、init（systemd / OpenRC）、软件包 |
| `src/tune.sh` | 网络调优 |
| `src/xray.sh` | SNI 优选、端口检测、Xray |
| `src/hy2.sh` | Hysteria2 |
| `src/firewall.sh` | nftables（strict / allow / off）、端口跳跃、fail2ban |
| `src/cert.sh` | 证书与订阅 |
| `src/cdn.sh` | CDN 上的 XHTTP / WebSocket |
| `src/link.sh` | 链接、二维码、客户端配置 |
| `src/singbox.sh` | 协议开关，以及 TUIC / AnyTLS（sing-box） |
| `src/nat.sh` | NAT 映射端口和安装主流程 |
| `src/selftest.sh` | REALITY 自检 |
| `src/land.sh` | 落地机与落地转发 |
| `src/menu.sh` | 安装后的管理命令 |
| `src/route.sh` | 回程线路检测 |
| `src/export.sh` | `proxy export` / `proxy import`（可选密码，迁机器时带走密钥和证书） |
| `src/doctor.sh` | `proxy doctor` 健康检查，以及 `--fix` 里那几项安全修复 |
| `src/cli.sh` | 菜单、参数和 `main` |
