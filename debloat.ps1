<#
.SYNOPSIS
    Gr3y Tools - one-line launcher for Gr3yLabs Tools: Dell/Lenovo debloat,
    Microsoft 365 Apps for business deploy, and a categorized app install catalog.

.DESCRIPTION
    Run this on the target laptop from an elevated or non-elevated PowerShell prompt -
    PowerShell 7/pwsh or Windows PowerShell 5.1, either one:

        irm get.gr3y.io/debloat | iex

    Fetches latest.json from the repo (or from -Ref, if pinned) for the current
    version/commit and each tool file's expected SHA256, downloads every file from that
    exact commit (immutable - no 5-minute CDN lag mismatch between files), verifies each
    hash, and aborts before running anything if any file doesn't match. Only elevates
    once it has a verified local copy - if the current session isn't already elevated, it
    relaunches directly into the verified Gr3ysUtilities.ps1 (no second network fetch).

    This download-and-verify step runs identically under PowerShell 7 or Windows
    PowerShell - only the GUI itself (Gr3ysUtilities.ps1, and the worker script it
    drives) needs Windows PowerShell 5.1, so only that final launch step is routed
    through powershell.exe. An earlier version re-ran this entire bootstrap a second
    time from scratch under a freshly spawned Windows PowerShell session just to reach
    that same launch step whenever it was started from PowerShell 7 - roughly doubling
    every network round-trip (the manifest plus all 5 files) for no benefit, and using a
    fragile piped re-fetch command that could close its window before anything was
    visible if that second attempt hit any early error. This version fetches and
    verifies exactly once no matter which shell started it.

    Always pulls the current version from GitHub, so there's nothing to keep manually
    copied/updated across client laptops - including edits to apps-catalog.json or
    bloat-patterns.json (add, remove, or rename entries there and every future run
    picks it up).

    Honest limit: hash verification protects integrity/consistency (the files you get
    are exactly the files that commit's manifest says they should be) - it does not
    protect against a compromised GitHub account publishing a bad commit and its matching
    manifest together. That's what code signing (a separate, planned effort) is for.

.PARAMETER Ref
    Branch, tag or commit SHA to fetch latest.json from. Defaults to main. Use this to
    pin a field run to a known-good release instead of whatever is on main right now,
    e.g. -Ref v1.2.0.
#>

param([string]$Ref = 'main')

function Test-Gr3yToolsIsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Old download folders from previous runs otherwise sit in %TEMP% forever.
Get-ChildItem -Path $env:TEMP -Directory -Filter 'Gr3yTools_*' -ErrorAction SilentlyContinue |
    Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-7) } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Gr3yLabs Tools - Dell/Lenovo debloat + Office deploy + app installer" -ForegroundColor Cyan
if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Host "Running under PowerShell 7 - that's fine for this part. Only the GUI itself needs Windows PowerShell 5.1, which is where it launches below." -ForegroundColor Yellow
}
Write-Host "Checking latest.json ($Ref)..."

$manifestUrl = "https://raw.githubusercontent.com/gr3ysbot-tech/Gr3y-Tools/$Ref/latest.json"
try {
    $manifest = Invoke-RestMethod -Uri $manifestUrl -UseBasicParsing
} catch {
    Write-Host "Could not fetch $manifestUrl - $($_.Exception.Message)" -ForegroundColor Red
    return
}
if (-not $manifest.commit -or -not $manifest.files) {
    Write-Host "latest.json at $Ref is missing 'commit' or 'files' - aborting." -ForegroundColor Red
    return
}

# Commit-SHA URLs are immutable - every file in this run comes from the exact same
# snapshot latest.json described, so there's no window where one file could be newer
# than another (a real risk with two files independently fetched from a moving branch).
$pinnedRawBase = "https://raw.githubusercontent.com/gr3ysbot-tech/Gr3y-Tools/$($manifest.commit)"
$shortCommit = if ($manifest.commit.Length -ge 7) { $manifest.commit.Substring(0, 7) } else { $manifest.commit }

$installDir = Join-Path $env:TEMP ("Gr3yTools_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $installDir -Force | Out-Null

Write-Host "Downloading and verifying tool files (version $($manifest.version), commit $shortCommit)..."

foreach ($fileEntry in $manifest.files.PSObject.Properties) {
    $fileName = $fileEntry.Name
    $expectedHash = $fileEntry.Value
    $destPath = Join-Path $installDir $fileName
    $sourceUrl = "$pinnedRawBase/debloat/$fileName"
    Write-Host "  - $fileName"
    try {
        Invoke-WebRequest -Uri $sourceUrl -OutFile $destPath -UseBasicParsing
    } catch {
        Write-Host "Download failed for $fileName - $($_.Exception.Message). Aborting." -ForegroundColor Red
        return
    }
    $actualHash = (Get-FileHash -Path $destPath -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash) {
        Write-Host "Hash mismatch for $fileName - expected $expectedHash, got $actualHash. Aborting - nothing will be run." -ForegroundColor Red
        return
    }
}

Write-Host 'All files verified.' -ForegroundColor Green

$guiPath = Join-Path $installDir 'Gr3ysUtilities.ps1'
$guiArgs = @(
    '-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', """$guiPath""",
    '-Version', $manifest.version, '-Commit', $shortCommit
)

if (-not (Test-Gr3yToolsIsAdmin)) {
    # Elevate ONCE, straight into the already-downloaded-and-verified GUI - no second
    # network fetch, no re-running this bootstrap a second time under the elevated
    # session. That used to mean two independent downloads of the same "latest" files,
    # with no guarantee both fetches saw the same content. Always powershell.exe here
    # (Windows PowerShell 5.1), regardless of which shell is running this bootstrap
    # script right now - the GUI only runs correctly there.
    Write-Host 'Elevation required - relaunching as Administrator (accept the UAC prompt)...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $guiArgs -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "Could not relaunch as Administrator: $($_.Exception.Message)" -ForegroundColor Red
    }
    return
}

Write-Host "Starting Gr3yLabs Tools..." -ForegroundColor Green
# Always launch as its own -ExecutionPolicy Bypass process, regardless of what policy the
# CURRENT session has - a plain "& script.ps1" call would inherit whatever policy this
# session already has (Restricted by default on an unmodified/clean machine - exactly
# what this tool's target laptops are).
try {
    Start-Process -FilePath 'powershell.exe' -Wait -ArgumentList $guiArgs -ErrorAction Stop
} catch {
    Write-Host "Could not launch Gr3yLabs Tools: $($_.Exception.Message)" -ForegroundColor Red
}
