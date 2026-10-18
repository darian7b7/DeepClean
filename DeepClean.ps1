<#
.SYNOPSIS
    DeepClean v1.0 - cleans what Windows' own tools never touch.

.DESCRIPTION
    Safe flow (wizard -> full PREVIEW -> confirm -> real run ->
    optional log), built around one rule: if Windows' own cleanup
    already does it, this script does NOT. Everything here is something
    Windows leaves behind forever.

    DELIBERATELY NOT HANDLED (Windows does these itself):
      User/System Temp, Recycle Bin, Downloads aging, Windows Update cache,
      Delivery Optimization, thumbnail cache, DirectX shader cache (D3DSCache),
      WER error reports, memory dumps, Windows.old / $Windows.~BT, Prefetch,
      Font cache, regular WinSxS StartComponentCleanup, Defender quarantine.

    CLEANUP GROUPS (each previewed, then approved per group) - Windows and
    system locations only; no per-app lists:
      Browser & app web caches   Every Chromium and Firefox-engine browser
                                 profile and every Electron / WebView2 app,
                                 found by their folder structure (nothing is
                                 hard-coded). Running apps are detected via
                                 their profile lock and skipped. Plus
                                 abandoned partial downloads in your folders.
      Deep system junk           Windows logs (C:\Windows\Logs, Debug, setup /
                                 Panther, update orchestrator, WMI traces,
                                 archived event logs), diagnostic/telemetry
                                 traces, temp and web caches of Windows' own
                                 service accounts, SystemTemp, LiveKernelReports
                                 dumps, failed-reset and update-assistant
                                 leftovers, stuck print jobs, Store-app temp and
                                 web cache, RDP cache, crash dumps, OneDrive
                                 logs, graphics-driver installer leftovers and
                                 driver shader caches
      Orphaned Installer files   .msi/.msp in C:\Windows\Installer that no
                                 installed product references (often GBs)
      Superseded drivers         Older DriverStore versions of drivers that
                                 have a newer version installed (pnputil
                                 refuses in-use drivers, so those stay)
      Registry & hygiene         Entries pointing at deleted programs: Uninstall,
                                 App Paths, Run, StartupApproved, MuiCache,
                                 compatibility records, "Open with" apps,
                                 SharedDLLs, fonts, right-click menu handlers,
                                 scheduled tasks and firewall rules (all backed
                                 up first)
      Broken shortcuts           Start Menu, Desktop, taskbar
      WSL disk compaction        .vhdx disks never shrink on their own
      $PatchCache$  (opt-in)     MSI baseline cache
      WinSxS ResetBase (opt-in)  Goes beyond Windows' own component cleanup

    INSIGHT REPORTS (never delete anything): leftover folders from uninstalled
    apps, largest files, everything that starts with Windows (incl. tasks and
    services Task Manager doesn't show), services pointing at missing programs,
    space Windows doesn't show you (hibernation file, page file, reserved
    storage, restore points, search index), and (opt-in) duplicate files.

    SAFETY:
      - Paths on drives that are missing / removable / network are treated as
        "unknown", never as "missing" - unplugging a USB drive will not make
        its shortcuts, tasks or registry entries look orphaned.
      - Reparse points (junctions/symlinks) are never followed.
      - Registry, scheduled tasks and firewall are exported before changes;
        if any backup fails, that group is not touched.

.PARAMETER Intensity
    Only sets how old cache, temp and log files must be; which groups are
    cleaned is chosen separately.
    Balanced (default): age/size thresholds keep recently used files.
    Maximum: ignores thresholds - every such file not in use is removed.

.PARAMETER Defaults
    Accept the wizard defaults without asking (still previews + confirms).

.PARAMETER Unattended
    No prompts at all: defaults, apply every group, back up, save log.
    Useful from Task Scheduler (run elevated).

.PARAMETER Detailed
    Log every single file instead of one line per location.

.PARAMETER InstallerQuarantinePath
    If set, orphaned Windows Installer files are MOVED here (ideally another
    drive) instead of deleted.

.EXAMPLE
    .\DeepClean.ps1
.EXAMPLE
    .\DeepClean.ps1 -Intensity Maximum
.EXAMPLE
    .\DeepClean.ps1 -Unattended

.NOTES
    HOW TO RUN: right-click DeepClean.ps1 > "Run with PowerShell", or in a terminal:
        powershell -ExecutionPolicy Bypass -File .\DeepClean.ps1
    Windows blocks downloaded scripts by default; the command above runs it once
    without changing any system setting. It asks for Administrator rights itself.
    Requires Windows 10/11. Nothing is deleted before you have seen a preview and
    confirmed it.
#>

[CmdletBinding()]
param(
    [ValidateSet('Balanced', 'Maximum')]
    [string]$Intensity,
    [switch]$Defaults,
    [switch]$Unattended,
    [switch]$Detailed,
    [int]$GlobalMinBenefitMB = 200,
    [int]$LargeFileMB = 1024,
    [string]$InstallerQuarantinePath,
    [string]$LogPath = "$([Environment]::GetFolderPath('Desktop'))\DeepClean_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
if ($Unattended) { $Defaults = $true }

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ==========================================
# LOGGING / PROMPTS
# ==========================================

$script:LogBuffer = [System.Collections.Generic.List[string]]::new()

function Write-Log {
    param([string]$Message, [string]$Color = "Gray")
    Write-Host $Message -ForegroundColor $Color
    $script:LogBuffer.Add($Message)
}

function Write-Detail {
    param([string]$Message, [string]$Color = "DarkGray")
    if ($Detailed) { Write-Log $Message $Color }
}

# Asks one question. Each choice is @(key, label, color); the default is shown as
# "Enter = label", the others as "key = label", and '? = explain' when Help exists.
function Read-Choice {
    param([string]$Prompt, [object[]]$Choices, [string]$Default, [string[]]$Help)
    if ($Unattended) { return $Default }
    $shown = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $Choices) { if ($c[0] -eq $Default) { $shown.Add(@("Enter = $($c[1])", $c[2])) } }
    foreach ($c in $Choices) { if ($c[0] -ne $Default) { $shown.Add(@("$($c[0]) = $($c[1])", $c[2])) } }
    # Only the '?' itself is colored; its label stays plain.
    if ($Help) { $shown.Add(@('?', 'Cyan', ' = explain')) }
    while ($true) {
        Write-Host $Prompt -NoNewline -ForegroundColor White
        Write-Host ' [' -NoNewline -ForegroundColor DarkGray
        for ($i = 0; $i -lt $shown.Count; $i++) {
            if ($i -gt 0) { Write-Host ', ' -NoNewline -ForegroundColor DarkGray }
            Write-Host $shown[$i][0] -NoNewline -ForegroundColor $shown[$i][1]
            if ($shown[$i].Count -gt 2) { Write-Host $shown[$i][2] -NoNewline }
        }
        Write-Host ']: ' -NoNewline -ForegroundColor DarkGray
        $resp = ([string](Read-Host)).Trim().ToLower()
        if (-not $resp) { return $Default }
        if ($Help -and $resp -eq '?') {
            Write-Host ""
            foreach ($line in $Help) { Write-Host "    $line" }
            Write-Host ""
            continue
        }
        foreach ($c in $Choices) { if ($resp -eq $c[0] -or $resp -eq $c[1].ToLower()) { return $c[0] } }
        Write-Host "  Please press Enter or type one of the letters shown in the brackets." -ForegroundColor Yellow
    }
}

function Read-YesNo {
    param([string]$Prompt, [string]$Default = 'Y', [string[]]$Help)
    $choices = @(@('y', 'yes', 'Green'), @('n', 'no', 'Red'))
    return (Read-Choice -Prompt $Prompt -Choices $choices -Default $Default.ToLower() -Help $Help) -eq 'y'
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

# Drawing characters are built at runtime so this file stays plain ASCII
# (Windows PowerShell 5.1 misreads non-ASCII text in files without a BOM).
$Bar = [string][char]0x2588; $Shade = [string][char]0x2591; $Dot = [string][char]0x00B7
$Arrow = [string][char]0x25B8; $Rule = [string][char]0x2500 * 52

# A size bar for summaries: Value relative to Max, Width characters wide.
function Format-Bar {
    param([double]$Value, [double]$Max, [int]$Width = 16)
    $n = if ($Max -gt 0) { [int][math]::Round([math]::Min(1.0, $Value / $Max) * $Width) } else { 0 }
    if ($Value -gt 0 -and $n -eq 0) { $n = 1 }
    return ($Bar * $n) + ($Shade * ($Width - $n))
}

function Write-Step {
    param([int]$Number, [string]$Title)
    Write-Host ""
    Write-Host " STEP $Number/3 " -NoNewline -ForegroundColor Black -BackgroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
}

# ==========================================
# STATE
# ==========================================

$script:DryRun           = $true
$script:DoRegistryBackup = $true
$script:Max              = $false
$script:Selected         = @{}
$script:Approved         = [System.Collections.Generic.HashSet[string]]::new()
$script:ProfileScan      = $null
$script:ChromiumProfiles = $null
# In-memory results from the preview, reused by the real run (never written to disk).
$script:StaleCache       = @{}
$script:InstallerRefs    = $null
$script:DriverList       = $null
$script:HygieneScan      = $null
$script:BrokenShortcuts  = $null
$script:RunningProcesses = $null

function Reset-Stats {
    $script:Removed         = 0
    $script:Skipped         = 0
    $script:BytesFreed      = [int64]0
    $script:EmptyFolders    = 0
    $script:CategoryTotals  = @{}
    $script:GroupBytes      = @{}
    $script:GroupPending    = @{}
    $script:CurrentGroup    = ''
    $script:Claimed         = [System.Collections.Generic.List[string]]::new()
}

function Add-Freed {
    param([int64]$Bytes, [string]$Category, [int]$Count = 1)
    if ($Bytes -lt 0) { $Bytes = 0 }
    $script:Removed    += $Count
    $script:BytesFreed += $Bytes
    if (-not $script:CategoryTotals.ContainsKey($Category)) { $script:CategoryTotals[$Category] = [int64]0 }
    $script:CategoryTotals[$Category] += $Bytes
    $g = $script:CurrentGroup
    if (-not $script:GroupBytes.ContainsKey($g)) { $script:GroupBytes[$g] = [int64]0 }
    $script:GroupBytes[$g] += $Bytes
}

# Non-byte work (registry entries, disks to compact, ...) so a group with
# nothing measurable in bytes still shows up for approval.
function Add-Pending {
    param([int]$Count = 1)
    $g = $script:CurrentGroup
    if (-not $script:GroupPending.ContainsKey($g)) { $script:GroupPending[$g] = 0 }
    $script:GroupPending[$g] += $Count
}

# Folders Windows recreates as scaffolding - never prune them even when empty.
$ProtectedEmptyFolderNames = @("SharedFileCache")

# ==========================================
# FILESYSTEM HELPERS
# ==========================================

function Test-Reparse {
    param([string]$Path)
    try { return [bool]([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) } catch { return $true }
}

# Every folder under Root, Root first and each parent before its children. Never
# follows junctions/symlinks and survives access-denied subfolders (Get-ChildItem
# -Recurse in PS 5.1 does neither well).
function Get-DirsSafe {
    param([string]$Root)
    $out = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
    if (-not [IO.Directory]::Exists($Root)) { return , $out }
    $stack = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $stack.Push([System.IO.DirectoryInfo]::new($Root))
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        $out.Add($d)
        try {
            foreach ($sub in $d.EnumerateDirectories()) {
                if (-not ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($sub) }
            }
        } catch {}
    }
    return , $out
}

function Get-FilesSafe {
    param([string]$Root, [string]$Pattern = '*', [switch]$NoRecurse)
    $out = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $dirs = Get-DirsSafe $Root
    if ($NoRecurse -and $dirs.Count -gt 1) { $dirs.RemoveRange(1, $dirs.Count - 1) }
    foreach ($d in $dirs) {
        try { foreach ($f in $d.EnumerateFiles($Pattern)) { $out.Add($f) } } catch {}
    }
    return , $out
}

# Size and age of a tree without keeping FileInfo objects around:
# returns @(totalBytes, newestWriteUtc, newestUseUtc).
function Measure-Tree {
    param([string]$Root)
    $size = [int64]0; $newestWrite = [datetime]::MinValue; $newestUsed = [datetime]::MinValue
    foreach ($d in (Get-DirsSafe $Root)) {
        try {
            foreach ($f in $d.EnumerateFiles()) {
                $size += $f.Length
                $w = $f.LastWriteTimeUtc; $a = $f.LastAccessTimeUtc
                if ($w -gt $newestWrite) { $newestWrite = $w }
                if ($a -gt $w) { $w = $a }
                if ($w -gt $newestUsed) { $newestUsed = $w }
            }
        } catch {}
    }
    return @($size, $newestWrite, $newestUsed)
}

function Get-FolderSize {
    param([string]$Path)
    return (Measure-Tree $Path)[0]
}

function Remove-EmptySubdirs {
    param([string]$Root, [switch]$IncludeRoot)
    $dirs = Get-DirsSafe $Root
    if ($dirs.Count -eq 0) { return }
    if (-not $IncludeRoot) { $dirs.RemoveAt(0) }
    # Parents come before children, so reversed order empties the deepest folders first.
    $dirs.Reverse()
    foreach ($d in $dirs) {
        if ($ProtectedEmptyFolderNames -contains $d.Name) { continue }
        # Non-recursive delete fails on non-empty folders, which is exactly what we want.
        try {
            if ($d.Attributes -band [IO.FileAttributes]::ReadOnly) { $d.Attributes = $d.Attributes -bxor [IO.FileAttributes]::ReadOnly }
            $d.Delete($false); $script:EmptyFolders++
        } catch {}
    }
}

function Remove-FileQuiet {
    param([System.IO.FileInfo]$File)
    try {
        if ($File.IsReadOnly) { $File.IsReadOnly = $false }
        $File.Delete()
        return $true
    } catch { return $false }
}

function Resolve-TargetPaths {
    param([string[]]$Paths)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $Paths) {
        if (-not $p) { continue }
        if ($p -match '[\*\?]') {
            Get-Item -Path $p -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.PSIsContainer } | ForEach-Object { $out.Add($_.FullName) }
        } elseif ([IO.Directory]::Exists($p)) {
            $out.Add($p)
        }
    }
    return , $out
}

