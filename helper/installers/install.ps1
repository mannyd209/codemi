# CodeMi Helper installer for Windows.
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm https://relay.mannydlabs.com/install.ps1))) <pairing-secret> <helper-sha256>"
# The CodeMi app passes the SHA-256 of the helper it expects, so the download is checked against
# a value from the app, not from this server. About the helper: https://mannydlabs.com/codemi-helper
# Installs a small background helper that lets the CodeMi iPhone app check Kimi Code's
# Remote Control and turn it back on. It never runs any other command.
# Uninstall: the same command with --uninstall instead of the pairing secret.
param([string]$Secret, [string]$Sha256)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$Relay = if ($env:CODEMI_RELAY) { $env:CODEMI_RELAY } else { 'https://relay.mannydlabs.com' }
$Dir = Join-Path $env:LOCALAPPDATA 'CodeMi Helper'
$Script = Join-Path $Dir 'helper.ps1'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValue = 'CodeMi Helper'

# Stops every running helper (any copy started from the CodeMi Helper folder) and waits until
# they are gone, so a new install never leaves an old helper with an old pairing running.
function Stop-Helper {
    for ($i = 0; $i -lt 10; $i++) {
        $old = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*CodeMi Helper*helper.ps1*' -and $_.ProcessId -ne $PID })
        if ($old.Count -eq 0) { return }
        $old | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 500
    }
}

if ($Secret -eq '--uninstall') {
    Stop-Helper
    Remove-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue
    Remove-Item -Path $Dir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output 'CodeMi Helper removed.'
    return
}

if ($Secret -notmatch '^[A-Za-z0-9_-]{43}$') {
    Write-Error 'Usage: install.ps1 <pairing-secret from the CodeMi app>'
    return
}

New-Item -ItemType Directory -Path $Dir -Force | Out-Null
$download = Join-Path $env:TEMP ("codemi-helper-" + [Guid]::NewGuid().ToString('N') + '.ps1')
Invoke-WebRequest -UseBasicParsing -Uri "$Relay/helper/windows/helper.ps1" -OutFile $download
if ($Sha256) {
    $expected = $Sha256.Trim().ToLower()
} else {
    $expected = ((Invoke-WebRequest -UseBasicParsing -Uri "$Relay/helper/windows/helper.sha256").Content -split '\s')[0].Trim().ToLower()
}
$actual = (Get-FileHash -Algorithm SHA256 -Path $download).Hash.ToLower()
# An older CodeMi app pins the helper version it shipped with (newest first).
foreach ($older in @('0.3.0', '0.2.1')) {
    if ($actual -eq $expected) { break }
    Invoke-WebRequest -UseBasicParsing -Uri "$Relay/helper/windows/$older/helper.ps1" -OutFile $download
    $actual = (Get-FileHash -Algorithm SHA256 -Path $download).Hash.ToLower()
}
if ($actual -ne $expected) {
    Remove-Item $download -Force -ErrorAction SilentlyContinue
    Write-Error "Download check failed (SHA-256 $actual, expected $expected); nothing was installed."
    return
}
Write-Output "Helper download verified (SHA-256 $actual)."


# Keep the pairings other iPhones and iPads already have: this one first, then up to 7 earlier ones.
$pairings = New-Object System.Collections.Generic.List[string]
$pairings.Add($Secret)
try {
    $old = Get-Content -Raw -Path (Join-Path $Dir 'config.json') | ConvertFrom-Json
    foreach ($code in @($old.secrets) + @($old.secret)) {
        if ($code -and -not $pairings.Contains([string]$code) -and $pairings.Count -lt 8) { $pairings.Add([string]$code) }
    }
} catch {}

Stop-Helper
# A fresh log, so the check below only counts the new helper connecting.
Remove-Item -Path (Join-Path $Dir 'helper.log') -Force -ErrorAction SilentlyContinue
Move-Item -Path $download -Destination $Script -Force
@{ relay = $Relay; secret = $Secret; secrets = $pairings.ToArray() } | ConvertTo-Json -Compress | Set-Content -Path (Join-Path $Dir 'config.json') -Encoding ASCII

$command = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`""
New-Item -Path $RunKey -Force | Out-Null
Set-ItemProperty -Path $RunKey -Name $RunValue -Value $command
Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$Script`"")

$log = Join-Path $Dir 'helper.log'
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 1
    if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'Connected to relay' -Quiet)) {
        Write-Output 'CodeMi Helper installed and running. You can turn Remote Control back on from the CodeMi app.'
        return
    }
}
Write-Error "CodeMi Helper was installed but hasn't connected yet. Log: $log"
