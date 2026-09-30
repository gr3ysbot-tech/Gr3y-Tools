<#
.SYNOPSIS
    Debloats a Dell or Lenovo business laptop and deploys Microsoft 365 Apps for business (en-us only).

.DESCRIPTION
    Three phases, each independently toggle-able:
      1. Remove known Dell/Lenovo OEM bloatware (AppX/MSIX apps + Win32 programs) and preloaded McAfee trialware.
      2. Fully remove any existing Office installation (Click-to-Run and/or MSI-based), which also clears
         out every preinstalled Office display/proofing language in one step.
      3. Install Microsoft 365 Apps for business via the Office Deployment Tool (ODT), en-us only.

    Run in -DryRun first on a representative model to review exactly what would be removed before
    rolling out silently across a fleet.

.PARAMETER DryRun
    List what would be removed/installed without making any changes.

.PARAMETER CreateRestorePoint
    Create a System Restore point before making any changes. Off by default when this
    script is run standalone/from the command line; the GUI surfaces it as a checkbox
    that defaults to checked (recommended) and passes this flag explicitly either way.
    Windows throttles restore point creation to one per 24 hours and some OEM images
    ship with System Protection disabled by policy, so it won't always succeed - a
    failure here is logged as a warning and never blocks the rest of the run.

.PARAMETER SkipDebloat
    Skip OEM (Dell/Lenovo) bloatware / McAfee removal (phase 1).

.PARAMETER Dell
.PARAMETER Lenovo
    Limit phase 1 to the selected OEM's patterns (generic bloat like McAfee/Dropbox/
    Widgets/Teams always runs regardless, since it isn't OEM-specific). If NEITHER is
    passed, both run - this is the safe default for standalone/command-line use; the
    GUI always passes at least one explicitly based on its checkboxes.

.PARAMETER TweakReduceTelemetry
    Set AllowTelemetry=0, disable the DiagTrack service, and disable the Activity
    Feed (publish/upload) registry values. Off by default.

.PARAMETER TweakDisableHibernation
    Run "powercfg /hibernate off" to remove hiberfil.sys and free its disk space.
    Off by default.

.PARAMETER TweakPreventSleep
    Set system sleep timeout to Never on both AC and battery, so the machine
    stays reachable for remote support/management tools instead of dropping off
    the network. Display timeout is left untouched, so the screen still locks
    for security. Off by default - on battery this trades battery life for
    availability, so only enable it where that tradeoff makes sense.

.PARAMETER TweakDisableSmartAppControl
    Turn off Windows Smart App Control, which on a clean Windows 11 22H2+
    image hard-blocks unsigned/low-reputation installers with no user-facing
    override - several apps in the Install Apps catalog will otherwise fail
    to install. Off by default: this is a one-way change on a real machine
    (Smart App Control cannot be turned back on without reinstalling Windows),
    so only enable it where that tradeoff is acceptable.

.PARAMETER InstallOemUpdateTool
    Installs the OEM's own driver/BIOS/firmware update utility if this machine is
    genuinely Dell or Lenovo, it looks like a supported commercial model (not a
    consumer line - Inspiron/Alienware, IdeaPad/Yoga/Legion), and it isn't already
    installed: Dell Command | Update (winget id Dell.CommandUpdate) or Lenovo System
    Update (winget id Lenovo.SystemUpdate). Neither vendor publishes an exhaustive
    supported-model list, so a winget install failure on a genuine commercial machine
    is logged as a warning, not treated as a hard error.

.PARAMETER CustomizeTweaks
    Comma-separated "Key=on" / "Key=off" pairs of Windows preference tweaks to apply (see
    tweaks.json, which must sit next to this script, for the full key list and each key's
    on/off registry values). Reversible: "off" writes the tweak's documented original value
    (or removes the registry value entirely, where that's what turning it off means).
    Restarts Explorer once at the end if any selected tweak needs it.

.PARAMETER DnsPreset
    Sets DNS servers on active physical network adapters (never virtual/VPN adapters) to
    a named preset (Google, Cloudflare, Cloudflare_Malware, Cloudflare_Malware_Adult,
    Open_DNS, Quad9, AdGuard_Ads_Trackers, AdGuard_Ads_Trackers_Malware_Adult) or back to
    DHCP. 'Default' (or omitted) makes no change. Refuses on a domain-joined machine
    unless -DnsForce is also passed, since a public resolver can break domain sign-in and
    internal name resolution. Registry/IP values sourced from ChrisTitusTech/winutil's
    config/tweaks.json and config/dns.json.

.PARAMETER DnsForce
    Applies -DnsPreset even on a domain-joined machine. Off by default - see DnsPreset.

.PARAMETER FixSystemRepair
    Run sfc /scannow then DISM /Online /Cleanup-Image /RestoreHealth. Can take
    10-20+ minutes. Off by default - intended to be triggered standalone from the
    GUI's Fixes tab, not bundled into a normal debloat/Office run.

.PARAMETER FixNetworkReset
    Reset Winsock and the TCP/IP stack, then flush DNS. Requires a reboot to fully
    take effect. Off by default - standalone Fixes-tab action.

.PARAMETER FixWindowsUpdateReset
    Stop the Windows Update-related services, clear the SoftwareDistribution and
    Catroot2 caches, and restart the services - the standard fix for a stuck/broken
    Windows Update. Off by default - standalone Fixes-tab action.

.PARAMETER FixWinGetReinstall
    Re-register the App Installer (winget) package for the current user, the
    standard fix when winget itself is missing or broken. Off by default -
    standalone Fixes-tab action.

.PARAMETER SkipOfficeRemoval
    Skip removing existing Office installs (phase 2).

.PARAMETER SkipOfficeInstall
    Skip installing Microsoft 365 Apps for business (phase 3).

.PARAMETER OfficeChannel
    Update channel for the new Office install. Default: MonthlyEnterprise (recommended for managed
    business fleets - monthly security updates, less feature churn than Current Channel).
    Valid values: Current, MonthlyEnterprise, SemiAnnual, SemiAnnualPreview.

.PARAMETER OfficeLanguage
    Language to install. Default: en-us.

.PARAMETER NoReboot
    Suppress the end-of-run reboot prompt (still logs that a reboot is recommended).

.EXAMPLE
    .\Deploy-DellOfficeSetup.ps1 -DryRun
    Preview everything with no changes made.

.EXAMPLE
    .\Deploy-DellOfficeSetup.ps1
    Full run: debloat, remove old Office, install Microsoft 365 Apps for business (en-us).

.EXAMPLE
    .\Deploy-DellOfficeSetup.ps1 -SkipDebloat -OfficeChannel Current
    Office-only redeploy on the Current channel, Dell software left alone.

.NOTES
    Run elevated (Administrator). Requires internet access to officecdn.microsoft.com.
    Activation of Microsoft 365 Apps for business happens on first launch via user sign-in against
    your Microsoft 365 tenant (shared/user-based activation) - no product key or KMS needed.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$CreateRestorePoint,
    [switch]$SkipDebloat,
    [switch]$Dell,
    [switch]$Lenovo,
    [switch]$SkipOfficeRemoval,
    [switch]$SkipOfficeInstall,
    [ValidateSet('Current', 'MonthlyEnterprise', 'SemiAnnual', 'SemiAnnualPreview')]
    [string]$OfficeChannel = 'MonthlyEnterprise',
    [string]$OfficeLanguage = 'en-us',
    [switch]$NoReboot,
    [switch]$TweakReduceTelemetry,
    [switch]$TweakDisableHibernation,
    [switch]$TweakPreventSleep,
    [switch]$TweakDisableSmartAppControl,
    [switch]$InstallOemUpdateTool,
    [string]$CustomizeTweaks = '',
    [string]$DnsPreset = '',
    [switch]$DnsForce,
    [switch]$FixSystemRepair,
    [switch]$FixNetworkReset,
    [switch]$FixWindowsUpdateReset,
    [switch]$FixWinGetReinstall
)

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $PSCommandPath
$workDir = Join-Path $env:ProgramData 'DellOfficeDeploy'
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

