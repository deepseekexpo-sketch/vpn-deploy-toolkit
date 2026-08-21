#!/usr/bin/env bash
# 08-gen-client-yaml.sh — 生成 mihomo/Clash Verge Rev 客户端配置
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
source "${KIT_DIR}/config.env"
[[ -f "${RUNTIME_ENV}" ]] && source "${RUNTIME_ENV}"

init_output
state_init

# F-CN-7: normalize legacy + new keys
hy2_port_normalize
reality_port_normalize

# 确保 HY2 变量就绪
if [[ -z "${HY2_PORT:-}" || -z "${HY2_PASS:-}" ]]; then
    log_error "HY2_PORT or HY2_PASS not set (run 06 first)"
    exit 1
fi

# Reality 字段(从 runtime.env 来,04 写入);step.04 完成才渲染 Reality 块
HAS_REALITY=0
if [[ "$(state_get step.04.completed false)" == "true" ]]; then
    if [[ -z "${REALITY_PORT:-}" || -z "${REALITY_UUID:-}" \
          || -z "${REALITY_PUBKEY:-}" || -z "${REALITY_SHORT_ID:-}" \
          || -z "${REALITY_SNI:-}" ]]; then
        log_error "Reality runtime fields missing despite step.04 completed; rerun 04"
        exit 1
    fi
    HAS_REALITY=1
    log_info "Including Reality proxy block (step.04 completed)"
fi

# === 渲染客户端 yaml ===
CLIENT_YAML="${OUTPUT_DIR}/client-${VPS_IP}.yaml"

log_info "Generating client yaml: ${CLIENT_YAML}"
export VPS_IP HY2_PORT HY2_PASS HY2_SNI CLIENT_NAME_PREFIX
if [[ "${HAS_REALITY}" == "1" ]]; then
    export REALITY_PORT REALITY_UUID REALITY_PUBKEY REALITY_SHORT_ID REALITY_SNI
fi

envsubst < "${KIT_DIR}/templates/client.yaml.tmpl" > "${CLIENT_YAML}"
chmod 644 "${CLIENT_YAML}"

# === 验证渲染结果 (无残留 ${} 占位符) ===
# shellcheck disable=SC2016
if grep -qE '\$\{[A-Z_]+\}' "${CLIENT_YAML}"; then
    log_error "Unresolved template variables in client yaml:"
    grep -Eo '\$\{[A-Z_]+\}' "${CLIENT_YAML}" | sort -u
    exit 1
fi

# === F-CN-8: Reality 块静态字段检查(grep 锚定,不引入 yq)===
if [[ "${HAS_REALITY}" == "1" ]]; then
    required_strings=(
        "name: \"${CLIENT_NAME_PREFIX}-reality\""
        "type: vless"
        "flow: xtls-rprx-vision"
        "tls: true"
        "servername: ${REALITY_SNI}"
        "public-key: ${REALITY_PUBKEY}"
        "short-id: ${REALITY_SHORT_ID}"
        "client-fingerprint: chrome"
        "port: ${REALITY_PORT}"
        "uuid: \"${REALITY_UUID}\""
    )
    for s in "${required_strings[@]}"; do
        if ! grep -qF "${s}" "${CLIENT_YAML}"; then
            log_error "Reality yaml missing required string: ${s}"
            exit 1
        fi
    done
    log_info "Reality yaml static field check ✓"
fi

log_info "Client yaml generated: ${CLIENT_YAML}"
log_info "Import to Clash Verge Rev: delete old config → import → activate"

mark_step_done "08-gen-client-yaml"
step_ok "08-gen-client-yaml"
