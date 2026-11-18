#!/usr/bin/env bash
# sing-box 运营节点一键部署：一个核心管所有协议（VLESS / Trojan / VMess / Shadowsocks / Hysteria2 / TUIC），DNS 防泄漏 + 禁 IPv6
# 用法：
#   本地：bash install.sh [域名]
#   远程一键：curl -fsSL https://raw.githubusercontent.com/nbbk/sing-box-node/main/install.sh | bash -s [域名]
#   （不给域名则交互询问；直接回车用 IP 明文跑，HY2/TUIC 不启用）
# 架构：有域名 -> Caddy 在 HTTPS 端口（默认 443，可自定义高位端口）终止 TLS，反代本机 sing-box 的 WS 入站（VLESS/Trojan/VMess）；
#        Hysteria2/TUIC 直接走 UDP，用 Caddy 签下的证书；Shadowsocks 直连（默认 8388，可自定义）
#        无域名 -> VLESS/Trojan/VMess 明文 WS（默认 8080/8081/8082，可自定义），SS 直连（默认 8388，可自定义），HY2/TUIC 不启用（需要域名证书）
# 公开端口：默认即当前端口，直接回车就行；默认端口被占时安装会问你要不要换高位端口（如 HTTPS 8443、SS 18388）；
#        80 端口必须空闲（Caddy 签证书走 HTTP-01 验证必须用 80），改不了，80 被占 TLS 装不了
# DNS 防泄漏设计（只用加密 DNS，永不回落明文）：
#   1) sing-box 自身解析只走加密 DNS：DoH(Cloudflare/Google/Quad9) + DoT，失败也不回落明文 UDP/TCP 53（宁可解析失败也不泄露）
#   2) dns.strategy=ipv4_only，只解析 A 记录，不产生 AAAA/IPv6 解析路径
#   3) 主机级禁用 IPv6（sysctl 持久化），堵死 IPv6 泄漏口
#   4) 客户端用随包生成的 clash.yaml：全部 DNS 走代理 DoH（含 fallback）、ipv6: false
# 速度设计：
#   1) 主机开 BBR + fq、加大 TCP 缓冲、开 TCP Fast Open
#   2) HY2/TUIC 走 QUIC（UDP），弱网也快；Clash 默认用 url-test 自动选延迟最低的协议
#      （节点只能管住服务端这一半，手机端设置见 README，装完务必跑 check.sh）
set -euo pipefail

# 工作目录：本地跑 bash install.sh 时用脚本所在目录；
# 远程一键（curl | bash 或 bash <(...)）时用 ~/sing-box-node-kit
if [ -f "$0" ]; then
  cd "$(dirname "$0")"
else
  mkdir -p "$HOME/sing-box-node-kit"
  cd "$HOME/sing-box-node-kit"
fi

DRY_RUN="${DRY_RUN:-0}"
TLS_MODE=1
CLI_DOMAIN="${1:-}"
DOMAIN="${DOMAIN:-}"
SERVER_IP="${SERVER_IP:-}"
HY2_ENABLED=1

# 端口是否被占用（TCP 或 UDP 任一被占即算被占；ss -> netstat -> /proc 回退）
port_in_use_any() {
  local port="$1" hex
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 0
    ss -uln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 0
    return 1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 0
    netstat -uln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 0
    return 1
  else
    # 无 ss/netstat 时回退读 /proc/net/*（端口为 16 进制，匹配监听地址字段）
    hex=$(printf '%04X' "$port")
    grep -qiE "^[[:space:]]*[0-9]+:[[:space:]]+[0-9A-Fa-f]+:${hex}[[:space:]]" /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null
  fi
}

# 打印占用某端口的进程（ss 能看到时列出，否则说明查不到）
show_port_owner() {
  local port="$1" line=""
  if command -v ss >/dev/null 2>&1; then
    line="$(ss -tlnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | head -1)"
    [ -z "$line" ] && line="$(ss -ulnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | head -1)"
    if [ -n "$line" ]; then echo "  端口 $port 被占用：$line"; else echo "  端口 $port 被占用（查不到占用进程，可能是权限不足）"; fi
  elif command -v netstat >/dev/null 2>&1; then
    line="$(netstat -tlnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | head -1)"
    [ -z "$line" ] && line="$(netstat -ulnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | head -1)"
    if [ -n "$line" ]; then echo "  端口 $port 被占用：$line"; else echo "  端口 $port 被占用（查不到占用进程）"; fi
  else
    echo "  端口 $port 被占用（本机无 ss/netstat，查不到占用进程）"
  fi
}

# 端口预检：按最终选定的端口查占用（不是只查默认端口）；80 在 TLS 模式下必须空闲
# （Caddy 签证书走 HTTP-01 验证，必须用 80；80 被占 TLS 装不了）
check_ports() {
  local occupied="" p
  if [ "$TLS_MODE" = "1" ] && port_in_use_any 80; then
    echo ""
    echo "80 端口已被占用，TLS 模式装不了："
    show_port_owner 80
    echo "Caddy 签证书走 HTTP-01 验证，必须用 80 端口；80 被占就签不下证书。"
    echo "办法：停掉占用 80 的程序再跑，或换一台服务器；"
    echo "也可以不带域名跑明文模式（临时测试，HY2/TUIC 不启用）。"
    exit 1
  fi
  local -a want=()
  if [ "$TLS_MODE" = "1" ]; then
    want=( "$HTTPS_PORT" "$SS_PORT" "$HY2_PORT" "$TUIC_PORT" )
  else
    want=( "$VLESS_PORT" "$TROJAN_PORT" "$VMESS_PORT" "$SS_PORT" )
  fi
  for p in "${want[@]}"; do
    if port_in_use_any "$p"; then occupied="$occupied $p"; fi
  done
  if [ -n "$occupied" ]; then
    echo ""
    echo "端口已被占用：$occupied"
    for p in $occupied; do show_port_owner "$p"; done
    if [ "$TLS_MODE" = "1" ]; then
      echo "TLS 模式需要这些端口空闲才能装。如果是 HTTPS 端口被占（比如这台机上已有 TikTok 节点 Xray 包占了 443），"
      echo "重跑安装、把 HTTPS 端口改成高位端口（如 8443）就能装；也可以先停掉占用的程序再跑："
      echo "  cd ~/tiktok-node-kit && docker compose down -v"
    else
      echo "明文模式需要这些端口空闲才能装。重跑安装、把被占的端口改成高位端口就能装；"
      echo "也可以先停掉占用它的程序再跑，或换一台服务器。"
    fi
    exit 1
  fi
}

