# Pester tests for what the Phase 1 removal engine does when an uninstaller HANGS and is stopped. Seen on a Dell Vostro 5620
# (2026-10-14): one SupportAssist MSI ran into the 10-minute limit and its msiexec was killed; the Windows Installer SERVICE kept
# running that change and kept the machine-wide installer lock, so every uninstall after it answered 1618 and the whole run was
# wasted. The engine now looks at the installer's own log, gives the service a minute, and only then ends the service process.
# The real functions are cut out of the script with the PowerShell parser; the installer service, the processes and the clock are
# stood in for (nothing of this machine is touched except one throw-away ping tree). ASCII only.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $deployScript = Join-Path $PSScriptRoot '..\debloat\Deploy-DellOfficeSetup.ps1'
    foreach ($fn in 'Get-WindowsInstallerServiceProcess', 'Stop-ProcessTree', 'Format-OemProcessTree', 'Get-OemLogTail', 'Resolve-HungWindowsInstaller',
        'Invoke-OemUninstallLayer', 'Format-OemLayerCommand', 'Get-UninstallExitClass', 'Get-MsiLogFailureSummary', 'Get-OemMsiEventSummary') {
        . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $deployScript -FunctionName $fn)))
    }

    function Write-Log {
        param([string]$Message, [string]$Level = 'INFO')
        $global:HangTestLog.Add("[$Level] $Message")
    }
    # Stand-ins for the two functions the code under test calls and that must never run for real here.
    function Wait-WindowsInstallerIdle { param([int]$TimeoutSec = 120) $true }
    function Start-ProcessLowPriority { param([string]$FilePath, [string]$ArgumentList, [int]$TimeoutMs = 600000) throw "never run for real from this file" }
}

AfterAll {
    Remove-Variable -Name HangTestLog -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Format-OemProcessTree' {
    BeforeAll {
        function New-Proc { param([int]$Id, [int]$Parent, [string]$Name, [string]$Cmd = '') [PSCustomObject]@{ ProcessId = $Id; ParentProcessId = $Parent; Name = $Name; CommandLine = $Cmd } }
    }

    It 'lists what descends from the root, not the root and not unrelated processes' {
        $procs = @(
            (New-Proc 100 4 'msiexec.exe' 'C:\Windows\system32\msiexec.exe /V'),
            (New-Proc 101 100 'msiexec.exe' 'MsiExec.exe -Embedding 1234'),
            (New-Proc 102 101 'net.exe' 'net stop SupportAssistAgent'),
            (New-Proc 200 4 'notepad.exe' 'notepad.exe'),
            (New-Proc 201 200 'conhost.exe' '')
        )
        $lines = @(Format-OemProcessTree -Processes $procs -RootId @(100))
        $lines.Count | Should -Be 2
        $lines[0] | Should -BeExactly 'msiexec.exe (PID 101): MsiExec.exe -Embedding 1234'
        $lines[1] | Should -BeExactly 'net.exe (PID 102): net stop SupportAssistAgent'
    }

    It 'gives nothing for a root with no children, and for no processes at all' {
        @(Format-OemProcessTree -Processes @((New-Proc 100 4 'msiexec.exe')) -RootId @(100)).Count | Should -Be 0
        @(Format-OemProcessTree -Processes @() -RootId @(100)).Count | Should -Be 0
    }

    It 'survives a parent loop (a reused process id) without running forever' {
        $procs = @((New-Proc 10 11 'a.exe'), (New-Proc 11 10 'b.exe'))
        @(Format-OemProcessTree -Processes $procs -RootId @(10)).Count | Should -Be 1
    }

    It 'cuts the list at the limit and says how many more there are' {
        $procs = @((New-Proc 100 4 'root.exe')) + @(1..20 | ForEach-Object { New-Proc (200 + $_) 100 "child$_.exe" })
        $lines = @(Format-OemProcessTree -Processes $procs -RootId @(100) -Max 5)
        $lines.Count | Should -Be 6
        $lines[5] | Should -BeExactly 'and 15 more'
    }

    It 'cuts a long command line' {
        $lines = @(Format-OemProcessTree -Processes @((New-Proc 1 0 'r.exe'), (New-Proc 2 1 'c.exe' ('x' * 500))) -RootId @(1))
        $lines[0].Length | Should -BeLessThan 200
        $lines[0] | Should -BeLike '*...'
    }
}

