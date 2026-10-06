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
         read-only BitLocker status scan and recovery key fetch, and a guarded Disable
         BitLocker... (it backs up every key Windows can export before decrypting).
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

function Remove-OldWorkDirFiles {
    # Cleanup of old run/fix/scan/winget logs and downloaded installers on every GUI launch - this directory otherwise
    # only ever grows, run after run, laptop after laptop. NEVER touched, whatever their age: the break-glass
    # administrator's credential file (breakglass-admin_*, on a machine that is not Entra-joined it is the ONLY copy
    # of that password) and the "Revert Last Run" snapshots (undo_*), which stop working if they disappear.
    param([string]$Path, [int]$OlderThanDays = 30)
    $limit = (Get-Date).AddDays(-$OlderThanDays)
    Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limit -and $_.Name -notlike 'breakglass-admin_*' -and $_.Name -notlike 'undo_*' } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
Remove-OldWorkDirFiles -Path $workDir

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

function Get-DellReplacementEligibility {
    # Looks up this machine's own Dell service tag via the Dell TechDirect Warranty API
    # and turns its ship date into a repair-vs-replace call:
    #   under 3 years  - repair/support (warranty repair, part replacement, upgrades)
    #   3-4 years      - toss-up, judgment call
    #   over 4 years   - replace only (repair cost is better spent toward a new PC)
    #
    # Needs a Dell TechDirect API Client ID/Secret - register for free at
    # techdirect.dell.com (Services > Get support and replace parts > APIs), approval
    # takes a few business days. This repo is public (irm get.gr3y.io/debloat | iex), so
    # those credentials can never be committed here - they're read from either the
    # GR3Y_DELL_API_CLIENT_ID/GR3Y_DELL_API_CLIENT_SECRET environment variables (e.g. set
    # by an RMM tool's script-variable injection for that one run) or a local
    # C:\ProgramData\Gr3yTools\dell-api.json file ({"clientId":"...","clientSecret":"..."})
    # that never ships with this tool and has to be placed on each machine separately.
    param([Parameter(Mandatory)][string]$ServiceTag)

    $clientId = $env:GR3Y_DELL_API_CLIENT_ID
    $clientSecret = $env:GR3Y_DELL_API_CLIENT_SECRET
    if (-not $clientId -or -not $clientSecret) {
        $credPath = Join-Path $env:ProgramData 'Gr3yTools\dell-api.json'
        if (Test-Path $credPath) {
            try {
                $cred = Get-Content -Path $credPath -Raw | ConvertFrom-Json
                $clientId = $cred.clientId
                $clientSecret = $cred.clientSecret
            } catch {}
        }
    }
    if (-not $clientId -or -not $clientSecret) {
        return [PSCustomObject]@{
            Success = $false
            Message = "Dell API credentials not found. Set GR3Y_DELL_API_CLIENT_ID / GR3Y_DELL_API_CLIENT_SECRET as environment variables, or create $credPath as {`"clientId`":`"...`",`"clientSecret`":`"...`"}. Register for a free API key at https://techdirect.dell.com/ (Services > Get support and replace parts > APIs) - approval takes a few business days."
        }
    }

    try {
        $authHeader = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${clientId}:${clientSecret}"))
        $tokenResponse = Invoke-RestMethod -Uri 'https://apigtwb2c.us.dell.com/auth/oauth/v2/token' -Method Post `
            -Headers @{ Authorization = $authHeader } `
            -Body @{ grant_type = 'client_credentials' } `
            -ContentType 'application/x-www-form-urlencoded'
        $accessToken = $tokenResponse.access_token
        if (-not $accessToken) {
            return [PSCustomObject]@{ Success = $false; Message = 'Dell API authentication did not return an access token - double check the Client ID/Secret.' }
        }

        $warrantyResponse = Invoke-RestMethod -Method Get -Headers @{ Authorization = "Bearer $accessToken"; Accept = 'application/json' } `
            -Uri "https://apigtwb2c.us.dell.com/PROD/sbil/eapi/v5/asset-entitlements?servicetags=$ServiceTag"
    } catch {
        return [PSCustomObject]@{ Success = $false; Message = "Dell API request failed: $($_.Exception.Message)" }
    }

    $asset = $warrantyResponse | Select-Object -First 1
    if (-not $asset -or -not $asset.shipDate) {
        return [PSCustomObject]@{ Success = $false; Message = "Dell API returned no ship date for service tag $ServiceTag - double check the tag, or this machine may not be a Dell-registered asset." }
    }

    $shipDate = [DateTime]$asset.shipDate
    $ageYears = ((Get-Date) - $shipDate).TotalDays / 365.25
    $recommendation =
        if ($ageYears -lt 3) { 'Repair/support - warranty repair, part replacement, upgrades as needed.' }
        elseif ($ageYears -lt 4) { 'Toss-up - judgment call. Weigh repair cost against replacement.' }
        else { 'Replace only - repair cost is better spent toward a new PC.' }

    return [PSCustomObject]@{
        Success        = $true
        ServiceTag     = $ServiceTag
        ShipDate       = $shipDate
        AgeYears       = [Math]::Round($ageYears, 1)
        Model          = $asset.productLineDescription
        Recommendation = $recommendation
    }
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
            <Button Name="BtnCompareBaseline" Content="Compare Against List..." BorderBrush="{StaticResource AccentBrush}"
                    ToolTip="Run this on the NEW machine. Get the old machine's list here by pairing code (needs an access code; run one command on the old machine and its list arrives by itself), or by loading an Export Installed Apps JSON file or a plain-text list. The dialog also has the command-line export commands for an old machine with no GUI, and Manage Access Codes for handing out guest codes. Then checks the box for every catalog app that's on the old list but missing here, in a Compare Results filter - pick which ones you want, then Install Selected. Apps already installed here are listed as such, and anything with no catalog match is listed for manual install."/>
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

                <TextBlock Style="{StaticResource Header}" Text="Hardware Lifecycle" Margin="0,14,0,0"/>
                <TextBlock Style="{StaticResource Hint}" Text="Dell only for now (service tag lookup needs a registered Dell TechDirect API key - see tooltip). Looks up this machine's ship date and applies: under 3 years - repair/support; 3-4 years - judgment call; over 4 years - replace only."
                           TextWrapping="Wrap" Margin="0,0,0,4" Opacity="0.7"/>
                <Button Name="BtnCheckReplacement" Content="Check Replacement Eligibility" HorizontalAlignment="Stretch" Margin="0,0,0,10"
                        ToolTip="Reads this machine's own Dell service tag and looks up its ship date via the Dell TechDirect Warranty API. Requires Dell API credentials set as GR3Y_DELL_API_CLIENT_ID / GR3Y_DELL_API_CLIENT_SECRET environment variables, or a C:\ProgramData\Gr3yTools\dell-api.json file ({&quot;clientId&quot;:&quot;...&quot;,&quot;clientSecret&quot;:&quot;...&quot;}) - register for free at techdirect.dell.com (approval takes a few business days). Non-Dell machines aren't supported yet - there's no equivalent reliable API without the same kind of registered access."/>

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
              <TextBlock Style="{StaticResource Hint}" Text="Scan and Save only READ status and recovery keys. Disable BitLocker... is the one separate, guarded action that decrypts a drive: it shows the status, saves and checks a backup of every key Windows can export, and only then decrypts the drives you tick. Nothing here ever turns BitLocker on (that is on the Provisioning tab)."
                         TextWrapping="Wrap" Margin="0,0,0,8" Opacity="0.7"/>
              <WrapPanel Margin="0,0,0,8">
                <Button Name="BtnBitLockerScan" Content="Scan BitLocker Status" Width="220" Margin="0,0,10,0"/>
                <Button Name="BtnBitLockerSave" Content="Save Recovery Keys to File..." Width="220" Margin="0,0,10,0" IsEnabled="False"/>
                <Button Name="BtnBitLockerDisable" Content="Disable BitLocker..." Width="220" Margin="0,0,10,0" BorderBrush="#D29922"/>
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
              <TextBlock Style="{StaticResource Hint}" Text="Opt-in only - these buttons never disable or decrypt BitLocker (turning it off is a separate, guarded action on the Panels tab: Disable BitLocker..., which backs up every key Windows can export first). Enable BitLocker turns on XtsAes256 used-space-only encryption with a TPM protector plus a recovery password protector, only if a ready TPM is present and protection is currently Off; on an Entra-joined device the recovery password is also backed up to Entra ID automatically, otherwise it goes into the handoff package only. Prevent Automatic Device Encryption is the opposite case - for a machine staying on local accounts, it stops Windows silently turning encryption on by itself at first Microsoft-account sign-in (24H2), which could otherwise leave the only recovery key in a personal account. Use one or the other, not usually both. Run after OEM Driver/BIOS Updates and after Entra join."
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
$btnCheckReplacement = $window.FindName('BtnCheckReplacement')
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
    # Read-only - never enables, disables, or changes encryption state on any volume (the one
    # place this app decrypts a drive is Show-BitLockerDisableDialog, below).
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
# Disable BitLocker (guarded) - Panels tab. The Scan and Save buttons above only READ
# status and keys. This is the one place the app decrypts a drive, and only when asked:
# status first, then a backup of EVERY key that is written and checked, then the decrypt.
# Recovery passwords live in memory and in the backup file the owner chooses - never in
# the action log and never in a message box. Pure helpers come first (unit-tested), the
# dialog last. All BitLocker work goes through the BitLocker module's own cmdlets so a
# test can stand in for them with functions of the same name.
# ============================================================================

function Get-BitLockerPropertyText {
    # A property's value as a string, or '' when the object has no such property or it is null.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return '' }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    return [string]$p.Value
}

function ConvertTo-BitLockerVolumeDetail {
    # One Get-BitLockerVolume object -> a plain object with everything the Disable dialog and the
    # key backup need. Missing or null properties (older modules, odd volumes) become ''.
    param($Volume)
    $protectors = New-Object System.Collections.Generic.List[object]
    foreach ($kp in @($Volume.KeyProtector)) {
        if ($null -eq $kp) { continue }
        $protectors.Add([PSCustomObject]@{
            Type             = Get-BitLockerPropertyText $kp 'KeyProtectorType'
            Id               = Get-BitLockerPropertyText $kp 'KeyProtectorId'
            RecoveryPassword = Get-BitLockerPropertyText $kp 'RecoveryPassword'
            KeyFileName      = Get-BitLockerPropertyText $kp 'KeyFileName'
            AutoUnlock       = ((Get-BitLockerPropertyText $kp 'AutoUnlockProtector') -eq 'True')
        })
    }
    $percent = 0
    [void][int]::TryParse((Get-BitLockerPropertyText $Volume 'EncryptionPercentage'), [ref]$percent)
    # AutoUnlockEnabled: a data drive that unlocks itself with a key kept on the Windows drive.
    # AutoUnlockKeyStored: the Windows drive holds such keys (Windows will not decrypt it while it does).
    return [PSCustomObject]@{
        MountPoint           = Get-BitLockerPropertyText $Volume 'MountPoint'
        VolumeType           = Get-BitLockerPropertyText $Volume 'VolumeType'
        ProtectionStatus     = Get-BitLockerPropertyText $Volume 'ProtectionStatus'
        VolumeStatus         = Get-BitLockerPropertyText $Volume 'VolumeStatus'
        LockStatus           = Get-BitLockerPropertyText $Volume 'LockStatus'
        EncryptionMethod     = Get-BitLockerPropertyText $Volume 'EncryptionMethod'
        EncryptionPercentage = $percent
        CapacityGB           = Get-BitLockerPropertyText $Volume 'CapacityGB'
        AutoUnlockEnabled    = Get-BitLockerPropertyText $Volume 'AutoUnlockEnabled'
        AutoUnlockKeyStored  = ((Get-BitLockerPropertyText $Volume 'AutoUnlockKeyStored') -eq 'True')
        Protectors           = $protectors.ToArray()
        VolumeId             = ''      # the volume's own ID; filled in by the callers that read every volume (Get-BitLockerVolumeIdMap)
    }
}

function Get-BitLockerVolumeIdMap {
    # Drive letter ('C:') -> the volume's own ID (\\?\Volume{GUID}\), from ONE Get-Volume query. That ID stays the same
    # while a drive encrypts or decrypts and differs between two sticks of the same make and size, which key IDs
    # (gone once a drive is decrypted) and size cannot tell apart. Empty when it cannot be read: the drive's identity
    # then falls back on key IDs, size and type. Never throws.
    $map = @{}
    try {
        foreach ($vol in @(Get-Volume -ErrorAction SilentlyContinue)) {
            $letter = [string]$vol.DriveLetter
            $id = [string]$vol.UniqueId
            if ($letter -cmatch '^[A-Za-z]$' -and $id) { $map[($letter.ToUpperInvariant() + ':')] = $id }
        }
    } catch { }
    return $map
}

function Get-BitLockerVolumeDetail {
    # Read-only. { Error; Volumes; Unreadable } - Volumes is always an array. One volume that BitLocker cannot
    # read does not hide the others: it is reported in Unreadable (error texts); Error is set only when nothing
    # could be read at all. Recovery passwords are in the result (in memory only); callers must never pass them
    # to a log.
    $problems = @()
    try {
        $volumes = @(Get-BitLockerVolume -ErrorAction SilentlyContinue -ErrorVariable problems)
    } catch {
        return [PSCustomObject]@{ Error = $_.Exception.Message; Volumes = @(); Unreadable = @() }
    }
    $unreadable = @(@($problems) | ForEach-Object { [string]$_.Exception.Message } | Where-Object { $_ } | Select-Object -Unique)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($v in $volumes) {
        if ($null -ne $v) { $list.Add((ConvertTo-BitLockerVolumeDetail -Volume $v)) }
    }
    if ($list.Count -eq 0 -and $unreadable.Count -gt 0) { return [PSCustomObject]@{ Error = $unreadable[0]; Volumes = @(); Unreadable = @() } }
    # every volume also gets its own ID (one query for all of them), so a drive can be told from another of the same size
    if ($list.Count -gt 0) {
        $ids = Get-BitLockerVolumeIdMap
        foreach ($d in $list) { if ($ids.ContainsKey([string]$d.MountPoint)) { $d.VolumeId = [string]$ids[[string]$d.MountPoint] } }
    }
    return [PSCustomObject]@{ Error = $null; Volumes = $list.ToArray(); Unreadable = $unreadable }
}

function Get-BitLockerStateText {
    # The state of a volume in plain words, for the dialog's list. These are the VolumeStatus values
    # the BitLocker module really has. "Paused" means the encrypting or decrypting was stopped part
    # way; "protection suspended" is a different thing (the drive is encrypted but its key is exposed).
    # A locked drive reports no status or percentage at all.
    param($Volume)
    if ($Volume.LockStatus -eq 'Locked') { return 'Locked - unlock it to see more' }
    $pct = $Volume.EncryptionPercentage
    switch ([string]$Volume.VolumeStatus) {
        'FullyDecrypted' { return 'Not encrypted' }
        'FullyEncrypted' {
            if ($Volume.ProtectionStatus -eq 'Off') { return 'Encrypted, protection suspended' }
            return 'Encrypted'
        }
        'EncryptionInProgress' { return "Encrypting ($pct% done)" }
        'DecryptionInProgress' { return "Decrypting ($pct% still encrypted)" }
        'EncryptionSuspended' { return "Encryption paused at $pct%" }
        'DecryptionSuspended' { return "Decryption paused ($pct% still encrypted)" }
        'FullyEncryptedWipeInProgress' { return 'Encrypted, wiping free space' }
        'FullyEncryptedWipeSuspended' { return 'Encrypted, free-space wipe paused' }
    }
    if ($Volume.VolumeStatus) { return [string]$Volume.VolumeStatus }
    return 'Unknown'
}

function Get-BitLockerDisableState {
    # Can this volume be decrypted right now? { CanDisable; Reason; Note }. Reason says why not; Note
    # is something worth knowing about a drive that can be. A locked drive cannot be decrypted until
    # it is unlocked; one that is not encrypted or is already decrypting needs nothing; a drive that
    # encrypts itself in hardware is not BitLocker's to decrypt; a decryption that was paused is
    # resumed with manage-bde, not started again.
    param($Volume)
    $s = [string]$Volume.VolumeStatus
    $mount = [string]$Volume.MountPoint
    $reason = ''
    if ($mount -cnotmatch '^[A-Za-z]:\z') { $reason = 'No drive letter - decrypt it from Windows' }
    elseif ($Volume.LockStatus -eq 'Locked') { $reason = 'Locked - unlock it first' }
    elseif ([string]$Volume.EncryptionMethod -eq 'Hardware') { $reason = 'Encrypted in hardware by the drive itself - not decrypted here' }
    elseif ($s -eq 'FullyDecrypted') { $reason = 'Not encrypted - nothing to do' }
    elseif ($s -eq 'DecryptionInProgress') { $reason = 'Already decrypting' }
    elseif ($s -eq 'DecryptionSuspended') { $reason = "Decryption is paused - resume it with: manage-bde -resume $mount" }
    elseif ($s -like 'FullyEncryptedWipe*') { $reason = 'Wiping free space - wait for it to finish' }
    elseif (-not $s -or $s -eq 'Unknown') { $reason = 'Status unknown' }
    elseif (@('FullyEncrypted', 'EncryptionInProgress', 'EncryptionSuspended') -notcontains $s) { $reason = "Status '$s' is not recognised - decrypt it from Windows" }
    if ($reason) { return [PSCustomObject]@{ CanDisable = $false; Reason = $reason; Note = '' } }
    $note = ''
    if ([string]$Volume.VolumeType -eq 'OperatingSystem' -and $Volume.AutoUnlockKeyStored) { $note = 'Holds auto-unlock keys for other drives - they are cleared first' }
    elseif ($s -eq 'EncryptionInProgress' -or $s -eq 'EncryptionSuspended') { $note = 'Not fully encrypted yet - decrypting reverses it' }
    return [PSCustomObject]@{ CanDisable = $true; Reason = ''; Note = $note }
}

function Get-BitLockerProtectorSummary {
    # "TPM, Recovery password" for a volume's key protectors; 'none' when it has none.
    param($Volume)
    $names = @{
        Tpm = 'TPM'; TpmPin = 'TPM + PIN'; TpmStartupKey = 'TPM + startup key'; TpmPinStartupKey = 'TPM + PIN + startup key'
        TpmNetworkKey = 'TPM + network key'; Password = 'Password'; RecoveryPassword = 'Recovery password'
        ExternalKey = 'Startup key file (.BEK)'; Certificate = 'Certificate'; AdAccountOrGroup = 'AD account or group'; PublicKey = 'Public key'
    }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($Volume.Protectors)) {
        if ($null -eq $p) { continue }
        $label = $(if ($names.ContainsKey([string]$p.Type)) { $names[[string]$p.Type] } elseif ($p.Type) { [string]$p.Type } else { 'Unknown' })
        if ($p.AutoUnlock -and [string]$p.Type -eq 'ExternalKey') { $label = 'Auto-unlock key' }
        if (-not $parts.Contains($label)) { $parts.Add($label) }
    }
    if ($parts.Count -eq 0) { return 'none' }
    return ($parts -join ', ')
}

function Get-BitLockerKeyIds {
    # Every key protector ID that exists on the given volumes.
    param($Volumes)
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($Volumes)) {
        foreach ($p in @($v.Protectors)) {
            if ($null -ne $p -and $p.Id) { $ids.Add([string]$p.Id) }
        }
    }
    return $ids.ToArray()   # callers wrap the call in @() - no leading comma, or @() would nest it
}

function Test-BitLockerKeysCovered {
    # A backup stays good only while it covers every key that exists now: true when each current
    # protector ID was in the backed-up set (a protector that disappeared does no harm).
    param($Volumes, $BackedUpIds)
    $backed = @($BackedUpIds | ForEach-Object { [string]$_ })
    foreach ($id in @(Get-BitLockerKeyIds -Volumes $Volumes)) {
        if ($backed -notcontains $id) { return $false }
    }
    return $true
}

function Get-BitLockerMountsWithoutRecoveryPassword {
    # Among the named mount points, the encrypted ones that have no readable recovery password.
    param($Volumes, [string[]]$Mounts)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($Volumes)) {
        if ($Mounts -notcontains $v.MountPoint) { continue }
        $has = @(@($v.Protectors) | Where-Object { $_.Type -eq 'RecoveryPassword' -and $_.RecoveryPassword }).Count -gt 0
        if (-not $has) { $out.Add([string]$v.MountPoint) }
    }
    return $out.ToArray()   # callers wrap the call in @()
}

function New-BitLockerBackupText {
    # The key backup as text (CRLF lines). It holds decryption secrets in plain text, on purpose:
    # that is what an emergency needs. $Info: ComputerName, UserName, Date, Os, Machine, Tpm.
    # $RawStatus / $RawProtectors: the text of manage-bde -status and manage-bde -protectors -get <drive>.
    # $Unreadable: texts of volumes BitLocker could not read when this was made - their keys are NOT in it.
    param($Volumes, $Info, [string]$RawStatus, $RawProtectors, $Unreadable)
    $t = New-Object System.Collections.Generic.List[string]
    $t.Add('BITLOCKER KEY BACKUP')
    $t.Add("Computer : $($Info.ComputerName)    User: $($Info.UserName)    Made: $($Info.Date)")
    if ($Info.Os) { $t.Add("Windows  : $($Info.Os)") }
    if ($Info.Machine) { $t.Add("Machine  : $($Info.Machine)") }
    if ($Info.Tpm) { $t.Add("TPM      : $($Info.Tpm)") }
    $t.Add('')
    $t.Add('Made by Gr3yLabs Support BEFORE BitLocker was disabled. THIS FILE HOLDS DECRYPTION SECRETS IN PLAIN TEXT:')
    $t.Add('keep it OFF the encrypted drives listed below and off any drive that is being decrypted, store it somewhere safe, and delete it when you no longer need it.')
    $t.Add('When BitLocker is turned on again Windows makes NEW keys - this backup does not unlock a drive encrypted later.')
    $t.Add('It holds every key Windows can export (recovery passwords and key IDs). A PIN, a password you typed and a startup-key (.BEK) file cannot be read back from Windows, so they are not in it.')
    $t.Add('')
    $t.Add("SUMMARY ($(@($Volumes).Count) volume(s))")
    foreach ($v in @($Volumes)) {
        $t.Add(("  {0,-4} {1,-16} {2,-22} protection {3,-4} protectors: {4}" -f $v.MountPoint, $v.VolumeType, $v.VolumeStatus, $v.ProtectionStatus, (Get-BitLockerProtectorSummary -Volume $v)))
    }
    $unreadableTexts = @(@($Unreadable) | Where-Object { $_ })
    if ($unreadableTexts.Count -gt 0) {
        $t.Add('NOT IN THIS BACKUP: BitLocker could not read some volumes when it was made, so their keys are missing: ' + ($unreadableTexts -join '; '))
    }
    foreach ($v in @($Volumes)) {
        $t.Add('')
        $t.Add("----- Drive $($v.MountPoint) -----")
        $t.Add("Type: $($v.VolumeType)   Status: $($v.VolumeStatus)   Protection: $($v.ProtectionStatus)   Lock: $($v.LockStatus)   Encrypted: $($v.EncryptionPercentage)%")
        $t.Add("Method: $($v.EncryptionMethod)   Capacity (GB): $($v.CapacityGB)   Auto-unlock: $($v.AutoUnlockEnabled)   Holds auto-unlock keys for other drives: $($v.AutoUnlockKeyStored)")
        $protectors = @($v.Protectors)
        $t.Add("Key protectors ($($protectors.Count)):")
        if ($protectors.Count -eq 0) { $t.Add('  (none)') }
        $n = 0
        foreach ($p in $protectors) {
            $n++
            $t.Add("  [$n] $($p.Type)    ID $($p.Id)")
            if ($p.Type -eq 'RecoveryPassword') {
                if ($p.RecoveryPassword) {
                    $t.Add("      Recovery password: $($p.RecoveryPassword)")
                    $idText = [string]$p.Id
                    $short = $idText.Trim('{', '}')
                    if ($short.Length -gt 8) { $short = $short.Substring(0, 8) }
                    $where = $(if ([string]$v.VolumeType -eq 'OperatingSystem') { 'Use it at the blue recovery screen when the PC starts: choose to enter the recovery key and type the 48 digits (if the number keys do nothing there, use the function keys F1-F10 as the screen shows).' } else { 'Use it when Windows asks to unlock this drive: choose More options, then Enter recovery key, and type the 48 digits.' })
                    $t.Add("      $where Windows shows a Key ID; it should match the start of the ID above ($short).")
                } else {
                    $t.Add('      (this protector exists but Windows did not return its password)')
                }
            } elseif ($p.Type -eq 'Password') {
                $t.Add('      The password itself cannot be read back from Windows - keep your own record of it.')
            } elseif ($p.Type -eq 'ExternalKey' -and $p.AutoUnlock) {
                $t.Add('      Auto-unlock key: lets Windows unlock this drive by itself on this PC. The key is kept on the Windows drive - there is no secret here to back up.')
            } elseif ($p.Type -eq 'ExternalKey' -or $p.Type -eq 'TpmStartupKey' -or $p.Type -eq 'TpmPinStartupKey') {
                $fileText = $(if ($p.KeyFileName) { $p.KeyFileName } else { '(name not reported)' })
                $t.Add("      Startup key file: $fileText - the .BEK file lives on the USB stick it was saved to; this tool cannot copy it.")
            } elseif ($p.Type -eq 'TpmPin') {
                $t.Add('      The PIN cannot be read back from Windows - keep your own record of it.')
            } elseif ($p.Type -eq 'Tpm') {
                $t.Add('      Sealed in this PC''s TPM - there is no secret to back up.')
            }
        }
        if ($RawProtectors -and $RawProtectors.ContainsKey([string]$v.MountPoint)) {
            $t.Add('')
            $t.Add("Raw output of: manage-bde -protectors -get $($v.MountPoint)")
            $t.Add([string]$RawProtectors[[string]$v.MountPoint])
        }
    }
    $t.Add('')
    $t.Add('----- Raw output of: manage-bde -status -----')
    $t.Add($(if ($RawStatus) { $RawStatus } else { '(not available)' }))
    $t.Add('')
    $t.Add('END OF BACKUP')
    return (($t -join "`r`n") + "`r`n")
}

function Test-BitLockerRecoveryPasswordFormat {
    # A BitLocker recovery password is 8 groups of 6 digits, each group a multiple of 11 and at most
    # 720885 (65535 x 11). True only for exactly that: a quick check that what the backup holds is
    # a real recovery password and not a placeholder or a damaged copy.
    param([string]$Candidate)
    if ($Candidate -cnotmatch '^[0-9]{6}(-[0-9]{6}){7}\z') { return $false }
    foreach ($group in $Candidate.Split('-')) {
        $n = [int]$group
        if (($n % 11) -ne 0 -or $n -gt 720885) { return $false }
    }
    return $true
}

function Test-BitLockerBackupText {
    # Is everything in the volumes' key list really in the text that was read back from the file?
    # Checks each drive, each key protector ID and each recovery password (which must also be a
    # well-formed 48-digit recovery password). { Ok; Missing }.
    param([string]$Text, $Volumes)
    $missing = New-Object System.Collections.Generic.List[string]
    if (-not $Text -or $Text.Length -lt 50) {
        $missing.Add('the file is empty or too short')
        return [PSCustomObject]@{ Ok = $false; Missing = $missing.ToArray() }
    }
    foreach ($v in @($Volumes)) {
        if ($Text.IndexOf("Drive $($v.MountPoint)", [System.StringComparison]::Ordinal) -lt 0) { $missing.Add("drive $($v.MountPoint)") }
        foreach ($p in @($v.Protectors)) {
            if ($p.Id -and $Text.IndexOf([string]$p.Id, [System.StringComparison]::Ordinal) -lt 0) { $missing.Add("key ID $($p.Id) of $($v.MountPoint)") }
            if ($p.RecoveryPassword) {
                if (-not (Test-BitLockerRecoveryPasswordFormat -Candidate ([string]$p.RecoveryPassword))) { $missing.Add("a recovery password of $($v.MountPoint) that is not a well-formed 48-digit recovery password") }
                elseif ($Text.IndexOf([string]$p.RecoveryPassword, [System.StringComparison]::Ordinal) -lt 0) { $missing.Add("a recovery password of $($v.MountPoint)") }
            }
        }
    }
    if ($Text.IndexOf('END OF BACKUP', [System.StringComparison]::Ordinal) -lt 0) { $missing.Add('the end marker (the file was cut short)') }
    return [PSCustomObject]@{ Ok = ($missing.Count -eq 0); Missing = $missing.ToArray() }
}

function Get-BitLockerBackupPlaceNote {
    # Where the backup file sits, in words: on a drive that is about to be decrypted, on another encrypted
    # drive (the keys would be locked inside it), and/or inside OneDrive (a copy of the keys goes to the
    # cloud). '' when it is somewhere unremarkable. $Volumes: the volume details; $Mounts: the ticked drives.
    param([string]$Path, $Volumes, [string[]]$Mounts, [string[]]$CloudRoots)
    if (-not $Path -or $Path.Length -lt 3) { return '' }
    # judged on the path as Windows will resolve it: no ".." or "." segments, one kind of slash
    try { $resolved = [System.IO.Path]::GetFullPath($Path); if ($resolved -and $resolved.Length -ge 3) { $Path = $resolved } } catch { }
    # a path through this PC's own administrative share (\\localhost\C$\... or \\<this PC>\C$\...) is the same place as C:\...
    # (this PC's other network names and addresses are not looked up: that would need the network)
    $self = @('localhost', '127.0.0.1')
    if ($env:COMPUTERNAME) { $self += [string]$env:COMPUTERNAME }
    if ($env:COMPUTERNAME -and $env:USERDNSDOMAIN) { $self += ('{0}.{1}' -f $env:COMPUTERNAME, $env:USERDNSDOMAIN) }
    $admin = [regex]::Match($Path, '^\\\\([^\\]+)\\([A-Za-z])\$(\\.*)?$')
    if ($admin.Success -and ($self -contains $admin.Groups[1].Value)) { $Path = $admin.Groups[2].Value + ':' + $(if ($admin.Groups[3].Success) { $admin.Groups[3].Value } else { '\' }) }
    $notes = New-Object System.Collections.Generic.List[string]
    $drive = $Path.Substring(0, 2)
    if ($Path.Substring(2, 1) -eq '\') {
        if (@($Mounts) -contains $drive) {
            $notes.Add("The backup file is on $($drive.ToUpperInvariant()), a drive about to be decrypted. Prefer a USB stick or another drive.")
        } elseif (@(@($Volumes) | Where-Object { $_ -and [string]$_.MountPoint -eq $drive -and [string]$_.VolumeStatus -ne 'FullyDecrypted' }).Count -gt 0) {
            $notes.Add("The backup file is on $($drive.ToUpperInvariant()), which is encrypted: if that drive ever needed its recovery key, the key would be locked inside it. Prefer a USB stick or another drive.")
        }
    }
    $cloud = @(@($CloudRoots) | Where-Object { $_ -and $Path.StartsWith(($_.TrimEnd('\') + '\'), [System.StringComparison]::OrdinalIgnoreCase) })
    if ($cloud.Count -gt 0) { $notes.Add('The file is inside OneDrive, so a copy of these keys also goes to your cloud storage and stays there until you delete it.') }
    return ($notes -join ' ')
}

function Get-BitLockerDefaultBackupFolder {
    # A sensible folder to offer for the key backup: the root of a ready, unencrypted removable drive first,
    # then of another ready, unencrypted fixed drive that is not the Windows drive; otherwise $Fallback.
    # $Drives: objects with Name ("E:\"), DriveType and IsReady (System.IO.DriveInfo fits); $Volumes: details.
    param($Drives, $Volumes, [string]$WindowsDrive, [string]$Fallback)
    foreach ($kind in 'Removable', 'Fixed') {
        foreach ($d in @($Drives)) {
            if (-not $d -or [string]$d.DriveType -ne $kind -or -not $d.IsReady) { continue }
            $letter = ([string]$d.Name).TrimEnd('\')
            if ($letter -cnotmatch '^[A-Za-z]:\z') { continue }
            if ($letter -eq $WindowsDrive) { continue }
            $vol = @(@($Volumes) | Where-Object { $_ -and [string]$_.MountPoint -eq $letter }) | Select-Object -First 1
            if ($vol -and ([string]$vol.VolumeStatus -ne 'FullyDecrypted' -or $vol.LockStatus -eq 'Locked')) { continue }
            return "$letter\"
        }
    }
    return $Fallback
}

function Test-BitLockerBackupPath {
    # Is this a place the backup can be written? Checked BEFORE anything is changed: a full path, a usable file
    # name, an existing folder you can create that very file in, and no file of that name yet. Never throws.
    # { Ok; Error }. -RemoveFile: how the empty test file is taken away again (a test hands over its own).
    param([string]$Path, [scriptblock]$RemoveFile = { param($p) [System.IO.File]::Delete($p) })
    $r = [PSCustomObject]@{ Ok = $false; Error = $null }
    try {
        # a full path: a drive letter and a backslash, or a network path (a drive-relative "C:name.txt" is rooted but not full)
        if (-not $Path -or $Path -cnotmatch '^([A-Za-z]:\\|\\\\)') { $r.Error = 'Give a full path, such as D:\Backups\bitlocker.txt'; return $r }
        if ($Path -match '^\\\\[?.]\\') { $r.Error = 'Give a normal path, such as D:\Backups\bitlocker.txt (paths that start with \\?\ or \\.\ are not supported).'; return $r }
        if ($Path.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) { $r.Error = 'That is not a usable file name: it contains a character Windows does not allow (a double quote, < > | or a control character).'; return $r }
        $leaf = [System.IO.Path]::GetFileName($Path)
        if (-not $leaf) { $r.Error = 'That path ends in a folder - add a file name, such as D:\Backups\bitlocker.txt'; return $r }
        # a name Windows cannot create (* ? : and the like, a reserved device name such as NUL.txt, a trailing dot or space)
        # is refused here, before the person is asked to change anything on a drive
        $afterRoot = $(if ($Path -match '^[A-Za-z]:') { $Path.Substring(2) } else { $Path })
        if ($leaf.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $afterRoot.IndexOf(':') -ge 0 -or $leaf -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$' -or $leaf -match '[. ]$') {
            # the name as typed (GetFileName would cut "a:b.txt" at the colon and name only "b.txt")
            $r.Error = "That is not a usable file name: $($Path.Substring($Path.LastIndexOf('\') + 1))"
            return $r
        }
        $dir = [System.IO.Path]::GetDirectoryName($Path)
        if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { $r.Error = "The folder does not exist: $dir"; return $r }
        if (Test-Path -LiteralPath $Path -PathType Container) { $r.Error = 'That is a folder - add a file name, such as D:\Backups\bitlocker.txt'; return $r }
        if (Test-Path -LiteralPath $Path) { $r.Error = 'That file already exists - choose a new name so an earlier backup is not overwritten.'; return $r }
        # prove the folder is writable and the name can really be created: make the real file and take it away again
        # (it holds nothing; the same name is made again, for real, by Save-BitLockerBackupFile). Only a file THIS call
        # created is ever deleted - never one that was already there (a race, a share's stale directory answer) - and it
        # is deleted with .NET, whose path rules are the ones that created it.
        $made = $null
        try {
            $made = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        } catch {
            # nothing was made by this call, so nothing is deleted
            $why = $_.Exception.Message
            if ($_.Exception.InnerException) { $why = $_.Exception.InnerException.Message }
            $r.Error = "You cannot save a file with that name there: $why"
            return $r
        }
        try { $made.Close() } catch { }
        # a virus scanner or a sync client can hold a new file for a moment, so removing it is tried a few times; if it
        # still stays, the person is told exactly which empty file is left (the name is then refused until it is gone)
        $removed = $false
        for ($attempt = 1; $attempt -le 5 -and -not $removed; $attempt++) {
            try { & $RemoveFile $Path; $removed = $true } catch { Start-Sleep -Milliseconds 200 }
        }
        if (-not $removed) { $r.Error = "A test file could not be removed again: $Path is now an empty file that something is holding. Delete it yourself, or choose another file name."; return $r }
        $r.Ok = $true
        return $r
    } catch {
        $why = $_.Exception.Message
        if ($_.Exception.InnerException) { $why = $_.Exception.InnerException.Message }
        $r.Error = "That is not a place the backup can be saved: $why"
        return $r
    }
}

function Test-BitLockerBackupStillGood {
    # The backup that was checked must still be there, unchanged, and must still cover every key that exists
    # now. Called before the confirmation AND again right before each drive is decrypted (a stick can be pulled,
    # a key added or a drive swapped while a message box is open). { Ok; Stale; Reason; Volumes }: Stale is true
    # when the backup itself no longer counts (file gone or changed, new keys), false when BitLocker merely
    # could not be read this time; Volumes is the fresh read.
    param([string]$Path, [string]$Hash, $BackedUpIds)
    $r = [PSCustomObject]@{ Ok = $false; Stale = $false; Reason = $null; Volumes = @() }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { $r.Stale = $true; $r.Reason = "The backup file is gone ($Path) - was the USB stick removed? Press button 1 again."; return $r }
    $now = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
    if (-not $now -or $now -ne $Hash) { $r.Stale = $true; $r.Reason = 'The backup file has changed since it was checked. Press button 1 again.'; return $r }
    $fresh = Get-BitLockerVolumeDetail
    if ($fresh.Error) { $r.Reason = "Could not read BitLocker status: $($fresh.Error)"; return $r }
    $r.Volumes = @($fresh.Volumes)
    if (-not (Test-BitLockerKeysCovered -Volumes $fresh.Volumes -BackedUpIds $BackedUpIds)) { $r.Stale = $true; $r.Reason = 'The keys on this PC have changed since the backup was made. Press button 1 to back them up again.'; return $r }
    $r.Ok = $true
    return $r
}

function Get-BitLockerDriveIdentity {
    # What makes a drive THAT drive across reads, whatever letter it has now (a letter can be given to another drive,
    # for example when a stick is swapped while a message box is open): its key protector IDs (every drive has its own),
    # its size, its type and - when Windows tells it - its volume ID (which, unlike the key IDs, survives decryption and
    # tells two sticks of the same size apart). { KeyIds; Capacity; VolumeType; VolumeId }. No I/O: it only reads $Volume.
    param($Volume)
    return [PSCustomObject]@{
        KeyIds     = @(@($Volume.Protectors) | Where-Object { $_ -and $_.Id } | ForEach-Object { [string]$_.Id } | Sort-Object)
        Capacity   = [string]$Volume.CapacityGB
        VolumeType = [string]$Volume.VolumeType
        VolumeId   = [string]$Volume.VolumeId
    }
}

function Test-BitLockerSameDrive {
    # Is this volume still the drive the identity was taken from? Size and type must match, the volume ID must match
    # when both sides know it (an unknown one proves nothing either way), and the key IDs must be exactly the same -
    # or, with -AllowAddedKeys (a recovery password was added to it on purpose), every old ID must still be there.
    # False when either side is missing.
    param($Identity, $Volume, [switch]$AllowAddedKeys)
    if (-not $Identity -or -not $Volume) { return $false }
    $now = Get-BitLockerDriveIdentity -Volume $Volume
    if ($now.Capacity -cne [string]$Identity.Capacity -or $now.VolumeType -cne [string]$Identity.VolumeType) { return $false }
    if ($now.VolumeId -and [string]$Identity.VolumeId -and $now.VolumeId -cne [string]$Identity.VolumeId) { return $false }
    $old = @($Identity.KeyIds)
    if ($AllowAddedKeys) {
        foreach ($id in $old) { if (@($now.KeyIds) -cnotcontains $id) { return $false } }
        return $true
    }
    return ((($old | Sort-Object) -join ',') -ceq ((@($now.KeyIds) | Sort-Object) -join ','))
}

function Get-RunningToolJobs {
    # The long jobs this window started that are still going (a decrypt should wait for them).
    $running = New-Object System.Collections.Generic.List[string]
    foreach ($j in @(@('Debloat / Office', $script:deployProc), @('Fixes', $script:fixProc), @('app install', $script:installProc), @('Provisioning', $script:provisionProc), @('winget install', $script:wingetInstallProc))) {
        try { if ($j[1] -and -not $j[1].HasExited) { $running.Add([string]$j[0]) } } catch { }
    }
    return $running.ToArray()   # callers wrap the call in @()
}

function Get-BitLockerPathFileSystem {
    # The file system of the drive a path is on ('NTFS', 'exFAT', ...), or '' when it cannot be told: a network
    # path, a drive letter MAPPED to a share (it reports the server's file system, but a share may not honour
    # permissions the way a local NTFS drive does), a drive that is gone. Never throws.
    param([string]$Path)
    try {
        $di = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($Path))
        if ([string]$di.DriveType -eq 'Network') { return '' }
        return [string]$di.DriveFormat
    } catch { return '' }
}

function Save-BitLockerBackupFile {
    # Writes the backup (UTF-8, no BOM) and returns { Ok; Error; AclWarning; Hash; Text }. The file is created
    # EMPTY with CreateNew (which fails if the name is taken, so an earlier backup can never be clobbered, even in
    # a race) and that handle is KEPT, nobody else allowed to open, rename or delete the file, until the keys are
    # written: it cannot be swapped for another file in between. Its permissions are restricted to you,
    # administrators and SYSTEM (not inherited from the folder) before any key goes in; when that cannot be done
    # on an NTFS or ReFS drive the file is deleted and the save fails, on a FAT/exFAT stick or a share (which may
    # not hold permissions) it is only a warning. It is read back afterwards.
    param([string]$Path, [string]$Text)
    $result = [PSCustomObject]@{ Ok = $false; Error = $null; AclWarning = $null; Hash = $null; Text = $null }
    $check = Test-BitLockerBackupPath -Path $Path
    if (-not $check.Ok) { $result.Error = $check.Error; return $result }
    $stream = $null
    try {
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        } catch {
            $result.Error = $(if (Test-Path -LiteralPath $Path) { 'That file already exists - choose a new name so an earlier backup is not overwritten.' } else { "Could not create the file: $($_.Exception.Message)" })
            return $result
        }
        $aclProblem = $null
        try {
            $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $icaclsOut = & icacls.exe $Path '/inheritance:r' '/grant:r' "*${userSid}:F" '*S-1-5-32-544:F' '*S-1-5-18:F' 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { $aclProblem = "Could not restrict who can read the file: $($icaclsOut.Trim())" }
        } catch {
            $aclProblem = "Could not restrict who can read the file: $($_.Exception.Message)"
        }
        if ($aclProblem) {
            if (@('NTFS', 'ReFS') -contains (Get-BitLockerPathFileSystem -Path $Path)) {
                $stream.Close(); $stream = $null
                try { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue } catch { }
                $result.Error = "$aclProblem The file was deleted rather than left readable by other people - choose another place."
                return $result
            }
            $result.AclWarning = "$aclProblem (a USB stick or network share may not support it)"
        }
        try {
            $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
            $stream.Close(); $stream = $null
        } catch {
            if ($stream) { try { $stream.Close() } catch { }; $stream = $null }
            $result.Error = "Could not write the file: $($_.Exception.Message)"
            try { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue } catch { }
            return $result
        }
    } finally {
        if ($stream) { try { $stream.Close() } catch { } }
    }
    try {
        $result.Text = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
        $result.Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
        $result.Ok = $true
    } catch {
        $result.Error = "The file was written but could not be read back: $($_.Exception.Message)"
    }
    return $result
}

function Get-BitLockerRawOutput {
    # The text of manage-bde -status and of manage-bde -protectors -get <drive> for each drive, kept
    # in the backup as a second opinion. Never throws; a failure is recorded as text.
    param($Volumes)
    $raw = [PSCustomObject]@{ Status = ''; Protectors = @{} }
    try { $raw.Status = (& manage-bde -status 2>&1 | Out-String).TrimEnd() } catch { $raw.Status = "(manage-bde -status failed: $($_.Exception.Message))" }
    foreach ($v in @($Volumes)) {
        $mount = [string]$v.MountPoint
        if ($mount -cnotmatch '^[A-Za-z]:\z') { continue }
        try { $raw.Protectors[$mount] = (& manage-bde -protectors -get $mount 2>&1 | Out-String).TrimEnd() } catch { $raw.Protectors[$mount] = "(manage-bde failed: $($_.Exception.Message))" }
    }
    return $raw
}

function Get-BitLockerBackupSystemInfo {
    # Who/what/when for the top of the backup, so it can be matched to a machine years later.
    $info = [PSCustomObject]@{ ComputerName = $env:COMPUTERNAME; UserName = "$env:USERDOMAIN\$env:USERNAME"; Date = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Os = ''; Machine = ''; Tpm = '' }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $info.Os = "$($os.Caption) (version $($os.Version))"
    } catch { $info.Os = '' }
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        $info.Machine = "$($cs.Manufacturer) $($cs.Model), serial $($bios.SerialNumber), BIOS $($bios.SMBIOSBIOSVersion)"
    } catch { $info.Machine = '' }
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $info.Tpm = "present=$($tpm.TpmPresent) ready=$($tpm.TpmReady) enabled=$($tpm.TpmEnabled)"
    } catch { $info.Tpm = '' }
    return $info
}

function Get-BitLockerAuditFolder {
    # Where the action log lives: ProgramData\Gr3yTools-audit, writable only by administrators and SYSTEM (it
    # records who decrypted what and when, so ordinary users must not be able to rewrite it) and outside the
    # work folder that is cleaned after 30 days. $null when it cannot be made or its owner is not trustworthy,
    # and always $null in a session that is not elevated (its token has Administrators as "deny only", so it
    # would be locked out of the very folder it just made). It has a folder of its own, not a sub-folder of
    # ProgramData\Gr3yTools: that one is where the Dell API credentials file is put by hand, and an ordinary user
    # who made it would make everything inside it untrustworthy.
    try {
        $root = $env:ProgramData
        if (-not $root) { return $null }
        $elevated = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $elevated) { return $null }
        $dir = Join-Path $root 'Gr3yTools-audit'
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            [void](& icacls.exe $dir '/inheritance:r' '/grant:r' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) { return $null }
        }
        # trusted only while it is still what was made: owned by Administrators or SYSTEM (compared as SIDs, so it
        # works on a Windows that is not in English; TrustedInstaller is the other owner Windows itself uses), not a
        # junction or link (here or in its parent - whose owner must be one of those too, or an ordinary user made it),
        # its permissions still protected (not inherited from ProgramData), and no ordinary users or Everyone with access
        $trustedOwners = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
        foreach ($p in @($dir, (Split-Path -Parent $dir))) {
            if ((Get-Item -LiteralPath $p -Force -ErrorAction Stop).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $null }
            if ($trustedOwners -notcontains (Get-Acl -LiteralPath $p -ErrorAction Stop).GetOwner([System.Security.Principal.SecurityIdentifier]).Value) { return $null }
        }
        $acl = Get-Acl -LiteralPath $dir -ErrorAction Stop
        if (-not $acl.AreAccessRulesProtected) { return $null }
        foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
            if ($rule.AccessControlType -eq 'Allow' -and @('S-1-1-0', 'S-1-5-32-545', 'S-1-5-11') -contains $rule.IdentityReference.Value) { return $null }
        }
        return $dir
    } catch {
        return $null
    }
}

function Write-BitLockerActionLog {
    # A line in bitlocker-actions.log (what was done, when, by whom), UTF-8. Never put a key in it. It goes to
    # the audit folder when that can be used, and to the work folder when it cannot (or when writing there fails).
    # Never throws and returns nothing - except with -PassThru, which returns $true when the line was written
    # somewhere and $false when no log could be written at all.
    param([string]$Message, [switch]$PassThru)
    $line = "{0}  {1}\{2}  {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:USERDOMAIN, $env:USERNAME, $Message
    $places = New-Object System.Collections.Generic.List[string]
    try { $audit = Get-BitLockerAuditFolder; if ($audit) { $places.Add($audit) } } catch { }
    $places.Add($(if ($workDir) { $workDir } else { $env:TEMP }))
    foreach ($dir in $places) {
        try {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            [System.IO.File]::AppendAllText((Join-Path $dir 'bitlocker-actions.log'), $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
            if ($PassThru) { return $true }
            return
        } catch { }
    }
    if ($PassThru) { return $false }
}

function Get-BitLockerFriendlyError {
    # Windows' own error text, followed (when the code is one we know) by what to do about it.
    # BitLocker errors end in their code, e.g. "(0x80310000)"; the access-denied one is only the code.
    param([string]$Message, [int]$HResult = 0)
    $text = $(if ($Message) { $Message.Trim() } else { 'Unknown error' })
    $code = ''
    $found = [regex]::Match($text, '0x[0-9A-Fa-f]{8}')
    if ($found.Success) { $code = $found.Value.ToLowerInvariant() }
    elseif ($HResult -ne 0) { $code = ('0x{0:x8}' -f $HResult) }
    $hint = ''
    switch ($code) {
        '0x80310029' { $hint = 'Windows will not decrypt the Windows drive while it holds auto-unlock keys for other drives. Clear them (this tool can do it when you let it) and try again.' }
        '0x80310000' { $hint = 'The drive is locked. Unlock it first (open it in File Explorer and enter its password or recovery key), then try again.' }
        '0x80310008' { $hint = 'The drive is not encrypted, so there is nothing to turn off.' }
        '0x80041003' { $hint = 'Access was denied. Start Gr3y Tools as an administrator and try again.' }
        '0x80070005' { $hint = 'Access was denied. Start Gr3y Tools as an administrator and try again.' }
    }
    if ($hint) { return "$text $hint" }
    return $text
}

function Clear-BitLockerStoredAutoUnlock {
    # Removes every auto-unlock key stored on the Windows drive (Windows will not decrypt that drive
    # while any exist). Data drives that stay encrypted then ask for their password or recovery key
    # instead of unlocking themselves. Re-reads the Windows drive afterwards to check.
    # { Ok; Cleared; Error }: Cleared is true as soon as the clear command itself ran without an error - even
    # when the check afterwards failed - because from then on the drives that used those keys will ask for
    # their password or recovery key, and the person must be told so.
    try {
        Clear-BitLockerAutoUnlock -ErrorAction Stop | Out-Null
    } catch {
        return [PSCustomObject]@{ Ok = $false; Cleared = $false; Error = (Get-BitLockerFriendlyError -Message $_.Exception.Message -HResult $_.Exception.HResult) }
    }
    try {
        $os = @(Get-BitLockerVolume -ErrorAction Stop | Where-Object { [string]$_.VolumeType -eq 'OperatingSystem' }) | Select-Object -First 1
        if ($os -and ([string]$os.AutoUnlockKeyStored -eq 'True')) {
            return [PSCustomObject]@{ Ok = $false; Cleared = $true; Error = 'Windows still reports stored auto-unlock keys after they were cleared.' }
        }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Cleared = $true; Error = "Could not re-read the Windows drive to check: $($_.Exception.Message)" }
    }
    return [PSCustomObject]@{ Ok = $true; Cleared = $true; Error = $null }
}

function Start-BitLockerDecrypt {
    # Decrypts ONE drive. Checks the argument is exactly a drive letter and re-reads the volume
    # first (it may have changed since the dialog looked). A Windows drive that holds auto-unlock keys
    # for other drives is refused by Windows until they are cleared; that is done only when the caller
    # passes -ClearAutoUnlock (the dialog does so after telling the person). With -ExpectedIdentity (the drive's
    # Get-BitLockerDriveIdentity from when it was listed and confirmed) it also refuses, before anything is cleared or
    # decrypted, when the drive that has this letter NOW is a different one - the last read the app controls.
    # { Ok; Error; ClearedAutoUnlock }.
    param([string]$MountPoint, [switch]$ClearAutoUnlock, $ExpectedIdentity)
    $r = [PSCustomObject]@{ Ok = $false; Error = $null; ClearedAutoUnlock = $false }
    if ($MountPoint -cnotmatch '^[A-Za-z]:\z') { $r.Error = "Not a drive letter: $MountPoint"; return $r }
    try {
        $now = ConvertTo-BitLockerVolumeDetail -Volume (Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop)
    } catch {
        $r.Error = "Could not read $MountPoint before decrypting: $(Get-BitLockerFriendlyError -Message $_.Exception.Message -HResult $_.Exception.HResult)"
        return $r
    }
    $verdict = Get-BitLockerDisableState -Volume $now
    if (-not $verdict.CanDisable) { $r.Error = "$MountPoint cannot be decrypted now: $($verdict.Reason)"; return $r }
    if ($null -ne $ExpectedIdentity) {
        $ids = Get-BitLockerVolumeIdMap
        if ($ids.ContainsKey($MountPoint)) { $now.VolumeId = [string]$ids[$MountPoint] }
        if (-not (Test-BitLockerSameDrive -Identity $ExpectedIdentity -Volume $now)) {
            $r.Error = 'it is not the drive that was confirmed (a different drive, or different keys) - nothing was decrypted. Press Refresh status and start again.'
            return $r
        }
    }
    if ($now.VolumeType -eq 'OperatingSystem' -and $now.AutoUnlockKeyStored) {
        if (-not $ClearAutoUnlock) {
            $r.Error = "$MountPoint holds auto-unlock keys for other drives, and Windows will not decrypt it until they are cleared."
            return $r
        }
        $clear = Clear-BitLockerStoredAutoUnlock
        # ClearedAutoUnlock says the clear command RAN, whatever happens next: the caller must report it even when
        # the check afterwards or the decrypt fails
        if ($clear.Cleared) { $r.ClearedAutoUnlock = $true }
        if (-not $clear.Ok) {
            $r.Error = $(if ($clear.Cleared) { "The auto-unlock keys stored on $MountPoint were cleared, but the result could not be confirmed - $($clear.Error)" } else { "Could not clear the auto-unlock keys stored on $MountPoint - $($clear.Error)" })
            return $r
        }
    }
    try {
        Disable-BitLocker -MountPoint $MountPoint -ErrorAction Stop | Out-Null
    } catch {
        $r.Error = Get-BitLockerFriendlyError -Message $_.Exception.Message -HResult $_.Exception.HResult
        return $r
    }
    $r.Ok = $true
    return $r
}

function Add-BitLockerRecoveryProtector {
    # Adds a recovery password protector to a drive that has none (a safety net while decrypting).
    # Add-BitLockerKeyProtector writes the new password into the WARNING stream; that is silenced
    # here so it can never reach a console, a log or a transcript. The backup reads it back properly.
    param([string]$MountPoint)
    if ($MountPoint -cnotmatch '^[A-Za-z]:\z') { return [PSCustomObject]@{ Ok = $false; Error = "Not a drive letter: $MountPoint" } }
    try {
        Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryPasswordProtector -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
        return [PSCustomObject]@{ Ok = $true; Error = $null }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Error = (Get-BitLockerFriendlyError -Message $_.Exception.Message -HResult $_.Exception.HResult) }
    }
}

function Get-PreventDeviceEncryptionValue {
    # The PreventDeviceEncryption setting as a number, or $null when it is not set or cannot be read.
    param([string]$Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker')
    try {
        return (Get-ItemProperty -LiteralPath $Path -Name 'PreventDeviceEncryption' -ErrorAction Stop).PreventDeviceEncryption
    } catch {
        return $null
    }
}

function Set-PreventDeviceEncryption {
    # A precaution: this documented registry value (the same one the Provisioning tab sets) tells Windows not to
    # start automatic device encryption (which can happen at the first Microsoft-account sign-in on a PC that
    # qualifies). Microsoft says device encryption that was turned off does not turn itself on again; a
    # management policy such as Intune can still re-encrypt. Reads it first and writes nothing when it is
    # already 1. { Ok; Error; AlreadySet }.
    param([string]$Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker')
    $r = [PSCustomObject]@{ Ok = $false; Error = $null; AlreadySet = $false }
    if ((Get-PreventDeviceEncryptionValue -Path $Path) -eq 1) { $r.Ok = $true; $r.AlreadySet = $true; return $r }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name 'PreventDeviceEncryption' -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        $r.Ok = $true
    } catch {
        $r.Error = $_.Exception.Message
    }
    return $r
}

function Test-BitLockerPolicyPresent {
    # True when any of these registry keys holds at least one value, which is how a BitLocker policy
    # (Group Policy, or MDM such as Intune) shows up on a PC. An empty leftover key does not count.
    param([string[]]$Path = @('HKLM:\SOFTWARE\Policies\Microsoft\FVE', 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FVE', 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\BitLocker'))
    foreach ($p in $Path) {
        try {
            if ((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -ErrorAction Stop).ValueCount -gt 0)) { return $true }
        } catch { }
    }
    return $false
}

function Test-BitLockerManagedText {
    # Does the text of "dsregcmd /status" say this PC is joined to Entra ID or enrolled in MDM? Each field is
    # matched on its OWN line: an empty "MdmUrl :" must not run on into the next field.
    param([string]$Text)
    if (-not $Text) { return $false }
    return (($Text -match '(?im)^[ \t]*AzureAdJoined[ \t]*:[ \t]*YES\b') -or ($Text -match '(?im)^[ \t]*MdmUrl[ \t]*:[ \t]*\S'))
}

function Get-BitLockerDecryptWarnings {
    # Things worth saying before decrypting: running on battery (discharging, low or critical); the PC looks
    # managed (a policy can switch BitLocker back on). Read-only; each check is allowed to fail quietly.
    $w = New-Object System.Collections.Generic.List[string]
    try {
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Select-Object -First 1
        if ($battery -and @(1, 4, 5) -contains [int]$battery.BatteryStatus) { $w.Add('The PC is running on battery - plug it in first; decrypting works the disk hard.') }
    } catch { }
    if (Test-BitLockerPolicyPresent) { $w.Add('BitLocker policy settings are present on this PC (Group Policy or MDM): a policy may switch BitLocker back on, or stop a drive being decrypted.') }
    try {
        $dsreg = & dsregcmd /status 2>&1 | Out-String
        if (Test-BitLockerManagedText -Text $dsreg) { $w.Add('This PC is joined to Entra ID or enrolled in MDM: your organisation may switch encryption back on by policy.') }
    } catch { }
    return $w.ToArray()   # callers wrap the call in @()
}

function Get-BitLockerDecryptOrder {
    # The ticked drives in the order to start decrypting them: data drives first, the Windows drive last.
    param($Volumes, [string[]]$Mounts)
    $data = New-Object System.Collections.Generic.List[string]
    $windows = New-Object System.Collections.Generic.List[string]
    foreach ($m in @($Mounts)) {
        $v = @($Volumes | Where-Object { $_.MountPoint -eq $m }) | Select-Object -First 1
        if ($v -and $v.VolumeType -eq 'OperatingSystem') { $windows.Add([string]$m) } else { $data.Add([string]$m) }
    }
    $all = New-Object System.Collections.Generic.List[string]
    $all.AddRange($data)
    $all.AddRange($windows)
    return $all.ToArray()   # callers wrap the call in @()
}

function Get-BitLockerAutoUnlockAffected {
    # Encrypted drives that are NOT being decrypted but unlock themselves with a key kept on the Windows
    # drive: once those keys are cleared they will ask for their password or recovery key instead.
    param($Volumes, [string[]]$Mounts)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($Volumes)) {
        if (@($Mounts) -contains $v.MountPoint) { continue }
        if ([string]$v.AutoUnlockEnabled -eq 'True' -and [string]$v.VolumeStatus -ne 'FullyDecrypted') { $out.Add([string]$v.MountPoint) }
    }
    return $out.ToArray()   # callers wrap the call in @()
}

function Get-BitLockerElapsedText {
    # "under a minute", "12 min", "1 h 05 min".
    param([timespan]$Span)
    $mins = [int][math]::Floor($Span.TotalMinutes)
    if ($mins -lt 1) { return 'under a minute' }
    if ($mins -lt 60) { return "$mins min" }
    return ('{0} h {1:D2} min' -f [int][math]::Floor($mins / 60), ($mins % 60))
}

function Get-BitLockerProgressText {
    # What to show for a drive whose decryption this dialog started: its state, how long it has been
    # going and, once it has moved a few points, a rough estimate of what is left. $Started: { At;
    # StartPercent } (the time and the "% still encrypted" when it was started), or $null. A drive that has
    # finished keeps the time it took: { Finished } is when it was first seen finished (a drive that finished
    # early must not go on "taking" longer while another drive is still working).
    param($Volume, $Started, [datetime]$Now)
    $text = Get-BitLockerStateText -Volume $Volume
    if (-not $Started) { return $text }
    $elapsed = $Now - [datetime]$Started.At
    if ([string]$Volume.VolumeStatus -eq 'FullyDecrypted') {
        $finishedProp = $Started.PSObject.Properties['Finished']
        if ($finishedProp -and $finishedProp.Value) { $elapsed = [datetime]$finishedProp.Value - [datetime]$Started.At }
        return "Decrypted - took $(Get-BitLockerElapsedText -Span $elapsed)"
    }
    $text = "$text - running $(Get-BitLockerElapsedText -Span $elapsed)"
    if ([string]$Volume.VolumeStatus -eq 'DecryptionInProgress') {
        $done = [int]$Started.StartPercent - [int]$Volume.EncryptionPercentage
        if ($done -ge 3 -and $elapsed.TotalSeconds -ge 60) {
            $left = [timespan]::FromSeconds($elapsed.TotalSeconds * [int]$Volume.EncryptionPercentage / $done)
            $text += $(if ($left.TotalMinutes -lt 1) { ', under a minute left' } else { ", about $(Get-BitLockerElapsedText -Span $left) left" })
        }
    }
    return $text
}

function Get-BitLockerDriveDescription {
    # The kind of drive ("Fixed", "Removable"...) and its label, from .NET. Never throws; a locked
    # drive has no readable label.
    param([string]$MountPoint)
    $d = [PSCustomObject]@{ Kind = ''; Label = '' }
    if ($MountPoint -cnotmatch '^[A-Za-z]:\z') { return $d }
    try {
        $di = New-Object System.IO.DriveInfo($MountPoint)
        $d.Kind = [string]$di.DriveType
        if ($di.IsReady) { $d.Label = [string]$di.VolumeLabel }
    } catch { }
    return $d
}

function Get-BitLockerTypeText {
    # "Windows drive", "Data drive, removable (BACKUPS)" - BitLocker itself only says OperatingSystem or Data.
    param($Volume, $Drive)
    $text = $(if ([string]$Volume.VolumeType -eq 'OperatingSystem') { 'Windows drive' } elseif ([string]$Volume.VolumeType -eq 'Data') { 'Data drive' } else { [string]$Volume.VolumeType })
    if ($Drive -and [string]$Volume.VolumeType -ne 'OperatingSystem') {
        $kind = $(switch ([string]$Drive.Kind) { 'Fixed' { 'fixed' } 'Removable' { 'removable' } 'Network' { 'network' } default { '' } })
        if ($kind) { $text += ", $kind" }
    }
    if ($Drive -and $Drive.Label) { $text += " ($($Drive.Label))" }
    return $text
}

function Show-BitLockerDisableDialog {
    # The guided flow: status -> backup of every key (written, read back, checked) -> decrypt the
    # ticked drives -> progress. Nothing is changed until the last button, and that button stays
    # off until a backup has been verified and the keys it covers are still the keys that exist.
    $dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Disable BitLocker" Width="980" Height="730" MinWidth="900" MinHeight="600"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="#232629" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <SolidColorBrush x:Key="BgBrush" Color="#232629"/>
    <SolidColorBrush x:Key="ButtonBrush" Color="#1E3747"/>
    <SolidColorBrush x:Key="ButtonHoverBrush" Color="#2A4C69"/>
    <SolidColorBrush x:Key="ControlBorderBrush" Color="#707070"/>
    <SolidColorBrush x:Key="TextBrush" Color="#F7F7F7"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#9AA3AB"/>
    <SolidColorBrush x:Key="HeaderBrush" Color="#5BDCFF"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#5BDCFF"/>
    <SolidColorBrush x:Key="GreenBrush" Color="#3FB950"/>
    <SolidColorBrush x:Key="AmberBrush" Color="#D29922"/>
    <SolidColorBrush x:Key="ErrorBrush" Color="#F85149"/>
    <SolidColorBrush x:Key="LogBgBrush" Color="#1B1E21"/>
    <SolidColorBrush x:Key="PanelBorderBrush" Color="#2F373D"/>
    <SolidColorBrush x:Key="NavSelectedBrush" Color="#5E81AC"/>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="{StaticResource ButtonBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,5"/>
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
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource LogBgBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="FontFamily" Value="Consolas"/>
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
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Text="Disable BitLocker" FontFamily="Consolas" FontSize="16" Foreground="{StaticResource HeaderBrush}" Margin="0,0,0,8"/>
      <TextBlock Grid.Row="1" TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" Margin="0,0,0,10"
                 Text="Decrypts a drive so it no longer needs a BitLocker key. Button 1 saves a backup of every key Windows can export (and, if you leave the first box ticked, offers to add a recovery password to a drive that has none - the question defaults to No), then reads the file back and checks it. Nothing is decrypted until you press button 2, which stays off until that check has passed. When decryption finishes Windows removes the drive's key protectors, so the backup is then your only record of them."/>
      <Grid Grid.Row="2" Margin="8,0,25,4">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="34"/>
          <ColumnDefinition Width="56"/>
          <ColumnDefinition Width="150"/>
          <ColumnDefinition Width="190"/>
          <ColumnDefinition Width="250"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="1" Text="Drive" FontWeight="Bold" Foreground="{StaticResource MutedBrush}"/>
        <TextBlock Grid.Column="2" Text="Type" FontWeight="Bold" Foreground="{StaticResource MutedBrush}"/>
        <TextBlock Grid.Column="3" Text="State" FontWeight="Bold" Foreground="{StaticResource MutedBrush}"/>
        <TextBlock Grid.Column="4" Text="Key protectors" FontWeight="Bold" Foreground="{StaticResource MutedBrush}"/>
        <TextBlock Grid.Column="5" Text="Note" FontWeight="Bold" Foreground="{StaticResource MutedBrush}"/>
      </Grid>
      <ScrollViewer Grid.Row="3" VerticalScrollBarVisibility="Visible" HorizontalScrollBarVisibility="Disabled" MinHeight="90">
        <StackPanel Name="BlRows"/>
      </ScrollViewer>
      <Grid Grid.Row="4" Margin="0,12,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="Key backup file" VerticalAlignment="Center" Margin="0,0,10,0"/>
        <TextBox Grid.Column="1" Name="BlPathBox" MinHeight="30" VerticalContentAlignment="Center" AutomationProperties.Name="Key backup file"/>
        <Button Grid.Column="2" Name="BtnBlBrowse" Content="Browse..." Margin="8,0,0,0" MinWidth="90"/>
      </Grid>
      <TextBlock Grid.Row="5" TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" FontSize="12" Margin="0,4,0,8"
                 Text="Save it on a USB stick or another drive - not on a drive you are decrypting or one that stays encrypted. The file holds decryption secrets in plain text. On an NTFS drive only you, administrators and SYSTEM can read it (on another PC you need an administrator account to open it); a stick formatted FAT32 or exFAT cannot restrict that, so keep the stick safe. A copy in a cloud folder or on a share is only as private as that place."/>
      <StackPanel Grid.Row="6" Margin="0,0,0,6">
        <CheckBox Name="BlChkAddRecovery" IsChecked="True" Margin="0,0,0,6"><TextBlock TextWrapping="Wrap" Text="If a drive has no recovery password, offer to add one (recommended: it is then in the backup, so there is a key to recover with)."/></CheckBox>
        <CheckBox Name="BlChkPrevent" IsChecked="True"><TextBlock TextWrapping="Wrap" Text="Precaution: if the Windows drive is decrypted, also set PreventDeviceEncryption = 1 (stops automatic device encryption; delete that value to undo)."/></CheckBox>
        <ScrollViewer Name="BlStatusScroll" Margin="0,12,0,0" MaxHeight="90" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" IsTabStop="True" AutomationProperties.Name="Status">
          <TextBlock Name="BlStatus" TextWrapping="Wrap" MinHeight="54" Foreground="{StaticResource MutedBrush}" Text="Reading BitLocker status..." AutomationProperties.LiveSetting="Polite"/>
        </ScrollViewer>
      </StackPanel>
      <DockPanel Grid.Row="7" Margin="0,10,0,0" LastChildFill="False">
        <Button Name="BtnBlRefresh" Content="Refresh status" DockPanel.Dock="Left" Margin="0,0,8,0"/>
        <Button Name="BtnBlBackup" Content="1. Back up all keys" DockPanel.Dock="Left" Margin="0,0,8,0" BorderBrush="{StaticResource AccentBrush}"/>
        <Button Name="BtnBlDisable" Content="2. Disable BitLocker on ticked drives" DockPanel.Dock="Left" Margin="0,0,8,0" BorderBrush="{StaticResource AmberBrush}"/>
        <Button Name="BtnBlOpenFolder" Content="Show backup file" DockPanel.Dock="Left" Visibility="Collapsed"/>
        <Button Name="BtnBlClose" Content="Close" DockPanel.Dock="Right" MinWidth="90" IsCancel="True"/>
      </DockPanel>
    </Grid>
  </Border>
</Window>
'@
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($dialogXaml))
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    $dialog.Owner = $window
    # never taller or wider than the screen's work area (a small or highly scaled display would put the buttons
    # off-screen with no way to reach them - the main window is clamped the same way)
    try {
        $work = [System.Windows.SystemParameters]::WorkArea
        $maxH = [double]($work.Height - 20)
        $maxW = [double]($work.Width - 20)
        if ($maxH -gt 300) { if ($dialog.Height -gt $maxH) { $dialog.Height = $maxH }; if ($dialog.MinHeight -gt $maxH) { $dialog.MinHeight = $maxH } }
        if ($maxW -gt 400) { if ($dialog.Width -gt $maxW) { $dialog.Width = $maxW }; if ($dialog.MinWidth -gt $maxW) { $dialog.MinWidth = $maxW } }
    } catch { }

    $rowsPanel = $dialog.FindName('BlRows')
    $pathBox = $dialog.FindName('BlPathBox')
    $statusText = $dialog.FindName('BlStatus')
    $statusScroll = $dialog.FindName('BlStatusScroll')
    $chkAddRecovery = $dialog.FindName('BlChkAddRecovery')
    $chkPrevent = $dialog.FindName('BlChkPrevent')
    $btnBrowse = $dialog.FindName('BtnBlBrowse')
    $btnRefresh = $dialog.FindName('BtnBlRefresh')
    $btnBackup = $dialog.FindName('BtnBlBackup')
    $btnDisable = $dialog.FindName('BtnBlDisable')
    $btnShowFile = $dialog.FindName('BtnBlOpenFolder')
    $btnClose = $dialog.FindName('BtnBlClose')

    # Everything the handlers share lives in this one object: a closure captures VARIABLES at the
    # moment it is made, so a plain variable assigned later would not be seen by an earlier handler.
    $state = [PSCustomObject]@{
        Volumes = @(); Rows = @(); BackupOk = $false; BackupPath = ''; BackupHash = ''; BackedUpIds = @()
        Busy = $false; Started = @(); FileName = ''; InitialPath = ''; FailedNote = ''; RunNotes = @()
    }
    $state.FileName = "BitLocker-Backup_{0}_{1}.txt" -f (Get-MachineTag), (Get-Date -Format 'yyyyMMdd_HHmmss')
    $state.InitialPath = Join-Path ([Environment]::GetFolderPath('Desktop')) $state.FileName
    $pathBox.Text = $state.InitialPath

    $setStatus = {
        param([string]$Text, [string]$Kind)
        $statusText.Text = $Text
        $statusScroll.ScrollToHome()      # a new, longer text must start at its first line, not where the last one was scrolled to
        $brush = $(switch ($Kind) { 'ok' { 'GreenBrush' } 'warn' { 'AmberBrush' } 'error' { 'ErrorBrush' } default { 'MutedBrush' } })
        $statusText.Foreground = $dialog.FindResource($brush)
    }.GetNewClosure()

    $ticked = {
        # the rows whose box is ticked and whose drive can be decrypted
        return , @($state.Rows | Where-Object { $_.CanDisable -and $_.CheckBox.IsChecked })
    }.GetNewClosure()

    $updateButtons = {
        $tickedNow = & $ticked
        $btnRefresh.IsEnabled = -not $state.Busy
        $btnBrowse.IsEnabled = -not $state.Busy
        $btnBackup.IsEnabled = ((@($state.Volumes).Count -gt 0) -and -not $state.Busy)
        $btnDisable.IsEnabled = ($state.BackupOk -and (@($tickedNow).Count -gt 0) -and -not $state.Busy)
        $btnShowFile.Visibility = $(if ($state.BackupOk) { 'Visible' } else { 'Collapsed' })
        $dialog.Cursor = $(if ($state.Busy) { [System.Windows.Input.Cursors]::Wait } else { $null })
    }.GetNewClosure()

    # A closure made INSIDE another closure does not see the outer one's variables, so the tick-box
    # handler is made here, at the top level of the dialog, and handed to each row.
    $onTickChanged = { & $updateButtons }.GetNewClosure()

    # When a backup stops counting (its file is gone, or the keys changed), offer a NEW file name in the same
    # folder (an existing file is never overwritten, so the old name would only be refused) - but only when the
    # box still shows the old backup's path, never over something the person typed.
    $suggestNewName = {
        if ($state.BackupPath -and ($pathBox.Text.Trim() -ieq $state.BackupPath)) {
            try {
                $dir = [System.IO.Path]::GetDirectoryName($state.BackupPath)
                if ($dir) { $pathBox.Text = Join-Path $dir ("BitLocker-Backup_{0}_{1}.txt" -f (Get-MachineTag), (Get-Date -Format 'yyyyMMdd_HHmmss')) }
            } catch { }
        }
    }.GetNewClosure()

    # Each row remembers WHICH DRIVE it was made from (key IDs, size, type: Get-BitLockerDriveIdentity), so a tick stays
    # with the drive: a different drive that takes over the letter - a stick swapped while a message box is open, or
    # between two refreshes - is refused wherever the rows are used (Refresh, both buttons, every drive in the decrypt
    # loop). The identity is never re-taken silently; only the one step that adds a recovery password on purpose extends it.
    $findMoved = {
        param($Rows, $Volumes, [string[]]$AllowAdded)
        $moved = New-Object System.Collections.Generic.List[object]
        foreach ($row in @($Rows)) {
            $v = @($Volumes | Where-Object { $_.MountPoint -eq $row.Mount }) | Select-Object -First 1
            if (-not $v -or -not (Test-BitLockerSameDrive -Identity $row.Identity -Volume $v -AllowAddedKeys:(@($AllowAdded) -contains $row.Mount))) { $moved.Add($row) }
        }
        return $moved.ToArray()      # no leading comma: every caller wraps the call in @(), and an array wrapped in an array would always count as one "moved" row
    }.GetNewClosure()

    $movedText = {
        param($Moved)
        return "$(@($Moved | ForEach-Object { $_.Mount }) -join ', ') is no longer the drive that was listed (its keys or size are different, or BitLocker cannot read it now - was a drive swapped or unplugged?). It was unticked"
    }.GetNewClosure()

    $extendIdentity = {
        # a recovery password was added to this drive on purpose: the row takes its new key set and shows it
        param($Row, $Volume)
        $extended = Get-BitLockerDriveIdentity -Volume $Volume
        if (-not $extended.VolumeId -and $Row.Identity) { $extended.VolumeId = [string]$Row.Identity.VolumeId }      # an ID that could not be read this time is not forgotten
        $Row.Identity = $extended
        $Row.ProtBlock.Text = Get-BitLockerProtectorSummary -Volume $Volume
    }.GetNewClosure()

    $addRow = {
        param($v)
        $dis = Get-BitLockerDisableState -Volume $v
        $grid = New-Object System.Windows.Controls.Grid
        foreach ($w in @('34', '56', '150', '190', '250', '*')) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = [System.Windows.GridLength]::new([double]($w -replace '\*', '1'), $(if ($w -eq '*') { 'Star' } else { 'Pixel' }))
            [void]$grid.ColumnDefinitions.Add($cd)
        }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.VerticalAlignment = 'Center'
        $cb.IsEnabled = [bool]$dis.CanDisable
        [System.Windows.Automation.AutomationProperties]::SetName($cb, "Decrypt $($v.MountPoint)")
        # a screen reader reads the state (and why a box cannot be ticked) after the name
        [System.Windows.Automation.AutomationProperties]::SetHelpText($cb, "$(Get-BitLockerStateText -Volume $v). $(if ($dis.CanDisable) { [string]$dis.Note } else { 'Cannot be selected: ' + [string]$dis.Reason })")
        [System.Windows.Controls.Grid]::SetColumn($cb, 0); [void]$grid.Children.Add($cb)
        $typeText = Get-BitLockerTypeText -Volume $v -Drive (Get-BitLockerDriveDescription -MountPoint $v.MountPoint)
        $cells = @(
            @{ Col = 1; Text = [string]$v.MountPoint; Font = 'Consolas'; Bold = $true },
            @{ Col = 2; Text = $typeText },
            @{ Col = 3; Text = (Get-BitLockerStateText -Volume $v) },
            @{ Col = 4; Text = (Get-BitLockerProtectorSummary -Volume $v) },
            @{ Col = 5; Text = $(if ($dis.CanDisable) { [string]$dis.Note } else { [string]$dis.Reason }) }
        )
        $blocks = @{}
        foreach ($c in $cells) {
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Text = $c.Text; $tb.TextWrapping = 'Wrap'; $tb.Margin = '0,0,8,0'; $tb.VerticalAlignment = 'Center'
            if ($c.Font) { $tb.FontFamily = $c.Font }
            if ($c.Bold) { $tb.FontWeight = 'Bold' }
            [System.Windows.Controls.Grid]::SetColumn($tb, $c.Col); [void]$grid.Children.Add($tb)
            $blocks[$c.Col] = $tb
        }
        $border = New-Object System.Windows.Controls.Border
        $border.Background = $dialog.FindResource('LogBgBrush'); $border.Padding = '8,7'; $border.Margin = '0,0,0,4'
        $border.Child = $grid
        [System.Windows.Automation.AutomationProperties]::SetName($border, "$($v.MountPoint) $(Get-BitLockerStateText -Volume $v)")
        [void]$rowsPanel.Children.Add($border)
        $cb.Add_Checked($onTickChanged)
        $cb.Add_Unchecked($onTickChanged)
        return [PSCustomObject]@{ Mount = [string]$v.MountPoint; CanDisable = [bool]$dis.CanDisable; CheckBox = $cb; StateBlock = $blocks[3]; ProtBlock = $blocks[4]; NoteBlock = $blocks[5]; Identity = (Get-BitLockerDriveIdentity -Volume $v) }
    }.GetNewClosure()

    $refresh = {
        # $AddedMounts: drives that just got a recovery password ON PURPOSE (their key set may grow and the tick stays).
        param([string[]]$AddedMounts = @())
        # Ticks are the person's own choice: they are kept across a refresh - for the SAME DRIVE only, not for whatever
        # drive now has the letter - and nothing is ever ticked for them.
        $keepTicked = @($state.Rows | Where-Object { $_.CheckBox.IsChecked } | ForEach-Object { [PSCustomObject]@{ Mount = $_.Mount; Identity = $_.Identity } })
        $untickedByIdentity = New-Object System.Collections.Generic.List[string]
        $rowsPanel.Children.Clear()
        $state.Rows = @()
        $data = Get-BitLockerVolumeDetail
        if ($data.Error) {
            $state.Volumes = @()
            # with nothing to compare against, an earlier backup cannot be said to still cover every key: it stops counting,
            # and (like every other time a backup stops counting) a new file name is offered, because an existing file is never overwritten
            $lostBackup = $state.BackupOk
            if ($lostBackup) { $state.BackupOk = $false; & $suggestNewName }
            $lostText = $(if ($lostBackup) { "`r`nThe backup you made earlier no longer counts: once BitLocker can be read, press button 1 to make a new one (under a new file name)." } else { '' })
            & $setStatus "Could not read BitLocker status: $($data.Error)`r`nThis needs the BitLocker PowerShell module and an elevated app (on Windows Home, turn device encryption off in Settings > Privacy and security > Device encryption).$lostText" 'error'
            & $updateButtons
            return
        }
        $state.Volumes = @($data.Volumes)
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($v in $state.Volumes) { $rows.Add((& $addRow $v)) }
        $state.Rows = $rows.ToArray()
        $eligible = @($state.Rows | Where-Object { $_.CanDisable })
        foreach ($row in $eligible) {
            $k = @($keepTicked | Where-Object { $_.Mount -eq $row.Mount }) | Select-Object -First 1
            if (-not $k) { continue }
            $vol = @($state.Volumes | Where-Object { $_.MountPoint -eq $row.Mount }) | Select-Object -First 1
            if (Test-BitLockerSameDrive -Identity $k.Identity -Volume $vol -AllowAddedKeys:(@($AddedMounts) -contains $row.Mount)) { $row.CheckBox.IsChecked = $true }
            else { $untickedByIdentity.Add($row.Mount) }
        }
        # A backup counts only while it covers every key that exists now.
        $hadBackup = $state.BackupOk
        if ($state.BackupOk -and -not (Test-BitLockerKeysCovered -Volumes $state.Volumes -BackedUpIds $state.BackedUpIds)) { $state.BackupOk = $false }
        if ($state.BackupOk -and -not (Test-Path -LiteralPath $state.BackupPath)) { $state.BackupOk = $false }
        $droppedBackup = ($hadBackup -and -not $state.BackupOk)
        if ($droppedBackup) { & $suggestNewName }
        if ($state.Volumes.Count -eq 0) {
            & $setStatus 'BitLocker reported no volumes.' 'warn'
        } elseif ($eligible.Count -eq 0) {
            & $setStatus 'No drive can be decrypted right now (none is encrypted, or the encrypted ones are locked, paused, encrypted by the drive itself, wiping free space, or already decrypting). Button 1 can still save a backup of every key.' 'warn'
        } else {
            & $setStatus 'Tick the drive(s) to decrypt, check the backup file name, then press button 1. Button 1 writes the backup file and, if you left the first box ticked, offers to add a recovery password to a drive that has none; it decrypts nothing.' 'info'
        }
        if ($droppedBackup) {
            & $setStatus "$($statusText.Text)`r`nThe backup you made earlier no longer counts (its file is gone or the keys changed): press button 1 to make a new one, under a new file name (an existing file is never overwritten)." 'warn'
        }
        # one volume BitLocker cannot read does not hide the others, but it is said
        if (@($data.Unreadable).Count -gt 0) {
            & $setStatus "$($statusText.Text)`r`nNote: BitLocker could not read some volumes, so they are not listed: $(@($data.Unreadable) -join '; ')" 'warn'
        }
        if ($untickedByIdentity.Count -gt 0) {
            & $setStatus "$($statusText.Text)`r`n$($untickedByIdentity -join ', ') was unticked: it is not the drive that was ticked (its keys or size changed - was a drive swapped?). Look at its row and tick it again if it is the one you want." 'warn'
        }
        & $updateButtons
    }.GetNewClosure()

    $btnRefresh.Add_Click({ & $refresh }.GetNewClosure())

    $btnBrowse.Add_Click({
        $sfd = New-Object Microsoft.Win32.SaveFileDialog
        $current = $pathBox.Text.Trim()
        $sfd.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
        $sfd.OverwritePrompt = $false   # an existing file is never overwritten; the save refuses it with a message
        try { $sfd.FileName = [System.IO.Path]::GetFileName($current); $sfd.InitialDirectory = [System.IO.Path]::GetDirectoryName($current) } catch { }
        if ($sfd.ShowDialog($dialog)) { $pathBox.Text = $sfd.FileName }
    }.GetNewClosure())

    $btnBackup.Add_Click({
        if ($state.Busy) { return }
        $state.Busy = $true
        & $updateButtons
        try {
            # what is typed is cleaned: spaces and the quotes Explorer's "Copy as path" puts round a path
            $path = $pathBox.Text.Trim().Trim('"').Trim()
            if ($path -cne $pathBox.Text) { $pathBox.Text = $path }
            if (-not $path) { & $setStatus 'Type or browse to the file the backup should be saved to.' 'warn'; return }

            # pressing button 1 again for a backup that is still good is not an error; one that no longer
            # counts is replaced under a new file name (an existing file is never overwritten)
            $newNameNote = ''
            if ($state.BackupOk -and $path -ieq $state.BackupPath) {
                $still = Test-BitLockerBackupStillGood -Path $state.BackupPath -Hash $state.BackupHash -BackedUpIds $state.BackedUpIds
                if ($still.Ok) { & $setStatus "That backup is still good, so there is nothing to do: $path`r`nIt covers every key BitLocker could read. Tick the drive(s) and press button 2 when you are ready." 'ok'; return }
                if (-not $still.Stale) { & $setStatus $still.Reason 'error'; return }
                $state.BackupOk = $false
                & $suggestNewName
                $path = $pathBox.Text.Trim()
                $newNameNote = "`r`nThe earlier backup no longer counted (its file changed or is gone, or the keys changed), so a new file name was used."
            }
            # the place is checked BEFORE anything is changed on a drive; a failed check leaves an earlier good backup alone
            $placeCheck = Test-BitLockerBackupPath -Path $path
            if (-not $placeCheck.Ok) {
                $earlier = $(if ($state.BackupOk) { "`r`nYour earlier backup ($($state.BackupPath)) still counts." } else { '' })
                & $setStatus "The backup was NOT saved and nothing was changed: $($placeCheck.Error)$earlier" 'error'
                return
            }

            $tickedNow = & $ticked
            $tickedMounts = @($tickedNow | ForEach-Object { $_.Mount })
            $addedTo = New-Object System.Collections.Generic.List[string]

            # BitLocker is read before anything changes: the ticked rows must still be the drives that were listed (a
            # letter can be given to another drive), and the place of the file is judged against the real drives. The
            # same check is made again after the message boxes below (they can stay open for minutes: a stick can be
            # swapped meanwhile) - right before a recovery password is added, and against the read the backup is made from.
            $pre = Get-BitLockerVolumeDetail
            if ($pre.Error) { & $setStatus "Could not read BitLocker status: $($pre.Error)" 'error'; return }
            $moved = @(& $findMoved $tickedNow $pre.Volumes @())
            if ($moved.Count -gt 0) {
                foreach ($row in $moved) { $row.CheckBox.IsChecked = $false }
                & $setStatus "$(& $movedText $moved) and nothing was changed. Press Refresh status to list the drives again, then tick what you want." 'error'
                return
            }
            # a place that deserves a second thought (a drive about to be decrypted, an encrypted drive, OneDrive) is asked about BEFORE the keys are written there
            $placeNote = Get-BitLockerBackupPlaceNote -Path $path -Volumes $pre.Volumes -Mounts $tickedMounts -CloudRoots @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)
            if ($placeNote) {
                $okPlace = [System.Windows.MessageBox]::Show($dialog, "The backup would be saved here:`r`n$path`r`n`r`n$placeNote`r`n`r`nSave it there anyway?", 'Gr3y Tools', 'YesNo', 'Warning', 'No')
                if ($okPlace -ne 'Yes') { & $setStatus 'Nothing was changed - choose another place for the backup file (a USB stick is best), then press button 1 again.' 'info'; return }
            }

            # a recovery password is the one key a person can actually type in an emergency; the question defaults to No
            if ($chkAddRecovery.IsChecked -and $tickedMounts.Count -gt 0) {
                $lacking = @(Get-BitLockerMountsWithoutRecoveryPassword -Volumes $pre.Volumes -Mounts $tickedMounts)
                if ($lacking.Count -gt 0) {
                    $ask = [System.Windows.MessageBox]::Show($dialog, "These drives have no recovery password: $($lacking -join ', ')`r`n`r`nAdd one now? It is saved in the backup, so there is something to unlock the drive with if anything goes wrong while decrypting. This changes nothing else about the drive.", 'Gr3y Tools', 'YesNo', 'Question', 'No')
                    if ($ask -eq 'Yes') {
                        # the question may have been open for minutes: read again, and only add to a drive that is STILL the
                        # one that was listed and STILL has no recovery password
                        $mid = Get-BitLockerVolumeDetail
                        if ($mid.Error) { & $setStatus "Nothing was changed. Could not read BitLocker status: $($mid.Error)" 'error'; return }
                        $movedMid = @(& $findMoved $tickedNow $mid.Volumes @())
                        if ($movedMid.Count -gt 0) {
                            foreach ($row in $movedMid) { $row.CheckBox.IsChecked = $false }
                            & $setStatus "$(& $movedText $movedMid) and nothing was changed (no recovery password was added). Press Refresh status to list the drives again, then tick what you want." 'error'
                            return
                        }
                        foreach ($m in @(Get-BitLockerMountsWithoutRecoveryPassword -Volumes $mid.Volumes -Mounts $lacking)) {
                            $add = Add-BitLockerRecoveryProtector -MountPoint $m
                            if ($add.Ok) { $addedTo.Add($m); Write-BitLockerActionLog "Added a recovery password protector to $m (before backup)" }
                            else {
                                Write-BitLockerActionLog "Could not add a recovery password protector to $m - $($add.Error)"
                                $before = $(if ($addedTo.Count -gt 0) { "A recovery password was added to $($addedTo -join ', ') first - it is in no backup yet; press button 1 again.`r`n" } else { '' })
                                & $refresh -AddedMounts $addedTo.ToArray()
                                & $setStatus "${before}Could not add a recovery password to $m - $($add.Error)" 'error'
                                return
                            }
                        }
                    }
                }
            }
            # whatever happens from here on, a protector added above must be named in every failure
            $addedFail = $(if ($addedTo.Count -gt 0) { "A recovery password WAS added to $($addedTo -join ', ') before this failed - it is in no backup file yet, so press button 1 again (it will be included).`r`n" } else { '' })

            & $setStatus 'Reading every key...' 'info'
            $data = Get-BitLockerVolumeDetail
            if ($data.Error) { & $setStatus "${addedFail}Could not read BitLocker status: $($data.Error)" 'error'; return }
            # a ticked drive BitLocker cannot read now would be missing from the backup: stop instead of backing up less than was asked for;
            # and every ticked drive must still be the one that was listed (a drive that just got a recovery password may have MORE keys)
            $moved2 = @(& $findMoved $tickedNow $data.Volumes $addedTo.ToArray())
            $movedMounts2 = @($moved2 | ForEach-Object { $_.Mount })
            # the rows of the drives that got a recovery password take its new keys and show them - also when something else
            # stops the backup below, so that pressing button 1 again finds those drives as they are now, not as "swapped"
            foreach ($row in @($tickedNow | Where-Object { $addedTo -contains $_.Mount -and $movedMounts2 -notcontains $_.Mount })) {
                $vNow = @($data.Volumes | Where-Object { $_.MountPoint -eq $row.Mount }) | Select-Object -First 1
                if ($vNow) { & $extendIdentity $row $vNow }
            }
            if ($moved2.Count -gt 0) {
                foreach ($row in $moved2) { $row.CheckBox.IsChecked = $false }
                & $setStatus "${addedFail}The backup was NOT made: $(& $movedText $moved2). Press Refresh status to list the drives again, then tick what you want." 'error'
                return
            }
            $raw = Get-BitLockerRawOutput -Volumes $data.Volumes
            $text = New-BitLockerBackupText -Volumes $data.Volumes -Info (Get-BitLockerBackupSystemInfo) -RawStatus $raw.Status -RawProtectors $raw.Protectors -Unreadable $data.Unreadable
            $save = Save-BitLockerBackupFile -Path $path -Text $text
            if (-not $save.Ok) { & $setStatus "${addedFail}The backup was NOT saved: $($save.Error)" 'error'; & $updateButtons; return }
            $check = Test-BitLockerBackupText -Text $save.Text -Volumes $data.Volumes
            if (-not $check.Ok) {
                & $setStatus "${addedFail}The file was written but failed the check - missing: $($check.Missing -join '; '). Nothing will be decrypted. Choose another location and try again." 'error'
                Write-BitLockerActionLog "Backup check FAILED for $path ($($check.Missing.Count) item(s) missing)"
                return
            }
            $state.Volumes = @($data.Volumes)
            $state.BackupOk = $true
            $state.BackupPath = $path
            $state.BackupHash = $save.Hash
            $state.BackedUpIds = @(Get-BitLockerKeyIds -Volumes $data.Volumes)
            $recoveryCount = @($data.Volumes | ForEach-Object { @($_.Protectors) | Where-Object { $_.RecoveryPassword } }).Count
            Write-BitLockerActionLog "Key backup saved and verified: $path ($(@($data.Volumes).Count) volume(s), $recoveryCount recovery password(s), $(@($state.BackedUpIds).Count) key protector(s))"
            $aclNote = $(if ($save.AclWarning) { "`r`nNote: $($save.AclWarning)" } else { '' })
            $sameDrive = $(if ($placeNote) { "`r`nNote: $placeNote" } else { '' })
            $unreadNote = $(if (@($data.Unreadable).Count -gt 0) { "`r`nNote: BitLocker could not read some volumes just now, so their keys are NOT in this backup: $(@($data.Unreadable) -join '; ')" } else { '' })
            # a drive that has no recovery password cannot be unlocked with this file
            $candidates = @($state.Rows | Where-Object { $_.CanDisable } | ForEach-Object { $_.Mount })
            $lackAll = @(Get-BitLockerMountsWithoutRecoveryPassword -Volumes $data.Volumes -Mounts $candidates)
            $hollow = $(if ($lackAll.Count -gt 0) { "`r`nNote: no recovery password exists for $($lackAll -join ', '), so this file cannot unlock $(if ($lackAll.Count -eq 1) { 'it' } else { 'them' }) - keep that drive's own password, PIN or key file safe." } else { '' })
            $addedText = $(if ($addedTo.Count -gt 0) { " A recovery password was added to $($addedTo -join ', ') first." } else { '' })
            $nextStep = $(if ($tickedMounts.Count -gt 0) { 'Press button 2 when you are ready.' } else { 'Now tick the drive(s) and press button 2 when you are ready.' })
            & $setStatus "Backup saved and checked: $path`r`n$(@($data.Volumes).Count) volume(s), $recoveryCount recovery password(s).$addedText $nextStep$newNameNote$aclNote$sameDrive$unreadNote$hollow" $(if ($sameDrive -or $aclNote -or $hollow -or $unreadNote) { 'warn' } else { 'ok' })
        } finally {
            $state.Busy = $false
            & $updateButtons
        }
    }.GetNewClosure())

    # Is this volume still the drive a started decrypt was following? Its key IDs are gone once it has finished, so the
    # follower goes by size, type and (when Windows tells it) the volume ID.
    $startedStillMatches = {
        param($S, $V)
        if ([string]$S.Capacity -and [string]$V.CapacityGB -cne [string]$S.Capacity) { return $false }
        if ([string]$S.VolumeType -and [string]$V.VolumeType -cne [string]$S.VolumeType) { return $false }
        if ([string]$S.VolumeId -and [string]$V.VolumeId -and [string]$V.VolumeId -cne [string]$S.VolumeId) { return $false }
        return $true
    }.GetNewClosure()

    # Does this row still show the drive that is being followed? A row made by a refresh AFTER another drive took the letter
    # shows that other drive, and what is written about the followed drive must not replace the real state of the one there now.
    $rowShowsFollowed = {
        param($Row, $S)
        if (-not $Row -or -not $Row.Identity) { return $false }
        return [bool](& $startedStillMatches $S ([PSCustomObject]@{ CapacityGB = $Row.Identity.Capacity; VolumeType = $Row.Identity.VolumeType; VolumeId = $Row.Identity.VolumeId }))
    }.GetNewClosure()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(5)
    $timer.Add_Tick({
        # A button handler is running (ticks also fire while one of its message boxes is open): the next tick reports, so that
        # what is written here is not overwritten by the handler before the person has seen it
        if ($state.Busy) { return }
        $data = Get-BitLockerVolumeDetail
        if ($data.Error) { return }
        $now = Get-Date
        $stillWorking = $false
        $gone = New-Object System.Collections.Generic.List[string]
        foreach ($s in @($state.Started)) {
            # an entry made by an older version of this window may lack the newer fields
            foreach ($field in @(@{ N = 'Misses'; V = 0 }, @{ N = 'Finished'; V = $null }, @{ N = 'DoneText'; V = '' }, @{ N = 'Gone'; V = $false }, @{ N = 'MissingSeen'; V = $false }, @{ N = 'VolumeId'; V = '' })) {
                if (-not $s.PSObject.Properties[$field.N]) { $s | Add-Member -NotePropertyName $field.N -NotePropertyValue $field.V }
            }
            $v = @($data.Volumes | Where-Object { $_.MountPoint -eq $s.Mount }) | Select-Object -First 1
            $row = @($state.Rows | Where-Object { $_.Mount -eq $s.Mount }) | Select-Object -First 1
            if ($s.Finished) {
                # a drive that finished stays finished, even if it is unplugged afterwards; its "Decrypted" text is put back on
                # its row (a refresh rebuilds the rows) for as long as it is still the same drive
                if ($v -and $row -and $s.DoneText -and [string]$v.VolumeStatus -eq 'FullyDecrypted' -and (& $startedStillMatches $s $v)) { $row.StateBlock.Text = [string]$s.DoneText }
                continue
            }
            # a drive judged to be another one stays judged so: it never becomes the one that was being decrypted later
            if ($s.Gone) { $gone.Add([string]$s.Mount); continue }
            if (-not $v) {
                # BitLocker answered with an error for some volume: this drive is probably still there - keep tracking
                # it (for about half a minute) instead of calling it unplugged
                if (@($data.Unreadable).Count -gt 0 -and [int]$s.Misses -lt 6) {
                    $s.Misses = [int]$s.Misses + 1
                    if ($row) { $row.StateBlock.Text = 'BitLocker could not read this drive just now - trying again...' }
                    $stillWorking = $true
                    continue
                }
                # unplugged (or not listed): it can come back, but only its volume ID can prove it is the same drive
                $s.MissingSeen = $true
                $gone.Add([string]$s.Mount)
                if ($row) { $row.StateBlock.Text = 'No longer listed - was it unplugged?' }
                continue
            }
            # another drive now has this letter (another size, type or volume ID - or one that was missing in between and
            # cannot be proved to be this one): not the drive that was being decrypted, so it must never be reported as
            # "finished" - a decrypted-looking drive in its place is not this one
            $idProves = ([string]$s.VolumeId -and [string]$v.VolumeId -and [string]$v.VolumeId -ceq [string]$s.VolumeId)
            if (-not (& $startedStillMatches $s $v) -or ($s.MissingSeen -and -not $idProves)) {
                $s.Gone = $true
                $gone.Add([string]$s.Mount)
                if ($row -and (& $rowShowsFollowed $row $s)) { $row.StateBlock.Text = 'A different drive now has this letter - the one being decrypted is gone' }
                continue
            }
            $s.MissingSeen = $false
            $s.Misses = 0
            # the time a drive took stops running when it finishes (another drive may still be working)
            if ([string]$v.VolumeStatus -eq 'FullyDecrypted' -and -not $s.Finished) {
                $s.Finished = $now
                Write-BitLockerActionLog "Decryption finished: $($s.Mount)"
            }
            if ($row) {
                $row.StateBlock.Text = Get-BitLockerProgressText -Volume $v -Started $s -Now $now
                if ($s.Finished) { $s.DoneText = $row.StateBlock.Text }
            }
            if ($v.VolumeStatus -ne 'FullyDecrypted') { $stillWorking = $true }
        }
        if (-not $stillWorking) {
            $timer.Stop()
            # a drive that finished is only reported as finished while nothing else has taken its letter: another drive there
            # now means it cannot be vouched for, like any other drive that is gone; the same drive encrypting again is said so
            $reenc = New-Object System.Collections.Generic.List[string]
            foreach ($s in @($state.Started)) {
                if (-not $s.Finished) { continue }
                $v = @($data.Volumes | Where-Object { $_.MountPoint -eq $s.Mount }) | Select-Object -First 1
                if (-not $v) { continue }
                $row = @($state.Rows | Where-Object { $_.Mount -eq $s.Mount }) | Select-Object -First 1
                if (-not (& $startedStillMatches $s $v)) {
                    $gone.Add([string]$s.Mount)
                    if ($row -and (& $rowShowsFollowed $row $s)) { $row.StateBlock.Text = 'A different drive now has this letter - the one being decrypted is gone' }
                } elseif ([string]$v.VolumeStatus -ne 'FullyDecrypted') {
                    $reenc.Add([string]$s.Mount)
                    if ($row) { $row.StateBlock.Text = Get-BitLockerStateText -Volume $v }
                }
            }
            $done = @($state.Started | ForEach-Object { $_.Mount } | Where-Object { $gone -notcontains $_ -and $reenc -notcontains $_ })
            if ($gone.Count -gt 0) { Write-BitLockerActionLog "Decryption: no longer listed: $($gone -join ', ')" }
            if ($reenc.Count -gt 0) { Write-BitLockerActionLog "Decryption: finished, but the drive on the letter is not fully decrypted now: $($reenc -join ', ')" }
            $msg = New-Object System.Collections.Generic.List[string]
            if ($done.Count -gt 0) {
                $windowsDone = (@($state.Volumes | Where-Object { $done -contains $_.MountPoint -and [string]$_.VolumeType -eq 'OperatingSystem' }).Count -gt 0)
                $dataDone = (@($done | Where-Object { $m = $_; @($state.Volumes | Where-Object { $_.MountPoint -eq $m -and [string]$_.VolumeType -eq 'OperatingSystem' }).Count -eq 0 }).Count -gt 0)
                $again = @()
                if ($windowsDone) { $again += 'To turn BitLocker on again for the Windows drive later: Provisioning tab, Enable BitLocker.' }
                if ($dataDone) { $again += 'To encrypt a data drive again later, turn BitLocker on from Windows (right-click the drive) or with manage-bde.' }
                $msg.Add("Decryption finished for $($done -join ', '). The drive(s) no longer need a BitLocker key. Keep the backup file until you are sure you do not need it. ($($again -join ' ') Windows then makes NEW keys.)")
            }
            if ($gone.Count -gt 0) { $msg.Add("$($gone -join ', ') is no longer listed, or another drive has taken its letter (was it unplugged?). Plug it back in and press Refresh status to see where it got to.") }
            foreach ($m in $reenc) { $msg.Add("$m finished decrypting, but the drive on $m is not fully decrypted now - it may be another drive, or this one encrypted again. The list shows its state.") }
            # what the person was told when the decrypt started and must not lose (keys cleared, a setting that could not be written)
            foreach ($note in @($state.RunNotes)) { $msg.Add([string]$note) }
            # a drive that was NOT started must not disappear from the screen when the others finish
            if ($state.FailedNote) { $msg.Add([string]$state.FailedNote) }
            & $setStatus ($msg -join "`r`n") $(if ($gone.Count -gt 0 -or $reenc.Count -gt 0 -or @($state.RunNotes).Count -gt 0 -or $state.FailedNote) { 'warn' } else { 'ok' })
            # everything that was followed has been reported now, and nothing of it is kept: a later run must never report a
            # drive again (its letter may belong to another drive by then), and a gone drive's letter must not flag whatever
            # drive is decrypted there next time (the rows keep their text until the next refresh)
            $state.Started = @()
            $state.RunNotes = @()
        }
    }.GetNewClosure())
    $dialog.Add_Closing({ $timer.Stop() }.GetNewClosure())

    $btnDisable.Add_Click({
        if ($state.Busy) { return }
        $state.Busy = $true
        & $updateButtons
        try {
            if (-not $state.BackupOk) { & $setStatus 'Press button 1 first: nothing is decrypted without a checked backup.' 'warn'; return }
            $tickedNow = & $ticked
            $mounts = @($tickedNow | ForEach-Object { $_.Mount })
            if ($mounts.Count -eq 0) { & $setStatus 'Tick at least one drive.' 'warn'; return }
            # a long job of this app (debloat, installs, provisioning) would fight the decryption for the disk
            $busyJobs = @(Get-RunningToolJobs)
            if ($busyJobs.Count -gt 0) { & $setStatus "A job is still running ($($busyJobs -join ', ')). Wait for it to finish, then press button 2 again." 'warn'; return }
            # the backup must still exist, unchanged, and still cover every key the drives have now
            $guard = Test-BitLockerBackupStillGood -Path $state.BackupPath -Hash $state.BackupHash -BackedUpIds $state.BackedUpIds
            if (-not $guard.Ok) { if ($guard.Stale) { $state.BackupOk = $false; & $suggestNewName }; & $setStatus $guard.Reason 'error'; return }
            $fresh = [PSCustomObject]@{ Volumes = $guard.Volumes }
            # every ticked drive must still be the drive that was listed and backed up (not whatever has its letter now)
            $movedNow = @(& $findMoved $tickedNow $fresh.Volumes @())
            if ($movedNow.Count -gt 0) {
                foreach ($row in $movedNow) { $row.CheckBox.IsChecked = $false }
                & $setStatus "$(& $movedText $movedNow) and nothing was decrypted. Press Refresh status to list the drives again, then tick what you want." 'error'
                return
            }
            # data drives first, the Windows drive last
            $order = @(Get-BitLockerDecryptOrder -Volumes $fresh.Volumes -Mounts $mounts)
            $lines = New-Object System.Collections.Generic.List[string]
            foreach ($m in $order) {
                $v = @($fresh.Volumes | Where-Object { $_.MountPoint -eq $m }) | Select-Object -First 1
                if ($v) {
                    # the label and size tell two USB sticks apart, which a bare drive letter cannot
                    $size = ''
                    $gb = 0.0
                    if ([double]::TryParse([string]$v.CapacityGB, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$gb) -and $gb -gt 0) { $size = (', {0:N1} GB' -f $gb) }
                    $lines.Add("  $m   $(Get-BitLockerTypeText -Volume $v -Drive (Get-BitLockerDriveDescription -MountPoint $m))$size, $(Get-BitLockerStateText -Volume $v)")
                }
            }
            # Windows will not decrypt the Windows drive while it holds auto-unlock keys for other drives
            $needClear = (@($fresh.Volumes | Where-Object { $order -contains $_.MountPoint -and $_.VolumeType -eq 'OperatingSystem' -and $_.AutoUnlockKeyStored }).Count -gt 0)
            $osMounts = @($fresh.Volumes | Where-Object { $order -contains $_.MountPoint -and $_.VolumeType -eq 'OperatingSystem' } | ForEach-Object { [string]$_.MountPoint })
            $affected = @(Get-BitLockerAutoUnlockAffected -Volumes $fresh.Volumes -Mounts $order)
            $facts = New-Object System.Collections.Generic.List[string]
            $facts.Add('Decryption runs in the background and can take from minutes to hours. The PC stays usable; keep it on and plugged in. If it restarts, decryption carries on afterwards. You can close this window.')
            $facts.Add('BitLocker protection is already off while a drive decrypts, and when it finishes anyone with physical access to the PC can read the drive without a key.')
            $facts.Add('Windows removes the drive''s key protectors at the end, so the backup becomes your only record of them.')
            if ($needClear) {
                $stay = $(if ($affected.Count -gt 0) { " Drives that stay encrypted ($($affected -join ', ')) will ask for their password or recovery key from then on." } else { '' })
                $facts.Add("The Windows drive holds auto-unlock keys for other drives, and Windows will not decrypt it until they are cleared. They will be cleared first - all of them, including the keys of drives that are not plugged in now (a drive that is not connected is not in this backup, and will ask for its own password or recovery key next time).$stay")
            }
            if ($chkPrevent.IsChecked -and $chkPrevent.IsEnabled -and $osMounts.Count -gt 0) { $facts.Add('As a precaution Windows will also be told not to start automatic device encryption (PreventDeviceEncryption = 1; delete that value to undo). A management policy such as Intune can still re-encrypt the PC.') }
            $cautions = New-Object System.Collections.Generic.List[string]
            $placeNote = Get-BitLockerBackupPlaceNote -Path $state.BackupPath -Volumes $fresh.Volumes -Mounts $order -CloudRoots @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)
            if ($placeNote) { $cautions.Add($placeNote) }
            $noRecovery = @(Get-BitLockerMountsWithoutRecoveryPassword -Volumes $fresh.Volumes -Mounts $order)
            if ($noRecovery.Count -gt 0) { $cautions.Add("No recovery password exists for $($noRecovery -join ', '), so the backup has none for it: if anything went wrong while it decrypts there would be no key to recover with.") }
            foreach ($w in @(Get-BitLockerDecryptWarnings)) { $cautions.Add($w) }
            # what is about to be asked is recorded; if no log can be written anywhere, the person is told before saying Yes
            if (-not (Write-BitLockerActionLog "Decrypt confirmation shown for: $($order -join ', ')" -PassThru)) { $cautions.Add('The action log cannot be written on this PC, so what happens next will not be recorded.') }
            $cautionText =$(if ($cautions.Count -gt 0) { "`r`n`r`nBefore you go on:`r`n- " + ($cautions -join "`r`n- ") } else { '' })
            $msg = "Decrypt these drives now? (data drives first, the Windows drive last)`r`n`r`n$($lines -join "`r`n")`r`n`r`nYour key backup was saved and checked:`r`n$($state.BackupPath)`r`n`r`nWhat happens:`r`n- $($facts -join "`r`n- ")$cautionText"
            $answer = [System.Windows.MessageBox]::Show($dialog, $msg, 'Disable BitLocker', 'YesNo', 'Warning', 'No')
            if ($answer -ne 'Yes') { & $setStatus 'Cancelled - nothing was changed.' 'info'; return }

            $started = New-Object System.Collections.Generic.List[object]
            $failed = New-Object System.Collections.Generic.List[string]
            $clearedAny = $false
            foreach ($m in $order) {
                # Everything that could have changed while the confirmation was open is checked again, right before
                # this drive is touched: the backup file, the keys that exist, and this drive's own keys.
                $again = Test-BitLockerBackupStillGood -Path $state.BackupPath -Hash $state.BackupHash -BackedUpIds $state.BackedUpIds
                if (-not $again.Ok) {
                    if ($again.Stale) { $state.BackupOk = $false }
                    $failed.Add("$m - $($again.Reason)")
                    Write-BitLockerActionLog "Decryption NOT started for $m - $($again.Reason)"
                    continue
                }
                $nowVol = @($again.Volumes | Where-Object { $_.MountPoint -eq $m }) | Select-Object -First 1
                $rowOfM = @($tickedNow | Where-Object { $_.Mount -eq $m }) | Select-Object -First 1
                # still the drive that was listed, backed up and confirmed (key IDs, size, type: the same ones were checked before the confirmation)
                if (-not $nowVol -or -not (Test-BitLockerSameDrive -Identity $(if ($rowOfM) { $rowOfM.Identity } else { $null }) -Volume $nowVol)) {
                    $failed.Add("$m - it changed after you confirmed (a different drive or different keys) - nothing was decrypted. Press Refresh status and start again.")
                    Write-BitLockerActionLog "Decryption NOT started for $m - the drive changed after the confirmation"
                    continue
                }
                # the function reads the drive once more right before it asks Windows (and checks it is still this drive)
                $r = Start-BitLockerDecrypt -MountPoint $m -ClearAutoUnlock:$needClear -ExpectedIdentity $rowOfM.Identity
                # the auto-unlock keys are gone as soon as the clear command ran - whether or not the decrypt then started
                if ($r.ClearedAutoUnlock) { $clearedAny = $true; Write-BitLockerActionLog "Cleared the auto-unlock keys stored on $m" }
                if ($r.Ok) {
                    # Size, type and volume ID follow the drive while it decrypts (its key IDs disappear when it finishes); the
                    # volume ID is the one the drive was confirmed with - the read just now may have failed to get it
                    $followId = $(if ([string]$rowOfM.Identity.VolumeId) { [string]$rowOfM.Identity.VolumeId } else { [string]$nowVol.VolumeId })
                    $started.Add([PSCustomObject]@{ Mount = $m; At = (Get-Date); StartPercent = [int]$nowVol.EncryptionPercentage; Misses = 0; Finished = $null; DoneText = ''; Gone = $false; MissingSeen = $false; Capacity = [string]$nowVol.CapacityGB; VolumeType = [string]$nowVol.VolumeType; VolumeId = $followId })
                    Write-BitLockerActionLog "Decryption started: $m"
                } else {
                    $failed.Add("$m - $($r.Error)")
                    Write-BitLockerActionLog "Decryption NOT started for $m - $($r.Error)"
                }
            }
            $state.FailedNote = $(if ($failed.Count -gt 0) { "Not started: $($failed -join '; ')" } else { '' })
            $startedMounts = @($started | ForEach-Object { $_.Mount })
            # Only once the Windows drive's decryption has really started, and only then: tell Windows not to
            # re-encrypt it by itself. (The setting is read first and not rewritten when it is already 1.)
            $preventNote = ''
            if ($chkPrevent.IsChecked -and $chkPrevent.IsEnabled -and @($osMounts | Where-Object { $startedMounts -contains $_ }).Count -gt 0) {
                $pv = Set-PreventDeviceEncryption
                if ($pv.AlreadySet) { Write-BitLockerActionLog 'PreventDeviceEncryption was already 1 - left as it is' }
                elseif ($pv.Ok) { Write-BitLockerActionLog 'PreventDeviceEncryption set to 1 (it was not 1 before)' }
                else {
                    Write-BitLockerActionLog "Could not set PreventDeviceEncryption: $($pv.Error)"
                    $preventNote = "`r`nCould not set PreventDeviceEncryption ($($pv.Error)), so Windows could start automatic device encryption again at a later sign-in."
                }
            }
            # merge with drives started earlier in this window, so none of them stops being tracked
            $state.Started = @(@($state.Started | Where-Object { $startedMounts -notcontains $_.Mount }) + $started.ToArray())
            & $refresh
            foreach ($row in @($state.Rows)) { if ($startedMounts -contains $row.Mount) { $row.CheckBox.IsEnabled = $false } }
            if ($startedMounts.Count -gt 0) { $timer.Start() }      # nothing started: nothing to follow (and a running timer is already running)
            $clearedNote = $(if ($clearedAny) { "`r`nThe auto-unlock keys stored on the Windows drive WERE cleared, so a drive that is still encrypted will now ask for its password or recovery key." } else { '' })
            # a run that is being followed keeps these two notes for its final status (the status below is replaced when it finishes)
            if ($timer.IsEnabled) { $state.RunNotes = @($state.RunNotes) + @(@($clearedNote, $preventNote) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) }
            if ($failed.Count -gt 0) {
                $startedText = $(if ($startedMounts.Count -gt 0) { "Started: $($startedMounts -join ', ')" } else { 'Nothing was started.' })
                & $setStatus "$startedText`r`nNot started: $($failed -join '; ')$clearedNote$preventNote" 'error'
            } else {
                & $setStatus "Decryption started for $($startedMounts -join ', '). It continues in the background even if you close this window; the list shows progress, and Scan BitLocker Status shows it too. Do not delete the backup file yet, and do not unplug a removable drive.$clearedNote$preventNote" $(if ($preventNote) { 'warn' } else { 'ok' })
            }
        } finally {
            $state.Busy = $false
            & $updateButtons
        }
    }.GetNewClosure())

    $btnShowFile.Add_Click({
        if ($state.BackupPath -and (Test-Path -LiteralPath $state.BackupPath)) { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$($state.BackupPath)`"" }
    }.GetNewClosure())
    $btnClose.Add_Click({ $dialog.Close() }.GetNewClosure())
    $dialog.Add_Loaded({
        # already set (this PC has it) -> say so instead of offering to set it again
        if ((Get-PreventDeviceEncryptionValue) -eq 1) {
            $chkPrevent.IsChecked = $false
            $chkPrevent.IsEnabled = $false
            $chkPrevent.Content.Text = 'Windows is already told not to start automatic device encryption (PreventDeviceEncryption = 1) - nothing to change.'
            $chkPrevent.Content.Foreground = $dialog.FindResource('MutedBrush')     # the label of a disabled box must look disabled
        }
        & $refresh
        # offer a better place for the backup than the Desktop (a ready, unencrypted USB or other drive), unless the person already typed one
        try {
            $folder = Get-BitLockerDefaultBackupFolder -Drives @([System.IO.DriveInfo]::GetDrives()) -Volumes $state.Volumes -WindowsDrive ([string]$env:SystemDrive) -Fallback ''
            if ($folder -and $pathBox.Text -ceq $state.InitialPath) { $pathBox.Text = Join-Path $folder $state.FileName }
        } catch { }
    }.GetNewClosure())
    Write-BitLockerActionLog 'Disable BitLocker dialog opened'
    $dialog.ShowDialog() | Out-Null
}

