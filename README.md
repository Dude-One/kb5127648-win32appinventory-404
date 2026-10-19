# KB5127648 breaks the Win32AppInventory CSP (Get returns 404)

After the October 2026 cumulative update for Windows 11 (**KB5127648**, build **26200.9711**), this MDM
query stopped working:

```
Get ./Vendor/MSFT/Win32AppInventory/Win32InstalledProgram?list=StructData
```

Before the update it returned every installed desktop program. After it, the device answers **404**
with no data, on every sync.

- **Cause:** the update added a column, `SentDetailedInv`, to Windows' installed-programs cache
  `C:\Windows\AppCompat\Programs\InventoryApplication.db`, but it doesn't migrate a cache that already
  exists. The new code finds the old table, logs `Schema mismatch` and gives up, and the CSP answers 404.
- **Fix on a device:** rename that file and run an MDM sync. Windows rebuilds it with the new table and
  the Get answers 200 again. Tested, see below.
- **Not fixed for good:** every PC that had the cache before the update needs this once, until
  Microsoft ships a migration.

If your MDM product uses this CSP for desktop app inventory, your devices on this build quietly stop
reporting installed software. Intune reads desktop apps through its own agent and WMI, which is
probably why this hasn't come up yet.

## Check it yourself

All three steps need an elevated PowerShell on an MDM-enrolled PC with KB5127648, in a copy of this
repo:

```powershell
git clone https://github.com/Dude-One/kb5127648-win32appinventory-404
cd kb5127648-win32appinventory-404
```

(or Code > Download ZIP and extract it). Every script has help: `Get-Help .\<script>.ps1 -Full`.

**1. Is the cache on the old layout?** (read-only)

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-Win32AppInventoryRegression.ps1
```

On an affected PC:

```
aeinv.dll                      10.0.26100.9711 (expects SentDetailedInv)
InventoryApplication.db        ... bytes, last written <before the update> UTC
Cache table                    OLD layout (no SentDetailedInv)

RESULT: AFFECTED. The updated inventory code rejects this cache, so the CSP answers 404.
```

Look at the "last written" time too: on an affected PC it stops at the moment the update installed.

**2. What does Windows log when the Get fails?** (ETW, built-in `logman` and `tracerpt` only)

```powershell
powershell -ExecutionPolicy Bypass -File .\Trace-Win32AppInventory.ps1
```

It starts a trace, triggers an MDM sync, waits 4 minutes and decodes the trace into `C:\Temp\poc\`.
Search the decoded `mdm.csv` for the errors:

```powershell
Select-String -Path C:\Temp\poc\mdm.csv -Pattern 'Schema mismatch|CreateTable failed|SqliteInvCache::Initialize'
```

On an affected PC, right after the MDM client's license (402) and allow (403) checks for
`./Vendor/MSFT/Win32AppInventory/Win32InstalledProgram`, on the same thread:

```
ERROR, Windows::Compat::Inventory::SqliteInvCache::CreateTable,1966,Schema mismatch [0x80004005]
ERROR, Windows::Compat::Inventory::SqliteInvCache::Initialize,838,CreateTable failed [0x80004005]
ERROR, TelCacheProvider::Initialize,638,SqliteInvCache::Initialize failed [0x80004005]
```

and no 401 (CSP Node Operation) for that node. The Store inventory node just before it gets its 401
and succeeds.

**3. Rebuild the cache and check again**

```powershell
powershell -ExecutionPolicy Bypass -File .\Rename-InventoryCache.ps1
Get-Content C:\Temp\poc3\rename-test.txt
```

It renames `InventoryApplication.db*` to `*.bak-test` (nothing is deleted), runs two MDM syncs and logs
the old and new table. Then run step 1 again: `Cache table` now says `new layout`, and your MDM server
gets 200 for the Get.

## What I saw

I work on Windows device management at Trio. Our server sends this Get to every enrolled PC every few
minutes. On October 13 two test PCs installed KB5127648, and each flipped to 404 at its first MDM
session after the update:

| | Last answer with data | KB5127648 installed | First 404 |
|---|---|---|---|
| PC A | 21:13:09 UTC (57 programs) | 21:21:49 UTC | 21:28:12 UTC |
| PC B | 22:06:42 UTC | ~22:21 UTC | 22:21:38 UTC |

Ruled out: our server (the command is byte for byte the same since July, nothing deployed that day),
the rest of MDM (every other command in the same SyncML message still succeeds, including the Store
inventory), missing apps (WMI `Win32_InstalledWin32Program` and the Uninstall keys still list them),
and a removed CSP (still registered, DLL present). The event logs show nothing.
Timeline: [evidence/timeline.md](evidence/timeline.md).

## Root cause

`Win32AppInventoryCSP.dll` gets its data from `aeinv.dll` (`GetAppInventory`, `GetAppInfo2`). KB5127648
replaced `aeinv.dll` with **10.0.26100.9711**, and that version keeps the inventory in SQLite databases
under `C:\Windows\AppCompat\Programs\`. The one for installed programs is `InventoryApplication.db`.

On PC A that file was last written at 21:13:06 UTC on October 13, 3 seconds before the last good answer
and 8 minutes before the update finished, and never again. The other inventory databases next to it
kept updating. Its table is one column short of what the new code creates:

```
old (previous build):          ... "UserSid" TEXT, "Source" TEXT, ...
new (aeinv.dll 10.0.26100.9711): ... "UserSid" TEXT, "SentDetailedInv" INTEGER, "Source" TEXT, ...
```

Everything else in the table is identical. The new code compares the table, logs `Schema mismatch`
and returns an error instead of adding the column or recreating the table. So the cache never
changes, and the CSP fails on every request.

Proof: renaming the file on PC A made Windows recreate it with the new table, and the Get came back:

| Session (UTC, Oct 19) | Status | Programs |
|---|---|---|
| 09:22:04, 09:22:18, 09:27:04 | 404 | 0 |
| *09:27:08 cache renamed, 09:28:51 rebuilt by Windows* | | |
| 09:28:57 | **200** | **58** |
| 09:42:12 (next scheduled Get) | **200** | **58** |

Details: [evidence/etw-trace.md](evidence/etw-trace.md), [evidence/etw-excerpt.txt](evidence/etw-excerpt.txt),
[evidence/cache-schema.md](evidence/cache-schema.md), [evidence/dll-analysis.md](evidence/dll-analysis.md).

## Fix

### On an affected device (tested)

[Repair-Win32AppInventoryCache.ps1](Repair-Win32AppInventoryCache.ps1), as Administrator or SYSTEM:

```powershell
powershell -ExecutionPolicy Bypass -File .\Repair-Win32AppInventoryCache.ps1
```

```
AFFECTED: InventoryApplication.db has the old layout (no SentDetailedInv) and aeinv.dll is 10.0.26100.9711.
Renamed InventoryApplication.db to InventoryApplication.db.old-20261019-133905
MDM sync started, waiting for Windows to rebuild the cache...
FIXED: Windows rebuilt InventoryApplication.db with the new layout.
```

It only acts when the PC has the updated `aeinv.dll` and the old table, so it's safe to run on every
PC and more than once. It renames the cache files all or nothing (if one is locked it puts everything
back and changes nothing), deletes nothing, then starts an MDM sync and waits for Windows to rebuild the
cache. `-DetectOnly` just reports. Exit code 0 means not affected or fixed, 1 means affected or failed.

Or by hand:

```powershell
Get-ChildItem C:\Windows\AppCompat\Programs -Force -Filter 'InventoryApplication.db*' |
    Rename-Item -NewName { $_.Name + '.old' }
