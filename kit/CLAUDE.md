# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目身份

**本项目 = `~/workplace/vpn/` 项目的产品化提取**。

`~/workplace/vpn/` 是用户**自己那台 VPS** 的部署 working dir(含 secrets, 日志, 历史 spec)。本项目把 vpn/ 里 production-validated 的部署经验抽出来、参数化,做成可复用工具包,**给朋友/未来的自己部署同款 Reality + Hysteria2 节点用**。

代码来源 + 教训来源都在 vpn/。**首次接手务必先读以下文件**(按顺序):

1. `~/workplace/vpn/CLAUDE.md` — vpn/ 项目指南(架构 + **12 个具体踩坑**)
2. `./DESIGN.md` — 本工具包设计文档(范围 / 架构 / 9 个 scripts 设计 / 4 个 batch 实施计划)
3. `~/workplace/vpn/独立Hysteria2部署方案-v4.md` — Hysteria2 spec(已实施,本工具包要参数化复用)
4. `~/workplace/vpn/部署设计.md` — Reality spec(已投产)
5. `~/workplace/vpn/hysteria-server/` — 4 个 production-validated 脚本(本工具包要抽出来参数化)

## 当前阶段(2026-05-17 移交时)

| 阶段 | 状态 |
|---|---|
| §0 范围对齐 | ✅ 完成:新机 + Reality+Hysteria2 + Mac+Windows + 一键脚本+文档双轨 |
| §1 DESIGN.md | ✅ 写完(`./DESIGN.md`,~370 行) |
| §2 spec-review 双评审 | ⏸️ **下一步** — subagent batch + Codex 并行 |
| §3 Batch 1 MVP(只 Hysteria2 部分)| 待评审通过 |
| §4 Batch 2 加 Reality | 待 |
| §5 Batch 3 文档 + Batch 4 卸载 | 待 |

## 上一个对话留下的关键决策

不要重做这些已收敛的判断:

1. **范围(DESIGN.md §0)**:不做 iOS/Android、不做 SS/VMess、不做 Docker/Ansible/GUI、不做域名+LE
2. **架构(§1)**:Reality 走 3x-ui + xray;Hysteria2 走独立 binary + systemd;**两进程隔离**(因为 xray-core 26.x 不支持 hysteria2 inbound,vpn/ v3 实测踩过,见 archive/2026-05-17/加挂Hysteria2方案.md)
3. **语言(§4.1)**:bash(不引入 Python / Ansible / Docker)
4. **密码管理(§4.2)**:自动 openssl 生成;envsubst pipe 不落盘;只用 `${VAR}` 形式(**不要再用 `__PLACEHOLDER__`**,vpn/ v4-minus 实测踩过)
5. **端口策略(§4.3)**:tcpdump 旁路实测,不依赖 nc 单向语义(vpn/ §2.1 教训)
6. **3x-ui 接入(§4.4 v2.1 反转)**:**Batch 2 评审后以方案 C 为主**——直改 sqlite 加 inbound + `x-ui setting` CLI 配 panel;**回滚用 id 不硬编码 tag**。API 为 Plan B(显式切换条件:sqlite schema 不匹配但 API contract 验证通过)。决策依据见 DESIGN.md §4.4 + `docs/reality-automation-spec-review-v1.md` + `archive/2026-05-20/xui-verification/SUMMARY.md`
7. **端到端预验证(§4.6)**:client config 用 source-of-truth (secrets.md) 的密码,**不从 server config grep**(vpn/ 本次踩过的 loopback 陷阱)

## 跟 vpn/ 项目的边界

| 不能做 | 必须做 |
|---|---|
| 修改 vpn/ 里任何 production 文件 | 引用 vpn/CLAUDE.md / spec 时用绝对路径 |
| 把 secrets.md 之类拷过来 | secrets 由用户在 config.env / output/ 自管 |
| 影响 vpn/ 那台 ancestor production VPS 的运行 | 必要时可在 ancestor VPS 上 dry-run 验证 |
| 修改 vpn/ 的 archive/ 历史 spec | 引用历史 spec 当 source-of-truth 是可以的 |

## 工作纪律(沿用 vpn/ 项目,补充本项目特定)

1. **任何 scripts 写完都要 shellcheck + bash -n**(`DESIGN.md §7.1`)
2. **每个 batch 完成后实测一遍**(`DESIGN.md §6`),不要 4 个 batch 全写完才测
3. **每个脚本必须 idempotent**(重跑不破坏)+ **结尾打印 `STEP_OK` marker**(bootstrap.sh 检查)
4. **不在本机 install 任何东西**(全局 CLAUDE.md 已规定),所有部署目标都是远端 VPS
5. **跨项目引用 vpn/ 文件用绝对路径**(`~/workplace/vpn/...`),不要硬编码本机用户名

## 关键 reference 路径速查

```
~/workplace/vpn/CLAUDE.md                        # vpn 项目指南 + 12 个踩坑
~/workplace/vpn/独立Hysteria2部署方案-v4.md      # Hysteria2 spec(参数化模板)
~/workplace/vpn/部署设计.md                      # Reality spec
~/workplace/vpn/hysteria-server/                 # 4 个 production-validated 脚本
~/workplace/vpn/archive/2026-05-17/              # 历史 spec + review(决策依据)
~/workplace/vpn/log/worklog-2026-05-17.md        # 本项目演化过程
~/workplace/vpn/log/changelog.md                 # 产出物变更日志
~/.claude/projects/-Users-huangqiwen-workplace-vpn/memory/  # vpn 项目 memory
```

**本项目 memory** 是独立的(`~/.claude/projects/-Users-huangqiwen-workplace-vpn-deploy-kit/memory/`),首次会话会自建。可以借鉴 vpn/ memory 但不要 copy(各自演化)。
