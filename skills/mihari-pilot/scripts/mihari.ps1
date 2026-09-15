<#
  mihari.ps1 - agent-facing control surface for the local mihari daemon (mihomo manager).

  Usage:
    ... -File mihari.ps1 status [-Probe] [-Json]
    ... -File mihari.ps1 doctor
    ... -File mihari.ps1 trace <domain|url> [-Probe]
    ... -File mihari.ps1 env
    ... -File mihari.ps1 on  [-Tun] [-Probe]
    ... -File mihari.ps1 off [-Tun]
    ... -File mihari.ps1 ensure-tui

  Exit: 0 ok | 1 action ok but still offline | 2 environment problem | 3 needs user

  Read-only commands (status, env) never need sandbox escalation: they use mihomo's
  external-controller over plain TCP plus the WinINET registry keys.
  Write commands need the mihari control named pipe, which the DSH sandbox blocks;
  that surfaces as NEED_ESCALATION=1 and one danger-full-access retry of the same command.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = 'status',
  [Parameter(Position = 1)][string]$Target = '',
  [switch]$Tun,
  [switch]$Probe,
  [switch]$Json,
  [int]$TimeoutSec = 5
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$script:SkillVersion = '0.1.0'

$script:Warns = @()
$script:RawExit = $null

function Add-Warn([string]$m) { $script:Warns += $m }

function Write-Result([int]$code) {
  foreach ($w in $script:Warns) { Write-Output ('WARN=' + $w) }
  if ($null -ne $script:RawExit -and $script:RawExit -ne 0) { Write-Output ('MIHARI_EXIT=' + $script:RawExit) }
  Write-Output ('EXIT=' + $code)
  exit $code
}

# ---------------------------------------------------------------- paths / config
$DataRoot = $env:MIHARI_DATA
if (-not $DataRoot) { $DataRoot = Join-Path $env:USERPROFILE '.mihari' }
$Settings = Join-Path $DataRoot 'mihari.yaml'

$script:MissingSettings = @()
function Get-Setting([string]$key, [string]$fallback) {
  if (-not (Test-Path $Settings)) { return $fallback }
  try {
    $text = Get-Content -Path $Settings -Raw
    $m = [regex]::Match($text, '(?m)^\s*' + [regex]::Escape($key) + ':\s*"?([^"\r\n]*?)"?\s*$')
    if ($m.Success -and $m.Groups[1].Value.Trim()) { return $m.Groups[1].Value.Trim() }
  } catch { }
  if ($script:MissingSettings -notcontains $key) { $script:MissingSettings += $key }
  return $fallback
}

function Resolve-MihariExe {
  if ($env:MIHARI_EXE -and (Test-Path $env:MIHARI_EXE)) { return $env:MIHARI_EXE }
  $c = Get-Command 'mihari.exe' -ErrorAction SilentlyContinue
  if ($c -and $c.Source) { return $c.Source }
  $candidates = @()
  $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\mihari\mihari.exe')
  $candidates += (Join-Path $env:ProgramFiles 'Mihari\mihari.exe')
  foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
  return $null
}

# The three literals below are LAST-RESORT fallbacks, not defaults: ports are chosen per machine.
# Whenever one is actually used the script says so (WARN=settings_missing_from_config /
# mihari_config_unreadable), so a wrong guess is never silent.
$MihariExe  = Resolve-MihariExe
$Secret     = Get-Setting 'controller-secret' ''
$Controller = Get-Setting 'controller-addr' '127.0.0.1:9090'
$Mixed      = Get-Setting 'mixed-addr' '127.0.0.1:9190'
$MixedPort  = ($Mixed -split ':')[-1]
$IeKey      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$TuiLog     = Join-Path $DataRoot 'logs\mihari-tui.log'

# ------------------------------------------------------------- read-only channels
function Invoke-Controller([string]$path) {
  if (-not $Secret) { return $null }
  $url = 'http://' + $Controller + $path
  $raw = & curl.exe -s --noproxy '*' --max-time $TimeoutSec -H ('Authorization: Bearer ' + $Secret) $url 2>$null
  if (-not $raw) { return $null }
  $text = ($raw | Out-String).Trim()
  if (-not $text) { return $null }
  try { return ($text | ConvertFrom-Json) } catch { return $null }
}

function Get-RegistryProxy {
  $r = @{ Enabled = $false; Server = ''; Foreign = $false }
  try {
    $p = Get-ItemProperty -Path $IeKey -ErrorAction Stop
    if ($null -ne $p.ProxyEnable) { $r.Enabled = ([int]$p.ProxyEnable -eq 1) }
    if ($null -ne $p.ProxyServer) { $r.Server = ([string]$p.ProxyServer).Trim() }
  } catch { }
  if ($r.Enabled -and $r.Server -and ($r.Server -ne $Mixed)) { $r.Foreign = $true }
  return $r
}

