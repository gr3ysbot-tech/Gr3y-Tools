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

$machineHost = $env:COMPUTERNAME
$machineManufacturer = if ($cs -and $cs.Manufacturer) { $cs.Manufacturer } else { 'UnknownMfr' }
$machineModel = if ($cs -and $cs.Model) { $cs.Model } else { 'UnknownModel' }
$machineSerial = if ($bios -and $bios.SerialNumber) { $bios.SerialNumber } else { 'UnknownSerial' }

$logIdentifier = "{0}_{1}-{2}_{3}" -f `
    (Get-SafeFileNamePart $machineHost), `
    (Get-SafeFileNamePart $machineManufacturer), `
    (Get-SafeFileNamePart $machineModel), `
    (Get-SafeFileNamePart $machineSerial)

$logPath = Join-Path $workDir "run_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$logIdentifier.log"
Start-Transcript -Path $logPath -Append | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
}

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
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
            Checkpoint-Computer -Description 'Gr3y Tools - before debloat/Office deploy' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
            Write-Log 'System Restore point created.'
        } catch {
            Write-Log "Could not create a System Restore point (often blocked by policy, or Windows allows only one per 24h): $($_.Exception.Message)" 'WARN'
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
            $item.PowerShell.Dispose()
        }
    }

    $pool.Close()
    $pool.Dispose()
}

