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

.PARAMETER Undo
    Path to an undo_<hostname>_<stamp>.json file (see C:\ProgramData\DellOfficeDeploy,
    written automatically by any run that applied a tweak, DNS, telemetry or power
    change). Walks it in reverse and exits - no other phase runs in the same invocation.
    OEM/AppX/Office removal and Smart App Control are one-way and were never captured,
    so Revert can't undo those regardless of which undo file is used.

.PARAMETER RenameComputer
    Renames this computer using -HostnamePattern (e.g. "ACME-{SERIAL}", {SERIAL} replaced
    with the BIOS serial number, result trimmed to 15 NetBIOS-safe characters). No
    immediate restart. Refuses if the machine is already Entra joined - rename first.

.PARAMETER ApplyOemUpdates
    Applies Dell Command Update / Lenovo System Update driver+BIOS updates (silent, no
    automatic reboot). Requires AC power; suspends BitLocker for one reboot first if it's
    on. No-ops on non-Dell/Lenovo hardware.

.PARAMETER RunWindowsUpdate
    Searches, downloads and installs Windows updates in a loop (up to 4 passes) until none
    remain. If a pass needs a reboot to continue, saves state and registers a scheduled
    task to resume automatically after the next restart - see -Resume. Dry run does one
    search-only pass and reports what would be installed.

.PARAMETER Resume
    Internal - set by the scheduled task Register-WindowsUpdateResumeTask registers, to
    continue a Windows Update pass loop that needed a reboot. Not meant to be passed by
    hand under normal use.

.PARAMETER GenerateHandoff
    Runs read-only validation checks (activation, Defender/AV, firewall, join state,
    Secure Boot, pending reboot, free disk, last Windows Update success, OEM update tool
    presence) and writes a handoff package (inventory.json, validation.txt, the full log,
    and an auto-opening report.html) to
    C:\ProgramData\DellOfficeDeploy\handoff\<ClientCode>_<hostname>_<serial>\.

.PARAMETER ClientCode
    Short client identifier used in the handoff package folder name and inventory.json.

.PARAMETER ApplyOneDriveKfm
    Configures silent OneDrive sign-in and Known Folder Move (Desktop/Documents/Pictures
    per -KfmDesktop/-KfmDocuments/-KfmPictures) instead of removing OneDrive. Requires
    -EntraTenantId; only meaningful on an Entra-joined device.

.PARAMETER ApplyRegionalBaseline
    Applies -TimeZoneId, -GeoId, -CultureName, -PowerPlanName and -LockTimeoutSec, plus a
    15-minute AC monitor timeout and Fast Startup off (needed for clean Wake-on-LAN and
    Windows Update).

.PARAMETER TargetProfile
    Current, Default, or Both (default). Every HKCU-scoped tweak entry always applies to
    the current (elevated) user's own hive; Default/Both additionally mirror it into
    C:\Users\Default\NTUSER.DAT via a temporary reg.exe load, so a user account created
    later (a fresh Entra join, a new local account) inherits the same settings instead of
    getting stock Windows defaults. HKLM-scoped tweaks are already machine-wide and are
    unaffected by this switch.

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
    [string]$OfficeExcludeApps = '',
    [switch]$OfficeSharedComputerLicensing,
    [switch]$NoReboot,
    [switch]$TweakReduceTelemetry,
    [switch]$TweakDisableHibernation,
    [switch]$TweakPreventSleep,
    [switch]$TweakDisableSmartAppControl,
    [switch]$InstallOemUpdateTool,
    [string]$CustomizeTweaks = '',
    [ValidateSet('Current', 'Default', 'Both')]
    [string]$TargetProfile = 'Both',
    [string]$DnsPreset = '',
    [switch]$DnsForce,
    [switch]$FixSystemRepair,
    [switch]$FixNetworkReset,
    [switch]$FixWindowsUpdateReset,
    [switch]$FixWinGetReinstall,
    [switch]$FixTimeSync,
    [switch]$FixNetFx3,
    [string]$Undo = '',
    [string]$Version = '',
    [string]$Commit = '',
    [switch]$RenameComputer,
    [string]$HostnamePattern = '',
    [switch]$ApplyOemUpdates,
    [switch]$RunWindowsUpdate,
    [switch]$Resume,
    [switch]$GenerateHandoff,
    [switch]$PostProvisioningCleanup,
    [string]$ClientCode = '',
    [switch]$ApplyOneDriveKfm,
    [string]$EntraTenantId = '',
    [switch]$KfmDesktop,
    [switch]$KfmDocuments,
    [switch]$KfmPictures,
    [switch]$ApplyRegionalBaseline,
    [string]$TimeZoneId = '',
    [string]$GeoId = '',
    [string]$CultureName = '',
    [string]$PowerPlanName = '',
    [int]$LockTimeoutSec = 900
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

Write-Log "Gr3y Support $(if ($Version) { "v$Version" } else { '(unversioned - launched directly, not via debloat.ps1)' })$(if ($Commit) { " ($Commit)" } else { '' }) | Worker PID: $PID | Profile: $env:USERNAME"
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
# UNDO SNAPSHOT - captures live "before" state ahead of any tweak, DNS, service or
# power change, so a later -Undo <file> pass can walk it in reverse. Deliberately does
# NOT cover OEM/AppX/Office removal or Smart App Control - those are one-way by design
# and are labeled as such in the GUI rather than implying Revert could undo them.
# ============================================================================

$script:undoSnapshot = $null
$script:undoSnapshotPath = $null

function Initialize-UndoSnapshot {
    if ($script:undoSnapshot) { return }
    $script:undoSnapshot = [ordered]@{
        hostname     = $env:COMPUTERNAME
        timestamp    = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        registry     = New-Object System.Collections.Generic.List[object]
        registryKeys = New-Object System.Collections.Generic.List[object]
        services     = New-Object System.Collections.Generic.List[object]
        dns          = New-Object System.Collections.Generic.List[object]
        power        = $null
        mpPreference = $null
    }
}

function Add-UndoRegistryEntry {
    param([string]$Path, [string]$Name, [string]$Type)
    Initialize-UndoSnapshot
    # First-seen state only - a second tweak touching the same value later in the same
    # run must not overwrite the snapshot with an already-modified "before".
    if ($script:undoSnapshot.registry | Where-Object { $_.path -eq $Path -and $_.name -eq $Name }) { return }
    $existing = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        $script:undoSnapshot.registry.Add([ordered]@{ path = $Path; name = $Name; hadValue = $false; value = $null; type = $Type })
    } else {
        $script:undoSnapshot.registry.Add([ordered]@{ path = $Path; name = $Name; hadValue = $true; value = $existing.$Name; type = $Type })
    }
}

function Add-UndoRegistryKeyEntry {
    # For whole-key create/delete tweaks (e.g. the classic context menu's InprocServer32
    # key) where the value being set is the key's own unnamed default value - Name '' is
    # not usable with Get/Set-ItemProperty (Set-ItemProperty -Name '' throws outright,
    # confirmed by hand against a real key), so this captures/restores via
    # Get-Item/Set-Item's GetValue('')/-Value instead, and tracks key existence itself
    # rather than a single named value's existence.
    param([string]$Path)
    Initialize-UndoSnapshot
    if ($script:undoSnapshot.registryKeys | Where-Object { $_.path -eq $Path }) { return }
    $item = Get-Item -Path $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        $script:undoSnapshot.registryKeys.Add([ordered]@{ path = $Path; hadKey = $false; defaultValue = $null })
    } else {
        $script:undoSnapshot.registryKeys.Add([ordered]@{ path = $Path; hadKey = $true; defaultValue = $item.GetValue('') })
    }
}

function Add-UndoServiceEntry {
    param([string]$Name)
    Initialize-UndoSnapshot
    if ($script:undoSnapshot.services | Where-Object { $_.name -eq $Name }) { return }
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($svc) {
        $script:undoSnapshot.services.Add([ordered]@{ name = $Name; startType = $svc.StartType.ToString(); status = $svc.Status.ToString() })
    }
}

