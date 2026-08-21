#!/usr/bin/env bash
# 99-uninstall.sh — 完整逆操作回滚(三档 scope)
# 跟 spec v3 §7 资源矩阵一致。本机模型。
#
# Usage:
#   ./99-uninstall.sh                              # 交互;默认 full
#   UNINSTALL_SCOPE=full ./99-uninstall.sh         # 卸 SSH/sysctl/Hy2/Reality/panel/ufw 全部
#   UNINSTALL_SCOPE=reality-only ./99-uninstall.sh # 只刨 Reality inbound + ufw rule,panel 保留
#   UNINSTALL_SCOPE=hysteria-only ./99-uninstall.sh# 只刨 Hy2,Reality + panel 保留
#   UNINSTALL_KEEP_BACKUP=1 ./99-uninstall.sh      # 保留 db 备份
#   UNINSTALL_PURGE_LOCAL=1 ./99-uninstall.sh      # 自动 shred output/ 本地文件

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=/dev/null
source "${KIT_DIR}/config.env"
# shellcheck source=/dev/null
[[ -f "${RUNTIME_ENV}" ]] && source "${RUNTIME_ENV}"

# Default scope
UNINSTALL_SCOPE="${UNINSTALL_SCOPE:-full}"
case "${UNINSTALL_SCOPE}" in
    full|reality-only|hysteria-only) : ;;
    *) log_error "Invalid UNINSTALL_SCOPE='${UNINSTALL_SCOPE}' (use: full|reality-only|hysteria-only)"; exit 1 ;;
esac

state_init

echo "⚠️  vpn-deploy-kit UNINSTALL — scope=${UNINSTALL_SCOPE}"
echo ""
case "${UNINSTALL_SCOPE}" in
    full)
        cat <<EOF
Will remove:
  - Reality inbound (sqlite DELETE by inbound_id)
  - 3x-ui panel (x-ui uninstall)
  - Hysteria2 binary, config, cert, systemd service, user
  - SSH hardening drop-in (restore original sshd_config)
  - fail2ban / sysctl / ufw vpn-deploy-kit rules (by comment)
  - output/ rotated to .uninstalled-<ts>
EOF
        ;;
    reality-only)
        cat <<EOF
Will remove:
  - Reality inbound (sqlite DELETE by inbound_id from state.json)
  - ufw rule 'vpn-deploy-kit:reality' (by comment)
  - .step-03 / .step-04 markers + state.json step.03/step.04 fields
  - Reality fields from runtime.env + secrets.env

Will KEEP:
  - 3x-ui panel binary/db (orphan, but not removed)
  - Hysteria2, SSH/sysctl/fail2ban hardening
EOF
        ;;
    hysteria-only)
        cat <<EOF
Will remove:
  - Hysteria2 binary, config, cert, systemd service, user
  - ufw rule 'vpn-deploy-kit:hy2' (by comment)
  - .step-05 / .step-06 markers + state.json step.05/step.06 fields
  - HY2_* fields from runtime.env + secrets.env

Will KEEP:
  - Reality inbound, 3x-ui panel, SSH/sysctl/fail2ban hardening
EOF
        ;;
esac

echo ""
echo "Will NOT remove (any scope):"
echo "  - Your authorized_keys entries (manual review recommended)"
echo "  - apt-installed packages (fail2ban, sqlite3, etc.)"
echo ""

if [[ "${UNINSTALL_FORCE:-0}" != "1" ]]; then
    read -rp "Continue? [y/N] " confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        echo "Aborted"
        exit 0
    fi
fi

# ============================================================================
# Helper:strip a key=value (and similar prefixed keys) from runtime.env
# ============================================================================
strip_runtime_keys() {
    local prefix="$1"
    [[ -f "${RUNTIME_ENV}" ]] || return 0
    sed -i "/^${prefix}/d" "${RUNTIME_ENV}"
}

strip_secrets_env_keys() {
    local prefix="$1"
    local sf
    sf=$(secrets_env_file)
    [[ -f "${sf}" ]] || return 0
    sed -i "/^${prefix}/d" "${sf}"
}