$btnBitLockerDisable = $window.FindName('BtnBitLockerDisable')
$btnBitLockerDisable.Add_Click({ Show-BitLockerDisableDialog })

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
        "Enable BitLocker on C:?`r`n`r`nOnly proceeds if a ready TPM is present and protection is currently Off. Uses XtsAes256, used-space-only, a TPM protector, and a recovery password protector. On an Entra-joined device the recovery password is backed up to Entra ID automatically; otherwise it is only written to the handoff package below (generate that before handing the machine off - there is no other copy). To turn BitLocker off again later, use Panels > Disable BitLocker... (it backs up every key first).",
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
        "Create local administrator '$accountName' with a random password?`r`n`r`nOn an Entra-joined device, Windows LAPS is configured to manage and rotate this account's password from here. On a non-Entra-joined device the password has no central backup - it is written once to a restricted file (breakglass-admin_<computer>_<serial>.txt) in the work directory, C:\ProgramData\DellOfficeDeploy, and nowhere else. Copy it somewhere safe: the app never deletes it by itself, so delete it yourself once it is stored.",
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

function Get-AppCatalogLayout {
    # How the Install Apps list is laid out: one block per category (alphabetical, as always). A category the catalog gives
    # named groups ("categoryGroups": { "Utilities": [ ... ] }) is split into those groups, in that order; an app of such a
    # category that names no group, or a group that is not in the list, goes last under "Other" so that it is never lost.
    # A category without groups stays one list with no group name. Apps are sorted by name inside every group.
    # A group listed twice is built once, and a listed group named "Other" is that catch-all itself (never a second one).
    param($Catalog)
    $order = @{}
    if ($Catalog.PSObject.Properties['categoryGroups'] -and $Catalog.categoryGroups) {
        foreach ($p in $Catalog.categoryGroups.PSObject.Properties) { $order[[string]$p.Name] = @($p.Value | ForEach-Object { [string]$_ }) }
    }
    $blocks = New-Object System.Collections.Generic.List[object]
    foreach ($cat in @($Catalog.apps | Group-Object category | Sort-Object Name)) {
        $named = @()
        if ($order.ContainsKey([string]$cat.Name)) { $named = @($order[[string]$cat.Name] | Where-Object { $_ -cne 'Other' } | Select-Object -Unique) }
        $groups = New-Object System.Collections.Generic.List[object]
        if ($named.Count -eq 0) {
            $groups.Add([PSCustomObject]@{ Name = ''; Apps = @($cat.Group | Sort-Object name) })
        } else {
            foreach ($g in $named) {
                $apps = @($cat.Group | Where-Object { [string]$_.group -ceq $g } | Sort-Object name)
                if ($apps.Count -gt 0) { $groups.Add([PSCustomObject]@{ Name = $g; Apps = $apps }) }
            }
            $other = @($cat.Group | Where-Object { $named -cnotcontains [string]$_.group } | Sort-Object name)
            if ($other.Count -gt 0) { $groups.Add([PSCustomObject]@{ Name = 'Other'; Apps = $other }) }
        }
        $blocks.Add([PSCustomObject]@{ Category = [string]$cat.Name; Groups = $groups.ToArray() })
    }
    return $blocks.ToArray()
}

