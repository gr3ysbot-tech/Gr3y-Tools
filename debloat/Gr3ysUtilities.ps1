<#
.SYNOPSIS
    Gr3yLabs Support - native Windows GUI for Dell/Lenovo debloat, Microsoft 365 Apps
    for business deploy, and a categorized app install catalog.

.DESCRIPTION
    Five tabs:
      1. Debloat + Office - same engine as Deploy-DellOfficeSetup.ps1 (must sit next to
         this script), driven through checkboxes instead of a command line, with live
         log streaming and a CPU-activity heartbeat across the whole process tree.
      2. Install Apps - a categorized winget-backed install catalog loaded from
         apps-catalog.json (must also sit next to this script), including a
         Non-Silent Installs category for direct-download entries with no winget
         package. Edit that JSON file to add/remove/rename entries - no code changes
         needed.
      3. Config - one-click Fixes (System Repair, Network Reset, Windows Update Reset,
         Time Resync, .NET Framework 3.5 Enable, winget re-registration), Customize
         Preferences (reversible per-tweak toggles driven by tweaks.json, must also sit
         next to this script, with a Scan Current State button to refresh live), DNS
         presets, and Revert Last Run.
      4. Panels - direct shortcuts to built-in Windows applets (Computer Management,
         Control Panel, Programs and Features, Windows Firewall, and the like), plus a
         read-only BitLocker status scan and recovery key fetch.
      5. Provisioning - client profile save/load, hostname rename, OneDrive Known
         Folder Move, regional/power/lock baseline, OEM driver/BIOS updates, Windows
         Update to completion, validation report and handoff package generation, and
         post-provisioning cleanup.

    Launch via the repo's debloat.ps1 bootstrap (self-elevates, downloads all five
    files fresh, then runs this), or directly if already elevated:
        .\Gr3ysUtilities.ps1

.NOTES
    Requires Administrator and an STA PowerShell process (both handled automatically -
    this script re-launches itself if either is missing, so it's safe to double-click
    or run from a non-elevated/non-STA shell).
#>

[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$Commit = ''
)

# ============================================================================
# Elevation + STA self-relaunch (WPF requires STA; admin is required by the
# worker script). Safe even when this file is invoked some other way than via
# debloat.ps1, since debloat.ps1 already guarantees both before calling this.
# ============================================================================

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$needsElevation = -not (Test-IsAdmin)
$needsSTA = [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'

if ($needsElevation -or $needsSTA) {
    # -WindowStyle Hidden hides only the console host this relaunched process would
    # otherwise sit behind - the WPF window it goes on to show is a separate native
    # window and isn't affected by its own console's visibility. Without this, techs saw
    # an empty "Windows PowerShell" console sitting behind the GUI for the whole session.
    $relaunchArgs = @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', """$PSCommandPath""")
    if ($Version) { $relaunchArgs += @('-Version', $Version) }
    if ($Commit) { $relaunchArgs += @('-Commit', $Commit) }
    if ($needsElevation) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunchArgs -Verb RunAs
    } else {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunchArgs
    }
    exit
}

$ErrorActionPreference = 'Continue'

# Loaded up front (not just before XamlReader.Load below) since the file-existence
# checks right after this also show a MessageBox on failure, and referencing that
# type before its assembly is loaded would itself throw a confusing error exactly
# when something has already gone wrong.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$scriptDir = Split-Path -Parent $PSCommandPath
$deployScript = Join-Path $scriptDir 'Deploy-DellOfficeSetup.ps1'
$catalogPath = Join-Path $scriptDir 'apps-catalog.json'
$patternsPath = Join-Path $scriptDir 'bloat-patterns.json'
$logoPath = Join-Path $scriptDir 'gr3ylabs-logo.png'
$workDir = Join-Path $env:ProgramData 'DellOfficeDeploy'
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

# One-time cleanup of old run/fix/scan/winget logs on every GUI launch - this directory
# otherwise only ever grows, run after run, laptop after laptop.
Get-ChildItem -Path $workDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

if (-not (Test-Path $deployScript)) {
    [System.Windows.Forms.MessageBox]::Show("Deploy-DellOfficeSetup.ps1 not found next to this script at:`r`n$deployScript", 'Gr3y Tools', 'OK', 'Error') | Out-Null
    exit 1
}
if (-not (Test-Path $patternsPath)) {
    [System.Windows.Forms.MessageBox]::Show("bloat-patterns.json not found next to this script at:`r`n$patternsPath", 'Gr3y Tools', 'OK', 'Error') | Out-Null
    exit 1
}
$bloatPatterns = Get-Content -Path $patternsPath -Raw | ConvertFrom-Json

# ============================================================================
# Shared helpers (same logic as WebApp.ps1's browser-panel version, reused here
# since the process-launching / log-tailing / CPU-heartbeat mechanics don't
# depend on how the UI renders them).
# ============================================================================

function Get-SafeFileNamePart {
    param([string]$Value)
    if (-not $Value) { return 'Unknown' }
    $clean = ($Value -replace '[\\/:*?"<>|]', '') -replace '\s+', '-'
    $clean = $clean.Trim('-')
    if (-not $clean) { return 'Unknown' }
    return $clean
}

function Get-MachineTag {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $csProduct = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
    $mfr = if ($cs -and $cs.Manufacturer) { $cs.Manufacturer } else { 'UnknownMfr' }
    # Same Lenovo-specific source as Deploy-DellOfficeSetup.ps1's $machineModel - Model
    # is a machine-type code on Lenovo, not the name printed on the box.
    $model =
        if ($mfr -match 'Lenovo' -and $csProduct -and $csProduct.Version) { $csProduct.Version }
        elseif ($cs -and $cs.Model) { $cs.Model }
        else { 'UnknownModel' }
    $serial = if ($bios -and $bios.SerialNumber) { $bios.SerialNumber } else { 'UnknownSerial' }
    return "{0}_{1}-{2}_{3}" -f `
        (Get-SafeFileNamePart $env:COMPUTERNAME), `
        (Get-SafeFileNamePart $mfr), `
        (Get-SafeFileNamePart $model), `
        (Get-SafeFileNamePart $serial)
}

function Get-DescendantProcessIds {
    # Returns {ProcessId; CreationDate} objects, not bare ints - CreationDate lets a
    # caller that's about to Stop-Process confirm the PID still refers to the same
    # process it scanned a moment ago, not a different process that reused the PID
    # in between. The visited set is what actually matters for correctness though:
    # ParentProcessId is just whatever value was recorded at that process's creation -
    # if its original parent has since exited and Windows reused that PID for something
    # else entirely, a plain unguarded BFS can re-enqueue the same id forever.
    param([int]$RootId)
    $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId, CreationDate
    $byId = @{}
    foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
    $result = New-Object System.Collections.Generic.List[object]
    $visited = New-Object 'System.Collections.Generic.HashSet[int]'
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($RootId)
    [void]$visited.Add($RootId)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $creationDate = if ($byId.ContainsKey($current)) { $byId[$current].CreationDate } else { $null }
        $result.Add([PSCustomObject]@{ ProcessId = $current; CreationDate = $creationDate })
        foreach ($p in ($all | Where-Object { $_.ParentProcessId -eq $current })) {
            $childId = [int]$p.ProcessId
            if ($visited.Add($childId)) {
                $queue.Enqueue($childId)
            }
        }
    }
    return $result
}

function Stop-ProcessTreeSafely {
    # Re-checks each PID's CreationDate immediately before killing it - the scan and the
    # kill aren't atomic, and a short-lived descendant can exit and have its PID reused
    # by something unrelated in the gap between them. Without this, Stop could kill a
    # completely different process that just happened to land on a recently-freed PID.
    param([System.Collections.Generic.List[object]]$Descendants)
    foreach ($d in $Descendants) {
        try {
            $stillThere = Get-CimInstance Win32_Process -Filter "ProcessId=$($d.ProcessId)" -ErrorAction SilentlyContinue
            if ($stillThere -and $stillThere.CreationDate -eq $d.CreationDate) {
                Stop-Process -Id $d.ProcessId -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

$script:deployDescendantCache = $null
$script:deployDescendantCacheRootId = $null
$script:deployDescendantCacheTime = [DateTime]::MinValue

function Get-TreeCpuSeconds {
    # Walking the whole system process table (inside Get-DescendantProcessIds) is the
    # expensive part - caching the descendant list for ~10s instead of redoing it every
    # 1.2s timer tick cuts that cost by roughly 8x while Get-Process (cheap) still runs
    # fresh every tick for up-to-date CPU numbers.
    param([int]$RootId)
    $stale = ($script:deployDescendantCacheRootId -ne $RootId) -or (((Get-Date) - $script:deployDescendantCacheTime).TotalSeconds -ge 10)
    if ($stale) {
        $script:deployDescendantCache = Get-DescendantProcessIds -RootId $RootId
        $script:deployDescendantCacheRootId = $RootId
        $script:deployDescendantCacheTime = Get-Date
    }
    $total = 0.0
    foreach ($d in $script:deployDescendantCache) {
        try {
            $p = Get-Process -Id $d.ProcessId -ErrorAction Stop
            $total += $p.TotalProcessorTime.TotalSeconds
        } catch {}
    }
    return [math]::Round($total, 1)
}

function Get-LogTail {
    param([string]$Path, [long]$Offset)
    if (-not $Path -or -not (Test-Path $Path)) { return @{ offset = 0; text = '' } }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $len = $fs.Length
        if ($Offset -ge $len) { return @{ offset = $len; text = '' } }
        if ($Offset -lt 0) { $Offset = 0 }
        $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $bytesToRead = [int]($len - $Offset)
        $buffer = New-Object byte[] $bytesToRead
        $fs.Read($buffer, 0, $bytesToRead) | Out-Null
        $text = [System.Text.Encoding]::UTF8.GetString($buffer)
        return @{ offset = $len; text = $text }
    } finally {
        $fs.Close()
    }
}

function Get-LogSummary {
    # One-shot summary that reads the whole log file - fine for a single call when a
    # job has just finished, but too expensive to call every timer tick against a log
    # that can grow to megabytes during a long-running phase (sfc/DISM, Office install).
    # For live per-tick phase tracking during a run, use Update-PhaseFromTail instead.
    param([string]$LogPath)
    $result = @{ phase = 'Idle'; completed = $false; hasWarnings = $false; warningCount = 0 }
    if (-not $LogPath -or -not (Test-Path $LogPath)) { return $result }
    $content = Get-Content -Path $LogPath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { $result.phase = 'Starting...'; return $result }
    $phase = 'Starting...'
    # .+? (not [^-]+) - a phase header can itself contain a hyphen, e.g. "en-us", which
    # [^-]+ would stop at, so the header never matched and the UI got stuck on the
    # previous phase for the rest of the run.
    $found = [regex]::Matches($content, '--- (Phase \d[a-z]?: .+?) ---')
    if ($found.Count -gt 0) { $phase = $found[$found.Count - 1].Groups[1].Value.Trim() }
    $warnMatch = [regex]::Match($content, 'Run complete with (\d+) warning')
    if ($warnMatch.Success) {
        $phase = 'All phases complete'
        $result.completed = $true
        $result.hasWarnings = $true
        $result.warningCount = [int]$warnMatch.Groups[1].Value
    } elseif ($content -match 'Run complete\.') {
        $phase = 'All phases complete'
        $result.completed = $true
    }
    $result.phase = $phase
    return $result
}

function Update-PhaseFromTail {
    # Incremental counterpart to Get-LogSummary's phase-scan: scans only newly-appended
    # tail text (which the per-tick timer already has from Get-LogTail) instead of
    # re-reading the entire log file from disk on every 1.2s tick.
    param([string]$TailText, [string]$CurrentPhase)
    if (-not $TailText) { return $CurrentPhase }
    $found = [regex]::Matches($TailText, '--- (Phase \d[a-z]?: .+?) ---')
    if ($found.Count -gt 0) { return $found[$found.Count - 1].Groups[1].Value.Trim() }
    return $CurrentPhase
}

function Get-UninstallEntries {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName }
}

# Read-only inspection using the exact same bloat-detection patterns
# Deploy-DellOfficeSetup.ps1 acts on (both load from bloat-patterns.json) - nothing here
# changes the system, it only reports what a real run's Phase 1 (OEM bloat removal) would
# touch. Respects the Dell/Lenovo toggles the same way a real run does. Two known gaps
# versus a real run, though: it only checks Get-AppxPackage -AllUsers, not
# Get-AppxProvisionedPackage -Online, so a package provisioned for future profiles but not
# installed for any current user won't show up here even though de-provisioning would
# still catch it; and its totals don't account for the Skip Debloat toggle - Scan always
# reports what Phase 1 would remove, even when Skip Debloat is checked and a real Start
# click would skip that phase entirely.
#
# Runs in a background runspace (see $btnScan.Add_Click below) instead of directly on the
# UI thread - AppX/scheduled-task/registry/service enumeration together take 5-20s on a
# real laptop, during which the window would otherwise go Not Responding. A separate
# runspace shares none of this script's variables or function definitions, so everything
# this needs (bloat patterns, the Dell/Lenovo toggle state, even the tiny
# Get-UninstallEntries helper) has to come in as parameters/be redefined inline rather
# than closed over or called by name.
$script:bloatScanAction = {
    param($BloatPatterns, [bool]$IncludeDell, [bool]$IncludeLenovo)

    function Get-UninstallEntriesLocal {
        $paths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
    }

    $lines = New-Object System.Collections.Generic.List[string]

    $oemsToScan = @()
    if ($IncludeDell) { $oemsToScan += 'dell' }
    if ($IncludeLenovo) { $oemsToScan += 'lenovo' }
    if ($oemsToScan.Count -eq 0) { $oemsToScan = @('dell', 'lenovo') }

    $appxPatternsToScan = New-Object System.Collections.Generic.List[string]
    $win32PatternsToScan = New-Object System.Collections.Generic.List[string]
    $taskFoldersToScan = New-Object System.Collections.Generic.List[string]
    $taskKeepPatternsToScan = New-Object System.Collections.Generic.List[string]
    $servicePatternsToScan = New-Object System.Collections.Generic.List[string]
    foreach ($p in $BloatPatterns.generic.appxPatterns) { $appxPatternsToScan.Add($p) }
    foreach ($p in $BloatPatterns.generic.win32Patterns) { $win32PatternsToScan.Add($p) }
    foreach ($oemName in $oemsToScan) {
        $section = $BloatPatterns.$oemName
        if (-not $section) { continue }
        foreach ($p in $section.appxPatterns) { $appxPatternsToScan.Add($p) }
        foreach ($p in $section.win32Patterns) { $win32PatternsToScan.Add($p) }
        foreach ($p in $section.scheduledTaskFolders) { $taskFoldersToScan.Add($p) }
        foreach ($p in $section.scheduledTaskKeepPatterns) { $taskKeepPatternsToScan.Add($p) }
        foreach ($p in $section.servicePatterns) { $servicePatternsToScan.Add($p) }
    }

    $allInstalledAppx = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    $foundAppx = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $appxPatternsToScan) {
        foreach ($pkg in ($allInstalledAppx | Where-Object { $_.Name -like $pattern })) {
            $foundAppx.Add($pkg.Name)
        }
    }

    $entries = Get-UninstallEntriesLocal
    $foundWin32 = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $win32PatternsToScan) {
        foreach ($match in ($entries | Where-Object { $_.DisplayName -like $pattern })) {
            $foundWin32.Add($match.DisplayName)
        }
    }

    $foundTasks = New-Object System.Collections.Generic.List[string]
    foreach ($folder in $taskFoldersToScan) {
        $tasks = Get-ScheduledTask -TaskPath "$folder*" -ErrorAction SilentlyContinue
        foreach ($task in $tasks) {
            # Match the full path + name - same reasoning as the worker's
            # Disable-OemScheduledTasksAndServices (a name-only match misses Dell Command
            # Update / Lenovo ImController tasks that don't carry the keep keyword in
            # their own TaskName).
            $fullTaskPathScan = "$($task.TaskPath)$($task.TaskName)"
            $isKept = $false
            foreach ($keep in $taskKeepPatternsToScan) {
                if ($fullTaskPathScan -like $keep) { $isKept = $true; break }
            }
            if (-not $isKept -and $task.State -ne 'Disabled') {
                $foundTasks.Add("$($task.TaskPath)$($task.TaskName)")
            }
        }
    }

    $foundServices = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $servicePatternsToScan) {
        foreach ($svc in (Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $pattern -or $_.Name -like $pattern })) {
            $foundServices.Add("$($svc.DisplayName) ($($svc.Name))")
        }
    }

    $hasC2R = Test-Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $msiOffice = @($entries | Where-Object { $_.DisplayName -like 'Microsoft Office*' -and $_.UninstallString -match 'msiexec' })

    $lines.Add("Scan results for $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add('Nothing below has been changed - this is a read-only inspection.')
    $lines.Add('')

    $lines.Add("OEM bloat apps found ($($foundAppx.Count + $foundWin32.Count)):")
    if ($foundAppx.Count -eq 0 -and $foundWin32.Count -eq 0) {
        $lines.Add('  (none matched)')
    } else {
        foreach ($n in $foundAppx) { $lines.Add("  - $n (AppX)") }
        foreach ($n in $foundWin32) { $lines.Add("  - $n (program)") }
    }
    $lines.Add('')

    # Work/school Teams is never a removal target (MSTeams AppX, or the classic Teams
    # Machine-Wide Installer*) - reported explicitly here since nothing else in this scan
    # would otherwise mention it at all.
    $workTeamsAppxScan = $allInstalledAppx | Where-Object { $_.Name -eq 'MSTeams' } | Select-Object -First 1
    $classicWorkTeamsScan = $entries | Where-Object { $_.DisplayName -like 'Teams Machine-Wide Installer*' } | Select-Object -First 1
    $lines.Add('Work/school Teams (never removed by this tool):')
    if ($workTeamsAppxScan) { $lines.Add("  - Detected: AppX MSTeams $($workTeamsAppxScan.Version)") }
    elseif ($classicWorkTeamsScan) { $lines.Add("  - Detected: $($classicWorkTeamsScan.DisplayName)") }
    else { $lines.Add('  - Not detected') }
    $lines.Add('')

    $lines.Add("OEM scheduled tasks that would be disabled ($($foundTasks.Count)):")
    if ($foundTasks.Count -eq 0) { $lines.Add('  (none matched)') }
    else { foreach ($n in $foundTasks) { $lines.Add("  - $n") } }
    $lines.Add('')

    $lines.Add("OEM services that would be disabled ($($foundServices.Count)):")
    if ($foundServices.Count -eq 0) { $lines.Add('  (none matched)') }
    else { foreach ($n in $foundServices) { $lines.Add("  - $n") } }
    $lines.Add('')

    $lines.Add('Office:')
    if ($hasC2R) { $lines.Add('  - Click-to-Run Office install detected (would be fully removed, then Microsoft 365 Apps installed fresh)') }
    foreach ($m in $msiOffice) { $lines.Add("  - MSI-based Office product detected: $($m.DisplayName)") }
    if (-not $hasC2R -and $msiOffice.Count -eq 0) { $lines.Add('  - No existing Office installation detected') }

    $totalFound = $foundAppx.Count + $foundWin32.Count + $foundTasks.Count + $foundServices.Count
    $lines.Add('')
    $lines.Add("Total items that would be touched: $totalFound" + $(if ($hasC2R -or $msiOffice.Count -gt 0) { ' (plus the existing Office install)' } else { '' }))

    return ($lines -join "`r`n")
}

# ============================================================================
# WPF setup
# ============================================================================

if (-not (Test-Path $catalogPath)) {
    [System.Windows.Forms.MessageBox]::Show("apps-catalog.json not found next to this script at:`r`n$catalogPath", 'Gr3y Tools', 'OK', 'Error') | Out-Null
    exit 1
}
$catalog = Get-Content -Path $catalogPath -Raw | ConvertFrom-Json

$tweaksJsonPath = Join-Path $scriptDir 'tweaks.json'
if (-not (Test-Path $tweaksJsonPath)) {
    [System.Windows.Forms.MessageBox]::Show("tweaks.json not found next to this script at:`r`n$tweaksJsonPath", 'Gr3y Tools', 'OK', 'Error') | Out-Null
    exit 1
}
$tweaksCatalog = (Get-Content -Path $tweaksJsonPath -Raw | ConvertFrom-Json).tweaks

