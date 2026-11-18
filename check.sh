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