function Start-ProcessLowPriority {
    # Launches an uninstaller at BelowNormal process priority so it yields to
    # whatever else is using the machine (remote session, foreground apps)
    # instead of competing for CPU/disk at full priority.
    param(
        [string]$FilePath,
        [string]$ArgumentList
    )
    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
    if ($proc) {
        try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
        $proc.WaitForExit()
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
    $appxRemoveAction = { param($FullName) Remove-AppxPackage -Package $FullName -AllUsers -ErrorAction SilentlyContinue }
    $appxDeprovisionAction = { param($PackageName) Remove-AppxProvisionedPackage -Online -PackageName $PackageName -ErrorAction SilentlyContinue | Out-Null }

    $appxSteps = New-Object System.Collections.Generic.List[hashtable]
    foreach ($pattern in $OemBloatAppxPatterns) {
        $installed = $allInstalledAppx | Where-Object { $_.Name -like $pattern }
        foreach ($pkg in $installed) {
            $appxSteps.Add(@{
                Description = "Removing AppX package: $($pkg.PackageFullName)"
                Action = $appxRemoveAction
                Args = @{ FullName = $pkg.PackageFullName }
            })
        }
        $provisioned = $allProvisionedAppx | Where-Object { $_.DisplayName -like $pattern }
        foreach ($pkg in $provisioned) {
            $appxSteps.Add(@{
                Description = "De-provisioning AppX package: $($pkg.DisplayName)"
                Action = $appxDeprovisionAction
                Args = @{ PackageName = $pkg.PackageName }
            })
        }
    }
    if ($appxSteps.Count -gt 0) {
        Write-Log "Removing $($appxSteps.Count) AppX package/provisioning entries (up to 3 at a time)..."
    }
    Invoke-ThrottledSteps -Steps $appxSteps -MaxConcurrency 3

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
                $uninstallString = $match.UninstallString
                if ($uninstallString) {
                    if ($uninstallString -match 'msiexec') {
                        $productCode = $match.PSChildName
                        Write-Log "Running msiexec /x $productCode /qn /norestart for '$name' (low priority)"
                        Start-ProcessLowPriority -FilePath 'msiexec.exe' -ArgumentList "/x $productCode /qn /norestart"
                    } else {
                        # Best-effort silent flags for EXE-based uninstallers (NSIS/InstallShield/Inno).
                        foreach ($flag in @('/S', '/silent', '/verysilent /norestart', '/quiet')) {
                            Write-Log "Attempting EXE uninstall for '$name' with flag(s): $flag (low priority)"
                            $exe = ($uninstallString -replace '"', '') -split ' ' | Select-Object -First 1
                            if (Test-Path $exe) {
                                Start-ProcessLowPriority -FilePath $exe -ArgumentList $flag
                                break
                            }
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
            $isKept = $false
            foreach ($keep in $OemTaskKeepPatterns) {
                if ($task.TaskName -like $keep) { $isKept = $true; break }
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

# ============================================================================
# FIXES - standalone one-click troubleshooting actions. Not bundled into a
# normal debloat/Office run; each is only invoked when its own flag is passed.
# ============================================================================

function Invoke-SystemRepair {
    Write-Log '--- Fix: Running System File Repair (sfc + DISM) - this can take 10-20+ minutes ---'
    Invoke-Step 'Running sfc /scannow' {
        sfc /scannow 2>&1 | ForEach-Object { Write-Log "sfc: $_" }
    }
    Invoke-Step 'Running DISM /Online /Cleanup-Image /RestoreHealth' {
        DISM /Online /Cleanup-Image /RestoreHealth 2>&1 | ForEach-Object { Write-Log "DISM: $_" }
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
    }
    $softwareDistribution = Join-Path $env:WINDIR 'SoftwareDistribution'
    $catroot2 = Join-Path $env:WINDIR 'System32\catroot2'
    Invoke-Step "Renaming $softwareDistribution and $catroot2 so Windows Update rebuilds them fresh" {
        if (Test-Path $softwareDistribution) {
            Remove-Item -Path "$softwareDistribution.bak" -Recurse -Force -ErrorAction SilentlyContinue
            Rename-Item -Path $softwareDistribution -NewName 'SoftwareDistribution.bak' -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $catroot2) {
            Remove-Item -Path "$catroot2.bak" -Recurse -Force -ErrorAction SilentlyContinue
            Rename-Item -Path $catroot2 -NewName 'catroot2.bak' -Force -ErrorAction SilentlyContinue
        }
    }
    Invoke-Step "Restarting services: $($services -join ', ')" {
        foreach ($svc in $services) { Start-Service -Name $svc -ErrorAction SilentlyContinue }
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
    # Pulls the live Click-to-Run setup.exe directly from the Office CDN - this is the
    # same binary the ODT wrapper installs, and avoids tracking a version-specific
    # download URL for the ODT wrapper itself.
    $setupPath = Join-Path $workDir 'setup.exe'
    if (-not (Test-Path $setupPath)) {
        Write-Log 'Downloading Office Click-to-Run setup.exe from officecdn.microsoft.com'
        Invoke-WebRequest -Uri 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -OutFile $setupPath -UseBasicParsing
    }
    return $setupPath
}

function Uninstall-ExistingOffice {
    Write-Log '--- Phase 2: Removing existing Office installation(s) ---'

    $c2rKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $hasC2R = Test-Path $c2rKey

    if ($hasC2R) {
        $setupPath = Get-OfficeDeploymentTool
        $removeXmlPath = Join-Path $workDir 'remove-all.xml'
        @'
<Configuration>
  <Remove All="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
'@ | Set-Content -Path $removeXmlPath -Encoding UTF8

        Invoke-Step 'Removing existing Click-to-Run Office (all products, all languages)' {
            Start-Process -FilePath $setupPath -ArgumentList "/configure ""$removeXmlPath""" -Wait
        }
    } else {
        Write-Log 'No Click-to-Run Office installation detected.'
    }

    # Older MSI-based Office (2016 and earlier, or volume-licensed MSI builds) isn't
    # managed by the ODT - clear it via its own MSI uninstall.
    $msiOffice = Get-UninstallEntries | Where-Object {
        $_.DisplayName -like 'Microsoft Office*' -and $_.UninstallString -match 'msiexec'
    }
    foreach ($entry in $msiOffice) {
        $productCode = $entry.PSChildName
        Invoke-Step "Removing MSI-based Office product: $($entry.DisplayName)" {
            Start-Process msiexec.exe -ArgumentList "/x $productCode /qn /norestart" -Wait
        }
    }

    if (-not $hasC2R -and -not $msiOffice) {
        Write-Log 'No existing Office installation found - nothing to remove.'
    }
}

# ============================================================================
# PHASE 3 - Install Microsoft 365 Apps for business (en-us only)
# ============================================================================

function Install-Microsoft365Business {
    Write-Log "--- Phase 3: Installing Microsoft 365 Apps for business ($OfficeLanguage, $OfficeChannel channel) ---"

    $setupPath = Get-OfficeDeploymentTool
    $installXmlPath = Join-Path $workDir 'install.xml'

    # Product ID O365BusinessRetail = Microsoft 365 Apps for business.
    # (O365ProPlusRetail is the "for enterprise" SKU - do not swap unless your tenant
    # licenses enterprise plans instead.)
    # Groove = legacy consumer OneDrive sync client, always safe to exclude.
    # Uncomment the Teams/OneDrive ExcludeApp lines if your org deploys those separately
    # (e.g. Teams via a dedicated MSI, OneDrive pinned to a specific build).
    @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="$OfficeChannel">
    <Product ID="O365BusinessRetail">
      <Language ID="$OfficeLanguage" />
      <ExcludeApp ID="Groove" />
      <!-- <ExcludeApp ID="Teams" /> -->
      <!-- <ExcludeApp ID="OneDrive" /> -->
    </Product>
  </Add>
  <Updates Enabled="TRUE" Channel="$OfficeChannel" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="AUTOACTIVATE" Value="1" />
</Configuration>
"@ | Set-Content -Path $installXmlPath -Encoding UTF8

    Invoke-Step "Installing Microsoft 365 Apps for business ($OfficeLanguage)" {
        Start-Process -FilePath $setupPath -ArgumentList "/configure ""$installXmlPath""" -Wait
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

if (-not $SkipDebloat) {
    Remove-OemBloatware
    Disable-OemScheduledTasksAndServices
}
if (-not $SkipOfficeRemoval) { Uninstall-ExistingOffice }
if (-not $SkipOfficeInstall) { Install-Microsoft365Business }

if ($FixSystemRepair) { Invoke-SystemRepair }
if ($FixNetworkReset) { Invoke-NetworkReset }
if ($FixWindowsUpdateReset) { Invoke-WindowsUpdateReset }
if ($FixWinGetReinstall) { Invoke-WinGetReinstall }

Write-Log "Run complete. Log saved to $logPath"

if (-not $DryRun -and -not $NoReboot) {
    Write-Log 'A reboot is recommended to finish clearing removed services/drivers.'
    $answer = Read-Host 'Reboot now? (y/N)'
    if ($answer -eq 'y') { Restart-Computer -Force }
}

Stop-Transcript | Out-Null
