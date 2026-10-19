# ETW trace: what Windows logs when the Get fails

The event logs show nothing for the failing Get, so I recorded an ETW trace on the affected PC
(26200.9711) while it ran an MDM sync. The script is
[Trace-Win32AppInventory.ps1](../Trace-Win32AppInventory.ps1). It uses only built-in tools:
`logman` for the trace and `tracerpt` to decode it.

Providers recorded, all at verbose level:

- `Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider`
- the OMA-DM client provider `{3B9602FF-E09B-4C6C-BC19-1A3DFA8F2250}`
- `Microsoft-Windows-Application-Experience`, where the inventory code (`aeinv.dll`) logs

The sync was started with the enrollment's own scheduled task ("Schedule #3 created by enrollment
client"), the same task Windows runs on its schedule. I ran two syncs, and both look the same.

Excerpt (enrollment id removed): [etw-excerpt.txt](etw-excerpt.txt)

## What it shows

The MDM client handles the Store inventory and the Win32 inventory one after the other, on the
same thread. Event IDs from the diagnostics provider: **402** = license check, **403** = CSP allow
check, **401** = the actual call into the CSP.

Store apps (works):

```
09:09:49.428  DM-Diag 402  ./Device/Vendor/MSFT/EnterpriseModernAppManagement/AppManagement/AppInventoryResults  OK
09:09:49.428  DM-Diag 403  ./Device/Vendor/MSFT/EnterpriseModernAppManagement/AppManagement/AppInventoryResults  OK
09:09:49.436  DM-Diag 401  EnterpriseModernAppManagement  GetValue  .../AppInventoryResults  OK
```

Win32 apps (fails):

```
09:09:49.453  DM-Diag 402  ./Vendor/MSFT/Win32AppInventory/Win32InstalledProgram  OK
09:09:49.453  DM-Diag 403  ./Vendor/MSFT/Win32AppInventory/Win32InstalledProgram  OK
09:09:49.460  AppExp  ERROR  Windows::Compat::Inventory::SqliteInvCache::CreateTable, line 1966, Schema mismatch [0x80004005]
09:09:49.460  AppExp  ERROR  Windows::Compat::Inventory::SqliteInvCache::Initialize, line 838, CreateTable failed [0x80004005]
09:09:49.460  AppExp  ERROR  TelCacheProvider::Initialize, line 638, SqliteInvCache::Initialize failed [0x80004005]
(the same three errors once more)
```

There is **no 401 for Win32AppInventory**. The license and allow checks pass, and 7 ms later
the inventory library fails to open its SQLite cache with "Schema mismatch". The CSP never gets to
return a value, and the server receives a 404.

## What I take from it

- The failure is inside Windows. It happens before anything from the MDM server is involved,
  apart from the request itself.
- The new `aeinv.dll` (10.0.26100.9711) keeps the inventory in a SQLite cache. On this PC that
  cache doesn't match the schema the new code expects, and the code doesn't recreate or migrate it.
  It looks like a cache written by the previous build that the update doesn't upgrade.
- Windows' general inventory still works through WMI (`Win32_InstalledWin32Program`), so the data
  exists. Only the path the CSP uses breaks.

A second trace found the cache file and the missing column, and rebuilding the cache fixed the CSP.
See [cache-schema.md](cache-schema.md).
