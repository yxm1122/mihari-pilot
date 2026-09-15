# mihari-pilot

一个 agent 技能：让 agent **自行诊断并操作本机的 [mihari](https://github.com/mihari-proxy/mihari) 代理**——零审批读状态、查清某个域名到底走哪条规则和哪个节点出口、在该开系统代理或 TUN 的时候自己开。

> **非官方。** 这是第三方配套技能，与 mihari 项目无隶属关系、未获其背书、也不是它的一部分。mihari 本体是 GPL-3.0；本仓库不含任何 mihari 代码，只有一个调用它的脚本。

## 它到底解决什么

"让 agent 自己修网络"通常死在三个地方，这个技能就是围着这三点设计的：

1. **只读的事不该花审批。** `status` / `doctor` / `trace` / `env` 走 mihomo 的本地控制器（loopback TCP）、注册表和核心日志，不碰控制管道，因此在 read-only 或 workspace-write 沙箱下**零审批**可用。只有写操作（`on` / `off` / `ensure-tui`）需要更宽的权限，而且只要一次。
2. **"我在用哪个节点"不等于"这个域名会走哪个节点"。** `trace <域名>` 同时给两样：**预测**（命中的规则 + 解析后的组链 + 末端节点）与**实证**（mihomo 日志里该域名最后一次真实连接的结果，失败时连出口节点自己的服务器地址和错误原因都在里面）。
3. **错答案比没答案更坏。** 当脚本无法判断时——配置读不到、规则类型判不了、入参是裸 IP、探测被沙箱扭曲——它会明说并以非零码退出，而不是打一行看起来很像结论的东西。

## 子命令

| 子命令 | 作用 | 审批 |
|---|---|---|
| `status` | 一行：daemon、核心、系统代理、TUN、组链、模式、代理端口（附真实可达性）、TUI、env | 无 |
| `doctor` | 本机**与本次沙箱**的能力矩阵——shell、语言模式、解析出的端口及其来源、控制器、注册表、管道、日志 | 无 |
| `trace <域名\|URL>` | 命中规则 → 解析链 → 末端节点，外加观测到的最后一次连接；`-Probe` 顺带测该节点 | 无 |
| `env` | mixed 端口的 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` / `NO_PROXY` | 无 |
| `on` / `off` | 系统代理开关；`-Tun` 作用于 TUN 并维护互斥 | 一次升级 |
| `ensure-tui` | 幂等确保 mihari TUI 在运行，方便用户查看 | 一次升级 |

## 安装

本仓库采用 `skills/<name>/SKILL.md` 布局，所以**用技能安装器指向本仓库，或把技能目录手工拷进技能根**——不要把仓库直接克隆进技能根，技能在下一层。

DSH 的安装器（来自 `find-skills` 技能）：

```powershell
node <path-to>\dsh-install.mjs --repo <owner>/mihari-pilot --all
# 或者直接拷：  skills\mihari-pilot  ->  %USERPROFILE%\.dsh\skills\
```

其他 harness 就把 `skills/mihari-pilot` 拷进各自的技能根（`.agents/skills/`、`.claude/skills/`、`~/.codex/skills/` 等）。有几处是本技能专门针对 DSH 沙箱与提权模型写的，移植时该改什么见 [`skills/mihari-pilot/references/setup.md`](skills/mihari-pilot/references/setup.md)。

## 支持矩阵

| 环境 | 状态 |
|---|---|
| DSH（DeepSeek Harness）+ Windows + PowerShell 5.1 | **已实测**——本技能就是在这个环境上开发与验证的 |
| Windows + PowerShell 7 | 预期可用，未实测 |
| 其他 agent harness（Claude Code、Codex、Cursor、Copilot CLI 等） | **未实测**——`references/setup.md` 说明要改什么；frontmatter 刻意只用 `name` + `description`，这是所有 harness 都接受的公共子集 |
| Linux / macOS | 本脚本不支持（`powershell -File` 在那里跑不了）；mihari 本体支持，移植清单见 `setup.md` |

## 依赖

- 已安装且服务在运行的 mihari。安装是上游的事——见 <https://github.com/mihari-proxy/mihari#quick-start>，本技能刻意不复述。
- Windows PowerShell 5.1 或更新。
- 由 mihari 托管的 mihomo 核心（技能正是通过控制器读它）。

## 刻意的边界

- **不修改** `mihari.yaml`、订阅、节点或注册表。它读配置里的 controller-secret；那是它碰这个文件的唯一理由。
- **不选节点**。节点不可用时它报告是哪个，把决定交回用户。
- **不强行制造冲突态**。系统代理与 TUN 互斥；两者同时为开时报 `STATE=conflict` 并停下。TUN 已开时 `on` 会拒绝，因为那可能是用户故意开的。

## 目录

```
skills/mihari-pilot/
├── SKILL.md                    技能本体（英文；description 里同时带中文触发词）
├── scripts/mihari.ps1          全部实现，PowerShell 5.1、纯 ASCII、无依赖
└── references/
    ├── troubleshooting.md      退出码、三条通道、故障对照、为什么探测在 mihomo 里跑
    └── setup.md                其他机器/harness 的初始化与移植指南（指导性，未经第二台机器验证）
```

## 许可

MIT，见 [`LICENSE`](LICENSE)。mihari 是另一个项目，采用 GPL-3.0；本仓库既不包含也不衍生其代码。
