# CodeMi Helper for Windows.
#
# Keeps a WebSocket open to the CodeMi relay so the CodeMi iPhone app can check Kimi Code's
# Remote Control and turn it back on while Remote Control itself is off. It reads the Remote
# Control status, Kimi Code's version and whether Kimi Code has downloaded an update, turns
# Remote Control on (opening Kimi Code first if it was quit), when asked runs the update installer
# Kimi Code downloaded itself (the way Kimi Code does when it quits), or removes itself when
# asked. It never runs any other command.
#
# Written for Windows PowerShell 5.1 (built into Windows 10 and 11); also runs on PowerShell 7.
# Config: %LOCALAPPDATA%\CodeMi Helper\config.json  {"relay": "...", "secrets": ["...", ...], "secret": "..."}
# Each pairing (one per iPhone or iPad that installed the helper, up to 8) has its own
# connection, so installing from another device never cuts off the ones already paired, and
# removing it from one device only drops that device's pairing (the last one removes the helper).
# "secret" alone is the 0.2 format, still read.

$ErrorActionPreference = 'Stop'
$HelperVersion = '0.4.2'
$HelperDir = if ($env:CODEMI_HELPER_DIR) { $env:CODEMI_HELPER_DIR } else { Join-Path $env:LOCALAPPDATA 'CodeMi Helper' }
$ConfigPath = Join-Path $HelperDir 'config.json'
$LogPath = Join-Path $HelperDir 'helper.log'
$KimiHome = Join-Path $HOME '.kimi-code'
$StatePath = Join-Path $HelperDir 'state.json'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValue = 'CodeMi Helper'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Write-Log([string]$Message) {
    try {
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) { Remove-Item $LogPath -Force }
        Add-Content -Path $LogPath -Value ("{0} {1}" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Message)
    } catch {}
}

# MARK: Kimi Code local API

function Get-KimiOrigin {
    $folder = Join-Path $KimiHome 'server\instances'
    if (-not (Test-Path $folder)) { $folder = Join-Path $KimiHome 'server/instances' }
    if (-not (Test-Path $folder)) { return $null }
    $best = $null
    foreach ($file in Get-ChildItem -Path $folder -Filter '*.json' -ErrorAction SilentlyContinue) {
        try { $info = Get-Content -Raw -Path $file.FullName | ConvertFrom-Json } catch { continue }
        if (-not (Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue)) { continue }
        if ($null -eq $best -or [double]$info.heartbeat_at -gt [double]$best.heartbeat_at) { $best = $info }
    }
    if ($null -eq $best) { return $null }
    $hostName = if ($best.host) { $best.host } else { '127.0.0.1' }
    return "http://${hostName}:$($best.port)/api/v1"
}

function Invoke-Kimi([string]$Method, [string]$Path, $Body = $null) {
    $origin = Get-KimiOrigin
    if (-not $origin) { throw 'Kimi Code is not running' }
    $token = (Get-Content -Raw -Path (Join-Path $KimiHome 'server.token')).Trim()
    $params = @{ Uri = "$origin/$Path"; Method = $Method; Headers = @{ Authorization = "Bearer $token" }; TimeoutSec = 10 }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Compress)
        $params.ContentType = 'application/json'
    }
    $reply = Invoke-RestMethod @params
    if ($reply.code -ne 0) { throw "Kimi Code API error $($reply.code): $($reply.msg)" }
    return $reply.data
}

function Get-KimiStatus {
    $status = [ordered]@{ running = $false; computerName = $env:COMPUTERNAME }
    $app = Get-KimiApp
    if ($app) { $status.app = $app }
    if (-not (Get-KimiOrigin)) { return $status }
    $status.running = $true
    try {
        $data = Invoke-Kimi 'GET' 'remote-control'
        $status.enabled = [bool]$data.enabled
        $status.state = $data.state
        if ($data.device_id) { $status.deviceId = $data.device_id }
        if ($data.device_name) { $status.deviceName = $data.device_name }
    } catch {
        $status.error = $_.Exception.Message
    }
    return $status
}

