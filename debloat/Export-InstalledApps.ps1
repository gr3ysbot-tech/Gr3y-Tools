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
#>

[CmdletBinding()]
param(
    [string]$OutputPath
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

if ($OutputPath) {
    ($export | ConvertTo-Json -Depth 4) | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Output "Saved $($export.wingetIds.Count) winget app(s) and $($export.installedProgramNames.Count) program name(s) to $OutputPath"
} else {
    $export
}