foreach ($block in @(Get-AppCatalogLayout -Catalog $catalog)) {
    $header = New-Object System.Windows.Controls.TextBlock
    $header.Text = $block.Category
    $header.FontFamily = 'Consolas'
    $header.FontSize = 16
    $header.Foreground = $headerBrush
    $header.Margin = '0,8,0,4'
    $installAppsPanel.Children.Add($header) | Out-Null

    # A category that is split into named groups (Utilities) gets one block for its heading and one per group, so a group with nothing
    # visible in the current filter hides its own sub-heading; a category without groups is one block.
    $hasGroups = (@($block.Groups | Where-Object { $_.Name }).Count -gt 0)
    if ($hasGroups) { $script:categoryBlocks.Add([PSCustomObject]@{ Header = $header; SubHeader = $null; Wrap = $null; Category = $block.Category; Group = $null }) }

    foreach ($grp in $block.Groups) {
        $subHeader = $null
        if ($grp.Name) {
            $subHeader = New-Object System.Windows.Controls.TextBlock
            $subHeader.Text = $grp.Name
            $subHeader.FontFamily = 'Segoe UI'
            $subHeader.FontSize = 13
            $subHeader.FontWeight = 'SemiBold'
            $subHeader.Foreground = $window.Resources['HintBrush']
            $subHeader.Margin = '3,10,0,2'
            $installAppsPanel.Children.Add($subHeader) | Out-Null
        }

        $wrap = New-Object System.Windows.Controls.WrapPanel
        foreach ($app in $grp.Apps) {
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
            $entry = [PSCustomObject]@{ CheckBox = $cb; Row = $row; Name = $app.name; Category = $block.Category; Group = [string]$grp.Name; WingetId = $app.wingetId; DownloadUrl = $app.downloadUrl; DynamicDownloadPage = $app.dynamicDownloadPage; Url = $app.url; SacRisk = [bool]$app.sacRisk; Msp = ($app.msp -ne $false); CompareMatch = $false }
            $script:appEntries.Add($entry)
            # Checked/Unchecked (not Click) since they fire off IsChecked itself changing,
            # regardless of interaction method - Click alone was observed to not reliably
            # fire for every path that can toggle a CheckBox.
            $cb.Add_Checked({ Update-SelectedCount })
            $cb.Add_Unchecked({ Update-SelectedCount })
        }
        $installAppsPanel.Children.Add($wrap) | Out-Null
        if ($hasGroups) { $script:categoryBlocks.Add([PSCustomObject]@{ Header = $null; SubHeader = $subHeader; Wrap = $wrap; Category = $block.Category; Group = [string]$grp.Name }) }
        else { $script:categoryBlocks.Add([PSCustomObject]@{ Header = $header; SubHeader = $null; Wrap = $wrap; Category = $block.Category; Group = $null }) }
    }
}

