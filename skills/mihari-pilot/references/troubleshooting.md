# mihari-pilot — troubleshooting reference

Read this only when `status`, `trace` or `doctor` reports something you do not understand.

## Exit codes

The script's own:

| code | meaning | next step |
|---|---|---|
| 0 | query succeeded / target state reached | continue |
| 1 | the command ran, but `-Probe` still fails | node or subscription problem; report it |
| 2 | environment problem (see the `WARN=` lines) | report them; if `NEED_ESCALATION=1`, retry once with wider access |
| 3 | needs the user (conflict, TUN in the way, proxy owned by someone else) | stop and ask |

mihari's own code is passed through as `MIHARI_EXIT=`: `0` ok · `2` usage / `system_proxy_not_owned` · `3` daemon
unavailable · `4` invalid state · `5` permission · `6` conflict · `7` upstream failure · `8` network failure ·
`9` data failure · `10` internal.

## The channels (why the script is written this way)

| channel | what it reads | needs escalation |
|---|---|---|
| mihomo external-controller on loopback TCP (`controller-addr` in `mihari.yaml`) | `/version`, `/configs` (`tun.enable`, `mode`, `mixed-port`), `/proxies` (group chain), `/rules` (ordered rule table), `/connections` (live only, usually empty) | no |
| registry `HKCU\...\Internet Settings` | `ProxyEnable`, `ProxyServer` | no |
| log `~/.mihari/logs/mihomo.log` | one line per real connection — `match <rule> using <group>[<node>]` on success, `dial <group> (match <rule>) … error: <reason>` on failure | no |
| mihari control pipe `\\.\pipe\mihari-control` | every write operation (`mihari sysproxy\|tun enable\|disable`, …) | **yes** |

mihari's control API **binds no TCP port** — it is a named pipe. Confined sandboxes deny named pipes, and the
denial is inherited by child processes, so inside one every `mihari` subcommand returns `exit 5 /
permission_denied`, and a TUI started from there cannot reach the daemon either. That is what `NEED_ESCALATION=1`
means. The controller on loopback TCP is unaffected, which is why the read-only path is approval-free.

**The two channels have different price tags.** The script itself may need one `workspace-write` retry in a
read-only session (see the next section), while mihari's control plane needs `danger-full-access` in *any*
confined mode. Same "look, don't touch" intent, two different approvals — which is why troubleshooting should go
through `trace` instead of hand-rolled CLI calls.

## Confined sandboxes push PowerShell into ConstrainedLanguage

Measured on Windows: **blocked** — `New-Object <non-core type>`, `[System.IO.File]::ReadAllText`,
`[Console]::OutputEncoding=`. **Allowed** — `Get-Content -Raw`, `Select-String`, `-match` / `$Matches`,
`[regex]::Match`, `[uri]::EscapeDataString`, `ConvertFrom-Json` / `ConvertTo-Json`, registry cmdlets,
`Get-Service` / `Get-Process`, external executables.

Two failure shapes with different meanings:

- The script **never starts**: `Cannot dot-source this command because it was defined in a different language
  mode` / `DotSourceNotSupported` plus `[exit code: 1]`. The invocation was rejected before the body ran; retry
  the same command **once** with wider access.
- The script runs but **degrades**: an early build printed `CORE=down … EXIT=0` while the core was alive. Fixed —
  when it cannot tell, it now prints `CORE=unknown` + `WARN=mihari_config_unreadable` + `EXIT=2`.

Lesson for anyone editing the script: build collections with `@()` + `+=`, read files with `Get-Content -Raw`,
and **never guess when you cannot tell** — a guessed `CORE=down` sends the next agent chasing a fault that does
not exist.

## trace: prediction versus observation

`trace <domain>` prints two lines with different meanings — do not mix them.

- `RULE=` / `CHAIN=` / `NODE=` are a **prediction**: from `/rules`, in `index` order, the first rule that can be
  decided for a domain name, then that rule's `proxy` resolved along the `/proxies` `now` chain to a terminal node.
