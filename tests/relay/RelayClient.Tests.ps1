# Pester tests for the GUI's relay-client functions, extracted from Gr3ysUtilities.ps1 with
# the repo's own Get-FunctionSource helper and exercised against the Node harness relay.
# Skips entirely when Node is not available (e.g. a runner without it). ASCII only.

BeforeDiscovery {
    $script:nodeAvailable = [bool](Get-Command node -ErrorAction SilentlyContinue)
}

Describe 'Relay client functions' -Skip:(-not $nodeAvailable) {
    BeforeAll {
        $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $gui = Join-Path $repo 'debloat/Gr3ysUtilities.ps1'
        $harness = Join-Path $repo 'tests/relay/harness.mjs'
        $script:harnessPath = $harness
        $worker = Join-Path $repo 'cloudflare/export-relay-worker.js'
        . (Join-Path $repo 'tests/TestHelpers.ps1')
        foreach ($fn in 'New-PairingCode', 'Invoke-RelayRequest', 'Test-RelayGated', 'Start-RelayPairing', 'Wait-RelayExport') {
            . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $gui -FunctionName $fn)))
        }
        $script:RelayOutdatedText = 'relay not updated'

        # A free loopback port.
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
        $script:relay = "http://127.0.0.1:$port"
        $script:logFile = Join-Path ([System.IO.Path]::GetTempPath()) "relaytest-$port.log"
        $script:node = Start-Process -FilePath 'node' -ArgumentList @($harness, 'serve', "$port", $worker) `
            -PassThru -RedirectStandardOutput $script:logFile -RedirectStandardError "$script:logFile.err" -WindowStyle Hidden
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 300
            $m = [regex]::Match((Get-Content $script:logFile -Raw -ErrorAction SilentlyContinue), 'admin=(\S+)')
            if ($m.Success) { $script:admin = $m.Groups[1].Value; break }
        }
        if (-not $script:admin) { throw 'harness relay did not start' }
    }

    AfterAll {
        if ($script:node -and -not $script:node.HasExited) { Stop-Process -Id $script:node.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item $script:logFile, "$script:logFile.err" -ErrorAction SilentlyContinue
    }

    It 'New-PairingCode makes a 6-char code in the unambiguous alphabet' {
        New-PairingCode | Should -MatchExactly '^[A-HJ-NP-Z2-9]{6}$'
    }

    It 'Test-RelayGated reports the gated Worker' {
        Test-RelayGated -RelayUrl $script:relay | Should -BeTrue
    }

    It 'Start-RelayPairing opens a slot with the admin key' {
        $p = Start-RelayPairing -RelayUrl $script:relay -AccessKey $script:admin
        $p.Ok | Should -BeTrue
        $p.Code | Should -MatchExactly '^[A-HJ-NP-Z2-9]{6}$'
        $p.Session.Length | Should -Be 36
        $p.Label | Should -Be 'admin'
    }

    It 'Start-RelayPairing rejects a wrong key as auth' {
        $p = Start-RelayPairing -RelayUrl $script:relay -AccessKey 'wrong-key-value'
        $p.Ok | Should -BeFalse
        $p.Failure | Should -Be 'auth'
    }

    It 'Start-RelayPairing works with an admin-created guest code' {
        $r = Invoke-RelayRequest -RelayUrl $script:relay -Method 'POST' -Path '/admin/keys?label=pester' -Headers @{ 'X-Access-Key' = $script:admin }
        $guest = ($r.Text | ConvertFrom-Json).key
        $p = Start-RelayPairing -RelayUrl $script:relay -AccessKey $guest
        $p.Ok | Should -BeTrue
        $p.Label | Should -Be 'pester'
    }

    It 'Wait-RelayExport returns the submitted export with non-ASCII intact' {
        $p = Start-RelayPairing -RelayUrl $script:relay -AccessKey $script:admin
        $nm = 'Caf' + [char]0xE9 + ' ' + [char]0x65E5
        $body = [pscustomobject]@{ hostname = 'OLDPC'; wingetIds = @('A.B'); installedProgramNames = @($nm) } | ConvertTo-Json
        Invoke-RestMethod -Uri "$($script:relay)/submit?code=$($p.Code)" -Method Post -ContentType 'application/json; charset=utf-8' -Body $body | Out-Null
        $got = Wait-RelayExport -RelayUrl $script:relay -Code $p.Code -Session $p.Session -TimeoutSeconds 8 -IntervalSeconds 1
        $got.Kind | Should -Be 'data'
        $got.Data.hostname | Should -Be 'OLDPC'
        @($got.Data.installedProgramNames)[0] | Should -BeExactly $nm
    }

    It 'Wait-RelayExport stops on a wrong session' {
        $p = Start-RelayPairing -RelayUrl $script:relay -AccessKey $script:admin
        Invoke-RestMethod -Uri "$($script:relay)/submit?code=$($p.Code)" -Method Post -ContentType 'application/json; charset=utf-8' -Body '{"hostname":"X","wingetIds":[],"installedProgramNames":[]}' | Out-Null
        $got = Wait-RelayExport -RelayUrl $script:relay -Code $p.Code -Session 'nope' -TimeoutSeconds 4 -IntervalSeconds 1
        $got.Kind | Should -Be 'session'
    }

    It 'Wait-RelayExport times out when nothing is submitted' {
        $p = Start-RelayPairing -RelayUrl $script:relay -AccessKey $script:admin
        $got = Wait-RelayExport -RelayUrl $script:relay -Code $p.Code -Session $p.Session -TimeoutSeconds 2 -IntervalSeconds 1
        $got.Kind | Should -Be 'timeout'
    }

    It 'Invoke-RelayRequest returns the server message for an HTTP error' {
        # 5.1 reads the response stream; 7 takes it from ErrorDetails - both must yield the body.
        $r = Invoke-RelayRequest -RelayUrl $script:relay -Method 'GET' -Path '/admin/keys'
        $r.Status | Should -Be 401
        $r.Text | Should -Match 'Admin access code required'
        $r2 = Invoke-RelayRequest -RelayUrl $script:relay -Method 'GET' -Path '/poll'
        $r2.Status | Should -Be 400
        $r2.Text | Should -Match 'Invalid or missing code'
    }

    It 'Test-RelayGated stays true when ADMIN_KEY is not configured (503)' {
        # A second relay with no ADMIN_KEY: the version probe still identifies the gated Worker
        # (503 "admin not configured" is the new Worker too), and the body explains why.
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $l.Start(); $port2 = $l.LocalEndpoint.Port; $l.Stop()
        $log2 = Join-Path ([System.IO.Path]::GetTempPath()) "relaytest-noadmin-$port2.log"
        $p2 = Start-Process -FilePath 'node' -ArgumentList @($script:harnessPath, 'serve', "$port2", '--no-admin-key') `
            -PassThru -RedirectStandardOutput $log2 -RedirectStandardError "$log2.err" -WindowStyle Hidden
        try {
            $deadline = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $deadline -and -not (Get-Content $log2 -Raw -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 300 }
            Test-RelayGated -RelayUrl "http://127.0.0.1:$port2" | Should -BeTrue
            $r = Invoke-RelayRequest -RelayUrl "http://127.0.0.1:$port2" -Method 'GET' -Path '/admin/keys' -Headers @{ 'X-Access-Key' = 'anything' }
            $r.Status | Should -Be 503
            $r.Text | Should -Match 'not configured'
        } finally {
            if ($p2 -and -not $p2.HasExited) { Stop-Process -Id $p2.Id -Force -ErrorAction SilentlyContinue }
            Remove-Item $log2, "$log2.err" -ErrorAction SilentlyContinue
        }
    }

    It 'Start-RelayPairing reports an unreachable relay as network' {
        $p = Start-RelayPairing -RelayUrl 'http://127.0.0.1:1' -AccessKey $script:admin
        $p.Ok | Should -BeFalse
        $p.Failure | Should -Be 'network'
    }
}
