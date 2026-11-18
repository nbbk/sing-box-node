#!/usr/bin/env bash
# sing-box 运营节点一键部署：一个核心管所有协议（VLESS / Trojan / VMess / Shadowsocks / Hysteria2 / TUIC），DNS 防泄漏 + 禁 IPv6
# 用法：
#   本地：bash install.sh [域名]
#   远程一键：curl -fsSL https://raw.githubusercontent.com/nbbk/sing-box-node/main/install.sh | bash -s [域名]
#   （不给域名则交互询问；直接回车用 IP 明文跑，HY2/TUIC 不启用）
#   追加节点：bash install.sh --add-node [新子域名]（装完也会问“还要再加一个节点吗？”）
#   删除单个节点：bash install.sh --del-node [子域名或编号]
#   不带参数重跑只换第一个节点的凭据，已追加的节点不受影响
# 架构：有域名 -> Caddy 在 HTTPS 端口（默认 443，可自定义高位端口）终止 TLS，反代本机 sing-box 的 WS 入站（VLESS/Trojan/VMess）；
#        Hysteria2/TUIC 直接走 UDP，用 Caddy 签下的证书；Shadowsocks 直连（默认 8388，可自定义）
#        无域名 -> VLESS/Trojan/VMess 明文 WS（默认 8080/8081/8082，可自定义），SS 直连（默认 8388，可自定义），HY2/TUIC 不启用（需要域名证书）
# 多节点：一台落地机可跑多个节点，每个节点一个子域名、自己的凭据与后端容器（singbox-node / singbox-node-N），
#        共用一个 Caddy 的 443 按域名分流（WS 三协议）；SS/HY2/TUIC 直连端口每节点不同（默认在前一节点端口上加 10000）。
# 证书签发方式（有域名时安装会问，二选一，默认走 80；追加节点沿用第一次选的方式，不再重问）：
#   [1] 默认走 80（HTTP-01）：最简单，什么都不用准备；要求 80 空闲；Caddy 逐个子域名自动签
#   [2] DNS 验证（Cloudflare，DNS-01）：不用 80、不改指向、续签全自动；要一个 Cloudflare API 令牌；
#       一张泛域名证书 *.example.com 通吃所有子域名，签一次就够（各节点须是同一父域名的子域名）
# 公开端口：默认即当前端口，直接回车就行；默认端口被占时安装会问你要不要换高位端口（如 HTTPS 8443、SS 18388）；
#        选 [1] 时 80 端口必须空闲（Caddy 签证书走 HTTP-01 验证必须用 80），改不了，80 被占 TLS 装不了；
#        选 [2] 时 80 被占也不影响签证书和续签
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
CLI_DOMAIN=""
MODE="fresh"          # fresh / add / del
MODE_ARG=""           # --add-node / --del-node 后面跟的参数（子域名或编号）
HY2_ENABLED=1

# ---------- 命令行参数 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --add-node) MODE="add"; MODE_ARG="${2:-}"; [ -n "${2:-}" ] && shift ;;
    --del-node) MODE="del"; MODE_ARG="${2:-}"; [ -n "${2:-}" ] && shift ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      echo "用法：bash install.sh [域名]"
      echo "     bash install.sh --add-node [新子域名]   追加一个节点"
      echo "     bash install.sh --del-node [子域名或编号] 删除单个节点"
      echo "     bash install.sh --dry-run [域名]        只生成配置文件，不安装"
      exit 0 ;;
    *) CLI_DOMAIN="$1" ;;
  esac
  shift
done

# ---------- 节点注册表 nodes.conf ----------
# 每节点一组 NODE_<编号>_ 前缀变量；全局设置 GLOBAL_ 前缀。首节点沿用旧文件名
# （sing-box.json / clash.yaml / qr-*.png，容器 singbox-node），追加节点用 -N 后缀。
# nodes.conf 只存本机 root 可读（600），里面有 UUID/密码（等同于密码）。
REG_FILE="nodes.conf"

reg_get() {  # reg_get KEY -> 值（找不到为空）
  local k="$1" line=""
  [ -f "$REG_FILE" ] || return 0
  line="$(grep -m1 "^${k}=" "$REG_FILE" || true)"
  printf '%s' "${line#*=}"
}

reg_set() {  # reg_set KEY VALUE：存在则整行重写，不存在则追加（不用 sed 替换，值里有 & 也不怕）
  local k="$1" v="$2"
  touch "$REG_FILE"
  grep -v "^${k}=" "$REG_FILE" > "$REG_FILE.tmp" || true
  printf '%s=%s\n' "$k" "$v" >> "$REG_FILE.tmp"
  mv "$REG_FILE.tmp" "$REG_FILE"
}

node_indices() {  # 全部节点编号（每行一个，数字升序）
  [ -f "$REG_FILE" ] || return 0
  grep -oE '^NODE_[0-9]+_DOMAIN=' "$REG_FILE" | grep -oE '[0-9]+' | sort -n -u || true
}

node_field() { reg_get "NODE_${1}_${2}"; }   # node_field 编号 字段名

node_count() { node_indices | wc -l | tr -d ' '; }

next_index() {  # 下一个可用编号 = 现有最大编号 + 1（删过的编号不复用）
  local max=0 i
  for i in $(node_indices); do [ "$i" -gt "$max" ] && max="$i"; done
  echo $((max + 1))
}

find_node_by_domain() {  # find_node_by_domain 域名 -> 编号（找不到返回 1）
  local d="$1" i
  for i in $(node_indices); do
    [ "$(node_field "$i" DOMAIN)" = "$d" ] && { echo "$i"; return 0; }
  done
  return 1
}

svc_name() {  # compose 服务名：节点 1 叫 sing-box，节点 N 叫 sing-box-N
  if [ "$1" = "1" ]; then echo "sing-box"; else echo "sing-box-$1"; fi
}

valid_domain() {  # 域名合法性：小写字母/数字/点/连字符，至少一个点，不以点或连字符开头结尾
  case "$1" in
    ""|*[!a-z0-9.-]*|.*|*.|*-*|*--*|*..*) return 1 ;;
  esac
  case "$1" in *.*) return 0 ;; *) return 1 ;; esac
}

# ---------- 端口占用预检（ss -> netstat -> /proc 回退） ----------
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

# 端口是否被我们自己的节点容器占用（重跑换节点 1 时旧容器还占着端口，不算被占，之后会被重建）
port_owned_by_us() {
  local port="$1"
  [ "$DRY_RUN" = "1" ] && return 1
  command -v docker >/dev/null 2>&1 || return 1
  docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E '^singbox-(node(-[0-9]+)?|caddy) ' | grep -q ":${port}->"
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
    if [ "$varname" = "HTTPS_PORT" ] && [ "$preset" = "80" ]; then
      if [ "${CERT_METHOD:-http}" = "dns" ]; then echo "环境变量 HTTPS_PORT 不能是 80（80 是 HTTP 端口，HTTPS 跑在 80 上客户端连不上），请修正后重跑。";
      else echo "环境变量 HTTPS_PORT 不能是 80（80 要留给 Caddy 签证书用），请修正后重跑。"; fi
      exit 1
    fi
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
    if [ "$varname" = "HTTPS_PORT" ] && [ "$ans" = "80" ]; then
      if [ "${CERT_METHOD:-http}" = "dns" ]; then echo "HTTPS 端口不能是 80（80 是 HTTP 端口，HTTPS 跑在 80 上客户端连不上），请换一个端口。";
      else echo "HTTPS 端口不能是 80（80 要留给 Caddy 签证书用），请换一个端口。"; fi
      ans=""; continue
    fi
    if port_used "$ans" "$used"; then echo "端口 $ans 已经被前面选的端口占用了，请换一个。"; ans=""; continue; fi
    break
  done
  printf -v "$varname" '%s' "$ans"
}

# 证书签发方式：每个选项先印几行解释（作用、适合谁、要什么、代价），再问；直接回车默认 1
ask_cert_method() {
  local ans=""
  while :; do
    echo "证书签发方式（Caddy 自动签 TLS 证书，两种方式选一种）："
    echo ""
    echo "  [1] 默认走 80 端口（HTTP-01）← 默认，直接回车就是 1"
    echo "      最简单，什么都不用准备，装完 Caddy 自己签证书、到期自己续。"
    echo "      前提：80 端口必须空闲，域名要指向这台落地机。"
    echo "      适合：单节点、80 没被占的情况。"
    echo ""
    echo "  [2] DNS 验证（Cloudflare，DNS-01）"
    echo "      不用 80 端口，域名不用改来改去，续签全自动，不怕忘。"
    echo "      前提：域名 DNS 在 Cloudflare，要去 Cloudflare 后台开一个只给改 DNS 权限的 API 令牌。"
    echo "      适合：80 被占了、多节点、怕忘续签的情况。"
    echo ""
    echo "请输入你的选择："
    read_line ans "证书签发方式（1=走 80，2=DNS 验证；默认 1，直接回车就是 1）： "
    [ -z "$ans" ] && ans="1"
    case "$ans" in
      1|http) CERT_METHOD="http"; return 0 ;;
      2|dns) CERT_METHOD="dns"; return 0 ;;
      *) echo "输入不合法：$ans（只能填 1 或 2），请重新输入。" ;;
    esac
  done
}

# Cloudflare API 令牌：输入不回显、不打印；空输入重问；不是 40 位时提醒一次
ask_cf_token() {
  local ans=""
  while :; do
    echo "请填写 Cloudflare API 令牌："
    echo "  去 Cloudflare 后台开：My Profile → API Tokens → Create Token → 用“Edit zone DNS”模板，"
    echo "  只给改 DNS 的权限（Zone:DNS:Edit），不要用 Global API Key。"
    if [ -t 0 ]; then
      read -rsp "Cloudflare API 令牌（输入时不显示，粘贴后回车）： " ans || true
    elif [ -r /dev/tty ]; then
      read -rsp "Cloudflare API 令牌（输入时不显示，粘贴后回车）： " ans </dev/tty 2>/dev/null || true
    fi
    echo ""
    if [ -z "$ans" ]; then echo "令牌不能为空，请重新输入。"; continue; fi
    if [ "${#ans}" -ne 40 ]; then echo "提醒：Cloudflare API 令牌一般是 40 位，你填的是 ${#ans} 位，请核对一下（确认无误就继续用，错了证书会签不下来）。"; fi
    printf -v CLOUDFLARE_API_TOKEN '%s' "$ans"
    return 0
  done
}

# 泛域名父域名：去掉第一个标签（us1.example.com -> example.com）；两段式域名本身就是父域名
base_domain() {
  local d="$1"
  case "$d" in *.*.*) printf '%s' "${d#*.}" ;; *) printf '%s' "$d" ;; esac
}