[xml]$xamlDoc = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Gr3yLabs Support" Height="820" Width="1150" MinHeight="640" MinWidth="980"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize"
        AllowsTransparency="False" Background="#232629"
        FontFamily="Segoe UI" FontSize="12"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="44" ResizeBorderThickness="6" GlassFrameThickness="0"
                  CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <SolidColorBrush x:Key="BgBrush" Color="#232629"/>
    <SolidColorBrush x:Key="PanelBorderBrush" Color="#2F373D"/>
    <SolidColorBrush x:Key="ButtonBrush" Color="#1E3747"/>
    <SolidColorBrush x:Key="ButtonHoverBrush" Color="#2A4C69"/>
    <SolidColorBrush x:Key="ControlBorderBrush" Color="#707070"/>
    <SolidColorBrush x:Key="TextBrush" Color="#F7F7F7"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#9AA3AB"/>
    <SolidColorBrush x:Key="HeaderBrush" Color="#5BDCFF"/>
    <SolidColorBrush x:Key="HintBrush" Color="#4FB5D2"/>
    <SolidColorBrush x:Key="NavSelectedBrush" Color="#5E81AC"/>
    <SolidColorBrush x:Key="ToggleOnBrush" Color="#2E77FF"/>
    <SolidColorBrush x:Key="ToggleOffBrush" Color="#707070"/>
    <SolidColorBrush x:Key="LogBgBrush" Color="#1B1E21"/>
    <SolidColorBrush x:Key="ScrollThumbBrush" Color="#3C4146"/>
    <SolidColorBrush x:Key="CloseHoverBrush" Color="#C42B1C"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#5BDCFF"/>
    <SolidColorBrush x:Key="GreenBrush" Color="#3FB950"/>
    <SolidColorBrush x:Key="RedBrush" Color="#F85149"/>
    <SolidColorBrush x:Key="YellowBrush" Color="#D29922"/>
    <SolidColorBrush x:Key="OrangeBrush" Color="#F0883E"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
    </Style>
    <Style x:Key="Header" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="Foreground" Value="{StaticResource HeaderBrush}"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Text" Value="(?)"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="{StaticResource HintBrush}"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Help"/>
      <Setter Property="ToolTipService.InitialShowDelay" Value="200"/>
    </Style>
    <Style x:Key="StatusLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="{StaticResource HintBrush}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
    </Style>
    <Style x:Key="StatusSep" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource PanelBorderBrush}"/>
      <Setter Property="Margin" Value="12,0,12,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="Panel" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource BgBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource PanelBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="0"/>
      <Setter Property="Padding" Value="10,8"/>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="{StaticResource ButtonBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlBorderBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="8,5" MaxWidth="380">
              <TextBlock Text="{TemplateBinding Content}" TextWrapping="Wrap" Foreground="{TemplateBinding Foreground}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Background" Value="{StaticResource ButtonBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,3"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="Height" Value="25"/>
      <Setter Property="MinWidth" Value="90"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource ButtonHoverBrush}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource NavSelectedBrush}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="NavButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Width" Value="110"/>
      <Setter Property="Background" Value="{StaticResource BgBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource TextBrush}"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="Padding" Value="4,2"/>
      <Style.Triggers>
        <Trigger Property="Tag" Value="selected">
          <Setter Property="Background" Value="{StaticResource NavSelectedBrush}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="WindowButton" TargetType="Button">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="44"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Arrow"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource ScrollThumbBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="WindowCloseButton" TargetType="Button" BasedOn="{StaticResource WindowButton}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource CloseHoverBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Margin" Value="2,1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Box" Width="14" Height="14" Background="{StaticResource ButtonBrush}"
                      BorderBrush="{StaticResource ControlBorderBrush}" BorderThickness="1" CornerRadius="0" VerticalAlignment="Center">
                <Path x:Name="CheckMark" Data="M2,7 L5.5,10.5 L12,3.5" Stroke="{StaticResource TextBrush}" StrokeThickness="2"
                      Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="6,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="False"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource HeaderBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ToggleSwitchStyle" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="34" Height="17">
              <Border x:Name="Track" CornerRadius="8.5" Background="{StaticResource ToggleOffBrush}"/>
              <Ellipse x:Name="Thumb" Width="13" Height="13" Fill="#FFFFFF" HorizontalAlignment="Left" Margin="2,0,0,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{StaticResource ToggleOnBrush}"/>
                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Thumb" Property="Margin" Value="0,0,2,0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="Transparent" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource NavSelectedBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Height" Value="25"/>
      <Setter Property="Padding" Value="8,2"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="{StaticResource ButtonBrush}" BorderBrush="{StaticResource ControlBorderBrush}" BorderThickness="1" CornerRadius="0">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="22"/>
                        </Grid.ColumnDefinitions>
                        <Path Grid.Column="1" Data="M0,0 L4,4 L8,0" Stroke="{StaticResource TextBrush}" StrokeThickness="1.2"
                              HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Grid>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                Margin="{TemplateBinding Padding}" VerticalAlignment="Center" HorizontalAlignment="Left"/>
              <Popup IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" Placement="Bottom" PopupAnimation="None">
                <Border Background="{StaticResource BgBrush}" BorderBrush="{StaticResource ControlBorderBrush}" BorderThickness="1"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource AncestorType=ComboBox}}" MaxHeight="220">
                  <ScrollViewer><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource BgBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="6,3"/>
      <Setter Property="CaretBrush" Value="{StaticResource TextBrush}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource NavSelectedBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="0">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource TextBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="LogBox" TargetType="TextBox" BasedOn="{StaticResource {x:Type TextBox}}">
      <Setter Property="Background" Value="{StaticResource LogBgBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource PanelBorderBrush}"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="8,6"/>
    </Style>
    <Style x:Key="VerticalSplitter" TargetType="GridSplitter">
      <Setter Property="Width" Value="6"/>
      <Setter Property="HorizontalAlignment" Value="Stretch"/>
      <Setter Property="VerticalAlignment" Value="Stretch"/>
      <Setter Property="Background" Value="{StaticResource ControlBorderBrush}"/>
      <Setter Property="Cursor" Value="SizeWE"/>
      <Setter Property="ResizeBehavior" Value="PreviousAndNext"/>
      <Setter Property="ToolTip" Value="Drag to resize"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="{StaticResource BgBrush}"/>
      <Setter Property="Width" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="{TemplateBinding Background}">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="{StaticResource ScrollThumbBrush}" Margin="2"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="Height" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="{TemplateBinding Background}">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.DecreaseRepeatButton>
                      <RepeatButton Command="{x:Static ScrollBar.PageLeftCommand}" Opacity="0" Focusable="False"/>
                    </Track.DecreaseRepeatButton>
                    <Track.IncreaseRepeatButton>
                      <RepeatButton Command="{x:Static ScrollBar.PageRightCommand}" Opacity="0" Focusable="False"/>
                    </Track.IncreaseRepeatButton>
                    <Track.Thumb>
                      <Thumb>
                        <Thumb.Template>
                          <ControlTemplate TargetType="Thumb">
                            <Border Background="{StaticResource ScrollThumbBrush}" Margin="2"/>
                          </ControlTemplate>
                        </Thumb.Template>
                      </Thumb>
                    </Track.Thumb>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="TabItem">
      <Setter Property="Visibility" Value="Collapsed"/>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="{StaticResource BgBrush}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="0"/>
    </Style>
  </Window.Resources>
  <Grid Name="RootGrid" Background="{StaticResource BgBrush}">
    <Grid.RowDefinitions>
      <RowDefinition Height="44"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Background="{StaticResource BgBrush}">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>

      <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
        <Image Name="LogoImage" Width="26" Height="26" Margin="14,0,8,0" VerticalAlignment="Center" Visibility="Collapsed"/>
        <TextBlock Text="Gr3yLabs Support" FontFamily="Consolas" FontSize="16" FontWeight="Bold"
                   Foreground="{StaticResource HeaderBrush}" VerticalAlignment="Center" Margin="0,0,16,0"/>
      </StackPanel>

      <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
        <Button Name="NavDebloat" Style="{StaticResource NavButton}" Tag="selected" Content="Debloat + Office" WindowChrome.IsHitTestVisibleInChrome="True"/>
        <Button Name="NavInstall" Style="{StaticResource NavButton}" Content="Install Apps" WindowChrome.IsHitTestVisibleInChrome="True"/>
        <Button Name="NavFixes" Style="{StaticResource NavButton}" Content="Config" WindowChrome.IsHitTestVisibleInChrome="True"/>
        <Button Name="NavPanels" Style="{StaticResource NavButton}" Content="Panels" WindowChrome.IsHitTestVisibleInChrome="True"/>
        <Button Name="NavProvisioning" Style="{StaticResource NavButton}" Content="Provisioning" WindowChrome.IsHitTestVisibleInChrome="True"/>
        <Border Name="SacStatusBorder" BorderThickness="1" BorderBrush="{StaticResource MutedBrush}" CornerRadius="3"
                Padding="6,2" Margin="14,0,0,0" VerticalAlignment="Center" Visibility="Collapsed">
          <TextBlock Name="SacStatusText" Text="Smart App Control: -" FontSize="11" Foreground="{StaticResource MutedBrush}"/>
        </Border>
      </StackPanel>

      <Button Grid.Column="3" Name="BtnOpenLogs" Style="{StaticResource WindowButton}" ToolTip="Open the log folder"
              WindowChrome.IsHitTestVisibleInChrome="True">
        <Path Data="M0,2 L4,2 L5,3.5 L12,3.5 L12,11 L0,11 Z" Stroke="{StaticResource TextBrush}" StrokeThickness="1" Width="12" Height="12"/>
      </Button>

      <StackPanel Grid.Column="4" Orientation="Horizontal">
        <Button Name="BtnWinMin" Style="{StaticResource WindowButton}" WindowChrome.IsHitTestVisibleInChrome="True">
          <Path Data="M0,5 L10,5" Stroke="{StaticResource TextBrush}" StrokeThickness="1" Width="10" Height="10"/>
        </Button>
        <Button Name="BtnWinMax" Style="{StaticResource WindowButton}" WindowChrome.IsHitTestVisibleInChrome="True">
          <Grid>
            <Path Name="IconMax" Data="M0.5,0.5 L9.5,0.5 L9.5,9.5 L0.5,9.5 Z" Stroke="{StaticResource TextBrush}" StrokeThickness="1" Width="10" Height="10"/>
            <Path Name="IconRestore" Data="M2.5,0.5 L9.5,0.5 L9.5,7.5 M0.5,2.5 L7.5,2.5 L7.5,9.5 L0.5,9.5 Z" Stroke="{StaticResource TextBrush}" StrokeThickness="1" Width="10" Height="10" Visibility="Collapsed"/>
          </Grid>
        </Button>
        <Button Name="BtnWinClose" Style="{StaticResource WindowCloseButton}" WindowChrome.IsHitTestVisibleInChrome="True">
          <Path Data="M0,0 L10,10 M10,0 L0,10" Stroke="{StaticResource TextBrush}" StrokeThickness="1" Width="10" Height="10"/>
        </Button>
      </StackPanel>
    </Grid>

    <TabControl Grid.Row="1" Name="MainTabs" Margin="10,8,10,10">
      <TabItem Header="Debloat + Office">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <Grid Grid.Row="0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="3*"/>
              <ColumnDefinition Width="10"/>
              <ColumnDefinition Width="2*"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Style="{StaticResource Panel}">
              <StackPanel>
                <TextBlock Style="{StaticResource Header}" Text="Debloat"/>
                <DockPanel LastChildFill="False" Margin="0,0,0,1">
                  <CheckBox DockPanel.Dock="Left" Name="OptDryRun" Content="Dry run (preview only)"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="Preview only: logs everything a real run would do without changing anything."/>
                </DockPanel>
                <DockPanel LastChildFill="False" Margin="0,0,0,1">
                  <CheckBox DockPanel.Dock="Left" Name="OptCreateRestorePoint" Content="Create System Restore point" IsChecked="True"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="Creates a System Restore point before any change. Can be blocked by policy; Windows allows one per 24h."/>
                </DockPanel>
                <DockPanel LastChildFill="False" Margin="0,0,0,1">
                  <CheckBox DockPanel.Dock="Left" Name="OptSkipDebloat" Content="Skip OEM debloat"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="Skips Phase 1 entirely: no OEM/McAfee app removal and no scheduled task or service changes. Leave unchecked to remove them - that removal is one-way and is NOT covered by Revert Last Run (Config tab)."/>
                </DockPanel>
                <DockPanel LastChildFill="False" Margin="22,0,0,1">
                  <CheckBox DockPanel.Dock="Left" Name="OptDell" Content="Debloat Dell software" IsChecked="True"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="Checks the Dell bloat patterns (SupportAssist, Optimizer, Digital Delivery, ...). Dell Command Update is kept."/>
                </DockPanel>
                <DockPanel LastChildFill="False" Margin="22,0,0,1">
                  <CheckBox DockPanel.Dock="Left" Name="OptLenovo" Content="Debloat Lenovo software" IsChecked="True"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="Checks the Lenovo bloat patterns (Lenovo Now, Welcome, Glance, ...). Lenovo Vantage is kept."/>
                </DockPanel>
                <DockPanel LastChildFill="False" Margin="0,0,0,1">
                  <CheckBox DockPanel.Dock="Left" Name="OptInstallOemUpdate" Content="Install Dell Command Update / Lenovo System Update" IsChecked="True"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="Auto-detects Dell vs Lenovo and installs the matching OEM driver/BIOS update tool via winget, only if this looks like commercial hardware (not Inspiron/Alienware/IdeaPad/Yoga/Legion) and it isn't already installed. No-ops on non-Dell/Lenovo machines."/>
                </DockPanel>
                <DockPanel LastChildFill="False" Margin="0,0,0,1">
                  <CheckBox DockPanel.Dock="Left" Name="OptProtectWorkTeams" Content="Protect work/school Teams if detected" IsChecked="True"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="Adds an explicit guard: a package identified as work/school Teams (AppX MSTeams, or the classic Teams Machine-Wide Installer) is never removed or de-provisioned, regardless of what any bloat pattern matches. The generic bloat pattern that removes consumer Teams (the old Chat-icon package, exact name MicrosoftTeams) already cannot match MSTeams - this is a second, independent layer. Scan This Machine reports whether work/school Teams is present on this machine either way."/>
                </DockPanel>
                <TextBlock Style="{StaticResource Header}" Text="Office" Margin="0,10,0,6"/>
                <DockPanel LastChildFill="False" Margin="0,0,0,1">
                  <CheckBox DockPanel.Dock="Left" Name="OptSkipOfficeRemoval" Content="Skip removing existing Office"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="Leaves any existing Office / Microsoft 365 install in place instead of removing it first. Leave unchecked to remove it - that removal is one-way and is NOT covered by Revert Last Run (Config tab)."/>
                </DockPanel>
                <DockPanel LastChildFill="False" Margin="0,0,0,1">
                  <CheckBox DockPanel.Dock="Left" Name="OptSkipOfficeInstall" Content="Skip installing Microsoft 365 Apps"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="Does not install Microsoft 365 Apps for business at the end of the run."/>
                </DockPanel>
                <DockPanel LastChildFill="False" Margin="0,6,0,0">
                  <TextBlock DockPanel.Dock="Left" Text="Office channel:" VerticalAlignment="Center" Margin="2,0,8,0"/>
                  <ComboBox DockPanel.Dock="Left" Name="OptChannel" Width="170" SelectedIndex="0">
                    <ComboBoxItem Content="MonthlyEnterprise"/>
                    <ComboBoxItem Content="Current"/>
                    <ComboBoxItem Content="SemiAnnual"/>
                    <ComboBoxItem Content="SemiAnnualPreview"/>
                  </ComboBox>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}" ToolTip="Update channel for the new install. MonthlyEnterprise is the fleet default."/>
                </DockPanel>
                <DockPanel LastChildFill="False" Margin="0,6,0,1">
                  <TextBlock DockPanel.Dock="Left" Text="Exclude apps:" VerticalAlignment="Center" Margin="2,0,8,0"/>
                </DockPanel>
                <WrapPanel Margin="0,0,0,1">
                  <CheckBox Name="OptExcludeTeams" Content="Teams" Margin="2,0,10,2"/>
                  <CheckBox Name="OptExcludeOneDrive" Content="OneDrive" Margin="0,0,10,2"/>
                  <CheckBox Name="OptExcludeAccess" Content="Access" Margin="0,0,10,2"/>
                  <CheckBox Name="OptExcludePublisher" Content="Publisher" Margin="0,0,10,2"/>
                  <CheckBox Name="OptExcludeLync" Content="Skype for Business" Margin="0,0,10,2"/>
                  <CheckBox Name="OptExcludeOneNote" Content="OneNote" Margin="0,0,10,2"/>
                </WrapPanel>
                <DockPanel LastChildFill="False" Margin="0,4,0,0">
                  <CheckBox DockPanel.Dock="Left" Name="OptSharedComputerLicensing" Content="Shared computer activation"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="For a shared/multi-user PC where Office should activate per-device instead of per-signed-in-user (SharedComputerLicensing). Leave unchecked for a normal single-user laptop."/>
                </DockPanel>
              </StackPanel>
            </Border>

            <Border Grid.Column="2" Style="{StaticResource Panel}">
              <StackPanel>
                <TextBlock Style="{StaticResource Header}" Text="Tweaks"/>
                <StackPanel Orientation="Horizontal" Margin="0,3,0,3">
                  <CheckBox Name="OptTweakTelemetry" Style="{StaticResource ToggleSwitchStyle}" VerticalAlignment="Center"/>
                  <TextBlock Text="Reduce telemetry &amp; activity tracking" VerticalAlignment="Center" Margin="8,0,0,0"/>
                  <TextBlock Style="{StaticResource Hint}" ToolTip="AllowTelemetry=0, disables the DiagTrack service, blocks activity publish/upload (Activity Feed itself is left on so clipboard history keeps working). CAUTION: breaks Windows Autopatch, Update Compliance and Intune Endpoint Analytics, which all require diagnostic data at Required or higher - skipped automatically (with a log warning) on a machine already MDM-enrolled. Microsoft also documents that Smart App Control turns itself off when optional diagnostic data is off, and can only be turned back on with a Windows reset/reinstall."/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,3,0,3">
                  <CheckBox Name="OptTweakHibernation" Style="{StaticResource ToggleSwitchStyle}" VerticalAlignment="Center"/>
                  <TextBlock Text="Disable hibernation (frees disk space)" VerticalAlignment="Center" Margin="8,0,0,0"/>
                  <TextBlock Style="{StaticResource Hint}" ToolTip="Runs powercfg /hibernate off, which removes hiberfil.sys and frees its disk space."/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,3,0,3">
                  <CheckBox Name="OptTweakPreventSleep" Style="{StaticResource ToggleSwitchStyle}" VerticalAlignment="Center"/>
                  <TextBlock Text="Prevent sleep (keep machine reachable)" VerticalAlignment="Center" Margin="8,0,0,0"/>
                  <TextBlock Style="{StaticResource Hint}" ToolTip="Sets system sleep to Never on AC and battery so the machine stays reachable. Display timeout is untouched, so the screen still locks."/>
                </StackPanel>
                <StackPanel Name="PanelTweakDisableSAC" Orientation="Horizontal" Margin="0,3,0,3">
                  <CheckBox Name="OptTweakDisableSAC" Style="{StaticResource ToggleSwitchStyle}" VerticalAlignment="Center"/>
                  <TextBlock Text="Disable Smart App Control" VerticalAlignment="Center" Margin="8,0,0,0"/>
                  <TextBlock Name="TextSacState" Style="{StaticResource Hint}" Margin="6,0,0,0" VerticalAlignment="Center"/>
                  <TextBlock Style="{StaticResource Hint}" ToolTip="Smart App Control hard-blocks unsigned/low-reputation installers on a clean Windows 11 22H2+ machine, with no user override - several Install Apps catalog entries will otherwise fail. WARNING: this is one-way on a real machine - once off, it cannot be turned back on without reinstalling Windows, and it is NOT covered by Revert Last Run (Config tab). Off by default."/>
                </StackPanel>
              </StackPanel>
            </Border>
          </Grid>

          <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,10,0,0">
            <Button Name="BtnScan" Content="Scan This Machine" MinWidth="140"/>
            <Button Name="BtnStart" Content="Start" MinWidth="110" BorderBrush="{StaticResource GreenBrush}"/>
            <Button Name="BtnStop" Content="Stop" MinWidth="90" BorderBrush="{StaticResource RedBrush}" Visibility="Collapsed"/>
            <Button Name="BtnDownloadLog" Content="Download Log" MinWidth="120" Visibility="Collapsed"/>
            <Button Name="BtnReboot" Content="Reboot Now" MinWidth="110" BorderBrush="{StaticResource YellowBrush}" Visibility="Collapsed"/>
          </StackPanel>

          <Border Grid.Row="2" Style="{StaticResource Panel}" Padding="10,5" Margin="0,10,0,0">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="STATE" Style="{StaticResource StatusLabel}"/>
              <Ellipse Name="StatusDot" Width="8" Height="8" Fill="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="0,0,5,0"/>
              <TextBlock Name="StateText" Text="Idle" VerticalAlignment="Center"/>
              <TextBlock Text="|" Style="{StaticResource StatusSep}"/>
              <TextBlock Text="PHASE" Style="{StaticResource StatusLabel}"/>
              <TextBlock Name="PhaseText" Text="-" VerticalAlignment="Center"/>
              <TextBlock Text="|" Style="{StaticResource StatusSep}"/>
              <TextBlock Text="ELAPSED" Style="{StaticResource StatusLabel}"/>
              <TextBlock Name="ElapsedText" Text="0:00" VerticalAlignment="Center"/>
              <TextBlock Text="|" Style="{StaticResource StatusSep}"/>
              <TextBlock Text="CPU (JOB TREE)" Style="{StaticResource StatusLabel}"/>
              <TextBlock Name="CpuText" Text="0.0s" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>

          <Border Grid.Row="3" Name="BannerBorder" Margin="0,8,0,0" Padding="10,6" BorderThickness="1" Visibility="Collapsed">
            <TextBlock Name="BannerText" TextWrapping="Wrap"/>
          </Border>

          <TextBlock Grid.Row="4" Style="{StaticResource Header}" Text="Live Log" Margin="0,10,0,4"/>
          <TextBox Grid.Row="5" Name="LogBox" Style="{StaticResource LogBox}" IsReadOnly="True" TextWrapping="NoWrap"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
        </Grid>
      </TabItem>

      <TabItem Header="Install Apps">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
            <Button Name="CatBusinessBaseline" Content="Business Baseline"
                    ToolTip="Default view - hides apps not generally appropriate for a client machine (Tor Browser, qBittorrent, OpenRGB, and similar). Pick All to see everything."/>
            <Button Name="CatAll" Content="All"/>
            <Button Name="CatBrowsers" Content="Browsers"/>
            <Button Name="CatMsTools" Content="Microsoft Tools"/>
            <Button Name="CatDocuments" Content="Documents"/>
            <Button Name="CatCommunications" Content="Communications"/>
            <Button Name="CatUtilities" Content="Utilities"/>
            <Button Name="CatNonSilent" Content="Non-Silent Installs"/>
            <Button Name="CatManualOnly" Content="Manual Install Only"
                    ToolTip="No automated installer exists for these (tenant login, license key, or vendor email required) - the (?) link opens the real product/download page so you can grab it yourself."/>
            <Button Name="CatCompareResults" Content="Compare Results" BorderBrush="{StaticResource AccentBrush}" Visibility="Collapsed"
                    ToolTip="Shows only the apps Compare Against Export found missing on this machine - pick which ones to install, then Install Selected."/>
            <Border Width="12"/>
            <Button Name="BtnSelectAll" Content="Select All"/>
            <Button Name="BtnClearSelection" Content="Clear Selection"/>
            <TextBlock Name="SelectedCountText" Text="Selected: 0" VerticalAlignment="Center" Margin="10,0,0,0" Foreground="{StaticResource MutedBrush}"/>
            <Ellipse Name="WinGetStatusDot" Width="8" Height="8" Fill="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="16,0,5,0"/>
            <TextBlock Name="WinGetStatusText" Text="Checking winget..." VerticalAlignment="Center" Foreground="{StaticResource MutedBrush}"/>
            <Button Name="BtnInstallWinGet" Content="Install winget" Margin="10,0,0,0"
                    Background="{StaticResource AccentBrush}" Foreground="{StaticResource BgBrush}"
                    Visibility="Collapsed"
                    ToolTip="Runs Install-Module Microsoft.WinGet.Client -Force; Repair-WinGetPackageManager - needs internet access."/>
          </StackPanel>
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
            <Button Name="BtnCheckInstalled" Content="Scan" BorderBrush="{StaticResource OrangeBrush}" ToolTip="Scan the catalog against what's actually installed on this machine and check the boxes for anything found - ready to hand off to Uninstall Selected."/>
            <Button Name="BtnInstallSelected" Content="Install Selected" BorderBrush="{StaticResource GreenBrush}"/>
            <Button Name="BtnUninstallSelected" Content="Uninstall Selected" BorderBrush="{StaticResource RedBrush}"/>
            <Button Name="BtnUpgradeAll" Content="Upgrade All Installed"/>
            <Border Width="14"/>
            <Button Name="BtnExportInstalled" Content="Export Installed Apps..." BorderBrush="{StaticResource AccentBrush}"
                    ToolTip="Run this on the OLD machine, if you can - saves a small JSON file listing everything winget sees as installed, plus every other installed program's name. Not required: Compare Against List also accepts a plain-text app-name list (e.g. copy-pasted Get-ItemProperty/RMM output), for when the old machine is still in use and this tool can't run there at all."/>
            <Button Name="BtnNoGuiExport" Content="No GUI access?" BorderBrush="{StaticResource AccentBrush}"
                    ToolTip="Get a command-line-only version of Export Installed Apps, for when you can only reach the old machine through an RMM run-script action or PowerShell remoting - no way to launch this GUI there at all."/>
            <Button Name="BtnCompareBaseline" Content="Compare Against List..." BorderBrush="{StaticResource AccentBrush}"
                    ToolTip="Run this on the NEW machine. Loads either an Export Installed Apps JSON file, or a plain .txt file - one app name per line, or a pasted DisplayName/DisplayVersion table (e.g. Get-ItemProperty on the Uninstall registry keys, run remotely through an RMM tool and saved from the console output). Scans this machine and checks the box for every catalog app that's on the old list but missing here, in a new Compare Results filter - pick which ones you want, then Install Selected. Anything missing with no catalog match is listed below instead, for manual install."/>
            <Button Name="BtnStopInstall" Content="Stop" Visibility="Collapsed"/>
            <TextBlock Name="InstallStatusText" Text="Idle" VerticalAlignment="Center" Margin="12,0,0,0"/>
          </StackPanel>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*" MinWidth="300"/>
              <ColumnDefinition Width="6"/>
              <ColumnDefinition Width="340" MinWidth="220"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Style="{StaticResource Panel}">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel Name="InstallAppsPanel"/>
              </ScrollViewer>
            </Border>
            <GridSplitter Grid.Column="1" Style="{StaticResource VerticalSplitter}"/>
            <Border Grid.Column="2" Margin="4,0,0,0" Style="{StaticResource Panel}" Padding="0">
              <TextBox Name="InstallLogBox" Style="{StaticResource LogBox}" BorderThickness="0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontSize="11"/>
            </Border>
          </Grid>
        </DockPanel>
      </TabItem>

      <TabItem Header="Config">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="5*" MinWidth="700"/>
            <ColumnDefinition Width="10"/>
            <ColumnDefinition Width="3*" MinWidth="300"/>
          </Grid.ColumnDefinitions>
          <Border Grid.Column="0" Style="{StaticResource Panel}">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel>
                <TextBlock Style="{StaticResource Header}" Text="Fixes"/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="10"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0">
                    <Button Name="BtnFixSystemRepair" Content="System File Repair - Run" HorizontalAlignment="Stretch" Margin="0,0,0,4"
                            ToolTip="Runs sfc /scannow then DISM RestoreHealth. Can take 10-20+ minutes."/>
                    <Button Name="BtnFixNetworkReset" Content="Network - Reset" HorizontalAlignment="Stretch" Margin="0,0,0,4"
                            ToolTip="Resets Winsock and TCP/IP, flushes DNS. Requires a reboot after."/>
                    <Button Name="BtnFixTimeSync" Content="Time - Resync Now" HorizontalAlignment="Stretch" Margin="0,0,0,4"
                            ToolTip="Forces an immediate clock resync (w32tm /resync). On a non-domain-joined machine, also points the time service at pool.ntp.org first. Fixes TLS/certificate and Office activation errors caused by clock drift."/>
                  </StackPanel>
                  <StackPanel Grid.Column="2">
                    <Button Name="BtnFixWindowsUpdate" Content="Windows Update - Reset" HorizontalAlignment="Stretch" Margin="0,0,0,4"
                            ToolTip="Clears the update cache and restarts related services - standard fix for a stuck Windows Update."/>
                    <Button Name="BtnFixWinGet" Content="WinGet - Reinstall" HorizontalAlignment="Stretch" Margin="0,0,0,4"
                            ToolTip="Re-registers the App Installer package - fixes a missing/broken winget."/>
                    <Button Name="BtnFixNetFx3" Content=".NET Framework 3.5 - Enable" HorizontalAlignment="Stretch" Margin="0,0,0,4"
                            ToolTip="Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All. Needed by some older line-of-business apps. Requires internet access (or installation media) if the feature files aren't already cached locally."/>
                    <Button Name="BtnRevertLastRun" Content="Revert Last Run" HorizontalAlignment="Stretch" Margin="0,0,0,4"
                            ToolTip="Undoes tweak/DNS/telemetry/power changes from the most recent run, using the undo snapshot it saved automatically. Does NOT cover OEM/AppX/Office removal or Smart App Control - those are one-way by design."/>
                  </StackPanel>
                </Grid>

                <TextBlock Style="{StaticResource Header}" Text="Customize Preferences" Margin="0,14,0,0"/>
                <TextBlock Style="{StaticResource Hint}" Text="Each switch reflects the machine's current setting. Toggle what you want and Apply only sends what changed. Explorer restarts once at the end if needed."
                           TextWrapping="Wrap" Margin="0,0,0,4" Opacity="0.7"/>
                <Button Name="BtnScanTweaks" Content="Scan Current State" HorizontalAlignment="Stretch" Margin="0,0,0,10"
                        Height="60" FontSize="15" FontWeight="Bold"
                        BorderBrush="{StaticResource OrangeBrush}" BorderThickness="2"
                        ToolTip="Re-reads every switch's live registry/BCD state and refreshes the checkboxes below to match - useful after a manual change, a Revert Last Run, or just to double-check before Apply. Also lists what's currently enabled in the log below."/>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                  <TextBlock Text="Apply to:" VerticalAlignment="Center" Margin="0,0,8,0"/>
                  <ComboBox Name="OptTweakTargetProfile" Width="230" SelectedIndex="2">
                    <ComboBoxItem Content="Current user only"/>
                    <ComboBoxItem Content="Default profile only (future users)"/>
                    <ComboBoxItem Content="Both (recommended)"/>
                  </ComboBox>
                  <TextBlock Style="{StaticResource Hint}" Margin="8,0,0,0"
                             ToolTip="Default profile mirrors per-user tweaks into C:\Users\Default\NTUSER.DAT, so a user account created later (a fresh Entra join, a new local account) inherits them too instead of getting stock Windows defaults. Machine-wide tweaks aren't affected either way - there's only one copy of those."/>
                </StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="16"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0" Name="TweaksPanelA"/>
                  <StackPanel Grid.Column="2" Name="TweaksPanelB"/>
                </Grid>
                <Button Name="BtnApplyTweaks" Content="Apply Selected Tweaks" HorizontalAlignment="Stretch" Margin="0,6,0,4"
                        BorderBrush="{StaticResource GreenBrush}"/>

                <TextBlock Style="{StaticResource Header}" Text="DNS" Margin="0,14,0,4"/>
                <DockPanel Margin="0,0,0,6">
                  <TextBlock Text="Set DNS to:" VerticalAlignment="Center" Margin="0,0,8,0"/>
                  <ComboBox Name="DnsPresetCombo" Width="240" SelectedIndex="0">
                    <ComboBoxItem Content="Default"/>
                    <ComboBoxItem Content="DHCP"/>
                    <ComboBoxItem Content="Google"/>
                    <ComboBoxItem Content="Cloudflare"/>
                    <ComboBoxItem Content="Cloudflare_Malware"/>
                    <ComboBoxItem Content="Cloudflare_Malware_Adult"/>
                    <ComboBoxItem Content="Open_DNS"/>
                    <ComboBoxItem Content="Quad9"/>
                    <ComboBoxItem Content="AdGuard_Ads_Trackers"/>
                    <ComboBoxItem Content="AdGuard_Ads_Trackers_Malware_Adult"/>
                  </ComboBox>
                </DockPanel>
                <Button Name="BtnApplyDns" Content="Apply DNS" HorizontalAlignment="Stretch" Margin="0,0,0,4"
                        ToolTip="Applies to all network adapters currently Up. Default makes no change."/>
              </StackPanel>
            </ScrollViewer>
          </Border>
          <Grid Grid.Column="2">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Orientation="Horizontal">
              <TextBlock Style="{StaticResource Header}" Text="Status" Margin="0,0,10,0"/>
              <TextBlock Name="FixesStatusText" Text="Idle" VerticalAlignment="Bottom"/>
              <Button Name="BtnStopFixes" Content="Stop" Margin="12,0,0,0" BorderBrush="{StaticResource RedBrush}" Visibility="Collapsed"/>
            </StackPanel>
            <TextBlock Grid.Row="1" Style="{StaticResource Header}" Text="Log" Margin="0,10,0,4"/>
            <TextBox Grid.Row="2" Name="FixesLogBox" Style="{StaticResource LogBox}" IsReadOnly="True" TextWrapping="NoWrap"
                     VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
          </Grid>
        </Grid>
      </TabItem>

      <TabItem Header="Panels">
        <Border Style="{StaticResource Panel}">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <TextBlock Style="{StaticResource Header}" Text="Quick Panels"/>
              <TextBlock Style="{StaticResource Hint}" Text="Direct shortcuts to built-in Windows applets - opens instantly, nothing to log."
                         TextWrapping="Wrap" Margin="0,0,0,8" Opacity="0.7"/>
              <WrapPanel>
                <Button Name="BtnPanelCompMgmt" Content="Computer Management" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelControlPanel" Content="Control Panel" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelMouse" Content="Mouse Properties" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelNetwork" Content="Network Connections" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelPower" Content="Power Panel" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelPrinters" Content="Printer Panel" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelProgramsFeatures" Content="Programs and Features" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelRegion" Content="Region" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelSecurityMaintenance" Content="Security and Maintenance" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelSound" Content="Sound Settings" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelSystemProps" Content="System Properties" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelTimeDate" Content="Time and Date" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelFirewall" Content="Windows Defender Firewall" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelSystemRestore" Content="Windows Restore" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelWorkplace" Content="Access Work or School" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelActivation" Content="Activation Settings" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelWindowsUpdate" Content="Windows Update Settings" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelBluetooth" Content="Bluetooth Settings" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelDisplay" Content="Display Settings" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelPrintersSettings" Content="Printers Settings" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelNetworkStatus" Content="Network Status" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelDefaultApps" Content="Default Apps" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelDeviceManager" Content="Device Manager" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelDiskManagement" Content="Disk Management" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelServices" Content="Services" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelTaskScheduler" Content="Task Scheduler" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelEventViewer" Content="Event Viewer" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelLocalUsers" Content="Local Users and Groups" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelNetplwiz" Content="User Accounts (netplwiz)" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelOptionalFeatures" Content="Windows Features" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelMsinfo32" Content="System Information" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelDxdiag" Content="DirectX Diagnostic" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelAdvFirewall" Content="Advanced Firewall (wf.msc)" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelActivationWizard" Content="Activation Wizard (phone)" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelDsregStatus" Content="Show Join/MDM Status" Width="260" Margin="0,0,10,8"/>
                <Button Name="BtnPanelAdminPowerShell" Content="Admin PowerShell Here" Width="260" Margin="0,0,10,8"/>
              </WrapPanel>

              <TextBlock Style="{StaticResource Header}" Text="BitLocker" Margin="0,16,0,0"/>
              <TextBlock Style="{StaticResource Hint}" Text="Read-only: shows current protection status per drive and lets you view or save any existing recovery keys. Never enables, disables, or changes encryption on any drive."
                         TextWrapping="Wrap" Margin="0,0,0,8" Opacity="0.7"/>
              <WrapPanel Margin="0,0,0,8">
                <Button Name="BtnBitLockerScan" Content="Scan BitLocker Status" Width="220" Margin="0,0,10,0"/>
                <Button Name="BtnBitLockerSave" Content="Save Recovery Keys to File..." Width="220" Margin="0,0,10,0" IsEnabled="False"/>
              </WrapPanel>
              <TextBox Name="BitLockerResultsBox" Style="{StaticResource LogBox}" Height="180" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontSize="11"/>
            </StackPanel>
          </ScrollViewer>
        </Border>
      </TabItem>

      <TabItem Header="Provisioning">
        <Border Style="{StaticResource Panel}">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="4">
              <TextBlock Style="{StaticResource Header}" Text="Client Profile"/>
              <TextBlock Style="{StaticResource Hint}" Text="Save these fields once per client engagement, then Load Profile on every subsequent machine for the same client instead of re-entering them. Never contains secrets - just settings."
                         TextWrapping="Wrap" Margin="0,0,0,6" Opacity="0.7"/>
              <WrapPanel Margin="0,0,0,4">
                <Button Name="BtnLoadProfile" Content="Load Profile..." Width="150" Margin="0,0,8,6"/>
                <Button Name="BtnSaveProfile" Content="Save Profile..." Width="150" Margin="0,0,8,6"/>
                <Button Name="BtnNewProfile" Content="Clear / New" Width="120" Margin="0,0,8,6"/>
                <TextBlock Name="TextProfileLoaded" Text="No profile loaded" VerticalAlignment="Center" Opacity="0.7" Margin="4,0,0,6"/>
              </WrapPanel>
              <Grid Margin="0,4,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="150"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="20"/>
                  <ColumnDefinition Width="150"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Grid.Column="0" Text="Client code:" VerticalAlignment="Center" Margin="0,4,0,4"/>
                <TextBox Grid.Row="0" Grid.Column="1" Name="TextClientCode" Margin="0,4,0,4" ToolTip="Short identifier for this client, e.g. ACME."/>
                <TextBlock Grid.Row="0" Grid.Column="3" Text="Entra tenant ID:" VerticalAlignment="Center" Margin="0,4,0,4"/>
                <TextBox Grid.Row="0" Grid.Column="4" Name="TextEntraTenantId" Margin="0,4,0,4" ToolTip="Used for OneDrive silent sign-in (KFMSilentOptIn). Leave blank if not Entra-joined."/>
                <TextBlock Grid.Row="1" Grid.Column="0" Text="Hostname pattern:" VerticalAlignment="Center" Margin="0,4,0,4"/>
                <TextBox Grid.Row="1" Grid.Column="1" Name="TextHostnamePattern" Margin="0,4,0,4" ToolTip="Use {SERIAL} for the BIOS serial number, e.g. ACME-{SERIAL}. Result is trimmed to 15 characters."/>
                <TextBlock Grid.Row="1" Grid.Column="3" Text="Lock timeout (sec):" VerticalAlignment="Center" Margin="0,4,0,4"/>
                <TextBox Grid.Row="1" Grid.Column="4" Name="TextLockTimeoutSec" Margin="0,4,0,4" Text="900" ToolTip="Screen lock inactivity timeout in seconds. 900 = 15 minutes."/>
                <TextBlock Grid.Row="2" Grid.Column="0" Text="Time zone:" VerticalAlignment="Center" Margin="0,4,0,4"/>
                <ComboBox Grid.Row="2" Grid.Column="1" Name="OptTimeZone" Margin="0,4,0,4"/>
                <TextBlock Grid.Row="2" Grid.Column="3" Text="Region:" VerticalAlignment="Center" Margin="0,4,0,4"/>
                <ComboBox Grid.Row="2" Grid.Column="4" Name="OptRegion" Margin="0,4,0,4"/>
                <TextBlock Grid.Row="3" Grid.Column="0" Text="Power plan:" VerticalAlignment="Center" Margin="0,4,0,4"/>
                <ComboBox Grid.Row="3" Grid.Column="1" Name="OptPowerPlan" SelectedIndex="0" Margin="0,4,0,4">
                  <ComboBoxItem Content="Balanced"/>
                  <ComboBoxItem Content="High performance"/>
                  <ComboBoxItem Content="Power saver"/>
                </ComboBox>
              </Grid>

              <Separator Margin="0,10,0,10"/>
              <TextBlock Style="{StaticResource Header}" Text="Hostname Rename"/>
              <TextBlock Style="{StaticResource Hint}" Text="Renames from the pattern above and this machine's BIOS serial number. Does not restart - a reboot is required to take effect. Do this before Entra join."
                         TextWrapping="Wrap" Margin="0,0,0,4" Opacity="0.7"/>
              <TextBlock Style="{StaticResource Hint}" Text="{}{SERIAL} becomes the BIOS serial number. Only letters, digits and hyphens survive - spaces, underscores and other punctuation are stripped - then the result is cut to 15 characters (NetBIOS limit). Examples: ACME-{SERIAL}, Client01-{SERIAL}-WKS, HQ{SERIAL}."
                         TextWrapping="Wrap" Margin="0,0,0,6" Opacity="0.55" FontStyle="Italic"/>
              <WrapPanel>
                <TextBlock Text="Computed name: " VerticalAlignment="Center"/>
                <TextBlock Name="TextComputedHostname" Text="(enter a pattern above)" VerticalAlignment="Center" FontWeight="Bold" Margin="0,0,16,0"/>
                <Button Name="BtnRenameComputer" Content="Rename This Computer" Width="180"/>
              </WrapPanel>

              <Separator Margin="0,10,0,10"/>
              <TextBlock Style="{StaticResource Header}" Text="OneDrive Known Folder Move"/>
              <TextBlock Style="{StaticResource Hint}" Text="Configures silent OneDrive sign-in and redirects Desktop/Documents/Pictures into OneDrive, instead of removing OneDrive. Requires the Entra tenant ID above and only applies on Entra-joined devices."
                         TextWrapping="Wrap" Margin="0,0,0,6" Opacity="0.7"/>
              <WrapPanel>
                <CheckBox Name="OptKfmDesktop" Content="Desktop" IsChecked="True" VerticalAlignment="Center" Margin="0,0,16,8"/>
                <CheckBox Name="OptKfmDocuments" Content="Documents" IsChecked="True" VerticalAlignment="Center" Margin="0,0,16,8"/>
                <CheckBox Name="OptKfmPictures" Content="Pictures" IsChecked="True" VerticalAlignment="Center" Margin="0,0,16,8"/>
              </WrapPanel>
              <Button Name="BtnApplyOneDriveKfm" Content="Apply OneDrive KFM" Width="180" HorizontalAlignment="Left"/>

              <Separator Margin="0,10,0,10"/>
              <TextBlock Style="{StaticResource Header}" Text="Regional, Power and Lock Baseline"/>
              <TextBlock Style="{StaticResource Hint}" Text="Applies the time zone, region, power plan and lock timeout selected above, plus a 15-minute monitor timeout and Fast Startup off (needed for clean Wake-on-LAN and Windows Update)."
                         TextWrapping="Wrap" Margin="0,0,0,6" Opacity="0.7"/>
              <CheckBox Name="OptProvisionPreventSleep" Content="Prevent sleep (keep machine reachable)" Margin="0,0,0,8"
                         ToolTip="Sets system sleep/standby to Never on both AC and battery (powercfg standby-timeout-ac/dc = 0). The screen and lock timeout above are untouched - only sleep itself is disabled, so the machine stays reachable for remote support."/>
              <Button Name="BtnApplyRegionalBaseline" Content="Apply Regional/Power/Lock Baseline" Width="240" HorizontalAlignment="Left"/>

              <Separator Margin="0,10,0,10"/>
              <TextBlock Style="{StaticResource Header}" Text="OEM Driver / BIOS Updates"/>
              <TextBlock Style="{StaticResource Hint}" Text="Runs Dell Command | Update or Lenovo System Update (already installed via the Debloat + Office tab's OEM update tool option) to scan and apply driver/BIOS updates. Requires AC power. May require a reboot - watch for the Reboot button."
                         TextWrapping="Wrap" Margin="0,0,0,6" Opacity="0.7"/>
              <Button Name="BtnApplyOemUpdates" Content="Apply OEM Driver/BIOS Updates" Width="240" HorizontalAlignment="Left"/>

              <Separator Margin="0,10,0,10"/>
              <TextBlock Style="{StaticResource Header}" Text="BitLocker Enable"/>
              <TextBlock Style="{StaticResource Hint}" Text="Opt-in only - this tool never disables or decrypts BitLocker anywhere (see the Panels tab for read-only status/recovery-key viewing). Enable BitLocker turns on XtsAes256 used-space-only encryption with a TPM protector plus a recovery password protector, only if a ready TPM is present and protection is currently Off; on an Entra-joined device the recovery password is also backed up to Entra ID automatically, otherwise it goes into the handoff package only. Prevent Automatic Device Encryption is the opposite case - for a machine staying on local accounts, it stops Windows silently turning encryption on by itself at first Microsoft-account sign-in (24H2), which could otherwise leave the only recovery key in a personal account. Use one or the other, not usually both. Run after OEM Driver/BIOS Updates and after Entra join."
                         TextWrapping="Wrap" Margin="0,0,0,6" Opacity="0.7"/>
              <WrapPanel>
                <Button Name="BtnEnableBitLocker" Content="Enable BitLocker" Width="180" Margin="0,0,10,0"/>
                <Button Name="BtnPreventAutoEncryption" Content="Prevent Automatic Device Encryption" Width="260"/>
              </WrapPanel>

              <Separator Margin="0,10,0,10"/>
              <TextBlock Style="{StaticResource Header}" Text="Windows Update to Completion"/>
              <TextBlock Style="{StaticResource Hint}" Text="Searches, downloads and installs all available Windows updates, looping until none remain (up to 4 passes). If a reboot is needed mid-way, schedules itself to resume automatically after restart - the status below tracks progress across reboots."
                         TextWrapping="Wrap" Margin="0,0,0,6" Opacity="0.7"/>
              <WrapPanel>
                <Button Name="BtnRunWindowsUpdate" Content="Patch to Current" Width="180" Margin="0,0,12,0"/>
                <TextBlock Name="TextWindowsUpdateResume" Text="" VerticalAlignment="Center" Foreground="{StaticResource YellowBrush}"/>
              </WrapPanel>

              <Separator Margin="0,10,0,10"/>
              <TextBlock Style="{StaticResource Header}" Text="Break-Glass Administrator"/>
              <TextBlock Style="{StaticResource Hint}" Text="Creates a local administrator account with a random 24+ character password and disables Guest. On an Entra-joined device, also configures Windows LAPS to manage and rotate this account's password going forward. The initial password is written once to an access-restricted file in the work directory (never to the log) - on a non-Entra-joined device that file is the only copy, since LAPS has nowhere to back it up to."
                         TextWrapping="Wrap" Margin="0,0,0,6" Opacity="0.7"/>
              <WrapPanel>
                <TextBlock Text="Account name:" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <TextBox Name="TextBreakGlassAdminName" Width="160" Text="Gr3yBreakGlass" Margin="0,0,12,0"/>
                <Button Name="BtnCreateBreakGlassAdmin" Content="Create Break-Glass Admin" Width="200"/>
              </WrapPanel>

              <Separator Margin="0,10,0,10"/>
              <TextBlock Style="{StaticResource Header}" Text="Local Administrators Cleanup"/>
              <TextBlock Style="{StaticResource Hint}" Text="Lists everyone currently in the local Administrators group. Scan, pick who to remove (e.g. the end user's account after an Entra join), then Remove Selected. The built-in Administrator account, unresolved Entra role assignments, and whichever account would be the last enabled administrator are never offered or removed."
                         TextWrapping="Wrap" Margin="0,0,0,6" Opacity="0.7"/>
              <WrapPanel Margin="0,0,0,6">
                <Button Name="BtnScanLocalAdmins" Content="Scan Administrators Group" Width="220" Margin="0,0,10,0"/>
                <Button Name="BtnRemoveLocalAdmins" Content="Remove Selected" Width="150" IsEnabled="False"/>
              </WrapPanel>
              <StackPanel Name="LocalAdminsPanel"/>

              <Separator Margin="0,10,0,10"/>
              <TextBlock Style="{StaticResource Header}" Text="Validation and Handoff Package"/>
              <TextBlock Style="{StaticResource Hint}" Text="Read-only checks (activation, Defender, firewall, pending reboot, disk space) plus a machine inventory, written as a handoff folder with an HTML report that opens automatically."
                         TextWrapping="Wrap" Margin="0,0,0,6" Opacity="0.7"/>
              <Button Name="BtnGenerateHandoff" Content="Generate Validation Report + Handoff Package" Width="320" HorizontalAlignment="Left"/>

              <Separator Margin="0,10,0,10"/>
              <TextBlock Style="{StaticResource Header}" Text="Post-Provisioning Cleanup"/>
              <TextBlock Style="{StaticResource Hint}" Text="Clears temp folders, the Windows Update download cache, the ODT install source cache, and runs Disk Cleanup (/VERYLOWDISK) plus a component-store cleanup. Does NOT run /ResetBase, so existing updates can still be uninstalled afterward. Run this last, once everything else on this machine is done."
                         TextWrapping="Wrap" Margin="0,0,0,6" Opacity="0.7"/>
              <Button Name="BtnPostProvisioningCleanup" Content="Run Cleanup" Width="180" HorizontalAlignment="Left"/>

              <Separator Margin="0,10,0,10"/>
              <TextBlock Name="ProvisioningStatusText" Text="Idle" Opacity="0.8" Margin="0,0,0,4"/>
              <TextBox Name="ProvisioningLogBox" Style="{StaticResource LogBox}" Height="160" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontSize="11"/>
            </StackPanel>
          </ScrollViewer>
        </Border>
      </TabItem>
    </TabControl>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xamlDoc
