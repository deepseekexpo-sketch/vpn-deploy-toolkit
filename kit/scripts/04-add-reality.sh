#!/usr/bin/env bash
# 04-add-reality.sh — 给 3x-ui 加 Reality inbound(方案 C:直改 sqlite)
# 跟 spec v3 §3 一致。本机模型。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=/dev/null
source "${KIT_DIR}/config.env"
# shellcheck source=/dev/null
[[ -f "${RUNTIME_ENV}" ]] && source "${RUNTIME_ENV}"

init_output
state_init

# ============================================================================
# Step 1: Idempotent + prereqs
# ============================================================================
if step_done "04-add-reality"; then
    step_ok "04-add-reality"
    exit 0
fi

# failure_count cap (Ops F-5)
cnt04=$(state_get "step.04.failure_count" "0")
if [[ "${cnt04}" -ge 2 ]]; then
    log_error "step 04 has failed ${cnt04} times. Run ./scripts/99-uninstall.sh --scope=reality-only and investigate"
    exit 2
fi

# step.03 must be complete
if [[ "$(state_get step.03.completed false)" != "true" ]]; then
    log_error "step.03 not completed yet (state.json). Aborting."
    exit 1
fi
[[ -f /etc/x-ui/x-ui.db ]] || { log_error "/etc/x-ui/x-ui.db missing"; exit 1; }

# Normalize Reality port (compat shim until Batch 3 cleanup)
reality_port_normalize
reality_port="${REALITY_PORT_ACTUAL:-${REALITY_PORT:-}}"
if [[ -z "${reality_port}" ]]; then
    log_error "REALITY_PORT_ACTUAL not set (02-port-probe should have set it)"
    exit 1
fi

# ============================================================================
# Step 2: Charset sanity (whitelist; prevents SQL injection via heredoc vars)
# ============================================================================
assert_charset "${reality_port}" '^[0-9]+$' "REALITY_PORT must be numeric"
assert_charset "${REALITY_SNI}" '^[a-zA-Z0-9.-]+$' "REALITY_SNI must be hostname charset"
assert_charset "${CLIENT_NAME_PREFIX}" '^[A-Za-z0-9_-]+$' "CLIENT_NAME_PREFIX charset"

INBOUND_TAG="inbound-${reality_port}"
INBOUND_REMARK="${CLIENT_NAME_PREFIX}-reality"
assert_charset "${INBOUND_TAG}" '^[A-Za-z0-9_-]+$' "INBOUND_TAG charset"
assert_charset "${INBOUND_REMARK}" '^[A-Za-z0-9_-]+$' "INBOUND_REMARK charset"

log_info "Adding Reality inbound: tag=${INBOUND_TAG} port=${reality_port} sni=${REALITY_SNI}"

# ============================================================================
# Step 3: Duplicate detection + 04-specific db backup
# ============================================================================
existing_id=$(sqlite3 /etc/x-ui/x-ui.db \
    "SELECT id FROM inbounds WHERE tag='${INBOUND_TAG}' LIMIT 1" 2>/dev/null || true)
if [[ -n "${existing_id}" ]]; then
    if [[ "${BOOTSTRAP_FORCE:-0}" == "1" ]]; then
        log_warn "Existing inbound id=${existing_id} (tag=${INBOUND_TAG}); FORCE=1 → will delete + reinsert"
    else
        log_error "Inbound tag=${INBOUND_TAG} already exists (id=${existing_id})."
        log_error "Use BOOTSTRAP_FORCE=1 to overwrite, or run 99-uninstall --scope=reality-only first."
        exit 1
    fi
fi

db_backup_04="/etc/x-ui/x-ui.db.bak.before-04-add-reality.$(date +%s)"
cp -p /etc/x-ui/x-ui.db "${db_backup_04}" \
    || { log_error "failed to backup db"; exit 1; }
state_set "step.04.pre_insert_backup_path" "${db_backup_04}"
log_info "DB backup: ${db_backup_04}"