function Add-UndoDnsEntry {
    param($Adapter)
    Initialize-UndoSnapshot
    if ($script:undoSnapshot.dns | Where-Object { $_.interfaceIndex -eq $Adapter.InterfaceIndex }) { return }
    $ipv4Servers = (Get-DnsClientServerAddress -InterfaceIndex $Adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    $ipv6Servers = (Get-DnsClientServerAddress -InterfaceIndex $Adapter.InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue).ServerAddresses
    $dhcpEnabled = (Get-NetIPInterface -InterfaceIndex $Adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp -eq 'Enabled'
    $script:undoSnapshot.dns.Add([ordered]@{
        interfaceIndex = $Adapter.InterfaceIndex
        interfaceName  = $Adapter.Name
        dhcp           = $dhcpEnabled
        serversV4      = @($ipv4Servers)
        serversV6      = @($ipv6Servers)
    })
}

function Add-UndoPowerEntry {
    Initialize-UndoSnapshot
    if ($script:undoSnapshot.power) { return }
    $schemeOutput = powercfg /getactivescheme 2>&1 | Out-String
    $schemeGuid = [regex]::Match($schemeOutput, 'Power Scheme GUID:\s*([0-9a-fA-F-]+)').Groups[1].Value
    $queryOutput = powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>&1 | Out-String
    $acIndex = [regex]::Match($queryOutput, 'Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)').Groups[1].Value
    $dcIndex = [regex]::Match($queryOutput, 'Current DC Power Setting Index:\s*(0x[0-9a-fA-F]+)').Groups[1].Value
    $script:undoSnapshot.power = [ordered]@{
        activeScheme      = $schemeGuid
        standbyTimeoutAC  = $acIndex
        standbyTimeoutDC  = $dcIndex
        hibernateEnabled  = (Test-Path (Join-Path $env:SystemDrive 'hiberfil.sys'))
    }
}

function Add-UndoMpPreferenceEntry {
    # Captures as the raw byte enum values Get-MpPreference returns (0/1/2) rather than
    # a string name - confirmed live that Set-MpPreference's -PUAProtection/
    # -EnableNetworkProtection parameters are typed System.Object, so passing the same
    # byte back on revert round-trips correctly without needing a byte-to-name lookup.
    Initialize-UndoSnapshot
    if ($script:undoSnapshot.mpPreference) { return }
    $pref = Get-MpPreference -ErrorAction SilentlyContinue
    if ($pref) {
        $script:undoSnapshot.mpPreference = [ordered]@{
            puaProtection           = [int]$pref.PUAProtection
            enableNetworkProtection = [int]$pref.EnableNetworkProtection
        }
    }
}

function Save-UndoSnapshot {
    if (-not $script:undoSnapshot) { return }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $path = Join-Path $workDir "undo_$($env:COMPUTERNAME)_$stamp.json"
    try {
        $script:undoSnapshot | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding UTF8
        Write-Log "Undo snapshot saved: $path"
        # Human-readable secondary backup, in addition to the JSON the Revert flow
        # actually reads - reg.exe export needs a whole KEY (not a single value), so this
        # exports each unique key that had at least one captured value.
        $uniqueKeys = $script:undoSnapshot.registry.path | Select-Object -Unique
        foreach ($regPath in $uniqueKeys) {
            $regExportArg = $regPath -replace '^HKLM:', 'HKLM' -replace '^HKCU:', 'HKCU' -replace '^HKU:', 'HKU' -replace '\\', '\'
            $safeName = ($regPath -replace '[\\:]', '_')
            $exportPath = Join-Path $workDir "undo_$($env:COMPUTERNAME)_$stamp`_$safeName.reg"
            & reg.exe export $regExportArg $exportPath /y 2>&1 | Out-Null
        }
    } catch {
        Write-Log "Could not save the undo snapshot: $($_.Exception.Message)" 'WARN'
    }
}

function Invoke-UndoSnapshot {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Log "Undo file not found: $Path" 'ERROR'
        return
    }
    Write-Log "--- Reverting from undo snapshot: $Path ---"
    try {
        $snapshot = Get-Content -Path $Path -Raw | ConvertFrom-Json
    } catch {
        Write-Log "Could not parse undo file: $($_.Exception.Message)" 'ERROR'
        return
    }

    # Reverse order - later entries in the file were captured (and so applied) later in
    # the original run, so undo them first.
    $registryEntries = @($snapshot.registry)
    [array]::Reverse($registryEntries)
    foreach ($entry in $registryEntries) {
        Invoke-Step "Reverting registry: $($entry.path)\$($entry.name)" {
            try {
                if (-not $entry.hadValue) {
                    Remove-ItemProperty -Path $entry.path -Name $entry.name -ErrorAction SilentlyContinue
                } else {
                    New-Item -Path $entry.path -Force -ErrorAction SilentlyContinue | Out-Null
                    Set-ItemProperty -Path $entry.path -Name $entry.name -Value $entry.value -Type $entry.type -ErrorAction Stop
                }
            } catch {
                Write-Log "Could not revert $($entry.path)\$($entry.name): $($_.Exception.Message)" 'WARN'
            }
        }
    }

    $registryKeyEntries = @($snapshot.registryKeys)
    [array]::Reverse($registryKeyEntries)
    foreach ($keyEntry in $registryKeyEntries) {
        Invoke-Step "Reverting registry key: $($keyEntry.path)" {
            try {
                if (-not $keyEntry.hadKey) {
                    Remove-Item -Path $keyEntry.path -Recurse -Force -ErrorAction SilentlyContinue
                } else {
                    New-Item -Path $keyEntry.path -Force -ErrorAction Stop | Out-Null
                    Set-Item -Path $keyEntry.path -Value $keyEntry.defaultValue -ErrorAction Stop
                }
            } catch {
                Write-Log "Could not revert registry key $($keyEntry.path): $($_.Exception.Message)" 'WARN'
            }
        }
    }

    foreach ($svcEntry in $snapshot.services) {
        Invoke-Step "Reverting service: $($svcEntry.name) -> StartType=$($svcEntry.startType), Status=$($svcEntry.status)" {
            try {
                Set-Service -Name $svcEntry.name -StartupType $svcEntry.startType -ErrorAction Stop
                if ($svcEntry.status -eq 'Running') {
                    Start-Service -Name $svcEntry.name -ErrorAction SilentlyContinue
                } else {
                    Stop-Service -Name $svcEntry.name -Force -ErrorAction SilentlyContinue
                }
            } catch {
                Write-Log "Could not revert service $($svcEntry.name): $($_.Exception.Message)" 'WARN'
            }
        }
    }

    foreach ($dnsEntry in $snapshot.dns) {
        Invoke-Step "Reverting DNS on $($dnsEntry.interfaceName)" {
            try {
                if ($dnsEntry.dhcp) {
                    Set-DnsClientServerAddress -InterfaceIndex $dnsEntry.interfaceIndex -ResetServerAddresses -ErrorAction Stop
                } elseif ($dnsEntry.serversV4 -or $dnsEntry.serversV6) {
                    Set-DnsClientServerAddress -InterfaceIndex $dnsEntry.interfaceIndex -ServerAddresses (@($dnsEntry.serversV4) + @($dnsEntry.serversV6)) -ErrorAction Stop
                }
            } catch {
                Write-Log "Could not revert DNS on $($dnsEntry.interfaceName): $($_.Exception.Message)" 'WARN'
            }
        }
    }

    if ($snapshot.power) {
        Invoke-Step 'Reverting power scheme, sleep timeout and hibernate state' {
            try {
                if ($snapshot.power.activeScheme) { powercfg /setactive $snapshot.power.activeScheme 2>&1 | Out-Null }
                if ($snapshot.power.standbyTimeoutAC) {
                    powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE $snapshot.power.standbyTimeoutAC 2>&1 | Out-Null
                }
                if ($snapshot.power.standbyTimeoutDC) {
                    powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE $snapshot.power.standbyTimeoutDC 2>&1 | Out-Null
                }
                powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
                if ($snapshot.power.hibernateEnabled) {
                    powercfg /hibernate on 2>&1 | Out-Null
                } else {
                    powercfg /hibernate off 2>&1 | Out-Null
                }
            } catch {
                Write-Log "Could not revert power settings: $($_.Exception.Message)" 'WARN'
            }
        }
    }

    if ($snapshot.mpPreference) {
        Invoke-Step 'Reverting Defender PUA Protection and Network Protection preferences' {
            try {
                Set-MpPreference -PUAProtection $snapshot.mpPreference.puaProtection -ErrorAction Stop
                Set-MpPreference -EnableNetworkProtection $snapshot.mpPreference.enableNetworkProtection -ErrorAction Stop
            } catch {
                Write-Log "Could not revert Defender preferences: $($_.Exception.Message)" 'WARN'
            }
        }
    }

    Write-Log 'Revert complete. Note: OEM/AppX/Office removal and Smart App Control are one-way and are never covered by an undo snapshot.'
}

# ============================================================================
# TWEAKS - opt-in preference changes, bundled into a normal run alongside debloat
# ============================================================================

function Set-TelemetryReduced {
    Invoke-Step 'Reducing telemetry and activity tracking' {
        # Update Compliance, Intune Endpoint Analytics and Windows Autopatch all require
        # diagnostic data at Required (or higher) to function - forcing AllowTelemetry=0
        # on a machine already enrolled in MDM would silently break whatever org tooling
        # depends on those, which only surfaces later as "why did our compliance
        # dashboard stop reporting this machine" tickets.
        #
        # HKLM:\SOFTWARE\Microsoft\Enrollments holds many unrelated internal Windows
        # "enrollment" records (push notification channels, device-health/attestation,
        # etc. - EVERY subkey typically shows EnrollmentState=1 regardless of whether
        # the device is actually corporate-managed, confirmed by testing against a
        # machine known via dsregcmd /status to be neither Azure AD nor domain joined,
        # which still showed 30+ such subkeys). Filtering specifically for
        # ProviderID -eq 'MS DM Server' - Intune's own registered provider id, and the
        # thing Autopatch/Update Compliance/Endpoint Analytics actually depend on -
        # correctly returned "not enrolled" on that same known-unmanaged machine.
        $enrollmentsKey = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
        $isIntuneEnrolled = (Test-Path $enrollmentsKey) -and [bool](Get-ChildItem -Path $enrollmentsKey -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
        } | Where-Object { $_.ProviderID -eq 'MS DM Server' })
        if ($isIntuneEnrolled) {
            Write-Log 'This machine is Intune-enrolled - skipping the telemetry reduction tweak (AllowTelemetry=0 can break Update Compliance / Intune Endpoint Analytics / Windows Autopatch reporting for an enrolled device).' 'WARN'
            return
        }
        try {
            Add-UndoRegistryEntry -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Type 'DWord'
            Add-UndoRegistryEntry -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'PublishUserActivities' -Type 'DWord'
            Add-UndoRegistryEntry -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'UploadUserActivities' -Type 'DWord'
            Add-UndoServiceEntry -Name 'DiagTrack'

            New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 0 -Type DWord -ErrorAction SilentlyContinue

            New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Force -ErrorAction SilentlyContinue | Out-Null
            # EnableActivityFeed is deliberately left alone (WinUtil's own explicit
            # rationale, flagged as an owner-identified gap): turning it off breaks
            # clipboard history, which most people expect to keep working. Blocking
            # Publish/UploadUserActivities alone already stops activity data leaving the
            # machine, without losing that local functionality.
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'PublishUserActivities' -Value 0 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'UploadUserActivities' -Value 0 -Type DWord -ErrorAction SilentlyContinue

            Stop-Service -Name DiagTrack -Force -ErrorAction SilentlyContinue
            Set-Service -Name DiagTrack -StartupType Disabled -ErrorAction SilentlyContinue

            # Expanded set (3.3) - every path below pulled from Win11Debloat's actual
            # Disable_Telemetry.reg (fetched the real file rather than expand the plan's
            # abbreviated key-name shorthand by hand), applied to the current user only -
            # deliberately not mirrored to the Default profile the way 1.1's tweaks.json
            # tweaks are: AllowTelemetry=0 (already set above, HKLM) already covers a new
            # profile machine-wide, and these HKCU entries are more about quieting nags/
            # prompts for whoever's using the machine right now than something a not-yet-
            # created future user needs guaranteed.
            $telemetryHkcuEntries = @(
                @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Value = 0 }
                @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Value = 0 }
                @{ Path = 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; Name = 'HasAccepted'; Value = 0 }
                @{ Path = 'HKCU:\Software\Microsoft\Input\TIPC'; Name = 'Enabled'; Value = 0 }
                @{ Path = 'HKCU:\Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitInkCollection'; Value = 1 }
                @{ Path = 'HKCU:\Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitTextCollection'; Value = 1 }
                @{ Path = 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore'; Name = 'HarvestContacts'; Value = 0 }
                @{ Path = 'HKCU:\Software\Microsoft\Personalization\Settings'; Name = 'AcceptedPrivacyPolicy'; Value = 0 }
                @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_TrackProgs'; Value = 0 }
                @{ Path = 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules'; Name = 'NumberOfSIUFInPeriod'; Value = 0 }
            )
            foreach ($entry in $telemetryHkcuEntries) {
                New-Item -Path $entry.Path -Force -ErrorAction SilentlyContinue | Out-Null
                Set-ItemProperty -Path $entry.Path -Name $entry.Name -Value $entry.Value -Type DWord -ErrorAction SilentlyContinue
            }

            New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'DiagnosticData' -Value 0 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'PersonalizationReportingEnabled' -Value 0 -Type DWord -ErrorAction SilentlyContinue

            # POWERSHELL_TELEMETRY_OPTOUT is a machine-wide environment variable, not a
            # normal setting - it's backed by this same registry key underneath, so
            # setting it here keeps this one function purely registry-based instead of
            # also calling [Environment]::SetEnvironmentVariable for one value.
            $envKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
            Set-ItemProperty -Path $envKey -Name 'POWERSHELL_TELEMETRY_OPTOUT' -Value '1' -Type String -ErrorAction SilentlyContinue

            Write-Log 'Telemetry and activity tracking reduced (AllowTelemetry=0, activity publishing/upload blocked, DiagTrack service disabled, advertising ID/speech/ink/contacts/feedback-nag privacy settings applied, Edge diagnostic data/personalization off, PowerShell telemetry opted out - Activity Feed itself left on so clipboard history keeps working).'
        } catch {
            Write-Log "Could not fully apply the telemetry tweak: $($_.Exception.Message)" 'WARN'
        }
    }
}