try {
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    [System.Windows.Forms.MessageBox]::Show("Failed to load the GUI layout:`r`n$($_.Exception.Message)", 'Gr3y Tools', 'OK', 'Error') | Out-Null
    exit 1
}

if ($Version) {
    $window.Title = "Gr3yLabs Support v$Version" + $(if ($Commit) { " ($Commit)" } else { '' })
}

# Logo is optional - ships as a 6th hash-pinned file alongside the 5 tracked ones (see
# latest.json/debloat.ps1), but an older cached copy or a hand-run local checkout might
# not have it yet. Skip silently rather than block the GUI from launching over a missing
# cosmetic asset.
if (Test-Path $logoPath) {
    try {
        $logoBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $logoBitmap.BeginInit()
        $logoBitmap.UriSource = [Uri]$logoPath
        $logoBitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $logoBitmap.EndInit()
        $logoBitmap.Freeze()
        $window.Icon = $logoBitmap
        $logoImage = $window.FindName('LogoImage')
        if ($logoImage) {
            $logoImage.Source = $logoBitmap
            $logoImage.Visibility = 'Visible'
        }
    } catch {}
}

# The XAML's Height="820"/Width="1150" isn't clamped to the work area - on a 1366x768
# laptop, or a 13-inch FHD panel at 150% scaling (a ~700px-tall effective work area), that
# puts the Install Apps action bar and window controls off-screen with no way to reach
# them.
$workArea = [System.Windows.SystemParameters]::WorkArea
if ($workArea.Height -lt 840) {
    $window.WindowState = 'Maximized'
} else {
    # Also grow on a bigger display, not just shrink on a small one - the XAML default
    # only ever got smaller here before, so on a big/wide monitor the window opened
    # noticeably smaller than the screen and had to be resized by hand every time.
    # Capped well short of the actual work area (never Maximized/fullscreen by this path -
    # that's the branch above, for small screens only) - just a roomier default.
    $targetHeight = [Math]::Min($workArea.Height - 40, 1000)
    $targetWidth = [Math]::Min($workArea.Width - 40, 1600)
    if ($targetHeight -gt $window.Height) { $window.Height = $targetHeight }
    if ($targetWidth -gt $window.Width) { $window.Width = $targetWidth }
    if ($window.Height -gt $workArea.Height - 20) { $window.Height = $workArea.Height - 20 }
    if ($window.Width -gt $workArea.Width - 20) { $window.Width = $workArea.Width - 20 }
}

# --- Tab 1 controls ---
$optDryRun = $window.FindName('OptDryRun')
$optCreateRestorePoint = $window.FindName('OptCreateRestorePoint')
$optSkipDebloat = $window.FindName('OptSkipDebloat')
$optDell = $window.FindName('OptDell')
$optLenovo = $window.FindName('OptLenovo')
$optInstallOemUpdate = $window.FindName('OptInstallOemUpdate')
$optProtectWorkTeams = $window.FindName('OptProtectWorkTeams')
$optSkipOfficeRemoval = $window.FindName('OptSkipOfficeRemoval')
$optSkipOfficeInstall = $window.FindName('OptSkipOfficeInstall')
$optExcludeTeams = $window.FindName('OptExcludeTeams')
$optExcludeOneDrive = $window.FindName('OptExcludeOneDrive')
$optExcludeAccess = $window.FindName('OptExcludeAccess')
$optExcludePublisher = $window.FindName('OptExcludePublisher')
$optExcludeLync = $window.FindName('OptExcludeLync')
$optExcludeOneNote = $window.FindName('OptExcludeOneNote')
$optSharedComputerLicensing = $window.FindName('OptSharedComputerLicensing')
$optTweakTelemetry = $window.FindName('OptTweakTelemetry')
$optTweakHibernation = $window.FindName('OptTweakHibernation')
$optTweakPreventSleep = $window.FindName('OptTweakPreventSleep')
$optTweakDisableSAC = $window.FindName('OptTweakDisableSAC')
$optTweakDisableSAC.Add_Checked({
    $result = [System.Windows.MessageBox]::Show(
        "Smart App Control blocks unsigned/low-reputation installers with no user override, so this lets more of the Install Apps catalog install cleanly.`r`n`r`nWARNING: this is one-way on a real machine - once turned off, Smart App Control cannot be turned back on without reinstalling Windows.`r`n`r`nEnable this tweak?",
        'Confirm: Disable Smart App Control', 'YesNo', 'Warning')
    if ($result -eq 'No') { $optTweakDisableSAC.IsChecked = $false }
})

