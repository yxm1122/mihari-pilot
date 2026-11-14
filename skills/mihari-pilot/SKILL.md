---
name: mihari-pilot
description: Check and drive the local mihari proxy before an agent tries to fix the network. Read state, trace the real exit chain for a domain, switch nodes and subscriptions, repair daemon/core/exit problems, and toggle the system proxy or TUN. Use when a request times out, github/npm/pip/git cannot connect, DNS fails, a proxy is needed or suspected, or the user asks to 检查代理 / 开代理 / 关代理 / 走代理 / 换节点 / 换订阅 / 翻墙 / 连不上.
---

# mihari-pilot

> **Third-party, opinionated subset — not mihari's manual.** This skill covers common agent workflows only; a
> feature it does not mention may still exist in mihari. Before concluding "mihari cannot do X", check
> `mihari --help` (no pipe needed) or upstream <https://github.com/mihari-proxy/mihari> (docs/commands.md, TUI, Web panel).

Drives the local **mihari** daemon (service `mihari`, data root `~/.mihari` on Windows), which manages mihomo.
mihari owns two **mutually exclusive** exits: the system proxy (WinINET, for desktop apps) and TUN (IP layer).

**Windows only, Node >= 18.** Everything goes through one script — no PowerShell, no dependencies:

```powershell
node "<skill-dir>\scripts\mihari.mjs" <command> [args] [--probe] [--json] [--tun]
```

`<skill-dir>` is the Base directory reported when this skill loads. Writes use mihari's control pipe
(`\\.\pipe\mihari-control`, Bearer token from `control.token`); mihomo's controller is only a fallback. Run `doctor` first if anything looks off.

## Read this first: a working exit is not the system proxy
As long as the mihari service runs, the mixed port is a usable HTTP/SOCKS proxy. `STATE=off` (both exits off)
**does not mean no proxy** — they exist only for programs you cannot configure yourself. Smallest fix for "my
request failed": `status --probe`, then wrap the command in the `env` variables. `on` is only for other programs.

**Never hardcode a port.** Ports are per machine; `status`, `doctor` and `env` print the live values (the running core wins over `mihari.yaml`).

## Ladder: smallest step first
| Step | When a request fails | Command |
|---|---|---|
| 1 | look first | `status --probe` |
| 2 | use the proxy yourself | `env`, wrap your command |
| 3 | the route or exit looks wrong | `trace <domain>` |
| 4 | the path is broken | `fix [domain]` |
| 5 | a program you do not control needs it | `on` (system proxy) |
| 6 | everything must go through it | `on --tun` |

Do not skip steps. TUN takes over every packet at the IP layer; use it only when the user asks for it.

## Commands
**`status [--probe]`** — no writes; run this first:

```
STATE=off|sysproxy|tun|conflict|unknown SYS=off|unknown|on[(foreign:<host:port>)] TUN=off|on|unknown
CORE=running/<ver>|down|unknown DAEMON=running|stopped|unknown NODE=<group>><node> MODE=rule|global|direct
MIXED=<port>:up|down TUI=present:<pid>|absent|unknown ENV=unset|set PROBE=skip|ok(<ms>ms)|fail(<reason>)
```

Problems are separate `WARN=` lines. `--probe` adds one daemon-side delay test. In a confined sandbox `DAEMON`/`TUI`/`SYS`/`STATE` can be `unknown` (access denied) — that is not "off".

**`doctor [--json]`** — capability matrix: Node, exe, config, token, pipe, daemon version/health/protocol/
capabilities, ports and their source, controller, core, registry, service, egress, routing, TUI, log; always exits 0, `NOTE=` explains what is degraded.

**`trace <domain|URL> [--probe]`** — which rule matches and which node the domain leaves through:

```
TRACE=youtube.com RULE=DomainSuffix(youtube.com)-><group> CHAIN=<group>><node> NODE=<node> CONFIDENCE=exact
EVIDENCE=ok <time>  DomainSuffix(youtube.com) using <group>[<node>]
```

`RULE`/`CHAIN`/`NODE` are a **prediction** from the current selection; `EVIDENCE` is the last connection the log
saw (`ok … using <group>[<node>]`, or `fail … dial <group> (match <rule>) error: <reason>`). Trust it only when
recent AND its node matches the chain — `WARN=evidence_stale` / `evidence_predates_selection` mean it describes
the past, so use `--probe` or `status --probe` for current health. `CONFIDENCE=approx` means an undecidable rule
sits earlier; `none` means a bare IP — only `EVIDENCE` is meaningful. `EVIDENCE=none_…`: never forwarded, log
level above `info`, or rotated out.

**`env`** — prints `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`/`NO_PROXY` for the live mixed port. The system proxy
only covers WinINET apps, so **your own requests need these variables**.