# Prevents two targets from cleaning (and double-counting) overlapping folders.
function Register-CleanRoot {
    param([string]$Path)
    $p = $Path.TrimEnd('\') + '\'
    foreach ($c in $script:Claimed) {
        if ($p.StartsWith($c, [StringComparison]::OrdinalIgnoreCase) -or $c.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    $script:Claimed.Add($p)
    return $true
}

# A path only counts as "missing" if its drive is a present, ready, fixed
# disk. Anything on an unplugged USB / network drive is "unknown" -> kept.
function Test-Missing {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -notmatch '^([A-Za-z]):\\') { return $false }
    $letter = $matches[1].ToUpper()
    $ok = $script:FixedDrives[$letter]
    if ($null -eq $ok) {
        $ok = $false
        try {
            $di = [IO.DriveInfo]::new("${letter}:\")
            $ok = $di.IsReady -and $di.DriveType -eq [IO.DriveType]::Fixed
        } catch {}
        $script:FixedDrives[$letter] = $ok
    }
    if (-not $ok) { return $false }
    return -not ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path))
}
$script:FixedDrives = @{}

# Program a command line starts: the quoted part, or everything up to the first
# matching extension; environment variables expanded.
function Get-CommandTarget {
    param([string]$Command, [string]$Extensions = 'exe')
    $p = ($Command -replace '^"([^"]+)".*$', '$1').Trim()
    if ($p -notmatch '^"' -and $p -match "^(.+?\.($Extensions))\b") { $p = $matches[1] }
    return [Environment]::ExpandEnvironmentVariables($p)
}

function Test-FileLocked {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $false }
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $fs.Close()
        return $false
    } catch { return $true }
}

# One process snapshot per group instead of a Get-Process call per name.
function Update-RunningProcesses {
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in [Diagnostics.Process]::GetProcesses()) { [void]$set.Add($p.ProcessName); $p.Dispose() }
    $script:RunningProcesses = $set
}

function Get-RunningProcess {
    param([string[]]$Names)
    foreach ($n in $Names) {
        if ($script:RunningProcesses.Contains($n)) { return $n }
    }
    return $null
}

function Test-SkipRunning {
    param([string[]]$Processes, [string]$Category)
    $running = Get-RunningProcess $Processes
    if ($running) { Write-Log ("  {0,-38} skipped - '{1}' is running (close it to clean this)" -f $Category, $running) "Yellow" }
    return [bool]$running
}

function Get-EffectiveAge {
    param([int]$Days, [int]$Floor = 0)
    if ($script:Max) { return $Floor }
    return [math]::Max($Days, $Floor)
}

# ==========================================
# CORE CLEAN ENGINES
# ==========================================

# File-level: removes files idle >= MinAgeDays, but only if the stale total
# reaches MinTotalMB (Maximum intensity drops both limits down to Floor/0).
function Clear-StaleFiles {
    param(
        [string[]]$Path,
        [string]$Category,
        [int]$MinAgeDays = 0,
        [int]$MinTotalMB = 0,
        [int]$Floor = 0,
        [string]$Filter = '*',
        [string[]]$Processes = @(),
        [switch]$NoRecurse,
        [switch]$RequiresAdmin
    )
    if ($RequiresAdmin -and -not $IsAdmin) { return }
    $roots = Resolve-TargetPaths $Path
    if ($roots.Count -eq 0) { return }

    if (Test-SkipRunning $Processes $Category) { return }

    $age      = Get-EffectiveAge $MinAgeDays $Floor
    $minBytes = if ($script:Max) { [int64]0 } else { [int64]$MinTotalMB * 1MB }
    $cutoff   = [datetime]::UtcNow.AddDays(-$age)
    $key      = "$Category|$($roots -join '|')|$Filter|$NoRecurse"
    $cached   = if ($script:DryRun) { $null } else { $script:StaleCache[$key] }

    if ($null -ne $cached) {
        # Real run after the preview: apply exactly the previewed list instead of
        # walking every folder again (each file is re-checked just before deletion).
        foreach ($r in $cached.Roots) { [void](Register-CleanRoot $r) }
        if ($null -eq $cached.Stale) { return }
        $stale = $cached.Stale; $staleBytes = $cached.Bytes; $usedRoots = $cached.Roots
    } else {
        $stale = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        $staleBytes = [int64]0
        $usedRoots = [System.Collections.Generic.List[string]]::new()
        foreach ($r in $roots) {
            if (Test-Reparse $r) { continue }
            if (-not (Register-CleanRoot $r)) { continue }
            $usedRoots.Add($r)
            foreach ($f in (Get-FilesSafe -Root $r -Pattern $Filter -NoRecurse:$NoRecurse)) {
                $lu = $f.LastWriteTimeUtc; $la = $f.LastAccessTimeUtc
                if ($la -gt $lu) { $lu = $la }
                if ($lu -lt $cutoff) { $stale.Add($f); $staleBytes += $f.Length }
            }
        }
        if ($script:DryRun) {
            # Keep only lists that will be acted on, so memory stays small.
            $keep = $null
            if ($stale.Count -gt 0 -and $staleBytes -ge $minBytes) { $keep = $stale }
            $script:StaleCache[$key] = @{ Stale = $keep; Bytes = $staleBytes; Roots = $usedRoots }
        }
        if ($stale.Count -eq 0) {
            Write-Detail ("  {0,-38} nothing idle {1}+ days" -f $Category, $age)
            return
        }
        if ($staleBytes -lt $minBytes) {
            Write-Log ("  {0,-38} {1} idle - below the {2} MB threshold, left alone" -f $Category, (Format-Size $staleBytes), $MinTotalMB) "DarkGray"
            return
        }
    }

    $ageText = if ($age -gt 0) { "idle $age+ days" } else { "any age" }
    $verb = if ($script:DryRun) { "would free" } else { "freeing" }
    Write-Log ("  {0,-38} {1,10} in {2,6} files  ({3}, {4})" -f $Category, (Format-Size $staleBytes), $stale.Count, $ageText, $verb) "Green"

    $freed = [int64]0; $count = 0; $failed = 0
    foreach ($f in $stale) {
        if ($script:DryRun) {
            $len = $f.Length
            if ($Detailed) { Write-Detail "    Would remove: $($f.FullName) ($(Format-Size $len))" "DarkYellow" }
            $freed += $len; $count++
            continue
        }
        if ($null -ne $cached) {
            # The preview may be minutes old: skip anything gone or used since.
            try { $f.Refresh() } catch { $failed++; continue }
            if (-not $f.Exists) { continue }
            $lu = $f.LastWriteTimeUtc; $la = $f.LastAccessTimeUtc
            if ($la -gt $lu) { $lu = $la }
            if ($lu -ge $cutoff) { continue }
        }
        $len = $f.Length
        if (Remove-FileQuiet $f) {
            if ($Detailed) { Write-Detail "    Removed: $($f.FullName)" }
            $freed += $len; $count++
        } else { $failed++ }
    }
    Add-Freed -Bytes $freed -Category $Category -Count $count
    $script:Skipped += $failed
    if (-not $script:DryRun) {
        if ($failed -gt 0) { Write-Log "    ($failed file(s) in use - skipped)" "DarkGray" }
        foreach ($r in $usedRoots) { Remove-EmptySubdirs -Root $r }
    }
}

# ==========================================
# DISCOVERY: Chromium / Electron / WebView2 profiles
# ==========================================

$ChromiumCacheSubdirs = @('Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache',
                          'DawnWebGPUCache', 'GrShaderCache', 'GraphiteDawnCache', 'ShaderCache', 'Crashpad\reports')
$ChromiumRootSubdirs  = @('GrShaderCache', 'GraphiteDawnCache', 'ShaderCache', 'Crashpad\reports')

# A folder holding both "Code Cache" and "GPUCache"/"Cache" is a Chromium
# profile - that signature finds every browser AND every Electron/WebView2
# app without needing a hand-maintained list.
function Find-ChromiumProfiles {
    if ($script:ChromiumProfiles) { return , $script:ChromiumProfiles }
    $found = [System.Collections.Generic.List[string]]::new()
    $skip = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in @("$env:LOCALAPPDATA\Temp", "$env:LOCALAPPDATA\Microsoft\Windows", "$env:LOCALAPPDATA\Docker",
                     "$env:LOCALAPPDATA\wsl", "$env:LOCALAPPDATA\npm-cache", "$env:LOCALAPPDATA\pip",
                     "$env:LOCALAPPDATA\NuGet", "$env:LOCALAPPDATA\Pub", "$env:APPDATA\npm")) { [void]$skip.Add($s) }
    $skipNames = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
        'node_modules', 'Service Worker', 'IndexedDB', 'Local Storage', 'Extensions', 'Session Storage', 'blob_storage'), [StringComparer]::OrdinalIgnoreCase)

    $roots = @($env:LOCALAPPDATA, $env:APPDATA, "$env:USERPROFILE\AppData\LocalLow") | Where-Object { $_ -and [IO.Directory]::Exists($_) }
    $stack = [System.Collections.Generic.Stack[object]]::new()
    foreach ($r in $roots) { $stack.Push(@([System.IO.DirectoryInfo]::new($r), 0)) }
    while ($stack.Count -gt 0) {
        $item = $stack.Pop(); $d = $item[0]; $depth = $item[1]
        try { $subs = $d.GetDirectories() } catch { continue }
        foreach ($sub in $subs) {
            if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($skip.Contains($sub.FullName) -or $skipNames.Contains($sub.Name)) { continue }
            $p = $sub.FullName
            if ([IO.Directory]::Exists("$p\Code Cache") -and ([IO.Directory]::Exists("$p\GPUCache") -or [IO.Directory]::Exists("$p\Cache"))) {
                $found.Add($p)
                continue
            }
            if ($depth + 1 -lt 8) { $stack.Push(@($sub, ($depth + 1))) }
        }
    }
    $script:ChromiumProfiles = $found
    return , $found
}

function Get-AppLabel {
    param([string]$ProfileDir)
    $rel = $ProfileDir
    foreach ($b in @($env:LOCALAPPDATA, $env:APPDATA, "$env:USERPROFILE\AppData\LocalLow")) {
        if ($ProfileDir.StartsWith("$b\", [StringComparison]::OrdinalIgnoreCase)) { $rel = $ProfileDir.Substring($b.Length + 1); break }
    }
    $seg = $rel.Split('\')
    if ($seg[0] -eq 'Packages' -and $seg.Count -gt 1) {
        $name = (($seg[1] -split '_')[0]) -replace '^Microsoft\.', ''
    } else {
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($s in $seg) {
            if ($s -in @('User Data', 'EBWebView', 'Partitions') -or $parts.Count -ge 2) { break }
            $parts.Add($s)
        }
        $name = $parts -join ' '
    }
    $leaf = [IO.Path]::GetFileName($ProfileDir)
    if ($leaf -match '^(Default|Profile \d+|Guest Profile|System Profile)$') { $name += " ($leaf)" }
    return $name
}

# ==========================================
# DISCOVERY: profile scan (one walk, shared by several groups)
# ==========================================

# Chrome/Edge/Brave, Firefox, Opera, uTorrent, generic - leftovers of downloads that never finished.
# Offline | RecallOnOpen | RecallOnDataAccess - files that are only in the cloud.
$CloudOnlyAttrs = 0x1000 -bor 0x40000 -bor 0x400000
$PartialDownloadExt = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
    '.crdownload', '.part', '.partial', '.opdownload', '.!ut', '.!qb', '.download'), [StringComparer]::OrdinalIgnoreCase)

function Invoke-ProfileScan {
    if ($script:ProfileScan) { return $script:ProfileScan }
    $wantReports = $script:Selected['Reports']
    $wantDup     = $script:Selected['Duplicates']
    $wantPartial = $script:Selected['Browsers']
    $largeBytes  = [int64]$LargeFileMB * 1MB

    $scan = @{
        PartialDownloads = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        Large         = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        DupCandidates = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    }

    $media = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($sf in @('Desktop', 'MyDocuments', 'MyPictures', 'MyVideos', 'MyMusic')) {
        $p = [Environment]::GetFolderPath($sf); if ($p) { [void]$media.Add($p) }
    }
    [void]$media.Add("$env:USERPROFILE\Downloads")

    $roots = @($env:USERPROFILE)

    Write-Host "  (scanning your files - this can take a minute...)" -ForegroundColor DarkGray
    # stack item: DirectoryInfo, depth, inAppData, inMedia, isProfileRoot
    $stack = [System.Collections.Generic.Stack[object]]::new()
    foreach ($r in $roots) { $stack.Push(@([System.IO.DirectoryInfo]::new($r), 0, $false, $media.Contains($r), ($r -eq $env:USERPROFILE))) }

    while ($stack.Count -gt 0) {
        $it = $stack.Pop()
        $d = $it[0]; $depth = $it[1]; $inAppData = $it[2]; $inMedia = $it[3]; $isProfileRoot = $it[4]

        $checkPartial = $wantPartial -and -not $inAppData
        if ($wantReports -or $checkPartial -or ($wantDup -and $inMedia)) {
            try {
                foreach ($f in $d.EnumerateFiles()) {
                    if ($checkPartial -and $PartialDownloadExt.Contains($f.Extension)) { $scan.PartialDownloads.Add($f) }
                    if ($wantReports -and $f.Length -ge $largeBytes) { $scan.Large.Add($f) }
                    # Skip OneDrive/cloud online-only files: hashing one would download it.
                    if ($wantDup -and $inMedia -and $f.Length -ge 1MB -and -not ([int]$f.Attributes -band $CloudOnlyAttrs)) { $scan.DupCandidates.Add($f) }
                }
            } catch {}
        }

        try { $subs = $d.GetDirectories() } catch { continue }
        foreach ($sub in $subs) {
            if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $name = $sub.Name
            $subInAppData = $inAppData
            if ($isProfileRoot) {
                if ($name -eq 'AppData') {
                    if (-not $wantReports) { continue }
                    $subInAppData = $true
                } elseif ($name.StartsWith('.')) { continue }
            }
            # Huge trees of tiny files that never hold partial downloads - skip for speed.
            if (-not $subInAppData -and $name -in @('.git', 'node_modules')) { continue }
            if ($depth + 1 -ge 18) { continue }
            $stack.Push(@($sub, ($depth + 1), $subInAppData, ($inMedia -or $media.Contains($sub.FullName)), $false))
        }
    }
    $script:ProfileScan = $scan
    return $scan
}

# ==========================================
# DISCOVERY: WSL / Docker virtual disks
# ==========================================

function Get-WslDisks {
    $list = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $lx = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (Test-Path $lx) {
        foreach ($k in (Get-ChildItem $lx -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.BasePath) { continue }
            $base = $p.BasePath -replace '^\\\\\?\\', ''
            $vhd  = if ($p.VhdFileName) { $p.VhdFileName } else { 'ext4.vhdx' }
            $full = Join-Path $base $vhd
            if ([IO.File]::Exists($full) -and $seen.Add($full)) {
                $list.Add([PSCustomObject]@{ Name = $p.DistributionName; Path = $full; Docker = ($p.DistributionName -like 'docker-desktop*') })
            }
        }
    }
    return , $list
}

# ==========================================
# DISCOVERY: Windows Installer references
# ==========================================

# Union of the installer registry database and the WindowsInstaller COM API.
# A file referenced by EITHER source is kept.
function Get-InstallerReferences {
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $add = {
        param($p)
        if ($p) { try { [void]$set.Add([IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($p))) } catch {} }
    }

    $ud = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData'
    foreach ($sidKey in (Get-ChildItem $ud -ErrorAction SilentlyContinue)) {
        foreach ($prod in (Get-ChildItem "$($sidKey.PSPath)\Products" -ErrorAction SilentlyContinue)) {
            $ip = Get-ItemProperty "$($prod.PSPath)\InstallProperties" -ErrorAction SilentlyContinue
            if ($ip) { & $add $ip.LocalPackage }
        }
        foreach ($pt in (Get-ChildItem "$($sidKey.PSPath)\Patches" -ErrorAction SilentlyContinue)) {
            & $add (Get-ItemProperty $pt.PSPath -ErrorAction SilentlyContinue).LocalPackage
        }
    }

    try {
        $bf = [Reflection.BindingFlags]::GetProperty
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $wt = $wi.GetType()
        $prods = $wt.InvokeMember('ProductsEx', $bf, $null, $wi, @('', 's-1-1-0', 7))
        $pc = $prods.GetType().InvokeMember('Count', $bf, $null, $prods, $null)
        for ($i = 0; $i -lt $pc; $i++) {
            try {
                $p = $prods.GetType().InvokeMember('Item', $bf, $null, $prods, @($i))
                & $add ($p.GetType().InvokeMember('InstallProperty', $bf, $null, $p, @('LocalPackage')))
                $code = $p.GetType().InvokeMember('ProductCode', $bf, $null, $p, $null)
                $patches = $wt.InvokeMember('PatchesEx', $bf, $null, $wi, @($code, 's-1-1-0', 7, 15))
                $n = $patches.GetType().InvokeMember('Count', $bf, $null, $patches, $null)
                for ($j = 0; $j -lt $n; $j++) {
                    try {
                        $pa = $patches.GetType().InvokeMember('Item', $bf, $null, $patches, @($j))
                        & $add ($pa.GetType().InvokeMember('PatchProperty', $bf, $null, $pa, @('LocalPackage')))
                    } catch {}
                }
            } catch {}
        }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wi)
    } catch {}
    return , $set
}