# Smart App Control shipped in Windows 11 22H2 (build 22621) - the toggle is meaningless
# (and its registry check below would just find nothing) on anything older, and on a
# machine where the policy value is absent for any other reason there's nothing this
# tweak could actually change. Hide the whole row rather than show a toggle that would
# silently no-op, and show the live state (0 off / 1 on / 2 evaluation) next to it so a
# tech can see it's already been turned off (one-way) before trying this tweak at all.
$panelTweakDisableSAC = $window.FindName('PanelTweakDisableSAC')
$textSacState = $window.FindName('TextSacState')
$sacPolicyState = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
if ([Environment]::OSVersion.Version.Build -lt 22621 -or $null -eq $sacPolicyState) {
    $panelTweakDisableSAC.Visibility = 'Collapsed'
} else {
    $textSacState.Text = switch ($sacPolicyState) {
        0 { '(currently: Off)' }
        1 { '(currently: On)' }
        2 { '(currently: Evaluation)' }
        default { "(currently: unknown state $sacPolicyState)" }
    }
}

# Always-visible indicator in the top nav bar (not just the Tweaks-tab row above), so a
# tech can see Smart App Control's state from any tab, e.g. before going to Install Apps.
$sacStatusBorder = $window.FindName('SacStatusBorder')
$sacStatusText = $window.FindName('SacStatusText')
if ($null -ne $sacPolicyState) {
    $sacStatusBorder.Visibility = 'Visible'
    switch ($sacPolicyState) {
        0 { $sacStatusText.Text = 'Smart App Control: Off'; $sacStatusText.Foreground = $window.Resources['MutedBrush']; $sacStatusBorder.BorderBrush = $window.Resources['MutedBrush'] }
        1 { $sacStatusText.Text = 'Smart App Control: On'; $sacStatusText.Foreground = $window.Resources['YellowBrush']; $sacStatusBorder.BorderBrush = $window.Resources['YellowBrush'] }
        2 { $sacStatusText.Text = 'Smart App Control: Evaluation'; $sacStatusText.Foreground = $window.Resources['YellowBrush']; $sacStatusBorder.BorderBrush = $window.Resources['YellowBrush'] }
        default { $sacStatusText.Text = "Smart App Control: state $sacPolicyState"; $sacStatusText.Foreground = $window.Resources['MutedBrush']; $sacStatusBorder.BorderBrush = $window.Resources['MutedBrush'] }
    }
}

# Smart App Control's cloud reputation checks need Optional diagnostic data - Microsoft's
# own guidance states SAC "requires Optional Diagnostic Data to be enabled" to query its
# app-intelligence graph. Reduce Telemetry lowers diagnostic data below that level, which
# can leave SAC unable to evaluate unknown/unsigned apps it would otherwise allow. Only
# warn when SAC is actually On (state 1) - Off and Evaluation aren't affected the same way.
$optTweakTelemetry.Add_Checked({
    if ($sacPolicyState -eq 1) {
        [System.Windows.MessageBox]::Show(
            "Smart App Control is On for this machine. Its cloud reputation checks need Optional diagnostic data enabled to work - reducing telemetry below that level can leave Smart App Control unable to evaluate unknown or unsigned apps it would otherwise allow through.`r`n`r`nThis tweak will still apply if you continue.",
            'Note: Smart App Control Interaction', 'OK', 'Information') | Out-Null
    }
})

$optChannel = $window.FindName('OptChannel')
$btnScan = $window.FindName('BtnScan')
$btnStart = $window.FindName('BtnStart')
$btnStop = $window.FindName('BtnStop')
$btnDownloadLog = $window.FindName('BtnDownloadLog')
$btnReboot = $window.FindName('BtnReboot')
$statusDot = $window.FindName('StatusDot')
$stateText = $window.FindName('StateText')
$phaseText = $window.FindName('PhaseText')
$elapsedText = $window.FindName('ElapsedText')
$cpuText = $window.FindName('CpuText')
$bannerBorder = $window.FindName('BannerBorder')
$bannerText = $window.FindName('BannerText')
$logBox = $window.FindName('LogBox')
$mainTabs = $window.FindName('MainTabs')
$rootGrid = $window.FindName('RootGrid')
$navDebloat = $window.FindName('NavDebloat')
$navInstall = $window.FindName('NavInstall')
$navFixes = $window.FindName('NavFixes')
$navPanels = $window.FindName('NavPanels')
$navProvisioning = $window.FindName('NavProvisioning')
$btnOpenLogs = $window.FindName('BtnOpenLogs')
$btnWinMin = $window.FindName('BtnWinMin')
$btnWinMax = $window.FindName('BtnWinMax')
$btnWinClose = $window.FindName('BtnWinClose')
$iconMax = $window.FindName('IconMax')
$iconRestore = $window.FindName('IconRestore')

# --- Tab 2 controls ---
$catBusinessBaselineBtn = $window.FindName('CatBusinessBaseline')
$catAllBtn = $window.FindName('CatAll')
$catBrowsersBtn = $window.FindName('CatBrowsers')
$catMsToolsBtn = $window.FindName('CatMsTools')
$catDocumentsBtn = $window.FindName('CatDocuments')
$catCommunicationsBtn = $window.FindName('CatCommunications')
$catUtilitiesBtn = $window.FindName('CatUtilities')
$catNonSilentBtn = $window.FindName('CatNonSilent')
$catManualOnlyBtn = $window.FindName('CatManualOnly')
$catCompareResultsBtn = $window.FindName('CatCompareResults')
$btnSelectAll = $window.FindName('BtnSelectAll')
$btnClearSelection = $window.FindName('BtnClearSelection')
$btnCheckInstalled = $window.FindName('BtnCheckInstalled')
$btnExportInstalled = $window.FindName('BtnExportInstalled')
$btnNoGuiExport = $window.FindName('BtnNoGuiExport')
$btnCompareBaseline = $window.FindName('BtnCompareBaseline')
$selectedCountText = $window.FindName('SelectedCountText')
$btnInstallSelected = $window.FindName('BtnInstallSelected')
$btnUninstallSelected = $window.FindName('BtnUninstallSelected')
$btnUpgradeAll = $window.FindName('BtnUpgradeAll')
$btnStopInstall = $window.FindName('BtnStopInstall')
$installStatusText = $window.FindName('InstallStatusText')
$installAppsPanel = $window.FindName('InstallAppsPanel')
$installLogBox = $window.FindName('InstallLogBox')
$wingetStatusDot = $window.FindName('WinGetStatusDot')
$wingetStatusText = $window.FindName('WinGetStatusText')
$btnInstallWinGet = $window.FindName('BtnInstallWinGet')

# --- Tab 3 controls ---
$btnFixSystemRepair = $window.FindName('BtnFixSystemRepair')
$btnFixNetworkReset = $window.FindName('BtnFixNetworkReset')
$btnFixTimeSync = $window.FindName('BtnFixTimeSync')
$btnFixNetFx3 = $window.FindName('BtnFixNetFx3')
$btnFixWindowsUpdate = $window.FindName('BtnFixWindowsUpdate')
$btnFixWinGet = $window.FindName('BtnFixWinGet')
$btnRevertLastRun = $window.FindName('BtnRevertLastRun')
$fixesStatusText = $window.FindName('FixesStatusText')
$fixesLogBox = $window.FindName('FixesLogBox')
$btnStopFixes = $window.FindName('BtnStopFixes')

# Quick Panels - direct shortcuts to built-in Windows applets, no job/log involved.
$quickPanels = @(
    @{ Btn = $window.FindName('BtnPanelCompMgmt');           File = 'compmgmt.msc'; Args = $null }
    @{ Btn = $window.FindName('BtnPanelControlPanel');       File = 'control.exe';  Args = $null }
    @{ Btn = $window.FindName('BtnPanelMouse');              File = 'control.exe';  Args = 'main.cpl' }
    @{ Btn = $window.FindName('BtnPanelNetwork');            File = 'control.exe';  Args = 'ncpa.cpl' }
    @{ Btn = $window.FindName('BtnPanelPower');              File = 'control.exe';  Args = 'powercfg.cpl' }
    @{ Btn = $window.FindName('BtnPanelPrinters');           File = 'control.exe';  Args = 'printers' }
    @{ Btn = $window.FindName('BtnPanelProgramsFeatures');   File = 'control.exe';  Args = 'appwiz.cpl' }
    @{ Btn = $window.FindName('BtnPanelRegion');             File = 'control.exe';  Args = 'intl.cpl' }
    @{ Btn = $window.FindName('BtnPanelSecurityMaintenance');File = 'control.exe';  Args = '/name Microsoft.ActionCenter' }
    @{ Btn = $window.FindName('BtnPanelSound');              File = 'control.exe';  Args = 'mmsys.cpl' }
    @{ Btn = $window.FindName('BtnPanelSystemProps');        File = 'control.exe';  Args = 'sysdm.cpl' }
    @{ Btn = $window.FindName('BtnPanelTimeDate');           File = 'control.exe';  Args = 'timedate.cpl' }
    @{ Btn = $window.FindName('BtnPanelFirewall');           File = 'control.exe';  Args = 'firewall.cpl' }
    @{ Btn = $window.FindName('BtnPanelSystemRestore');      File = 'rstrui.exe';   Args = $null }
    @{ Btn = $window.FindName('BtnPanelWorkplace');          File = 'ms-settings:workplace';      Args = $null }
    @{ Btn = $window.FindName('BtnPanelActivation');         File = 'ms-settings:activation';     Args = $null }
    @{ Btn = $window.FindName('BtnPanelWindowsUpdate');      File = 'ms-settings:windowsupdate';  Args = $null }
    @{ Btn = $window.FindName('BtnPanelBluetooth');          File = 'ms-settings:bluetooth';      Args = $null }
    @{ Btn = $window.FindName('BtnPanelDisplay');            File = 'ms-settings:display';        Args = $null }
    @{ Btn = $window.FindName('BtnPanelPrintersSettings');   File = 'ms-settings:printers';       Args = $null }
    @{ Btn = $window.FindName('BtnPanelNetworkStatus');      File = 'ms-settings:network-status'; Args = $null }
    @{ Btn = $window.FindName('BtnPanelDefaultApps');        File = 'ms-settings:defaultapps';    Args = $null }
    @{ Btn = $window.FindName('BtnPanelDeviceManager');      File = 'devmgmt.msc';    Args = $null }
    @{ Btn = $window.FindName('BtnPanelDiskManagement');     File = 'diskmgmt.msc';   Args = $null }
    @{ Btn = $window.FindName('BtnPanelServices');           File = 'services.msc';   Args = $null }
    @{ Btn = $window.FindName('BtnPanelTaskScheduler');      File = 'taskschd.msc';   Args = $null }
    @{ Btn = $window.FindName('BtnPanelEventViewer');        File = 'eventvwr.msc';   Args = $null }
    @{ Btn = $window.FindName('BtnPanelLocalUsers');         File = 'lusrmgr.msc';    Args = $null }
    @{ Btn = $window.FindName('BtnPanelNetplwiz');           File = 'netplwiz.exe';   Args = $null }
    @{ Btn = $window.FindName('BtnPanelOptionalFeatures');   File = 'optionalfeatures.exe'; Args = $null }
    @{ Btn = $window.FindName('BtnPanelMsinfo32');           File = 'msinfo32.exe';   Args = $null }
    @{ Btn = $window.FindName('BtnPanelDxdiag');             File = 'dxdiag.exe';     Args = $null }
    @{ Btn = $window.FindName('BtnPanelAdvFirewall');        File = 'wf.msc';         Args = $null }
    @{ Btn = $window.FindName('BtnPanelActivationWizard');   File = 'slui.exe';       Args = '4' }
)
foreach ($p in $quickPanels) {
    $panelFile = $p.File
    $panelArgs = $p.Args
    $p.Btn.Add_Click({
        try {
            if ($panelArgs) { Start-Process -FilePath $panelFile -ArgumentList $panelArgs }
            else { Start-Process -FilePath $panelFile }
        } catch {
            [System.Windows.MessageBox]::Show("Could not open this panel: $($_.Exception.Message)", 'Gr3y Tools', 'OK', 'Error') | Out-Null
        }
    }.GetNewClosure())
}

$btnPanelDsregStatus = $window.FindName('BtnPanelDsregStatus')
$btnPanelDsregStatus.Add_Click({
    try {
        $dsregOutput = & dsregcmd /status 2>&1 | Out-String
        [System.Windows.MessageBox]::Show($dsregOutput, 'Join / MDM Status (dsregcmd /status)', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show("Could not run dsregcmd: $($_.Exception.Message)", 'Gr3y Tools', 'OK', 'Error') | Out-Null
    }
})

$btnPanelAdminPowerShell = $window.FindName('BtnPanelAdminPowerShell')
$btnPanelAdminPowerShell.Add_Click({
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoExit' -WorkingDirectory $workDir
    } catch {
        [System.Windows.MessageBox]::Show("Could not open PowerShell: $($_.Exception.Message)", 'Gr3y Tools', 'OK', 'Error') | Out-Null
    }
})

function Get-BitLockerKeyData {
    # Read-only - never enables, disables, or changes encryption state on any volume.
    # Duplicated from Deploy-DellOfficeSetup.ps1's copy of the same function (this file
    # is self-contained by design, matching the existing Get-SafeFileNamePart/
    # Get-LogSummary duplication pattern). Callers must never pass RecoveryPassword to a
    # log/transcript - only to this tab's own in-memory display or the Save-to-file button.
    try {
        $volumes = Get-BitLockerVolume -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{ Error = $_.Exception.Message; Volumes = @() }
    }
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($vol in $volumes) {
        $recoveryKeys = @($vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | ForEach-Object {
            [PSCustomObject]@{ KeyProtectorId = $_.KeyProtectorId; RecoveryPassword = $_.RecoveryPassword }
        })
        $result.Add([PSCustomObject]@{
            MountPoint           = $vol.MountPoint
            VolumeType           = $vol.VolumeType
            ProtectionStatus     = $vol.ProtectionStatus
            VolumeStatus         = $vol.VolumeStatus
            EncryptionPercentage = $vol.EncryptionPercentage
            RecoveryKeys         = $recoveryKeys
        })
    }
    return [PSCustomObject]@{ Error = $null; Volumes = $result }
}

$btnBitLockerScan = $window.FindName('BtnBitLockerScan')
$btnBitLockerSave = $window.FindName('BtnBitLockerSave')
$bitLockerResultsBox = $window.FindName('BitLockerResultsBox')
$script:bitLockerScanResults = $null

$btnBitLockerScan.Add_Click({
    $bitLockerResultsBox.Text = 'Scanning...'
    $btnBitLockerSave.IsEnabled = $false
    $data = Get-BitLockerKeyData
    if ($data.Error) {
        $bitLockerResultsBox.Text = "Could not read BitLocker status: $($data.Error)`r`n`r`nThis requires the BitLocker module (Windows 10/11 Pro, Enterprise or Education) and elevation - this app should already be running elevated."
        $script:bitLockerScanResults = $null
        return
    }
    if ($data.Volumes.Count -eq 0) {
        $bitLockerResultsBox.Text = 'No volumes reported by Get-BitLockerVolume.'
        $script:bitLockerScanResults = $null
        return
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $anyKeys = $false
    foreach ($v in $data.Volumes) {
        $lines.Add("$($v.MountPoint)  [$($v.VolumeType)]  Protection: $($v.ProtectionStatus)  Status: $($v.VolumeStatus)  Encrypted: $($v.EncryptionPercentage)%")
        if ($v.RecoveryKeys.Count -gt 0) {
            $anyKeys = $true
            foreach ($k in $v.RecoveryKeys) {
                $lines.Add("    Recovery Key ($($k.KeyProtectorId)):")
                $lines.Add("    $($k.RecoveryPassword)")
            }
        } else {
            $lines.Add('    (no recovery password protector found)')
        }
        $lines.Add('')
    }
    $bitLockerResultsBox.Text = $lines -join "`r`n"
    $script:bitLockerScanResults = $data.Volumes
    $btnBitLockerSave.IsEnabled = $anyKeys
})

$btnBitLockerSave.Add_Click({
    if (-not $script:bitLockerScanResults) { return }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.FileName = "bitlocker-recovery_$(Get-MachineTag)_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    $dialog.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    if ($dialog.ShowDialog()) {
        $content = New-Object System.Collections.Generic.List[string]
        $content.Add("BitLocker recovery keys for $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $content.Add('This file contains decryption secrets - store or destroy it securely.')
        $content.Add('')
        foreach ($v in $script:bitLockerScanResults) {
            foreach ($k in $v.RecoveryKeys) {
                $content.Add("Drive $($v.MountPoint) [$($v.VolumeType)] - Key Protector ID $($k.KeyProtectorId)")
                $content.Add("Recovery Key: $($k.RecoveryPassword)")
                $content.Add('')
            }
        }
        try {
            ($content -join "`r`n") | Set-Content -Path $dialog.FileName -Encoding UTF8 -ErrorAction Stop
            [System.Windows.MessageBox]::Show("Saved to $($dialog.FileName)`r`n`r`nThis file contains BitLocker recovery keys in plain text - store or destroy it securely.", 'Gr3y Tools', 'OK', 'Information') | Out-Null
        } catch {
            [System.Windows.MessageBox]::Show("Could not save: $($_.Exception.Message)", 'Gr3y Tools', 'OK', 'Error') | Out-Null
        }
    }
})

# ============================================================================
# Provisioning tab (Phase 2 core: client profile, hostname rename, OneDrive KFM,
# regional/power/lock baseline, OEM driver/BIOS updates, Windows Update to completion,
# validation/handoff package)
# ============================================================================

$btnLoadProfile = $window.FindName('BtnLoadProfile')
$btnSaveProfile = $window.FindName('BtnSaveProfile')
$btnNewProfile = $window.FindName('BtnNewProfile')
$textProfileLoaded = $window.FindName('TextProfileLoaded')
$textClientCode = $window.FindName('TextClientCode')
$textEntraTenantId = $window.FindName('TextEntraTenantId')
$textHostnamePattern = $window.FindName('TextHostnamePattern')
$textLockTimeoutSec = $window.FindName('TextLockTimeoutSec')
$optTimeZone = $window.FindName('OptTimeZone')
$optRegion = $window.FindName('OptRegion')
$optPowerPlan = $window.FindName('OptPowerPlan')
$textComputedHostname = $window.FindName('TextComputedHostname')
$btnRenameComputer = $window.FindName('BtnRenameComputer')
$optKfmDesktop = $window.FindName('OptKfmDesktop')
$optKfmDocuments = $window.FindName('OptKfmDocuments')
$optKfmPictures = $window.FindName('OptKfmPictures')
$btnApplyOneDriveKfm = $window.FindName('BtnApplyOneDriveKfm')
$btnApplyRegionalBaseline = $window.FindName('BtnApplyRegionalBaseline')
$optProvisionPreventSleep = $window.FindName('OptProvisionPreventSleep')
$btnApplyOemUpdates = $window.FindName('BtnApplyOemUpdates')
$btnEnableBitLocker = $window.FindName('BtnEnableBitLocker')
$btnPreventAutoEncryption = $window.FindName('BtnPreventAutoEncryption')
$btnRunWindowsUpdate = $window.FindName('BtnRunWindowsUpdate')
$textWindowsUpdateResume = $window.FindName('TextWindowsUpdateResume')
$textBreakGlassAdminName = $window.FindName('TextBreakGlassAdminName')
$btnCreateBreakGlassAdmin = $window.FindName('BtnCreateBreakGlassAdmin')
$btnScanLocalAdmins = $window.FindName('BtnScanLocalAdmins')
$btnRemoveLocalAdmins = $window.FindName('BtnRemoveLocalAdmins')
$localAdminsPanel = $window.FindName('LocalAdminsPanel')
$btnGenerateHandoff = $window.FindName('BtnGenerateHandoff')
$btnPostProvisioningCleanup = $window.FindName('BtnPostProvisioningCleanup')
$provisioningStatusText = $window.FindName('ProvisioningStatusText')
$provisioningLogBox = $window.FindName('ProvisioningLogBox')

# Populated live from this machine's own installed time zones - always accurate, no
# hardcoded list to go stale. .Id is exactly what Set-TimeZone -Id expects.
foreach ($tz in [System.TimeZoneInfo]::GetSystemTimeZones()) {
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = "$($tz.Id) ($($tz.DisplayName))"
    $item.Tag = $tz.Id
    [void]$optTimeZone.Items.Add($item)
    if ($tz.Id -eq [System.TimeZoneInfo]::Local.Id) { $optTimeZone.SelectedItem = $item }
}

# GeoId values verified against Microsoft's own "Table of Geographical Locations"
# (learn.microsoft.com/windows/win32/intl/table-of-geographical-locations) before use -
# a short, MSP-realistic list rather than the full few-hundred-country table.
$script:regionGeoIds = [ordered]@{
    'United States'  = 244
    'Canada'         = 39
    'United Kingdom' = 242
    'Australia'      = 12
}
foreach ($regionName in $script:regionGeoIds.Keys) {
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = $regionName
    $item.Tag = $script:regionGeoIds[$regionName]
    [void]$optRegion.Items.Add($item)
}
$optRegion.SelectedIndex = 0

function Update-ComputedHostnamePreview {
    $pattern = $textHostnamePattern.Text
    if (-not $pattern) {
        $textComputedHostname.Text = '(enter a pattern above)'
        return
    }
    try {
        $serial = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber
    } catch {
        $serial = 'UNKNOWN'
    }
    $name = $pattern -replace '\{SERIAL\}', $serial
    $name = $name -replace '[^A-Za-z0-9-]', ''
    if ($name.Length -gt 15) { $name = $name.Substring(0, 15) }
    $textComputedHostname.Text = if ($name) { $name } else { '(pattern produced an empty name)' }
}
$textHostnamePattern.Add_TextChanged({ Update-ComputedHostnamePreview })
Update-ComputedHostnamePreview

function Get-CurrentProfileObject {
    [ordered]@{
        clientCode      = $textClientCode.Text
        hostnamePattern = $textHostnamePattern.Text
        entraTenantId   = $textEntraTenantId.Text
        timeZoneId      = if ($optTimeZone.SelectedItem) { $optTimeZone.SelectedItem.Tag } else { $null }
        geoId           = if ($optRegion.SelectedItem) { $optRegion.SelectedItem.Tag } else { $null }
        powerPlan       = $optPowerPlan.SelectedItem.Content
        lockTimeoutSec  = $textLockTimeoutSec.Text
        kfmDesktop      = [bool]$optKfmDesktop.IsChecked
        kfmDocuments    = [bool]$optKfmDocuments.IsChecked
        kfmPictures     = [bool]$optKfmPictures.IsChecked
    }
}

function Set-ProfileToControls {
    param($Profile)
    if ($Profile.clientCode) { $textClientCode.Text = $Profile.clientCode }
    if ($Profile.hostnamePattern) { $textHostnamePattern.Text = $Profile.hostnamePattern }
    if ($Profile.entraTenantId) { $textEntraTenantId.Text = $Profile.entraTenantId }
    if ($Profile.lockTimeoutSec) { $textLockTimeoutSec.Text = "$($Profile.lockTimeoutSec)" }
    if ($null -ne $Profile.kfmDesktop) { $optKfmDesktop.IsChecked = [bool]$Profile.kfmDesktop }
    if ($null -ne $Profile.kfmDocuments) { $optKfmDocuments.IsChecked = [bool]$Profile.kfmDocuments }
    if ($null -ne $Profile.kfmPictures) { $optKfmPictures.IsChecked = [bool]$Profile.kfmPictures }
    if ($Profile.timeZoneId) {
        foreach ($item in $optTimeZone.Items) { if ($item.Tag -eq $Profile.timeZoneId) { $optTimeZone.SelectedItem = $item; break } }
    }
    if ($Profile.geoId) {
        foreach ($item in $optRegion.Items) { if ($item.Tag -eq $Profile.geoId) { $optRegion.SelectedItem = $item; break } }
    }
    if ($Profile.powerPlan) {
        foreach ($item in $optPowerPlan.Items) { if ($item.Content -eq $Profile.powerPlan) { $optPowerPlan.SelectedItem = $item; break } }
    }
    Update-ComputedHostnamePreview
}

$btnSaveProfile.Add_Click({
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.FileName = if ($textClientCode.Text) { "$($textClientCode.Text)-profile.json" } else { 'profile.json' }
    $dialog.Filter = 'Profile files (*.json)|*.json|All files (*.*)|*.*'
    if ($dialog.ShowDialog()) {
        try {
            Get-CurrentProfileObject | ConvertTo-Json -Depth 4 | Set-Content -Path $dialog.FileName -Encoding UTF8
            $script:loadedProfilePath = $dialog.FileName
            $textProfileLoaded.Text = "Saved: $(Split-Path -Leaf $dialog.FileName)"
        } catch {
            [System.Windows.MessageBox]::Show("Could not save the profile: $($_.Exception.Message)", 'Gr3y Tools', 'OK', 'Error') | Out-Null
        }
    }
})

$btnLoadProfile.Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'Profile files (*.json)|*.json|All files (*.*)|*.*'
    if ($dialog.ShowDialog()) {
        try {
            $profileObj = Get-Content -Path $dialog.FileName -Raw | ConvertFrom-Json
            Set-ProfileToControls -Profile $profileObj
            $script:loadedProfilePath = $dialog.FileName
            $textProfileLoaded.Text = "Loaded: $(Split-Path -Leaf $dialog.FileName)"
        } catch {
            [System.Windows.MessageBox]::Show("Could not load that profile: $($_.Exception.Message)", 'Gr3y Tools', 'OK', 'Error') | Out-Null
        }
    }
})

