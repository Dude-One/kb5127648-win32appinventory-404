# Timeline

Both PCs are Windows 11 25H2 (build 26200), enrolled in the same MDM server, which sends this Get
every few minutes:

```
Get ./Vendor/MSFT/Win32AppInventory/Win32InstalledProgram?list=StructData
```

All times are UTC, October 13, 2026. They come from the server's own SyncML logs and, for the update
time, the Windows Update event log on the PC (System log, `WindowsUpdateClient` event 19).

## PC A

Build 26200.9457 before the update, 26200.9711 after.

| Time | What |
|---|---|
| 20:58:09 | Get answered: status 200, full program list |
| 21:12:59 | Server sends the Get |
| 21:13:09 | Status 200, 57 programs (about 122 KB of SyncML). Last good answer |
| 21:21:49 | KB5127648 installed |
| 21:28:00 | Server sends the same Get, byte for byte |
| 21:28:12 | Status 404, no Results. The other command in the same message (a Replace) returns 200 |
| 21:33:02, 21:38:02, ... | 404 every time |

The device's answer at 21:28:12, trimmed to the two status elements:

```xml
<Status><CmdID>4</CmdID><MsgRef>1</MsgRef><CmdRef>...</CmdRef><Cmd>Replace</Cmd><Data>200</Data></Status>
<Status><CmdID>5</CmdID><MsgRef>1</MsgRef><CmdRef>...</CmdRef><Cmd>Get</Cmd><Data>404</Data></Status>
```

Six days later (October 19) it is still the same: every session in the last 24 hours got a 404 on this
Get, and none returned data.

## PC B

Same build change, about an hour later.

| Time | What |
|---|---|
| 22:06:42 | Last answer with data |
| ~22:21 | KB5127648 installed |
| 22:21:38 | First 404 |

## Files the update replaced (PC A)

All within the same minute, while the update was being staged:

| File | Version after | Modified (UTC) |
|---|---|---|
| `System32\Win32AppInventoryCSP.dll` | 10.0.26100.9549 | 20:19:35 |
| `System32\invagent.dll` (WMI provider `InvProv`) | 10.0.26100.9549 | 20:19:35 |
| `InventorySvc.dll` | 10.0.26100.9549 | 20:19:30 |
| `aepic.dll` | 10.0.26100.9549 | 20:19:31 |
| `aeinv.dll` | **10.0.26100.9711** | 20:19:30 |

The Inventory and Compatibility Appraisal service (`InventorySvc`) is running normally afterwards.

## Same PC, after the update

Run as SYSTEM on October 19:

```
Win32_InstalledWin32Program: 25 items
Win32_InstalledStoreProgram: 134 items
```

So Windows still has the inventory. Only the CSP's answer is gone. (The WMI count is lower than the
CSP's 57 because the two sources filter differently. They aren't meant to match one to one.)
