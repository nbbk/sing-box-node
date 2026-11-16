#!/usr/bin/env bash
# 停止或删除 sing-box 节点，释放端口
#   bash stop.sh            停止节点，保留配置（之后在目录里 docker compose up -d 可再启动）
#   bash stop.sh --remove   彻底删除节点（容器、数据卷、配置目录全部删除）
# 远程一键（不用先下载）：
#   curl -fsSL https://raw.githubusercontent.com/nbbk/sing-box-node/main/stop.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/nbbk/sing-box-node/main/stop.sh | bash -s -- --remove
set -euo pipefail

REMOVE=0
[ "${1:-}" = "--remove" ] && REMOVE=1

# 找到 docker-compose.yml 所在的目录（解析为绝对路径）
COMPOSE_DIR=""
for d in "$(dirname "$0")" "$PWD" "$HOME/sing-box-node-kit"; do
  if [ -f "$d/docker-compose.yml" ]; then COMPOSE_DIR="$(cd "$d" && pwd)"; break; fi
done

# ---------- 1. 停容器 ----------
if [ -n "$COMPOSE_DIR" ]; then
  echo "在 $COMPOSE_DIR 停止节点..."
  cd "$COMPOSE_DIR"
  if [ "$REMOVE" = "1" ]; then
    docker compose down -v 2>/dev/null || true
  else
    docker compose down 2>/dev/null || true
  fi
fi
# 兜底：按容器名直接删除（compose 文件丢了也能释放端口）
for c in singbox-node singbox-caddy; do
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
    docker rm -f "$c" >/dev/null 2>&1 || true
    echo "已删除容器 $c"
  fi
done

# ---------- 2. 验证端口是否已释放 ----------
# 用法：port_in_use tcp|udp 端口
port_in_use() {
  local proto="$1" port="$2"
  local hex
  if [ "$proto" = "tcp" ]; then
    if command -v ss >/dev/null 2>&1; then
      ss -tln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
    elif command -v netstat >/dev/null 2>&1; then
      netstat -tln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
    else
      hex=$(printf '%04X' "$port")
      grep -qiE "^[[:space:]]*[0-9]+:[[:space:]]+[0-9A-Fa-f]+:${hex}[[:space:]]" /proc/net/tcp /proc/net/tcp6 2>/dev/null
    fi
  else
    if command -v ss >/dev/null 2>&1; then
      ss -uln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
    elif command -v netstat >/dev/null 2>&1; then
      netstat -uln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
    else
      hex=$(printf '%04X' "$port")
      grep -qiE "^[[:space:]]*[0-9]+:[[:space:]]+[0-9A-Fa-f]+:${hex}[[:space:]]" /proc/net/udp /proc/net/udp6 2>/dev/null
    fi
  fi
}

echo ""
echo "端口检查："
STILL_HELD=""
for spec in "tcp 80" "tcp 443" "tcp 8080" "tcp 8081" "tcp 8082" "tcp 8388" "udp 8388" "udp 8443" "udp 8444"; do
  set -- $spec
  if port_in_use "$1" "$2"; then
    echo "  端口 $2/$1 仍被占用："
    if command -v ss >/dev/null 2>&1; then
      if [ "$1" = "tcp" ]; then
        ss -tlnp 2>/dev/null | grep -E "[:.]${2}[[:space:]]" | sed 's/^/    /' || true
      else
        ss -ulnp 2>/dev/null | grep -E "[:.]${2}[[:space:]]" | sed 's/^/    /' || true
      fi
    fi
    STILL_HELD="$STILL_HELD $2/$1"
  else
    echo "  端口 $2/$1 已释放"
  fi
done

echo ""
if [ -n "$STILL_HELD" ]; then
  echo "注意：端口$STILL_HELD 仍被占用（上面列出了占用它的进程）。"
  echo "如果占用它的是本节点的容器，说明容器没停干净，请手动执行："
  echo "  docker ps -a | grep -E 'singbox-node|singbox-caddy'"
  echo "  docker rm -f <容器名>"
  echo "如果是别的程序占了这些端口，需要先停掉那个程序，或换一台服务器。"
else
  echo "端口 80/443/8080/8081/8082/8388/8443/8444 已全部释放，装新节点不会再报端口占用。"
fi

# ---------- 3. 彻底删除时清理系统改动与目录 ----------
if [ "$REMOVE" = "1" ]; then
  echo ""
  echo "彻底删除："
  if [ -f /etc/sysctl.d/99-singbox-node.conf ]; then
    rm -f /etc/sysctl.d/99-singbox-node.conf
    sysctl -p >/dev/null 2>&1 || true
    echo "  已删除 /etc/sysctl.d/99-singbox-node.conf（IPv6 与网络调优已恢复）"
  fi
  # 只删名字里带 sing-box-node-kit 的目录，脚本退出后再删（避免删正在执行的文件）
  if [ -n "$COMPOSE_DIR" ] && [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then
    case "$COMPOSE_DIR" in
      *sing-box-node-kit*)
        trap 'rm -rf "$COMPOSE_DIR"' EXIT
        echo "  节点目录 $COMPOSE_DIR 将在脚本退出后删除"
        ;;
      *)
        echo "  节点目录 $COMPOSE_DIR 请手动删除：rm -rf $COMPOSE_DIR"
        ;;
    esac
  fi
  echo ""
  echo "节点已彻底删除。"
else
  echo ""
  echo "节点已停止（配置保留）。"
  if [ -n "$COMPOSE_DIR" ]; then
    echo "再启动：cd $COMPOSE_DIR && docker compose up -d"
  fi
fi
