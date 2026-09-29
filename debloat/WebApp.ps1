<#
.SYNOPSIS
    Local web control panel for Deploy-DellOfficeSetup.ps1 - start/stop the deploy job,
    watch live progress and CPU activity, and reboot when done, from a browser tab
    instead of babysitting a PowerShell console.

.DESCRIPTION
    Runs a small local-only web server (http://localhost:8787/) that:
      - Lets you pick DryRun / SkipDebloat / SkipOfficeRemoval / SkipOfficeInstall /
        OfficeChannel and click Start, instead of typing a PowerShell command line.
      - Launches Deploy-DellOfficeSetup.ps1 (must be in the same folder) as a child
        process and streams its log output live into the page.
      - Reports whether the job is actually still working (aggregate CPU time across
        the whole process tree - the deploy script itself plus setup.exe/msiexec/
        OfficeClickToRun children) so "is it stuck?" has a real answer on screen
        instead of needing manual Get-Process checks.
      - Shows a Reboot Now button once the run finishes successfully.

    Only reachable from this machine (binds to localhost only). Close this window to
    stop the web app; a deploy job already running keeps going independently of it.

.NOTES
    Run elevated (same requirement as Deploy-DellOfficeSetup.ps1). Use Run-WebApp.bat
    to launch this without typing anything.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [int]$Port = 8787
)

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$deployScript = Join-Path $scriptDir 'Deploy-DellOfficeSetup.ps1'
$workDir = Join-Path $env:ProgramData 'DellOfficeDeploy'
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

if (-not (Test-Path $deployScript)) {
    Write-Host "ERROR: Deploy-DellOfficeSetup.ps1 not found next to this script at $deployScript" -ForegroundColor Red
    Write-Host "Place WebApp.ps1 in the same folder as Deploy-DellOfficeSetup.ps1 and try again."
    Read-Host 'Press Enter to close'
    exit 1
}

$script:proc = $null
$script:logFile = $null
$script:errFile = $null
$script:startTime = $null
$script:hasRun = $false

function Get-SafeFileNamePart {
    param([string]$Value)
    if (-not $Value) { return 'Unknown' }
    $clean = ($Value -replace '[\\/:*?"<>|]', '') -replace '\s+', '-'
    $clean = $clean.Trim('-')
    if (-not $clean) { return 'Unknown' }
    return $clean
}

function Get-MachineTag {
    # Same identifying tag Deploy-DellOfficeSetup.ps1 bakes into its own log filename,
    # computed independently here so downloaded logs are named consistently even if
    # $script:logFile is the web app's own redirect file rather than the deploy
    # script's transcript.
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $mfr = if ($cs -and $cs.Manufacturer) { $cs.Manufacturer } else { 'UnknownMfr' }
    $model = if ($cs -and $cs.Model) { $cs.Model } else { 'UnknownModel' }
    $serial = if ($bios -and $bios.SerialNumber) { $bios.SerialNumber } else { 'UnknownSerial' }
    return "{0}_{1}-{2}_{3}" -f `
        (Get-SafeFileNamePart $env:COMPUTERNAME), `
        (Get-SafeFileNamePart $mfr), `
        (Get-SafeFileNamePart $model), `
        (Get-SafeFileNamePart $serial)
}

function Get-DescendantProcessIds {
    param([int]$RootId)
    $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId
    $result = New-Object System.Collections.Generic.List[int]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($RootId)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $result.Add($current)
        foreach ($p in ($all | Where-Object { $_.ParentProcessId -eq $current })) {
            $queue.Enqueue([int]$p.ProcessId)
        }
    }
    return $result
}

function Get-TreeCpuSeconds {
    param([int]$RootId)
    $ids = Get-DescendantProcessIds -RootId $RootId
    $total = 0.0
    foreach ($id in $ids) {
        try {
            $p = Get-Process -Id $id -ErrorAction Stop
            $total += $p.TotalProcessorTime.TotalSeconds
        } catch {}
    }
    return [math]::Round($total, 1)
}