$btnNewProfile.Add_Click({
    $textClientCode.Text = ''
    $textHostnamePattern.Text = ''
    $textEntraTenantId.Text = ''
    $textLockTimeoutSec.Text = '900'
    $optKfmDesktop.IsChecked = $true
    $optKfmDocuments.IsChecked = $true
    $optKfmPictures.IsChecked = $true
    $optPowerPlan.SelectedIndex = 0
    $optRegion.SelectedIndex = 0
    $script:loadedProfilePath = $null
    $textProfileLoaded.Text = 'No profile loaded'
    Update-ComputedHostnamePreview
})

# Provisioning gets its own job track (like Tab 1/Install Apps/Fixes each have their own)
# rather than reusing Start-FixJob, since Start-FixJob always bundles
# -SkipDebloat/-SkipOfficeRemoval/-SkipOfficeInstall, which doesn't make sense to imply
# for a provisioning action.
$script:provisionProc = $null
$script:provisionLogFile = $null
$script:provisionErrFile = $null
$script:provisionLogOffset = 0
$script:provisionStartTime = $null

$provisionButtons = @($btnRenameComputer, $btnApplyOneDriveKfm, $btnApplyRegionalBaseline, $btnApplyOemUpdates, $btnEnableBitLocker, $btnPreventAutoEncryption, $btnRunWindowsUpdate, $btnCreateBreakGlassAdmin, $btnRemoveLocalAdmins, $btnGenerateHandoff, $btnPostProvisioningCleanup)

function Start-ProvisionJob {
    param([string[]]$ProvisionArgs, [string]$Label)
    if ($script:provisionProc -and -not $script:provisionProc.HasExited) { return }

    $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', """$deployScript""",
                 '-NoReboot', '-SkipDebloat', '-SkipOfficeRemoval', '-SkipOfficeInstall') + $ProvisionArgs
    if ($Version) { $argList += @('-Version', $Version) }
    if ($Commit) { $argList += @('-Commit', $Commit) }
    if ($optDryRun.IsChecked) { $argList += '-DryRun' }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:provisionLogFile = Join-Path $workDir "gui_provision_$stamp.out.log"
    $script:provisionErrFile = Join-Path $workDir "gui_provision_$stamp.err.log"
    $script:provisionLogOffset = 0
    $provisioningLogBox.Text = ''
    $provisioningStatusText.Text = if ($optDryRun.IsChecked) { "Running (DRY RUN - no changes will be made): $Label..." } else { "Running: $Label..." }
    foreach ($b in $provisionButtons) { $b.IsEnabled = $false }

    $script:provisionProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
        -RedirectStandardOutput $script:provisionLogFile -RedirectStandardError $script:provisionErrFile `
        -WindowStyle Hidden -PassThru
    $script:provisionStartTime = Get-Date
}

$btnRenameComputer.Add_Click({
    $computed = $textComputedHostname.Text
    $result = [System.Windows.MessageBox]::Show(
        "Rename this computer to '$computed'?`r`n`r`nTakes effect after a reboot. Do this before joining Entra - renaming an already-joined device is refused.",
        'Confirm Rename', 'YesNo', 'Warning')
    if ($result -ne 'Yes') { return }
    Start-ProvisionJob -ProvisionArgs @('-RenameComputer', '-HostnamePattern', $textHostnamePattern.Text) -Label 'Rename Computer'
})

$btnApplyOneDriveKfm.Add_Click({
    if (-not $textEntraTenantId.Text) {
        [System.Windows.MessageBox]::Show('Enter an Entra tenant ID above first - OneDrive silent sign-in/KFM needs it.', 'Gr3y Tools', 'OK', 'Warning') | Out-Null
        return
    }
    $provisionArgs = @('-ApplyOneDriveKfm', '-EntraTenantId', $textEntraTenantId.Text)
    if ($optKfmDesktop.IsChecked) { $provisionArgs += '-KfmDesktop' }
    if ($optKfmDocuments.IsChecked) { $provisionArgs += '-KfmDocuments' }
    if ($optKfmPictures.IsChecked) { $provisionArgs += '-KfmPictures' }
    Start-ProvisionJob -ProvisionArgs $provisionArgs -Label 'Apply OneDrive KFM'
})

$btnApplyRegionalBaseline.Add_Click({
    $provisionArgs = @('-ApplyRegionalBaseline', '-LockTimeoutSec', $textLockTimeoutSec.Text)
    if ($optTimeZone.SelectedItem) { $provisionArgs += @('-TimeZoneId', $optTimeZone.SelectedItem.Tag) }
    if ($optRegion.SelectedItem) {
        $provisionArgs += @('-GeoId', "$($optRegion.SelectedItem.Tag)")
        $cultureMap = @{ 244 = 'en-US'; 39 = 'en-CA'; 242 = 'en-GB'; 12 = 'en-AU' }
        $culture = $cultureMap[[int]$optRegion.SelectedItem.Tag]
        if ($culture) { $provisionArgs += @('-CultureName', $culture) }
    }
    if ($optPowerPlan.SelectedItem) { $provisionArgs += @('-PowerPlanName', $optPowerPlan.SelectedItem.Content) }
    # Reuses the exact same -TweakPreventSleep switch (-> Set-SleepNever) the Config
    # tab's "Prevent sleep" toggle already uses - same powercfg calls, same undo-snapshot
    # registration - just bundled into this same provisioning job instead of a separate
    # trip to the Config tab.
    if ($optProvisionPreventSleep.IsChecked) { $provisionArgs += '-TweakPreventSleep' }
    Start-ProvisionJob -ProvisionArgs $provisionArgs -Label 'Apply Regional/Power/Lock Baseline'
})

$btnApplyOemUpdates.Add_Click({
    $result = [System.Windows.MessageBox]::Show(
        "Apply Dell/Lenovo driver and BIOS updates now?`r`n`r`nRequires AC power (this machine's own battery status is checked before starting). Suspends BitLocker for one reboot first if it's on. No automatic reboot - watch for a REBOOT REQUIRED message when it finishes.",
        'Confirm OEM Updates', 'YesNo', 'Warning')
    if ($result -ne 'Yes') { return }
    Start-ProvisionJob -ProvisionArgs @('-ApplyOemUpdates') -Label 'Apply OEM Driver/BIOS Updates'
})

$btnEnableBitLocker.Add_Click({
    $result = [System.Windows.MessageBox]::Show(
        "Enable BitLocker on C:?`r`n`r`nOnly proceeds if a ready TPM is present and protection is currently Off. Uses XtsAes256, used-space-only, a TPM protector, and a recovery password protector. On an Entra-joined device the recovery password is backed up to Entra ID automatically; otherwise it is only written to the handoff package below (generate that before handing the machine off - there is no other copy). This tool never disables or decrypts BitLocker - that would need to be done separately if it's ever genuinely required.",
        'Confirm Enable BitLocker', 'YesNo', 'Warning')
    if ($result -ne 'Yes') { return }
    Start-ProvisionJob -ProvisionArgs @('-EnableBitLocker') -Label 'Enable BitLocker'
})

$btnPreventAutoEncryption.Add_Click({
    $result = [System.Windows.MessageBox]::Show(
        "Prevent automatic device encryption on this machine?`r`n`r`nFor a machine staying on local accounts - stops Windows silently turning BitLocker on by itself at first Microsoft-account sign-in (24H2), which could otherwise leave the only recovery key in a personal Microsoft account instead of this tenant.",
        'Confirm Prevent Automatic Device Encryption', 'YesNo', 'Warning')
    if ($result -ne 'Yes') { return }
    Start-ProvisionJob -ProvisionArgs @('-PreventAutomaticDeviceEncryption') -Label 'Prevent Automatic Device Encryption'
})

$btnRunWindowsUpdate.Add_Click({
    $msg = if ($optDryRun.IsChecked) {
        "Check for available Windows updates (dry run - search only, nothing will be downloaded or installed)?"
    } else {
        "Patch Windows Update to current?`r`n`r`nSearches, downloads and installs in a loop (up to 4 passes) until none remain. If a reboot is needed mid-way, it schedules itself to resume automatically after you restart - no need to re-click anything."
    }
    $result = [System.Windows.MessageBox]::Show($msg, 'Confirm Windows Update', 'YesNo', 'Warning')
    if ($result -ne 'Yes') { return }
    Start-ProvisionJob -ProvisionArgs @('-RunWindowsUpdate') -Label 'Patch to Current'
})

$btnCreateBreakGlassAdmin.Add_Click({
    $accountName = $textBreakGlassAdminName.Text.Trim()
    if (-not $accountName) {
        [System.Windows.MessageBox]::Show('Enter an account name above first.', 'Gr3y Tools', 'OK', 'Warning') | Out-Null
        return
    }
    $result = [System.Windows.MessageBox]::Show(
        "Create local administrator '$accountName' with a random password?`r`n`r`nOn an Entra-joined device, Windows LAPS is configured to manage and rotate this account's password from here. On a non-Entra-joined device the password has no central backup - it is written once to a restricted file in the work directory and nowhere else.",
        'Confirm Break-Glass Admin', 'YesNo', 'Warning')
    if ($result -ne 'Yes') { return }
    Start-ProvisionJob -ProvisionArgs @('-CreateBreakGlassAdmin', '-BreakGlassAdminName', $accountName) -Label 'Create Break-Glass Admin'
})

function Get-LocalAdministratorsReport {
    # Read-only. Duplicated from Deploy-DellOfficeSetup.ps1's copy (this file is
    # self-contained by design, matching the existing Get-SafeFileNamePart/
    # Get-BitLockerKeyData duplication pattern) so the Scan button here can run
    # synchronously in-process instead of needing a worker job just to list members.
    # Remove-LocalAdministratorMembers (the actual removal) still only exists in the
    # worker, run as a provisioning job like every other system-modifying action.
    $result = New-Object System.Collections.Generic.List[object]
    try {
        $members = Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop
    } catch {
        return [PSCustomObject]@{ Error = $_.Exception.Message; Members = @() }
    }
    $localUsers = @{}
    try {
        Get-LocalUser -ErrorAction Stop | ForEach-Object { $localUsers[$_.SID.Value] = $_ }
    } catch {}
    foreach ($m in $members) {
        $sidValue = if ($m.SID) { $m.SID.Value } else { $null }
        $isUnresolvedEntraRoleSid = [bool]($m.Name -match '^S-1-')
        $isBuiltInAdministrator = [bool]($sidValue -and ($sidValue -like '*-500'))
        $localUser = if ($sidValue -and $localUsers.ContainsKey($sidValue)) { $localUsers[$sidValue] } else { $null }
        $isEnabled = if ($localUser) { [bool]$localUser.Enabled } else { $true }
        $result.Add([PSCustomObject]@{
            Name = $m.Name
            IsBuiltInAdministrator = $isBuiltInAdministrator
            IsUnresolvedEntraRoleSid = $isUnresolvedEntraRoleSid
            IsEnabled = $isEnabled
            Removable = (-not $isBuiltInAdministrator) -and (-not $isUnresolvedEntraRoleSid) -and ($m.ObjectClass -eq 'User')
        })
    }
    return [PSCustomObject]@{ Error = $null; Members = $result }
}

$script:localAdminEntries = New-Object System.Collections.Generic.List[object]

$btnScanLocalAdmins.Add_Click({
    $localAdminsPanel.Children.Clear()
    $script:localAdminEntries.Clear()
    $btnRemoveLocalAdmins.IsEnabled = $false
    $report = Get-LocalAdministratorsReport
    if ($report.Error) {
        $msg = New-Object System.Windows.Controls.TextBlock
        $msg.Text = "Could not read the Administrators group: $($report.Error)"
        $msg.Foreground = $redBrush
        $localAdminsPanel.Children.Add($msg) | Out-Null
        return
    }
    foreach ($m in $report.Members) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Margin = '0,1'
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $m.Name
        $cb.IsEnabled = $m.Removable
        $row.Children.Add($cb) | Out-Null
        if (-not $m.Removable) {
            $reason =
                if ($m.IsBuiltInAdministrator) { '(built-in Administrator account - never removable here)' }
                elseif ($m.IsUnresolvedEntraRoleSid) { '(unresolved Entra role assignment - left alone)' }
                else { '(not an individual user account)' }
            $note = New-Object System.Windows.Controls.TextBlock
            $note.Text = $reason
            $note.Margin = '6,0,0,0'
            $note.Opacity = 0.6
            $note.VerticalAlignment = 'Center'
            $row.Children.Add($note) | Out-Null
        } elseif (-not $m.IsEnabled) {
            $note = New-Object System.Windows.Controls.TextBlock
            $note.Text = '(disabled)'
            $note.Margin = '6,0,0,0'
            $note.Opacity = 0.6
            $note.VerticalAlignment = 'Center'
            $row.Children.Add($note) | Out-Null
        }
        $localAdminsPanel.Children.Add($row) | Out-Null
        $script:localAdminEntries.Add([PSCustomObject]@{ CheckBox = $cb; Name = $m.Name; Removable = $m.Removable })
    }
    $btnRemoveLocalAdmins.IsEnabled = [bool]($report.Members | Where-Object { $_.Removable })
})

$btnRemoveLocalAdmins.Add_Click({
    $selected = @($script:localAdminEntries | Where-Object { $_.CheckBox.IsChecked })
    if ($selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Check at least one account first.', 'Gr3y Tools', 'OK', 'Warning') | Out-Null
        return
    }
    $names = $selected.Name
    $result = [System.Windows.MessageBox]::Show(
        "Remove the following from the local Administrators group?`r`n`r`n$($names -join "`r`n")`r`n`r`nThis cannot be undone by Revert Last Run. The worker refuses individual accounts that would leave zero enabled administrators on this machine.",
        'Confirm Remove From Administrators', 'YesNo', 'Warning')
    if ($result -ne 'Yes') { return }
    Start-ProvisionJob -ProvisionArgs @('-RemoveLocalAdmins', ($names -join ',')) -Label 'Remove From Local Administrators'
})

$btnGenerateHandoff.Add_Click({
    $provisionArgs = @('-GenerateHandoff')
    if ($textClientCode.Text) { $provisionArgs += @('-ClientCode', $textClientCode.Text) }
    Start-ProvisionJob -ProvisionArgs $provisionArgs -Label 'Generate Validation Report + Handoff Package'
})

$btnPostProvisioningCleanup.Add_Click({
    $result = [System.Windows.MessageBox]::Show('Clears temp folders, the Windows Update download cache, and the ODT install source cache, and runs Disk Cleanup and a component-store cleanup. Run this last, once everything else on this machine is done. Continue?', 'Confirm Post-Provisioning Cleanup', 'YesNo', 'Warning')
    if ($result -eq 'Yes') {
        Start-ProvisionJob -ProvisionArgs @('-PostProvisioningCleanup') -Label 'Post-Provisioning Cleanup'
    }
})

# Customize Preferences - built from tweaks.json (shared with Deploy-DellOfficeSetup.ps1,
# which applies from the same file). Each switch reflects the LIVE current registry state
# at window load (read here, since this process is already elevated), not just "off by
# default" - so unlike the old one-way version, unchecking a switch that's currently on
# and clicking Apply actually reverts it, and checking one that's already on is a no-op.
$tweaksPanelA = $window.FindName('TweaksPanelA')
$tweaksPanelB = $window.FindName('TweaksPanelB')
$btnApplyTweaks = $window.FindName('BtnApplyTweaks')
$btnScanTweaks = $window.FindName('BtnScanTweaks')
$optTweakTargetProfile = $window.FindName('OptTweakTargetProfile')
$dnsPresetCombo = $window.FindName('DnsPresetCombo')
$btnApplyDns = $window.FindName('BtnApplyDns')

function Test-TweakIsOn {
    # "On" is decided from the tweak's first registry entry only - good enough to seed
    # a checkbox's initial state; Apply always (re)writes every entry for a changed key,
    # regardless of whether any single entry already happened to match.
    param($TweakDef)
    # ClassicContextMenu has no named-value entries (it's a whole-key create/delete tweak
    # applied via Deploy-DellOfficeSetup.ps1's Set-ClassicContextMenu special case) - "on"
    # just means the InprocServer32 key exists.
    if ($TweakDef.key -eq 'ClassicContextMenu') {
        return (Test-Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32')
    }
    # F8BootMenuOn is a BCD setting, not a registry value - read it back via bcdedit's own
    # documented /enum output format (a "bootmenupolicy    Legacy" line when explicitly
    # set; the line is absent under the Standard default). Not live-verified against a
    # real elevated bcdedit in this dev session (this sandbox session isn't elevated,
    # confirmed via IsInRole(Administrator)=False, and the real GUI always runs elevated) -
    # based on Microsoft's own documented /set bootmenupolicy behavior instead.
    if ($TweakDef.key -eq 'F8BootMenuOn') {
        try {
            $bcdOutput = & bcdedit /enum '{current}' 2>&1
            return [bool]($bcdOutput | Select-String -Pattern 'bootmenupolicy\s+Legacy' -Quiet)
        } catch {
            return $false
        }
    }
    if (-not $TweakDef.entries -or $TweakDef.entries.Count -eq 0) { return $false }
    $first = $TweakDef.entries[0]
    try {
        $current = (Get-ItemProperty -Path $first.path -Name $first.name -ErrorAction Stop).($first.name)
        return ("$current" -eq "$($first.onValue)")
    } catch {
        return $false
    }
}

# NumLockOnStartup's first entry lives under HKU:\.Default - mount that PSDrive once,
# up front, so the live-state read below can resolve it (not auto-mounted by default,
# unlike HKLM:/HKCU:).
if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script -ErrorAction SilentlyContinue | Out-Null
}

$script:tweakCheckBoxes = @{}
$script:tweakInitialState = @{}
$tweakHalf = [Math]::Ceiling($tweaksCatalog.Count / 2)
for ($i = 0; $i -lt $tweaksCatalog.Count; $i++) {
    $t = $tweaksCatalog[$i]
    $targetPanel = if ($i -lt $tweakHalf) { $tweaksPanelA } else { $tweaksPanelB }

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.Margin = '0,3,0,3'

    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $window.Resources['ToggleSwitchStyle']
    $cb.VerticalAlignment = 'Center'
    $isOn = Test-TweakIsOn -TweakDef $t
    $cb.IsChecked = $isOn
    $row.Children.Add($cb) | Out-Null

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $t.label
    $label.VerticalAlignment = 'Center'
    $label.Margin = '8,0,0,0'
    $label.TextWrapping = 'Wrap'
    $row.Children.Add($label) | Out-Null

    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Style = $window.Resources['Hint']
    $hint.ToolTip = $t.tip
    $row.Children.Add($hint) | Out-Null

    $targetPanel.Children.Add($row) | Out-Null
    $script:tweakCheckBoxes[$t.key] = $cb
    $script:tweakInitialState[$t.key] = $isOn
}

$btnApplyTweaks.Add_Click({
    $changed = $script:tweakCheckBoxes.Keys | Where-Object {
        [bool]$script:tweakCheckBoxes[$_].IsChecked -ne [bool]$script:tweakInitialState[$_]
    }
    if (-not $changed) {
        [System.Windows.MessageBox]::Show('No tweak changes to apply - every switch already matches its current setting.', 'Gr3y Tools', 'OK', 'Information') | Out-Null
        return
    }
    $selections = New-Object System.Collections.Generic.List[string]
    $summaryLines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $changed) {
        $direction = if ($script:tweakCheckBoxes[$key].IsChecked) { 'on' } else { 'off' }
        $selections.Add("$key=$direction")
        $tweakDef = $tweaksCatalog | Where-Object { $_.key -eq $key } | Select-Object -First 1
        $label = if ($tweakDef) { $tweakDef.label } else { $key }
        $summaryLines.Add("  - $label -> $direction")
    }
    $targetProfile = switch ($optTweakTargetProfile.SelectedIndex) {
        0 { 'Current' }
        1 { 'Default' }
        default { 'Both' }
    }
    $confirmMsg = "Apply these $($changed.Count) tweak change(s)? (Apply to: $($optTweakTargetProfile.SelectedItem.Content))`r`n`r`n" + ($summaryLines -join "`r`n")
    $result = [System.Windows.MessageBox]::Show($confirmMsg, 'Confirm Apply Tweaks', 'YesNo', 'Warning')
    if ($result -ne 'Yes') { return }
    Start-FixJob -FixArgs @('-CustomizeTweaks', ($selections -join ','), '-TargetProfile', $targetProfile) -Label 'Apply Tweaks'
    # Optimistic - assumes the job succeeds, so a second Apply later only sends whatever
    # changes again from here, rather than re-sending everything just applied.
    foreach ($key in $changed) { $script:tweakInitialState[$key] = [bool]$script:tweakCheckBoxes[$key].IsChecked }
})

$btnScanTweaks.Add_Click({
    # Fast, synchronous re-check - unlike the Debloat + Office tab's Scan (which
    # enumerates AppX/scheduled tasks/services and can take 5-20s, hence its background
    # runspace), Test-TweakIsOn per tweak is just a handful of registry reads plus one
    # bcdedit call for F8BootMenuOn - all 46 tweaks complete well under a second, so this
    # runs directly on the UI thread rather than adding runspace complexity for no
    # real benefit.
    $fixesLogBox.Text = ''
    $fixesStatusText.Text = 'Scanning current tweak state...'
    $enabledLabels = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tweaksCatalog) {
        $isOn = Test-TweakIsOn -TweakDef $t
        $script:tweakCheckBoxes[$t.key].IsChecked = $isOn
        # Re-baseline here too, not just the checkbox - otherwise Apply Selected Tweaks
        # would compare against the stale state captured at window load, and a tweak
        # that changed outside this tool (Revert Last Run, a manual edit) would show up
        # as a "change" to re-send even though the checkbox already reflects it.
        $script:tweakInitialState[$t.key] = $isOn
        if ($isOn) { $enabledLabels.Add($t.label) }
    }
    if ($enabledLabels.Count -gt 0) {
        $fixesLogBox.AppendText("Currently enabled ($($enabledLabels.Count) of $($tweaksCatalog.Count)):`r`n")
        foreach ($label in $enabledLabels) { $fixesLogBox.AppendText("  - $label`r`n") }
    } else {
        $fixesLogBox.AppendText("None of this catalog's tweaks are currently enabled.`r`n")
    }
    $fixesLogBox.ScrollToEnd()
    $fixesStatusText.Text = "Scan complete - $($enabledLabels.Count) of $($tweaksCatalog.Count) tweak(s) currently enabled."
})

$btnApplyDns.Add_Click({
    $preset = $dnsPresetCombo.SelectedItem.Content
    if ($preset -eq 'Default') {
        [System.Windows.MessageBox]::Show('DNS preset is Default - nothing to apply.', 'Gr3y Tools', 'OK', 'Information') | Out-Null
        return
    }
    $result = [System.Windows.MessageBox]::Show("Set DNS to '$preset' on every active network adapter? This can disrupt connectivity if the resolver is unreachable.", 'Confirm DNS Change', 'YesNo', 'Warning')
    if ($result -eq 'Yes') { Start-FixJob -FixArgs @('-DnsPreset', $preset) -Label "Set DNS to $preset" }
})

$greenBrush = $window.Resources['GreenBrush']
$redBrush = $window.Resources['RedBrush']
$accentBrush = $window.Resources['AccentBrush']
$yellowBrush = $window.Resources['YellowBrush']
$headerBrush = $window.Resources['HeaderBrush']

# winget presence check - Install Apps is entirely winget-backed, and a machine
# without it (a minimal/no-Store image like Windows Sandbox, or a broken App
# Installer) would otherwise only find out via a raw Start-Process exception the
# moment a button is clicked. Check once at startup and disable the winget-backed
# buttons up front instead, with an explanation instead of a stack trace.
$script:wingetAvailable = [bool](Get-Command 'winget.exe' -ErrorAction SilentlyContinue)
if ($script:wingetAvailable) {
    $wingetStatusDot.Fill = $greenBrush
    $wingetStatusText.Text = 'winget ready'
    $wingetStatusText.Foreground = $greenBrush
} else {
    $wingetStatusDot.Fill = $redBrush
    $wingetStatusText.Text = 'winget not found'
    $wingetStatusText.Foreground = $redBrush
    $wingetTooltip = "winget (App Installer) was not found on this machine, so Install Apps is disabled. " +
        "Click Install winget, or install it from the Microsoft Store yourself."
    $wingetStatusText.ToolTip = $wingetTooltip
    foreach ($b in @($btnInstallSelected, $btnUninstallSelected, $btnUpgradeAll, $btnCheckInstalled, $btnExportInstalled, $btnCompareBaseline)) {
        $b.IsEnabled = $false
        $b.ToolTip = $wingetTooltip
    }
    $btnInstallWinGet.Visibility = 'Visible'
}

function Set-ActiveTab {
    param([int]$Index)
    $mainTabs.SelectedIndex = $Index
    $navDebloat.Tag = if ($Index -eq 0) { 'selected' } else { '' }
    $navInstall.Tag = if ($Index -eq 1) { 'selected' } else { '' }
    $navFixes.Tag = if ($Index -eq 2) { 'selected' } else { '' }
    $navPanels.Tag = if ($Index -eq 3) { 'selected' } else { '' }
    $navProvisioning.Tag = if ($Index -eq 4) { 'selected' } else { '' }
}
$navDebloat.Add_Click({ Set-ActiveTab -Index 0 })
$navInstall.Add_Click({ Set-ActiveTab -Index 1 })
$navFixes.Add_Click({ Set-ActiveTab -Index 2 })
$navPanels.Add_Click({ Set-ActiveTab -Index 3 })
$navProvisioning.Add_Click({ Set-ActiveTab -Index 4 })

$btnWinMin.Add_Click({ $window.WindowState = 'Minimized' })
$btnWinMax.Add_Click({
    if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' } else { $window.WindowState = 'Maximized' }
})
$btnWinClose.Add_Click({ $window.Close() })
$window.Add_StateChanged({
    # WindowChrome lets a maximized window overflow the screen by its resize border.
    $isMax = $window.WindowState -eq 'Maximized'
    $rootGrid.Margin = if ($isMax) { '7' } else { '0' }
    $iconMax.Visibility = if ($isMax) { 'Collapsed' } else { 'Visible' }
    $iconRestore.Visibility = if ($isMax) { 'Visible' } else { 'Collapsed' }
})
$btnOpenLogs.Add_Click({ Invoke-Item -Path $workDir })

$window.Add_Closing({
    # Capture the CancelEventArgs into a named variable before the switch below - switch
    # rebinds the automatic $_ to the value it's matching on for the duration of its
    # clauses, which would otherwise shadow this handler's own $_ (the event args) and
    # silently turn "Cancel = $true" into a no-op set on the wrong object.
    $closingArgs = $_

    $anyRunning = ($script:deployProc -and -not $script:deployProc.HasExited) -or
                  ($script:fixProc -and -not $script:fixProc.HasExited) -or
                  ($script:installProc -and -not $script:installProc.HasExited)
    if (-not $anyRunning) { return }

    $result = [System.Windows.MessageBox]::Show(
        "A job is still running.`r`n`r`nYes = stop it and close`r`nNo = close and leave it running in the background`r`nCancel = go back without closing",
        'Job Still Running', 'YesNoCancel', 'Warning')

    switch ($result) {
        'Yes' {
            foreach ($proc in @($script:deployProc, $script:fixProc, $script:installProc)) {
                if ($proc -and -not $proc.HasExited) {
                    $ids = Get-DescendantProcessIds -RootId $proc.Id
                    Stop-ProcessTreeSafely -Descendants $ids
                }
            }
        }
        'No' { }
        default { $closingArgs.Cancel = $true }
    }
})

# ============================================================================
# Populate Install Apps tab from apps-catalog.json
# ============================================================================

$script:appEntries = New-Object System.Collections.Generic.List[object]
$script:categoryBlocks = New-Object System.Collections.Generic.List[object]

$categories = $catalog.apps | Group-Object category | Sort-Object Name
foreach ($cat in $categories) {
    $header = New-Object System.Windows.Controls.TextBlock
    $header.Text = $cat.Name
    $header.FontFamily = 'Consolas'
    $header.FontSize = 16
    $header.Foreground = $headerBrush
    $header.Margin = '0,8,0,4'
    $installAppsPanel.Children.Add($header) | Out-Null

    $wrap = New-Object System.Windows.Controls.WrapPanel
    foreach ($app in ($cat.Group | Sort-Object name)) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Width = 230
        $row.Margin = '2,1'

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $app.name
        $cb.Tag = $app.wingetId
        $cb.MaxWidth = 208
        $row.Children.Add($cb) | Out-Null

        if ($app.url) {
            $help = New-Object System.Windows.Controls.TextBlock
            $help.Text = '(?)'
            $help.Foreground = $headerBrush
            $help.FontSize = 11
            $help.Margin = '3,0,0,0'
            $help.VerticalAlignment = 'Center'
            $help.Cursor = 'Hand'
            $help.TextDecorations = [System.Windows.TextDecorations]::Underline
            $help.ToolTip = "Open $($app.url)"
            $helpUrl = $app.url
            $help.Add_MouseLeftButtonUp({ Start-Process $helpUrl }.GetNewClosure())
            $row.Children.Add($help) | Out-Null
        }

        $wrap.Children.Add($row) | Out-Null
        # Msp defaults to true (business-appropriate) when the catalog entry omits the
        # field - only the handful of entries explicitly flagged "msp": false (Tor
        # Browser, qBittorrent, OpenRGB and similar) are excluded from Business Baseline.
        $entry = [PSCustomObject]@{ CheckBox = $cb; Row = $row; Name = $app.name; Category = $cat.Name; WingetId = $app.wingetId; DownloadUrl = $app.downloadUrl; DynamicDownloadPage = $app.dynamicDownloadPage; Url = $app.url; SacRisk = [bool]$app.sacRisk; Msp = ($app.msp -ne $false); CompareMatch = $false }
        $script:appEntries.Add($entry)
        # Checked/Unchecked (not Click) since they fire off IsChecked itself changing,
        # regardless of interaction method - Click alone was observed to not reliably
        # fire for every path that can toggle a CheckBox.
        $cb.Add_Checked({ Update-SelectedCount })
        $cb.Add_Unchecked({ Update-SelectedCount })
    }
    $installAppsPanel.Children.Add($wrap) | Out-Null
    $script:categoryBlocks.Add([PSCustomObject]@{ Header = $header; Wrap = $wrap; Category = $cat.Name })
}

function Update-SelectedCount {
    $count = ($script:appEntries | Where-Object { $_.CheckBox.IsChecked }).Count
    $selectedCountText.Text = "Selected: $count"
}

# Business Baseline is the default filter (improvement-plan.md 3.11) - a client-laptop
# tech sees the safe-for-business subset first and has to deliberately switch to All to
# reach things like Tor Browser or qBittorrent, rather than seeing everything by default.
$script:activeCategory = 'Business Baseline'

function Update-AppVisibility {
    foreach ($block in $script:categoryBlocks) {
        $anyVisible = $false
        foreach ($entry in ($script:appEntries | Where-Object { $_.Category -eq $block.Category })) {
            $visible =
                if ($script:activeCategory -eq 'All') { $true }
                elseif ($script:activeCategory -eq 'Business Baseline') { $entry.Msp }
                elseif ($script:activeCategory -eq 'Compare Results') { $entry.CompareMatch }
                else { $block.Category -eq $script:activeCategory }
            $entry.Row.Visibility = if ($visible) { 'Visible' } else { 'Collapsed' }
            if ($visible) { $anyVisible = $true }
        }
        $blockVisibility = if ($anyVisible) { 'Visible' } else { 'Collapsed' }
        $block.Header.Visibility = $blockVisibility
        $block.Wrap.Visibility = $blockVisibility
    }
}

$catBusinessBaselineBtn.Add_Click({ $script:activeCategory = 'Business Baseline'; Update-AppVisibility })
$catAllBtn.Add_Click({ $script:activeCategory = 'All'; Update-AppVisibility })
$catBrowsersBtn.Add_Click({ $script:activeCategory = 'Browsers'; Update-AppVisibility })
$catMsToolsBtn.Add_Click({ $script:activeCategory = 'Microsoft Tools'; Update-AppVisibility })
$catDocumentsBtn.Add_Click({ $script:activeCategory = 'Documents'; Update-AppVisibility })
$catCommunicationsBtn.Add_Click({ $script:activeCategory = 'Communications'; Update-AppVisibility })
$catUtilitiesBtn.Add_Click({ $script:activeCategory = 'Utilities'; Update-AppVisibility })
$catNonSilentBtn.Add_Click({ $script:activeCategory = 'Non-Silent Installs'; Update-AppVisibility })
$catManualOnlyBtn.Add_Click({ $script:activeCategory = 'Manual Install Only'; Update-AppVisibility })
$catCompareResultsBtn.Add_Click({ $script:activeCategory = 'Compare Results'; Update-AppVisibility })

# Apply the Business Baseline default filter now - every row defaults to Visible when
# created above, which matched the old 'All' default but would otherwise show the full
# unfiltered catalog (Tor Browser, qBittorrent, etc.) until the tech clicked something.
Update-AppVisibility

$btnSelectAll.Add_Click({
    # With the "All" filter active, Select All used to tick everything in the entire
    # catalog in one click - including Tor Browser, qBittorrent and the auto-clicker
    # tools, which is exactly the kind of one-click mistake that's easy to make on a
    # client laptop. A specific category filter (e.g. just "Documents") is a deliberate,
    # narrower choice, so that case proceeds without asking.
    if ($script:activeCategory -eq 'All') {
        $visibleCount = @($script:appEntries | Where-Object { $_.Row.Visibility -eq 'Visible' }).Count
        $result = [System.Windows.MessageBox]::Show(
            "This selects all $visibleCount apps across every category, including things like Tor Browser, qBittorrent and auto-clicker tools that usually aren't appropriate for a client machine.`r`n`r`nPick a specific category first if you only want apps from one group. Select all $visibleCount anyway?",
            'Confirm Select All', 'YesNo', 'Warning')
        if ($result -ne 'Yes') { return }
    }
    foreach ($entry in $script:appEntries) {
        if ($entry.Row.Visibility -eq 'Visible') { $entry.CheckBox.IsChecked = $true }
    }
    Update-SelectedCount
})
$btnClearSelection.Add_Click({
    foreach ($entry in $script:appEntries) { $entry.CheckBox.IsChecked = $false }
    Update-SelectedCount
})

# ============================================================================
# Tab 1: Debloat + Office job control
# ============================================================================

$script:deployProc = $null
$script:deployLogFile = $null
$script:deployErrFile = $null
$script:deployLogOffset = 0
$script:deployStartTime = $null
$script:deployIsDryRun = $false
$script:deployHasFinishedBannerShown = $true
$script:deployPhase = 'Idle'

$script:scanPS = $null
$script:scanHandle = $null

$btnScan.Add_Click({
    if ($script:scanPS) { return }
    $btnScan.IsEnabled = $false
    $stateText.Text = 'Scanning...'
    $bannerBorder.Visibility = 'Collapsed'
    $logBox.Text = ''

    $script:scanPS = [powershell]::Create()
    [void]$script:scanPS.AddScript($script:bloatScanAction.ToString())
    [void]$script:scanPS.AddArgument($bloatPatterns)
    [void]$script:scanPS.AddArgument([bool]$optDell.IsChecked)
    [void]$script:scanPS.AddArgument([bool]$optLenovo.IsChecked)
    $script:scanHandle = $script:scanPS.BeginInvoke()
})

$btnStart.Add_Click({
    # Re-entrancy guard - $btnStart only gets disabled on the next 1.2s timer tick, so
    # without this a fast double-click launched two workers racing on OEM/Office removal
    # and both writing to gui_run_<same-second-stamp>.out.log.
    if ($script:deployProc -and -not $script:deployProc.HasExited) { return }

    if (-not $optDryRun.IsChecked) {
        $summaryParts = New-Object System.Collections.Generic.List[string]
        if (-not $optSkipDebloat.IsChecked) { $summaryParts.Add('- Remove OEM/McAfee bloatware') }
        if ($optInstallOemUpdate.IsChecked) { $summaryParts.Add('- Install Dell Command Update / Lenovo System Update (if applicable)') }
        if (-not $optSkipOfficeRemoval.IsChecked) { $summaryParts.Add('- Remove any existing Office install') }
        if (-not $optSkipOfficeInstall.IsChecked) {
            $summaryParts.Add('- Install Microsoft 365 Apps for business')
            $excludeSummary = New-Object System.Collections.Generic.List[string]
            if ($optExcludeTeams.IsChecked) { $excludeSummary.Add('Teams') }
            if ($optExcludeOneDrive.IsChecked) { $excludeSummary.Add('OneDrive') }
            if ($optExcludeAccess.IsChecked) { $excludeSummary.Add('Access') }
            if ($optExcludePublisher.IsChecked) { $excludeSummary.Add('Publisher') }
            if ($optExcludeLync.IsChecked) { $excludeSummary.Add('Skype for Business') }
            if ($optExcludeOneNote.IsChecked) { $excludeSummary.Add('OneNote') }
            if ($excludeSummary.Count -gt 0) { $summaryParts.Add("  - Excluding: $($excludeSummary -join ', ')") }
            if ($optSharedComputerLicensing.IsChecked) { $summaryParts.Add('  - Shared computer activation enabled') }
        }
        if ($optTweakTelemetry.IsChecked) { $summaryParts.Add('- Reduce telemetry') }
        if ($optTweakHibernation.IsChecked) { $summaryParts.Add('- Disable hibernation') }
        if ($optTweakPreventSleep.IsChecked) { $summaryParts.Add('- Prevent sleep') }
        if ($optTweakDisableSAC.IsChecked) { $summaryParts.Add('- Disable Smart App Control (one-way on a real machine)') }
        $summaryText = if ($summaryParts.Count -gt 0) { $summaryParts -join "`r`n" } else { '(no phases selected - this run would do nothing)' }
        $result = [System.Windows.MessageBox]::Show("Start this run on THIS machine?`r`n`r`n$summaryText", 'Confirm Start', 'YesNo', 'Warning')
        if ($result -ne 'Yes') { return }
    }

    $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', """$deployScript""", '-NoReboot')
    if ($Version) { $argList += @('-Version', $Version) }
    if ($Commit) { $argList += @('-Commit', $Commit) }
    if ($optDryRun.IsChecked) { $argList += '-DryRun' }
    if ($optCreateRestorePoint.IsChecked) { $argList += '-CreateRestorePoint' }
    if ($optSkipDebloat.IsChecked) { $argList += '-SkipDebloat' }
    if ($optDell.IsChecked) { $argList += '-Dell' }
    if ($optLenovo.IsChecked) { $argList += '-Lenovo' }
    if ($optInstallOemUpdate.IsChecked) { $argList += '-InstallOemUpdateTool' }
    if ($optProtectWorkTeams.IsChecked) { $argList += '-ProtectWorkTeams' }
    if ($optSkipOfficeRemoval.IsChecked) { $argList += '-SkipOfficeRemoval' }
    if ($optSkipOfficeInstall.IsChecked) { $argList += '-SkipOfficeInstall' }
    if ($optTweakTelemetry.IsChecked) { $argList += '-TweakReduceTelemetry' }
    if ($optTweakHibernation.IsChecked) { $argList += '-TweakDisableHibernation' }
    if ($optTweakPreventSleep.IsChecked) { $argList += '-TweakPreventSleep' }
    if ($optTweakDisableSAC.IsChecked) { $argList += '-TweakDisableSmartAppControl' }
    $channel = $optChannel.SelectedItem.Content
    $argList += @('-OfficeChannel', $channel)
    $excludeApps = New-Object System.Collections.Generic.List[string]
    if ($optExcludeTeams.IsChecked) { $excludeApps.Add('Teams') }
    if ($optExcludeOneDrive.IsChecked) { $excludeApps.Add('OneDrive') }
    if ($optExcludeAccess.IsChecked) { $excludeApps.Add('Access') }
    if ($optExcludePublisher.IsChecked) { $excludeApps.Add('Publisher') }
    if ($optExcludeLync.IsChecked) { $excludeApps.Add('Lync') }
    if ($optExcludeOneNote.IsChecked) { $excludeApps.Add('OneNote') }
    if ($excludeApps.Count -gt 0) { $argList += @('-OfficeExcludeApps', ($excludeApps -join ',')) }
    if ($optSharedComputerLicensing.IsChecked) { $argList += '-OfficeSharedComputerLicensing' }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:deployLogFile = Join-Path $workDir "gui_run_$stamp.out.log"
    $script:deployErrFile = Join-Path $workDir "gui_run_$stamp.err.log"
    $script:deployLogOffset = 0
    $script:deployIsDryRun = [bool]$optDryRun.IsChecked
    $script:deployHasFinishedBannerShown = $false
    $script:deployPhase = 'Starting...'

    $logBox.Text = ''
    $bannerBorder.Visibility = 'Collapsed'
    $btnReboot.Visibility = 'Collapsed'
    $btnDownloadLog.Visibility = 'Collapsed'

    $script:deployProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
        -RedirectStandardOutput $script:deployLogFile -RedirectStandardError $script:deployErrFile `
        -WindowStyle Hidden -PassThru
    $script:deployStartTime = Get-Date
})

