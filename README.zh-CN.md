[English](README.md) · **中文**

# mihari-pilot

一个 agent 技能：让 agent **自行诊断并操作本机的 [mihari](https://github.com/mihari-proxy/mihari) 代理**——零审批读状态、查清某个域名到底走哪条规则和哪个节点出口、按需切换节点与订阅、修复 daemon/核心/出口链路，并在该开系统代理或 TUN 的时候自己开。

> **非官方。** 这是第三方配套技能，与 mihari 项目无隶属关系、未获其背书、也不是它的一部分。它只覆盖常见的 agent 工作流：技能里没提到的功能，mihari 可能依然支持——下结论前先看 `mihari --help` 或上游文档。mihari 本体是 GPL-3.0；本仓库不含任何 mihari 代码，只有一个调用它的脚本。

## 它到底解决什么

"让 agent 自己修网络"通常死在三个地方，这个技能就是围着这三点设计的：

1. **只读的事不该花审批——能绕开管道就绕开。** `status` / `doctor` / `trace` / `env` / `nodes` 不需要控制管道；`subs` 的数据在管道后面，受限沙箱里可能需要一次更宽权限的重试。所有经管道的命令（`on` / `off` / `select` / `use-sub` / `fix` / `subs`）都会输出 `NEED_ESCALATION=1`，让 harness 恰好重试一次。
2. **"我在用哪个节点"不等于"这个域名会走哪个节点"。** `trace <域名>` 同时给两样：**预测**（命中的规则 + 解析后的组链 + 末端节点）与**实证**（mihomo 日志里该域名最后一次真实连接的结果，失败时连出口节点自己的服务器地址和错误原因都在里面）。
3. **错答案比没答案更坏。** 当脚本无法判断时——配置读不到、规则类型判不了、入参是裸 IP、日志级别压掉了证据、沙箱拒绝了进程或管道访问——它会明说并以非零码退出，而不是打一行看起来很像结论的东西；读不到的状态报 `unknown`，绝不猜成 `off`。

## 子命令

| 子命令 | 作用 |
|---|---|
| `status` | 一行：daemon、核心、系统代理、TUN、组链、模式、代理端口（附真实可达性）、TUI、env；`--probe` 追加一次由 daemon 执行的延迟测试 |
| `doctor` | 能力矩阵：Node、可执行文件、配置、token、管道、daemon 版本/健康/协议/能力、解析出的端口及来源、控制器、注册表、服务、egress、routing、日志 |
| `trace <域名\|URL>` | 命中规则 → 解析链 → 末端节点，外加观测到的最后一次连接；`--probe` 顺带测该节点 |
| `env` | 实时 mixed 端口的 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` / `NO_PROXY` |
| `on` / `off` | 系统代理 / TUN 开关；`--tun` 作用于 TUN；命令会收敛到恰好一个出口并输出 `SWITCHED=` 说明 |
| `tui` | 幂等确保 mihari TUI 在运行，方便用户查看 |
| `nodes [组]` | 列出组或某组成员及当前选中；`--probe` 追加延迟 |
| `select <组> [节点]` | 按名称或唯一子串切节点；省略节点 = 自动测速挑最快健康节点 |
| `subs` | 列出订阅：激活/启用/缓存/到期/流量 |
| `use-sub <id\|名称\|前缀>` | 切换激活订阅（必要时自动启用 + 自动刷新，然后校验） |
| `fix [域名]` | 修复阶梯：daemon → 核心 → mixed 端口 → 出口节点延迟测试；仅当失败出口是手动选中的代理节点时，才在同组内改选健康兄弟节点 |

所有命令都支持 `--json`；输出是稳定的单行 `KEY=value` 协议 + `WARN=` 行 + 末行 `EXIT=`（0 成功 · 1 仍不通 · 2 环境问题 · 3 需要用户决策）。

## 它怎么和 mihari 通信

- **写与读：mihari 本地控制管道**（`\\.\pipe\mihari-control`）——带 `protocol_version`/`capabilities` 的 HTTP/1.1 API，用 `~/.mihari/control.token` 里的 64 位十六进制 token 鉴权。这与 TUI 同一条通道，错误返回结构化 `mihari.error/v1`。
- **回退读：mihomo external-controller（loopback TCP）**，用于 `/version`、`/configs`、`/rules` 和延迟探测，用 `mihari.yaml` 里的 `controller-secret` 鉴权。
- **被动检查**：注册表（`ProxyEnable`/`ProxyServer`）与 mixed 端口的 TCP 连通性。

端口从不写死：来自 `mihari.yaml` 与运行中的核心，`doctor` 会标明每个值的来源。

## 安装

本仓库采用 `skills/<name>/SKILL.md` 布局，所以**用技能安装器指向本仓库，或把技能目录手工拷进技能根**——不要把仓库直接克隆进技能根，技能在下一层。

```powershell
# 或者直接拷：
skills\mihari-pilot  ->  %USERPROFILE%\.dsh\skills\   # 或你的 harness 的技能根
```

## 依赖

- 已安装且服务在运行的 mihari（v0.9.x）。安装是上游的事——见 <https://github.com/mihari-proxy/mihari#quick-start>，本技能刻意不复述。
- Windows 11 或更新，Node 18+（`node` 在 `PATH` 里）。无 npm 依赖，不用 PowerShell。
- 由 mihari 托管的 mihomo 核心（技能正是通过控制器读它）。

## 刻意的边界

- **不修改** `mihari.yaml`、订阅内容、节点定义或注册表。它只从本地文件读取控制 token 与 controller-secret，这是它碰这些文件的唯一理由。
- `select` 与 `use-sub` 是仅有的路由写操作。`use-sub` 是全局操作，只在用户明确要求时执行；`select GLOBAL` 仅在 global 模式下可用；URLTest 组永远不碰。
- `fix` **绝不自动切换** DIRECT 出口、URLTest 组或伪节点——只报告。
- **不强行制造冲突态**。系统代理与 TUN 互斥；两者同时为开时报 `STATE=conflict` 并停下。`on` / `on --tun` 通过关掉另一个出口来收敛，并输出说明。
- 不做 `service install/uninstall/purge`、`self update` / `core update`、egress 或 routing-mode 修改。

## 目录

```
skills/mihari-pilot/
├── SKILL.md                    技能本体（英文；description 里同时带中文触发词）
└── scripts/mihari.mjs          全部实现，Node >= 18，仅标准库，单文件
```

## 许可

MIT，见 [`LICENSE`](LICENSE)。mihari 是另一个项目，采用 GPL-3.0；本仓库既不包含也不衍生其代码。