# The Kimi plan's usage, as Kimi Code's own Plan usage screen shows it (Kimi Code asks Kimi's servers).
# Only the percentages and reset times are passed on; $null when it isn't available.
function Get-KimiUsage {
    if (-not (Get-KimiOrigin)) { return $null }
    try { $data = Invoke-Kimi 'GET' 'oauth/usage' } catch { return $null }
    if ($data.kind -ne 'ok' -or -not $data.quota.usages) { return $null }
    $out = [ordered]@{}
    foreach ($key in 'limit5h', 'limit7d', 'monthTotal') {
        $entry = $data.quota.usages.$key
        if ($null -eq $entry -or $null -eq $entry.usedRatio) { continue }
        $item = [ordered]@{ used = [double]$entry.usedRatio }
        # PowerShell 7 turns ISO timestamps into dates; send ISO 8601 (UTC) either way.
        if ($entry.resetAt -is [datetime]) { $item.resetAt = $entry.resetAt.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
        elseif ($entry.resetAt) { $item.resetAt = [string]$entry.resetAt }
        $out[$key] = $item
    }
    if ($out.Count -eq 0) { return $null }
    return $out
}

function Find-KimiExe {
    # Kimi Code registers the kimi-code:// link handler, which names its program.
    foreach ($key in 'HKCU:\Software\Classes\kimi-code\shell\open\command', 'Registry::HKEY_CLASSES_ROOT\kimi-code\shell\open\command') {
        try {
            $command = (Get-ItemProperty -Path $key -ErrorAction Stop).'(default)'
            if ($command -match '^"([^"]+\.exe)"' -and (Test-Path $Matches[1])) { return $Matches[1] }
        } catch {}
    }
    foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Kimi Code\Kimi Code.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\kimi-code\Kimi Code.exe'),
        (Join-Path $env:ProgramFiles 'Kimi Code\Kimi Code.exe')
    )) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

function Enable-RemoteControl {
    if (-not (Get-KimiOrigin)) {
        Write-Log "Kimi Code isn't running; opening it"
        $exe = Find-KimiExe
        if (-not $exe) { return @{ ok = $false; status = (Get-KimiStatus); error = 'kimi_not_found' } }
        Start-Process -FilePath $exe
        for ($i = 0; $i -lt 40 -and -not (Get-KimiOrigin); $i++) { Start-Sleep -Seconds 1 }
        if (-not (Get-KimiOrigin)) { return @{ ok = $false; status = (Get-KimiStatus); error = 'kimi_not_started' } }
        Start-Sleep -Seconds 2
    }
    $current = Get-KimiStatus
    if ($current.enabled -and $current.state -eq 'on') { return @{ ok = $true; status = $current } }
    try {
        Invoke-Kimi 'POST' 'remote-control' @{ enabled = $true } | Out-Null
    } catch {
        return @{ ok = $false; status = $current; error = $_.Exception.Message }
    }
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        $current = Get-KimiStatus
        if ($current.state -eq 'on') { return @{ ok = $true; status = $current } }
    }
    return @{ ok = $false; status = $current; error = "still_$($current.state)" }
}

# MARK: Kimi Code's version and updates

$script:Installing = $null
$script:Latest = $null
$script:LatestChecked = [DateTime]::MinValue

# What the helper remembers between runs: the auto-reconnect switch, the version seen last, the
# last version change, and the update an alert already went out for.
function Get-HelperState {
    $state = [ordered]@{ autoReconnect = $true; seenVersion = $null; updated = $null; alertedVersion = $null }
    try {
        $saved = Get-Content -Raw -Path $StatePath | ConvertFrom-Json
        foreach ($key in @($state.Keys)) { if ($null -ne $saved.$key) { $state[$key] = $saved.$key } }
    } catch {}
    return $state
}
function Save-HelperState($State) {
    try { [IO.File]::WriteAllText($StatePath, ($State | ConvertTo-Json -Compress -Depth 4)) } catch {}
}

function Get-KimiVersion {
    $exe = Find-KimiExe
    if (-not $exe) { return $null }
    $v = (Get-Item $exe).VersionInfo.ProductVersion
    if (-not $v) { return $null }
    $parts = @($v.Trim() -split '\.' | Select-Object -First 3)
    return ($parts -join '.')
}

