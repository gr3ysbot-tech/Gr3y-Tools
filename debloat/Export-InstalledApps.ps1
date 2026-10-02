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
    (hostname, exportedAt, wingetIds, installedProgramNames), built from a `winget list`
    and a registry Uninstall-key scan - both read-only, no admin rights required.

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
    Optional. A pairing code shown by Gr3ysUtilities.ps1's "Pair with Old Machine..."
    dialog (Compare Against List...). Sends the export straight to that running app
    instance via a short-lived Cloudflare Worker relay instead of printing it or saving a
    file - nothing to copy-paste or transfer by hand. Takes priority over -OutputPath if
    both are given. The code is one-time and expires in 10 minutes - if nothing is
    actively polling for it (the GUI isn't open to that dialog), the export goes nowhere
    and isn't retried.

.PARAMETER RelayUrl
    Base URL of the pairing relay Worker. Defaults to the deployed Gr3y Tools relay -
    only override this if you're running your own (see cloudflare/README.md).
#>

[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$Code,
    # PLACEHOLDER - update once the Worker in cloudflare/export-relay-worker.js is
    # deployed (see cloudflare/README.md) and its real *.workers.dev URL is known. Left
    # obviously fake on purpose rather than a guessed-but-plausible URL, so -Code fails
    # loudly instead of silently posting to a made-up endpoint.
    [string]$RelayUrl = 'https://REPLACE-WITH-YOUR-WORKER-URL.workers.dev'
)

function Get-UninstallEntries {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
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

$export = [PSCustomObject]@{
    hostname              = $env:COMPUTERNAME
    exportedAt            = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    wingetIds             = @(Get-WingetListedIds -Lines $wingetLines)
    installedProgramNames = @(Get-UninstallEntries | Select-Object -ExpandProperty DisplayName -Unique | Sort-Object)
}

if ($Code) {
    if ($RelayUrl -match 'REPLACE-WITH-YOUR-WORKER-URL') {
        Write-Error "This copy of Export-InstalledApps.ps1 has no relay configured yet (RelayUrl is still the placeholder). Deploy cloudflare/export-relay-worker.js and update RelayUrl's default, or pass -RelayUrl explicitly."
        return
    }
    try {
        Invoke-RestMethod -Uri "$RelayUrl/submit?code=$Code" -Method Post -ContentType 'application/json' `
            -Body ($export | ConvertTo-Json -Depth 4) -ErrorAction Stop | Out-Null
        Write-Output "Sent to pairing code $Code - check the Pair with Old Machine... dialog on the other machine. (One-time use - if that dialog isn't open and waiting, this export goes nowhere.)"
    } catch {
        Write-Error "Could not send to pairing code $Code - $($_.Exception.Message)"
    }
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
    } catch {
        Write-Error "Could not save to $OutputPath - $($_.Exception.Message)"
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