function Get-MihariRoles {
  $daemon = @(); $tui = @()
  foreach ($p in @(Get-Process -Name 'mihari' -ErrorAction SilentlyContinue)) {
    $path = ''
    try { $path = [string]$p.Path } catch { $path = '' }
    $isDaemon = ($p.SessionId -eq 0)
    if (-not $isDaemon -and $path) {
      $serviceRoot = Join-Path $env:ProgramFiles 'Mihari\'
      if ($path.StartsWith($serviceRoot, [System.StringComparison]::OrdinalIgnoreCase)) { $isDaemon = $true }
    }
    if ($isDaemon) { $daemon += $p } else { $tui += $p }
  }
  return @{ Daemon = $daemon; Tui = $tui }
}

function Get-NodeChain($proxies) {
  $chain = @()
  if (-not $proxies) { return '' }
  $items = @($proxies.PSObject.Properties)
  if ($items.Count -eq 0) { return '' }
  $selectors = @($items | Where-Object { $_.Value.type -eq 'Selector' -and $_.Name -ne 'GLOBAL' })
  $entry = $null
  # \uXXXX escapes keep this file pure ASCII: PowerShell 5.1 reads a .ps1 without a
  # BOM as ANSI, which would mangle literal CJK. -match decodes them itself; -eq needs
  # an explicit Regex::Unescape.
  $primary = [regex]::Unescape('\u8282\u70B9\u9009\u62E9')
  $alias   = [regex]::Unescape('\u9009\u62E9\u8282\u70B9')
  foreach ($pref in @($primary, 'Proxy', 'PROXY', $alias)) {
    $hit = @($selectors | Where-Object { $_.Name -eq $pref })
    if ($hit.Count -gt 0) { $entry = $hit[0]; break }
  }
  if (-not $entry -and $selectors.Count -gt 0) { $entry = $selectors[0] }
  if (-not $entry) { return '' }
  $cur = $entry
  for ($i = 0; $i -lt 4 -and $cur; $i++) {
    $chain += [string]$cur.Name
    $now = [string]$cur.Value.now
    if (-not $now) { break }
    $nxt = @($items | Where-Object { $_.Name -eq $now })
    if ($nxt.Count -gt 0) { $cur = $nxt[0] } else { $chain += $now; $cur = $null }
  }
  return ($chain -join '>')
}

function Resolve-Chain($proxies, [string]$start, [int]$maxDepth = 5) {
  $chain = @()
  if (-not $proxies -or -not $start) { return $chain }
  $items = @($proxies.PSObject.Properties)
  $cur = $start
  for ($i = 0; $i -lt $maxDepth -and $cur; $i++) {
    $chain += $cur
    $hit = @($items | Where-Object { $_.Name -eq $cur })
    if ($hit.Count -eq 0) { break }
    $now = [string]$hit[0].Value.now
    if (-not $now) { break }
    if ($chain -contains $now) { break }
    $cur = $now
  }
  return $chain
}

function Test-MixedPort([string]$port) {
  # MIXED= is only the configured value; this answers "is something actually accepting there".
  # A proxy port answers a plain GET with 400, which is still proof of life.
  if (-not $port) { return $false }
  $u = 'http://' + ($Mixed -split ':')[0] + ':' + $port + '/'
  $code = (& curl.exe -s -o NUL -w '%{http_code}' --noproxy '*' --max-time 2 $u 2>$null | Out-String).Trim()
  if (-not $code -or $code -eq '000') { return $false }
  return $true
}

