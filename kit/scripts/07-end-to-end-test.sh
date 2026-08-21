#!/usr/bin/env bash
# 07-end-to-end-test.sh — Hysteria2 协议层端到端握手测试
# ⚠️ 密码来源: output/secrets-*.md (source-of-truth)，绝不 grep server config
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
source "${KIT_DIR}/config.env"
[[ -f "${RUNTIME_ENV}" ]] && source "${RUNTIME_ENV}"

init_output

# Idempotent guard
if step_done "07-end-to-end-test"; then
    step_ok "07-end-to-end-test"
    exit 0
fi

if [[ -z "${HY2_PORT:-}" ]]; then
    log_error "HY2_PORT not set"
    exit 1
fi

# === 关键: 密码从 secrets 文件读取 (不 grep server config) ===
if [[ -z "${HY2_PASS:-}" ]]; then
    log_error "HY2_PASS not in runtime.env — must come from 06 output"
    exit 1
fi
log_info "Using HY2_PASS from runtime.env (source-of-truth: secrets file)"

# Dry-run: 无法做真实协议握手，显式 SKIP
if [[ "${BOOTSTRAP_DRY_RUN:-0}" == "1" ]]; then
    log_warn "DRY-RUN: skipping protocol handshake test (requires real service)"
    log_warn "DRY-RUN: on real VPS, this test will:"
    log_warn "  1. Check hysteria-server is active"
    log_warn "  2. Start local Hysteria2 client on 127.0.0.1:${HY2_PORT}"
    log_warn "  3. Curl through SOCKS5 proxy to verify connectivity"
    mark_step_done "07-end-to-end-test"
    step_ok "07-end-to-end-test"
    exit 0
fi

# === 1. 检查服务运行 ===
if ! systemctl is-active --quiet hysteria-server; then
    log_error "hysteria-server is not running"
    journalctl -u hysteria-server --no-pager -n 30
    exit 1
fi
log_info "hysteria-server is active ✓"

# === 2. 本地回环握手测试 ===
log_info "Running local loopback Hysteria2 handshake test"

TEST_CFG="/tmp/hy2-test-config.yaml"
TEST_SOCKS_PORT=10808
HY2_BIN="/usr/local/bin/hysteria-server"

# 生成临时客户端配置
cat > "${TEST_CFG}" << EOF
server: 127.0.0.1:${HY2_PORT}

auth: ${HY2_PASS}

tls:
  sni: ${HY2_SNI}
  insecure: true

socks5:
  listen: 127.0.0.1:${TEST_SOCKS_PORT}
EOF

cleanup() {
    kill "${TEST_PID:-}" 2>/dev/null || true
    rm -f "${TEST_CFG}"
}
trap cleanup EXIT

# 启动临时客户端 (同 binary，不同 subcommand)
"${HY2_BIN}" client --config "${TEST_CFG}" &>/tmp/hy2-test-client.log &
TEST_PID=$!
sleep 2

# 通过 SOCKS5 代理测试连通性
if curl -x socks5h://127.0.0.1:${TEST_SOCKS_PORT} \
    --connect-timeout 10 \
    -fsSL \
    https://www.google.com/generate_204 &>/dev/null; then
    log_info "Hysteria2 loopback test PASSED ✓"
else
    log_warn "Loopback test via google.com failed (may be GFW), trying alternative"
    if curl -x socks5h://127.0.0.1:${TEST_SOCKS_PORT} \
        --connect-timeout 10 \
        -fsSL \
        https://cp.cloudflare.com &>/dev/null; then
        log_info "Hysteria2 loopback test (cloudflare) PASSED ✓"
    else
        log_error "Hysteria2 loopback test FAILED"
        echo "=== Server log ==="
        journalctl -u hysteria-server --no-pager -n 20
        echo "=== Client log ==="
        cat /tmp/hy2-test-client.log
        exit 1
    fi
fi

# 清理
cleanup
trap - EXIT

