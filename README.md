**English** · [中文](README.zh-CN.md)

# mihari-pilot

An agent skill that lets an agent **diagnose and operate the local [mihari](https://github.com/mihari-proxy/mihari)
proxy by itself** — read the proxy state without asking for permission, find out which rule and which exit node a
domain actually uses, and turn the system proxy or TUN on and off when that is genuinely the right answer.

> **Unofficial.** This is a third-party companion skill. It is not affiliated with, endorsed by, or part of the
> mihari project. mihari itself is GPL-3.0; this repository contains no mihari code — only a script that calls it.

## What it actually does

Most "agent can fix the network" attempts fail in one of three ways. This skill is shaped around those:

1. **Read-only work should never cost an approval.** `status`, `doctor`, `trace` and `env` talk to mihomo's local
   controller over loopback TCP, read the registry, and read the core log. No control-pipe access is involved, so
   they run in a read-only or workspace-write sandbox with **no approval at all**. Only the write commands
   (`on` / `off` / `ensure-tui`) need wider access, and the skill asks for exactly once.
2. **"Which node am I using" is not "which node will this domain use".** `trace <domain>` returns both: the
   **prediction** (matched rule + resolved group chain + terminal node) and the **observation** from mihomo's log
   (what the last real connection for that host actually did, including the exit node's own server and error when
   it failed).
3. **A wrong answer is worse than no answer.** When the script cannot tell — an unreadable config, an
   un-evaluable rule type, a bare-IP argument, a sandbox that distorts a probe — it says so and exits non-zero
   instead of printing something that looks authoritative.

## Commands

| Command | What it does | Approval |
|---|---|---|
| `status` | one line: daemon, core, system proxy, TUN, group chain, mode, proxy port (with a real reachability check), TUI, env | none |
| `doctor` | capability matrix for this machine **and this sandbox** — shell, language mode, resolved ports and their source, controller, registry, pipe access, log | none |
| `trace <domain\|URL>` | matched rule → resolved chain → terminal node, plus the observed last connection; `-Probe` also tests that node | none |
| `env` | `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` / `NO_PROXY` for the mixed port | none |
| `on` / `off` | system proxy on/off; `-Tun` scopes it to TUN and maintains the mutual exclusion | one escalation |
| `ensure-tui` | idempotently make sure the mihari TUI is running so the user can watch | one escalation |

## Install

This repository lays skills out as `skills/<name>/SKILL.md`, so **point a skill installer at the repository, or
copy the bundle into your agent's skills root** — do not clone it straight into the skills root, because the
skill sits one level down.

With DSH's installer (from the [`find-skills`](https://github.com/) skill):

```powershell
node <path-to>\dsh-install.mjs --repo yxm1122/mihari-pilot --all
# or simply copy:  skills\mihari-pilot  ->  %USERPROFILE%\.dsh\skills\
```

For other harnesses, copy `skills/mihari-pilot` into that harness's own skills root (`.agents/skills/`,
`.claude/skills/`, `~/.codex/skills/`, …). See [`skills/mihari-pilot/references/setup.md`](skills/mihari-pilot/references/setup.md)
for what to adapt — several parts of this skill are specific to DSH's sandbox and escalation model.

## Support matrix

| Environment | Status |
|---|---|
| DSH (DeepSeek Harness) on Windows, PowerShell 5.1 | **tested** — this is what the skill was built and verified against |
| Windows, PowerShell 7 | expected to work; not tested |
| Other agent harnesses (Claude Code, Codex, Cursor, Copilot CLI, …) | **not tested** — `references/setup.md` explains what to change; the frontmatter deliberately uses only `name` + `description`, which every harness accepts |
| Linux / macOS | not supported by this script (`powershell -File` cannot run there); mihari itself does support them, and `setup.md` lists what a port needs |

## Requirements

- A running mihari installation with its service up. Installation is upstream's job —
  see <https://github.com/mihari-proxy/mihari#quick-start>. This skill deliberately does not repeat it.
- Windows PowerShell 5.1 or newer.
- A mihomo core that mihari manages (that is what the skill reads through the controller).

## Boundaries (on purpose)

- The skill **never modifies** `mihari.yaml`, subscriptions, nodes or the registry. It reads the controller
  secret from the config; that is the only reason it touches the file.
- It **never selects a node**. When a node is dead it reports which one and hands the decision back.
- It **never forces** a conflicting state. System proxy and TUN are mutually exclusive; when both are on it
  reports `STATE=conflict` and stops. `on` refuses when TUN is already on, because the user may have enabled it
  deliberately.

## Layout

```
skills/mihari-pilot/
├── SKILL.md                    the skill itself (English; the description carries Chinese trigger words too)
├── scripts/mihari.ps1          the whole implementation, PowerShell 5.1, pure ASCII, no dependencies
└── references/
    ├── troubleshooting.md      exit codes, channels, failure table, why the probe runs inside mihomo
    └── setup.md                initialization and porting guide for other machines/harnesses (guidance, unverified)
```

## License

MIT — see [`LICENSE`](LICENSE). mihari is a separate project under GPL-3.0; this repository neither includes nor
derives from its code.