# ---------- 端口预检 ----------
# 首装/重跑：按最终选定的端口查占用（不是只查默认端口）；80 在 TLS 模式下必须空闲
# （Caddy 签证书走 HTTP-01 验证，必须用 80；80 被占 TLS 装不了）
# 自家旧容器占的端口不算被占（重跑换节点 1 时旧容器之后会被重建）
check_ports() {
  local occupied="" p
  if [ "$TLS_MODE" = "1" ] && [ "${CERT_METHOD:-http}" = "dns" ]; then
    echo "DNS 验证模式：80 端口不用空闲，跳过 80 预检。"
  elif [ "$TLS_MODE" = "1" ] && port_in_use_any 80 && ! port_owned_by_us 80; then
    echo ""
    echo "80 端口已被占用，TLS 模式装不了："
    show_port_owner 80
    echo "Caddy 签证书走 HTTP-01 验证，必须用 80 端口；80 被占就签不下证书。"
    echo "办法：停掉占用 80 的程序再跑，或换一台服务器；"
    echo "也可以重跑并选 [2] DNS 验证（要 Cloudflare API 令牌），80 被占也能装；"
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
    if port_in_use_any "$p" && ! port_owned_by_us "$p"; then occupied="$occupied $p"; fi
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

# 追加节点：只查新节点的直连端口（SS/HY2/TUIC 或明文 WS 端口）；80 与 HTTPS 端口是 Caddy 共用的，不查
check_ports_add() {
  local occupied="" p
  local -a want=()
  if [ "$TLS_MODE" = "1" ]; then
    want=( "$SS_PORT" "$HY2_PORT" "$TUIC_PORT" )
  else
    want=( "$VLESS_PORT" "$TROJAN_PORT" "$VMESS_PORT" "$SS_PORT" )
  fi
  for p in "${want[@]}"; do
    if port_in_use_any "$p"; then occupied="$occupied $p"; fi
  done
  if [ -n "$occupied" ]; then
    echo ""
    echo "新节点的端口已被占用：$occupied"
    for p in $occupied; do show_port_owner "$p"; done
    echo "办法：重跑 --add-node 并把被占的端口改成高位端口，或先停掉占用它的程序。"
    exit 1
  fi
}

# ---------- 旧版迁移 ----------
# 只有 .env、没有 nodes.conf 的旧版单节点：从 .env + sing-box.json 读出节点 1 的全部信息写进注册表
# （之后 --add-node / --del-node 才能认出它；迁移不改任何已有文件）
migrate_legacy() {
  [ -f .env ] || return 1
  [ -f nodes.conf ] && return 1
  [ -f sing-box.json ] || return 1
  echo "检测到旧版单节点（只有 .env，没有 nodes.conf），正在迁移到节点注册表..."
  set -a; . ./.env; set +a
  local base
  base="$(base_domain "${DOMAIN:-}")"
  python3 - "$PWD/sing-box.json" > /tmp/sb-migrate.env <<'PY' || return 1
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
by_tag = {i.get("tag"): i for i in d.get("inbounds", [])}
def ws_path(tag):
    t = by_tag.get(tag, {}).get("transport", {})
    return t.get("path", "").lstrip("/")
def first_user(tag, key):
    u = by_tag.get(tag, {}).get("users", [{}])
    return u[0].get(key, "") if u else ""
def listen(tag):
    return str(by_tag.get(tag, {}).get("listen_port", ""))
vals = {
 "UUID_VLESS": first_user("vless-ws", "uuid"),
 "UUID_VMESS": first_user("vmess-ws", "uuid"),
 "UUID_TUIC": first_user("tuic", "uuid"),
 "PASS_TROJAN": first_user("trojan-ws", "password"),
 "PASS_SS": first_user("ss", "password"),
 "PASS_HY2": first_user("hy2", "password"),
 "PASS_TUIC": first_user("tuic", "password"),
 "PATH_VLESS": ws_path("vless-ws"),
 "PATH_TROJAN": ws_path("trojan-ws"),
 "PATH_VMESS": ws_path("vmess-ws"),
 "HY2_ENABLED": "1" if "hy2" in by_tag else "0",
}
for k, v in vals.items():
    print(f"{k}={v}")
PY
  set -a; . /tmp/sb-migrate.env; set +a
  rm -f /tmp/sb-migrate.env
  reg_set "GLOBAL_TLS_MODE" "${TLS_MODE:-1}"
  reg_set "GLOBAL_CERT_METHOD" "${CERT_METHOD:-http}"
  reg_set "GLOBAL_HTTPS_PORT" "${HTTPS_PORT:-443}"
  reg_set "GLOBAL_SERVER_IP" "${SERVER_IP:-}"
  reg_set "GLOBAL_BASE_DOMAIN" "$base"
  reg_set "NODE_1_DOMAIN" "${DOMAIN:-}"
  reg_set "NODE_1_TLS_MODE" "${TLS_MODE:-1}"
  reg_set "NODE_1_CERT_METHOD" "${CERT_METHOD:-http}"
  reg_set "NODE_1_WS_BASE" "10000"
  reg_set "NODE_1_PATH_VLESS" "$PATH_VLESS"
  reg_set "NODE_1_PATH_TROJAN" "$PATH_TROJAN"
  reg_set "NODE_1_PATH_VMESS" "$PATH_VMESS"
  reg_set "NODE_1_UUID_VLESS" "$UUID_VLESS"
  reg_set "NODE_1_UUID_VMESS" "$UUID_VMESS"
  reg_set "NODE_1_UUID_TUIC" "$UUID_TUIC"
  reg_set "NODE_1_PASS_TROJAN" "$PASS_TROJAN"
  reg_set "NODE_1_PASS_SS" "$PASS_SS"
  reg_set "NODE_1_PASS_HY2" "$PASS_HY2"
  reg_set "NODE_1_PASS_TUIC" "$PASS_TUIC"
  reg_set "NODE_1_SS_PORT" "${SS_PORT:-8388}"
  reg_set "NODE_1_HY2_PORT" "${HY2_PORT:-8443}"
  reg_set "NODE_1_TUIC_PORT" "${TUIC_PORT:-8444}"
  reg_set "NODE_1_VLESS_PORT" "${VLESS_PORT:-8080}"
  reg_set "NODE_1_TROJAN_PORT" "${TROJAN_PORT:-8081}"
  reg_set "NODE_1_VMESS_PORT" "${VMESS_PORT:-8082}"
  reg_set "NODE_1_HY2_ENABLED" "$HY2_ENABLED"
  reg_set "NODE_1_CONTAINER" "singbox-node"
  reg_set "NODE_1_CONFIG" "sing-box.json"
  reg_set "NODE_1_CLASH" "clash.yaml"
  chmod 600 "$REG_FILE"
  echo "迁移完成：旧节点已登记为节点 1（${DOMAIN:-明文}）。"
  return 0
}

# ---------- 生成 sing-box 配置（纯函数：只读注册表，写 sing-box[-N].json） ----------
gen_singbox_json() {
  local n="$1"
  local dom tls cm base wsb pv pt pm uv um ut ptr pss phy ptu ss hp tu hy2en cfg
  dom="$(node_field "$n" DOMAIN)"; tls="$(node_field "$n" TLS_MODE)"; cm="$(node_field "$n" CERT_METHOD)"
  base="$(reg_get GLOBAL_BASE_DOMAIN)"
  wsb="$(node_field "$n" WS_BASE)"; pv="$(node_field "$n" PATH_VLESS)"; pt="$(node_field "$n" PATH_TROJAN)"; pm="$(node_field "$n" PATH_VMESS)"
  uv="$(node_field "$n" UUID_VLESS)"; um="$(node_field "$n" UUID_VMESS)"; ut="$(node_field "$n" UUID_TUIC)"
  ptr="$(node_field "$n" PASS_TROJAN)"; pss="$(node_field "$n" PASS_SS)"; phy="$(node_field "$n" PASS_HY2)"; ptu="$(node_field "$n" PASS_TUIC)"
  ss="$(node_field "$n" SS_PORT)"; hp="$(node_field "$n" HY2_PORT)"; tu="$(node_field "$n" TUIC_PORT)"
  hy2en="$(node_field "$n" HY2_ENABLED)"; cfg="$(node_field "$n" CONFIG)"
  local crt key
  if [ "$cm" = "dns" ]; then
    crt="/caddy-data/certificates/acme-v02.api.letsencrypt.org-directory/*.${base}/*.${base}.crt"
    key="/caddy-data/certificates/acme-v02.api.letsencrypt.org-directory/*.${base}/*.${base}.key"
  else
    crt="/caddy-data/certificates/acme-v02.api.letsencrypt.org-directory/${dom}/${dom}.crt"
    key="/caddy-data/certificates/acme-v02.api.letsencrypt.org-directory/${dom}/${dom}.key"
  fi
  local hy2_block="" tuic_block=""
  if [ "$tls" = "1" ] && [ "$hy2en" = "1" ]; then
    hy2_block=",
    { \"type\": \"hysteria2\", \"tag\": \"hy2\", \"listen\": \"0.0.0.0\", \"listen_port\": $hp,
      \"users\": [ { \"password\": \"$phy\" } ],
      \"tls\": { \"enabled\": true, \"server_name\": \"$dom\", \"alpn\": [\"h3\"],
               \"certificate_path\": \"$crt\", \"key_path\": \"$key\" } }"
    tuic_block=",
    { \"type\": \"tuic\", \"tag\": \"tuic\", \"listen\": \"0.0.0.0\", \"listen_port\": $tu,
      \"users\": [ { \"uuid\": \"$ut\", \"password\": \"$ptu\" } ],
      \"congestion_control\": \"bbr\",
      \"tls\": { \"enabled\": true, \"server_name\": \"$dom\", \"alpn\": [\"h3\"],
               \"certificate_path\": \"$crt\", \"key_path\": \"$key\" } }"
  fi
  cat > "$cfg" <<EOF
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
    { "type": "vless", "tag": "vless-ws", "listen": "0.0.0.0", "listen_port": $wsb,
      "users": [ { "uuid": "$uv" } ],
      "transport": { "type": "ws", "path": "/$pv" } },
    { "type": "trojan", "tag": "trojan-ws", "listen": "0.0.0.0", "listen_port": $((wsb + 1)),
      "users": [ { "password": "$ptr" } ],
      "transport": { "type": "ws", "path": "/$pt" } },
    { "type": "vmess", "tag": "vmess-ws", "listen": "0.0.0.0", "listen_port": $((wsb + 2)),
      "users": [ { "uuid": "$um", "alterId": 0 } ],
      "transport": { "type": "ws", "path": "/$pm" } },
    { "type": "shadowsocks", "tag": "ss", "listen": "0.0.0.0", "listen_port": $ss,
      "method": "2022-blake3-aes-128-gcm", "password": "$pss" }$hy2_block$tuic_block
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": {
    "final": "direct",
    "default_domain_resolver": { "server": "doh-cf", "strategy": "ipv4_only" }
  }
}
EOF
}

# ---------- 生成 Caddyfile（纯函数：只读注册表） ----------
# HTTP-01：每个 TLS 节点一段 site 配置，Caddy 逐个子域名自动签；
# DNS-01：一张泛域名证书 *.父域名 通吃所有子域名（一个泛域名 site 块 + 所有节点的 handle，
#         若有节点直接用父域名本身，再加一个父域名 site 块）
gen_caddyfile() {
  local has_tls=0 i
  for i in $(node_indices); do
    [ "$(node_field "$i" TLS_MODE)" = "1" ] && has_tls=1
  done
  if [ "$has_tls" = "0" ]; then rm -f Caddyfile; return 0; fi
  local cm hp base
  cm="$(reg_get GLOBAL_CERT_METHOD)"; hp="$(reg_get GLOBAL_HTTPS_PORT)"; base="$(reg_get GLOBAL_BASE_DOMAIN)"
  if [ "$cm" = "dns" ]; then
    {
      # 泛域名 site：所有 TLS 节点的 WS 路径按路径分流到各自后端
      echo "*.${base}:${hp} {"
      echo "    tls {"
      echo "        dns cloudflare {env.CLOUDFLARE_API_TOKEN}"
      echo "    }"
      for i in $(node_indices); do
        [ "$(node_field "$i" TLS_MODE)" = "1" ] || continue
        echo "    handle /$(node_field "$i" PATH_VLESS) {"
        echo "        reverse_proxy $(svc_name "$i"):$(node_field "$i" WS_BASE)"
        echo "    }"
        echo "    handle /$(node_field "$i" PATH_TROJAN) {"
        echo "        reverse_proxy $(svc_name "$i"):$(( $(node_field "$i" WS_BASE) + 1 ))"
        echo "    }"
        echo "    handle /$(node_field "$i" PATH_VMESS) {"
        echo "        reverse_proxy $(svc_name "$i"):$(( $(node_field "$i" WS_BASE) + 2 ))"
        echo "    }"
      done
      echo "    handle {"
      echo "        respond \"ok\" 200"
      echo "    }"
      echo "}"
      # 有节点直接用父域名本身（如 example.com）：再加一个父域名 site 块（同款 handle）
      local has_apex=0
      for i in $(node_indices); do
        [ "$(node_field "$i" DOMAIN)" = "$base" ] && has_apex=1
      done
      if [ "$has_apex" = "1" ]; then
        echo "${base}:${hp} {"
        echo "    tls {"
        echo "        dns cloudflare {env.CLOUDFLARE_API_TOKEN}"
        echo "    }"
        for i in $(node_indices); do
          [ "$(node_field "$i" TLS_MODE)" = "1" ] || continue
          echo "    handle /$(node_field "$i" PATH_VLESS) {"
          echo "        reverse_proxy $(svc_name "$i"):$(node_field "$i" WS_BASE)"
          echo "    }"
          echo "    handle /$(node_field "$i" PATH_TROJAN) {"
          echo "        reverse_proxy $(svc_name "$i"):$(( $(node_field "$i" WS_BASE) + 1 ))"
          echo "    }"
          echo "    handle /$(node_field "$i" PATH_VMESS) {"
          echo "        reverse_proxy $(svc_name "$i"):$(( $(node_field "$i" WS_BASE) + 2 ))"
          echo "    }"
        done
        echo "    handle {"
        echo "        respond \"ok\" 200"
        echo "    }"
        echo "}"
      fi
    } > Caddyfile
  else
    {
      for i in $(node_indices); do
        [ "$(node_field "$i" TLS_MODE)" = "1" ] || continue
        echo "$(node_field "$i" DOMAIN):${hp} {"
        echo "    handle /$(node_field "$i" PATH_VLESS) {"
        echo "        reverse_proxy $(svc_name "$i"):$(node_field "$i" WS_BASE)"
        echo "    }"
        echo "    handle /$(node_field "$i" PATH_TROJAN) {"
        echo "        reverse_proxy $(svc_name "$i"):$(( $(node_field "$i" WS_BASE) + 1 ))"
        echo "    }"
        echo "    handle /$(node_field "$i" PATH_VMESS) {"
        echo "        reverse_proxy $(svc_name "$i"):$(( $(node_field "$i" WS_BASE) + 2 ))"
        echo "    }"
        echo "    handle {"
        echo "        respond \"ok\" 200"
        echo "    }"
        echo "}"
      done
    } > Caddyfile
  fi
}

# ---------- 生成 docker-compose.yml（纯函数：只读注册表） ----------
gen_compose() {
  local i dom tls_mode cm cfg ctr hp has_tls=0
  for i in $(node_indices); do
    [ "$(node_field "$i" TLS_MODE)" = "1" ] && has_tls=1
  done
  {
    echo "services:"
    for i in $(node_indices); do
      cfg="$(node_field "$i" CONFIG)"
      ctr="$(node_field "$i" CONTAINER)"
      tls_mode="$(node_field "$i" TLS_MODE)"
      echo "  $(svc_name "$i"):"
      echo "    image: ghcr.io/sagernet/sing-box:latest"
      echo "    container_name: $ctr"
      echo "    restart: unless-stopped"
      echo "    command: run -c /etc/sing-box/config.json"
      echo "    volumes:"
      echo "      - ./$cfg:/etc/sing-box/config.json:ro"
      if [ "$tls_mode" = "1" ]; then
        echo "      - caddy_data:/caddy-data:ro"
        echo "    ports:"
        echo "      - \"$(node_field "$i" SS_PORT):$(node_field "$i" SS_PORT)\""
        echo "      - \"$(node_field "$i" SS_PORT):$(node_field "$i" SS_PORT)/udp\""
        if [ "$(node_field "$i" HY2_ENABLED)" = "1" ]; then
          echo "      - \"$(node_field "$i" HY2_PORT):$(node_field "$i" HY2_PORT)/udp\""
          echo "      - \"$(node_field "$i" TUIC_PORT):$(node_field "$i" TUIC_PORT)/udp\""
        fi
      else
        echo "    ports:"
        echo "      - \"$(node_field "$i" VLESS_PORT):$(node_field "$i" WS_BASE)\""
        echo "      - \"$(node_field "$i" TROJAN_PORT):$(( $(node_field "$i" WS_BASE) + 1 ))\""
        echo "      - \"$(node_field "$i" VMESS_PORT):$(( $(node_field "$i" WS_BASE) + 2 ))\""
        echo "      - \"$(node_field "$i" SS_PORT):$(node_field "$i" SS_PORT)\""
        echo "      - \"$(node_field "$i" SS_PORT):$(node_field "$i" SS_PORT)/udp\""
      fi
    done
    if [ "$has_tls" = "1" ]; then
      cm="$(reg_get GLOBAL_CERT_METHOD)"
      hp="$(reg_get GLOBAL_HTTPS_PORT)"
      echo "  caddy:"
      if [ "$cm" = "dns" ]; then
        echo "    image: caddy-cloudflare:latest"
      else
        echo "    image: caddy:2"
      fi
      echo "    container_name: singbox-caddy"
      echo "    restart: unless-stopped"
      if [ "$cm" = "dns" ]; then
        echo "    environment:"
        echo '      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}'
      fi
      echo "    ports:"
      if [ "$cm" != "dns" ]; then
        echo '      - "80:80"'
      fi
      echo "      - \"$hp:$hp\""
      echo "    volumes:"
      echo "      - ./Caddyfile:/etc/caddy/Caddyfile:ro"
      echo "      - caddy_data:/data"
      echo "      - caddy_config:/config"
      echo "volumes:"
      echo "  caddy_data:"
      echo "  caddy_config:"
    fi
  } > docker-compose.yml
  # DNS 验证模式要用的带插件 Caddy Dockerfile（现场编，只编一次）
  if [ "$has_tls" = "1" ] && [ "$(reg_get GLOBAL_CERT_METHOD)" = "dns" ]; then
    cat > Dockerfile.caddy <<'DCEOF'
# 带 Cloudflare DNS 插件的 Caddy：官方 caddy:2-builder 现场编，插件源码来自 github.com/caddy-dns/cloudflare
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare
FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
DCEOF
  fi
}

# ---------- 生成节点文件：clash.yaml + 各协议链接（只读注册表 + NODE_* 凭据已在注册表里） ----------
# 写完后设置全局变量：NODE_LINK_VLESS/TROJAN/VMESS/SS/HY2/TUIC、NODE_SUB（base64 订阅）
write_node_files() {
  local n="$1"
  local dom tls cm wsb pv pt pm uv um ut ptr pss phy ptu ss hp tu vp tp mp hy2en clash cfg server_ip
  dom="$(node_field "$n" DOMAIN)"; tls="$(node_field "$n" TLS_MODE)"; cm="$(node_field "$n" CERT_METHOD)"
  wsb="$(node_field "$n" WS_BASE)"; pv="$(node_field "$n" PATH_VLESS)"; pt="$(node_field "$n" PATH_TROJAN)"; pm="$(node_field "$n" PATH_VMESS)"
  uv="$(node_field "$n" UUID_VLESS)"; um="$(node_field "$n" UUID_VMESS)"; ut="$(node_field "$n" UUID_TUIC)"
  ptr="$(node_field "$n" PASS_TROJAN)"; pss="$(node_field "$n" PASS_SS)"; phy="$(node_field "$n" PASS_HY2)"; ptu="$(node_field "$n" PASS_TUIC)"
  ss="$(node_field "$n" SS_PORT)"; hp="$(node_field "$n" HY2_PORT)"; tu="$(node_field "$n" TUIC_PORT)"
  vp="$(node_field "$n" VLESS_PORT)"; tp="$(node_field "$n" TROJAN_PORT)"; mp="$(node_field "$n" VMESS_PORT)"
  hy2en="$(node_field "$n" HY2_ENABLED)"; clash="$(node_field "$n" CLASH)"
  server_ip="$(reg_get GLOBAL_SERVER_IP)"
  gen_singbox_json "$n"
  local https_port
  https_port="$(reg_get GLOBAL_HTTPS_PORT)"; [ -n "$https_port" ] || https_port=443

  local vless_port trojan_port vmess_port vless_tls trojan_tls vmess_tls srv
  if [ "$tls" = "1" ]; then
    vless_port="$https_port"; trojan_port="$https_port"; vmess_port="$https_port"
    vless_tls=true; trojan_tls=true; vmess_tls=true; srv="$dom"
  else
    vless_port="$vp"; trojan_port="$tp"; vmess_port="$mp"
    vless_tls=false; trojan_tls=false; vmess_tls=false; srv="$server_ip"
  fi

  cat > "$clash" <<EOF
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
    server: $srv
    port: $vless_port
    uuid: $uv
    tls: $vless_tls
    servername: $srv
    network: ws
    ws-opts:
      path: /$pv
      headers:
        Host: $srv
  - name: "SingBox-Trojan"
    type: trojan
    server: $srv
    port: $trojan_port
    password: $ptr
    sni: $srv
    network: ws
    ws-opts:
      path: /$pt
      headers:
        Host: $srv
  - name: "SingBox-VMess"
    type: vmess
    server: $srv
    port: $vmess_port
    uuid: $um
    alterId: 0
    cipher: auto
    tls: $vmess_tls
    servername: $srv
    network: ws
    ws-opts:
      path: /$pm
      headers:
        Host: $srv
  - name: "SingBox-SS"
    type: ss
    server: $srv
    port: $ss
    cipher: 2022-blake3-aes-128-gcm
    password: $pss
    udp: true
EOF
  if [ "$tls" = "1" ] && [ "$hy2en" = "1" ]; then
    cat >> "$clash" <<EOF
  - name: "SingBox-HY2"
    type: hysteria2
    server: $dom
    port: $hp
    password: $phy
    sni: $dom
    alpn:
      - h3
  - name: "SingBox-TUIC"
    type: tuic
    server: $dom
    port: $tu
    uuid: $ut
    password: $ptu
    congestion-controller: bbr
    alpn:
      - h3
    sni: $dom
EOF
  fi
  local proxy_list='      - "SingBox-VLESS"
      - "SingBox-Trojan"
      - "SingBox-VMess"
      - "SingBox-SS"'
  if [ "$tls" = "1" ] && [ "$hy2en" = "1" ]; then
    proxy_list="$proxy_list
      - \"SingBox-HY2\"
      - \"SingBox-TUIC\""
  fi
  cat >> "$clash" <<EOF
proxy-groups:
  - name: "PROXY"
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
$proxy_list
  - name: "MANUAL"
    type: select
    proxies:
$proxy_list
rules:
  - MATCH,PROXY
EOF

  # 各协议节点链接
  if [ "$tls" = "1" ]; then
    NODE_LINK_VLESS="vless://$uv@$dom:$https_port?encryption=none&security=tls&type=ws&host=$dom&path=%2F$pv#SingBox-VLESS"
    NODE_LINK_TROJAN="trojan://$ptr@$dom:$https_port?security=tls&type=ws&host=$dom&path=%2F$pt#SingBox-Trojan"
    local vmess_json="{\"v\":\"2\",\"ps\":\"SingBox-VMess\",\"add\":\"$dom\",\"port\":\"$https_port\",\"id\":\"$um\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$dom\",\"path\":\"/$pm\",\"tls\":\"tls\",\"sni\":\"$dom\"}"
  else
    NODE_LINK_VLESS="vless://$uv@$server_ip:$vp?encryption=none&security=none&type=ws&path=%2F$pv#SingBox-VLESS"
    NODE_LINK_TROJAN="trojan://$ptr@$server_ip:$tp?security=none&type=ws&path=%2F$pt#SingBox-Trojan"
    local vmess_json="{\"v\":\"2\",\"ps\":\"SingBox-VMess\",\"add\":\"$server_ip\",\"port\":\"$mp\",\"id\":\"$um\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$server_ip\",\"path\":\"/$pm\",\"tls\":\"\"}"
  fi
  NODE_LINK_VMESS="vmess://$(printf '%s' "$vmess_json" | base64 -w0)"
  local ss_userinfo
  ss_userinfo="$(printf '%s' "2022-blake3-aes-128-gcm:$pss" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
  NODE_LINK_SS="ss://$ss_userinfo@$srv:$ss#SingBox-SS"
  if [ "$tls" = "1" ] && [ "$hy2en" = "1" ]; then
    NODE_LINK_HY2="hysteria2://$phy@$dom:$hp?sni=$dom&alpn=h3#SingBox-HY2"
    NODE_LINK_TUIC="tuic://$ut:$ptu@$dom:$tu?congestion_control=bbr&alpn=h3&sni=$dom#SingBox-TUIC"
  else
    NODE_LINK_HY2=""; NODE_LINK_TUIC=""
  fi
  local sub_links="$NODE_LINK_VLESS
$NODE_LINK_TROJAN
$NODE_LINK_VMESS
$NODE_LINK_SS"
  if [ -n "$NODE_LINK_HY2" ]; then
    sub_links="$sub_links
$NODE_LINK_HY2
$NODE_LINK_TUIC"
  fi
  NODE_SUB="$(printf '%s' "$sub_links" | base64 -w0)"
}

# 二维码：qrencode 优先，没有就用 python qrcode 模块；都失败返回 1
make_qr() {  # make_qr 链接 文件名
  local link="$1" file="$2"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -o "$file" -s 8 "$link" 2>/dev/null && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$link" "$file" <<'PY' 2>/dev/null
import sys
try:
    import qrcode
except ImportError:
    sys.exit(1)
qrcode.make(sys.argv[1]).save(sys.argv[2])
PY
    return $?
  fi
  return 1
}

# Caddy reload（不断已有节点连接）；reload 失败就重启 Caddy 容器，再不行就起一个
caddy_reload() {
  if docker exec singbox-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null; then
    echo "Caddy 已 reload（已有节点不断连）"
    return 0
  fi
  echo "Caddy reload 失败，尝试重启 Caddy 容器..."
  docker compose restart caddy 2>/dev/null || docker compose up -d caddy
}

# WS 握手拨测：test_node_ws 协议 主机 端口 路径
test_node_ws() {
  local proto="$1" host="$2" port="$3" path="$4" code=""
  code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" "$proto://$host:$port/$path" || true)"
  echo "WS 握手 $proto://$host:$port/$path -> HTTP ${code:-无响应}（101 = 正常；200 = Caddy 没转给 sing-box，跑 docker compose down && docker compose up -d 重建；400 = sing-box 拒绝握手）"
}

# ---------- 部署单个节点 ----------
# 调用前先设好 NODE_* 全局变量（编号 N、域名、模式、端口、凭据、文件与容器名），
# 本函数负责：写注册表 -> 生成全部配置文件 -> 写首节点 .env -> 起容器 -> 拨测 -> 二维码 -> 打印结果
# mode=fresh（首装/重跑换节点 1）或 add（追加）
deploy_node() {
  local mode="$1"
  local n="$N"
  echo "== 部署节点 $n（${NODE_DOMAIN:-明文}） =="
  # 注册（存在则整行重写，不存在则追加；追加的节点不碰已有节点记录）
  reg_set "NODE_${n}_DOMAIN" "$NODE_DOMAIN"
  reg_set "NODE_${n}_TLS_MODE" "$NODE_TLS_MODE"
  reg_set "NODE_${n}_CERT_METHOD" "$NODE_CERT_METHOD"
  reg_set "NODE_${n}_WS_BASE" "$NODE_WS_BASE"
  reg_set "NODE_${n}_PATH_VLESS" "$NODE_PATH_VLESS"
  reg_set "NODE_${n}_PATH_TROJAN" "$NODE_PATH_TROJAN"
  reg_set "NODE_${n}_PATH_VMESS" "$NODE_PATH_VMESS"
  reg_set "NODE_${n}_UUID_VLESS" "$NODE_UUID_VLESS"
  reg_set "NODE_${n}_UUID_VMESS" "$NODE_UUID_VMESS"
  reg_set "NODE_${n}_UUID_TUIC" "$NODE_UUID_TUIC"
  reg_set "NODE_${n}_PASS_TROJAN" "$NODE_PASS_TROJAN"
  reg_set "NODE_${n}_PASS_SS" "$NODE_PASS_SS"
  reg_set "NODE_${n}_PASS_HY2" "$NODE_PASS_HY2"
  reg_set "NODE_${n}_PASS_TUIC" "$NODE_PASS_TUIC"
  reg_set "NODE_${n}_SS_PORT" "$NODE_SS_PORT"
  reg_set "NODE_${n}_HY2_PORT" "$NODE_HY2_PORT"
  reg_set "NODE_${n}_TUIC_PORT" "$NODE_TUIC_PORT"
  reg_set "NODE_${n}_VLESS_PORT" "$NODE_VLESS_PORT"
  reg_set "NODE_${n}_TROJAN_PORT" "$NODE_TROJAN_PORT"
  reg_set "NODE_${n}_VMESS_PORT" "$NODE_VMESS_PORT"
  reg_set "NODE_${n}_HY2_ENABLED" "$NODE_HY2_ENABLED"
  reg_set "NODE_${n}_CONTAINER" "$NODE_CONTAINER"
  reg_set "NODE_${n}_CONFIG" "$NODE_CONFIG"
  reg_set "NODE_${n}_CLASH" "$NODE_CLASH"
  chmod 600 "$REG_FILE"
  write_node_files "$n"
  gen_caddyfile
  gen_compose
  if [ "$mode" = "fresh" ] && [ "$n" = "1" ]; then
    # 首节点安装记录（.env）：域名、模式、证书方式与最终端口（check.sh / stop.sh 从这里读实际端口与方式）
    # .env 里有 Cloudflare API 令牌时只限本机 root 读（600），绝不在输出里打印
    {
      echo "DOMAIN=$DOMAIN"
      echo "SERVER_IP=$SERVER_IP"
      echo "TLS_MODE=$TLS_MODE"
      echo "CERT_METHOD=${CERT_METHOD:-}"
      if [ "$TLS_MODE" = "1" ] && [ "$CERT_METHOD" = "dns" ]; then
        echo "CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN"
      fi
      echo "HTTPS_PORT=$HTTPS_PORT"
      echo "SS_PORT=$SS_PORT"
      echo "HY2_PORT=$HY2_PORT"
      echo "TUIC_PORT=$TUIC_PORT"
      echo "VLESS_PORT=$VLESS_PORT"
      echo "TROJAN_PORT=$TROJAN_PORT"
      echo "VMESS_PORT=$VMESS_PORT"
    } > .env
    chmod 600 .env
  fi
  if [ "$DRY_RUN" != "1" ]; then
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
      if [ "$NODE_TLS_MODE" = "1" ]; then
        if [ "$NODE_CERT_METHOD" = "http" ]; then ufw allow 80/tcp >/dev/null; fi
        ufw allow "$NODE_HTTPS_PORT"/tcp >/dev/null
        ufw allow "$NODE_SS_PORT"/tcp >/dev/null; ufw allow "$NODE_SS_PORT"/udp >/dev/null
        if [ "$NODE_HY2_ENABLED" = "1" ]; then ufw allow "$NODE_HY2_PORT"/udp >/dev/null; ufw allow "$NODE_TUIC_PORT"/udp >/dev/null; fi
      else
        ufw allow "$NODE_VLESS_PORT"/tcp >/dev/null; ufw allow "$NODE_TROJAN_PORT"/tcp >/dev/null; ufw allow "$NODE_VMESS_PORT"/tcp >/dev/null
        ufw allow "$NODE_SS_PORT"/tcp >/dev/null; ufw allow "$NODE_SS_PORT"/udp >/dev/null
      fi
      echo "ufw 已放行对应端口"
    fi
    # DNS 验证模式：先编带 Cloudflare 插件的 Caddy（官方 builder 镜像现场编，只编一次；已有镜像就跳过）
    if [ "$NODE_TLS_MODE" = "1" ] && [ "$NODE_CERT_METHOD" = "dns" ]; then
      if docker image inspect caddy-cloudflare:latest >/dev/null 2>&1; then
        echo "已找到本地 caddy-cloudflare 镜像，跳过编译"
      else
        echo "正在编译带 Cloudflare 插件的 Caddy（官方 builder 镜像现场编，第一次约 1-3 分钟）..."
        docker build -t caddy-cloudflare:latest -f Dockerfile.caddy . || { echo "Caddy 编译失败：检查本机能否访问 Docker Hub 与 proxy.golang.org，或稍后重跑"; exit 1; }
        echo "Caddy 编译完成：caddy-cloudflare:latest"
      fi
    fi
    # 先起 Caddy（新 Caddyfile 生效，HY2/TUIC 要用 Caddy 签下的证书）；已有其他节点时只 reload，不重建
    if [ "$NODE_TLS_MODE" = "1" ]; then
      if [ "$mode" = "fresh" ]; then
        docker compose up -d caddy
        caddy_reload
      else
        caddy_reload
      fi
      # 等证书（最多 180 秒）：HTTP-01 等本节点域名的证书；DNS-01 等泛域名证书
      local cert_file=""
      if [ "$NODE_CERT_METHOD" = "dns" ]; then
        cert_file="/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/*.$(reg_get GLOBAL_BASE_DOMAIN)/*.$(reg_get GLOBAL_BASE_DOMAIN).crt"
      else
        cert_file="/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$NODE_DOMAIN/$NODE_DOMAIN.crt"
      fi
      echo "等 Caddy 签证书（最多 180 秒）..."
      local cert_ok=0
      for i in $(seq 1 36); do
        if docker exec singbox-caddy test -f "$cert_file" 2>/dev/null; then cert_ok=1; break; fi
        sleep 5
      done
      if [ "$cert_ok" = "1" ]; then
        echo "证书已就绪，HY2/TUIC 启用"
      else
        echo "警告：180 秒内没拿到证书，HY2/TUIC 暂不启用（VLESS/Trojan/VMess/SS 不受影响）；重跑一次本命令可补上（会换一套新节点）"
        NODE_HY2_ENABLED=0
        reg_set "NODE_${n}_HY2_ENABLED" "0"
        gen_singbox_json "$n"
        gen_compose
      fi
    fi
    # 只起/重建本节点服务（已有其他节点时不碰它们的容器）
    if [ "$mode" = "fresh" ]; then
      docker compose up -d --force-recreate "$(svc_name "$n")"
    else
      docker compose up -d "$(svc_name "$n")"
    fi
    sleep 3
    if [ "$NODE_TLS_MODE" = "1" ]; then
      local code=""
      for i in $(seq 1 30); do
        code=$(curl -s -o /dev/null -w "%{http_code}" "https://$NODE_DOMAIN:$NODE_HTTPS_PORT/" || true)
        [ "$code" = "200" ] && break
        sleep 3
      done
      echo "首页 https://$NODE_DOMAIN:$NODE_HTTPS_PORT/ -> HTTP ${code:-无响应}（200 = Caddy 与证书正常）"
      test_node_ws "https" "$NODE_DOMAIN" "$NODE_HTTPS_PORT" "$NODE_PATH_VLESS"
      test_node_ws "https" "$NODE_DOMAIN" "$NODE_HTTPS_PORT" "$NODE_PATH_TROJAN"
      test_node_ws "https" "$NODE_DOMAIN" "$NODE_HTTPS_PORT" "$NODE_PATH_VMESS"
      echo "SS $NODE_SS_PORT / HY2 $NODE_HY2_PORT / TUIC $NODE_TUIC_PORT 需用客户端实测（非 HTTP 端口，curl 测不了）"
    else
      test_node_ws "http" "$NODE_SERVER_IP" "$NODE_VLESS_PORT" "$NODE_PATH_VLESS"
      test_node_ws "http" "$NODE_SERVER_IP" "$NODE_TROJAN_PORT" "$NODE_PATH_TROJAN"
      test_node_ws "http" "$NODE_SERVER_IP" "$NODE_VMESS_PORT" "$NODE_PATH_VMESS"
    fi
  else
    echo "[dry-run] 跳过启动与拨测"
  fi
  # 二维码（qrencode 没有时尝试安装；实在没有就提示手动生成）
  local qr_ok=0 qr_prefix=""
  if [ "$n" = "1" ]; then qr_prefix="qr-"; else qr_prefix="qr-$n-"; fi
  if ! command -v qrencode >/dev/null 2>&1 && [ "$DRY_RUN" != "1" ]; then
    echo "本机没有 qrencode，尝试安装..."
    if command -v apt-get >/dev/null 2>&1; then
      timeout 180 apt-get update -qq >/dev/null 2>&1 || true
      timeout 180 apt-get install -y -qq qrencode >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      timeout 180 yum install -y -q qrencode >/dev/null 2>&1 || true
    fi
  fi
  if make_qr "$NODE_LINK_VLESS" "${qr_prefix}vless.png" && make_qr "$NODE_LINK_TROJAN" "${qr_prefix}trojan.png" && make_qr "$NODE_LINK_VMESS" "${qr_prefix}vmess.png" && make_qr "$NODE_LINK_SS" "${qr_prefix}ss.png"; then
    qr_ok=1
    if [ -n "$NODE_LINK_HY2" ]; then
      make_qr "$NODE_LINK_HY2" "${qr_prefix}hy2.png" && make_qr "$NODE_LINK_TUIC" "${qr_prefix}tuic.png" || qr_ok=0
    fi
  fi
  echo ""
  if [ "$mode" = "fresh" ]; then
    echo "================ 部署完成 ================"
  else
    echo "================ 追加完成 ================"
  fi
  if [ "$NODE_TLS_MODE" = "1" ]; then
    if [ "$NODE_CERT_METHOD" = "dns" ]; then
      echo "证书方式：DNS 验证（Cloudflare），泛域名证书 *.$(reg_get GLOBAL_BASE_DOMAIN)，续签全自动，不用管 80 端口"
    else
      echo "证书方式：默认走 80（HTTP-01）；证书剩余天数用 bash check.sh 看"
    fi
  fi
  echo "节点链接（小火箭/Clash 可直接导入）："
  echo "VLESS:  $NODE_LINK_VLESS"
  echo "Trojan: $NODE_LINK_TROJAN"
  echo "VMess:  $NODE_LINK_VMESS"
  echo "SS:     $NODE_LINK_SS"
  if [ -n "$NODE_LINK_HY2" ]; then
    echo "HY2:    $NODE_LINK_HY2"
    echo "TUIC:   $NODE_LINK_TUIC"
  fi
  echo ""
  echo "订阅内容（base64，含全部可用协议）："
  echo "$NODE_SUB"
  echo ""
  echo "Clash 配置已生成：$(pwd)/$(node_field "$n" CLASH)（DNS 全走代理、禁 IPv6，直接导入 Clash/Stash）"
  if [ "$qr_ok" = "1" ]; then
    echo "二维码已生成：$(pwd)/${qr_prefix}vless.png ${qr_prefix}trojan.png ${qr_prefix}vmess.png ${qr_prefix}ss.png（TLS 模式另有 ${qr_prefix}hy2.png ${qr_prefix}tuic.png），下载到手机扫码即可"
  else
    echo "本机没生成二维码：把上面的节点链接发给 Muse，它会回你二维码图片。"
  fi
  echo ""
  echo "注意：链接里的 UUID/密码等同于密码，不要外传。"
}

# 追加节点问端口：ask_port + 已占端口重问（与已有节点端口重复时 ask_port 内部已重问；主机被占时这里重问）
ask_node_port() {
  local varname="$1" prompt_line="$2" default="$3" used="${4:-}"
  while :; do
    ask_port "$varname" "$prompt_line" "$default" "$used"
    if [ "$DRY_RUN" != "1" ] && port_in_use_any "${!varname}"; then
      echo "端口 ${!varname} 已被占用："
      show_port_owner "${!varname}"
      echo "请换一个端口。"
      printf -v "$varname" '%s' ""
      continue
    fi
    break
  done
}

# ---------- 追加节点 ----------
add_node_flow() {
  migrate_legacy || true
  if [ ! -f "$REG_FILE" ]; then
    echo "还没装过节点：请先跑 bash install.sh 装第一个节点，再用 --add-node 追加。"
    exit 1
  fi
  local g_tls g_cm g_hp g_ip g_base
  g_tls="$(reg_get GLOBAL_TLS_MODE)"; [ -n "$g_tls" ] || g_tls=1
  g_cm="$(reg_get GLOBAL_CERT_METHOD)"; [ -n "$g_cm" ] || g_cm=http
  g_hp="$(reg_get GLOBAL_HTTPS_PORT)"; [ -n "$g_hp" ] || g_hp=443
  g_ip="$(reg_get GLOBAL_SERVER_IP)"
  g_base="$(reg_get GLOBAL_BASE_DOMAIN)"
  # 清掉上一个节点残留的 NODE_* 端口变量：ask_port 会把已设置的同名变量当环境变量预设，
  # 同一进程内装完首节点再追问追加时，节点 1 的端口会误当成新节点的预设而报错退出
  unset NODE_SS_PORT NODE_HY2_PORT NODE_TUIC_PORT NODE_VLESS_PORT NODE_TROJAN_PORT NODE_VMESS_PORT
  N="$(next_index)"
  NODE_TLS_MODE="$g_tls"; NODE_CERT_METHOD="$g_cm"; NODE_HTTPS_PORT="$g_hp"; NODE_SERVER_IP="$g_ip"
  NODE_HY2_ENABLED=1
  NODE_WS_BASE=$((10000 + (N - 1) * 10))

  if [ "$g_tls" = "1" ]; then
    if [ "$g_cm" = "dns" ]; then
      echo "== 追加节点 $N（TLS 模式，证书方式沿用首次安装的选择：DNS 验证（Cloudflare），泛域名证书 *.${g_base} 通吃所有子域名） =="
    else
      echo "== 追加节点 $N（TLS 模式，证书方式沿用首次安装的选择：默认走 80（HTTP-01），Caddy 逐个子域名自动签） =="
    fi
    echo "每个节点一个子域名；推荐先在 DNS 加一条泛域名 A 记录：*.${g_base} -> 落地机 IP，一次配好，以后加节点不用再改 DNS。"
    local sugg="us${N}.${g_base}"
    local new_domain="${MODE_ARG:-}"
    while :; do
      if [ -z "$new_domain" ]; then
        echo "请填写新节点的子域名："
        read_line new_domain "新节点域名（默认 $sugg，直接回车就是 $sugg）： "
        [ -z "$new_domain" ] && new_domain="$sugg"
      fi
      if ! valid_domain "$new_domain"; then echo "域名不合法：$new_domain（要是小写字母/数字/点/连字符，至少一个点），请重新输入。"; new_domain=""; continue; fi
      if find_node_by_domain "$new_domain" >/dev/null 2>&1; then echo "域名 $new_domain 已经被节点占用了，请换一个子域名。"; new_domain=""; continue; fi
      if [ "$g_cm" = "dns" ]; then
        case "$new_domain" in
          "$g_base"|*".$g_base") ;;
          *) echo "DNS 验证模式下新节点域名必须是泛域名证书覆盖的范围（$g_base 或它下面的子域名），$new_domain 不在范围内，请换一个。"; new_domain=""; continue ;;
        esac
      fi
      break
    done
    NODE_DOMAIN="$new_domain"
  else
    echo "== 追加节点 $N（明文模式，不用域名，各节点用不同 WS 端口） =="
    NODE_DOMAIN=""
  fi

  # 已有节点占用的直连端口（追加时新端口不能撞）
  local used_ports="" i
  for i in $(node_indices); do
    used_ports="$used_ports $(node_field "$i" SS_PORT) $(node_field "$i" HY2_PORT) $(node_field "$i" TUIC_PORT) $(node_field "$i" VLESS_PORT) $(node_field "$i" TROJAN_PORT) $(node_field "$i" VMESS_PORT)"
  done
  local prev=$((N - 1))
  if [ "$g_tls" = "1" ]; then
    echo "直连端口默认在前一节点端口上加 10000（SS/HY2/TUIC 各节点必须不同）；直接回车就是默认值。"
    ask_node_port NODE_SS_PORT "请填写新节点 Shadowsocks 端口：" "$(( $(node_field "$prev" SS_PORT) + 10000 ))" "$used_ports"
    used_ports="$used_ports $NODE_SS_PORT"
    ask_node_port NODE_HY2_PORT "请填写新节点 Hysteria2 端口：" "$(( $(node_field "$prev" HY2_PORT) + 10000 ))" "$used_ports"
    used_ports="$used_ports $NODE_HY2_PORT"
    ask_node_port NODE_TUIC_PORT "请填写新节点 TUIC 端口：" "$(( $(node_field "$prev" TUIC_PORT) + 10000 ))" "$used_ports"
    used_ports="$used_ports $NODE_TUIC_PORT"
    NODE_VLESS_PORT="$g_hp"; NODE_TROJAN_PORT="$g_hp"; NODE_VMESS_PORT="$g_hp"
  else
    echo "明文端口默认在前一节点端口上加 10000（各节点必须不同）；直接回车就是默认值。"
    ask_node_port NODE_VLESS_PORT "请填写新节点 VLESS 端口：" "$(( $(node_field "$prev" VLESS_PORT) + 10000 ))" "$used_ports"
    used_ports="$used_ports $NODE_VLESS_PORT"
    ask_node_port NODE_TROJAN_PORT "请填写新节点 Trojan 端口：" "$(( $(node_field "$prev" TROJAN_PORT) + 10000 ))" "$used_ports"
    used_ports="$used_ports $NODE_TROJAN_PORT"
    ask_node_port NODE_VMESS_PORT "请填写新节点 VMess 端口：" "$(( $(node_field "$prev" VMESS_PORT) + 10000 ))" "$used_ports"
    used_ports="$used_ports $NODE_VMESS_PORT"
    ask_node_port NODE_SS_PORT "请填写新节点 Shadowsocks 端口：" "$(( $(node_field "$prev" SS_PORT) + 10000 ))" "$used_ports"
    used_ports="$used_ports $NODE_SS_PORT"
    NODE_HY2_PORT="$(( $(node_field "$prev" HY2_PORT) + 10000 ))"; NODE_TUIC_PORT="$(( $(node_field "$prev" TUIC_PORT) + 10000 ))"
  fi
  # 最终预检（覆盖环境变量预设的端口）
  TLS_MODE="$g_tls"; HTTPS_PORT="$g_hp"; SS_PORT="$NODE_SS_PORT"; HY2_PORT="$NODE_HY2_PORT"; TUIC_PORT="$NODE_TUIC_PORT"
  VLESS_PORT="$NODE_VLESS_PORT"; TROJAN_PORT="$NODE_TROJAN_PORT"; VMESS_PORT="$NODE_VMESS_PORT"
  CERT_METHOD="$g_cm"
  check_ports_add

  # 凭据（每次追加都生成全新一套，不碰已有节点）
  NODE_UUID_VLESS="$(cat /proc/sys/kernel/random/uuid)"
  NODE_UUID_VMESS="$(cat /proc/sys/kernel/random/uuid)"
  NODE_UUID_TUIC="$(cat /proc/sys/kernel/random/uuid)"
  NODE_PASS_TROJAN="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
  NODE_PASS_SS="$(head -c 16 /dev/urandom | base64 -w0)" # 2022-blake3 密码必须是 base64 编码的 16 字节密钥
  NODE_PASS_HY2="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
  NODE_PASS_TUIC="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
  NODE_PATH_VLESS="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
  NODE_PATH_TROJAN="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
  NODE_PATH_VMESS="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
  if [ "$N" = "1" ]; then
    NODE_CONFIG="sing-box.json"; NODE_CONTAINER="singbox-node"; NODE_CLASH="clash.yaml"
  else
    NODE_CONFIG="sing-box-$N.json"; NODE_CONTAINER="singbox-node-$N"; NODE_CLASH="clash-$N.yaml"
  fi
  echo "新节点凭据已生成（UUID 与 WS 路径全新，与已有节点不同）。"
  deploy_node add
  if [ "$DRY_RUN" != "1" ]; then
    echo ""
    bash check.sh || true
  fi
}