function Update-SelectedCount {
    # @() around the pipeline: a single match has no .Count in Windows PowerShell 5.1, so
    # exactly one ticked app used to read "Selected: " with no number.
    $count = @($script:appEntries | Where-Object { $_.CheckBox.IsChecked }).Count
    $selectedCountText.Text = "Selected: $count"
}

# Business Baseline is the default filter (improvement-plan.md 3.11) - a client-laptop
# tech sees the safe-for-business subset first and has to deliberately switch to All to
# reach things like Tor Browser or qBittorrent, rather than seeing everything by default.
$script:activeCategory = 'Business Baseline'

function Update-AppVisibility {
    # A block is a category's heading (Group $null, no Wrap, when the category is split into groups), one group of a split category,
    # or a whole category without groups. Each is visible only while one of its apps is.
    foreach ($block in $script:categoryBlocks) {
        $anyVisible = $false
        foreach ($entry in ($script:appEntries | Where-Object { $_.Category -eq $block.Category -and ($null -eq $block.Group -or $_.Group -ceq $block.Group) })) {
            $visible =
                if ($script:activeCategory -eq 'All') { $true }
                elseif ($script:activeCategory -eq 'Business Baseline') { $entry.Msp }
                elseif ($script:activeCategory -eq 'Compare Results') { $entry.CompareMatch }
                else { $block.Category -eq $script:activeCategory }
            $entry.Row.Visibility = if ($visible) { 'Visible' } else { 'Collapsed' }
            if ($visible) { $anyVisible = $true }
        }
        $blockVisibility = if ($anyVisible) { 'Visible' } else { 'Collapsed' }
        if ($block.Header) { $block.Header.Visibility = $blockVisibility }
        if ($block.SubHeader) { $block.SubHeader.Visibility = $blockVisibility }
        if ($block.Wrap) { $block.Wrap.Visibility = $blockVisibility }
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

# Two small REST calls (token + warranty lookup), not a multi-minute job - run inline on
# the UI thread rather than a background runspace, same call this codebase already makes
# for the FreeFileSync dynamicDownloadPage fetch (a brief pause is an acceptable tradeoff
# against a full extra async stage for something this quick).
$btnCheckReplacement.Add_Click({
    $btnCheckReplacement.IsEnabled = $false
    try {
        $fixesLogBox.AppendText("=== Checking replacement eligibility ===`r`n")
        $fixesLogBox.ScrollToEnd()

        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
        $mfr = if ($cs -and $cs.Manufacturer) { $cs.Manufacturer } else { '' }
        if ($mfr -notmatch 'Dell') {
            $fixesLogBox.AppendText("This machine's manufacturer is '$mfr' - automatic ship-date lookup currently only supports Dell (service tag via the Dell TechDirect API). Use manual judgment for this machine.`r`n`r`n")
            $fixesLogBox.ScrollToEnd()
            return
        }
        $serviceTag = if ($bios -and $bios.SerialNumber) { $bios.SerialNumber } else { $null }
        if (-not $serviceTag) {
            $fixesLogBox.AppendText("Could not read a BIOS serial number (service tag) from this machine.`r`n`r`n")
            $fixesLogBox.ScrollToEnd()
            return
        }

        $result = Get-DellReplacementEligibility -ServiceTag $serviceTag
        if (-not $result.Success) {
            $fixesLogBox.AppendText("$($result.Message)`r`n`r`n")
        } else {
            $fixesLogBox.AppendText("Service tag: $($result.ServiceTag)`r`n")
            if ($result.Model) { $fixesLogBox.AppendText("Model: $($result.Model)`r`n") }
            $fixesLogBox.AppendText("Ship date: $($result.ShipDate.ToString('yyyy-MM-dd')) ($($result.AgeYears) years old)`r`n")
            $fixesLogBox.AppendText("Recommendation: $($result.Recommendation)`r`n`r`n")
        }
        $fixesLogBox.ScrollToEnd()
    } finally {
        $btnCheckReplacement.IsEnabled = $true
    }
})

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
# Every return uses the unary comma: PowerShell unrolls a collection on return, so an EMPTY
# set came back as $null (and a one-id set as a bare [string]), which broke the callers'
# .Contains() - a Stop during a scan threw dozens of hidden errors, and a Compare against an
# empty `winget list` ticked apps that were already installed here.
function Get-WingetListedIds {
    param([string]$Path)
    $ids = New-Object 'System.Collections.Generic.HashSet[string]'
    if (-not $Path -or -not (Test-Path $Path)) { return , $ids }
    $lines = Get-Content -Path $Path -ErrorAction SilentlyContinue
    $headerIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^Name\s+Id\s+Version') { $headerIndex = $i; break }
    }
    if ($headerIndex -lt 0 -or $headerIndex + 1 -ge $lines.Count) { return , $ids }
    $header = $lines[$headerIndex]
    $idCol = $header.IndexOf('Id')
    $versionCol = $header.IndexOf('Version')
    if ($idCol -lt 0 -or $versionCol -lt 0 -or $versionCol -le $idCol) { return , $ids }
    for ($i = $headerIndex + 2; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $line -or $line.Length -le $idCol) { continue }
        if ($line -match '^\d+ package') { continue }
        $endCol = [Math]::Min($versionCol, $line.Length)
        $id = $line.Substring($idCol, $endCol - $idCol).Trim()
        if ($id) { [void]$ids.Add($id) }
    }
    return , $ids
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

# Matches Export-InstalledApps.ps1's own $RelayUrl default - keep both in sync.
$script:ExportRelayUrl = 'https://gr3y-export-relay.gr3y-b8f.workers.dev'

# Access codes, kept in memory only so a second pairing/management action in the same run
# doesn't ask again. Never written to disk: this mostly runs on client machines, where a
# saved code would be left behind. On a machine you own, set GR3Y_RELAY_ACCESS_KEY to skip
# the pairing prompt.
#   Access = the code (admin or guest) that unlocked pairing
#   Admin  = the admin code, used only for Manage Access Codes - kept separate so a guest
#            code cached for pairing is never sent to an admin route as if it were the admin key
# This is ONE shared object, not two $script: variables, on purpose: dialog event handlers are
# built with .GetNewClosure(), and inside a closure `$script:` points at the closure's own
# module scope, not this file's. A handler that captures a reference to this object (see
# Show-AccessCodesDialog) mutates the same object everyone else sees.
$script:RelayKeys = [PSCustomObject]@{ Access = $env:GR3Y_RELAY_ACCESS_KEY; Admin = $null }
$script:RelayOutdatedText = "The pairing relay hasn't been updated for access codes yet. Ask whoever runs it to deploy the new Worker (cloudflare/README.md has the steps), or use Load a File or Pasted List for now."
$script:RelayBadKeyText = 'That code contains a character that cannot be sent (a typographic dash or an invisible character?). Retype it using plain letters, digits and hyphens.'

function New-PairingCode {
    # Unambiguous alphabet (no 0/O, 1/I/L) - meant to be read aloud over a phone or typed
    # into an RMM console without confusion. With the access gate, this 6-char code is the
    # only secret protecting /submit for an open slot, so it is generated without modulo
    # bias: 256 is not a multiple of 31, so a plain byte % 31 would make the first 8 symbols
    # 12.5% more likely. Reject bytes >= 248 (248 = 31 * 8) so every symbol is equally likely.
    $alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $out = New-Object System.Text.StringBuilder
    $buf = New-Object byte[] 12
    while ($out.Length -lt 6) {
        $rng.GetBytes($buf)
        foreach ($b in $buf) {
            if ($b -lt 248 -and $out.Length -lt 6) { [void]$out.Append($alphabet[$b % 31]) }
        }
    }
    $rng.Dispose()
    $out.ToString()
}

function Invoke-RelayRequest {
    # One HTTP call to the relay -> { Status; Text; Error }. Status is the HTTP status code,
    # or 0 when there was no HTTP response at all (DNS/TLS/connect failure or timeout).
    # Works the same in Windows PowerShell 5.1 and PowerShell 7: [int]$_.Exception.Response.StatusCode
    # is valid in both (HttpWebResponse vs HttpResponseMessage), and the body is decoded as
    # UTF-8 from RawContentStream because 5.1's Invoke-RestMethod decodes a charset-less
    # application/json response as ISO-8859-1. Parameterised on $RelayUrl (no $script: reads)
    # so it can be injected into the polling runspace.
    param(
        [Parameter(Mandatory)][string]$RelayUrl,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Headers = @{},
        [int]$TimeoutSec = 10
    )
    try {
        $response = Invoke-WebRequest -Uri "$RelayUrl$Path" -Method $Method -Headers $Headers -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        $stream = New-Object System.IO.MemoryStream
        $response.RawContentStream.CopyTo($stream)
        return [PSCustomObject]@{ Status = [int]$response.StatusCode; Text = [System.Text.Encoding]::UTF8.GetString($stream.ToArray()); Error = $null }
    } catch {
        $err = $_
        $status = 0
        try { $status = [int]$err.Exception.Response.StatusCode } catch {}
        # Best-effort server message for an HTTP error (e.g. 503 "Admin access is not
        # configured ..."): PowerShell 7 puts the body in ErrorDetails; Windows PowerShell 5.1
        # needs the response stream read. Never throws - a missing body just stays $null.
        $body = $null
        try {
            if ($err.ErrorDetails -and $err.ErrorDetails.Message) {
                $body = $err.ErrorDetails.Message
            } elseif ($err.Exception.Response -and ($err.Exception.Response | Get-Member -Name GetResponseStream -ErrorAction SilentlyContinue)) {
                $sr = New-Object System.IO.StreamReader($err.Exception.Response.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $body = $sr.ReadToEnd()
                $sr.Dispose()
            }
        } catch {}
        return [PSCustomObject]@{ Status = $status; Text = $body; Error = $err.Exception.Message }
    }
}

function Test-RelayGated {
    # Cheap, zero-KV-cost probe to tell the access-gated Worker from the old anonymous one
    # BEFORE asking the user for a code: GET /admin/keys with no key is 401 on the new Worker
    # (admin required) and 400 on the old one (it only knows ?code=). Returns $true (gated),
    # $false (old Worker), or $null (could not tell - network error).
    param([Parameter(Mandatory)][string]$RelayUrl)
    # Short timeout: this runs on the UI thread before any dialog is shown, so a relay that
    # accepts the connection but never answers would otherwise freeze the window for the
    # whole timeout.
    $r = Invoke-RelayRequest -RelayUrl $RelayUrl -Method 'GET' -Path '/admin/keys' -TimeoutSec 8
    if ($r.Status -eq 401 -or $r.Status -eq 503) { return $true }
    if ($r.Status -eq 400 -or $r.Status -eq 404) { return $false }
    return $null
}

function ConvertTo-RelayKey {
    # Cleans a typed or pasted access code so it can ride in an HTTP header. Pasting from chat,
    # Word or a PDF often swaps the hyphens for look-alike dashes (U+2010..U+2015, U+2212) or
    # adds invisible characters, and .NET refuses a header value with anything above U+00FF -
    # that used to surface as "could not reach the relay" and stick until the GUI restarted.
    # Maps those dashes back to '-', turns non-breaking spaces into plain ones, drops zero-width
    # and direction-mark characters, trims, and returns $null if nothing was typed or anything
    # other than printable ASCII is left. Works on code points (not a regex with escapes) so
    # this file stays pure ASCII.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x2010 -and $c -le 0x2015) -or $c -eq 0x2212 -or $c -eq 0xFE58 -or $c -eq 0xFE63 -or $c -eq 0xFF0D) {
            [void]$sb.Append('-')
        } elseif ($c -eq 0xA0 -or $c -eq 0x2007 -or $c -eq 0x202F) {
            [void]$sb.Append(' ')
        } elseif (($c -ge 0x200B -and $c -le 0x200F) -or ($c -ge 0x202A -and $c -le 0x202E) -or $c -eq 0x2060 -or $c -eq 0xFEFF) {
            # zero-width / direction marks: drop
        } else {
            [void]$sb.Append($ch)
        }
    }
    $t = $sb.ToString().Trim()
    if ($t -notmatch '^[\x20-\x7E]+\z') { return $null }
    return $t
}

