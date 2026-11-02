<#
.SYNOPSIS
    Exports installed-app info from the command line only - no GUI, no window.

.DESCRIPTION
    Gr3ysUtilities.ps1's "Export Installed Apps..." button does this from inside the
    GUI, which needs an interactive desktop session to launch. This is the same export,
    as a standalone script, for the case where the only access to the old/replacement
    machine is a command line - an RMM "run script" action, a PowerShell remoting
    session, or similar - and there's no way to launch the GUI there at all.

    Produces the exact same JSON shape Compare Against List... already reads
    (hostname, exportedAt, wingetIds, installedProgramNames, officeDetectionStatus,
    officeInstallations), built from winget, registry and Office binary inspection.
    All inspection is read-only; no admin rights are required. Office bitness remains
    available even when winget is missing. Older exports remain readable but cannot
    recover Office bitness that was never recorded.

    With no -OutputPath, the export object is written to the pipeline instead of a file,
    so it composes with however it's actually being run remotely, e.g.:

        Invoke-Command -ComputerName OLDPC -FilePath .\Export-InstalledApps.ps1 |
            ConvertTo-Json -Depth 4 | Set-Content installed-apps_OLDPC.json

    Or, run directly on the target through an RMM console with -OutputPath to leave the
    JSON file sitting there for pickup:

        .\Export-InstalledApps.ps1 -OutputPath C:\Temp\installed-apps.json

.PARAMETER OutputPath
    Optional. Writes the export as JSON to this path instead of the pipeline.

.PARAMETER Code
    Optional. A pairing code shown by Gr3ysUtilities.ps1's "Pair with Old Machine"
    dialog (Compare Against List...). Sends the export straight to that running app
    instance via a short-lived Cloudflare Worker relay instead of printing it or saving a
    file - nothing to copy-paste or transfer by hand. Takes priority over -OutputPath if
    both are given. No access code is needed on this side - the app unlocked the pairing
    code with one already. The code is one-time and expires in 10 minutes; if no app has
    it open, the relay refuses the export and nothing is stored.

.PARAMETER RelayUrl
    Base URL of the pairing relay Worker. Defaults to the deployed Gr3y Tools relay -
    only override this if you're running your own (see cloudflare/README.md).
#>

[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$Code,
    [string]$RelayUrl = 'https://gr3y-export-relay.gr3y-b8f.workers.dev'
)

function Get-UninstallEntries {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
}

function Get-OfficeExecutableEdition {
    param([string]$Path)
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = New-Object IO.BinaryReader($stream)
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { return 'Unknown' }
        $stream.Position = 60
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt ($stream.Length - 6)) { return 'Unknown' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { return 'Unknown' }
        switch ($reader.ReadUInt16()) {
            0x014C { return '32' }
            0x8664 { return '64' }
            0xAA64 { return '64' }
            default { return 'Unknown' }
        }
    } catch { return 'Unknown' } finally {
        if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
    }
}