# Tag the log filename with the machine it ran on, since these logs accumulate across
# many different client laptops over time - a bare timestamp alone isn't enough to
# identify which machine a log came from once you're not looking at it live.
function Get-SafeFileNamePart {
    param([string]$Value)
    if (-not $Value) { return 'Unknown' }
    $clean = ($Value -replace '[\\/:*?"<>|]', '') -replace '\s+', '-'
    $clean = $clean.Trim('-')
    if (-not $clean) { return 'Unknown' }
    return $clean
}

$cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
$bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
$csProduct = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue

$machineHost = $env:COMPUTERNAME
$machineManufacturer = if ($cs -and $cs.Manufacturer) { $cs.Manufacturer } else { 'UnknownMfr' }
# On Lenovo, Win32_ComputerSystem.Model is the internal machine-type code (e.g.
# "21AHCTO1WW"), not the name printed on the box - the marketing/friendly name
# (e.g. "ThinkPad X1 Carbon Gen 10") is Win32_ComputerSystemProduct.Version instead.
# Dell (and everyone else) puts the real model name in Win32_ComputerSystem.Model,
# so only switch sources for Lenovo.
$machineModel =
    if ($machineManufacturer -match 'Lenovo' -and $csProduct -and $csProduct.Version) { $csProduct.Version }
    elseif ($cs -and $cs.Model) { $cs.Model }
    else { 'UnknownModel' }
$machineSerial = if ($bios -and $bios.SerialNumber) { $bios.SerialNumber } else { 'UnknownSerial' }

$logIdentifier = "{0}_{1}-{2}_{3}" -f `
    (Get-SafeFileNamePart $machineHost), `
    (Get-SafeFileNamePart $machineManufacturer), `
    (Get-SafeFileNamePart $machineModel), `
    (Get-SafeFileNamePart $machineSerial)

$logPath = Join-Path $workDir "run_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$logIdentifier.log"
Start-Transcript -Path $logPath -Append | Out-Null

$script:errorCount = 0

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    if ($Level -eq 'WARN' -or $Level -eq 'ERROR') { $script:errorCount++ }
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
}

Write-Log "Worker PID: $PID"
Write-Log "Machine: $machineHost | $machineManufacturer $machineModel | Serial/Service Tag: $machineSerial"
if ($osInfo) {
    Write-Log "OS: $($osInfo.Caption) (Build $($osInfo.BuildNumber)) | Logged-in user: $env:USERNAME"
}

function Invoke-Step {
    param([string]$Description, [scriptblock]$Action)
    if ($DryRun) {
        Write-Log "DRYRUN: $Description" 'DRYRUN'
    } else {
        Write-Log $Description
        & $Action
    }
}

function New-PreDeploySystemRestorePoint {
    Invoke-Step 'Creating a System Restore point before making any changes' {
        $freqKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $freqName = 'SystemRestorePointCreationFrequency'
        $restorePointDescription = 'Gr3y Tools - before debloat/Office deploy'
        $hadOriginalFreq = $false
        $originalFreq = $null
        try {
            $existing = Get-ItemProperty -Path $freqKey -Name $freqName -ErrorAction SilentlyContinue
            if ($existing) { $originalFreq = $existing.$freqName; $hadOriginalFreq = $true }
        } catch {}

        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
            # Windows silently skips creating a new restore point if one was already made
            # in the last 24h (the default throttle) - drop the frequency to 0 for this one
            # call so ours actually gets created, then put the original value back below.
            New-Item -Path $freqKey -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path $freqKey -Name $freqName -Value 0 -Type DWord -ErrorAction SilentlyContinue

            Checkpoint-Computer -Description $restorePointDescription -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop

            $point = Get-ComputerRestorePoint -ErrorAction SilentlyContinue |
                Where-Object { $_.Description -eq $restorePointDescription } |
                Sort-Object SequenceNumber -Descending | Select-Object -First 1
            if ($point) {
                Write-Log "System Restore point created (SequenceNumber $($point.SequenceNumber))."
            } else {
                Write-Log 'Checkpoint-Computer reported success but no matching restore point was found afterward - verify manually.' 'WARN'
            }
        } catch {
            Write-Log "Could not create a System Restore point (often blocked by policy, or Windows allows only one per 24h): $($_.Exception.Message)" 'WARN'
        } finally {
            try {
                if ($hadOriginalFreq) {
                    Set-ItemProperty -Path $freqKey -Name $freqName -Value $originalFreq -Type DWord -ErrorAction SilentlyContinue
                } else {
                    Remove-ItemProperty -Path $freqKey -Name $freqName -ErrorAction SilentlyContinue
                }
            } catch {}
        }
    }
}

# ============================================================================
# PHASE 1 - OEM bloatware (Dell + Lenovo) + McAfee removal
# ============================================================================

# Bloat detection patterns (AppX/Win32/scheduled-task/service) live in
# bloat-patterns.json, which must sit next to this script - shared with
# Gr3ysUtilities.ps1's Scan feature so both read from one source of truth
# instead of two copies that could drift apart. Deliberately NOT included in any
# of these: DellInc.DellCommandUpdate (driver update tool - keep for IT), Dell
# display/audio drivers (not AppX packages), Dell.SupportAssistAgent core service
# if your org actively uses SupportAssist for Business, and the Lenovo Vantage /
# Commercial Vantage + System Interface Foundation packages (keep for driver/BIOS
# updates and fan/thermal control - same reasoning as Dell Command Update).
$patternsPath = Join-Path $scriptDir 'bloat-patterns.json'
if (-not (Test-Path $patternsPath)) {
    Write-Log "ERROR: bloat-patterns.json not found next to this script at $patternsPath" 'ERROR'
    Stop-Transcript | Out-Null
    exit 1
}
$bloatPatterns = Get-Content -Path $patternsPath -Raw | ConvertFrom-Json

# Customize Preferences tweak definitions live in tweaks.json (must also sit next to
# this script) - shared with Gr3ysUtilities.ps1, which reads it to build the toggle list
# and to read each tweak's live current state, so both sides read one source of truth.
$tweaksJsonPath = Join-Path $scriptDir 'tweaks.json'
if (-not (Test-Path $tweaksJsonPath)) {
    Write-Log "ERROR: tweaks.json not found next to this script at $tweaksJsonPath" 'ERROR'
    Stop-Transcript | Out-Null
    exit 1
}
$script:tweakDefs = @{}
foreach ($tweakDef in (Get-Content -Path $tweaksJsonPath -Raw | ConvertFrom-Json).tweaks) {
    $script:tweakDefs[$tweakDef.key] = $tweakDef
}

# Which OEM section(s) to actually check - avoids matching Lenovo patterns on a
# known-Dell machine (and vice versa) when the operator already knows the brand.
# Generic bloat (McAfee/Dropbox/Widgets/Teams) isn't OEM-specific, so it always runs.
$script:selectedOems = @()
if ($Dell) { $script:selectedOems += 'dell' }
if ($Lenovo) { $script:selectedOems += 'lenovo' }
if ($script:selectedOems.Count -eq 0) { $script:selectedOems = @('dell', 'lenovo') }