# Kimi Code's update feed (from its own app-update.yml), e.g. https://code.kimi.com/kimi-code/desktop/
function Get-KimiFeed {
    $exe = Find-KimiExe
    if (-not $exe) { return $null }
    $yml = Join-Path (Split-Path $exe) 'resources\app-update.yml'
    if (-not (Test-Path $yml)) { return $null }
    foreach ($line in Get-Content -Path $yml) {
        if ($line -match '^url:\s*(\S+)') { $u = $Matches[1]; if (-not $u.EndsWith('/')) { $u += '/' }; return $u }
    }
    return $null
}

# The update Kimi Code downloaded and installs when it quits: @{ version; path }
function Get-KimiDownload {
    $info = Join-Path $env:LOCALAPPDATA 'kimi-code-app-updater\pending\update-info.json'
    if (-not (Test-Path $info)) { return $null }
    try { $json = Get-Content -Raw -Path $info | ConvertFrom-Json } catch { return $null }
    $path = Join-Path (Split-Path $info) ([string]$json.fileName)
    if (-not $json.fileName -or -not (Test-Path $path)) { return $null }
    if ([string]$json.fileName -notmatch '([0-9]+(\.[0-9]+)+)') { return $null }
    return @{ version = $Matches[1]; path = $path }
}

function Test-Newer([string]$A, [string]$B) {
    if (-not $A -or -not $B) { return $false }
    $x = @($A -split '\.' | ForEach-Object { [int]$_ }); $y = @($B -split '\.' | ForEach-Object { [int]$_ })
    for ($i = 0; $i -lt [Math]::Max($x.Count, $y.Count); $i++) {
        $p = 0; $q = 0
        if ($i -lt $x.Count) { $p = $x[$i] }
        if ($i -lt $y.Count) { $q = $y[$i] }
        if ($p -ne $q) { return ($p -gt $q) }
    }
    return $false
}

# Checks Kimi's update feed (at most every 30 minutes).
function Update-KimiFeed {
    if (((Get-Date) - $script:LatestChecked).TotalMinutes -lt 30) { return }
    $script:LatestChecked = Get-Date
    $feed = Get-KimiFeed
    if (-not $feed) { return }
    try {
        $text = (Invoke-WebRequest -Uri ($feed + 'latest.yml') -UseBasicParsing -TimeoutSec 15).Content
        if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
        if ($text -match '(?m)^version:\s*''?([0-9.]+)') { $script:Latest = $Matches[1] }
    } catch {}
}

function Get-KimiApp {
    $version = Get-KimiVersion
    if (-not $version) { return $null }
    $state = Get-HelperState
    $download = Get-KimiDownload
    $ready = $null
    if ($download -and (Test-Newer $download.version $version)) { $ready = $download.version }
    $latest = $ready
    if (Test-Newer $script:Latest $version) { $latest = $script:Latest }
    $app = [ordered]@{ version = $version; autoReconnect = [bool]$state.autoReconnect }
    if ($latest) { $app.latest = $latest }
    if ($ready) { $app.ready = $ready }
    if ($script:Installing) { $app.installing = $script:Installing }
    if ($state.updated) { $app.updated = $state.updated }
    $feed = Get-KimiFeed
    if ($feed) { $app.notes = $feed + 'binaries/' }
    return $app
}

function Get-KimiProcesses {
    $exe = Find-KimiExe
    if (-not $exe) { return @() }
    $dir = Split-Path $exe
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) })
}

# Whether any Kimi Code session is in the middle of a turn.
function Test-KimiBusy {
    try { $data = Invoke-Kimi 'GET' 'sessions?limit=50' } catch { return $false }
    foreach ($item in @($data.items)) { if ($item.busy -eq $true) { return $true } }
    return $false
}

# $null if Install Now can go ahead, or why not.
function Get-InstallProblem {
    if ($script:Installing) { return 'already_installing' }
    $version = Get-KimiVersion
    if (-not $version) { return 'kimi_not_installed' }
    $download = Get-KimiDownload
    if (-not $download -or -not (Test-Newer $download.version $version)) { return 'no_update' }
    $signature = Get-AuthenticodeSignature -FilePath $download.path
    if ($signature.Status -ne 'Valid') { return 'update_not_signed' }
    if ((Get-KimiOrigin) -and (Test-KimiBusy)) { return 'busy' }
    return $null
}

