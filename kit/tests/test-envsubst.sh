#!/usr/bin/env bash
# test-envsubst.sh — 验证模板中无残留 __PLACEHOLDER__ 和未替换 ${VAR}
set -euo pipefail

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

echo "=== test-envsubst ==="

# 1. 检查模板中无 __PLACEHOLDER__ 形式
for tmpl in "${KIT_DIR}"/templates/*.tmpl; do
    name=$(basename "${tmpl}")
    if grep -qE '__[A-Z_]+__' "${tmpl}"; then
        echo "FAIL: ${name} contains __PLACEHOLDER__ format (use \${VAR} instead)"
        grep -nE '__[A-Z_]+__' "${tmpl}"
        ERRORS=$((ERRORS + 1))
    else
        echo "OK: ${name} — no __PLACEHOLDER__ format"
    fi
done

# 2. 检查模板使用 ${VAR} 形式 (不是 $VAR)
for tmpl in "${KIT_DIR}"/templates/*.tmpl; do
    name=$(basename "${tmpl}")
    # 找 $VAR 但不是 ${VAR} 也不是 $$ 的情况
    if grep -Pn '(?<!\$)\$[A-Z_][A-Z_0-9]*(?![{])' "${tmpl}" | grep -v '^\s*#' | grep -qv '^\s*$'; then
        echo "WARN: ${name} uses \$VAR instead of \${VAR} (may cause envsubst issues)"
        grep -Pn '(?<!\$)\$[A-Z_][A-Z_0-9]*(?![{])' "${tmpl}"
    fi
done

# 3. 模拟 envsubst 渲染并检查无残留 ${}
for tmpl in "${KIT_DIR}"/templates/*.tmpl; do
    name=$(basename "${tmpl}")
    # 用假值渲染
    rendered=$(VPS_IP=1.2.3.4 HY2_PORT=8443 HY2_PASS=testpass \
              HY2_SNI=test.com HY2_MASQUERADE=https://test.com \
              CLIENT_NAME_PREFIX=us \
              envsubst < "${tmpl}" 2>/dev/null || true)
    if echo "${rendered}" | grep -qE '\$\{[A-Z_]+\}'; then
        echo "FAIL: ${name} has unresolved variables after envsubst"
        echo "${rendered}" | grep -Eo '\$\{[A-Z_]+\}' | sort -u
        ERRORS=$((ERRORS + 1))
    else
        echo "OK: ${name} — all variables resolved"
    fi
done

if [[ ${ERRORS} -gt 0 ]]; then
    echo "FAILED: ${ERRORS} error(s)"
    exit 1
fi

echo "All envsubst tests passed"