Describe 'Get-WindowsInstallerServiceProcess' {
    It 'returns the msiexec process the service manager names' {
        Mock Get-CimInstance { [PSCustomObject]@{ ProcessId = 4321 } }
        Mock Get-Process { [PSCustomObject]@{ Id = 4321; ProcessName = 'msiexec' } }
        (Get-WindowsInstallerServiceProcess).Id | Should -Be 4321
    }

    It 'returns nothing when what runs under that id is not msiexec' {
        Mock Get-CimInstance { [PSCustomObject]@{ ProcessId = 4321 } }
        Mock Get-Process { [PSCustomObject]@{ Id = 4321; ProcessName = 'svchost' } }
        Get-WindowsInstallerServiceProcess | Should -BeNullOrEmpty
    }

    It 'returns nothing when the service is not running (process id 0), for the System process, or for this very process' -ForEach @(
        @{ Id = 0 }
        @{ Id = 4 }
        @{ Id = $PID }
    ) {
        Mock Get-CimInstance { [PSCustomObject]@{ ProcessId = $Id } }
        Mock Get-Process { [PSCustomObject]@{ Id = $Id; ProcessName = 'msiexec' } }
        Get-WindowsInstallerServiceProcess | Should -BeNullOrEmpty
    }

    It 'returns nothing, and does not throw, when the service cannot be read' {
        Mock Get-CimInstance { throw 'access denied' }
        Get-WindowsInstallerServiceProcess | Should -BeNullOrEmpty
    }
}

Describe 'Get-OemLogTail' {
    It 'gives the last non-empty lines, cut short' {
        $path = Join-Path $TestDrive 'msi.log'
        Set-Content -LiteralPath $path -Value (@(1..30 | ForEach-Object { "line $_" }) + @('', ('y' * 400), ''))
        $tail = @(Get-OemLogTail -Path $path -Lines 3)
        $tail.Count | Should -Be 3
        $tail[1] | Should -BeExactly 'line 30'
        $tail[2] | Should -BeLike 'yyy*...'
        $tail[2].Length | Should -BeLessThan 240
    }

    It 'gives nothing for a missing file or no path' {
        @(Get-OemLogTail -Path (Join-Path $TestDrive 'nope.log')).Count | Should -Be 0
        @(Get-OemLogTail -Path '').Count | Should -Be 0
    }
}

Describe 'Resolve-HungWindowsInstaller' {
    BeforeEach {
        $global:HangTestLog = New-Object System.Collections.Generic.List[string]
        $script:logPath = Join-Path $TestDrive 'uninstall.log'
        Set-Content -LiteralPath $script:logPath -Value @('Action start 18:48:55: SA_StopRemediation.', 'MSI (s) (A4:B8) Executing op: CustomActionSchedule')
        $global:HangWaits = New-Object System.Collections.Generic.Queue[bool]
        Mock Wait-WindowsInstallerIdle { if ($global:HangWaits.Count -gt 0) { $global:HangWaits.Dequeue() } else { $true } }
        Mock Stop-ProcessTree {}
        Mock Get-CimInstance {
            @([PSCustomObject]@{ ProcessId = 700; ParentProcessId = 4; Name = 'msiexec.exe'; CommandLine = 'msiexec.exe /V' },
              [PSCustomObject]@{ ProcessId = 701; ParentProcessId = 700; Name = 'SupportAssistUninstaller.exe'; CommandLine = 'SupportAssistUninstaller.exe /stop' })
        }
    }
    AfterEach { Remove-Variable -Name HangWaits -Scope Global -ErrorAction SilentlyContinue }

    It 'does nothing to the machine when Windows Installer is free, and still shows the end of the installer log' {
        $global:HangWaits.Enqueue($true)
        Mock Get-WindowsInstallerServiceProcess { [PSCustomObject]@{ Id = 700; ProcessName = 'msiexec' } }
        Resolve-HungWindowsInstaller -ProductName 'Dell SupportAssist' -LogPath $script:logPath | Should -BeExactly 'Free'
        Should -Invoke Stop-ProcessTree -Times 0 -Exactly
        $global:HangTestLog -join "`n" | Should -BeLike '*installer log, last lines: Action start 18:48:55: SA_StopRemediation.*'
    }

    It 'waits a minute first, and ends the stuck service process (once) when it still holds the lock' {
        $global:HangWaits.Enqueue($false)   # still busy after the grace period
        $global:HangWaits.Enqueue($true)    # free after the service was ended
        Mock Get-WindowsInstallerServiceProcess { [PSCustomObject]@{ Id = 700; ProcessName = 'msiexec' } }
        Resolve-HungWindowsInstaller -ProductName 'Dell SupportAssist' -LogPath $script:logPath | Should -BeExactly 'Cleared'
        Should -Invoke Wait-WindowsInstallerIdle -Times 2 -Exactly -ParameterFilter { $TimeoutSec -eq 60 }
        Should -Invoke Stop-ProcessTree -Times 1 -Exactly -ParameterFilter { $ProcessId -eq 700 }
        $text = $global:HangTestLog -join "`n"
        $text | Should -BeLike "*[WARN]*still busy 60 s after 'Dell SupportAssist' was stopped*PID 700*"
        $text | Should -BeLike '*was running under it: SupportAssistUninstaller.exe (PID 701): SupportAssistUninstaller.exe /stop*'
        $text | Should -BeLike '*Windows Installer is free again*'
    }

    It 'ends nothing when the service process cannot be identified' {
        $global:HangWaits.Enqueue($false)
        Mock Get-WindowsInstallerServiceProcess { $null }
        Resolve-HungWindowsInstaller -ProductName 'X' -LogPath $script:logPath | Should -BeExactly 'StillBusy'
        Should -Invoke Stop-ProcessTree -Times 0 -Exactly
        $global:HangTestLog -join "`n" | Should -BeLike '*[WARN]*could not be identified - nothing was ended*'
    }

    It 'says so, and tells the operator to restart, when it is still busy after the service was ended' {
        $global:HangWaits.Enqueue($false)
        $global:HangWaits.Enqueue($false)
        Mock Get-WindowsInstallerServiceProcess { [PSCustomObject]@{ Id = 700; ProcessName = 'msiexec' } }
        Resolve-HungWindowsInstaller -ProductName 'X' -LogPath $script:logPath | Should -BeExactly 'StillBusy'
        Should -Invoke Stop-ProcessTree -Times 1 -Exactly
        $global:HangTestLog -join "`n" | Should -BeLike '*[WARN]*still busy after its service was ended. Restart the PC*'
    }
}

