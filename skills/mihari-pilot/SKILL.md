---
name: mihari-pilot
description: Check and drive the local mihari proxy before an agent tries to fix the network. Read its state, resolve the real exit chain for a domain, and turn the system proxy or TUN on or off. Use when a request times out, github/npm/pip/git cannot connect, DNS fails, a proxy is needed or suspected, or the user asks to 检查代理 / 开代理 / 关代理 / 走代理 / 翻墙 / 连不上.
---

# mihari-pilot

Drives the local **mihari** daemon (service `mihari`, data root `~/.mihari`), which manages mihomo. mihari owns
two **mutually exclusive** exits: the system proxy (WinINET, for desktop apps) and TUN (IP layer, for everything).

**Everything goes through one script** (it reads `controller-secret` from `mihari.yaml` itself, read-only):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\mihari.ps1" <command>
```

`<skill-dir>` is the Base directory reported when this skill loads.

## Read this first: a working exit is not the same as the system proxy

**As long as the mihari service is running, the mixed port is a usable HTTP/SOCKS proxy.** `STATE=off` (system
proxy and TUN both off) **does not mean no proxy is available** — the system proxy and TUN exist only for
programs you cannot configure yourself.

So the smallest fix for "my request failed" is: `status` to confirm `CORE=running`, then wrap the command in
`env`. Reach for `on` only when some program you do not control must use the proxy.

**Never hardcode a port.** Ports are chosen per machine and read from `mihari.yaml` at runtime; `doctor`,
`status` and `env` print the values actually in use.

## Ladder: look first, then escalate by the smallest step

| Step | When a request fails | Approval |
|---|---|---|
| 1 | `status` | none |
| 2 | `env`, wrap the command that needs the network | none |
| 3 | `trace <domain>` when the route or the exit looks wrong | none |
| 4 | `on` (system proxy) | one |
| 5 | `on -Tun` (TUN) | one |

Do not skip steps. TUN takes over every packet at the IP layer; use it only when the user asks for it.

## Commands

**`status`** — no approval; run this first. It doubles as the "is mihari installed / is the service up" check:
`WARN=mihari_not_found` = binary missing, `DAEMON=running|stopped` = service state, `MIXED=<port>:up|down` =
the proxy port was actually reached. **Do not** probe the `mihari` CLI instead: its control channel is a
Windows named pipe, a confined sandbox always denies it, and you would burn an approval for nothing.

```
STATE=off SYS=off TUN=off CORE=running/<ver> DAEMON=running NODE=<group>><group>><node> MODE=rule MIXED=<port>:up TUI=present:<pid> ENV=unset PROBE=skip
```

`STATE=off|sysproxy|tun|conflict`. Problems arrive as separate `WARN=` lines. `-Probe` adds one real
connectivity test, performed by mihomo itself (so the sandbox cannot distort it); on failure the exit code
becomes 1.

**`doctor`** — no approval. Capability matrix for this machine *and this sandbox*: shell version, language mode,
mihari path, config/data paths, resolved ports and where they came from, controller, core, registry, pipe
access, TUI, log. It always exits 0 — it is a report, not a state query. Anything the sandbox can distort is
labelled (`PIPE=denied(exit5)`) with a `NOTE=` telling you to re-run it under the sandbox you actually use.

**`trace <domain|URL>`** — no approval. Answers "which rule does this domain hit, and which node does it leave
through", in two lines (`-Probe` adds a third):

```
TRACE=youtube.com RULE=DomainSuffix(youtube.com)-><group> CHAIN=<group>><group>><node> NODE=<node> CONFIDENCE=exact
EVIDENCE=ok <timestamp>  DomainSuffix(youtube.com) using <group>[<node>]
```

- `RULE` / `CHAIN` / `NODE` are a **prediction** (rule order plus the current group selection). `EVIDENCE` is
  what the log says **actually happened**: either `ok … using <group>[<node>]`, or
  `fail … dial <group> (match <rule>) error: <reason>`, where `<reason>` names the exit node's own server.
  When the two disagree, trust `EVIDENCE`.
- `-Probe` also tests the predicted exit node (`PROBE=ok(ms)|fail(reason)`). Use it when TCP connects but the
  TLS handshake breaks or stalls: one call separates "the exit node is dead" from "the site is blocked".
- `CONFIDENCE=`: `exact` is trustworthy; `approx` means an IP/process/port rule sits earlier and might match
  first (`WARN=rule_order_preceded_by_undecidable:<type>#<index>` names it); `none` means the input was a bare
  IP, where domain rules say nothing and only `EVIDENCE` is meaningful.
