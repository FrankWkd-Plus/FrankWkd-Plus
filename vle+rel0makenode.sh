#!/usr/bin/env bash
# ============================================================
# VLESS + Reality + Vision 部署脚本 (Pterodactyl 适配版)
# 多镜像下载 | 状态持久化 | 隐蔽性 | 单端口
# ============================================================
set -euo pipefail

# ---------- 配置 ----------
XRAY_VERSION="v25.9.14"
FAKE_DOMAIN="www.microsoft.com"
FAKE_PROC="[kworker/u4:2]"

PORT="${1:-${SERVER_PORT:-${PORT:-}}}"
if [[ -z "$PORT" ]]; then
    echo "❌ 需要端口: bash script.sh <端口>"
    exit 1
fi

# Pterodactyl 工作目录
WORKDIR="${HOME:-/home/container}"
cd "$WORKDIR" || { echo "❌ 无法进入 $WORKDIR"; exit 1; }

# 隐蔽文件 & 持久化状态
RAND_SUFFIX="${RANDOM}${RANDOM}"; RAND_SUFFIX="${RAND_SUFFIX:0:6}"
BIN_NAME=".cache_${RAND_SUFFIX}"
STATE_FILE=".st_${PORT}.env"
CONF_FILE=".cf_${PORT}.json"

# ---------- 架构检测 ----------
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        *) echo "❌ 架构不支持: $(uname -m)"; exit 1 ;;
    esac
}

# ---------- 多镜像下载 ----------
download_xray() {
    local suffix="$1"
    local tmp=".xray.$$.zip"
    local urls=(
        "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${suffix}.zip"
        "https://ghfast.top/https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${suffix}.zip"
        "https://gh-proxy.com/https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${suffix}.zip"
        "https://ghproxy.net/https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${suffix}.zip"
        "https://mirror.ghproxy.com/https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${suffix}.zip"
    )

    local ok=0
    for u in "${urls[@]}"; do
        echo "⬇️  尝试: ${u:0:55}..."
        rm -f "$tmp"
        if curl -Lsf --connect-timeout 15 --max-time 180 -o "$tmp" "$u" 2>/dev/null; then
            if [[ -s "$tmp" ]]; then
                # 简单校验 zip 头 (PK\x03\x04)
                if [[ "$(head -c 2 "$tmp" 2>/dev/null)" == "PK" ]]; then
                    ok=1; break
                fi
            fi
        fi
    done

    [[ "$ok" -ne 1 ]] && { echo "❌ 所有下载源均失败"; rm -f "$tmp"; exit 1; }

    # 解压（多路径 fallback）
    local extracted=0
    if command -v unzip >/dev/null 2>&1; then
        unzip -o -q "$tmp" xray && extracted=1
    fi
    if [[ "$extracted" -eq 0 ]] && command -v python3 >/dev/null 2>&1; then
        python3 -c "import zipfile,sys; zipfile.ZipFile('$tmp').extract('xray','.')" 2>/dev/null && extracted=1
    fi
    if [[ "$extracted" -eq 0 ]] && command -v busybox >/dev/null 2>&1; then
        busybox unzip -o "$tmp" xray && extracted=1
    fi
    if [[ "$extracted" -eq 0 ]] && command -v jar >/dev/null 2>&1; then
        jar xf "$tmp" xray && extracted=1
    fi

    rm -f "$tmp"
    [[ "$extracted" -eq 1 && -f xray ]] || { echo "❌ 解压失败（无可用工具）"; exit 1; }

    mv -f xray "$BIN_NAME"
    chmod +x "$BIN_NAME"
}

# ---------- 凭证持久化 ----------
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        if [[ -n "${UUID:-}" && -n "${PRIVATE_KEY:-}" && -n "${PUBLIC_KEY:-}" && -n "${SHORT_ID:-}" ]]; then
            echo "ℹ️  复用已有凭证（重启不会换链接）"
            return 0
        fi
    fi
    return 1
}

save_state() {
    cat > "$STATE_FILE" <<EOF
UUID='${UUID}'
PRIVATE_KEY='${PRIVATE_KEY}'
PUBLIC_KEY='${PUBLIC_KEY}'
SHORT_ID='${SHORT_ID}'
EOF
    chmod 600 "$STATE_FILE" 2>/dev/null || true
}

gen_credentials() {
    local out
    out=$("$BIN_NAME" x25519 2>/dev/null) || { echo "❌ x25519 失败"; exit 1; }
    PRIVATE_KEY=$(echo "$out" | awk '/[Pp]rivate/{print $NF; exit}')
    PUBLIC_KEY=$(echo "$out" | awk '/[Pp]ublic|[Pp]assword/{print $NF; exit}')
    [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]] && { echo "❌ 密钥解析失败"; echo "$out"; exit 1; }
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || "$BIN_NAME" uuid)
    SHORT_ID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
}

# ---------- 生成配置 ----------
gen_config() {
    cat > "$CONF_FILE" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision"}],
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
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

    if ! "$BIN_NAME" run -c "$CONF_FILE" -test >/dev/null 2>&1; then
        if ! "$BIN_NAME" -test -c "$CONF_FILE" >/dev/null 2>&1; then
            echo "⚠️  配置校验工具不可用，跳过校验"
        fi
    fi
}

# ---------- 输出 ----------
output_link() {
    local ip
    ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "YOUR_IP")
    local link="vless://${UUID}@${ip}:${PORT}?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&fp=firefox&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&sni=${FAKE_DOMAIN}#VLESS-Reality-${PORT}"

    echo "------------------------------------------------"
    echo "🚀 部署完成"
    echo "📍 ${ip}:${PORT}  伪装: ${FAKE_DOMAIN}"
    echo "🔗 节点链接:"
    echo -e "\033[36m${link}\033[0m"
    echo "------------------------------------------------"
}

# ---------- 主流程 ----------
main() {
    echo "------------------------------------------------"
    echo "🛠️  VLESS + Reality + Vision (Pterodactyl 版)"
    echo "------------------------------------------------"

    command -v curl >/dev/null 2>&1 || { echo "❌ 缺少 curl"; exit 1; }

    # 二进制不存在才下载
    if [[ ! -x "$BIN_NAME" ]]; then
        # 清理旧二进制（不同后缀名）
        rm -f .cache_* 2>/dev/null || true
        local suffix; suffix=$(detect_arch)
        download_xray "$suffix"
    else
        echo "ℹ️  已有 Xray 二进制，跳过下载"
    fi

    # 凭证：加载或生成
    if ! load_state; then
        gen_credentials
        save_state
    fi

    gen_config
    output_link

    # 自删除（管道执行时跳过）
    local _self; _self="$(basename "$0" 2>/dev/null || echo "")"
    case "$_self" in
        bash|sh|dash|zsh|-bash|-sh|-dash|-zsh|"") : ;;
        *) [[ -f "$0" ]] && rm -f "$0" 2>/dev/null || true ;;
    esac

    # 常驻，伪装进程名
    exec -a "${FAKE_PROC}" "$BIN_NAME" run -c "$CONF_FILE" >/dev/null 2>&1
}

main "$@"