Describe 'Invoke-OemUninstallLayer after a hang' {
    BeforeEach {
        $global:HangTestLog = New-Object System.Collections.Generic.List[string]
        $script:layer = [PSCustomObject]@{ Kind = 'Msi'; FilePath = 'msiexec.exe'; ArgumentList = '/x {65043213-393F-49BF-B658-5B06C5F713FF} /qn /norestart'; LogPath = (Join-Path $TestDrive 'u.log') }
        $global:HangResolveCalls = New-Object System.Collections.Generic.List[string]
        $global:HangRuns = New-Object System.Collections.Generic.Queue[object]
        Mock Start-ProcessLowPriority { $global:HangRuns.Dequeue() }
        Mock Start-Sleep {}
        Mock Resolve-HungWindowsInstaller { $global:HangResolveCalls.Add("$ProductName|$LogPath"); 'Cleared' }
    }
    AfterEach { Remove-Variable -Name HangResolveCalls, HangRuns -Scope Global -ErrorAction SilentlyContinue }

    It 'checks Windows Installer once after a run that had to be stopped, does not run the layer again, and reports the timeout' {
        $global:HangRuns.Enqueue([PSCustomObject]@{ Started = $true; ExitCode = $null; TimedOut = $true; Seconds = 601; Error = $null })
        $r = Invoke-OemUninstallLayer -Layer $script:layer -ProductName 'Dell SupportAssist'
        $r.Class | Should -BeExactly 'TimedOut'
        @($global:HangResolveCalls).Count | Should -Be 1
        $global:HangResolveCalls[0] | Should -BeExactly ('Dell SupportAssist|' + $script:layer.LogPath)
        Should -Invoke Start-ProcessLowPriority -Times 1 -Exactly
    }

    It 'does not touch Windows Installer after a run that finished, whatever its exit code' -ForEach @(
        @{ Code = 0 }
        @{ Code = 1603 }
    ) {
        $global:HangRuns.Enqueue([PSCustomObject]@{ Started = $true; ExitCode = $Code; TimedOut = $false; Seconds = 5; Error = $null })
        $null = Invoke-OemUninstallLayer -Layer $script:layer -ProductName 'Dell SupportAssist'
        @($global:HangResolveCalls).Count | Should -Be 0
    }

    It 'still returns its result when the check itself fails' {
        Mock Resolve-HungWindowsInstaller { throw 'boom' }
        $global:HangRuns.Enqueue([PSCustomObject]@{ Started = $true; ExitCode = $null; TimedOut = $true; Seconds = 601; Error = $null })
        $r = Invoke-OemUninstallLayer -Layer $script:layer -ProductName 'Dell SupportAssist'
        $r.Class | Should -BeExactly 'TimedOut'
        $global:HangTestLog -join "`n" | Should -BeLike '*[WARN]*Could not check whether Windows Installer is still held: boom*'
    }
}

Describe 'Stop-ProcessTree (a real throw-away process tree)' {
    It 'ends the process and what it started' {
        # A ping with a buffer size nobody else uses is found again by its command line.
        $size = Get-Random -Minimum 20001 -Maximum 60000
        $finder = { @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'PING.EXE'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*-l $size *" }) }
        $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $proc = Start-Process -FilePath $cmd -ArgumentList "/c ping -n 60 -l $size 127.0.0.1 > nul" -PassThru -WindowStyle Hidden
        try {
            Start-Sleep -Milliseconds 1200
            @(& $finder).Count | Should -BeGreaterThan 0 -Because 'the check must be able to see the ping at all'
            Stop-ProcessTree -ProcessId $proc.Id
            Start-Sleep -Milliseconds 1500
            @(& $finder).Count | Should -Be 0 -Because 'the whole tree must go, not just cmd.exe'
        } finally {
            try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch { $null = $_ }
        }
    }
}
