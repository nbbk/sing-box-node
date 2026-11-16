# sing-box 运营节点一键包（一个核心管所有协议）

**核心：sing-box**（v1.14，`ghcr.io/sagernet/sing-box:latest`）。一个核心同时跑 6 个协议：VLESS、Trojan、VMess、Shadowsocks、Hysteria2、TUIC。DNS 只走加密通道、永不回落明文，主机开 BBR 加速，Clash 自动选最快的协议。

> 想要 Xray 内核的版本？看 [tiktok-node](https://github.com/nbbk/tiktok-node)（核心：Xray，VLESS + WS + TLS 单协议）。

在你自己的墙外服务器上跑一条命令，节点即上线。包里已把 DNS 防泄漏和速度优化做全，装完自带泄漏自检。

## 前置条件

- 一台墙外服务器（你机场现有的机器就行），Ubuntu/Debian，root 权限
- 一个域名，已解析（A 记录）到这台机器，80/443 端口放行——**有域名强烈建议用**，Caddy 会自动签 TLS 证书，6 个协议全开
  - 没有域名也能跑：直接回车跳过，用 IP 明文 WS（VLESS 8080 / Trojan 8081 / VMess 8082 + SS 8388），HY2/TUIC 不启用（需要域名证书），之后补域名重跑即可升级
- 服务器地区 = 你要做的 TikTok 地区（美区、东南亚、英国……），**节点 IP 的地区必须和运营地区一致**，否则直接限流
- IP 尽量干净：住宅/ISP 的 IP 最好；机房 IP 也能跑，但 TikTok 风控更严，`check.sh` 会告诉你当前 IP 是不是机房 IP

## 使用步骤

### 远程一键安装（推荐，不用传包）

服务器上直接跑一条命令，运行后会问域名，输入这台服务器的域名就行：

```
curl -fsSL https://raw.githubusercontent.com/nbbk/sing-box-node/main/install.sh | bash
```

也可以把域名直接跟在命令后面（比如 `... | bash -s yinni.930327.xyz`）。换服务器、换地区时不用改脚本：域名先解析到新服务器，再跑同一条命令、输入新域名即可；每次运行都会生成新的 UUID/密码和 WS 路径，每个服务器一套独立的节点。

### 本地安装（传包）

1. 把本包传到服务器并解压，进入目录
2. 运行：`bash install.sh`
3. 有域名就输入域名，没有直接回车
4. 脚本会自动：装 Docker → 禁用 IPv6 + 开 BBR/TCP 优化 → 生成全部凭据与随机 WS 路径 → 启动 sing-box + Caddy → 拨测 → 输出 6 个协议的节点链接、base64 订阅内容、`clash.yaml`，并在服务器上生成每个协议的二维码（`qr-vless.png`、`qr-trojan.png`、`qr-vmess.png`、`qr-ss.png`，TLS 模式另有 `qr-hy2.png`、`qr-tuic.png`；没有 qrencode 时自动用 apt/yum 安装），最后自动跑一遍 `check.sh` 自检

## 协议与端口

| 协议 | TLS 模式（有域名） | 明文模式（无域名） | 说明 |
|---|---|---|---|
| VLESS + WS | 443（经 Caddy） | 8080 | TikTok 主用 |
| Trojan + WS | 443（经 Caddy） | 8081 | 简单、兼容好 |
| VMess + WS | 443（经 Caddy） | 8082 | 老客户端兼容 |
| Shadowsocks 2022 | 8388（TCP+UDP） | 8388 | 轻量、速度快 |
| Hysteria2 | 8443/UDP | 不启用 | QUIC，弱网也快 |
| TUIC | 8444/UDP | 不启用 | QUIC + BBR |

每次运行都会覆盖之前的节点：重新生成新的 UUID/密码和 WS 路径，旧的节点链接就失效，手机上要重新导入新的。端口是固定的（443/8080/8081/8082/8388/8443/8444），随机的是 UUID、密码和 WS 路径。

## 手机端（关键：节点只解决网络这一半）

TikTok 从 IP、DNS、时区、SIM 卡几个地方一起判断地区，节点配好只算完成一半，手机端必须配套：

1. **拔卡**：拔掉国内 SIM 卡（或用无 SIM 的备用机）；双卡手机只留目标地区卡，没有就空着用 Wi-Fi
2. **时区语言**：手机时区、语言、地区全部改成节点所在地区，和 IP 地区一致
3. **关定位**：关掉 TikTok 的定位权限，系统定位服务也建议关掉
4. **导入节点**：
   - 小火箭（Shadowrocket）：扫对应的 `qr-*.png`，或导入脚本输出的链接；然后在配置的 DNS 设置里开启远程解析（通过代理解析），不要用本地 DNS
   - Clash/Stash：直接导入随包生成的 `clash.yaml`，它已经配好全部流量走节点、全部 DNS 走代理 DoH、禁用 IPv6；`PROXY` 组是 url-test，会自动选延迟最低的协议，`MANUAL` 组可以手动指定
5. **验证泄漏**（开着节点，在手机浏览器里做）：
   - 打开 https://www.dnsleaktest.com → Extended test：全部 DNS 服务器 IP 都应该是节点所在国家/机房的，出现中国运营商 DNS = 泄漏
   - 打开 https://browserleaks.com/ip：不能出现你的真实 IP、不能出现 IPv6 地址、时区和语言要和节点地区一致
   - 刷几个 TikTok 视频，看个人主页显示的地区是否和节点地区一致

## 这个包防泄漏是怎么做的（只用加密 DNS，永不回落明文）

- **服务端 sing-box**：自身解析只走加密 DNS——DoH（Cloudflare 1.1.1.1、Google 8.8.8.8、Quad9 9.9.9.9）+ DoT（tls://1.1.1.1、tls://8.8.8.8），失败也不回落明文 UDP/TCP 53（宁可解析失败也不泄露）；`strategy=ipv4_only` 只解析 A 记录；`default_domain_resolver` 指定全部出站解析都走 DoH
- **主机级**：写 sysctl 持久化禁用 IPv6，堵死 IPv6 泄漏口
- **客户端 Clash 配置**：`ipv6: false`；DNS 全部走代理 DoH（`proxy-server-nameserver` + `fallback` 也是 DoH，`fallback-filter` 挡住国内 IP）；TikTok 域名强制走代理解析；规则 `MATCH,PROXY`，全部流量走节点，不分流
- **自检**：`bash check.sh` 会查节点 IP 的地区、运营商、是不是机房 IP、IPv6 状态、TikTok 从节点出口是否可达

## 这个包速度是怎么做的

- **主机级**：开 BBR + fq 拥塞控制、加大 TCP 读写缓冲、开 TCP Fast Open（写 sysctl 持久化；内核不支持 BBR 时自动跳过）
- **协议级**：Hysteria2、TUIC 走 QUIC（UDP），弱网、高丢包下也快；TUIC 用 BBR 拥塞控制
- **客户端**：`clash.yaml` 的 `PROXY` 组是 url-test，每 300 秒测一次速，自动用延迟最低的协议，不用手动换

## 排障

- **节点没网、手机全打不开**：先在服务器上测 WS 握手（装完脚本会自动测）：
  `curl -s -i -N --max-time 10 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" https://你的域名/WS路径`
  返回 `101` = 正常；返回 `200 ok` = Caddy 没把请求转给 sing-box，跑 `docker compose down && docker compose up -d` 重建容器再测；返回 `400` = sing-box 拒绝握手，核对手机上的 UUID 和 WS 路径跟 sing-box.json 是否一致。
- **Caddy 拿不到证书**：核对域名 A 记录指到本机 IP、云厂商安全组放行 80/443；看日志 `docker logs singbox-caddy --tail 20`。
- **HY2/TUIC 没启用**：装完提示证书未就绪时会出现，重跑一次安装命令即可补上（会换一套新节点）。
- **sing-box 起不来**：看日志 `docker logs singbox-node --tail 30`；也可以用 `sing-box check -c sing-box.json` 校验配置。

## 说明

- 架构：有域名时 Caddy 在 443 终止 TLS，只把随机 WS 路径反代到 sing-box，其余请求返回普通网页响应（伪装）；HY2/TUIC 直接走 UDP，用 Caddy 签下的证书；SS 直连 8388
- 链接里的 UUID/密码等同于密码，不要外传；泄露了重跑脚本即可换一套
- 停止/卸载：在目录里运行 `docker compose down`；恢复 IPv6 与网络调优：删掉 `/etc/sysctl.d/99-singbox-node.conf` 后执行 `sysctl -p`
- 如果 `check.sh` 显示 hosting=true（机房 IP）且之后出现 0 播放/限流，优先换住宅/ISP 的干净 IP，换节点比调参数管用
