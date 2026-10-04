<#
.SYNOPSIS
    Live end-to-end test of the access-gated pairing relay. Run by the owner AFTER the new
    Worker is deployed. Never prints the admin key, sessions, or full guest codes, so its
    output is safe to paste into a chat.

.DESCRIPTION
    Walks the whole flow against the real relay: version probe, admin auth, guest-code
    create/open/switch-off/switch-on/delete, a real Export-InstalledApps.ps1 -Code run, and
    measures real Cloudflare KV propagation delays (which the in-memory test harness cannot).
    Always deletes the throwaway guest code it creates, even on failure.

    The admin key comes from $env:GR3Y_RELAY_ADMIN_KEY, or a hidden prompt. It is never
    echoed. KV cost per run is roughly 8 writes and ~60 reads of the free daily budget.
    Do not run quota-exhaustion tests against production.

.PARAMETER RelayUrl
    Base URL of the relay. Defaults to the deployed one.

.PARAMETER ExportScript
    Path to Export-InstalledApps.ps1. If omitted, the script is downloaded from
    https://get.gr3y.io/debloat-export (what a real old machine would run). Pass a local path
    to test a build before it is merged to main.

.PARAMETER PollTimeoutSeconds
    How long to wait for the exported data to appear (real KV delay can be a minute or more).

.EXAMPLE
    $env:GR3Y_RELAY_ADMIN_KEY = '<admin key>'   # or just run it and answer the hidden prompt
    .\tests\Test-RelayLive.ps1
#>
[CmdletBinding()]
param(
    [string]$RelayUrl = 'https://gr3y-export-relay.gr3y-b8f.workers.dev',
    [string]$ExportScript,
    [int]$PollTimeoutSeconds = 150
)

$ErrorActionPreference = 'Stop'
$script:pass = 0
$script:fail = 0
$script:createdGuest = $null
$script:openSlots = @()   # @{Code;Session} to close in finally
$script:adminKey = $null

function Write-Result([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++ } else { $script:fail++ }
    $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
    $line = "[$tag] $Name"
    if ($Detail) { $line += " - $Detail" }
    Write-Output $line
}

# Mask a guest code like ABCD-EFGH-JKMN as ABCD-****-**** so output stays shareable.
function Hide-Code([string]$Code) {
    if (-not $Code) { return '' }
    $parts = $Code -split '-'
    if ($parts.Count -ge 2) { return ($parts[0] + '-' + (($parts[1..($parts.Count - 1)] | ForEach-Object { '****' }) -join '-')) }
    return ($Code.Substring(0, [Math]::Min(4, $Code.Length)) + '****')
}

# One HTTP call -> @{Status; Text}. Status 0 = no HTTP response. Works in 5.1 and 7.
function Invoke-Relay([string]$Method, [string]$Path, [hashtable]$Headers = @{}, [int]$TimeoutSec = 20) {
    try {
        $r = Invoke-WebRequest -Uri "$RelayUrl$Path" -Method $Method -Headers $Headers -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        $ms = New-Object System.IO.MemoryStream
        $r.RawContentStream.CopyTo($ms)
        return @{ Status = [int]$r.StatusCode; Text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray()) }
    } catch {
        $s = 0
        try { $s = [int]$_.Exception.Response.StatusCode } catch {}
        return @{ Status = $s; Text = $null }
    }
}

function New-TestCode {
    # 6 chars from the same unambiguous alphabet the app uses.
    $alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $out = New-Object System.Text.StringBuilder
    $buf = New-Object byte[] 12
    while ($out.Length -lt 6) {
        $rng.GetBytes($buf)
        foreach ($b in $buf) { if ($b -lt 248 -and $out.Length -lt 6) { [void]$out.Append($alphabet[$b % 31]) } }
    }
    $out.ToString()
}