# ---------- 删除单个节点 ----------
del_node_flow() {
  migrate_legacy || true
  if [ ! -f "$REG_FILE" ] || [ "$(node_count)" = "0" ]; then
    echo "没有可删除的节点（还没装过节点，或 nodes.conf 不在）。"
    exit 1
  fi
  echo "== 删除单个节点（其他节点不受影响） =="
  echo "当前节点："
  local i
  for i in $(node_indices); do
    local d t
    d="$(node_field "$i" DOMAIN)"; t="$(node_field "$i" TLS_MODE)"
    if [ "$t" = "1" ]; then
      echo "  [$i] $d（TLS，SS $(node_field "$i" SS_PORT) / HY2 $(node_field "$i" HY2_PORT) / TUIC $(node_field "$i" TUIC_PORT)，容器 $(node_field "$i" CONTAINER)）"
    else
      echo "  [$i] 明文（VLESS $(node_field "$i" VLESS_PORT) / Trojan $(node_field "$i" TROJAN_PORT) / VMess $(node_field "$i" VMESS_PORT) / SS $(node_field "$i" SS_PORT)，容器 $(node_field "$i" CONTAINER)）"
    fi
  done
  local pick="${MODE_ARG:-}" target=""
  if [ -n "$pick" ]; then
    if valid_domain "$pick"; then
      target="$(find_node_by_domain "$pick" || true)"
      [ -z "$target" ] && { echo "找不到域名为 $pick 的节点。"; exit 1; }
    elif valid_port "$pick"; then
      target="$pick"
      [ -z "$(node_field "$target" DOMAIN)" ] && [ "$(node_field "$target" TLS_MODE)" != "0" ] && [ -z "$(node_field "$target" CONTAINER)" ] && { echo "找不到编号为 $pick 的节点。"; exit 1; }
    else
      echo "参数 $pick 既不是域名也不是节点编号。"; exit 1
    fi
  else
    echo "请选择要删除的节点编号："
    read_line pick "节点编号： "
    target="$pick"
    if ! valid_port "$target" || { [ -z "$(node_field "$target" DOMAIN)" ] && [ "$(node_field "$target" TLS_MODE)" != "0" ] && [ -z "$(node_field "$target" CONTAINER)" ]; }; then
      echo "编号 $target 没有对应节点。"; exit 1
    fi
  fi
  local d_dom d_tls d_uuid d_cfg d_clash d_ctr
  d_dom="$(node_field "$target" DOMAIN)"; d_tls="$(node_field "$target" TLS_MODE)"
  d_uuid="$(node_field "$target" UUID_VLESS)"; d_cfg="$(node_field "$target" CONFIG)"
  d_clash="$(node_field "$target" CLASH)"; d_ctr="$(node_field "$target" CONTAINER)"
  echo ""
  echo "将删除节点 $target，信息如下（请留底）："
  if [ "$d_tls" = "1" ]; then
    echo "  域名：$d_dom"
  else
    echo "  模式：明文（无域名）"
  fi
  echo "  VLESS UUID：$d_uuid"
  if [ "$d_tls" = "1" ]; then
    echo "  端口：SS $(node_field "$target" SS_PORT) / HY2 $(node_field "$target" HY2_PORT) / TUIC $(node_field "$target" TUIC_PORT)"
  else
    echo "  端口：VLESS $(node_field "$target" VLESS_PORT) / Trojan $(node_field "$target" TROJAN_PORT) / VMess $(node_field "$target" VMESS_PORT) / SS $(node_field "$target" SS_PORT)"
  fi
  echo "  容器：$d_ctr"
  echo "  配置：$d_cfg、$d_clash"
  echo "删除后该节点的链接立即失效，其他节点不受影响。"
  local confirm=""
  read_line confirm "确定删除节点 $target？[y/N，默认 N]： "
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "已取消，未删除任何节点。"
    exit 0
  fi
  echo ""
  echo "正在删除节点 $target..."
  if [ "$DRY_RUN" != "1" ]; then
    docker rm -f "$d_ctr" >/dev/null 2>&1 || true
    echo "  已删除容器 $d_ctr"
  else
    echo "  [dry-run] 跳过删除容器 $d_ctr"
  fi
  rm -f "$d_cfg" "$d_clash" "qr-${target}-vless.png" "qr-${target}-trojan.png" "qr-${target}-vmess.png" "qr-${target}-ss.png" "qr-${target}-hy2.png" "qr-${target}-tuic.png" 2>/dev/null
  if [ "$target" = "1" ]; then
    rm -f qr-vless.png qr-trojan.png qr-vmess.png qr-ss.png qr-hy2.png qr-tuic.png 2>/dev/null
  fi
  echo "  已删除配置文件 $d_cfg、$d_clash 与二维码"
  grep -v "^NODE_${target}_" "$REG_FILE" > "$REG_FILE.tmp" || true
  mv "$REG_FILE.tmp" "$REG_FILE"
  echo "  已删除节点记录"
  if [ "$(node_count)" = "0" ]; then
    echo ""
    echo "已删完最后一个节点。"
    if [ "$DRY_RUN" != "1" ]; then
      docker rm -f singbox-caddy >/dev/null 2>&1 || true
    fi
    rm -f Caddyfile docker-compose.yml nodes.conf .env
    echo "Caddyfile、docker-compose.yml、nodes.conf、.env 已清理。彻底清理残留请跑 bash stop.sh --remove。"
    echo ""
    echo "已删除节点 $target：${d_dom:-明文}，VLESS UUID $d_uuid"
    exit 0
  fi
  gen_caddyfile
  gen_compose
  echo "  Caddyfile 与 docker-compose.yml 已更新（去掉节点 $target 的配置段）"
  if [ "$DRY_RUN" != "1" ]; then
    # 还有 TLS 节点就 reload 新 Caddyfile；一个 TLS 节点都没了就停掉 Caddy（否则它还用旧配置对外服务）
    _any_tls=0
    for _i2 in $(node_indices); do [ "$(node_field "$_i2" TLS_MODE)" = "1" ] && _any_tls=1; done
    if [ "$_any_tls" = "1" ]; then
      caddy_reload
    else
      docker rm -f singbox-caddy >/dev/null 2>&1 || true
    fi
    docker compose up -d >/dev/null 2>&1 || true
  else
    echo "  [dry-run] 跳过 reload Caddy"
  fi
  # 逐个核查剩余节点仍正常
  echo ""
  echo "核查剩余节点："
  local ok=1 i2 r_dom r_tls r_cfg
  for i2 in $(node_indices); do
    r_dom="$(node_field "$i2" DOMAIN)"; r_tls="$(node_field "$i2" TLS_MODE)"; r_cfg="$(node_field "$i2" CONFIG)"
    if [ "$DRY_RUN" = "1" ]; then
      if [ -f "$r_cfg" ] && { [ "$r_tls" = "0" ] || grep -q "$(node_field "$i2" PATH_VLESS)" Caddyfile 2>/dev/null; }; then
        echo "  [通过] 节点 $i2（${r_dom:-明文}）：配置文件与 Caddyfile 正常"
      else
        echo "  [风险] 节点 $i2（${r_dom:-明文}）：配置文件或 Caddyfile 异常"
        ok=0
      fi
      continue
    fi
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$(node_field "$i2" CONTAINER)"; then
      echo "  [风险] 节点 $i2（${r_dom:-明文}）：容器 $(node_field "$i2" CONTAINER) 不在运行"
      ok=0
      continue
    fi
    if [ "$r_tls" = "1" ]; then
      test_node_ws "https" "$r_dom" "$(reg_get GLOBAL_HTTPS_PORT)" "$(node_field "$i2" PATH_VLESS)"
    else
      test_node_ws "http" "$(reg_get GLOBAL_SERVER_IP)" "$(node_field "$i2" VLESS_PORT)" "$(node_field "$i2" PATH_VLESS)"
    fi
  done
  echo ""
  if [ "$ok" = "1" ]; then
    echo "删除完成，剩余节点核查正常。"
  else
    echo "删除完成，但剩余节点核查有风险（见上面），请跑 bash check.sh 再看一次。"
  fi
  echo "已删除节点 $target：${d_dom:-明文}，VLESS UUID $d_uuid"
}