function Get-TraceEvidence([string]$hostName) {
  # mihomo writes two shapes for one connection, and the last line wins:
  #   ok   "[TCP] <src> --> host:443 match <Rule>[(<payload>)] using <Group>[<Node>]"
  #        (a rule with an empty payload, e.g. Match, is logged WITHOUT parentheses)
  #   fail "[TCP] dial <Group> (match <Rule>[/<payload>]) <src> --> host:443 error: <reason>"
  #        where <reason> names the exit node's own server and why it failed -- this is the
  #        fastest way to tell "the node is dead" from "the site blocked me".
  # This is the only *observed* answer available: the rules+now chain is a prediction, and
  # /connections is live-only and usually empty.
  $log = Join-Path $DataRoot 'logs\mihomo.log'
  if (-not (Test-Path $log)) { return '' }
  $hits = @(Select-String -Path $log -SimpleMatch -Pattern $hostName -ErrorAction SilentlyContinue)
  if ($hits.Count -eq 0) { return '' }
  $last = $hits[$hits.Count - 1].Line
  $ts = ''
  if ($last -match '"time":"([^"]+)"') { $ts = $Matches[1] }
  if ($last -match 'dial ([^ ]+) \(match ([^)]*)\) .+? error: (.+?)\\?"') {
    $reason = $Matches[3].TrimEnd('\', '"')
    return ('fail ' + $ts + '  dial ' + $Matches[1] + ' (match ' + $Matches[2] + ') error: ' + $reason)
  }
  if ($last -match 'match ([A-Za-z]+)(\(([^)]*)\))? using ([^\[]+)\[([^\]]+)\]') {
    $pl = ''
    if ($Matches[3]) { $pl = '(' + $Matches[3] + ')' }
    return ('ok ' + $ts + '  ' + $Matches[1] + $pl + ' using ' + $Matches[4] + '[' + $Matches[5] + ']')
  }
  return ''
}

function Get-State {
  $st = @{
    Reg = Get-RegistryProxy; TunLive = $false; Mode = ''; MixedPort = $MixedPort
    CoreUp = $false; CoreVersion = ''; NodeChain = ''; PortUp = $false
  }
  $v = Invoke-Controller '/version'
  if ($v) {
    $st.CoreUp = $true
    if ($v.version) { $st.CoreVersion = [string]$v.version }
  }
  $c = Invoke-Controller '/configs'
  if ($c) {
    if ($null -ne $c.tun) { $st.TunLive = [bool]$c.tun.enable }
    if ($c.mode) { $st.Mode = [string]$c.mode }
    if ($c.'mixed-port') { $st.MixedPort = [string]$c.'mixed-port' }
    # Settings file and running core can disagree right after a port change that has not
    # been applied yet; for the address and for ownership, the live value wins.
    if ($st.MixedPort -and ($st.MixedPort -ne $MixedPort)) {
      $liveAddr = ($Mixed -split ':')[0] + ':' + $st.MixedPort
      if ($st.Reg.Enabled -and $st.Reg.Server -and ($st.Reg.Server -ne $liveAddr)) { $st.Reg.Foreign = $true }
      else { $st.Reg.Foreign = $false }
    }
  }
  $px = Invoke-Controller '/proxies'
  if ($px -and $px.proxies) { $st.NodeChain = Get-NodeChain $px.proxies }; $st.PortUp = Test-MixedPort $st.MixedPort
  return $st
}

function Get-ProbeNode($st) {
  if (-not $st.NodeChain -or $st.NodeChain -eq 'unknown') { return '' }
  return ($st.NodeChain -split '>')[-1]
}

function Invoke-Probe([string]$node) {
  # The probe deliberately runs *inside* mihomo (its own delay test) instead of as a TLS
  # request from this process: a restricted sandbox denies Windows Schannel credentials
  # (SEC_E_NO_CREDENTIALS), so curl/Invoke-WebRequest cannot complete any https:// request
  # there and would report a false "network down". mihomo lives outside the sandbox.
  if (-not $node) { return @{ Ok = $false; Ms = 0; Code = 'no_node' } }
  # Clash's canonical test URL is *plain http*. Measured on this machine: one node returned
  # Timeout for https://www.gstatic.com/generate_204 while http://www.gstatic.com/generate_204
  # answered in 927ms -- an https-only target reports a false failure. The second target
  # guards against any single endpoint being blocked.
  $last = 'delay_failed'
  foreach ($u in @('http://www.gstatic.com/generate_204', 'https://www.cloudflare.com/cdn-cgi/trace')) {
    $path = '/proxies/' + [uri]::EscapeDataString($node) + '/delay?timeout=6000&url=' + [uri]::EscapeDataString($u)
    $raw = & curl.exe -s --noproxy '*' --max-time 12 -H ('Authorization: Bearer ' + $Secret) ('http://' + $Controller + $path) 2>$null
    if (-not $raw) { return @{ Ok = $false; Ms = 0; Code = 'controller_unreachable' } }
    $json = $null
    try { $json = (($raw | Out-String).Trim() | ConvertFrom-Json) } catch { return @{ Ok = $false; Ms = 0; Code = 'unparsable' } }
    if ($null -ne $json.delay -and ([int]$json.delay -gt 0)) { return @{ Ok = $true; Ms = [int]$json.delay; Code = 'delay' } }
    if ($json.message) { $last = [string]$json.message }
  }
  return @{ Ok = $false; Ms = 0; Code = $last }
}

# ------------------------------------------------------------- writing channel
function Invoke-Mihari([string[]]$MihariArgs) {
  if (-not $MihariExe) { return @{ Code = 127; Text = ''; Json = $null } }
  $out = & $MihariExe @MihariArgs 2>&1
  $code = $LASTEXITCODE
  $text = (($out | ForEach-Object { "$_" }) -join "`n")
  $json = $null
  $m = [regex]::Match($text, '(?s)\{.*\}')
  if ($m.Success) { try { $json = $m.Value | ConvertFrom-Json } catch { } }
  $script:RawExit = $code
  return @{ Code = $code; Text = $text; Json = $json }
}

function Get-MihariErrorCode($res) {
  if ($res.Json -and $res.Json.error -and $res.Json.error.code) { return [string]$res.Json.error.code }
  return ''
}

function Test-EscalationNeeded($res) {
  if ($res.Code -eq 127) { return $false }
  if ($res.Code -eq 5) { return $true }
  if ((Get-MihariErrorCode $res) -eq 'permission_denied') { return $true }
  if ($res.Text -match 'permission_denied') { return $true }
  return $false
}

function Invoke-Write($res) {
  if (Test-EscalationNeeded $res) { return @{ Code = 2; Escalate = $true; Msg = 'control_pipe_blocked_by_sandbox' } }
  if ($res.Code -eq 0) { return @{ Code = 0; Msg = '' } }
  $ec = Get-MihariErrorCode $res
  if ($res.Code -eq 3) { return @{ Code = 2; Msg = 'daemon_unavailable' } }
  if ($res.Code -eq 2 -or $res.Code -eq 6) {
    if ($ec) { return @{ Code = 3; Msg = $ec } }
    return @{ Code = 3; Msg = 'mihari_rejected' }
  }
  if ($ec) { return @{ Code = 2; Msg = 'mihari_' + $res.Code + ':' + $ec } }
  return @{ Code = 2; Msg = 'mihari_exit_' + $res.Code }
}

function Wait-TunLive([bool]$want, [int]$seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    $c = Invoke-Controller '/configs'
    if ($c -and ($null -ne $c.tun)) {
      if ([bool]$c.tun.enable -eq $want) { return $true }
    }
    Start-Sleep -Milliseconds 400
  }
  return $false
}

