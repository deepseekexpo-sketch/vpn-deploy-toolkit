#!/usr/bin/env bash
# 06-deploy-hysteria-cfg.sh — 渲染 Hysteria2 配置 + 生成密码 + 启动服务
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
source "${KIT_DIR}/config.env"
[[ -f "${RUNTIME_ENV}" ]] && source "${RUNTIME_ENV}"

init_output

# Idempotent guard
if step_done "06-deploy-hysteria-cfg"; then
    step_ok "06-deploy-hysteria-cfg"
    exit 0
fi

# 确保 HY2_PORT 已确定
if [[ -z "${HY2_PORT:-}" ]]; then
    log_error "HY2_PORT not set (02-port-probe should have set it)"
    exit 1
fi

# === 1. 生成 Hysteria2 密码 ===
if [[ -z "${HY2_PASS:-}" ]]; then
    log_info "Generating Hysteria2 password (openssl rand -hex 16)"
    HY2_PASS=$(rand_hex 16)
    write_runtime "HY2_PASS=${HY2_PASS}"
    # 写入 secrets 文件
    write_secrets "| Hysteria2 密码 | \`${HY2_PASS}\` |"
    log_info "Password generated and saved to $(secrets_file)"
else
    log_info "HY2_PASS already set, reusing"
fi

# === 2. 渲染配置 (envsubst pipe，不落盘到 /tmp) ===
log_info "Rendering Hysteria2 config to /etc/hysteria/config.yaml"
export HY2_PASS VPS_IP HY2_PORT HY2_SNI HY2_MASQUERADE

if [[ "${BOOTSTRAP_DRY_RUN:-0}" == "1" ]]; then
    run bash -c "envsubst < '${KIT_DIR}/templates/hysteria-config.yaml.tmpl'"
    log_warn "[DRY-RUN] Config not actually written"
else
    envsubst < "${KIT_DIR}/templates/hysteria-config.yaml.tmpl" > /etc/hysteria/config.yaml
    chown hysteria:hysteria /etc/hysteria/config.yaml
    chmod 640 /etc/hysteria/config.yaml
fi

# === 3. 启动服务 ===
log_info "Starting hysteria-server"
run systemctl restart hysteria-server

# 等待启动
sleep 2

# === 4. 验证端口监听 ===
if [[ "${BOOTSTRAP_DRY_RUN:-0}" != "1" ]]; then
    if ss -ulnp | grep -q ":${HY2_PORT} "; then
        log_info "Hysteria2 listening on UDP :${HY2_PORT} ✓"
    else
        log_error "Hysteria2 not listening on UDP :${HY2_PORT}"
        journalctl -u hysteria-server --no-pager -n 20
        exit 1
    fi
fi

# 写入 secrets 中的连接信息
write_secrets "| Hysteria2 端口 | \`${HY2_PORT}/udp\` |"
write_secrets "| Hysteria2 SNI | \`${HY2_SNI}\` |"
write_secrets "| VPS IP | \`${VPS_IP}\` |"

mark_step_done "06-deploy-hysteria-cfg"
step_ok "06-deploy-hysteria-cfg"