# ============================================================================
# Reality 端到端段(spec v3 §5;只有当 step.04 完成时才跑)
# 字段来源:runtime.env(REALITY_UUID/PUBKEY/SHORT_ID/SUB_ID/SNI)+
#         secrets-*.env(REALITY_PRIVKEY 这里不需要,client 用 pubkey)
# ============================================================================
state_init
if [[ "$(state_get step.04.completed false)" == "true" ]]; then
    log_info "Reality e2e test (step.04 completed)"

    reality_port_normalize
    reality_port="${REALITY_PORT_ACTUAL:-${REALITY_PORT:-}}"

    if [[ -z "${reality_port}" || -z "${REALITY_UUID:-}" \
          || -z "${REALITY_PUBKEY:-}" || -z "${REALITY_SHORT_ID:-}" \
          || -z "${REALITY_SNI:-}" ]]; then
        log_error "Reality runtime fields missing; rerun 04"
        exit 1
    fi

    XRAY_BIN_CLIENT=/usr/local/x-ui/bin/xray-linux-amd64
    REALITY_TEST_CFG="/tmp/reality-test-client.json"
    REALITY_SOCKS_PORT=10809
    REALITY_TEST_PID=""

    # Build test-client.json with fields strictly from runtime.env (NOT grepping
    # /usr/local/x-ui/bin/config.json — that would reintroduce the loopback trap
    # in DESIGN.md §4.6 #3/#4).
    cat > "${REALITY_TEST_CFG}" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": ${REALITY_SOCKS_PORT},
    "listen": "127.0.0.1",
    "protocol": "socks",
    "settings": {"udp": true}
  }],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext": [{
      "address": "127.0.0.1",
      "port": ${reality_port},
      "users": [{
        "id": "${REALITY_UUID}",
        "encryption": "none",
        "flow": "xtls-rprx-vision"
      }]
    }]},
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "serverName": "${REALITY_SNI}",
        "fingerprint": "chrome",
        "publicKey": "${REALITY_PUBKEY}",
        "shortId": "${REALITY_SHORT_ID}",
        "spiderX": "/"
      }
    }
  }]
}
EOF

    # F-CN-5: trap EXIT immediately after backgrounding xray to ensure cleanup
    # even when set -e triggers on a failing curl
    "${XRAY_BIN_CLIENT}" run -c "${REALITY_TEST_CFG}" >/tmp/reality-test-xray.log 2>&1 &
    REALITY_TEST_PID=$!
    trap 'kill "${REALITY_TEST_PID}" 2>/dev/null || true; wait "${REALITY_TEST_PID}" 2>/dev/null || true; rm -f "${REALITY_TEST_CFG}" /tmp/reality-test-xray.log' EXIT
    sleep 3

    # F-CN-5: if-then explicit (not curl; ...; test_result=$? which set -e kills)
    if curl -sf --socks5 127.0.0.1:${REALITY_SOCKS_PORT} \
            --connect-timeout 5 --max-time 10 \
            https://www.gstatic.com/generate_204 >/dev/null; then
        log_info "Reality e2e test PASSED ✓"
    elif curl -sf --socks5 127.0.0.1:${REALITY_SOCKS_PORT} \
              --connect-timeout 5 --max-time 10 \
              https://cp.cloudflare.com >/dev/null; then
        log_info "Reality e2e test (cloudflare) PASSED ✓"
    else
        log_error "Reality e2e test FAILED — dumping diagnostics"
        echo "=== test-client config ==="
        cat "${REALITY_TEST_CFG}"
        echo "=== xray client stderr ==="
        cat /tmp/reality-test-xray.log
        echo "=== x-ui journalctl (last 30) ==="
        journalctl -u x-ui --no-pager -n 30
        exit 1
    fi

    # trap EXIT cleanup runs on normal exit too
    log_info "Reality e2e cleanup (kill test xray client)"
else
    log_info "step.04 not completed; skipping Reality e2e test"
fi

mark_step_done "07-end-to-end-test"
step_ok "07-end-to-end-test"