function ConvertFrom-RelayKeyList {
    # Parses the GET /admin/keys response (a JSON array of guest-code records) into a real
    # array. Windows PowerShell 5.1's ConvertFrom-Json emits a JSON array as ONE pipeline
    # object, so `@($text | ConvertFrom-Json)` is a one-element array holding the whole list:
    # an empty relay showed a phantom blank row and two or more codes collapsed into one
    # garbled row. Assigning first and enumerating with foreach is right in 5.1 and 7, for
    # 0, 1 or many records. An unparseable body, or a record without a key, yields nothing.
    # Always returns an array (the leading comma stops an empty one unrolling to $null).
    param([string]$Json)
    $parsed = $null
    try { $parsed = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return , @() }
    $rows = New-Object System.Collections.ArrayList
    foreach ($rec in $parsed) {
        if ($rec -and $rec.key) { [void]$rows.Add($rec) }
    }
    return , $rows.ToArray()
}

function Get-GuestRowInfo {
    # Display facts for one guest-code record from the relay: the state word (On / Off /
    # Expired), the expiry as local time or "Never", and whether it has expired. Pure, so it can
    # be unit-tested. A relay that predates the expiry feature sends no expires / expired
    # fields: those codes simply never expire.
    param($Rec)
    $names = @($Rec.PSObject.Properties | ForEach-Object { $_.Name })
    $expiresMs = $null
    if (($names -contains 'expires') -and $null -ne $Rec.expires) {
        try { $expiresMs = [long]$Rec.expires } catch { $expiresMs = $null }
    }
    $expired = ($names -contains 'expired') -and ($Rec.expired -eq $true)
    $enabled = ($Rec.enabled -eq $true)
    $state = if ($expired) { 'Expired' } elseif ($enabled) { 'On' } else { 'Off' }
    $text = 'Never'
    if ($null -ne $expiresMs) {
        try {
            $text = [System.DateTimeOffset]::FromUnixTimeMilliseconds($expiresMs).LocalDateTime.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        } catch {
            $text = 'Invalid'
            $expiresMs = $null
        }
    }
    # Refused, but no time that can be shown (absent, damaged, or out of range): it needs an expiry.
    if ($expired -and $null -eq $expiresMs) { $text = 'Needs expiry' }
    # Expired but not lapsed: no usable time, or - for a code under 8 characters - one well in the future
    # (more than 10 minutes, so a clock difference cannot cause it). The relay refuses such a code for
    # another reason (a short code needs an expiry within a day), and "has expired" would be the wrong
    # thing to say. A longer code with a usable time can only have lapsed. A record without a key counts as short.
    $codeLength = $(if ($names -contains 'key') { ([string]$Rec.key -replace '[^A-Za-z0-9]', '').Length } else { 0 })
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $needsExpiry = $expired -and (($null -eq $expiresMs) -or ($codeLength -lt 8 -and $expiresMs -gt ($nowMs + 600000)))
    return [PSCustomObject]@{ State = $state; Expires = $text; ExpiresMs = $expiresMs; Expired = $expired; NeedsExpiry = $needsExpiry; Enabled = $enabled }
}

