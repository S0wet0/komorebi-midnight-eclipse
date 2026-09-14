# komorebi-desktop: elevated half of the startup/recovery pair.
# Runs at logon from the "komorebi-desktop\Elevated" scheduled task (Run with
# highest privileges), installed by install.ps1. Keep this file ASCII-only:
# Windows PowerShell 5.1 misreads non-ASCII in BOM-less UTF-8 files.
#
# Starts and supervises, elevated:
#   komorebi - elevated so it can tile elevated windows (Windhawk, admin
#              terminals); a normal-level komorebi can't even read them.
#   whkd     - elevated because its low-level keyboard hook can't see keys
#              typed into elevated windows otherwise. Reads its config from
#              the admin-only install folder, never from the user profile.
#
# Recovery rule: a program this script started that exits with code 0 was
# stopped on purpose (e.g. Alt+Shift+E runs `komorebic stop`) and is left
# alone until next logon. Any other exit is a crash and is restarted, with a
# crash-loop brake.

$ErrorActionPreference = 'Continue'
$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Komorebi  = 'C:\Program Files\komorebi\bin\komorebi.exe'
$Komorebic = 'C:\Program Files\komorebi\bin\komorebic.exe'
$Whkd      = 'C:\Program Files\whkd\bin\whkd.exe'
$Whkdrc    = Join-Path $Root 'whkdrc'
# komorebi restores this snapshot at startup without re-checking window
# rules; a stale one resurrected wrongly-managed windows twice during setup.
$StateFile = Join-Path $env:LOCALAPPDATA 'Temp\komorebi.state.json'
$LogFile   = Join-Path $Root 'logs\elevated.log'

New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null
function Log($message) {
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Move-Item $LogFile "$LogFile.old" -Force }
    Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $message)
}

function Wait-ForShell {
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        if (Get-Process explorer -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 3; return }
        Start-Sleep -Seconds 1
    }
    Log 'explorer did not appear within 90s; continuing anyway'
}

function Test-KomorebiReady {
    & $Komorebic state *> $null
    return ($LASTEXITCODE -eq 0)
}

# komorebi exits at once (code 1, "failed call to AllowSetForegroundWindow")
# unless it may bring windows to the front. Windows grants that only to the
# process the user is working with, processes it starts, or anyone while
# nothing is in the foreground: true at most logons, but not if an app wins
# the race at logon, nor for a crash restart while the user is working.
# Windows also re-grants it when Alt is pressed. So after a startup failure,
# the next attempt first sends one no-op chord (Alt + 0xE8, an unassigned key
# code, the same dummy whkd uses; SendInput delivers it as one unbroken
# sequence, so it can't mix with the user's typing) and opens foreground
# rights to any process, then launches komorebi immediately.
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class Foreground {
  [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public KEYBDINPUT ki; public long pad; }
  [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int size);
  [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int pid);
  static INPUT Key(ushort vk, bool up) { var i = new INPUT(); i.type = 1; i.ki.wVk = vk; i.ki.dwFlags = up ? 2u : 0u; return i; }
  public static string Unlock() {
    var keys = new[] { Key(0x12, false), Key(0xE8, false), Key(0xE8, true), Key(0x12, true) };
    uint sent = SendInput((uint)keys.Length, keys, Marshal.SizeOf(typeof(INPUT)));
    return "sent " + sent + " keys, allow-any " + AllowSetForegroundWindow(-1);
  }
}
"@
$unlockNext = $false

function Start-Komorebi {
    if (Test-Path $StateFile) { Remove-Item $StateFile -Force -ErrorAction SilentlyContinue; Log 'cleared komorebi state snapshot' }
    if ($script:unlockNext) { Log "foreground unlock before starting: $([Foreground]::Unlock())" }
    $proc = Start-Process -FilePath $Komorebi -WindowStyle Hidden -PassThru
    Log "started komorebi (pid $($proc.Id))"
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
        if (Test-KomorebiReady) { Log 'komorebi is answering'; $script:unlockNext = $false; return $proc }
        Start-Sleep -Milliseconds 500
    }
    if ($proc.HasExited) {
        # Almost always the foreground check above: unlock on the next try.
        Log "komorebi exited during startup (code $($proc.ExitCode)); the next start unlocks the foreground first"
        $script:unlockNext = $true
    } else { Log 'komorebi did not answer within 30s' }
    return $proc
}

function Start-Whkd {
    $proc = Start-Process -FilePath $Whkd -ArgumentList @('-c', "`"$Whkdrc`"") -WindowStyle Hidden -PassThru
    Log "started whkd (pid $($proc.Id)) with $Whkdrc"
    return $proc
}

# Crash-loop brake: more than 5 restarts of one program within 5 minutes
# pauses restarts of it for 5 minutes.
$restarts = @{ komorebi = New-Object System.Collections.ArrayList; whkd = New-Object System.Collections.ArrayList }
function Allow-Restart($name) {
    $now = Get-Date
    $recent = @($restarts[$name] | Where-Object { ($now - $_).TotalMinutes -lt 5 })
    $restarts[$name] = New-Object System.Collections.ArrayList(,$recent)
    if ($recent.Count -ge 5) { return $false }
    [void]$restarts[$name].Add($now)
    return $true
}

Log '--- elevated supervisor starting ---'
Wait-ForShell

$komorebiProc = $null; $komorebiStopped = $false
$whkdProc = $null; $whkdStopped = $false
$pausedUntil = @{ komorebi = [datetime]::MinValue; whkd = [datetime]::MinValue }

# Adopt instances that are already running (e.g. started by hand) instead of
# starting duplicates; they aren't ours, so their exit codes can't be read.
if (Get-Process komorebi -ErrorAction SilentlyContinue) { Log 'komorebi already running; adopting' } else { $komorebiProc = Start-Komorebi }
if (Get-Process whkd -ErrorAction SilentlyContinue) { Log 'whkd already running; adopting' } else { $whkdProc = Start-Whkd }

while ($true) {
    Start-Sleep -Seconds 5

    # --- komorebi ---
    if ($komorebiProc -and $komorebiProc.HasExited) {
        $code = $komorebiProc.ExitCode
        $komorebiProc = $null
        if ($code -eq 0) { $komorebiStopped = $true; Log 'komorebi exited cleanly (code 0): treated as a deliberate stop, not restarting' }
        else { Log "komorebi exited with code ${code}: treating as a crash" }
    }
    if (-not $komorebiStopped -and -not (Get-Process komorebi -ErrorAction SilentlyContinue) -and (Get-Date) -gt $pausedUntil.komorebi) {
        if (Allow-Restart 'komorebi') { $komorebiProc = Start-Komorebi }
        else { $pausedUntil.komorebi = (Get-Date).AddMinutes(5); Log 'komorebi crash loop: pausing restarts for 5 minutes' }
    }

    # --- whkd ---
    if ($whkdProc -and $whkdProc.HasExited) {
        $code = $whkdProc.ExitCode
        $whkdProc = $null
        if ($code -eq 0) { $whkdStopped = $true; Log 'whkd exited cleanly (code 0): not restarting' }
        else { Log "whkd exited with code ${code}: treating as a crash" }
    }
    if (-not $whkdStopped -and -not (Get-Process whkd -ErrorAction SilentlyContinue) -and (Get-Date) -gt $pausedUntil.whkd) {
        if (Allow-Restart 'whkd') { $whkdProc = Start-Whkd }
        else { $pausedUntil.whkd = (Get-Date).AddMinutes(5); Log 'whkd crash loop: pausing restarts for 5 minutes' }
    }
}