- `EVIDENCE=` is an **observation**: the last real connection for that host in `mihomo.log`, in one of two shapes:
  - `ok <time>  <rule>[(payload)] using <group>[<node>]` — dispatched. Note that a rule with an empty payload
    (e.g. `Match`) is logged **without parentheses**, as `match Match using …`.
  - `fail <time>  dial <group> (match <rule>[/payload]) error: <reason>` — dispatch failed. `<reason>` usually
    names the **exit node's own server**, e.g. `connect error: context deadline exceeded` against
    `node.example.com:20059`. This is the fastest way to tell "the node is dead" from "the site blocked me".

`/connections` holds live connections only (usually empty), so historical evidence can only come from the log.
When the prediction and the observation disagree, trust `EVIDENCE` — the group usually re-selected in between.
For "which chain is in use *right now*", have the user reproduce the request and run `trace` again.
`EVIDENCE=none_no_recent_connection_in_log` simply means this host has not been forwarded by this core lately.

**`trace <domain> -Probe`** additionally tests the predicted terminal node and prints `PROBE=ok(ms)|fail(reason)`.
When TCP connects but the TLS handshake breaks or stalls, use this flag: one call gives both "which chain should
be used" and "is that chain usable".

`CONFIDENCE` has three values: `exact` = the matched rule is a domain rule and nothing undecidable precedes it;
`approx` = an IP / process / port / geosite / ruleset rule sits earlier and might match first — the first such rule
is named in `WARN=rule_order_preceded_by_undecidable:<type>#<index>`; `none` = the input was a bare IP, for which
domain rules say nothing and the script deliberately does not evaluate IPCIDR/GEOIP
(`WARN=trace_target_is_ip_ip_rules_not_evaluated`) — then only `EVIDENCE=` is meaningful.

## Failure table

| symptom | meaning | next step |
|---|---|---|
| script does not start: `different language mode` / `DotSourceNotSupported` | a read-only session's restricted language mode rejected the invocation | retry once with `workspace-write` (**not** `danger-full-access`) |
| `WARN=mihari_not_found` | binary is not on PATH and not in the default install location | report to the user |
| `DAEMON=stopped` | the `mihari` service is not running | report to the user (`mihari service start` needs an administrator) |
| `CORE=down` | the controller does not answer **and** the config was readable (so the daemon is up) | report to the user; `mihari core restart` needs escalation |
| `CORE=unknown` + `WARN=mihari_config_unreadable` + `EXIT=2` | `mihari.yaml` could not be read, so the core state is **unknown** | environment problem, not a core fault; report as `EXIT=2`, do not chase a phantom |
| `WARN=settings_missing_from_config:<keys>` | the config exists but those keys are absent, so built-in fallbacks were used for the ports | treat the ports as guesses; `doctor` shows `PORTS=… source=fallback_missing_keys:…` |
| `MIXED=<port>:down` | nothing is listening on the proxy port (core not started or crashed) | report to the user; read `CORE=` too |
| `EVIDENCE=fail … error: …` | the last real connection for that host failed to dispatch; the reason names the exit node's server | exit-node problem: report and let the user switch nodes; do not edit config or select nodes yourself |
| `EVIDENCE=none_no_recent_connection_in_log` | this host has not been forwarded lately | have the user reproduce the request, then `trace` again |
| `WARN=trace_target_is_ip_ip_rules_not_evaluated` | the `trace` argument was a bare IP, so domain rules do not apply | use `EVIDENCE=`, ignore `RULE=` |
| `STATE=conflict` | system proxy and TUN are both on | stop; let the user choose one |
| `SYS=on(foreign:<host:port>)` | the system proxy belongs to other software | `on` refuses; `off` cannot clear it either — hand it to the user |
| `WARN=suspicious_node:<name>` | a subscription pseudo-node (`remaining traffic`, `plan expires …`) is selected — providers often inject these into URLTest groups | send the user to the TUI's Proxies page to pick a real node |
| `WARN=mixed_port_drift:yaml=…,live=…` | configured port and the live core port disagree (usually a port change without a daemon restart) | the live value wins; suggest a daemon restart |
| `CONFIDENCE=approx` | the `trace` prediction has an undecidable rule before the match | treat it as a hint, trust `EVIDENCE` |
| `PROBE=fail` while `CORE=running` | node / subscription / traffic exhausted | report; do not change nodes yourself |
| `NEED_ESCALATION=1` | the sandbox blocked the named pipe (write commands only) | retry the same command once with `danger-full-access` |
| `MIHARI_EXIT=6` | state conflict (revision / TUN conflict) | run `status` again, then retry once |
| `TUI=blocked` / `TUI=failed:…` | the sandbox blocked the pipe, or the TUI could not start | retry `ensure-tui` once with `danger-full-access` |
| TUI opens without colour | the launched process inherited `NO_COLOR=1` from the harness | the script strips that variable around the spawn (do not "fix" it with `-UseNewEnvironment`, which a confined sandbox denies); if it still happens, check `~/.mihari/preferences/tui.json` |