# ============================================================================
# Section: Reality (run if full or reality-only)
# ============================================================================
remove_reality() {
    log_info "[Reality] Removing inbound + ufw rule"

    local inbound_id reality_port
    inbound_id=$(state_get "step.04.inbound_id" "")
    reality_port=$(state_get "step.04.reality_port" "${REALITY_PORT_ACTUAL:-${REALITY_PORT:-}}")

    if [[ -z "${inbound_id}" ]]; then
        log_warn "[Reality] state.step.04.inbound_id missing; skipping sqlite DELETE"
    elif [[ ! -f /etc/x-ui/x-ui.db ]]; then
        log_warn "[Reality] x-ui.db missing; skipping sqlite DELETE"
    else
        log_info "[Reality] DELETE inbound id=${inbound_id} + client_traffics"
        sqlite3 /etc/x-ui/x-ui.db <<SQL || log_warn "[Reality] sqlite DELETE failed (continuing)"
BEGIN IMMEDIATE;
DELETE FROM client_traffics WHERE inbound_id=${inbound_id};
DELETE FROM inbounds WHERE id=${inbound_id};
COMMIT;
SQL

        # Verify by id (NOT global grep config.json — F-CN spec v3 §7.2)
        local remaining
        remaining=$(sqlite3 /etc/x-ui/x-ui.db "SELECT id FROM inbounds WHERE id=${inbound_id}" 2>/dev/null || true)
        if [[ -n "${remaining}" ]]; then
            log_warn "[Reality] inbound id=${inbound_id} still in db after DELETE"
        else
            log_info "[Reality] inbound id=${inbound_id} confirmed removed"
        fi

        # x-ui restart so xray drops the inbound
        x-ui restart >/dev/null 2>&1 || log_warn "[Reality] x-ui restart failed"
        sleep 2

        # If port was known, verify xray is no longer listening on it
        if [[ -n "${reality_port}" ]]; then
            if ss -tlnpH "sport = :${reality_port}" 2>/dev/null | grep -q xray; then
                log_warn "[Reality] xray STILL listening on :${reality_port} after restart"
            else
                log_info "[Reality] xray no longer listening on :${reality_port}"
            fi
        fi
    fi

    # F-CN-4: ufw delete by comment only
    ufw_delete_by_comment "vpn-deploy-kit:reality"

    # Clean local state
    rm -f "${OUTPUT_DIR}/.step-03-install-3xui" "${OUTPUT_DIR}/.step-04-add-reality"
    strip_runtime_keys "REALITY_"
    strip_runtime_keys "PANEL_"
    strip_secrets_env_keys "REALITY_PRIVKEY"
    # NOTE: PANEL_PASS stays in secrets.env unless full scope (panel is being kept here)

    # state.json: drop step.03/04 entries when reality-only;
    # full scope blows away the whole file later
    if [[ "${UNINSTALL_SCOPE}" == "reality-only" ]]; then
        local tmp
        tmp=$(mktemp -p "${OUTPUT_DIR}" .state.json.XXXXXX)
        if jq 'del(.step["03"], .step["04"])' "${STATE_JSON}" > "${tmp}" 2>/dev/null; then
            mv -f "${tmp}" "${STATE_JSON}"
        else
            rm -f "${tmp}"
        fi
        chmod 600 "${STATE_JSON}" 2>/dev/null || true
    fi

    # db backup cleanup (unless UNINSTALL_KEEP_BACKUP=1)
    if [[ "${UNINSTALL_KEEP_BACKUP:-0}" != "1" ]]; then
        local backup_04
        backup_04=$(state_get "step.04.pre_insert_backup_path" "")
        [[ -n "${backup_04}" && -f "${backup_04}" ]] && rm -f "${backup_04}"
        # In full scope, also remove 03 backup
        if [[ "${UNINSTALL_SCOPE}" == "full" ]]; then
            local backup_03
            backup_03=$(state_get "step.03.db_backup_path" "")
            [[ -n "${backup_03}" && -f "${backup_03}" ]] && rm -f "${backup_03}"
        fi
    fi
}

# ============================================================================
# Section: 3x-ui panel (only on full scope; spec v3 §7.1)
# ============================================================================
remove_panel() {
    log_info "[Panel] Removing 3x-ui"
    if command -v x-ui &>/dev/null; then
        # `x-ui uninstall` is interactive; pipe yes
        yes | x-ui uninstall >/dev/null 2>&1 || log_warn "[Panel] x-ui uninstall failed"
    fi
    # Defensive: ensure files gone
    rm -rf /usr/local/x-ui /etc/x-ui /var/log/x-ui /usr/bin/x-ui
    rm -f /etc/systemd/system/x-ui.service
    systemctl daemon-reload 2>/dev/null || true
}

# ============================================================================
# Section: Hysteria2 (run if full or hysteria-only)
# ============================================================================
remove_hysteria2() {
    log_info "[Hysteria2] Removing service + binary + user"

    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        systemctl stop hysteria-server || true
    fi
    if systemctl is-enabled --quiet hysteria-server 2>/dev/null; then
        systemctl disable hysteria-server || true
    fi
    rm -f /etc/systemd/system/hysteria-server.service
    systemctl daemon-reload

    rm -f /usr/local/bin/hysteria-server
    rm -rf /etc/hysteria

    if id hysteria &>/dev/null; then
        userdel hysteria || true
    fi

    ufw_delete_by_comment "vpn-deploy-kit:hy2"

    rm -f "${OUTPUT_DIR}/.step-05-install-hysteria" "${OUTPUT_DIR}/.step-06-deploy-hysteria-cfg"
    strip_runtime_keys "HY2_"
    strip_secrets_env_keys "HY2_"

    if [[ "${UNINSTALL_SCOPE}" == "hysteria-only" ]]; then
        local tmp
        tmp=$(mktemp -p "${OUTPUT_DIR}" .state.json.XXXXXX)
        if jq 'del(.step["05"], .step["06"])' "${STATE_JSON}" > "${tmp}" 2>/dev/null; then
            mv -f "${tmp}" "${STATE_JSON}"
        else
            rm -f "${tmp}"
        fi
        chmod 600 "${STATE_JSON}" 2>/dev/null || true
    fi
}

