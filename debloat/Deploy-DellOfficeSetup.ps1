<#
.SYNOPSIS
    Debloats a Dell or Lenovo business laptop and deploys Microsoft 365 Apps for business (en-us only).

.DESCRIPTION
    Three phases, each independently toggle-able:
      1. Remove known Dell/Lenovo OEM bloatware (AppX/MSIX apps + Win32 programs) and McAfee software
         (every program named McAfee*: trial, paid or centrally managed alike).
      2. Fully remove any existing Office installation (Click-to-Run and/or MSI-based), which also clears
         out every preinstalled Office display/proofing language in one step.
      3. Install Microsoft 365 Apps for business via the Office Deployment Tool (ODT), en-us only.

    Run in -DryRun first on a representative model to preview what would be removed (programs and
    Store apps, and the services and scheduled tasks that would be disabled) before rolling out
    silently across a fleet.

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
    passed, both run - this is the safe default for standalone/command-line use. The
    GUI passes a flag for each ticked box, so unticking BOTH passes neither and the
    worker then takes it as both (tick Skip debloat to run no OEM removal at all).

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
    internal name resolution. Resolver IPs and DoH templates are each provider's own
    well-known public addresses.

.PARAMETER DnsForce
    Applies -DnsPreset even on a domain-joined machine. Off by default - see DnsPreset.