# ============================================================================
# rollback_04 (called on any verify failure below)
# ============================================================================
tmp_dir=""
rollback_04() {
    local reason="$1"
    log_error "rollback_04: ${reason}"

    # 1. Restore db
    if [[ -n "${db_backup_04}" && -f "${db_backup_04}" ]]; then
        cp -p "${db_backup_04}" /etc/x-ui/x-ui.db 2>/dev/null || true
    fi

    # 2. Restart x-ui so old state takes effect
    x-ui restart >/dev/null 2>&1 || true
    sleep 2

    # 3. Drop ufw rule by comment (F-CN-4: never by raw port in rollback)
    ufw_delete_by_comment "vpn-deploy-kit:reality" >/dev/null 2>&1 || true

    # 4. Bump failure_count
    local new_cnt=$((cnt04 + 1))
    state_set "step.04.failure_count" "${new_cnt}"
    state_set "step.04.last_failure" "${reason}"

    # 5. Troubleshoot bundle (Ops F-11)
    local diag
    diag="${OUTPUT_DIR}/troubleshoot-04-$(date +%s).log"
    {
        echo "=== rollback_04 reason: ${reason} ==="
        echo
        echo "=== x-ui -v ==="
        x-ui -v 2>&1 || true
        echo
        echo "=== sqlite3 .schema inbounds ==="
        sqlite3 /etc/x-ui/x-ui.db ".schema inbounds" 2>&1 || true
        echo
        echo "=== current inbounds (after restore) ==="
        sqlite3 /etc/x-ui/x-ui.db "SELECT id, tag, port, enable FROM inbounds" 2>&1 || true
        echo
        echo "=== /usr/local/x-ui/bin/config.json ==="
        cat /usr/local/x-ui/bin/config.json 2>&1 || true
        echo
        echo "=== journalctl -u x-ui -n 50 ==="
        journalctl -u x-ui --no-pager -n 50 2>&1 || true
    } > "${diag}"
    log_error "Troubleshoot bundle: ${diag}"

    if [[ "${new_cnt}" -ge 2 ]]; then
        log_error "step 04 failed twice. Investigate before retrying."
        exit 2
    fi
    exit 1
}

# Set trap for tmp_dir cleanup (even on exit/rollback)
trap '[[ -n "${tmp_dir:-}" && -d "${tmp_dir}" ]] && { shred -u "${tmp_dir}"/*.json 2>/dev/null || true; rm -rf "${tmp_dir}"; }' EXIT

# ============================================================================
# Step 4: Generate Reality keypair + UUID + shortID
# ============================================================================
xray_bin=/usr/local/x-ui/bin/xray-linux-amd64
[[ -x "${xray_bin}" ]] || rollback_04 "xray binary missing at ${xray_bin}"

# Parse "Private key: X\nPublic key: Y" robustly with -F': ' (Bash F-2)
REALITY_PRIVKEY=""
REALITY_PUBKEY=""
output=$("${xray_bin}" x25519)
# 兼容新旧 xray 输出格式:
#   旧版: "Private key: X" / "Public key: Y"
#   26.x: "PrivateKey: X"   / "Password (PublicKey): Y"
REALITY_PRIVKEY=$(printf '%s\n' "${output}" | grep -iE 'private[[:space:]]*key' | head -n1 | sed -E 's/^[^:]*:[[:space:]]*//')
REALITY_PUBKEY=$(printf '%s\n'  "${output}" | grep -iE 'public[[:space:]]*key'  | head -n1 | sed -E 's/^[^:]*:[[:space:]]*//')
[[ -n "${REALITY_PRIVKEY}" && -n "${REALITY_PUBKEY}" ]] \
    || rollback_04 "xray x25519 output parse failed (priv='${REALITY_PRIVKEY}' pub='${REALITY_PUBKEY}')"

# privkey must be url-safe base64 (charset for envsubst safety)
assert_charset "${REALITY_PRIVKEY}" '^[A-Za-z0-9_-]+$' "REALITY_PRIVKEY must be url-safe base64"
assert_charset "${REALITY_PUBKEY}"  '^[A-Za-z0-9_-]+$' "REALITY_PUBKEY must be url-safe base64"

REALITY_UUID=$(uuidgen)
REALITY_SHORT_ID=$(openssl rand -hex 8)
REALITY_SUB_ID=$(openssl rand -hex 8)

# ============================================================================
# Step 5: Render templates to /root/ (700 inherited) + trap shred
# ============================================================================
tmp_dir=$(mktemp -d -p /root vpn-deploy-kit-04.XXXXXX)
chmod 700 "${tmp_dir}"

export REALITY_UUID REALITY_SUB_ID REALITY_SNI REALITY_PRIVKEY REALITY_PUBKEY REALITY_SHORT_ID CLIENT_NAME_PREFIX

envsubst < "${KIT_DIR}/templates/reality-settings.json.tmpl"        > "${tmp_dir}/settings.json"
envsubst < "${KIT_DIR}/templates/reality-stream-settings.json.tmpl" > "${tmp_dir}/stream.json"
chmod 600 "${tmp_dir}/settings.json" "${tmp_dir}/stream.json"

