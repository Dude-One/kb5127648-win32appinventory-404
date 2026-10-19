<#
.SYNOPSIS
    Checks whether this PC has the KB5127648 inventory cache problem that makes the
    Win32AppInventory CSP answer 404.

.DESCRIPTION
    Read-only. It changes nothing on the PC.

    The cause: the updated aeinv.dll (10.0.26100.9711) expects a column called SentDetailedInv in
    C:\Windows\AppCompat\Programs\InventoryApplication.db, but doesn't add it to a database created
    by an earlier build. With the old table, the CSP fails and answers 404.

    Run as Administrator: the cache folder can only be read by administrators, and that check is
    the one that decides.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Test-Win32AppInventoryRegression.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Show([string]$label, $value) { '{0,-30} {1}' -f $label, $value }

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

''
'Win32AppInventory / KB5127648 check'
'-----------------------------------'
Show 'Windows' ("{0} {1}, build {2}.{3}" -f $cv.EditionID, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR)
$kb = Get-HotFix -Id KB5127648 -ErrorAction SilentlyContinue
Show 'KB5127648' $(if ($kb) { "installed ($($kb.InstalledOn))" } else { 'not installed' })

$aeinv = Join-Path $env:WINDIR 'System32\aeinv.dll'
$aeinvVersion = $null
if (Test-Path $aeinv) { $aeinvVersion = [version](((Get-Item $aeinv).VersionInfo.FileVersion -split ' ')[0]) }
$newCode = $aeinvVersion -and $aeinvVersion -ge [version]'10.0.26100.9711'
Show 'aeinv.dll' $(if ($aeinvVersion) { "$aeinvVersion" + $(if ($newCode) { ' (expects SentDetailedInv)' } else { ' (older)' }) } else { 'missing' })

$db = Join-Path $env:WINDIR 'AppCompat\Programs\InventoryApplication.db'
$schema = 'unknown'
if (-not $isAdmin) {
    Show 'InventoryApplication.db' 'not checked (run as Administrator)'
} elseif (-not (Test-Path $db)) {
    Show 'InventoryApplication.db' 'not there (Windows creates it on the next inventory run)'
    $schema = 'none'
} else {
    $i = Get-Item $db -Force
    Show 'InventoryApplication.db' ("{0} bytes, last written {1:yyyy-MM-dd HH:mm} UTC" -f $i.Length, $i.LastWriteTimeUtc)
    try {
        $fs = [IO.File]::Open($db, 'Open', 'Read', 'ReadWrite,Delete')
        $buf = New-Object byte[] $fs.Length
        [void]$fs.Read($buf, 0, $buf.Length)
        $fs.Close()
        $text = [Text.Encoding]::UTF8.GetString($buf)
        $m = [regex]::Match($text, 'CREATE TABLE InventoryApplication_0 \([^)]*\)')
        $schema = if (-not $m.Success) { 'unknown' } elseif ($m.Value -match '"SentDetailedInv"') { 'new' } else { 'old' }
        Show 'Cache table' $(switch ($schema) {
            'new' { 'new layout (has SentDetailedInv)' }
            'old' { 'OLD layout (no SentDetailedInv)' }
            default { 'table not found in the file' } })
    } catch {
        Show 'Cache table' "could not read: $($_.Exception.Message)"
    }
}

''
if ($newCode -and $schema -eq 'old') {
    'RESULT: AFFECTED. The updated inventory code rejects this cache, so the CSP answers 404.'
    'Fix: rename C:\Windows\AppCompat\Programs\InventoryApplication.db* and run an MDM sync'
    '(see Rename-InventoryCache.ps1). Windows rebuilds it with the new layout.'
} elseif ($newCode -and $schema -in 'new', 'none') {
    'RESULT: OK. The cache matches the updated code, so the CSP should answer normally.'
} elseif ($newCode) {
    'RESULT: probably affected (KB5127648 or later). Run as Administrator to check the cache.'
} elseif ($aeinvVersion) {
    'RESULT: not affected yet. This PC is on a build before KB5127648. It will likely break after'
    'that update unless a later fix migrates the cache.'
} else {
    'RESULT: unknown. aeinv.dll not found.'
}
''