function ConvertTo-GuestCodeText {
    # Cleans a guest code the owner typed. Blank is allowed (= let the relay make a random one).
    # Letters and digits only; spaces and dashes are ignored; case does not matter (the relay
    # stores it upper-case). Returns { Ok; Code; Error }. The same rules the relay applies.
    param([string]$Text)
    $typed = $(if ($null -eq $Text) { '' } else { $Text.Trim() })
    if ($typed -eq '') { return [PSCustomObject]@{ Ok = $true; Code = ''; Error = $null } }
    # -cnotmatch, not -notmatch: the case-insensitive operator also lets U+212A (Kelvin sign) and
    # U+0130 through as "letters", and the relay would then refuse them with a different message.
    if ($typed -cnotmatch '^[A-Za-z0-9 \-]+\z') {
        return [PSCustomObject]@{ Ok = $false; Code = ''; Error = 'Use only letters and digits in a code (spaces and dashes are ignored).' }
    }
    $code = ($typed -replace '[ \-]', '').ToUpperInvariant()
    if ($code.Length -lt 4) { return [PSCustomObject]@{ Ok = $false; Code = ''; Error = 'A code needs at least 4 letters or digits.' } }
    if ($code.Length -gt 32) { return [PSCustomObject]@{ Ok = $false; Code = ''; Error = 'A code can be at most 32 letters or digits.' } }
    return [PSCustomObject]@{ Ok = $true; Code = $code; Error = $null }
}