# Closes Kimi Code and runs the installer it downloaded, silently, the same way Kimi Code's own
# updater does when it quits; then opens Kimi Code again and turns Remote Control on.
function Install-KimiUpdate {
    $from = Get-KimiVersion
    $download = Get-KimiDownload
    if (-not $download) { return @{ ok = $false; error = 'no_update' } }
    $script:Installing = $download.version
    try {
        Write-Log "Installing Kimi Code $($download.version) (from $from)"
        # Kimi Code asks "Quit Kimi Code?" while Remote Control is on; turning it off first (it
        # comes back on after the update) lets it close without asking.
        if (Get-KimiOrigin) {
            try { Invoke-Kimi 'POST' 'remote-control' @{ enabled = $false } | Out-Null; Start-Sleep -Seconds 2 } catch {}
        }
        $procs = Get-KimiProcesses
        foreach ($p in $procs) { try { [void]$p.CloseMainWindow() } catch {} }
        for ($i = 0; $i -lt 10 -and (Get-KimiProcesses).Count -gt 0; $i++) { Start-Sleep -Seconds 1 }
        Get-KimiProcesses | ForEach-Object { try { Stop-Process -Id $_.Id -Force } catch {} }
        Start-Sleep -Seconds 2
        $installer = Start-Process -FilePath $download.path -ArgumentList '--updated', '/S', '--force-run' -PassThru
        $installer.WaitForExit(300000) | Out-Null
        for ($i = 0; $i -lt 120 -and (Get-KimiVersion) -ne $download.version; $i++) { Start-Sleep -Seconds 1 }
        $now = Get-KimiVersion
        if ($now -ne $from) {
            $state = Get-HelperState
            $state.updated = [ordered]@{ from = $from; to = $now; byPhone = $true }
            $state.seenVersion = $now
            Save-HelperState $state
            Write-Log "Kimi Code is now $now"
        }
        $result = Enable-RemoteControl
        if ($now -ne $download.version) { return @{ ok = $false; error = 'update_not_installed' } }
        return @{ ok = $result.ok; error = $result.error }
    } finally {
        $script:Installing = $null
    }
}

# Between requests: notices a version change Kimi Code made itself, says when a new update is
# downloaded (returns its version, once), and turns Remote Control back on when Kimi Code comes
# back after a restart or update with it off (if the switch is on and it was on before).
$script:WasOn = $false
$script:LastPid = $null
$script:WasDown = $false
$script:WaitingSince = $null

function Watch-Kimi {
    Update-KimiFeed
    $alert = $null
    $state = Get-HelperState
    $version = Get-KimiVersion
    if ($version -and $version -ne $state.seenVersion) {
        if ($state.seenVersion -and -not $script:Installing) {
            $state.updated = [ordered]@{ from = $state.seenVersion; to = $version; byPhone = $false }
            Write-Log "Kimi Code updated itself: $($state.seenVersion) -> $version"
        }
        $state.seenVersion = $version
        Save-HelperState $state
    }
    $download = Get-KimiDownload
    if ($download -and (Test-Newer $download.version $version) -and $state.alertedVersion -ne $download.version) {
        $state.alertedVersion = $download.version
        Save-HelperState $state
        Write-Log "Kimi Code $($download.version) is downloaded and ready to install"
        $alert = $download.version
    }
    if ($script:Installing) { return $alert }
    $procs = Get-KimiProcesses
    if ($procs.Count -eq 0) {
        if ($script:LastPid) { $script:WasDown = $true }
        $script:LastPid = $null
        return $alert
    }
    $origin = Get-KimiOrigin
    if (-not $origin) { return $alert }
    $currentPid = ($procs | Sort-Object StartTime | Select-Object -First 1).Id
    if ($script:LastPid -ne $currentPid) {
        if ($script:WasDown -or $script:LastPid -or $script:WasOn) { $script:WaitingSince = Get-Date } else { $script:WaitingSince = $null }
        $script:LastPid = $currentPid
        $script:WasDown = $false
    }
    $status = Get-KimiStatus
    if ($status.state -eq 'on') { $script:WasOn = $true; $script:WaitingSince = $null; return $alert }
    if (-not $script:WaitingSince) { if ($status.enabled -eq $false) { $script:WasOn = $false }; return $alert }
    if (-not $script:WasOn -or -not $state.autoReconnect) { $script:WaitingSince = $null; return $alert }
    if (((Get-Date) - $script:WaitingSince).TotalSeconds -ge 20) {
        $script:WaitingSince = $null
        Write-Log 'Kimi Code came back with Remote Control off; turning it back on'
        $result = Enable-RemoteControl
        Write-Log ("Turn on result: ok={0} error={1}" -f $result.ok, $result.error)
    }
    return $alert
}

