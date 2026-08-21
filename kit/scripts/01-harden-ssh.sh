#!/usr/bin/env bash
# 01-harden-ssh.sh — SSH 加固 Phase A (准备新路径，不动旧路径)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
source "${KIT_DIR}/config.env"
[[ -f "${RUNTIME_ENV}" ]] && source "${RUNTIME_ENV}"

init_output

# Idempotent guard
if step_done "01-harden-ssh"; then
    step_ok "01-harden-ssh"
    exit 0
fi

CONF_DROPIN="/etc/ssh/sshd_config.d/99-vpn-deploy-kit.conf"
FAIL2BAN_DROPIN="/etc/fail2ban/jail.d/99-vpn-deploy-kit.local"
SYSCTL_DROPIN="/etc/sysctl.d/99-vpn-deploy-kit.conf"

# === 1. 安装 SSH 公钥 ===
if [[ -n "${SSH_PUBKEY:-}" ]]; then
    log_info "Installing SSH public key"
    run bash -c "
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        if ! grep -qF '${SSH_PUBKEY}' ~/.ssh/authorized_keys 2>/dev/null; then
            echo '${SSH_PUBKEY}' >> ~/.ssh/authorized_keys
            chmod 600 ~/.ssh/authorized_keys
            echo 'Key added'
        else
            echo 'Key already exists'
        fi
    "
else
    log_warn "SSH_PUBKEY not set, skipping key installation"
fi

# === 2. 启用 PubkeyAuthentication ===
log_info "Enabling PubkeyAuthentication"
run bash -c "
    if grep -q '^PubkeyAuthentication no' /etc/ssh/sshd_config; then
        sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    elif ! grep -q '^PubkeyAuthentication' /etc/ssh/sshd_config; then
        echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
    fi
"

# === 3. 配置新 SSH 端口 (Phase A: 新旧并存) ===
log_info "Adding SSH port ${SSH_NEW_PORT} (keeping old port ${SSH_PORT})"
run bash -c "
    mkdir -p /etc/ssh/sshd_config.d
    cat > ${CONF_DROPIN} << EOF
# vpn-deploy-kit managed — do not edit manually
Port ${SSH_PORT}
Port ${SSH_NEW_PORT}
PubkeyAuthentication yes
EOF
"

# === 4. 安装 fail2ban ===
log_info "Installing fail2ban"
if ! command -v fail2ban-client &>/dev/null; then
    run apt-get update -qq
    run apt-get install -y -qq fail2ban
fi

run bash -c "
    cat > ${FAIL2BAN_DROPIN} << EOF
# vpn-deploy-kit managed
[sshd]
enabled = true
port = ${SSH_PORT},${SSH_NEW_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
findtime = 600
EOF
    systemctl enable fail2ban
    systemctl restart fail2ban
"

# === 5. sysctl: BBR + 优化 ===
log_info "Configuring sysctl (BBR + buffer)"
run bash -c "
    cat > ${SYSCTL_DROPIN} << EOF
# vpn-deploy-kit managed
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF
    sysctl --system > /dev/null
"

# === 6. ufw: 放行新端口 + Hysteria2 UDP ===
if command -v ufw &>/dev/null; then
    log_info "Configuring ufw rules"
    run ufw allow "${SSH_NEW_PORT}/tcp" comment "vpn-deploy-kit:ssh-new"
    run ufw allow "${SSH_PORT}/tcp" comment "vpn-deploy-kit:ssh-old"
    # Hysteria2 端口 (HY2_PORT 可能还没确定，先跳过，06 会补)
    run ufw --force enable
fi

# === 7. 重启 sshd (新旧端口并存) ===
log_info "Restarting sshd (both ports active)"
run systemctl restart sshd

# 记录到 runtime.env
write_runtime "SSH_NEW_PORT=${SSH_NEW_PORT}"
write_runtime "SSH_HARDEN_PHASE=A"

mark_step_done "01-harden-ssh"
step_ok "01-harden-ssh"
