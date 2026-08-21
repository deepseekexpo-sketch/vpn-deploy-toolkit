#!/usr/bin/env bash
# vpn-deploy-kit shared library
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${KIT_DIR}/output"
RUNTIME_ENV="${OUTPUT_DIR}/runtime.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Run command or dry-run echo
run() {
    if [[ "${BOOTSTRAP_DRY_RUN:-0}" == "1" ]]; then
        echo "[DRY-RUN] $*"
        return 0
    fi
    "$@"
}

# Init output dir
init_output() {
    mkdir -p "${OUTPUT_DIR}"
    touch "${RUNTIME_ENV}"
}

# Append/update key=value to runtime.env (dedup)
write_runtime() {
    local kv="$1"
    local key="${kv%%=*}"
    if grep -q "^${key}=" "${RUNTIME_ENV}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${kv}|" "${RUNTIME_ENV}"
    else
        echo "${kv}" >> "${RUNTIME_ENV}"
    fi
}

# Get value from runtime.env (fallback to default if key absent / value empty)
get_runtime() {
    local key="$1"
    local default="${2:-}"
    local val
    val=$(grep "^${key}=" "${RUNTIME_ENV}" 2>/dev/null | head -1 | cut -d= -f2-)
    echo "${val:-$default}"
}

# Signal step completion (must be last stdout line)
step_ok() {
    echo "STEP_OK: $1"
}

# Generate random hex
rand_hex() {
    openssl rand -hex "${1:-16}"
}

# Secrets file path
secrets_file() {
    echo "${OUTPUT_DIR}/secrets-${VPS_IP}.md"
}

# Append to secrets file (create if needed)
write_secrets() {
    local sf
    sf=$(secrets_file)
    if [[ ! -f "${sf}" ]]; then
        cat > "${sf}" << 'HEADER'
# vpn-deploy-kit Secrets (自动生成，勿手动编辑)
# ⚠️ 此文件包含敏感信息，不要提交到 git

HEADER
    fi
    echo "$1" >> "${sf}"
    chmod 600 "${sf}"
}

# Check if step already completed (idempotent guard)
step_done() {
    local step="$1"
    if [[ -f "${OUTPUT_DIR}/.step-${step}" ]]; then
        log_warn "Step ${step} already completed, skipping"
        return 0
    fi
    return 1
}

# Mark step as done
mark_step_done() {
    touch "${OUTPUT_DIR}/.step-${1}"
}

# ============================================================================
# Batch 2 (Reality automation) extensions — added per spec v3
# ============================================================================

STATE_JSON="${OUTPUT_DIR}/state.json"

# Initialize state.json if absent. Idempotent.
state_init() {
    if [[ ! -f "${STATE_JSON}" ]]; then
        echo '{}' > "${STATE_JSON}"
    fi
    chmod 600 "${STATE_JSON}"
}

# Get dotted-path value from state.json, fall back to default if absent.
# Usage: state_get step.03.completed false
state_get() {
    local key="$1"
    local default="${2:-}"
    [[ -f "${STATE_JSON}" ]] || { echo "${default}"; return 0; }

    local val
    val=$(jq -r --arg k "${key}" \
        'getpath($k | split(".")) // empty' \
        "${STATE_JSON}" 2>/dev/null)
    echo "${val:-$default}"
}

# Atomic write a dotted-path key=value into state.json.
# Usage: state_set step.03.completed true
#        state_set step.04.inbound_id 2
state_set() {
    local key="$1"
    local val="$2"
    state_init

    local tmp
    tmp=$(mktemp -p "${OUTPUT_DIR}" .state.json.XXXXXX)
    # Try to write as number first; fall back to string.
    if [[ "${val}" =~ ^-?[0-9]+$ ]] || [[ "${val}" == "true" ]] || [[ "${val}" == "false" ]] || [[ "${val}" == "null" ]]; then
        jq --arg k "${key}" --argjson v "${val}" \
            'setpath($k | split("."); $v)' \
            "${STATE_JSON}" > "${tmp}"
    else
        jq --arg k "${key}" --arg v "${val}" \
            'setpath($k | split("."); $v)' \
            "${STATE_JSON}" > "${tmp}"
    fi
    mv -f "${tmp}" "${STATE_JSON}"
    chmod 600 "${STATE_JSON}"
}

# Machine-readable secrets file path (Reality privkey, panel pass, etc.)
secrets_env_file() {
    echo "${OUTPUT_DIR}/secrets-${VPS_IP}.env"
}

# Append or update KEY=value in secrets-<VPS_IP>.env. chmod 600 enforced.
# Usage: write_secrets_env "REALITY_PRIVKEY=xxx"
write_secrets_env() {
    local kv="$1"
    local sf
    sf=$(secrets_env_file)

    umask 077
    if [[ ! -f "${sf}" ]]; then
        cat > "${sf}" <<'HEADER'
# vpn-deploy-kit secrets - machine readable, chmod 600, NEVER COMMIT
HEADER
    fi

    local key="${kv%%=*}"
    if grep -q "^${key}=" "${sf}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${kv}|" "${sf}"
    else
        echo "${kv}" >> "${sf}"
    fi
    chmod 600 "${sf}"
}

# Charset assertion (whitelist regex). Aborts on mismatch.
# Usage: assert_charset "${REALITY_SNI}" '^[a-zA-Z0-9.-]+$' "REALITY_SNI must be hostname"
assert_charset() {
    local val="$1"
    local pattern="$2"
    local msg="$3"
    if [[ ! "${val}" =~ ${pattern} ]]; then
        log_error "${msg}: got '${val}'"
        exit 1
    fi
}

# Version >= comparison. Returns 0 if v1 >= v2.
# Usage: version_ge "3.37.0" "3.16" && echo "OK"
version_ge() {
    [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# F-CN-7: Hysteria2 port normalize (compat 05/06 reading legacy HY2_PORT)
hy2_port_normalize() {
    HY2_PORT="${HY2_PORT_ACTUAL:-${HY2_PORT:-}}"
}

# F-CN-7: Reality port normalize (compat 04/07/08 reading legacy REALITY_PORT)
reality_port_normalize() {
    REALITY_PORT="${REALITY_PORT_ACTUAL:-${REALITY_PORT:-}}"
}

# F-CN-4: Delete ufw rules by comment, NOT by raw port (safer for shared ports).
# Usage: ufw_delete_by_comment "vpn-deploy-kit:reality"
# Strategy: ufw status numbered -> grep "# <comment>" -> awk to get rule
# numbers -> sort -rn to delete from highest to lowest (avoid index shift).
ufw_delete_by_comment() {
    local comment="$1"
    if [[ -z "${comment}" ]]; then
        log_error "ufw_delete_by_comment: empty comment"
        return 1
    fi

    local rule_nums
    rule_nums=$(ufw status numbered 2>/dev/null \
                | grep -F "# ${comment}" \
                | awk -F'[][]' '{print $2}' \
                | sort -rn)

    if [[ -z "${rule_nums}" ]]; then
        log_warn "ufw_delete_by_comment: no rule with comment '${comment}' found"
        return 0
    fi

    local count=0
    while IFS= read -r n; do
        if [[ -n "${n}" ]]; then
            yes | ufw delete "${n}" >/dev/null
            count=$((count + 1))
        fi
    done <<< "${rule_nums}"

    log_info "ufw_delete_by_comment: deleted ${count} rule(s) with comment '${comment}'"
}