function Get-OfficeArchitectureInventory {
    # Inspect both registry locations, independently of the Windows/Office bitness.
    # Legacy InstallRoot keys are only evidence when an Office executable still exists.
    $bases = @('HKLM:\SOFTWARE\Microsoft\Office', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office')
    $seen = @{}
    foreach ($base in $bases) {
        $path = "$base\ClickToRun\Configuration"
        if (Test-Path -LiteralPath $path -ErrorAction Stop) {
            $config = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
            $edition = switch ($config.Platform) { 'x86' { '32' }; 'x64' { '64' }; 'arm64' { '64' }; default { 'Unknown' } }
            $products = @($config.ProductReleaseIds -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $unexpected = @($products | Where-Object { $_ -notmatch '^(O365BusinessRetail|O365ProPlusRetail|O365HomePremRetail|HomeStudentRetail|HomeBusinessRetail|PersonalRetail|OneNoteFreeRetail)$' })
            [pscustomobject]@{
                Name = "Click-to-Run Office ($($products -join ', '))"
                Edition = $edition
                Kind = 'ClickToRun'
                ProductIds = $products
                Protected = ($products.Count -eq 0 -or $unexpected.Count -gt 0)
                Source = $path
            }
        }
        foreach ($version in @('16.0', '15.0', '14.0', '12.0')) {
            foreach ($product in @('', 'Visio', 'Project')) {
                $path = if ($product) { "$base\$version\$product\InstallRoot" } else { "$base\$version\Common\InstallRoot" }
                if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) { continue }
                $root = (Get-ItemProperty -LiteralPath $path -ErrorAction Stop).Path
                if (-not $root) { continue }
                $executables = if ($product -eq 'Visio') { @('VISIO.EXE') } elseif ($product -eq 'Project') { @('WINPROJ.EXE') } else { @('WINWORD.EXE', 'EXCEL.EXE', 'OUTLOOK.EXE', 'MSACCESS.EXE', 'POWERPNT.EXE', 'VISIO.EXE', 'WINPROJ.EXE') }
                foreach ($exe in $executables) {
                    $exePath = Join-Path $root $exe
                    if ($seen.ContainsKey($exePath) -or -not (Test-Path -LiteralPath $exePath -PathType Leaf -ErrorAction Stop)) { continue }
                    $seen[$exePath] = $true
                    [pscustomobject]@{
                        Name = "Office $version ($exe)"
                        Edition = Get-OfficeExecutableEdition -Path $exePath
                        Kind = 'Legacy'
                        Protected = ($exe -in @('VISIO.EXE', 'WINPROJ.EXE'))
                        Source = $exePath
                    }
                }
            }
        }
    }
}

function Get-OfficeAppInventory {
    try {
        $installations = @(foreach ($entry in @(Get-OfficeArchitectureInventory)) {
            $ids = @($entry.ProductIds)
            $isSuite = if ($entry.Kind -eq 'ClickToRun') {
                [bool]@($ids | Where-Object { $_ -match '^(O365BusinessRetail|O365ProPlusRetail|O365HomePremRetail|HomeStudentRetail|HomeBusinessRetail|PersonalRetail|ProPlus|Standard|Professional)' }).Count
            } else { $entry.Name -match '(WINWORD|EXCEL|OUTLOOK|MSACCESS|POWERPNT)\.EXE' }
            [pscustomobject]@{
                name = $entry.Name
                architecture = $entry.Edition
                installationType = $entry.Kind
                productIds = $ids
                isSuite = [bool]$isSuite
            }
        })
        [pscustomobject]@{ Status = $(if ($installations.Count) { 'Detected' } else { 'NotDetected' }); Installations = $installations }
    } catch {
        [pscustomobject]@{ Status = 'Failed'; Installations = @() }
    }
}

function Get-OfficeExportSummary {
    param($Export)
    if ($Export.officeDetectionStatus -eq 'Failed') { return 'Office: detection failed; verify before installing.' }
    $editions = @($Export.officeInstallations | Where-Object { $_ } | ForEach-Object { if ($_.architecture -in @('32', '64')) { "$($_.architecture)-bit" } else { 'bitness unknown' } } | Select-Object -Unique)
    if ($editions.Count) { return "Office detected: $($editions -join ', ')." }
    return 'Office: none detected.'
}

function New-InstalledAppsExport {
    param([string[]]$WingetIds = @(), [string[]]$ProgramNames = @())
    $office = Get-OfficeAppInventory
    [pscustomobject]@{
        hostname = $env:COMPUTERNAME
        exportedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        wingetIds = @($WingetIds)
        installedProgramNames = @($ProgramNames)
        officeDetectionStatus = $office.Status
        officeInstallations = @($office.Installations)
    }
}

# Same column-position technique as Gr3ysUtilities.ps1's Get-WingetListedIds - reads
# straight from captured `winget list` lines instead of a redirected log file, since
# there's no GUI runspace here needing the output on disk.
function Get-WingetListedIds {
    param([string[]]$Lines)
    $ids = New-Object 'System.Collections.Generic.HashSet[string]'
    if (-not $Lines) { return $ids }
    $headerIndex = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^Name\s+Id\s+Version') { $headerIndex = $i; break }
    }
    if ($headerIndex -lt 0 -or $headerIndex + 1 -ge $Lines.Count) { return $ids }
    $header = $Lines[$headerIndex]
    $idCol = $header.IndexOf('Id')
    $versionCol = $header.IndexOf('Version')
    if ($idCol -lt 0 -or $versionCol -lt 0 -or $versionCol -le $idCol) { return $ids }
    for ($i = $headerIndex + 2; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if (-not $line -or $line.Length -le $idCol) { continue }
        if ($line -match '^\d+ package') { continue }
        $endCol = [Math]::Min($versionCol, $line.Length)
        $id = $line.Substring($idCol, $endCol - $idCol).Trim()
        if ($id) { [void]$ids.Add($id) }
    }
    return $ids
}

$wingetLines = $null
try {
    $wingetLines = & winget.exe list --source winget --accept-source-agreements --disable-interactivity 2>$null
} catch {
    Write-Warning "winget list failed or winget isn't available - wingetIds will be empty ($($_.Exception.Message))."
}

