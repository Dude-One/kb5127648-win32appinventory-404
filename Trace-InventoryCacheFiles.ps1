#Requires -Version 5.1
<#
.SYNOPSIS
    Finds the SQLite inventory cache the failing Win32AppInventory Get opens, and reads its layout.

.DESCRIPTION
    Run as Administrator. Built-in tools only (logman, tracerpt). It:
      1. traces file opens (Microsoft-Windows-Kernel-File), process starts
         (Microsoft-Windows-Kernel-Process), the MDM diagnostics provider and Application Experience;
      2. starts an MDM sync through the enrollment's own scheduled task and records for 75 seconds;
      3. finds the process that logged the SqliteInvCache "Schema mismatch" error, and lists every
         file that process opened, flagging database files;
      4. for each database file found, makes a READ-ONLY copy and reads its SQLite header and the
         table definitions stored inside it.

    Nothing on the PC is changed, apart from the temporary trace session (stopped at the end) and
    one normal MDM sync. Output: C:\Temp\poc2\files-summary.txt. The raw trace stays local.
#>
[CmdletBinding()]
param([int]$WaitSeconds = 75)

$ErrorActionPreference = 'Continue'
$out = 'C:\Temp\poc2'
New-Item -ItemType Directory -Force $out, "$out\copies" | Out-Null
$session = 'InvCacheFiles'
$etl = Join-Path $out 'files.etl'
$csv = Join-Path $out 'files.csv'
$summary = Join-Path $out 'files-summary.txt'
Remove-Item $etl, $csv, $summary -Force -ErrorAction SilentlyContinue

function Log([string]$line) { $line; Add-Content -Path $summary -Value $line -Encoding ascii }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Run this in PowerShell as Administrator.'; exit 1 }

Log ("Run at {0:u}" -f (Get-Date).ToUniversalTime())

# 1. Trace. Kernel-File keywords: 0x10 file name, 0x80 create (open), 0x1000 create new file.
logman stop $session -ets 2>$null | Out-Null
logman create trace $session -o $etl -ets -bs 1024 -nb 64 256 -p 'Microsoft-Windows-Kernel-File' 0x1090 0x5 | Out-Null
logman update trace $session -ets -p 'Microsoft-Windows-Kernel-Process' 0x10 0x5 2>$null | Out-Null
logman update trace $session -ets -p 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider' 0xFFFFFFFFFFFFFFFF 0xFF 2>$null | Out-Null
logman update trace $session -ets -p 'Microsoft-Windows-Application-Experience' 0xFFFFFFFFFFFFFFFF 0xFF 2>$null | Out-Null
Log "Trace started: $session"

# 2. Sync
$task = Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -match 'PushLaunch|Schedule #3|Schedule to run OMADMClient by client' } | Select-Object -First 1
if ($task) { Start-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName; Log "Sync started with task: $($task.TaskName)" }
else { Log 'No enrollment sync task found; recording the next scheduled session.' }
Log "Recording for $WaitSeconds seconds..."
Start-Sleep -Seconds $WaitSeconds
logman stop $session -ets | Out-Null
tracerpt $etl -o $csv -of CSV -y 2>&1 | Out-Null
Log ("Trace stopped. ETL {0} bytes, CSV {1} bytes" -f (Get-Item $etl).Length, (Get-Item $csv -ErrorAction SilentlyContinue).Length)

# 3. Which process failed, and what it opened
$rows = Get-Content $csv
$failPids = @{}
$procNames = @{}
foreach ($r in $rows) {
    $c = $r -split ','
    if ($c.Count -lt 20) { continue }
    $procId = $c[9].Trim()
    if ($r -match 'SqliteInvCache') { $failPids[$procId] = $true }
    if ($c[0] -like '*Kernel-Process*' -and $r -match '\\([^\\",]+\.exe)') { $procNames[$procId] = $Matches[1] }
}
Log ''
Log ("Processes that logged the SqliteInvCache error: " + (($failPids.Keys | ForEach-Object {
    $n = [Convert]::ToInt32($_, 16); $name = (Get-Process -Id $n -ErrorAction SilentlyContinue).ProcessName
    "$_ ($n) $name" }) -join ', '))