# Reject unrendered placeholders (intentional literal '${' search)
# shellcheck disable=SC2016
if grep -q '\${' "${tmp_dir}/settings.json" || grep -q '\${' "${tmp_dir}/stream.json"; then
    rollback_04 "envsubst left unrendered \${...} placeholders"
fi

# Pre-INSERT json_valid (Codex P1-3)
jq empty < "${tmp_dir}/settings.json" \
    || rollback_04 "settings.json invalid JSON after envsubst"
jq empty < "${tmp_dir}/stream.json" \
    || rollback_04 "stream.json invalid JSON after envsubst"

# ============================================================================
# Step 6: Transactional INSERT with CAST AS TEXT (F-CN-6)
# ============================================================================
log_info "INSERT inbound + client_traffics (transactional)"
sqlite_out=$(sqlite3 /etc/x-ui/x-ui.db <<SQL
.parameter init
.parameter set :remark '${INBOUND_REMARK}'
.parameter set :tag    '${INBOUND_TAG}'
.parameter set :port   ${reality_port}
.parameter set :email  '${CLIENT_NAME_PREFIX}'

BEGIN IMMEDIATE;

-- Force-delete if FORCE=1 (for reruns)
DELETE FROM client_traffics WHERE inbound_id IN (SELECT id FROM inbounds WHERE tag = :tag);
DELETE FROM inbounds WHERE tag = :tag;

INSERT INTO inbounds (
    user_id, up, down, total, all_time, remark, enable, expiry_time,
    traffic_reset, last_traffic_reset_time, listen, port, protocol,
    settings, stream_settings, tag, sniffing
) VALUES (
    1, 0, 0, 0, 0, :remark, 1, 0,
    'never', 0, '', :port, 'vless',
    CAST(readfile('${tmp_dir}/settings.json') AS TEXT),
    CAST(readfile('${tmp_dir}/stream.json')   AS TEXT),
    :tag,
    '{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'
);

-- v2.9.4 client_traffics has 'reset' and 'last_online' cols (SUMMARY.md §4)
INSERT INTO client_traffics (
    inbound_id, enable, email, up, down, all_time, expiry_time, total, reset, last_online
) VALUES (
    (SELECT id FROM inbounds WHERE tag = :tag), 1, :email, 0, 0, 0, 0, 0, 0, 0
);

COMMIT;
SQL
) || rollback_04 "sqlite INSERT failed: ${sqlite_out}"

# ============================================================================
# Step 7: post-check (typeof + json_valid + enable=1)
# ============================================================================
inbound_id=$(sqlite3 /etc/x-ui/x-ui.db "SELECT id FROM inbounds WHERE tag='${INBOUND_TAG}'")
[[ -n "${inbound_id}" ]] || rollback_04 "inbound id not found after INSERT"

# F-CN-6: typeof must be text|text (CAST AS TEXT effective)
types=$(sqlite3 /etc/x-ui/x-ui.db \
    "SELECT typeof(settings) || '|' || typeof(stream_settings) FROM inbounds WHERE id=${inbound_id}")
[[ "${types}" == "text|text" ]] \
    || rollback_04 "settings/stream typeof != text|text (got: ${types}) — CAST AS TEXT failed"

# Codex P1-3: json_valid both fields
jv=$(sqlite3 /etc/x-ui/x-ui.db \
    "SELECT json_valid(settings) || '|' || json_valid(stream_settings) FROM inbounds WHERE id=${inbound_id}")
[[ "${jv}" == "1|1" ]] \
    || rollback_04 "json_valid check failed (got: ${jv})"

# enable must be 1 (otherwise silent skip)
en=$(sqlite3 /etc/x-ui/x-ui.db "SELECT enable FROM inbounds WHERE id=${inbound_id}")
[[ "${en}" == "1" ]] || rollback_04 "enable=${en} (expected 1) - would silent skip"

state_set "step.04.inbound_id" "${inbound_id}"
state_set "step.04.inbound_tag" "${INBOUND_TAG}"
state_set "step.04.inbound_remark" "${INBOUND_REMARK}"

# ============================================================================
# Step 8: ufw allow Reality port (by comment; F-CN-4)
# ============================================================================
ufw allow "${reality_port}/tcp" comment 'vpn-deploy-kit:reality' >/dev/null \
    || log_warn "ufw allow ${reality_port}/tcp failed (may already be allowed)"