function Ensure-Tui([switch]$Preflight) {
  $roles = Get-MihariRoles
  if ($roles.Tui.Count -gt 0) { return @{ State = 'present:' + $roles.Tui[0].Id; Code = 0 } }
  if (-not $MihariExe) { return @{ State = 'failed:no_binary'; Code = 2 } }
  if ($Preflight) {
    $check = Invoke-Mihari @('status', '--json')
    if (Test-EscalationNeeded $check) { return @{ State = 'blocked'; Code = 2; Escalate = $true } }
    if ($check.Code -ne 0) { return @{ State = 'failed:daemon_unavailable'; Code = 2 } }
  }
  # The harness runs tools with NO_COLOR=1 so its own output stays plain; a child would
  # inherit it and the TUI would come up colourless. Strip it for the spawn only and put it
  # back afterwards (Start-Process -UseNewEnvironment is denied inside the sandbox).
  $savedNoColor = $env:NO_COLOR
  if ($savedNoColor) { Remove-Item Env:\NO_COLOR -ErrorAction SilentlyContinue }
  try {
    Start-Process -FilePath $MihariExe -ErrorAction Stop | Out-Null
  } catch {
    if ($savedNoColor) { $env:NO_COLOR = $savedNoColor }
    return @{ State = 'failed:spawn'; Code = 2 }
  }
  if ($savedNoColor) { $env:NO_COLOR = $savedNoColor }
  $newPid = $null
  $deadline = (Get-Date).AddSeconds(8)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    $roles = Get-MihariRoles
    if ($roles.Tui.Count -gt 0) { $newPid = $roles.Tui[0].Id; break }
  }
  if (-not $newPid) { return @{ State = 'failed:no_process'; Code = 2 } }
  Start-Sleep -Milliseconds 700
  if (Test-Path $TuiLog) {
    $tail = @(Get-Content -Path $TuiLog -Tail 4 -ErrorAction SilentlyContinue)
    $lastStart = -1
    for ($i = 0; $i -lt $tail.Count; $i++) { if ($tail[$i] -match 'tui started') { $lastStart = $i } }
    if ($lastStart -ge 0) {
      for ($i = $lastStart + 1; $i -lt $tail.Count; $i++) {
        if ($tail[$i] -match 'daemon_unavailable') { return @{ State = 'broken:' + $newPid; Code = 2 } }
      }
    }
  }
  return @{ State = 'present:' + $newPid; Code = 0 }
}

