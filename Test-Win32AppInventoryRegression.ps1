#Requires -Version 5.1
<#
.SYNOPSIS
    Checks whether this PC has the October 2026 change (KB5127648) that makes the Win32AppInventory
    CSP answer 404.

.DESCRIPTION
    Read-only. It changes nothing on the PC.

    The CSP itself can only be queried by an MDM server, so the real test is a Get of
    ./Vendor/MSFT/Win32AppInventory/Win32InstalledProgram?list=StructData from your server
    (404 = affected). This script checks what can be checked locally: the build, the update, the
    DLL versions, whether the CSP is still registered, and whether the new aeinv.dll is there.

    Run as Administrator to also count what WMI (Win32_InstalledWin32Program) sees.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Test-Win32AppInventoryRegression.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Show([string]$label, $value) { '{0,-34} {1}' -f $label, $value }

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = [int]$cv.CurrentBuild
$ubr = [int]$cv.UBR
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

''
'Win32AppInventory CSP check (KB5127648)'
'---------------------------------------'
Show 'Windows' ("{0} {1}, build {2}.{3}" -f $cv.EditionID, $cv.DisplayVersion, $build, $ubr)

$kb = Get-HotFix -Id KB5127648 -ErrorAction SilentlyContinue
Show 'KB5127648 installed' $(if ($kb) { "yes ($($kb.InstalledOn))" } else { 'no' })

$sys32 = Join-Path $env:WINDIR 'System32'
$cspDll = Join-Path $sys32 'Win32AppInventoryCSP.dll'
$aeinvDll = Join-Path $sys32 'aeinv.dll'
foreach ($f in $cspDll, $aeinvDll) {
    if (Test-Path $f) {
        $i = Get-Item $f
        Show (Split-Path $f -Leaf) ("{0} (modified {1:yyyy-MM-dd HH:mm} UTC)" -f $i.VersionInfo.FileVersion, $i.LastWriteTimeUtc)
    } else {
        Show (Split-Path $f -Leaf) 'missing'
    }
}

# The key name has a '.' segment, which the PowerShell registry provider drops, so use .NET.
$hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
$reg = $hklm.OpenSubKey('SOFTWARE\Microsoft\Provisioning\CSPs\.\Vendor\MSFT\Win32AppInventory')
Show 'CSP registered' $(if ($reg) { "yes ($($reg.GetValue('')))" } else { 'no' })

$marker = 'Request of deprecated flag: GAI_FLAG_APPLICATION_INFO'
$hasMarker = $false
if (Test-Path $aeinvDll) {
    $hasMarker = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($aeinvDll)).Contains($marker)
}
Show 'aeinv.dll has deprecated-flag code' $(if ($hasMarker) { 'yes' } else { 'no' })

if ($isAdmin) {
    try {
        $n = @(Get-CimInstance -ClassName Win32_InstalledWin32Program -ErrorAction Stop).Count
        Show 'WMI Win32_InstalledWin32Program' "$n items"
    } catch {
        Show 'WMI Win32_InstalledWin32Program' "error: $($_.Exception.Message)"
    }
} else {
    Show 'WMI Win32_InstalledWin32Program' 'skipped (run as Administrator to check)'
}

''
$changedBuild = ($build -in 26100, 26200, 26300) -and ($ubr -ge 9711)
if ($changedBuild) {
    'RESULT: likely affected. This PC is on KB5127648 or later.'
    'Your MDM server will most likely get a 404 for'
    '  ./Vendor/MSFT/Win32AppInventory/Win32InstalledProgram?list=StructData'
} elseif ($build -in 26100, 26200, 26300) {
    'RESULT: not affected yet. This PC is on a build before KB5127648.'
} else {
    'RESULT: unknown. This change was only seen on Windows 11 24H2/25H2/26H2 (builds 26100/26200/26300).'
}
'(Only a Get from your MDM server can confirm it.)'
''
