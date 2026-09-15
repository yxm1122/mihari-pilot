# mihari-pilot — setup and porting guide

**This guide is guidance, not a guarantee.** It was written from one machine (Windows 11, DSH, PowerShell 5.1)
and has **not** been verified on a second machine or a second agent harness. Treat every step as "check this and
decide", not as "this is how it is". Where a fact was measured it says so; where it is not, it says so.

Nothing here covers installing mihari itself — that is upstream's job:
<https://github.com/mihari-proxy/mihari#quick-start>.

## 1. Run `doctor` first, under the sandbox you will actually use

`doctor` prints a capability matrix for the machine *and the sandbox it ran in*:

```
SKILL=mihari-pilot/<version>      SHELL=powershell/<version>     LANGMODE=FullLanguage|ConstrainedLanguage
MIHARI=<path>|missing             CONFIG=present|missing        DATA=<data root>
PORTS=mixed=<port> controller=<host:port> source=config_file|fallback_…
CONTROLLER=ok|unreachable         CORE=running/<ver>|down|unknown
REGISTRY=ok|unreadable proxy_enable=<bool>                       MIXEDPORT_REACHABLE=True|False
PIPE=ok|denied(exit5)|no_binary|daemon_unavailable               TUI=present:<pid>|absent   LOG=present|missing
```

Two of those fields depend on the mode you run it in, so **run it in the mode you intend to keep using** and
read the `NOTE=` lines. If you run it read-only and then work in a wider mode, the `PIPE=` and `LANGMODE=` values
you saw describe a situation you are not in.

`PIPE=denied(exit5)` has two possible causes and `doctor` cannot separate them: the sandbox blocked the named
pipe, or this process cannot read mihari's control token under `DATA`. Re-run outside the sandbox to tell them
apart.

## 2. Capability → what to change

| `doctor` says | what it means for this skill | what to change |
|---|---|---|
| `PIPE=ok` | the host lets a process open `\\.\pipe\mihari-control` | nothing; `on` / `off` / `ensure-tui` work as written |
| `PIPE=denied(exit5)` | the sandbox blocks the pipe (the normal DSH case) | keep the `NEED_ESCALATION=1` half of "Escalation discipline", and make sure your harness has a way to retry one command with wider access |
| `LANGMODE=ConstrainedLanguage` | a restricted interpreter runs your script | keep the script's CLM-safe style (`@()` + `+=`, `Get-Content -Raw`, no `[System.IO.File]::*`); if your harness has no such restriction, this section can be dropped |
| `LANGMODE=FullLanguage`, `PIPE=ok` | none of the sandbox machinery applies | delete the whole "Escalation discipline" section from `SKILL.md` — it is noise on a harness with no sandbox |
| `PORTS=… source=config_file` | ports resolved from `mihari.yaml` | nothing |
| `PORTS=… source=fallback_…` | ports are built-in guesses | fix the config path or the missing keys before trusting anything port-related |
| `MIHARI=missing` | the binary is not where the script looks | point `MIHARI_EXE` at it, or edit `Resolve-MihariExe` |
| `SHELL=powershell/5.1` | Windows PowerShell | keep as written. PowerShell 7 is also fine |
| `LOG=missing` | `trace` will have no `EVIDENCE` | check `DATA` — it is probably the wrong data root |

## 3. What is DSH-specific and must be replaced elsewhere

Four things in this skill are **not** properties of mihari; they are properties of the harness it was written on.
On another harness, translate them rather than copying them.

1. **`NEED_ESCALATION=1`** — a handshake this script emits when mihari's control pipe is blocked. No other
   harness detects it. Replace it with your harness's own "this command needs wider access" signal, or delete
   the mechanism if your harness has no sandbox.
2. **`sandbox_permissions: danger-full-access` / `workspace-write`** — DSH's retry-with-wider-access parameter.
   Counterparts, as documented by their vendors: GitHub Copilot CLI can run a single command outside its sandbox
   with approval; Codex has sandbox modes plus an approval policy; Cursor asks for approval when a command must
   leave its sandbox; Claude Code documents an unsandboxed retry. Match the *shape* — one retry, minimum width,
   then stop and report.