**`on [--tun]`** / **`off [--tun]`** — idempotent. `on` and `on --tun` **converge** to exactly one exit: if the
other one is on it is switched off first (`SWITCHED=tun->sysproxy` / `sysproxy->tun`). `off` turns both off;
`off --tun` only TUN. TUN conflicts are reported (`EXIT=3`), never force-overridden.

**`tui`** — idempotently ensure the TUI is running (detached console window the user closes).

**`nodes [group] [--probe]`** — groups (`GROUP=<name> TYPE=<type> NOW=<sel> MEMBERS=<n>`) or one group's members
(`NODE=<name> CURRENT=yes|no [DELAY=…]`). Names accept unique substrings; ambiguity lists `CANDIDATE=` lines.

**`select <group> [node]`** — switch nodes. With no `node`, measures the group and picks the fastest healthy
member (REJECT, pseudo-nodes, DIRECT and nested groups are never auto-picked) and prints
`AUTO_PICK=<node> DELAY=<ms>`. `select <node>` searches the primary selector first, then other Selector groups.
`select GLOBAL` needs `MODE=global`; URLTest groups are not selectable. Reports
`SELECT=<group>:<node> PREV=<old> CHANGED=…`.

**`subs`** — subscriptions: id, name, active/enabled/cache/generation, expiry, traffic.

**`use-sub <id|name|prefix>`** — switch the active subscription: auto-enables, refreshes when it has no cache,
activates, verifies. It is global — only when the user asked; the script never picks a subscription itself.
Unknown targets exit 2; ambiguous names exit 3 with `CANDIDATE=` lines.

**`fix [domain]`** — daemon (one `mihari service start`) → core (one restart) → mixed port → delay test of the
current exit. If the failing exit is a manually selected proxy node, it picks the fastest healthy sibling in the
same selector and re-tests; DIRECT, URLTest groups, pseudo-nodes, and a domain that fails across an otherwise
healthy group are never auto-switched (reported instead).

```
FIX=ok|fixed|failed STEPS=<steps> CHANGED=none|node:<group>:<old>-><new> [PATH=ok NODE=<node>] [STEP=<failed-step> REASON=...]
```
`fix` never touches sysproxy, TUN, subscriptions, egress or routing mode.

## The invariant
System proxy and TUN **must not both be on**. `STATE=conflict` → stop and tell the user. Commands converge toward what you explicitly asked for and print `SWITCHED=` whenever they had to turn something off.
## Boundaries
- **Never modify** `mihari.yaml`, subscription content, node definitions or the registry. The script reads
  `controller-secret` and `control.token` itself; that is the only reason it touches those files.
- `select` and `use-sub` are the only routing writes offered; nothing else switches traffic.
- No `service install/uninstall/purge`, no `self update` / `core update`, no egress/routing-mode changes, no
  killing processes. A dead node is a report, not a guess: `nodes --probe`, then a named `select` or auto pick.
- Non-GLOBAL selections live in mihomo and may not survive a subscription refresh; re-check with `status`.
- If the daemon is not running, `on`/`off`/`fix` attempt `mihari service start` once; a permission failure is
  reported (needs an administrator).

## Exit codes and escalation
`EXIT=0` ok · `1` ran but still offline · `2` environment problem · `3` needs the user (conflict, ambiguity, foreign proxy, TUN conflict, global-mode gate).

`NEED_ESCALATION=1` means the sandbox blocked mihari's control pipe (writes and `subs`). Retry the same command **once** with wider access; never retry other read-only commands that way, and never loop.

Common `WARN=` lines: `mihari_not_found`, `daemon_stopped`, `daemon_state_unknown`, `tui_state_unknown`,
`process_enumeration_denied`, `core_down`, `mihari_config_unreadable`, `settings_missing_from_config:<keys>`,
`mixed_port_drift:yaml=…,live=…`, `sysproxy_state_unknown`, `tun_state_unknown`, `sysproxy_and_tun_both_on`,
`foreign_sysproxy:<host:port>`, `suspicious_node:<name>`, `rule_order_preceded_by_undecidable:<type>#<index>`,
`trace_target_is_ip_ip_rules_not_evaluated`, `evidence_stale:<age>s`, `evidence_predates_selection:<node>`,
`no_healthy_node:<group>`, `subscription_error:<name>:<reason>`, `daemon_unavailable`, `control_pipe_denied`,
`control_token_missing`, `control_auth_failed`, `selection_not_effective`.

## When you are done
Restore what **you** turned on; leave what the user had on. Announce every change in one line:
`PROXY: off → on (sysproxy)`. A TUI you started is not a debt (the user closes it), and node/subscription
choices the user made by hand are not yours to revert — but **your** `select`/`use-sub`/`fix` changes are yours
to state.
