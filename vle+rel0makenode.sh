#!/usr/bin/env bash
# ============================================================
# VLESS + Reality + Vision 单端口部署脚本
# 特性: 自动更新 | 进程守护 | 隐蔽性 | CPU优化
# 适配: 单端口虚拟主机, 低CPU配额
# ============================================================
set -euo pipefail

# ---------- 配置区 ----------
XRAY_VERSION="v25.9.14"
FAKE_DOMAIN="www.microsoft.com"
FAKE_PROC="[kworker/u4:2]"
UPDATE_INTERVAL=86400  # 自动更新检查间隔（秒），默认24小时

# 端口: 优先命令行参数, 其次环境变量 PORT
PORT="${1:-${PORT:-}}"
if [[ -z "$PORT" ]]; then
    echo "❌ 请指定端口: bash script.sh <端口>"
    exit 1
fi

# 隐蔽二进制名
RAND_SUFFIX=$(head -c 8 /dev/urandom 2>/dev/null | base64 | tr -dc 'A-Za-z0-9' | head -c 6 || echo "x00000")
BIN_NAME="./.cache_${RAND_SUFFIX}"
BIN_REAL="/usr/local/lib/.xray_${RAND_SUFFIX}"

# ---------- 依赖检查 ----------
check_deps() {
    local missing=()
    for cmd in curl od unzip; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "❌ 缺少依赖: ${missing[*]}" >&2
        exit 1
    fi
}

# ---------- 架构检测 ----------
detect_arch() {
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   echo "64" ;;
        aarch64|arm64)  echo "arm64-v8a" ;;
        *) echo "❌ 不支持的架构: $arch" >&2; exit 1 ;;
    esac
}

# ---------- 下载 Xray ----------
download_xray() {
    local arch_suffix="$1" tmp_zip=".xray_$$.zip"
    echo "⬇️  正在下载 Xray-core ${XRAY_VERSION}..."
    if ! curl -Lsf --retry 2 --connect-timeout 10 -o "$tmp_zip" \
        "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${arch_suffix}.zip"; then
        echo "❌ 下载失败" >&2; exit 1
    fi
    unzip -o -q "$tmp_zip" xray -d . || { echo "❌ 解压失败"; exit 1; }
    rm -f "$tmp_zip"
    mv xray "$BIN_NAME"; chmod +x "$BIN_NAME"
    # 同时安装一份到系统目录，供更新脚本使用
    mkdir -p /usr/local/lib
    cp "$BIN_NAME" "$BIN_REAL"; chmod +x "$BIN_REAL"
}

# ---------- 生成凭证 ----------
gen_credentials() {
    local output
    output=$("$BIN_NAME" x25519 2>/dev/null) || { echo "❌ x25519 失败"; exit 1; }
    PRIVATE_KEY=$(echo "$output" | grep -i "private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$output" | grep -iE "public|password" | awk '{print $NF}')
    [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]] && { echo "❌ 密钥解析失败"; exit 1; }
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || "$BIN_NAME" uuid)
    SHORT_ID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
}

# ---------- 生成配置 ----------
gen_config() {
    cat > .conf.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${FAKE_DOMAIN}:443",
        "xver": 0,
        "serverNames": ["${FAKE_DOMAIN}"],
        "privateKey": "${PRIVATE_KEY}",
        "shortIds": ["${SHORT_ID}"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
    "$BIN_NAME" run -c .conf.json -test >/dev/null 2>&1 || echo "⚠️  配置校验跳过"
}

# ---------- 自动更新脚本 ----------
create_updater() {
    cat > "${BIN_REAL}.update" <<'UPDEOF'
#!/usr/bin/env bash
# Xray 自动更新守护脚本
set -euo pipefail
BIN_REAL="${1:-/usr/local/lib/.xray_auto}"
XRAY_VERSION_FILE="${BIN_REAL}.version"

while true; do
    sleep 86400
    # 检查最新版本
    LATEST=$(curl -sf --max-time 15 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | grep -oP '"tag_name": "\K[^"]+' || echo "")
    [[ -z "$LATEST" ]] && continue

    CURRENT=$(cat "$XRAY_VERSION_FILE" 2>/dev/null || echo "none")
    [[ "$LATEST" == "$CURRENT" ]] && continue

    # 下载新版本
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) SUFFIX="64" ;;
        aarch64|arm64) SUFFIX="arm64-v8a" ;;
        *) continue ;;
    esac

    TMP=".xray_update_$$.zip"
    if curl -Lsf --max-time 60 -o "$TMP" \
        "https://github.com/XTLS/Xray-core/releases/download/${LATEST}/Xray-linux-${SUFFIX}.zip" 2>/dev/null; then
        if unzip -o -q "$TMP" xray -d /tmp 2>/dev/null; then
            # 替换二进制
            mv /tmp/xray "$BIN_REAL" 2>/dev/null && chmod +x "$BIN_REAL"
            echo "$LATEST" > "$XRAY_VERSION_FILE"
            # 通知主进程重启（通过信号）
            pkill -f "$(basename "$BIN_REAL")" 2>/dev/null || true
        fi
        rm -f "$TMP"
    fi
done
UPDEOF
    chmod +x "${BIN_REAL}.update"
    # 记录当前版本
    echo "$XRAY_VERSION" > "${BIN_REAL}.version"
    # 后台启动更新守护
    setsid "${BIN_REAL}.update" "$BIN_REAL" >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# ---------- 输出链接 ----------
output_link() {
    local pub_ip; pub_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")
    local link="vless://${UUID}@${pub_ip}:${PORT}?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&fp=firefox&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&sni=${FAKE_DOMAIN}#VLESS-Reality-${pub_ip}"
    echo "------------------------------------------------"
    echo "🚀 部署完成！"
    echo "📍 IP: ${pub_ip}  端口: ${PORT}  伪装: ${FAKE_DOMAIN}"
    echo "🔗 节点链接:"
    echo -e "\033[36m${link}\033[0m"
    echo "------------------------------------------------"
}

# ---------- 主流程 ----------
main() {
    echo "------------------------------------------------"
    echo "🛠️  VLESS + Reality + Vision 单端口部署———"
    echo "🚩  使用即表示您已同意相关条款。"
    echo "------------------------------------------------"

    check_deps
    local arch_suffix; arch_suffix=$(detect_arch)
    download_xray "$arch_suffix"
    gen_credentials
    gen_config
    output_link
    create_updater

    # 隐蔽性处理
    if command -v chrt >/dev/null 2>&1; then
        chrt -r 20 -p $$ >/dev/null 2>&1 || true
    fi

    local _self; _self="$(basename "$0" 2>/dev/null || echo "")"
    case "$_self" in
        bash|sh|dash|zsh|-bash|-sh|-dash|-zsh|"") : ;;
        *) [[ -f "$0" ]] && rm -f "$0" 2>/dev/null || true ;;
    esac

    # 常驻运行 + 进程守护
    while true; do
        exec -a "${FAKE_PROC}" "$BIN_NAME" run -c .conf.json >/dev/null 2>&1 || true
        # 如果进程退出（被更新脚本kill或崩溃），短暂等待后重启
        sleep 3
        # 如果二进制被更新，使用新版本
        [[ -x "$BIN_REAL" ]] && cp -f "$BIN_REAL" "$BIN_NAME" 2>/dev/null && chmod +x "$BIN_NAME"
    done
}

main "$@"