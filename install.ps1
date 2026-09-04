# komorebi Midnight Eclipse preset installer. Run from a normal PowerShell in
# this folder:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#
# Copies komorebi.json and whkdrc to where komorebi and whkd look for them,
# backing up any existing files first (*.bak-<timestamp>), and downloads
# komorebi's community application rules (applications.json). Doesn't start
# or stop anything. Keep this file ASCII-only (Windows PowerShell 5.1).
$ErrorActionPreference = 'Stop'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# Where komorebi and whkd read their configs (their documented defaults,
# unless you've set these environment variables).
$KomorebiHome = if ($env:KOMOREBI_CONFIG_HOME) { $env:KOMOREBI_CONFIG_HOME } else { $env:USERPROFILE }
$WhkdHome     = if ($env:WHKD_CONFIG_HOME) { $env:WHKD_CONFIG_HOME } else { Join-Path $env:USERPROFILE '.config' }

function Install-File($name, $destDir) {
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $dest = Join-Path $destDir $name
    if (Test-Path $dest) {
        Copy-Item $dest "$dest.bak-$Stamp" -Force
        Write-Host "backed up existing $dest"
    }
    Copy-Item (Join-Path $Here $name) $dest -Force
    Write-Host "installed $dest"
}

Install-File 'komorebi.json' $KomorebiHome
Install-File 'whkdrc' $WhkdHome

# komorebi.json expects applications.json in %USERPROFILE%; fetch-asc saves it
# to KOMOREBI_CONFIG_HOME, so point the installed copy there when that's set.
if ($env:KOMOREBI_CONFIG_HOME) {
    $configPath = Join-Path $KomorebiHome 'komorebi.json'
    $text = [System.IO.File]::ReadAllText($configPath)
    $text = $text.Replace('$Env:USERPROFILE/applications.json', ($KomorebiHome.Replace('\', '/') + '/applications.json'))
    [System.IO.File]::WriteAllText($configPath, $text, (New-Object System.Text.UTF8Encoding $false))
}

$komorebic = Get-Command komorebic.exe -ErrorAction SilentlyContinue
if ($komorebic) {
    Write-Host 'fetching applications.json (community rules for apps that need special handling)...'
    Push-Location $KomorebiHome
    try { & $komorebic.Source fetch-asc } finally { Pop-Location }
} else {
    Write-Warning 'komorebic.exe not found on PATH; install komorebi (winget install LGUG2Z.komorebi), then run: komorebic fetch-asc'
}

Write-Host ''
Write-Host 'Done. Start komorebi with its keybindings:'
Write-Host '  komorebic start --whkd'
Write-Host 'or reload a running instance with Alt+Shift+R. For automatic, elevated startup see autostart\ in README.md.'