$export = New-InstalledAppsExport -WingetIds @(Get-WingetListedIds -Lines $wingetLines) -ProgramNames @(Get-UninstallEntries | Select-Object -ExpandProperty DisplayName -Unique | Sort-Object)

if ($Code) {
    if ($RelayUrl -match 'REPLACE-WITH-YOUR-WORKER-URL') {
        Write-Error "This copy of Export-InstalledApps.ps1 has no relay configured yet (RelayUrl is still the placeholder). Deploy cloudflare/export-relay-worker.js and update RelayUrl's default, or pass -RelayUrl explicitly."
        return
    }
    $body = $export | ConvertTo-Json -Depth 4
    # The relay only takes an export for a code the app has actually opened (with its access
    # code). A freshly opened code can take up to a minute (or more) to be visible from
    # wherever this machine reaches Cloudflare, and KV also caches "not found", so a 404 - or
    # a transient connection/5xx error - is retried for a while before giving up; it usually
    # just means "not yet". charset=utf-8 so Windows PowerShell 5.1 doesn't send non-ASCII
    # program names as ISO-8859-1.
    $deadline = (Get-Date).AddSeconds(120)
    $announcedRetry = $false
    $sendOk = $false
    while ($true) {
        try {
            Invoke-RestMethod -Uri "$RelayUrl/submit?code=$Code" -Method Post -ContentType 'application/json; charset=utf-8' `
                -Body $body -TimeoutSec 30 -ErrorAction Stop | Out-Null
            Write-Output "Sent to pairing code $Code - check the Pair with Old Machine dialog on the other machine."
            $sendOk = $true
            break
        } catch {
            $err = $_
            $status = 0
            try { $status = [int]$err.Exception.Response.StatusCode } catch {}
            # 404 = code not open yet; 0 = no HTTP response (DNS/TLS/connect/timeout); 429/5xx
            # = transient. All are worth retrying until the deadline.
            $transient = ($status -eq 404) -or ($status -eq 0) -or ($status -eq 429) -or ($status -ge 500 -and $status -le 599)
            if ($transient -and (Get-Date) -lt $deadline) {
                if (-not $announcedRetry) {
                    Write-Output "Pairing code $Code isn't ready yet - retrying for up to 2 minutes..."
                    $announcedRetry = $true
                }
                Start-Sleep -Seconds 10
                continue
            }
            $reason = switch ($status) {
                404 { "nothing is waiting for that code. Check it matches the Pair with Old Machine dialog exactly, and that the dialog is still open." }
                409 { "something was already sent for that code. Generate a new code and try again." }
                503 { "the relay is temporarily unavailable. Try again in a few minutes." }
                default { $err.Exception.Message }
            }
            Write-Error "Could not send to pairing code $Code - $reason"
            break
        }
    }
    # An RMM runs this with -File; Write-Error alone leaves the exit code 0, so a failed send
    # would look like success. $PSCommandPath is set only for a file run (empty for irm|iex and
    # & ([scriptblock]::Create(...))), so this doesn't close an interactive session.
    if (-not $sendOk -and $PSCommandPath) { exit 1 }
} elseif ($OutputPath) {
    # Set-Content fails if the target directory doesn't exist yet (e.g. a fresh machine
    # with no C:\Temp) - that's a non-terminating error by default, so without -ErrorAction
    # Stop the script would print a false "Saved" success message right after a real
    # failure. Create the directory first, and only claim success if the write actually
    # happens.
    $outputDir = Split-Path -Path $OutputPath -Parent
    if ($outputDir -and -not (Test-Path -Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    try {
        ($export | ConvertTo-Json -Depth 4) | Set-Content -Path $OutputPath -Encoding UTF8 -ErrorAction Stop
        Write-Output "Saved $($export.wingetIds.Count) winget app(s) and $($export.installedProgramNames.Count) program name(s) to $OutputPath"
        Write-Output (Get-OfficeExportSummary -Export $export)
    } catch {
        Write-Error "Could not save to $OutputPath - $($_.Exception.Message)"
        # Non-zero exit for an RMM -File run (see the -Code branch note).
        if ($PSCommandPath) { exit 1 }
    }
} else {
    # Not -OutputPath | Format-List or just `$export` - either lets PowerShell's default
    # table/list formatter decide how to show this, which truncates array properties
    # (wingetIds, installedProgramNames) to a handful of entries plus "..." and clips wide
    # columns to the console width. The whole point of this no-OutputPath path is "print
    # something capturable" (see the GUI's own No GUI Access dialog text) - full JSON text
    # is what's actually copyable and re-saveable as the .json Compare Against List reads,
    # not a truncated table meant for human skimming.
    $export | ConvertTo-Json -Depth 4
}