$btnStop.Add_Click({
    $result = [System.Windows.MessageBox]::Show('Stop the running job? Anything mid-uninstall/install may be left partially applied.', 'Confirm Stop', 'YesNo', 'Warning')
    if ($result -eq 'Yes' -and $script:deployProc -and -not $script:deployProc.HasExited) {
        $ids = Get-DescendantProcessIds -RootId $script:deployProc.Id
        Stop-ProcessTreeSafely -Descendants $ids
    }
})

$btnDownloadLog.Add_Click({
    if (-not $script:deployLogFile -or -not (Test-Path $script:deployLogFile)) { return }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.FileName = "gr3ytools-debloat_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$(Get-MachineTag).zip"
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    $dialog.Filter = 'Zip files (*.zip)|*.zip|All files (*.*)|*.*'
    if ($dialog.ShowDialog()) {
        $filesToZip = New-Object System.Collections.Generic.List[string]
        $filesToZip.Add($script:deployLogFile)
        if ($script:deployErrFile -and (Test-Path $script:deployErrFile)) { $filesToZip.Add($script:deployErrFile) }
        # gui_run_*.out.log only has what the worker wrote to stdout - the worker's own
        # Start-Transcript log additionally has the exact command line (every -Tweak*/
        # -Skip*/-Office* flag) it was launched with, which is often the first thing
        # worth checking on a "why did this run do something unexpected" ticket. Most
        # recent run_*.log in the work dir, since Download Log is only ever enabled once
        # a job has finished and nothing else writes new transcripts there concurrently.
        $transcript = Get-ChildItem -Path $workDir -Filter 'run_*.log' -ErrorAction SilentlyContinue |
            Sort-Object CreationTime -Descending | Select-Object -First 1
        if ($transcript) { $filesToZip.Add($transcript.FullName) }
        Compress-Archive -Path $filesToZip -DestinationPath $dialog.FileName -Force
    }
})

$btnReboot.Add_Click({
    $result = [System.Windows.MessageBox]::Show('Reboot this computer now?', 'Confirm Reboot', 'YesNo', 'Warning')
    if ($result -eq 'Yes') {
        $bannerText.Text = 'Rebooting now - this window will close shortly.'
        Start-Sleep -Milliseconds 500
        Restart-Computer -Force
    }
})

# ============================================================================
# Tab 3: One-click Fixes - each runs Deploy-DellOfficeSetup.ps1 standalone (all
# three main phases skipped) with just its own -Fix... flag, reusing the same
# child-process + redirected-log pattern as the Start button.
# ============================================================================

$script:fixProc = $null
$script:fixLogFile = $null
$script:fixErrFile = $null
$script:fixLogOffset = 0
$script:fixStartTime = $null

$fixButtons = @($btnFixSystemRepair, $btnFixNetworkReset, $btnFixTimeSync, $btnFixWindowsUpdate, $btnFixWinGet, $btnFixNetFx3, $btnScanTweaks, $btnApplyTweaks, $btnApplyDns, $btnRevertLastRun)