$files = @{}
foreach ($r in $rows) {
    $c = $r -split ','
    if ($c.Count -lt 20 -or $c[0] -notlike '*Kernel-File*') { continue }
    if (-not $failPids.ContainsKey($c[9].Trim())) { continue }
    if ($r -match '"(\\Device\\[^"]+|[A-Z]:\\[^"]+)"') { $files[$Matches[1]] = 1 + [int]$files[$Matches[1]] }
}
Log ''
Log "=== files opened by that process during the sync ($($files.Count))"
$files.Keys | Sort-Object | ForEach-Object {
    $flag = if ($_ -match '(?i)\.db$|\.db-wal$|\.db-shm$|\.sqlite|\.dat$|Inventory|appcompat|Amcache') { '  <<<' } else { '' }
    Log ("{0,4}x {1}{2}" -f $files[$_], $_, $flag)
}

# 4. Read every database file it opened (read-only copy)
function DevicePathToDos([string]$p) {
    if ($p -match '^[A-Z]:\\') { return $p }
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        $sb = New-Object Text.StringBuilder 260
        Add-Type -Namespace W -Name K -MemberDefinition '[DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern uint QueryDosDevice(string d, System.Text.StringBuilder t, uint m);' -ErrorAction SilentlyContinue
        [void][W.K]::QueryDosDevice($d.Name.TrimEnd('\'), $sb, 260)
        if ($sb.Length -and $p.StartsWith($sb.ToString() + '\')) { return $d.Name.TrimEnd('\') + $p.Substring($sb.Length) }
    }
    return $p
}
$dbs = $files.Keys | Where-Object { $_ -match '(?i)\.(db|sqlite|sqlite3|dat)$' } | ForEach-Object { DevicePathToDos $_ } | Select-Object -Unique
Log ''
Log "=== database files ($(@($dbs).Count))"
foreach ($db in $dbs) {
    Log "--- $db"
    if (-not (Test-Path $db)) { Log '    (gone)'; continue }
    $i = Get-Item $db -Force
    Log ("    size {0} bytes, created {1:u}, modified {2:u} (UTC)" -f $i.Length, $i.CreationTimeUtc, $i.LastWriteTimeUtc)
    $copy = Join-Path "$out\copies" ($i.Name)
    try {
        $src = [IO.File]::Open($db, 'Open', 'Read', 'ReadWrite,Delete')
        $dst = [IO.File]::Create($copy); $src.CopyTo($dst); $dst.Close(); $src.Close()
    } catch { Log "    copy failed: $($_.Exception.Message)"; continue }
    $bytes = [IO.File]::ReadAllBytes($copy)
    $isSqlite = [Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(16, $bytes.Length)) -eq "SQLite format 3`0"
    Log "    SQLite file: $isSqlite"
    if ($isSqlite) {
        function BE32([int]$o) { ([int]$bytes[$o] -shl 24) -bor ([int]$bytes[$o+1] -shl 16) -bor ([int]$bytes[$o+2] -shl 8) -bor [int]$bytes[$o+3] }
        Log ("    page size {0}, schema cookie {1}, schema format {2}, user_version {3}, application_id {4}, written by SQLite {5}" -f `
            ((([int]$bytes[16] -shl 8) -bor [int]$bytes[17])), (BE32 40), (BE32 44), (BE32 60), (BE32 68), (BE32 96))
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        [regex]::Matches($text, 'CREATE (TABLE|INDEX|UNIQUE INDEX)[^\x00-\x08]{0,600}?\)(?=[\x00-\x1F]|$)') |
            ForEach-Object { $_.Value -replace '\s+', ' ' } | Select-Object -Unique | ForEach-Object { Log "    $_" }
    }
}
Log ''
Log "Done. Summary: $summary (raw trace and copies stay in $out)"
