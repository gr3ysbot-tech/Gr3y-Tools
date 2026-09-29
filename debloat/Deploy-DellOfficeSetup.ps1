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
    [switch]$SkipOfficeRemoval,
    [switch]$SkipOfficeInstall,
    [ValidateSet('Current', 'MonthlyEnterprise', 'SemiAnnual', 'SemiAnnualPreview')]
    [string]$OfficeChannel = 'MonthlyEnterprise',
    [string]$OfficeLanguage = 'en-us',
    [switch]$NoReboot
)

$ErrorActionPreference = 'Continue'
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

# AppX/MSIX package Name patterns known to be Dell/Lenovo OEM bloat, safe to remove
# on a business fleet managed via Intune/Dell Command | Update/Lenovo Vantage.
# Deliberately NOT included: DellInc.DellCommandUpdate (driver update tool - keep
# for IT), Dell display/audio drivers (not AppX packages), Dell.SupportAssistAgent
# core service if your org actively uses SupportAssist for Business, and the Lenovo
# Vantage / Commercial Vantage + System Interface Foundation packages (keep for
# driver/BIOS updates and fan/thermal control - same reasoning as Dell Command Update).
$OemBloatAppxPatterns = @(
    # Dell
    'DellInc.DellSupportAssistforPCs'
    'DellInc.DellOptimizer*'
    'DellInc.PartnerPromo*'
    'DellInc.DellCustomerConnect'
    'DellInc.MyDell'
    'DellInc.DellDigitalDelivery'
    'DellInc.DellProductRegistration'
    'DellInc.DellPremierColor'
    'DellInc.DellCinemaColor'
    'DellInc.DellPowerManager'
    'DellInc.DellPeripheralManager'
    'DellInc.DellPair'
    'DellInc.DellMobileConnect'
    'DellInc.PrivacyandSecurity'
    # Lenovo (publisher ID E046963F.*) - Vantage/Commercial Vantage and System
    # Interface Foundation are intentionally excluded, see note above.
    'E046963F.LenovoCompanion'
    'E046963F.LenovoNow'
    'E046963F.LenovoWelcome'
    'E046963F.LenovoVoice'
    'E046963F.LenovoFamilyCloud'
    'E046963F.LenovoUtility'
    'E046963F.LenovoServiceBridge'
    'MirametrixInc.GlancebyMirametrix'
    # Generic trialware bundled by multiple OEMs
    '*Dropbox*'
    '*McAfee*'
    '*WildTangent*'
    # Windows 11's built-in consumer "Chat"/Teams AppX (personal Microsoft/Skype
    # accounts, pinned to the taskbar by default). This is NOT the work/business
    # Teams client - that installs separately as a Win32 app via MSI, not AppX, so
    # removing this package leaves a real work Teams install completely untouched.
    'MicrosoftTeams'
)

# Win32 (registry Uninstall key) DisplayName patterns for Dell/Lenovo/McAfee bloat.
# Same exclusions as above apply - Dell Command | Update and Lenovo Vantage are
# intentionally excluded.
$Win32BloatPatterns = @(
    # Dell
    'Dell SupportAssist*'
    'Dell SupportAssist Remediation'
    'Dell SupportAssist OS Recovery*'
    'Dell Optimizer*'
    'Dell Digital Delivery*'
    'Dell Product Registration'
    'Dell Peripheral Manager*'
    'Dell Mobile Connect*'
    'Dell Pair'
    'Dell Core Services'
    'Waves MaxxAudio*'
    'MaxxAudioPro*'
    # Lenovo
    'Lenovo Now'
    'Lenovo Welcome'
    'Lenovo Voice'
    'Lenovo Family Cloud'
    'Lenovo Utility*'
    'Lenovo Service Bridge'
    'Glance by Mirametrix*'
    # Generic trialware bundled by multiple OEMs
    'Dropbox Promotion'
    'McAfee*'
    'WildTangent*'
)

function Get-UninstallEntries {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName }
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

    foreach ($pattern in $OemBloatAppxPatterns) {
        $installed = $allInstalledAppx | Where-Object { $_.Name -like $pattern }
        foreach ($pkg in $installed) {
            Invoke-Step "Removing AppX package: $($pkg.PackageFullName)" {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            }
        }
        $provisioned = $allProvisionedAppx | Where-Object { $_.DisplayName -like $pattern }
        foreach ($pkg in $provisioned) {
            Invoke-Step "De-provisioning AppX package: $($pkg.DisplayName)" {
                Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }

    # --- Win32 programs, via their own registry uninstall string ---
    # (Previously also tried winget first on every match, but the registry uninstall
    # string below always ran anyway - winget rarely recognizes OEM-bundled software
    # by name, so it was pure added latency for no extra removals.)
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
                        Write-Log "Running msiexec /x $productCode /qn /norestart for '$name'"
                        Start-Process msiexec.exe -ArgumentList "/x $productCode /qn /norestart" -Wait -ErrorAction SilentlyContinue
                    } else {
                        # Best-effort silent flags for EXE-based uninstallers (NSIS/InstallShield/Inno).
                        foreach ($flag in @('/S', '/silent', '/verysilent /norestart', '/quiet')) {
                            Write-Log "Attempting EXE uninstall for '$name' with flag(s): $flag"
                            $exe = ($uninstallString -replace '"', '') -split ' ' | Select-Object -First 1
                            if (Test-Path $exe) {
                                Start-Process $exe -ArgumentList $flag -Wait -ErrorAction SilentlyContinue
                                break
                            }
                        }
                    }
                }
            }
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
    $oemTaskFolders = @('\Dell\', '\Lenovo\')
    $keepTaskPatterns = @('*CommandUpdate*', '*Vantage*')

    foreach ($folder in $oemTaskFolders) {
        $tasks = Get-ScheduledTask -TaskPath "$folder*" -ErrorAction SilentlyContinue
        foreach ($task in $tasks) {
            $isKept = $false
            foreach ($keep in $keepTaskPatterns) {
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
    $bloatServicePatterns = @(
        '*SupportAssist*', '*Dell Digital Delivery*', '*Dell Optimizer*',
        '*Lenovo Now*', '*Lenovo Welcome*', '*Lenovo Voice*', '*Lenovo Family Cloud*',
        '*Lenovo Utility*', '*Lenovo Service Bridge*'
    )
    foreach ($pattern in $bloatServicePatterns) {
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
if (-not $SkipDebloat) {
    Remove-OemBloatware
    Disable-OemScheduledTasksAndServices
}
if (-not $SkipOfficeRemoval) { Uninstall-ExistingOffice }
if (-not $SkipOfficeInstall) { Install-Microsoft365Business }

Write-Log "Run complete. Log saved to $logPath"

if (-not $DryRun -and -not $NoReboot) {
    Write-Log 'A reboot is recommended to finish clearing removed services/drivers.'
    $answer = Read-Host 'Reboot now? (y/N)'
    if ($answer -eq 'y') { Restart-Computer -Force }
}

Stop-Transcript | Out-Null
