# komorebi-desktop uninstaller: removes the logon tasks and stops their
# supervisors. Run from an ELEVATED PowerShell:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 [-RemoveFiles]
#
# Leaves komorebi, whkd and Zebar running (stop them yourself if wanted). If
# the Midnight Eclipse theme is installed, restores its own Zebar logon entry.
# -RemoveFiles also deletes C:\ProgramData\komorebi-desktop.
param([switch]$RemoveFiles)
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated (Administrator) PowerShell.'
}

$TaskPath = '\komorebi-desktop\'
# Whose tasks these are, for handing Zebar's logon start back below.
$taskUser = $null
$userTask = Get-ScheduledTask -TaskPath $TaskPath -TaskName 'User' -ErrorAction SilentlyContinue
if ($userTask) { $taskUser = $userTask.Principal.UserId }
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

# The autostart install removed the Midnight Eclipse theme's own logon entry
# (the User task started Zebar instead). If the theme is installed for that
# user, give the entry back so Zebar still starts at logon.
$zebarExe = Join-Path $env:ProgramFiles 'glzr.io\Zebar\zebar.exe'
if ($taskUser -and (Test-Path $zebarExe)) {
    try {
        $sid = (New-Object Security.Principal.NTAccount($taskUser)).Translate([Security.Principal.SecurityIdentifier]).Value
        $userProfile = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
        $runKey = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Run"
        if ($userProfile -and (Test-Path (Join-Path $userProfile '.glzr\zebar\midnight-eclipse')) -and (Test-Path $runKey)) {
            Set-ItemProperty -Path $runKey -Name 'Midnight Eclipse (Zebar)' -Value "`"$zebarExe`""
            Write-Host "Midnight Eclipse theme found: Zebar will start at logon for $taskUser again"
        }
    } catch { Write-Warning "couldn't restore the theme's logon entry for ${taskUser}: $_ (re-run the theme's install.ps1)" }
}

if ($RemoveFiles) {
    Remove-Item (Join-Path $env:ProgramData 'komorebi-desktop') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'removed C:\ProgramData\komorebi-desktop'
}
Write-Host 'done. komorebi, whkd and Zebar were left running.'