## Why `-Probe` runs inside mihomo

`-Probe` calls mihomo's `/proxies/<node>/delay`; the request is made **by mihomo**, so this process performs no
TLS. The reason is that a confined sandbox's token cannot obtain Windows Schannel credentials
(`curl: (35) schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS 0x8009030e`), so **any** `https://`
request from this process fails — direct or proxied alike — which would report a healthy proxy as "network down".
Plain HTTP is unaffected and still works through the mixed port.

The same limitation applies to the caller: inside a confined sandbox `curl https://…` and `Invoke-WebRequest`
always fail (**or merely time out**), unrelated to the proxy; only tools with their own TLS stack (Node, Python)
really use the variables from `env`. When a client reports `ECONNRESET` or `SSLEOFError` at the handshake and two
independent TLS stacks show the same signature, the problem is the exit node — confirm with `trace <domain> -Probe`
or by reading the `EVIDENCE=fail` line.

**The test target must be plain HTTP** (`http://www.gstatic.com/generate_204`, which is Clash's own default test
URL), with a second target as a fallback. Do not narrow it to `https://www.gstatic.com/generate_204`: measured on
one node that https target timed out while the http target answered in 927 ms — an https-only target reports a
false failure and turns a healthy proxy into a reported fault.

`PROBE=fail(...)` carries one of `no_node`, `controller_unreachable`, `unparsable`, `delay_failed`, or mihomo's
own error text.

## Semantics worth knowing

- **Ports are not fixed.** `mixed-addr` and `controller-addr` are read from `~/.mihari/mihari.yaml` on every run;
  the proxy port additionally follows the live `/configs.mixed-port`. Built-in fallbacks exist only for the case
  where the config cannot be read, and that case is always reported (`WARN=mihari_config_unreadable` /
  `WARN=settings_missing_from_config:…`). Changing ports is done in the TUI (System → Ports Config) and usually
  needs a daemon restart.
- **System proxy** (`sysproxy`): only flips WinINET's `ProxyEnable`, which covers browsers and desktop apps; it
  does **not** affect the agent's own processes — that is what `env` is for. On disable, mihari deliberately keeps
  `ProxyServer` in place, so an address remaining in the registry while `SYS=off` is normal.
- **TUN**: mihomo takes over every packet at the IP layer (including the agent's own), with `auto-route` and
  `dns-hijack`. Highest cost, and mutually exclusive with the system proxy.
- **`off` does not stop processes**: mihomo keeps listening on the mixed port; only `mihari service stop` really
  stops it.
- **Node selection belongs to the user**: once a selector group is pinned to a node by hand it stops rotating
  (URLTest only rotates inside its own group). When a node is dead, report it and hand it back.
- **The TUI** is a console/bubbletea program with no window handle; running `mihari.exe` with no arguments opens
  it, and it needs a real console (redirect its output and it exits 2). It is detected as "a mihari process that
  is not in session 0".

## Logs

`~/.mihari/logs/` holds JSONL: `mihari-daemon.log` (daemon operations and `control.server` errors),
`mihari-tui.log` (`tui started`, accompanied by `daemon_unavailable` when it cannot reach the daemon), and
`mihomo.log` (core output, including the per-connection `match … using …` and `dial … error: …` lines that
`trace` reads). Read the last few lines; never read them whole.
