# komorebi-desktop: normal-privilege half of the startup/recovery pair.
# Runs at logon from the "komorebi-desktop\User" scheduled task (normal
# privileges), installed by install.ps1. Keep this file ASCII-only.
#
# Starts and supervises Zebar (bar + tooltip widgets), at normal privilege:
# - Only after komorebi is answering. If Zebar starts first, komorebi tiles
#   the bar as an ordinary window.
# - Restarted after a crash; left alone after a clean exit (code 0, e.g.
#   Zebar's own "Exit"), until next logon.
# - Restarted when komorebi itself restarts, so the bar's live komorebi
#   subscription reconnects.

$ErrorActionPreference = 'Continue'
$Komorebic = 'C:\Program Files\komorebi\bin\komorebic.exe'
$Zebar     = 'C:\Program Files\glzr.io\Zebar\zebar.exe'
$LogFile   = Join-Path $env:LOCALAPPDATA 'komorebi-desktop\logs\user.log'

New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null
function Log($message) {
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Move-Item $LogFile "$LogFile.old" -Force }
    Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $message)
}

function Test-KomorebiReady {
    & $Komorebic state *> $null
    return ($LASTEXITCODE -eq 0)
}

function Wait-ForKomorebi($seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-KomorebiReady) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Get-KomorebiId {
    $k = Get-Process komorebi -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($k) { return $k.Id } else { return $null }
}

function Stop-Zebar {
    Get-Process zebar -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
}

function Start-Zebar {
    $proc = Start-Process -FilePath $Zebar -PassThru
    Log "started zebar (pid $($proc.Id))"
    return $proc
}

$restarts = New-Object System.Collections.ArrayList
function Allow-Restart {
    $now = Get-Date
    $recent = @($restarts | Where-Object { ($now - $_).TotalMinutes -lt 5 })
    $script:restarts = New-Object System.Collections.ArrayList(,$recent)
    if ($recent.Count -ge 5) { return $false }
    [void]$script:restarts.Add($now)
    return $true
}

Log '--- user supervisor starting ---'
if (-not (Wait-ForKomorebi 120)) { Log 'komorebi not answering after 120s; starting zebar anyway' }

$zebarProc = $null; $zebarStopped = $false
$pausedUntil = [datetime]::MinValue
$komorebiId = Get-KomorebiId

if (Get-Process zebar -ErrorAction SilentlyContinue) {
    # A Zebar started before komorebi was ready may have been tiled; restart
    # it so komorebi's ignore rule applies to a fresh window.
    Log 'zebar already running; restarting it after komorebi'
    Stop-Zebar
}
$zebarProc = Start-Zebar

while ($true) {
    Start-Sleep -Seconds 5

    if ($zebarProc -and $zebarProc.HasExited) {
        $code = $zebarProc.ExitCode
        $zebarProc = $null
        if ($code -eq 0) { $zebarStopped = $true; Log 'zebar exited cleanly (code 0): treated as a deliberate exit, not restarting' }
        else { Log "zebar exited with code ${code}: treating as a crash" }
    }

    # komorebi restarted (new process): reconnect the bar's subscription.
    $currentId = Get-KomorebiId
    if ($currentId -and $komorebiId -and $currentId -ne $komorebiId -and -not $zebarStopped) {
        Log "komorebi restarted (pid $komorebiId -> $currentId); restarting zebar once it answers"
        if (Wait-ForKomorebi 30) { Stop-Zebar; $zebarProc = Start-Zebar }
    }
    if ($currentId) { $komorebiId = $currentId }

    if (-not $zebarStopped -and -not (Get-Process zebar -ErrorAction SilentlyContinue) -and (Get-Date) -gt $pausedUntil) {
        if (Allow-Restart) { [void](Wait-ForKomorebi 30); $zebarProc = Start-Zebar }
        else { $pausedUntil = (Get-Date).AddMinutes(5); Log 'zebar crash loop: pausing restarts for 5 minutes' }
    }
}
