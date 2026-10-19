# Proposed fix for Microsoft

## The bug

`aeinv.dll` 10.0.26100.9711 (KB5127648) added the column `"SentDetailedInv" INTEGER` to the table
`InventoryApplication_0` in `C:\Windows\AppCompat\Programs\InventoryApplication.db`, after `"UserSid"`.

When the database already exists from an earlier build, `SqliteInvCache::CreateTable` compares the
existing table with the expected one, finds the column missing, and fails:

```
SqliteInvCache::CreateTable, 1966, Schema mismatch [0x80004005]
SqliteInvCache::Initialize, 838, CreateTable failed [0x80004005]
TelCacheProvider::Initialize, 638, SqliteInvCache::Initialize failed [0x80004005]
```

Nothing then changes the database, so the failure repeats on every call, forever. Every caller of
`GetAppInventory` that goes through this cache fails, including the Win32AppInventory CSP, which
answers 404 to `./Vendor/MSFT/Win32AppInventory/Win32InstalledProgram?list=StructData`.

The databases carry no schema version (`PRAGMA user_version` is 0), so the code can't tell an old
layout from a corrupted one.

## Suggested change

In `SqliteInvCache::CreateTable`, when the existing table doesn't match, migrate instead of failing.
It's a cache, so losing its contents is acceptable; failing permanently isn't.

```
existing = PRAGMA table_info(<table>)
expected = column list for this build

if existing == expected:
    use it
else if every existing column is in expected (only new columns are missing):
    BEGIN
      CREATE TABLE <table>_new (<expected columns, in order>)
      INSERT INTO <table>_new (<existing columns>) SELECT <existing columns> FROM <table>
      DROP TABLE <table>
      ALTER TABLE <table>_new RENAME TO <table>
    COMMIT
    (keeps the data, puts the new column where the new code expects it)
else:
    DROP TABLE <table>, CREATE TABLE <table> (<expected>), and reset LastScanTime in Metadata_0
    so the next run does a full scan
```

A plain `ALTER TABLE ... ADD COLUMN "SentDetailedInv" INTEGER` would only work if the comparison
ignores column order, because SQLite adds the column at the end.

Two smaller changes would stop this from happening again:

- Write a schema version to `PRAGMA user_version` and migrate by number on later changes.
- If the cache still can't be opened, delete and recreate the file rather than returning
  `0x80004005` on every call.

## Fix for PCs that already have the bug

Until an update carries the migration, renaming the database is enough: the next MDM sync makes
Windows create a new one with the right layout, and the CSP answers 200 again.
[Repair-Win32AppInventoryCache.ps1](Repair-Win32AppInventoryCache.ps1) does that safely (checks
first, renames all or nothing, deletes nothing). Tested on Windows 11 25H2, 26200.9711.

If the fix in `aeinv.dll` migrates the table as above, PCs that are already broken recover on their
own after the update, with no action needed.
