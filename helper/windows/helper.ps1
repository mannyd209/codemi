# CodeMi Helper for Windows.
#
# Keeps a WebSocket open to the CodeMi relay so the CodeMi iPhone app can check Kimi Code's
# Remote Control and turn it back on while Remote Control itself is off. It only ever reads the
# Remote Control status and turns Remote Control on (opening Kimi Code first if it was quit),
# or removes itself when asked. It never runs any other command.
#
# Written for Windows PowerShell 5.1 (built into Windows 10 and 11); also runs on PowerShell 7.
# Config: %LOCALAPPDATA%\CodeMi Helper\config.json  {"relay": "...", "secrets": ["...", ...], "secret": "..."}
# Each pairing (one per iPhone or iPad that installed the helper, up to 8) has its own
# connection, so installing from another device never cuts off the ones already paired, and
# removing it from one device only drops that device's pairing (the last one removes the helper).
# "secret" alone is the 0.2 format, still read.

$ErrorActionPreference = 'Stop'
$HelperVersion = '0.3.2'
$HelperDir = if ($env:CODEMI_HELPER_DIR) { $env:CODEMI_HELPER_DIR } else { Join-Path $env:LOCALAPPDATA 'CodeMi Helper' }
$ConfigPath = Join-Path $HelperDir 'config.json'
$LogPath = Join-Path $HelperDir 'helper.log'
$KimiHome = Join-Path $HOME '.kimi-code'
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
            Send-Message $Socket @{ type = 'status'; id = $message.id; status = (Get-KimiStatus) }
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
            # Turning Remote Control on can take a minute; that time doesn't count as silence.
            $conn.LastHeard = Get-Date
        }
        if ($conn.Removed) { continue }
        try { $conn.Pending = Receive-Start $conn.Socket $conn.Buffer } catch { Close-Connection $conn $_.Exception.GetBaseException().Message }
    } catch {
        Write-Log "Loop error: $($_.Exception.Message)"
        Start-Sleep -Seconds 2
    }
}
