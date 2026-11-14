**English** · [中文](README.zh-CN.md)

# mihari-pilot

An agent skill that lets an agent **diagnose and operate the local [mihari](https://github.com/mihari-proxy/mihari)
proxy by itself** — read the proxy state without asking for permission, find out which rule and which exit node a
domain actually uses, switch nodes or subscriptions when asked, repair a broken daemon/core/exit path, and turn
the system proxy or TUN on and off when that is genuinely the right answer.

> **Unofficial.** This is a third-party companion skill. It is not affiliated with, endorsed by, or part of the
> mihari project. mihari itself is GPL-3.0; this repository contains no mihari code — only a script that calls it.

## What it actually does

Most "agent can fix the network" attempts fail in one of three ways. This skill is shaped around those:

1. **Read-only work should not cost an approval — when it can avoid the pipe.** `status`, `doctor`, `trace`,
   `env` and `nodes` read without the control pipe; `subs` lives behind it, so a confined sandbox may need one
   wider retry for it. Commands that act through the pipe (`on` / `off` / `select` / `use-sub` / `fix` / `subs`)
   emit `NEED_ESCALATION=1` so the harness can retry exactly once.
2. **"Which node am I using" is not "which node will this domain use".** `trace <domain>` returns both: the
   **prediction** (matched rule + resolved group chain + terminal node) and the **observation** from mihomo's log
   (what the last real connection for that host actually did, including the exit node's own server and error when
   it failed).
3. **A wrong answer is worse than no answer.** When the script cannot tell — an unreadable config, an
   un-evaluable rule type, a bare-IP argument, a log level that suppresses evidence, a sandbox that denies
   process or pipe access — it says so and exits non-zero instead of printing something that looks
   authoritative; unreadable state is `unknown`, never `off`.

## Commands

| Command | What it does |
|---|---|
| `status` | one line: daemon, core, system proxy, TUN, group chain, mode, proxy port (with a real reachability check), TUI, env; `--probe` adds a daemon-measured delay test |
| `doctor` | capability matrix: Node, exe, config, token, pipe, daemon version/health/protocol/capabilities, resolved ports and their source, controller, registry, service, egress, routing, log |
| `trace <domain\|URL>` | matched rule → resolved chain → terminal node, plus the observed last connection; `--probe` also tests that node |
| `env` | `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` / `NO_PROXY` for the live mixed port |
| `on` / `off` | system proxy / TUN on/off; `--tun` scopes to TUN; commands converge to exactly one exit and report `SWITCHED=` |
| `tui` | idempotently make sure the mihari TUI is running so the user can watch |
| `nodes [group]` | list groups or one group's members with the current selection; `--probe` adds delays |
| `select <group> [node]` | switch nodes by name or unique substring; without a node, pick the fastest healthy member |
| `subs` | list subscriptions with active/enabled/cache/expiry/traffic |
| `use-sub <id\|name\|prefix>` | switch the active subscription (auto-enable + auto-refresh when needed, then verify) |
| `fix [domain]` | repair ladder: daemon → core → mixed port → exit-node delay test; re-selects a healthy sibling only when the failing exit is a manually selected proxy node |

All commands accept `--json`; output is a stable single-line `KEY=value` protocol plus `WARN=` lines and a final
`EXIT=` line (0 ok · 1 still offline · 2 environment · 3 needs the user).

## How it talks to mihari

- **Writes and reads: mihari's local control pipe** (`\\.\pipe\mihari-control`) — a versioned HTTP/1.1 API with
  `protocol_version`/`capabilities`, authenticated by the 64-hex token in `~/.mihari/control.token`. This is the
  same channel the TUI uses; responses are structured `mihari.error/v1` envelopes.
- **Fallback reads: mihomo's external-controller on loopback TCP** for `/version`, `/configs`, `/rules` and
  delay probes, authenticated by `controller-secret` from `mihari.yaml`.
- **Passive checks**: the registry (`ProxyEnable`/`ProxyServer`) and a TCP connect to the mixed port.

Ports are never hardcoded: they come from `mihari.yaml` and the live core, and `doctor` shows where each value
came from.

## Install

This repository lays skills out as `skills/<name>/SKILL.md`, so **point a skill installer at the repository, or
copy the bundle into your agent's skills root** — do not clone it straight into the skills root, because the
skill sits one level down.

```powershell
# or simply copy:
skills\mihari-pilot  ->  %USERPROFILE%\.dsh\skills\   # or your harness's skills root
```

## Requirements

- A running mihari installation (v0.9.x) with its service up. Installation is upstream's job —
  see <https://github.com/mihari-proxy/mihari#quick-start>. This skill deliberately does not repeat it.
- Windows 11 or newer, with Node 18+ (`node` on `PATH`). No npm packages, no PowerShell.
- A mihomo core that mihari manages (that is what the skill reads through the controller).

## Boundaries (on purpose)

- The skill **never modifies** `mihari.yaml`, subscription content, node definitions or the registry. It reads
  the control token and controller secret from local files; that is the only reason it touches them.
- `select` and `use-sub` are the only routing writes offered. `use-sub` is global and only runs when the user
  asked for it; `select GLOBAL` only works in global routing mode; URLTest groups are never touched.
- `fix` **never switches** a DIRECT exit, a URLTest group or a pseudo-node — it reports instead.
- It **never forces** a conflicting state. System proxy and TUN are mutually exclusive; when both are on it
  reports `STATE=conflict` and stops. `on` / `on --tun` converge by turning the other exit off and saying so.
- No `service install/uninstall/purge`, no `self update` / `core update`, no egress or routing-mode changes.

## Layout

```
skills/mihari-pilot/
├── SKILL.md                    the skill itself (English; the description carries Chinese trigger words too)
└── scripts/mihari.mjs          the whole implementation, Node >= 18, stdlib only, single file
```

## License

MIT — see [`LICENSE`](LICENSE). mihari is a separate project under GPL-3.0; this repository neither includes nor
derives from its code.
