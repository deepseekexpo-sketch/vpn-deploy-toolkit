#!/usr/bin/env bash
# vpn-deploy-kit — 一键部署编排器
set -euo pipefail

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
export KIT_DIR

cd "${KIT_DIR}"

# 验证 config.env 存在
if [[ ! -f config.env ]]; then
    echo "ERROR: config.env not found. Run: cp config.example.env config.env && edit"
    exit 1
fi

# 加载配置
source config.env

# 验证必填字段
if [[ -z "${VPS_IP:-}" ]]; then
    echo "ERROR: VPS_IP is required in config.env"
    exit 1
fi

# 初始化 output
mkdir -p output
touch output/runtime.env
LOG_FILE="output/deploy.log"

# 初始化日志
echo "=== vpn-deploy-kit deploy started $(date -Iseconds) ===" > "${LOG_FILE}"

# 脚本执行顺序(Batch 1: 00,01,02,05,06,07,08;Batch 2 加 03,04;spec v3 §8.3)
SCRIPTS=(
    "00-precheck"
    "01-harden-ssh"
    "02-port-probe"
    "03-install-3xui"        # Batch 2(v2.1):装 3x-ui + 锁 127.0.0.1
    "04-add-reality"         # Batch 2(v2.1):sqlite 直写 Reality inbound
    "05-install-hysteria"
    "06-deploy-hysteria-cfg"
    "07-end-to-end-test"
    "08-gen-client-yaml"
)

# 运行单个脚本并检查 STEP_OK
run_script() {
    local name="$1"
    local script="scripts/${name}.sh"

    if [[ ! -f "${script}" ]]; then
        echo "ERROR: ${script} not found"
        exit 1
    fi

    echo ""
    echo "========== Running ${name} =========="
    local output
    output=$(bash "${script}" 2>&1 | tee -a "${LOG_FILE}")
    local exit_code=${PIPESTATUS[0]}

    if [[ ${exit_code} -ne 0 ]]; then
        echo "ERROR: ${name} failed (exit ${exit_code})"
        echo "Check ${LOG_FILE} for details"
        echo "Suggested: fix the issue, then re-run bootstrap.sh (scripts are idempotent)"
        exit 1
    fi

    # 检查 STEP_OK marker (tail -1 精确匹配)
    local last_line
    last_line=$(echo "${output}" | tail -1)
    if [[ "${last_line}" != "STEP_OK: ${name}" ]]; then
        echo "ERROR: ${name} did not output STEP_OK: ${name} (got: '${last_line}')"
        exit 1
    fi

    echo "========== ${name} OK =========="
}

# 主流程
echo "vpn-deploy-kit starting on VPS ${VPS_IP}"
echo "BOOTSTRAP_DRY_RUN=${BOOTSTRAP_DRY_RUN:-0}"
echo "BOOTSTRAP_FORCE=${BOOTSTRAP_FORCE:-0}"
echo ""

for name in "${SCRIPTS[@]}"; do
    run_script "${name}"
done

echo ""
echo "=========================================="
echo "All steps completed successfully!"
echo "=========================================="
echo ""
echo "Client config: output/client-${VPS_IP}.yaml"
echo "Secrets file:  output/secrets-${VPS_IP}.md"
echo "Deploy log:    ${LOG_FILE}"
echo ""
echo "Next: copy client yaml to your Clash Verge Rev"