# Poll until a status condition holds or the timeout passes. Returns elapsed seconds, or -1.
function Wait-ForStatus([scriptblock]$Probe, [int]$Expected, [int]$TimeoutSec, [int]$IntervalSec = 5) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $s = & $Probe
        if ($s -eq $Expected) { return [int][Math]::Round($sw.Elapsed.TotalSeconds) }
        Start-Sleep -Seconds $IntervalSec
    }
    return -1
}

# Resolve the admin key without ever echoing it.
$script:adminKey = $env:GR3Y_RELAY_ADMIN_KEY
if ([string]::IsNullOrWhiteSpace($script:adminKey)) {
    $secure = Read-Host -Prompt 'Admin key (hidden)' -AsSecureString
    $script:adminKey = [System.Net.NetworkCredential]::new('', $secure).Password
}
$script:adminKey = $script:adminKey.Trim()
if ($script:adminKey.Length -lt 16) {
    Write-Output '[FAIL] Admin key is missing or shorter than 16 characters.'
    exit 2
}
$adminHdr = @{ 'X-Access-Key' = $script:adminKey }

Write-Output "Live relay test against $RelayUrl"
Write-Output '(output never contains the admin key, sessions, or full guest codes)'
Write-Output ''

$exportPath = $null
$tempDownloaded = $false
try {
    # (a) version probe: the gated Worker answers 401 (no key); 503 = deployed but ADMIN_KEY unset/short.
    $r = Invoke-Relay 'GET' '/admin/keys'
    $detail = "HTTP $($r.Status)"
    if ($r.Status -eq 400) { $detail += ' (this is the OLD ungated Worker - deploy the new one first)' }
    if ($r.Status -eq 503) { $detail += ' (new Worker deployed but the ADMIN_KEY secret is missing/short)' }
    Write-Result '(a) no-key /admin/keys -> 401 (gated Worker live)' ($r.Status -eq 401) $detail
    if ($r.Status -ne 401) { throw 'The gated Worker is not live; stopping.' }

    # (b) wrong key -> 401
    $r = Invoke-Relay 'GET' '/admin/keys' @{ 'X-Access-Key' = 'definitely-not-the-admin-key-123' }
    Write-Result '(b) wrong admin key -> 401' ($r.Status -eq 401) "HTTP $($r.Status)"

    # (c) admin key -> 200 JSON array (proves ADMIN_KEY is bound and >= 16 chars)
    $r = Invoke-Relay 'GET' '/admin/keys' $adminHdr
    $isArray = $false
    if ($r.Status -eq 200) { try { $null = $r.Text | ConvertFrom-Json -ErrorAction Stop; $isArray = $true } catch {} }
    Write-Result '(c) admin key -> 200 list' ($r.Status -eq 200 -and $isArray) "HTTP $($r.Status)"
    if ($r.Status -ne 200) { throw 'Admin key was not accepted; stopping. Check it matches the ADMIN_KEY secret exactly.' }

    # (d) create a throwaway guest code
    $label = 'e2e-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $r = Invoke-Relay 'POST' ("/admin/keys?label=" + [uri]::EscapeDataString($label)) $adminHdr
    $guest = $null
    if ($r.Status -eq 200) { try { $guest = ($r.Text | ConvertFrom-Json -ErrorAction Stop).key } catch {} }
    $fmtOk = [bool]($guest -and $guest -cmatch '^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$')
    Write-Result '(d) create guest code' ($r.Status -eq 200 -and $fmtOk) "label=$label code=$(Hide-Code $guest)"
    if (-not $fmtOk) { throw 'Could not create a guest code; stopping.' }
    $script:createdGuest = $guest
    $guestBare = $guest -replace '-', ''
    $guestHdr = @{ 'X-Access-Key' = $guest }

    # (e) /open with the guest; same code again -> 409; anonymous /submit to an unopened code -> 404
    $code = New-TestCode
    $r = Invoke-Relay 'POST' "/open?code=$code" $guestHdr
    $session = $null; $gotLabel = $null
    if ($r.Status -eq 200) { try { $o = $r.Text | ConvertFrom-Json -ErrorAction Stop; $session = $o.session; $gotLabel = $o.label } catch {} }
    Write-Result '(e1) /open with guest code' ($r.Status -eq 200 -and $session -and $gotLabel -eq $label) "HTTP $($r.Status) label=$gotLabel"
    if (-not $session) { throw 'Could not open a pairing slot; stopping.' }
    $script:openSlots += @{ Code = $code; Session = $session }

    $r = Invoke-Relay 'POST' "/open?code=$code" $adminHdr
    Write-Result '(e2) same code opened again -> 409' ($r.Status -eq 409) "HTTP $($r.Status)"

    $unopened = New-TestCode
    $r = Invoke-Relay 'POST' "/submit?code=$unopened"
    Write-Result '(e3) anonymous /submit to an unopened code -> 404 (or 400 for empty body)' ($r.Status -eq 404 -or $r.Status -eq 400) "HTTP $($r.Status)"

    # (f) real export through the public path, then time how long until /poll returns it.
    if ($ExportScript) {
        $exportPath = $ExportScript
    } else {
        $exportPath = Join-Path ([System.IO.Path]::GetTempPath()) ("Export-InstalledApps-live-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1")
        try {
            Invoke-WebRequest -Uri 'https://get.gr3y.io/debloat-export' -OutFile $exportPath -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            $tempDownloaded = $true
        } catch { $exportPath = $null }
    }
    if (-not $exportPath -or -not (Test-Path -LiteralPath $exportPath)) {
        Write-Output '[SKIP] (f) export run - could not obtain Export-InstalledApps.ps1 (pass -ExportScript <path>)'
    } else {
        $exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $exportPath -Code $code -RelayUrl $RelayUrl 2>&1
        $exit = $LASTEXITCODE
        $sendSecs = [int][Math]::Round($sw.Elapsed.TotalSeconds)
        $sent = ($out | Out-String) -match 'Sent to pairing code'
        Write-Result '(f1) Export-InstalledApps.ps1 -Code reports Sent' ($sent -and $exit -eq 0) "exit=$exit, took ${sendSecs}s (includes any retry for KV propagation)"

        # a bogus session must not be able to read it: 401 once an export exists (404 if not visible yet)
        $r = Invoke-Relay 'GET' "/poll?code=$code" @{ 'X-Session' = 'not-the-session' }
        Write-Result '(f2) bogus session cannot read the export' ($r.Status -eq 401 -or $r.Status -eq 404) "HTTP $($r.Status) (401 expected once the export is visible)"

        # real poll: time until the data shows up
        $pollSw = [System.Diagnostics.Stopwatch]::StartNew()
        $data = $null
        while ($pollSw.Elapsed.TotalSeconds -lt $PollTimeoutSeconds) {
            $r = Invoke-Relay 'GET' "/poll?code=$code" @{ 'X-Session' = $session } 20
            if ($r.Status -eq 200) { try { $data = $r.Text | ConvertFrom-Json -ErrorAction Stop } catch {}; break }
            Start-Sleep -Seconds 3
        }
        $pollSecs = [int][Math]::Round($pollSw.Elapsed.TotalSeconds)
        $shapeOk = [bool]($data -and ($data.PSObject.Properties.Name -contains 'hostname') -and ($data.PSObject.Properties.Name -contains 'installedProgramNames'))
        Write-Result '(f3) poll with the real session returns the export' $shapeOk "data visible after ${pollSecs}s of polling (real KV propagation)"
        if ($shapeOk) { $script:openSlots = @($script:openSlots | Where-Object { $_.Code -ne $code }) }

        # (g) second submit refused; second poll finds nothing
        $r = Invoke-Relay 'POST' "/submit?code=$code"
        Write-Result '(g1) second submit is refused (404/409/400)' ($r.Status -in 404, 409, 400) "HTTP $($r.Status) (record which)"
        $r = Invoke-Relay 'GET' "/poll?code=$code" @{ 'X-Session' = $session }
        Write-Result '(g2) second poll finds nothing (404)' ($r.Status -eq 404) "HTTP $($r.Status)"
    }

    # (h) switch the guest off and time how long until /open is refused; then on; then delete.
    $r = Invoke-Relay 'POST' "/admin/keys/$guestBare/disable" $adminHdr
    Write-Result '(h1) disable guest code' ($r.Status -eq 200) "HTTP $($r.Status)"
    $probeOff = { $c = New-TestCode; $x = Invoke-Relay 'POST' "/open?code=$c" $guestHdr; if ($x.Status -eq 200) { try { $sx = ($x.Text | ConvertFrom-Json).session; $script:openSlots += @{ Code = $c; Session = $sx } } catch {} }; $x.Status }
    $offSecs = Wait-ForStatus $probeOff 401 90 5
    Write-Result '(h2) switched-off guest is refused' ($offSecs -ge 0) $(if ($offSecs -ge 0) { "took ${offSecs}s to take effect" } else { 'still accepted after 90s' })

    $r = Invoke-Relay 'POST' "/admin/keys/$guestBare/enable" $adminHdr
    Write-Result '(h3) enable guest code' ($r.Status -eq 200) "HTTP $($r.Status)"
    $probeOn = { $c = New-TestCode; $x = Invoke-Relay 'POST' "/open?code=$c" $guestHdr; if ($x.Status -eq 200) { try { $sx = ($x.Text | ConvertFrom-Json).session; $script:openSlots += @{ Code = $c; Session = $sx } } catch {} }; $x.Status }
    $onSecs = Wait-ForStatus $probeOn 200 90 5
    Write-Result '(h4) re-enabled guest is accepted' ($onSecs -ge 0) $(if ($onSecs -ge 0) { "took ${onSecs}s to take effect" } else { 'still refused after 90s' })

    $r = Invoke-Relay 'DELETE' "/admin/keys/$guestBare" $adminHdr
    Write-Result '(h5) delete guest code' ($r.Status -eq 200) "HTTP $($r.Status)"
    $script:createdGuest = $null   # deleted on purpose; nothing left for finally to clean
    $delSecs = Wait-ForStatus $probeOff 401 90 5
    Write-Result '(h6) deleted guest is refused' ($delSecs -ge 0) $(if ($delSecs -ge 0) { "took ${delSecs}s" } else { 'still accepted after 90s' })
    $r = Invoke-Relay 'GET' '/admin/keys' $adminHdr
    $stillListed = $false
    if ($r.Status -eq 200) { try { $stillListed = [bool](@($r.Text | ConvertFrom-Json) | Where-Object { $_.label -eq $label }) } catch {} }
    Write-Result '(h7) deleted guest is gone from the list' (-not $stillListed) $(if ($stillListed) { 'still listed (list may lag up to ~60s)' } else { '' })
} catch {
    Write-Output "[ABORT] $($_.Exception.Message)"
    $script:fail++
} finally {
    # Always clean up the throwaway guest and any slots we opened, even after a failure.
    foreach ($s in $script:openSlots) {
        try { $null = Invoke-Relay 'POST' "/close?code=$($s.Code)" @{ 'X-Session' = $s.Session } 10 } catch {}
    }
    if ($script:createdGuest) {
        $bare = $script:createdGuest -replace '-', ''
        $r = Invoke-Relay 'DELETE' "/admin/keys/$bare" @{ 'X-Access-Key' = $script:adminKey }
        Write-Output "[CLEANUP] deleted throwaway guest code $(Hide-Code $script:createdGuest) (HTTP $($r.Status))"
    }
    if ($tempDownloaded -and $exportPath) { Remove-Item -LiteralPath $exportPath -ErrorAction SilentlyContinue }
    $script:adminKey = $null
}

Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