# ============================================================================
# Section: SSH/sysctl/fail2ban hardening rollback (full only)
# ============================================================================
remove_hardening() {
    log_info "[Hardening] Removing SSH/sysctl/fail2ban drop-ins"

    rm -f /etc/ssh/sshd_config.d/99-vpn-deploy-kit.conf
    if systemctl is-active --quiet sshd; then
        systemctl reload sshd || systemctl restart sshd || true
    fi

    rm -f /etc/fail2ban/jail.d/99-vpn-deploy-kit.local
    if systemctl is-active --quiet fail2ban; then
        systemctl reload fail2ban || systemctl restart fail2ban || true
    fi

    rm -f /etc/sysctl.d/99-vpn-deploy-kit.conf
    sysctl --system 2>/dev/null || true

    # ufw: any remaining vpn-deploy-kit comments (catch-all for SSH-new, etc.)
    if command -v ufw &>/dev/null; then
        while ufw status numbered 2>/dev/null | grep -q "# vpn-deploy-kit:"; do
            local rule_num
            rule_num=$(ufw status numbered 2>/dev/null | grep "# vpn-deploy-kit:" | head -1 | grep -oP '^\[\s*\K\d+')
            if [[ -n "${rule_num}" ]]; then
                yes | ufw delete "${rule_num}" >/dev/null 2>&1 || break
            else
                break
            fi
        done
    fi
}

# ============================================================================
# Section: local output cleanup
# ============================================================================
rotate_or_purge_local() {
    local mode="$1"   # rotate | purge | partial
    local ts
    ts=$(date +%s)

    case "${mode}" in
        rotate)
            for f in "${OUTPUT_DIR}"/secrets-*.md "${OUTPUT_DIR}"/secrets-*.env \
                     "${OUTPUT_DIR}"/state.json "${OUTPUT_DIR}"/runtime.env \
                     "${OUTPUT_DIR}"/deploy.log; do
                [[ -f "${f}" ]] && mv "${f}" "${f}.uninstalled-${ts}" 2>/dev/null || true
            done
            ;;
        purge)
            for f in "${OUTPUT_DIR}"/secrets-*.md "${OUTPUT_DIR}"/secrets-*.env \
                     "${OUTPUT_DIR}"/state.json "${OUTPUT_DIR}"/runtime.env \
                     "${OUTPUT_DIR}"/deploy.log; do
                [[ -f "${f}" ]] && shred -u "${f}" 2>/dev/null || true
            done
            ;;
        partial)
            # for reality-only / hysteria-only: keys already stripped in section
            # functions; nothing to rotate at file level
            :
            ;;
    esac
}

# ============================================================================
# Main dispatch by scope
# ============================================================================
case "${UNINSTALL_SCOPE}" in
    full)
        # Reality first (so x-ui restart doesn't run on uninstalled panel)
        if [[ -f /etc/x-ui/x-ui.db ]]; then
            remove_reality
        fi
        remove_panel
        remove_hysteria2
        remove_hardening

        # Final: rotate or purge local
        if [[ "${UNINSTALL_PURGE_LOCAL:-0}" == "1" ]]; then
            rotate_or_purge_local purge
        else
            rotate_or_purge_local rotate
        fi
        ;;
    reality-only)
        remove_reality
        rotate_or_purge_local partial
        ;;
    hysteria-only)
        remove_hysteria2
        rotate_or_purge_local partial
        ;;
esac

log_info "Uninstall (${UNINSTALL_SCOPE}) complete"
echo ""
echo "⚠️  Recommended manual steps:"
echo "  1. Review ~/.ssh/authorized_keys and remove unwanted entries"

if [[ "${UNINSTALL_SCOPE}" == "full" ]]; then
    echo "  2. Verify SSH access still works on original port ${SSH_PORT:-22}"
    echo "  3. apt purge fail2ban sqlite3 jq (if you want to remove packages too)"
fi

if [[ "${UNINSTALL_PURGE_LOCAL:-0}" != "1" ]]; then
    echo ""
    echo "⚠️  Local files retained (含 Reality privkey / panel 凭据):"
    if [[ "${UNINSTALL_SCOPE}" == "full" ]]; then
        echo "  output/secrets-*.md.uninstalled-*"
        echo "  output/secrets-*.env.uninstalled-*"
        echo "  output/state.json.uninstalled-*"
        echo "  output/runtime.env.uninstalled-*"
        echo "  output/deploy.log.uninstalled-*"
    fi
    echo "  Secure delete: shred -u <file>"
    echo "  (Or: UNINSTALL_PURGE_LOCAL=1 ./scripts/99-uninstall.sh to auto-shred)"
fi

step_ok "99-uninstall"
