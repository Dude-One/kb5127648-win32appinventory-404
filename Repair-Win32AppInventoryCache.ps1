#Requires -Version 5.1
<#
.SYNOPSIS
    Fixes the Win32AppInventory 404 after KB5127648 on one PC.

.DESCRIPTION
    The updated aeinv.dll (10.0.26100.9711) expects a column called SentDetailedInv in
    C:\Windows\AppCompat\Programs\InventoryApplication.db and refuses a cache created by an earlier
    build ("Schema mismatch"), so the CSP answers 404.

    This script:
      1. checks that the PC has the updated inventory code and the old cache layout;
      2. renames InventoryApplication.db and its -wal/-journal/-shm files to *.old-<timestamp>
         (all or nothing, nothing is deleted);
      3. starts an MDM sync and waits until Windows has recreated the cache with the new layout.

    It does nothing on a PC that isn't affected, so it's safe to run more than once or on every PC.
    Run as Administrator or SYSTEM.

    Exit codes, so any script runner can use it:
      0  not affected, or fixed
      1  affected (with -DetectOnly), or the fix couldn't be applied

    For Intune Remediations, upload one copy as the detection script with $DetectOnly defaulting
    to $true, and one unchanged copy as the remediation script.

    To undo: delete the new InventoryApplication.db* files and remove .old-<timestamp> from the
    renamed ones.

.PARAMETER DetectOnly
    Only report. Exit 1 if the PC is affected.

.PARAMETER NoSync
    Rename the cache but don't start an MDM sync. Windows rebuilds it on the next one.

.PARAMETER WaitSeconds
    How long to wait for Windows to rebuild the cache after the sync. Default 180.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Repair-Win32AppInventoryCache.ps1 -DetectOnly

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Repair-Win32AppInventoryCache.ps1
#>
[CmdletBinding()]
param(
    [switch]$DetectOnly = $false,
    [switch]$NoSync,
    [int]$WaitSeconds = 180,
    [string]$CacheFolder = (Join-Path $env:WINDIR 'AppCompat\Programs')
)

$ErrorActionPreference = 'Stop'
$name = 'InventoryApplication.db'
$db = Join-Path $CacheFolder $name

function Get-CacheLayout([string]$path) {
    # SQLite keeps each table's CREATE statement as plain text, so reading the bytes is enough.
    # The file is in use; open it with sharing so Windows can keep writing.
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite,Delete')
    try {
        $buf = New-Object byte[] $fs.Length
        [void]$fs.Read($buf, 0, $buf.Length)
    } finally { $fs.Close() }
    $m = [regex]::Match([Text.Encoding]::UTF8.GetString($buf), 'CREATE TABLE InventoryApplication_0 \([^)]*\)')
    if (-not $m.Success) { return 'unknown' }
    if ($m.Value -match '"SentDetailedInv"') { 'new' } else { 'old' }
}

function Start-MdmSync {
    $tasks = @(Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -match 'PushLaunch|Schedule #3|Schedule to run OMADMClient by client' })
    if ($tasks.Count -eq 0) { return $false }
    $t = $tasks[0]
    Start-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName
    $true
}

# 1. Is this PC affected?
$aeinv = Join-Path $env:WINDIR 'System32\aeinv.dll'
if (-not (Test-Path $aeinv)) { 'aeinv.dll not found. Nothing to do.'; exit 0 }
$version = [version](((Get-Item $aeinv).VersionInfo.FileVersion -split ' ')[0])
if ($version -lt [version]'10.0.26100.9711') {
    "Not affected: aeinv.dll is $version, before KB5127648."
    exit 0
}
try { $exists = Test-Path $db -ErrorAction Stop }
catch { "Can't open ${CacheFolder}: run as Administrator or SYSTEM."; exit 1 }
if (-not $exists) {
    "Not affected: $name isn't there yet. Windows creates it with the new layout."
    exit 0
}
try { $layout = Get-CacheLayout $db }
catch { "Can't read ${db}: $($_.Exception.Message) Run as Administrator or SYSTEM."; exit 1 }

switch ($layout) {
    'new'     { "Not affected: $name already has the new layout."; exit 0 }
    'unknown' { "$name doesn't contain the expected table. Not touching it."; exit 1 }
}
"AFFECTED: $name has the old layout (no SentDetailedInv) and aeinv.dll is $version."
if ($DetectOnly) { exit 1 }

# 2. Move the old cache aside, all or nothing
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$renamed = @()
try {
    foreach ($n in @($name, "$name-wal", "$name-journal", "$name-shm")) {
        $p = Join-Path $CacheFolder $n
        if (-not (Test-Path $p)) { continue }
        Rename-Item -Path $p -NewName "$n.old-$stamp"
        $renamed += $n
        "Renamed $n to $n.old-$stamp"
    }
} catch {
    "Couldn't rename: $($_.Exception.Message)"
    foreach ($n in $renamed) { Rename-Item -Path (Join-Path $CacheFolder "$n.old-$stamp") -NewName $n -ErrorAction SilentlyContinue }
    'Put everything back. Nothing changed. Try again in a minute.'
    exit 1
}

# 3. Let Windows rebuild it
if ($NoSync) { 'Done. Windows rebuilds the cache on the next MDM sync.'; exit 0 }
if (-not (Start-MdmSync)) { 'No MDM sync task found. Windows rebuilds the cache on the next MDM sync.'; exit 0 }
'MDM sync started, waiting for Windows to rebuild the cache...'
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    if (Test-Path $db) {
        try { $layout = Get-CacheLayout $db } catch { continue }
        if ($layout -eq 'new') { "FIXED: Windows rebuilt $name with the new layout."; exit 0 }
    }
}
"Not rebuilt within $WaitSeconds seconds. That's fine: Windows rebuilds it on the next MDM sync."
exit 0
