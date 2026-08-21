#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vpn-deploy-toolkit 一键部署入口
================================
同事拿到本仓库后, 只需三件事:
  export VPN_HOST=<VPS IP>  VPN_PORT=<SSH端口>  VPN_USER=root  VPN_PASS=<root密码>
  python deploy.py

脚本自动完成:
  1. 用环境变量生成 kit/config.env(带你的 VPS/公钥)
  2. SFTP 上传整个 kit/ 到 VPS /opt/vpn-deploy-kit/
  3. 远程去 CRLF + bash -n 语法检查
  4. 跑 bootstrap.sh 一键部署(Reality 443 + Hysteria2 8443)
  5. 回收 client-<IP>.yaml + secrets-<IP>.md 到 ./deliverables/

依赖: pip install paramiko
"""
import os, sys, posixpath, time, argparse, paramiko

parser = argparse.ArgumentParser(description="vpn-deploy-toolkit 一键部署")
parser.add_argument("--verify-only", action="store_true",
                    help="只做非破坏检查: 生成config.env+上传kit+bash-n, 不部署不停服务")
parser.add_argument("--upload-only", action="store_true",
                    help="只上传kit+去CRLF+bash-n, 不跑bootstrap(不中断现有服务)")
ARGS = parser.parse_args()

# ============ 1. 凭据(环境变量) ============
HOST = os.environ.get("VPN_HOST", "").strip()
PORT = int(os.environ.get("VPN_PORT", "22"))
USER = os.environ.get("VPN_USER", "root").strip()
PASS = os.environ.get("VPN_PASS", "").strip()
PUBKEY = os.environ.get("VPN_PUBKEY", "").strip()   # 可选: "ssh-ed25519 AAAA... comment"

if not HOST or not PASS:
    print("=" * 60)
    print("缺少连接信息。请先设置环境变量:")
    print("  export VPN_HOST=<VPS公网IP>")
    print("  export VPN_PORT=<SSH端口>   (可选, 默认22)")
    print("  export VPN_USER=root")
    print("  export VPN_PASS=<root密码>")
    print("=" * 60)
    sys.exit(3)

KIT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "kit")
REMOTE_BASE = "/opt/vpn-deploy-kit"
DELIV_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "deliverables")

def log(msg):
    print(f"[*] {msg}", flush=True)

def run(sh, cmd, tmo=180):
    sh.settimeout(tmo)
    sh.exec_command(cmd)
    o = sh.makefile().read().decode("utf-8", "replace")
    e = sh.makefile_stderr().read().decode("utf-8", "replace")
    sh.close()
    return o, e

# ============ 2. 生成 config.env ============
def gen_config_env():
    os.makedirs(KIT_DIR, exist_ok=True)
    cfg = f"""# vpn-deploy-toolkit 自动生成 (deploy.py)
VPS_IP={HOST}
SSH_PORT={PORT}
SSH_NEW_PORT=22022
SSH_PUBKEY="{PUBKEY}"
SSH_KEY_PATH=

HY2_PORT=
HY2_SNI=www.microsoft.com
HY2_MASQUERADE=https://www.bing.com
HY2_VERSION=app/v2.6.0
HY2_SHA256=

XUI_VERSION_PIN=v2.9.4
PANEL_PORT=2053
PANEL_PATH=
PANEL_USER=
PANEL_PASS=
REALITY_PORT=
REALITY_SNI=addons.mozilla.org

CLIENT_NAME_PREFIX=us

BOOTSTRAP_FORCE=1
BOOTSTRAP_DRY_RUN=0
"""
    with open(os.path.join(KIT_DIR, "config.env"), "w", newline="\n") as f:
        f.write(cfg)
    log("已生成 kit/config.env")

# ============ 3. 上传 kit ============
def upload(c):
    log(f"上传 {KIT_DIR} -> {REMOTE_BASE} ...")
    sftp = c.open_sftp()
    def mkdir_p(path):
        parts = path.strip("/").split("/")
        cur = ""
        for p in parts:
            cur += "/" + p
            try: sftp.stat(cur)
            except IOError: sftp.mkdir(cur)
    mkdir_p(REMOTE_BASE)
    n = 0
    for root, _, files in os.walk(KIT_DIR):
        for fn in files:
            if fn == "config.env":
                continue  # 一律不把本机凭据 conf 上传(仅本地生成供 bootstrap 读取)
            src = os.path.join(root, fn)
            rel = os.path.relpath(src, KIT_DIR).replace("\\", "/")
            dst = posixpath.join(REMOTE_BASE, rel)
            mkdir_p(posixpath.dirname(dst))
            sftp.put(src, dst)
            if rel.endswith(".sh") or rel == "bootstrap.sh":
                sftp.chmod(dst, 0o755)
            n += 1
    sftp.close()
    log(f"上传完成 ({n} 文件)")

# ============ 4+5. 部署 ============
def deploy(c):
    # 先去 CRLF(本地可能 CRLF), 再 bash -n, 再 reset state + 跑 bootstrap
    sh = c.get_transport().open_session()
    sh.settimeout(900)
    script = f"""cd {REMOTE_BASE}