3. **PowerShell ConstrainedLanguage** — this is a Windows/WDAC feature that a read-only DSH session happens to
   trigger. No other harness researched documents restricting the interpreter, so on most of them the section
   does not apply.
4. **`NO_COLOR=1` inheritance** — DSH sets it for tool processes, so a TUI this script launches would come up
   colourless. Any harness that sets it needs the same strip-before-spawn trick; harnesses that do not can drop
   it.

Everything else — the channels, the ladder, the invariant, the boundaries — is about mihari and mihomo, and
should survive the move unchanged.

## 4. Porting to POSIX

The script is `powershell -File`, so on Linux or macOS it will not run at all. You need a second entry point
(`bash`, or a small `node`/`python` program) that speaks the same commands and the same exit codes. What it must
do is small and fully specified by this skill:

- read `mixed-addr` / `controller-addr` / `controller-secret` from the mihari settings file,
- `GET /version`, `/configs`, `/proxies`, `/rules` from the controller with a bearer token (`status`, `trace`,
  `doctor`),
- `grep` the last matching line of the mihomo log for `trace`'s `EVIDENCE`,
- shell out to the `mihari` CLI for `on` / `off` / `ensure-tui`.

Three things get **easier** on POSIX, and a porter should not carry them over:

- mihari's control channel is a **Unix domain socket**, not a Windows named pipe, so the "sandbox blocks the
  control channel" story may not apply at all — measure it rather than assuming.
- there is no PowerShell ConstrainedLanguage, so the CLM-safe style is unnecessary.
- there is no `NO_COLOR` inheritance problem from DSH's tooling.

And one thing gets harder: the system-proxy and TUN commands differ per platform, so `on` / `off` / `-Tun` must
be re-derived from `mihari <command> --help` on that machine rather than translated.

## 5. Do not change these

- **Where ports come from.** They are read from `mihari.yaml` (and the live `/configs.mixed-port`); never
  hardcode a port, in code or in documentation. A port printed in an example is a bug in the example.
- **The mutual-exclusion invariant.** System proxy and TUN must not both be on; `status` reports
  `STATE=conflict` and exits 3, and `on` refuses when TUN is already on. This is a deliberate safety property.
- **The boundaries.** The skill reports and never modifies `mihari.yaml`, subscriptions, nodes or the registry.
  A porter who "helpfully" adds node switching or config editing has broken the contract, not extended it.
- **The probe target.** `-Probe` must use a plain-HTTP target (`http://www.gstatic.com/generate_204`) with a
  fallback; measured behaviour on one node was https-timeout versus http-927 ms, i.e. https-only testing reports
  false failures.

## 6. After you change anything, check it like this

Every item is a thing you can run; none of them need mihari to be healthy.

1. `doctor` — every field says something you can explain, and no `NOTE=` contradicts how you intend to run.
2. `status` — one line, `EXIT=0`, and `MIXED=<port>:up` matches the port mihari actually uses on this machine.
3. `status -Json` — parses as JSON (this catches quoting and encoding damage).
4. `trace <a domain you know is proxied>` — `RULE=` names a rule you can find in `/rules`, and `CHAIN=` ends at a
   node you can see in `/proxies`.
5. `trace <domain> -Probe` — `PROBE=` reports something; `fail(...)` with `CORE=running` means the node, not you.
6. `env` — the four variables, with the port `status` just showed (not a port you typed).
7. `ensure-tui` — either `TUI=present:<pid>` or the documented escalation path; never a TUI that opens and cannot
   reach the daemon (check `~/.mihari/logs/mihari-tui.log` for `daemon_unavailable`).
8. `on`, then `off` — `SYS=on` then `SYS=off`, `STATE=sysproxy` then `STATE=off`, and the registry's
   `ProxyEnable` follows. If you cannot test these, say so in your README rather than claiming they work.
9. If you edited the script: it must stay pure ASCII (a Windows PowerShell 5.1 reads a BOM-less `.ps1` as ANSI and
   mangles any non-ASCII literal) and it must still parse — the cheapest check is
   `[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)`.