function Disable-Hibernation {
    Invoke-Step 'Disabling hibernation (frees hiberfil.sys disk space)' {
        Add-UndoPowerEntry
        powercfg /hibernate off 2>&1 | ForEach-Object { Write-Log "powercfg: $_" }
    }
}

function Set-SleepNever {
    Invoke-Step 'Setting sleep to Never on AC and battery (display timeout left as-is)' {
        Add-UndoPowerEntry
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

        # Dell publishes Command Update as two separate winget packages - Universal
        # (Dell.CommandUpdate.Universal) and Classic (Dell.CommandUpdate, the older Win32
        # build). Try Universal first, fall back to Classic if that install fails or isn't
        # offered for this model - confirmed both package ids exist separately via a real
        # winget search before writing this, rather than assuming.
        $wingetIds = if ($isDell) { @('Dell.CommandUpdate.Universal', 'Dell.CommandUpdate') } else { @('Lenovo.SystemUpdate') }
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

        $installed = $false
        foreach ($wingetId in $wingetIds) {
            Write-Log "Installing $toolLabel ($wingetId) via winget..."
            try {
                $wingetOutput = & winget.exe install --id $wingetId -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
                $wingetOutput | ForEach-Object { Write-Log "winget: $_" }
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "$toolLabel ($wingetId) installed successfully."
                    $installed = $true
                    break
                } else {
                    Write-Log "$wingetId install exited with code $LASTEXITCODE." 'WARN'
                }
            } catch {
                Write-Log "Could not install ${wingetId}: $($_.Exception.Message)" 'WARN'
            }
        }
        if (-not $installed) {
            $vendorName = if ($isDell) { 'Dell' } else { 'Lenovo' }
            Write-Log "$toolLabel could not be installed via any of: $($wingetIds -join ', '). $vendorName doesn't publish an exhaustive supported-model list, so this can happen on a genuine but unsupported commercial model." 'WARN'
        }
    }
}

# Every HKCU write in this script normally lands in the elevated tech's own hive, not the
# client's actual user - who's typically created later (first Entra join, a fresh local
# account) and just gets stock Windows defaults, with no way to know a tweak was ever
# intended for them. This loads C:\Users\Default\NTUSER.DAT - the template Windows copies
# to build every brand-new profile - so $Body's writes get inherited by whoever logs in
# next, not just the current session. Verified against a real elevated process on
# 2026-09-30 (load, write, read back, unload all succeeded); $Body's own registry calls
# should prefer reg.exe add/query over Set-ItemProperty/Get-ItemProperty where practical,
# since .NET's registry handles are more prone to lingering past this function's own
# scope and making the final `reg.exe unload` fail with "the process cannot access the
# file" (harmless if it happens - the hive unloads on the next reboot regardless - but
# best avoided since it leaves Gr3yDefault mounted for the rest of this session).
function Invoke-DefaultProfileRegistry {
    param([scriptblock]$Body)
    $hiveLoaded = $false
    try {
        if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script -ErrorAction Stop | Out-Null
        }
        $ntUserPath = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
        if (-not (Test-Path $ntUserPath)) {
            Write-Log "Default profile hive not found at $ntUserPath - skipping Default profile registry changes." 'WARN'
            return
        }
        $loadOutput = & reg.exe load 'HKU\Gr3yDefault' $ntUserPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Could not load the Default profile hive (reg.exe load exited $LASTEXITCODE): $loadOutput" 'WARN'
            return
        }
        $hiveLoaded = $true
        $DefaultRoot = 'HKU:\Gr3yDefault'
        & $Body
    } finally {
        if ($hiveLoaded) {
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            Start-Sleep -Milliseconds 300
            $unloadOutput = & reg.exe unload 'HKU\Gr3yDefault' 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Log "Could not unload the Default profile hive (reg.exe unload exited $LASTEXITCODE) - this clears on its own at next reboot: $unloadOutput" 'WARN'
            }
        }
    }
}

