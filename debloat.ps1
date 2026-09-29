<#
.SYNOPSIS
    Gr3y Tools - one-line launcher for the Dell/Lenovo debloat + Microsoft 365 Apps
    for business deploy tool. Fetches the latest version of the tool and opens its
    browser control panel.

.DESCRIPTION
    Run this on the target laptop from an elevated or non-elevated PowerShell prompt:

        irm https://raw.githubusercontent.com/gr3ysbot-tech/Gr3y-Tools/main/debloat.ps1 | iex

    If the current session isn't elevated, this relaunches itself elevated (one UAC
    prompt) and re-fetches itself there - same pattern as the tools this is modeled
    after. Once elevated, it downloads the actual tool files (Deploy-DellOfficeSetup.ps1
    + WebApp.ps1) fresh from this repo into a per-run temp folder and starts the local
    web control panel at http://localhost:8787.

    Always pulls the current version from GitHub, so there's nothing to keep manually
    copied/updated across client laptops.
#>

function Test-Gr3yToolsIsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$repoRawBase = 'https://raw.githubusercontent.com/gr3ysbot-tech/Gr3y-Tools/main'
$bootstrapUrl = "$repoRawBase/debloat.ps1"

if (-not (Test-Gr3yToolsIsAdmin)) {
    Write-Host 'Elevation required - relaunching as Administrator (accept the UAC prompt)...' -ForegroundColor Yellow
    $relaunchCommand = "irm $bootstrapUrl | iex"
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', $relaunchCommand
    )
    return
}

Write-Host 'Gr3y Tools - Dell/Lenovo debloat + Office deploy' -ForegroundColor Cyan
Write-Host 'Downloading latest tool files...'

$installDir = Join-Path $env:TEMP ("Gr3yTools-Debloat_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $installDir -Force | Out-Null

$toolFiles = @('debloat/Deploy-DellOfficeSetup.ps1', 'debloat/WebApp.ps1')
foreach ($relativePath in $toolFiles) {
    $fileName = Split-Path -Leaf $relativePath
    $destPath = Join-Path $installDir $fileName
    $sourceUrl = "$repoRawBase/$relativePath"
    Write-Host "  - $fileName"
    Invoke-WebRequest -Uri $sourceUrl -OutFile $destPath -UseBasicParsing
}

Write-Host 'Starting control panel at http://localhost:8787 ...' -ForegroundColor Green
& (Join-Path $installDir 'WebApp.ps1')