.PARAMETER RemoveLocalAdmins
    Comma-separated account names to remove from the local Administrators group (e.g. the
    end user's account after an Entra join). Refuses to remove the built-in RID-500
    Administrator account, an unresolved Entra role SID, or whichever account would be the
    last enabled administrator remaining on the machine.

.PARAMETER CreateBreakGlassAdmin
    Creates a local administrator account (-BreakGlassAdminName) with a random 24+
    character password, disables Guest, and - only on an Entra-joined device - configures
    Windows LAPS to manage and rotate that account's password going forward. On a non-
    Entra-joined device the password has no central backup; it is written once, to an
    ACL-restricted credential file in the work directory, and never to the log.

.PARAMETER BreakGlassAdminName
    Account name for -CreateBreakGlassAdmin. Defaults to Gr3yBreakGlass. Never the
    built-in Administrator account name.

.PARAMETER EnableBitLocker
    Enables BitLocker on C: (XtsAes256, used-space-only, TPM protector) and adds a
    recovery password protector, only if a ready TPM is present and protection is
    currently Off. On an Entra-joined device, backs the recovery password up to Entra ID.
    This script never disables or decrypts. Turning BitLocker off is a separate, guarded
    action in the GUI (Panels > Disable BitLocker...), which backs up every key first.

.PARAMETER PreventAutomaticDeviceEncryption
    Sets HKLM\SYSTEM\CurrentControlSet\Control\BitLocker PreventDeviceEncryption=1, so
    Windows does not silently turn on device encryption at first Microsoft-account
    sign-in (relevant on 24H2) for a machine that is staying on local accounts.

.PARAMETER ProtectWorkTeams
    Adds an explicit guard in Remove-OemBloatware: a package identified as work/school
    Teams (AppX name MSTeams, or the classic "Teams Machine-Wide Installer*" Win32
    entry) is never removed or de-provisioned, regardless of what any bloat pattern
    matches - today's generic.appxPatterns entry ("MicrosoftTeams", no wildcards) is
    already an exact match that cannot catch MSTeams, so this is a second, independent
    layer rather than something that changes current behavior.

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
    [int]$LockTimeoutSec = 900,
    [string]$RemoveLocalAdmins = '',
    [switch]$CreateBreakGlassAdmin,
    [string]$BreakGlassAdminName = 'Gr3yBreakGlass',
    [switch]$EnableBitLocker,
    [switch]$PreventAutomaticDeviceEncryption,
    [switch]$ProtectWorkTeams
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

Write-Log "Gr3yLabs Support $(if ($Version) { "v$Version" } else { '(unversioned - launched directly, not via debloat.ps1)' })$(if ($Commit) { " ($Commit)" } else { '' }) | Worker PID: $PID | Profile: $env:USERNAME"
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

function Confirm-RegistryKey {
    # Makes sure a registry key exists WITHOUT touching it when it already does. New-Item -Force on an
    # EXISTING key EMPTIES it - every value and subkey (verified on Windows PowerShell 5.1 and 7) - so it must
    # never be used to "make sure a key is there": it wiped e.g. Policies\System (UAC settings), Session
    # Manager\Power and Explorer\Advanced preferences before a single value was written. Missing parents are
    # created first, and every key is created WITHOUT -Force: if another process makes the key between the
    # check and the creation, New-Item then fails ("a key in this path already exists") and leaves it alone,
    # instead of emptying it. Never throws; returns $true when the key exists afterwards, and keeps the first
    # failure's text in $script:LastRegistryKeyError for callers that report it. Call it as
    # "$null = Confirm-RegistryKey ..." (it returns a [bool]).
    param([string]$Path, [switch]$Nested)
    if (-not $Nested) { $script:LastRegistryKeyError = $null }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        if (-not $script:LastRegistryKeyError) { $script:LastRegistryKeyError = 'no registry path was given' }
        return $false
    }
    try {
        if (Test-Path -LiteralPath $Path) { return $true }
        $parent = Split-Path -Path $Path -Parent
        if ($parent -and $parent -ne $Path -and -not (Test-Path -LiteralPath $parent)) { [void](Confirm-RegistryKey -Path $parent -Nested) }
        New-Item -Path $Path -ErrorAction Stop | Out-Null
    } catch {
        if (-not $script:LastRegistryKeyError) { $script:LastRegistryKeyError = $_.Exception.Message }
    }
    try { return [bool](Test-Path -LiteralPath $Path) } catch { return $false }
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
            $null = Confirm-RegistryKey -Path $freqKey
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
# instead of two copies that could drift apart.
# Deliberately NOT included: DellInc.DellCommandUpdate and the Dell Command | Update program (driver/BIOS update tool - keep for IT),
# Dell display/audio drivers (not AppX packages), and the Lenovo Vantage / Commercial Vantage + System Interface Foundation
# packages (driver/BIOS updates and fan/thermal control - same reasoning as Dell Command Update).
# Included on purpose, whatever the organisation uses (delete the pattern from the JSON to keep one): the win32 pattern
# 'Dell SupportAssist*' and the service pattern '*SupportAssist*' ALSO match Dell SupportAssist for Business PCs and its
# SupportAssistAgent service - they are uninstalled, stopped and disabled like the consumer SupportAssist; Waves MaxxAudio* and
# MaxxAudioPro* (audio software; users report that removing it can cost headphone-jack / microphone detection), Dell Core Services
# (kept while other software depends on it) and every program named McAfee* (trial, paid or centrally managed).
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
# How long the whole run may spend waiting for a busy Windows Installer - about 10 minutes: it is checked before each wait, and a
# wait that has begun (up to 2 minutes) is not cut short. Counted by Invoke-OemUninstallLayer.
$OemBudget = @{ BusySeconds = 0; BusyLimitSec = 600 }
# The services this run has set to Disabled (service name -> { Name; DisplayName; Was; Stopped }): several products share a hint (the three
# SupportAssist programs), and the report of the one that stays must name the services an EARLIER product's turn disabled as well.
$OemRunDisabled = @{}
# Per-product knowledge for the removal: which services and processes keep a product busy (they are stopped before its
# uninstaller runs), the silent switches to use, a time limit, or "leave it while other software depends on it". Optional - a
# product without a hint is simply uninstalled.
$OemProductHints = @($bloatPatterns.generic.productHints | Where-Object { $_ })
foreach ($oemName in $script:selectedOems) {
    $section = $bloatPatterns.$oemName
    if (-not $section) { continue }
    $OemBloatAppxPatterns += $section.appxPatterns
    $Win32BloatPatterns += $section.win32Patterns
    $OemTaskFolders += $section.scheduledTaskFolders
    $OemTaskKeepPatterns += $section.scheduledTaskKeepPatterns
    $OemServicePatterns += $section.servicePatterns
    $OemProductHints += @($section.productHints | Where-Object { $_ })
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

function ConvertFrom-UninstallString {
    # Pure decision logic (what an Uninstall entry's command line would run) - no filesystem
    # or process side effects, so it's safe to unit test directly (Pester,
    # tests/ConvertFrom-UninstallString.Tests.ps1). Get-OemUninstallLayer builds on it; the
    # caller still does Test-Path and Start-ProcessLowPriority itself.
    param(
        [string]$UninstallString,
        [string]$QuietUninstallString
    )
    # QuietUninstallString, when the vendor provides one, is already the correct
    # fully-silent command line - trust it over any guessing below.
    $effectiveString = if ($QuietUninstallString) { $QuietUninstallString } else { $UninstallString }
    if (-not $effectiveString) {
        return [PSCustomObject]@{ Type = 'None'; FilePath = $null; ArgumentList = $null; ProductCode = $null; EffectiveString = $effectiveString }
    }

    if ($effectiveString -match 'msiexec') {
        # The caller's PSChildName (the registry key name) is a fallback for some Dell
        # entries where it's a product name, not the GUID - pull the real GUID out of the
        # uninstall string itself when present.
        $guidMatch = [regex]::Match($effectiveString, '\{[0-9A-Fa-f-]{36}\}')
        $productCode = if ($guidMatch.Success) { $guidMatch.Value } else { $null }
        $argumentList = if ($productCode) { "/x $productCode /qn /norestart" } else { $null }
        return [PSCustomObject]@{ Type = 'Msi'; FilePath = 'msiexec.exe'; ArgumentList = $argumentList; ProductCode = $productCode; EffectiveString = $effectiveString }
    }

    # Parse "path" and any trailing args separately - a naive (-replace '"','') -split ' '
    # approach truncates any quoted path containing a space (e.g. "C:\Program Files\...")
    # to just the first word, so Test-Path always fails and no EXE uninstaller under
    # Program Files ever actually runs.
    $exe = $null
    $existingArgs = ''
    $ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $quotedMatch = [regex]::Match($effectiveString, '^"([^"]+)"\s*(.*)$')
    if ($quotedMatch.Success) {
        $exe = $quotedMatch.Groups[1].Value
        $existingArgs = $quotedMatch.Groups[2].Value
    } else {
        $bareMatch = [regex]::Match($effectiveString, '^(\S+?\.exe)\s*(.*)$', $ignoreCase)
        if ($bareMatch.Success) {
            $exe = $bareMatch.Groups[1].Value
            $existingArgs = $bareMatch.Groups[2].Value
        } else {
            # An UNQUOTED path that itself contains spaces - the way NSIS-based uninstallers such as Dell Pair and Dell Peripheral
            # Manager register themselves ("C:\Program Files\Dell\Dell Pair\Uninstall.exe /S"). The path ends at the first
            # .exe/.bat/.cmd/.com that is followed by white space or the end of the string; these used to be reported as "could not
            # resolve an uninstaller" and skipped.
            $spacedMatch = [regex]::Match($effectiveString, '^(?<path>.+?\.(?:exe|bat|cmd|com))(?:\s+(?<args>.*))?$', $ignoreCase)
            if ($spacedMatch.Success) {
                $exe = $spacedMatch.Groups['path'].Value
                $existingArgs = $spacedMatch.Groups['args'].Value
            }
        }
    }

    if (-not $exe) {
        return [PSCustomObject]@{ Type = 'Unparseable'; FilePath = $null; ArgumentList = $null; ProductCode = $null; EffectiveString = $effectiveString }
    }

    $silentArgs =
        if ($exe -match '(^|[\\/])unins\d*\.exe$') {   # (the file name is matched by pattern: no file system is asked about a registry string here)
            # Inno Setup's own uninstaller - this is its documented silent switch set.
            '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
        } elseif ($existingArgs) {
            # The vendor's own uninstall string already carries flags - trust them rather
            # than guessing over the top of a command that was tested to work.
            $existingArgs
        } else {
            # No args at all in the registry string - /S is the most common silent switch
            # across NSIS-based uninstallers, which covers most of the rest.
            '/S'
        }
    return [PSCustomObject]@{ Type = 'Exe'; FilePath = $exe; ArgumentList = $silentArgs; ProductCode = $null; EffectiveString = $effectiveString }
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

function Get-UninstallExitClass {
    # Pure decision logic (Pester: tests/OemRemoval.Tests.ps1): what an uninstaller's exit code means for the run. msiexec and WiX
    # Burn bundles report Win32 error codes; Burn often wraps them as an HRESULT (0x8007xxxx), which .NET shows as a negative Int32 -
    # the value is unwrapped to the plain Win32 code first. NSIS, Inno Setup and InstallShield have codes of their own, so a small
    # code from such an installer is only a hint: what decides whether a program is gone is the Apps list, never the code.
    # Class: Success, RebootRequired (it worked, a restart finishes it), NotInstalled (Windows Installer says there is nothing to remove),
    # Busy (another install is running - retry later), RebootFirst (a restart from an earlier installation is pending and the
    # installer took no action - a Burn bundle then exits 350 on every try until the PC restarts), NoSource (the cached installer
    # is missing - retrying cannot help), Blocked (a policy forbids it), Failed, TimedOut, NotStarted or Unknown (no exit code).
    param($ExitCode, [bool]$TimedOut = $false, [bool]$Started = $true)
    if (-not $Started) { return [PSCustomObject]@{ Class = 'NotStarted'; Code = $null; Text = 'the uninstaller could not be started' } }
    if ($TimedOut) { return [PSCustomObject]@{ Class = 'TimedOut'; Code = $null; Text = 'the uninstaller did not finish in time and was stopped' } }
    if ($null -eq $ExitCode) { return [PSCustomObject]@{ Class = 'Unknown'; Code = $null; Text = 'no exit code was reported' } }
    $unsigned = [int64]$ExitCode -band 4294967295
    # 0x8007xxxx is a Win32 error wrapped as an HRESULT (2147942400 = 0x80070000; 4294901760 = 0xFFFF0000).
    $win32 = if (($unsigned -band 4294901760) -eq 2147942400) { $unsigned -band 65535 } else { $unsigned }
    $texts = @{
        5    = 'access denied'
        350  = 'no action was taken: a restart from an earlier installation is pending'
        740  = 'elevation is required'
        1223 = 'the uninstall was cancelled'
        1260 = 'blocked by a group policy'
        1601 = 'the Windows Installer service could not be reached'
        1602 = 'the uninstall was cancelled'
        1603 = 'fatal error during the uninstall'
        1604 = 'suspended: a restart from an earlier installation is pending'
        1605 = 'this product is not installed'
        1608 = 'unknown property'
        1612 = 'the original install source is missing'
        1614 = 'the product is already uninstalled'
        1618 = 'another installation is already in progress'
        1619 = 'the installer package could not be opened'
        1620 = 'the installer package is invalid'
        1625 = 'blocked by a system policy'
        1631 = 'the Windows Installer service failed to start'
        1638 = 'another version of this product is installed'
        1639 = 'invalid command line'
        1641 = 'the installer started a restart'
        1643 = 'blocked by a system policy'
        1644 = 'blocked by a policy'
        1706 = 'the installation source is missing'
        3010 = 'a restart is required to finish'
        3011 = 'a restart is required to finish'
        3017 = 'a restart from an earlier installation is pending'
        3018 = 'a restart from an earlier installation is pending'
    }
    $code = [int64]$win32
    $class = switch ($code) {
        0 { 'Success' }
        1707 { 'Success' }
        3010 { 'RebootRequired' }
        3011 { 'RebootRequired' }
        1641 { 'RebootRequired' }
        1605 { 'NotInstalled' }
        1614 { 'NotInstalled' }
        1618 { 'Busy' }
        350 { 'RebootFirst' }
        1604 { 'RebootFirst' }
        3017 { 'RebootFirst' }
        3018 { 'RebootFirst' }
        1612 { 'NoSource' }
        1706 { 'NoSource' }
        1619 { 'NoSource' }
        1620 { 'NoSource' }
        1625 { 'Blocked' }
        1643 { 'Blocked' }
        1644 { 'Blocked' }
        1260 { 'Blocked' }
        default { 'Failed' }
    }
    $text = if ($code -eq 0) { 'success' } elseif ($code -eq 1707) { 'success' } elseif ($code -le 65535 -and $texts.ContainsKey([int]$code)) { $texts[[int]$code] } else { 'the uninstaller reported an error' }
    # How the code is written in logs: a Win32 code as a plain number (with the HRESULT it came wrapped in, which is the form Burn's own
    # log shows), anything bigger - COM, .NET and NT status codes - in hex, the form vendors and search engines use, not as a huge decimal.
    $display = if ($code -gt 65535) { '0x{0:X8}' -f $unsigned } elseif ($win32 -ne $unsigned) { '{0} (0x{1:X8})' -f $code, $unsigned } else { [string]$code }
    return [PSCustomObject]@{ Class = $class; Code = $code; Display = $display; Text = $text }
}

function Test-WindowsInstallerBusy {
    # True while another Windows Installer operation holds the machine-wide _MSIExecute mutex (msiexec then fails with 1618).
    # Only the SYNCHRONIZE right is asked for (what the other side of the mutex's ACL grants everybody); the default of
    # Mutex.TryOpenExisting would also ask for MODIFY and be refused.
    $mutex = $null
    try {
        try {
            $mutex = [System.Threading.Mutex]::OpenExisting('Global\_MSIExecute', [System.Security.AccessControl.MutexRights]::Synchronize)
        } catch [System.Threading.WaitHandleCannotBeOpenedException] {
            return $false
        }
        $acquired = $false
        try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if ($acquired) { try { $mutex.ReleaseMutex() } catch {} ; return $false }
        return $true
    } catch {
        # No rights to look: do not block on a guess; an actual collision comes back as 1618 and is retried.
        return $false
    } finally {
        if ($mutex) { $mutex.Dispose() }
    }
}

function Wait-WindowsInstallerIdle {
    # Counts its own waiting (instead of watching the clock) so that it is deterministic and testable.
    param([int]$TimeoutSec = 120)
    $announced = $false
    for ($waited = 0; ; $waited += 5) {
        if (-not (Test-WindowsInstallerBusy)) { return $true }
        if (-not $announced) { Write-Log 'Another Windows Installer operation is running - waiting for it to finish...'; $announced = $true }
        if ($waited -ge $TimeoutSec) { return $false }
        Start-Sleep -Seconds 5
    }
}

function Get-OemHangGuess {
    # Pure: the likely reason an uninstaller has not finished, for the warning that says it is being stopped. A Windows Installer
    # product (msiexec) has no window under /qn, so a dialog is not the likely reason for it; any other installer may be waiting on one.
    param([string]$FilePath)
    if ($FilePath -match '(^|[\\/])msiexec\.exe$') { return 'a Windows Installer product has no window under /qn: a stuck custom action, or a file in use?' }
    return 'probably a dialog nobody can answer: is the silent switch right?'
}

function Get-RunWarningCount {
    # The number of WARN/ERROR lines this run has written so far (the counter Write-Log keeps, which the finish banner reports).
    return [int]$script:errorCount
}

function Start-ProcessLowPriority {
    # Launches an uninstaller hidden at BelowNormal process priority so it yields to whatever else is using the machine (remote
    # session, foreground apps), and waits for it with a bound - a wrong silent flag can pop an interactive dialog on a hidden
    # process, which would otherwise block this step (and the whole run) forever. Returns what happened (Started, ExitCode,
    # TimedOut, Seconds, Error): the exit code used to be thrown away, which made a failed uninstall look exactly like a
    # successful one.
    param(
        [string]$FilePath,
        [string]$ArgumentList,
        [int]$TimeoutMs = 600000
    )
    $result = [PSCustomObject]@{ Started = $false; ExitCode = $null; TimedOut = $false; Seconds = 0; Error = $null }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = $null
    try {
        # Start-Process refuses an empty -ArgumentList, so it is only passed when there is one.
        $startArgs = @{ FilePath = $FilePath; PassThru = $true; WindowStyle = 'Hidden'; ErrorAction = 'Stop' }
        if ($ArgumentList) { $startArgs['ArgumentList'] = $ArgumentList }
        $proc = Start-Process @startArgs
    } catch {
        # (the message Start-Process gives for a missing file does not name the file)
        $result.Error = "$($_.Exception.Message) [$FilePath]"
        return $result
    }
    $result.Started = $true
    # Some builds of Windows PowerShell 5.1 are reported to lose the exit code of a Start-Process -PassThru object unless its handle
    # was read while the process was still running (not reproduced on 5.1.26100; reading it is harmless).
    try { $null = $proc.Handle } catch {}
    try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
    if ($proc.WaitForExit($TimeoutMs)) {
        $result.ExitCode = $proc.ExitCode
    } else {
        $result.TimedOut = $true
        Write-Log "Uninstaller '$FilePath' did not exit within $($TimeoutMs / 1000)s ($(Get-OemHangGuess -FilePath $FilePath)) - killing it." 'WARN'
        # /T: the whole tree - an installer's child (msiexec, a temp copy of itself) would otherwise keep running. When the process IS
        # msiexec (a Windows Installer product that has not finished after the limit - 10 minutes, with no window to wait on under
        # /qn), its client is stopped too; the work itself runs in the Windows Installer service, and what that service does with an
        # interrupted transaction is NOT known. Leaving it running would be worse - every other MSI of the run would sit behind it
        # until its 1618 retries ran out - so the product stays "NOT REMOVED" and its verbose log is kept.
        try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch {}
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    $result.Seconds = [int][Math]::Round($sw.Elapsed.TotalSeconds)
    return $result
}

function Test-IsWorkSchoolTeams {
    # AppX name MSTeams is the modern (23H2+) work/school client, inbox or installed by
    # Microsoft 365 Apps; "Teams Machine-Wide Installer*" is the classic per-machine MSI
    # stub the pre-2023 desktop client used. Neither is ever a legitimate removal target
    # for this tool - see improvement-plan.md's explicit "do not add MSTeams" rule.
    param([string]$AppxName, [string]$Win32DisplayName)
    if ($AppxName -and $AppxName -eq 'MSTeams') { return $true }
    if ($Win32DisplayName -and $Win32DisplayName -like 'Teams Machine-Wide Installer*') { return $true }
    return $false
}

function ConvertTo-BurnUninstallArguments {
    # Pure: the command line for a WiX Burn setup bundle (the "...\Package Cache\{GUID}\setup.exe /uninstall" kind that vendors
    # such as Dell register next to their MSI): always /uninstall /quiet /norestart, whatever else the vendor string carried
    # (a /passive would pop a window; /modify, /repair and /layout would override the /uninstall, because Burn obeys the LAST
    # action switch - a bundle whose Modify button is disabled registers '/modify' as its plain uninstall string), plus an
    # optional /log so that a failure can be diagnosed afterwards.
    param([string]$ExistingArguments, [string]$LogPath)
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($token in @($ExistingArguments -split '\s+' | Where-Object { $_ })) {
        if ($token -match '^[/-](uninstall|quiet|q|qn|passive|norestart|forcerestart|promptrestart|modify|repair|layout)$') { continue }
        $kept.Add($token)
    }
    $parts = @('/uninstall', '/quiet', '/norestart') + $kept.ToArray()
    if ($LogPath) { $parts += "/log `"$LogPath`"" }
    return ($parts -join ' ')
}

function Test-PathQuiet {
    # Test-Path for a string that came out of the registry. A character a path cannot hold (a quote, < > |) makes Test-Path write an
    # "Illegal characters in path" ERROR instead of answering "no", which fills the log with red text; such a string is answered with
    # $false here without asking the file system. Some questions THROW even with -ErrorAction SilentlyContinue (a folder on a network
    # server that is down), and they too are answered with $false. (Our own work-folder paths are tested with plain Test-Path.)
    param([string]$Path, [string]$PathType = 'Any')
    if (-not $Path) { return $false }
    if ($Path.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) { return $false }
    try { return [bool](Test-Path -LiteralPath $Path -PathType $PathType -ErrorAction SilentlyContinue) } catch { return $false }
}

function ConvertTo-OemFolderPath {
    # Pure: registry text -> a path worth asking the file system about. Registry values are not reliable: quoted, still carrying
    # %VARIABLES%, blank, "." or "C:" (which Test-Path reads as "the current directory", not as a program folder). Quotes and white
    # space are removed, %VARIABLES% expanded, "/" turned into "\", and only a ROOTED path (a drive letter and a separator, or a UNC
    # share) is returned; anything else gives ''.
    param([string]$Text)
    if (-not $Text) { return '' }
    $path = ([Environment]::ExpandEnvironmentVariables($Text.Trim().Trim('"').Trim())) -replace '/', '\'
    if ($path -notmatch '^(?:[A-Za-z]:\\|\\\\)') { return '' }
    return $path
}

function Get-OemUninstallerFolder {
    # Pure: the folder an uninstaller file sits in, cut off by hand from the normalised registry text; '' when it has no rooted folder
    # of its own (a bare program name, a file in a drive root).
    param([string]$UninstallerPath)
    $full = ConvertTo-OemFolderPath -Text $UninstallerPath
    if (-not $full) { return '' }
    $cut = $full.LastIndexOf('\')
    if ($cut -le 2) { return '' }
    return $full.Substring(0, $cut)
}

function Resolve-UninstallExecutable {
    # Finds, on disk, the file an Uninstall entry's command line really starts with. Registry strings are not reliable: an unquoted
    # path may contain spaces (even a folder called "x.exe y"), and a REG_SZ value may still carry %ProgramFiles%. Returns
    # { FilePath; Arguments } for the first reading that exists as a file (shortest path first), or $null when there is none.
    param([string]$CommandLine)
    if (-not $CommandLine) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    $quoted = [regex]::Match($expanded, '^"([^"]+)"\s*(.*)$')
    if ($quoted.Success) {
        if (Test-PathQuiet -Path $quoted.Groups[1].Value -PathType Leaf) {
            return [PSCustomObject]@{ FilePath = $quoted.Groups[1].Value; Arguments = $quoted.Groups[2].Value }
        }
        # Some vendors quote the WHOLE command - "C:\Program Files\Vendor\uninstall.exe /S" - so look inside the quotes as well.
        $expanded = ($quoted.Groups[1].Value + ' ' + $quoted.Groups[2].Value).Trim()
    }
    $ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    foreach ($end in [regex]::Matches($expanded, '\.(?:exe|bat|cmd|com)(?=\s|$)', $ignoreCase)) {
        $candidate = $expanded.Substring(0, $end.Index + $end.Length)
        if (Test-PathQuiet -Path $candidate -PathType Leaf) {
            return [PSCustomObject]@{ FilePath = $candidate; Arguments = $expanded.Substring($candidate.Length).Trim() }
        }
    }
    return $null
}

function ConvertTo-MsiUninstallArguments {
    # Pure: the msiexec command line that removes one MSI product quietly. A WiX Burn bundle passes IGNOREDEPENDENCIES=ALL itself when
    # it removes a chained MSI - but only AFTER its own check of what depends on the package; this tool makes no such check. The
    # flag is here for a known WiX mechanism: an MSI built with the WiX dependency extension whose bundle is registered as a
    # dependent asks "really remove it?", which a silent run answers with "skip" - exit 0 and NOTHING removed (not yet observed on
    # Dell's own MSIs). For an MSI without that check the property is simply unused. A product that other software shares (Dell Core
    # Services, which Dell Update installs and other Dell agents rely on) is removed WITHOUT it, so that the check keeps protecting
    # what depends on it.
    param([string]$ProductCode, [string]$LogPath, [bool]$IgnoreDependencies = $true)
    $dependencies = if ($IgnoreDependencies) { ' IGNOREDEPENDENCIES=ALL' } else { '' }
    return "/x $ProductCode$dependencies /qn /norestart" + $(if ($LogPath) { " /L*v `"$LogPath`"" } else { '' })
}

function Get-OemProductHint {
    # What bloat-patterns.json "productHints" knows about a product - every hint whose "match" wildcard fits its name, merged:
    # services and processes to stop before its uninstaller runs, the silent switches to use instead of the vendor's own (some
    # vendor strings open a wizard), a time limit, and whether the product is shared software whose dependents must be respected.
    # Always returns the object; its lists are empty when nothing matches.
    param([string]$ProductName)
    $services = New-Object System.Collections.Generic.List[string]
    $processes = New-Object System.Collections.Generic.List[string]
    $silentArgs = ''
    $timeoutSec = 0
    $respectDependencies = $false
    foreach ($hint in @($OemProductHints)) {
        if (-not $hint -or -not $hint.match -or $ProductName -notlike $hint.match) { continue }
        foreach ($s in @($hint.services)) { if ($s -and -not $services.Contains([string]$s)) { $services.Add([string]$s) } }
        foreach ($p in @($hint.processes)) { if ($p -and -not $processes.Contains([string]$p)) { $processes.Add([string]$p) } }
        if (-not $silentArgs -and $hint.silentArgs) { $silentArgs = [string]$hint.silentArgs }
        if (-not $timeoutSec -and $hint.timeoutSec) { $timeoutSec = [int]$hint.timeoutSec }
        if ($hint.respectDependencies -eq $true) { $respectDependencies = $true }
    }
    return [PSCustomObject]@{ Services = $services.ToArray(); Processes = $processes.ToArray(); SilentArgs = $silentArgs; TimeoutSec = $timeoutSec; RespectDependencies = $respectDependencies }
}

function Get-OemUninstallLayer {
    # Turns one registry Uninstall entry into the command that removes that layer of a product, or a layer of Kind
    # 'Unparseable'/'None' when the entry carries nothing runnable. Kind: Msi (a Windows Installer product), Bundle (WiX Burn
    # bundle, which also removes its own MSIs), Wrapper (an InstallShield-style setup that wraps an MSI and tends to ignore silent
    # flags) or Exe (any other uninstaller). -SilentArgs (from a product hint) replaces the arguments of an Exe/Wrapper layer. The
    # only side effect is a file-exists check on the command's executable.
    param($Entry, [string]$LogPath, [string]$SilentArgs, [bool]$IgnoreDependencies = $true)
    $decision = ConvertFrom-UninstallString -UninstallString $Entry.UninstallString -QuietUninstallString $Entry.QuietUninstallString
    $originalString = $decision.EffectiveString
    # When the file the parser named is not there, look for the one the command line really starts with and parse that instead.
    if ($originalString -and $decision.Type -in 'Exe', 'Unparseable') {
        $parsedFileExists = ($decision.Type -eq 'Exe') -and $decision.FilePath -and (Test-PathQuiet -Path $decision.FilePath)
        if (-not $parsedFileExists) {
            $found = Resolve-UninstallExecutable -CommandLine $originalString
            if ($found) { $decision = ConvertFrom-UninstallString -UninstallString ('"{0}" {1}' -f $found.FilePath, $found.Arguments) }
        }
    }
    $keyName = [string]$Entry.PSChildName
    $keyIsGuid = $keyName -match '^\{[0-9A-Fa-f-]{36}\}$'
    $layer = [PSCustomObject]@{ Kind = 'None'; FilePath = $null; ArgumentList = $null; ProductCode = $null; KeyName = $keyName; EffectiveString = $originalString }
    if ($decision.Type -eq 'Msi') {
        # PSChildName is the registry key name, which for some Dell entries is a product name, not the GUID - only a fallback
        # for an uninstall string that did not contain one.
        $code = if ($decision.ProductCode) { $decision.ProductCode } elseif ($keyIsGuid) { $keyName } else { $null }
        if (-not $code) { $layer.Kind = 'Unparseable'; return $layer }
        $layer.Kind = 'Msi'
        $layer.FilePath = 'msiexec.exe'
        $layer.ProductCode = $code
        $layer.ArgumentList = ConvertTo-MsiUninstallArguments -ProductCode $code -LogPath $LogPath -IgnoreDependencies $IgnoreDependencies
        return $layer
    }
    if ($decision.Type -eq 'None') {
        # An MSI-registered entry can lack an uninstall string; its key name is then the product code.
        if ($keyIsGuid -and $Entry.WindowsInstaller -eq 1) {
            $layer.Kind = 'Msi'
            $layer.FilePath = 'msiexec.exe'
            $layer.ProductCode = $keyName
            $layer.ArgumentList = ConvertTo-MsiUninstallArguments -ProductCode $keyName -LogPath $LogPath -IgnoreDependencies $IgnoreDependencies
        }
        return $layer
    }
    if ($decision.Type -eq 'Unparseable') { $layer.Kind = 'Unparseable'; return $layer }
    $layer.FilePath = $decision.FilePath
    # A command that starts with a bare program name (powershell.exe, rundll32.exe, cmd.exe) is found through PATH, which a file check
    # does not search: it is resolved to the real file here, so that it is neither run from (or judged against) the current directory
    # nor taken for a missing uninstaller. Only a program that lives in the Windows folder is accepted: a file in some other PATH
    # folder (which a user may be able to write to) is not run on the strength of a registry string - it stays unresolved, is
    # reported, and counts as "cannot be checked from here".
    if ($layer.FilePath -match '^[A-Za-z0-9_.-]+\.(?:exe|bat|cmd|com)$' -and $env:SystemRoot) {
        $application = @(Get-Command -Name $layer.FilePath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        # (compared as canonical paths: a PATH entry written "C:/WINDOWS/../Users/x/tools" is not in the Windows folder, and one written
        # with "/" is)
        $resolved = ''
        $windowsRoot = ''
        try {
            if ($application.Count -gt 0 -and $application[0].Source) { $resolved = [System.IO.Path]::GetFullPath([string]$application[0].Source) }
            $windowsRoot = [System.IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\') + '\'
        } catch { $resolved = '' }
        if ($resolved -and $windowsRoot -and $resolved.StartsWith($windowsRoot, [System.StringComparison]::OrdinalIgnoreCase)) { $layer.FilePath = $resolved }
    }
    $layer.ArgumentList = $decision.ArgumentList
    if ($decision.FilePath -match '[\\/]Package Cache[\\/]' -or $Entry.BundleCachePath -or $Entry.BundleProviderKey) {
        $layer.Kind = 'Bundle'
        $vendorArgs = if ($Entry.QuietUninstallString -or $Entry.UninstallString) { $decision.ArgumentList } else { '' }
        $layer.ArgumentList = ConvertTo-BurnUninstallArguments -ExistingArguments $vendorArgs -LogPath $LogPath
    } elseif ($decision.FilePath -match 'InstallShield Installation Information') {
        $layer.Kind = 'Wrapper'
    } else {
        $layer.Kind = 'Exe'
    }
    if ($SilentArgs -and $layer.Kind -in 'Exe', 'Wrapper') { $layer.ArgumentList = $SilentArgs }
    return $layer
}

function Group-OemProductEntries {
    # Pure: collapses the Uninstall entries matched by the bloat patterns into ONE record per product (its DisplayName), so that
    # a product the patterns match more than once - or that registers several installer layers (an MSI plus the bundle around
    # it) - is handled once, with all its layers together, instead of being attempted again and again. Product order = order
    # of first match (the order of the layers inside a product is Remove-OemWin32Product's business).
    param([object[]]$Entries, [string[]]$Patterns)
    $seen = @{}
    $byName = @{}
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($pattern in $Patterns) {
        foreach ($entry in @($Entries | Where-Object { $_.DisplayName -like $pattern })) {
            $id = if ($entry.PSPath) { [string]$entry.PSPath } else { ([string]$entry.DisplayName) + '|' + ([string]$entry.PSChildName) }
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            $key = ([string]$entry.DisplayName).Trim().ToLowerInvariant()
            if (-not $byName.ContainsKey($key)) {
                $product = [PSCustomObject]@{ Name = [string]$entry.DisplayName; Version = [string]$entry.DisplayVersion; Entries = (New-Object System.Collections.Generic.List[object]) }
                $byName[$key] = $product
                $out.Add($product)
            }
            $byName[$key].Entries.Add($entry)
        }
    }
    # Plain arrays out: in Windows PowerShell 5.1, @(<a generic List held in a property>) can throw "Argument types do not match".
    foreach ($product in $out) { $product.Entries = $product.Entries.ToArray() }
    return $out.ToArray()
}

function Get-MsiLogFailureSummary {
    # Reads a verbose Windows Installer log (msiexec /L*v) of a FAILED run and pulls out what names the cause: the custom action
    # that returned a failure, the "Error NNNN." message the installer printed, and the final status. Returns '' when the log is
    # missing or says nothing useful. Never throws.
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    try {
        $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
        $action = $null
        $actualCode = $null
        $errorLine = $null
        $status = $null
        foreach ($line in $lines) {
            $m = [regex]::Match($line, 'Action ended \d+:\d+:\d+: (?<name>[^.]+)\. Return value 3\.')
            if ($m.Success -and -not $action) { $action = $m.Groups['name'].Value }
            $m = [regex]::Match($line, 'CustomAction (?<name>\S+) returned actual error code (?<code>\d+)')
            if ($m.Success -and -not $actualCode) { $actualCode = "custom action $($m.Groups['name'].Value) returned $($m.Groups['code'].Value)" }
            $m = [regex]::Match($line, '(?:^|\s)(?<msg>Error \d{4}\..{0,160})')
            if ($m.Success -and -not $errorLine) { $errorLine = $m.Groups['msg'].Value.Trim() }
            $m = [regex]::Match($line, 'Removal success or error status: (?<s>\d+)')
            if ($m.Success) { $status = $m.Groups['s'].Value }
        }
        if ($action) { $parts.Add("failed in action '$action'") }
        if ($actualCode) { $parts.Add($actualCode) }
        if ($errorLine) { $parts.Add($errorLine) }
        if ($status -and $status -ne '0') { $parts.Add("final status $status") }
    } catch {
        return ''
    }
    $text = $parts -join '; '
    if ($text.Length -gt 320) { $text = $text.Substring(0, 320) + '...' }
    return $text
}

function Get-OemMsiEventSummary {
    # The Windows Installer's own account of a failed run, from the Application event log (source MsiInstaller): the last few
    # error/warning events since $Since, each cut to one line. Needs no verbose log. Returns an array of strings (possibly
    # empty); never throws.
    param([datetime]$Since)
    $out = New-Object System.Collections.Generic.List[string]
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; StartTime = $Since; Level = 2, 3 } -MaxEvents 6 -ErrorAction Stop)
        foreach ($e in $events) {
            $msg = ([string]$e.Message -replace '\s+', ' ').Trim()
            if ($msg.Length -gt 240) { $msg = $msg.Substring(0, 240) + '...' }
            if ($msg) { $out.Add("event $($e.Id): $msg") }
        }
    } catch {
        # "No events were found" is an exception for Get-WinEvent, and an unreadable log is no reason to stop.
    }
    return $out.ToArray()
}

function Test-OemProductPresent {
    # True while any Uninstall entry (HKLM 64/32-bit, HKCU) still carries this product's name - the one check that does not
    # depend on what an uninstaller claims about itself.
    param([string]$Name)
    $wanted = ([string]$Name).Trim()
    $now = @(Get-UninstallEntries | Where-Object { ([string]$_.DisplayName).Trim() -eq $wanted })
    return ($now.Count -gt 0)
}

function Wait-OemProductGone {
    # Some installers hand the real work to a child process and exit at once, so the exit code alone proves nothing: poll the
    # Uninstall keys for a while before declaring the product still installed.
    param([string]$Name, [int]$TimeoutSec = 30)
    for ($waited = 0; ; $waited += 3) {
        if (-not (Test-OemProductPresent -Name $Name)) { return $true }
        if ($waited -ge $TimeoutSec) { return $false }
        Start-Sleep -Seconds 3
    }
}

function Stop-ServiceBounded {
    # Stop-Service has no deadline of its own in Windows PowerShell 5.1: a service stuck in StopPending makes it wait for ever (one
    # warning every two seconds), which would hold a hidden run for good. So the service is asked to stop WITHOUT waiting and the
    # wait is bounded here. Returns $true when the service has stopped (or is gone), $false when it has not - the caller carries on.
    param([string]$Name, [int]$TimeoutSec = 30)
    try {
        Stop-Service -Name $Name -Force -NoWait -ErrorAction Stop
    } catch {
        Write-Log "Could not stop service '$Name': $($_.Exception.Message)" 'WARN'
        return $false
    }
    for ($waited = 0; $waited -lt $TimeoutSec; $waited += 2) {
        $current = @(Get-Service -Name $Name -ErrorAction SilentlyContinue)
        if ($current.Count -eq 0 -or "$($current[0].Status)" -eq 'Stopped') { return $true }
        Start-Sleep -Seconds 2
    }
    Write-Log "Service '$Name' is still not stopped after $TimeoutSec s." 'WARN'
    return $false
}

function Test-OemProcessMayBeStopped {
    # The guard in front of every process kill. Never: this worker, a PowerShell host, msiexec, anything in the Windows folder, Dell
    # Command | Update (kept on purpose), a product's own uninstaller (-ProtectPaths) or the installer cache an uninstaller runs from -
    # killing those in the middle of a removal would only make it fail.
    param($Process, [string[]]$ProtectPaths = @())
    if ($Process.Id -eq $PID) { return $false }
    if ($Process.ProcessName -in 'powershell', 'pwsh', 'msiexec') { return $false }
    $path = [string]$Process.Path
    if ($path) {
        if ($env:windir -and $path.StartsWith($env:windir + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ($path -match '[\\/](CommandUpdate|Package Cache|InstallShield Installation Information)[\\/]') { return $false }
        foreach ($protected in $ProtectPaths) {
            if ($protected -and $path.Equals($protected, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
    }
    return $true
}

function Stop-OemProductActivity {
    # Stops what keeps a product's files and services busy BEFORE its uninstaller runs: the vendor's own agent services and
    # processes (named in bloat-patterns.json "productHints") and anything running from the product's install folder. A running
    # agent is the usual reason a silent uninstall fails or is undone a moment later. -ProtectPaths: the product's own uninstallers,
    # which must never be stopped by this. In a dry run NOTHING is changed: the function only says what it would do. Returns the
    # services it set to Disabled ({ Name; DisplayName; Was; Stopped }): when the product cannot be removed after all they stay that
    # way (and a service that could not be stopped keeps running), and the report says so.
    param([string]$ProductName, [string]$InstallLocation, [string[]]$ProtectPaths = @())
    $hint = Get-OemProductHint -ProductName $ProductName
    $disabled = New-Object System.Collections.Generic.List[object]
    foreach ($svcName in $hint.Services) {
        # A hint names a service by its name or its display name; wildcards are allowed.
        $found = @(Get-Service -Name $svcName -ErrorAction SilentlyContinue)
        if ($found.Count -eq 0) { $found = @(Get-Service -DisplayName $svcName -ErrorAction SilentlyContinue) }
        foreach ($svc in $found) {
            # Disabled first: some vendor services restart themselves (service recovery actions) a moment after being stopped, which
            # puts their files back in use in the middle of the uninstall. Phase 1b would disable these services anyway. What it was
            # before goes into the log, because nothing else records it.
            $record = $null
            if ("$($svc.StartType)" -ne 'Disabled') {
                if ($DryRun) {
                    Write-Log "DRYRUN: Would disable service '$($svc.DisplayName)' ($($svc.Name); it is set to $($svc.StartType) and is $($svc.Status)) so that it cannot restart during the uninstall of '$ProductName'." 'DRYRUN'
                } else {
                    Write-Log "Disabling service '$($svc.DisplayName)' ($($svc.Name); it was set to $($svc.StartType) and was $($svc.Status)) so that it cannot restart during the uninstall of '$ProductName'."
                    try {
                        Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
                        $record = [PSCustomObject]@{ Name = [string]$svc.Name; DisplayName = [string]$svc.DisplayName; Was = "$($svc.StartType)"; Stopped = ("$($svc.Status)" -eq 'Stopped') }
                        $disabled.Add($record)
                        if ($null -ne $OemRunDisabled) { $OemRunDisabled[[string]$svc.Name] = $record }
                    } catch { Write-Log "Could not disable service '$($svc.Name)': $($_.Exception.Message)" 'WARN' }
                }
            } elseif (-not $DryRun -and $null -ne $OemRunDisabled -and $OemRunDisabled.ContainsKey([string]$svc.Name)) {
                # (disabled earlier in this run, by another product that shares this hint: it is still this run's doing, and the report of
                # a product that stays must say so)
                $record = $OemRunDisabled[[string]$svc.Name]
                $disabled.Add($record)
            }
            if ($svc.Status -ne 'Stopped') {
                if ($DryRun) {
                    Write-Log "DRYRUN: Would stop service '$($svc.DisplayName)' ($($svc.Name)) before uninstalling '$ProductName'." 'DRYRUN'
                } else {
                    Write-Log "Stopping service '$($svc.DisplayName)' ($($svc.Name)) before uninstalling '$ProductName'."
                    # A service that will not stop does not hold the run: its hinted processes are ended next, below. (Whether it did stop
                    # is kept: the report must not say "stopped" about a service that is still running.)
                    $stopped = [bool](Stop-ServiceBounded -Name $svc.Name -TimeoutSec 30)
                    if ($record) { $record.Stopped = $stopped }
                }
            }
        }
    }
    foreach ($procName in $hint.Processes) {
        $running = @(Get-Process -Name $procName -ErrorAction SilentlyContinue | Where-Object { Test-OemProcessMayBeStopped -Process $_ -ProtectPaths $ProtectPaths })
        if ($running.Count -gt 0) {
            if ($DryRun) {
                Write-Log "DRYRUN: Would stop $($running.Count) running '$procName' process(es) before uninstalling '$ProductName'." 'DRYRUN'
            } else {
                Write-Log "Stopping $($running.Count) running '$procName' process(es) before uninstalling '$ProductName'."
                foreach ($p in $running) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { Write-Log "Could not stop '$procName' (PID $($p.Id)): $($_.Exception.Message)" 'WARN' } }
            }
        }
    }
    # Whatever runs from the product's own folder (when its Apps entry registers one) - but never from a folder that is shared: a
    # vendor root such as C:\Program Files\Dell also holds the Dell Command | Update this tool deliberately keeps. A product folder
    # is at least three levels deep (drive, Program Files, vendor, product).
    # (the registry text is read as Get-OemProgramEvidence reads it - quotes and %VARIABLES% resolved - so that both see the same folder;
    # a folder on a network share is never searched for processes)
    $location = ConvertTo-OemFolderPath -Text $InstallLocation
    $folderDepth = @($location.TrimEnd('\') -split '\\' | Where-Object { $_ }).Count
    if ($location -and $location -notlike '\\*' -and $folderDepth -ge 4 -and (Test-PathQuiet -Path $location)) {
        $root = $location.TrimEnd('\') + '\'
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-OemProcessMayBeStopped -Process $_ -ProtectPaths $ProtectPaths) })) {
            if ($DryRun) {
                Write-Log "DRYRUN: Would stop '$($p.ProcessName)' (PID $($p.Id)), running from the install folder of '$ProductName'." 'DRYRUN'
            } else {
                Write-Log "Stopping '$($p.ProcessName)' (PID $($p.Id)), running from the install folder of '$ProductName'."
                try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { Write-Log "Could not stop '$($p.ProcessName)': $($_.Exception.Message)" 'WARN' }
            }
        }
    }
    return $disabled.ToArray()
}

function Format-OemLayerCommand {
    # Pure: the command line of an uninstaller layer as the log shows it (an MSI goes through msiexec).
    param($Layer)
    if ($Layer.Kind -eq 'Msi') { return "msiexec $($Layer.ArgumentList)" }
    return "`"$($Layer.FilePath)`" $($Layer.ArgumentList)"
}

function Invoke-OemUninstallLayer {
    # Runs ONE uninstaller layer of a product and reports what came of it (never throws). Windows Installer serialises all MSI
    # work machine-wide, so msiexec is only started once it is idle, and a 1618 ("another installation is in progress") is
    # waited out and retried instead of being taken as the final answer.
    param($Layer, [string]$ProductName, [int]$TimeoutSec = 0)
    $isMsi = ($Layer.Kind -eq 'Msi')
    # A bundle runs its MSIs through the same machine-wide Windows Installer service, so it waits for it just like msiexec does.
    $usesInstallerService = ($Layer.Kind -in 'Msi', 'Bundle')
    # How long each kind may take before it is taken to be stuck: a Windows Installer product or a bundle of several can be large
    # (and an MSI has no window under /qn, so what holds it is a stuck custom action or a file in use); a wrapper or plain EXE that
    # has not finished after a few minutes is usually waiting for a click.
    if ($TimeoutSec -le 0) { $TimeoutSec = switch ($Layer.Kind) { 'Msi' { 600 } 'Bundle' { 600 } 'Wrapper' { 240 } default { 300 } } }
    $command = Format-OemLayerCommand -Layer $Layer
    $attempt = [PSCustomObject]@{ Layer = $Layer.Kind; Command = $command; Class = 'NotStarted'; ExitCode = $null; ExitDisplay = $null; Text = ''; Seconds = 0; LogPath = $Layer.LogPath; Why = '' }
    $startedAt = Get-Date
    $maxTries = 4
    for ($try = 1; $try -le $maxTries; $try++) {
        # Waiting for Windows Installer has a budget for the whole run ($OemBudget): a machine whose installer is busy for good (first-boot
        # updates, a stuck transaction) would otherwise cost every program four tries of two minutes each, twice.
        $busyBudgetSpent = ($OemBudget -and $OemBudget.BusySeconds -ge $OemBudget.BusyLimitSec)
        if ($usesInstallerService -and -not $busyBudgetSpent) {
            $waitWatch = [System.Diagnostics.Stopwatch]::StartNew()
            [void](Wait-WindowsInstallerIdle -TimeoutSec 120)
            if ($OemBudget) { $OemBudget.BusySeconds += $waitWatch.Elapsed.TotalSeconds }
        }
        # The exact command line goes into the log: it is the only way to see afterwards which switches were really passed.
        Write-Log "  Running the $($Layer.Kind) uninstaller for '$ProductName': $command"
        $run = Start-ProcessLowPriority -FilePath $Layer.FilePath -ArgumentList $Layer.ArgumentList -TimeoutMs ($TimeoutSec * 1000)
        $cls = Get-UninstallExitClass -ExitCode $run.ExitCode -TimedOut $run.TimedOut -Started $run.Started
        $attempt.Class = $cls.Class
        $attempt.ExitCode = if ($null -ne $cls.Code) { $cls.Code } else { $run.ExitCode }
        $attempt.ExitDisplay = if ($cls.Display) { $cls.Display } elseif ($null -ne $run.ExitCode) { [string]$run.ExitCode } else { $null }
        $attempt.Text = if ($run.Error) { $run.Error } else { $cls.Text }
        $attempt.Seconds = $run.Seconds
        # (a hang or a failed start has no exit code: the text alone says it)
        $outcome = if ($null -ne $attempt.ExitDisplay) { "exit $($attempt.ExitDisplay) ($($attempt.Text))" } else { [string]$attempt.Text }
        $level = if ($cls.Class -in 'Success', 'RebootRequired', 'NotInstalled') { 'INFO' } else { 'WARN' }
        Write-Log "  $($Layer.Kind) uninstaller for '$ProductName': $outcome, $($attempt.Seconds)s" $level
        if ($cls.Class -ne 'Busy') { break }
        if ($OemBudget -and $OemBudget.BusySeconds -ge $OemBudget.BusyLimitSec) {
            Write-Log "  Windows Installer has been busy for $([int]($OemBudget.BusySeconds / 60)) minutes of this run - not waiting for it any longer. Let Windows Update finish, restart the PC, then run the clean-up again." 'WARN'
            break
        }
        if ($try -lt $maxTries) {
            Write-Log '  Windows Installer was busy - waiting 20 s and trying again.'
            Start-Sleep -Seconds 20
            if ($OemBudget) { $OemBudget.BusySeconds += 20 }
        }
    }
    if ($isMsi -and $attempt.Class -in 'Failed', 'NoSource', 'Blocked') {
        # The exit code alone says "1603"; the installer's own log and the Application event log say WHY.
        $why = Get-MsiLogFailureSummary -Path $Layer.LogPath
        if (-not $why) { $why = (@(Get-OemMsiEventSummary -Since $startedAt) | Select-Object -First 1) }
        if ($why) {
            $attempt.Why = [string]$why
            Write-Log "  Windows Installer says: $why" 'WARN'
        }
    }
    return $attempt
}

function Remove-StaleUninstallEntry {
    # Clears an Uninstall registry entry that can never be used again (its uninstaller is gone, or Windows Installer says the
    # product is not installed) so it stops showing up in Settings > Apps. The key is exported to a .reg file first, so it can
    # be restored; only keys directly under ...\Windows\CurrentVersion\Uninstall are ever touched. -Reason goes into the log line.
    param([string]$PsPath, [string]$ProductName, [string]$Reason = 'its uninstaller no longer exists')
    $regPath = $PsPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
    if ($regPath -notmatch '^HKEY_(LOCAL_MACHINE|CURRENT_USER)\\.+\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\[^\\]+$') {
        Write-Log "Not touching '$regPath': not a direct Uninstall entry." 'WARN'
        return $false
    }
    $safeName = (($ProductName -replace '[^A-Za-z0-9._-]', '_').Trim('_'))
    if (-not $safeName) { $safeName = 'entry' }
    # The key's own name is in the file name, and an existing file is never reused: one product can have several entries cleared in
    # the same second, and each one's backup must survive. (The removed-uninstall-entry_ prefix is what the 30-day clean-up of the
    # work folder keeps.)
    $keyPart = ((($regPath -split '\\')[-1]) -replace '[^A-Za-z0-9._-]', '_').Trim('_')
    if ($keyPart.Length -gt 40) { $keyPart = $keyPart.Substring(0, 40) }
    if (-not $keyPart) { $keyPart = 'key' }
    $backupBase = "removed-uninstall-entry_{0}_{1}_{2}" -f $safeName, $keyPart, (Get-Date -Format 'yyyyMMdd_HHmmss')
    $backup = Join-Path $workDir ($backupBase + '.reg')
    for ($copy = 2; (Test-Path -LiteralPath $backup); $copy++) { $backup = Join-Path $workDir ("{0}_{1}.reg" -f $backupBase, $copy) }
    # (a failing reg.exe writes to stderr, and under $ErrorActionPreference = 'Stop' - the caller's, a test host's, a CI step's - Windows
    # PowerShell 5.1 raises that as an exception instead of letting the exit code below speak: here it must never throw)
    $ErrorActionPreference = 'Continue'
    try { & reg.exe export $regPath $backup /y 2>&1 | Out-Null } catch { $null = $_ }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $backup)) {
        Write-Log "Could not back up the stale Uninstall entry of '$ProductName' (reg export failed) - leaving it alone." 'WARN'
        return $false
    }
    try {
        Remove-Item -LiteralPath $PsPath -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Log "Could not remove the stale Uninstall entry of '$ProductName': $($_.Exception.Message)" 'WARN'
        return $false
    }
    if (Test-Path -LiteralPath $PsPath) { return $false }
    Write-Log "Removed the stale Uninstall entry of '$ProductName' ($Reason); backup: $backup"
    return $true
}

function Remove-OemUninstallLogs {
    # The verbose Windows Installer logs are only worth keeping for a product that could not be removed.
    param($Layers)
    foreach ($layer in $Layers) {
        if ($layer.LogPath -and (Test-Path -LiteralPath $layer.LogPath)) { Remove-Item -LiteralPath $layer.LogPath -Force -ErrorAction SilentlyContinue }
    }
}

function Get-OemProgramEvidence {
    # Reasons to believe a program whose uninstaller cannot be run - or whose installer says it is "not installed" - is STILL INSTALLED:
    # the install folder its entry registers (if it holds something), the folder its uninstaller used to sit in, the file its Apps icon
    # points at (a program file, not a Windows one), a service its product hint names; a location that cannot be checked from here
    # counts as well. An empty answer means nothing was found - the only case in which the Apps entry may be cleared as a leftover.
    # "I could not find it" is not evidence that it is gone.
    param($Layer, $Hint)
    $reasons = New-Object System.Collections.Generic.List[string]
    # (registry text is read as a rooted path: quotes and %VARIABLES% resolved, anything else - ".", "C:", a bare name - is not a folder)
    $location = ConvertTo-OemFolderPath -Text $Layer.InstallLocation
    $uninstallerFolder = Get-OemUninstallerFolder -UninstallerPath $Layer.FilePath
    if ($location -and (Test-OemFolderHasContent -Path $location)) {
        $reasons.Add("the program's folder still exists ($location)")
    } elseif (Test-OemProgramFolderPresent -UninstallerPath $Layer.FilePath) {
        $reasons.Add("the program's folder still exists ($uninstallerFolder)")
    }
    # A command that starts with a bare program name (powershell.exe, rundll32.exe) is found through PATH, which a file check does not
    # search: it cannot be judged here either.
    if ($Layer.Kind -ne 'Msi' -and $Layer.FilePath -and ([string]$Layer.FilePath).IndexOfAny([char[]]@('\', '/')) -lt 0) {
        $reasons.Add("its command starts with a bare program name ($($Layer.FilePath)) that cannot be checked from here")
    }
    $icon = Get-OemIconFilePath -DisplayIcon $Layer.DisplayIcon
    if ($icon -and (Test-PathQuiet -Path $icon -PathType Leaf)) { $reasons.Add("the file its Apps icon points at still exists ($icon)") }
    # A location on a network share, or on a drive letter this session cannot see (a drive mapped in the non-elevated session, a
    # volume that is locked or removed), cannot be judged from here: never proof that the program is gone.
    foreach ($place in @($location, $uninstallerFolder, $icon)) {
        if ($place -like '\\*') { $reasons.Add("its location is on a network share ($place) that cannot be checked from here"); break }
        if ($place -match '^[A-Za-z]:\\' -and -not (Test-PathQuiet -Path $place.Substring(0, 3) -PathType Container)) {
            $reasons.Add("its location is on a drive this session cannot see ($($place.Substring(0, 2))) and cannot be checked from here")
            break
        }
    }
    foreach ($svcName in @($Hint.Services)) {
        $found = @(Get-Service -Name $svcName -ErrorAction SilentlyContinue)
        if ($found.Count -eq 0) { $found = @(Get-Service -DisplayName $svcName -ErrorAction SilentlyContinue) }
        if ($found.Count -gt 0) { $reasons.Add("its service '$($found[0].Name)' still exists"); break }
    }
    return $reasons.ToArray()
}

function Get-OemIconFilePath {
    # Pure: the file an Apps entry's DisplayIcon points at, when that says something about the PROGRAM - a rooted path outside the
    # Windows folder ("shell32.dll,-5" or "cmd.exe" would be judged against the working directory and is a system file, and a
    # Windows Installer product keeps its icon cache under C:\Windows\Installer, which says nothing about the program itself).
    # Quotes, an icon index and %VARIABLES% are read; anything else gives ''.
    param([string]$DisplayIcon)
    if (-not $DisplayIcon) { return '' }
    $icon = ConvertTo-OemFolderPath -Text ($DisplayIcon -replace ',\s*-?\d+\s*$', '')
    if (-not $icon) { return '' }
    $windowsRoot = if ($env:SystemRoot) { $env:SystemRoot.TrimEnd('\') + '\' } else { '' }
    if ($windowsRoot -and $icon.StartsWith($windowsRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return '' }
    return $icon
}

function Get-OemProgramFootprints {
    # The places an Apps entry DECLARES that can be looked at to see whether its program is still installed: its install folder, the
    # folder its uninstaller sits in (unless that is an installer cache, which exists only for the uninstaller's sake), the icon file
    # (unless it is a Windows file) and the services its product hint names. An entry that declares none of them cannot be proven gone -
    # there is nothing to look at, so "nothing found" would mean nothing - and is never cleared on the strength of an installer's
    # "not installed" or a missing uninstaller alone.
    param($Layer, $Hint)
    $declared = New-Object System.Collections.Generic.List[string]
    if (ConvertTo-OemFolderPath -Text $Layer.InstallLocation) { $declared.Add('install folder') }
    $uninstallerFolder = Get-OemUninstallerFolder -UninstallerPath $Layer.FilePath
    if ($uninstallerFolder -and $uninstallerFolder -notmatch '[\\/](Package Cache|InstallShield Installation Information)([\\/]|$)') { $declared.Add('uninstaller folder') }
    if (Get-OemIconFilePath -DisplayIcon $Layer.DisplayIcon) { $declared.Add('icon file') }
    if (@($Hint.Services | Where-Object { $_ }).Count -gt 0) { $declared.Add('service') }
    return $declared.ToArray()
}

function Format-OemNothingToCheck {
    # Pure: the sentence for an Apps entry that registers nothing that could show whether its program is still installed - it is kept,
    # and the technician is told how to take it away by hand if it is the dead leftover it looks like.
    param([string[]]$PsPaths = @())
    $keys = @($PsPaths | Where-Object { $_ } | ForEach-Object { ([string]$_) -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' })
    $where = if ($keys.Count -gt 0) { " (registry key: $($keys -join '; '))" } else { '' }
    return "its Apps entry registers nothing that could show whether the program is still installed (no install folder, icon file or service to look at); it probably is a dead leftover - if so, delete the key by hand (export it first)$where, and it is left alone"
}

function Test-OemProgramFolderPresent {
    # True when the folder an uninstaller used to sit in still holds something and is a PROGRAM folder - not an installer cache such as
    # ...\Package Cache\{GUID} or ...\InstallShield Installation Information\{GUID}, which only exist for the uninstaller's sake. A
    # registry entry whose uninstaller file is gone but whose program folder is still full is a program that is still installed.
    param([string]$UninstallerPath)
    $dir = Get-OemUninstallerFolder -UninstallerPath $UninstallerPath
    if (-not $dir) { return $false }
    if ($dir -match '[\\/](Package Cache|InstallShield Installation Information)([\\/]|$)') { return $false }
    if (-not (Test-PathQuiet -Path $dir -PathType Container)) { return $false }
    return (Test-OemFolderHasContent -Path $dir)
}

function Test-OemFolderHasContent {
    # True when the path exists and, if it is a folder, holds at least one item. An EMPTY folder (the install folder an uninstaller left
    # behind) is not a program that is still installed; a folder with anything in it, or a file, is treated as one.
    param([string]$Path)
    if (-not (Test-PathQuiet -Path $Path)) { return $false }
    if (-not (Test-PathQuiet -Path $Path -PathType Container)) { return $true }
    # (a folder that cannot be listed, or a path the provider rejects, is "nothing found", not an error in the log)
    try { return [bool](Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1) } catch { return $false }
}

function Remove-OemWin32Product {
    # Removes ONE Win32 product with everything the registry knows about it, and says plainly how it went: every layer's exit
    # code is logged, success is only believed when the Uninstall entry is really gone, the product's services and processes are
    # stopped before every pass (the first included) and a failed pass is followed by one more, and what could not be removed is
    # reported with the reason.
    # -SkipPsPaths: Uninstall entries whose layer already hit a wall in an earlier call (it hung, was refused, ...) and is not run
    # again. -EarlierAttempts: what an earlier look at this product already did - a restart it asked for and an uninstaller that
    # worked count here too (without them a program that an uninstaller really removed would be called "a leftover entry cleared").
    # Returns Status: Removed, RemovedRestartNeeded, StaleEntryCleared, DryRun or Failed (+ Detail, Attempts, WallPsPaths, ...).
    param($Product, [int]$Passes = 2, [string[]]$SkipPsPaths = @(), [object[]]$EarlierAttempts = @())
    $name = $Product.Name
    $result = [PSCustomObject]@{ Name = $name; Version = $Product.Version; Status = 'Failed'; Detail = ''; RestartNeeded = $false; Attempts = (New-Object System.Collections.Generic.List[object]); WallPsPaths = @(); DetailNotes = @(); Shared = $false; DisabledServices = @(); LogLayers = @() }
    $hint = Get-OemProductHint -ProductName $name
    # (set at once, not only on the last path: every way out of this function, the early returns included, reports it)
    $result.Shared = [bool]$hint.RespectDependencies
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $safeName = (($name -replace '[^A-Za-z0-9._-]', '_').Trim('_'))
    $layers = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($entry in @($Product.Entries)) {
        $n++
        $logPath = Join-Path $workDir ("uninstall_{0}_{1}_{2}.log" -f $safeName, $stamp, $n)
        $layer = Get-OemUninstallLayer -Entry $entry -LogPath $logPath -SilentArgs $hint.SilentArgs -IgnoreDependencies (-not $hint.RespectDependencies)
        $layer | Add-Member -NotePropertyName LogPath -NotePropertyValue $logPath -Force
        $layer | Add-Member -NotePropertyName PsPath -NotePropertyValue ([string]$entry.PSPath) -Force
        $layer | Add-Member -NotePropertyName InstallLocation -NotePropertyValue ([string]$entry.InstallLocation) -Force
        $layer | Add-Member -NotePropertyName DisplayIcon -NotePropertyValue ([string]$entry.DisplayIcon) -Force
        $layer | Add-Member -NotePropertyName Index -NotePropertyValue $n -Force
        $layers.Add($layer)
    }
    # A bundle removes the MSIs it carries, and an InstallShield wrapper is the suite uninstaller that removes the MSI it wraps (Dell's
    # own script runs Optimizer's wrapper and nothing else), so both go before the MSI; a plain EXE goes last - the usual one that
    # sits next to an MSI is an interactive front end (McAfee's), which would wait for a click when the MSI alone would have worked.
    $order = @{ Bundle = 0; Wrapper = 1; Msi = 2; Exe = 3 }
    $runnable = @($layers | Where-Object {
        ($_.Kind -eq 'Msi') -or ($order.ContainsKey($_.Kind) -and $_.FilePath -and (Test-PathQuiet -Path $_.FilePath))
    } | Sort-Object { $order[$_.Kind] }, Index)    # (Index: Sort-Object is not stable in Windows PowerShell 5.1, same-kind layers would come out in no particular order)
    $notRunnable = @($layers | Where-Object { $runnable -notcontains $_ })
    # (the verbose installer logs of these layers are deleted by Remove-OemBloatware, after its last look at the Apps list, for a program that is gone)
    $result.LogLayers = $layers.ToArray()
    if ($DryRun) {
        if ($runnable.Count -gt 0) {
            Write-Log "DRYRUN: Uninstalling: $name ($($runnable.Count) usable installer layer(s): $((@($runnable | ForEach-Object { $_.Kind })) -join ', '))" 'DRYRUN'
            # What a real run would do, step by step: the commands (so that the silent switches can be checked before anything runs),
            # then the services it would disable and the processes it would end first. Nothing is changed.
            foreach ($layer in $runnable) { Write-Log "DRYRUN:   would run the $($layer.Kind) uninstaller: $(Format-OemLayerCommand -Layer $layer)" 'DRYRUN' }
            $dryLocation = (@($layers | Where-Object { $_.InstallLocation } | Select-Object -First 1)).InstallLocation
            [void]@(Stop-OemProductActivity -ProductName $name -InstallLocation $dryLocation -ProtectPaths @($runnable | ForEach-Object { $_.FilePath }))
        } else {
            # Say what would really happen with an entry nothing can be run for (read-only checks): a proven leftover is cleared from
            # the Apps list - a .reg backup is saved first - and anything else is only reported.
            $unreadableDry = @($notRunnable | Where-Object { $_.Kind -in 'None', 'Unparseable' })
            $stillThereDry = @($notRunnable | ForEach-Object { Get-OemProgramEvidence -Layer $_ -Hint $hint })
            $declaredDry = @($notRunnable | ForEach-Object { Get-OemProgramFootprints -Layer $_ -Hint $hint })
            $fate = if ($unreadableDry.Count -gt 0 -or $stillThereDry.Count -gt 0 -or $declaredDry.Count -eq 0) { 'it would be reported as NOT REMOVED (its command cannot be read, the program still seems to be there, or the entry registers nothing that could be checked)' } else { 'its Apps entry would be cleared as a leftover (a .reg backup is saved first)' }
            Write-Log "DRYRUN: $name - no usable uninstaller; $fate" 'DRYRUN'
        }
        $result.Status = 'DryRun'
        return $result
    }
    # Already gone when its turn comes (an earlier program's uninstaller took it with it): nothing to do, and its services must not be
    # stopped and disabled for nothing.
    if (-not (Test-OemProductPresent -Name $name)) {
        Write-Log "'$name' is already gone - nothing to uninstall."
        $result.Status = 'Removed'
        return $result
    }
    # A second look at a program whose runnable layers all hit a wall in the first look has nothing to start: it is not announced, and
    # its services and processes are not stopped again for nothing. What is wrong with its other entries is still worked out below.
    if ($SkipPsPaths.Count -gt 0 -and $runnable.Count -gt 0 -and @($runnable | Where-Object { -not ($_.PsPath -and $SkipPsPaths -contains $_.PsPath) }).Count -eq 0) {
        $Passes = 0
    } else {
        Write-Log "Uninstalling: $name$(if ($Product.Version) { ' ' + $Product.Version }) ($($runnable.Count) usable installer layer(s): $((@($runnable | ForEach-Object { $_.Kind })) -join ', '))"
    }
    # What is wrong with the layers that cannot be run, for the report.
    $unrunnableNotes = New-Object System.Collections.Generic.List[string]
    foreach ($layer in $notRunnable) {
        if ($layer.Kind -in 'None', 'Unparseable') {
            $unrunnableNotes.Add($(if ($layer.EffectiveString) { "its uninstall command cannot be read ('$($layer.EffectiveString)')" } else { 'it has no uninstall command registered' }))
        } else {
            $unrunnableNotes.Add("its uninstaller file is missing ($($layer.FilePath))")
        }
    }
    if ($runnable.Count -eq 0) {
        # Nothing can be run. Only a leftover that is PROVEN gone may be cleared from the Apps list: its uninstaller file is missing, the
        # entry DECLARES something that can be looked at (its install folder, the folder the uninstaller sat in, an icon file, a service
        # its product hint names) AND nothing of that is found. Not finding something is not evidence that it is gone - and an entry
        # that declares nothing has nothing to find - so an entry whose command merely cannot be read, whose program seems to be still
        # installed, or that registers nothing to look at, is reported as it is and never deleted.
        $unreadable = @($notRunnable | Where-Object { $_.Kind -in 'None', 'Unparseable' })
        $evidence = New-Object System.Collections.Generic.List[string]
        $declared = New-Object System.Collections.Generic.List[string]
        foreach ($layer in $notRunnable) {
            foreach ($reason in @(Get-OemProgramEvidence -Layer $layer -Hint $hint)) { if (-not $evidence.Contains($reason)) { $evidence.Add($reason) } }
            foreach ($place in @(Get-OemProgramFootprints -Layer $layer -Hint $hint)) { $declared.Add($place) }
        }
        if ($unreadable.Count -gt 0 -or $evidence.Count -gt 0 -or $declared.Count -eq 0) {
            $why = ''
            if ($evidence.Count -gt 0) { $why = 'the program still seems to be installed: ' + ($evidence -join '; ') }
            elseif ($declared.Count -eq 0) { $why = Format-OemNothingToCheck -PsPaths @($notRunnable | ForEach-Object { $_.PsPath }) }
            $result.Detail = (@($unrunnableNotes) + @($why | Where-Object { $_ })) -join '; '
            # (the notes in the spelling of the main path, so that a second look which comes out here says each fact once, not twice)
            $result.DetailNotes = @(@($unrunnableNotes | ForEach-Object { "another entry of this program: $_" }) + @($why | Where-Object { $_ }))
            return $result
        }
        $cleared = $true
        foreach ($layer in $notRunnable) {
            if ($layer.PsPath) { if (-not (Remove-StaleUninstallEntry -PsPath $layer.PsPath -ProductName $name -Reason 'its uninstaller file is missing and nothing it registers (install folder, icon file, service) shows the program is still there')) { $cleared = $false } } else { $cleared = $false }
        }
        if ($cleared) {
            # (an uninstaller of an earlier look that really worked is the one who removed the program)
            $earlierWorked = @($EarlierAttempts | Where-Object { $_ -and $_.Class -in 'Success', 'RebootRequired' })
            $earlierRestart = @($EarlierAttempts | Where-Object { $_ -and $_.Class -eq 'RebootRequired' }).Count -gt 0
            $result.Status = if ($earlierWorked.Count -gt 0) { if ($earlierRestart) { 'RemovedRestartNeeded' } else { 'Removed' } } else { 'StaleEntryCleared' }
            return $result
        }
        $result.Detail = (@($unrunnableNotes) -join '; ') + '; the entry could not be cleared'
        $result.DetailNotes = @(@($unrunnableNotes | ForEach-Object { "another entry of this program: $_" }) + @('the entry could not be cleared'))
        return $result
    }

    $anyRestart = @($EarlierAttempts | Where-Object { $_ -and $_.Class -eq 'RebootRequired' }).Count -gt 0
    $installLocation = (@($layers | Where-Object { $_.InstallLocation } | Select-Object -First 1)).InstallLocation
    $doNotRepeat = @{}      # layers (by log path) that would do the same again: they hung, were refused, said "not installed" ...
    $deadLayers = @{}       # layers with nothing left to run: their uninstaller file is gone, or their own Apps entry is not listed any more
    $fileGone = @{}         # ... and of those, the ones whose uninstaller FILE is gone (an entry that is merely not listed may be registered again)
    $wallPsPaths = New-Object System.Collections.Generic.List[string]
    $disabledServices = New-Object System.Collections.Generic.List[object]    # services set to Disabled on the way; they stay so if the product stays
    $protectPaths = @($runnable | ForEach-Object { $_.FilePath })
    for ($pass = 1; $pass -le $Passes; $pass++) {
        if ($pass -ge 2) {
            if (-not (Test-OemProductPresent -Name $name)) { break }
            # Nothing left that is worth trying again (every layer hung, was refused, is gone or is waiting for a restart): do not say otherwise.
            # (judged against the registry as it is NOW: a layer whose own Apps entry or uninstaller file an earlier layer took away has
            # nothing left to run, and nothing is stopped or announced for it)
            $liveNow = @(Get-UninstallEntries | ForEach-Object { [string]$_.PSPath })
            $worthTrying = @($runnable | Where-Object {
                -not $doNotRepeat.ContainsKey($_.LogPath) -and -not $deadLayers.ContainsKey($_.LogPath) -and -not ($_.PsPath -and $SkipPsPaths -contains $_.PsPath) -and
                (-not $_.PsPath -or $liveNow -contains $_.PsPath) -and ($_.Kind -eq 'Msi' -or (Test-PathQuiet -Path $_.FilePath))
            })
            if ($worthTrying.Count -eq 0) { break }
            Write-Log "  '$name' is still installed - stopping its services and processes and trying once more."
        }
        foreach ($service in @(Stop-OemProductActivity -ProductName $name -InstallLocation $installLocation -ProtectPaths $protectPaths)) {
            if ($service -and @($disabledServices | Where-Object { $_.Name -eq $service.Name }).Count -eq 0) { $disabledServices.Add($service) }
        }
        foreach ($layer in $runnable) {
            if (-not (Test-OemProductPresent -Name $name)) { break }
            # A layer that hung, could not even start, was told to wait for a restart, has lost its cached installer, is blocked by a
            # policy or was told "not installed" would do exactly the same again - here, and in a second look at the product.
            if ($doNotRepeat.ContainsKey($layer.LogPath)) { continue }
            if ($layer.PsPath -and $SkipPsPaths -contains $layer.PsPath) { continue }
            # An earlier layer can take a later layer's uninstaller with it (an MSI removes the folder that held an EXE uninstaller),
            # and can unregister a later layer's own Apps entry: neither has anything left to run.
            if ($layer.Kind -ne 'Msi' -and -not (Test-PathQuiet -Path $layer.FilePath)) {
                if (-not $deadLayers.ContainsKey($layer.LogPath)) {
                    $deadLayers[$layer.LogPath] = $true
                    $fileGone[$layer.LogPath] = $true
                    Write-Log "  The $($layer.Kind) uninstaller of '$name' is gone ($($layer.FilePath)) - an earlier step removed it."
                }
                continue
            }
            if ($layer.PsPath) {
                $livePsPaths = @(Get-UninstallEntries | ForEach-Object { [string]$_.PSPath })
                if ($livePsPaths -notcontains $layer.PsPath) {
                    if (-not $deadLayers.ContainsKey($layer.LogPath)) {
                        $deadLayers[$layer.LogPath] = $true
                        Write-Log "  The $($layer.Kind) entry of '$name' is gone already - nothing left to run for it."
                    }
                    continue
                }
            }
            # A layer that is runnable again - its entry is listed again, its uninstaller file is back - is no longer "dead": what it has
            # said from now on is what counts, not what it looked like a moment ago.
            if ($deadLayers.ContainsKey($layer.LogPath)) { $deadLayers.Remove($layer.LogPath); $fileGone.Remove($layer.LogPath) }
            # (a product hint's time limit is for the product's own EXE / wrapper / bundle uninstallers; an MSI keeps its default)
            $attempt = Invoke-OemUninstallLayer -Layer $layer -ProductName $name -TimeoutSec $(if ($layer.Kind -eq 'Msi') { 0 } else { $hint.TimeoutSec })
            $result.Attempts.Add($attempt)
            if ($attempt.Class -in 'TimedOut', 'NotStarted', 'RebootFirst', 'NoSource', 'Blocked', 'NotInstalled') {
                $doNotRepeat[$layer.LogPath] = $true
                if ($layer.PsPath) { $wallPsPaths.Add($layer.PsPath) }
            }
            if ($attempt.Class -eq 'RebootRequired') { $anyRestart = $true }
            if ($attempt.Class -in 'Success', 'RebootRequired') {
                # Installers that hand the real work to a copy of themselves and exit at once (NSIS, InstallShield) need longer.
                $waitSec = if ($layer.Kind -in 'Exe', 'Wrapper') { 90 } else { 30 }
                [void](Wait-OemProductGone -Name $name -TimeoutSec $waitSec)
            }
        }
        if (-not (Test-OemProductPresent -Name $name)) { break }
    }
    $result.WallPsPaths = @($wallPsPaths | Select-Object -Unique)
    $result.RestartNeeded = $anyRestart
    $result.DisabledServices = $disabledServices.ToArray()

    if (-not (Test-OemProductPresent -Name $name)) {
        $result.Status = if ($anyRestart) { 'RemovedRestartNeeded' } else { 'Removed' }
        return $result
    }
    # Still registered. Entries that can never be of use again are cleared (backed up first) and the product is looked at once more:
    # an MSI or an InstallShield wrapper that says "not installed" is a dead registration; an uninstaller that an earlier step took
    # away is a leftover - provided nothing else says the program is still there.
    $deadCandidates = New-Object System.Collections.Generic.List[object]
    $keptNotes = New-Object System.Collections.Generic.List[string]
    foreach ($layer in $runnable) {
        if (-not $layer.PsPath) { continue }
        $layerLog = $layer.LogPath
        $saidNotInstalled = @($result.Attempts | Where-Object { $_.LogPath -eq $layerLog -and $_.Class -eq 'NotInstalled' }).Count -gt 0
        if ($layer.Kind -in 'Msi', 'Wrapper' -and $saidNotInstalled) {
            # "Not installed" (1605/1614) is only proof that the REGISTRATION is dead - Windows Installer can answer it for a program that
            # is still on the disk (a damaged installer registration, a per-user install of another account). The entry is cleared only
            # when nothing else shows the program is still there; otherwise it stays, and the report says why.
            # ... and not even then when the entry registers nothing that could be looked at: "nothing found" would then mean nothing.
            $stillThere = @(Get-OemProgramEvidence -Layer $layer -Hint $hint)
            $declaredPlaces = @(Get-OemProgramFootprints -Layer $layer -Hint $hint)
            if ($stillThere.Count -eq 0 -and $declaredPlaces.Count -gt 0) {
                $deadCandidates.Add([PSCustomObject]@{ Layer = $layer; Reason = 'the installer says the product is not installed and nothing it registers (install folder, icon file, service) shows it is still there' })
            } elseif ($stillThere.Count -gt 0) {
                $keptNotes.Add("the $($layer.Kind) uninstaller says the product is not installed, yet the program still seems to be installed: " + ($stillThere -join '; ') + ' (its Apps entry is left alone)')
            } else {
                $keptNotes.Add("the $($layer.Kind) uninstaller says the product is not installed, but " + (Format-OemNothingToCheck -PsPaths @($layer.PsPath)))
            }
        } elseif ($fileGone.ContainsKey($layer.LogPath)) {
            # (only a layer whose uninstaller FILE is gone: one whose entry was merely not listed for a moment is a live entry if it is back)
            $stillThereGone = @(Get-OemProgramEvidence -Layer $layer -Hint $hint)
            $declaredGone = @(Get-OemProgramFootprints -Layer $layer -Hint $hint)
            if ($stillThereGone.Count -eq 0 -and $declaredGone.Count -gt 0) {
                $deadCandidates.Add([PSCustomObject]@{ Layer = $layer; RequireFileGone = $true; Reason = 'its uninstaller file was removed by an earlier step and nothing it registers (install folder, icon file, service) shows the program is still there' })
            } elseif ($stillThereGone.Count -eq 0) {
                $keptNotes.Add("the $($layer.Kind) uninstaller file is gone, but " + (Format-OemNothingToCheck -PsPaths @($layer.PsPath)))
            }
        }
    }
    if ($deadCandidates.Count -gt 0) {
        $clearedAny = $false
        $livePsPaths = @(Get-UninstallEntries | ForEach-Object { [string]$_.PSPath })
        foreach ($candidate in $deadCandidates) {
            $layer = $candidate.Layer
            # The file is looked at once more right before the delete: a program that put it back (a repair, an update tool) is installed.
            if ($candidate.RequireFileGone -and (Test-PathQuiet -Path $layer.FilePath)) { continue }
            # (only an entry that is still listed is cleared; one that is gone already needs no backup and no delete)
            if (($livePsPaths -contains $layer.PsPath) -and (Remove-StaleUninstallEntry -PsPath $layer.PsPath -ProductName $name -Reason $candidate.Reason)) { $clearedAny = $true }
        }
        if ($clearedAny -and -not (Test-OemProductPresent -Name $name)) {
            # An uninstaller that really worked is the one who removed it; only a product nothing ran for is "a leftover entry cleared".
            $workedAttempts = @(@($EarlierAttempts) + @($result.Attempts | Where-Object { $_ }) | Where-Object { $_ -and $_.Class -in 'Success', 'RebootRequired' })
            $result.Status = if ($workedAttempts.Count -gt 0) { if ($anyRestart) { 'RemovedRestartNeeded' } else { 'Removed' } } else { 'StaleEntryCleared' }
            return $result
        }
    }
    # The reason is kept in its parts as well: a second look at the product rebuilds it from everything attempted in both looks.
    $result.DetailNotes = @(@($unrunnableNotes | ForEach-Object { "another entry of this program: $_" }) + @($keptNotes))
    $result.Shared = [bool]$hint.RespectDependencies
    $result.Detail = Format-OemFailureDetail -AttemptLines @(Get-OemAttemptLines -Attempts $result.Attempts) -Notes $result.DetailNotes -Shared $result.Shared -DisabledServices $result.DisabledServices
    return $result
}

function Get-OemAttemptLines {
    # Pure (apart from looking for each installer log): what the attempts of one product said, one text per distinct outcome of a
    # layer - the same layer failing the same way again (in the second pass, or in the second look at the product) is said once, with
    # how often. The installer's own log of the LATEST such attempt is named (msiexec /L*v, or the Burn bundle's /log; it is kept
    # when the program could not be removed).
    param($Attempts)
    $texts = New-Object System.Collections.Generic.List[string]
    $counts = @{}
    $logs = @{}
    # (iterated directly: in Windows PowerShell 5.1, @(<a List held in an object's property>) throws "Argument types do not match")
    foreach ($a in $Attempts) {
        if (-not $a) { continue }
        $why = "$($a.Layer): " + $(if ($null -ne $a.ExitDisplay) { "exit $($a.ExitDisplay) ($($a.Text))" } elseif ($null -ne $a.ExitCode) { "exit $($a.ExitCode) ($($a.Text))" } else { [string]$a.Text })
        # An uninstaller that says "success" while the program is still listed is the case that used to go unnoticed.
        if ($a.Class -in 'Success', 'RebootRequired') { $why += ', yet the program is still listed in Apps' }
        if ($a.Class -in 'RebootFirst', 'RebootRequired') { $why += '; restart the PC, then run the clean-up again' }
        if ($a.Why) { $why += "; Windows Installer says: $($a.Why)" }
        if (-not $counts.ContainsKey($why)) { $texts.Add($why); $counts[$why] = 0; $logs[$why] = '' }
        $counts[$why] = 1 + [int]$counts[$why]
        if ($a.Layer -in 'Msi', 'Bundle' -and $a.Class -in 'Failed', 'NoSource', 'Blocked', 'RebootFirst', 'TimedOut', 'Success', 'RebootRequired' -and $a.LogPath -and (Test-Path -LiteralPath $a.LogPath)) { $logs[$why] = "; verbose log $($a.LogPath)" }
    }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($text in $texts) { $lines.Add($text + $logs[$text] + $(if ($counts[$text] -gt 1) { " (tried $($counts[$text]) times)" } else { '' })) }
    # (not "return ,$array": the caller's @() would then wrap the array a second time)
    return $lines.ToArray()
}

function Format-OemFailureDetail {
    # Pure: the whole "why it stayed" text of a product - what its attempts said, what is wrong with its other registry entries, which
    # of its services were set to Disabled on the way (they stay that way, and the technician has to know) and, for software that
    # other programs depend on, why it is left in place on purpose.
    param([string[]]$AttemptLines = @(), [string[]]$Notes = @(), [bool]$Shared = $false, [object[]]$DisabledServices = @())
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($AttemptLines | Where-Object { $_ })) { $parts.Add($line) }
    foreach ($note in @($Notes | Where-Object { $_ })) { $parts.Add($note) }
    $services = @($DisabledServices | Where-Object { $_ })
    if ($services.Count -gt 0 -and $parts.Count -gt 0) {
        # (a service that could not be stopped is said to be still running: "Stopped" is $false only when a stop was tried and failed)
        $named = (@($services | ForEach-Object { "'$($_.Name)' (was $($_.Was)$(if ($null -ne $_.Stopped -and -not $_.Stopped) { '; could not be stopped and is still running' }))" })) -join ', '
        $parts.Add("its service(s) $named were set to Disabled before the uninstall and stay Disabled; to undo: Set-Service -Name <service name> -StartupType <what it was>")
    }
    if ($Shared -and $parts.Count -gt 0) { $parts.Add('this program may be shared with other Dell software: its installer can refuse to remove it while other software depends on it (the exit code above says what happened)') }
    if ($parts.Count -gt 0) { return ($parts -join ' | ') }
    return 'no uninstaller could be started'
}

function Get-PendingRestartReasons {
    # What the registry says about a restart that is waiting to happen. Read-only; returns short texts (an empty array = none).
    # PendingFileRenameOperations is deliberately not read: almost every running Windows PC has some.
    param([string]$Hklm = 'HKLM:')
    $reasons = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath "$Hklm\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $reasons.Add('Windows servicing is waiting for a restart') }
    if (Test-Path -LiteralPath "$Hklm\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $reasons.Add('Windows Update is waiting for a restart') }
    # A WiX Burn bundle that needs a restart leaves a volatile "<bundle id>.RebootRequired" key next to its Uninstall entry.
    foreach ($root in @("$Hklm\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", "$Hklm\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall")) {
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like '*.RebootRequired' })) {
            $reasons.Add("an installer ($($key.PSChildName -replace '\.RebootRequired$', '')) is waiting for a restart")
        }
    }
    return $reasons.ToArray()
}

function Test-OemResultRetryable {
    # Pure: whether a second go at a product that failed could come out differently. It cannot when every attempt hit a wall that
    # repeating will not move: a hang, an uninstaller that would not start, a pending restart, a missing cached installer, a policy,
    # an installer that says the product is not installed.
    param($Result)
    # (@($null) is an array of one null in PowerShell, hence the filter.)
    $attempts = @($Result.Attempts | Where-Object { $_ })
    if ($attempts.Count -eq 0) { return $false }
    $wall = @($attempts | Where-Object { $_.Class -in 'TimedOut', 'NotStarted', 'RebootFirst', 'NoSource', 'Blocked', 'NotInstalled' })
    return ($wall.Count -lt $attempts.Count)
}

function Get-OemRemovalSummaryLines {
    # Pure: the closing report of Phase 1 as { Level; Message } lines. Anything that is still installed is a WARN with its reason,
    # so the run's warning count (and the window's banner) can no longer say "complete" over a machine where nothing changed.
    # The banner counts warning LINES, not programs: -WarningsRaised (the WARN lines this phase wrote before the report) lets the
    # report say so when every program is gone although warnings were raised on the way.
    param($AppxResult, $ProductResults, [int]$WarningsRaised = 0)
    $lines = New-Object System.Collections.Generic.List[object]
    $products = @($ProductResults)
    $removed = @($products | Where-Object { $_.Status -in 'Removed', 'RemovedRestartNeeded' })
    # A leftover entry cleared from the Apps list is not a removed program: it is counted on its own, so that "removed" only ever
    # means that an uninstaller ran and the program left.
    $cleared = @($products | Where-Object { $_.Status -eq 'StaleEntryCleared' })
    $failed = @($products | Where-Object { $_.Status -eq 'Failed' })
    $restart = @($products | Where-Object { $_.Status -eq 'RemovedRestartNeeded' })
    $appxUnverified = if ($AppxResult -and $AppxResult.Unverified) { ", $($AppxResult.Unverified) could not be checked" } else { '' }
    $appxText = if ($AppxResult) { "Store apps: $($AppxResult.Removed) removed, $($AppxResult.Failed) not removed$appxUnverified" } else { 'Store apps: none matched' }
    $clearedText = if ($cleared.Count -gt 0) { ", $($cleared.Count) leftover Apps entr$(if ($cleared.Count -eq 1) { 'y' } else { 'ies' }) cleared" } else { '' }
    $progText = if ($products.Count -eq 0) { 'programs: none matched' } else { "programs: $($removed.Count) removed$clearedText, $($failed.Count) NOT removed" }
    $lines.Add([PSCustomObject]@{ Level = 'INFO'; Message = "Phase 1 result - $appxText; $progText." })
    foreach ($p in $restart) { $lines.Add([PSCustomObject]@{ Level = 'INFO'; Message = "  '$($p.Name)' is removed; a restart finishes the clean-up." }) }
    foreach ($p in $failed) { $lines.Add([PSCustomObject]@{ Level = 'WARN'; Message = "  NOT REMOVED: '$($p.Name)'$(if ($p.Version) { ' ' + $p.Version }) - $($p.Detail)" }) }
    if ($AppxResult) {
        foreach ($f in @($AppxResult.FailedNames)) { $lines.Add([PSCustomObject]@{ Level = 'WARN'; Message = "  NOT REMOVED (Store app): $f" }) }
    }
    $restartFirst = @($failed | Where-Object { @($_.Attempts | Where-Object { $_.Class -eq 'RebootFirst' }).Count -gt 0 })
    if ($restartFirst.Count -gt 0) {
        $lines.Add([PSCustomObject]@{ Level = 'WARN'; Message = '  Some uninstallers answered that a restart must come first (a restart from an earlier installation is pending) and took no action: restart the PC and run the clean-up again.' })
    }
    # An uninstaller that finished and asked for a restart while the program is still listed: the restart finishes it.
    $restartFinishes = @($failed | Where-Object { @($_.Attempts | Where-Object { $_.Class -eq 'RebootRequired' }).Count -gt 0 })
    if ($restartFinishes.Count -gt 0) {
        $lines.Add([PSCustomObject]@{ Level = 'INFO'; Message = '  Some uninstallers finished and asked for a restart before the program leaves the Apps list: restart the PC, then check again.' })
    }
    if ($failed.Count -gt 0 -or ($AppxResult -and @($AppxResult.FailedNames).Count -gt 0)) {
        $lines.Add([PSCustomObject]@{ Level = 'INFO'; Message = '  What is listed as NOT REMOVED can usually be removed by hand in Settings > Apps (a program that other software depends on, such as Dell Core Services, may refuse; a Store app that is only provisioned is not listed there). Where an exit code or a log path exists, it is in that program''s NOT REMOVED line.' })
    }
    # Everything targeted is gone, yet the run raised warnings (a first attempt that failed and a later one made good, a restart
    # that was already pending): say so, because the finish banner counts warning lines, not programs.
    $appxFailedCount = if ($AppxResult) { [int]$AppxResult.Failed } else { 0 }
    $appxUnverifiedCount = if ($AppxResult) { [int]$AppxResult.Unverified } else { 0 }
    $targeted = $products.Count + $(if ($AppxResult) { [int]$AppxResult.Removed + $appxFailedCount + $appxUnverifiedCount } else { 0 })
    if ($targeted -gt 0 -and $failed.Count -eq 0 -and $appxFailedCount -eq 0 -and $appxUnverifiedCount -eq 0 -and $WarningsRaised -gt 0) {
        $lines.Add([PSCustomObject]@{ Level = 'INFO'; Message = "  Nothing that was targeted is left. The $WarningsRaised warning line(s) above are failed first attempts, refusals and notices; the finish banner counts warning lines, not programs." })
    } elseif ($targeted -eq 0 -and $WarningsRaised -gt 0) {
        # (nothing matched at all, yet the banner will count the warning lines - typically the notice of a restart that is pending)
        $lines.Add([PSCustomObject]@{ Level = 'INFO'; Message = "  Nothing matched the removal patterns. The $WarningsRaised warning line(s) above are notices (for example a restart that is already pending); the finish banner counts warning lines." })
    }
    return $lines.ToArray()
}

function Get-OemAppxIdentity {
    # Pure: what identifies a Store app in BOTH lists - the installed one (Get-AppxPackage PackageFullName, "Name_Version_Arch_ResourceId_
    # Publisher", e.g. DellInc.MyDell_3.1.12.0_x64__htrsf667h5kn2) and the provisioned one (Get-AppxProvisionedPackage PackageName, the staged
    # bundle: DellInc.MyDell_3.1.12.0_neutral_~_htrsf667h5kn2): its name and its publisher id, lower-cased. A package name holds no
    # underscore, so the string is split on it. Anything that does not have five parts is its own identity.
    param([string]$PackageName)
    $parts = ([string]$PackageName) -split '_'
    if ($parts.Count -ge 5) { return ($parts[0] + '|' + $parts[$parts.Count - 1]).ToLowerInvariant() }
    return ([string]$PackageName).ToLowerInvariant()
}

function Remove-OemAppxPackages {
    # Store (AppX/MSIX) apps: de-provisioned FIRST (so a new user profile does not get them back - DISM needs the package's staged
    # files, which Remove-AppxPackage -AllUsers deletes) and then removed for every existing user; both states are re-read
    # afterwards, and only a package that is really still there is reported. Returns { Removed; Failed; FailedNames }.
    $result = [PSCustomObject]@{ Removed = 0; Failed = 0; FailedNames = @(); Unverified = 0 }
    # Query once and filter in memory - Get-AppxProvisionedPackage -Online is a slow DISM-backed call, and running it once per
    # pattern (instead of once total) was the main source of the CPU/disk spike during this phase.
    $allInstalledAppx = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    $allProvisionedAppx = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)

    $removeTargets = New-Object System.Collections.Generic.List[object]
    $deprovisionTargets = New-Object System.Collections.Generic.List[object]
    $seenInstalled = @{}
    $seenProvisioned = @{}
    foreach ($pattern in $OemBloatAppxPatterns) {
        foreach ($pkg in @($allInstalledAppx | Where-Object { $_.Name -like $pattern })) {
            if ($ProtectWorkTeams -and (Test-IsWorkSchoolTeams -AppxName $pkg.Name)) {
                Write-Log "Skipping removal of '$($pkg.Name)' - identified as work/school Teams, protected by -ProtectWorkTeams." 'WARN'
                continue
            }
            if ($seenInstalled.ContainsKey($pkg.PackageFullName)) { continue }
            $seenInstalled[$pkg.PackageFullName] = $true
            $removeTargets.Add($pkg)
        }
        foreach ($pkg in @($allProvisionedAppx | Where-Object { $_.DisplayName -like $pattern })) {
            if ($ProtectWorkTeams -and (Test-IsWorkSchoolTeams -AppxName $pkg.DisplayName)) {
                Write-Log "Skipping de-provisioning of '$($pkg.DisplayName)' - identified as work/school Teams, protected by -ProtectWorkTeams." 'WARN'
                continue
            }
            if ($seenProvisioned.ContainsKey($pkg.PackageName)) { continue }
            $seenProvisioned[$pkg.PackageName] = $true
            $deprovisionTargets.Add($pkg)
        }
    }
    if ($DryRun) {
        foreach ($pkg in $deprovisionTargets) { Write-Log "DRYRUN: De-provisioning AppX package: $($pkg.DisplayName)" 'DRYRUN' }
        foreach ($pkg in $removeTargets) { Write-Log "DRYRUN: Removing AppX package: $($pkg.PackageFullName)" 'DRYRUN' }
        return $result
    }

    # De-provisioning goes through DISM's online image API, which is not thread-safe for concurrent in-process calls the way
    # Remove-AppxPackage is, so these run strictly one at a time.
    $deprovisionErrors = @{}
    if ($deprovisionTargets.Count -gt 0) { Write-Log "De-provisioning $($deprovisionTargets.Count) AppX package(s) (one at a time - DISM's online API isn't safe to call concurrently)..." }
    foreach ($pkg in $deprovisionTargets) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
        } catch {
            $deprovisionErrors[$pkg.PackageName] = $_.Exception.Message
        }
    }

    # AppX removals are cheap and independent of each other, so a few run at once in a bounded pool instead of one at a time -
    # real time drops without the machine-choking effect an unbounded parallel pass would cause. No -ErrorAction
    # SilentlyContinue in the action: inside a separate [powershell] runspace instance it would keep the error from ever
    # reaching that instance's own Streams.Error collection, which Invoke-ThrottledSteps reads to log a WARN afterward.
    $removeAction = { param($FullName) Remove-AppxPackage -Package $FullName -AllUsers }
    $removeSteps = New-Object System.Collections.Generic.List[hashtable]
    foreach ($pkg in $removeTargets) {
        # (Invoke-ThrottledSteps logs this text AFTER the step ran and before it reports any error, so it must not claim success:
        # what is really gone is read back below and reported by the summary.)
        $removeSteps.Add(@{ Description = "Removal requested for AppX package (all users): $($pkg.PackageFullName)"; Action = $removeAction; Args = @{ FullName = $pkg.PackageFullName } })
    }
    if ($removeSteps.Count -gt 0) { Write-Log "Removing $($removeSteps.Count) AppX package(s) (up to 3 at a time)..." }
    Invoke-ThrottledSteps -Steps $removeSteps -MaxConcurrency 3

    # Believe only what is there afterwards - and say so when it cannot be read: a list that failed to load must not pass for an empty one.
    $installedKnown = $true
    $provisionedKnown = $true
    $installedAfter = @()
    $provisionedAfter = @()
    $unreadable = New-Object System.Collections.Generic.List[string]
    try { $installedAfter = @(Get-AppxPackage -AllUsers -ErrorAction Stop) } catch { $installedKnown = $false; $unreadable.Add("the installed Store apps ($($_.Exception.Message))") }
    try { $provisionedAfter = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch { $provisionedKnown = $false; $unreadable.Add("the provisioned Store apps ($($_.Exception.Message))") }
    # One entry per APP, whether it was targeted as installed, as provisioned or both. The two lists do NOT spell a package the same way
    # (Get-AppxPackage: "Name_Version_x64__Publisher"; Get-AppxProvisionedPackage: the staged bundle, "Name_Version_neutral_~_Publisher"),
    # so an app is identified by its name and publisher id - otherwise it would be counted, and reported, once per spelling.
    $targetNames = New-Object System.Collections.Generic.List[string]
    $targetKeys = @{}
    foreach ($pkg in $removeTargets) {
        $appKey = Get-OemAppxIdentity -PackageName ([string]$pkg.PackageFullName)
        if (-not $targetKeys.ContainsKey($appKey)) { $targetKeys[$appKey] = $true; $targetNames.Add([string]$pkg.PackageFullName) }
    }
    foreach ($pkg in $deprovisionTargets) {
        $appKey = Get-OemAppxIdentity -PackageName ([string]$pkg.PackageName)
        if (-not $targetKeys.ContainsKey($appKey)) { $targetKeys[$appKey] = $true; $targetNames.Add([string]$pkg.PackageName) }
    }
    $failedNames = New-Object System.Collections.Generic.List[string]
    $unverified = 0
    foreach ($targetName in $targetNames) {
        $targetKey = Get-OemAppxIdentity -PackageName $targetName
        # (what is LEFT is named, not the spelling that was targeted: the installed package may be gone while its staged bundle stays)
        $leftInstalled = @($installedAfter | Where-Object { (Get-OemAppxIdentity -PackageName ([string]$_.PackageFullName)) -eq $targetKey } | ForEach-Object { [string]$_.PackageFullName })
        $leftProvisioned = @($provisionedAfter | Where-Object { (Get-OemAppxIdentity -PackageName ([string]$_.PackageName)) -eq $targetKey } | ForEach-Object { [string]$_.PackageName })
        if ($leftInstalled.Count -gt 0 -or $leftProvisioned.Count -gt 0) {
            $failedNames.Add((@($leftInstalled) + @($leftProvisioned) | Select-Object -Unique) -join ' + ')
        } elseif (-not $installedKnown -or -not $provisionedKnown) {
            $unverified++
        } else {
            $result.Removed++
        }
    }
    foreach ($pkg in $deprovisionTargets) {
        $stillProvisioned = @($provisionedAfter | Where-Object { $_.PackageName -eq $pkg.PackageName }).Count -gt 0
        if ($stillProvisioned) {
            $why = if ($deprovisionErrors.ContainsKey($pkg.PackageName)) { $deprovisionErrors[$pkg.PackageName] } else { 'it is still listed after the de-provisioning pass' }
            Write-Log "Still provisioned after de-provisioning: $($pkg.DisplayName) - new user profiles may get it back ($why)." 'WARN'
        } elseif ($provisionedKnown) {
            Write-Log "De-provisioned: $($pkg.DisplayName)"
        }
    }
    if ($unreadable.Count -gt 0) {
        Write-Log "Could not read $($unreadable -join ' or ') after the removal, so $unverified Store app(s) could not be checked and are not counted as removed." 'WARN'
    }
    $result.Failed = $failedNames.Count
    $result.FailedNames = $failedNames.ToArray()
    $result.Unverified = $unverified
    return $result
}

function Remove-OemBloatware {
    Write-Log '--- Phase 1: Removing OEM (Dell/Lenovo) bloatware and McAfee software ---'
    $warningsAtStart = Get-RunWarningCount

    # An uninstaller started while a restart is pending may do nothing at all (a WiX Burn bundle exits 350, "no action was taken as a
    # system reboot is required"), so say so before the report below shows programs that are still there.
    $pendingRestart = @(Get-PendingRestartReasons)
    if ($pendingRestart.Count -gt 0) {
        Write-Log "A restart is pending on this PC ($($pendingRestart -join '; ')). An installer can refuse to run, or do nothing, until it has happened - if programs are listed as NOT REMOVED below, restart the PC and run the clean-up again." $(if ($DryRun) { 'INFO' } else { 'WARN' })
    }

    # --- Store apps (AppX): removed for all users and de-provisioned ---
    $appxResult = Remove-OemAppxPackages

    # --- Win32 programs, via their own registry uninstall entries ---
    # (Previously also tried winget first on every match, but the registry uninstall string always ran anyway - winget rarely
    # recognizes OEM-bundled software by name, so it was pure added latency for no extra removals.)
    # One record per product with all of its installer layers: a product that several patterns match, or that registers an
    # MSI plus the bundle around it, used to be attempted again and again with no word on the outcome. These stay serial -
    # Windows Installer serializes MSI operations internally regardless - and each uninstaller runs at BelowNormal priority with
    # a short pause between products so that disk/AV activity has a moment to settle.
    $products = @(Group-OemProductEntries -Entries @(Get-UninstallEntries) -Patterns $Win32BloatPatterns)
    $results = @{}
    $resultOrder = New-Object System.Collections.Generic.List[string]
    $finished = @('Removed', 'RemovedRestartNeeded', 'StaleEntryCleared', 'DryRun')
    # Vendors disagree on the order products must go in (Dell's own wiki and Dell's own script differ), and one product can hold
    # another in place; so after a pass in which something WAS removed, what is left gets one more try on a fresh look at the registry.
    for ($sweep = 1; $sweep -le 2; $sweep++) {
        $progress = $false
        foreach ($product in $products) {
            if ($ProtectWorkTeams -and (Test-IsWorkSchoolTeams -Win32DisplayName $product.Name)) {
                if ($sweep -eq 1) { Write-Log "Skipping uninstall of '$($product.Name)' - identified as work/school Teams, protected by -ProtectWorkTeams." 'WARN' }
                continue
            }
            $key = $product.Name.Trim().ToLowerInvariant()
            $before = $null
            if ($sweep -gt 1) {
                # Only what failed in a way a second go could change: not what is done, and not what hung, was refused or is waiting
                # for a restart (those would just hang, be refused or wait again).
                if (-not $results.ContainsKey($key) -or $results[$key].Status -in $finished) { continue }
                if (-not (Test-OemResultRetryable -Result $results[$key])) { continue }
                $before = $results[$key]
            }
            $skip = if ($before) { @($before.WallPsPaths) } else { @() }
            # Nothing left that a second look could run (every entry still listed belongs to a layer that already hit a wall): the first
            # look's result and its explanation stand, and nothing is stopped or announced for nothing.
            if ($before -and @($product.Entries | Where-Object { $skip -notcontains [string]$_.PSPath }).Count -eq 0) { continue }
            # (iterated into a plain array: in Windows PowerShell 5.1, @(<a List held in an object's property>) throws)
            $earlier = New-Object System.Collections.Generic.List[object]
            if ($before) { foreach ($a in $before.Attempts) { if ($a) { $earlier.Add($a) } } }
            $result = Remove-OemWin32Product -Product $product -Passes $(if ($sweep -eq 1) { 2 } else { 1 }) -SkipPsPaths $skip -EarlierAttempts $earlier.ToArray()
            if ($before) {
                # The second look adds to the first one's story, it does not replace it: what was attempted and what needs a restart.
                # (iterated directly: in Windows PowerShell 5.1, @(<a List held in an object's property>) throws "Argument types do not match")
                $merged = New-Object System.Collections.Generic.List[object]
                foreach ($a in $before.Attempts) { $merged.Add($a) }
                foreach ($a in $result.Attempts) { $merged.Add($a) }
                $result | Add-Member -NotePropertyName Attempts -NotePropertyValue $merged -Force
                $result | Add-Member -NotePropertyName WallPsPaths -NotePropertyValue @(@($before.WallPsPaths) + @($result.WallPsPaths) | Select-Object -Unique) -Force
                if ($before.RestartNeeded) {
                    $result | Add-Member -NotePropertyName RestartNeeded -NotePropertyValue $true -Force
                    if ($result.Status -eq 'Removed') { $result.Status = 'RemovedRestartNeeded' }
                }
                # (the services the first look disabled are already Disabled in the second, which therefore does not report them)
                $mergedServices = New-Object System.Collections.Generic.List[object]
                foreach ($s in @($before.DisabledServices)) { if ($s) { $mergedServices.Add($s) } }
                foreach ($s in @($result.DisabledServices)) { if ($s -and @($mergedServices | Where-Object { $_.Name -eq $s.Name }).Count -eq 0) { $mergedServices.Add($s) } }
                $result | Add-Member -NotePropertyName DisabledServices -NotePropertyValue $mergedServices.ToArray() -Force
                # (the notes of the first look - a layer that said "not installed" while the program is still there, an entry that could not
                # be run - belong to the report as well; the second look may skip those layers and say nothing about them)
                $mergedNotes = New-Object System.Collections.Generic.List[string]
                foreach ($note in @($before.DetailNotes)) { if ($note) { $mergedNotes.Add([string]$note) } }
                foreach ($note in @($result.DetailNotes)) { if ($note -and -not $mergedNotes.Contains([string]$note)) { $mergedNotes.Add([string]$note) } }
                $result | Add-Member -NotePropertyName DetailNotes -NotePropertyValue $mergedNotes.ToArray() -Force
                # (the installer logs of both looks are cleaned up together, once the program is known to be gone)
                $result | Add-Member -NotePropertyName LogLayers -NotePropertyValue @(@($before.LogLayers) + @($result.LogLayers) | Where-Object { $_ }) -Force
                # What it says about a product that stayed is rebuilt from everything attempted in BOTH looks (a program that got the
                # second look would otherwise be reported from that look alone, with the first one's attempts missing from the text).
                if ($result.Status -eq 'Failed') {
                    $result.Detail = Format-OemFailureDetail -AttemptLines @(Get-OemAttemptLines -Attempts $merged) -Notes @($result.DetailNotes) -Shared ([bool]$result.Shared) -DisabledServices @($result.DisabledServices)
                }
            }
            if (-not $results.ContainsKey($key)) { $resultOrder.Add($key) }
            $results[$key] = $result
            if ($result.Status -in $finished) { $progress = $true }
            if (-not $DryRun) { Start-Sleep -Milliseconds 400 }
        }
        if ($sweep -eq 1) {
            $retry = @($resultOrder | Where-Object { $results[$_].Status -eq 'Failed' -and (Test-OemResultRetryable -Result $results[$_]) })
            # An uninstaller that said "restart first" (a Burn bundle's own lock, or a restart that is pending on the whole PC) is not likely
            # to be the only one: another sweep would probably only hit the same wall.
            $restartWall = @($resultOrder | Where-Object { @($results[$_].Attempts | Where-Object { $_.Class -eq 'RebootFirst' }).Count -gt 0 }).Count -gt 0
            if ($DryRun -or -not $progress -or $retry.Count -eq 0 -or $restartWall) { break }
            $products = @(Group-OemProductEntries -Entries @(Get-UninstallEntries) -Patterns $Win32BloatPatterns)
            # (there is a second sweep only if some program has an entry that did not hit a wall; a program whose runnable layers all did
            # is passed over by the look itself: nothing is announced or stopped for it, and its first result stands)
            $again = @($products | Where-Object {
                $againKey = $_.Name.Trim().ToLowerInvariant()
                $results.ContainsKey($againKey) -and $retry -contains $againKey -and
                @($_.Entries | Where-Object { @($results[$againKey].WallPsPaths) -notcontains [string]$_.PSPath }).Count -gt 0
            })
            if ($again.Count -eq 0) { break }
            Write-Log 'Some programs are still installed although others were removed - taking a second look at them.'
        }
    }

    if (-not $DryRun) {
        # A last look: the report says what is on the PC NOW, not what each step believed when it ran. A program can be gone after all -
        # taken along by another program's uninstaller, or by an installer that finished after it had been given up on.
        if ($resultOrder.Count -gt 0) {
            $endKeys = @(Group-OemProductEntries -Entries @(Get-UninstallEntries) -Patterns $Win32BloatPatterns | ForEach-Object { $_.Name.Trim().ToLowerInvariant() })
            foreach ($key in $resultOrder) {
                if ($results[$key].Status -eq 'Failed' -and $endKeys -notcontains $key) {
                    $results[$key].Status = if ($results[$key].RestartNeeded) { 'RemovedRestartNeeded' } else { 'Removed' }
                    $results[$key].Detail = ''
                } elseif ($results[$key].Status -in 'Removed', 'RemovedRestartNeeded', 'StaleEntryCleared' -and $endKeys -contains $key) {
                    # ... and the other way round: a program that is listed in Apps AGAIN at the end (an update tool or a delivery
                    # service installed it back, or an installer finished late) is not a removed program.
                    $results[$key].Status = 'Failed'
                    # (what its uninstallers said stays in the report - the exit codes are the only diagnosis there is - and the cause is a
                    # possibility, not a fact: an update tool, a delivery service, a late installer, or another program with the same name)
                    $flipLines = @('it was removed, but it is listed in Apps again - possibly installed back by Dell Command | Update, a Dell delivery service or another installer') + @(Get-OemAttemptLines -Attempts $results[$key].Attempts)
                    $results[$key].Detail = Format-OemFailureDetail -AttemptLines $flipLines -DisabledServices @($results[$key].DisabledServices)
                }
            }
        }
        $productResults = @($resultOrder | ForEach-Object { $results[$_] })
        # The verbose installer logs are only worth keeping for a program that is NOT gone: they are deleted now, after the last look (a
        # program that turns out to be listed again keeps its logs - they are what its exit codes can be checked against).
        foreach ($finishedResult in @($productResults | Where-Object { $_.Status -in 'Removed', 'RemovedRestartNeeded', 'StaleEntryCleared' })) { Remove-OemUninstallLogs -Layers @($finishedResult.LogLayers) }
        foreach ($line in @(Get-OemRemovalSummaryLines -AppxResult $appxResult -ProductResults $productResults -WarningsRaised ((Get-RunWarningCount) - $warningsAtStart))) {
            Write-Log $line.Message $line.Level
        }
        # Dell Command | Update (kept on purpose) can fetch some of these programs again with its "Application" updates.
        $removedAny = @($productResults | Where-Object { $_.Status -in 'Removed', 'RemovedRestartNeeded' }).Count -gt 0
        if ($removedAny -and (@('C:\Program Files\Dell\CommandUpdate\dcu-cli.exe', 'C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe') | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0) {
            Write-Log "Dell Command | Update is installed and can download some of these programs again (for example, Dell's catalog for the Vostro 16 5630 lists the SupportAssist OS Recovery Plugin and Dell Update as 'Application' updates): in its settings, un-tick 'Application' under Update Type, or run dcu-cli.exe /configure -updateType=bios,firmware,driver (Dell's documented switch; whether its scheduled run honours it has not been tested)."
        }
    }
    if ($DryRun) {
        # (a dry run prints no result line and removes nothing, so there is nothing to refer to and no remnant to advise about)
        Write-Log 'OEM bloatware / McAfee removal pass finished (dry run: nothing was changed).'
    } else {
        Write-Log 'OEM bloatware / McAfee removal pass finished (the result line above says what is gone and what is not).'
        # (the keys of $resultOrder are the lower-cased product names)
        if (@($resultOrder | Where-Object { $_ -like 'mcafee*' }).Count -gt 0) {
            Write-Log 'McAfee software was part of this run: if remnants remain, download McAfee''s own removal tool from https://www.mcafee.com/en-us/consumer-support/mcpr.html and run it manually - it is designed to run interactively.'
        }
    }
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
    # its uninstaller didn't clean up its service registration. This is done whether or
    # not the program was removed: a program that could not be uninstalled stays installed
    # with its service stopped and Disabled. What each service was set to goes into the log.
    foreach ($pattern in $OemServicePatterns) {
        $services = Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $pattern -or $_.Name -like $pattern }
        foreach ($svc in $services) {
            # (Phase 1 may have stopped and disabled it already: nothing left to do, nothing to log)
            if ("$($svc.StartType)" -eq 'Disabled' -and "$($svc.Status)" -eq 'Stopped') { continue }
            Invoke-Step "Disabling service: $($svc.DisplayName) ($($svc.Name); currently set to $($svc.StartType), $($svc.Status))" {
                # (bounded: a plain Stop-Service waits for ever on a service stuck in StopPending)
                if ($svc.Status -ne 'Stopped') { [void](Stop-ServiceBounded -Name $svc.Name -TimeoutSec 30) }
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
                    $null = Confirm-RegistryKey -Path $entry.path
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
                    if (-not (Confirm-RegistryKey -Path $keyEntry.path)) { throw ("Could not create the registry key " + $keyEntry.path + ": " + $script:LastRegistryKeyError) }
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

            $null = Confirm-RegistryKey -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 0 -Type DWord -ErrorAction SilentlyContinue

            $null = Confirm-RegistryKey -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
            # EnableActivityFeed is deliberately left alone (owner-identified gap):
            # turning it off breaks clipboard history, which most people expect to keep
            # working. Blocking Publish/UploadUserActivities alone already stops
            # activity data leaving the machine, without losing that local functionality.
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
                $null = Confirm-RegistryKey -Path $entry.Path
                Set-ItemProperty -Path $entry.Path -Name $entry.Name -Value $entry.Value -Type DWord -ErrorAction SilentlyContinue
            }

            $null = Confirm-RegistryKey -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
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
            $null = Confirm-RegistryKey -Path $ciPolicyPath
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
        if (-not (Confirm-RegistryKey -Path $keyPath)) { throw ("Could not create the registry key " + $keyPath + ": " + $script:LastRegistryKeyError) }
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
                            $null = Confirm-RegistryKey -Path $entry.path
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
                                    $null = Confirm-RegistryKey -Path $defaultPath
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

# Each provider's own well-known public resolver addresses and DoH templates. DoH
# registration itself happens in Set-DnsPreset below, via Add-DnsClientDohServerAddress.
$script:dnsPresets = @{
    'Google'                             = @{ V4 = @('8.8.8.8', '8.8.4.4'); V6 = @('2001:4860:4860::8888', '2001:4860:4860::8844'); DohTemplate = 'https://dns.google/dns-query' }
    'Cloudflare'                         = @{ V4 = @('1.1.1.1', '1.0.0.1'); V6 = @('2606:4700:4700::1111', '2606:4700:4700::1001'); DohTemplate = 'https://cloudflare-dns.com/dns-query' }
    'Cloudflare_Malware'                 = @{ V4 = @('1.1.1.2', '1.0.0.2'); V6 = @('2606:4700:4700::1112', '2606:4700:4700::1002'); DohTemplate = 'https://security.cloudflare-dns.com/dns-query' }
    'Cloudflare_Malware_Adult'           = @{ V4 = @('1.1.1.3', '1.0.0.3'); V6 = @('2606:4700:4700::1113', '2606:4700:4700::1003'); DohTemplate = 'https://family.cloudflare-dns.com/dns-query' }
    'Open_DNS'                           = @{ V4 = @('208.67.222.222', '208.67.220.220'); V6 = @('2620:119:35::35', '2620:119:53::53'); DohTemplate = 'https://doh.opendns.com/dns-query' }
    'Quad9'                              = @{ V4 = @('9.9.9.9', '149.112.112.112'); V6 = @('2620:fe::fe', '2620:fe::9'); DohTemplate = 'https://dns.quad9.net/dns-query' }
    'AdGuard_Ads_Trackers'               = @{ V4 = @('94.140.14.14', '94.140.15.15'); V6 = @('2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff'); DohTemplate = 'https://dns.adguard-dns.com/dns-query' }
    'AdGuard_Ads_Trackers_Malware_Adult' = @{ V4 = @('94.140.14.15', '94.140.15.16'); V6 = @('2a10:50c0::bad1:ff', '2a10:50c0::bad2:ff'); DohTemplate = 'https://family.adguard-dns.com/dns-query' }
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

            # DoH registration is system-wide (Add-DnsClientDohServerAddress has no
            # -InterfaceIndex) so this runs once per preset, not once per adapter like the
            # IP address loop above. Add-DnsClientDohServerAddress only exists on
            # Windows 11+ - absent on Windows 10, where DNS is still set above, just not
            # upgraded to DoH.
            if ($script:dnsPresets.ContainsKey($Preset) -and $script:dnsPresets[$Preset].DohTemplate) {
                if (Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue) {
                    $p = $script:dnsPresets[$Preset]
                    foreach ($ip in ($p.V4 + $p.V6)) {
                        try {
                            Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $p.DohTemplate -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop | Out-Null
                            Write-Log "  Registered DoH for $ip -> $($p.DohTemplate)"
                        } catch {
                            Write-Log "  Could not register DoH for $ip (may already be registered): $($_.Exception.Message)" 'WARN'
                        }
                    }
                } else {
                    Write-Log 'Add-DnsClientDohServerAddress is not available on this OS (Windows 11+ only) - DNS servers were set, but DNS-over-HTTPS was not registered.' 'WARN'
                }
            }
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
            $null = Confirm-RegistryKey -Path $path
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
            $null = Confirm-RegistryKey -Path $policyPath
            Set-ItemProperty -Path $policyPath -Name 'SilentAccountConfig' -Value 1 -Type DWord -ErrorAction Stop
            Set-ItemProperty -Path $policyPath -Name 'KFMSilentOptIn' -Value $TenantId -Type String -ErrorAction Stop
            Set-ItemProperty -Path $policyPath -Name 'KFMSilentOptInWithNotification' -Value 1 -Type DWord -ErrorAction Stop
            Set-ItemProperty -Path $policyPath -Name 'KFMBlockOptOut' -Value 1 -Type DWord -ErrorAction Stop
            Set-ItemProperty -Path $policyPath -Name 'FilesOnDemandEnabled' -Value 1 -Type DWord -ErrorAction Stop
            # Exactly the chosen folders: a folder that is not chosen loses an opt-in left by an earlier run (the key
            # used to be emptied on every run, which did this by accident; only these three values are touched now).
            foreach ($folder in @(@('Desktop', $Desktop), @('Documents', $Documents), @('Pictures', $Pictures))) {
                $optInName = 'KFMSilentOptIn' + $folder[0]
                if ($folder[1]) { Set-ItemProperty -Path $policyPath -Name $optInName -Value 1 -Type DWord -ErrorAction Stop }
                else { Remove-ItemProperty -Path $policyPath -Name $optInName -ErrorAction SilentlyContinue }
            }
            Write-Log "OneDrive KFM configured for tenant $TenantId (Desktop=$Desktop, Documents=$Documents, Pictures=$Pictures). Takes effect the next time OneDrive starts and the user signs in."
        } catch {
            Write-Log "Could not configure OneDrive KFM: $($_.Exception.Message)" 'WARN'
        }
    }
}

function Get-LocalAdministratorsReport {
    # Read-only. Flags enough detail for a caller to decide what's safe to offer for
    # removal - never decides that itself. Shared by the GUI's in-process scan and
    # Remove-LocalAdministratorMembers' own re-check before acting.
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
        # A resolved principal's Name looks like "AzureAD\user@domain.com" or
        # "COMPUTERNAME\localaccount". An Entra ID role/group assignment that
        # Get-LocalGroupMember can't resolve to a friendly name falls back to the raw SID
        # string as Name itself (a known gap - see PowerShell/PowerShell#15585). Detecting
        # on the Name's shape, not the SID's numeric authority prefix: a normal signed-in
        # Entra USER's SID also lives under the same S-1-12-1 Azure AD authority, so
        # matching on the prefix would wrongly exclude real user accounts too (caught by
        # this function's own mocked test suite before this code ever ran for real).
        $isUnresolvedEntraRoleSid = [bool]($m.Name -match '^S-1-')
        $isBuiltInAdministrator = [bool]($sidValue -and ($sidValue -like '*-500'))
        $localUser = if ($sidValue -and $localUsers.ContainsKey($sidValue)) { $localUsers[$sidValue] } else { $null }
        $isEnabled = if ($localUser) { [bool]$localUser.Enabled } else { $true }

        $result.Add([PSCustomObject]@{
            Name             = $m.Name
            Sid              = $sidValue
            PrincipalSource  = "$($m.PrincipalSource)"
            ObjectClass      = "$($m.ObjectClass)"
            IsBuiltInAdministrator = $isBuiltInAdministrator
            IsUnresolvedEntraRoleSid = $isUnresolvedEntraRoleSid
            IsEnabled        = $isEnabled
            Removable        = (-not $isBuiltInAdministrator) -and (-not $isUnresolvedEntraRoleSid) -and ($m.ObjectClass -eq 'User')
        })
    }
    return [PSCustomObject]@{ Error = $null; Members = $result }
}

function Remove-LocalAdministratorMembers {
    param([string[]]$Names)
    Invoke-Step "Removing $($Names.Count) account(s) from the local Administrators group" {
        if (-not $Names -or $Names.Count -eq 0) { return }
        $report = Get-LocalAdministratorsReport
        if ($report.Error) {
            Write-Log "Could not enumerate local Administrators group: $($report.Error)" 'WARN'
            return
        }
        $enabledCount = @($report.Members | Where-Object { $_.IsEnabled }).Count
        foreach ($name in $Names) {
            $target = $report.Members | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if (-not $target) {
                Write-Log "'$name' is not currently a member of Administrators - skipping." 'WARN'
                continue
            }
            if (-not $target.Removable) {
                Write-Log "Skipping '$name' - not eligible for removal (built-in Administrator account or an unresolved Entra role SID)." 'WARN'
                continue
            }
            if ($target.IsEnabled -and ($enabledCount - 1) -lt 1) {
                Write-Log "Refusing to remove '$name' - this would leave zero enabled administrators on this machine." 'WARN'
                continue
            }
            try {
                Remove-LocalGroupMember -Group 'Administrators' -Member $name -ErrorAction Stop
                Write-Log "Removed '$name' from the local Administrators group."
                if ($target.IsEnabled) { $enabledCount-- }
            } catch {
                Write-Log "Could not remove '$name' from Administrators: $($_.Exception.Message)" 'WARN'
            }
        }
        # Same ProviderID filter as the telemetry tweak's MDM check (1.1/3.3) - every
        # subkey under Enrollments shows EnrollmentState=1 regardless of real management
        # state; 'MS DM Server' is Intune's own registered provider id.
        $enrollmentsKey = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
        $isIntuneEnrolled = (Test-Path $enrollmentsKey) -and [bool](Get-ChildItem -Path $enrollmentsKey -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
        } | Where-Object { $_.ProviderID -eq 'MS DM Server' })
        if ($isIntuneEnrolled) {
            Write-Log 'This machine is Intune-enrolled - an Entra ID Administrators role assignment or an Intune/Autopilot policy may re-add an account independently of this change.' 'WARN'
        }
    }
}

function Test-PasswordClasses {
    # True when the password has at least $Minimum of the four character classes (upper, lower, digit, other).
    param([string]$Password, [int]$Minimum = 3)
    $classes = 0
    foreach ($pattern in '[A-Z]', '[a-z]', '[0-9]', '[^A-Za-z0-9]') { if ($Password -cmatch $pattern) { $classes++ } }
    return ($classes -ge $Minimum)
}

function New-BreakGlassPassword {
    # 24 random characters from a mixed charset - comfortably over both the plan's 20+ char minimum and Windows LAPS'
    # own PasswordLength=20 policy. They come from the operating system's cryptographic generator, never Get-Random
    # (this is a credential): RandomNumberGenerator.Create().GetBytes works on Windows PowerShell 5.1 (.NET Framework,
    # the host the GUI always uses) AND on PowerShell 7 - the static ::Fill exists only on .NET Core, and this
    # function used to fail on 5.1 because of it. The charset has 64 characters, so "byte modulo 64" is unbiased
    # (256 is a multiple of 64). It is drawn again until it holds at least three of the four character classes, which
    # a local or domain complexity policy would otherwise refuse (about 1 draw in 1000 has only letters).
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#$%^&*'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $bytes = New-Object byte[] 24
            $rng.GetBytes($bytes)
            $password = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
            if (Test-PasswordClasses -Password $password) { return $password }
        }
        throw 'Could not generate a password that meets the complexity rules.'
    } finally {
        $rng.Dispose()
    }
}

function New-BreakGlassLocalAdmin {
    param([string]$AccountName = 'Gr3yBreakGlass')
    Invoke-Step "Creating break-glass local administrator account ($AccountName)" {
        try {
            $existing = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
            if ($existing) {
                Write-Log "Local account '$AccountName' already exists - leaving its password alone (delete the account first for a fresh one)." 'WARN'
            } else {
                $password = New-BreakGlassPassword
                $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
                New-LocalUser -Name $AccountName -Password $secure -PasswordNeverExpires -AccountNeverExpires -ErrorAction Stop | Out-Null
                Add-LocalGroupMember -Group 'Administrators' -Member $AccountName -ErrorAction Stop
                Write-Log "Created local administrator '$AccountName' with a random password (not logged here)."

                $dsregOutput = & dsregcmd /status 2>&1 | Out-String
                $isAzureAdJoined = $dsregOutput -match 'AzureAdJoined\s*:\s*YES'

                # Written immediately, in this same step, because a generated local-account
                # password cannot be read back from Windows later the way a BitLocker
                # recovery key can (Get-BitLockerKeyData re-reads live state at handoff
                # time; there is no equivalent re-read for a local account's password) -
                # same icacls ACL hardening as bitlocker-recovery.txt, same "never
                # Write-Log the secret itself" rule.
                $credLines = New-Object System.Collections.Generic.List[string]
                $credLines.Add("Break-glass local administrator for $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
                $credLines.Add('This file contains a credential - store or destroy it securely.')
                $credLines.Add('')
                $credLines.Add("Account: $AccountName")
                $credLines.Add("Password: $password")
                if ($isAzureAdJoined) {
                    $credLines.Add('')
                    $credLines.Add('This machine is Entra-joined - Windows LAPS is configured to manage and rotate this')
                    $credLines.Add('password going forward (see below). This initial password should still be treated as')
                    $credLines.Add('sensitive until LAPS has rotated it at least once.')
                } else {
                    $credLines.Add('')
                    $credLines.Add('This machine is NOT Entra-joined, so Windows LAPS cannot back this password up or')
                    $credLines.Add('rotate it. This file is the only copy - there is no central recovery.')
                }
                $credPath = Join-Path $workDir "breakglass-admin_$(Get-SafeFileNamePart $env:COMPUTERNAME)_$(Get-SafeFileNamePart $machineSerial).txt"
                ($credLines -join "`r`n") | Set-Content -Path $credPath -Encoding UTF8
                try {
                    & icacls $credPath '/inheritance:r' '/grant:r' '*S-1-5-32-544:F' 'SYSTEM:F' 2>&1 | Out-Null
                } catch {
                    Write-Log "Could not restrict permissions on $(Split-Path -Leaf $credPath): $($_.Exception.Message)" 'WARN'
                }
                Write-Log "Credential written to $credPath (ACL-restricted to Administrators/SYSTEM) - not logged here."
            }

            try {
                Disable-LocalUser -Name 'Guest' -ErrorAction Stop
                Write-Log 'Guest account disabled.'
            } catch {
                Write-Log "Could not disable the Guest account (may already be disabled or absent): $($_.Exception.Message)" 'WARN'
            }

            if (-not $existing) {
                $dsregOutput2 = & dsregcmd /status 2>&1 | Out-String
                if ($dsregOutput2 -match 'AzureAdJoined\s*:\s*YES') {
                    # Never the built-in RID-500 Administrator per the plan's explicit
                    # caution - AdministratorAccountName is always this break-glass
                    # account's own name, never that built-in account.
                    $lapsPath = 'HKLM:\SOFTWARE\Microsoft\Policies\LAPS'
                    $null = Confirm-RegistryKey -Path $lapsPath
                    Set-ItemProperty -Path $lapsPath -Name 'BackupDirectory' -Value 1 -Type DWord -ErrorAction Stop
                    Set-ItemProperty -Path $lapsPath -Name 'AdministratorAccountName' -Value $AccountName -Type String -ErrorAction Stop
                    Set-ItemProperty -Path $lapsPath -Name 'PasswordLength' -Value 20 -Type DWord -ErrorAction Stop
                    Set-ItemProperty -Path $lapsPath -Name 'PasswordComplexity' -Value 4 -Type DWord -ErrorAction Stop
                    Set-ItemProperty -Path $lapsPath -Name 'PasswordAgeDays' -Value 30 -Type DWord -ErrorAction Stop
                    Write-Log "Windows LAPS policy set to manage '$AccountName' (backs up to Entra ID, 20-char complex password, 30-day rotation)."
                    if (Get-Command Invoke-LapsPolicyProcessing -ErrorAction SilentlyContinue) {
                        try {
                            Invoke-LapsPolicyProcessing -ErrorAction Stop | Out-Null
                            Write-Log 'Ran Invoke-LapsPolicyProcessing - LAPS takes over rotating this password from here on its own schedule.'
                        } catch {
                            Write-Log "Invoke-LapsPolicyProcessing failed: $($_.Exception.Message) - the policy is set and LAPS should still pick it up on its own schedule." 'WARN'
                        }
                    } else {
                        Write-Log 'Invoke-LapsPolicyProcessing is not available on this machine (needs the Windows LAPS client - built into 22H2+, or installed separately on older builds) - the policy is set but has no effect until that is present.' 'WARN'
                    }
                } else {
                    Write-Log 'This machine is not Entra-joined - Windows LAPS cannot back up to Entra ID, so the generated password is only in this run''s credential file. There is no central recovery copy.' 'WARN'
                }
            }
        } catch {
            Write-Log "Could not create the break-glass administrator account: $($_.Exception.Message)" 'WARN'
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
        $null = Confirm-RegistryKey -Path $policyPath
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

function Get-WuResultText {
    # OperationResultCode enum (wuapi.h) - shared by download and install results.
    # Confirmed against Microsoft's own wuapi.h reference rather than assumed:
    # 0=NotStarted, 1=InProgress, 2=Succeeded, 3=SucceededWithErrors, 4=Failed, 5=Aborted.
    param([int]$ResultCode)
    switch ($ResultCode) {
        0 { 'not started' }
        1 { 'in progress' }
        2 { 'succeeded' }
        3 { 'succeeded with errors' }
        4 { 'failed' }
        5 { 'aborted' }
        default { "unknown code $ResultCode" }
    }
}

function Format-WuElapsed {
    param([TimeSpan]$Elapsed)
    $totalSec = [int]$Elapsed.TotalSeconds
    '{0}m {1:D2}s' -f [int]($totalSec / 60), ($totalSec % 60)
}

function Invoke-WindowsUpdatePassAttempt {
    # One search -> download -> install cycle. Download()/Install() are still the same
    # synchronous WUA calls as before (no new async/callback surface - BeginDownload's
    # callback parameters need a COM event-sink object, which is fragile to implement
    # reliably from PowerShell) - the only change here is reading the per-update detail
    # both result objects already carry (IDownloadResult/IInstallationResult.GetUpdateResult,
    # confirmed via Microsoft's own wuapi.h reference) instead of only the one aggregate
    # ResultCode for the whole batch, plus elapsed time so a long silent gap reads as
    # "still working" instead of "did this freeze."
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

        Write-Log "Downloading $($updatesToDownload.Count) update(s)... (large cumulative updates can take several minutes with no further output until the download finishes)"
        $downloader = $updateSession.CreateUpdateDownloader()
        $downloader.Updates = $updatesToDownload
        $downloadStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $downloadResult = $downloader.Download()
        Write-Log "Download finished in $(Format-WuElapsed $downloadStopwatch.Elapsed) - overall result: $(Get-WuResultText $downloadResult.ResultCode)"
        for ($i = 0; $i -lt $updatesToDownload.Count; $i++) {
            $itemResult = $downloadResult.GetUpdateResult($i)
            Write-Log "  - $(Get-WuResultText $itemResult.ResultCode): $($updatesToDownload.Item($i).Title)"
        }

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

        Write-Log "Installing $($updatesToInstall.Count) update(s)... (no further output until the install finishes)"
        $installer = $updateSession.CreateUpdateInstaller()
        $installer.Updates = $updatesToInstall
        $installStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $installResult = $installer.Install()
        Write-Log "Install finished in $(Format-WuElapsed $installStopwatch.Elapsed) - overall result: $(Get-WuResultText $installResult.ResultCode)"

        $installedCount = 0
        for ($i = 0; $i -lt $updatesToInstall.Count; $i++) {
            $itemResult = $installResult.GetUpdateResult($i)
            Write-Log "  - $(Get-WuResultText $itemResult.ResultCode): $($updatesToInstall.Item($i).Title)"
            if ($itemResult.ResultCode -eq 2 -or $itemResult.ResultCode -eq 3) { $installedCount++ }
        }

        $result.InstalledCount = $installedCount
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
        $workTeamsAppx = Get-AppxPackage -AllUsers -Name 'MSTeams' -ErrorAction SilentlyContinue | Select-Object -First 1
        $classicWorkTeams = Get-UninstallEntries | Where-Object { $_.DisplayName -like 'Teams Machine-Wide Installer*' } | Select-Object -First 1
        if ($workTeamsAppx -or $classicWorkTeams) {
            $detail = if ($workTeamsAppx) { "AppX MSTeams $($workTeamsAppx.Version)" } else { $classicWorkTeams.DisplayName }
            $checks.Add([PSCustomObject]@{ Check = 'Work/School Teams'; Status = 'INFO'; Detail = "Detected ($detail) - never removed by this tool" })
        } else {
            $checks.Add([PSCustomObject]@{ Check = 'Work/School Teams'; Status = 'INFO'; Detail = 'Not detected' })
        }
    } catch {
        $checks.Add([PSCustomObject]@{ Check = 'Work/School Teams'; Status = 'UNKNOWN'; Detail = $_.Exception.Message })
    }

    try {
        $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop
        $checks.Add([PSCustomObject]@{ Check = 'Secure Boot'; Status = if ($secureBoot) { 'OK' } else { 'ATTENTION' }; Detail = "Enabled=$secureBoot" })
    } catch {
        $checks.Add([PSCustomObject]@{ Check = 'Secure Boot'; Status = 'UNKNOWN'; Detail = 'Not UEFI, or could not be checked' })
    }

    try {
        # Status only - protection state and whether a recovery password protector
        # exists. Never the recovery password value itself, which only ever goes into
        # bitlocker-recovery.txt (a separate file in this same handoff folder).
        $osVol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        $hasRecoveryProtector = [bool]($osVol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
        $isProtected = $osVol.ProtectionStatus -eq 'On'
        $checks.Add([PSCustomObject]@{
            Check  = 'BitLocker'
            Status = if ($isProtected -and $hasRecoveryProtector) { 'OK' } else { 'ATTENTION' }
            Detail = "ProtectionStatus=$($osVol.ProtectionStatus), EncryptionPercentage=$($osVol.EncryptionPercentage), RecoveryPasswordProtector=$hasRecoveryProtector"
        })
    } catch {
        $checks.Add([PSCustomObject]@{ Check = 'BitLocker'; Status = 'UNKNOWN'; Detail = $_.Exception.Message })
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

function Get-BitLockerKeyData {
    # Read-only - never enables, disables, or changes encryption state on any volume.
    # Returns one object per volume with its protection status and any RecoveryPassword
    # key protectors found. Callers must never pass the RecoveryPassword value to
    # Write-Log - it only ever goes into a dedicated, ACL-restricted file
    # (bitlocker-recovery.txt) or the GUI's own in-memory display, never the run log.
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

function Enable-BitLockerProtection {
    # Opt-in only, and deliberately not undo-tracked - improvement-plan.md 2.5 scopes
    # this feature as "status, enable, escrow (never a silent disable)". Disabling/decrypting
    # a drive is destructive enough that it must always be a separate, deliberate action
    # (the GUI's Panels > Disable BitLocker..., which backs up every key first, or
    # BitLocker's own tools), never an automatic side effect of reverting something else
    # via Revert Last Run.
    param([string]$MountPoint = 'C:')
    Invoke-Step "Enabling BitLocker on $MountPoint" {
        try {
            $tpm = Get-Tpm -ErrorAction Stop
            if (-not $tpm.TpmReady) {
                Write-Log "TPM is not ready (TpmReady=$($tpm.TpmReady)) - BitLocker needs a ready TPM for the protector this tool uses. Skipping." 'WARN'
                return
            }
        } catch {
            Write-Log "Could not read TPM status: $($_.Exception.Message) - skipping BitLocker enable." 'WARN'
            return
        }

        try {
            $volume = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
        } catch {
            Write-Log "Could not read BitLocker status for $MountPoint`: $($_.Exception.Message)" 'WARN'
            return
        }
        if ($volume.ProtectionStatus -eq 'On') {
            Write-Log "BitLocker protection is already On for $MountPoint - nothing to do."
            return
        }

        try {
            # Enable-BitLocker takes exactly one key-protector switch per call (TpmProtector
            # and RecoveryPasswordProtector are separate, mutually exclusive parameter
            # sets, confirmed against Microsoft's own BitLocker module reference) - the
            # recovery password protector is added in a second, separate call, matching
            # the plan's own two-step sequence.
            Enable-BitLocker -MountPoint $MountPoint -EncryptionMethod XtsAes256 -UsedSpaceOnly -TpmProtector -SkipHardwareTest -ErrorAction Stop | Out-Null
            # Add-BitLockerKeyProtector prints the NEW recovery password in the warning stream, which the run
            # transcript (and so the log the GUI can zip) would keep: silenced here. The password is read from
            # Windows when it is needed (Panels > BitLocker status, or manage-bde -protectors -get).
            Add-BitLockerKeyProtector -MountPoint $MountPoint -RecoveryPasswordProtector -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
            Write-Log "BitLocker enabled on $MountPoint (XtsAes256, used-space-only, TPM protector + recovery password protector added; the recovery password is not written to this log)."
        } catch {
            Write-Log "Could not enable BitLocker on $MountPoint`: $($_.Exception.Message)" 'WARN'
            return
        }

        $dsregOutput = & dsregcmd /status 2>&1 | Out-String
        if ($dsregOutput -match 'AzureAdJoined\s*:\s*YES') {
            try {
                $refreshed = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
                $recoveryProtector = $refreshed.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
                if ($recoveryProtector) {
                    BackupToAAD-BitLockerKeyProtector -MountPoint $MountPoint -KeyProtectorId $recoveryProtector.KeyProtectorId -ErrorAction Stop
                    Write-Log 'Recovery password backed up to Entra ID (BackupToAAD-BitLockerKeyProtector).'
                } else {
                    Write-Log 'Could not find the recovery password protector to back up to Entra ID.' 'WARN'
                }
            } catch {
                Write-Log "Could not back up the recovery password to Entra ID: $($_.Exception.Message) - the key still exists locally and will be included in the handoff package." 'WARN'
            }
        } else {
            Write-Log 'This machine is not Entra-joined - the recovery password has no central (Entra ID) backup. It will be included in the handoff package - store that securely.' 'WARN'
        }
        Write-Log 'Encryption continues in the background - re-run Scan BitLocker Status or check Get-BitLockerVolume to monitor progress. This is never reversed automatically; use the BitLocker control panel or manage-bde if decryption is ever genuinely needed.'
    }
}

function Set-PreventAutomaticDeviceEncryption {
    Invoke-Step 'Preventing automatic device encryption' {
        try {
            $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker'
            $null = Confirm-RegistryKey -Path $path
            Add-UndoRegistryEntry -Path $path -Name 'PreventDeviceEncryption' -Type 'DWord'
            Set-ItemProperty -Path $path -Name 'PreventDeviceEncryption' -Value 1 -Type DWord -ErrorAction Stop
            Write-Log 'Automatic device encryption prevented (PreventDeviceEncryption=1) - Windows will not silently turn on BitLocker at first Microsoft-account sign-in (relevant on 24H2, for machines staying on local accounts rather than Entra/Microsoft accounts).'
        } catch {
            Write-Log "Could not set PreventDeviceEncryption: $($_.Exception.Message)" 'WARN'
        }
    }
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

        # bitlocker-recovery.txt - written only when a recovery password protector
        # actually exists, and only the recovery keys themselves, never logged via
        # Write-Log. ProgramData is world-readable by default, so this file's
        # permissions are restricted to Administrators/SYSTEM right after writing it -
        # this repo's handoff folder isn't meant to be a place a standard user could read
        # a decryption secret out of.
        $bitLockerData = Get-BitLockerKeyData
        if (-not $bitLockerData.Error) {
            $anyRecoveryKeys = [bool]($bitLockerData.Volumes | Where-Object { $_.RecoveryKeys.Count -gt 0 })
            if ($anyRecoveryKeys) {
                $bitLockerLines = New-Object System.Collections.Generic.List[string]
                $bitLockerLines.Add("BitLocker recovery keys for $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
                $bitLockerLines.Add('This file contains decryption secrets - store or destroy it securely.')
                $bitLockerLines.Add('')
                foreach ($vol in $bitLockerData.Volumes) {
                    foreach ($key in $vol.RecoveryKeys) {
                        $bitLockerLines.Add("Drive $($vol.MountPoint) [$($vol.VolumeType)] - Key Protector ID $($key.KeyProtectorId)")
                        $bitLockerLines.Add("Recovery Key: $($key.RecoveryPassword)")
                        $bitLockerLines.Add('')
                    }
                }
                $bitLockerPath = Join-Path $handoffDir 'bitlocker-recovery.txt'
                ($bitLockerLines -join "`r`n") | Set-Content -Path $bitLockerPath -Encoding UTF8
                try {
                    & icacls $bitLockerPath '/inheritance:r' '/grant:r' '*S-1-5-32-544:F' 'SYSTEM:F' 2>&1 | Out-Null
                } catch {
                    Write-Log "Could not restrict permissions on bitlocker-recovery.txt: $($_.Exception.Message)" 'WARN'
                }
                Write-Log "BitLocker recovery key(s) for $($bitLockerData.Volumes.Count) volume(s) written to bitlocker-recovery.txt (not logged here)."
            } else {
                Write-Log 'No BitLocker recovery password protectors found - bitlocker-recovery.txt not created.'
            }
        } else {
            Write-Log "Could not read BitLocker status for the handoff package: $($bitLockerData.Error)" 'WARN'
        }

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
            $null = Confirm-RegistryKey -Path $lockPath
            Set-ItemProperty -Path $lockPath -Name 'InactivityTimeoutSecs' -Value $LockTimeoutSec -Type DWord -ErrorAction Stop
            # Fast Startup hibernates the kernel session instead of a full shutdown, which
            # both interferes with Wake-on-LAN and can leave a Windows Update pass looking
            # "installed" without a genuine cold boot.
            $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
            $null = Confirm-RegistryKey -Path $powerKey
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
if ($RemoveLocalAdmins) { Remove-LocalAdministratorMembers -Names ($RemoveLocalAdmins -split ',' | Where-Object { $_ }) }
if ($CreateBreakGlassAdmin) { New-BreakGlassLocalAdmin -AccountName $BreakGlassAdminName }
if ($EnableBitLocker) { Enable-BitLockerProtection }
if ($PreventAutomaticDeviceEncryption) { Set-PreventAutomaticDeviceEncryption }

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