# ============================================================================
# Step 9: x-ui restart + wait for xray to listen
# ============================================================================
restart_ts=$(date +%s)
log_info "Restarting x-ui (xray will reload config.json)"
x-ui restart >/dev/null 2>&1 || rollback_04 "x-ui restart failed"

xray_listening=""
for i in 1 2 3 5 8 13 21; do
    sleep "${i}"
    if ss -tlnpH "sport = :${reality_port}" 2>/dev/null | grep -q xray; then
        xray_listening=1
        break
    fi
done
[[ -n "${xray_listening}" ]] || rollback_04 "xray not listening on :${reality_port} after retry loop"

# ============================================================================
# Step 10: silent skip three-piece defense (Architect F-7 + Ops F-3 + Bash F-4)
# ============================================================================

# Defense 1: process on this port really is xray
xray_pid=$(ss -tlnpH "sport = :${reality_port}" 2>/dev/null \
           | awk -F'pid=' '{split($2,a,","); print a[1]; exit}')
[[ -n "${xray_pid}" ]] || rollback_04 "ss returned no pid for :${reality_port}"

xray_exe=$(readlink -f "/proc/${xray_pid}/exe" 2>/dev/null || echo "")
case "${xray_exe}" in
    *xray*) : ;;
    *) rollback_04 "process on :${reality_port} is '${xray_exe}', not xray" ;;
esac

# Defense 2: config.json inbound on this port really has security=reality
config_json=/usr/local/x-ui/bin/config.json
security=$(jq -r --arg p "${reality_port}" \
    '.inbounds[]? | select(.port==($p|tonumber)) | .streamSettings.security' \
    "${config_json}" 2>/dev/null || echo "")
[[ "${security}" == "reality" ]] \
    || rollback_04 "config.json inbound on :${reality_port} security='${security}' (expected 'reality')"

# Defense 3: xray process started AFTER x-ui restart (not a stale fork)
# 宽容差 60s: 规避 restart 返回瞬间新 xray 时间戳比 restart_ts 早 1~2s 的
# 秒级时钟竞态 (真正的陈旧进程会早数分钟, 仍会被捕获)
xray_lstart_human=$(ps -o lstart= -p "${xray_pid}" 2>/dev/null | tr -s ' ' | sed 's/^ //')
if [[ -n "${xray_lstart_human}" ]]; then
    xray_lstart_ts=$(date -d "${xray_lstart_human}" +%s 2>/dev/null || echo "0")
    if [[ $((xray_lstart_ts + 60)) -lt "${restart_ts}" ]]; then
        rollback_04 "xray pid=${xray_pid} started at ${xray_lstart_ts} (>=60s before restart at ${restart_ts}, stale process)"
    fi
fi

# ============================================================================
# Step 11: persist runtime + secrets + state
# ============================================================================
# runtime.env: non-secret reusable values (07/08 consume)
write_runtime "REALITY_PORT_ACTUAL=${reality_port}"
write_runtime "REALITY_SNI=${REALITY_SNI}"
write_runtime "REALITY_UUID=${REALITY_UUID}"
write_runtime "REALITY_PUBKEY=${REALITY_PUBKEY}"
write_runtime "REALITY_SHORT_ID=${REALITY_SHORT_ID}"
write_runtime "REALITY_SUB_ID=${REALITY_SUB_ID}"

# secrets-*.env: privkey ONLY (machine-readable)
write_secrets_env "REALITY_PRIVKEY=${REALITY_PRIVKEY}"

# secrets-*.md: human-readable archive
write_secrets ""
write_secrets "## Reality Inbound ($(date -Iseconds))"
write_secrets "- Inbound id: \`${inbound_id}\`   Tag: \`${INBOUND_TAG}\`"
write_secrets "- Port: \`${reality_port}\`   SNI: \`${REALITY_SNI}\`"
write_secrets "- UUID: \`${REALITY_UUID}\`"
write_secrets "- Pubkey: \`${REALITY_PUBKEY}\`"
write_secrets "- Privkey: \`${REALITY_PRIVKEY}\`   ⚠️ 私钥,泄露需立即重新生成"
write_secrets "- ShortID: \`${REALITY_SHORT_ID}\`   SubID: \`${REALITY_SUB_ID}\`"
write_secrets "- DB backup (04): \`${db_backup_04}\`"

state_set "step.04.completed" "true"

mark_step_done "04-add-reality"
step_ok "04-add-reality"