# 合法端口：1-65535 的整数（支持高位端口，如 18443、24443、30000）
valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]
}

# 端口是否在“已选端口”列表里（空格分隔）
port_used() {
  case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# 从终端读一行（远程一键时 stdin 是管道，用 /dev/tty；无终端时返回空串，不挂起）
read_line() {
  local _var="$1" _prompt="$2" _a=""
  if [ -t 0 ]; then
    read -rp "$_prompt" _a || true
  elif [ -r /dev/tty ]; then
    read -rp "$_prompt" _a </dev/tty 2>/dev/null || true
  fi
  printf -v "$_var" '%s' "$_a"
}

# 交互问端口：先印一句带冒号的独立提示行，再问；标默认值，直接回车即用默认
# 非法输入、与已选端口重复、HTTPS 选 80 都会重问；无终端且默认值被占时直接报错退出
# 用法：ask_port 变量名 "提示行" 默认值 "已选端口（空格分隔）"
# 端口也可用环境变量预设（HTTPS_PORT / SS_PORT / HY2_PORT / TUIC_PORT / VLESS_PORT / TROJAN_PORT / VMESS_PORT），有就不再问
ask_port() {
  local varname="$1" prompt_line="$2" default="$3" used="${4:-}"
  local preset="${!varname:-}"
  if [ -n "$preset" ]; then
    if ! valid_port "$preset"; then echo "环境变量 $varname=$preset 不是合法端口（1-65535），请修正后重跑。"; exit 1; fi
    preset="$((10#$preset))"
    if [ "$varname" = "HTTPS_PORT" ] && [ "$preset" = "80" ]; then echo "环境变量 HTTPS_PORT 不能是 80（80 要留给 Caddy 签证书用），请修正后重跑。"; exit 1; fi
    if port_used "$preset" "$used"; then echo "环境变量 $varname=$preset 与前面选的端口重复了，请修正后重跑。"; exit 1; fi
    printf -v "$varname" '%s' "$preset"
    return 0
  fi
  local _tty=0 ans=""
  if [ -t 0 ] || [ -r /dev/tty ]; then _tty=1; fi
  if [ "$_tty" = "0" ] && port_used "$default" "$used"; then
    echo "默认值 $default 与已选端口重复，且当前没有可交互的终端，请用环境变量指定 $varname 后重跑。"; exit 1
  fi
  echo "$prompt_line"
  while :; do
    if port_used "$default" "$used"; then
      read_line ans "默认值 $default 已被占用，请另外输入一个端口（1-65535）： "
      if [ -z "$ans" ]; then echo "默认值 $default 已被占用，直接回车选不了，必须另外输入一个端口。"; continue; fi
    else
      read_line ans "端口（默认 $default，直接回车就是 $default）： "
      if [ -z "$ans" ]; then ans="$default"; fi
    fi
    if ! valid_port "$ans"; then echo "端口不合法：$ans（必须是 1-65535 的数字），请重新输入。"; ans=""; continue; fi
    ans="$((10#$ans))"
    if [ "$varname" = "HTTPS_PORT" ] && [ "$ans" = "80" ]; then echo "HTTPS 端口不能是 80（80 要留给 Caddy 签证书用），请换一个端口。"; ans=""; continue; fi
    if port_used "$ans" "$used"; then echo "端口 $ans 已经被前面选的端口占用了，请换一个。"; ans=""; continue; fi
    break
  done
  printf -v "$varname" '%s' "$ans"
}

if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] 只生成配置文件，不安装、不改系统"
  [ -n "$SERVER_IP" ] || SERVER_IP="203.0.113.1"
fi