$OemBloatAppxPatterns = @($bloatPatterns.generic.appxPatterns)
$Win32BloatPatterns = @($bloatPatterns.generic.win32Patterns)
$OemTaskFolders = @()
$OemTaskKeepPatterns = @()
$OemServicePatterns = @()
foreach ($oemName in $script:selectedOems) {
    $section = $bloatPatterns.$oemName
    if (-not $section) { continue }
    $OemBloatAppxPatterns += $section.appxPatterns
    $Win32BloatPatterns += $section.win32Patterns
    $OemTaskFolders += $section.scheduledTaskFolders
    $OemTaskKeepPatterns += $section.scheduledTaskKeepPatterns
    $OemServicePatterns += $section.servicePatterns
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

function Invoke-ThrottledSteps {
    # Runs a batch of independent script actions in a bounded runspace pool
    # (default 3 at a time) instead of fully serial or fully unbounded-parallel.
    # Each Action must be self-contained (no closures over outer variables) -
    # pass inputs via Args, since runspaces don't share the caller's scope.
    param(
        [System.Collections.Generic.List[hashtable]]$Steps,
        [int]$MaxConcurrency = 3
    )
    if ($DryRun) {
        foreach ($step in $Steps) { Write-Log "DRYRUN: $($step.Description)" 'DRYRUN' }
        return
    }
    if ($Steps.Count -eq 0) { return }

    $pool = [runspacefactory]::CreateRunspacePool(1, $MaxConcurrency)
    $pool.Open()
    $handles = New-Object System.Collections.Generic.List[object]

    foreach ($step in $Steps) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($step.Action)
        if ($step.Args) {
            foreach ($key in $step.Args.Keys) {
                [void]$ps.AddParameter($key, $step.Args[$key])
            }
        }
        $handle = $ps.BeginInvoke()
        $handles.Add([pscustomobject]@{ PowerShell = $ps; Handle = $handle; Description = $step.Description })
    }

    # Log from the main thread only - Start-Transcript doesn't capture output
    # written inside separate runspaces, and it keeps the log file write single-threaded.
    foreach ($item in $handles) {
        try {
            $item.PowerShell.EndInvoke($item.Handle) | Out-Null
            Write-Log $item.Description
        } catch {
            Write-Log "Failed: $($item.Description) - $($_.Exception.Message)" 'WARN'
        } finally {
            # -ErrorAction SilentlyContinue inside an Action still records a non-terminating
            # error to this runspace's own error stream - it just stops it from throwing or
            # printing. Without checking Streams.Error here, a step that silently failed
            # (e.g. DISM refusing to de-provision a package) got logged as if it succeeded.
            foreach ($err in $item.PowerShell.Streams.Error) {
                Write-Log "$($item.Description) reported an error: $($err.ToString())" 'WARN'
            }
            $item.PowerShell.Dispose()
        }
    }

    $pool.Close()
    $pool.Dispose()
}

