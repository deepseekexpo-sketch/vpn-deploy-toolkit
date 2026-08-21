# vpn-deploy-kit · 部署工具集

在全新 Ubuntu VPS 上部署双协议 VPN **Reality(VLESS/tcp 443) + Hysteria2(udp 8443)**，并生成 Clash Verge 客户端配置。
本仓库是**脱敏模板版**：可安全公开，供同事复用自己的服务器部署。

> ⚠️ 不含任何真实服务器凭据。部署时通过环境变量传入你自己的 VPS 信息（见下）。

## 特性
- 双协议高可用：Reality（抗封锁 TCP）+ Hysteria2（UDP 低延迟），任一可用即可上网
- 与 **3x-ui v2.9.4** 完全兼容（含 v2.9.4 面板认证模型迁移）
- 一键部署 + 客户端分流规则（chatgpt/openai 走代理，国内站直连）
- 全程 Python(paramiko) 驱动，适配 **Windows Git Bash**（无 sleep/chmod/which 的环境）

## 快速开始

### 0. 准备
- 一台全新 Ubuntu 22.04 VPS（root 权限）
- 本机装 Python 3.10+，`pip install paramiko`
- 部署公钥（可选；若 sshd 禁公钥则用密码）

### 1. 配置你的 VPS 凭据（环境变量，不进 git）
```bash
export VPN_HOST=<你的VPS IP>
export VPN_PORT=<SSH端口>
export VPN_USER=root
export VPN_PASS=<root密码>
```

### 2. 部署三步
```bash
# ① 连接测试 + 注入部署公钥 + 环境探测
export VPN_PUBFILE="<你的公钥路径>"
python scripts/ssh_init_new.py

# ② 上传 vpn-deploy-kit 套件到 VPS /opt/vpn-deploy-kit/
python scripts/upload_kit_new.py

# ③ 跑 bootstrap 一键部署（去CRLF→语法检查→部署→轮询）
python scripts/exec_deploy_new.py
```
成功后 VPS 监听：**443/tcp(Reality) + 8443/udp(Hysteria2)**。

### 3. 回收客户端配置
```bash
# 用 paramiko 拉取 VPS 上 /opt/vpn-deploy-kit/output/client-<IP>.yaml 和 secrets-<IP>.md
```

### 4. Clash Verge 导入
1. 删旧配置 → 导入 `client-<IP>.yaml` → 激活
2. **必须关闭 Verge「设置→DNS 设置」开关**，否则会覆盖配置里的 DNS（致 ChatGPT 回源、国内站 5s 慢）

## 部署脚本清单
| 脚本 | 作用 |
|------|------|
| `ssh_init_new.py` | 密码连 + 注入公钥(幂等) + 探测 OS/arch/x-ui/jq |
| `upload_kit_new.py` | SFTP 上传套件到 /opt/vpn-deploy-kit/ + 远程验证 |
| `deploy_remote.sh` | 远程：去 CRLF + bash -n + reset state + 停残留 + 跑 bootstrap |
| `exec_deploy_new.py` | 上传 deploy_remote.sh 并阻塞执行（长超时） |
| `manual_reality.sh` | (备用) x-ui 重启竞态兜底的手动 Reality 部署 |

远程套件需配齐：`bootstrap.sh`、`config.env`、`scripts/00-08`、`templates/`、`tests/`
（本项目为精简版，完整套件在 [原仓库](https://github.com/chieven-sys/vpn-deploy-kit)，按需复制）。

## ⚠️ 踩坑速查表（x-ui v2.9.4，部署前必读）

| # | 症状 | 根因 | 修复 |
|---|------|------|------|
| 1 | 上传后脚本全崩 `$'\r'` | 本地 .sh 是 CRLF | 远程 `sed -i 's/\r$//' bootstrap.sh scripts/*.sh` |
| 2 | bootstrap rc=1 无日志 | 重定向时 output 目录不存在 | 先 `mkdir -p output` |
| 3 | `jq: command not found` | 系统缺 jq | `apt-get install -y jq` |
| 4 | 03 卡死 "already in use" | **v2.9.4 旧 `x-ui setting` CLI 失效** | 改用 sqlite 写 `settings.secret`；面板锁 2053 用 `iptables !-i lo` + ufw deny；port precheck 仅 FORCE=0 |
| 5 | curl 校验失败 | panel 绑 `*`，IPv6 回环 `[::1]` 不通 | 用 IPv4 回环 `curl http://127.0.0.1:2053/` |
| 6 | 脚本 exit 28 | `$(curl ...)` 超时触 `set -e` | `code="$(curl ... || true)"` |
| 7 | x-ui 装完无 db | install.sh 不自动建 db | 手动 `x-ui start` 生成 `/etc/x-ui/x-ui.db` |
| 8 | xray 26.x 密钥解析失败 | 输出格式变 `PrivateKey:` | 用 `grep -iE 'private[[:space:]]*key' \| sed 's/^[^:]*:[[:space:]]*//'` |

## 安全说明
- 部署脚本通过环境变量读凭据，**仓库内无任何真实密码/IP/密钥**
- 客户端 yaml / secrets 含节点凭据，**切勿提交**——用示例模板 `templates/client.example.yaml`
- 面板（3x-ui 2053）默认仅本机/SSH 隧道可访问（iptables + ufw deny）

## License
MIT