# ==========================================
# DISCOVERY: registry / system hygiene
# ==========================================

function Get-OrphanedUninstallEntries {
    $bases = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $orphans = @()
    foreach ($base in $bases) {
        if (-not (Test-Path $base)) { continue }
        Get-ChildItem -Path $base -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$') { return }
            $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
            if (-not $props -or -not $props.DisplayName) { return }
            $uninstallString = $props.UninstallString
            $installLocation = $props.InstallLocation
            if ($uninstallString -and $uninstallString -match 'msiexec') { return }

            $locationMissing = $installLocation -and (Test-Missing ([Environment]::ExpandEnvironmentVariables($installLocation.Trim('"'))))
            $exeMissing = $false
            if ($uninstallString) {
                $exeMissing = Test-Missing (Get-CommandTarget $uninstallString)
            }

            if ($installLocation -and $locationMissing -and $exeMissing) {
                $orphans += [PSCustomObject]@{ KeyPath = $_.PSPath; Label = $props.DisplayName; Reason = "Install folder and uninstaller both missing" }
            } elseif (-not $installLocation -and $exeMissing) {
                $orphans += [PSCustomObject]@{ KeyPath = $_.PSPath; Label = $props.DisplayName; Reason = "Uninstaller executable missing" }
            }
        }
    }
    return @($orphans)
}

function Get-OrphanedAppPathsEntries {
    $orphans = @()
    foreach ($base in @("HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths", "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths")) {
        if (-not (Test-Path $base)) { continue }
        Get-ChildItem -Path $base -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $val = (Get-Item -Path $_.PSPath).GetValue("")
                if ($val) {
                    $expanded = [Environment]::ExpandEnvironmentVariables($val.Trim('"'))
                    if (Test-Missing $expanded) {
                        $orphans += [PSCustomObject]@{ KeyPath = $_.PSPath; Label = $_.PSChildName; Reason = "Target missing: $expanded" }
                    }
                }
            } catch {}
        }
    }
    return @($orphans)
}

function Get-OrphanedRunEntries {
    $keys = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    )
    $orphans = @()
    foreach ($k in $keys) {
        if (-not (Test-Path $k)) { continue }
        $props = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
            $cmd = [string]$_.Value
            if (-not $cmd -or $cmd -notmatch '\.(exe|cmd|bat|com)') { return }
            if ($cmd -match 'rundll32|regsvr32') { return }
            $exePath = Get-CommandTarget $cmd 'exe|cmd|bat|com'
            if (Test-Missing $exePath) {
                $orphans += [PSCustomObject]@{ KeyPath = $k; Label = $_.Name; Reason = "Startup target missing: $exePath" }
            }
        }
    }
    return @($orphans)
}

function Get-OrphanedMuiCacheEntries {
    $base = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache"
    $orphans = @()
    if (Test-Path $base) {
        try {
            $key = Get-Item -Path $base
            foreach ($valueName in $key.GetValueNames()) {
                if (-not $valueName) { continue }
                $path = ($valueName -replace '\.(FriendlyAppName|ApplicationCompany)$', '')
                $expanded = [Environment]::ExpandEnvironmentVariables($path)
                if (Test-Missing $expanded) {
                    $orphans += [PSCustomObject]@{ KeyPath = $base; Label = $valueName; Reason = "Cached path missing: $expanded" }
                }
            }
        } catch {}
    }
    return @($orphans)
}

function Get-OrphanedScheduledTasks {
    $orphans = @()
    try { $tasks = Get-ScheduledTask -ErrorAction Stop } catch { return @() }
    foreach ($t in $tasks) {
        if ($t.TaskPath -like '\Microsoft\*') { continue }
        $exec = @($t.Actions | Where-Object { $_.Execute })
        if ($exec.Count -eq 0) { continue }
        $missing = 0; $first = $null
        foreach ($a in $exec) {
            $exe = [Environment]::ExpandEnvironmentVariables($a.Execute.Trim().Trim('"'))
            if (Test-Missing $exe) { $missing++; if (-not $first) { $first = $exe } }
        }
        if ($missing -eq $exec.Count) {
            $orphans += [PSCustomObject]@{ TaskName = $t.TaskName; TaskPath = $t.TaskPath; Label = "$($t.TaskPath)$($t.TaskName)"; Reason = "Program missing: $first" }
        }
    }
    return @($orphans)
}

function Get-OrphanedFirewallRules {
    if (-not $IsAdmin) { return @() }
    $orphans = @()
    try {
        $rules = @{}
        Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop | ForEach-Object { $rules[$_.InstanceID] = $_ }
        $filters = Get-NetFirewallApplicationFilter -PolicyStore PersistentStore -ErrorAction Stop
    } catch { return @() }
    foreach ($f in $filters) {
        $prog = $f.Program
        if (-not $prog -or $prog -in @('Any', 'System')) { continue }
        $exp = [Environment]::ExpandEnvironmentVariables($prog)
        if (-not (Test-Missing $exp)) { continue }
        $r = $rules[$f.InstanceID]
        if (-not $r) { continue }
        if ($r.Group -like '@*') { continue }   # built-in Windows rule - leave to Windows
        $orphans += [PSCustomObject]@{ RuleId = $r.InstanceID; Label = $r.DisplayName; Reason = "Program missing: $exp" }
    }
    return @($orphans)
}

# Value names of the Run keys (the programs Task Manager lists under Startup).
# $null when a Run key exists but can't be read - then nothing is judged.
function Get-RunValueNames {
    param([string[]]$Except = @())
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
                     'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')) {
        if (-not (Test-Path $k)) { continue }
        try { foreach ($n in (Get-Item -Path $k -ErrorAction Stop).GetValueNames()) { if ($n -and $Except -notcontains $n) { [void]$names.Add($n) } } }
        catch { return $null }
    }
    return , $names
}

# Task Manager's on/off switches (StartupApproved) for startup items that are gone.
function Get-OrphanedStartupApprovedEntries {
    param([object[]]$RunOrphans = @())
    $orphans = @()
    $runNames = Get-RunValueNames -Except @($RunOrphans | ForEach-Object { $_.Label })
    if ($null -eq $runNames) { return @() }
    $files = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($dir in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        if ($dir -and [IO.Directory]::Exists($dir)) { foreach ($f in [IO.Directory]::EnumerateFiles($dir)) { [void]$files.Add([IO.Path]::GetFileName($f)) } }
    }
    foreach ($hive in 'HKCU', 'HKLM') {
        foreach ($sub in 'Run', 'Run32', 'StartupFolder') {
            $k = "${hive}:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$sub"
            try { $key = Get-Item -Path $k -ErrorAction Stop } catch { continue }
            foreach ($n in $key.GetValueNames()) {
                if (-not $n) { continue }
                $exists = if ($sub -eq 'StartupFolder') { $files.Contains($n) } else { $runNames.Contains($n) }
                if (-not $exists) { $orphans += [PSCustomObject]@{ KeyPath = $k; Label = $n; Reason = 'startup item no longer exists' } }
            }
        }
    }
    return @($orphans)
}

# Windows' compatibility records (Program Compatibility Assistant, compatibility
# mode settings) for programs that were deleted. The value name is the path.
function Get-OrphanedCompatEntries {
    $orphans = @()
    foreach ($k in @('HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Compatibility Assistant\Store',
                     'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers',
                     'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers')) {
        try { $key = Get-Item -Path $k -ErrorAction Stop } catch { continue }
        foreach ($n in $key.GetValueNames()) {
            if ($n -and (Test-Missing $n)) { $orphans += [PSCustomObject]@{ KeyPath = $k; Label = $n; Reason = 'program missing' } }
        }
    }
    return @($orphans)
}

# "Open with" registrations (Classes\Applications\<app>.exe) of deleted programs.
function Get-OrphanedOpenWithEntries {
    $orphans = @()
    foreach ($base in @('HKCU:\Software\Classes\Applications', 'HKLM:\SOFTWARE\Classes\Applications')) {
        foreach ($app in (Get-ChildItem -Path $base -ErrorAction SilentlyContinue)) {
            try { $cmd = [string](Get-Item -LiteralPath "$($app.PSPath)\shell\open\command" -ErrorAction Stop).GetValue('') } catch { continue }
            if (-not $cmd) { continue }
            $target = Get-CommandTarget $cmd
            if (Test-Missing $target) { $orphans += [PSCustomObject]@{ KeyPath = $app.PSPath; Label = $app.PSChildName; Reason = "program missing: $target" } }
        }
    }
    return @($orphans)
}

# SharedDLLs: install counters for shared files that are gone. A 32-bit
# installer's "System32" means SysWOW64, so a file counts as gone only if
# missing in both.
function Get-OrphanedSharedDllEntries {
    $orphans = @()
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedDLLs', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\SharedDLLs')) {
        try { $key = Get-Item -Path $k -ErrorAction Stop } catch { continue }
        foreach ($n in $key.GetValueNames()) {
            if (-not $n -or -not (Test-Missing $n)) { continue }
            $alt = $n -replace '(?i)\\system32\\', '\SysWOW64\'
            if ($alt -ne $n -and -not (Test-Missing $alt)) { continue }
            $orphans += [PSCustomObject]@{ KeyPath = $k; Label = $n; Reason = 'file missing' }
        }
    }
    return @($orphans)
}

# Registered fonts whose font file is gone.
function Get-OrphanedFontEntries {
    $orphans = @()
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts', 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts')) {
        try { $key = Get-Item -Path $k -ErrorAction Stop } catch { continue }
        foreach ($n in $key.GetValueNames()) {
            $v = [string]$key.GetValue($n)
            if (-not $n -or -not $v -or $v.Contains(',')) { continue }
            $path = if ($v -match '^[A-Za-z]:\\') { $v } else { Join-Path "$env:WINDIR\Fonts" $v }
            if (Test-Missing $path) { $orphans += [PSCustomObject]@{ KeyPath = $k; Label = $n; Reason = "font file missing: $path" } }
        }
    }
    return @($orphans)
}