# ------------------------------------------------------------- state line
function Get-StateLine($st, $roles, [string]$probe) {
  $sys = 'off'
  if ($st.Reg.Enabled) {
    if ($st.Reg.Foreign) { $sys = 'on(foreign:' + $st.Reg.Server + ')' } else { $sys = 'on' }
  }
  $tunText = 'off'
  if ($st.TunLive) { $tunText = 'on' }
  $state = 'off'
  if ($st.Reg.Enabled -and $st.TunLive) { $state = 'conflict' }
  elseif ($st.TunLive) { $state = 'tun' }
  elseif ($st.Reg.Enabled) { $state = 'sysproxy' }
  $core = 'unknown'
  if ($st.CoreUp) { $core = 'running'; if ($st.CoreVersion) { $core = 'running/' + $st.CoreVersion } } elseif ($Secret) { $core = 'down' }
  $daemon = 'stopped'
  if ($roles.Daemon.Count -gt 0) { $daemon = 'running' }
  else {
    $svc = Get-Service -Name 'mihari' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { $daemon = 'running' }
  }
  $tui = 'absent'
  if ($roles.Tui.Count -gt 0) { $tui = 'present:' + $roles.Tui[0].Id }
  $envs = 'unset'
  if ($env:HTTP_PROXY -or $env:HTTPS_PROXY -or $env:ALL_PROXY) { $envs = 'set' }
  if (-not $st.NodeChain) { $st.NodeChain = 'unknown' }
  if (-not $st.Mode) { $st.Mode = 'unknown' }
  $portTxt = 'down'
  if ($st.PortUp) { $portTxt = 'up' }
  return ('STATE=' + $state + ' SYS=' + $sys + ' TUN=' + $tunText + ' CORE=' + $core + ' DAEMON=' + $daemon +
          ' NODE=' + $st.NodeChain + ' MODE=' + $st.Mode + ' MIXED=' + $st.MixedPort + ':' + $portTxt +
          ' TUI=' + $tui + ' ENV=' + $envs + ' PROBE=' + $probe)
}

function Add-StateWarnings($st, $roles) {
  if ($script:MissingSettings.Count -gt 0) { Add-Warn ('settings_missing_from_config:' + ($script:MissingSettings -join ',')) }
  if (-not $MihariExe) { Add-Warn 'mihari_not_found' }
  if ($roles.Daemon.Count -eq 0) {
    $svc = Get-Service -Name 'mihari' -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') { Add-Warn 'daemon_stopped' }
  }
  if (-not $st.CoreUp) { if ($Secret) { Add-Warn 'core_down' } else { Add-Warn 'mihari_config_unreadable' } }
  if ($st.CoreUp -and $st.MixedPort -and ($st.MixedPort -ne $MixedPort)) {
    Add-Warn ('mixed_port_drift:yaml=' + $MixedPort + ',live=' + $st.MixedPort)
  }
  if ($st.Reg.Enabled -and $st.TunLive) { Add-Warn 'sysproxy_and_tun_both_on' }
  if ($st.Reg.Foreign) { Add-Warn ('foreign_sysproxy:' + $st.Reg.Server) }
  if ($st.NodeChain -and $st.NodeChain -ne 'unknown') {
    $tail = ($st.NodeChain -split '>')[-1]
    if ($tail -match '\u5269\u4F59\u6D41\u91CF|\u5230\u671F|\u8FC7\u671F|\u91CD\u7F6E|\u5B98\u7F51|\u8BA2\u9605|\u6D41\u91CF|\d+(\.\d+)?\s*(GB|MB|TB)|expire|traffic') {
      Add-Warn ('suspicious_node:' + $tail)
    }
  }
}

# ------------------------------------------------------------- commands
$cmd = $Command.ToLower()

if ($cmd -eq 'status') {
  $roles = Get-MihariRoles
  $st = Get-State
  $probeText = 'skip'
  $probeFailed = $false
  if ($Probe) {
    $p = Invoke-Probe (Get-ProbeNode $st)
    if ($p.Ok) { $probeText = 'ok(' + $p.Ms + 'ms)' } else { $probeText = 'fail(' + $p.Code + ')'; $probeFailed = $true }
  }
  Add-StateWarnings $st $roles
  if ($Json) {
    $obj = @{
      state       = ((Get-StateLine $st $roles $probeText) -split ' ')[0].Split('=')[1]
      sysproxy    = $st.Reg
      tun_live    = $st.TunLive
      core_up     = $st.CoreUp
      core_version = $st.CoreVersion
      mode        = $st.Mode
      mixed_port  = $st.MixedPort
      node_chain  = $st.NodeChain
      probe       = $probeText
      warns       = @($script:Warns)
    }
    Write-Output ($obj | ConvertTo-Json -Depth 5 -Compress)
  } else {
    Write-Output (Get-StateLine $st $roles $probeText)
  }
  $code = 0
  if ($probeFailed) { $code = 1 }; if (-not $Secret) { $code = 2 }
  if ($st.Reg.Enabled -and $st.TunLive) { $code = 3 }
  Write-Result $code
}

