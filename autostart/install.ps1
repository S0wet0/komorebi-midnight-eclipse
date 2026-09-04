# komorebi-desktop installer: sets up startup + recovery for komorebi, whkd
# and Zebar. Run once from an ELEVATED PowerShell:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#
# Re-running is safe (it replaces the previous install). Undo with
# uninstall.ps1. Keep this file ASCII-only (Windows PowerShell 5.1).
#
# What it does:
#  1. Creates C:\ProgramData\komorebi-desktop, writable only by
#     Administrators/SYSTEM (normal processes can read, not modify), and
#     copies in whkdrc + both supervisor scripts. whkd and the elevated
#     supervisor run elevated, so nothing unprivileged may edit what they run.
#  2. Registers two logon tasks (folder \komorebi-desktop\):
#       Elevated - "Run with highest privileges": komorebi + whkd
#       User     - normal privileges: Zebar, after komorebi answers
#     Launched via `conhost --headless` so no console window appears.
#  3. Switches over immediately: stops the current komorebi/whkd/Zebar and
#     starts both tasks, then prints a status report.

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated (Administrator) PowerShell.'
}

$Source    = Split-Path -Parent $MyInvocation.MyCommand.Path          # autostart
$ConfigDir = Split-Path -Parent $Source                               # preset root (whkdrc)
$Root      = Join-Path $env:ProgramData 'komorebi-desktop'
$TaskPath  = '\komorebi-desktop\'
$User      = $identity.Name

Write-Host "Installing for $User into $Root"

# --- 0. stop any previous supervisors so they don't fight the new ones -----
foreach ($name in 'Elevated', 'User') {
    if (Get-ScheduledTask -TaskPath $TaskPath -TaskName $name -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskPath $TaskPath -TaskName $name -ErrorAction SilentlyContinue
    }
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'komorebi-desktop\\start-(elevated|user)\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "stopped old supervisor pid $($_.ProcessId)" }

# --- 1. protected install folder ---------------------------------------------
New-Item -ItemType Directory -Force -Path $Root, (Join-Path $Root 'logs') | Out-Null
Copy-Item (Join-Path $ConfigDir 'whkdrc')    (Join-Path $Root 'whkdrc') -Force
Copy-Item (Join-Path $Source 'start-elevated.ps1')    $Root -Force
Copy-Item (Join-Path $Source 'start-user.ps1')        $Root -Force
# Well-known SIDs, so this works on non-English Windows too:
#   S-1-5-32-544 Administrators, S-1-5-18 SYSTEM, S-1-5-32-545 Users.
# Owner is set to Administrators: an owner can always rewrite the ACL, so the
# normal (non-elevated) user must not own it.
& icacls $Root /setowner '*S-1-5-32-544' /T /C /Q | Out-Null
& icacls $Root /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /T /C /Q | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed ($LASTEXITCODE)" }
Write-Host 'install folder created and locked to Administrators/SYSTEM (others read-only)'

# Keep the user-profile whkdrc in sync too, so a manual `komorebic start --whkd`
# (normal privileges) still has the same bindings. The tasks don't read it.
Copy-Item (Join-Path $ConfigDir 'whkdrc') (Join-Path $env:USERPROFILE '.config\whkdrc') -Force

# --- 2. logon tasks ----------------------------------------------------------
function Register-Supervisor($name, $script, $runLevel, $description) {
    $action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" `
        -Argument "--headless `"$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $Root $script)`""
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $User
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel $runLevel
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $name -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description $description -Force | Out-Null
    Write-Host "registered task $TaskPath$name ($runLevel)"
}
Register-Supervisor 'Elevated' 'start-elevated.ps1' 'Highest' 'komorebi-desktop: starts and supervises komorebi and whkd (elevated).'
Register-Supervisor 'User'     'start-user.ps1'     'Limited' 'komorebi-desktop: starts and supervises Zebar after komorebi is ready.'

# --- 3. switch over now ------------------------------------------------------
Write-Host 'stopping current komorebi / whkd / Zebar...'
& 'C:\Program Files\komorebi\bin\komorebic.exe' stop *> $null
Start-Sleep -Seconds 2
Get-Process komorebi, whkd, zebar -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

Start-ScheduledTask -TaskPath $TaskPath -TaskName 'Elevated'
Start-ScheduledTask -TaskPath $TaskPath -TaskName 'User'
Write-Host 'tasks started; waiting 15s for everything to come up...'
Start-Sleep -Seconds 15

# --- status report -----------------------------------------------------------
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class Elev {
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool i, int p);
  [DllImport("advapi32.dll")] static extern bool OpenProcessToken(IntPtr p, uint a, out IntPtr t);
  [DllImport("advapi32.dll")] static extern bool GetTokenInformation(IntPtr t, int c, out int v, int l, out int r);
  public static string Of(int pid) {
    IntPtr p = OpenProcess(0x1000, false, pid), t; int v, r;
    if (p == IntPtr.Zero || !OpenProcessToken(p, 8, out t)) return "unknown";
    GetTokenInformation(t, 20, out v, 4, out r); return v != 0 ? "elevated" : "normal";
  }
}
"@
Write-Host ''
Write-Host '=== status ==='
foreach ($want in @(@('komorebi','elevated'), @('whkd','elevated'), @('zebar','normal'))) {
    $procs = @(Get-Process $want[0] -ErrorAction SilentlyContinue)
    if (-not $procs) { Write-Host ("{0,-9} NOT RUNNING" -f $want[0]); continue }
    foreach ($p in $procs) {
        $level = [Elev]::Of($p.Id)
        Write-Host ("{0,-9} pid {1,-6} {2,-8} {3}" -f $want[0], $p.Id, $level, $(if ($level -eq $want[1]) { 'ok' } else { "EXPECTED $($want[1])" }))
    }
}
foreach ($name in 'Elevated', 'User') {
    $info = Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $name
    Write-Host ("task {0,-9} last result 0x{1:X}  ({2})" -f $name, $info.LastTaskResult, $(if ($info.LastTaskResult -eq 0x41301) { 'running' } else { 'see Task Scheduler' }))
}
Write-Host ''
Write-Host "Logs: $Root\logs\elevated.log  and  $env:LOCALAPPDATA\komorebi-desktop\logs\user.log"
Get-Content (Join-Path $Root 'logs\elevated.log') -Tail 6 -ErrorAction SilentlyContinue