echo "== 1/8 检查 Docker =="
if [ "$DRY_RUN" != "1" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "未检测到 Docker，正在安装..."
    curl -fsSL https://get.docker.com | sh
  fi
  docker compose version >/dev/null 2>&1 || { echo "缺少 Docker Compose 插件，请先安装 docker-compose-plugin"; exit 1; }
fi

echo "== 2/8 域名（可空） =="
# 优先级：命令行参数 > .env > 环境变量 > 交互输入 > 留空走明文
# 端口只接受命令行/环境变量预设；.env 里上次的端口只作安装记录（给 check.sh / stop.sh 读），
# 重跑要换端口时仍会问，不会被旧值悄悄定死
declare -A _env_ports=()
for _pv in HTTPS_PORT SS_PORT HY2_PORT TUIC_PORT VLESS_PORT TROJAN_PORT VMESS_PORT; do
  [ -n "${!_pv:-}" ] && _env_ports[$_pv]="${!_pv}"
done
if [ -f .env ]; then set -a; . ./.env; set +a; fi
for _pv in HTTPS_PORT SS_PORT HY2_PORT TUIC_PORT VLESS_PORT TROJAN_PORT VMESS_PORT; do
  if [ -n "${_env_ports[$_pv]:-}" ]; then
    printf -v "$_pv" '%s' "${_env_ports[$_pv]}"
  else
    unset "$_pv"
  fi
done
unset _env_ports _pv
DOMAIN="${CLI_DOMAIN:-${DOMAIN:-}}"
if [ -z "$DOMAIN" ] && [ "$DRY_RUN" != "1" ]; then
  # 远程一键时 stdin 是管道，用 /dev/tty 直接问终端
  echo "请填写已解析到本机的域名："
  if [ -t 0 ]; then
    read -rp "域名（没有直接回车，用 IP 明文跑，HY2/TUIC 不启用）： " DOMAIN || true
  elif [ -r /dev/tty ]; then
    read -rp "域名（没有直接回车，用 IP 明文跑，HY2/TUIC 不启用）： " DOMAIN </dev/tty 2>/dev/null || true
  fi
fi
if [ -z "$DOMAIN" ]; then
  TLS_MODE=0
  HY2_ENABLED=0
  echo "无域名：明文 WS 模式（VLESS 8080 / Trojan 8081 / VMess 8082 + SS 8388），HY2/TUIC 不启用，建议之后补域名重跑以启用 TLS 和全部协议"
else
  echo "域名：$DOMAIN（TLS 模式，全部 6 个协议）"
fi

# 公开端口：默认即当前端口，直接回车就行；默认端口被占时可改高位端口避开
echo ""
echo "== 3/8 公开端口（可自定义） =="
if [ "$TLS_MODE" = "1" ]; then
  echo "TLS 模式：HTTPS 端口默认 443，SS 默认 8388，HY2 默认 8443，TUIC 默认 8444。"
  echo "80 端口必须空闲（Caddy 签证书走 HTTP-01 验证必须用 80），改不了。"
  _used=""
  ask_port HTTPS_PORT "请填写 HTTPS 端口（WS 走的那个端口，例如被占时可改高位端口 8443）：" 443 "$_used"; _used="$_used $HTTPS_PORT"
  ask_port SS_PORT "请填写 Shadowsocks 端口（例如被占时可改高位端口 18388）：" 8388 "$_used"; _used="$_used $SS_PORT"
  ask_port HY2_PORT "请填写 Hysteria2 端口（例如被占时可改高位端口 18443）：" 8443 "$_used"; _used="$_used $HY2_PORT"
  ask_port TUIC_PORT "请填写 TUIC 端口（例如被占时可改高位端口 18444）：" 8444 "$_used"; _used="$_used $TUIC_PORT"
  VLESS_PORT="$HTTPS_PORT"; TROJAN_PORT="$HTTPS_PORT"; VMESS_PORT="$HTTPS_PORT"
  echo "公开端口：HTTPS $HTTPS_PORT，SS $SS_PORT，HY2 $HY2_PORT，TUIC $TUIC_PORT"
else
  echo "明文模式：VLESS 默认 8080，Trojan 默认 8081，VMess 默认 8082，SS 默认 8388。"
  _used=""
  ask_port VLESS_PORT "请填写 VLESS 端口（例如被占时可改高位端口 18080）：" 8080 "$_used"; _used="$_used $VLESS_PORT"
  ask_port TROJAN_PORT "请填写 Trojan 端口（例如被占时可改高位端口 18081）：" 8081 "$_used"; _used="$_used $TROJAN_PORT"
  ask_port VMESS_PORT "请填写 VMess 端口（例如被占时可改高位端口 18082）：" 8082 "$_used"; _used="$_used $VMESS_PORT"
  ask_port SS_PORT "请填写 Shadowsocks 端口（例如被占时可改高位端口 18388）：" 8388 "$_used"; _used="$_used $SS_PORT"
  HTTPS_PORT=443; HY2_PORT=8443; TUIC_PORT=8444
  echo "公开端口：VLESS $VLESS_PORT，Trojan $TROJAN_PORT，VMess $VMESS_PORT，SS $SS_PORT"
fi

# 按最终选定的端口预检占用（被占即退出，不跑后面的步骤）
check_ports

if [ "$TLS_MODE" = "0" ] && [ -z "$SERVER_IP" ]; then
  SERVER_IP="$(curl -s --max-time 5 https://api.ipify.org || true)"
  [ -n "$SERVER_IP" ] || SERVER_IP="$(curl -s --max-time 5 https://ifconfig.me || true)"
  [ -n "$SERVER_IP" ] || { echo "拿不到本机公网 IP，请手动在 .env 写 SERVER_IP=你的IP 后重跑"; exit 1; }
fi

echo "== 4/8 生成凭据与 WS 路径 =="
UUID_VLESS="$(cat /proc/sys/kernel/random/uuid)"
UUID_VMESS="$(cat /proc/sys/kernel/random/uuid)"
UUID_TUIC="$(cat /proc/sys/kernel/random/uuid)"
PASS_TROJAN="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
PASS_SS="$(head -c 16 /dev/urandom | base64 -w0)" # 2022-blake3 密码必须是 base64 编码的 16 字节密钥
PASS_HY2="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
PASS_TUIC="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
PATH_VLESS="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
PATH_TROJAN="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
PATH_VMESS="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
echo "VLESS UUID: $UUID_VLESS"
echo "VMess UUID: $UUID_VMESS"
echo "WS 路径: /$PATH_VLESS /$PATH_TROJAN /$PATH_VMESS"

echo "== 5/8 禁用 IPv6 + 网络加速（BBR / 缓冲 / TFO） =="
if [ "$DRY_RUN" != "1" ]; then
  cat > /etc/sysctl.d/99-singbox-node.conf <<'SYSCTL'
# sing-box 节点：禁用 IPv6（堵死 IPv6 泄漏口）+ BBR 加速 + TCP 缓冲 + TFO
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_fastopen = 3
net.core.netdev_max_backlog = 250000
SYSCTL
  # BBR 需要内核支持；不支持就去掉 BBR 两行再应用
  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    modprobe tcp_bbr 2>/dev/null || true
  fi
  if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    sysctl -p /etc/sysctl.d/99-singbox-node.conf >/dev/null 2>&1 || true
    echo "IPv6 已禁用：$(sysctl -n net.ipv6.conf.all.disable_ipv6)，BBR：$(sysctl -n net.ipv4.tcp_congestion_control)"
  else
    sed -i '/tcp_congestion_control/d; /default_qdisc/d' /etc/sysctl.d/99-singbox-node.conf
    sysctl -p /etc/sysctl.d/99-singbox-node.conf >/dev/null 2>&1 || true
    echo "IPv6 已禁用：$(sysctl -n net.ipv6.conf.all.disable_ipv6)，当前内核不支持 BBR，已跳过 BBR（不影响使用）"
  fi
else
  echo "[dry-run] 跳过写 /etc/sysctl.d"
fi

echo "== 6/8 写入配置 =="
CERT_CRT="/caddy-data/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN/$DOMAIN.crt"
CERT_KEY="/caddy-data/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN/$DOMAIN.key"

if [ "$TLS_MODE" = "1" ]; then
  cat > sing-box.json <<EOF
{
  "log": { "level": "warn" },
  "dns": {
    "servers": [
      { "type": "https", "tag": "doh-cf", "server": "1.1.1.1" },
      { "type": "https", "tag": "doh-google", "server": "8.8.8.8" },
      { "type": "https", "tag": "doh-quad9", "server": "9.9.9.9" },
      { "type": "tls", "tag": "dot-cf", "server": "1.1.1.1" },
      { "type": "tls", "tag": "dot-google", "server": "8.8.8.8" }
    ],
    "final": "doh-cf",
    "strategy": "ipv4_only",
    "disable_cache": false
  },
  "inbounds": [
    { "type": "vless", "tag": "vless-ws", "listen": "0.0.0.0", "listen_port": 10000,
      "users": [ { "uuid": "$UUID_VLESS" } ],
      "transport": { "type": "ws", "path": "/$PATH_VLESS" } },
    { "type": "trojan", "tag": "trojan-ws", "listen": "0.0.0.0", "listen_port": 10001,
      "users": [ { "password": "$PASS_TROJAN" } ],
      "transport": { "type": "ws", "path": "/$PATH_TROJAN" } },
    { "type": "vmess", "tag": "vmess-ws", "listen": "0.0.0.0", "listen_port": 10002,
      "users": [ { "uuid": "$UUID_VMESS", "alterId": 0 } ],
      "transport": { "type": "ws", "path": "/$PATH_VMESS" } },
    { "type": "shadowsocks", "tag": "ss", "listen": "0.0.0.0", "listen_port": $SS_PORT,
      "method": "2022-blake3-aes-128-gcm", "password": "$PASS_SS" },
    { "type": "hysteria2", "tag": "hy2", "listen": "0.0.0.0", "listen_port": $HY2_PORT,
      "users": [ { "password": "$PASS_HY2" } ],
      "tls": { "enabled": true, "server_name": "$DOMAIN", "alpn": ["h3"],
               "certificate_path": "$CERT_CRT", "key_path": "$CERT_KEY" } },
    { "type": "tuic", "tag": "tuic", "listen": "0.0.0.0", "listen_port": $TUIC_PORT,
      "users": [ { "uuid": "$UUID_TUIC", "password": "$PASS_TUIC" } ],
      "congestion_control": "bbr",
      "tls": { "enabled": true, "server_name": "$DOMAIN", "alpn": ["h3"],
               "certificate_path": "$CERT_CRT", "key_path": "$CERT_KEY" } }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": {
    "final": "direct",
    "default_domain_resolver": { "server": "doh-cf", "strategy": "ipv4_only" }
  }
}
EOF

  cat > Caddyfile <<EOF
$DOMAIN:$HTTPS_PORT {
    handle /$PATH_VLESS {
        reverse_proxy sing-box:10000
    }
    handle /$PATH_TROJAN {
        reverse_proxy sing-box:10001
    }
    handle /$PATH_VMESS {
        reverse_proxy sing-box:10002
    }
    handle {
        respond "ok" 200
    }
}
EOF
  cat > docker-compose.yml <<EOF
services:
  sing-box:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: singbox-node
    restart: unless-stopped
    command: run -c /etc/sing-box/config.json
    volumes:
      - ./sing-box.json:/etc/sing-box/config.json:ro
      - caddy_data:/caddy-data:ro
    ports:
      - "$SS_PORT:$SS_PORT"
      - "$SS_PORT:$SS_PORT/udp"
      - "$HY2_PORT:$HY2_PORT/udp"
      - "$TUIC_PORT:$TUIC_PORT/udp"
  caddy:
    image: caddy:2
    container_name: singbox-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "$HTTPS_PORT:$HTTPS_PORT"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
volumes:
  caddy_data:
  caddy_config:
EOF
else
  cat > sing-box.json <<EOF
{
  "log": { "level": "warn" },
  "dns": {
    "servers": [
      { "type": "https", "tag": "doh-cf", "server": "1.1.1.1" },
      { "type": "https", "tag": "doh-google", "server": "8.8.8.8" },
      { "type": "https", "tag": "doh-quad9", "server": "9.9.9.9" },
      { "type": "tls", "tag": "dot-cf", "server": "1.1.1.1" },
      { "type": "tls", "tag": "dot-google", "server": "8.8.8.8" }
    ],
    "final": "doh-cf",
    "strategy": "ipv4_only",
    "disable_cache": false
  },
  "inbounds": [
    { "type": "vless", "tag": "vless-ws", "listen": "0.0.0.0", "listen_port": 10000,
      "users": [ { "uuid": "$UUID_VLESS" } ],
      "transport": { "type": "ws", "path": "/$PATH_VLESS" } },
    { "type": "trojan", "tag": "trojan-ws", "listen": "0.0.0.0", "listen_port": 10001,
      "users": [ { "password": "$PASS_TROJAN" } ],
      "transport": { "type": "ws", "path": "/$PATH_TROJAN" } },
    { "type": "vmess", "tag": "vmess-ws", "listen": "0.0.0.0", "listen_port": 10002,
      "users": [ { "uuid": "$UUID_VMESS", "alterId": 0 } ],
      "transport": { "type": "ws", "path": "/$PATH_VMESS" } },
    { "type": "shadowsocks", "tag": "ss", "listen": "0.0.0.0", "listen_port": $SS_PORT,
      "method": "2022-blake3-aes-128-gcm", "password": "$PASS_SS" }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": {
    "final": "direct",
    "default_domain_resolver": { "server": "doh-cf", "strategy": "ipv4_only" }
  }
}
EOF
  cat > docker-compose.yml <<EOF
services:
  sing-box:
    image: ghcr.io/sagernet/sing-box:latest
    container_name: singbox-node
    restart: unless-stopped
    command: run -c /etc/sing-box/config.json
    volumes:
      - ./sing-box.json:/etc/sing-box/config.json:ro
    ports:
      - "$VLESS_PORT:10000"
      - "$TROJAN_PORT:10001"
      - "$VMESS_PORT:10002"
      - "$SS_PORT:$SS_PORT"
      - "$SS_PORT:$SS_PORT/udp"
EOF
fi

# 安装记录：域名、模式与最终端口（check.sh / stop.sh 从这里读实际端口）
cat > .env <<EOF
DOMAIN=$DOMAIN
SERVER_IP=$SERVER_IP
TLS_MODE=$TLS_MODE
HTTPS_PORT=$HTTPS_PORT
SS_PORT=$SS_PORT
HY2_PORT=$HY2_PORT
TUIC_PORT=$TUIC_PORT
VLESS_PORT=$VLESS_PORT
TROJAN_PORT=$TROJAN_PORT
VMESS_PORT=$VMESS_PORT
EOF

# 客户端 Clash 配置：全部流量走节点；DNS 全部走代理 DoH；禁 IPv6
if [ "$TLS_MODE" = "1" ]; then
  VLESS_PORT=$HTTPS_PORT; TROJAN_PORT=$HTTPS_PORT; VMESS_PORT=$HTTPS_PORT
  VLESS_TLS=true; TROJAN_TLS=true; VMESS_TLS=true
  VLESS_SERVER="$DOMAIN"; TROJAN_SERVER="$DOMAIN"; VMESS_SERVER="$DOMAIN"; SS_SERVER="$DOMAIN"
else
  VLESS_PORT=$VLESS_PORT; TROJAN_PORT=$TROJAN_PORT; VMESS_PORT=$VMESS_PORT
  VLESS_TLS=false; TROJAN_TLS=false; VMESS_TLS=false
  VLESS_SERVER="$SERVER_IP"; TROJAN_SERVER="$SERVER_IP"; VMESS_SERVER="$SERVER_IP"; SS_SERVER="$SERVER_IP"
fi

cat > clash.yaml <<EOF
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
ipv6: false
dns:
  enable: true
  ipv6: false
  listen: 0.0.0.0:1053
  enhanced-mode: redir-host
  nameserver:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  proxy-server-nameserver:
    - https://dns.cloudflare.com/dns-query
  fallback:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  fallback-filter:
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4
      - 0.0.0.0/32
  nameserver-policy:
    "+.tiktok.com":
      - https://dns.cloudflare.com/dns-query
proxies:
  - name: "SingBox-VLESS"
    type: vless
    server: $VLESS_SERVER
    port: $VLESS_PORT
    uuid: $UUID_VLESS
    tls: $VLESS_TLS
    servername: $VLESS_SERVER
    network: ws
    ws-opts:
      path: /$PATH_VLESS
      headers:
        Host: $VLESS_SERVER
  - name: "SingBox-Trojan"
    type: trojan
    server: $TROJAN_SERVER
    port: $TROJAN_PORT
    password: $PASS_TROJAN
    sni: $TROJAN_SERVER
    network: ws
    ws-opts:
      path: /$PATH_TROJAN
      headers:
        Host: $TROJAN_SERVER
  - name: "SingBox-VMess"
    type: vmess
    server: $VMESS_SERVER
    port: $VMESS_PORT
    uuid: $UUID_VMESS
    alterId: 0
    cipher: auto
    tls: $VMESS_TLS
    servername: $VMESS_SERVER
    network: ws
    ws-opts:
      path: /$PATH_VMESS
      headers:
        Host: $VMESS_SERVER
  - name: "SingBox-SS"
    type: ss
    server: $SS_SERVER
    port: $SS_PORT
    cipher: 2022-blake3-aes-128-gcm
    password: $PASS_SS
    udp: true
EOF
if [ "$TLS_MODE" = "1" ]; then
  cat >> clash.yaml <<EOF
  - name: "SingBox-HY2"
    type: hysteria2
    server: $DOMAIN
    port: $HY2_PORT
    password: $PASS_HY2
    sni: $DOMAIN
    alpn:
      - h3
  - name: "SingBox-TUIC"
    type: tuic
    server: $DOMAIN
    port: $TUIC_PORT
    uuid: $UUID_TUIC
    password: $PASS_TUIC
    congestion-controller: bbr
    alpn:
      - h3
    sni: $DOMAIN
EOF
fi
PROXY_LIST='      - "SingBox-VLESS"
      - "SingBox-Trojan"
      - "SingBox-VMess"
      - "SingBox-SS"'
if [ "$TLS_MODE" = "1" ]; then
  PROXY_LIST="$PROXY_LIST
      - \"SingBox-HY2\"
      - \"SingBox-TUIC\""
fi
cat >> clash.yaml <<EOF
proxy-groups:
  - name: "PROXY"
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
$PROXY_LIST
  - name: "MANUAL"
    type: select
    proxies:
$PROXY_LIST
rules:
  - MATCH,PROXY
EOF

# 各协议节点链接
if [ "$TLS_MODE" = "1" ]; then
  LINK_VLESS="vless://$UUID_VLESS@$DOMAIN:$HTTPS_PORT?encryption=none&security=tls&type=ws&host=$DOMAIN&path=%2F$PATH_VLESS#SingBox-VLESS"
  LINK_TROJAN="trojan://$PASS_TROJAN@$DOMAIN:$HTTPS_PORT?security=tls&type=ws&host=$DOMAIN&path=%2F$PATH_TROJAN#SingBox-Trojan"
  VMESS_JSON="{\"v\":\"2\",\"ps\":\"SingBox-VMess\",\"add\":\"$DOMAIN\",\"port\":\"$HTTPS_PORT\",\"id\":\"$UUID_VMESS\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$DOMAIN\",\"path\":\"/$PATH_VMESS\",\"tls\":\"tls\",\"sni\":\"$DOMAIN\"}"
else
  LINK_VLESS="vless://$UUID_VLESS@$SERVER_IP:$VLESS_PORT?encryption=none&security=none&type=ws&path=%2F$PATH_VLESS#SingBox-VLESS"
  LINK_TROJAN="trojan://$PASS_TROJAN@$SERVER_IP:$TROJAN_PORT?security=none&type=ws&path=%2F$PATH_TROJAN#SingBox-Trojan"
  VMESS_JSON="{\"v\":\"2\",\"ps\":\"SingBox-VMess\",\"add\":\"$SERVER_IP\",\"port\":\"$VMESS_PORT\",\"id\":\"$UUID_VMESS\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$SERVER_IP\",\"path\":\"/$PATH_VMESS\",\"tls\":\"\"}"
fi
LINK_VMESS="vmess://$(printf '%s' "$VMESS_JSON" | base64 -w0)"
SS_USERINFO="$(printf '%s' "2022-blake3-aes-128-gcm:$PASS_SS" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
LINK_SS="ss://$SS_USERINFO@$SS_SERVER:$SS_PORT#SingBox-SS"
if [ "$TLS_MODE" = "1" ]; then
  LINK_HY2="hysteria2://$PASS_HY2@$DOMAIN:$HY2_PORT?sni=$DOMAIN&alpn=h3#SingBox-HY2"
  LINK_TUIC="tuic://$UUID_TUIC:$PASS_TUIC@$DOMAIN:$TUIC_PORT?congestion_control=bbr&alpn=h3&sni=$DOMAIN#SingBox-TUIC"
fi

echo "== 7/8 启动并拨测 =="
if [ "$DRY_RUN" != "1" ]; then
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    if [ "$TLS_MODE" = "1" ]; then
      ufw allow 80/tcp >/dev/null; ufw allow "$HTTPS_PORT"/tcp >/dev/null
      ufw allow "$SS_PORT"/tcp >/dev/null; ufw allow "$SS_PORT"/udp >/dev/null
      ufw allow "$HY2_PORT"/udp >/dev/null; ufw allow "$TUIC_PORT"/udp >/dev/null
    else
      ufw allow "$VLESS_PORT"/tcp >/dev/null; ufw allow "$TROJAN_PORT"/tcp >/dev/null; ufw allow "$VMESS_PORT"/tcp >/dev/null
      ufw allow "$SS_PORT"/tcp >/dev/null; ufw allow "$SS_PORT"/udp >/dev/null
    fi
    echo "ufw 已放行对应端口"
  fi

  if [ "$TLS_MODE" = "1" ]; then
    # 先起 Caddy 拿证书，HY2/TUIC 要用 Caddy 签下的证书
    docker compose up -d --force-recreate caddy
    echo "等 Caddy 签证书（最多 180 秒）..."
    CERT_OK=0
    for i in $(seq 1 36); do
      if docker exec singbox-caddy test -f "/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN/$DOMAIN.crt" 2>/dev/null; then
        CERT_OK=1; break
      fi
      sleep 5
    done
    if [ "$CERT_OK" = "1" ]; then
      echo "证书已就绪，HY2/TUIC 启用"
    else
      echo "警告：180 秒内没拿到证书，HY2/TUIC 暂不启用（VLESS/Trojan/VMess/SS 不受影响）；重跑一次本命令可补上（会换一套新节点）"
      HY2_ENABLED=0
      python3 - "$PWD/sing-box.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["inbounds"] = [i for i in d["inbounds"] if i.get("tag") not in ("hy2", "tuic")]
json.dump(d, open(p, "w"), indent=2)
PY
    fi
    docker compose up -d --force-recreate sing-box
    sleep 3
    CODE=""
    for i in $(seq 1 30); do
      CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN:$HTTPS_PORT/" || true)
      [ "$CODE" = "200" ] && break
      sleep 3
    done
    echo "首页 https://$DOMAIN:$HTTPS_PORT/ -> HTTP ${CODE:-无响应}（200 = Caddy 与证书正常）"
    for P in "$PATH_VLESS" "$PATH_TROJAN" "$PATH_VMESS"; do
      WSCODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" "https://$DOMAIN:$HTTPS_PORT/$P" || true)
      echo "WS 握手 https://$DOMAIN:$HTTPS_PORT/$P -> HTTP ${WSCODE:-无响应}（101 = 正常；200 = Caddy 没转给 sing-box，跑 docker compose down && docker compose up -d 重建；400 = sing-box 拒绝握手）"
    done
    echo "SS $SS_PORT / HY2 $HY2_PORT / TUIC $TUIC_PORT 需用客户端实测（非 HTTP 端口，curl 测不了）"
  else
    docker compose up -d --force-recreate
    sleep 3
    WSCODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" "http://$SERVER_IP:$VLESS_PORT/$PATH_VLESS" || true)
    echo "VLESS WS 握手 -> HTTP ${WSCODE:-无响应}（101 = 正常）"
    WSCODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" "http://$SERVER_IP:$TROJAN_PORT/$PATH_TROJAN" || true)
    echo "Trojan WS 握手 -> HTTP ${WSCODE:-无响应}（101 = 正常）"
    WSCODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" "http://$SERVER_IP:$VMESS_PORT/$PATH_VMESS" || true)
    echo "VMess WS 握手 -> HTTP ${WSCODE:-无响应}（101 = 正常）"
  fi
else
  echo "[dry-run] 跳过启动与拨测"
fi

# 订阅：全部可用协议链接放一起
SUB_LINKS="$LINK_VLESS
$LINK_TROJAN
$LINK_VMESS
$LINK_SS"
if [ "$TLS_MODE" = "1" ] && [ "$HY2_ENABLED" = "1" ]; then
  SUB_LINKS="$SUB_LINKS
$LINK_HY2
$LINK_TUIC"
fi
SUB=$(printf '%s' "$SUB_LINKS" | base64 -w0)

echo "== 8/8 生成二维码 =="
QR_OK=0
if ! command -v qrencode >/dev/null 2>&1; then
  echo "本机没有 qrencode，尝试安装..."
  if command -v apt-get >/dev/null 2>&1; then
    timeout 180 apt-get update -qq >/dev/null 2>&1 || true
    timeout 180 apt-get install -y -qq qrencode >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    timeout 180 yum install -y -q qrencode >/dev/null 2>&1 || true
  fi
fi
if command -v qrencode >/dev/null 2>&1; then
  qrencode -o qr-vless.png -s 8 "$LINK_VLESS" && \
  qrencode -o qr-trojan.png -s 8 "$LINK_TROJAN" && \
  qrencode -o qr-vmess.png -s 8 "$LINK_VMESS" && \
  qrencode -o qr-ss.png -s 8 "$LINK_SS" && QR_OK=1
  if [ "$TLS_MODE" = "1" ] && [ "$HY2_ENABLED" = "1" ]; then
    qrencode -o qr-hy2.png -s 8 "$LINK_HY2" && \
    qrencode -o qr-tuic.png -s 8 "$LINK_TUIC" || QR_OK=0
  fi
elif command -v python3 >/dev/null 2>&1; then
  if python3 - "$LINK_VLESS" "$LINK_TROJAN" "$LINK_VMESS" "$LINK_SS" <<'PY'
import sys
try:
    import qrcode
except ImportError:
    sys.exit(1)
names = ["qr-vless.png", "qr-trojan.png", "qr-vmess.png", "qr-ss.png"]
for name, link in zip(names, sys.argv[1:]):
    qrcode.make(link).save(name)
PY
  then QR_OK=1; fi
fi

echo ""
echo "================ 部署完成 ================"
echo "节点链接（小火箭/Clash 可直接导入）："
echo "VLESS:  $LINK_VLESS"
echo "Trojan: $LINK_TROJAN"
echo "VMess:  $LINK_VMESS"
echo "SS:     $LINK_SS"
if [ "$TLS_MODE" = "1" ] && [ "$HY2_ENABLED" = "1" ]; then
  echo "HY2:    $LINK_HY2"
  echo "TUIC:   $LINK_TUIC"
fi
echo ""
echo "订阅内容（base64，含全部可用协议）："
echo "$SUB"
echo ""
echo "Clash 配置已生成：$(pwd)/clash.yaml（DNS 全走代理、禁 IPv6，直接导入 Clash/Stash）"
if [ "$QR_OK" = "1" ]; then
  echo "二维码已生成：$(pwd)/qr-vless.png qr-trojan.png qr-vmess.png qr-ss.png（TLS 模式另有 qr-hy2.png qr-tuic.png），下载到手机扫码即可"
else
  echo "本机没生成二维码：把上面的节点链接发给 Muse，它会回你二维码图片。"
fi
echo ""
echo "注意：链接里的 UUID/密码等同于密码，不要外传。"
echo "下一步：运行 bash check.sh 做泄漏自检，再按 README 配手机端。"
# check.sh 由 install.sh 内嵌生成（远程一键时只有一个文件）
cat > check.sh <<'CHECK_EOF'
#!/usr/bin/env bash
# TikTok 节点泄漏自检：在节点服务器上运行，检查 IP 纯净度、地区、IPv6、DNS、TikTok 可达性、公开端口监听
# 手机端的 DNS/WebRTC 泄漏需在手机上验证（脚本末尾会给出检查方法）
# 公开端口从安装目录的 .env 读（install.sh 安装时写入实际端口）；没有 .env 就用默认端口
set -uo pipefail

pass() { echo "  [通过] $1"; }
warn() { echo "  [注意] $1"; }
fail() { echo "  [风险] $1"; }

echo "== 1/6 节点 IP 与地区 =="
IPJSON="$(curl -s --max-time 10 "https://ip-api.org/json/" || true)"
if [ -z "$IPJSON" ]; then
  warn "ip-api.org 查不到，改用 ipinfo.io"
  IPJSON="$(curl -s --max-time 10 "https://ipinfo.io/json" || true)"
fi
if command -v python3 >/dev/null 2>&1 && [ -n "$IPJSON" ]; then
  python3 - "$IPJSON" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("  [注意] IP 查询返回异常"); sys.exit(0)
ip = d.get("query") or d.get("ip", "?")
country = d.get("country") or d.get("countryCode", "?")
cc = d.get("countryCode") or ""
city = d.get("city") or d.get("region", "?")
isp = d.get("isp") or d.get("org", "?")
hosting = d.get("hosting")
print(f"  节点 IP：{ip}")
print(f"  地区：{country} {cc} / {city}")
print(f"  运营商/机房：{isp}")
if hosting is True:
    print("  [风险] 这是机房 IP（hosting=true）。TikTok 对机房 IP 风控更严，")
    print("        容易限流/0播放。如果之后播放量异常，优先换住宅/ISP 的干净 IP。")
elif hosting is False:
    print("  [通过] 看起来是住宅/ISP IP（hosting=false），TikTok 风控相对友好。")
else:
    print("  [注意] 查不到 hosting 标记，可在 https://ipinfo.io 再核对一次。")
PY
else
  echo "  原始结果：$IPJSON"
fi

echo ""
echo "== 2/6 IPv6 是否禁用 =="
V6="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "?")"
if [ "$V6" = "1" ]; then
  pass "IPv6 已禁用（disable_ipv6=1）"
else
  fail "IPv6 未禁用（disable_ipv6=$V6）。跑 install.sh 时会自动禁用；手动执行："
  echo "       echo 'net.ipv6.conf.all.disable_ipv6 = 1' >> /etc/sysctl.d/99-tiktok-node.conf && sysctl -p"
fi
if ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
  fail "本机仍有全局 IPv6 地址，存在 IPv6 泄漏口"
else
  pass "本机无全局 IPv6 地址"
fi

echo ""
echo "== 3/6 DNS 解析路径 =="
if command -v dig >/dev/null 2>&1; then
  RESOLVER="$(dig +short whoami.akamai.net @1.1.1.1 2>/dev/null | head -1)"
  [ -n "$RESOLVER" ] && echo "  经 1.1.1.1 解析的出口解析器 IP：$RESOLVER（应为 Cloudflare 的 IP，非国内运营商）"
  [ -z "$RESOLVER" ] && warn "dig 查询无返回，检查本机出站 UDP/TCP 53 是否被墙"
else
  warn "本机无 dig，跳过解析器核对（apt install dnsutils 可装）"
fi
echo "  xray 已配置 DoH(1.1.1.1/8.8.8.8)+TCP 兜底、只解析 IPv4，服务端不再走明文 UDP 53"

echo ""
echo "== 4/6 TikTok 可达性（从节点 IP 出口测） =="
TT_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://www.tiktok.com/" || echo "000")"
API_CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://api16-normal-c-useast1a.tiktokv.com/" || echo "000")"
echo "  tiktok.com -> HTTP $TT_CODE"
echo "  TikTok API 域名 -> HTTP $API_CODE"
if [ "$TT_CODE" = "200" ] || [ "$TT_CODE" = "301" ] || [ "$TT_CODE" = "302" ]; then
  pass "TikTok 主站从节点 IP 可达"
else
  fail "TikTok 主站从节点 IP 不可达（HTTP $TT_CODE），检查节点 IP 是否被 TikTok 拉黑或出站被墙"
fi

echo ""
echo "== 5/6 手机端自查（在手机上开着节点做） =="
echo "  节点只能管服务端这一半，手机端泄漏要这样验："
echo "  1) 打开 https://www.dnsleaktest.com 点 Extended test："
echo "     全部 DNS 服务器 IP 应该都是节点所在国家/机房的，出现中国运营商 DNS = 泄漏"
echo "  2) 打开 https://browserleaks.com/ip："
echo "     不能出现你的真实 IP、不能出现 IPv6 地址、时区/语言要和节点地区一致"
echo "  3) TikTok 里刷几个视频再看个人主页地区：应与节点地区一致"
echo "  4) 手机设置核对（见 README）：已拔国内 SIM 卡、时区语言=节点地区、定位已关"
echo ""
echo "== 6/6 公开端口监听 =="
# 端口从安装目录的 .env 读（install.sh 安装时写入实际端口）；没有 .env 就用默认端口
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a; . "$SCRIPT_DIR/.env"; set +a
  echo "  端口配置来自 $SCRIPT_DIR/.env"
else
  echo "  未找到 .env，按默认端口检查（TLS：HTTPS 443 / SS 8388 / HY2 8443 / TUIC 8444；明文：8080/8081/8082/8388）"
fi
TLS_MODE="${TLS_MODE:-1}"
HTTPS_PORT="${HTTPS_PORT:-443}"; SS_PORT="${SS_PORT:-8388}"; HY2_PORT="${HY2_PORT:-8443}"; TUIC_PORT="${TUIC_PORT:-8444}"
VLESS_PORT="${VLESS_PORT:-8080}"; TROJAN_PORT="${TROJAN_PORT:-8081}"; VMESS_PORT="${VMESS_PORT:-8082}"

port_listening_tcp() {
  local port="$1" hex
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
  else
    hex=$(printf '%04X' "$port")
    grep -qiE "^[[:space:]]*[0-9]+:[[:space:]]+[0-9A-Fa-f]+:${hex}[[:space:]]" /proc/net/tcp /proc/net/tcp6 2>/dev/null
  fi
}
port_listening_udp() {
  local port="$1" hex
  if command -v ss >/dev/null 2>&1; then
    ss -uln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
  else
    hex=$(printf '%04X' "$port")
    grep -qiE "^[[:space:]]*[0-9]+:[[:space:]]+[0-9A-Fa-f]+:${hex}[[:space:]]" /proc/net/udp /proc/net/udp6 2>/dev/null
  fi
}
check_port() { # check_port 名字 端口 tcp|udp|both
  local name="$1" port="$2" proto="$3" ok=1
  case "$proto" in
    tcp) port_listening_tcp "$port" || ok=0 ;;
    udp) port_listening_udp "$port" || ok=0 ;;
    both) { port_listening_tcp "$port" && port_listening_udp "$port"; } || ok=0 ;;
  esac
  if [ "$ok" = "1" ]; then pass "$name 正在监听（端口 $port/$proto）"; else fail "$name 未监听（端口 $port/$proto），容器可能没起来，或端口被别的程序占了"; fi
}
if [ "$TLS_MODE" = "1" ]; then
  check_port "HTTPS(WS)" "$HTTPS_PORT" tcp
  check_port "Shadowsocks" "$SS_PORT" both
  check_port "Hysteria2" "$HY2_PORT" udp
  check_port "TUIC" "$TUIC_PORT" udp
else
  check_port "VLESS" "$VLESS_PORT" tcp
  check_port "Trojan" "$TROJAN_PORT" tcp
  check_port "VMess" "$VMESS_PORT" tcp
  check_port "Shadowsocks" "$SS_PORT" both
fi
echo ""
echo "自检完成。"
CHECK_EOF
chmod +x check.sh

if [ "$DRY_RUN" != "1" ]; then
  echo ""
  bash check.sh || true
fi