function Get-LogTail {
    param([string]$Path, [long]$Offset)
    if (-not $Path -or -not (Test-Path $Path)) { return @{ offset = 0; text = '' } }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $len = $fs.Length
        if ($Offset -ge $len) { return @{ offset = $len; text = '' } }
        if ($Offset -lt 0) { $Offset = 0 }
        $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $bytesToRead = [int]($len - $Offset)
        $buffer = New-Object byte[] $bytesToRead
        $fs.Read($buffer, 0, $bytesToRead) | Out-Null
        $text = [System.Text.Encoding]::UTF8.GetString($buffer)
        return @{ offset = $len; text = $text }
    } finally {
        $fs.Close()
    }
}

function Get-LogSummary {
    # Reads the deploy script's own log once and derives both the current phase and
    # whether it actually finished. "Run complete." is the script's own final line on
    # a normal finish - a much more trustworthy success signal than the child process's
    # exit code, which has proven unreliable to read back through this launch chain
    # (nested Start-Process, redirected output) during testing.
    param([string]$LogPath)
    $result = @{ phase = 'Idle'; completed = $false }
    if (-not $LogPath -or -not (Test-Path $LogPath)) { return $result }
    $content = Get-Content -Path $LogPath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { $result.phase = 'Starting...'; return $result }
    $phase = 'Starting...'
    $found = [regex]::Matches($content, '--- (Phase \d: [^-]+) ---')
    if ($found.Count -gt 0) { $phase = $found[$found.Count - 1].Groups[1].Value.Trim() }
    if ($content -match 'Run complete\.') {
        $phase = 'All phases complete'
        $result.completed = $true
    }
    $result.phase = $phase
    return $result
}

