#!/usr/bin/env bash
# test-templates.sh — 验证模板文件语法正确性
set -euo pipefail

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

echo "=== test-templates ==="

# 1. hysteria-config.yaml.tmpl — 用假值渲染后验证 YAML 语法
echo "Testing hysteria-config.yaml.tmpl YAML syntax..."
rendered=$(VPS_IP=1.2.3.4 HY2_PORT=8443 HY2_PASS=testpass \
           HY2_SNI=test.com HY2_MASQUERADE=https://test.com \
           envsubst < "${KIT_DIR}/templates/hysteria-config.yaml.tmpl")

if echo "${rendered}" | python3 -c "import sys,yaml; yaml.safe_load(sys.stdin)" 2>/dev/null; then
    echo "OK: hysteria-config.yaml.tmpl — valid YAML"
else
    echo "FAIL: hysteria-config.yaml.tmpl — invalid YAML"
    echo "${rendered}"
    ERRORS=$((ERRORS + 1))
fi

# 2. client.yaml.tmpl — 用假值渲染后验证 YAML 语法(含 Reality + Hy2 两个 proxy 块)
echo "Testing client.yaml.tmpl YAML syntax..."
rendered=$(VPS_IP=1.2.3.4 HY2_PORT=8443 HY2_PASS=testpass \
           HY2_SNI=test.com CLIENT_NAME_PREFIX=us \
           REALITY_PORT=23456 \
           REALITY_UUID=11111111-2222-3333-4444-555555555555 \
           REALITY_SNI=www.microsoft.com \
           REALITY_PUBKEY=abcdEFGHijkl_-1234567890ABCDEfgh \
           REALITY_SHORT_ID=0123456789abcdef \
           envsubst < "${KIT_DIR}/templates/client.yaml.tmpl")

if echo "${rendered}" | python3 -c "import sys,yaml; yaml.safe_load(sys.stdin)" 2>/dev/null; then
    echo "OK: client.yaml.tmpl — valid YAML"
else
    echo "FAIL: client.yaml.tmpl — invalid YAML"
    echo "${rendered}"
    ERRORS=$((ERRORS + 1))
fi

# 2a. reality-settings.json.tmpl — 渲染后验证 JSON
echo "Testing reality-settings.json.tmpl JSON syntax..."
rendered=$(REALITY_UUID=11111111-2222-3333-4444-555555555555 \
           CLIENT_NAME_PREFIX=us \
           REALITY_SUB_ID=abcdef0123456789 \
           envsubst < "${KIT_DIR}/templates/reality-settings.json.tmpl")
if echo "${rendered}" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    echo "OK: reality-settings.json.tmpl — valid JSON"
else
    echo "FAIL: reality-settings.json.tmpl — invalid JSON"
    echo "${rendered}"
    ERRORS=$((ERRORS + 1))
fi

# 2b. reality-stream-settings.json.tmpl — 渲染后验证 JSON
echo "Testing reality-stream-settings.json.tmpl JSON syntax..."
rendered=$(REALITY_SNI=www.microsoft.com \
           REALITY_PRIVKEY=kMvBmRfXr0p1zT3jOyqLgN6QwH8sX2Yd_K5C3fV0aBI \
           REALITY_PUBKEY=abcdEFGHijkl_-1234567890ABCDEfgh \
           REALITY_SHORT_ID=0123456789abcdef \
           envsubst < "${KIT_DIR}/templates/reality-stream-settings.json.tmpl")
if echo "${rendered}" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    echo "OK: reality-stream-settings.json.tmpl — valid JSON"
else
    echo "FAIL: reality-stream-settings.json.tmpl — invalid JSON"
    echo "${rendered}"
    ERRORS=$((ERRORS + 1))
fi

# 3. hysteria-server.service — 验证 systemd unit 语法
echo "Testing hysteria-server.service..."
if systemd-analyze verify "${KIT_DIR}/templates/hysteria-server.service" &>/dev/null; then
    echo "OK: hysteria-server.service — valid systemd unit"
else
    echo "WARN: hysteria-server.service — systemd-analyze failed (may need systemd running)"
fi

# 4. 检查 client.yaml.tmpl 不含 DOMAIN-KEYWORD (DESIGN.md §5 踩坑 #6)
echo "Checking no DOMAIN-KEYWORD in client.yaml.tmpl..."
if grep -q "DOMAIN-KEYWORD" "${KIT_DIR}/templates/client.yaml.tmpl"; then
    echo "FAIL: client.yaml.tmpl contains DOMAIN-KEYWORD (use DOMAIN-SUFFIX instead)"
    grep -n "DOMAIN-KEYWORD" "${KIT_DIR}/templates/client.yaml.tmpl"
    ERRORS=$((ERRORS + 1))
else
    echo "OK: client.yaml.tmpl — no DOMAIN-KEYWORD"
fi

# 5. 检查 client.yaml.tmpl 含 skip-cert-verify: true (自签证书必须)
echo "Checking skip-cert-verify in client.yaml.tmpl..."
if grep -q "skip-cert-verify: true" "${KIT_DIR}/templates/client.yaml.tmpl"; then
    echo "OK: skip-cert-verify: true present"
else
    echo "FAIL: client.yaml.tmpl missing skip-cert-verify: true (self-signed cert requires it)"
    ERRORS=$((ERRORS + 1))
fi

if [[ ${ERRORS} -gt 0 ]]; then
    echo "FAILED: ${ERRORS} error(s)"
    exit 1
fi

echo "All template tests passed"