if ($cmd -eq 'doctor') {
  # Capability probe for this machine AND this sandbox. Every field says what was actually
  # observed; anything the sandbox can distort is labelled rather than guessed. Always exits 0:
  # this is a report, not a state query.
  $psv = 'unknown'
  try { $psv = [string]$PSVersionTable.PSVersion } catch { }
  Write-Output ('SKILL=mihari-pilot/' + $script:SkillVersion)
  Write-Output ('SHELL=powershell/' + $psv)
  $lm = 'unknown'
  try { $lm = [string]$ExecutionContext.SessionState.LanguageMode } catch { }
  Write-Output ('LANGMODE=' + $lm)
  $exe = 'missing'
  if ($MihariExe) { $exe = $MihariExe }
  Write-Output ('MIHARI=' + $exe)
  $cfg = 'missing'
  if (Test-Path $Settings) { $cfg = 'present' }
  Write-Output ('CONFIG=' + $cfg)
  Write-Output ('DATA=' + $DataRoot)
  $portSrc = 'config_file'
  if (-not (Test-Path $Settings)) { $portSrc = 'fallback_no_config' }
  elseif ($script:MissingSettings.Count -gt 0) { $portSrc = 'fallback_missing_keys:' + ($script:MissingSettings -join ',') }
  $st = Get-State
  Write-Output ('PORTS=mixed=' + $st.MixedPort + ' controller=' + $Controller + ' source=' + $portSrc)
  $ctrl = 'unreachable'
  if ($st.CoreUp) { $ctrl = 'ok' }
  Write-Output ('CONTROLLER=' + $ctrl)
  $core = 'unknown'
  if ($st.CoreUp) { $core = 'running/' + $st.CoreVersion }
  elseif ($Secret) { $core = 'down' }
  Write-Output ('CORE=' + $core)
  $reg = 'unreadable'
  try { $null = Get-ItemProperty -Path $IeKey -ErrorAction Stop; $reg = 'ok' } catch { }
  Write-Output ('REGISTRY=' + $reg + ' proxy_enable=' + $st.Reg.Enabled)
  Write-Output ('MIXEDPORT_REACHABLE=' + $st.PortUp)
  $pipe = 'untested'
  $res = Invoke-Mihari @('status', '--json')
  if ($res.Code -eq 127) { $pipe = 'no_binary' }
  elseif (Test-EscalationNeeded $res) { $pipe = 'denied(exit5)' }
  elseif ($res.Code -eq 0) { $pipe = 'ok' }
  elseif ($res.Code -eq 3) { $pipe = 'daemon_unavailable' }
  else { $pipe = 'error(' + $res.Code + ')' }
  Write-Output ('PIPE=' + $pipe)
  $roles = Get-MihariRoles
  $tui = 'absent'
  if ($roles.Tui.Count -gt 0) { $tui = 'present:' + $roles.Tui[0].Id }
  Write-Output ('TUI=' + $tui)
  $lg = 'missing'
  if (Test-Path (Join-Path $DataRoot 'logs\mihomo.log')) { $lg = 'present' }
  Write-Output ('LOG=' + $lg)
  if ($pipe -ne 'ok') {
    Write-Output 'NOTE=PIPE denied: either the sandbox blocks the named pipe, or this process cannot read the control token under DATA; re-run doctor under the sandbox you actually use'
  }
  if ($lm -ne 'FullLanguage') {
    Write-Output ('NOTE=LANGMODE is ' + $lm + '; the read-only commands are written to work there, but if the script cannot even start it needs one retry with wider access')
  }
  if ($portSrc -ne 'config_file') {
    Write-Output 'NOTE=PORTS came from a built-in fallback, not from mihari.yaml; treat those numbers as guesses until CONFIG=present and the keys exist'
  }
  Write-Result 0
}
if ($cmd -eq 'trace') {
  if (-not $Target) {
    Write-Output 'ERROR=trace_needs_a_domain'
    Write-Output 'USAGE=trace <domain|url> [-Probe]'
    Write-Result 2
  }
  $hostName = $Target.ToLower()
  if ($hostName -match '^[a-z][a-z0-9+.-]*://') { $hostName = ($hostName -replace '^[a-z][a-z0-9+.-]*://', '') }
  $hostName = ($hostName -split '/')[0]
  $hostName = ($hostName -split ':')[0]
  $hostName = $hostName.Trim('.')
  $rules = Invoke-Controller '/rules'
  $px = Invoke-Controller '/proxies'
  if (-not $rules -or -not $px) {
    if (-not $Secret) { Add-Warn 'mihari_config_unreadable' }
    Add-Warn 'controller_unreachable'
    Write-Output ('TRACE=' + $hostName + ' RULE=unknown CHAIN=unknown NODE=unknown CONFIDENCE=none')
    Write-Result 2
  }
  # mihomo evaluates rules in list order. A type we cannot evaluate from a bare domain name
  # (IP / process / port / geosite / ruleset) may well match first, so the prediction below is
  # only exact when nothing undecidable precedes the matched rule.
  $undecidable = @('GEOSITE', 'GEOIP', 'IPCIDR', 'SRCIPCIDR', 'SRCGEOIP', 'IPSUFFIX', 'SRCIPSUFFIX', 'DSTPORT', 'SRCPORT', 'PROCESSNAME', 'PROCESSPATH', 'RULESET', 'NETWORK')
  $picked = $null
  $blocker = ''
  foreach ($rule in @($rules.rules)) {
    $t = [string]$rule.type
    $pl = ([string]$rule.payload).ToLower()
    $isMatch = $false
    if ($t -eq 'Domain') { if ($hostName -eq $pl) { $isMatch = $true } }
    elseif ($t -eq 'DomainSuffix') { if ($hostName -eq $pl -or $hostName.EndsWith('.' + $pl)) { $isMatch = $true } }
    elseif ($t -eq 'DomainKeyword') { if ($pl -and $hostName.Contains($pl)) { $isMatch = $true } }
    elseif ($t -eq 'DomainRegex') { if ($hostName -match $pl) { $isMatch = $true } }
    elseif ($t -eq 'Match') { $isMatch = $true }
    elseif ($undecidable -contains $t.ToUpper()) { if (-not $blocker) { $blocker = $t + '#' + [string]$rule.index }; continue }
    else { if (-not $blocker) { $blocker = $t + '#' + [string]$rule.index }; continue }
    if ($isMatch) { $picked = $rule; break }
  }
  $ruleTxt = 'none_matched'
  $chain = @()
  if ($picked) {
    if ([string]$picked.payload) { $ruleTxt = [string]$picked.type + '(' + [string]$picked.payload + ')->' + [string]$picked.proxy }
    else { $ruleTxt = [string]$picked.type + '->' + [string]$picked.proxy }
    $chain = Resolve-Chain $px.proxies ([string]$picked.proxy)
    if ($chain.Count -eq 0) { $chain = @([string]$picked.proxy) }
  }
  $chainTxt = 'unknown'
  if ($chain.Count -gt 0) { $chainTxt = ($chain -join '>') }
  $nodeTxt = 'unknown'
  if ($chain.Count -gt 0) { $nodeTxt = $chain[$chain.Count - 1] }
  $conf = 'exact'
  if ($blocker) { $conf = 'approx'; Add-Warn ('rule_order_preceded_by_undecidable:' + $blocker) }
  # Domain rules say nothing about a bare IP: the real match would come from IPCIDR/GEOIP rules,
  # which this script deliberately does not evaluate. Never present a prediction here.
  if ($hostName -match '^[0-9]{1,3}(\.[0-9]{1,3}){3}$') {
    $conf = 'none'
    Add-Warn 'trace_target_is_ip_ip_rules_not_evaluated'
  }
  if ($nodeTxt -match '\u5269\u4F59\u6D41\u91CF|\u5230\u671F|\u8FC7\u671F|\u91CD\u7F6E|\u5B98\u7F51|\u8BA2\u9605|\u6D41\u91CF|\d+(\.\d+)?\s*(GB|MB|TB)|expire|traffic') {
    Add-Warn ('suspicious_node:' + $nodeTxt)
  }
  Write-Output ('TRACE=' + $hostName + ' RULE=' + $ruleTxt + ' CHAIN=' + $chainTxt + ' NODE=' + $nodeTxt + ' CONFIDENCE=' + $conf)
  if ($Probe) {
    $pr = Invoke-Probe $nodeTxt
    if ($pr.Ok) { Write-Output ('PROBE=ok(' + $pr.Ms + 'ms)') } else { Write-Output ('PROBE=fail(' + $pr.Code + ')') }
  }
  $ev = Get-TraceEvidence $hostName
  if ($ev) { Write-Output ('EVIDENCE=' + $ev) } else { Write-Output 'EVIDENCE=none_no_recent_connection_in_log' }
  Write-Result 0
}

