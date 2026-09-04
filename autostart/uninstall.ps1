# komorebi-desktop uninstaller: removes the logon tasks and stops their
# supervisors. Run from an ELEVATED PowerShell:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 [-RemoveFiles]
#
# Leaves komorebi, whkd and Zebar running (stop them yourself if wanted).
# -RemoveFiles also deletes C:\ProgramData\komorebi-desktop.
param([switch]$RemoveFiles)
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated (Administrator) PowerShell.'
}

$TaskPath = '\komorebi-desktop\'
foreach ($name in 'Elevated', 'User') {
    if (Get-ScheduledTask -TaskPath $TaskPath -TaskName $name -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskPath $TaskPath -TaskName $name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $name -Confirm:$false
        Write-Host "removed task $TaskPath$name"
    }
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'komorebi-desktop\\start-(elevated|user)\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "stopped supervisor pid $($_.ProcessId)" }

if ($RemoveFiles) {
    Remove-Item (Join-Path $env:ProgramData 'komorebi-desktop') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'removed C:\ProgramData\komorebi-desktop'
}
Write-Host 'done. komorebi, whkd and Zebar were left running.'
