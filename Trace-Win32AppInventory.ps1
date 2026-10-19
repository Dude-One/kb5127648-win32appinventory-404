<#
.SYNOPSIS
    Records what Windows itself logs when the MDM client runs the Win32AppInventory Get.

.DESCRIPTION
    Run as Administrator on an MDM-enrolled PC. It:
      1. records the PC's build, the update, the CSP and aeinv.dll versions;
      2. starts an ETW trace (built-in logman) of the MDM diagnostics provider, the OMA-DM client
         and Application Experience, at verbose level;
      3. asks Windows to run an MDM sync now (the enrollment's own scheduled task, the same sync
         Windows runs on its schedule);
      4. waits for the session, stops the trace and decodes it with the built-in tracerpt;
      5. writes the lines about Win32AppInventory and their result codes to poc-summary.txt.

    Nothing is installed or changed apart from the temporary trace session, which is stopped at
    the end. The full trace (mdm.etl / mdm.csv) can contain enrollment details: keep it local and
    share only poc-summary.txt after checking it.

.PARAMETER WaitSeconds
    How long to record after starting the sync. Default 240.
#>
#Requires -Version 5.1
[CmdletBinding()]
param([int]$WaitSeconds = 240)

$ErrorActionPreference = 'Continue'
$out = 'C:\Temp\poc'
New-Item -ItemType Directory -Force $out | Out-Null
$session = 'Win32AppInvPoc'
$etl = Join-Path $out 'mdm.etl'
$csv = Join-Path $out 'mdm.csv'
$summary = Join-Path $out 'poc-summary.txt'
Remove-Item $etl, $csv, $summary -Force -ErrorAction SilentlyContinue

function Log([string]$line) { $line; Add-Content -Path $summary -Value $line -Encoding ascii }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { 'Run this in PowerShell as Administrator.'; exit 1 }

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Log ("Run at {0:u}" -f (Get-Date).ToUniversalTime())
Log ("Windows {0} {1}, build {2}.{3}" -f $cv.EditionID, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR)
$kb = Get-HotFix -Id KB5127648 -ErrorAction SilentlyContinue
Log ("KB5127648: " + $(if ($kb) { "installed $($kb.InstalledOn)" } else { 'not installed' }))
foreach ($f in 'Win32AppInventoryCSP.dll', 'aeinv.dll') {
    $p = Join-Path $env:WINDIR "System32\$f"
    if (Test-Path $p) { Log ("{0}: {1}" -f $f, (Get-Item $p).VersionInfo.FileVersion) } else { Log "${f}: missing" }
}
try { Log ("Win32_InstalledWin32Program: {0} items" -f @(Get-CimInstance Win32_InstalledWin32Program -ErrorAction Stop).Count) }
catch { Log ("Win32_InstalledWin32Program error: " + $_.Exception.Message) }

# 2. ETW trace
logman stop $session -ets 2>$null | Out-Null
logman create trace $session -o $etl -ets -p 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider' 0xFFFFFFFFFFFFFFFF 0xFF | Out-Null
# OMA-DM client (by GUID, it is not registered by name) and Application Experience (aeinv.dll's area)
logman update trace $session -ets -p '{3B9602FF-E09B-4C6C-BC19-1A3DFA8F2250}' 0xFFFFFFFFFFFFFFFF 0xFF 2>$null | Out-Null
logman update trace $session -ets -p 'Microsoft-Windows-Application-Experience' 0xFFFFFFFFFFFFFFFF 0xFF 2>$null | Out-Null
Log "Trace started: $session"

# 3. Trigger an MDM sync through the enrollment's own scheduled task
$tasks = @(Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -match 'PushLaunch|Schedule #3|Schedule to run OMADMClient by client' })
if ($tasks.Count -gt 0) {
    $t = $tasks | Select-Object -First 1
    Start-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName
    Log "Sync started with task: $($t.TaskName)"
} else {
    Log 'No enrollment sync task found; recording the next scheduled session instead.'
}

# 4. Record, then stop and decode
Log "Recording for $WaitSeconds seconds..."
Start-Sleep -Seconds $WaitSeconds
logman stop $session -ets | Out-Null
tracerpt $etl -o $csv -of CSV -y 2>&1 | Out-Null
Log ("Trace stopped. ETL {0} bytes, CSV {1} bytes" -f (Get-Item $etl -ErrorAction SilentlyContinue).Length, (Get-Item $csv -ErrorAction SilentlyContinue).Length)

# 5. What Windows logged about this CSP
Log ''
Log '=== decoded events mentioning Win32AppInventory / Win32InstalledProgram / GetAppInventory'
$hits = @(Select-String -Path $csv -Pattern 'Win32AppInventory|Win32InstalledProgram|GetAppInventory|AppInventory' -ErrorAction SilentlyContinue)
Log ("{0} lines" -f $hits.Count)
$hits | Select-Object -First 40 | ForEach-Object { Log ($_.Line.Substring(0, [Math]::Min(600, $_.Line.Length))) }

Log ''
Log '=== raw ETL strings mentioning the CSP (fallback when an event is not decoded)'
$text = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes($etl))
$raw = [regex]::Matches($text, '[\x20-\x7E]{0,120}(Win32AppInventory|Win32InstalledProgram|GetAppInventory)[\x20-\x7E]{0,200}') |
    ForEach-Object { $_.Value } | Select-Object -Unique
Log ("{0} strings" -f @($raw).Count)
$raw | Select-Object -First 30 | ForEach-Object { Log $_ }

Log ''
Log "Done. Full trace: $etl / $csv (keep local). Summary: $summary"
