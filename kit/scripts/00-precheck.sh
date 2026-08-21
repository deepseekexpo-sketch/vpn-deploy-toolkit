#!/usr/bin/env bash
# 00-precheck.sh — VPS 环境预检
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
source "${KIT_DIR}/config.env"
[[ -f "${RUNTIME_ENV}" ]] && source "${RUNTIME_ENV}"

init_output

# 跳过预检
if [[ "${BOOTSTRAP_FORCE:-0}" == "1" ]]; then
    log_warn "BOOTSTRAP_FORCE=1, skipping precheck"
    step_ok "00-precheck"
    exit 0
fi

ERRORS=0

# 1. OS 检查
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ "${ID}" != "ubuntu" ]] || [[ "${VERSION_ID%%.*}" != "22" ]]; then
        log_error "Unsupported OS: ${PRETTY_NAME} (require Ubuntu 22.04)"
        ERRORS=$((ERRORS + 1))
    else
        log_info "OS: ${PRETTY_NAME} ✓"
    fi
else
    log_error "Cannot determine OS (/etc/os-release missing)"
    ERRORS=$((ERRORS + 1))
fi

# 2. root / sudo 检查
if [[ "$(id -u)" -ne 0 ]]; then
    log_error "Must run as root"
    ERRORS=$((ERRORS + 1))
else
    log_info "Running as root ✓"
fi

# 3. 必要工具检查
REQUIRED_TOOLS=(openssl curl wget ss systemctl jq sqlite3 ufw envsubst uuidgen)
for tool in "${REQUIRED_TOOLS[@]}"; do
    if command -v "${tool}" &>/dev/null; then
        log_info "Tool ${tool} ✓"
    else
        log_error "Missing required tool: ${tool}"
        ERRORS=$((ERRORS + 1))
    fi
done

# 3a. sqlite3 >= 3.16 (Reality 04 readfile() 要求,F-CN-6/spec v3 §10.2)
if command -v sqlite3 &>/dev/null; then
    SQLITE_VER=$(sqlite3 --version | awk '{print $1}')
    if version_ge "${SQLITE_VER}" "3.16"; then
        log_info "sqlite3 ${SQLITE_VER} >= 3.16 ✓"
    else
        log_error "sqlite3 ${SQLITE_VER} too old; need >= 3.16 for readfile()"
        ERRORS=$((ERRORS + 1))
    fi
fi

# 4. 443 端口占用检查 (如果未指定自定义端口)
if ss -tlnp | grep -q ':443 '; then
    log_warn "Port 443/tcp is in use — may conflict with Reality if not using custom port"
fi
if ss -ulnp | grep -q ':443 '; then
    log_warn "Port 443/udp is in use — may conflict with Hysteria2 if not using custom port"
fi

# 5. systemd 检查
if systemctl is-system-running &>/dev/null; then
    log_info "systemd running ✓"
else
    log_error "systemd not running"
    ERRORS=$((ERRORS + 1))
fi

# 6. VPS_IP 必填
if [[ -z "${VPS_IP:-}" ]]; then
    log_error "VPS_IP is required in config.env"
    ERRORS=$((ERRORS + 1))
else
    log_info "VPS_IP=${VPS_IP} ✓"
fi

if [[ ${ERRORS} -gt 0 ]]; then
    log_error "Precheck failed with ${ERRORS} error(s). Set BOOTSTRAP_FORCE=1 to skip."
    exit 1
fi

mark_step_done "00-precheck"
step_ok "00-precheck"
