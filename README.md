# KB5127648 breaks the Win32AppInventory CSP (Get returns 404)

After the October 2026 cumulative update for Windows 11 (**KB5127648**, build **26200.9711**), Windows
stopped answering this MDM query:

```
Get ./Vendor/MSFT/Win32AppInventory/Win32InstalledProgram?list=StructData
```

Before the update it returned the full list of installed desktop programs. After it, the MDM client
answers with a bare **404** and no data, every time.

If your MDM product relies on this CSP for desktop app inventory, your Windows 11 devices on this
build will quietly stop reporting installed software. As far as I can tell Intune doesn't depend on
this CSP for desktop apps (its management extension reads WMI), which is probably why nobody has
written about this yet.

## What I saw

I work on Windows device management at Trio. Our server sends the Get above to every enrolled PC every
few minutes. On October 13 two of our test PCs installed KB5127648, and each one flipped from 200 to
404 at its first MDM session after the update:

| | Last answer with data | KB5127648 installed | First 404 |
|---|---|---|---|
| PC A | 21:13:09 UTC (57 programs) | 21:21:49 UTC | 21:28:12 UTC |
| PC B | 22:06:42 UTC | ~22:21 UTC | 22:21:38 UTC |

Both are still 404 six days later. Details in [evidence/timeline.md](evidence/timeline.md).

Things I ruled out:

- **The server.** The command is byte for byte the same before and after, it hasn't changed since
  July, and nothing was deployed that evening.
- **The rest of MDM.** Every other command in the same SyncML message still succeeds, including the
  Store/MSIX inventory (`EnterpriseModernAppManagement/AppManagement/AppInventoryQuery`) and the MSI
  status nodes under `EnterpriseDesktopAppManagement`.
- **Missing apps.** The programs are still installed and Windows still knows about them:
  `Win32_InstalledWin32Program` (WMI) still returns them, and the Uninstall registry keys are full.
- **A removed CSP.** It's still registered under
  `HKLM\SOFTWARE\Microsoft\Provisioning\CSPs\.\Vendor\MSFT\Win32AppInventory` and its DLL is there.
- **Logging.** Nothing about the failing Get shows up in the
  DeviceManagement-Enterprise-Diagnostics-Provider Admin or Operational logs.

## What Windows logs when it fails

The event logs are empty for this, so I recorded an ETW trace while the PC ran an MDM sync
([Trace-Win32AppInventory.ps1](Trace-Win32AppInventory.ps1), built-in `logman` and `tracerpt` only).
Full write-up in [evidence/etw-trace.md](evidence/etw-trace.md), raw excerpt in
[evidence/etw-excerpt.txt](evidence/etw-excerpt.txt).

The MDM client passes its license and allow checks for the node. Then, 7 ms later on the same thread,
the inventory code fails:

```
ERROR, Windows::Compat::Inventory::SqliteInvCache::CreateTable, 1966, Schema mismatch [0x80004005]
ERROR, Windows::Compat::Inventory::SqliteInvCache::Initialize, 838, CreateTable failed [0x80004005]
ERROR, TelCacheProvider::Initialize, 638, SqliteInvCache::Initialize failed [0x80004005]
```

The CSP is never actually called (no "CSP Node Operation" event, which the Store inventory right
before it does get), and the server receives a 404. So the inventory library's SQLite cache doesn't
match the schema the updated code expects, and nothing recreates it.

## What the DLLs show

I also looked at the DLLs on an affected PC (strings and import tables only). Full notes in
[evidence/dll-analysis.md](evidence/dll-analysis.md).

- `Win32AppInventoryCSP.dll` doesn't use WMI. It imports exactly two functions,
  `GetAppInventory` and `GetAppInfo2`, from **`aeinv.dll`**, and builds its answer from those.
- The update replaced the whole application inventory stack (`Win32AppInventoryCSP.dll`,
  `aeinv.dll`, `InventorySvc.dll`, `aepic.dll`, `invagent.dll`). Only **`aeinv.dll`** is at
  **10.0.26100.9711**, the version of this update itself. The others are at .9549.
- The new `aeinv.dll` has this inside `GetAppInventory`:

  ```
  Request of deprecated flag: GAI_FLAG_APPLICATION_INFO [%#x]
  Request of deprecated flag: GAI_FLAG_FILE_INFO [%#x]
  ```

  The new `aeinv.dll` also keeps the inventory in an embedded SQLite cache, which is the part that
  fails in the trace above.

Before the trace, my guess was the deprecated flags. The trace points at the SQLite cache instead.
Both live in the same rebuilt `aeinv.dll`.

## Am I affected?

Run [Test-Win32AppInventoryRegression.ps1](Test-Win32AppInventoryRegression.ps1) in PowerShell. It's
read-only. As Administrator it also counts what WMI sees.

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-Win32AppInventoryRegression.ps1
```

The only real test is the Get itself from your MDM server: a 404 on the node above means you're
affected. The script tells you if the PC is on a build that has the change.

KB5127648 ships the same build number for 24H2 (26100.9711), 25H2 (26200.9711) and 26H2 (26300.9711).
I've only seen it on 25H2.

## Workaround

There's no query I know of that brings the data back yet. If you run an MDM server:

- Don't treat the 404 as "no apps installed". Keep the last good inventory instead of wiping it.
- Get the software list another way on these builds: your own agent reading the Uninstall keys, or
  WMI `Win32_InstalledWin32Program` if you have code running on the device.

## Status

- 2026-10-13: first seen
- 2026-10-19: reported to Microsoft through Feedback Hub (link to be added)

I'll update this when Microsoft responds or a later update fixes it. If you're seeing the same thing,
open an issue with your build number so we can see how widespread it is.

Amin Khabbazi