# Right-click menu handlers whose DLL was deleted - Explorer tries to load each
# one on every right-click. Only the handler entry is removed; a handler whose
# DLL can't be determined is left alone.
function Get-OrphanedShellExtensions {
    $orphans = @()
    foreach ($root in @('HKLM:\SOFTWARE\Classes', 'HKCU:\Software\Classes')) {
        foreach ($type in @('*', 'Directory', 'Directory\Background', 'Folder', 'AllFilesystemObjects', 'Drive')) {
            foreach ($h in (Get-ChildItem -LiteralPath "$root\$type\shellex\ContextMenuHandlers" -ErrorAction SilentlyContinue)) {
                $clsid = [string]$h.GetValue('')
                if ($clsid -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { $clsid = $h.PSChildName }
                if ($clsid -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { continue }
                $dll = $null
                foreach ($c in @("HKLM:\SOFTWARE\Classes\CLSID\$clsid\InprocServer32", "HKCU:\Software\Classes\CLSID\$clsid\InprocServer32")) {
                    try { $v = [string](Get-Item -LiteralPath $c -ErrorAction Stop).GetValue(''); if ($v) { $dll = $v; break } } catch {}
                }
                if (-not $dll) { continue }
                $dll = [Environment]::ExpandEnvironmentVariables($dll.Trim('"'))
                if (Test-Missing $dll) {
                    $orphans += [PSCustomObject]@{ KeyPath = $h.PSPath; Label = "$type > $($h.PSChildName)"; Reason = "handler file missing: $dll" }
                }
            }
        }
    }
    return @($orphans)
}

function ConvertTo-RegExePath {
    param([string]$Path)
    $p = $Path -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
    return ($p -replace '^HKEY_CURRENT_USER\\', 'HKCU\' -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\' -replace '^HKLM:\\', 'HKLM\')
}

function Remove-RegistryValueDirect {
    # Raw .NET DeleteValue: Remove-ItemProperty treats -Name as a wildcard
    # pattern and silently fails on names containing [ ] (common in MuiCache).
    param([string]$KeyPath, [string]$ValueName)
    try {
        if ($KeyPath -match '^HKCU:\\(.+)$') { $hive = [Microsoft.Win32.Registry]::CurrentUser }
        elseif ($KeyPath -match '^HKLM:\\(.+)$') { $hive = [Microsoft.Win32.Registry]::LocalMachine }
        else { return $false }
        $key = $hive.OpenSubKey($matches[1], $true)
        if (-not $key) { return $false }
        try { $key.DeleteValue($ValueName, $false); return $true } finally { $key.Close() }
    } catch { return $false }
}

# ==========================================
# DISCOVERY: installed-app name index (leftover-folder report)
# ==========================================

function ConvertTo-NormName { param([string]$s) return ($s.ToLower() -replace '[^a-z0-9]', '') }

function Get-InstalledNameIndex {
    param([object[]]$Services = @())
    $set = [System.Collections.Generic.HashSet[string]]::new()
    $addName = { param($n) if ($n) { $x = ConvertTo-NormName $n; if ($x.Length -ge 3) { [void]$set.Add($x) } } }
    # A program's folder and its parent folder (e.g. Vendor\Product\app.exe).
    $addExeDirs = {
        param($exe)
        $dir = [IO.Path]::GetDirectoryName($exe)
        & $addName ([IO.Path]::GetFileName($dir)); & $addName ([IO.Path]::GetFileName([IO.Path]::GetDirectoryName($dir)))
    }
    $keys = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue | ForEach-Object {
        & $addName $_.DisplayName; & $addName $_.Publisher
        if ($_.InstallLocation) { & $addName ([IO.Path]::GetFileName($_.InstallLocation.Trim('"').TrimEnd('\'))) }
    }
    try { Get-AppxPackage -ErrorAction Stop | ForEach-Object { & $addName $_.Name; & $addName (($_.Name -split '\.')[-1]) } } catch {}
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path } | ForEach-Object { & $addExeDirs $_.Path }
    foreach ($s in $Services) {
        if ($s.PathName -match '^"?([A-Za-z]:\\[^"]+?\.exe)') { & $addExeDirs $matches[1] }
    }
    return , $set
}

# ==========================================
# GROUP DEFINITIONS
# ==========================================

$GroupDefs = [ordered]@{
    Browsers   = @{ Title = 'Browser & app web caches';            Default = 'Y'; Admin = $false; Report = $false
                    Prompt = 'Clean browser and app caches (logins, history and bookmarks are kept)?' }
    System     = @{ Title = 'Deep system junk';                    Default = 'Y'; Admin = $false; Report = $false
                    Prompt = 'Clean old Windows logs, traces, crash reports and system caches?' }
    Installer  = @{ Title = 'Orphaned Windows Installer packages'; Default = 'Y'; Admin = $true;  Report = $false
                    Explain = @(
                        'When you install a program with a .msi installer, Windows keeps a hidden copy of it in'
                        'C:\Windows\Installer so it can repair or uninstall that program later. When the program'
                        'is removed, the copy is often left behind forever. This removes ONLY copies that no'
                        'installed program uses any more - your installed programs keep theirs.')
                    Prompt = 'Remove leftover installer copies of programs that are already uninstalled?' }
    Drivers    = @{ Title = 'Superseded driver packages';          Default = 'Y'; Admin = $true;  Report = $false
                    Explain = @(
                        'Every time a driver updates (graphics, network, chipset...), Windows keeps the old'
                        'version too. This removes old versions when a newer one of the same driver is installed.'
                        'Windows itself refuses to remove any driver a device is currently using.')
                    Prompt = 'Remove old driver versions that a newer version has replaced?' }
    Hygiene    = @{ Title = 'Registry & system hygiene';           Default = 'Y'; Admin = $false; Report = $false
                    Explain = @(
                        'When programs are deleted, entries about them often stay behind: in the installed-programs'
                        'list, startup items and their on/off switches, scheduled tasks, firewall rules, Windows'''
                        'compatibility records, "Open with" lists, fonts and right-click menus (Explorer tries to'
                        'load a dead right-click entry every time you right-click). This removes only entries whose'
                        'program or file no longer exists. Everything is backed up to your Desktop first, so it can'
                        'be restored by double-clicking the backup file.')
                    Prompt = 'Remove leftover settings of programs that were deleted?' }
    Shortcuts  = @{ Title = 'Broken shortcuts';                    Default = 'Y'; Admin = $false; Report = $false
                    Prompt = 'Remove shortcuts that no longer work?' }
    WSL        = @{ Title = 'WSL disk compaction';        Default = 'Y'; Admin = $true;  Report = $false
                    Explain = @(
                        'WSL (Linux on Windows) and Docker store their data in one big virtual-disk file.'
                        'When you delete files inside Linux/Docker, that file does NOT get smaller - the space'
                        'stays taken on your C: drive. This shrinks the file back to what is really used.'
                        'Your Linux/Docker files are not touched, but any open WSL terminal will be closed.')
                    Prompt = 'Shrink the WSL/Docker virtual disks?' }
    PatchCache = @{ Title = 'Old update backup copies ($PatchCache$)'; Default = 'N'; Admin = $true;  Report = $false
                    Explain = @(
                        'Some programs installed with .msi installers (e.g. Office, Visual C++ runtimes, some'
                        'Adobe/Autodesk tools) keep a backup copy of their original files in the hidden folder'
                        'C:\Windows\Installer\$PatchCache$, so future updates can be applied without asking you.'
                        'If you delete it: everything keeps working, but a future update or repair of such a'
                        'program MAY ask you for its original installer/setup file. Usually small - only worth it'
                        'if this folder is big on your PC (the preview shows its size before anything happens).')
                    Prompt = 'Delete old update backup copies ($PatchCache$)?' }
    ResetBase  = @{ Title = 'Make installed updates permanent (ResetBase)'; Default = 'N'; Admin = $true;  Report = $false
                    Explain = @(
                        'Each time Windows installs an update, it keeps the old version of the changed system files'
                        'so you can uninstall that update if it causes problems (Settings > Windows Update >'
                        'Update history > Uninstall updates). Windows already deletes very old versions itself.'
                        'This goes further and deletes ALL of them, freeing space (often 0.5-3 GB).'
                        'Downside: updates installed so far can NO LONGER be uninstalled. Only say yes if your'
                        'PC has been running fine since the last updates. Takes 5-20 minutes. Future updates'
                        'are not affected.')
                    Prompt = 'Make the currently installed updates permanent to free space?' }
    Reports    = @{ Title = 'Insight reports';                     Default = 'Y'; Admin = $false; Report = $true
                    Prompt = 'Show a report of big and leftover files (nothing is deleted)?' }
    Duplicates = @{ Title = 'Duplicate files report';              Default = 'N'; Admin = $false; Report = $true
                    Prompt = 'Look for duplicate files (nothing is deleted, slower)?' }
}

# ==========================================
# FRIENDLY PROGRESS FOR LONG WINDOWS TOOLS
# ==========================================

function Get-SystemFreeBytes { return ([IO.DriveInfo]::new($env:SystemDrive)).AvailableFreeSpace }

function Format-Duration {
    param([TimeSpan]$T)
    if ($T.TotalHours -ge 1) { return '{0}h {1:00}m' -f [int][math]::Floor($T.TotalHours), $T.Minutes }
    if ($T.TotalMinutes -ge 1) { return '{0}m {1:00}s' -f [int][math]::Floor($T.TotalMinutes), $T.Seconds }
    return '{0}s' -f $T.Seconds
}

# Redraws one console line in place instead of printing a new line per update.
function Write-StatusLine {
    param([string]$Text)
    $w = 119
    try { $w = [Console]::WindowWidth - 1 } catch {}
    if ($Text.Length -gt $w) { $Text = $Text.Substring(0, $w) }
    Write-Host -NoNewline ("`r" + $Text.PadRight($w)) -ForegroundColor Gray
}

function Clear-StatusLine {
    Write-StatusLine ""
    Write-Host "`r" -NoNewline
}

# Runs DISM and turns its raw output (a progress bar reprinted dozens of
# times, restarting at every internal stage) into one live status line:
#   Stage 2  [##########.........]  62.2%  | elapsed 4m 10s | no change for 2m 31s - still working
# Each finished stage gets one summary line in the log.
function Invoke-DismFriendly {
    param([string]$Arguments, [string]$What)

    Write-Log "  $What" "Green"
    Write-Host "    What you'll see: DISM works in several stages and its % starts over for each stage" -ForegroundColor DarkGray
    Write-Host "    (so 100% followed by 70% just means stage 2 began). It can sit on one number for" -ForegroundColor DarkGray
    Write-Host "    many minutes while it checks thousands of Windows components without reporting" -ForegroundColor DarkGray
    Write-Host "    progress - that is normal. Please don't close this window." -ForegroundColor DarkGray

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:WINDIR\System32\Dism.exe"
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    try { $proc = [System.Diagnostics.Process]::Start($psi) } catch {
        Write-Log "    Could not start DISM: $($_.Exception.Message)" "Yellow"
        return -1
    }

    $total = [Diagnostics.Stopwatch]::StartNew()
    $stageClock = [Diagnostics.Stopwatch]::StartNew()
    $lastChange = [Diagnostics.Stopwatch]::StartNew()
    $stage = 1; $pct = -1.0
    $messages = [System.Collections.Generic.List[string]]::new()
    $pending = $proc.StandardOutput.ReadLineAsync()

    while ($true) {
        if ($pending.Wait(1000)) {
            $line = $pending.Result
            if ($null -eq $line) { break }
            $pending = $proc.StandardOutput.ReadLineAsync()
            if ($line -match '(\d{1,3}(?:[.,]\d+)?)\s*%') {
                $v = [double]($matches[1] -replace ',', '.')
                if ($pct -ge 0 -and $v -lt ($pct - 0.05)) {
                    Clear-StatusLine
                    Write-Log ("    Stage {0} done after {1} - stage {2} starting (its % starts over)" -f $stage, (Format-Duration $stageClock.Elapsed), ($stage + 1)) "DarkGray"
                    $stage++
                    $stageClock.Restart()
                }
                if ($v -ne $pct) { $pct = $v; $lastChange.Restart() }
            } elseif ($line.Trim() -and $line -notmatch '^\s*(Deployment Image Servicing|Version:|Image Version:)') {
                $messages.Add($line.Trim())
            }
        }
        $shown = [math]::Max($pct, 0)
        $filled = [int][math]::Round($shown / 100 * 25)
        $bar = ('#' * $filled) + ('.' * (25 - $filled))
        $status = "    Stage $stage  [$bar] {0,5:N1}%  | elapsed {1}" -f $shown, (Format-Duration $total.Elapsed)
        if ($pct -lt 0) { $status = "    Starting DISM...  | elapsed $(Format-Duration $total.Elapsed)" }
        elseif ($lastChange.Elapsed.TotalSeconds -ge 20) { $status += " | no change for $(Format-Duration $lastChange.Elapsed) - still working" }
        Write-StatusLine $status
    }
    $proc.WaitForExit()
    Clear-StatusLine

    $code = $proc.ExitCode
    $result = if ($code -eq 0) { 'completed successfully' } else { "failed (exit code $code)" }
    Write-Log ("    Finished: {0} stage(s) in {1} - {2}" -f $stage, (Format-Duration $total.Elapsed), $result) $(if ($code -eq 0) { "Green" } else { "Yellow" })
    foreach ($m in $messages) {
        if ($m -notmatch 'operation completed successfully') { Write-Log "    DISM: $m" "DarkGray" }
    }
    return $code
}

# ==========================================
# WINDOWS TOOLS MENU ('w' at the first question)
# ==========================================

# Windows' own tools, started as-is. Console tools run here in list order; windowed ones just open.
$WindowsTools = @(
    @{ Name = 'Disk Cleanup';           Note = "opens Windows' Disk Cleanup";                 Run = { Start-Process "$env:WINDIR\System32\cleanmgr.exe" } }
    @{ Name = 'Storage Sense';          Note = 'opens Settings > Storage';                    Run = { Start-Process 'ms-settings:storagesense' } }
    @{ Name = 'Cleanup recommendations'; Note = 'opens Settings > Storage > Cleanup recommendations'; Run = { Start-Process 'ms-settings:storagerecommendations' } }
    @{ Name = 'Store cache reset';      Note = 'wsreset (the Store opens when done)';         Run = { Start-Process "$env:WINDIR\System32\wsreset.exe" } }
    @{ Name = 'Analyze component store'; Note = 'DISM /AnalyzeComponentStore (says if 6 is worth it)'; Admin = $true
       Run = { Start-Process "$env:WINDIR\System32\Dism.exe" '/Online /Cleanup-Image /AnalyzeComponentStore' -NoNewWindow -Wait } }
    @{ Name = 'Component cleanup';      Note = 'DISM /Online /Cleanup-Image /StartComponentCleanup'; Admin = $true
       Run = { [void](Invoke-DismFriendly -Arguments '/Online /Cleanup-Image /StartComponentCleanup' -What 'DISM /StartComponentCleanup') } }
    @{ Name = 'Check image health';     Note = 'DISM /CheckHealth (seconds, read-only)';      Admin = $true
       Run = { Start-Process "$env:WINDIR\System32\Dism.exe" '/Online /Cleanup-Image /CheckHealth' -NoNewWindow -Wait } }
    @{ Name = 'Repair Windows image';   Note = 'DISM /Online /Cleanup-Image /RestoreHealth';  Admin = $true
       Run = { [void](Invoke-DismFriendly -Arguments '/Online /Cleanup-Image /RestoreHealth' -What 'DISM /RestoreHealth') } }
    @{ Name = 'Repair system files';    Note = 'sfc /scannow';                                Admin = $true
       Run = { Start-Process "$env:WINDIR\System32\sfc.exe" '/scannow' -NoNewWindow -Wait } }
    @{ Name = 'Drive health';           Note = 'Get-PhysicalDisk (+ wear/temperature as admin)'
       Run = {
           foreach ($d in Get-PhysicalDisk) {
               $r = if ($IsAdmin) { $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue }
               $extra = ''
               if ($r -and $null -ne $r.Wear) { $extra += " | wear $($r.Wear)%" }
               if ($r -and $r.Temperature) { $extra += " | $($r.Temperature) C" }
               Write-Log ("  {0}  {1}  {2}  {3}{4}" -f $d.FriendlyName, $d.MediaType, (Format-Size $d.Size), $d.HealthStatus, $extra) $(if ($d.HealthStatus -eq 'Healthy') { 'Green' } else { 'Yellow' })
           }
       } }
    @{ Name = 'Check disk';            Note = "chkdsk $env:SystemDrive /scan (online, no restart)"; Admin = $true
       Run = { Start-Process "$env:WINDIR\System32\chkdsk.exe" "$env:SystemDrive /scan" -NoNewWindow -Wait } }
    @{ Name = 'Optimize Drives';        Note = 'opens defrag / TRIM';                         Run = { Start-Process "$env:WINDIR\System32\dfrgui.exe" } }
    @{ Name = 'Memory Diagnostic';      Note = 'opens mdsched (asks before restarting)';      Run = { Start-Process "$env:WINDIR\System32\mdsched.exe" } }
    @{ Name = 'Defender quick scan';    Note = 'MpCmdRun -Scan -ScanType 1';
       Run = { Start-Process "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" '-Scan -ScanType 1' -NoNewWindow -Wait } }
)

# Arrow-key checklist. Returns the picked numbers (sorted), or nothing for Back/Esc.
function Show-WindowsToolsMenu {
    $n = $WindowsTools.Count
    $rows = $n + 2                       # tools + Run + Back
    $lines = $rows + 2                   # + 'Selected' line + message line
    $picked = [System.Collections.Generic.SortedSet[int]]::new()
    $pos = 0; $msg = ''
    $typed = ''; $typedAt = [DateTime]::MinValue
    $w = 119
    try { $w = [Console]::WindowWidth - 1 } catch {}

    Write-Host ""
    Write-Host "--- Windows tools ---" -ForegroundColor Cyan
    Write-Host "  Up/Down = move, 1-$n = jump, Enter = select, Esc = back" -ForegroundColor Gray
    # Reserve the space first so scrolling can't shift where the menu is redrawn.
    for ($i = 0; $i -lt $lines; $i++) { Write-Host "" }
    $top = [Console]::CursorTop - $lines
    $cursorWas = [Console]::CursorVisible
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            [Console]::SetCursorPosition(0, $top)
            for ($i = 0; $i -lt $rows; $i++) {
                $arrow = if ($i -eq $pos) { '>' } else { ' ' }
                if ($i -lt $n) {
                    $t = $WindowsTools[$i]
                    $on = $picked.Contains($i + 1)
                    $locked = $t.Admin -and -not $IsAdmin
                    $note = if ($locked) { 'needs Administrator' } else { $t.Note }
                    $text = " {0} [{1}] {2,2}  {3,-24} {4}" -f $arrow, $(if ($on) { 'x' } else { ' ' }), ($i + 1), $t.Name, $note
                    $color = if ($locked) { 'DarkGray' } elseif ($on) { 'Green' } elseif ($i -eq $pos) { 'White' } else { 'Gray' }
                } else {
                    $text = " $arrow " + $(if ($i -eq $n) { 'Run selected' } else { 'Back to DeepClean' })
                    $color = if ($i -eq $pos) { 'White' } else { 'Cyan' }
                }
                if ($text.Length -gt $w) { $text = $text.Substring(0, $w) }
                Write-Host $text.PadRight($w) -ForegroundColor $color
            }
            $sel = if ($picked.Count) { $picked -join ', ' } else { 'none' }
            Write-Host ("  Selected: $sel").PadRight($w) -ForegroundColor Green
            Write-Host ("  $msg").PadRight($w) -ForegroundColor Yellow
            $msg = ''

            $k = [Console]::ReadKey($true)
            $hit = -1
            # Digits jump to a tool; a second digit within a second makes 10-99.
            if ([char]::IsDigit($k.KeyChar)) {
                if (([DateTime]::Now - $typedAt).TotalSeconds -gt 1) { $typed = '' }
                $typedAt = [DateTime]::Now
                if ([int]($typed + $k.KeyChar) -gt $n) { $typed = '' }
                $typed += $k.KeyChar
                if ([int]$typed -ge 1) { $pos = [int]$typed - 1 }
            }
            switch ($k.Key) {
                'UpArrow'   { $pos = ($pos + $rows - 1) % $rows; $typed = '' }
                'DownArrow' { $pos = ($pos + 1) % $rows; $typed = '' }
                'Escape'    { return }
                'Enter'     {
                    $typed = ''
                    if ($pos -eq $n + 1) { return }
                    if ($pos -eq $n) {
                        if ($picked.Count) { return @($picked) }
                        $msg = 'Select at least one tool first.'
                    } else { $hit = $pos }
                }
            }
            if ($hit -ge 0) {
                if ($WindowsTools[$hit].Admin -and -not $IsAdmin) { $msg = 'That one needs Administrator.' }
                elseif (-not $picked.Remove($hit + 1)) { [void]$picked.Add($hit + 1) }
            }
        }
    } finally {
        [Console]::SetCursorPosition(0, $top + $lines)
        [Console]::CursorVisible = $cursorWas
    }
}

function Invoke-WindowsTools {
    while ($true) {
        $sel = @(Show-WindowsToolsMenu)
        if ($sel.Count -eq 0) { return }
        foreach ($i in $sel) {
            $t = $WindowsTools[$i - 1]
            Write-Log ""
            Write-Log "[$i $($t.Name)] $($t.Note)" "Cyan"
            try { & $t.Run } catch { Write-Log "  Could not start: $($_.Exception.Message)" "Yellow" }
        }
        Write-Host ""
        Write-Host "Done. Press any key to return to the Windows tools menu." -ForegroundColor Gray
        [void][Console]::ReadKey($true)
    }
}

function Use-Group {
    param([string]$Key)
    if (-not $script:Selected[$Key]) { return $false }
    if (-not $script:DryRun -and -not $script:Approved.Contains($Key)) { return $false }
    $script:CurrentGroup = $Key
    Update-RunningProcesses
    Write-Log ""
    Write-Log "$Arrow $($GroupDefs[$Key].Title)" "Cyan"
    return $true
}

# ==========================================
# MAIN PASS
# ==========================================

function Invoke-CleanupPass {
    $tag = if ($script:DryRun) { "PREVIEW" } else { "REAL RUN" }
    Write-Log ""
    Write-Log $Rule "DarkCyan"
    Write-Log "  $tag  $Dot  $(if ($script:Max) { 'Maximum' } else { 'Balanced' }) intensity" "Cyan"
    Write-Log $Rule "DarkCyan"

    # ---------- Browser & app web caches ----------
    if (Use-Group 'Browsers') {
        $profiles = Find-ChromiumProfiles
        foreach ($p in $profiles) {
            $parent = [IO.Path]::GetDirectoryName($p)
            $label = Get-AppLabel $p
            if ((Test-FileLocked "$p\lockfile") -or (Test-FileLocked "$parent\lockfile")) {
                Write-Log ("  {0,-38} skipped - app is running (close it to clean)" -f $label) "Yellow"
                continue
            }
            $paths = @($ChromiumCacheSubdirs | ForEach-Object { "$p\$_" })
            if ([IO.File]::Exists("$parent\Local State")) { $paths += @($ChromiumRootSubdirs | ForEach-Object { "$parent\$_" }) }
            Clear-StaleFiles -Path $paths -Category $label -MinAgeDays 7
        }
        # Firefox-engine browsers (Firefox, Thunderbird, LibreWolf, Waterfox...): the
        # cache is under LOCALAPPDATA\...\Profiles\<p>, the lock under the same path in APPDATA.
        foreach ($fp in (Resolve-TargetPaths @("$env:LOCALAPPDATA\*\Profiles\*", "$env:LOCALAPPDATA\*\*\Profiles\*"))) {
            if (-not [IO.Directory]::Exists("$fp\cache2")) { continue }
            $rel = $fp.Substring($env:LOCALAPPDATA.Length)
            $label = "$(Split-Path ($rel -replace '\\Profiles\\.*$', '') -Leaf) ($([IO.Path]::GetFileName($fp)))"
            if (Test-FileLocked "$env:APPDATA$rel\parent.lock") {
                Write-Log ("  {0,-38} skipped - app is running (close it to clean)" -f $label) "Yellow"
                continue
            }
            Clear-StaleFiles -Path @("$fp\cache2", "$fp\startupCache", "$fp\jumpListCache") -Category $label -MinAgeDays 7
        }

        # Abandoned partial downloads anywhere in your folders (an active download is
        # never older than the 2-day floor, even at Maximum intensity).
        $scan = Invoke-ProfileScan
        $cutoff = (Get-Date).AddDays(-(Get-EffectiveAge 7 2))
        # A paused torrent can sit for weeks and still be resumed - keep the
        # unfinished files of a torrent client that is installed.
        $torrentKeep = @()
        if ([IO.Directory]::Exists("$env:APPDATA\uTorrent") -or [IO.Directory]::Exists("$env:APPDATA\BitTorrent")) { $torrentKeep += '.!ut' }
        if ([IO.Directory]::Exists("$env:APPDATA\qBittorrent") -or [IO.Directory]::Exists("$env:LOCALAPPDATA\qBittorrent")) { $torrentKeep += '.!qb' }
        foreach ($f in $scan.PartialDownloads) {
            if ($torrentKeep -contains $f.Extension.ToLower()) { continue }
            $f.Refresh()
            if (-not $f.Exists -or $f.LastWriteTime -ge $cutoff) { continue }
            $len = $f.Length
            if ($script:DryRun) {
                Write-Log ("  {0,-38} {1,10}  {2}  (stalled since {3:yyyy-MM-dd})" -f 'Abandoned partial download', (Format-Size $len), $f.FullName, $f.LastWriteTime) "Green"
                Add-Freed -Bytes $len -Category 'Abandoned partial downloads'
            } elseif (Remove-FileQuiet $f) {
                Write-Log "  Removed partial download: $($f.FullName)" "DarkGray"
                Add-Freed -Bytes $len -Category 'Abandoned partial downloads'
            } else { $script:Skipped++ }
        }
    }

    # ---------- Deep system junk ----------
    if (Use-Group 'System') {
        if (-not $IsAdmin) { Write-Log "  (not elevated - only per-user items below; system locations need Administrator)" "DarkGray" }
        Clear-StaleFiles -RequiresAdmin -Category 'Service-account temp' -MinAgeDays 7 -Floor 1 -Path @(
            "$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\Temp",
            "$env:WINDIR\ServiceProfiles\NetworkService\AppData\Local\Temp",
            "$env:WINDIR\System32\config\systemprofile\AppData\Local\Temp",
            "$env:WINDIR\SysWOW64\config\systemprofile\AppData\Local\Temp",
            "$env:WINDIR\SystemTemp")
        Clear-StaleFiles -RequiresAdmin -Path @("$env:WINDIR\LiveKernelReports") -Category 'LiveKernelReports dumps' -MinAgeDays 14
        # Every Windows log folder (CBS, DISM, MeasuredBoot, WindowsUpdate, SIH,
        # waasmedic, MoSetup...) - files in use are locked and simply skipped.
        Clear-StaleFiles -RequiresAdmin -Path @("$env:WINDIR\Logs", "$env:WINDIR\Debug") -Category 'Windows logs (Logs, Debug)' -MinAgeDays 30 -Floor 3
        Clear-StaleFiles -RequiresAdmin -Path @("$env:ProgramData\USOShared\Logs") -Category 'Update orchestrator logs' -MinAgeDays 30 -Floor 3
        Clear-StaleFiles -RequiresAdmin -Path @("$env:ProgramData\Microsoft\Diagnosis\ETLLogs") -Filter '*.etl' -Category 'Diagnostic / telemetry traces' -MinAgeDays 30 -Floor 3
        # Web caches of Windows' own service accounts - Disk Cleanup only cleans yours.
        Clear-StaleFiles -RequiresAdmin -Category 'Windows service web caches' -MinAgeDays 14 -Floor 1 -Path @(
            "$env:WINDIR\System32\config\systemprofile\AppData\Local\Microsoft\Windows\INetCache",
            "$env:WINDIR\SysWOW64\config\systemprofile\AppData\Local\Microsoft\Windows\INetCache",
            "$env:WINDIR\ServiceProfiles\LocalService\AppData\Local\Microsoft\Windows\INetCache",
            "$env:WINDIR\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\INetCache")
        Clear-StaleFiles -RequiresAdmin -Path @("$env:WINDIR\System32\LogFiles\WMI\RtBackup") -Category 'WMI trace backups' -MinAgeDays 30 -Floor 3
        # Setup / upgrade logs; Windows only needs them for the 10-day rollback window.
        Clear-StaleFiles -RequiresAdmin -Path @("$env:WINDIR\Panther") -Filter '*.log' -Category 'Windows setup logs (Panther)' -MinAgeDays 30 -Floor 11
        Clear-StaleFiles -RequiresAdmin -Path @("$env:WINDIR\Panther") -Filter '*.etl' -Category 'Windows setup traces (Panther)' -MinAgeDays 30 -Floor 11
        Clear-StaleFiles -RequiresAdmin -Path @("$env:WINDIR\System32\winevt\Logs") -Filter 'Archive-*.evtx' -NoRecurse -Category 'Archived event logs' -MinAgeDays 30
        Clear-StaleFiles -RequiresAdmin -Path @("$env:SystemDrive\`$GetCurrent", "$env:SystemDrive\`$WinREAgent") -Category 'Update-assistant leftovers' -MinAgeDays 14 -Floor 7
        Clear-StaleFiles -RequiresAdmin -Path @("$env:SystemDrive\`$SysReset") -Category 'Failed PC-reset leftovers ($SysReset)' -MinAgeDays 14 -Floor 7
        Clear-StaleFiles -RequiresAdmin -Path @("$env:WINDIR\System32\spool\PRINTERS") -Category 'Stuck print jobs' -MinAgeDays 7 -Floor 1
        Clear-StaleFiles -Path @("$env:LOCALAPPDATA\Packages\*\TempState", "$env:LOCALAPPDATA\Packages\*\AC\Temp", "$env:LOCALAPPDATA\Packages\*\AC\INetCache") `
            -Category 'Store app temp & web cache' -MinAgeDays 7 -Floor 1
        Clear-StaleFiles -Path @("$env:LOCALAPPDATA\Microsoft\Terminal Server Client\Cache") -Category 'RDP bitmap cache' -MinAgeDays 30 -Processes @('mstsc')
        Clear-StaleFiles -Path @("$env:LOCALAPPDATA\CrashDumps") -Category 'App crash dumps' -MinAgeDays 14
        Clear-StaleFiles -Path @("$env:LOCALAPPDATA\Microsoft\OneDrive\logs", "$env:LOCALAPPDATA\Microsoft\OneDrive\setup\logs") -Category 'OneDrive logs' -MinAgeDays 30 -Floor 3
        # Graphics drivers: installer extracts left on C:\ and shader caches of unused games.
        Clear-StaleFiles -Path @("$env:ProgramData\NVIDIA Corporation\Downloader", "$env:SystemDrive\NVIDIA", "$env:SystemDrive\AMD") -Category 'Graphics driver installer leftovers' -MinAgeDays 7
        Clear-StaleFiles -Path @("$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\NVIDIA\GLCache", "$env:ProgramData\NVIDIA Corporation\NV_Cache",
            "$env:LOCALAPPDATA\AMD\DxCache", "$env:LOCALAPPDATA\AMD\DxcCache", "$env:LOCALAPPDATA\AMD\GLCache", "$env:LOCALAPPDATA\AMD\VkCache",
            "$env:LOCALAPPDATA\Intel\ShaderCache", "$env:USERPROFILE\AppData\LocalLow\Intel\ShaderCache") `
            -Category 'Graphics driver shader caches' -MinAgeDays 90 -MinTotalMB 1024
    }

    # ---------- Orphaned Windows Installer packages ----------
    if (Use-Group 'Installer') {
        $instDir = "$env:WINDIR\Installer"
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress') {
            Write-Log "  An installation is in progress - skipped for safety. Run again after it finishes." "Yellow"
        } else {
            if ($null -eq $script:InstallerRefs -or $script:InstallerRefs.Count -eq 0) { $script:InstallerRefs = Get-InstallerReferences }
            $refs = $script:InstallerRefs
            $pkgs = @((Get-FilesSafe -Root $instDir -NoRecurse) | Where-Object { $_.Extension -in @('.msi', '.msp') })
            $cutoff = (Get-Date).AddDays(-7)
            $orph = @($pkgs | Where-Object { -not $refs.Contains($_.FullName) -and $_.LastWriteTime -lt $cutoff })
            if ($refs.Count -eq 0) {
                Write-Log "  Could not read the Windows Installer database - skipped for safety." "Yellow"
            } elseif ($pkgs.Count -ge 10 -and $orph.Count -gt ($pkgs.Count * 0.8)) {
                Write-Log "  $($orph.Count) of $($pkgs.Count) packages look orphaned - that's implausible, so nothing will be touched." "Yellow"
            } elseif ($orph.Count -eq 0) {
                Write-Log "  No orphaned packages ($($pkgs.Count) packages, all referenced)." "DarkGray"
            } else {
                $sum = [int64]0; foreach ($o in $orph) { $sum += $o.Length }
                $how = if ($InstallerQuarantinePath) { "move to $InstallerQuarantinePath" } else { "delete" }
                Write-Log ("  {0} of {1} packages are orphaned: {2} ({3})" -f $orph.Count, $pkgs.Count, (Format-Size $sum), $how) "Green"
                if (-not $script:DryRun -and $InstallerQuarantinePath) { New-Item -ItemType Directory -Path $InstallerQuarantinePath -Force | Out-Null }
                foreach ($o in $orph) {
                    $len = $o.Length
                    if ($script:DryRun) {
                        Write-Detail "    $($o.Name)  $(Format-Size $len)" "DarkYellow"
                        Add-Freed -Bytes $len -Category 'Orphaned installer packages'
                        continue
                    }
                    try {
                        if ($InstallerQuarantinePath) { Move-Item -LiteralPath $o.FullName -Destination $InstallerQuarantinePath -Force -ErrorAction Stop }
                        elseif (-not (Remove-FileQuiet $o)) { throw }
                        Add-Freed -Bytes $len -Category 'Orphaned installer packages'
                    } catch { $script:Skipped++ }
                }
            }
        }
    }

    # ---------- $PatchCache$ ----------
    if (Use-Group 'PatchCache') {
        Clear-StaleFiles -RequiresAdmin -Path @("$env:WINDIR\Installer\`$PatchCache`$") -Category '$PatchCache$' -MinAgeDays 0
    }

    # ---------- Superseded drivers ----------
    if (Use-Group 'Drivers') {
        if ($null -eq $script:DriverList) {
            Write-Host "  (reading the driver store...)" -ForegroundColor DarkGray
            try { $script:DriverList = @(Get-WindowsDriver -Online -ErrorAction Stop) } catch { Write-Log "  Could not read the driver store: $($_.Exception.Message)" "Yellow" }
        }
        $drivers = if ($null -ne $script:DriverList) { $script:DriverList } else { @() }
        $groups = $drivers | Where-Object { $_.OriginalFileName } |
            Group-Object { "$([IO.Path]::GetFileName($_.OriginalFileName).ToLower())|$($_.ProviderName)|$($_.ClassName)" } |
            Where-Object { $_.Count -gt 1 }
        $found = 0
        foreach ($g in $groups) {
            $sorted = @($g.Group | Sort-Object @{ Expression = { try { [version]$_.Version } catch { [version]'0.0' } }; Descending = $true }, @{ Expression = { $_.Date }; Descending = $true })
            $keep = $sorted[0]
            foreach ($old in $sorted[1..($sorted.Count - 1)]) {
                $size = Get-FolderSize ([IO.Path]::GetDirectoryName($old.OriginalFileName))
                $desc = "{0} {1} v{2} ({3}) - newer v{4} kept" -f $old.ProviderName, $old.ClassName, $old.Version, $old.Date.ToString('yyyy-MM-dd'), $keep.Version
                $found++
                if ($script:DryRun) {
                    Write-Log ("    {0,-14} {1,10}  {2}" -f $old.Driver, (Format-Size $size), $desc) "DarkYellow"
                    Add-Freed -Bytes $size -Category 'Superseded drivers'
                } else {
                    $out = & pnputil.exe /delete-driver $old.Driver 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "    Removed $($old.Driver)  $desc" "DarkGray"
                        Add-Freed -Bytes $size -Category 'Superseded drivers'
                    } else {
                        Write-Log "    Kept $($old.Driver) - Windows reports it is still in use" "DarkGray"
                        $script:Skipped++
                    }
                }
            }
        }
        if ($found -eq 0) { Write-Log "  No superseded third-party drivers found." "DarkGray" }
    }

    # ---------- WinSxS ResetBase ----------
    if (Use-Group 'ResetBase') {
        if ($script:DryRun) {
            Write-Log "  Would run: Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase (several minutes)" "DarkYellow"
            Add-Pending
        } else {
            $free0 = (Get-SystemFreeBytes)
            [void](Invoke-DismFriendly -Arguments '/Online /Cleanup-Image /StartComponentCleanup /ResetBase' `
                -What 'WinSxS ResetBase: permanently removing every replaced Windows component version')
            $delta = (Get-SystemFreeBytes) - $free0
            if ($delta -ge 1MB) {
                Write-Log "    Freed ~$(Format-Size $delta)." "Green"
                Add-Freed -Bytes $delta -Category 'WinSxS ResetBase'
            } else {
                Write-Log "    Nothing measurable freed - Windows' own maintenance task had already removed the old versions." "DarkGray"
            }
        }
    }

    # ---------- WSL / Docker compaction ----------
    if (Use-Group 'WSL') {
        $disks = Get-WslDisks
        $minBytes = if ($script:Max) { 0 } else { 1GB }
        # Compaction needs 'wsl --shutdown', which also stops Docker Desktop's
        # engine - so nothing is compacted while Docker Desktop runs.
        $dockerRunning = Get-RunningProcess @('Docker Desktop', 'com.docker.backend')
        if ($dockerRunning -and $disks.Count -gt 0) {
            Write-Log "  skipped - Docker Desktop is running ('wsl --shutdown' would stop it). Quit it to compact." "Yellow"
            $disks = @()
        }
        $todo = @()
        foreach ($d in $disks) {
            $len = ([IO.FileInfo]::new($d.Path)).Length
            if ($len -lt $minBytes) { Write-Detail "  $($d.Name): $(Format-Size $len) - too small to bother"; continue }
            $todo += $d
            Write-Log ("  {0,-38} {1,10}  {2}" -f $d.Name, (Format-Size $len), $(if ($script:DryRun) { 'would trim + compact' } else { 'compacting...' })) "Green"
        }
        if ($script:DryRun) {
            if ($todo.Count -gt 0) { Add-Pending $todo.Count; Write-Log "  Note: this runs 'wsl --shutdown' - save work in any WSL terminals first." "DarkGray" }
        } elseif ($todo.Count -gt 0) {
            foreach ($d in ($todo | Where-Object { -not $_.Docker })) {
                & wsl.exe -d $d.Name -u root -e fstrim -a 2>&1 | Out-Null   # lets compaction actually reclaim deleted blocks
            }
            & wsl.exe --shutdown 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            foreach ($d in $todo) {
                if (Test-FileLocked $d.Path) { Write-Log "    $($d.Name): disk still in use - skipped" "Yellow"; continue }
                $before = ([IO.FileInfo]::new($d.Path)).Length
                # Commands go through stdin - no temporary script file on disk.
                "select vdisk file=`"$($d.Path)`"`r`nattach vdisk readonly`r`ncompact vdisk`r`ndetach vdisk`r`nexit`r`n" | & diskpart.exe 2>&1 | Out-Null
                $after = ([IO.FileInfo]::new($d.Path)).Length
                Write-Log ("    {0}: {1} -> {2}" -f $d.Name, (Format-Size $before), (Format-Size $after)) "DarkGray"
                Add-Freed -Bytes ($before - $after) -Category 'WSL/Docker compaction'
            }
        }
    }

    # ---------- Broken shortcuts ----------
    if (Use-Group 'Shortcuts') {
        $roots = @(
            "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
            "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
            [Environment]::GetFolderPath('Desktop')
            "$env:PUBLIC\Desktop"
            "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
        ) | Where-Object { $_ } | Select-Object -Unique
        # The real run removes exactly what the preview listed (re-checked first) -
        # a shortcut that broke after the preview is never removed unseen.
        if ($null -eq $script:BrokenShortcuts) {
            $script:BrokenShortcuts = [System.Collections.Generic.List[object]]::new()
            $shell = New-Object -ComObject WScript.Shell
            foreach ($root in $roots) {
                foreach ($lnk in (Get-FilesSafe -Root $root -Pattern '*.lnk')) {
                    try {
                        $target = $shell.CreateShortcut($lnk.FullName).TargetPath
                        if (Test-Missing $target) { $script:BrokenShortcuts.Add(@($lnk, $target)) }
                    } catch {}
                }
            }
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
        foreach ($b in $script:BrokenShortcuts) {
            $lnk = $b[0]; $target = $b[1]
            if ($script:DryRun) {
                Write-Log "  Would remove: $($lnk.FullName) -> $target" "DarkYellow"
                Add-Pending
            } elseif ((Test-Missing $target) -and (Remove-FileQuiet $lnk)) {
                Write-Log "  Removed: $($lnk.FullName) -> $target" "DarkGray"; $script:Removed++
            }
        }
        if ($script:BrokenShortcuts.Count -eq 0) { Write-Log "  None found." "DarkGray" }
    }

    # ---------- Registry & system hygiene ----------
    if (Use-Group 'Hygiene') {
        # The real run applies exactly what the preview listed - no re-scan, and
        # nothing found later can sneak in without having been shown.
        if ($null -eq $script:HygieneScan) {
            $script:HygieneScan = @{
                Uninst = @(Get-OrphanedUninstallEntries); AppPth = @(Get-OrphanedAppPathsEntries)
                Run    = @(Get-OrphanedRunEntries);       Mui    = @(Get-OrphanedMuiCacheEntries)
                Tasks  = @(Get-OrphanedScheduledTasks);   Fw     = @(Get-OrphanedFirewallRules)
                Compat = @(Get-OrphanedCompatEntries);    OpenW  = @(Get-OrphanedOpenWithEntries)
                Shared = @(Get-OrphanedSharedDllEntries); Fonts  = @(Get-OrphanedFontEntries)
                Shell  = @(Get-OrphanedShellExtensions)
            }
            $script:HygieneScan.SA = @(Get-OrphanedStartupApprovedEntries -RunOrphans $script:HygieneScan.Run)
        }
        $uninst = $script:HygieneScan.Uninst
        $apppth = $script:HygieneScan.AppPth
        $run    = $script:HygieneScan.Run
        $mui    = $script:HygieneScan.Mui
        $tasks  = $script:HygieneScan.Tasks
        $fw     = $script:HygieneScan.Fw
        # Newer checks: value entries (remove one value) and key entries (remove the key)
        $valueItems = @($script:HygieneScan.SA) + @($script:HygieneScan.Compat) + @($script:HygieneScan.Shared) + @($script:HygieneScan.Fonts)
        $keyItems   = @($script:HygieneScan.OpenW) + @($script:HygieneScan.Shell)
        $all = @(
            @{ Name = 'Uninstall entries';   Items = $uninst }
            @{ Name = 'App Paths entries';   Items = $apppth }
            @{ Name = 'Run/RunOnce entries'; Items = $run }
            @{ Name = 'MuiCache entries';    Items = $mui }
            @{ Name = 'Scheduled tasks';     Items = $tasks }
            @{ Name = 'Firewall rules';      Items = $fw }
            @{ Name = 'Startup on/off switches';  Items = $script:HygieneScan.SA }
            @{ Name = 'Compatibility records';    Items = $script:HygieneScan.Compat }
            @{ Name = '"Open with" programs';     Items = $script:HygieneScan.OpenW }
            @{ Name = 'SharedDLLs counters';      Items = $script:HygieneScan.Shared }
            @{ Name = 'Font registrations';       Items = $script:HygieneScan.Fonts }
            @{ Name = 'Right-click menu handlers'; Items = $script:HygieneScan.Shell }
        )
        $total = 0
        foreach ($g in $all) {
            Write-Log "  $($g.Name): $($g.Items.Count) orphaned" "DarkCyan"
            foreach ($i in $g.Items) { Write-Log "    - $($i.Label)  [$($i.Reason)]" "DarkGray" }
            $total += $g.Items.Count
        }
        if (-not $IsAdmin) { Write-Log "  (firewall rules need Administrator to check)" "DarkGray" }

        if ($script:DryRun) {
            if ($total -gt 0) { Add-Pending $total }
        } elseif ($total -gt 0) {
            $backupOk = $true
            if ($script:DoRegistryBackup) {
                # The real Desktop - it is often moved into OneDrive.
                $bk = "$([Environment]::GetFolderPath('Desktop'))\DeepClean_Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                New-Item -ItemType Directory -Path $bk -Force | Out-Null
                Write-Log "  Backing up to: $bk" "Yellow"
                $regKeys = @(
                    @{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';             File = 'Uninstall_HKLM.reg';      Need = $uninst }
                    @{ Path = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; File = 'Uninstall_HKLM_WOW.reg';  Need = $uninst }
                    @{ Path = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';             File = 'Uninstall_HKCU.reg';      Need = $uninst }
                    @{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths';             File = 'AppPaths_HKLM.reg';       Need = $apppth }
                    @{ Path = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths';             File = 'AppPaths_HKCU.reg';       Need = $apppth }
                    @{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                   File = 'Run_HKLM.reg';            Need = $run }
                    @{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';               File = 'RunOnce_HKLM.reg';        Need = $run }
                    @{ Path = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';       File = 'Run_HKLM_WOW.reg';        Need = $run }
                    @{ Path = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                   File = 'Run_HKCU.reg';            Need = $run }
                    @{ Path = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';               File = 'RunOnce_HKCU.reg';        Need = $run }
                    @{ Path = 'HKCU\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache'; File = 'MuiCache.reg';  Need = $mui }
                )
                foreach ($k in $regKeys) {
                    if ($k.Need.Count -eq 0) { continue }
                    $psPath = $k.Path -replace '^HKLM', 'HKLM:' -replace '^HKCU', 'HKCU:'
                    if (-not (Test-Path $psPath)) { continue }
                    $out = & reg.exe export "$($k.Path)" "$bk\$($k.File)" /y 2>&1
                    if ($LASTEXITCODE -ne 0) { $backupOk = $false; Write-Log "    Backup failed for $($k.Path): $out" "Yellow" }
                }
                foreach ($t in $tasks) {
                    try {
                        $safe = ($t.Label -replace '[\\/:*?"<>|]', '_').Trim('_')
                        Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-File -LiteralPath "$bk\Task_$safe.xml" -Encoding unicode
                    } catch { $backupOk = $false; Write-Log "    Backup failed for task $($t.Label)" "Yellow" }
                }
                # Each key touched by the newer checks, exported on its own.
                $n = 0
                foreach ($kp in @(@($valueItems + $keyItems) | ForEach-Object { $_.KeyPath } | Select-Object -Unique)) {
                    $n++
                    $out = & reg.exe export "$(ConvertTo-RegExePath $kp)" "$bk\Key_$n.reg" /y 2>&1
                    if ($LASTEXITCODE -ne 0) { $backupOk = $false; Write-Log "    Backup failed for $(ConvertTo-RegExePath $kp): $out" "Yellow" }
                }
                if ($fw.Count -gt 0) {
                    & netsh.exe advfirewall export "$bk\firewall_policy.wfw" 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { $backupOk = $false; Write-Log "    Firewall backup failed" "Yellow" }
                }
            } else {
                Write-Log "  Proceeding WITHOUT a backup, as you requested." "Yellow"
            }

            if ($script:DoRegistryBackup -and -not $backupOk) {
                Write-Log "  A backup failed - skipping all hygiene changes this run to be safe." "Red"
            } else {
                $fixed = 0; $muiFixed = 0
                foreach ($i in ($uninst + $apppth)) {
                    try { Remove-Item -LiteralPath $i.KeyPath -Recurse -Force -ErrorAction Stop; $fixed++; Write-Detail "    Removed key: $($i.KeyPath)" }
                    catch { Write-Log "    Could not remove: $($i.Label)" "Yellow" }
                }
                foreach ($i in $run) {
                    if (Remove-RegistryValueDirect -KeyPath $i.KeyPath -ValueName $i.Label) { $fixed++ } else { Write-Log "    Could not remove value: $($i.Label)" "Yellow" }
                }
                foreach ($i in $mui) {
                    if (Remove-RegistryValueDirect -KeyPath $i.KeyPath -ValueName $i.Label) { $fixed++; $muiFixed++ } else { Write-Log "    Could not remove value: $($i.Label)" "Yellow" }
                }
                foreach ($t in $tasks) {
                    try { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop; $fixed++ }
                    catch { Write-Log "    Could not remove task: $($t.Label)" "Yellow" }
                }
                foreach ($r in $fw) {
                    try { Remove-NetFirewallRule -Name $r.RuleId -ErrorAction Stop; $fixed++ }
                    catch { Write-Log "    Could not remove firewall rule: $($r.Label)" "Yellow" }
                }
                foreach ($i in $valueItems) {
                    if (Remove-RegistryValueDirect -KeyPath $i.KeyPath -ValueName $i.Label) { $fixed++ } else { Write-Log "    Could not remove value: $($i.Label)" "Yellow" }
                }
                foreach ($i in $keyItems) {
                    try { Remove-Item -LiteralPath $i.KeyPath -Recurse -Force -ErrorAction Stop; $fixed++ }
                    catch { Write-Log "    Could not remove: $($i.Label)" "Yellow" }
                }
                $script:Removed += $fixed
                Write-Log "  Removed $fixed of $total orphaned item(s)." "Green"
                if ($script:DoRegistryBackup) { Write-Log "  Restore: double-click the .reg files / import the task XML / 'netsh advfirewall import' from $bk" "DarkGray" }

                if ($muiFixed -gt 0) {
                    Write-Log "  Explorer keeps MuiCache in memory and may write stale values back until it restarts." "DarkGray"
                    if (-not $Unattended -and (Read-YesNo -Prompt "  Restart Windows Explorer now? (screen flickers briefly, nothing else closes)" -Default 'Y')) {
                        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 2
                        if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
                        Write-Log "  Explorer restarted." "DarkGray"
                    }
                }
            }
        }
    }

    # ---------- Insight reports (preview only) ----------
    if ($script:DryRun -and (Use-Group 'Reports')) {
        $scan = Invoke-ProfileScan

        Write-Log "  Largest files in your profile (>= $LargeFileMB MB):" "Green"
        $big = @($scan.Large | Sort-Object Length -Descending | Select-Object -First 20)
        if ($big.Count -eq 0) { Write-Log "    none" "DarkGray" }
        foreach ($f in $big) { Write-Log ("    {0,10}  {1}  (modified {2:yyyy-MM-dd})" -f (Format-Size $f.Length), $f.FullName, $f.LastWriteTime) "DarkCyan" }

        Write-Log ""
        Write-Log "  Possible leftover folders from uninstalled apps (>= 25 MB, idle 60+ days - verify before deleting):" "Green"
        # Queried once, used for both the leftover-folder and the dead-service report.
        $services = try { @(Get-CimInstance Win32_Service -ErrorAction Stop) } catch { @() }
        $index = Get-InstalledNameIndex -Services $services
        $whitelist = @('Common Files', 'Internet Explorer', 'Windows Defender', 'WindowsApps', 'Microsoft', 'Windows', 'Windows NT',
            'Uninstall Information', 'Package Cache', 'PackageCache', 'USOShared', 'USOPrivate', 'Microsoft.NET', 'ModifiableWindowsApps',
            'WindowsPowerShell', 'Windows Mail', 'Windows Media Player', 'Windows Photo Viewer', 'Windows Portable Devices', 'Windows Sidebar',
            'Reference Assemblies', 'MSBuild', 'dotnet', 'Packages', 'Temp', 'Programs', 'Comms', 'ConnectedDevicesPlatform', 'D3DSCache',
            'CrashDumps', 'PeerDistRepub', 'Publishers', 'VirtualStore', 'PlaceholderTileLogoFolder', 'Application Data', 'History',
            'Temporary Internet Files', 'Desktop', 'Documents', 'Start Menu', 'Templates', 'regid.1991-06.com.microsoft', 'ssh', 'SoftwareDistribution',
            'npm', 'npm-cache', 'pip', 'NuGet', 'Python', 'ToastNotificationManagerCompat', 'Setup', 'speech', 'Microsoft Help')
        $leftovers = @()
        $cut60 = (Get-Date).AddDays(-60)
        foreach ($root in (@(${env:ProgramFiles}, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA) | Where-Object { $_ } | Select-Object -Unique)) {
            try { $dirs = ([IO.DirectoryInfo]::new($root)).GetDirectories() } catch { continue }
            foreach ($d in $dirs) {
                if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($whitelist -contains $d.Name -or $d.Name.StartsWith('.') -or $d.LastWriteTime -gt $cut60) { continue }
                $norm = ConvertTo-NormName $d.Name
                if ($norm.Length -lt 3) { continue }
                $matched = $false
                foreach ($n in $index) { if ($n.Contains($norm) -or ($n.Length -ge 4 -and $norm.Contains($n))) { $matched = $true; break } }
                if ($matched) { continue }
                $sz = Get-FolderSize $d.FullName
                if ($sz -ge 25MB) { $leftovers += [PSCustomObject]@{ Path = $d.FullName; Size = $sz; Last = $d.LastWriteTime } }
            }
        }
        $leftovers = @($leftovers | Sort-Object Size -Descending | Select-Object -First 25)
        if ($leftovers.Count -eq 0) { Write-Log "    none" "DarkGray" }
        foreach ($l in $leftovers) { Write-Log ("    {0,10}  {1}  (modified {2:yyyy-MM-dd})" -f (Format-Size $l.Size), $l.Path, $l.Last) "DarkCyan" }

        Write-Log ""
        Write-Log "  Space Windows doesn't show you (only listed - change it yourself if you want):" "Green"
        $hidden = @(
            @{ Name = 'Hibernation file'; Path = "$env:SystemDrive\hiberfil.sys"; Tip = "only for Hibernate / Fast Startup - 'powercfg /h off' removes it" }
            @{ Name = 'Page file';        Path = "$env:SystemDrive\pagefile.sys"; Tip = 'virtual memory - managed by Windows, best left alone' }
            @{ Name = 'Swap file';        Path = "$env:SystemDrive\swapfile.sys"; Tip = 'used by Store apps - managed by Windows' }
            @{ Name = 'Search index';     Path = "$env:ProgramData\Microsoft\Search\Data\Applications\Windows"; Tip = 'over 2 GB is unusual - Indexing Options > Advanced > Rebuild' }
        )
        $shownHidden = 0
        foreach ($h in $hidden) {
            $size = if ([IO.File]::Exists($h.Path)) { ([IO.FileInfo]::new($h.Path)).Length } elseif ([IO.Directory]::Exists($h.Path)) { Get-FolderSize $h.Path } else { 0 }
            if ($size -ge 100MB) { $shownHidden++; Write-Log ("    {0,10}  {1,-17} {2}" -f (Format-Size $size), $h.Name, $h.Tip) "DarkCyan" }
        }
        if ($IsAdmin) {
            $restore = [int64]0
            foreach ($s in @(Get-CimInstance Win32_ShadowStorage -ErrorAction SilentlyContinue)) { $restore += [int64]$s.UsedSpace }
            if ($restore -ge 100MB) {
                $shownHidden++
                Write-Log ("    {0,10}  {1,-17} {2}" -f (Format-Size $restore), 'Restore points', "System Restore snapshots - Control Panel > System Protection > Configure") "DarkCyan"
            }
        }
        if ($IsAdmin) {
            $rs = (& "$env:WINDIR\System32\Dism.exe" /Online /Get-ReservedStorageState /English 2>$null) -join ' '
            if ($rs -match 'Reserved storage is enabled') {
                $shownHidden++
                Write-Log ("    {0,10}  {1,-17} {2}" -f '~7 GB', 'Reserved storage', "kept free for updates - 'DISM /Online /Set-ReservedStorageState /State:Disabled' releases it") "DarkCyan"
            }
        }
        if ($shownHidden -eq 0) { Write-Log "    nothing over 100 MB" "DarkGray" }

        Write-Log ""
        Write-Log "  What starts with Windows (only listed - turn items off in Task Manager > Startup apps, or services.msc):" "Green"
        # Task Manager's on/off state: first byte even = on, odd = off.
        $approved = @{}
        foreach ($hive in 'HKCU', 'HKLM') {
            foreach ($sub in 'Run', 'Run32', 'StartupFolder') {
                try {
                    $k = Get-Item -Path "${hive}:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$sub" -ErrorAction Stop
                    foreach ($n in $k.GetValueNames()) { $b = $k.GetValue($n); if ($b -is [byte[]] -and $b.Length) { $approved[$n] = (($b[0] -band 1) -eq 0) } }
                } catch {}
            }
        }
        $startup = [System.Collections.Generic.List[object]]::new()
        foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
                         'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')) {
            try { $key = Get-Item -Path $k -ErrorAction Stop } catch { continue }
            foreach ($n in $key.GetValueNames()) {
                if ($n) { $startup.Add([PSCustomObject]@{ On = $(if ($approved.ContainsKey($n)) { $approved[$n] } else { $true }); Name = $n; Kind = 'startup app' }) }
            }
        }
        foreach ($dir in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
            if (-not $dir -or -not [IO.Directory]::Exists($dir)) { continue }
            foreach ($f in [IO.Directory]::EnumerateFiles($dir)) {
                $n = [IO.Path]::GetFileName($f)
                if ($n -ne 'desktop.ini') { $startup.Add([PSCustomObject]@{ On = $(if ($approved.ContainsKey($n)) { $approved[$n] } else { $true }); Name = $n; Kind = 'startup folder' }) }
            }
        }
        try {
            foreach ($t in (Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' })) {
                $kinds = @($t.Triggers | ForEach-Object { $_.CimClass.CimClassName })
                if ($kinds -contains 'MSFT_TaskLogonTrigger' -or $kinds -contains 'MSFT_TaskBootTrigger') {
                    $startup.Add([PSCustomObject]@{ On = $true; Name = "$($t.TaskPath)$($t.TaskName)"; Kind = 'task at sign-in/boot (not in Task Manager)' })
                }
            }
        } catch {}
        foreach ($s in $services) {
            if ($s.StartMode -ne 'Auto' -or -not $s.PathName) { continue }
            $exe = [Environment]::ExpandEnvironmentVariables(($s.PathName -replace '^"([^"]+)".*$', '$1'))
            # Windows' own services (incl. Defender, which lives under ProgramData\Microsoft)
            if ($exe -like "$env:WINDIR\*" -or $exe -like "$env:ProgramData\Microsoft\*" -or $exe -like "$env:ProgramFiles\Windows Defender*" -or $exe -notmatch '^[A-Za-z]:\\') { continue }
            $startup.Add([PSCustomObject]@{ On = ($s.State -eq 'Running'); Name = "$($s.DisplayName) ($($s.Name))"; Kind = 'auto-start service (not in Task Manager)' })
        }
        $onCount = @($startup | Where-Object { $_.On }).Count
        Write-Log "    $onCount active of $($startup.Count) - fewer active items = faster sign-in" "DarkGray"
        foreach ($s in ($startup | Sort-Object @{ Expression = 'On'; Descending = $true }, Kind, Name | Select-Object -First 40)) {
            Write-Log ("    {0,-4} {1}  [{2}]" -f $(if ($s.On) { 'on' } else { 'off' }), $s.Name, $s.Kind) $(if ($s.On) { 'DarkCyan' } else { 'DarkGray' })
        }
        if ($startup.Count -gt 40) { Write-Log "    ... and $($startup.Count - 40) more" "DarkGray" }

        Write-Log ""
        Write-Log "  Services whose program no longer exists:" "Green"
        $svcCount = 0
        foreach ($s in $services) {
            $pn = $s.PathName
            if (-not $pn) { continue }
            if ($pn -match '^"([^"]+)"') { $exe = $matches[1] } elseif ($pn -match '^(.+?\.(exe|sys))(\s|$)') { $exe = $matches[1] } else { continue }
            $exe = [Environment]::ExpandEnvironmentVariables($exe) -replace '^\\\?\?\\', '' -replace '^\\SystemRoot', $env:WINDIR
            if (Test-Missing $exe) { $svcCount++; Write-Log "    $($s.Name) ($($s.DisplayName)) -> $exe   [remove with: sc.exe delete `"$($s.Name)`"]" "DarkCyan" }
        }
        if ($svcCount -eq 0) { Write-Log "    none" "DarkGray" }
    }

    if ($script:DryRun -and (Use-Group 'Duplicates')) {
        $scan = Invoke-ProfileScan
        Write-Host "  (hashing candidates...)" -ForegroundColor DarkGray
        $md5 = [Security.Cryptography.MD5]::Create()
        $buf = New-Object byte[] 65536
        $dupGroups = @()
        foreach ($sg in ($scan.DupCandidates | Group-Object Length | Where-Object { $_.Count -gt 1 })) {
            $byHead = @{}
            foreach ($f in $sg.Group) {
                try {
                    $fs = [IO.File]::OpenRead($f.FullName)
                    try { $n = $fs.Read($buf, 0, $buf.Length); $h = [BitConverter]::ToString($md5.ComputeHash($buf, 0, $n)) } finally { $fs.Close() }
                    if (-not $byHead.ContainsKey($h)) { $byHead[$h] = @() }
                    $byHead[$h] += $f
                } catch {}
            }
            foreach ($hg in ($byHead.Values | Where-Object { $_.Count -gt 1 })) {
                foreach ($fg in ($hg | Group-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash } | Where-Object { $_.Name -and $_.Count -gt 1 })) {
                    $dupGroups += [PSCustomObject]@{ Size = $fg.Group[0].Length; Files = $fg.Group; Wasted = $fg.Group[0].Length * ($fg.Count - 1) }
                }
            }
        }
        $md5.Dispose()
        $wasted = [int64]0; foreach ($dg in $dupGroups) { $wasted += $dg.Wasted }
        Write-Log "  $($dupGroups.Count) duplicate group(s), $(Format-Size $wasted) wasted$(if ($dupGroups.Count -gt 0) { '. Largest:' })" "Green"
        foreach ($dg in ($dupGroups | Sort-Object Wasted -Descending | Select-Object -First 25)) {
            Write-Log ("    {0} x {1}:" -f $dg.Files.Count, (Format-Size $dg.Size)) "DarkCyan"
            foreach ($f in $dg.Files) { Write-Log "        $($f.FullName)" "DarkGray" }
        }
    }

    # ---------- Pass summary ----------
    Write-Log ""
    Write-Log $Rule "DarkCyan"
    Write-Log "  $tag summary" "Cyan"
    Write-Log "Items $(if ($script:DryRun) { 'that would be removed' } else { 'removed' }): $($script:Removed)   | skipped (in use): $($script:Skipped)$(if (-not $script:DryRun) { "   | empty folders pruned: $($script:EmptyFolders)" })"
    Write-Log "Space $(if ($script:DryRun) { 'that would be freed' } else { 'freed' }): $(Format-Size $script:BytesFreed)"
    if (@($script:CategoryTotals.Values | Where-Object { $_ -gt 0 }).Count -gt 0) {
        Write-Log "By category:"
        foreach ($c in ($script:CategoryTotals.GetEnumerator() | Sort-Object Value -Descending)) {
            if ($c.Value -gt 0) { Write-Log ("  {0,-40} {1,10}" -f $c.Key, (Format-Size $c.Value)) }
        }
    }
}

# ==========================================
# START
# ==========================================

Write-Host ""
Write-Host " DeepClean v1.0 " -NoNewline -ForegroundColor Black -BackgroundColor Cyan
Write-Host "  cleans what Windows' own cleanup misses" -ForegroundColor Cyan
Write-Host "  Temp, Recycle Bin, Update cache, thumbnails, Windows.old... are left to Windows itself." -ForegroundColor DarkGray

# Arguments to start this script again in Windows PowerShell with the same parameters.
function Get-RelaunchArgs {
    $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($kv in $script:BoundParams.GetEnumerator()) {
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) { if ($kv.Value.IsPresent) { $list += "-$($kv.Key)" } }
        elseif ($kv.Value -is [array]) { $list += "-$($kv.Key)"; $list += "`"$($kv.Value -join ';')`"" }
        else { $list += "-$($kv.Key)"; $list += "`"$($kv.Value)`"" }
    }
    return $list
}
$script:BoundParams = $PSBoundParameters
$WinPS = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"

# Built for Windows PowerShell 5.1 (part of every Windows 10/11); PowerShell 7 lacks
# some of the Windows modules used here, so hand over to the built-in one.
if ($PSVersionTable.PSEdition -eq 'Core' -and $PSCommandPath) {
    Start-Process $WinPS -ArgumentList (Get-RelaunchArgs) -NoNewWindow -Wait
    exit
}

if (-not $IsAdmin -and -not $Unattended) {
    Write-Host ""
    Write-Host "Not running as Administrator - some cleanups (system files, installers, drivers, WSL) need it." -ForegroundColor Yellow
    if ($PSCommandPath -and (Read-YesNo -Prompt "Restart as Administrator now? (Windows will ask for permission)" -Default 'Y')) {
        try {
            Start-Process $WinPS -Verb RunAs -ArgumentList (Get-RelaunchArgs) -ErrorAction Stop
            exit
        } catch { Write-Host "Not allowed - continuing without Administrator." -ForegroundColor Yellow }
    }
}

# ---------- Wizard ----------
Write-Host ""
if (-not $Intensity) {
    if ($Defaults) { $Intensity = 'Balanced' }
    else {
      # 'w' opens the Windows tools menu; leaving it comes back to this question.
      do {
        Write-Step 1 'How old must files be before they are removed?'
        Write-Host "  1  Balanced (recommended) - only cache, temp and log files unused for a while." -ForegroundColor Green
        Write-Host "  2  Maximum - any age, as long as they are not in use; frees the most." -ForegroundColor Yellow
        Write-Host "  What gets cleaned (caches, logs, installers, drivers, registry...) you choose next." -ForegroundColor Gray
        Write-Host ""
        $pick = Read-Choice -Prompt "Which one?" -Default '1' -Choices @(
            @('1', 'Balanced', 'Green'), @('2', 'Maximum', 'Yellow'), @('w', 'Windows tools', 'Magenta')) -Help @(
            'This choice only sets HOW OLD cache, temp and log files must be before they are removed.'
            'WHAT gets cleaned - caches, logs, leftover installer files, old drivers, registry entries,'
            'shortcuts... - you decide in the next questions.'
            ''
            'Balanced: only files unused for a while (e.g. browser cache 7+ days, logs 30+ days,'
            '          game shaders 90+ days). What you use daily stays, so apps start as fast as before.'
            'Maximum:  any age, as long as the file is not in use right now. Frees the most, but'
            '          browsers, apps and games start slower once while they rebuild their cache.'
            ''
            'A cache is a copy of something an app already downloaded or built (website images,'
            'game shaders, packages...). Removing it loses no settings, logins or personal files.'
            ''
            'w opens a separate menu of Windows'' own tools (Disk Cleanup, DISM, SFC, CHKDSK...).')
        if ($pick -eq 'w') { Invoke-WindowsTools; Write-Host "" }
      } while ($pick -eq 'w')
        $Intensity = if ($pick -eq '2') { 'Maximum' } else { 'Balanced' }
        Write-Host "  -> $Intensity" -ForegroundColor Cyan
    }
}
$script:Max = ($Intensity -eq 'Maximum')

$script:WslDiskCount = (Get-WslDisks).Count
Write-Host ""
Write-Step 2 'What should be cleaned?'
Write-Host "  Press Enter to accept the answer shown, or type the other letter shown to change it." -ForegroundColor Gray
Write-Host "  Where you see '? = explain', type ? to learn more before answering." -ForegroundColor Gray
Write-Host "  You will see a preview first - nothing will be deleted in the preview." -ForegroundColor Gray
Write-Host ""
foreach ($key in $GroupDefs.Keys) {
    $g = $GroupDefs[$key]
    if ($key -eq 'WSL' -and $script:WslDiskCount -eq 0) { $script:Selected[$key] = $false; continue }
    if ($g.Admin -and -not $IsAdmin) {
        Write-Host "  - $($g.Title): skipped (needs Administrator)" -ForegroundColor DarkGray
        $script:Selected[$key] = $false
        continue
    }
    if ($Defaults) { $script:Selected[$key] = ($g.Default -eq 'Y') }
    else {
        # Explanations stay hidden unless asked for with '?'.
        $script:Selected[$key] = Read-YesNo -Prompt $g.Prompt -Default $g.Default -Help $g.Explain
    }
}

$freeBefore = @{}
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object { $freeBefore[$_.DeviceID] = [int64]$_.FreeSpace }

# ---------- Preview ----------
Write-Step 3 'Preview - nothing is deleted yet'
Reset-Stats
$script:DryRun = $true
Invoke-CleanupPass

$previewBytes   = $script:BytesFreed
$previewGroups  = @{}; foreach ($k in $script:GroupBytes.Keys) { $previewGroups[$k] = $script:GroupBytes[$k] }
$previewPending = @{}; foreach ($k in $script:GroupPending.Keys) { $previewPending[$k] = $script:GroupPending[$k] }

$actionable = @($GroupDefs.Keys | Where-Object {
    $script:Selected[$_] -and -not $GroupDefs[$_].Report -and (($previewGroups[$_] -gt 0) -or ($previewPending[$_] -gt 0))
})

Write-Host ""
Write-Host $Rule -ForegroundColor DarkCyan
$proceed = $false
$hasPending = @($actionable | Where-Object { $previewPending[$_] -gt 0 }).Count -gt 0
if ($actionable.Count -eq 0) {
    Write-Log "Nothing to clean - your system is already tidy." "Yellow"
} elseif ($previewBytes -lt ($GlobalMinBenefitMB * 1MB) -and -not $hasPending) {
    Write-Log "Only $(Format-Size $previewBytes) is reclaimable - below the $GlobalMinBenefitMB MB minimum-benefit threshold. System left untouched." "Yellow"
} else {
    Write-Log "Ready to apply:" "Cyan"
    $biggest = [double](@($actionable | ForEach-Object { [double]$previewGroups[$_] }) | Measure-Object -Maximum).Maximum
    foreach ($k in $actionable) {
        $b = if ($previewGroups[$k] -gt 0) { Format-Size $previewGroups[$k] } else { '-' }
        $p = if ($previewPending[$k] -gt 0) { "$($previewPending[$k]) item(s)" } else { '' }
        Write-Log ("  {0,-40} {1,10}  {2}  {3}" -f $GroupDefs[$k].Title, $b, (Format-Bar ([double]$previewGroups[$k]) $biggest), $p)
    }
    Write-Log ("  {0,-40} {1,10}" -f 'TOTAL', (Format-Size $previewBytes)) "Cyan"
    Write-Host ""
    $choice = Read-Choice -Prompt "Apply these changes?" -Default 'a' -Choices @(
        @('a', 'apply all', 'Green'), @('c', 'choose one by one', 'Yellow'), @('n', 'cancel', 'Red'))
    if ($choice -eq 'a') {
        foreach ($k in $actionable) { [void]$script:Approved.Add($k) }
    } elseif ($choice -eq 'c') {
        foreach ($k in $actionable) {
            if (Read-YesNo -Prompt "  Apply '$($GroupDefs[$k].Title)'?" -Default 'Y') { [void]$script:Approved.Add($k) }
        }
    }
    $proceed = $script:Approved.Count -gt 0
}

if (-not $proceed) {
    Write-Log ""
    Write-Log "DeepClean changed nothing." "Yellow"
} else {
    if ($script:Approved.Contains('Hygiene')) {
        $script:DoRegistryBackup = Read-YesNo -Prompt "Back up registry keys, scheduled tasks and firewall policy to your Desktop first (strongly recommended)?" -Default 'Y'
    }
    Reset-Stats
    $script:DryRun = $false
    Invoke-CleanupPass
}
$script:StaleCache.Clear()   # free the preview's file lists

if ($proceed) {
    Write-Log ""
    Write-Log "Actual free-space change:" "Cyan"
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object {
        if ($freeBefore.ContainsKey($_.DeviceID)) {
            $delta = [int64]$_.FreeSpace - $freeBefore[$_.DeviceID]
            if ([math]::Abs($delta) -ge 1MB) { Write-Log ("  {0}  {1}{2}   (now {3} free)" -f $_.DeviceID, $(if ($delta -ge 0) { '+' } else { '-' }), (Format-Size ([math]::Abs($delta))), (Format-Size $_.FreeSpace)) "Green" }
        }
    }
}

# ==========================================
# LOG EXPORT
# ==========================================

Write-Host ""
# Nothing is written to disk unless asked; scheduled (-Unattended) runs keep a report.
if (Read-YesNo -Prompt "Save a report of what was done to your Desktop?" -Default $(if ($Unattended) { 'Y' } else { 'N' })) {
    try {
        $script:LogBuffer | Out-File -LiteralPath $LogPath -Encoding utf8 -ErrorAction Stop
        Write-Host "Report saved to: $LogPath" -ForegroundColor Cyan
    } catch {
        Write-Host "Could not save the report: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
Write-Host ""
Write-Host "Done. DeepClean v1.0" -ForegroundColor Cyan
# Keeps a double-clicked window open so the result can be read.
if (-not $Unattended) { Read-Host "Press Enter to close" | Out-Null }