function ConvertTo-HoursQuery {
    # A number of hours as the invariant-culture text the relay's ?hours= expects (a comma
    # decimal separator from another locale would be read as garbage). 0 means never expires.
    param([double]$Hours)
    return $Hours.ToString('0.######', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Start-RelayPairing {
    # Opens a fresh pairing code with the access code. Retries a new code on 409 (collision)
    # up to 3 times. Failure reasons: 'auth' (401), 'locked' (429 - too many wrong codes from this
    # connection), 'badkey' (the code holds characters that
    # cannot go in a header - nothing was sent), 'outdated' (404 - old Worker has no /open),
    # 'network' (no HTTP response), 'busy' (3 collisions), 'server' (anything else, incl. 503).
    # NOTE: no `continue` inside a switch here - in PowerShell that continues the SWITCH, not
    # the enclosing loop, so this uses if/elseif.
    param([Parameter(Mandatory)][string]$RelayUrl, [Parameter(Mandatory)][string]$AccessKey)
    # .NET throws on a header value outside printable ASCII before anything is sent, which
    # would otherwise read as "relay unreachable" - catch it here so the caller can re-prompt.
    if ($AccessKey -notmatch '^[\x20-\x7E]+\z') {
        return [PSCustomObject]@{ Ok = $false; Failure = 'badkey'; Message = 'The access code contains a character that cannot be sent.'; Attempts = 0 }
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $code = New-PairingCode
        $r = Invoke-RelayRequest -RelayUrl $RelayUrl -Method 'POST' -Path "/open?code=$code" -Headers @{ 'X-Access-Key' = $AccessKey }
        if ($r.Status -eq 200) {
            $o = $null
            try { $o = $r.Text | ConvertFrom-Json -ErrorAction Stop } catch {}
            if (-not $o -or -not $o.session) {
                return [PSCustomObject]@{ Ok = $false; Failure = 'server'; Message = 'The relay answered 200 but without a session.'; Attempts = $attempt }
            }
            return [PSCustomObject]@{ Ok = $true; Code = $code; Session = [string]$o.session; Label = [string]$o.label; Attempts = $attempt }
        }
        if ($r.Status -eq 401) { return [PSCustomObject]@{ Ok = $false; Failure = 'auth'; Message = 'The access code was not accepted (wrong, switched off or expired).'; Attempts = $attempt } }
        if ($r.Status -eq 404) { return [PSCustomObject]@{ Ok = $false; Failure = 'outdated'; Message = $script:RelayOutdatedText; Attempts = $attempt } }
        if ($r.Status -eq 429) { return [PSCustomObject]@{ Ok = $false; Failure = 'locked'; Message = 'Too many wrong access codes from this connection.'; Attempts = $attempt } }
        if ($r.Status -eq 0) { return [PSCustomObject]@{ Ok = $false; Failure = 'network'; Message = $r.Error; Attempts = $attempt } }
        if ($r.Status -ne 409) { return [PSCustomObject]@{ Ok = $false; Failure = 'server'; Message = "The relay answered HTTP $($r.Status)."; Attempts = $attempt } }
        # 409 = this code is already open elsewhere; loop and try a brand new code.
    }
    return [PSCustomObject]@{ Ok = $false; Failure = 'busy'; Message = 'Could not get an unused pairing code after 3 tries.'; Attempts = 3 }
}

function Wait-RelayExport {
    # Poll loop for the background runspace. 404 = nothing yet (keep waiting). 401 = the
    # session is no longer valid (stop). Anything else is a transient failure: keep going but
    # surface it through the shared $State hashtable so the UI timer can show "relay
    # unreachable, still trying". Returns Kind = data | session | invalid | timeout.
    param(
        [Parameter(Mandatory)][string]$RelayUrl,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Session,
        [int]$TimeoutSeconds = 600,
        [int]$IntervalSeconds = 5,
        [hashtable]$State
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-RelayRequest -RelayUrl $RelayUrl -Method 'GET' -Path "/poll?code=$Code" -Headers @{ 'X-Session' = $Session } -TimeoutSec 15
        if ($r.Status -eq 200) {
            try { return [PSCustomObject]@{ Kind = 'data'; Data = ($r.Text | ConvertFrom-Json -ErrorAction Stop); Detail = $null } }
            catch { return [PSCustomObject]@{ Kind = 'invalid'; Data = $null; Detail = 'The relay returned something that is not valid JSON.' } }
        }
        if ($r.Status -eq 401) { return [PSCustomObject]@{ Kind = 'session'; Data = $null; Detail = 'The relay no longer recognises this pairing session.' } }
        if ($r.Status -eq 404) {
            if ($State) { $State.Message = $null }
        } else {
            $lastError = if ($r.Error) { $r.Error } else { "HTTP $($r.Status)" }
            if ($State) { $State.Message = "Relay not reachable ($lastError) - still trying." }
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
    return [PSCustomObject]@{ Kind = 'timeout'; Data = $null; Detail = $lastError }
}

function Show-PromptDialog {
    # A small themed input prompt (its own XAML tree, like the other dialogs). -Secret uses a
    # PasswordBox so the code isn't shown or captured; otherwise a plain TextBox (used for the
    # guest-code label). Returns the entered string, or $null on Cancel/Esc. The two dialogs'
    # shared TextBox style forces IsReadOnly=True, so this dialog declares its own input styles.
    param(
        [string]$Title = 'Access Code',
        [string]$Message = 'Enter the access code you were given to pair with an old machine.',
        [switch]$Secret,
        [string]$ErrorText,
        [string]$DefaultText,
        # The window to centre on and sit above. Defaults to the main window; a prompt raised
        # from inside another dialog (Manage Access Codes) passes that dialog instead.
        [System.Windows.Window]$Owner
    )
    $dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Access Code" Width="480" Height="300" MinWidth="420" MinHeight="250"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize" ShowInTaskbar="False"
        Background="#232629" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <SolidColorBrush x:Key="BgBrush" Color="#232629"/>
    <SolidColorBrush x:Key="ButtonBrush" Color="#1E3747"/>
    <SolidColorBrush x:Key="ButtonHoverBrush" Color="#2A4C69"/>
    <SolidColorBrush x:Key="ControlBorderBrush" Color="#707070"/>
    <SolidColorBrush x:Key="TextBrush" Color="#F7F7F7"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#9AA3AB"/>
    <SolidColorBrush x:Key="HeaderBrush" Color="#5BDCFF"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#5BDCFF"/>
    <SolidColorBrush x:Key="ErrorBrush" Color="#F85149"/>
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
              <Trigger Property="IsDefault" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource LogBgBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontFamily" Value="Consolas"/>
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
    <Style TargetType="PasswordBox">
      <Setter Property="Background" Value="{StaticResource LogBgBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="SelectionBrush" Value="{StaticResource NavSelectedBrush}"/>
      <Setter Property="CaretBrush" Value="{StaticResource TextBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
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
      <TextBlock Name="PromptTitle" Text="Access Code" FontFamily="Consolas" FontSize="16" Foreground="{StaticResource HeaderBrush}" Margin="0,0,0,10"/>
      <TextBlock Name="PromptMessage" TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" Margin="0,0,0,12"
                 Text="Enter the access code you were given to pair with an old machine."/>
      <PasswordBox Name="SecretBox" MinHeight="32" VerticalContentAlignment="Center"/>
      <TextBox Name="PlainBox" MinHeight="32" VerticalContentAlignment="Center" Visibility="Collapsed"/>
      <TextBlock Name="PromptError" TextWrapping="Wrap" Foreground="{StaticResource ErrorBrush}" Margin="0,8,0,0" Visibility="Collapsed"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
        <Button Name="BtnPromptOk" Content="OK" Width="90" IsDefault="True" Margin="0,0,8,0"/>
        <Button Name="BtnPromptCancel" Content="Cancel" Width="90" IsCancel="True"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($dialogXaml))
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    $dialog.Owner = $(if ($Owner) { $Owner } else { $window })
    $dialog.Title = $Title

    $dialog.FindName('PromptTitle').Text = $Title
    $dialog.FindName('PromptMessage').Text = $Message
    $secretBox = $dialog.FindName('SecretBox')
    $plainBox = $dialog.FindName('PlainBox')
    $promptError = $dialog.FindName('PromptError')
    $btnOk = $dialog.FindName('BtnPromptOk')
    $btnCancel = $dialog.FindName('BtnPromptCancel')

    if ($Secret) {
        $plainBox.Visibility = 'Collapsed'
        $secretBox.Visibility = 'Visible'
    } else {
        $secretBox.Visibility = 'Collapsed'
        $plainBox.Visibility = 'Visible'
        if ($DefaultText) { $plainBox.Text = $DefaultText }
    }
    if ($ErrorText) {
        $promptError.Text = $ErrorText
        $promptError.Visibility = 'Visible'
    }

    $resultHolder = [PSCustomObject]@{ Value = $null }
    $btnOk.Add_Click({
        $entered = $(if ($Secret) { $secretBox.Password } else { $plainBox.Text })
        if ([string]::IsNullOrWhiteSpace($entered)) {
            # Stay open and say so: closing on an empty box read as "the click did nothing".
            $promptError.Text = $(if ($Secret) { 'Enter the access code first, or press Cancel.' } else { 'Type something first, or press Cancel.' })
            $promptError.Visibility = 'Visible'
            return
        }
        $resultHolder.Value = $entered
        if ($Secret) { $secretBox.Clear() }
        $dialog.Close()
    }.GetNewClosure())
    $btnCancel.Add_Click({ if ($Secret) { $secretBox.Clear() }; $dialog.Close() }.GetNewClosure())

    # A pre-filled value (the Custom Expiry prompt's "24") is selected, so typing replaces it. Left
    # unselected the caret sits in front of it, and typing 48 gave "4824" - about 200 days.
    $dialog.Add_Loaded({
        if ($Secret) { $secretBox.Focus() } else { $plainBox.Focus(); if ($plainBox.Text) { $plainBox.SelectAll() } }
    }.GetNewClosure())
    $dialog.ShowDialog() | Out-Null
    # Empty string counts as cancel (nothing typed), so callers only get a non-empty code.
    if ([string]::IsNullOrEmpty($resultHolder.Value)) { return $null }
    return $resultHolder.Value
}

function Get-RelayAccessKey {
    # Returns the pairing access key: the in-memory cached one (from GR3Y_RELAY_ACCESS_KEY or a
    # previous prompt this run), or prompts for it. Kept in memory ONLY - never written to disk,
    # since this mostly runs on client machines. -ErrorText re-prompts after a rejected key.
    param([string]$Message = 'Enter the access code (admin or a guest code) to generate a pairing code. It is kept in memory only for this session and never written to disk.', [string]$ErrorText)
    if (-not $ErrorText -and -not [string]::IsNullOrEmpty($script:RelayKeys.Access)) {
        # A cached key (typed earlier, or from GR3Y_RELAY_ACCESS_KEY, which is typed by hand
        # too) goes through the same clean-up; one that cannot be repaired is dropped and the
        # user is asked again with an explanation instead of failing the same way every time.
        $cached = ConvertTo-RelayKey -Text $script:RelayKeys.Access
        if ($cached) { $script:RelayKeys.Access = $cached; return $cached }
        $script:RelayKeys.Access = $null
        $ErrorText = $script:RelayBadKeyText
    }
    for ($asked = 0; $asked -lt 3; $asked++) {
        $entered = Show-PromptDialog -Title 'Access Code' -Message $Message -Secret -ErrorText $ErrorText
        if ([string]::IsNullOrEmpty($entered)) { return $null }
        $clean = ConvertTo-RelayKey -Text $entered
        if ($clean) { $script:RelayKeys.Access = $clean; return $clean }
        $ErrorText = $script:RelayBadKeyText
    }
    return $null
}

function Show-CompareSourceChooser {
    # One dialog for the whole "get the old machine's list here" question - this used to be
    # split across a separate "No GUI access?" button/dialog (the command-line export
    # commands) and this chooser (file vs pairing code), which read as two unrelated
    # features when it's really one flow. Themed as its own XAML tree, same as the other
    # dialogs, since it can't share the main window's resources.
    $dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Compare Against an Old Machine" Width="660" Height="600" MinWidth="520" MinHeight="460"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="#232629" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <SolidColorBrush x:Key="BgBrush" Color="#232629"/>
    <SolidColorBrush x:Key="ButtonBrush" Color="#1E3747"/>
    <SolidColorBrush x:Key="ButtonHoverBrush" Color="#2A4C69"/>
    <SolidColorBrush x:Key="ControlBorderBrush" Color="#707070"/>
    <SolidColorBrush x:Key="TextBrush" Color="#F7F7F7"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#9AA3AB"/>
    <SolidColorBrush x:Key="HeaderBrush" Color="#5BDCFF"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#5BDCFF"/>
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
  <ScrollViewer VerticalScrollBarVisibility="Auto">
  <Border Padding="20">
    <StackPanel>
      <TextBlock Text="Compare Against an Old Machine" FontFamily="Consolas" FontSize="16" Foreground="{StaticResource HeaderBrush}" Margin="0,0,0,10"/>
      <TextBlock TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" Margin="0,0,0,14"
                 Text="Checks off every catalog app that's installed on the old machine but missing here. Pick how the old machine's list gets here:"/>

      <Button Name="BtnChoosePair" AutomationProperties.Name="Generate a Pairing Code (needs an access code)" HorizontalAlignment="Stretch" Margin="0,0,0,8" BorderBrush="{StaticResource AccentBrush}">
        <StackPanel Margin="0,4">
          <TextBlock Text="Generate a Pairing Code..." FontWeight="Bold" HorizontalAlignment="Center"/>
          <TextBlock Text="Easiest - run one command on the old machine and its list arrives here by itself. No file. Needs an access code." Foreground="{StaticResource MutedBrush}" FontSize="12" HorizontalAlignment="Center" TextWrapping="Wrap" TextAlignment="Center" Margin="0,2,0,0"/>
        </StackPanel>
      </Button>
      <Button Name="BtnChooseFile" AutomationProperties.Name="Load a File or Pasted List" HorizontalAlignment="Stretch" Margin="0,0,0,18">
        <StackPanel Margin="0,4">
          <TextBlock Text="Load a File or Pasted List..." FontWeight="Bold" HorizontalAlignment="Center"/>
          <TextBlock Text="An Export Installed Apps file, or a plain-text list (one app name per line, or a pasted DisplayName/DisplayVersion table)." Foreground="{StaticResource MutedBrush}" FontSize="12" TextWrapping="Wrap" TextAlignment="Center" Margin="0,2,0,0"/>
        </StackPanel>
      </Button>

      <Border BorderBrush="{StaticResource PanelBorderBrush}" BorderThickness="0,1,0,0" Padding="0,14,0,0">
        <StackPanel>
          <TextBlock Text="Old machine has no GUI to run this on?" FontWeight="Bold" Margin="0,0,0,4"/>
          <TextBlock TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" Margin="0,0,0,10"
                     Text="Make the file from its command line instead - RMM run-script, PowerShell remoting, winrs, anything that can run a PowerShell command. Then use Load a File above."/>

          <TextBlock Text="Print the list to the console (copy the output into a .json file):" Margin="0,0,0,4"/>
          <Grid Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox Name="CmdPrint" Grid.Column="0" MinHeight="32" VerticalContentAlignment="Center" TextWrapping="NoWrap" HorizontalScrollBarVisibility="Auto"/>
            <Button Name="BtnCopyPrint" Grid.Column="1" Content="Copy" Width="70" Height="32" Margin="8,0,0,0"/>
          </Grid>

          <TextBlock Text="Or save it straight to a file on that machine:" Margin="0,0,0,4"/>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox Name="CmdFile" Grid.Column="0" MinHeight="32" VerticalContentAlignment="Center" TextWrapping="Wrap" VerticalScrollBarVisibility="Disabled" HorizontalScrollBarVisibility="Disabled"/>
            <Button Name="BtnCopyFile" Grid.Column="1" Content="Copy" Width="70" Height="32" Margin="8,0,0,0" VerticalAlignment="Top"/>
          </Grid>
        </StackPanel>
      </Border>

      <DockPanel Margin="0,18,0,0" LastChildFill="False">
        <Button Name="BtnChooseManage" Content="Manage Access Codes..." Width="180" DockPanel.Dock="Left"/>
        <Button Name="BtnChooseCancel" Content="Cancel" Width="90" DockPanel.Dock="Right"/>
      </DockPanel>
    </StackPanel>
  </Border>
  </ScrollViewer>
</Window>
'@
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($dialogXaml))
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    $dialog.Owner = $window

    $btnChooseFile = $dialog.FindName('BtnChooseFile')
    $btnChoosePair = $dialog.FindName('BtnChoosePair')
    $btnChooseManage = $dialog.FindName('BtnChooseManage')
    $btnChooseCancel = $dialog.FindName('BtnChooseCancel')
    $cmdPrint = $dialog.FindName('CmdPrint')
    $cmdFile = $dialog.FindName('CmdFile')
    $btnCopyPrint = $dialog.FindName('BtnCopyPrint')
    $btnCopyFile = $dialog.FindName('BtnCopyFile')

    $cmdPrint.Text = 'irm get.gr3y.io/debloat-export | iex'
    # One line, `;`-separated, not two lines joined by a newline - a lot of RMM "run
    # command" fields are single-line text inputs, and even in a real console, pasting
    # two lines runs each as its own separate paste-and-Enter instead of one atomic paste.
    $cmdFile.Text = "`$s = irm get.gr3y.io/debloat-export; & ([scriptblock]::Create(`$s)) -OutputPath C:\Temp\installed-apps.json"

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

    $resultHolder = [PSCustomObject]@{ Value = $null }
    $btnChooseFile.Add_Click({ $resultHolder.Value = 'file'; $dialog.Close() }.GetNewClosure())
    $btnChoosePair.Add_Click({ $resultHolder.Value = 'pair'; $dialog.Close() }.GetNewClosure())
    $btnChooseManage.Add_Click({ $resultHolder.Value = 'manage'; $dialog.Close() }.GetNewClosure())
    $btnChooseCancel.Add_Click({ $dialog.Close() }.GetNewClosure())

    $dialog.ShowDialog() | Out-Null
    return $resultHolder.Value
}

function Show-CodeDialog {
    # One dialog for creating a guest code (Mode 'new') and for changing one (Mode 'edit'): the
    # label, the code itself (blank = a random one when creating, "keep it" when editing) and
    # how long it lasts. Clicking an expiry button finishes the dialog, after the entries are
    # checked; "Keep current expiry" (edit only) leaves the expiry alone. Returns $null when
    # cancelled, else { Label; Code; Hours; Keep }: Code is '' for blank, Hours is a number
    # (0 = never) or $null with Keep. A code under 8 characters can be guessed, so it must
    # expire within 24 hours - the relay enforces that too; checking here means the owner is
    # told before anything is sent. Its own XAML tree, like the other dialogs.
    param(
        [ValidateSet('new', 'edit')][string]$Mode = 'new',
        [string]$Title = 'Guest Code',
        [string]$Message,
        [string]$CurrentCode,
        [string]$CurrentExpiry,
        [double]$CurrentRemainingHours = -1,
        # The code being edited has already expired: "keep the expiry" would leave it unusable, so
        # that button is not offered and Enter picks 1 day instead.
        [switch]$CurrentExpired,
        [System.Windows.Window]$Owner
    )
    $dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Guest Code" Width="560" Height="610" MinWidth="520" MinHeight="500"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize" ShowInTaskbar="False"
        Background="#232629" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <SolidColorBrush x:Key="BgBrush" Color="#232629"/>
    <SolidColorBrush x:Key="ButtonBrush" Color="#1E3747"/>
    <SolidColorBrush x:Key="ButtonHoverBrush" Color="#2A4C69"/>
    <SolidColorBrush x:Key="ControlBorderBrush" Color="#707070"/>
    <SolidColorBrush x:Key="TextBrush" Color="#F7F7F7"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#9AA3AB"/>
    <SolidColorBrush x:Key="HeaderBrush" Color="#5BDCFF"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#5BDCFF"/>
    <SolidColorBrush x:Key="ErrorBrush" Color="#F85149"/>
    <SolidColorBrush x:Key="LogBgBrush" Color="#1B1E21"/>
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
              <Trigger Property="IsDefault" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource LogBgBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="FontFamily" Value="Consolas"/>
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
      <TextBlock Name="CdTitle" Text="Guest Code" FontFamily="Consolas" FontSize="16" Foreground="{StaticResource HeaderBrush}" Margin="0,0,0,10"/>
      <TextBlock Name="CdMessage" TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" Margin="0,0,0,12"/>
      <Grid Name="CdLabelRow" Margin="0,0,0,8">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="64"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="Label" VerticalAlignment="Center"/>
        <TextBox Name="LabelBox" Grid.Column="1" MinHeight="30" VerticalContentAlignment="Center" MaxLength="60" FontFamily="Segoe UI" AutomationProperties.Name="Label"/>
      </Grid>
      <Grid Margin="0,0,0,4">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="64"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="Code" VerticalAlignment="Center"/>
        <TextBox Name="CodeBox" Grid.Column="1" MinHeight="30" VerticalContentAlignment="Center" MaxLength="40" AutomationProperties.Name="Code"/>
      </Grid>
      <TextBlock Name="CdHint" TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" FontSize="12" Margin="64,0,0,12"/>
      <TextBlock Name="CdCurrent" TextWrapping="Wrap" Margin="0,0,0,8" Visibility="Collapsed"/>
      <TextBlock Text="Expires after - click one to finish:" FontWeight="Bold" Margin="0,2,0,6"/>
      <UniformGrid Columns="3" Margin="-3,0,-3,0">
        <Button Name="BtnExp1" Content="1 hour" Height="34" Margin="3,0,3,6"/>
        <Button Name="BtnExp8" Content="8 hours" Height="34" Margin="3,0,3,6"/>
        <Button Name="BtnExp24" Content="1 day" Height="34" Margin="3,0,3,6"/>
        <Button Name="BtnExp168" Content="7 days" Height="34" Margin="3,0,3,6"/>
        <Button Name="BtnExp720" Content="30 days" Height="34" Margin="3,0,3,6"/>
        <Button Name="BtnExp0" Content="Never expires" Height="34" Margin="3,0,3,6"/>
      </UniformGrid>
      <Button Name="BtnExpCustom" Content="Custom number of hours..." Height="34" HorizontalAlignment="Stretch" Margin="0,0,0,6"/>
      <Button Name="BtnExpKeep" Content="Keep current expiry" Height="34" HorizontalAlignment="Stretch" Margin="0,0,0,6" Visibility="Collapsed"/>
      <TextBlock Name="CdError" TextWrapping="Wrap" Foreground="{StaticResource ErrorBrush}" Margin="0,4,0,0" Visibility="Collapsed" AutomationProperties.LiveSetting="Assertive"/>
      <Button Name="BtnCdCancel" Content="Cancel" Width="90" HorizontalAlignment="Right" IsCancel="True" Margin="0,10,0,0"/>
    </StackPanel>
  </Border>
</Window>
'@
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($dialogXaml))
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    $dialog.Owner = $(if ($Owner) { $Owner } else { $window })
    $dialog.Title = $Title
    $dialog.FindName('CdTitle').Text = $Title
    $dialog.FindName('CdMessage').Text = $Message
    $labelBox = $dialog.FindName('LabelBox')
    $codeBox = $dialog.FindName('CodeBox')
    $hint = $dialog.FindName('CdHint')
    $errBox = $dialog.FindName('CdError')
    $btnKeep = $dialog.FindName('BtnExpKeep')
    $btnDay = $dialog.FindName('BtnExp24')

    # Keep these two in step with cloudflare/export-relay-worker.js (WEAK_CODE_LENGTH / _MAX_HOURS).
    $weakLength = 8
    $weakHours = 24
    $currentNorm = (($CurrentCode -replace '[^A-Za-z0-9]', '')).ToUpperInvariant()

    if ($Mode -eq 'new') {
        $hint.Text = 'Leave Code blank for a random 12-character code, or type your own (4 to 32 letters or digits, any case). A code under 8 characters can be guessed, so it must expire within 24 hours.'
        $btnDay.IsDefault = $true
        $dialog.Add_Loaded({ $labelBox.Focus() }.GetNewClosure())
    } else {
        $dialog.FindName('CdLabelRow').Visibility = 'Collapsed'
        $codeBox.Text = $CurrentCode
        $hint.Text = 'Leave Code as it is to keep this code, or type a new one - the old code stops working within about a minute. A code under 8 characters can be guessed, so it must expire within 24 hours.'
        if ($CurrentExpiry) {
            $cur = $dialog.FindName('CdCurrent')
            $cur.Text = $CurrentExpiry
            $cur.Visibility = 'Visible'
        }
        if ($CurrentExpired) {
            # Nothing to keep: the code is already unusable. Pick a new life for it.
            $btnDay.IsDefault = $true
        } else {
            $btnKeep.Visibility = 'Visible'
            $btnKeep.IsDefault = $true
        }
        $dialog.Height = 660
        $dialog.Add_Loaded({ $codeBox.Focus(); $codeBox.SelectAll() }.GetNewClosure())
    }

    $showError = {
        param([string]$msg)
        $errBox.Text = $msg
        $errBox.Visibility = 'Visible'
    }.GetNewClosure()

    $result = [PSCustomObject]@{ Value = $null }   # stays $null when cancelled
    $finish = {
        param($hours, [bool]$keep)
        $errBox.Visibility = 'Collapsed'
        $labelText = ''
        if ($Mode -eq 'new') {
            $labelText = $labelBox.Text.Trim()
            if (-not $labelText) { & $showError 'Give the code a label - the person or site it is for.'; return }
        }
        $parsed = ConvertTo-GuestCodeText -Text $codeBox.Text
        if (-not $parsed.Ok) { & $showError $parsed.Error; return }
        $code = $parsed.Code
        if ($Mode -eq 'edit' -and $code -eq $currentNorm) { $code = '' }   # unchanged = keep it
        if ($Mode -eq 'edit' -and $code -eq '' -and $keep) { & $showError 'Nothing to change - type a new code, or click an expiry.'; return }
        $length = $(if ($code) { $code.Length } elseif ($Mode -eq 'edit') { $currentNorm.Length } else { 12 })
        if ($length -lt $weakLength) {
            $tooLong = $(if ($keep) { $CurrentRemainingHours -lt 0 -or $CurrentRemainingHours -gt $weakHours } else { $hours -le 0 -or $hours -gt $weakHours })
            if ($tooLong) {
                & $showError 'A code under 8 characters can be guessed, so it must expire within 24 hours. Click 1 hour, 8 hours or 1 day (or a custom number up to 24), or use a longer code.'
                return
            }
        }
        $result.Value = [PSCustomObject]@{ Label = $labelText; Code = $code; Hours = $hours; Keep = $keep }
        $dialog.Close()
    }.GetNewClosure()

    foreach ($preset in @(
            @{ Id = 'BtnExp1'; Hours = 1 }, @{ Id = 'BtnExp8'; Hours = 8 }, @{ Id = 'BtnExp24'; Hours = 24 },
            @{ Id = 'BtnExp168'; Hours = 168 }, @{ Id = 'BtnExp720'; Hours = 720 }, @{ Id = 'BtnExp0'; Hours = 0 })) {
        $presetHours = [double]$preset.Hours   # copied to a local so each closure keeps its own value
        $dialog.FindName($preset.Id).Add_Click({ & $finish $presetHours $false }.GetNewClosure())
    }
    $btnKeep.Add_Click({ & $finish $null $true }.GetNewClosure())
    $dialog.FindName('BtnExpCustom').Add_Click({
        $err = $null
        for ($asked = 0; $asked -lt 3; $asked++) {
            $typed = Show-PromptDialog -Owner $dialog -Title 'Custom Expiry' -Message 'Hours until the code expires (for example 48 = two days, 0.5 = half an hour). 0 means it never expires.' -DefaultText '24' -ErrorText $err
            if ([string]::IsNullOrWhiteSpace($typed)) { return }   # cancelled: stay in this dialog
            $hours = 0.0
            $parsedHours = [double]::TryParse($typed.Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$hours)
            if ($parsedHours -and ($hours -eq 0 -or ($hours -ge 0.02 -and $hours -le 8760))) {
                & $finish $hours $false
                return
            }
            $err = 'Enter a number from 0.02 (about a minute) to 8760, or 0 for never. Use a dot for decimals (0.5).'
        }
        # Three bad entries in a row: say so here instead of closing the prompt without a word.
        & $showError $err
    }.GetNewClosure())
    $dialog.ShowDialog() | Out-Null
    return $result.Value
}

function Show-AccessCodesDialog {
    # Admin-only management of guest access codes (create / copy / switch off-on / delete),
    # reached from the Compare chooser. Uses $script:RelayKeys.Admin (kept separate from the
    # pairing access key so a guest code cached for pairing is never sent as the admin key).
    # Rows are updated from each call's response rather than re-listing, because KV is
    # eventually consistent. All calls are short, blocking requests on the UI thread with a
    # wait cursor, consistent with the script's other small inline fetches.
    $relayUrl = $script:ExportRelayUrl
    if ($script:ExportRelayUrl -match 'REPLACE-WITH-YOUR-WORKER-URL') {
        [System.Windows.MessageBox]::Show('The pairing relay is not configured yet in this build - see cloudflare/README.md.', 'Gr3y Tools', 'OK', 'Warning') | Out-Null
        return
    }
    $gated = Test-RelayGated -RelayUrl $relayUrl
    if ($gated -eq $false) {
        [System.Windows.MessageBox]::Show($script:RelayOutdatedText, 'Gr3y Tools', 'OK', 'Warning') | Out-Null
        return
    }
    if ($null -eq $gated) {
        [System.Windows.MessageBox]::Show("Could not reach the pairing relay. Check this machine's internet connection.", 'Gr3y Tools', 'OK', 'Warning') | Out-Null
        return
    }

    $dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Manage Access Codes" Width="840" Height="560" MinWidth="760" MinHeight="460"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="#232629" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <SolidColorBrush x:Key="BgBrush" Color="#232629"/>
    <SolidColorBrush x:Key="ButtonBrush" Color="#1E3747"/>
    <SolidColorBrush x:Key="ButtonHoverBrush" Color="#2A4C69"/>
    <SolidColorBrush x:Key="ControlBorderBrush" Color="#707070"/>
    <SolidColorBrush x:Key="TextBrush" Color="#F7F7F7"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#9AA3AB"/>
    <SolidColorBrush x:Key="HeaderBrush" Color="#5BDCFF"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#5BDCFF"/>
    <SolidColorBrush x:Key="GreenBrush" Color="#3FB950"/>
    <SolidColorBrush x:Key="AmberBrush" Color="#D29922"/>
    <SolidColorBrush x:Key="ErrorBrush" Color="#F85149"/>
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
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" Background="Transparent" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource NavSelectedBrush}"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource ButtonHoverBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Padding="20">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Text="Manage Access Codes" FontFamily="Consolas" FontSize="16" Foreground="{StaticResource HeaderBrush}" Margin="0,0,0,10"/>
      <TextBlock Grid.Row="1" TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" Margin="0,0,0,12"
                 Text="Guest codes let someone else pair with an old machine without knowing the admin code. Choose the code yourself or let one be generated; a code can expire on its own (Expires column), and Edit Code... changes the code or its expiry any time. A code under 8 characters must expire within 24 hours. An expired code stays listed for a week. Changes can take up to a minute to reach every Cloudflare location."/>
      <Grid Grid.Row="2" Margin="8,0,25,4">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="250"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="70"/>
          <ColumnDefinition Width="130"/>
          <ColumnDefinition Width="90"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="Code" FontWeight="Bold" Foreground="{StaticResource MutedBrush}"/>
        <TextBlock Grid.Column="1" Text="Label" FontWeight="Bold" Foreground="{StaticResource MutedBrush}"/>
        <TextBlock Grid.Column="2" Text="State" FontWeight="Bold" Foreground="{StaticResource MutedBrush}"/>
        <TextBlock Grid.Column="3" Text="Expires" FontWeight="Bold" Foreground="{StaticResource MutedBrush}"/>
        <TextBlock Grid.Column="4" Text="Created" FontWeight="Bold" Foreground="{StaticResource MutedBrush}"/>
      </Grid>
      <ListBox Grid.Row="3" Name="CodesList" SelectionMode="Single" Background="{StaticResource LogBgBrush}"
               BorderBrush="{StaticResource PanelBorderBrush}" BorderThickness="1"
               HorizontalContentAlignment="Stretch" ScrollViewer.HorizontalScrollBarVisibility="Disabled"
               ScrollViewer.VerticalScrollBarVisibility="Visible"/>
      <TextBlock Grid.Row="4" Name="CodesStatus" TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" Margin="0,10,0,0" Text="Loading..."/>
      <DockPanel Grid.Row="5" Margin="0,14,0,0" LastChildFill="False">
        <Button Name="BtnCodeNew" Content="New Code..." Width="105" Margin="0,0,6,0" DockPanel.Dock="Left" BorderBrush="{StaticResource AccentBrush}"/>
        <Button Name="BtnCodeCopy" Content="Copy Code" Width="90" Margin="0,0,6,0" DockPanel.Dock="Left"/>
        <Button Name="BtnCodeEdit" Content="Edit Code..." Width="105" Margin="0,0,6,0" DockPanel.Dock="Left"/>
        <Button Name="BtnCodeToggle" Content="Switch Off" Width="95" Margin="0,0,6,0" DockPanel.Dock="Left"/>
        <Button Name="BtnCodeDelete" Content="Delete..." Width="80" Margin="0,0,6,0" DockPanel.Dock="Left"/>
        <Button Name="BtnCodeClose" Content="Close" Width="80" DockPanel.Dock="Right"/>
        <Button Name="BtnCodeRefresh" Content="Refresh" Width="80" Margin="0,0,6,0" DockPanel.Dock="Right"/>
      </DockPanel>
    </Grid>
  </Border>
</Window>
'@
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($dialogXaml))
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    $dialog.Owner = $window

    $codesList = $dialog.FindName('CodesList')
    $codesStatus = $dialog.FindName('CodesStatus')
    $btnNew = $dialog.FindName('BtnCodeNew')
    $btnCopy = $dialog.FindName('BtnCodeCopy')
    $btnEdit = $dialog.FindName('BtnCodeEdit')
    $btnToggle = $dialog.FindName('BtnCodeToggle')
    $btnDelete = $dialog.FindName('BtnCodeDelete')
    $btnRefresh = $dialog.FindName('BtnCodeRefresh')
    $btnClose = $dialog.FindName('BtnCodeClose')

    # Build one ListBox item (a Grid of TextBlocks, no data binding - matching the rest of the
    # GUI). The ListBox stretches its items, never scrolls sideways and always shows its vertical
    # scrollbar, so the star-sized Label column gets exactly the leftover width and lines up with
    # the header, which leaves the same room on its right for that scrollbar (without that, a
    # long label widened its column, and a scrollbar appearing later nudged the rest out of
    # alignment). The Code column fits the longest code the relay accepts (32 characters, with room to spare). Tag carries the bare code
    # (no dashes) for the admin calls. The green "On"/red "Off"/amber "Expired" is its own
    # TextBlock so the colour reads on the selected (blue) row too. This only
    # BUILDS the item; callers add it ($addRow) or swap it into an existing slot (Toggle) -
    # a ListBoxItem already in the list can't be inserted a second time.
    $newItem = {
        param($rec)
        $row = New-Object System.Windows.Controls.Grid
        $info = Get-GuestRowInfo -Rec $rec
        foreach ($w in @('250', '*', '70', '130', '90')) {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = [System.Windows.GridLength]::new([double]($w -replace '\*', '1'), $(if ($w -eq '*') { 'Star' } else { 'Pixel' }))
            $row.ColumnDefinitions.Add($cd)
        }
        $tbCode = New-Object System.Windows.Controls.TextBlock
        $tbCode.Text = $rec.key; $tbCode.FontFamily = 'Consolas'
        $tbCode.TextTrimming = 'CharacterEllipsis'; $tbCode.Margin = '0,0,8,0'; $tbCode.ToolTip = [string]$rec.key
        [System.Windows.Controls.Grid]::SetColumn($tbCode, 0); [void]$row.Children.Add($tbCode)
        $tbLabel = New-Object System.Windows.Controls.TextBlock
        $tbLabel.Text = $rec.label; $tbLabel.TextTrimming = 'CharacterEllipsis'; $tbLabel.Margin = '0,0,8,0'
        [System.Windows.Controls.Grid]::SetColumn($tbLabel, 1); [void]$row.Children.Add($tbLabel)
        $tbState = New-Object System.Windows.Controls.TextBlock
        $tbState.Text = $info.State; $tbState.FontWeight = 'Bold'
        $stateBrush = if ($info.State -eq 'On') { 'GreenBrush' } elseif ($info.State -eq 'Off') { 'ErrorBrush' } else { 'AmberBrush' }
        $tbState.Foreground = $dialog.FindResource($stateBrush)
        [System.Windows.Controls.Grid]::SetColumn($tbState, 2); [void]$row.Children.Add($tbState)
        $tbExpires = New-Object System.Windows.Controls.TextBlock
        $tbExpires.Text = $info.Expires
        $tbExpires.Foreground = $dialog.FindResource($(if ($info.Expired) { 'AmberBrush' } else { 'TextBrush' }))
        [System.Windows.Controls.Grid]::SetColumn($tbExpires, 3); [void]$row.Children.Add($tbExpires)
        $tbCreated = New-Object System.Windows.Controls.TextBlock
        $tbCreated.Text = $rec.created; $tbCreated.Foreground = $dialog.FindResource('MutedBrush')
        [System.Windows.Controls.Grid]::SetColumn($tbCreated, 4); [void]$row.Children.Add($tbCreated)
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = $row
        # A readable accessible name (screen readers, UI automation) - without it the row is
        # announced as the type name of the item.
        [System.Windows.Automation.AutomationProperties]::SetName($item, "$($rec.key) $($rec.label) $($info.State) expires $($info.Expires)")
        # Tag: the bare code (no separators) plus the enabled flag and expiry, for Toggle / Set
        # Expiry / Delete / Copy.
        $item.Tag = [PSCustomObject]@{ Code = ($rec.key -replace '[^A-Za-z0-9]', ''); Display = $rec.key; Enabled = $info.Enabled; Label = $rec.label; ExpiresMs = $info.ExpiresMs; ExpiresText = $info.Expires; Expired = $info.Expired; NeedsExpiry = $info.NeedsExpiry }
        return $item
    }.GetNewClosure()

    $addRow = {
        param($rec)
        [void]$codesList.Items.Add((& $newItem $rec))
    }.GetNewClosure()

    # Server-supplied detail for a failed call (e.g. "Admin access is not configured ..."),
    # as " <text>", or nothing when there is none.
    $errDetail = {
        param($r)
        $d = if ($r.Text) { $r.Text.Trim() } elseif ($r.Error) { $r.Error } else { '' }
        # 429 = this connection has had too many wrong codes. The relay answers EVERY non-admin key
        # that way (never 401), so a mistyped admin code looks like a lock-out: say that Refresh asks
        # for the code again (the right admin code works at once - it is never blocked).
        if ($r.Status -eq 429) { $d = "$d (Wrong admin code? Press Refresh to enter it again.)".Trim() }
        if ($d) { " $d" } else { '' }
    }.GetNewClosure()

    $setBusy = {
        param([bool]$busy, [string]$msg)
        $dialog.Cursor = $(if ($busy) { [System.Windows.Input.Cursors]::Wait } else { $null })
        foreach ($b in @($btnNew, $btnCopy, $btnEdit, $btnToggle, $btnDelete, $btnRefresh)) { $b.IsEnabled = -not $busy }
        if ($msg) { $codesStatus.Text = $msg }
        # The relay calls below block this thread, so paint the busy state first - otherwise
        # the "Loading..." text and wait cursor are set but never drawn until the call returns.
        if ($busy) { try { $dialog.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render) } catch {} }
    }.GetNewClosure()

    # "HTTP 404", or plain words when there was no HTTP response at all (Status 0).
    $httpText = {
        param($r)
        if ($r.Status -eq 0) { 'no answer from the relay' } else { "HTTP $($r.Status)" }
    }.GetNewClosure()

    # Admin key: try the cached admin code, else the pairing key (the admin may have used it
    # for pairing), else prompt. A 401 clears the key and re-prompts (a silently-tried cached
    # key that fails doesn't show an error; a typed one does). Gives up after two typed
    # attempts. Any other status (e.g. 503 = ADMIN_KEY not configured on the relay) is
    # returned as-is - re-prompting can't fix those. $keys is the shared key holder: a
    # reference, not $script: variables, because inside a closure `$script:` is the closure's
    # own scope.
    $keys = $script:RelayKeys
    $badKeyText = $script:RelayBadKeyText
    $callAdmin = {
        param([string]$Method, [string]$Path)
        $key = $keys.Admin
        # $guessed: the key being tried is only the cached pairing key, which may be a guest code.
        $guessed = $false
        if ([string]::IsNullOrEmpty($key)) { $key = $keys.Access; $guessed = -not [string]::IsNullOrEmpty($key) }
        $typed = $false
        $errText = $null
        # Same clean-up as the pairing key: a cached code with a stray typographic dash would
        # otherwise fail inside .NET and read as "no answer from the relay".
        if (-not [string]::IsNullOrEmpty($key)) {
            $key = ConvertTo-RelayKey -Text $key
            if (-not $key) { $errText = $badKeyText }
        }
        for ($tries = 0; $tries -lt 3; $tries++) {
            if ([string]::IsNullOrEmpty($key)) {
                $key = Show-PromptDialog -Owner $dialog -Title 'Admin Code' -Message 'Enter the ADMIN code (the ADMIN_KEY Worker secret) to manage guest codes. Kept in memory only.' -Secret -ErrorText $errText
                if ([string]::IsNullOrEmpty($key)) { return $null }  # cancelled
                $key = ConvertTo-RelayKey -Text $key
                if (-not $key) { $errText = $badKeyText; continue }  # nothing was sent; ask again
                $typed = $true
                $guessed = $false
            }
            $r = Invoke-RelayRequest -RelayUrl $relayUrl -Method $Method -Path $Path -Headers @{ 'X-Access-Key' = $key }
            # 429 = this connection has had too many refused codes. The relay never blocks the ADMIN
            # code, so a 429 for a key that was only guessed from the pairing cache (a guest code) means
            # "not the admin code": ask for it, the same as for a 401, instead of dead-ending.
            if ($r.Status -eq 401 -or ($r.Status -eq 429 -and $guessed)) {
                $errText = $(if ($typed) { 'That admin code was not accepted. Try again.' } else { $null })
                $key = $null
                $keys.Admin = $null
                $typed = $false
                $guessed = $false
                continue
            }
            if ($r.Status -ge 200 -and $r.Status -lt 300) { $keys.Admin = $key }
            return $r
        }
        return [PSCustomObject]@{ Status = 401; Text = 'The admin code was not accepted.'; Error = $null }
    }.GetNewClosure()

    $refresh = {
        & $setBusy $true 'Loading...'
        $codesList.Items.Clear()
        $r = & $callAdmin 'GET' '/admin/keys'
        & $setBusy $false $null
        if ($null -eq $r) { $codesStatus.Text = 'Admin code needed to manage access codes.'; return }
        if ($r.Status -ne 200) { $codesStatus.Text = "Could not load codes ($(& $httpText $r)).$(& $errDetail $r)"; return }
        $rows = ConvertFrom-RelayKeyList -Json $r.Text
        foreach ($rec in $rows) { & $addRow $rec }
        $codesStatus.Text = "$($rows.Count) guest code(s). Switching a code off or deleting it can take up to a minute to reach every Cloudflare location."
    }.GetNewClosure()

    # The selected row's Tag, or $null when nothing is selected or the row somehow has no code
    # (so Copy/Switch/Delete can never send an empty code to the relay).
    $selectedTag = {
        $t = $null
        if ($codesList.SelectedItem) { $t = $codesList.SelectedItem.Tag }
        if ($t -and $t.Code) { $t } else { $null }
    }.GetNewClosure()

    $btnRefresh.Add_Click({ & $refresh }.GetNewClosure())

    $btnNew.Add_Click({
        $choice = Show-CodeDialog -Mode new -Owner $dialog -Title 'New Guest Code' -Message 'Choose a label, optionally choose the code yourself, then click how long it should last. (Enter picks 1 day.)'
        if ($null -eq $choice) { return }   # cancelled: nothing is created
        $query = "label=$([uri]::EscapeDataString($choice.Label))"
        if ($choice.Code) { $query += '&code=' + [uri]::EscapeDataString($choice.Code) }
        if ($choice.Hours -gt 0) { $query += '&hours=' + (ConvertTo-HoursQuery -Hours $choice.Hours) }
        & $setBusy $true 'Creating...'
        $r = & $callAdmin 'POST' "/admin/keys?$query"
        & $setBusy $false $null
        if ($null -eq $r) { $codesStatus.Text = 'Admin code needed.'; return }
        if ($r.Status -eq 409) { $codesStatus.Text = 'That code is already taken - choose another.'; return }
        if ($r.Status -ne 200) { $codesStatus.Text = "Could not create the code ($(& $httpText $r)).$(& $errDetail $r)"; return }
        $rec = $null
        try { $rec = $r.Text | ConvertFrom-Json -ErrorAction Stop } catch {}
        if (-not $rec) { $codesStatus.Text = 'The relay returned an unexpected response.'; return }
        $made = Get-GuestRowInfo -Rec $rec
        $names = @($rec.PSObject.Properties | ForEach-Object { $_.Name })
        $tooOld = ($choice.Hours -gt 0 -and $null -eq $made.ExpiresMs) -or ($choice.Code -and ($names -notcontains 'custom'))
        if ($tooOld) {
            # An old relay ignores ?hours= and ?code=: it made a random code that never expires.
            # Don't leave that live - take it straight back out, and say what happened.
            $stray = $rec.key -replace '[^A-Za-z0-9]', ''
            & $setBusy $true 'Removing...'
            $gone = & $callAdmin 'DELETE' "/admin/keys/$stray"
            & $setBusy $false $null
            if ($gone -and $gone.Status -eq 200) {
                $codesStatus.Text = 'This relay is too old for expiry and codes you choose, so nothing was created. Update the Worker (cloudflare/README.md).'
            } else {
                & $addRow $rec
                $codesList.SelectedIndex = $codesList.Items.Count - 1
                $codesList.ScrollIntoView($codesList.SelectedItem)
                $codesStatus.Text = "This relay is too old for expiry and codes you choose: it made the random code $($rec.key), which will NOT expire, and it could not be removed. Delete it from the list, then update the Worker (cloudflare/README.md)."
            }
            return
        }
        & $addRow $rec
        $codesList.SelectedIndex = $codesList.Items.Count - 1
        # In a long list the new row can be below the visible part - bring it into view.
        $codesList.ScrollIntoView($codesList.SelectedItem)
        $copied = $false
        try { [System.Windows.Clipboard]::SetText($rec.key); $copied = $true } catch {}
        $when = $(if ($null -ne $made.ExpiresMs) { "expires $($made.Expires)" } else { 'never expires' })
        $note = $(if ($copied) { ' - copied to the clipboard.' } else { '.' })
        # Making a code you chose reads that name first, and Cloudflare caches a miss for about a
        # minute - so someone trying it straight away can still be told no.
        $wait = $(if ($choice.Code) { ' It can take up to a minute before it works everywhere.' } else { '' })
        $codesStatus.Text = "Created $($rec.key) ('$($rec.label)') - $when$note$wait"
    }.GetNewClosure())

    $btnEdit.Add_Click({
        $tag = & $selectedTag
        if (-not $tag) { $codesStatus.Text = 'Select a code first.'; return }
        $current = $(if ($tag.NeedsExpiry) {
                $(if ($null -ne $tag.ExpiresMs) { "Currently: expires $($tag.ExpiresText) - not accepted, see below." } else { 'Currently: no usable expiry.' })
            } elseif ($tag.Expired) { "Currently: expired ($($tag.ExpiresText))." } elseif ($null -ne $tag.ExpiresMs) { "Currently: expires $($tag.ExpiresText)." } else { 'Currently: never expires.' })
        $remaining = $(if ($null -ne $tag.ExpiresMs) { ($tag.ExpiresMs - [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) / 3600000.0 } else { -1.0 })
        # An expired code, or one the relay refuses for want of a usable expiry, has nothing worth keeping.
        $whyRefused = $(if (-not $tag.Expired) { '' }
            elseif ($tag.NeedsExpiry -and $tag.Code.Length -lt 8) { ' A code under 8 characters needs an expiry within 24 hours - click how long it should last from now. (Enter picks 1 day.)' }
            elseif ($tag.NeedsExpiry) { ' This code has no usable expiry - click how long it should last from now. (Enter picks 1 day.)' }
            else { ' This code has expired - click how long it should last from now. (Enter picks 1 day.)' })
        $choice = Show-CodeDialog -Mode edit -Owner $dialog -Title 'Edit Guest Code' -Message "Editing $($tag.Display) ('$($tag.Label)'). Change the code, its expiry, or both.$whyRefused" -CurrentCode $tag.Display -CurrentExpiry $current -CurrentRemainingHours $remaining -CurrentExpired:([bool]$tag.Expired)
        if ($null -eq $choice) { return }
        $renaming = [bool]$choice.Code
        # Belt and braces: the dialog refuses "keep the expiry" with nothing else changed, but if
        # that ever slipped through, a null Hours would be sent as 0 and REMOVE the expiry.
        if (-not $renaming -and ($choice.Keep -or $null -eq $choice.Hours)) { $codesStatus.Text = 'Nothing changed.'; return }
        if ($renaming) {
            $path = "/admin/keys/$($tag.Code)/rename?to=$([uri]::EscapeDataString($choice.Code))"
            if (-not $choice.Keep) { $path += '&hours=' + (ConvertTo-HoursQuery -Hours $choice.Hours) }
        } else {
            $path = "/admin/keys/$($tag.Code)/expiry?hours=$(ConvertTo-HoursQuery -Hours $choice.Hours)"
        }
        & $setBusy $true 'Saving...'
        $r = & $callAdmin 'POST' $path
        & $setBusy $false $null
        if ($null -eq $r) { $codesStatus.Text = 'Admin code needed.'; return }
        if ($r.Status -eq 404 -and $r.Text -and $r.Text.Trim() -eq 'Not found') {
            # An old Worker has no /expiry or /rename route (a missing code answers "No such guest code").
            $codesStatus.Text = 'This relay is too old to edit a code. Update the Worker (cloudflare/README.md).'
            return
        }
        if ($r.Status -eq 409) { $codesStatus.Text = 'That code is already taken - choose another.'; return }
        if ($r.Status -ne 200) { $codesStatus.Text = "Could not save the change ($(& $httpText $r)).$(& $errDetail $r)"; return }
        $rec = $null
        try { $rec = $r.Text | ConvertFrom-Json -ErrorAction Stop } catch {}
        if (-not $rec) { $codesStatus.Text = 'The relay returned an unexpected response.'; return }
        # Same swap as Toggle: remove + insert, never the indexer, then keep the row selected.
        $idx = $codesList.SelectedIndex
        $codesList.Items.RemoveAt($idx)
        $codesList.Items.Insert($idx, (& $newItem $rec))
        $codesList.SelectedIndex = $idx
        $after = Get-GuestRowInfo -Rec $rec
        $when = $(if ($after.Expired) { 'expired' } elseif ($null -ne $after.ExpiresMs) { "expires $($after.Expires)" } else { 'never expires' })
        # A switched-off code stays off when it is renamed or given a new expiry - say so, or the
        # owner expects it to work now.
        $stillOff = $(if (-not $after.Enabled) { ' It is still switched Off - use Switch On to let it be used.' } else { '' })
        if ($renaming) {
            $codesStatus.Text = "$($tag.Display) is now $($rec.key) ($when). The old code stops working; this can take up to a minute to reach every Cloudflare location.$stillOff"
        } else {
            $codesStatus.Text = "$($rec.key) $when. It can take up to a minute to take effect everywhere.$stillOff"
        }
    }.GetNewClosure())

    $btnCopy.Add_Click({
        $tag = & $selectedTag
        if (-not $tag) { $codesStatus.Text = 'Select a code first.'; return }
        try { [System.Windows.Clipboard]::SetText($tag.Display); $codesStatus.Text = "Copied $($tag.Display) to the clipboard." }
        catch { $codesStatus.Text = 'Could not access the clipboard.' }
    }.GetNewClosure())

    $btnToggle.Add_Click({
        $tag = & $selectedTag
        if (-not $tag) { $codesStatus.Text = 'Select a code first.'; return }
        $action = if ($tag.Enabled) { 'disable' } else { 'enable' }
        & $setBusy $true "Switching $($action)..."
        $r = & $callAdmin 'POST' "/admin/keys/$($tag.Code)/$action"
        & $setBusy $false $null
        if ($null -eq $r) { $codesStatus.Text = 'Admin code needed.'; return }
        if ($r.Status -ne 200) { $codesStatus.Text = "Could not switch the code ($(& $httpText $r)).$(& $errDetail $r)"; return }
        $rec = $null
        try { $rec = $r.Text | ConvertFrom-Json -ErrorAction Stop } catch {}
        if ($rec) {
            # Swap a freshly built item into the same slot rather than re-listing (KV reads
            # are eventually consistent), and keep the row selected. Remove + insert, NOT
            # `Items[$idx] = ...`: assigning through the indexer makes WPF reuse the old
            # container and draw the new ListBoxItem's ToString() as the row's text.
            $idx = $codesList.SelectedIndex
            $codesList.Items.RemoveAt($idx)
            $codesList.Items.Insert($idx, (& $newItem $rec))
            $codesList.SelectedIndex = $idx
            $nowState = $(if ($rec.enabled) { 'On' } else { 'Off' })
            if ($rec.expired -eq $true) {
                # The row stays "Expired" whatever the switch says, and the code still cannot be used. Say why:
                # a code that merely lacks a usable expiry has not "expired".
                $nowInfo = Get-GuestRowInfo -Rec $rec
                $why = $(if (-not $nowInfo.NeedsExpiry) { 'it has expired' } elseif ($tag.Code.Length -lt 8) { 'a code under 8 characters needs an expiry within 24 hours' } else { 'it has no usable expiry' })
                $codesStatus.Text = "$($rec.key) is now $nowState, but $why - use Edit Code... to give it a new expiry."
            } else {
                $codesStatus.Text = "$($rec.key) is now $nowState. It can take up to a minute to take effect everywhere."
            }
        } else {
            $codesStatus.Text = 'The relay returned an unexpected response.'
        }
    }.GetNewClosure())

    $btnDelete.Add_Click({
        $tag = & $selectedTag
        if (-not $tag) { $codesStatus.Text = 'Select a code first.'; return }
        $confirm = [System.Windows.MessageBox]::Show("Delete guest code $($tag.Display) ('$($tag.Label)')? Anyone using it will no longer be able to pair. This cannot be undone.", 'Gr3y Tools', 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') { return }
        & $setBusy $true 'Deleting...'
        $r = & $callAdmin 'DELETE' "/admin/keys/$($tag.Code)"
        & $setBusy $false $null
        if ($null -eq $r) { $codesStatus.Text = 'Admin code needed.'; return }
        if ($r.Status -ne 200) { $codesStatus.Text = "Could not delete the code ($(& $httpText $r)).$(& $errDetail $r)"; return }
        $idx = $codesList.SelectedIndex
        if ($idx -ge 0) { $codesList.Items.RemoveAt($idx) }
        $codesStatus.Text = "Deleted $($tag.Display)."
    }.GetNewClosure())

    # Toggle the button label to match the selected row's state ("Switch Off" when nothing is
    # selected, so it never keeps the previous row's "Switch On").
    $codesList.Add_SelectionChanged({
        $tag = & $selectedTag
        $btnToggle.Content = $(if ($tag -and -not $tag.Enabled) { 'Switch On' } else { 'Switch Off' })
    }.GetNewClosure())

    $btnClose.Add_Click({ $dialog.Close() }.GetNewClosure())
    $dialog.Add_Loaded({ & $refresh }.GetNewClosure())
    $dialog.ShowDialog() | Out-Null
}

function Show-PairingDialog {
    if ($script:ExportRelayUrl -match 'REPLACE-WITH-YOUR-WORKER-URL') {
        [System.Windows.MessageBox]::Show('The pairing relay is not configured yet in this build - see cloudflare/README.md.', 'Gr3y Tools', 'OK', 'Warning') | Out-Null
        return
    }
    $relayUrl = $script:ExportRelayUrl

    # Probe the relay BEFORE asking for a code: an old (ungated) Worker has no /open route, so
    # pairing can't work against it, and there's no point prompting for an access code.
    $gated = Test-RelayGated -RelayUrl $relayUrl
    if ($gated -eq $false) {
        [System.Windows.MessageBox]::Show($script:RelayOutdatedText, 'Gr3y Tools', 'OK', 'Warning') | Out-Null
        return
    }
    if ($null -eq $gated) {
        [System.Windows.MessageBox]::Show("Could not reach the pairing relay. Check this machine's internet connection, or use Load a File or Pasted List instead.", 'Gr3y Tools', 'OK', 'Warning') | Out-Null
        return
    }

    # Ask for the access code and open a pairing slot. Re-prompt once on a rejected code,
    # then give up. The access key is cached in memory (Get-RelayAccessKey) so a second
    # pairing this run doesn't ask again; a rejected key is cleared so it isn't reused.
    $pair = $null
    $promptError = $null
    for ($tries = 0; $tries -lt 2; $tries++) {
        $key = Get-RelayAccessKey -ErrorText $promptError
        if ([string]::IsNullOrEmpty($key)) { return }  # user cancelled
        $pair = Start-RelayPairing -RelayUrl $relayUrl -AccessKey $key
        if ($pair.Ok) { break }
        if ($pair.Failure -eq 'auth' -or $pair.Failure -eq 'badkey') {
            $script:RelayKeys.Access = $null
            $promptError = $(if ($pair.Failure -eq 'badkey') { $script:RelayBadKeyText } else { 'That code was not accepted - it may be wrong, switched off or expired. Try again.' })
            $pair = $null
            continue
        }
        # Any other failure is not something a re-prompt fixes. The detail text already ends
        # with a full stop, so drop it before it goes inside the brackets.
        $detail = ([string]$pair.Message).TrimEnd('.')
        $msg = switch ($pair.Failure) {
            'outdated' { $script:RelayOutdatedText }
            'locked'   { 'Too many wrong access codes were entered from this connection. Wait about ten minutes and try again, or use Load a File or Pasted List.' }
            'network'  { "Could not reach the pairing relay ($detail). Check this machine's internet connection, or use Load a File or Pasted List." }
            'busy'     { 'Could not get an unused pairing code - try again in a moment.' }
            default    { "The relay is temporarily unavailable ($detail). Try again in a few minutes." }
        }
        [System.Windows.MessageBox]::Show($msg, 'Gr3y Tools', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not ($pair -and $pair.Ok)) {
        [System.Windows.MessageBox]::Show('That code was not accepted. Pairing cancelled.', 'Gr3y Tools', 'OK', 'Warning') | Out-Null
        return
    }
    $code = $pair.Code
    $session = $pair.Session
    $label = $pair.Label

    $dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Pair with Old Machine" Width="640" Height="440" MinWidth="500" MinHeight="380"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="#232629" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <SolidColorBrush x:Key="BgBrush" Color="#232629"/>
    <SolidColorBrush x:Key="ButtonBrush" Color="#1E3747"/>
    <SolidColorBrush x:Key="ButtonHoverBrush" Color="#2A4C69"/>
    <SolidColorBrush x:Key="ControlBorderBrush" Color="#707070"/>
    <SolidColorBrush x:Key="TextBrush" Color="#F7F7F7"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#9AA3AB"/>
    <SolidColorBrush x:Key="HeaderBrush" Color="#5BDCFF"/>
    <SolidColorBrush x:Key="GreenBrush" Color="#3FB950"/>
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
  <ScrollViewer VerticalScrollBarVisibility="Auto">
  <Border Padding="20">
    <StackPanel>
      <TextBlock Text="Pair with Old Machine" FontFamily="Consolas" FontSize="16" Foreground="{StaticResource HeaderBrush}" Margin="0,0,0,10"/>
      <TextBlock TextWrapping="Wrap" Foreground="{StaticResource MutedBrush}" Margin="0,0,0,16"
                 Text="Run the command below on the OLD machine through whatever command-line access you have - it needs no access code. The export is sent straight here: one-time use, and lost if this dialog is closed before it arrives. It can take up to a minute to appear after the old machine says Sent."/>

      <TextBlock Text="Code:" FontWeight="Bold" Margin="0,0,0,4"/>
      <TextBlock Name="CodeDisplay" FontFamily="Consolas" FontSize="26" FontWeight="Bold" Foreground="{StaticResource HeaderBrush}" Margin="0,0,0,2"/>
      <TextBlock Name="AccessText" Foreground="{StaticResource GreenBrush}" FontSize="12" Margin="0,0,0,16"/>

      <TextBlock Text="Run on the old machine:" FontWeight="Bold" Margin="0,0,0,4"/>
      <Grid Margin="0,0,0,16">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBox Name="CmdPair" Grid.Column="0" MinHeight="32" VerticalContentAlignment="Center" TextWrapping="Wrap" VerticalScrollBarVisibility="Disabled" HorizontalScrollBarVisibility="Disabled"/>
        <Button Name="BtnCopyPair" Grid.Column="1" Content="Copy" Width="70" Height="32" Margin="8,0,0,0" VerticalAlignment="Top"/>
      </Grid>

      <TextBlock Name="StatusText" Text="Waiting for data..." Foreground="{StaticResource MutedBrush}" Margin="0,0,0,16" TextWrapping="Wrap"/>

      <Button Name="BtnCancelPairing" Content="Cancel" HorizontalAlignment="Right" Width="90"/>
    </StackPanel>
  </Border>
  </ScrollViewer>
</Window>
'@
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($dialogXaml))
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    $dialog.Owner = $window

    $codeDisplay = $dialog.FindName('CodeDisplay')
    $accessText = $dialog.FindName('AccessText')
    $cmdPair = $dialog.FindName('CmdPair')
    $btnCopyPair = $dialog.FindName('BtnCopyPair')
    $statusText = $dialog.FindName('StatusText')
    $btnCancelPairing = $dialog.FindName('BtnCancelPairing')

    $codeDisplay.Text = $code
    $accessText.Text = "Unlocked as: $label"
    $cmdPair.Text = "`$s = irm get.gr3y.io/debloat-export; & ([scriptblock]::Create(`$s)) -Code $code"

    $btnCopyPair.Add_Click({
        try { [System.Windows.Clipboard]::SetText($cmdPair.Text) } catch {}
        $btnCopyPair.Content = 'Copied!'
        $revertTimer = New-Object System.Windows.Threading.DispatcherTimer
        $revertTimer.Interval = [TimeSpan]::FromSeconds(1.2)
        $revertTimer.Add_Tick({ $btnCopyPair.Content = 'Copy'; $revertTimer.Stop() }.GetNewClosure())
        $revertTimer.Start()
    }.GetNewClosure())

    # Poll in a background runspace, not inline - each poll is a network round-trip repeating
    # for up to 10 minutes. The runspace runs Wait-RelayExport, which needs this script's
    # Invoke-RelayRequest too, so both are injected via an InitialSessionState (a background
    # runspace shares nothing else with the script). A synchronized hashtable lets the loop
    # surface a transient-error message to the UI without sharing anything else. A 500 ms
    # DispatcherTimer only checks "is the call done yet" and copies that message across.
    $state = [hashtable]::Synchronized(@{ Message = $null })
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new('Invoke-RelayRequest', (Get-Command Invoke-RelayRequest).Definition))
    $iss.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new('Wait-RelayExport', (Get-Command Wait-RelayExport).Definition))
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $pollPS = [powershell]::Create()
    $pollPS.Runspace = $rs
    [void]$pollPS.AddCommand('Wait-RelayExport').AddParameter('RelayUrl', $relayUrl).AddParameter('Code', $code).AddParameter('Session', $session).AddParameter('TimeoutSeconds', 600).AddParameter('State', $state)
    $pollHandle = $pollPS.BeginInvoke()

    # One cleanup path shared by Cancel and the window X (the old code only stopped the timer
    # on close, leaving the poll runspace running up to 10 minutes and able to consume the
    # export). Idempotent via $cleanedUp. Best-effort /close so the old machine can't submit
    # into a gone dialog; skipped once the export has been claimed.
    $pairClosed = [PSCustomObject]@{ Done = $false; Consumed = $false }
    # Create the timer BEFORE $cleanup so the closure captures the real object, not $null.
    $checkTimer = New-Object System.Windows.Threading.DispatcherTimer
    $checkTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $cleanup = {
        if ($pairClosed.Done) { return }
        $pairClosed.Done = $true
        try { $checkTimer.Stop() } catch {}
        if (-not $pollHandle.IsCompleted) { try { $pollPS.Stop() } catch {} }
        try { $pollPS.Dispose() } catch {}
        try { $rs.Dispose() } catch {}
        if (-not $pairClosed.Consumed) {
            # Short timeout: this runs on the UI thread as the dialog closes.
            Invoke-RelayRequest -RelayUrl $relayUrl -Method 'POST' -Path "/close?code=$code" -Headers @{ 'X-Session' = $session } -TimeoutSec 3 | Out-Null
        }
    }.GetNewClosure()

    $checkTimer.Add_Tick({
        if (-not $pollHandle.IsCompleted) {
            if ($state.Message) { $statusText.Text = $state.Message } else { $statusText.Text = 'Waiting for the old machine...' }
            return
        }
        $checkTimer.Stop()
        $result = $null
        try { $result = @($pollPS.EndInvoke($pollHandle))[0] } catch {}
        if ($result -and $result.Kind -eq 'data') {
            $pairClosed.Consumed = $true
            $d = $result.Data
            $hasShape = $d -and (($d.PSObject.Properties.Name -contains 'installedProgramNames') -or ($d.PSObject.Properties.Name -contains 'wingetIds'))
            if (-not $hasShape) {
                $statusText.Text = 'The old machine sent something that is not a valid app export. Close this and try again.'
                return
            }
            $hostName = if ($d.hostname) { $d.hostname } else { 'the old machine' }
            $exportedAt = if ($d.exportedAt) { $d.exportedAt } else { 'unknown time' }
            # Count real entries only: @($null).Count is 1 in PowerShell, so an export that
            # lacks one of the lists would claim "1 winget app(s)".
            $wingetIds = @($d.wingetIds | Where-Object { $_ })
            $programNames = @($d.installedProgramNames | Where-Object { $_ })
            $wingetCount = $wingetIds.Count
            $nameCount = $programNames.Count
            # Confirm the received machine before applying it - the one-time claim is
            # best-effort on eventually-consistent storage, so let the tech eyeball it.
            $confirm = [System.Windows.MessageBox]::Show(
                "Received an app list from:`n`n  $hostName  (exported $exportedAt)`n  $wingetCount winget app(s), $nameCount program name(s)`n`nCompare this machine against it?",
                'Gr3y Tools', 'YesNo', 'Question')
            if ($confirm -ne 'Yes') { $dialog.Close(); return }
            $baseline = [PSCustomObject]@{
                hostname = $hostName
                exportedAt = $exportedAt
                wingetIds = $wingetIds
                installedProgramNames = $programNames
            }
            $dialog.Close()
            Set-CompareBaseline -Baseline $baseline
        } elseif ($result -and $result.Kind -eq 'session') {
            $statusText.Text = 'This pairing session is no longer valid. Close this and try again.'
        } elseif ($result -and $result.Kind -eq 'invalid') {
            $statusText.Text = $result.Detail
        } else {
            $extra = if ($result -and $result.Detail) { " (last error: $($result.Detail))" } else { '' }
            $statusText.Text = "Timed out - no data received in 10 minutes$extra. Close this and try again if needed."
        }
    }.GetNewClosure())
    $checkTimer.Start()

    $btnCancelPairing.Add_Click({ $dialog.Close() }.GetNewClosure())
    $dialog.Add_Closing($cleanup)

    $dialog.ShowDialog() | Out-Null
}