function Send-Json {
    param($Response, $Object, [int]$StatusCode = 200)
    $json = $Object | ConvertTo-Json -Compress -Depth 6
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

$HtmlPage = @'
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dell/Lenovo + Office Deploy</title>
<style>
  :root {
    --bg: #0d1117; --panel: #161b22; --border: #30363d; --text: #c9d1d9;
    --muted: #8b949e; --accent: #2f81f7; --green: #3fb950; --red: #f85149; --yellow: #d29922;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text); font-family: Segoe UI, Arial, sans-serif; }
  header { padding: 16px 20px; border-bottom: 1px solid var(--border); }
  header h1 { margin: 0; font-size: 18px; }
  header p { margin: 4px 0 0; color: var(--muted); font-size: 13px; }
  main { max-width: 960px; margin: 0 auto; padding: 20px; display: grid; gap: 16px; }
  .panel { background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 16px; }
  .panel h2 { margin: 0 0 12px; font-size: 14px; color: var(--muted); text-transform: uppercase; letter-spacing: .05em; }
  .options { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 10px 16px; margin-bottom: 14px; }
  label.opt { display: flex; align-items: center; gap: 8px; font-size: 14px; cursor: pointer; }
  select { background: var(--bg); color: var(--text); border: 1px solid var(--border); border-radius: 4px; padding: 6px 8px; }
  .row { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  button { border: none; border-radius: 6px; padding: 10px 18px; font-size: 14px; cursor: pointer; font-weight: 600; }
  button:disabled { opacity: .45; cursor: not-allowed; }
  button.start { background: var(--green); color: #04220d; }
  button.stop { background: var(--red); color: #2a0a08; }
  button.reboot { background: var(--yellow); color: #241a00; }
  button.download { background: var(--accent); color: #04122a; }
  .status-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; }
  .stat { background: var(--bg); border: 1px solid var(--border); border-radius: 6px; padding: 10px 12px; }
  .stat .label { color: var(--muted); font-size: 11px; text-transform: uppercase; }
  .stat .value { font-size: 18px; margin-top: 4px; }
  .dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 8px; background: var(--muted); }
  .dot.running { background: var(--green); box-shadow: 0 0 8px var(--green); }
  .dot.stopped { background: var(--muted); }
  .dot.done { background: var(--accent); box-shadow: 0 0 8px var(--accent); }
  .dot.error { background: var(--red); box-shadow: 0 0 8px var(--red); }
  #log { background: #010409; border: 1px solid var(--border); border-radius: 6px; padding: 12px; height: 360px;
         overflow-y: auto; font-family: Consolas, monospace; font-size: 12.5px; white-space: pre-wrap; }
  .banner { padding: 10px 12px; border-radius: 6px; font-size: 14px; margin-bottom: 12px; }
  .banner.ok { background: #0f2a17; border: 1px solid var(--green); color: #7ee2a1; }
  .banner.err { background: #2a0f0f; border: 1px solid var(--red); color: #f5a3a0; }
  .hidden { display: none; }
</style>
</head>
<body>
<header>
  <h1>Dell / Lenovo Debloat + Office Deploy</h1>
  <p>Runs locally on this machine only. Close this browser tab any time - the job keeps running; reopen http://localhost:PORT/ to check back in.</p>
</header>
<main>

  <div class="panel">
    <h2>Options</h2>
    <div class="options">
      <label class="opt"><input type="checkbox" id="optDryRun"> Dry run (preview only)</label>
      <label class="opt"><input type="checkbox" id="optSkipDebloat"> Skip OEM debloat</label>
      <label class="opt"><input type="checkbox" id="optSkipOfficeRemoval"> Skip removing existing Office</label>
      <label class="opt"><input type="checkbox" id="optSkipOfficeInstall"> Skip installing Microsoft 365 Apps</label>
    </div>
    <div class="row">
      <label>Office channel:
        <select id="optChannel">
          <option value="MonthlyEnterprise" selected>MonthlyEnterprise (recommended)</option>
          <option value="Current">Current</option>
          <option value="SemiAnnual">SemiAnnual</option>
          <option value="SemiAnnualPreview">SemiAnnualPreview</option>
        </select>
      </label>
      <button class="start" id="btnStart">Start</button>
      <button class="stop hidden" id="btnStop">Stop</button>
      <button class="download hidden" id="btnDownload">Download Log</button>
      <button class="reboot hidden" id="btnReboot">Reboot Now</button>
    </div>
  </div>

  <div class="panel">
    <h2>Status</h2>
    <div id="banner"></div>
    <div class="status-grid">
      <div class="stat"><div class="label">State</div><div class="value"><span class="dot stopped" id="dot"></span><span id="stateText">Idle</span></div></div>
      <div class="stat"><div class="label">Phase</div><div class="value" id="phaseText">-</div></div>
      <div class="stat"><div class="label">Elapsed</div><div class="value" id="elapsedText">0:00</div></div>
      <div class="stat"><div class="label">CPU time (job tree)</div><div class="value" id="cpuText">0.0s</div></div>
    </div>
  </div>

  <div class="panel">
    <h2>Live Log</h2>
    <div id="log"></div>
  </div>

</main>
<script>
(function () {
  var logEl = document.getElementById('log');
  var btnStart = document.getElementById('btnStart');
  var btnStop = document.getElementById('btnStop');
  var btnDownload = document.getElementById('btnDownload');
  var btnReboot = document.getElementById('btnReboot');
  var dot = document.getElementById('dot');
  var stateText = document.getElementById('stateText');
  var phaseText = document.getElementById('phaseText');
  var elapsedText = document.getElementById('elapsedText');
  var cpuText = document.getElementById('cpuText');
  var banner = document.getElementById('banner');

  var offset = 0;
  var polling = false;
  var dryRunActive = false;
  var rebootRequested = false;

  function fmtElapsed(sec) {
    sec = sec || 0;
    var m = Math.floor(sec / 60);
    var s = Math.floor(sec % 60);
    return m + ':' + (s < 10 ? '0' : '') + s;
  }

  function setBanner(kind, text) {
    if (!text) { banner.innerHTML = ''; return; }
    banner.innerHTML = '<div class="banner ' + kind + '">' + text + '</div>';
  }

  function poll() {
    fetch('/api/poll?offset=' + offset)
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (data.log && data.log.text) {
          logEl.textContent += data.log.text;
          logEl.scrollTop = logEl.scrollHeight;
        }
        if (data.log) { offset = data.log.offset; }

        var st = data.status;
        stateText.textContent = st.running ? 'Running' : (st.hasRun ? 'Stopped' : 'Idle');
        phaseText.textContent = st.phase || '-';
        elapsedText.textContent = fmtElapsed(st.elapsedSeconds);
        cpuText.textContent = (st.cpuSeconds || 0).toFixed(1) + 's';

        dot.className = 'dot';
        if (st.running) {
          dot.classList.add('running');
        } else if (st.hasRun && st.success === true) {
          dot.classList.add('done');
        } else if (st.hasRun && st.success === false) {
          dot.classList.add('error');
        } else {
          dot.classList.add('stopped');
        }

        btnStart.disabled = st.running;
        btnStop.classList.toggle('hidden', !st.running);
        btnDownload.classList.toggle('hidden', !st.hasRun);

        if (!st.running && st.hasRun && !rebootRequested) {
          if (st.success === true) {
            if (dryRunActive) {
              setBanner('ok', 'Dry run finished. Nothing was changed. Review the log above, then run for real when ready.');
            } else {
              setBanner('ok', 'Run finished successfully. Reboot to finish clearing removed services/drivers.');
              btnReboot.classList.remove('hidden');
            }
          } else {
            var detail = st.stderr ? (' Details: ' + st.stderr) : ' Check the log above for where it stopped.';
            setBanner('err', 'The job ended before finishing.' + detail);
          }
        }
      })
      .catch(function () { /* transient - next tick will retry */ })
      .finally(function () {
        setTimeout(poll, 1500);
      });
  }

  btnStart.addEventListener('click', function () {
    dryRunActive = document.getElementById('optDryRun').checked;
    var body = {
      dryRun: dryRunActive,
      skipDebloat: document.getElementById('optSkipDebloat').checked,
      skipOfficeRemoval: document.getElementById('optSkipOfficeRemoval').checked,
      skipOfficeInstall: document.getElementById('optSkipOfficeInstall').checked,
      officeChannel: document.getElementById('optChannel').value
    };
    logEl.textContent = '';
    offset = 0;
    setBanner('', '');
    btnReboot.classList.add('hidden');
    btnStart.disabled = true;
    fetch('/api/start', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (!data.ok) {
          setBanner('err', 'Could not start: ' + (data.error || 'unknown error'));
          btnStart.disabled = false;
        }
      });
  });

  btnStop.addEventListener('click', function () {
    if (!confirm('Stop the running job? Anything mid-uninstall/install may be left partially applied.')) { return; }
    fetch('/api/stop', { method: 'POST' });
  });

  btnDownload.addEventListener('click', function () {
    window.location = '/api/download';
  });

  btnReboot.addEventListener('click', function () {
    if (!confirm('Reboot this computer now?')) { return; }
    rebootRequested = true;
    setBanner('ok', 'Rebooting now - this page will stop responding shortly.');
    btnReboot.disabled = true;
    fetch('/api/reboot', { method: 'POST' });
  });

  poll();
})();
</script>
</body>
</html>
'@

$prefix = "http://localhost:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    Write-Host "ERROR: could not bind $prefix - $($_.Exception.Message)" -ForegroundColor Red
    Read-Host 'Press Enter to close'
    exit 1
}

Write-Host "Dell/Lenovo + Office deploy control panel running at $prefix"
Write-Host "Leave this window open while you use it. Closing it stops the web app (a deploy job already running keeps going)."
Start-Process $prefix

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response
    try {
        $path = $request.Url.AbsolutePath
        $method = $request.HttpMethod

        if ($method -eq 'GET' -and $path -eq '/') {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($HtmlPage.Replace('PORT', $Port))
            $response.ContentType = 'text/html; charset=utf-8'
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        elseif ($method -eq 'POST' -and $path -eq '/api/start') {
            if ($script:proc -and -not $script:proc.HasExited) {
                Send-Json -Response $response -Object @{ ok = $false; error = 'A job is already running.' }
            } else {
                $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                $bodyText = $reader.ReadToEnd()
                $reader.Close()
                $opts = $null
                if ($bodyText) { $opts = $bodyText | ConvertFrom-Json }

                $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $deployScript, '-NoReboot')
                if ($opts.dryRun) { $argList += '-DryRun' }
                if ($opts.skipDebloat) { $argList += '-SkipDebloat' }
                if ($opts.skipOfficeRemoval) { $argList += '-SkipOfficeRemoval' }
                if ($opts.skipOfficeInstall) { $argList += '-SkipOfficeInstall' }
                if ($opts.officeChannel) { $argList += @('-OfficeChannel', [string]$opts.officeChannel) }

                $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                $script:logFile = Join-Path $workDir "webapp_run_$stamp.out.log"
                $script:errFile = Join-Path $workDir "webapp_run_$stamp.err.log"

                $script:proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
                    -RedirectStandardOutput $script:logFile -RedirectStandardError $script:errFile `
                    -WindowStyle Hidden -PassThru
                $script:startTime = Get-Date
                $script:hasRun = $true

                Send-Json -Response $response -Object @{ ok = $true }
            }
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/poll') {
            $offset = 0
            $offsetParam = $request.QueryString['offset']
            if ($offsetParam) { [long]::TryParse($offsetParam, [ref]$offset) | Out-Null }

            $logResult = Get-LogTail -Path $script:logFile -Offset $offset
            $logSummary = Get-LogSummary -LogPath $script:logFile

            # Process.ExitCode on a nested/fast-exiting child has proven unreliable to
            # read back during testing (HasExited/ExitCode access can silently fail).
            # It's kept here only as extra diagnostic info - the real success/failure
            # signal is whether the log reached its own "Run complete." line, computed
            # below, since non-terminating errors along the way (ErrorActionPreference
            # = Continue) can otherwise make a genuinely successful run look failed.
            $running = $false
            $hasExited = $null
            $exitCode = $null
            $cpuSeconds = 0.0
            $childPid = $null
            if ($script:proc) {
                $childPid = $script:proc.Id
                try {
                    $script:proc.Refresh()
                    $hasExited = $script:proc.HasExited
                    if ($hasExited) {
                        try { $exitCode = $script:proc.ExitCode } catch { $exitCode = $null }
                    } else {
                        $running = $true
                        $cpuSeconds = Get-TreeCpuSeconds -RootId $childPid
                    }
                } catch { $hasExited = $true }
            }

            $stderrText = ''
            if ($script:errFile -and (Test-Path $script:errFile)) {
                $stderrText = (Get-Content -Path $script:errFile -Raw -ErrorAction SilentlyContinue)
                if ($stderrText) { $stderrText = $stderrText.Trim() }
            }

            # success: $true (log shows it finished), $false (job ended without ever
            # reaching "Run complete."), $null (still running / never started).
            $success = $null
            if (-not $running -and $script:hasRun) {
                $success = $logSummary.completed
            }

            $elapsed = 0
            if ($script:startTime) { $elapsed = [math]::Round(((Get-Date) - $script:startTime).TotalSeconds, 0) }

            $statusObj = [ordered]@{
                running        = $running
                hasRun         = $script:hasRun
                pid            = $childPid
                exitCode       = $exitCode
                success        = $success
                cpuSeconds     = $cpuSeconds
                phase          = $logSummary.phase
                elapsedSeconds = $elapsed
                stderr         = $stderrText
            }

            Send-Json -Response $response -Object @{ status = $statusObj; log = $logResult }
        }
        elseif ($method -eq 'POST' -and $path -eq '/api/stop') {
            if ($script:proc -and -not $script:proc.HasExited) {
                $ids = Get-DescendantProcessIds -RootId $script:proc.Id
                foreach ($id in $ids) {
                    try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch { }
                }
            }
            Send-Json -Response $response -Object @{ ok = $true }
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/download') {
            if (-not $script:logFile -or -not (Test-Path $script:logFile)) {
                $response.StatusCode = 404
            } else {
                $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                $fileName = "gr3ytools-debloat_$($stamp)_$(Get-MachineTag).log"
                $bytes = [System.IO.File]::ReadAllBytes($script:logFile)
                $response.ContentType = 'text/plain; charset=utf-8'
                $response.AddHeader('Content-Disposition', "attachment; filename=""$fileName""")
                $response.ContentLength64 = $bytes.Length
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
        }
        elseif ($method -eq 'POST' -and $path -eq '/api/reboot') {
            Send-Json -Response $response -Object @{ ok = $true }
            try { $response.OutputStream.Close() } catch { }
            Start-Sleep -Seconds 1
            Restart-Computer -Force
        }
        else {
            $response.StatusCode = 404
        }
    } catch {
        try {
            $response.StatusCode = 500
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($_.Exception.Message)
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        } catch { }
    } finally {
        try { $response.OutputStream.Close() } catch { }
    }
}