# Classic context menu is a whole-key create/delete tweak (the key's own unnamed default
# value, not a named value under an existing key) - Set-ItemProperty -Name '' throws
# outright (confirmed by hand against a real key), so this can't be expressed as a normal
# tweaks.json entries[] item. ClassicContextMenu's tweakDefs entry carries entries=@() and
# is special-cased in Invoke-CustomizeTweaks instead, using Add-UndoRegistryKeyEntry for
# revert support. Confirmed live: New-Item + Set-Item -Value '' creates the key with an
# empty REG_SZ default value; Remove-Item -Recurse deletes it and Windows falls back to
# the modern menu, matching Microsoft Q&A/community-documented revert steps.
function Set-ClassicContextMenu {
    param([string]$Direction)
    $keyPath = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
    Add-UndoRegistryKeyEntry -Path $keyPath
    if ($Direction -eq 'on') {
        New-Item -Path $keyPath -Force -ErrorAction Stop | Out-Null
        Set-Item -Path $keyPath -Value '' -ErrorAction Stop
    } else {
        Remove-Item -Path $keyPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# F8BootMenuOn sets a whole-machine BCD value (not a registry value), so - like
# ClassicContextMenu - it can't go through the tweaks.json entries[] engine and is
# special-cased instead. Deliberately NOT wired into the Revert Last Run undo snapshot:
# bootmenupolicy only has two legal values (Legacy/Standard), the tweak's own on/off
# toggle is already a full, trivial revert, and Revert Last Run already has documented
# exclusions (OEM/AppX/Office removal, Smart App Control) for things outside its scope -
# adding a third undo-snapshot category (alongside registry/registryKeys/mpPreference)
# for a single two-state BCD flag isn't worth the added mechanism.
function Set-F8BootMenuPolicy {
    param([string]$Direction)
    $policyValue = if ($Direction -eq 'on') { 'Legacy' } else { 'Standard' }
    $bcdOutput = & bcdedit /set '{current}' bootmenupolicy $policyValue 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit exited with code $LASTEXITCODE - $($bcdOutput -join ' ')"
    }
}

# DefenderHardening's registry entries (RunAsPPL, SmartScreen) go through the normal
# tweaks.json entries[] loop - only the two Set-MpPreference calls need this dedicated
# function, since the generic engine only knows how to set/remove registry values.
function Set-DefenderMpPreferenceHardening {
    param([string]$Direction)
    Add-UndoMpPreferenceEntry
    $value = if ($Direction -eq 'on') { 'Enabled' } else { 'Disabled' }
    Set-MpPreference -PUAProtection $value -ErrorAction Stop
    Set-MpPreference -EnableNetworkProtection $value -ErrorAction Stop
}

# $script:tweakDefs is loaded from tweaks.json above (shared with Gr3ysUtilities.ps1's
# toggle list and its live-state read). Each entry carries an onValue and offValue (a
# literal "<RemoveEntry>" offValue means delete the value rather than write one) - the
# GUI computes which keys actually changed since it loaded and sends "Key=on"/"Key=off"
# for each, so this is a real reversible apply, not a one-way-only tweak.
function Invoke-CustomizeTweaks {
    param([string[]]$Selections, [string]$TargetProfile = 'Both')

    $consoleUser = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if ($consoleUser -and $consoleUser -notmatch [regex]::Escape($env:USERNAME)) {
        Write-Log "The account signed in at the console ($consoleUser) differs from the account this is running as ($env:USERNAME) - Current-user tweaks apply to $env:USERNAME's profile, which may not be who's sitting at this machine." 'WARN'
    }

    $restartExplorer = $false
    $appliedDefs = New-Object System.Collections.Generic.List[object]
    foreach ($selection in $Selections) {
        $parts = $selection -split '=', 2
        if ($parts.Count -ne 2) { Write-Log "Malformed tweak selection: $selection" 'WARN'; continue }
        $key = $parts[0]
        $direction = $parts[1]
        if (-not $script:tweakDefs.ContainsKey($key)) { Write-Log "Unknown tweak key: $key" 'WARN'; continue }
        if ($direction -ne 'on' -and $direction -ne 'off') { Write-Log "Unknown tweak direction '$direction' for $key" 'WARN'; continue }
        $def = $script:tweakDefs[$key]

        # S3Sleep forces the machine off Modern Standby and onto S3 (PlatformAoAcOverride=0) -
        # on firmware that never exposed S3 in the first place (most recent Dell/Lenovo
        # laptops), this doesn't just no-op, it breaks sleep/wake entirely. powercfg /a
        # lists every sleep state the firmware actually supports; only apply the "on"
        # direction when S3 is genuinely one of them.
        if ($key -eq 'S3Sleep' -and $direction -eq 'on') {
            $supportedStates = powercfg /a 2>&1 | Out-String
            if ($supportedStates -notmatch 'Standby \(S3\)') {
                Write-Log 'This machine''s firmware does not expose S3 sleep (powercfg /a) - skipping the S3 Sleep tweak, since forcing it on Modern-Standby-only hardware breaks sleep/wake.' 'WARN'
                continue
            }
        }
        # DefenderHardening assumes Microsoft Defender is the active AV engine - a
        # registered third-party AV in Security Center means these Set-MpPreference/LSA/
        # SmartScreen changes could conflict with (or be silently ignored by) the other
        # product, so skip entirely rather than apply half-meaningful settings.
        if ($key -eq 'DefenderHardening' -and $direction -eq 'on') {
            $thirdPartyAv = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue |
                Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' })
            if ($thirdPartyAv.Count -gt 0) {
                Write-Log "Third-party antivirus registered in Security Center ($($thirdPartyAv.displayName -join ', ')) - skipping Defender Hardening." 'WARN'
                continue
            }
        }
        Invoke-Step "Applying tweak: $($def.label) -> $direction" {
            try {
                if ($key -eq 'ClassicContextMenu') {
                    Set-ClassicContextMenu -Direction $direction
                } elseif ($key -eq 'F8BootMenuOn') {
                    Set-F8BootMenuPolicy -Direction $direction
                } else {
                    if ($def.needsHKU -and -not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
                        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script -ErrorAction Stop | Out-Null
                    }
                    foreach ($entry in $def.entries) {
                        $value = if ($direction -eq 'on') { $entry.onValue } else { $entry.offValue }
                        Add-UndoRegistryEntry -Path $entry.path -Name $entry.name -Type $entry.type
                        if ($value -eq '<RemoveEntry>') {
                            Remove-ItemProperty -Path $entry.path -Name $entry.name -ErrorAction SilentlyContinue
                        } else {
                            New-Item -Path $entry.path -Force -ErrorAction SilentlyContinue | Out-Null
                            Set-ItemProperty -Path $entry.path -Name $entry.name -Value $value -Type $entry.type -ErrorAction Stop
                        }
                    }
                    if ($key -eq 'DefenderHardening') {
                        Set-DefenderMpPreferenceHardening -Direction $direction
                    }
                    if ($key -eq 'RegistryBackupOn' -and $direction -eq 'on') {
                        Start-ScheduledTask -TaskName 'RegIdleBackup' -TaskPath '\Microsoft\Windows\Registry\' -ErrorAction SilentlyContinue
                        Write-Log 'Triggered an immediate RegIdleBackup run, in addition to its normal scheduled maintenance window.'
                    }
                }
                Write-Log "Applied: $($def.label) -> $direction"
            } catch {
                Write-Log "Could not apply '$($def.label)': $($_.Exception.Message)" 'WARN'
            }
        }
        if ($def.explorerRestart) { $restartExplorer = $true }
        if ($key -eq 'ClassicContextMenu' -and $TargetProfile -in @('Default', 'Both')) {
            Write-Log 'Classic context menu is current-profile-only and does not mirror to the Default profile - it lives under HKCU\Software\Classes, which is backed by UsrClass.dat, not the NTUSER.DAT hive the Default-profile mirror mechanism loads. A new user account will still get the modern Windows 11 menu.' 'WARN'
        }
        $appliedDefs.Add(@{ Def = $def; Direction = $direction })
    }

    if ($restartExplorer) {
        Invoke-Step 'Restarting Explorer to apply visual changes' {
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            Start-Process explorer.exe
        }
        if ($TargetProfile -in @('Default', 'Both')) {
            Write-Log 'Explorer was restarted for the current session only - a tweak mirrored into the Default profile below takes effect the next time a NEW user signs in for the first time, not on the next Explorer restart.'
        }
    }

    if ($TargetProfile -in @('Default', 'Both')) {
        $hkcuAppliedDefs = @($appliedDefs | Where-Object { $_.Def.scope -eq 'HKCU' })
        if ($hkcuAppliedDefs.Count -gt 0) {
            Invoke-Step "Mirroring $($hkcuAppliedDefs.Count) per-user tweak(s) into the Default profile (so a future/new user account inherits them)" {
                Invoke-DefaultProfileRegistry -Body {
                    foreach ($applied in $hkcuAppliedDefs) {
                        $def = $applied.Def
                        $direction = $applied.Direction
                        foreach ($entry in ($def.entries | Where-Object { $_.path -like 'HKCU:*' })) {
                            $value = if ($direction -eq 'on') { $entry.onValue } else { $entry.offValue }
                            $defaultPath = $entry.path -replace '^HKCU:', $DefaultRoot
                            try {
                                if ($value -eq '<RemoveEntry>') {
                                    Remove-ItemProperty -Path $defaultPath -Name $entry.name -ErrorAction SilentlyContinue
                                } else {
                                    New-Item -Path $defaultPath -Force -ErrorAction SilentlyContinue | Out-Null
                                    Set-ItemProperty -Path $defaultPath -Name $entry.name -Value $value -Type $entry.type -ErrorAction Stop
                                }
                                Write-Log "Mirrored to Default profile: $($def.label) -> $direction"
                            } catch {
                                Write-Log "Could not mirror '$($def.label)' to the Default profile: $($_.Exception.Message)" 'WARN'
                            }
                        }
                    }
                }
            }
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
                Add-UndoDnsEntry -Adapter $adapter

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

function Invoke-TimeSync {
    Write-Log '--- Fix: Forcing an immediate time resync ---'
    # Only touch the NTP peer list on a non-domain-joined machine - a domain-joined PC is
    # supposed to sync from the domain hierarchy (PDC emulator), and pointing it at
    # pool.ntp.org instead would work against Kerberos's clock-skew tolerance and
    # whatever the domain's own time policy already enforces.
    $isDomainJoined = [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).PartOfDomain
    if (-not $isDomainJoined) {
        Invoke-Step 'Configuring pool.ntp.org as the time source (not domain-joined)' {
            & w32tm /config /manualpeerlist:'pool.ntp.org' /syncfromflags:manual /reliable:yes /update 2>&1 | ForEach-Object { Write-Log "w32tm config: $_" }
            Restart-Service -Name w32time -ErrorAction SilentlyContinue
        }
    } else {
        Write-Log 'Machine is domain-joined - leaving the time source as the domain hierarchy, only forcing a resync.'
    }
    Invoke-Step 'Resyncing the system clock (w32tm /resync)' {
        $resyncOutput = & w32tm /resync /force 2>&1
        $resyncOutput | ForEach-Object { Write-Log "w32tm resync: $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Log "w32tm /resync exited with code $LASTEXITCODE - the time service may not be running or reachable yet (common right after a fresh config change)." 'WARN'
        } else {
            Write-Log 'Time resync completed successfully.'
        }
    }
}

function Invoke-NetFx3Enable {
    Write-Log '--- Fix: Enabling .NET Framework 3.5 ---'
    Invoke-Step 'Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All' {
        try {
            $result = Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart -ErrorAction Stop
            if ($result -and $result.RestartNeeded) {
                Write-Log '.NET Framework 3.5 enabled - a restart is recommended to fully finish.'
            } else {
                Write-Log '.NET Framework 3.5 enabled.'
            }
        } catch {
            Write-Log ".NET Framework 3.5 could not be enabled: $($_.Exception.Message). This usually means no internet access and no Windows installation media/SXS source configured." 'WARN'
        }
    }
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
    # Groove = legacy consumer OneDrive sync client, always excluded - -OfficeExcludeApps
    # (wired from the GUI's per-run checkboxes) adds any of Teams/OneDrive/Access/
    # Publisher/Lync/OneNote on top of that, verified against Microsoft's own ODT
    # ExcludeApp ID list before allowing them into the XML.
    # SourcePath points /download and /configure at the same local cache, so /configure
    # installs from what pre-flight already verified downloaded cleanly instead of
    # re-pulling from the CDN. RemoveMSI clears any old MSI-based Office as part of this
    # same install pass instead of a separate manual msiexec loop. AUTOACTIVATE is a
    # volume-licence Property and is silently ignored for O365BusinessRetail - omitted so
    # the config doesn't imply activation behavior it doesn't actually control.
    $allowedExcludeApps = @('Teams', 'OneDrive', 'Access', 'Publisher', 'Lync', 'OneNote')
    $excludeAppLines = New-Object System.Collections.Generic.List[string]
    $excludeAppLines.Add('      <ExcludeApp ID="Groove" />')
    if ($OfficeExcludeApps) {
        $requestedApps = @($OfficeExcludeApps -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        foreach ($app in $requestedApps) {
            if ($allowedExcludeApps -contains $app) {
                $excludeAppLines.Add("      <ExcludeApp ID=""$app"" />")
            } else {
                Write-Log "Ignoring unrecognized -OfficeExcludeApps value '$app' - must be one of: $($allowedExcludeApps -join ', ')." 'WARN'
            }
        }
    }
    $excludeAppXml = $excludeAppLines -join "`r`n"
    $sharedLicensingXml = if ($OfficeSharedComputerLicensing) { "`r`n  <Property Name=""SharedComputerLicensing"" Value=""1"" />" } else { '' }
    @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="$OfficeChannel" SourcePath="$SourceDir">
    <Product ID="O365BusinessRetail">
      <Language ID="$OfficeLanguage" />
$excludeAppXml
    </Product>
  </Add>
  <Updates Enabled="TRUE" Channel="$OfficeChannel" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Logging Level="Standard" Path="C:\ProgramData\DellOfficeDeploy" />
  <RemoveMSI />$sharedLicensingXml
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
# PROVISIONING (Phase 2 core) - client hostname, OneDrive KFM, regional/power/lock
# baseline. Opt-in, driven from the GUI's Provisioning tab / client profile.
# ============================================================================

function Rename-ComputerFromPattern {
    param([string]$Pattern)
    Invoke-Step "Renaming computer using pattern '$Pattern'" {
        if (-not $Pattern) {
            Write-Log 'No hostname pattern provided - nothing to do.' 'WARN'
            return
        }
        $dsregOutput = & dsregcmd /status 2>&1 | Out-String
        if ($dsregOutput -match 'AzureAdJoined\s*:\s*YES') {
            Write-Log 'This machine is already Entra (Azure AD) joined - renaming now can break the device identity Entra already has on record. Skipping. Rename before joining, not after.' 'WARN'
            return
        }
        try {
            $serial = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber
        } catch {
            $serial = 'UNKNOWN'
        }
        # NetBIOS-safe: letters/digits/hyphens only, 15 chars max - Windows itself still
        # enforces the 15-char limit for Rename-Computer regardless of DNS's longer limit.
        $newName = $Pattern -replace '\{SERIAL\}', $serial
        $newName = $newName -replace '[^A-Za-z0-9-]', ''
        if ($newName.Length -gt 15) { $newName = $newName.Substring(0, 15) }
        if (-not $newName) {
            Write-Log "Pattern '$Pattern' produced an empty computer name - not renaming." 'WARN'
            return
        }
        if ($newName -eq $env:COMPUTERNAME) {
            Write-Log "Computer name is already '$newName' - nothing to do."
            return
        }
        try {
            Rename-Computer -NewName $newName -Force -ErrorAction Stop
            Write-Log "Computer renamed to '$newName'. Takes effect after a reboot."
        } catch {
            Write-Log "Could not rename the computer: $($_.Exception.Message)" 'WARN'
        }
    }
}

function Set-OneDriveKfm {
    param([string]$TenantId, [bool]$Desktop, [bool]$Documents, [bool]$Pictures)
    Invoke-Step 'Configuring OneDrive Known Folder Move (silent sign-in + redirect)' {
        if (-not $TenantId) {
            Write-Log 'No Entra tenant ID provided - silent OneDrive sign-in/KFM only works on an Entra-joined device with a tenant ID. Skipping.' 'WARN'
            return
        }
        try {
            $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
            New-Item -Path $policyPath -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path $policyPath -Name 'SilentAccountConfig' -Value 1 -Type DWord -ErrorAction Stop
            Set-ItemProperty -Path $policyPath -Name 'KFMSilentOptIn' -Value $TenantId -Type String -ErrorAction Stop
            Set-ItemProperty -Path $policyPath -Name 'KFMSilentOptInWithNotification' -Value 1 -Type DWord -ErrorAction Stop
            Set-ItemProperty -Path $policyPath -Name 'KFMBlockOptOut' -Value 1 -Type DWord -ErrorAction Stop
            Set-ItemProperty -Path $policyPath -Name 'FilesOnDemandEnabled' -Value 1 -Type DWord -ErrorAction Stop
            if ($Desktop) { Set-ItemProperty -Path $policyPath -Name 'KFMSilentOptInDesktop' -Value 1 -Type DWord -ErrorAction Stop }
            if ($Documents) { Set-ItemProperty -Path $policyPath -Name 'KFMSilentOptInDocuments' -Value 1 -Type DWord -ErrorAction Stop }
            if ($Pictures) { Set-ItemProperty -Path $policyPath -Name 'KFMSilentOptInPictures' -Value 1 -Type DWord -ErrorAction Stop }
            Write-Log "OneDrive KFM configured for tenant $TenantId (Desktop=$Desktop, Documents=$Documents, Pictures=$Pictures). Takes effect the next time OneDrive starts and the user signs in."
        } catch {
            Write-Log "Could not configure OneDrive KFM: $($_.Exception.Message)" 'WARN'
        }
    }
}

function Get-DcuExitCodeMeaning {
    param([int]$ExitCode)
    switch ($ExitCode) {
        0   { 'OK.' }
        1   { 'Reboot required to complete the operation.' }
        3   { 'Not a Dell system.' }
        5   { 'A reboot was already pending from a previous operation.' }
        7   { 'Unsupported model.' }
        500 { 'No updates found.' }
        501 { 'Scan error.' }
        default { "Unrecognized exit code $ExitCode." }
    }
}

function Invoke-DellCommandUpdateApply {
    # Dell Command Update (Classic or Universal) both install their CLI to a
    # "Dell\CommandUpdate" folder, just under a different Program Files root depending on
    # build - check both rather than assume one.
    $candidatePaths = @(
        (Join-Path $env:ProgramFiles 'Dell\CommandUpdate\dcu-cli.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Dell\CommandUpdate\dcu-cli.exe')
    )
    $dcuPath = $candidatePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $dcuPath) {
        Write-Log "dcu-cli.exe not found at any of: $($candidatePaths -join ', ') - install Dell Command Update first (the OEM update tool option)." 'WARN'
        return
    }

    $reportDir = Join-Path $workDir 'dcu'
    New-Item -ItemType Directory -Path $reportDir -Force -ErrorAction SilentlyContinue | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $reportPath = Join-Path $reportDir "scan_$stamp.xml"
    $applyLogPath = Join-Path $reportDir "apply_$stamp.log"

    Write-Log 'Configuring Dell Command Update (silent, no user consent prompt)...'
    & $dcuPath /configure -silent -autoSuspendBitLocker=enable -userConsent=disable 2>&1 | ForEach-Object { Write-Log "dcu-cli: $_" }

    Write-Log 'Scanning for Dell updates...'
    & $dcuPath /scan -silent "-report=$reportPath" 2>&1 | ForEach-Object { Write-Log "dcu-cli: $_" }
    $scanExit = $LASTEXITCODE
    Write-Log "Scan exit code $scanExit - $(Get-DcuExitCodeMeaning -ExitCode $scanExit)"
    if ($scanExit -eq 500) {
        Write-Log 'No Dell updates found - already current.'
        return
    }
    if ($scanExit -notin @(0, 1, 5)) {
        Write-Log "Scan did not complete cleanly (exit $scanExit) - not attempting to apply updates." 'WARN'
        return
    }

    Write-Log 'Applying Dell updates (no automatic reboot)...'
    & $dcuPath /applyUpdates -silent -reboot=disable "-outputLog=$applyLogPath" 2>&1 | ForEach-Object { Write-Log "dcu-cli: $_" }
    $applyExit = $LASTEXITCODE
    Write-Log "Apply exit code $applyExit - $(Get-DcuExitCodeMeaning -ExitCode $applyExit)"
    if ($applyExit -in @(1, 5)) {
        # Exit 1/5 is Dell's documented "succeeded, needs a reboot" result, not a failure -
        # plain INFO, not WARN, so a normal/expected outcome doesn't get flagged as an error
        # and paint the GUI's completion banner yellow for no real reason.
        Write-Log 'REBOOT REQUIRED to finish applying Dell updates - use the Reboot button (Debloat + Office tab) or reboot manually.'
    } elseif ($applyExit -ne 0) {
        Write-Log "Apply did not report success (exit $applyExit) - check $applyLogPath for detail." 'WARN'
    }
}

function Invoke-LenovoSystemUpdateApply {
    $tvsuPath = Join-Path ${env:ProgramFiles(x86)} 'Lenovo\System Update\tvsu.exe'
    if (-not (Test-Path $tvsuPath)) {
        Write-Log "tvsu.exe not found at $tvsuPath - install Lenovo System Update first (the OEM update tool option)." 'WARN'
        return
    }

    try {
        $policyPath = 'HKLM:\Software\Policies\Lenovo\System Update\UserSettings\General'
        New-Item -Path $policyPath -Force -ErrorAction SilentlyContinue | Out-Null
        Set-ItemProperty -Path $policyPath -Name 'AdminCommandLine' -Value '-search A -action INSTALL -includerebootpackages 0,3 -noicon -nolicense -noreboot -exporttowmi' -Type String -ErrorAction Stop
    } catch {
        Write-Log "Could not configure Lenovo System Update's command line policy: $($_.Exception.Message)" 'WARN'
        return
    }

    Write-Log 'Running Lenovo System Update (search + install, no automatic reboot)...'
    & $tvsuPath /CM 2>&1 | ForEach-Object { Write-Log "tvsu: $_" }
    Write-Log "tvsu.exe exited with code $LASTEXITCODE"

    try {
        $results = Get-CimInstance -Namespace 'root\Lenovo' -ClassName 'Lenovo_Updates' -ErrorAction Stop
        if ($results) {
            foreach ($r in $results) { Write-Log "Lenovo update result: $($r | Select-Object * | Out-String)" }
        } else {
            Write-Log 'No results in root\Lenovo\Lenovo_Updates (WMI) - check the log above for what tvsu.exe itself reported.'
        }
    } catch {
        Write-Log "Could not read Lenovo update results from WMI (root\Lenovo\Lenovo_Updates): $($_.Exception.Message)" 'WARN'
    }
    Write-Log 'If any installed package needed a reboot, Lenovo System Update needs one to finish - reboot via the Reboot button (Debloat + Office tab) or manually, then re-run this to confirm nothing remains.'
}

function Invoke-OemDriverUpdates {
    Invoke-Step 'Applying OEM driver/BIOS updates' {
        # BIOS packages write firmware - a battery-powered flash that loses power mid-write
        # can brick the board. BatteryStatus 1/4/5 (verified via Microsoft's own documented
        # values) are the "definitely on battery" states (Battery Power/Low/Critical); no
        # battery instance at all means a desktop, always fine; everything else (AC,
        # Charging, Fully Charged, etc.) is treated as plugged in.
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($battery -and $battery.BatteryStatus -in @(1, 4, 5)) {
            Write-Log "This machine appears to be running on battery power (BatteryStatus=$($battery.BatteryStatus)) - OEM driver/BIOS updates require AC power. Plug in and retry." 'WARN'
            return
        }

        $isDell = $machineManufacturer -match 'Dell'
        $isLenovo = $machineManufacturer -match 'Lenovo'
        if (-not $isDell -and -not $isLenovo) {
            Write-Log "Manufacturer '$machineManufacturer' is neither Dell nor Lenovo - nothing to update."
            return
        }

        # Suspend BitLocker for one reboot before a firmware update - a BIOS/driver change
        # can trip the TPM's measured-boot state and force a 48-character recovery-key
        # prompt on next boot otherwise.
        try {
            $bitlockerVolume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
            if ($bitlockerVolume.ProtectionStatus -eq 'On') {
                Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 -ErrorAction Stop
                Write-Log 'BitLocker suspended for one reboot before applying updates.'
            }
        } catch {
            Write-Log "Could not check/suspend BitLocker (may mean it isn't enabled, or the BitLocker module isn't available on this edition): $($_.Exception.Message)"
        }

        if ($isDell) { Invoke-DellCommandUpdateApply } else { Invoke-LenovoSystemUpdateApply }
    }
}

function Enable-MicrosoftUpdateService {
    Invoke-Step 'Opting into Microsoft Update (Office/driver updates alongside Windows Update)' {
        try {
            $serviceManager = New-Object -ComObject Microsoft.Update.ServiceManager
            $serviceManager.AddService2('7971f918-a847-4430-9279-4a52d1efe18d', 7, '') | Out-Null
            Write-Log 'Opted into Microsoft Update.'
        } catch {
            Write-Log "Could not opt into Microsoft Update (often means it's already opted in): $($_.Exception.Message)"
        }
    }
}

function Invoke-StoreAppUpdateScan {
    try {
        $mdmClass = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction Stop
        if ($mdmClass) {
            Invoke-CimMethod -InputObject $mdmClass -MethodName 'UpdateScanMethod' -ErrorAction Stop | Out-Null
            Write-Log 'Triggered a Microsoft Store app update scan.'
        }
    } catch {
        Write-Log "Could not trigger a Store app update scan (the MDM bridge may not be available on this edition/config): $($_.Exception.Message)"
    }
}

function Invoke-WindowsUpdateSearchOnly {
    $result = [PSCustomObject]@{ Count = 0; Titles = @() }
    try {
        $updateSession = New-Object -ComObject Microsoft.Update.Session
        $updateSearcher = $updateSession.CreateUpdateSearcher()
        $searchResult = $updateSearcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
        $result.Count = $searchResult.Updates.Count
        if ($result.Count -gt 0) {
            $result.Titles = @(0..($result.Count - 1) | ForEach-Object { $searchResult.Updates.Item($_).Title })
        }
    } catch {
        Write-Log "Windows Update search failed: $($_.Exception.Message)" 'WARN'
    }
    return $result
}

function Invoke-WindowsUpdatePassAttempt {
    # One search -> download -> install cycle. ResultCode reference (both Download and
    # Install results use the same enum): 2=Succeeded, 3=SucceededWithErrors, 4=Failed,
    # 5=Cancelled.
    $result = [PSCustomObject]@{ InstalledCount = 0; RebootRequired = $false; MoreUpdatesAvailable = $false; ErrorOccurred = $false; HResult = $null }
    try {
        $updateSession = New-Object -ComObject Microsoft.Update.Session
        $updateSearcher = $updateSession.CreateUpdateSearcher()
        $searchResult = $updateSearcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")

        $count = $searchResult.Updates.Count
        Write-Log "Found $count applicable update(s)."
        if ($count -eq 0) { return $result }

        $updatesToDownload = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $count; $i++) {
            $update = $searchResult.Updates.Item($i)
            if (-not $update.EulaAccepted) { [void]$update.AcceptEula() }
            [void]$updatesToDownload.Add($update)
            Write-Log "  - $($update.Title)"
        }

        Write-Log "Downloading $($updatesToDownload.Count) update(s)..."
        $downloader = $updateSession.CreateUpdateDownloader()
        $downloader.Updates = $updatesToDownload
        $downloadResult = $downloader.Download()
        Write-Log "Download result code: $($downloadResult.ResultCode)"

        $updatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $updatesToDownload.Count; $i++) {
            $update = $updatesToDownload.Item($i)
            if ($update.IsDownloaded) { [void]$updatesToInstall.Add($update) }
        }
        if ($updatesToInstall.Count -eq 0) {
            Write-Log 'No updates were successfully downloaded this pass.' 'WARN'
            $result.ErrorOccurred = $true
            return $result
        }

        Write-Log "Installing $($updatesToInstall.Count) update(s)..."
        $installer = $updateSession.CreateUpdateInstaller()
        $installer.Updates = $updatesToInstall
        $installResult = $installer.Install()
        Write-Log "Install result code: $($installResult.ResultCode)"

        $result.InstalledCount = $updatesToInstall.Count
        $result.RebootRequired = [bool]$installResult.RebootRequired
        $result.MoreUpdatesAvailable = $true
        if ($installResult.ResultCode -eq 4) { $result.ErrorOccurred = $true }
    } catch {
        Write-Log "Windows Update pass failed: $($_.Exception.Message)" 'WARN'
        $result.ErrorOccurred = $true
        $result.HResult = $_.Exception.HResult
    }
    return $result
}

function Invoke-WindowsUpdatePass {
    # WU_E_ALL_UPDATES_FAILED (0x80240022 / -2145124318 as a signed HRESULT, confirmed via
    # search rather than assumed) is usually transient - AV/network blocking the
    # SoftwareDistribution working folder - so one retry after a cooldown is worth it;
    # anything else (or a second failure) is not retried.
    $attempt = 0
    while ($true) {
        $attempt++
        $result = Invoke-WindowsUpdatePassAttempt
        if ($result.ErrorOccurred -and $result.HResult -eq -2145124318 -and $attempt -eq 1) {
            Write-Log 'Windows Update reported WU_E_ALL_UPDATES_FAILED (0x80240022, often transient) - retrying once after 60s.' 'WARN'
            Start-Sleep -Seconds 60
            continue
        }
        return $result
    }
}

function Register-WindowsUpdateResumeTask {
    # Copies the worker (and the two JSON files it hard-requires at startup) into a
    # stable cache dir under the work dir - the original install came from a timestamped
    # %TEMP%\Gr3yTools_* folder that the 7-day-old sweep (or just a reboot clearing temp
    # profiles) could remove before the scheduled task ever fires.
    $cacheDir = Join-Path $workDir 'resume_cache'
    New-Item -ItemType Directory -Path $cacheDir -Force -ErrorAction SilentlyContinue | Out-Null
    $cachedScriptPath = Join-Path $cacheDir 'Deploy-DellOfficeSetup.ps1'
    Copy-Item -Path $PSCommandPath -Destination $cachedScriptPath -Force
    Copy-Item -Path $patternsPath -Destination (Join-Path $cacheDir 'bloat-patterns.json') -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $tweaksJsonPath -Destination (Join-Path $cacheDir 'tweaks.json') -Force -ErrorAction SilentlyContinue

    $taskName = 'Gr3yToolsWindowsUpdateResume'
    $taskArgument = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$cachedScriptPath`" -RunWindowsUpdate -Resume -NoReboot -SkipDebloat -SkipOfficeRemoval -SkipOfficeInstall"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgument
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "Registered scheduled task '$taskName' to resume Windows Update automatically after the next reboot."
}

function Unregister-WindowsUpdateResumeTask {
    Unregister-ScheduledTask -TaskName 'Gr3yToolsWindowsUpdateResume' -Confirm:$false -ErrorAction SilentlyContinue
}

function Invoke-WindowsUpdateToCompletion {
    param([switch]$Resume)

    $stateFile = Join-Path $workDir 'wu_resume_state.json'
    $maxPasses = 4

    if ($DryRun -and -not $Resume) {
        Invoke-Step 'Checking for Windows updates (dry run - search only, no download/install)' {
            $searchOnly = Invoke-WindowsUpdateSearchOnly
            if ($searchOnly.Count -gt 0) {
                Write-Log "DRYRUN: $($searchOnly.Count) update(s) available: $($searchOnly.Titles -join '; ')" 'DRYRUN'
            } else {
                Write-Log 'DRYRUN: No updates available - already current.' 'DRYRUN'
            }
        }
        return
    }

    $startPass = 1
    if ($Resume -and (Test-Path $stateFile)) {
        try {
            $state = Get-Content -Path $stateFile -Raw | ConvertFrom-Json
            $startPass = [int]$state.pass + 1
            Write-Log "Resuming Windows Update after reboot - continuing at pass $startPass of $maxPasses."
        } catch {
            Write-Log "Could not read the resume state file - starting from pass 1 instead: $($_.Exception.Message)" 'WARN'
        }
    } elseif ($Resume) {
        Write-Log 'Resume requested but no state file found - starting from pass 1.' 'WARN'
    }

    Invoke-Step "Patching Windows Update to current (starting at pass $startPass of up to $maxPasses)" {
        Enable-MicrosoftUpdateService
        Invoke-StoreAppUpdateScan

        for ($pass = $startPass; $pass -le $maxPasses; $pass++) {
            Write-Log "--- Windows Update pass $pass of $maxPasses ---"
            $passResult = Invoke-WindowsUpdatePass

            if ($passResult.ErrorOccurred) {
                Write-Log "Windows Update pass $pass reported an error - stopping here rather than looping further." 'WARN'
                Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
                Unregister-WindowsUpdateResumeTask
                return
            }

            if ($passResult.InstalledCount -eq 0 -and -not $passResult.MoreUpdatesAvailable) {
                Write-Log 'No further updates found - Windows Update is current.'
                Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
                Unregister-WindowsUpdateResumeTask
                return
            }

            if ($passResult.RebootRequired) {
                @{ pass = $pass; timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') } | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
                Register-WindowsUpdateResumeTask
                Write-Log "REBOOT REQUIRED to continue Windows Update (pass $pass of $maxPasses installed $($passResult.InstalledCount) update(s)) - it will resume automatically after the next reboot. Use the Reboot button (Debloat + Office tab) or reboot manually."
                return
            }
        }

        Write-Log "Reached the $maxPasses-pass cap - some updates may remain. Re-run Patch to Current if needed." 'WARN'
        Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
        Unregister-WindowsUpdateResumeTask
    }
}

function Get-ValidationChecks {
    # Read-only checks - returns {Check; Status (OK/ATTENTION/INFO/UNKNOWN); Detail}
    $checks = New-Object System.Collections.Generic.List[object]

    try {
        $licProduct = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationId='55c92734-d682-4d71-983e-d6ec3f16059f'" -ErrorAction Stop | Select-Object -First 1
        $licensed = $licProduct -and $licProduct.LicenseStatus -eq 1
        if (-not $licensed) {
            try { & cscript.exe //nologo "$env:SystemRoot\System32\slmgr.vbs" /ato 2>&1 | Out-Null } catch {}
            Start-Sleep -Seconds 2
            $licProduct = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationId='55c92734-d682-4d71-983e-d6ec3f16059f'" -ErrorAction SilentlyContinue | Select-Object -First 1
            $licensed = $licProduct -and $licProduct.LicenseStatus -eq 1
        }
        $checks.Add([PSCustomObject]@{ Check = 'Windows Activation'; Status = if ($licensed) { 'OK' } else { 'ATTENTION' }; Detail = "LicenseStatus=$($licProduct.LicenseStatus)" })
    } catch {
        $checks.Add([PSCustomObject]@{ Check = 'Windows Activation'; Status = 'UNKNOWN'; Detail = $_.Exception.Message })
    }

    try {
        $defender = Get-MpComputerStatus -ErrorAction Stop
        $sigAge = (Get-Date) - $defender.AntivirusSignatureLastUpdated
        $checks.Add([PSCustomObject]@{ Check = 'Defender Real-Time Protection'; Status = if ($defender.RealTimeProtectionEnabled) { 'OK' } else { 'ATTENTION' }; Detail = "TamperProtected=$($defender.IsTamperProtected)" })
        $checks.Add([PSCustomObject]@{ Check = 'Defender Signature Age'; Status = if ($sigAge.TotalDays -lt 7) { 'OK' } else { 'ATTENTION' }; Detail = "$([int]$sigAge.TotalDays) day(s) old" })
    } catch {
        # Get-MpComputerStatus fails outright when a third-party AV owns the Security
        # Center - check root\SecurityCenter2 for that instead of just reporting failure.
        try {
            $avProducts = Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop
            $names = ($avProducts | Select-Object -ExpandProperty displayName) -join ', '
            $checks.Add([PSCustomObject]@{ Check = 'Antivirus'; Status = if ($names) { 'OK' } else { 'ATTENTION' }; Detail = if ($names) { "Third-party: $names" } else { 'No AV product registered' } })
        } catch {
            $checks.Add([PSCustomObject]@{ Check = 'Antivirus'; Status = 'UNKNOWN'; Detail = $_.Exception.Message })
        }
    }

    try {
        $fwProfiles = Get-NetFirewallProfile -ErrorAction Stop
        $allEnabled = -not ($fwProfiles | Where-Object { -not $_.Enabled })
        $checks.Add([PSCustomObject]@{ Check = 'Firewall (all profiles)'; Status = if ($allEnabled) { 'OK' } else { 'ATTENTION' }; Detail = ($fwProfiles | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join ', ' })
    } catch {
        $checks.Add([PSCustomObject]@{ Check = 'Firewall'; Status = 'UNKNOWN'; Detail = $_.Exception.Message })
    }

    try {
        $dsregOutput = & dsregcmd /status 2>&1 | Out-String
        $azureJoined = [regex]::Match($dsregOutput, 'AzureAdJoined\s*:\s*(\S+)').Groups[1].Value
        $domainJoined = [regex]::Match($dsregOutput, 'DomainJoined\s*:\s*(\S+)').Groups[1].Value
        $checks.Add([PSCustomObject]@{ Check = 'Device Join State'; Status = 'INFO'; Detail = "AzureAdJoined=$azureJoined, DomainJoined=$domainJoined" })
    } catch {
        $checks.Add([PSCustomObject]@{ Check = 'Device Join State'; Status = 'UNKNOWN'; Detail = $_.Exception.Message })
    }

    try {
        $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
        $checks.Add([PSCustomObject]@{ Check = 'Secure Boot'; Status = if ($secureBoot) { 'OK' } else { 'ATTENTION' }; Detail = "Enabled=$secureBoot" })
    } catch {
        $checks.Add([PSCustomObject]@{ Check = 'Secure Boot'; Status = 'UNKNOWN'; Detail = 'Not UEFI, or could not be checked' })
    }

    $pendingReboot = $false
    $pendingReasons = New-Object System.Collections.Generic.List[string]
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pendingReboot = $true; $pendingReasons.Add('CBS') }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pendingReboot = $true; $pendingReasons.Add('WindowsUpdate') }
    if (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue) { $pendingReboot = $true; $pendingReasons.Add('PendingFileRename') }
    $checks.Add([PSCustomObject]@{ Check = 'Pending Reboot'; Status = if ($pendingReboot) { 'ATTENTION' } else { 'OK' }; Detail = if ($pendingReboot) { $pendingReasons -join ', ' } else { 'None detected' } })

    $sysDrive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction SilentlyContinue
    $freeGb = if ($sysDrive) { [Math]::Round($sysDrive.FreeSpace / 1GB, 1) } else { $null }
    $checks.Add([PSCustomObject]@{ Check = 'Free Disk Space'; Status = if ($freeGb -and $freeGb -ge 20) { 'OK' } else { 'ATTENTION' }; Detail = "$freeGb GB free on $env:SystemDrive" })

    try {
        $wuSession = New-Object -ComObject Microsoft.Update.Session
        $wuSearcher = $wuSession.CreateUpdateSearcher()
        $historyCount = $wuSearcher.GetTotalHistoryCount()
        $lastSuccess = $null
        if ($historyCount -gt 0) {
            $entries = $wuSearcher.QueryHistory(0, [Math]::Min($historyCount, 20))
            $lastSuccess = $entries | Where-Object { $_.ResultCode -eq 2 } | Sort-Object Date -Descending | Select-Object -First 1
        }
        $checks.Add([PSCustomObject]@{ Check = 'Last Windows Update Success'; Status = if ($lastSuccess) { 'OK' } else { 'UNKNOWN' }; Detail = if ($lastSuccess) { "$($lastSuccess.Title) on $($lastSuccess.Date)" } else { 'No successful update found in recent history' } })
    } catch {
        $checks.Add([PSCustomObject]@{ Check = 'Last Windows Update Success'; Status = 'UNKNOWN'; Detail = $_.Exception.Message })
    }

    $isDell = $machineManufacturer -match 'Dell'
    $isLenovo = $machineManufacturer -match 'Lenovo'
    if ($isDell -or $isLenovo) {
        $displayNames = if ($isDell) { @('Dell Command | Update', 'Dell Command | Update for Windows Universal') } else { @('Lenovo System Update') }
        $oemToolPresent = Get-UninstallEntries | Where-Object { $_.DisplayName -in $displayNames } | Select-Object -First 1
        $checks.Add([PSCustomObject]@{ Check = 'OEM Update Tool'; Status = if ($oemToolPresent) { 'OK' } else { 'ATTENTION' }; Detail = if ($oemToolPresent) { "$($oemToolPresent.DisplayName) installed" } else { 'Not installed' } })
    }

    return $checks
}

function Get-MachineInventory {
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $tpm = Get-Tpm -ErrorAction SilentlyContinue
    $ramGb = if ($cs) { [Math]::Round($cs.TotalPhysicalMemory / 1GB, 1) } else { $null }
    $disks = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{ Model = $_.Model; SizeGB = [Math]::Round($_.Size / 1GB, 1); InterfaceType = $_.InterfaceType }
    })
    $macs = @(Get-CimInstance -ClassName Win32_NetworkAdapter -Filter 'PhysicalAdapter=True AND MACAddress IS NOT NULL' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty MACAddress)
    $ubr = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'UBR' -ErrorAction SilentlyContinue).UBR
    $installDate = if ($os -and $os.InstallDate) { $os.InstallDate.ToString('yyyy-MM-dd') } else { $null }

    $c2rKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $officeInfo = if (Test-Path $c2rKey) {
        $c2r = Get-ItemProperty -Path $c2rKey -ErrorAction SilentlyContinue
        [PSCustomObject]@{ ProductReleaseIds = $c2r.ProductReleaseIds; Version = $c2r.VersionToReport; UpdateChannel = $c2r.UpdateChannel }
    } else { $null }

    $installedPrograms = @(Get-UninstallEntries | Select-Object DisplayName, DisplayVersion, Publisher | Sort-Object DisplayName)

    [ordered]@{
        capturedAt        = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        toolVersion        = $Version
        toolCommit         = $Commit
        hostname           = $env:COMPUTERNAME
        serial             = $machineSerial
        manufacturer       = $machineManufacturer
        model              = $machineModel
        biosVersion        = $bios.SMBIOSBIOSVersion
        tpmPresent         = if ($tpm) { $tpm.TpmPresent } else { $null }
        tpmReady           = if ($tpm) { $tpm.TpmReady } else { $null }
        tpmSpecVersion     = if ($tpm) { $tpm.ManufacturerVersion } else { $null }
        windowsEdition     = $os.Caption
        windowsBuild       = $os.BuildNumber
        windowsUbr         = $ubr
        windowsInstalled   = $installDate
        ramGb              = $ramGb
        disks              = $disks
        macAddresses       = $macs
        office             = $officeInfo
        installedPrograms  = $installedPrograms
    }
}

function New-ValidationHandoffPackage {
    param([string]$ClientCode)
    Invoke-Step 'Generating validation report and handoff package' {
        $checks = Get-ValidationChecks
        $inventory = Get-MachineInventory

        $rawFolderName = "$(if ($ClientCode) { "${ClientCode}_" })$($env:COMPUTERNAME)_$machineSerial"
        $folderName = $rawFolderName -replace '[\\/:*?"<>|]', '_'
        $handoffDir = Join-Path $workDir "handoff\$folderName"
        New-Item -ItemType Directory -Path $handoffDir -Force -ErrorAction SilentlyContinue | Out-Null

        $inventory | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $handoffDir 'inventory.json') -Encoding UTF8

        $validationLines = New-Object System.Collections.Generic.List[string]
        $validationLines.Add("Validation report for $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $validationLines.Add('')
        foreach ($c in $checks) { $validationLines.Add("[$($c.Status)] $($c.Check): $($c.Detail)") }
        ($validationLines -join "`r`n") | Set-Content -Path (Join-Path $handoffDir 'validation.txt') -Encoding UTF8

        Copy-Item -Path $logPath -Destination (Join-Path $handoffDir (Split-Path -Leaf $logPath)) -Force -ErrorAction SilentlyContinue

        $attentionCount = @($checks | Where-Object { $_.Status -eq 'ATTENTION' }).Count
        $htmlChecks = $checks | Select-Object Check, Status, Detail | ConvertTo-Html -Fragment -PreContent '<h2>Validation Checks</h2>'
        $htmlSummary = [PSCustomObject]@{
            Hostname = $inventory.hostname; Serial = $inventory.serial; Manufacturer = $inventory.manufacturer; Model = $inventory.model
            BIOS = $inventory.biosVersion; Windows = "$($inventory.windowsEdition) build $($inventory.windowsBuild).$($inventory.windowsUbr)"
            'RAM (GB)' = $inventory.ramGb; 'Tool Version' = $inventory.toolVersion
        } | ConvertTo-Html -Fragment -PreContent '<h2>Machine Summary</h2>'
        $css = @'
<style>
body { font-family: "Segoe UI", Arial, sans-serif; margin: 24px; color: #222; }
table { border-collapse: collapse; width: 100%; margin-bottom: 24px; }
th, td { border: 1px solid #ccc; padding: 6px 10px; text-align: left; }
th { background: #232629; color: #fff; }
tr:nth-child(even) { background: #f4f4f4; }
</style>
'@
        $bodyHtml = "<h1>Handoff Report - $env:COMPUTERNAME</h1><p>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $attentionCount item(s) need attention</p>$htmlSummary$htmlChecks"
        $reportPath = Join-Path $handoffDir 'report.html'
        (ConvertTo-Html -Head $css -Title "Handoff Report - $env:COMPUTERNAME" -Body $bodyHtml) | Set-Content -Path $reportPath -Encoding UTF8

        Write-Log "Handoff package written to $handoffDir ($attentionCount item(s) need attention)."
        if (-not $DryRun) {
            try { Start-Process -FilePath $reportPath } catch { Write-Log "Could not auto-open the report: $($_.Exception.Message)" 'WARN' }
        }
    }
}

function Invoke-PostProvisioningCleanup {
    # Standalone from Fixes' Invoke-WindowsUpdateReset (which does a heavier reset of
    # wuauserv/bits/cryptsvc/msiserver for a STUCK update) - this only needs wuauserv
    # stopped long enough to clear the Download subfolder of files it may have locked.
    Write-Log '--- Post-provisioning cleanup ---'

    Invoke-Step 'Clearing temp folders' {
        Get-ChildItem -Path $env:TEMP -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path (Join-Path $env:SystemRoot 'Temp') -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    Invoke-Step 'Clearing the Windows Update download cache (SoftwareDistribution\Download)' {
        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
        $downloadPath = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
        Get-ChildItem -Path $downloadPath -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue
    }

    Invoke-Step 'Clearing the ODT install source cache' {
        # Computed fresh rather than reusing $officeSourceDir - Start-ProvisionJob always
        # bundles -SkipOfficeRemoval -SkipOfficeInstall, so that variable is never set on
        # the code path that reaches this function via the GUI's Provisioning tab.
        $officeSourceCache = Join-Path $workDir 'OfficeSource'
        if (Test-Path $officeSourceCache) {
            Remove-Item -Path $officeSourceCache -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-Step 'Running Disk Cleanup (cleanmgr /VERYLOWDISK)' {
        # /VERYLOWDISK runs with Disk Cleanup's default item set, no prompts, no prior
        # /SAGESET profile needed - unlike /SAGERUN:n, which requires one.
        $proc = Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/VERYLOWDISK' -PassThru -Wait
        Write-Log "cleanmgr exited with code $($proc.ExitCode)."
    }

    Invoke-Step 'Running DISM component store cleanup (StartComponentCleanup, no ResetBase)' {
        # Deliberately NOT /ResetBase - that permanently removes the ability to uninstall
        # any currently-installed update, which StartComponentCleanup alone does not do.
        $dismOutput = & DISM /Online /Cleanup-Image /StartComponentCleanup 2>&1
        $dismExit = $LASTEXITCODE
        $finalStatus = $dismOutput | Where-Object { $_ -and $_.Trim() -and $_ -notmatch '^\s*\[?=*\s*\d+\.?\d*%' } | Select-Object -Last 3
        foreach ($line in $finalStatus) { Write-Log "DISM: $line" }
        if ($dismExit -ne 0) { Write-Log "DISM StartComponentCleanup exited with code $dismExit." 'WARN' }
    }

    Write-Log 'Post-provisioning cleanup complete.'
}

function Set-RegionalPowerLockBaseline {
    param([string]$TimeZoneId, [string]$GeoId, [string]$CultureName, [string]$PowerPlanName, [int]$LockTimeoutSec)
    Invoke-Step 'Applying regional, power and lock baseline' {
        try {
            if ($TimeZoneId) {
                Set-TimeZone -Id $TimeZoneId -ErrorAction Stop
                Write-Log "Time zone set to $TimeZoneId"
            }
            Get-Service -Name tzautoupdate -ErrorAction SilentlyContinue | Set-Service -StartupType Automatic -ErrorAction SilentlyContinue
            if ($GeoId) {
                Set-WinHomeLocation -GeoId $GeoId -ErrorAction Stop
                Write-Log "Home location (GeoId) set to $GeoId"
            }
            if ($CultureName) {
                Set-Culture -CultureInfo $CultureName -ErrorAction Stop
                Write-Log "Culture set to $CultureName"
            }
            # Domain controllers own time sync for domain members - resyncing here would
            # just fight the domain's own NTP hierarchy.
            $csForTime = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
            if (-not ($csForTime -and $csForTime.PartOfDomain)) {
                w32tm /resync 2>&1 | ForEach-Object { Write-Log "w32tm: $_" }
            }
            if ($PowerPlanName) {
                $schemeLine = powercfg /list | Select-String -Pattern ([regex]::Escape($PowerPlanName))
                if ($schemeLine) {
                    $schemeGuid = [regex]::Match($schemeLine.Line, '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})').Value
                    if ($schemeGuid) {
                        powercfg /setactive $schemeGuid 2>&1 | Out-Null
                        Write-Log "Power plan set to $PowerPlanName"
                    }
                } else {
                    Write-Log "Power plan '$PowerPlanName' not found via powercfg /list - leaving the active plan unchanged." 'WARN'
                }
            }
            powercfg /change monitor-timeout-ac 15 2>&1 | Out-Null
            $lockPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
            New-Item -Path $lockPath -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path $lockPath -Name 'InactivityTimeoutSecs' -Value $LockTimeoutSec -Type DWord -ErrorAction Stop
            # Fast Startup hibernates the kernel session instead of a full shutdown, which
            # both interferes with Wake-on-LAN and can leave a Windows Update pass looking
            # "installed" without a genuine cold boot.
            $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
            New-Item -Path $powerKey -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path $powerKey -Name 'HiberbootEnabled' -Value 0 -Type DWord -ErrorAction Stop
            Write-Log "Regional/power/lock baseline applied (monitor timeout 15 min on AC, lock timeout ${LockTimeoutSec}s, Fast Startup off)."
        } catch {
            Write-Log "Could not fully apply the regional/power/lock baseline: $($_.Exception.Message)" 'WARN'
        }
    }
}

# ============================================================================
# MAIN
# ============================================================================

Write-Log "Starting run. DryRun=$DryRun CreateRestorePoint=$CreateRestorePoint SkipDebloat=$SkipDebloat SkipOfficeRemoval=$SkipOfficeRemoval SkipOfficeInstall=$SkipOfficeInstall OfficeExcludeApps=$OfficeExcludeApps OfficeSharedComputerLicensing=$OfficeSharedComputerLicensing TargetProfile=$TargetProfile Undo=$Undo"

if ($Undo) {
    Invoke-UndoSnapshot -Path $Undo
    Write-Log "Run complete. Log saved to $logPath"
    Stop-Transcript | Out-Null
    exit 0
}

if ($CreateRestorePoint) { New-PreDeploySystemRestorePoint }

if ($TweakReduceTelemetry) { Set-TelemetryReduced }
if ($TweakDisableHibernation) { Disable-Hibernation }
if ($TweakPreventSleep) { Set-SleepNever }
if ($TweakDisableSmartAppControl) { Disable-SmartAppControl }
if ($InstallOemUpdateTool) { Install-OemUpdateTool }
if ($CustomizeTweaks) { Invoke-CustomizeTweaks -Selections ($CustomizeTweaks -split ',' | Where-Object { $_ }) -TargetProfile $TargetProfile }
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
if ($FixTimeSync) { Invoke-TimeSync }
if ($FixNetFx3) { Invoke-NetFx3Enable }

if ($RenameComputer) { Rename-ComputerFromPattern -Pattern $HostnamePattern }
if ($ApplyOemUpdates) { Invoke-OemDriverUpdates }
if ($RunWindowsUpdate) { Invoke-WindowsUpdateToCompletion -Resume:$Resume }
if ($GenerateHandoff) { New-ValidationHandoffPackage -ClientCode $ClientCode }
if ($PostProvisioningCleanup) { Invoke-PostProvisioningCleanup }
if ($ApplyOneDriveKfm) { Set-OneDriveKfm -TenantId $EntraTenantId -Desktop $KfmDesktop -Documents $KfmDocuments -Pictures $KfmPictures }
if ($ApplyRegionalBaseline) { Set-RegionalPowerLockBaseline -TimeZoneId $TimeZoneId -GeoId $GeoId -CultureName $CultureName -PowerPlanName $PowerPlanName -LockTimeoutSec $LockTimeoutSec }

if (-not $DryRun) { Save-UndoSnapshot }

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