function Start-ProcessLowPriority {
    # Launches an uninstaller at BelowNormal process priority so it yields to
    # whatever else is using the machine (remote session, foreground apps)
    # instead of competing for CPU/disk at full priority. Bounded wait - a wrong
    # silent flag can pop an interactive dialog on a -WindowStyle Hidden process,
    # which would otherwise block this step (and the whole run) forever.
    param(
        [string]$FilePath,
        [string]$ArgumentList,
        [int]$TimeoutMs = 600000
    )
    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
    if ($proc) {
        try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
        $exited = $proc.WaitForExit($TimeoutMs)
        if (-not $exited) {
            Write-Log "Uninstaller '$FilePath' did not exit within $($TimeoutMs / 1000)s (likely showing a dialog with the wrong silent flag) - killing it." 'WARN'
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

function Remove-OemBloatware {
    Write-Log '--- Phase 1: Removing OEM (Dell/Lenovo) bloatware and McAfee trialware ---'

    # --- AppX packages (installed for all existing users, and de-provision so new
    #     user profiles don't get them reinstalled) ---
    # Query once and filter in memory - Get-AppxProvisionedPackage -Online is a slow
    # DISM-backed call, and running it once per pattern (instead of once total) was
    # the main source of the CPU/disk spike during this phase.
    $allInstalledAppx = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    $allProvisionedAppx = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue

    # AppX removals are cheap and independent of each other, so a few run at once
    # in a bounded pool instead of one at a time - real time drops without the
    # machine-choking effect an unbounded parallel pass would cause.
    # No -ErrorAction SilentlyContinue here - inside a separate [powershell] runspace
    # instance, SilentlyContinue/Ignore stop the error from ever reaching that
    # instance's own Streams.Error collection, which is what Invoke-ThrottledSteps reads
    # to log a WARN afterward. Leaving ErrorAction at its default lets a failed
    # removal/de-provision show up there without throwing (non-terminating by default)
    # and without printing to a console no one's attached to.
    $appxRemoveAction = { param($FullName) Remove-AppxPackage -Package $FullName -AllUsers }
    $appxDeprovisionAction = { param($PackageName) Remove-AppxProvisionedPackage -Online -PackageName $PackageName | Out-Null }

    $appxRemoveSteps = New-Object System.Collections.Generic.List[hashtable]
    $appxDeprovisionSteps = New-Object System.Collections.Generic.List[hashtable]
    foreach ($pattern in $OemBloatAppxPatterns) {
        $installed = $allInstalledAppx | Where-Object { $_.Name -like $pattern }
        foreach ($pkg in $installed) {
            $appxRemoveSteps.Add(@{
                Description = "Removing AppX package: $($pkg.PackageFullName)"
                Action = $appxRemoveAction
                Args = @{ FullName = $pkg.PackageFullName }
            })
        }
        $provisioned = $allProvisionedAppx | Where-Object { $_.DisplayName -like $pattern }
        foreach ($pkg in $provisioned) {
            $appxDeprovisionSteps.Add(@{
                Description = "De-provisioning AppX package: $($pkg.DisplayName)"
                Action = $appxDeprovisionAction
                Args = @{ PackageName = $pkg.PackageName }
            })
        }
    }
    if ($appxRemoveSteps.Count -gt 0) {
        Write-Log "Removing $($appxRemoveSteps.Count) AppX package(s) (up to 3 at a time)..."
    }
    Invoke-ThrottledSteps -Steps $appxRemoveSteps -MaxConcurrency 3

    # De-provisioning goes through DISM's online image API, which is not thread-safe for
    # concurrent in-process calls the way Remove-AppxPackage is - running these 3-wide
    # like the removals above silently corrupted/dropped some calls. MaxConcurrency 1
    # keeps them on the same Invoke-ThrottledSteps/Streams.Error plumbing but strictly serial.
    if ($appxDeprovisionSteps.Count -gt 0) {
        Write-Log "De-provisioning $($appxDeprovisionSteps.Count) AppX package(s) (serially - DISM's online API isn't safe to call concurrently)..."
    }
    Invoke-ThrottledSteps -Steps $appxDeprovisionSteps -MaxConcurrency 1

    if ($appxDeprovisionSteps.Count -gt 0 -and -not $DryRun) {
        $stillProvisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        foreach ($pattern in $OemBloatAppxPatterns) {
            $remaining = $stillProvisioned | Where-Object { $_.DisplayName -like $pattern }
            foreach ($pkg in $remaining) {
                Write-Log "Still provisioned after de-provisioning pass: $($pkg.DisplayName) - may need a manual Remove-AppxProvisionedPackage or a reboot." 'WARN'
            }
        }
    }

    # --- Win32 programs, via their own registry uninstall string ---
    # (Previously also tried winget first on every match, but the registry uninstall
    # string below always ran anyway - winget rarely recognizes OEM-bundled software
    # by name, so it was pure added latency for no extra removals.)
    # These stay serial - Windows Installer serializes MSI operations internally
    # regardless, so "parallel" here would just queue up and fail with "another
    # installation is already in progress." Instead: run each uninstaller at
    # BelowNormal priority and pause briefly between them so disk/AV activity
    # has a moment to settle instead of stacking back-to-back at full throttle.
    $entries = Get-UninstallEntries

    foreach ($pattern in $Win32BloatPatterns) {
        $matches = $entries | Where-Object { $_.DisplayName -like $pattern }
        foreach ($match in $matches) {
            $name = $match.DisplayName
            Invoke-Step "Uninstalling: $name" {
                # QuietUninstallString, when the vendor provides one, is already the
                # correct fully-silent command line - trust it over any guessing below.
                $uninstallString = if ($match.QuietUninstallString) { $match.QuietUninstallString } else { $match.UninstallString }
                if ($uninstallString) {
                    if ($uninstallString -match 'msiexec') {
                        # PSChildName is the registry key name, which for some Dell entries
                        # is a product name, not the GUID - pull the real GUID out of the
                        # uninstall string itself instead.
                        $guidMatch = [regex]::Match($uninstallString, '\{[0-9A-Fa-f-]{36}\}')
                        $productCode = if ($guidMatch.Success) { $guidMatch.Value } else { $match.PSChildName }
                        Write-Log "Running msiexec /x $productCode /qn /norestart for '$name' (low priority)"
                        Start-ProcessLowPriority -FilePath 'msiexec.exe' -ArgumentList "/x $productCode /qn /norestart"
                    } else {
                        # Parse "path" and any trailing args separately - the old
                        # (-replace '"','') -split ' ' approach truncated any quoted path
                        # containing a space (e.g. "C:\Program Files\...") to just the
                        # first word, so Test-Path always failed and no EXE uninstaller
                        # under Program Files ever actually ran.
                        $exe = $null
                        $existingArgs = ''
                        $quotedMatch = [regex]::Match($uninstallString, '^"([^"]+)"\s*(.*)$')
                        if ($quotedMatch.Success) {
                            $exe = $quotedMatch.Groups[1].Value
                            $existingArgs = $quotedMatch.Groups[2].Value
                        } else {
                            $bareMatch = [regex]::Match($uninstallString, '^(\S+?\.exe)\s*(.*)$')
                            if ($bareMatch.Success) {
                                $exe = $bareMatch.Groups[1].Value
                                $existingArgs = $bareMatch.Groups[2].Value
                            }
                        }

                        if ($exe -and (Test-Path $exe)) {
                            $silentArgs =
                                if ((Split-Path -Leaf $exe) -match '^unins\d*\.exe$') {
                                    # Inno Setup's own uninstaller - this is its documented silent switch set.
                                    '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
                                } elseif ($existingArgs) {
                                    # The vendor's own uninstall string already carries flags - trust them
                                    # rather than guessing over the top of a command that was tested to work.
                                    $existingArgs
                                } else {
                                    # No args at all in the registry string - /S is the most common silent
                                    # switch across NSIS-based uninstallers, which covers most of the rest.
                                    '/S'
                                }
                            Write-Log "Running '$exe' $silentArgs for '$name' (low priority)"
                            Start-ProcessLowPriority -FilePath $exe -ArgumentList $silentArgs
                        } else {
                            Write-Log "Could not resolve an uninstaller executable from '$uninstallString' for '$name' - skipping." 'WARN'
                        }
                    }
                }
            }
            if (-not $DryRun) { Start-Sleep -Milliseconds 400 }
        }
    }

    Write-Log 'OEM bloatware / McAfee removal pass complete.'
    Write-Log 'If McAfee remnants remain (rare once the MSI above runs cleanly), download the official removal tool from https://www.mcafee.com/en-us/consumer-support/mcpr.html and run it manually - it is designed to run interactively.'
}

function Disable-OemScheduledTasksAndServices {
    Write-Log '--- Phase 1b: Disabling leftover OEM scheduled tasks/services ---'

    # OEMs create their own Task Scheduler folders. Uninstalling the app alone often
    # leaves a scheduled task behind that silently re-triggers/reinstalls it later -
    # disable (not delete, so it stays reversible) everything under \Dell\ and
    # \Lenovo\ except the driver/BIOS update tooling deliberately kept installed
    # above (Dell Command Update, Lenovo Vantage).
    foreach ($folder in $OemTaskFolders) {
        $tasks = Get-ScheduledTask -TaskPath "$folder*" -ErrorAction SilentlyContinue
        foreach ($task in $tasks) {
            # Match against the full path + name, not just the name - Dell Command
            # Update's tasks live under \Dell\CommandUpdate\ with task names that don't
            # necessarily contain "CommandUpdate" themselves, and Lenovo Vantage depends
            # on the \Lenovo\ImController\ System Interface Foundation tasks, which a
            # name-only "*Vantage*" pattern never matches.
            $fullTaskPath = "$($task.TaskPath)$($task.TaskName)"
            $isKept = $false
            foreach ($keep in $OemTaskKeepPatterns) {
                if ($fullTaskPath -like $keep) { $isKept = $true; break }
            }
            if ($isKept -or $task.State -eq 'Disabled') { continue }
            Invoke-Step "Disabling scheduled task: $($task.TaskPath)$($task.TaskName)" {
                Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }

    # Same bloat keywords used for the Win32 program removal above, matched against
    # Windows services instead - disabling stops the app respawning itself even when
    # its uninstaller didn't clean up its service registration.
    foreach ($pattern in $OemServicePatterns) {
        $services = Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $pattern -or $_.Name -like $pattern }
        foreach ($svc in $services) {
            Invoke-Step "Disabling service: $($svc.DisplayName) ($($svc.Name))" {
                Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
                Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Log 'OEM scheduled task / service cleanup pass complete.'
}

# ============================================================================
# TWEAKS - opt-in preference changes, bundled into a normal run alongside debloat
# ============================================================================

function Set-TelemetryReduced {
    Invoke-Step 'Reducing telemetry and activity tracking' {
        try {
            New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 0 -Type DWord -ErrorAction SilentlyContinue

            New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'EnableActivityFeed' -Value 0 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'PublishUserActivities' -Value 0 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'UploadUserActivities' -Value 0 -Type DWord -ErrorAction SilentlyContinue

            Stop-Service -Name DiagTrack -Force -ErrorAction SilentlyContinue
            Set-Service -Name DiagTrack -StartupType Disabled -ErrorAction SilentlyContinue

            Write-Log 'Telemetry and activity tracking reduced (AllowTelemetry=0, Activity Feed disabled, DiagTrack service disabled).'
        } catch {
            Write-Log "Could not fully apply the telemetry tweak: $($_.Exception.Message)" 'WARN'
        }
    }
}

function Disable-Hibernation {
    Invoke-Step 'Disabling hibernation (frees hiberfil.sys disk space)' {
        powercfg /hibernate off 2>&1 | ForEach-Object { Write-Log "powercfg: $_" }
    }
}

function Set-SleepNever {
    Invoke-Step 'Setting sleep to Never on AC and battery (display timeout left as-is)' {
        powercfg /change standby-timeout-ac 0 2>&1 | ForEach-Object { Write-Log "powercfg: $_" }
        powercfg /change standby-timeout-dc 0 2>&1 | ForEach-Object { Write-Log "powercfg: $_" }
        Write-Log 'Sleep timeout set to Never (AC and battery). The screen will still lock on its own timeout for security - only system sleep was disabled, so the machine stays reachable for remote support/management.'
    }
}

function Disable-SmartAppControl {
    Invoke-Step 'Disabling Smart App Control (one-way until a clean Windows reinstall)' {
        try {
            $ciPolicyPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
            $current = (Get-ItemProperty -Path $ciPolicyPath -Name 'VerifiedAndReputablePolicyState' -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
            if ($null -eq $current) {
                Write-Log 'Smart App Control policy value not present - likely already off or not available on this Windows edition/build. Nothing to do.'
                return
            }
            if ($current -eq 0) {
                Write-Log 'Smart App Control is already off.'
                return
            }
            New-Item -Path $ciPolicyPath -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path $ciPolicyPath -Name 'VerifiedAndReputablePolicyState' -Value 0 -Type DWord -ErrorAction Stop
            Write-Log 'Smart App Control disabled. Takes full effect after the next reboot. This cannot be turned back on without reinstalling Windows.'
        } catch {
            Write-Log "Could not disable Smart App Control: $($_.Exception.Message)" 'WARN'
        }
    }
}

function Install-OemUpdateTool {
    Invoke-Step 'Checking for the OEM update tool (Dell Command Update / Lenovo System Update)' {
        if (-not (Get-Command 'winget.exe' -ErrorAction SilentlyContinue)) {
            Write-Log 'winget not found - cannot install the OEM update tool. Run the Install winget fix first.' 'WARN'
            return
        }

        $isDell = $machineManufacturer -match 'Dell'
        $isLenovo = $machineManufacturer -match 'Lenovo'
        if (-not $isDell -and -not $isLenovo) {
            Write-Log "Manufacturer '$machineManufacturer' is neither Dell nor Lenovo - nothing to install."
            return
        }

        # Neither vendor publishes an exhaustive supported-model list, but both
        # explicitly exclude their consumer lines - Dell Command Update is Dell
        # commercial hardware only (Latitude/OptiPlex/Precision/business XPS-Vostro,
        # not Inspiron/Alienware); Lenovo System Update is Think* only, not
        # IdeaPad/Yoga/Legion. This only filters the unambiguous consumer names -
        # everything else is attempted and winget's own result is trusted.
        $consumerKeywords = if ($isDell) { @('Inspiron', 'Alienware') } else { @('IdeaPad', 'Yoga', 'Legion') }
        # "Yoga" alone would wrongly catch ThinkPad X1 Yoga / L13 Yoga / X13 Yoga, which
        # are commercial models System Update does support - exclude anything already
        # named ThinkPad from the Yoga match specifically.
        $looksConsumer = $consumerKeywords | Where-Object {
            $machineModel -match $_ -and -not ($_ -eq 'Yoga' -and $machineModel -match '^ThinkPad')
        }
        if ($looksConsumer) {
            Write-Log "Model '$machineModel' looks like a consumer line ($($looksConsumer -join ', ')) - Dell Command Update/Lenovo System Update only support commercial hardware. Skipping."
            return
        }

        $wingetId = if ($isDell) { 'Dell.CommandUpdate' } else { 'Lenovo.SystemUpdate' }
        $toolLabel = if ($isDell) { 'Dell Command | Update' } else { 'Lenovo System Update' }
        $displayNames = if ($isDell) { @('Dell Command | Update', 'Dell Command | Update for Windows Universal') } else { @('Lenovo System Update') }

        $uninstallEntries = Get-ItemProperty -Path @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        ) -ErrorAction SilentlyContinue
        $alreadyInstalled = $uninstallEntries | Where-Object { $_.DisplayName -in $displayNames } | Select-Object -First 1
        if ($alreadyInstalled) {
            Write-Log "$toolLabel is already installed ($($alreadyInstalled.DisplayName) $($alreadyInstalled.DisplayVersion)) - skipping."
            return
        }

        Write-Log "Installing $toolLabel ($wingetId) via winget..."
        try {
            $wingetOutput = & winget.exe install --id $wingetId -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
            $wingetOutput | ForEach-Object { Write-Log "winget: $_" }
            if ($LASTEXITCODE -eq 0) {
                Write-Log "$toolLabel installed successfully."
            } else {
                $vendorName = if ($isDell) { 'Dell' } else { 'Lenovo' }
                Write-Log "$toolLabel install exited with code $LASTEXITCODE - $vendorName doesn't publish an exhaustive supported-model list, so this can happen on a genuine but unsupported commercial model." 'WARN'
            }
        } catch {
            Write-Log "Could not install ${toolLabel}: $($_.Exception.Message)" 'WARN'
        }
    }
}

# $script:tweakDefs is loaded from tweaks.json above (shared with Gr3ysUtilities.ps1's
# toggle list and its live-state read). Each entry carries an onValue and offValue (a
# literal "<RemoveEntry>" offValue means delete the value rather than write one) - the
# GUI computes which keys actually changed since it loaded and sends "Key=on"/"Key=off"
# for each, so this is a real reversible apply, not a one-way-only tweak.
function Invoke-CustomizeTweaks {
    param([string[]]$Selections)

    $restartExplorer = $false
    foreach ($selection in $Selections) {
        $parts = $selection -split '=', 2
        if ($parts.Count -ne 2) { Write-Log "Malformed tweak selection: $selection" 'WARN'; continue }
        $key = $parts[0]
        $direction = $parts[1]
        if (-not $script:tweakDefs.ContainsKey($key)) { Write-Log "Unknown tweak key: $key" 'WARN'; continue }
        if ($direction -ne 'on' -and $direction -ne 'off') { Write-Log "Unknown tweak direction '$direction' for $key" 'WARN'; continue }
        $def = $script:tweakDefs[$key]
        Invoke-Step "Applying tweak: $($def.label) -> $direction" {
            try {
                if ($def.needsHKU -and -not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
                    New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script -ErrorAction Stop | Out-Null
                }
                foreach ($entry in $def.entries) {
                    $value = if ($direction -eq 'on') { $entry.onValue } else { $entry.offValue }
                    if ($value -eq '<RemoveEntry>') {
                        Remove-ItemProperty -Path $entry.path -Name $entry.name -ErrorAction SilentlyContinue
                    } else {
                        New-Item -Path $entry.path -Force -ErrorAction SilentlyContinue | Out-Null
                        Set-ItemProperty -Path $entry.path -Name $entry.name -Value $value -Type $entry.type -ErrorAction Stop
                    }
                }
                Write-Log "Applied: $($def.label) -> $direction"
            } catch {
                Write-Log "Could not apply '$($def.label)': $($_.Exception.Message)" 'WARN'
            }
        }
        if ($def.explorerRestart) { $restartExplorer = $true }
    }

    if ($restartExplorer) {
        Invoke-Step 'Restarting Explorer to apply visual changes' {
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            Start-Process explorer.exe
        }
    }
}

# IP addresses sourced verbatim from ChrisTitusTech/winutil's config/dns.json (main branch).
# DNS-over-HTTPS registration is intentionally not configured here - only the plain
# resolver IPv4/IPv6 addresses are set, which is what "change the DNS" means day to day.
$script:dnsPresets = @{
    'Google'                             = @{ V4 = @('8.8.8.8', '8.8.4.4'); V6 = @('2001:4860:4860::8888', '2001:4860:4860::8844') }
    'Cloudflare'                         = @{ V4 = @('1.1.1.1', '1.0.0.1'); V6 = @('2606:4700:4700::1111', '2606:4700:4700::1001') }
    'Cloudflare_Malware'                 = @{ V4 = @('1.1.1.2', '1.0.0.2'); V6 = @('2606:4700:4700::1112', '2606:4700:4700::1002') }
    'Cloudflare_Malware_Adult'           = @{ V4 = @('1.1.1.3', '1.0.0.3'); V6 = @('2606:4700:4700::1113', '2606:4700:4700::1003') }
    'Open_DNS'                           = @{ V4 = @('208.67.222.222', '208.67.220.220'); V6 = @('2620:119:35::35', '2620:119:53::53') }
    'Quad9'                              = @{ V4 = @('9.9.9.9', '149.112.112.112'); V6 = @('2620:fe::fe', '2620:fe::9') }
    'AdGuard_Ads_Trackers'               = @{ V4 = @('94.140.14.14', '94.140.15.15'); V6 = @('2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff') }
    'AdGuard_Ads_Trackers_Malware_Adult' = @{ V4 = @('94.140.14.15', '94.140.15.16'); V6 = @('2a10:50c0::bad1:ff', '2a10:50c0::bad2:ff') }
}

function Set-DnsPreset {
    param([string]$Preset, [switch]$DnsForce)

    if (-not $Preset -or $Preset -eq 'Default') {
        Write-Log 'DNS preset is Default - no change made.'
        return
    }

    # Forcing a public resolver on a domain-joined machine can break domain sign-in, GPO
    # and internal name resolution - refuse unless explicitly overridden.
    $csForDns = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($csForDns -and $csForDns.PartOfDomain -and -not $DnsForce) {
        Write-Log "This machine is domain-joined ($($csForDns.Domain)) - changing DNS to '$Preset' could break domain sign-in and internal name resolution. Not applying. Re-run with -DnsForce to override." 'WARN'
        return
    }

    Invoke-Step "Setting DNS to '$Preset' on active physical network adapters" {
        try {
            # -Physical, plus an explicit description exclusion, so this never touches
            # Hyper-V/VMware/WSL virtual adapters or VPN tunnel adapters - forcing a
            # public resolver onto a VPN adapter breaks split-DNS for internal names.
            $adapters = Get-NetAdapter -Physical -ErrorAction Stop | Where-Object {
                $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Virtual|Hyper-V|VPN|WAN Miniport|TAP|WireGuard'
            }
            if (-not $adapters) { Write-Log 'No active physical network adapters found - nothing to change.' 'WARN'; return }

            foreach ($adapter in $adapters) {
                # Log the current servers before changing anything, so DHCP isn't the only way back.
                $previous = Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue |
                    Where-Object { $_.ServerAddresses }
                foreach ($prevEntry in $previous) {
                    Write-Log "  $($adapter.Name) previous $($prevEntry.AddressFamily) servers: $($prevEntry.ServerAddresses -join ', ')"
                }

                if ($Preset -eq 'DHCP') {
                    Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
                    & netsh interface ip set dnsservers name="$($adapter.Name)" source=dhcp | Out-Null
                    & netsh interface ipv6 set dnsservers name="$($adapter.Name)" source=dhcp | Out-Null
                    Write-Log "  $($adapter.Name): DNS reset to DHCP"
                } elseif ($script:dnsPresets.ContainsKey($Preset)) {
                    $p = $script:dnsPresets[$Preset]
                    Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses ($p.V4 + $p.V6) -ErrorAction Stop
                    Write-Log "  $($adapter.Name): DNS set to $Preset ($($p.V4 -join ', '))"
                } else {
                    Write-Log "Unknown DNS preset: $Preset" 'WARN'
                    return
                }
            }
            Clear-DnsClientCache -ErrorAction SilentlyContinue
            Write-Log "DNS updated on $($adapters.Count) adapter(s)."
        } catch {
            Write-Log "Could not set DNS: $($_.Exception.Message)" 'WARN'
        }
    }
}

# ============================================================================
# FIXES - standalone one-click troubleshooting actions. Not bundled into a
# normal debloat/Office run; each is only invoked when its own flag is passed.
# ============================================================================

function Invoke-SystemRepair {
    Write-Log '--- Fix: Running System File Repair (chkdsk scan + sfc + DISM) - this can take 10-20+ minutes ---'

    Invoke-Step 'Running chkdsk /scan /perf (online, read-only scan of the system drive)' {
        $chkdskOutput = & chkdsk $env:SystemDrive /scan /perf 2>&1
        $chkdskExit = $LASTEXITCODE
        $chkdskOutput | Where-Object { $_ -and $_.Trim() } | Select-Object -Last 10 | ForEach-Object { Write-Log "chkdsk: $_" }
        # /scan is read-only (no dismount, no reboot) - exit codes 1 and 2 just mean it
        # found something to report, not that this step itself failed.
        switch ($chkdskExit) {
            0 { Write-Log 'chkdsk: no errors found.' }
            1 { Write-Log 'chkdsk: errors were found (informational for an online /scan pass - re-run with /spotfix or a full offline chkdsk to correct them).' }
            2 { Write-Log 'chkdsk: further scanning is required (informational for an online /scan pass).' }
            default { Write-Log "chkdsk exited with code $chkdskExit." 'WARN' }
        }
    }

    Invoke-Step 'Running sfc /scannow' {
        # sfc writes UTF-16LE to a redirected pipe. Capturing it while
        # [Console]::OutputEncoding is temporarily Unicode decodes it into normal .NET
        # strings - but logging must happen AFTER restoring the encoding, not while
        # still inside this block: Write-Log's own Write-Host calls also respect
        # [Console]::OutputEncoding, so logging sfc's lines while still set to Unicode
        # would write THOSE bytes as UTF-16LE too, corrupting this run's otherwise-UTF8
        # log file right alongside them (confirmed both failure and fix with a
        # cmd /u stand-in before shipping this).
        $originalEncoding = [Console]::OutputEncoding
        $sfcOutput = $null
        try {
            [Console]::OutputEncoding = [Text.Encoding]::Unicode
            $sfcOutput = sfc /scannow 2>&1
        } finally {
            [Console]::OutputEncoding = $originalEncoding
        }
        foreach ($line in $sfcOutput) { Write-Log "sfc: $line" }
    }

    Invoke-Step 'Running DISM /Online /Cleanup-Image /RestoreHealth' {
        # DISM's own live progress percentage becomes hundreds of near-duplicate lines
        # once piped (no way to overwrite a line in a redirected stream) - /LogPath keeps
        # the full detail in its own file, and only the last few non-progress-bar lines
        # (plus the exit code) go into this run's log.
        $dismLogPath = Join-Path $workDir 'dism_restorehealth.log'
        $dismOutput = & DISM /Online /Cleanup-Image /RestoreHealth "/LogPath:$dismLogPath" 2>&1
        $dismExit = $LASTEXITCODE
        $finalStatus = $dismOutput | Where-Object { $_ -and $_.Trim() -and $_ -notmatch '^\s*\[?=*\s*\d+\.?\d*%' } | Select-Object -Last 3
        foreach ($line in $finalStatus) { Write-Log "DISM: $line" }
        if ($dismExit -eq 0) {
            Write-Log "DISM completed successfully. Full log: $dismLogPath"
        } else {
            Write-Log "DISM exited with code $dismExit - see $dismLogPath for full detail." 'WARN'
        }
    }

    Write-Log 'System file repair complete.'
}

function Invoke-NetworkReset {
    Write-Log '--- Fix: Resetting network stack ---'
    Invoke-Step 'Resetting Winsock' { netsh winsock reset 2>&1 | ForEach-Object { Write-Log "netsh: $_" } }
    Invoke-Step 'Resetting TCP/IP stack' { netsh int ip reset 2>&1 | ForEach-Object { Write-Log "netsh: $_" } }
    Invoke-Step 'Flushing DNS cache' { ipconfig /flushdns 2>&1 | ForEach-Object { Write-Log "ipconfig: $_" } }
    Write-Log 'Network reset complete. A reboot is required for the Winsock/TCP-IP reset to fully take effect.'
}

function Invoke-WindowsUpdateReset {
    Write-Log '--- Fix: Resetting Windows Update ---'
    $services = @('wuauserv', 'bits', 'cryptsvc', 'msiserver')
    Invoke-Step "Stopping services: $($services -join ', ')" {
        foreach ($svc in $services) { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
        $wuauserv = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
        if ($wuauserv -and $wuauserv.Status -ne 'Stopped') {
            Write-Log "wuauserv is still $($wuauserv.Status), not Stopped - the rename below may fail while it still holds the folder open." 'WARN'
        }
    }
    $softwareDistribution = Join-Path $env:WINDIR 'SoftwareDistribution'
    $catroot2 = Join-Path $env:WINDIR 'System32\catroot2'
    Invoke-Step "Renaming $softwareDistribution and $catroot2 so Windows Update rebuilds them fresh" {
        if (Test-Path $softwareDistribution) {
            Remove-Item -Path "$softwareDistribution.bak" -Recurse -Force -ErrorAction SilentlyContinue
            Rename-Item -Path $softwareDistribution -NewName 'SoftwareDistribution.bak' -Force -ErrorAction SilentlyContinue
            if (Test-Path $softwareDistribution) {
                Write-Log 'SoftwareDistribution still exists after attempting to rename it - Windows Update will keep using the old cache.' 'WARN'
            } else {
                Write-Log 'SoftwareDistribution renamed successfully.'
            }
        }
        if (Test-Path $catroot2) {
            Remove-Item -Path "$catroot2.bak" -Recurse -Force -ErrorAction SilentlyContinue
            Rename-Item -Path $catroot2 -NewName 'catroot2.bak' -Force -ErrorAction SilentlyContinue
            if (Test-Path $catroot2) {
                Write-Log 'catroot2 still exists after attempting to rename it.' 'WARN'
            }
        }
    }
    Invoke-Step "Restarting services: $($services -join ', ')" {
        foreach ($svc in $services) { Start-Service -Name $svc -ErrorAction SilentlyContinue }
    }
    Invoke-Step 'Cleaning up SoftwareDistribution.bak' {
        Remove-Item -Path "$softwareDistribution.bak" -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Log 'Windows Update reset complete.'
}

function Invoke-WinGetReinstall {
    Write-Log '--- Fix: Re-registering winget (App Installer) ---'
    Invoke-Step 'Re-registering Microsoft.DesktopAppInstaller for the current user' {
        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
            Write-Log 'winget re-registered successfully.'
        } catch {
            Write-Log "Re-register failed ($($_.Exception.Message)); trying to re-register from the existing package's own manifest instead." 'WARN'
            $pkg = Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue
            if ($pkg) {
                Add-AppxPackage -Register "$($pkg.InstallLocation)\AppXManifest.xml" -DisableDevelopmentMode -ErrorAction SilentlyContinue
                Write-Log 'Re-registered from local package manifest.'
            } else {
                Write-Log 'App Installer is not present on this machine at all - install it from the Microsoft Store manually.' 'WARN'
            }
        }
    }
}

# ============================================================================
# PHASE 2 - Remove existing Office (clears out every preloaded language too)
# ============================================================================

function Get-OfficeDeploymentTool {
    # Always re-fetch, rather than caching setup.exe in $workDir forever - an old cached
    # copy eventually fails against the current CDN with "setup.exe is out of date", and
    # the file itself is only ~7 MB, so there's no real cost to just always pulling the
    # current build instead of trying to version-check a cached one.
    $setupPath = Join-Path $workDir 'setup.exe'
    Write-Log 'Downloading Office Click-to-Run setup.exe from officecdn.microsoft.com'
    Invoke-WebRequest -Uri 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -OutFile $setupPath -UseBasicParsing
    return $setupPath
}

function New-OfficeInstallXml {
    param([string]$Path, [string]$SourceDir)
    # Product ID O365BusinessRetail = Microsoft 365 Apps for business.
    # (O365ProPlusRetail is the "for enterprise" SKU - do not swap unless your tenant
    # licenses enterprise plans instead.)
    # Groove = legacy consumer OneDrive sync client, always safe to exclude.
    # Uncomment the Teams/OneDrive ExcludeApp lines if your org deploys those separately
    # (e.g. Teams via a dedicated MSI, OneDrive pinned to a specific build).
    # SourcePath points /download and /configure at the same local cache, so /configure
    # installs from what pre-flight already verified downloaded cleanly instead of
    # re-pulling from the CDN. RemoveMSI clears any old MSI-based Office as part of this
    # same install pass instead of a separate manual msiexec loop. AUTOACTIVATE is a
    # volume-licence Property and is silently ignored for O365BusinessRetail - omitted so
    # the config doesn't imply activation behavior it doesn't actually control.
    @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="$OfficeChannel" SourcePath="$SourceDir">
    <Product ID="O365BusinessRetail">
      <Language ID="$OfficeLanguage" />
      <ExcludeApp ID="Groove" />
      <!-- <ExcludeApp ID="Teams" /> -->
      <!-- <ExcludeApp ID="OneDrive" /> -->
    </Product>
  </Add>
  <Updates Enabled="TRUE" Channel="$OfficeChannel" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Logging Level="Standard" Path="C:\ProgramData\DellOfficeDeploy" />
  <RemoveMSI />
</Configuration>
"@ | Set-Content -Path $Path -Encoding UTF8
}

$script:officePreflightOk = $true

function Invoke-OfficePreflight {
    param([string]$SetupPath, [string]$InstallXmlPath)

    $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction SilentlyContinue
    $freeGb = if ($drive) { [Math]::Round($drive.FreeSpace / 1GB, 1) } else { $null }
    if ($null -eq $freeGb -or $freeGb -lt 5) {
        Write-Log "Only $freeGb GB free on $env:SystemDrive - need at least 5 GB free before touching the existing Office install. Aborting the Office phase before removing anything." 'ERROR'
        $script:officePreflightOk = $false
        return
    }
    Write-Log "Free space check OK ($freeGb GB free on $env:SystemDrive)."

    Invoke-Step 'Pre-downloading the Microsoft 365 Apps install source (so the existing Office is only removed once the new install source is confirmed good)' {
        $proc = Start-Process -FilePath $SetupPath -ArgumentList "/download ""$InstallXmlPath""" -PassThru -Wait
        if ($proc.ExitCode -ne 0) {
            Write-Log "setup.exe /download exited with code $($proc.ExitCode) - could not stage the install source." 'ERROR'
            $script:officePreflightOk = $false
        } else {
            Write-Log 'Install source downloaded successfully.'
        }
    }
}

function Uninstall-ExistingOffice {
    param([string]$SetupPath)
    Write-Log '--- Phase 2: Removing existing Office installation(s) ---'

    $c2rKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $hasC2R = Test-Path $c2rKey

    if ($hasC2R) {
        $config = Get-ItemProperty -Path $c2rKey -ErrorAction SilentlyContinue
        $products = @()
        if ($config -and $config.ProductReleaseIds) { $products = @($config.ProductReleaseIds -split ';' | Where-Object { $_ }) }
        Write-Log "Existing Click-to-Run product(s): $($products -join ', ')"

        $expectedSkuPattern = '^(O365BusinessRetail|O365ProPlusRetail|O365HomePremRetail|HomeStudentRetail|HomeBusinessRetail|PersonalRetail)$'
        $unexpected = @($products | Where-Object { $_ -notmatch $expectedSkuPattern })

        # Well-known ODT/CDN per-channel base-URL GUIDs (Microsoft's own, published in
        # the ODT docs) - used only to skip a needless remove+reinstall when the machine
        # already has exactly the target SKU on the target channel. Anything not
        # confidently recognized here just falls through to a normal reinstall, which is
        # always safe either way.
        $channelGuidMap = @{
            'MonthlyEnterprise' = '55336b82-a18d-4dd6-b5f6-9e5095c314a6'
            'Current'           = '492350f6-3a01-4f97-b9c0-c7c6ddf67d60'
            'SemiAnnual'        = '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114'
            'SemiAnnualPreview' = 'b8f9b850-328d-4355-9145-c59439a0c4cf'
        }
        $targetGuid = $channelGuidMap[$OfficeChannel]
        $onTargetChannel = $targetGuid -and $config.UpdateChannel -and ($config.UpdateChannel -match [regex]::Escape($targetGuid))
        $onlyExpectedSku = $products.Count -eq 1 -and $products[0] -eq 'O365BusinessRetail'

        if ($unexpected.Count -gt 0) {
            Write-Log "Refusing to run remove-all.xml - found product(s) beyond the expected business/consumer SKUs: $($unexpected -join ', '). This usually means a licensed Visio/Project (or similar add-on) is installed, and remove-all.xml would take it out too. Leaving the existing Click-to-Run install in place; Phase 3's install.xml only adds/updates O365BusinessRetail and never removes anything, so it still runs normally." 'ERROR'
        } elseif ($onlyExpectedSku -and $onTargetChannel) {
            Write-Log "O365BusinessRetail is already installed on the $OfficeChannel channel - skipping removal, Phase 3 will reconfigure it in place."
        } else {
            $removeXmlPath = Join-Path $workDir 'remove-all.xml'
            @'
<Configuration>
  <Remove All="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
'@ | Set-Content -Path $removeXmlPath -Encoding UTF8

            Invoke-Step 'Removing existing Click-to-Run Office (all products, all languages)' {
                $proc = Start-Process -FilePath $SetupPath -ArgumentList "/configure ""$removeXmlPath""" -PassThru -Wait
                if ($proc.ExitCode -ne 0) {
                    Write-Log "setup.exe /configure remove-all.xml exited with code $($proc.ExitCode) - Office removal may not have fully completed." 'ERROR'
                } else {
                    Write-Log 'Existing Click-to-Run Office removed.'
                }
            }
        }
    } else {
        # Older MSI-based Office (2016 and earlier, or volume-licensed MSI builds) isn't
        # managed by the ODT - Phase 3's <RemoveMSI /> clears it during install instead
        # of a separate manual msiexec uninstall here.
        $msiOffice = @(Get-UninstallEntries | Where-Object {
            $_.DisplayName -like 'Microsoft Office*' -and $_.UninstallString -match 'msiexec'
        })
        if ($msiOffice.Count -gt 0) {
            Write-Log "No Click-to-Run Office found, but $($msiOffice.Count) MSI-based Office product(s) detected ($($msiOffice.DisplayName -join ', ')) - Phase 3's RemoveMSI will clear these during install."
        } else {
            Write-Log 'No existing Office installation found - nothing to remove.'
        }
    }
}

# ============================================================================
# PHASE 3 - Install Microsoft 365 Apps for business (en-us only)
# ============================================================================

function Install-Microsoft365Business {
    param([string]$SetupPath, [string]$InstallXmlPath)
    Write-Log "--- Phase 3: Installing Microsoft 365 Apps for business ($OfficeLanguage, $OfficeChannel channel) ---"

    Invoke-Step "Installing Microsoft 365 Apps for business ($OfficeLanguage)" {
        $proc = Start-Process -FilePath $SetupPath -ArgumentList "/configure ""$InstallXmlPath""" -PassThru -Wait
        if ($proc.ExitCode -ne 0) {
            Write-Log "setup.exe /configure install.xml exited with code $($proc.ExitCode) - Office may not be fully installed." 'ERROR'
        } else {
            Write-Log 'setup.exe reported success installing Microsoft 365 Apps for business.'
        }
    }

    # The ODT's Display Level="None" only suppresses the INSTALLER's own UI - it has
    # no effect on the separate "Default File Types" prompt (Office Open XML vs
    # OpenDocument) that Word/Excel/PowerPoint show on their own first launch.
    # ShownFileFmtPrompt is also a real ADMX-backed Group Policy value (officecustom
    # DisableFileFmtPrompt16, key Software\Microsoft\Office\16.0\Common\General) -
    # writing it under HKLM\SOFTWARE\Policies instead of the plain per-user HKCU path
    # applies it machine-wide, to every user (current and future), with a single
    # ordinary HKLM write instead of per-profile registry hive juggling.
    Invoke-Step "Suppressing the Office first-run 'Default File Types' prompt" {
        try {
            $path = 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\General'
            New-Item -Path $path -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path $path -Name 'ShownFileFmtPrompt' -Value 1 -Type DWord -ErrorAction Stop
            Write-Log 'Default File Types prompt suppressed machine-wide (HKLM Policies ShownFileFmtPrompt=1) - Office keeps its built-in Open XML default without ever asking.'
        } catch {
            Write-Log "Could not suppress the Default File Types prompt: $($_.Exception.Message)" 'WARN'
        }
    }

    $c2rKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    if (Test-Path $c2rKey) {
        $config = Get-ItemProperty -Path $c2rKey -ErrorAction SilentlyContinue
        if ($config -and $config.ProductReleaseIds) {
            Write-Log "Verified: ClickToRun Configuration shows $($config.ProductReleaseIds) installed, version $($config.VersionToReport)."
        } else {
            Write-Log 'ClickToRun Configuration key exists but ProductReleaseIds is empty - Office install may not have completed.' 'ERROR'
        }
    } else {
        Write-Log 'ClickToRun Configuration key not found after install - Office does not appear to be installed.' 'ERROR'
    }

    Write-Log 'Install complete. Activation happens on first app launch when the user signs in with their Microsoft 365 business account.'
}

# ============================================================================
# OPTIONAL - trim extra languages from an EXISTING Office C2R install without a
# full uninstall/reinstall. Not called by default; invoke manually if you want to
# keep the current Office build and just drop unused languages.
# ============================================================================

function Remove-ExtraOfficeLanguages {
    param([string]$KeepLanguage = 'en-us')

    $configKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    if (-not (Test-Path $configKey)) {
        Write-Log 'No Click-to-Run Office installation found - nothing to trim.' 'WARN'
        return
    }

    $config = Get-ItemProperty -Path $configKey
    $installed = @($config.ClientCulture) + @($config.AdditionalClientCultures -split ',') |
        Where-Object { $_ -and $_ -ne $KeepLanguage } | Select-Object -Unique

    if (-not $installed) {
        Write-Log "Only $KeepLanguage is installed - nothing to trim."
        return
    }

    $setupPath = Get-OfficeDeploymentTool
    $langXmlPath = Join-Path $workDir 'remove-languages.xml'
    $languageLines = ($installed | ForEach-Object { '      <Language ID="' + $_ + '" />' }) -join [Environment]::NewLine

    @"
<Configuration>
  <Display Level="None" AcceptEULA="TRUE" />
  <Remove>
    <Product ID="LanguagePack">
$languageLines
    </Product>
  </Remove>
</Configuration>
"@ | Set-Content -Path $langXmlPath -Encoding UTF8

    Invoke-Step "Removing extra Office languages: $($installed -join ', ')" {
        Start-Process -FilePath $setupPath -ArgumentList "/configure ""$langXmlPath""" -Wait
    }
}

# ============================================================================
# MAIN
# ============================================================================

Write-Log "Starting run. DryRun=$DryRun CreateRestorePoint=$CreateRestorePoint SkipDebloat=$SkipDebloat SkipOfficeRemoval=$SkipOfficeRemoval SkipOfficeInstall=$SkipOfficeInstall"

if ($CreateRestorePoint) { New-PreDeploySystemRestorePoint }

if ($TweakReduceTelemetry) { Set-TelemetryReduced }
if ($TweakDisableHibernation) { Disable-Hibernation }
if ($TweakPreventSleep) { Set-SleepNever }
if ($TweakDisableSmartAppControl) { Disable-SmartAppControl }
if ($InstallOemUpdateTool) { Install-OemUpdateTool }
if ($CustomizeTweaks) { Invoke-CustomizeTweaks -Selections ($CustomizeTweaks -split ',' | Where-Object { $_ }) }
if ($DnsPreset) { Set-DnsPreset -Preset $DnsPreset -DnsForce:$DnsForce }

if (-not $SkipDebloat) {
    Remove-OemBloatware
    Disable-OemScheduledTasksAndServices
}
if (-not $SkipOfficeRemoval -or -not $SkipOfficeInstall) {
    $officeSetupPath = Get-OfficeDeploymentTool
    $officeInstallXmlPath = Join-Path $workDir 'install.xml'
    $officeSourceDir = Join-Path $workDir 'OfficeSource'
    New-OfficeInstallXml -Path $officeInstallXmlPath -SourceDir $officeSourceDir
    Invoke-OfficePreflight -SetupPath $officeSetupPath -InstallXmlPath $officeInstallXmlPath

    if ($script:officePreflightOk) {
        if (-not $SkipOfficeRemoval) { Uninstall-ExistingOffice -SetupPath $officeSetupPath }
        if (-not $SkipOfficeInstall) { Install-Microsoft365Business -SetupPath $officeSetupPath -InstallXmlPath $officeInstallXmlPath }
    } else {
        Write-Log 'Skipping both Office removal and install - pre-flight check failed (see ERROR above).' 'ERROR'
    }
}

if ($FixSystemRepair) { Invoke-SystemRepair }
if ($FixNetworkReset) { Invoke-NetworkReset }
if ($FixWindowsUpdateReset) { Invoke-WindowsUpdateReset }
if ($FixWinGetReinstall) { Invoke-WinGetReinstall }

if ($script:errorCount -gt 0) {
    Write-Log "Run complete with $script:errorCount warning(s)/error(s) - check the log above for details. Log saved to $logPath"
} else {
    Write-Log "Run complete. Log saved to $logPath"
}

if (-not $DryRun -and -not $NoReboot) {
    Write-Log 'A reboot is recommended to finish clearing removed services/drivers.'
    $answer = Read-Host 'Reboot now? (y/N)'
    if ($answer -eq 'y') { Restart-Computer -Force }
}

Stop-Transcript | Out-Null