- For "this domain goes to the wrong region / gets sent to DIRECT", use this — **not** the raw `mihari rules` or
  `mihari proxy groups` CLI, which needs a full-access approval and wastes calls on `--help`.

**`env`** — no approval. Prints `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` / `NO_PROXY` for the mixed port. The
system proxy only covers WinINET apps, so **your own requests need these variables** — copy the values it prints
rather than typing a port:

```powershell
$env:HTTP_PROXY='http://<host>:<mixed-port>'; $env:HTTPS_PROXY=$env:HTTP_PROXY; <your command>
```

Inside a confined sandbox, an `https://` request from this process fails because Windows Schannel cannot get
credentials (`SEC_E_NO_CREDENTIALS`) — **or merely times out**; both signatures are unrelated to the proxy and
happen on a direct connection too. Only tools with their own TLS stack (Node, Python) really use these variables.

**`on`** / **`off`** — toggle the system proxy. `-Tun` scopes the action to TUN (`on -Tun` means "I want TUN" and
turns the system proxy off first, to keep the invariant). `off` turns both off. Both are idempotent.

**`ensure-tui`** — idempotently make sure the TUI is running (`on` / `off` also do this after succeeding, so one
approval covers both).

## The invariant

The system proxy and TUN **must not both be on**. When `status` reports `STATE=conflict`, stop and tell the user;
do not act. `on` also refuses when TUN is already on, because the user may have enabled it by hand.

## Escalation discipline

`status` / `doctor` / `trace` / `env` only use mihomo's TCP controller, the registry and log files — **no
approval, in any sandbox mode**. Escalation has two sources; pick the smallest that works:

1. **The host sandbox denies you** (`[sandbox: … denied]`, or the script cannot even start and reports
   `different language mode` / `DotSourceNotSupported`): retry the same command **once** with
   `sandbox_permissions: workspace-write` — the script only needs `FullLanguage` in order to run.
2. **`NEED_ESCALATION=1`** (reported by the script: the named pipe is blocked): only `on` / `off` /
   `ensure-tui` hit this. Retry the same command **once** with `sandbox_permissions: danger-full-access`.

Retry once, then stop and report. **Never** use `danger-full-access` for a read-only command.

`EXIT=3` → stop and ask the user. `EXIT=2` → environment problem; report the `WARN=` lines. `EXIT=1` → the
command ran, but the network really is down.

## Boundaries

Report, do not act: **never modify** `mihari.yaml`, subscriptions, nodes or the registry. Reading them is fine —
the script itself reads `controller-secret` from the config. When a node is dead, report it and let the user
switch; do not run `proxy select` yourself. `WARN=suspicious_node:<name>` means a subscription pseudo-node
("remaining traffic", "plan expires …") is selected — that is a configuration problem; send the user to the TUI.
If the daemon is not running, do not try `mihari service start` (it needs an administrator).

## When you are done

Restore what **you** turned on; leave what the user had on. Announce every change in one line:
`PROXY: off → on (sysproxy)`.

Two things are not debts: the TUI started by `ensure-tui` is something the user asked to see (this skill
deliberately offers no way to close it — the user closes the window), and node selections made by hand in the TUI
are not yours to revert.

Exit codes, log locations and the failure table: `references/troubleshooting.md`.
Porting this skill to another agent or platform: `references/setup.md`.