function Start-FixJob {
    param([string[]]$FixArgs, [string]$Label)
    if ($script:fixProc -and -not $script:fixProc.HasExited) { return }

    $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', """$deployScript""",
                 '-NoReboot', '-SkipDebloat', '-SkipOfficeRemoval', '-SkipOfficeInstall') + $FixArgs
    if ($Version) { $argList += @('-Version', $Version) }
    if ($Commit) { $argList += @('-Commit', $Commit) }
    # Honor the Debloat + Office tab's Dry run checkbox here too - it previously only
    # applied to the Start button, so ticking Dry run and then clicking a Config-tab
    # action (a Fix, Apply Tweaks, Apply DNS) made real changes anyway.
    if ($optDryRun.IsChecked) { $argList += '-DryRun' }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:fixLogFile = Join-Path $workDir "gui_fix_$stamp.out.log"
    $script:fixErrFile = Join-Path $workDir "gui_fix_$stamp.err.log"
    $script:fixLogOffset = 0
    $fixesLogBox.Text = ''
    $fixesStatusText.Text = if ($optDryRun.IsChecked) { "Running (DRY RUN - no changes will be made): $Label..." } else { "Running: $Label..." }
    foreach ($b in $fixButtons) { $b.IsEnabled = $false }
    $btnStopFixes.Visibility = 'Visible'

    $script:fixProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
        -RedirectStandardOutput $script:fixLogFile -RedirectStandardError $script:fixErrFile `
        -WindowStyle Hidden -PassThru
    $script:fixStartTime = Get-Date
}

$btnFixSystemRepair.Add_Click({ Start-FixJob -FixArgs @('-FixSystemRepair') -Label 'System File Repair' })

$btnFixNetworkReset.Add_Click({
    $result = [System.Windows.MessageBox]::Show('This resets Winsock and TCP/IP and requires a reboot afterward to fully take effect. Continue?', 'Confirm Network Reset', 'YesNo', 'Warning')
    if ($result -eq 'Yes') { Start-FixJob -FixArgs @('-FixNetworkReset') -Label 'Network Reset' }
})

$btnFixWindowsUpdate.Add_Click({
    $result = [System.Windows.MessageBox]::Show('This stops Windows Update-related services and clears their cache. Continue?', 'Confirm Windows Update Reset', 'YesNo', 'Warning')
    if ($result -eq 'Yes') { Start-FixJob -FixArgs @('-FixWindowsUpdateReset') -Label 'Windows Update Reset' }
})

$btnFixWinGet.Add_Click({ Start-FixJob -FixArgs @('-FixWinGetReinstall') -Label 'Reinstall winget' })

$btnFixTimeSync.Add_Click({ Start-FixJob -FixArgs @('-FixTimeSync') -Label 'Time Resync' })

$btnFixNetFx3.Add_Click({ Start-FixJob -FixArgs @('-FixNetFx3') -Label 'Enable .NET Framework 3.5' })

$btnRevertLastRun.Add_Click({
    $undoFile = Get-ChildItem -Path $workDir -Filter 'undo_*.json' -ErrorAction SilentlyContinue |
        Sort-Object CreationTime -Descending | Select-Object -First 1
    if (-not $undoFile) {
        [System.Windows.MessageBox]::Show('No undo snapshot found - no run in this work directory has applied a tweak, DNS, telemetry or power change yet.', 'Gr3y Tools', 'OK', 'Information') | Out-Null
        return
    }
    $result = [System.Windows.MessageBox]::Show(
        "Revert changes from the most recent run?`r`n`r`nSnapshot: $($undoFile.Name)`r`nCaptured: $($undoFile.CreationTime)`r`n`r`nThis undoes tweak/DNS/telemetry/power changes only. OEM/AppX/Office removal and Smart App Control are one-way and are never covered by this.",
        'Confirm Revert Last Run', 'YesNo', 'Warning')
    if ($result -ne 'Yes') { return }
    Start-FixJob -FixArgs @('-Undo', $undoFile.FullName) -Label 'Revert Last Run'
})

$btnStopFixes.Add_Click({
    $result = [System.Windows.MessageBox]::Show('Stop the running fix? Interrupting sfc/DISM mid-scan is safe (just leaves the check unverified) - a network/Windows Update reset should finish quickly on its own instead.', 'Confirm Stop', 'YesNo', 'Warning')
    if ($result -eq 'Yes' -and $script:fixProc -and -not $script:fixProc.HasExited) {
        $ids = Get-DescendantProcessIds -RootId $script:fixProc.Id
        Stop-ProcessTreeSafely -Descendants $ids
    }
})

# ============================================================================
# Tab 2: Install/Uninstall/Upgrade queue control
# ============================================================================

$script:installQueue = New-Object System.Collections.Generic.Queue[object]
$script:installProc = $null
$script:installLogFile = $null
$script:installMode = $null
$script:installTotal = 0
$script:installDone = 0
$script:installFailedCount = 0
$script:installFailedNames = New-Object System.Collections.Generic.List[string]
$script:currentQueueEntry = $null
$script:installPendingAction = $null
$script:directDownloadPS = $null
$script:directDownloadHandle = $null
$script:directDownloadPath = $null

# For Compare Against Export when the old machine can't run this tool at all (e.g. it's
# in active use by the person still on it) - accepts the raw copy-pasted console output of
# a remote command run through an RMM tool, PowerShell remoting, or similar, saved to a
# .txt file. Same column-position technique as Get-WingetListedIds below: look for the
# DisplayName/DisplayVersion header a Format-Table dump produces, find the real columns
# from the header's own character positions (not a fixed offset), and stop at the first
# blank line or trailing "PS C:\..." prompt a copy-pasted console transcript carries.
# Falls back to one app name per non-empty line for anything that isn't that exact shape -
# a plain name list (however it was produced) still works.
function ConvertFrom-AppListText {
    param([string]$Text)
    $lines = $Text -split "`r?`n"
    $names = New-Object System.Collections.Generic.List[string]
    $headerIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^DisplayName\s+DisplayVersion') { $headerIndex = $i; break }
    }
    if ($headerIndex -ge 0) {
        $header = $lines[$headerIndex]
        $nameCol = $header.IndexOf('DisplayName')
        $versionCol = $header.IndexOf('DisplayVersion')
        for ($i = $headerIndex + 2; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if (-not $line -or -not $line.Trim()) { break }
            if ($line -match '^PS [A-Za-z]:\\') { break }
            if ($line.Length -le $nameCol) { continue }
            $endCol = if ($versionCol -gt $nameCol) { [Math]::Min($versionCol, $line.Length) } else { $line.Length }
            $name = $line.Substring($nameCol, $endCol - $nameCol).Trim()
            if ($name) { $names.Add($name) }
        }
    } else {
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if (-not $trimmed) { continue }
            if ($trimmed -match '^PS [A-Za-z]:\\') { continue }
            $names.Add($trimmed)
        }
    }
    return @($names | Sort-Object -Unique)
}

# Plain substring matching (catalog Name inside a real DisplayName) doesn't work for the
# .NET runtime family - a single .NET major version shows up under several different
# component names (confirmed against real Compare Against List output: "Microsoft .NET
# Host - 10.0.12 (x64)", "Microsoft .NET Host FX Resolver - 10.0.12 (x64)", "Microsoft
# .NET Runtime - 10.0.12 (x64)", "Microsoft Windows Desktop Runtime - 10.0.12 (x64)", and
# even "Microsoft Windows Desktop Runtime 10.0.12 (x64)" with no dash - none of which
# contain the catalog's own name, ".NET Desktop Runtime 10", as a literal substring).
# Installing any one of the catalog's "N.DotNet.DesktopRuntime.N" winget packages pulls in
# the whole matching component stack together, so one correct match per major version is
# enough - this only needs to recognize that stack by name, not install each piece
# separately. Scoped narrowly to catalog entries actually named this way (unlike a fully
# generic fuzzy matcher) since .NET runtime components are the one case confirmed, twice,
# to recur on every real machine comparison - everything else observed so far (the VC++
# Redistributable naming mismatch) was accepted as a one-off, not chased the same way.
function Test-DotNetRuntimeNameMatch {
    param([string]$CatalogName, [string]$CandidateName)
    if (-not $CandidateName) { return $false }
    if ($CatalogName -notmatch '^\.NET Desktop Runtime (\d+)$') { return $false }
    $majorVersion = $Matches[1]
    if ($CandidateName -notmatch '(?i)(\.NET|Desktop Runtime)') { return $false }
    # Major version as its own token (e.g. the "10" in "10.0.12", not the "10" inside
    # "110.0.12") - not preceded by another digit. No lookahead needed after the literal
    # dot: a version string always has more digits after its first dot ("10.0.12"), so
    # requiring "not followed by a digit" there would reject every real version string -
    # confirmed as a real bug this way during testing, not assumed.
    return [bool]($CandidateName -match "(?<!\d)$majorVersion\.")
}

# winget right-pads every column to the widest value it holds in that particular run, so
# there's no fixed offset to hardcode - the header row's own character positions are the
# only reliable way to slice the Id column back out of a `winget list` table.
function Get-WingetListedIds {
    param([string]$Path)
    $ids = New-Object 'System.Collections.Generic.HashSet[string]'
    if (-not $Path -or -not (Test-Path $Path)) { return $ids }
    $lines = Get-Content -Path $Path -ErrorAction SilentlyContinue
    $headerIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^Name\s+Id\s+Version') { $headerIndex = $i; break }
    }
    if ($headerIndex -lt 0 -or $headerIndex + 1 -ge $lines.Count) { return $ids }
    $header = $lines[$headerIndex]
    $idCol = $header.IndexOf('Id')
    $versionCol = $header.IndexOf('Version')
    if ($idCol -lt 0 -or $versionCol -lt 0 -or $versionCol -le $idCol) { return $ids }
    for ($i = $headerIndex + 2; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $line -or $line.Length -le $idCol) { continue }
        if ($line -match '^\d+ package') { continue }
        $endCol = [Math]::Min($versionCol, $line.Length)
        $id = $line.Substring($idCol, $endCol - $idCol).Trim()
        if ($id) { [void]$ids.Add($id) }
    }
    return $ids
}

function Complete-InstallQueueItem {
    # Shared "what happens after one queue item finishes" logic - used by both the
    # winget-backed completion path and the direct-download completion path below, so
    # the final "Done: n ok, m failed" summary and button re-enabling only live in one
    # place.
    if ($script:installQueue -and $script:installQueue.Count -gt 0) {
        Start-NextInQueue
    } else {
        $okCount = $script:installTotal - $script:installFailedCount
        $installStatusText.Text = "Done: $okCount ok, $($script:installFailedCount) failed"
        $btnInstallSelected.IsEnabled = $true
        $btnUninstallSelected.IsEnabled = $true
        $btnUpgradeAll.IsEnabled = $true
        $btnCheckInstalled.IsEnabled = $true
        $btnExportInstalled.IsEnabled = $true
        $btnCompareBaseline.IsEnabled = $true
        $btnStopInstall.Visibility = 'Collapsed'
    }
}

function Start-NextInQueue {
    if ($script:installQueue.Count -eq 0) {
        $installStatusText.Text = "Done ($($script:installDone)/$($script:installTotal))"
        $btnInstallSelected.IsEnabled = $true
        $btnUninstallSelected.IsEnabled = $true
        $btnUpgradeAll.IsEnabled = $true
        $btnCheckInstalled.IsEnabled = $true
        $btnExportInstalled.IsEnabled = $true
        $btnCompareBaseline.IsEnabled = $true
        $btnStopInstall.Visibility = 'Collapsed'
        $script:installProc = $null
        $script:currentQueueEntry = $null
        return
    }
    $entry = $script:installQueue.Dequeue()
    $script:currentQueueEntry = $entry
    $actionWord = switch ($script:installMode) {
        'install' { 'Installing' }
        'uninstall' { 'Uninstalling' }
    }
    $installStatusText.Text = "$actionWord $($entry.Name)... ($($script:installDone + 1)/$($script:installTotal))"

    # Manual Install Only entries (no winget package, no direct-download URL either -
    # tenant login, license key, or a vendor email is required) have nothing this tool
    # can run. Point at the real product/download page instead of falling through to the
    # winget branch below with an empty --id, which would just log a confusing failure.
    if (-not $entry.WingetId -and -not $entry.DownloadUrl) {
        $installLogBox.AppendText("=== $actionWord`: $($entry.Name) (manual install only) ===`r`n")
        $linkText = if ($entry.Url) { $entry.Url } else { 'no link available - check the vendor directly' }
        $installLogBox.AppendText("No automated installer available for $($entry.Name). Download it yourself from: $linkText`r`n")
        $installLogBox.ScrollToEnd()
        $script:installDone++
        Complete-InstallQueueItem
        return
    }

    # Direct-download entries (no winget package exists) skip winget entirely - they
    # download their own installer and launch it visibly (not hidden, not waited on),
    # since some free-edition installers (FreeFileSync) don't support silent/unattended
    # install and would otherwise stall the queue waiting on a window nobody can click.
    if (-not $entry.WingetId -and $entry.DownloadUrl) {
        $installLogBox.AppendText("=== $actionWord`: $($entry.Name) (direct download, no winget package) ===`r`n")
        if ($script:installMode -ne 'install') {
            $installLogBox.AppendText("Not available via winget - manage $($entry.Name) manually (Programs and Features).`r`n")
            $installLogBox.ScrollToEnd()
            $script:installDone++
            Complete-InstallQueueItem
            return
        }

        # FreeFileSync's download URL embeds its current version number with no stable
        # "latest" redirect - the catalog's own downloadUrl goes stale every release, so
        # when a dynamicDownloadPage is set, resolve today's real filename from that page
        # first. This is a small page fetch (tens of KB), not the installer itself, so
        # doing it inline (not in the background runspace below) is an acceptable brief
        # UI pause rather than a full extra async stage for one catalog entry.
        $resolvedDownloadUrl = $entry.DownloadUrl
        if ($entry.DynamicDownloadPage) {
            try {
                $pageHtml = Invoke-WebRequest -Uri $entry.DynamicDownloadPage -UseBasicParsing -ErrorAction Stop
                $fileMatch = [regex]::Match($pageHtml.Content, 'FreeFileSync_[\d.]+_Windows_Setup\.exe')
                if ($fileMatch.Success) {
                    $resolvedDownloadUrl = "https://freefilesync.org/download/$($fileMatch.Value)"
                } else {
                    $installLogBox.AppendText("Could not find a current download link on $($entry.DynamicDownloadPage) - falling back to the last-known version.`r`n")
                }
            } catch {
                $installLogBox.AppendText("Could not check for the current version ($($_.Exception.Message)) - falling back to the last-known version.`r`n")
            }
        }

        # Invoke-WebRequest runs in a background runspace, not inline here - this used to
        # block the UI thread for as long as the download took, same class of problem as
        # the Scan feature above. The queue continues once the timer tick sees the
        # background download finish (see the $script:directDownloadPS poll below),
        # instead of recursing into Start-NextInQueue immediately.
        $downloadPath = Join-Path $workDir (Split-Path -Leaf $resolvedDownloadUrl)
        $installLogBox.AppendText("Downloading $resolvedDownloadUrl...`r`n")
        $installLogBox.ScrollToEnd()
        $script:directDownloadPath = $downloadPath
        $script:directDownloadPS = [powershell]::Create()
        [void]$script:directDownloadPS.AddScript({
            param($Url, $OutFile)
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
        })
        [void]$script:directDownloadPS.AddArgument($resolvedDownloadUrl)
        [void]$script:directDownloadPS.AddArgument($downloadPath)
        $script:directDownloadHandle = $script:directDownloadPS.BeginInvoke()
        return
    }

    $installLogBox.AppendText("=== $actionWord`: $($entry.Name) ($($entry.WingetId)) ===`r`n")
    $installLogBox.ScrollToEnd()

    $script:installLogFile = Join-Path $workDir "winget_$($script:installMode)_$(Get-Date -Format 'yyyyMMdd_HHmmss_fff').log"
    $wingetArgs = switch ($script:installMode) {
        'install' { @('install', '--id', $entry.WingetId, '-e', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') }
        'uninstall' { @('uninstall', '--id', $entry.WingetId, '-e', '--source', 'winget', '--silent', '--accept-source-agreements', '--disable-interactivity') }
    }

    $script:installProc = Start-Process -FilePath 'winget.exe' -ArgumentList $wingetArgs `
        -RedirectStandardOutput $script:installLogFile -RedirectStandardError "$($script:installLogFile).err" `
        -WindowStyle Hidden -PassThru
    # Force .NET to retain a real process handle now, before this winget can exit - read
    # ExitCode later without this and it's unreliable (throws or reads stale), since the
    # CLR only caches the handle needed to retrieve it if something touches Handle early.
    $script:installProc.Handle | Out-Null
    $script:installDone++
}

function Start-AppQueue {
    param([string]$Mode)
    $selected = @($script:appEntries | Where-Object { $_.CheckBox.IsChecked })
    if ($selected.Count -eq 0) { return }
    # $sacPolicyState (read once at window load) is 1 only when Smart App Control is On
    # and actually enforcing - 0 (off) or 2 (evaluation/audit-only) don't block installs,
    # so there's nothing useful to warn about in those states.
    if ($Mode -eq 'install' -and $sacPolicyState -eq 1) {
        $riskyNames = @($selected | Where-Object { $_.SacRisk } | ForEach-Object { $_.Name })
        if ($riskyNames.Count -gt 0) {
            $result = [System.Windows.MessageBox]::Show(
                "Smart App Control is On for this machine. These selected apps are known to be unsigned/low-reputation and may be blocked by Smart App Control during install:`r`n`r`n$($riskyNames -join "`r`n")`r`n`r`nContinue anyway?",
                'Confirm: Smart App Control Risk', 'YesNo', 'Warning')
            if ($result -ne 'Yes') { return }
        }
    }
    $script:installQueue = New-Object System.Collections.Generic.Queue[object]
    foreach ($entry in $selected) { $script:installQueue.Enqueue($entry) }
    $script:installMode = $Mode
    $script:installTotal = $selected.Count
    $script:installDone = 0
    $script:installFailedCount = 0
    $script:installFailedNames.Clear()
    $installLogBox.Text = ''
    $btnInstallSelected.IsEnabled = $false
    $btnUninstallSelected.IsEnabled = $false
    $btnUpgradeAll.IsEnabled = $false
    $btnCheckInstalled.IsEnabled = $false
    $btnExportInstalled.IsEnabled = $false
    $btnCompareBaseline.IsEnabled = $false
    $btnStopInstall.Visibility = 'Visible'
    Start-NextInQueue
}

# Detecting "what's already installed" answers a different question than
# install/uninstall - it scans the whole catalog regardless of what's ticked, in one
# consolidated `winget list` call (see 0.10: this used to be 63 separate per-app winget
# processes/log files), so it's its own function rather than a Start-AppQueue mode.
function Start-InstalledCheck {
    if ($script:installProc -and -not $script:installProc.HasExited) { return }
    $installLogBox.Text = ''
    $installStatusText.Text = 'Checking installed apps...'
    $btnInstallSelected.IsEnabled = $false
    $btnUninstallSelected.IsEnabled = $false
    $btnUpgradeAll.IsEnabled = $false
    $btnCheckInstalled.IsEnabled = $false
    $btnExportInstalled.IsEnabled = $false
    $btnCompareBaseline.IsEnabled = $false
    $btnStopInstall.Visibility = 'Visible'
    $script:installMode = 'check'
    $script:currentQueueEntry = $null
    $script:installLogFile = Join-Path $workDir "winget_list_all_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $script:installProc = Start-Process -FilePath 'winget.exe' `
        -ArgumentList @('list', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity') `
        -RedirectStandardOutput $script:installLogFile -RedirectStandardError "$($script:installLogFile).err" `
        -WindowStyle Hidden -PassThru
    $script:installProc.Handle | Out-Null
}

$btnInstallSelected.Add_Click({ Start-AppQueue -Mode 'install' })
$btnUninstallSelected.Add_Click({
    $selected = @($script:appEntries | Where-Object { $_.CheckBox.IsChecked })
    if ($selected.Count -eq 0) { return }
    $names = ($selected | ForEach-Object { "- $($_.Name)" }) -join "`r`n"
    $result = [System.Windows.MessageBox]::Show("Uninstall these $($selected.Count) app(s)?`r`n`r`n$names", 'Confirm Uninstall', 'YesNo', 'Warning')
    if ($result -ne 'Yes') { return }
    Start-AppQueue -Mode 'uninstall'
})
$btnCheckInstalled.Add_Click({ Start-InstalledCheck })

$btnExportInstalled.Add_Click({
    if ($script:installProc -and -not $script:installProc.HasExited) { return }
    $script:installPendingAction = 'export'
    Start-InstalledCheck
})

# Themed as its own small XAML tree (not sharable with the main window's resources,
# which live in that separate parsed document) rather than a plain System.Windows.MessageBox
# - a MessageBox can't hold a selectable/copyable command box, and its default white
# Win32 chrome looks broken sitting on top of this app's dark theme.
function Show-NoGuiExportDialog {
    $dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="No GUI Access - Export Installed Apps" Width="640" SizeToContent="Height"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="#232629" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <SolidColorBrush x:Key="BgBrush" Color="#232629"/>
    <SolidColorBrush x:Key="ButtonBrush" Color="#1E3747"/>
    <SolidColorBrush x:Key="ButtonHoverBrush" Color="#2A4C69"/>
    <SolidColorBrush x:Key="ControlBorderBrush" Color="#707070"/>
    <SolidColorBrush x:Key="TextBrush" Color="#F7F7F7"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#9AA3AB"/>
    <SolidColorBrush x:Key="HeaderBrush" Color="#5BDCFF"/>
    <SolidColorBrush x:Key="LogBgBrush" Color="#1B1E21"/>
    <SolidColorBrush x:Key="PanelBorderBrush" Color="#2F373D"/>
    <SolidColorBrush x:Key="NavSelectedBrush" Color="#5E81AC"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="{StaticResource ButtonBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource ButtonHoverBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource LogBgBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource PanelBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="SelectionBrush" Value="{StaticResource NavSelectedBrush}"/>
      <Setter Property="CaretBrush" Value="{StaticResource TextBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Padding="20">
    <StackPanel>
      <TextBlock Text="No GUI access on the old machine?" FontFamily="Consolas" FontSize="16" Foreground="{StaticResource HeaderBrush}" Margin="0,0,0,10"/>
      <TextBlock TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" Margin="0,0,0,16"
                 Text="Run this on the OLD machine through whatever command-line access you have - RMM run-script, PowerShell remoting, winrs, whatever - when you can't launch this GUI there at all. It prints the same export Export Installed Apps... produces straight to the console."/>

      <TextBlock Text="Run on the old machine:" FontWeight="Bold" Margin="0,0,0,4"/>
      <Grid Margin="0,0,0,16">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBox Name="CmdPrint" Grid.Column="0" Height="30" VerticalContentAlignment="Center"/>
        <Button Name="BtnCopyPrint" Grid.Column="1" Content="Copy" Width="70" Height="30" Margin="8,0,0,0"/>
      </Grid>

      <TextBlock Text="Or save straight to a file on that machine instead:" FontWeight="Bold" Margin="0,0,0,4"/>
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBox Name="CmdFile" Grid.Column="0" Height="54" AcceptsReturn="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
        <Button Name="BtnCopyFile" Grid.Column="1" Content="Copy" Width="70" Height="30" Margin="8,0,0,0" VerticalAlignment="Top"/>
      </Grid>

      <TextBlock TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" Margin="0,16,0,16"
                 Text="Either way, the result is the same JSON shape Compare Against List... already reads - once you have the file (or saved console output) on the new machine, point Compare Against List... at it like normal."/>

      <Button Name="BtnDialogClose" Content="Close" HorizontalAlignment="Right" Width="90"/>
    </StackPanel>
  </Border>
</Window>
'@
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($dialogXaml))
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    $dialog.Owner = $window

    $cmdPrint = $dialog.FindName('CmdPrint')
    $cmdFile = $dialog.FindName('CmdFile')
    $btnCopyPrint = $dialog.FindName('BtnCopyPrint')
    $btnCopyFile = $dialog.FindName('BtnCopyFile')
    $btnDialogClose = $dialog.FindName('BtnDialogClose')

    $cmdPrint.Text = 'irm get.gr3y.io/debloat-export | iex'
    $cmdFile.Text = "`$s = irm get.gr3y.io/debloat-export`r`n& ([scriptblock]::Create(`$s)) -OutputPath C:\Temp\installed-apps.json"

    # Brief "Copied!" feedback on the clicked button, reverted after ~1.2s - a DispatcherTimer
    # closure per click rather than a single shared one, since either Copy button can fire
    # independently and each needs to revert only its own Content.
    $makeCopyHandler = {
        param($TextBox, $Button)
        # Clipboard access can transiently fail (another process briefly holding it open,
        # no desktop/window station attached, etc.) - still give "Copied!" feedback either
        # way rather than letting an unhandled COMException surface from inside a Click
        # handler.
        try { [System.Windows.Clipboard]::SetText($TextBox.Text) } catch {}
        $Button.Content = 'Copied!'
        $revertTimer = New-Object System.Windows.Threading.DispatcherTimer
        $revertTimer.Interval = [TimeSpan]::FromSeconds(1.2)
        $revertTimer.Add_Tick({ $Button.Content = 'Copy'; $revertTimer.Stop() }.GetNewClosure())
        $revertTimer.Start()
    }
    $btnCopyPrint.Add_Click({ & $makeCopyHandler $cmdPrint $btnCopyPrint }.GetNewClosure())
    $btnCopyFile.Add_Click({ & $makeCopyHandler $cmdFile $btnCopyFile }.GetNewClosure())
    $btnDialogClose.Add_Click({ $dialog.Close() }.GetNewClosure())

    $dialog.ShowDialog() | Out-Null
}

$btnNoGuiExport.Add_Click({ Show-NoGuiExportDialog })

$btnCompareBaseline.Add_Click({
    if ($script:installProc -and -not $script:installProc.HasExited) { return }
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'App list (*.json;*.txt)|*.json;*.txt|All files (*.*)|*.*'
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if (-not $dialog.ShowDialog()) { return }
    $rawText = $null
    try {
        $rawText = Get-Content -Path $dialog.FileName -Raw
    } catch {
        [System.Windows.MessageBox]::Show("Could not read that file: $($_.Exception.Message)", 'Gr3y Tools', 'OK', 'Error') | Out-Null
        return
    }

    # Two input shapes: a Gr3y Tools export (JSON, has wingetIds) from a machine that ran
    # this tool's own Export Installed Apps, or any plain-text program-name list (.txt) -
    # the old machine's own installed-apps dump from an RMM tool, PowerShell remoting, or
    # anything else, for the common case where this tool can't be run there at all (e.g.
    # it's in active use by the person still on it). Both end up normalized to the same
    # {hostname; exportedAt; wingetIds; installedProgramNames} shape the compare logic uses.
    $baseline = $null
    try {
        $parsedJson = $rawText | ConvertFrom-Json -ErrorAction Stop
        if ($parsedJson.installedProgramNames -or $parsedJson.wingetIds) {
            $baseline = [PSCustomObject]@{
                hostname = if ($parsedJson.hostname) { $parsedJson.hostname } else { Split-Path -Leaf $dialog.FileName }
                exportedAt = if ($parsedJson.exportedAt) { $parsedJson.exportedAt } else { (Get-Item $dialog.FileName).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') }
                wingetIds = @($parsedJson.wingetIds)
                installedProgramNames = @($parsedJson.installedProgramNames)
            }
        }
    } catch {}
    if (-not $baseline) {
        $names = ConvertFrom-AppListText -Text $rawText
        if ($names.Count -eq 0) {
            [System.Windows.MessageBox]::Show("Could not find any app names in that file. Expected either a Gr3y Tools export (JSON) or a plain-text list - one app name per line, or a pasted DisplayName/DisplayVersion table (e.g. from Get-ItemProperty on the Uninstall registry keys, run through an RMM tool).", 'Gr3y Tools', 'OK', 'Error') | Out-Null
            return
        }
        $baseline = [PSCustomObject]@{
            hostname = Split-Path -Leaf $dialog.FileName
            exportedAt = (Get-Item $dialog.FileName).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            wingetIds = @()
            installedProgramNames = $names
        }
    }

    $script:installPendingAction = [PSCustomObject]@{ Action = 'compare'; Baseline = $baseline }
    Start-InstalledCheck
})

$btnUpgradeAll.Add_Click({
    # Same double-launch hole as Start had - a fast double-click before the next timer
    # tick disables the button would otherwise orphan the first winget upgrade process.
    if ($script:installProc -and -not $script:installProc.HasExited) { return }

    # Distinct mode (not reusing 'install'/'check') so the per-entry completion
    # handling below never mistakes this one-off run for a queued check result.
    $script:installMode = 'upgrade'
    $script:currentQueueEntry = $null
    $script:installLogFile = Join-Path $workDir "winget_upgrade_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $installLogBox.Text = "=== Upgrading all installed apps ===`r`n"
    $script:installProc = Start-Process -FilePath 'winget.exe' -ArgumentList @('upgrade', '--all', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') `
        -RedirectStandardOutput $script:installLogFile -RedirectStandardError "$($script:installLogFile).err" -WindowStyle Hidden -PassThru
    $installStatusText.Text = 'Upgrading all installed apps...'
    $btnInstallSelected.IsEnabled = $false
    $btnUninstallSelected.IsEnabled = $false
    $btnUpgradeAll.IsEnabled = $false
    $btnCheckInstalled.IsEnabled = $false
    $btnExportInstalled.IsEnabled = $false
    $btnCompareBaseline.IsEnabled = $false
    $btnStopInstall.Visibility = 'Visible'
})

$btnStopInstall.Add_Click({
    if ($script:installProc -and -not $script:installProc.HasExited) {
        try { Stop-Process -Id $script:installProc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    $script:installQueue.Clear()
    $script:currentQueueEntry = $null
    $script:installPendingAction = $null
    $installStatusText.Text = 'Stopped.'
    $btnInstallSelected.IsEnabled = $true
    $btnUninstallSelected.IsEnabled = $true
    $btnUpgradeAll.IsEnabled = $true
    $btnCheckInstalled.IsEnabled = $true
    $btnExportInstalled.IsEnabled = $true
    $btnCompareBaseline.IsEnabled = $true
    $btnStopInstall.Visibility = 'Collapsed'
})

$script:wingetInstallProc = $null
$script:wingetInstallLogFile = $null

$btnInstallWinGet.Add_Click({
    $btnInstallWinGet.IsEnabled = $false
    $btnInstallWinGet.Content = 'Installing winget...'
    $wingetStatusDot.Fill = $accentBrush
    $wingetStatusText.Text = 'Installing winget (needs internet)...'
    $wingetStatusText.Foreground = $accentBrush

    $script:wingetInstallLogFile = Join-Path $workDir "wingetinstall_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $installCmd = 'Install-PackageProvider -Name NuGet -Force | Out-Null; ' +
        'Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null; ' +
        'Repair-WinGetPackageManager'
    $script:wingetInstallProc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $installCmd) `
        -RedirectStandardOutput $script:wingetInstallLogFile -RedirectStandardError "$($script:wingetInstallLogFile).err" `
        -WindowStyle Hidden -PassThru
})

# ============================================================================
# Poll timer - drives both tabs
# ============================================================================

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(1200)
$timer.Add_Tick({
    # --- Tab 1 ---
    if ($script:deployProc) {
        $logResult = Get-LogTail -Path $script:deployLogFile -Offset $script:deployLogOffset
        if ($logResult.text) {
            $logBox.AppendText($logResult.text)
            $logBox.ScrollToEnd()
        }
        $script:deployLogOffset = $logResult.offset

        $running = $false
        try {
            $script:deployProc.Refresh()
            $running = -not $script:deployProc.HasExited
        } catch {}

        $script:deployPhase = Update-PhaseFromTail -TailText $logResult.text -CurrentPhase $script:deployPhase
        $phaseText.Text = $script:deployPhase
        if ($script:deployStartTime) {
            $elapsed = [int]((Get-Date) - $script:deployStartTime).TotalSeconds
            $elapsedText.Text = "{0}:{1:D2}" -f [int]($elapsed / 60), ($elapsed % 60)
        }

        if ($running) {
            $cpu = Get-TreeCpuSeconds -RootId $script:deployProc.Id
            $cpuText.Text = "{0:N1}s" -f $cpu
            $stateText.Text = 'Running'
            $statusDot.Fill = $greenBrush
            $btnStart.IsEnabled = $false
            $btnStop.Visibility = 'Visible'
        } else {
            $btnStart.IsEnabled = $true
            $btnStop.Visibility = 'Collapsed'
            $btnDownloadLog.Visibility = 'Visible'
            if (-not $script:deployHasFinishedBannerShown) {
                $script:deployHasFinishedBannerShown = $true
                # One-shot full-file read is fine here - this only runs once, right as
                # the job finishes, not on every tick.
                $finishedSummary = Get-LogSummary -LogPath $script:deployLogFile
                if ($finishedSummary.completed -and -not $finishedSummary.hasWarnings) {
                    $stateText.Text = 'Done'
                    $statusDot.Fill = $accentBrush
                    $bannerText.Text = 'Run finished successfully. Reboot to finish clearing removed services/drivers.'
                    $bannerBorder.Background = '#0f2a17'
                    $bannerBorder.BorderBrush = $greenBrush
                    $bannerBorder.Visibility = 'Visible'
                    if (-not $script:deployIsDryRun) { $btnReboot.Visibility = 'Visible' }
                } elseif ($finishedSummary.completed -and $finishedSummary.hasWarnings) {
                    $stateText.Text = 'Done (warnings)'
                    $statusDot.Fill = $yellowBrush
                    $bannerText.Text = "Run finished with $($finishedSummary.warningCount) warning(s)/error(s) - check the log above before considering this machine done."
                    $bannerBorder.Background = '#2a2410'
                    $bannerBorder.BorderBrush = $yellowBrush
                    $bannerBorder.Visibility = 'Visible'
                    if (-not $script:deployIsDryRun) { $btnReboot.Visibility = 'Visible' }
                } else {
                    $stateText.Text = 'Error'
                    $statusDot.Fill = $redBrush
                    $bannerText.Text = 'The job ended before finishing. Check the log above for where it stopped.'
                    $bannerBorder.Background = '#2a0f0f'
                    $bannerBorder.BorderBrush = $redBrush
                    $bannerBorder.Visibility = 'Visible'
                }
                if ($script:deployErrFile -and (Test-Path $script:deployErrFile)) {
                    $errTail = Get-Content -Path $script:deployErrFile -Raw -ErrorAction SilentlyContinue
                    if ($errTail) {
                        $logBox.AppendText("`r`n=== stderr ===`r`n$errTail")
                        $logBox.ScrollToEnd()
                    }
                }
            }
        }
    }

    # --- Tab 2 ---
    if ($script:installProc) {
        $running = $false
        try {
            $script:installProc.Refresh()
            $running = -not $script:installProc.HasExited
        } catch {}
        if (-not $running) {
            if ($script:installMode -eq 'check') {
                $installedIds = Get-WingetListedIds -Path $script:installLogFile

                if ($script:installPendingAction -eq 'export') {
                    $script:installPendingAction = $null
                    $programNames = @(Get-UninstallEntries | Select-Object -ExpandProperty DisplayName -Unique | Sort-Object)
                    $export = [PSCustomObject]@{
                        hostname = $env:COMPUTERNAME
                        exportedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        wingetIds = @($installedIds)
                        installedProgramNames = $programNames
                    }
                    $saveDialog = New-Object Microsoft.Win32.SaveFileDialog
                    $saveDialog.FileName = "installed-apps_$(Get-MachineTag).json"
                    $saveDialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
                    $saveDialog.Filter = 'JSON files (*.json)|*.json|All files (*.*)|*.*'
                    if ($saveDialog.ShowDialog()) {
                        try {
                            ($export | ConvertTo-Json -Depth 4) | Set-Content -Path $saveDialog.FileName -Encoding UTF8
                            $installStatusText.Text = "Exported $($export.wingetIds.Count) winget app(s) and $($programNames.Count) program name(s) to $($saveDialog.FileName)"
                            [System.Windows.MessageBox]::Show("Saved to $($saveDialog.FileName)`r`n`r`nRun Compare Against Export on the new machine and point it at this file.", 'Gr3y Tools', 'OK', 'Information') | Out-Null
                        } catch {
                            [System.Windows.MessageBox]::Show("Could not save: $($_.Exception.Message)", 'Gr3y Tools', 'OK', 'Error') | Out-Null
                        }
                    } else {
                        $installStatusText.Text = 'Export cancelled.'
                    }
                } elseif ($script:installPendingAction -and $script:installPendingAction.Action -eq 'compare') {
                    $baseline = $script:installPendingAction.Baseline
                    $script:installPendingAction = $null
                    # Matching works by name (always available - a plain-text/RMM-pulled
                    # list only ever has DisplayNames, never winget package IDs) OR'd with
                    # winget ID matching when the baseline came from this tool's own Export
                    # (more precise where it's available). Name matching is a substring
                    # check: catalog names are short ("Firefox") and real product names are
                    # longer ("Mozilla Firefox") - confirmed necessary and sufficient by a
                    # dedicated test against the exact kind of DisplayName/DisplayVersion
                    # dump an RMM tool's remote command output produces. Best-effort, not
                    # guaranteed full recall - e.g. catalog name "Visual C++ 2015-2022
                    # 64-bit" is genuinely not a substring of the real registered name
                    # "Microsoft Visual C++ 2015-2022 Redistributable (x64)", so that one
                    # would land in the manual-install list below despite having a real
                    # catalog entry. A missed match only means one more line in that list,
                    # never a wrong auto-check, so this tradeoff was kept deliberately
                    # simple rather than chasing a token/synonym matcher for marginal gain.
                    $currentProgramNames = @(Get-UninstallEntries | Select-Object -ExpandProperty DisplayName)
                    $currentNameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                    foreach ($n in $currentProgramNames) { [void]$currentNameSet.Add($n) }

                    $matchedCount = 0
                    $matchedCatalogNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                    foreach ($entry in $script:appEntries) {
                        # Reset first - a second Compare run (a different export file, or a
                        # re-run after installing some of the first batch) must not leave
                        # last time's matches stuck in the Compare Results view.
                        $entry.CompareMatch = $false
                        $onBaseline = ($entry.WingetId -and ($baseline.wingetIds -contains $entry.WingetId)) -or
                                      [bool]($baseline.installedProgramNames | Where-Object { $_ -and (($_ -like "*$($entry.Name)*") -or (Test-DotNetRuntimeNameMatch -CatalogName $entry.Name -CandidateName $_)) } | Select-Object -First 1)
                        if (-not $onBaseline) { continue }
                        $alreadyHere = ($entry.WingetId -and $installedIds.Contains($entry.WingetId)) -or
                                       [bool]($currentProgramNames | Where-Object { $_ -and (($_ -like "*$($entry.Name)*") -or (Test-DotNetRuntimeNameMatch -CatalogName $entry.Name -CandidateName $_)) } | Select-Object -First 1)
                        if ($alreadyHere) { continue }
                        $entry.CheckBox.IsChecked = $true
                        $entry.CheckBox.Foreground = $accentBrush
                        $entry.CheckBox.Content = "$($entry.Name) (missing - on old machine)"
                        $entry.CompareMatch = $true
                        [void]$matchedCatalogNames.Add($entry.Name)
                        $matchedCount++
                    }
                    # Apps present by name on the baseline machine with no catalog match at
                    # all - nothing to auto-check, so just list them (matches the kind of
                    # manual line-item the ticket's own instructions already call out, e.g.
                    # a LOB app with no winget package).
                    $unmatched = New-Object System.Collections.Generic.List[string]
                    foreach ($name in @($baseline.installedProgramNames)) {
                        if (-not $name) { continue }
                        if ($currentNameSet.Contains($name)) { continue }
                        # Catalog names are short ("Firefox") and registry DisplayNames are
                        # the full product name ("Mozilla Firefox") - they're different
                        # strings for the same app, so an exact-match check here would never
                        # catch an app the catalog match above already checked (confirmed by
                        # a failing test before this -like substring check was added: Firefox
                        # was both auto-checked AND wrongly listed as needing a manual
                        # install). A substring check is a reasonable match for this case.
                        $alreadyHandled = $false
                        foreach ($catalogName in $matchedCatalogNames) {
                            if (($name -like "*$catalogName*") -or (Test-DotNetRuntimeNameMatch -CatalogName $catalogName -CandidateName $name)) { $alreadyHandled = $true; break }
                        }
                        if ($alreadyHandled) { continue }
                        $unmatched.Add($name)
                    }
                    $unmatched = @($unmatched | Sort-Object -Unique)

                    # A dedicated filter instead of 'All' - the whole point raised against
                    # the first version of this feature was that scrolling through all 77
                    # catalog apps across categories to find ~5 highlighted ones wasn't
                    # usable; this view shows only the matches, so picking which ones to
                    # install means looking at a short list, not hunting for color-coding.
                    # Only switch to it when there's something to show - an empty filtered
                    # view reads as "this is broken," not "good news, nothing missing."
                    $lines = New-Object System.Collections.Generic.List[string]
                    $lines.Add("Compared against $($baseline.hostname) (exported $($baseline.exportedAt)).")
                    if ($matchedCount -gt 0) {
                        $catCompareResultsBtn.Visibility = 'Visible'
                        $script:activeCategory = 'Compare Results'
                        Update-AppVisibility
                        $lines.Add("$matchedCount catalog app(s) checked below (installed there, missing here) - ready for Install Selected.")
                    } else {
                        $lines.Add('No catalog app was missing here that is installed on the old machine.')
                        # Don't strand the view on a now-empty Compare Results filter from a
                        # previous run.
                        if ($script:activeCategory -eq 'Compare Results') {
                            $script:activeCategory = 'Business Baseline'
                            Update-AppVisibility
                        }
                    }
                    $lines.Add('')
                    if ($unmatched.Count -gt 0) {
                        $lines.Add("$($unmatched.Count) more installed on the old machine with no catalog match - install these manually:")
                        foreach ($n in $unmatched) { $lines.Add("  - $n") }
                    } else {
                        $lines.Add('Nothing else installed on the old machine was missing here.')
                    }
                    $installLogBox.Text = $lines -join "`r`n"
                    $installStatusText.Text = "Done - $matchedCount app(s) checked, $($unmatched.Count) need a manual look (see log)"
                } else {
                    # One consolidated `winget list` covering the whole catalog - colour/relabel
                    # only, never auto-tick a box, so a fresh laptop's Edge/OneDrive/PowerShell/
                    # Windows Terminal/VC++ redists/.NET runtimes don't end up pre-selected for
                    # Uninstall Selected.
                    $foundCount = 0
                    foreach ($entry in $script:appEntries) {
                        if (-not $entry.WingetId) { continue }
                        if ($installedIds.Contains($entry.WingetId)) {
                            $entry.CheckBox.Foreground = $greenBrush
                            $entry.CheckBox.Content = "$($entry.Name) (installed)"
                            $foundCount++
                        } else {
                            $entry.CheckBox.ClearValue([System.Windows.Controls.Control]::ForegroundProperty)
                            $entry.CheckBox.Content = $entry.Name
                        }
                    }
                    $installStatusText.Text = "Done - $foundCount of $($script:appEntries.Count) already installed (colour-coded above - tick the ones you want and use Uninstall Selected to remove them)"
                }

                $script:installProc = $null
                $btnInstallSelected.IsEnabled = $true
                $btnUninstallSelected.IsEnabled = $true
                $btnUpgradeAll.IsEnabled = $true
                $btnCheckInstalled.IsEnabled = $true
                $btnExportInstalled.IsEnabled = $true
                $btnCompareBaseline.IsEnabled = $true
                $btnStopInstall.Visibility = 'Collapsed'
            } elseif ($script:installMode -eq 'upgrade') {
                $tail = $null
                if ($script:installLogFile -and (Test-Path $script:installLogFile)) {
                    $tail = Get-Content -Path $script:installLogFile -Raw -ErrorAction SilentlyContinue
                    if ($tail) { $installLogBox.AppendText($tail); $installLogBox.ScrollToEnd() }
                }
                $installStatusText.Text = 'Done upgrading installed apps.'
                $script:installProc = $null
                $btnInstallSelected.IsEnabled = $true
                $btnUninstallSelected.IsEnabled = $true
                $btnUpgradeAll.IsEnabled = $true
                $btnCheckInstalled.IsEnabled = $true
                $btnExportInstalled.IsEnabled = $true
                $btnCompareBaseline.IsEnabled = $true
                $btnStopInstall.Visibility = 'Collapsed'
            } else {
                # install / uninstall: queue-driven, one winget process (and log file) per
                # selected app - up to 63 of them in a full run. Delete each one right
                # after reading it into the log box instead of leaving it in
                # C:\ProgramData\DellOfficeDeploy forever - its content already went into
                # the Install Apps log box above.
                $tail = $null
                if ($script:installLogFile -and (Test-Path $script:installLogFile)) {
                    $tail = Get-Content -Path $script:installLogFile -Raw -ErrorAction SilentlyContinue
                    if ($tail) { $installLogBox.AppendText($tail); $installLogBox.AppendText("`r`n"); $installLogBox.ScrollToEnd() }
                    Remove-Item -Path $script:installLogFile -Force -ErrorAction SilentlyContinue
                    Remove-Item -Path "$($script:installLogFile).err" -Force -ErrorAction SilentlyContinue
                }

                $exitCode = $null
                try { $exitCode = $script:installProc.ExitCode } catch {}
                if ($script:currentQueueEntry -and $exitCode -ne 0) {
                    $script:installFailedCount++
                    $script:installFailedNames.Add($script:currentQueueEntry.Name)
                    $script:currentQueueEntry.CheckBox.Foreground = $redBrush
                    $script:currentQueueEntry.CheckBox.Content = "$($script:currentQueueEntry.Name) (failed)"
                }

                $script:installProc = $null
                Complete-InstallQueueItem
            }
        }
    }

    if ($script:directDownloadPS -and $script:directDownloadHandle.IsCompleted) {
        try {
            $script:directDownloadPS.EndInvoke($script:directDownloadHandle)
            if ($script:directDownloadPS.Streams.Error.Count -eq 0) {
                $installLogBox.AppendText("Downloaded. Launching installer - this app's free edition doesn't support silent install, so finish its setup wizard manually.`r`n")
                Start-Process -FilePath $script:directDownloadPath
            } else {
                foreach ($err in $script:directDownloadPS.Streams.Error) {
                    $installLogBox.AppendText("Download failed: $($err.ToString())`r`n")
                }
            }
        } catch {
            $installLogBox.AppendText("Download/launch failed: $($_.Exception.Message)`r`n")
        } finally {
            $installLogBox.ScrollToEnd()
            $script:directDownloadPS.Dispose()
            $script:directDownloadPS = $null
            $script:directDownloadHandle = $null
            $script:directDownloadPath = $null
            $script:installDone++
            Complete-InstallQueueItem
        }
    }

    if ($script:wingetInstallProc) {
        $running = $false
        try {
            $script:wingetInstallProc.Refresh()
            $running = -not $script:wingetInstallProc.HasExited
        } catch {}
        if (-not $running) {
            $script:wingetInstallProc = $null
            $script:wingetAvailable = [bool](Get-Command 'winget.exe' -ErrorAction SilentlyContinue)
            if ($script:wingetAvailable) {
                $wingetStatusDot.Fill = $greenBrush
                $wingetStatusText.Text = 'winget ready'
                $wingetStatusText.Foreground = $greenBrush
                $wingetStatusText.ClearValue([System.Windows.Controls.Control]::ToolTipProperty)
                $btnInstallWinGet.Visibility = 'Collapsed'
                foreach ($b in @($btnInstallSelected, $btnUninstallSelected, $btnUpgradeAll, $btnCheckInstalled, $btnExportInstalled, $btnCompareBaseline)) {
                    $b.IsEnabled = $true
                    $b.ClearValue([System.Windows.Controls.Control]::ToolTipProperty)
                }
            } else {
                $wingetStatusDot.Fill = $redBrush
                $wingetStatusText.Text = 'winget install failed - see Install Apps log'
                $wingetStatusText.Foreground = $redBrush
                $btnInstallWinGet.IsEnabled = $true
                $btnInstallWinGet.Content = 'Retry Install winget'
                if ($script:wingetInstallLogFile -and (Test-Path $script:wingetInstallLogFile)) {
                    $tail = Get-Content -Path $script:wingetInstallLogFile -Raw -ErrorAction SilentlyContinue
                    if ($tail) { $installLogBox.AppendText("=== winget install output ===`r`n$tail`r`n"); $installLogBox.ScrollToEnd() }
                }
                $errFile = "$($script:wingetInstallLogFile).err"
                if (Test-Path $errFile) {
                    $errTail = Get-Content -Path $errFile -Raw -ErrorAction SilentlyContinue
                    if ($errTail) { $installLogBox.AppendText("=== winget install errors ===`r`n$errTail`r`n"); $installLogBox.ScrollToEnd() }
                }
            }
        }
    }

    if ($script:scanPS -and $script:scanHandle.IsCompleted) {
        try {
            $reportLines = $script:scanPS.EndInvoke($script:scanHandle)
            $logBox.Text = ($reportLines -join "`r`n")
        } catch {
            $logBox.Text = "Scan failed: $($_.Exception.Message)"
        } finally {
            foreach ($err in $script:scanPS.Streams.Error) {
                $logBox.AppendText("`r`nScan warning: $($err.ToString())")
            }
            $script:scanPS.Dispose()
            $script:scanPS = $null
            $script:scanHandle = $null
            $stateText.Text = 'Idle'
            $btnScan.IsEnabled = $true
        }
    }

    # --- Tab 3 ---
    if ($script:fixProc) {
        $running = $false
        try {
            $script:fixProc.Refresh()
            $running = -not $script:fixProc.HasExited
        } catch {}

        $logResult = Get-LogTail -Path $script:fixLogFile -Offset $script:fixLogOffset
        if ($logResult.text) {
            $fixesLogBox.AppendText($logResult.text)
            $fixesLogBox.ScrollToEnd()
        }
        $script:fixLogOffset = $logResult.offset

        if ($running) {
            $elapsed = [int]((Get-Date) - $script:fixStartTime).TotalSeconds
            $fixesStatusText.Text = "Running... ({0}:{1:D2} elapsed)" -f [int]($elapsed / 60), ($elapsed % 60)
        } else {
            $summary = Get-LogSummary -LogPath $script:fixLogFile
            $fixesStatusText.Text = if ($summary.completed) { 'Done.' } else { 'Ended before finishing - check the log above.' }
            foreach ($b in $fixButtons) { $b.IsEnabled = $true }
            $btnStopFixes.Visibility = 'Collapsed'
            $script:fixProc = $null
        }
    }

    # --- Provisioning tab ---
    if ($script:provisionProc) {
        $running = $false
        try {
            $script:provisionProc.Refresh()
            $running = -not $script:provisionProc.HasExited
        } catch {}

        $logResult = Get-LogTail -Path $script:provisionLogFile -Offset $script:provisionLogOffset
        if ($logResult.text) {
            $provisioningLogBox.AppendText($logResult.text)
            $provisioningLogBox.ScrollToEnd()
        }
        $script:provisionLogOffset = $logResult.offset

        if ($running) {
            $elapsed = [int]((Get-Date) - $script:provisionStartTime).TotalSeconds
            $provisioningStatusText.Text = "Running... ({0}:{1:D2} elapsed)" -f [int]($elapsed / 60), ($elapsed % 60)
        } else {
            $summary = Get-LogSummary -LogPath $script:provisionLogFile
            $provisioningStatusText.Text = if ($summary.completed) { 'Done.' } else { 'Ended before finishing - check the log above.' }
            foreach ($b in $provisionButtons) { $b.IsEnabled = $true }
            $script:provisionProc = $null
        }
    }

    # A reboot-resume can complete via a SYSTEM scheduled task while the GUI wasn't even
    # open (or was open but didn't spawn that process itself), so this can't rely on
    # $script:provisionProc tracking - just check whether the worker's own state file is
    # still there, cheap enough to do every tick.
    $wuStateFile = Join-Path $workDir 'wu_resume_state.json'
    if (Test-Path $wuStateFile) {
        try {
            $wuState = Get-Content -Path $wuStateFile -Raw -ErrorAction Stop | ConvertFrom-Json
            $textWindowsUpdateResume.Text = "Windows Update: resume pending (was on pass $($wuState.pass) of 4 - will continue automatically after the next reboot)"
        } catch {
            $textWindowsUpdateResume.Text = 'Windows Update: a resume is pending (could not read its details).'
        }
    } elseif ($textWindowsUpdateResume.Text) {
        $textWindowsUpdateResume.Text = ''
    }
})
$timer.Start()

$window.ShowDialog() | Out-Null
