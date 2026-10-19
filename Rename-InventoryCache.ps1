<#
.SYNOPSIS
    The test that proved the fix: moves the inventory cache aside, syncs twice, logs old and new table.

.DESCRIPTION
    Run as Administrator or SYSTEM. Renames InventoryApplication.db and its sidecar files to
    *.bak-test (all or nothing, nothing is deleted), triggers two MDM syncs and logs the files and
    both table layouts to C:\Temp\poc3\rename-test.txt. For fixing PCs, use
    Repair-Win32AppInventoryCache.ps1 instead.
#>
$ErrorActionPreference = 'Continue'
$dir = 'C:\Windows\AppCompat\Programs'
$base = 'InventoryApplication.db'
$log = 'C:\Temp\poc3\rename-test.txt'
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
Remove-Item $log -Force -ErrorAction SilentlyContinue
function Log([string]$s) { Add-Content -Path $log -Value $s -Encoding ascii }
function Files { Get-ChildItem $dir -Force -Filter 'InventoryApplication.db*' -ErrorAction SilentlyContinue |
    ForEach-Object { "  {0,-38} {1,9} bytes  modified {2:yyyy-MM-dd HH:mm:ss} UTC" -f $_.Name, $_.Length, $_.LastWriteTimeUtc } }
function Schema([string]$path) {
    try {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite,Delete'); $buf = New-Object byte[] $fs.Length
        [void]$fs.Read($buf, 0, $buf.Length); $fs.Close()
        $t = [Text.Encoding]::UTF8.GetString($buf)
        [regex]::Matches($t, 'CREATE[\x20-\x7E]{6,1200}') | ForEach-Object { '  ' + $_.Value } | Select-Object -Unique
    } catch { "  (could not read: $($_.Exception.Message))" }
}
function Sync {
    $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -match 'PushLaunch|Schedule #3|Schedule to run OMADMClient by client' } | Select-Object -First 1
    if ($t) { Start-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName; Log ("MDM sync started at {0:HH:mm:ss} UTC ({1})" -f (Get-Date).ToUniversalTime(), $t.TaskName) }
    else { Log 'No enrollment sync task found.' }
}

Log ("Rename test, run at {0:u} as {1}" -f (Get-Date).ToUniversalTime(), [Security.Principal.WindowsIdentity]::GetCurrent().Name)
Log 'Before:'
Files | ForEach-Object { Log $_ }
Log 'Old schema:'
Schema (Join-Path $dir $base) | ForEach-Object { Log $_ }

# Rename the db and its sidecars. All or nothing: if one is locked, put back what was renamed.
$done = @()
$ok = $true
foreach ($n in @($base, "$base-wal", "$base-journal", "$base-shm")) {
    $p = Join-Path $dir $n
    if (-not (Test-Path $p)) { continue }
    try { Rename-Item -Path $p -NewName "$n.bak-test" -ErrorAction Stop; $done += $n; Log "Renamed $n -> $n.bak-test" }
    catch { Log "Could not rename ${n}: $($_.Exception.Message)"; $ok = $false; break }
}
if (-not $ok) {
    foreach ($n in $done) { Rename-Item -Path (Join-Path $dir "$n.bak-test") -NewName $n -ErrorAction SilentlyContinue; Log "Put back $n" }
    Log 'ABORTED: a cache file is in use. Nothing changed.'
    exit 1
}

Sync
Start-Sleep -Seconds 90
Log 'After first sync:'
Files | ForEach-Object { Log $_ }
Sync
Start-Sleep -Seconds 75
Log 'After second sync:'
Files | ForEach-Object { Log $_ }
$new = Join-Path $dir $base
if (Test-Path $new) { Log 'New schema:'; Schema $new | ForEach-Object { Log $_ } }
else { Log 'No new InventoryApplication.db was created yet.' }

Log ''
Log 'To restore the original cache (as SYSTEM or admin), delete the new InventoryApplication.db* files and'
Log 'rename each InventoryApplication.db*.bak-test back by removing .bak-test.'
Log ("Done at {0:u}" -f (Get-Date).ToUniversalTime())
