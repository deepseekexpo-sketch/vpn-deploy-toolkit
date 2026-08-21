---
title: VPN 部署工具包 — Design Doc
date: 2026-05-17
revision: v2(原 v1 经两份独立 spec-review 后修订:subagent batch + Codex,7 项必修 closed)
status: v2(post-double-review),待用户批准后进 Batch 1 实施
ancestor: ~/workplace/vpn/(本工具包从此项目"产品化"提取)
target_audience: 给朋友部署同款 Reality + Hysteria2 VPS 节点的人(可能是你,可能是技术朋友)
v1_reviews:
  - DESIGN-review.md(subagent batch:7 HIGH / 11 MEDIUM / 6 LOW / 4 CRITICAL GAP)
  - cx-design-review.md(Codex:3 HIGH + 实地核对 + 3 其他观察)
---

# VPN 部署工具包(vpn-deploy-kit)— Design Doc

## Revision log

### v2.1(2026-05-20)— Reality 路径从方案 B(API)反转到方案 C(sqlite 直写)

**触发**:Batch 2 进实施前的 mini spec-review(subagent batch + Codex 双评审,见 `docs/reality-automation-spec-review-v1.md`)。

**反转**:§4.4 从 "走 POST API(login → CSRF → POST)" 改为 **直改 sqlite(方案 C)+ 3x-ui CLI 配 panel + xray restart 验证 listen**。API 保留为 Plan B(切换条件:sqlite schema 不匹配但 API contract 验证通过)。

**论据**(基于 `archive/2026-05-20/xui-verification/SUMMARY.md` 准静态 verification):

1. **v2.9.4 Inbound model 完全没有 NodeID 字段**(multi-node 是 v3 才加的)→ vpn/ production(v3.x)踩过的 `node_id silent skip` 在 v2.9.4 上**不存在**;v2.9.4 `GetXrayConfig()` 唯一 inbound 级 skip 是 `!inbound.Enable`
2. **install.sh 自己就用 `x-ui setting -username U -password P -port N -webBasePath P`**(install.sh:703)→ CLI 子命令名跨 v2.x 稳定,且足够覆盖 panel 全部需要的配置
3. **方案 C 工作量比 B 小**(~30 行 bash vs ~80 行 bash),失败模式少(无 login/CSRF/POST/JSON body 多层),回滚更精确(`SELECT id FROM inbounds WHERE tag=...`)

**修订位置**:§0.2 / §1.3 / §2 目录结构 / §3.1 config.env / §4.1 / §4.4 / §5 表 / §8.3

**反证条件**:trial VPS 实测时若发现 v2.9.4 sqlite schema 跟 spec 字段不匹配,或者 install.sh sed patch 失败导致 panel 凭据残留默认值,撤回方案 C,启用 Plan B(走 API)。

### v1 原版 → v2 改了什么