sed -i 's/\\r$//' bootstrap.sh scripts/*.sh
echo '--- bash -n ---'
for f in bootstrap.sh scripts/*.sh; do bash -n "$f" 2>/dev/null || echo "FAIL:$f"; done
echo '--- config.env 校验 ---'
[ -f config.env ] || {{ echo 'FATAL: config.env missing'; exit 2; }}
source config.env
echo "VPS_IP=${{VPS_IP}}  CLIENT_PREFIX=${{CLIENT_NAME_PREFIX}}  FORCE=${{BOOTSTRAP_FORCE}}"
echo '--- reset state(幂等重跑) ---'
mkdir -p output
echo '{{}}' > output/state.json
rm -f output/.step-* output/runtime.env
x-ui stop >/dev/null 2>&1 || true
iptables -D INPUT -p tcp --dport 2053 -j DROP 2>/dev/null || true
iptables -D INPUT ! -i lo -p tcp --dport 2053 -j DROP 2>/dev/null || true
sleep 1
echo '--- bootstrap.sh ---'
bash bootstrap.sh
echo "BOOTSTRAP_RC=$?"
echo '--- 监听校验 ---'
ss -tlnup 2>/dev/null | grep -E ':443 |:8443 ' || echo 'NO_LISTEN'
echo '--- 产物 ---'
ls -la output/*.yaml output/secrets*.md 2>/dev/null || echo 'NO_OUTPUTS'
"""
    log("远程部署中(可能耗时几分钟)...")
    sh.exec_command(script)
    o = sh.makefile().read().decode("utf-8", "replace")
    e = sh.makefile_stderr().read().decode("utf-8", "replace")
    rc = sh.recv_exit_status()
    sh.close()
    print("\n========== 远程部署输出 ==========")
    print(o)
    if e.strip():
        print("=== STDERR ===")
        print(e[-2000:])
    return rc

# ============ 6. 回收配置 ============
def collect(c):
    log("回收客户端配置...")
    os.makedirs(DELIV_DIR, exist_ok=True)
    sftp = c.open_sftp()
    got = []
    for f in [f"client-{HOST}.yaml", f"secrets-{HOST}.md"]:
        try:
            sftp.get(posixpath.join(REMOTE_BASE, "output", f),
                     os.path.join(DELIV_DIR, f))
            got.append(f)
        except Exception as ex:
            print(f"  [warn] 拉取 {f} 失败: {ex}")
    sftp.close()
    return got

# ============ 非破坏验证(不动现有服务) ============
def verify(c):
    log("非破坏验证: 检查上传后的套件语法与关键文件")
    sh = c.get_transport().open_session()
    sh.settimeout(120)
    sh.exec_command(f"""cd {REMOTE_BASE}
echo '--- 去 CRLF(与部署一致) ---'
sed -i 's/\\r$//' bootstrap.sh scripts/*.sh tests/*.sh 2>/dev/null || true
echo '--- 文件树 ---'
ls -la bootstrap.sh config.example.env scripts/ templates/ 2>&1 | head -12
echo '--- bash -n 全套件 ---'
fails=0
for f in bootstrap.sh scripts/*.sh tests/*.sh; do
  bash -n "$f" 2>/dev/null || {{ echo "FAIL:$f"; fails=$((fails+1)); }}
done
echo "SYNTAX_FAIL_COUNT=$fails"
echo '--- 03/04 是否含 v2.9.4 修复 ---'
grep -qc "connect-timeout" scripts/03-install-3xui.sh && echo "03-FIX_OK" || echo "03-FIX_MISSING"
grep -qc "grep -iE 'private" scripts/04-add-reality.sh && echo "04-FIX_OK" || echo "04-FIX_MISSING"
echo '--- config.env 是否被意外上传(应为NO) ---'
[ -f config.env ] && echo "CONFIG_ENV_PRESENT(异常)" || echo "CONFIG_ENV_ABSENT_OK"
""")
    o = sh.makefile().read().decode("utf-8", "replace")
    e = sh.makefile_stderr().read().decode("utf-8", "replace")
    sh.close()
    print(o)
    if e.strip():
        print("STDERR:", e[-1000:])
    return "SYNTAX_FAIL_COUNT=0" in o and "03-FIX_OK" in o and "04-FIX_OK" in o

def main():
    log(f"目标 VPS: {USER}@{HOST}:{PORT}  模式: {'verify-only' if ARGS.verify_only else 'upload-only' if ARGS.upload_only else 'deploy'}")
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        c.connect(HOST, port=PORT, username=USER, password=PASS,
                  timeout=40, banner_timeout=60, auth_timeout=60,
                  look_for_keys=False, allow_agent=False)
    except Exception as ex:
        print(f"连接失败: {type(ex).__name__}: {ex}")
        print("提示: 若 fail2ban 封了本机 IP, 请去商家控制台 VNC 执行 unban。")
        sys.exit(1)
    log("SSH 连接成功")

    if ARGS.verify_only:
        gen_config_env()          # 生成本地 config.env(不入库)
        upload(c)                 # 上传整套 kit
        ok = verify(c)            # 非破坏检查
        c.close()
        print("VERIFY:", "PASS ✅ 套件与修复齐全" if ok else "FAIL ❌ 检查输出")
        sys.exit(0 if ok else 1)

    if ARGS.upload_only:
        gen_config_env()
        upload(c)                 # 上传 + 去CRLF
        log("upload-only: 已上传并去CRLF, 未部署(现有服务未中断)")
        c.close()
        sys.exit(0)

    # 完整部署(默认)
    gen_config_env()
    upload(c)
    deploy(c)
    got = collect(c)
    c.close()
    print("=" * 60)
    print("部署流程结束。")
    if got:
        for g in got:
            print(f"  → deliverables/{g}")
        print("Clash Verge 导入 client-<IP>.yaml, 并关闭『设置→DNS设置』开关。")
    else:
        print("⚠️  未拉到客户端配置, 请到 VPS 检查 /opt/vpn-deploy-kit/output/")
    print("=" * 60)

if __name__ == "__main__":
    main()