function Set-CompareBaseline {
    param([Parameter(Mandatory)][PSCustomObject]$Baseline)
    $script:installPendingAction = [PSCustomObject]@{ Action = 'compare'; Baseline = $Baseline }
    Start-InstalledCheck
}

function Import-CompareBaselineFromFile {
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
    Set-CompareBaseline -Baseline $baseline
}

$btnCompareBaseline.Add_Click({
    if ($script:installProc -and -not $script:installProc.HasExited) { return }
    # Re-entrancy guard: two quick activations (a double-click, a held Enter) would stack two
    # chooser dialogs, because each one runs its own nested message loop.
    if ($script:compareFlowOpen) { return }
    $script:compareFlowOpen = $true
    try {
        # Loop so "Manage Access Codes..." returns to the chooser afterwards instead of
        # closing the whole flow.
        do {
            $choice = Show-CompareSourceChooser
            if ($choice -eq 'manage') { Show-AccessCodesDialog }
        } while ($choice -eq 'manage')
        switch ($choice) {
            'file' { Import-CompareBaselineFromFile }
            'pair' { Show-PairingDialog }
        }
    } finally {
        $script:compareFlowOpen = $false
    }
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
    # Forget the killed process: left in place, the poll timer sees it as a job that just
    # finished and overwrites "Stopped." with a wrong "Done" status a moment later.
    $script:installProc = $null
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
                    # Two different sets, deliberately - $matchedCatalogNames is only the
                    # ones auto-checked (missing here, ready to install); $accountedCatalogNames
                    # is every catalog entry that explains a baseline name at all, whether or
                    # not it still needs installing. Using only $matchedCatalogNames to filter
                    # the unmatched list below was the bug: a catalog app already installed
                    # here (e.g. .NET Desktop Runtime 10, already present in some version) hit
                    # `continue` before ever being recorded, so every baseline name it should
                    # have explained - all five .NET 10 component names, VC++ redist variants,
                    # whatever - fell through into "no catalog match, install manually" even
                    # though there genuinely was a match. It just didn't need installing.
                    $matchedCatalogNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                    $accountedCatalogNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                    $alreadyInstalledNames = New-Object System.Collections.Generic.List[string]
                    foreach ($entry in $script:appEntries) {
                        # Reset first - a second Compare run (a different export file, or a
                        # re-run after installing some of the first batch) must not leave
                        # last time's matches stuck: the Compare Results view, the ticks and
                        # the "(missing - on old machine)" labels all go back to normal, or
                        # Install Selected would install rows the new result no longer lists.
                        if ($entry.CompareMatch) {
                            $entry.CheckBox.IsChecked = $false
                            $entry.CheckBox.ClearValue([System.Windows.Controls.Control]::ForegroundProperty)
                            $entry.CheckBox.Content = $entry.Name
                        }
                        $entry.CompareMatch = $false
                        $onBaseline = ($entry.WingetId -and ($baseline.wingetIds -contains $entry.WingetId)) -or
                                      [bool]($baseline.installedProgramNames | Where-Object { $_ -and (($_ -like "*$($entry.Name)*") -or (Test-DotNetRuntimeNameMatch -CatalogName $entry.Name -CandidateName $_)) } | Select-Object -First 1)
                        if (-not $onBaseline) { continue }
                        [void]$accountedCatalogNames.Add($entry.Name)
                        $alreadyHere = ($entry.WingetId -and $installedIds.Contains($entry.WingetId)) -or
                                       [bool]($currentProgramNames | Where-Object { $_ -and (($_ -like "*$($entry.Name)*") -or (Test-DotNetRuntimeNameMatch -CatalogName $entry.Name -CandidateName $_)) } | Select-Object -First 1)
                        if ($alreadyHere) {
                            $alreadyInstalledNames.Add($entry.Name)
                            continue
                        }
                        $entry.CheckBox.IsChecked = $true
                        $entry.CheckBox.Foreground = $accentBrush
                        $entry.CheckBox.Content = "$($entry.Name) (missing - on old machine)"
                        $entry.CompareMatch = $true
                        [void]$matchedCatalogNames.Add($entry.Name)
                        $matchedCount++
                    }
                    $alreadyInstalledNames = @($alreadyInstalledNames | Sort-Object -Unique)
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
                        foreach ($catalogName in $accountedCatalogNames) {
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
                        # previous run, and hide its button - it would only list nothing.
                        $catCompareResultsBtn.Visibility = 'Collapsed'
                        if ($script:activeCategory -eq 'Compare Results') {
                            $script:activeCategory = 'Business Baseline'
                            Update-AppVisibility
                        }
                    }
                    $lines.Add('')
                    if ($alreadyInstalledNames.Count -gt 0) {
                        $lines.Add("$($alreadyInstalledNames.Count) catalog app(s) already installed here - not offered again (old machine's copy isn't needed; this machine's installed version may be newer):")
                        foreach ($n in $alreadyInstalledNames) { $lines.Add("  - $n") }
                        $lines.Add('')
                    }
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