# Drops one pairing from the config. Returns $false when it was the last one (or the config
# can't be rewritten), in which case the whole helper should go.
function Remove-Pairing([string]$Secret) {
    try {
        $current = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
        $left = New-Object System.Collections.Generic.List[string]
        foreach ($s in @($current.secrets) + @($current.secret)) {
            if ($s -and [string]$s -ne $Secret -and -not $left.Contains([string]$s)) { $left.Add([string]$s) }
        }
        if ($left.Count -eq 0) { return $false }
        $json = @{ relay = $current.relay; secret = $left[0]; secrets = $left.ToArray() } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($ConfigPath, $json)
        return $true
    } catch {
        return $false
    }
}

function Remove-Helper {
    Write-Log 'Removing the helper'
    try { Remove-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue } catch {}
    # PowerShell won't delete the folder it's working in.
    try { Set-Location -Path ([IO.Path]::GetTempPath()) } catch {}
    try { Remove-Item -Path $HelperDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    exit 0
}

# MARK: Relay connection

function Send-Message($Socket, $Object) {
    $json = $Object | ConvertTo-Json -Compress -Depth 5
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $bytes)
    $Socket.SendAsync($segment, [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
}

function Receive-Start($Socket, $Buffer) {
    $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $Buffer)
    return $Socket.ReceiveAsync($segment, [Threading.CancellationToken]::None)
}

function Handle-Message($Conn, [string]$Text) {
    $Socket = $Conn.Socket
    try { $message = $Text | ConvertFrom-Json } catch { return }
    if (-not $message.id) { return }
    switch ($message.type) {
        'status' {
            $reply = @{ type = 'status'; id = $message.id; status = (Get-KimiStatus) }
            # Plan usage only when the phone asks (CodeMi 1.2+); it's never stored anywhere.
            if ($message.usage -eq $true) {
                $usage = Get-KimiUsage
                if ($usage) { $reply.usage = $usage }
            }
            Send-Message $Socket $reply
        }
        'enable' {
            Write-Log 'Relay asked to turn Remote Control on'
            $result = Enable-RemoteControl
            Write-Log ("Turn on result: ok={0} state={1} error={2}" -f $result.ok, $result.status.state, $result.error)
            $reply = @{ type = 'result'; id = $message.id; ok = $result.ok; status = $result.status }
            if ($result.error) { $reply.error = $result.error }
            Send-Message $Socket $reply
            $script:LastSent = ($result.status | ConvertTo-Json -Compress)
        }
        'install' {
            # Install the Kimi Code update it downloaded (restarts Kimi Code). Answers right away;
            # the phone follows along in the status.
            $problem = Get-InstallProblem
            if ($problem) {
                Send-Message $Socket @{ type = 'result'; id = $message.id; ok = $false; error = $problem; status = (Get-KimiStatus) }
                return
            }
            Write-Log 'Relay asked to install the Kimi Code update'
            $script:Installing = (Get-KimiDownload).version
            Send-Message $Socket @{ type = 'result'; id = $message.id; ok = $true; status = (Get-KimiStatus) }
            $script:Installing = $null
            $result = Install-KimiUpdate
            Write-Log ("Install result: ok={0} error={1}" -f $result.ok, $result.error)
            $script:LastSent = $null
        }
        'settings' {
            $state = Get-HelperState
            if ($message.autoReconnect -is [bool]) {
                $state.autoReconnect = $message.autoReconnect
                Save-HelperState $state
                Write-Log ("Turn Remote Control back on after restarts: {0}" -f $message.autoReconnect)
            }
            Send-Message $Socket @{ type = 'result'; id = $message.id; ok = $true; status = (Get-KimiStatus) }
        }
        'uninstall' {
            Send-Message $Socket @{ type = 'result'; id = $message.id; ok = $true }
            Start-Sleep -Seconds 1
            # "all": the user chose to remove the helper from this computer for every device.
            if ($message.all -eq $true) {
                Write-Log 'A device removed the helper from this computer'
                Remove-Helper
            } elseif (Remove-Pairing $Conn.Secret) {
                Write-Log 'A device unpaired; the helper keeps running for its other devices'
                $Conn.Removed = $true
                try { $Socket.Dispose() } catch {}
                $Conn.Socket = $null
                $Conn.Pending = $null
            } else {
                Write-Log 'The last paired device removed the helper'
                Remove-Helper
            }
        }
        default {
            Send-Message $Socket @{ type = 'result'; id = $message.id; ok = $false; error = 'unsupported' }
        }
    }
}

# One connection per pairing. Each has its own socket, receive buffer and reconnect backoff.
function New-Connection([string]$Secret) {
    return [pscustomobject]@{
        Secret = $Secret; Socket = $null; Pending = $null
        Buffer = (New-Object byte[] 65536); Text = (New-Object System.Text.StringBuilder)
        Backoff = 2; RetryAt = [DateTime]::MinValue; Removed = $false
        LastHeard = [DateTime]::MinValue; NextPing = [DateTime]::MinValue
    }
}

function Open-Connection($Conn, [string]$Relay) {
    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $socket.Options.SetRequestHeader('Authorization', "Bearer $($Conn.Secret)")
    $socket.Options.SetRequestHeader('X-CodeMi-Platform', 'windows')
    $socket.Options.SetRequestHeader('X-CodeMi-Helper-Version', $HelperVersion)
    # Protocol-level keep-alive frames: free on the relay, and they keep NAT routers from
    # dropping the idle connection.
    $socket.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
    $uri = [Uri](($Relay -replace '^https://', 'wss://') + '/v1/helper')
    $socket.ConnectAsync($uri, [Threading.CancellationToken]::None).Wait()
    Write-Log 'Connected to relay'
    $Conn.Socket = $socket
    $Conn.Backoff = 2
    $Conn.LastHeard = Get-Date
    $Conn.NextPing = (Get-Date).AddSeconds($PingSeconds)
    [void]$Conn.Text.Clear()
    $status = Get-KimiStatus
    $script:LastSent = ($status | ConvertTo-Json -Compress)
    Send-Message $socket @{ type = 'hello'; status = $status }
    $Conn.Pending = Receive-Start $socket $Conn.Buffer
}

function Close-Connection($Conn, [string]$Reason) {
    try { $Conn.Socket.Dispose() } catch {}
    $Conn.Socket = $null
    $Conn.Pending = $null
    $delay = $Conn.Backoff + (Get-Random -Minimum 0 -Maximum ([int][Math]::Max(1, $Conn.Backoff / 2)))
    $Conn.Backoff = [Math]::Min($Conn.Backoff * 2, 300)
    $Conn.RetryAt = (Get-Date).AddSeconds($delay)
    Write-Log "Disconnected ($Reason); reconnecting in ${delay}s"
}

# Heartbeat: the relay answers each ping with a pong. A connection that hears nothing for
# $SilentSeconds is dead (after sleep, or a network change, Windows can keep a socket that
# looks open for hours) and is reopened.
$PingSeconds = 25
$SilentSeconds = 70

function Check-Heartbeat($Conn) {
    if (-not $Conn.Socket) { return }
    $now = Get-Date
    if (($now - $Conn.LastHeard).TotalSeconds -gt $SilentSeconds) {
        Close-Connection $Conn 'no answer from the relay'
        return
    }
    if ($now -ge $Conn.NextPing) {
        $Conn.NextPing = $now.AddSeconds($PingSeconds)
        $bytes = [Text.Encoding]::UTF8.GetBytes('{"type":"ping"}')
        $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $bytes)
        $Conn.Socket.SendAsync($segment, [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait(10000) | Out-Null
    }
}

# MARK: Main

if ($args -contains '--status') {
    Get-KimiStatus | ConvertTo-Json -Compress
    exit 0
}

# One helper at a time: the Run key and the installer could otherwise start two.
$created = $false
$mutex = New-Object System.Threading.Mutex($false, 'Local\CodeMiHelper', [ref]$created)
if (-not $mutex.WaitOne(0)) { exit 0 }

try { $config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json } catch { Write-Log "Missing or unreadable config at $ConfigPath"; exit 78 }
# Every pairing, newest first, without repeats (0.2 configs have only "secret").
$pairings = New-Object System.Collections.Generic.List[string]
foreach ($secret in @($config.secrets) + @($config.secret)) {
    if ($secret -and -not $pairings.Contains([string]$secret) -and $pairings.Count -lt 8) { $pairings.Add([string]$secret) }
}
if ($pairings.Count -eq 0) { Write-Log "No pairing in $ConfigPath"; exit 78 }
Write-Log ("CodeMi Helper {0} starting with {1} pairing(s)" -f $HelperVersion, $pairings.Count)

$connections = @($pairings | ForEach-Object { New-Connection $_ })
$nextCheck = (Get-Date).AddSeconds(20)
while ($true) {
    # Nothing here may end the helper: a failure is logged and the loop carries on.
    try {
        foreach ($conn in $connections) {
            if (-not $conn.Removed -and -not $conn.Socket -and (Get-Date) -ge $conn.RetryAt) {
                try { Open-Connection $conn $config.relay } catch { Close-Connection $conn $_.Exception.GetBaseException().Message }
            }
            try { Check-Heartbeat $conn } catch { Close-Connection $conn $_.Exception.GetBaseException().Message }
        }
        # Every 20 s: tell every pairing if Kimi Code's Remote Control state changed.
        if ((Get-Date) -ge $nextCheck) {
            $nextCheck = (Get-Date).AddSeconds(20)
            $ready = $null
            try { $ready = Watch-Kimi } catch { Write-Log "Watch failed: $($_.Exception.Message)" }
            if ($ready) {
                foreach ($conn in $connections) {
                    if ($conn.Socket) { try { Send-Message $conn.Socket @{ type = 'event'; kind = 'kimiUpdate'; version = $ready; computerName = $env:COMPUTERNAME } } catch {} }
                }
            }
            $status = Get-KimiStatus
            $json = $status | ConvertTo-Json -Compress
            if ($json -ne $script:LastSent) {
                $script:LastSent = $json
                foreach ($conn in $connections) {
                    if ($conn.Socket) { try { Send-Message $conn.Socket @{ type = 'status'; status = $status } } catch {} }
                }
            }
        }
        $open = @($connections | Where-Object { $_.Pending })
        if ($open.Count -eq 0) { Start-Sleep -Seconds 1; continue }
        $tasks = [System.Threading.Tasks.Task[]]@($open | ForEach-Object { $_.Pending })
        $index = [System.Threading.Tasks.Task]::WaitAny($tasks, 5000)
        if ($index -lt 0) { continue }
        $conn = $open[$index]
        try {
            $result = $conn.Pending.Result
        } catch {
            Close-Connection $conn $_.Exception.GetBaseException().Message
            continue
        }
        if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
            Close-Connection $conn 'closed'
            continue
        }
        $conn.LastHeard = Get-Date
        [void]$conn.Text.Append([Text.Encoding]::UTF8.GetString($conn.Buffer, 0, $result.Count))
        if ($result.EndOfMessage) {
            $message = $conn.Text.ToString()
            [void]$conn.Text.Clear()
            try { Handle-Message $conn $message } catch { Write-Log "Message failed: $($_.Exception.Message)" }
            # Turning Remote Control on (or installing an update) can take minutes; that time
            # doesn't count as silence on any connection.
            foreach ($c in $connections) { $c.LastHeard = Get-Date; $c.NextPing = Get-Date }
        }
        if ($conn.Removed) { continue }
        try { $conn.Pending = Receive-Start $conn.Socket $conn.Buffer } catch { Close-Connection $conn $_.Exception.GetBaseException().Message }
    } catch {
        Write-Log "Loop error: $($_.Exception.Message)"
        Start-Sleep -Seconds 2
    }
}
