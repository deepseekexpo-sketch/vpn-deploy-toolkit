#!/usr/bin/env bash
# 02-port-probe.sh — 端口探测 (检查端口可用性)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
source "${KIT_DIR}/config.env"
[[ -f "${RUNTIME_ENV}" ]] && source "${RUNTIME_ENV}"

init_output

# Idempotent guard
if step_done "02-port-probe"; then
    step_ok "02-port-probe"
    exit 0
fi

# Hysteria2 UDP 候选端口 (避开 443 — 可能被 Reality 占)
HY2_CANDIDATES=(8443 20443 34567 13456 54321)
# Reality TCP 候选端口 (Batch 2 用)
REALITY_CANDIDATES=(443 8443 2053 23456 13456)

# 检查端口是否被占用
port_available() {
    local port="$1"
    local proto="$2"  # tcp or udp
    if [[ "${proto}" == "tcp" ]]; then
        ss -tlnp | grep -q ":${port} " && return 1 || return 0
    else
        ss -ulnp | grep -q ":${port} " && return 1 || return 0
    fi
}

# === Hysteria2 UDP 端口 ===
if [[ -n "${HY2_PORT:-}" ]]; then
    log_info "HY2_PORT=${HY2_PORT} (user specified)"
else
    log_info "Auto-selecting Hysteria2 UDP port"
    for port in "${HY2_CANDIDATES[@]}"; do
        if port_available "${port}" udp; then
            HY2_PORT="${port}"
            log_info "Selected HY2_PORT=${port}"
            break
        fi
    done
    if [[ -z "${HY2_PORT:-}" ]]; then
        log_error "No available UDP port for Hysteria2"
        exit 1
    fi
fi

# 验证选中端口确实可用
if ! port_available "${HY2_PORT}" udp; then
    log_error "HY2_PORT=${HY2_PORT} is already in use (UDP)"
    exit 1
fi

# === Reality TCP 端口 (Batch 2 预留) ===
if [[ -n "${REALITY_PORT:-}" ]]; then
    log_info "REALITY_PORT=${REALITY_PORT} (user specified)"
else
    for port in "${REALITY_CANDIDATES[@]}"; do
        if port_available "${port}" tcp; then
            REALITY_PORT="${port}"
            log_info "Selected REALITY_PORT=${port}"
            break
        fi
    done
    if [[ -z "${REALITY_PORT:-}" ]]; then
        # Reality 是 Batch 2，不阻塞 Batch 1
        log_warn "No available TCP port for Reality (Batch 2 will handle this)"
        REALITY_PORT=""
    fi
fi

# 写入 runtime.env
# F-CN-7 / spec v3 §10.3:同时写 *_ACTUAL(spec 字段)+ 旧键(05/06 既有读路径过渡期兼容)
# Batch 3 重构时拆掉旧键
write_runtime "HY2_PORT_ACTUAL=${HY2_PORT}"
write_runtime "HY2_PORT=${HY2_PORT}"
if [[ -n "${REALITY_PORT}" ]]; then
    write_runtime "REALITY_PORT_ACTUAL=${REALITY_PORT}"
    write_runtime "REALITY_PORT=${REALITY_PORT}"
fi

# 端口冲突 assert(Architect F-10):两协议虽然 tcp/udp 不同,但 ufw/state 管理简化要求不复用同物理端口
if [[ -n "${REALITY_PORT}" && "${HY2_PORT}" == "${REALITY_PORT}" ]]; then
    log_error "HY2_PORT and REALITY_PORT collide (${HY2_PORT}). Pick different ports."
    exit 1
fi

# 补 ufw 规则 (01 可能还没写 HY2_PORT)
if command -v ufw &>/dev/null; then
    log_info "Adding ufw rule for Hysteria2 UDP ${HY2_PORT}"
    run ufw allow "${HY2_PORT}/udp" comment "vpn-deploy-kit:hy2"
fi

log_info "Port probe complete: HY2_PORT=${HY2_PORT} REALITY_PORT=${REALITY_PORT:-TBD}"

mark_step_done "02-port-probe"
step_ok "02-port-probe"
