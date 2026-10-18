# DeepClean

**Cleans what Windows' own cleanup can't reach, and shows the space Windows hides from you.**

DeepClean is a single PowerShell script for Windows 10/11. It goes **below** Windows' own tools: system logs and traces, leftovers of deleted programs in the registry, orphaned installer files, superseded drivers, dead startup and right-click entries, and more. Everything is **previewed first**, nothing is deleted until you confirm, and registry changes are **backed up**.

- **System-only:** Windows and system locations, plus browser and app caches found by their folder structure. No per-app lists.
- **Leaves Windows' jobs to Windows:** Temp, Recycle Bin, Downloads, Windows Update cache and Windows.old are deliberately **not** touched. Use Windows' own Disk Cleanup or Storage Sense for those (`w` in the first question opens them).
- **Safe by design:** preview, then confirm; files in use are skipped; junctions are never followed; unplugged drives are never treated as "missing"; backups before any registry change.
- **Lightweight:** no installer, no service. Nothing is written to disk except what you approve: deletions, the safety backup, and an optional report.

---

## Run it

1. Download `DeepClean.ps1`.
2. Right-click it and choose **Run with PowerShell**, or open a terminal in its folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\DeepClean.ps1
```

Windows blocks downloaded scripts by default; this command runs it once **without changing any system setting**. DeepClean asks for Administrator rights itself. Some groups need them: system logs, installer files, drivers, WSL.

### Options

| Command | What it does |
|---|---|
| `.\DeepClean.ps1` | Interactive wizard (recommended) |
| `.\DeepClean.ps1 -Intensity Maximum` | Ignore age limits: remove every such file not in use |
| `.\DeepClean.ps1 -Defaults` | Accept the default answers, still shows the preview and asks before applying |
| `.\DeepClean.ps1 -Unattended` | No questions at all: defaults, applies everything, backs up, saves a report (for Task Scheduler, run elevated) |
| `.\DeepClean.ps1 -Detailed` | List every single file instead of one line per location |
| `.\DeepClean.ps1 -InstallerQuarantinePath D:\Quarantine` | **Move** orphaned installer files there instead of deleting them |
| `.\DeepClean.ps1 -LargeFileMB 500` | Size limit for the "largest files" report (default 1024) |

---

## How it works

1. **STEP 1/3: How old?** *Balanced* keeps recently used files (browser cache 7+ days, logs 30+ days…). *Maximum* removes any age, as long as it isn't in use.
2. **STEP 2/3: What to clean?** One short question per group. Type `?` for an explanation where offered.
3. **STEP 3/3: Preview.** Shows exactly what would be removed and how much space each group frees. Nothing is deleted yet.
4. **Apply** all, choose group by group, or cancel.

---

## What it cleans

| Group | What | Admin |
|---|---|---|
| **Browser & app web caches** | Every Chromium and Firefox-engine browser profile and every Electron / WebView2 app, found by folder structure. Running apps are skipped. Plus abandoned partial downloads. | – |
| **Deep system junk** | Windows logs (`C:\Windows\Logs`, `Debug`, `Panther`, update orchestrator, WMI traces, archived event logs), diagnostic / telemetry traces, temp and web caches of Windows' own service accounts, `SystemTemp`, LiveKernelReports dumps, failed-reset (`$SysReset`) and update-assistant leftovers, stuck print jobs, Store-app temp and web cache, RDP cache, crash dumps, OneDrive logs, graphics-driver installer leftovers and driver shader caches | partly |
| **Orphaned Windows Installer packages** | `.msi`/`.msp` copies in `C:\Windows\Installer` that no installed program uses any more (often GBs) | ✔ |
| **Superseded driver packages** | Old driver versions replaced by a newer one. Windows refuses to remove drivers in use. | ✔ |
| **Registry & system hygiene** | Entries pointing at deleted programs: Uninstall, App Paths, Run, startup on/off switches, MuiCache, compatibility records, "Open with" apps, SharedDLLs counters, fonts, right-click menu handlers, scheduled tasks, firewall rules. **All backed up to your Desktop first.** | partly |
| **Broken shortcuts** | Start Menu, Desktop, taskbar shortcuts whose target no longer exists | – |
| **WSL disk compaction** | Shrinks WSL virtual disks, which never shrink on their own | ✔ |
| **$PatchCache$** *(off by default)* | MSI update baseline copies | ✔ |
| **ResetBase** *(off by default)* | Makes installed updates permanent to free WinSxS space; they can no longer be uninstalled | ✔ |

## What it shows (never deletes)

- **Space Windows doesn't show you:** hibernation file, page file, reserved storage, System Restore storage, search index, with what each one is and how to change it yourself.
- **What starts with Windows:** startup apps **plus** the scheduled tasks and auto-start services Task Manager doesn't show, each marked on or off.
- **Leftover folders** of uninstalled apps, **largest files**, **services** pointing at missing programs.
- **Duplicate files** *(optional)*. Cloud-only OneDrive files are skipped so nothing gets downloaded.

---

## Undo / restore

Registry changes are exported to `DeepClean_Backup_<date>` on your Desktop before anything is removed:
- **Registry:** double-click a `.reg` file.
- **Scheduled tasks:** import the `.xml` in Task Scheduler.
- **Firewall:** `netsh advfirewall import "<backup>\firewall_policy.wfw"`

If any backup fails, that group is not touched at all.

## Will it make my PC faster?

Cleaning frees **storage**. It speeds Windows up mainly when the system drive is nearly full. The **startup report** is the part that helps speed: it shows everything that starts with Windows, so you can turn off what you don't need.

## Requirements

Windows 10 or 11 with Windows PowerShell 5.1, which is built in. When started from PowerShell 7, DeepClean hands over to 5.1 automatically.

## License

MIT. See [LICENSE](LICENSE).