# ---------- 装完追问：还要再加一个节点吗 ----------
ask_add_more() {
  local ans=""
  while :; do
    echo ""
    read_line ans "还要再加一个节点吗？[y/N，默认 N]： "
    case "$ans" in
      y|Y|yes) MODE_ARG=""; add_node_flow ;;
      *) break ;;
    esac
  done
}

# ================= 主流程 =================
if [ "$MODE" = "add" ]; then
  add_node_flow
  exit 0
fi
if [ "$MODE" = "del" ]; then
  del_node_flow
  exit 0
fi

# ---- fresh：首装 / 重跑换节点 1（已追加的节点不受影响） ----
DOMAIN="${DOMAIN:-}"
SERVER_IP="${SERVER_IP:-}"

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
# 证书方式与令牌也可用环境变量预设（CERT_METHOD / CLOUDFLARE_API_TOKEN），优先级：环境变量 > .env > 交互输入
ENV_CERT_METHOD="${CERT_METHOD:-}"
ENV_CF_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
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
  TLS_MODE=1
  echo "域名：$DOMAIN（TLS 模式，全部 6 个协议）"
fi

# 证书签发方式（TLS 模式才问）：环境变量 CERT_METHOD > .env > 交互输入（直接回车默认 1）
if [ "$TLS_MODE" = "1" ]; then
  CERT_METHOD="${ENV_CERT_METHOD:-${CERT_METHOD:-}}"
  case "$CERT_METHOD" in
    1|http) CERT_METHOD="http" ;;
    2|dns) CERT_METHOD="dns" ;;
    "")
      if [ "$DRY_RUN" != "1" ]; then
        ask_cert_method
      else
        CERT_METHOD="http"
      fi
      ;;
    *) echo "CERT_METHOD=$CERT_METHOD 不合法（只能是 1/http 或 2/dns），请修正后重跑。"; exit 1 ;;
  esac
  if [ "$CERT_METHOD" = "dns" ]; then echo "证书方式：DNS 验证（Cloudflare）"; else echo "证书方式：默认走 80（HTTP-01）"; fi
  # DNS 验证要 Cloudflare API 令牌：环境变量 CLOUDFLARE_API_TOKEN > .env > 交互输入
  # 令牌只存进 .env，绝不在输出里打印；输入时不回显
  CLOUDFLARE_API_TOKEN="${ENV_CF_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
  if [ "$CERT_METHOD" = "dns" ] && [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    if [ "$DRY_RUN" != "1" ]; then
      ask_cf_token
    else
      echo "[dry-run] DNS 验证模式：未预设 CLOUDFLARE_API_TOKEN，.env 里令牌为空（实装时会问）"
    fi
  fi
fi

# 公开端口：默认即当前端口，直接回车就行；默认端口被占时可改高位端口避开
echo ""
echo "== 3/8 公开端口（可自定义） =="
if [ "$TLS_MODE" = "1" ]; then
  echo "TLS 模式：HTTPS 端口默认 443，SS 默认 8388，HY2 默认 8443，TUIC 默认 8444。"
  if [ "$CERT_METHOD" = "dns" ]; then
    echo "证书方式：DNS 验证（Cloudflare），80 端口不用空闲。"
  else
    echo "80 端口必须空闲（Caddy 签证书走 HTTP-01 验证必须用 80），改不了。"
  fi
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
N=1
NODE_DOMAIN="$DOMAIN"
NODE_TLS_MODE="$TLS_MODE"
NODE_CERT_METHOD="${CERT_METHOD:-http}"
NODE_HTTPS_PORT="$HTTPS_PORT"
NODE_SERVER_IP="$SERVER_IP"
NODE_WS_BASE=10000
NODE_UUID_VLESS="$(cat /proc/sys/kernel/random/uuid)"
NODE_UUID_VMESS="$(cat /proc/sys/kernel/random/uuid)"
NODE_UUID_TUIC="$(cat /proc/sys/kernel/random/uuid)"
NODE_PASS_TROJAN="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
NODE_PASS_SS="$(head -c 16 /dev/urandom | base64 -w0)" # 2022-blake3 密码必须是 base64 编码的 16 字节密钥
NODE_PASS_HY2="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
NODE_PASS_TUIC="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
NODE_PATH_VLESS="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
NODE_PATH_TROJAN="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
NODE_PATH_VMESS="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16 || true)"
NODE_SS_PORT="$SS_PORT"; NODE_HY2_PORT="$HY2_PORT"; NODE_TUIC_PORT="$TUIC_PORT"
NODE_VLESS_PORT="$VLESS_PORT"; NODE_TROJAN_PORT="$TROJAN_PORT"; NODE_VMESS_PORT="$VMESS_PORT"
NODE_HY2_ENABLED="$HY2_ENABLED"
NODE_CONFIG="sing-box.json"; NODE_CONTAINER="singbox-node"; NODE_CLASH="clash.yaml"
echo "VLESS UUID: $NODE_UUID_VLESS"
echo "VMess UUID: $NODE_UUID_VMESS"
echo "WS 路径: /$NODE_PATH_VLESS /$NODE_PATH_TROJAN /$NODE_PATH_VMESS"

# 全局设置（追加节点沿用）：证书方式、HTTPS 端口、服务器 IP、泛域名父域名
reg_set "GLOBAL_TLS_MODE" "$TLS_MODE"
reg_set "GLOBAL_CERT_METHOD" "${CERT_METHOD:-http}"
reg_set "GLOBAL_HTTPS_PORT" "$HTTPS_PORT"
reg_set "GLOBAL_SERVER_IP" "$SERVER_IP"
if [ "$TLS_MODE" = "1" ]; then
  reg_set "GLOBAL_BASE_DOMAIN" "$(base_domain "$DOMAIN")"
fi

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
deploy_node fresh

echo ""
echo "下一步：运行 bash check.sh 做泄漏自检，再按 README 配手机端。"
cat > check.sh <<'CHECK_EOF'
#!/usr/bin/env bash
# TikTok 节点泄漏自检：在节点服务器上运行，检查 IP 纯净度、地区、IPv6、DNS、TikTok 可达性、公开端口监听
# 手机端的 DNS/WebRTC 泄漏需在手机上验证（脚本末尾会给出检查方法）
# 多节点：有 nodes.conf（install.sh --add-node 维护）时逐节点检查；没有就按旧版单节点（.env）检查
set -uo pipefail

pass() { echo "  [通过] $1"; }
warn() { echo "  [注意] $1"; }
fail() { echo "  [风险] $1"; }

echo "== 1/7 节点 IP 与地区 =="
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
echo "== 2/7 IPv6 是否禁用 =="
V6="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "?")"
if [ "$V6" = "1" ]; then
  pass "IPv6 已禁用（disable_ipv6=1）"
else
  fail "IPv6 未禁用（disable_ipv6=$V6）。跑 install.sh 时会自动禁用；手动执行："
  echo "       echo 'net.ipv6.conf.all.disable_ipv6 = 1' >> /etc/sysctl.d/99-singbox-node.conf && sysctl -p"
fi
if ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
  fail "本机仍有全局 IPv6 地址，存在 IPv6 泄漏口"
else
  pass "本机无全局 IPv6 地址"
fi

echo ""
echo "== 3/7 DNS 解析路径 =="
if command -v dig >/dev/null 2>&1; then
  RESOLVER="$(dig +short whoami.akamai.net @1.1.1.1 2>/dev/null | head -1)"
  [ -n "$RESOLVER" ] && echo "  经 1.1.1.1 解析的出口解析器 IP：$RESOLVER（应为 Cloudflare 的 IP，非国内运营商）"
  [ -z "$RESOLVER" ] && warn "dig 查询无返回，检查本机出站 UDP/TCP 53 是否被墙"
else
  warn "本机无 dig，跳过解析器核对（apt install dnsutils 可装）"
fi
echo "  sing-box 已配置 DoH(1.1.1.1/8.8.8.8/9.9.9.9)+DoT、只解析 IPv4，服务端不再走明文 UDP 53"

echo ""
echo "== 4/7 TikTok 可达性（从节点 IP 出口测） =="
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
echo "== 5/7 手机端自查（在手机上开着节点做） =="
echo "  节点只能管服务端这一半，手机端泄漏要这样验："
echo "  1) 打开 https://www.dnsleaktest.com 点 Extended test："
echo "     全部 DNS 服务器 IP 应该都是节点所在国家/机房的，出现中国运营商 DNS = 泄漏"
echo "  2) 打开 https://browserleaks.com/ip："
echo "     不能出现你的真实 IP、不能出现 IPv6 地址、时区/语言要和节点地区一致"
echo "  3) TikTok 里刷几个视频再看个人主页地区：应与节点地区一致"
echo "  4) 手机设置核对（见 README）：已拔国内 SIM 卡、时区语言=节点地区、定位已关"
echo ""
echo "== 6/7 公开端口监听 =="
# 节点列表：有 nodes.conf 时逐节点读（install.sh --add-node 维护）；没有就按旧版单节点（.env）读
CK_DIR="$(cd "$(dirname "$0")" && pwd)"
CK_REG="$CK_DIR/nodes.conf"
ck_reg_get() {
  local k="$1" line=""
  [ -f "$CK_REG" ] || return 0
  line="$(grep -m1 "^${k}=" "$CK_REG" || true)"
  printf '%s' "${line#*=}"
}
ck_node_field() { ck_reg_get "NODE_${1}_${2}"; }
ck_node_indices() {
  [ -f "$CK_REG" ] || return 0
  grep -oE '^NODE_[0-9]+_DOMAIN=' "$CK_REG" | grep -oE '[0-9]+' | sort -n -u || true
}
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
if [ -f "$CK_REG" ]; then
  echo "  端口配置来自 $CK_REG（逐节点检查）"
  CK_HTTPS="$(ck_reg_get GLOBAL_HTTPS_PORT)"; [ -n "$CK_HTTPS" ] || CK_HTTPS=443
  _any_tls=0
  for _ni in $(ck_node_indices); do
    [ "$(ck_node_field "$_ni" TLS_MODE)" = "1" ] && _any_tls=1
  done
  [ "$_any_tls" = "1" ] && check_port "HTTPS(WS，共用)" "$CK_HTTPS" tcp
  for _ni in $(ck_node_indices); do
    _tls="$(ck_node_field "$_ni" TLS_MODE)"
    _dom="$(ck_node_field "$_ni" DOMAIN)"
    if [ "$_tls" = "1" ]; then
      check_port "节点 $_ni（$_dom）Shadowsocks" "$(ck_node_field "$_ni" SS_PORT)" both
      if [ "$(ck_node_field "$_ni" HY2_ENABLED)" = "1" ]; then
        check_port "节点 $_ni（$_dom）Hysteria2" "$(ck_node_field "$_ni" HY2_PORT)" udp
        check_port "节点 $_ni（$_dom）TUIC" "$(ck_node_field "$_ni" TUIC_PORT)" udp
      else
        echo "  节点 $_ni（$_dom）Hysteria2/TUIC 未启用（证书没拿到时自动去掉的，重跑 install.sh 可补上）"
      fi
    else
      check_port "节点 $_ni（明文）VLESS" "$(ck_node_field "$_ni" VLESS_PORT)" tcp
      check_port "节点 $_ni（明文）Trojan" "$(ck_node_field "$_ni" TROJAN_PORT)" tcp
      check_port "节点 $_ni（明文）VMess" "$(ck_node_field "$_ni" VMESS_PORT)" tcp
      check_port "节点 $_ni（明文）Shadowsocks" "$(ck_node_field "$_ni" SS_PORT)" both
    fi
  done
  unset _ni _tls _dom _any_tls
else
  # 旧版单节点：端口从安装目录的 .env 读（install.sh 安装时写入实际端口）；没有 .env 就用默认端口
  if [ -f "$CK_DIR/.env" ]; then
    set -a; . "$CK_DIR/.env"; set +a
    echo "  端口配置来自 $CK_DIR/.env"
  else
    echo "  未找到 .env，按默认端口检查（TLS：HTTPS 443 / SS 8388 / HY2 8443 / TUIC 8444；明文：8080/8081/8082/8388）"
  fi
  TLS_MODE="${TLS_MODE:-1}"
  HTTPS_PORT="${HTTPS_PORT:-443}"; SS_PORT="${SS_PORT:-8388}"; HY2_PORT="${HY2_PORT:-8443}"; TUIC_PORT="${TUIC_PORT:-8444}"
  VLESS_PORT="${VLESS_PORT:-8080}"; TROJAN_PORT="${TROJAN_PORT:-8081}"; VMESS_PORT="${VMESS_PORT:-8082}"
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
fi
echo ""
echo "== 7/7 证书与续签 =="
# 证书方式与到期天数：TLS 节点逐个查；有 nodes.conf 时逐节点读，没有就按旧版单节点（.env）读
# DNS 验证用一张泛域名证书，所有 TLS 节点共用，只查一次
ck_cert_days() {  # ck_cert_days 节点名 域名 HTTPS端口 证书方式
  local name="$1" dom="$2" hp="$3" cm="$4"
  if [ "$cm" = "dns" ]; then
    local _base
    _base="$(ck_reg_get GLOBAL_BASE_DOMAIN)"
    if [ -n "$_base" ]; then
      echo "  节点 $name（$dom）：证书方式 DNS 验证（Cloudflare），泛域名证书 *.${_base}，续签全自动，不用管 80 端口"
    else
      echo "  节点 $name（$dom）：证书方式 DNS 验证（Cloudflare），续签全自动，不用管 80 端口"
    fi
  else
    echo "  节点 $name（$dom）：证书方式默认走 80（HTTP-01），续签要走 80 端口"
    echo "  注意：如果域名现在指向中转、且 80 没转到这台机，续签会失败，见 README“手动续签”一节"
  fi
  if command -v openssl >/dev/null 2>&1; then
    local end="" end_epoch="" now_epoch="" days=""
    end="$(timeout 10 openssl s_client -connect "127.0.0.1:$hp" -servername "$dom" </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    if [ -n "$end" ]; then
      end_epoch="$(date -d "$end" +%s 2>/dev/null || echo "")"
      now_epoch="$(date +%s)"
      if [ -n "$end_epoch" ]; then
        days="$(( (end_epoch - now_epoch) / 86400 ))"
        echo "  证书到期日：$end（剩余约 $days 天）"
        if [ "$days" -lt 0 ]; then
          fail "节点 $name：证书已过期 $(( -days )) 天！节点已不可用，立即按 README“手动续签”处理"
        elif [ "$days" -le 14 ]; then
          warn "节点 $name：证书 14 天内到期；Caddy 会在到期前 30 天内自动续签，到期还没续上就按 README“手动续签”处理"
        elif [ "$days" -le 30 ]; then
          pass "节点 $name：证书剩余 $days 天，Caddy 会自动续签"
        else
          pass "节点 $name：证书剩余 $days 天，Caddy 会在到期前 30 天内自动续签"
        fi
      else
        warn "节点 $name：读到证书但解析不到期日：$end"
      fi
    else
      warn "节点 $name：读不到证书（Caddy 可能没起来，或证书还没签好）；等几分钟再跑 check.sh"
    fi
  else
    warn "本机无 openssl，看不到证书剩余天数（apt install openssl 可装）"
  fi
}
if [ -f "$CK_REG" ]; then
  CK_HTTPS="$(ck_reg_get GLOBAL_HTTPS_PORT)"; [ -n "$CK_HTTPS" ] || CK_HTTPS=443
  CK_CM="$(ck_reg_get GLOBAL_CERT_METHOD)"; [ -n "$CK_CM" ] || CK_CM=http
  _any_tls=0; _dns_checked=0
  for _ni in $(ck_node_indices); do
    if [ "$(ck_node_field "$_ni" TLS_MODE)" = "1" ]; then
      _any_tls=1
      if [ "$CK_CM" = "dns" ]; then
        # 泛域名证书所有节点共用，只查一次（用第一个 TLS 节点的域名去握手，拿到的是同一张泛域名证书）
        if [ "$_dns_checked" = "0" ]; then
          ck_cert_days "节点 $_ni（泛域名证书，所有 TLS 节点共用）" "$(ck_node_field "$_ni" DOMAIN)" "$CK_HTTPS" "dns"
          _dns_checked=1
        fi
      else
        ck_cert_days "节点 $_ni" "$(ck_node_field "$_ni" DOMAIN)" "$CK_HTTPS" "http"
      fi
    else
      echo "  节点 $_ni（明文）：没有证书（补域名重跑 install.sh 可升级 TLS）"
    fi
  done
  [ "$_any_tls" = "0" ] && echo "  全部节点都是明文模式，没有证书（补域名重跑 install.sh 可升级 TLS）"
  unset _ni _any_tls _dns_checked
elif [ "${TLS_MODE:-}" != "1" ]; then
  echo "  明文模式，没有证书（补域名重跑 install.sh 可升级 TLS）"
else
  if [ "${CERT_METHOD:-http}" = "dns" ]; then
    echo "  证书方式：DNS 验证（Cloudflare），续签全自动，不用管 80 端口"
  else
    echo "  证书方式：默认走 80（HTTP-01），续签要走 80 端口"
    echo "  注意：如果域名现在指向中转、且 80 没转到这台机，续签会失败，见 README“手动续签”一节"
  fi
  if [ -n "${DOMAIN:-}" ]; then
    ck_cert_days "节点 1" "${DOMAIN:-}" "${HTTPS_PORT:-443}" "${CERT_METHOD:-http}"
  else
    warn "没找到域名（.env 不在），看不到证书剩余天数"
  fi
fi
echo ""
echo "自检完成。"
CHECK_EOF
chmod +x check.sh

if [ "$DRY_RUN" != "1" ]; then
  echo ""
  bash check.sh || true
fi

ask_add_more
