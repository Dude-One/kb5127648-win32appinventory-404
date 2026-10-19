# What the DLLs show

Everything here comes from reading the files on an affected PC (26200.9711): printable strings and
the PE import/export tables. Nothing was run, patched or disassembled.

## The CSP

`C:\Windows\System32\Win32AppInventoryCSP.dll`, 10.0.26100.9549, signed by Microsoft.

Registered as:

```
HKLM\SOFTWARE\Microsoft\Provisioning\CSPs\.\Vendor\MSFT\Win32AppInventory
    (default) = {B4463941-6512-4B2D-A54E-107DD721B4E1}
HKLM\SOFTWARE\Classes\CLSID\{B4463941-6512-4B2D-A54E-107DD721B4E1}\InprocServer32
    (default) = C:\WINDOWS\system32\Win32AppInventoryCSP.dll
```

Note the `.` in the key path. PowerShell's registry provider drops it, so read it with
`[Microsoft.Win32.RegistryKey]` instead of `Get-Item`.

Apart from the C runtime, ntdll and kernel32, its only real dependency is:

```
AEINV.dll: GetAppInfo2, GetAppInventory
```

So it doesn't go through WMI. It asks `aeinv.dll` for the inventory and turns it into OMA-DM nodes.

Strings worth noting:

```
GetAppInventory failed [%#x]
Failed to get Program Id from URI [%#x]
Failed to get segment count of query URI [%#x]
CWin32AppInventoryNode::GetChildNodeNames
CWin32AppInventoryNode::GetValue
Win32InstalledProgram
InventoryApplication
AddRemoveProgram
AddRemoveProgramPerUser
AppvPackage
RtlQueryFeatureConfiguration
```

It writes errors through ETW/debug output, not the event log. That matches the empty MDM event logs.

## aeinv.dll

`C:\Windows\System32\aeinv.dll`, **10.0.26100.9711**, the version of KB5127648 itself. The other
inventory DLLs the update replaced carry .9549.

Exports:

```
CreateAppxPackageInventory, CreateAppxPackageInventoryExtracted, CreateSoftwareInventory,
GetAppInfo, GetAppInfo2, GetAppInventory, GetApplicationKBsTC2, GetCachedAppInventory,
GetDetailedAppInventory, GetDetailedAppInventoryFile, GetDetailedAppInventoryOrphanFile,
UpdateSoftwareInventoryW, UpdateSoftwareInventoryWTCEx
```

It reads the compatibility inventory (`AppCompat\Programs\Amcache.hve`, `Root\InventoryApplication`).

The interesting part is in `GetAppInventory`:

```
onecore\internal\base\inc\appcompat\inventory\GetAppInventory.cpp
Request of deprecated flag: GAI_FLAG_APPLICATION_INFO [%#x]
Request of deprecated flag: GAI_FLAG_FILE_INFO [%#x]
Someone's using GetAppInfo [%#x]
```

It also has an embedded SQLite cache (`SqliteInvCache`, `TelCacheProvider`, "Using SQLite cache
provider: %ls") next to the older `AepicInvCache`.

## What this does and doesn't show

The strings show what code is in the new `aeinv.dll`, not which path the CSP takes. The ETW trace
([etw-trace.md](etw-trace.md)) answers that: the failure is the SQLite cache's "Schema mismatch",
not the deprecated flags. Comparing against the 26200.9457 versions of both DLLs would still be
useful. If you have a PC still on that build, I'd love the comparison.