```

then trigger an MDM sync, or wait for the next one. On PC A the Get answered 200 right after the
rebuild and stayed fixed on the following scheduled syncs. The rebuilt cache had the same 58
programs. Still, test on one machine first and keep the `.old` files for a while.

### For a fleet

The device doesn't fix itself, and plain OMA-DM has no CSP that can rename this file, so the rename
has to run through something that executes code on the device:

- your own agent, if you have one;
- Intune Remediations or any script runner: the repair script with `-DetectOnly` (or `$DetectOnly`
  defaulting to `$true` in the copy you upload) as detection, unchanged as remediation;
- a one-time scheduled task pushed by your existing tooling.

On the server side, until devices are fixed:

- Don't treat this 404 as "no apps installed". Keep the last good inventory instead of wiping it.
- Get the list another way on these builds: your agent reading the Uninstall keys, or WMI
  `Win32_InstalledWin32Program`.

### What Microsoft needs to fix

The real fix is in `aeinv.dll`: when the table is an older layout, migrate it (copy it into a table
with the new layout) or drop and rebuild it, since it's rebuildable data anyway. Either would make
every affected PC recover on its own after the update. The change I'm suggesting, with the steps, is
in [PROPOSED-FIX.md](PROPOSED-FIX.md).

I haven't tried adding the column by hand. The new code puts it in the middle of the table and
`ALTER TABLE` can only add it at the end, so the check may still fail. Renaming the file is the tested
route.

### Is it fully solved?

- **Root cause:** yes. The failing check, the missing column and the rebuild that fixes it are all shown
  above on the same PC.
- **On a device:** yes, the rename fixes it and it stays fixed.
- **For good:** no. Every PC that had the cache before KB5127648 hits this, and stays broken until
  someone renames the file or Microsoft adds the migration.
- **Not proven yet:** I've rebuilt the cache on one PC (25H2). PC B shows the same 404 but I haven't
  checked its cache. KB5127648 also ships 26100.9711 (24H2) and 26300.9711 (26H2), which I haven't
  tested. Why some PCs might not be affected (for example a fresh install after the update) is a guess.

If you're seeing this, open an issue with your build number and the output of step 1.

## Status

- 2026-10-13: first seen
- 2026-10-19: root cause found and the cache rebuild confirmed as a fix on the affected PC
- 2026-10-19: reported to Microsoft through Feedback Hub (link to be added)

I'll update this when Microsoft responds or a later update fixes it.

Amin Khabbazi, thanks to [Opus 5.5](https://www.anthropic.com/claude)