| Tier 1(两份评审强共识 HIGH,必修) | 改动位置 |
|---|---|
| SSH 加固后失联风险(双方 HIGH) | §4.7 新增两阶段化协议;§2/§6 把 `99-uninstall.sh` 移到 Batch 1;§7 加 sshd/fail2ban/sysctl/原端口完整逆操作验收 |
| 3x-ui API 版本锁定 + 兜底缺失(双方 HIGH) | §4.4 加版本 pin 字段 + API 失败硬停;§3.1 config.env 加 `XUI_VERSION_PIN` |
| Batch 1 实测环境模糊(双方 HIGH) | §6 加硬约束:Batch 1 实测**只准在 trial VPS / disposable 环境**,不准在 vpn/ 那台 production VPS 上跑;dry-run 模式范围显式定义 |
| config.env 被自动写回(双方 HIGH:F-1.3 + Codex 观察 #1) | §3.1 / §4.3 改成:用户输入 = config.env(只读),实测/生成的值写到 `output/runtime.env`,两者不混 |

| Tier 2(单方 HIGH 或必要补强) | 改动位置 |
|---|---|
| 99-uninstall.sh 范围不全(Codex F-1 后半段) | §7.3 / §2 新增"99 完整逆操作清单":sshd_config / fail2ban / sysctl/BBR / 原 SSH 端口 / ufw 按 comment 删 |
| config.env 缺 SSH 接入字段(F-1.4 + F-3.1) | §3.1 加 `SSH_PUBKEY` / `SSH_KEY_PATH`(默认 `~/.ssh/id_ed25519`)+ ssh 接入命令统一参数化 |
| 不支持的 VPS 状态没显式 callout(F-9.1 + F-9.2) | §0.3 新增"不支持的 VPS 状态"段(已装服务占 443、非 Ubuntu 22.04);§1.3 / 01 加预检 |
| 99-uninstall.sh 是 Batch 4 可选(F-6.1) | §6 移到 Batch 1;每个 batch 实测失败后能干净环境继续测 |

| Tier 3(MEDIUM,留 Batch 1 实施时决定,不卡 spec) | 备注 |
|---|---|
| STEP_OK marker 传递机制(F-1.1) | §1.4 给方向(walking 模式 + 退出码),细节实施时定 |
| output/state.json schema(F-1.2) | §1.4 提一下用途,schema 实施时定 |
| deploy.log tee(F-5.1) | bootstrap.sh 实施时加 |
| dry-run / verbose flag(F-5.2 / F-5.3) | 同上 |
| vpn/ 经验迁移性偏见(F-11.1) | §4.3 端口策略改成"实测决定,不写偏好默认" |
| Reality 自动化跟 Hysteria2 参数化捆绑评审(我推荐方案 D 拆开) | **本 v2 不拆**——用户决策保持方案 A 一气呵成,但 §6 加更硬的 batch 边界 |

| 显式 defer(本 v2 不修,quarterly 复核) | 理由 |
|---|---|
| 3x-ui fork pin 自托管 install.sh | 接受 TOFU,跟 hysteria binary 一样,但版本 pin 必做(Tier 1) |
| 自签 cert + skip-cert-verify 安全权衡说明 | §0.3 第 3 项已声明,本 v2 加一行"风险接受"即可,不展开 |
| 多 VPS 批量部署 / rotate 节点功能 | YAGNI,等真实需求 |
| 流量统计 / Prometheus | §0.3 已排除,不动 |

---

# VPN 部署工具包(vpn-deploy-kit)— Design Doc(正文)

## 0. 目标 + 范围

### 0.1 用户场景

你(或一个有 Linux 基础的朋友)拿到一台**全新的 Ubuntu 22.04 KVM VPS**,目标:在 30-60 分钟内部署一个跟 `~/workplace/vpn/` 同款的 **Reality + Hysteria2 双协议** 代理节点,生成可直接 import 到 Clash Verge(Mac / Windows)的 yaml。

### 0.2 范围内

| 项 | 说明 |
|---|---|
| 新机 SSH 加固 | 公钥免密 / 改端口 / 禁密码登录 / ufw / fail2ban / BBR |
| Reality 部署 | 3x-ui 一键安装(`x-ui setting` CLI 配 panel)+ 直改 sqlite 加 Reality inbound(方案 C,v2.1 反转;详见 §4.4) |
| Hysteria2 部署 | 独立官方 binary + systemd(直接复用 `~/workplace/vpn/hysteria-server/`,参数化) |
| 端口策略 | tcpdump 旁路实测 443/tcp + 443/udp,自动选可达端口(Reality 倾向 23456 高位,Hysteria2 倾向 443/udp) |
| 客户端 yaml 生成 | Mac + Windows 用同一份 Clash yaml,模板化(envsubst) |
| 端到端预验证 | 部署完用 hysteria 官方 client 自连 + curl probe Reality,**实测协议层握手**(本次 v3 失败的修复) |
| 回滚 | 单脚本卸载所有,VPS 回到原始状态 |

### 0.3 范围外(显式不做,防止 scope creep)

| 项 | 不做的理由 |
|---|---|
| iOS / Android 客户端配置 | 用户回答只要 Mac+Windows;格式互通,文档里给个一行提示即可 |
| SS / VMess / Trojan / 其他协议 | 本项目验证只过了 Reality + Hysteria2 两种;加协议另开 spec |
| 域名 + Let's Encrypt 证书 | 朋友不一定有域名;自签 + skip-cert-verify 在 vpn/ 项目已验证够用。**安全权衡风险接受**:client 端 skip-cert-verify = 接受 MITM 可能,本工具包目标受众(自用 + 信任的朋友)可接受;如果不接受,本工具包不适用 |
| Docker / Kubernetes | 1-core 小 VPS over-engineering(v4 review 已结论) |
| Ansible / Terraform | 单台 VPS 不值得引入工具链(同 v4 review) |
| 多用户管理 / Web 面板订阅 | 单节点单用户场景,直接生成 yaml 即可 |
| 流量统计 / Prometheus | Reality 看 3x-ui 自带面板,Hysteria2 看 journalctl 即够 |
| GUI 部署工具 | bash 脚本 + markdown 文档已经覆盖目标受众(技术朋友)|

### 0.4 不支持的 VPS 状态(v2 新增,显式 callout 防止误用)

**bootstrap.sh 在 `01-precheck-and-harden.sh` 第一步必须 detect 以下状态,命中任何一条则中止并报错,不允许继续**:

| 状态 | detect 方法 | 中止理由 |
|---|---|---|
| 非 Ubuntu 22.04 | `lsb_release -ds` 不含 `Ubuntu 22.04` | 本工具包只在 Ubuntu 22.04 LTS 上验证;Debian/Alma/Ubuntu 20.04 各自 useradd / ufw / systemd 行为有差异,需要单独适配 |
| 443/tcp 或 443/udp 已被占用 | `ss -tlnp \| grep ':443 '` / `ss -ulnp \| grep ':443 '` | 朋友的 VPS 已装 nginx/caddy/其他服务占了 443 → 02 端口实测会误判 GFW 阻断 |
| `xray` / `hysteria` / `3x-ui` 已存在 | `which xray hysteria-server x-ui` | 不是全新机,工具包可能覆盖现有配置 → 必须先手工卸载或开另一台 |
| 不是 root 且 sudo 不可用 | `[[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null` | tcpdump / sshd / ufw / systemd 都需要 root |

**注**:如果用户**确认**接受风险想跑非全新机,可加 `BOOTSTRAP_FORCE=1` env override,跑出来的状态自己负责(类似 `rm -rf --no-preserve-root`)。

### 0.5 成功标准(部署后)

1. SSH 隧道 + 3x-ui 面板可登录(`http://localhost:<panel_port>/<random_path>/`)
2. Reality inbound 在 3x-ui 列表里且 `ss -tlnp` 看到 listen
3. `systemctl is-active hysteria-server` = active,`ss -ulnp` 看到 443/udp listen
4. 客户端 yaml 复制到 Verge 后 import,两个节点 delay 均绿(`delay < 500ms` 算绿,基于 vpn/ 那台 VPS baseline 150-300ms 留 2x 余量)
5. 端到端切节点 + 访问 `https://api.ipify.org` 返回 VPS IP

---

## 1. 架构

### 1.1 技术选型(沿用 vpn/ 项目已验证的)

| 协议 | 服务端 | 客户端 |
|---|---|---|
| Reality | 3x-ui 管理 xray-core(`xray` 进程)| mihomo via Verge,`type: vless` + `flow: xtls-rprx-vision` |
| Hysteria2 | 独立 `apernet/hysteria` binary + systemd | mihomo via Verge,`type: hysteria2` |

**为什么不都用 3x-ui**:`xray-core 26.x` 的 `proxy/` 模块**没有 `hysteria2`**,通过 3x-ui 加 hysteria2 inbound 会让 xray crash(本次 v3 实测过,已成定论)。两协议**进程隔离**部署是正确架构。

### 1.2 双协议隔离价值

- Reality 加挂期间需要 `xray` reload,Reality 自己会断 5 秒(本次 v3.5 实测)
- Hysteria2 是独立 systemd unit,加挂/改配置完全不影响 Reality
- 故障域隔离:Hysteria2 binary crash 不会拖死 Reality

### 1.3 安装顺序(强制串行)

```
1. 新机加固(SSH + ufw + fail2ban + BBR)
   ↓
2. 端口实测(443/tcp + 443/udp tcpdump 旁路)— 决定后续端口
   ↓
3. 装 3x-ui(一键脚本) + 锁 127.0.0.1
   ↓
4. 直改 sqlite 加 Reality inbound(方案 C,v2.1 反转)+ xray restart + silent skip 三件套验证
   ↓ Reality 验证 listen + 客户端可达后才进下一步
5. 装 hysteria binary + 配 systemd unit + 推 config(envsubst pipe,密码不落盘)
   ↓ Hysteria2 验证 listen + 端到端握手通过才进下一步
6. 生成客户端 yaml + 输出"如何 import 到 Verge"指引
   ↓
7. 全套验收(命令行 + 用户 UI 手动切节点)
```

每步**必须验证通过**才能进下一步(防止 v3 那种"假设 OK 实际不 OK"翻车)。

**关于 Reality 加挂 5 秒短断**(vpn/ CLAUDE.md 已踩坑):本工具包场景是**新机部署,没有 existing connections**,所以 step 4 加 Reality 不存在"用户感知断 5 秒"——这一点本工具包比 vpn/ 那台 production VPS 加挂场景更安全。但如果用户重跑 bootstrap.sh(已有连接的机器),仍有短断 → bootstrap.sh 检测 `xray` 已存在 + 有 existing connections 时,加 confirmation prompt。

### 1.4 Scripts 接口协议(v2 新增)

每个 script 必须满足以下契约,bootstrap.sh 据此判断是否往下走:

| 项 | 约定 |
|---|---|
| 退出码 | 成功 `exit 0`;失败 `exit 1`(bash `set -e` 自动) |
| 成功标志 | 脚本**最后一行** stdout 必须是字符串 `STEP_OK: <script_name>`(精确格式,bootstrap.sh 用 `tail -1` 匹配,不是 grep,避免中间 echo 误伤) |
| stdout/stderr | 同时 tee 到 `output/deploy.log`(bootstrap.sh 用 `\| tee -a $LOG_FILE` 包裹) |
| 输入 | `source config.env`(只读)+ 可选 `source output/runtime.env`(若存在,前序 script 写的) |
| 输出 | 不允许写回 `config.env`;实测/生成的值(端口、密码、生成的 panel path)写到 `output/runtime.env`;sqlite 返回的资源 id(如 inbound id)+ 状态写到 `output/state.json`(schema 实施时定) |
| Idempotent | 重跑不破坏(`[[ -f ... ]] || ...` 守卫);`output/state.json` 已有该 step 标记则 skip 或 prompt 确认 |
| Dry-run | 支持 `BOOTSTRAP_DRY_RUN=1` env,实际执行的命令改成 `echo` 打印(粒度:能 dry-run 的部分尽量 dry-run,实在不能的[如 `tcpdump` 实测]显式 SKIP 并说明) |

**state.json 用途**(不是完整 schema,实施时定):跟踪 step 完成度 / sqlite 返回的 inbound id / 实测决定的端口 / 生成的 secrets 文件名——用于 idempotent 重跑 + 99-uninstall.sh 精确回滚。

---

## 2. 目录结构

```
vpn-deploy-kit/
├── DESIGN.md                       # 本文档
├── README.md                       # 一页纸入门
├── DEPLOYMENT.md                   # 详细 step-by-step playbook
├── TROUBLESHOOTING.md              # 本项目 12 个踩坑沉淀 + 检测命令
├── config.example.env              # 用户填变量(VPS_IP / SSH_KEY_PATH 等),复制为 config.env 使用
├── config.env                      # 用户编辑(只读 for scripts);不进 git
├── bootstrap.sh                    # 一键入口:source config.env + 依次跑 scripts/01-08 + tee log
├── scripts/                        # 模块化脚本,可独立 cherry-pick
│   ├── 00-precheck.sh              # v2 新增:检测 OS 版本 / 443 占用 / 已装服务 / sudo 可用(见 §0.4)
│   ├── 01-harden-ssh.sh            # v2 改名:SSH 加固两阶段化(见 §4.7);ufw / fail2ban / BBR
│   ├── 02-port-probe.sh            # tcpdump 旁路实测 443/tcp + 443/udp,写 output/runtime.env
│   ├── 03-install-3xui.sh          # 装 3x-ui(pin 版本)+ 锁 127.0.0.1 + 改默认端口/path/密码
│   ├── 04-add-reality.sh           # 直改 sqlite 加 Reality inbound(方案 C v2.1),id 写 state.json
│   ├── 05-install-hysteria.sh      # 装 hysteria binary(pin app/v2.9.1 + SHA256)+ 用户 + cert + systemd
│   ├── 06-deploy-hysteria-cfg.sh   # 推 hysteria config(envsubst pipe,无落盘)
│   ├── 07-end-to-end-test.sh       # Reality delay probe + Hysteria2 官方 client 自连
│   ├── 08-gen-client-yaml.sh       # 渲染客户端 yaml(模板 + 真实参数)
│   └── 99-uninstall.sh             # v2 提到 Batch 1:**完整逆操作**(见 §7.3),按 state.json 精确回滚
├── output/                         # v2 新增:scripts 的产出物 + 运行时状态;不进 git
│   ├── runtime.env                 # 实测/生成的值(端口、密码、panel path),后续 script source
│   ├── state.json                  # 资源 id(inbound id 等)+ step 完成度(用于 idempotent + 精确回滚)
│   ├── deploy.log                  # bootstrap.sh tee 所有 scripts stdout/stderr
│   ├── secrets-<VPS_IP>.md         # chmod 600,密码归档(用户自管,可上 1Password)
│   └── client-<VPS_IP>.yaml        # 渲染好的 Clash Verge yaml,用户 import
├── templates/
│   ├── hysteria-server.service     # 直接复用 vpn/hysteria-server/(可能微调)
│   ├── hysteria-config.yaml.tmpl   # envsubst 占位符 ${HY2_PASS} 等
│   ├── reality-settings.json.tmpl       # inbound.settings(clients[].id/flow/subId/email)— sqlite readfile() 注入
│   ├── reality-stream-settings.json.tmpl # inbound.stream_settings(reality dest/privateKey/shortIds 等)— sqlite readfile() 注入
│   └── client.yaml.tmpl            # Clash Verge yaml(Mac / Windows 通用)
└── tests/                          # bash 自检(部署前 dry-run)
    ├── test-envsubst.sh            # 验证 envsubst placeholder format(防 __PLACEHOLDER__ 坑)
    └── test-templates.sh           # 渲染所有模板,grep 没替换的 placeholder
```

**关键说明**(v2 强化):
- `scripts/` 数字前缀 = **执行顺序**,bootstrap.sh 按字典序跑(00 预检在 01 之前)
- 每个脚本满足 **§1.4 接口协议**(STEP_OK / dry-run / 输入只 config.env、输出走 output/)
- 每个脚本 **idempotent**(重跑不破坏):用 `[[ -f ... ]] || ...` 守卫 + 查 `output/state.json` 已完成 step 则 skip
- `output/` 目录由 bootstrap.sh 第一步 `mkdir -p` 创建,**绝不写回 config.env**(用户输入不污染)

---

## 3. 用户使用流程

### 3.1 准备阶段(用户做)

```bash
git clone <repo> vpn-deploy-kit  # 或解压
cd vpn-deploy-kit
cp config.example.env config.env
vim config.env  # 填:VPS_IP, SSH_PORT, REMOTE_USER, 期望 panel 端口等
```

`config.env` 包含(**v2 改:用户编辑后 scripts 只读;实测值写到 `output/runtime.env`,不污染本文件**):
```bash
# === SSH 接入(v2 强化:统一参数化,不再依赖 ~/.ssh/config alias) ===
VPS_IP=203.0.113.10            # 示例 IP(RFC 5737 documentation 段),替换成你的实际 VPS IP
SSH_PORT=22                    # 商家默认;01 加固时切到 SSH_NEW_PORT(本字段不变)
SSH_NEW_PORT=22022             # 示例;自行选 1024-65535 范围内的高位端口(加固后启用,01 切换成功后写入 output/runtime.env)
REMOTE_USER=root               # 全新机通常是 root,加固时**默认仍用 root**(创建非 root 留待后续 spec)
SSH_KEY_PATH=~/.ssh/id_ed25519 # v2 新增:本机私钥路径,所有 ssh 命令用 `ssh -i $SSH_KEY_PATH -p $SSH_PORT $REMOTE_USER@$VPS_IP`
SSH_PUBKEY=                    # v2 新增:留空 = 从 ${SSH_KEY_PATH}.pub 读;非空则用该字符串塞 authorized_keys

# === 3x-ui 面板 ===
XUI_VERSION_PIN=v2.9.4         # v2.1:实测 2026-05-20 当前 stable release;v3.0.x 当时还是 prerelease
                               # 关键:v2.9.4 无 NodeID 字段,vpn/ v3 踩过的 node_id silent skip 在 v2.9.4 不存在
PANEL_PORT=2053                # 锁 127.0.0.1,通过 SSH tunnel 访问
PANEL_PATH=                    # 留空 = 自动生成随机 16 字符(防爆破),写 output/secrets-*.md
PANEL_USER=                    # 留空 = 自动生成
PANEL_PASS=                    # 留空 = 自动生成(写入 output/secrets-*.md)

# === Reality ===
REALITY_PORT=                  # 留空 = 02 实测决定(写 output/runtime.env);**不写回本文件**
REALITY_SNI=addons.mozilla.org # 默认值。必须 PQ-ready(X25519MLKEM768),否则 HRR → xray 握手 EOF;详见 §5 踩坑表。降级 → dl.google.com

# === Hysteria2 ===
HY2_PORT=                      # 留空 = 02 实测决定(写 output/runtime.env);**不写回本文件**
HY2_SNI=www.microsoft.com
HY2_MASQUERADE=https://www.bing.com  # 跟 Reality dest 不同避免关联指纹

# === 客户端 yaml ===
CLIENT_NAME_PREFIX=us          # 节点命名前缀,生成 us-reality + us-hysteria2

# === 安全护栏 ===
BOOTSTRAP_FORCE=0              # v2 新增:1 = 跳过 00-precheck(允许在非全新机/非 Ubuntu 22.04 上跑);默认 0
BOOTSTRAP_DRY_RUN=0            # v2 新增:1 = 所有可 dry-run 的步骤打印命令不执行(见 §1.4)
```

### 3.2 部署阶段

```bash
./bootstrap.sh
# 内部依次跑 scripts/00-08(00 预检 + 01-08 部署),每步打印 STEP_OK 才进下一步
# 99-uninstall.sh 不在主流程,用户失败/回滚时单独跑
# 失败 → 打印失败位置 + 建议(回滚 / 手动调查),失败上下文已 tee 到 output/deploy.log
```

预计耗时:**20-40 分钟**(3x-ui 一键安装最慢,其他都是几秒钟)。

### 3.3 客户端阶段

```bash
# bootstrap.sh 最后一步会输出:
echo "Client yaml: ./output/client-<VPS_IP>.yaml"
echo "Secrets:     ./output/secrets-<VPS_IP>.md (chmod 600)"
echo "Next:"
echo "  Mac/Win:  打开 Verge → 订阅页 → 本地文件 import ./output/client-<VPS_IP>.yaml"
```

### 3.4 回滚

```bash
./scripts/99-uninstall.sh  # 全部回滚(交互式确认,危险操作)
```

---

## 4. 关键设计决策

### 4.1 语言:bash

**选**:bash(跟 `~/workplace/vpn/hysteria-server/` 一致,零依赖,所有 VPS 默认有)。
**排除**:python(要 venv;3x-ui CLI + sqlite 直写 + ssh ops bash 也够;复杂状态用 jq)。

### 4.2 密码管理:全自动生成 + 不落盘 + 输出 secrets 文件

- bootstrap.sh 跑之前,所有 `*_PASS` 字段如果是空,**自动 `openssl rand -hex 16` 生成**
- 写入 `./output/secrets-<VPS_IP>.md`(chmod 600,本机本地,不进 git)
- 推送到 VPS 走 envsubst pipe(密码不落 /tmp,不出现在 ps argv)— **修复本次 envsubst placeholder format 坑(只用 `${VAR}` 形式)**
- 用户(部署者)责任:secrets 文件本机自己保管 / 上传 1Password

### 4.3 端口策略:实测先行,不盲选(v2 改:去 vpn/ 经验偏见)

- `02-port-probe.sh` 在 VPS 端跑 tcpdump,本地端跑 nc/curl probe
- 判据:**tcpdump 是否抓到包**(不依赖 nc/curl 单向无回返语义,修复 vpn/ F-NEW-1 + Codex F-3 坑)
- 选端口规则(**v2 改**:不写"倾向 443/23456",改成实测决定):
  - Reality (tcp):**实测 443 通 → 443;不通 → 实测 23456/13456/34567 等高位,直到通**
  - Hysteria2 (udp):**实测 443 通 → 443;不通 → 实测 34567/13456/54321 等高位,直到通**
  - 两个都不通(443+所有高位 fallback) → 中止部署,可能是 VPS 整体出网不通或商家禁端口,自动选无意义
- **端口决定后写到 `output/runtime.env`**(v2 改:不写回 `config.env`,避免污染用户输入)
- 实测耗时预算:每端口 ~10s tcpdump(总计 ~30-60s 含 fallback);超时阈值 `PROBE_DURATION_SEC` 在 `02-port-probe.sh` 里定 default 30s
- **背景说明**:作者那台 ancestor VPS 实测 443/tcp 被国内 ISP 端口级阻断(2025-08-20 后美西小众 IP 段现象),所以 ancestor 项目用 23456。但这是**特定 IP 段 + 特定时间窗口的经验**,朋友的 VPS(欧洲/东南亚/香港/其他美西段)可能 443/tcp 通——本工具包不预设偏好

### 4.4 3x-ui 接入:方案 C(直改 sqlite),版本 pin,失败硬停(v2.1 反转)

> **v2.1 反转**:原 v2 走方案 B(API),v2.1 反转到方案 C(sqlite 直写)。详细论据见文首 v2.1 Revision log + `docs/reality-automation-spec-review-v1.md` + `archive/2026-05-20/xui-verification/SUMMARY.md`。

**03-install-3xui.sh**(装 panel + 锁 127.0.0.1):

- 安装 **pin 到 `${XUI_VERSION_PIN}` 版本**(默认 `v2.9.4`,实测 2026-05-20);**不准跑 `latest`** — 供应链 + schema 漂移防线
- 安装来源:`curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/${XUI_VERSION_PIN}/install.sh -o /tmp/3xui-install.sh` — **TOFU 模型**(跟 hysteria binary 一样)
- **Patch install.sh 跳过 config_after_install**(`sed` 注释掉对该函数的调用)— 避开 SSL setup 这一段交互式 MANDATORY 流程
- `bash /tmp/3xui-install.sh ${XUI_VERSION_PIN} </dev/null` 跑 install
- 立刻 `iptables -I INPUT -p tcp --dport <default-port> -j DROP` — **关闭公网暴露窗口**(install 完默认 panel 在 `0.0.0.0` 监听默认凭据,到锁 127.0.0.1 之间存在数十秒暴露洞)
- 用 `x-ui setting -port N -username U -password P -webBasePath P -listenIP 127.0.0.1` 配 panel(**实际 flag 是 `-listenIP` 不是 `-listen`**,evidence 见 install.sh:703 + main.go:438-453)
- `systemctl restart x-ui` 让 listen 生效;loopback `curl -s http://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}/` 验证返回 HTML
- 撤 `iptables -D INPUT` DROP 规则
- **备份 db**:`cp /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.bak.before-vpn-deploy-kit.$(date +%s)`,路径写 state.json

**04-add-reality.sh**(加 inbound):

- 前置守卫:state.json 必须有 `step.03.completed=true`;`/etc/x-ui/x-ui.db` 必须存在
- **再备份 db**(独立于 03 备份):`cp x-ui.db x-ui.db.bak.before-04.$(date +%s)` — 04 回滚专用
- 生成 keypair / UUID / shortID(VPS 本机跑 `/usr/local/x-ui/bin/xray-linux-amd64 x25519`)
- 输入字段白名单 sanity(`REALITY_SNI` 限 hostname charset / `INBOUND_REMARK` 限 `[A-Za-z0-9_-]`)
- envsubst 渲染 `reality-settings.json.tmpl` + `reality-stream-settings.json.tmpl` 落到 `/root/`(700 权限继承)+ `chmod 600` + `trap 'shred -u' EXIT`
- **INSERT inbounds 用 sqlite3 builtin `readfile()` + prepared statement**(完全绕开 shell quoting):
  - `BEGIN IMMEDIATE; INSERT INTO inbounds (...) VALUES (...readfile('/root/settings.json')...); INSERT INTO client_traffics ...; COMMIT;`
  - 字段顺序见 `archive/2026-05-20/xui-verification/SUMMARY.md` §3.3
  - **v2.9.4 无 NodeID 字段,无需"故意省略 node_id"**(v3 才有)
- 写入后校验:`json_valid(settings)` + `json_valid(stream_settings)` + `SELECT enable FROM inbounds WHERE id=${ID}` 必须返回 1
- 取真实 inbound id 写 state.json
- `x-ui restart` + **重试循环** `for i in 1 2 3 5 8 13 21; do ss -tlnpH "sport = :${PORT}" | grep xray && break; sleep $i; done`(xray 冷启动 5-8s,`sleep 3` race)
- **silent skip 三件套防线**:
  1. `ss -tlnpH "sport = :${REALITY_PORT}"` + `readlink /proc/<pid>/exe` 必须是 xray binary
  2. `jq` 按端口字段精确匹配 `/usr/local/x-ui/bin/config.json` 里 `streamSettings.security=="reality"`
  3. xray 进程 `ps -o lstart=` ≥ x-ui restart 命令发起时间(证明真重启了)
- **失败处理**:任一防线挂掉 → 用 04 备份恢复 db + `x-ui restart` + `failure_count++` 写 state.json + exit 1(达 2 次硬 abort)
- `ufw allow ${REALITY_PORT}/tcp comment 'vpn-deploy-kit:reality'`(99 按 comment 删,不按裸端口)
- inbound 真实 `id` + `tag` + `remark` 写 `output/state.json`;UUID/pubkey/shortID 写 `output/runtime.env`;**privkey 只进 `output/secrets-<VPS_IP>.env`(chmod 600,机器可读)+ Markdown(人读归档)**

**Plan B(API)切换条件**:仅在以下条件**全部满足**时启用 — sqlite schema 不匹配 spec § A.6 字段顺序;且 3x-ui v2.9.4 panel `/panel/api/inbounds/add` POST 返回 2xx 通过;且 CSRF token 提取流程通过(login 后 GET `/panel/` 主页才能拿到 CSRF meta,不是 login 302 redirect 页 — vpn/ 历史 403 坑)。切换决策需用户显式批准,不允许实现者临场选。

### 4.5 Hysteria2 cert:独立到 `/etc/hysteria/cert/`

- 不再放 `/etc/x-ui/`(**修复 v4 review HIGH finding 3.1**)
- 自签 + SAN=IP:`<VPS_IP>`
- owner `hysteria:hysteria`, mode 0640

### 4.6 端到端预验证(本次 v3 教训核心修复)

`07-end-to-end-test.sh` 必做的事:
1. Reality:VPS 自连 `xray` 配置 + curl 测试 → 失败立刻 dump xray journalctl 给用户
2. Hysteria2:VPS 上跑 `hysteria client --config /tmp/test.yaml` 连 `127.0.0.1:443` + curl → 失败 dump
3. **客户端 SNI 跟生产 mihomo client 的 SNI 完全一致**(**修复本次"预验证 sni 跟生产不一致" 的 §3.5 缺陷**)
4. **client config 中的密码用 source-of-truth (secrets.md) 的值,不从 server config grep**(**修复本次 envsubst 坑导致 "两边都用错值反而握手通过" 的陷阱**)

### 4.7 SSH 加固两阶段化(v2 新增,Codex F-1 + 我 F-2.2 共识必修)

**目的**:01-harden-ssh.sh 要做"改端口 / 禁密码登录 / 公钥免密",任何一步顺序错都可能把自己锁在 VPS 外。v2 强制两阶段化协议,失败有兜底。

#### Phase A:准备新访问路径(不动旧路径)

1. 把 `${SSH_PUBKEY}` 追加到 `${REMOTE_USER}` 的 `~/.ssh/authorized_keys`(append,不覆盖)— 验证公钥免密登录可用,**但旧密码登录此时仍开着**
2. 修改 `sshd_config` 用 `Match`-block 增量(不替换整文件):新建 `/etc/ssh/sshd_config.d/99-vpn-deploy-kit.conf`,内含 `Port ${SSH_NEW_PORT}` + `PasswordAuthentication no` + `PermitRootLogin prohibit-password` —— **此时 sshd 还监听旧 SSH_PORT,因为只是 reload 加端口,旧端口不立即停**
3. `ufw allow ${SSH_NEW_PORT}/tcp comment "vpn-deploy-kit:ssh-new"`(comment 用于 99 精确删)
4. `systemctl reload sshd` —— sshd 现在**同时监听** SSH_PORT 和 SSH_NEW_PORT
5. **独立进程验证新端口可达**:Mac 端跑 `ssh -i $SSH_KEY_PATH -p $SSH_NEW_PORT -o ConnectTimeout=10 -o BatchMode=yes $REMOTE_USER@$VPS_IP 'echo PHASE_A_OK'`,**必须返回 `PHASE_A_OK`**

如果 step 5 失败 → **不进 Phase B,立刻回滚**:`rm /etc/ssh/sshd_config.d/99-vpn-deploy-kit.conf && systemctl reload sshd && ufw delete allow ${SSH_NEW_PORT}/tcp`。用户的旧 SSH 通道始终未受影响。

#### Phase B:切换旧路径(确认新路径稳定后)

6. 给 Phase A 加 **5 分钟自动回滚保险**:`at now + 5 minutes` 调度 `mv /etc/ssh/sshd_config.d/99-vpn-deploy-kit.conf{,.scheduled-rollback} && systemctl reload sshd`(at job id 记到 `output/state.json`)
7. 让 sshd **不再监听旧 SSH_PORT**:编辑 `/etc/ssh/sshd_config.d/99-vpn-deploy-kit.conf` 把 sshd 主配置 Port 改成只听 SSH_NEW_PORT,`systemctl reload sshd`
8. 再次 Mac 端独立进程验证 SSH_NEW_PORT 可达且 SSH_PORT 已不通 → 通过则 `atrm <job_id>` **取消保险**,把 SSH_NEW_PORT 写到 `output/runtime.env`
9. 如果保险触发(用户没在 5 分钟内 atrm),sshd 自动 reload 把 99-vpn-deploy-kit.conf 重命名 = 失效 → 回到 step 1 之前的状态;**用户没失联**

#### 其他加固

- `ufw allow ${SSH_NEW_PORT}/tcp` 已 done;关闭 `ufw deny ${SSH_PORT}/tcp`(确认 Phase B step 8 通过后);comment `vpn-deploy-kit:ssh-old`
- `fail2ban` 装 + 启 + sshd jail(配置存到 `/etc/fail2ban/jail.d/99-vpn-deploy-kit.local`,卸载时按文件名删)
- `sysctl` BBR 加到 `/etc/sysctl.d/99-vpn-deploy-kit.conf`(同上)

#### 99-uninstall.sh 完整逆操作(v2 强化,Codex F-1 后半段)

```bash
# SSH 加固回滚
rm -f /etc/ssh/sshd_config.d/99-vpn-deploy-kit.conf
systemctl reload sshd  # sshd 回到只监听原 SSH_PORT
ufw delete allow $(grep ^SSH_NEW_PORT output/runtime.env | cut -d= -f2)/tcp 2>/dev/null
# 按 comment 删,不按 port,避免误删用户原有规则

# fail2ban
rm -f /etc/fail2ban/jail.d/99-vpn-deploy-kit.local
systemctl reload fail2ban 2>/dev/null
# 注意:不 `apt remove fail2ban`,用户可能本来就装了它

# sysctl/BBR
rm -f /etc/sysctl.d/99-vpn-deploy-kit.conf
sysctl --system  # 重新加载 sysctl,BBR 回到 default(cubic)

# authorized_keys:不动(避免删错用户自己加的)— 仅打印警告让用户决定
echo "WARN: ~/.ssh/authorized_keys 里 vpn-deploy-kit 加的 SSH_PUBKEY 未自动删除,请人工核对"
```

### 4.8 客户端 yaml 模板:一份 yaml 覆盖 Mac + Windows

- mihomo / Clash Verge yaml 格式跨平台一致
- 模板见 `templates/client.yaml.tmpl`,envsubst 替换 `${VPS_IP}` / `${REALITY_PORT}` / `${HY2_PORT}` / `${REALITY_PASSWORD_UUID}` / `${HY2_PASS}` / `${REALITY_PUBLIC_KEY}` / `${REALITY_SHORT_ID}`
- DEPLOYMENT.md 包含 Verge 安装指引(Mac: brew cask / Win: scoop or direct download)

#### 4.8.1 DNS 块设计(2026-05-20 vpn/ 项目踩坑沉淀)

**为什么需要**:

mihomo / Clash Verge 默认行为(Verge 自动注入的 dns 段)在国内网络环境下有两个坑,会导致用户用了 VPN **还是看不到 chatgpt.com**:

1. **明文 UDP DNS 被 GFW 投毒**:Verge 默认 `nameserver: [8.8.8.8, https://dns.google/dns-query]`,首项 `8.8.8.8` 是明文 UDP,在国内被 GFW 注入污染响应是常态。例如 `chatgpt.com` 会被解析到国内 IP `118.184.26.113`(非真实 Cloudflare IP)。
2. **`fallback-filter.geoip-code: CN` 误伤国内站**:Verge 默认 `fallback` 用境外 DoH,`fallback-filter` 规则是"主 DNS 返回 CN 地理位置 IP → 认为被污染 → 改用 fallback"。对真国内站(如 baidu.com)反而是误伤,因为它本来就该返回 CN IP,被强制走境外 DoH 后超时,造成 5s+ 延迟。

第 1 个坑的下游效应:被污染的国内 IP 会触发 `GEOIP,CN,DIRECT`(默认未加 `no-resolve`,mihomo 反解后判位),导致 `chatgpt.com` 走直连,**用户看到的现象是"主域 DIRECT、子域 PROXY"的反常组合**(子域不在 GFW 黑名单上,DNS 拿到 Cloudflare 真 IP,正常走 MATCH PROXY)。

**模板 DNS 块设计**(写进 `templates/client.yaml.tmpl`):

```yaml
dns:
  enable: true
  listen: :53
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - '*.lan'
    - '*.local'
    - '*.arpa'
    - localhost.ptlogin2.qq.com
    - +.market.xiaomi.com
    - '*.msftncsi.com'
    - www.msftconnecttest.com
    - time.*.com
    - ntp.*.com
  # bootstrap:仅用于解析 nameserver 里的 DoH host(我们都用 IP 形式,基本走不到)
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  # 关键开关:让 DoH 查询本身跑 rules → 境外 DoH 经代理节点出去,避开 GFW
  respect-rules: true
  # 默认 nameserver:境外 DoH,IP 形式免 bootstrap;经代理通道出去
  nameserver:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
  # 国内域名分流:走国内 DoH(快+准+不依赖代理)
  nameserver-policy:
    'geosite:cn,private':
      - https://223.5.5.5/dns-query
      - https://120.53.53.53/dns-query
  # mihomo dial 代理 server 时用(节点 server 是 IP 不需解析,但保险配上防循环)
  proxy-server-nameserver:
    - https://223.5.5.5/dns-query
```

**rules 顶部** 必须加(配合 DNS 治本方案):

```yaml
rules:
  - IP-CIDR,${VPS_IP}/32,DIRECT,no-resolve   # 防 mihomo dial 节点循环
  # 安全网:DNS 配置失效时的兜底(显式 > 隐式;geosite 滞后时仍生效)
  - DOMAIN-SUFFIX,chatgpt.com,PROXY
  - DOMAIN-SUFFIX,openai.com,PROXY
  - DOMAIN-SUFFIX,oaistatic.com,PROXY
  - DOMAIN-SUFFIX,oaiusercontent.com,PROXY
  # GFW 黑名单一次性走代理(治本,免后续维护被污染域名清单)
  - GEOSITE,gfw,PROXY
  ...
```

**4 个关键设计点解释**:

| 字段 | 为什么这么配 |
|---|---|
| `respect-rules: true` | mihomo 默认 nameserver 查询直连出去,境外 DoH IP(`1.1.1.1`/`8.8.8.8`)在国内常被 RST。开启后 DoH 查询本身跑 rules,因不命中任何直连规则被 MATCH PROXY 接住,经代理节点出去,绕过 GFW |
| DoH 用 IP 形式(`https://1.1.1.1/dns-query`,不是 `https://cloudflare-dns.com/dns-query`) | 避免 bootstrap 鸡生蛋:解析 `cloudflare-dns.com` host 需要 DNS,而 DNS 自己又要解析它。用 IP 形式跳过这步 |
| `nameserver-policy` 用 `geosite:cn,private` 分流 | 国内域名(geosite:cn)走国内 DoH,境外域名走 nameserver(境外 DoH 经代理)。private 涵盖局域网 / RFC1918 反向解析 |
| 不配 `fallback` 和 `fallback-filter` | 这两个是 Verge 默认行为的污染源(`fallback-filter.geoip-code: CN` 把国内站推向境外 DoH 超时,造成 5s 慢)。配了完整 `nameserver-policy` 后 fallback 完全多余 |

**Verge 客户端 UI 配合要求**(必须写进 DEPLOYMENT.md):

> ⚠️ **关键步骤**:Verge 默认会用 UI 内置的 DNS 设置**覆盖 yaml 里的 dns 段**,导致本配置失效。安装 Verge 后:
> 1. 打开 Verge → 设置 → DNS / DNS 设置
> 2. **关闭**"DNS 设置"开关(`enable_dns_settings: false`)
> 3. 重启 Verge(或重新激活 profile)
>
> 验证:`curl --unix-socket /tmp/verge/verge-mihomo.sock http://localhost/dns/query?name=chatgpt.com` 应该返回 Cloudflare IP(`104.18.x.x` / `172.64.x.x`),不是国内 IP。

**风险点**:

| 风险 | 缓解 |
|---|---|
| `respect-rules: true` 引发 DNS↔rules 循环 | DoH 用 IP 形式不需解析;GEOSITE 走 mmdb 不需 DNS。理论无循环(已在 vpn/ 实测验证) |
| 代理节点挂掉时境外 DNS 全瘫 | `nameserver-policy` 国内 DoH 仍工作;境外站此时本来就用不了,DNS 瘫不瘫无影响 |
| `geosite:gfw` mmdb 滞后导致新被污染域名漏网 | 4 条 DOMAIN-SUFFIX 安全网兜底;部署文档建议用户每月 Verge 更新一次 geosite |

**验收方法**(写进 `08-gen-client-yaml.sh` 输出的客户端 README):

```bash
# 1. 检查 Verge 用了 yaml 的 dns 段(不是被 UI 覆盖)
python3 -c "import yaml; print(yaml.safe_load(open('~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml')).get('dns', {}).get('respect-rules'))"
# 应输出 True

# 2. 关键域名解析正确
curl -s --unix-socket /tmp/verge/verge-mihomo.sock 'http://localhost/dns/query?name=chatgpt.com'
# 应返回 104.18.x.x 或 172.64.x.x(Cloudflare),不是国内 IP

# 3. 国内站快速解析
curl -s --unix-socket /tmp/verge/verge-mihomo.sock 'http://localhost/dns/query?name=baidu.com'
# 应在 300ms 内返回国内 IP

# 4. 浏览器实测 chatgpt.com + baidu.com 都正常打开
```

---

## 5. 13 个踩坑沉淀到 scripts 的对照表

| 坑 | 编码到 scripts 的位置 |
|---|---|
| envsubst 只识别 `$VAR`,不识别 `__PLACEHOLDER__` | 所有模板用 `${VAR}` + `tests/test-templates.sh` grep 没替换的 placeholder |
| Loopback 测试取密码方式埋陷阱(两边都用错值通过) | `07-end-to-end-test.sh` 强制从 `output/secrets-*.md` 读密码,不 grep server config |
| xray-core 26.x 不支持 hysteria2 inbound | 架构上分开,3x-ui 只管 Reality;Hysteria2 走独立 binary |
| 3x-ui sqlite `node_id` silent skip(v3 的坑) | **pin v2.9.4 → 无 NodeID 字段**,坑天然不存在(v2.1 反转后的关键收益) |
| Verge copy-on-import | DEPLOYMENT.md 明确写"必须删旧 import + 重新 import + 激活" |
| `fake-ip` + `DOMAIN-KEYWORD,DIRECT` 不兼容 | `templates/client.yaml.tmpl` 全用 `DOMAIN-SUFFIX`,不用 `DOMAIN-KEYWORD` |
| 回滚 SQL 硬编码 tag(tag ≠ remark) | 04 加 inbound 后**记下 sqlite 返回的真实 id 到 output/state.json**;99-uninstall.sh 用 id 删 |
| 预验证只测 schema/sqlite INSERT ≠ 真能加载 | 07 做协议层端到端握手测试(xray client loopback) |
| 加挂期间 Reality 5 秒短断 | DEPLOYMENT.md 提示用户在 04 之前不要做关键工作 |
| GFW 443/tcp 阻断 | 02 实测,决定 Reality 端口 |
| 自签 cert + masquerade 跟 Reality dest 同站 | Hysteria2 默认 masquerade = bing.com,Reality dest = addons.mozilla.org,**不同站** |
| 密码爆破 | 3x-ui panel path 自动生成 16 字符随机串;Hysteria2 密码 16 字节 hex |
| **Reality dest 不支持后量子 `X25519MLKEM768`**(如 `www.microsoft.com`/Akamai):面对 Chrome uTLS 指纹的 MLKEM768+X25519 ClientHello 回 **HelloRetryRequest**,xray 26.x 的 Reality 借证书接管逻辑处理不了 HRR 二次往返 → 握手 EOF / 客户端 Timeout(未认证连接仍能 fallback 拿真证书,易误判为路径/密钥问题)| `REALITY_SNI` 默认 `addons.mozilla.org`(PQ-ready);**选/换 SNI 前** `openssl s_client -groups X25519MLKEM768 -connect <dest>:443` 验证(需 openssl≥3.5,handshake_failure=不支持);降级链 `addons.mozilla.org → dl.google.com`;避开 xray 自警的 apple/icloud。根治待 xray 升级修复 HRR 接管(vpn/ 生产 2026-06-25 实测 microsoft 5/5 失败,mozilla/google/apple 5/5 成功) |
| **GFW DNS 污染主域**(`chatgpt.com` → 国内 IP → 误命中 `GEOIP,CN,DIRECT` → 走直连看不到)+ Verge 默认 `fallback-filter.geoip-code: CN` 误伤国内站(baidu 5s 慢) | `templates/client.yaml.tmpl` 内置完整 dns 块(`respect-rules: true` + IP 形式 DoH + `nameserver-policy` 分流 + 不配 `fallback`),rules 顶部加 `GEOSITE,gfw,PROXY` + 4 条 DOMAIN-SUFFIX 安全网。**DEPLOYMENT.md 强制要求关 Verge UI 的"DNS 设置"开关**(否则覆盖 yaml dns 段)。详见 §4.8.1 |

---

## 6. 实施分批(v2 改:99-uninstall 移到 Batch 1 + trial VPS 硬约束)

| 批次 | 范围 | 验收 |
|---|---|---|
| **Batch 1: MVP(Hysteria2 + 完整回滚)** | `00-precheck.sh` + `01-harden-ssh.sh` + `02-port-probe.sh` + `05-install-hysteria.sh` + `06-deploy-hysteria-cfg.sh` + `07-end-to-end-test.sh`(Hysteria2 部分) + `08-gen-client-yaml.sh`(只生成 hysteria 节点) + **`99-uninstall.sh`(本 batch 必含,见 §4.7 完整逆操作)** | 在 trial VPS 上 install → 验证 → uninstall → `ss/journalctl/dpkg/sysctl` 全部确认无残留 → 重跑 install → 同样结果(可重复性) |
| **Batch 2: 加 Reality + 3x-ui** | `03-install-3xui.sh` + `04-add-reality.sh` + 扩 07 + 扩 08 + 扩 99 | 同上,加 Reality 完整 install/uninstall 闭环 |
| **Batch 3: 完善文档 + 测试** | `README.md` + `DEPLOYMENT.md` + `TROUBLESHOOTING.md` + `tests/` | 一个新人(非作者)按文档跑通 |

### 6.1 Batch 实测环境硬约束(v2 新增,双方 HIGH 共识)

**每个 batch 实测必须在以下环境之一**,不允许在作者那台 ancestor production VPS 上跑(`xray` + `hysteria-server` 已在运行,工具包会覆盖):

1. **trial VPS**(推荐):另开一台 5-10 美元/月的 KVM VPS(BandwagonHost / RackNerd / Vultr 都行),实测完销毁,成本 < $1/次
2. **本地 KVM/qemu VM**(次选):本地起 Ubuntu 22.04 VM,通过 NAT 映射模拟 VPS;不能完全模拟"国内访问 VPS"路径,但能验证脚本本身
3. **`BOOTSTRAP_DRY_RUN=1` 模式**(再次选):在 vpn/ VPS 上跑 dry-run,只打印命令不执行;**但 dry-run 不能完全验证 idempotent / 回滚 / 协议握手,不能算通过 batch 验收**

**禁止**:在 vpn/ 那台 production VPS 上 `BOOTSTRAP_FORCE=1 BOOTSTRAP_DRY_RUN=0` 真跑——这会破坏 production。

### 6.2 推迟决定:Reality 拆独立 spec?

subagent batch review 推荐方案 D(把 Reality 自动化拆成独立 spec 走独立评审,因为 vpn/ 项目 Reality 从未自动化过 = 新代码)。**v2 决策保持方案 A 一气呵成**(用户已批准),但增加保险:Batch 2 实施前**单独跑一次 Reality 部分的 spec-review**(只评审 03+04 两个 script 的设计,不重审整体)。

---

## 7. 验收标准

### 7.1 工具包自身验收

- [ ] `tests/test-envsubst.sh` 通过(防 placeholder format 倒退)
- [ ] `tests/test-templates.sh` 通过(渲染后无未替换占位符)
- [ ] `shellcheck scripts/*.sh` 通过(防 bash 常见错误)
- [ ] `bash -n scripts/*.sh` 语法检查通过

### 7.2 端到端验收(在 trial VPS 上,v2 强化)

- [ ] `./bootstrap.sh` 一路绿到底,生成 `output/client-*.yaml` + `output/secrets-*.md` + `output/runtime.env` + `output/state.json` + `output/deploy.log`
- [ ] Mac Verge import `client-*.yaml`,两节点 delay 全绿(< 500ms)
- [ ] Windows Verge 同上
- [ ] 切到自建节点 → 访问 `https://api.ipify.org` 返回 VPS IP
- [ ] **重跑 `./bootstrap.sh` idempotent 验证**:不破坏 state,不重复装服务

### 7.3 回滚验收(99-uninstall.sh 完整逆操作,v2 强化,Codex F-1 后半段)

跑 `./scripts/99-uninstall.sh` 后,**所有以下检查必须通过**(任一项有残留 = 回滚不完整):

```bash
# 接入命令:从 config.env + output/runtime.env 读
SSH="ssh -i $SSH_KEY_PATH -p ${SSH_NEW_PORT:-$SSH_PORT} $REMOTE_USER@$VPS_IP"

# A. 服务进程
$SSH 'systemctl status hysteria-server 2>&1 | grep -q "could not be found"'  # ✓ unit 已删
$SSH 'systemctl status x-ui 2>&1 | grep -q "could not be found"'              # ✓ unit 已删(Batch 2 后)
$SSH 'ss -tlnp | grep -E ":23456|:2053"'                                      # ✓ 应无输出
$SSH 'ss -ulnp | grep ":443"'                                                  # ✓ 应无输出
$SSH 'pgrep -a hysteria; pgrep -a xray; pgrep -a x-ui'                        # ✓ 应无输出

# B. 文件残留
$SSH 'ls /etc/hysteria 2>&1 | grep -q "No such"'                              # ✓ 已删
$SSH 'ls /usr/local/bin/hysteria-server 2>&1 | grep -q "No such"'             # ✓ 已删
$SSH 'ls /etc/systemd/system/hysteria-server.service 2>&1 | grep -q "No such"' # ✓ 已删
$SSH 'ls /etc/x-ui 2>&1 | grep -q "No such"'                                  # ✓ 已删(Batch 2 后)
$SSH 'id hysteria 2>&1 | grep -q "no such user"'                              # ✓ 用户已删

# C. SSH 加固回滚(Codex F-1 后半段必检)
$SSH 'cat /etc/ssh/sshd_config.d/99-vpn-deploy-kit.conf 2>&1 | grep -q "No such"' # ✓ 已删
$SSH 'ss -tlnp | grep sshd | grep ${SSH_NEW_PORT}'                             # ✓ 不再监听新端口
$SSH 'ss -tlnp | grep sshd | grep ${SSH_PORT}'                                 # ✓ 回到监听原端口

# D. fail2ban / sysctl/BBR 回滚
$SSH 'ls /etc/fail2ban/jail.d/99-vpn-deploy-kit.local 2>&1 | grep -q "No such"' # ✓ 已删
$SSH 'ls /etc/sysctl.d/99-vpn-deploy-kit.conf 2>&1 | grep -q "No such"'        # ✓ 已删
$SSH 'sysctl net.ipv4.tcp_congestion_control'                                  # ✓ 回到 cubic(若用户原本不是 BBR)

# E. ufw 规则
$SSH 'ufw status | grep "vpn-deploy-kit"'                                      # ✓ 应无输出(comment 已被精确删)

# F. 重跑 install 闭环验证
./bootstrap.sh    # 应跟首次跑一样从零开始,不报"已存在"错误
```

**所有 ✓ 通过 = Batch 1 验收通过**;任一项失败 = 99-uninstall.sh 有 bug,必须修复后重测。

---

## 8. 评审历史 + Tier 1 修复对照(v2 已 closed)

v1 经两份独立 spec-review:
- **subagent batch review** → `DESIGN-review.md`(7 HIGH / 11 MEDIUM / 6 LOW / 4 CRITICAL GAP)
- **Codex review** → `cx-design-review.md`(3 HIGH + 实地核对 + 3 其他观察)

收敛后 v2 修复 7 项必修 + 必要补强,对照表见文首 "Revision log"。

### 8.1 v1 原本列的 9 个 "待评审重点" 现状

| v1 问题 | v2 status |
|---|---|
| §0.3 范围外是否合理 | 通过(双方未挑) |
| §1.3 串行 vs 并行 | 通过(双方未挑;v2 在 §1.3 加 Reality 短断说明) |
| §2 scripts 粒度 | 改进(v2 加 00-precheck + 调整 01 命名) |
| §3.1 config.env 字段够全? | **不够全**(v2 加 SSH_KEY_PATH / SSH_PUBKEY / XUI_VERSION_PIN / BOOTSTRAP_FORCE / BOOTSTRAP_DRY_RUN) |
| §4.4 3x-ui CLI / sqlite schema 跨版本稳定? | **必须 pin v2.9.4**(v2.1 §4.4);v2.9.4 schema 已实证(无 NodeID),CLI 子命令名实证(install.sh:703 自己用) |
| §4.6 预验证顺序 | 通过(VPS 自连优先于 Mac 公网连,已在原 §4.6) |
| §5 12 坑对照表 漏吗? | 接近完整(v2 不动,后续 batch 实施时遇新踩坑再加) |
| §6 Batch 1 用 vpn/ VPS 验证破坏 production? | **会**(v2 §6.1 加 trial VPS 硬约束) |
| §7 是否要规定全流程实测? | **要**(v2 §7.3 加完整回滚验收 + idempotent 重跑验证) |

### 8.2 未在 v2 修的(显式 defer)

| 项 | 来源 | 推迟理由 |
|---|---|---|
| 自动写 deploy.log tee 实现细节(F-5.1) | subagent F-5.1 | Batch 1 实施时定 helper 函数,spec 给方向(§1.4)即可 |
| state.json 完整 schema(F-1.2) | subagent F-1.2 | Batch 1 实施时定字段,spec 给用途说明(§1.4)即可 |
| 3x-ui fork pin 自托管 install.sh | subagent F-3.2 / F-7.1 | 接受 TOFU,跟 hysteria binary 一样 |
| 多 VPS 批量部署 / rotate 节点 | Quarter 1 时间纵深推演 | YAGNI,本工具包目标是单机部署 |
| 非 Ubuntu 22.04 兼容(Debian / Alma) | subagent F-9.2 | §0.4 显式列"不支持",将来需要时另开 spec |
| Reality 拆独立 spec(方案 D 推荐) | subagent ≥2 方案对比 | 用户决策保持方案 A;v2 §6.2 增加 "Batch 2 实施前单独跑 Reality 部分 mini spec-review" 作为折中 |

### 8.3 实施时仍要警惕的(给 AI 自己)

1. **§4.7 SSH 加固两阶段必须真做**——不准走捷径"直接改 sshd_config 然后 reload"。Phase A step 5 独立进程验证是关键
2. **§6.1 trial VPS 硬约束不准放水**——即使用户说"在我那台跑也行",也要先确认是 trial VPS 不是 vpn/ 那台 production
3. **§4.4 sqlite INSERT 失败 / silent skip 防线挂掉硬停不准 fallback "继续往下走"**——Codex F-2 + 我 F-7.1 共识必修(v2.1 把 API 改为 sqlite 后,该原则仍适用)
4. **`output/state.json` 写入要 atomic**(`mktemp + mv`),不然 partial write 后回滚会读到坏数据

## 9. 不目标的边界说明(给未来的我)

如果有需求来了让我"扩 vpn-deploy-kit 支持 X" — 先检查 §0.3:

- 想加 iOS 客户端 → 写**另一个工具包** `vpn-client-mobile-kit`,不要塞进本包
- 想加 SS / VMess → 写**协议加挂 spec**,跟本包独立
- 想加 Web UI → 项目本意是"自用工具",GUI 是另一个项目
- 想加多节点编排 / 集群 → 写 Ansible 项目,不要把本包升级成 IaC 引擎
