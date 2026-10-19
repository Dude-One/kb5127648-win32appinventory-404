# The cache that breaks it

## Where it is

A second ETW trace, this time of file opens (`Microsoft-Windows-Kernel-File`) during an MDM sync,
showed which files the failing process opens. It's the inventory cache in:

```
C:\Windows\AppCompat\Programs\InventoryApplication.db        <- installed programs
C:\Windows\AppCompat\Programs\InventoryApplicationFile.db
C:\Windows\AppCompat\Programs\InventoryApplicationShortcut.db
C:\Windows\AppCompat\Programs\InventoryApplicationFramework.db
C:\Windows\AppCompat\Programs\InventoryApplicationAppV.db
```

They're plain SQLite 3 databases (SQLite 3.43.0, `user_version` 0), all created in August 2026 by the
build before KB5127648.

## The one that stopped

On the affected PC, `InventoryApplication.db` was last written at **2026-10-13 21:13:06 UTC**. That's 3
seconds before the last good MDM answer (21:13:09) and 8 minutes before KB5127648 finished installing
(21:21:49). It never changed after that. The other four databases kept being updated every day.

## Old table vs new table

What the cache had (created by the previous build):

```sql
CREATE TABLE InventoryApplication_0 (ItemKey TEXT PRIMARY KEY, "ProgramId" TEXT UNIQUE,
  "ProgramInstanceId" TEXT, "Name" TEXT, "Version" TEXT, "Publisher" TEXT, "Language" INTEGER,
  "InstallDate" TEXT, "UserSid" TEXT, "Source" TEXT, "StoreAppType" TEXT, "PackageFullName" TEXT,
  "InboxModernApp" INTEGER, "ManifestPath" TEXT, "BundleManifestPath" TEXT, "HiddenArp" INTEGER,
  "RootDirPath" TEXT, "UninstallString" TEXT, "RegistryKeyPath" TEXT, "MsiPackageCode" TEXT,
  "MsiProductCode" TEXT, "MsiInstallDate" TEXT, "Type" TEXT, "LastModified" INTEGER DEFAULT 0)
```

What the updated `aeinv.dll` (10.0.26100.9711) creates when there's no cache:

```sql
CREATE TABLE InventoryApplication_0 (ItemKey TEXT PRIMARY KEY, "ProgramId" TEXT UNIQUE,
  "ProgramInstanceId" TEXT, "Name" TEXT, "Version" TEXT, "Publisher" TEXT, "Language" INTEGER,
  "InstallDate" TEXT, "UserSid" TEXT, "SentDetailedInv" INTEGER, "Source" TEXT, "StoreAppType" TEXT,
  "PackageFullName" TEXT, "InboxModernApp" INTEGER, "ManifestPath" TEXT, "BundleManifestPath" TEXT,
  "HiddenArp" INTEGER, "RootDirPath" TEXT, "UninstallString" TEXT, "RegistryKeyPath" TEXT,
  "MsiPackageCode" TEXT, "MsiProductCode" TEXT, "MsiInstallDate" TEXT, "Type" TEXT,
  "LastModified" INTEGER DEFAULT 0)
```

The only difference is one new column, **`"SentDetailedInv" INTEGER`**, after `UserSid`. The updated
code checks the existing table, sees it doesn't match, logs "Schema mismatch" and gives up. It never
adds the column or rebuilds the table, so the cache stays on the old layout for good and the CSP
fails every time.

## Rename test

On the affected PC (2026-10-19), as an administrator:

1. Renamed `InventoryApplication.db` to `InventoryApplication.db.bak-test`, nothing deleted.
2. Started an MDM sync through the enrollment's own scheduled task, then a second one.
3. Windows created a fresh `InventoryApplication.db` (09:28:51 UTC) with the new table above.

What the MDM server got from that PC for the same Get:

| Session (UTC) | Status | Programs |
|---|---|---|
| 09:22:04, 09:22:18, 09:27:04 | 404 | 0 |
| *09:27:08 cache renamed, 09:28:51 rebuilt by Windows* | | |
| 09:28:57 | **200** | **58** |
| 09:42:12 (next scheduled Get) | **200** | **58** |

That's the first good answer since October 13, and the same size as before the update. It stayed
fixed on the next scheduled Get as well.

Script used: [Rename-InventoryCache.ps1](../Rename-InventoryCache.ps1).
