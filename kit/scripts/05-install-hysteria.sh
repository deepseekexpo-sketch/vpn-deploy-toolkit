#!/usr/bin/env bash
# 05-install-hysteria.sh — 下载 Hysteria2 binary + 自签 cert + systemd 服务
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
source "${KIT_DIR}/config.env"
[[ -f "${RUNTIME_ENV}" ]] && source "${RUNTIME_ENV}"

init_output

# Idempotent guard
if step_done "05-install-hysteria"; then
    step_ok "05-install-hysteria"
    exit 0
fi

HY2_BIN="/usr/local/bin/hysteria-server"
HY2_CERT_DIR="/etc/hysteria/cert"
HY2_CFG_DIR="/etc/hysteria"

# === 1. 下载 binary ===
if [[ -x "${HY2_BIN}" ]]; then
    log_info "Hysteria2 binary already exists at ${HY2_BIN}"
else
    log_info "Downloading Hysteria2 ${HY2_VERSION}"
    ARCH="$(uname -m)"
    case "${ARCH}" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) log_error "Unsupported arch: ${ARCH}"; exit 1 ;;
    esac

    DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/${HY2_VERSION}/hysteria-linux-${ARCH}"

    run bash -c "
        curl -fsSL '${DOWNLOAD_URL}' -o '${HY2_BIN}' \
        && chmod +x '${HY2_BIN}'
    "

    # SHA256 校验
    if [[ -n "${HY2_SHA256:-}" ]]; then
        log_info "Verifying SHA256 checksum"
        run bash -c "
            echo '${HY2_SHA256}  ${HY2_BIN}' | sha256sum -c -
        "
    else
        log_warn "HY2_SHA256 not set, skipping checksum verification"
    fi
fi

# 验证 binary 可执行
if ! run "${HY2_BIN}" version &>/dev/null; then
    log_error "Hysteria2 binary not working"
    exit 1
fi
log_info "Hysteria2 binary OK"

# === 2. 创建系统用户 ===
if id hysteria &>/dev/null; then
    log_info "User hysteria already exists"
else
    log_info "Creating system user 'hysteria'"
    run useradd -r -s /usr/sbin/nologin -d /etc/hysteria hysteria
fi

# === 3. 创建目录 ===
run bash -c "
    mkdir -p '${HY2_CERT_DIR}' '${HY2_CFG_DIR}'
    chown -R hysteria:hysteria '${HY2_CFG_DIR}'
    chmod 750 '${HY2_CFG_DIR}'
"

# === 4. 生成自签证书 ===
if [[ -f "${HY2_CERT_DIR}/server.crt" && -f "${HY2_CERT_DIR}/server.key" ]]; then
    log_info "Self-signed cert already exists"
else
    log_info "Generating self-signed cert (SAN=IP:${VPS_IP})"
    run openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -nodes -days 3650 \
        -subj "/CN=${VPS_IP}" \
        -addext "subjectAltName=IP:${VPS_IP}" \
        -keyout "${HY2_CERT_DIR}/server.key" \
        -out "${HY2_CERT_DIR}/server.crt"

    run bash -c "
        chown hysteria:hysteria '${HY2_CERT_DIR}/server.crt' '${HY2_CERT_DIR}/server.key'
        chmod 640 '${HY2_CERT_DIR}/server.crt' '${HY2_CERT_DIR}/server.key'
    "
fi

# === 5. 安装 systemd unit ===
log_info "Installing systemd service"
run bash -c "
    cp '${KIT_DIR}/templates/hysteria-server.service' /etc/systemd/system/hysteria-server.service
    systemctl daemon-reload
    systemctl enable hysteria-server
"

# 不 start — 06 会推配置后再 start
log_info "Service enabled (not started yet — 06 will start after config)"

mark_step_done "05-install-hysteria"
step_ok "05-install-hysteria"