if ($cmd -eq 'env') {
  $st = Get-State
  if (-not $st.CoreUp) { if ($Secret) { Add-Warn 'core_down' } else { Add-Warn 'mihari_config_unreadable' } }
  # the live mixed-port wins over the settings file, so a stale config never hands out a dead port
  $addr = ($Mixed -split ':')[0] + ':' + $st.MixedPort
  Write-Output ('HTTP_PROXY=http://' + $addr)
  Write-Output ('HTTPS_PROXY=http://' + $addr)
  Write-Output ('ALL_PROXY=socks5h://' + $addr)
  Write-Output 'NO_PROXY=localhost,127.0.0.1,::1'
  Write-Result 0
}

if ($cmd -eq 'ensure-tui') {
  $r = Ensure-Tui -Preflight
  Write-Output ('TUI=' + $r.State)
  if ($r.Escalate) { Write-Output 'NEED_ESCALATION=1' }
  if ($r.Code -ne 0 -and -not $r.Escalate) { Add-Warn ('tui_' + $r.State) }
  Write-Result $r.Code
}

if ($cmd -eq 'on' -or $cmd -eq 'off') {
  $roles = Get-MihariRoles
  $st = Get-State
  $exitCode = 0

  if ($cmd -eq 'on') {
    if ($Tun) {
      if ($st.TunLive -and $st.Reg.Enabled) {
        Add-Warn 'sysproxy_and_tun_both_on'
        Write-Output (Get-StateLine $st $roles 'skip')
        Write-Result 3
      }
      if (-not $st.TunLive) {
        $disabledSys = $false
        if ($st.Reg.Enabled -and $st.Reg.Foreign) {
          Add-Warn ('foreign_sysproxy:' + $st.Reg.Server)
          Add-Warn 'foreign_sysproxy_blocks_tun'
          Write-Output (Get-StateLine $st $roles 'skip')
          Write-Result 3
        }
        if ($st.Reg.Enabled) {
          $r1 = Invoke-Write (Invoke-Mihari @('sysproxy', 'disable', '--json'))
          if ($r1.Code -ne 0) {
            Add-StateWarnings $st $roles
            if ($r1.Escalate) { Write-Output 'NEED_ESCALATION=1' }
            Add-Warn ('sysproxy_pre_off_failed:' + $r1.Msg)
            Write-Output (Get-StateLine $st $roles 'skip')
            Write-Result $r1.Code
          }
          $disabledSys = $true
        }
        $r2 = Invoke-Write (Invoke-Mihari @('tun', 'enable', '--json'))
        if ($r2.Code -ne 0) {
          if ($disabledSys) { [void](Invoke-Mihari @('sysproxy', 'enable', '--json')) }
          Add-StateWarnings $st $roles
          if ($r2.Escalate) { Write-Output 'NEED_ESCALATION=1' }
          Add-Warn ('tun_enable_failed:' + $r2.Msg)
          Write-Output (Get-StateLine $st $roles 'skip')
          Write-Result $r2.Code
        }
        [void](Wait-TunLive $true 5)
      }
    } else {
      if ($st.TunLive) {
        Add-Warn 'tun_on_blocks_sysproxy'
        Write-Output (Get-StateLine $st $roles 'skip')
        Write-Result 3
      }
      if (-not $st.Reg.Enabled) {
        $r = Invoke-Write (Invoke-Mihari @('sysproxy', 'enable', '--json'))
        if ($r.Code -ne 0) {
          Add-StateWarnings $st $roles
          if ($r.Escalate) { Write-Output 'NEED_ESCALATION=1' }
          Add-Warn ('sysproxy_enable_failed:' + $r.Msg)
          Write-Output (Get-StateLine $st $roles 'skip')
          Write-Result $r.Code
        }
      }
    }
  }

  if ($cmd -eq 'off') {
    $scopeSys = (-not $Tun)
    if ($scopeSys -and $st.Reg.Enabled) {
      $r = Invoke-Write (Invoke-Mihari @('sysproxy', 'disable', '--json'))
      if ($r.Code -ne 0) {
        Add-StateWarnings $st $roles
        if ($r.Escalate) { Write-Output 'NEED_ESCALATION=1' }
        Add-Warn ('sysproxy_disable_failed:' + $r.Msg)
        Write-Output (Get-StateLine $st $roles 'skip')
        Write-Result $r.Code
      }
    }
    if ($st.TunLive) {
      $r = Invoke-Write (Invoke-Mihari @('tun', 'disable', '--json'))
      if ($r.Code -ne 0) {
        Add-StateWarnings $st $roles
        if ($r.Escalate) { Write-Output 'NEED_ESCALATION=1' }
        Add-Warn ('tun_disable_failed:' + $r.Msg)
        Write-Output (Get-StateLine $st $roles 'skip')
        Write-Result $r.Code
      }
      [void](Wait-TunLive $false 5)
    }
  }

  # reflect the new state, then keep the TUI available for the user
  $roles = Get-MihariRoles
  $st = Get-State
  $probeText = 'skip'
  if ($Probe) {
    $p = Invoke-Probe (Get-ProbeNode $st)
    if ($p.Ok) { $probeText = 'ok(' + $p.Ms + 'ms)' }
    else { $probeText = 'fail(' + $p.Code + ')'; $exitCode = 1 }
  }
  $tui = Ensure-Tui -Preflight
  if ($tui.Code -ne 0) { Add-Warn ('tui_' + $tui.State) }
  $roles = Get-MihariRoles   # Ensure-Tui may have just opened the TUI; report what exists now
  Add-StateWarnings $st $roles
  Write-Output (Get-StateLine $st $roles $probeText)
  Write-Result $exitCode
}

Write-Output ('ERROR=unknown_command:' + $Command)
Write-Output 'USAGE=status|doctor|trace <domain>|env|on|off|ensure-tui [-Tun] [-Probe] [-Json]'
Write-Result 2
