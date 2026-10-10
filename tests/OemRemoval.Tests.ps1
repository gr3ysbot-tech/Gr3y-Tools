# Pester tests for the Phase 1 removal engine of Deploy-DellOfficeSetup.ps1 (Dell/Lenovo/McAfee programs). It used to start each
# uninstaller and throw its exit code away: a failed uninstall looked exactly like a successful one, the same product was
# attempted several times, and nothing checked that anything was gone. The engine now reads every exit code, waits out other
# Windows Installer activity, believes a success only when the Uninstall entry is really gone, stops the product's services and
# processes before every try (a failed pass is followed by one more), clears dead registry entries (with a backup) and reports
# everything that could not be removed.
# The real functions are cut out of the script with the PowerShell parser; the registry, the processes and the clock are
# stood in for, so nothing is installed or removed. ASCII only.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $deployScript = Join-Path $PSScriptRoot '..\debloat\Deploy-DellOfficeSetup.ps1'
    foreach ($fn in 'Get-UninstallEntries', 'Start-ProcessLowPriority', 'ConvertFrom-UninstallString', 'Test-PathQuiet', 'Resolve-UninstallExecutable', 'Test-OemProgramFolderPresent', 'Get-OemProgramEvidence', 'Stop-ServiceBounded', 'Test-OemProcessMayBeStopped', 'ConvertTo-MsiUninstallArguments', 'Get-PendingRestartReasons', 'Test-OemResultRetryable', 'Remove-OemBloatware', 'Get-OemProductHint', 'Get-UninstallExitClass', 'ConvertTo-BurnUninstallArguments', 'Get-OemUninstallLayer', 'Group-OemProductEntries',
        'Get-OemRemovalSummaryLines', 'Get-OemAttemptLines', 'Format-OemFailureDetail', 'Format-OemLayerCommand', 'ConvertTo-OemFolderPath', 'Get-OemUninstallerFolder', 'Get-RunWarningCount', 'Get-OemHangGuess', 'Get-OemAppxIdentity', 'Test-OemFolderHasContent', 'Get-OemIconFilePath', 'Get-OemProgramFootprints', 'Format-OemNothingToCheck', 'Test-OemProductPresent', 'Wait-OemProductGone', 'Stop-OemProductActivity', 'Invoke-OemUninstallLayer',
        'Remove-StaleUninstallEntry', 'Remove-OemUninstallLogs', 'Remove-OemWin32Product', 'Test-WindowsInstallerBusy', 'Wait-WindowsInstallerIdle',
        'Get-MsiLogFailureSummary', 'Get-OemMsiEventSummary', 'Remove-OemAppxPackages', 'Invoke-ThrottledSteps', 'Test-IsWorkSchoolTeams', 'Disable-OemScheduledTasksAndServices', 'Invoke-Step') {
        . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $deployScript -FunctionName $fn)))
    }

    # The log is captured so that the tests can read what the operator would read.
    function Write-Log {
        param([string]$Message, [string]$Level = 'INFO')
        $global:OemTestLog.Add("[$Level] $Message")
    }

    # One installed program as the registry shows it.
    function New-TestEntry {
        param([string]$Name, [string]$Key, [string]$Uninstall, [string]$Quiet = '', [string]$Version = '1.0', [int]$WindowsInstaller = 0, [string]$Location = '')
        [PSCustomObject]@{
            DisplayName = $Name; DisplayVersion = $Version; PSChildName = $Key; UninstallString = $Uninstall; QuietUninstallString = $Quiet
            WindowsInstaller = $WindowsInstaller; InstallLocation = $Location
            PSPath = "Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$Key"
        }
    }

    # What an uninstaller run returns, in the shape Start-ProcessLowPriority gives.
    function New-TestRun {
        param($ExitCode = 0, [bool]$TimedOut = $false, [bool]$Started = $true, [string]$ErrorText = $null)
        [PSCustomObject]@{ Started = $Started; ExitCode = $ExitCode; TimedOut = $TimedOut; Seconds = 2; Error = $ErrorText }
    }
}

AfterAll {
    Remove-Variable -Name OemTestLog, OemTestInstalled, OemTestRuns, OemTestCalls, OemTestStopCalls, OemTestSkips, OemTestAfterFails, OemTestPolls -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Get-UninstallExitClass' {
    It 'reads <Code> as <Class>' -ForEach @(
        @{ Code = 0; Class = 'Success' }
        @{ Code = 3010; Class = 'RebootRequired' }
        @{ Code = 1641; Class = 'RebootRequired' }
        @{ Code = -2147021886; Class = 'RebootRequired' }     # 0x80070BC2: 3010 wrapped as an HRESULT (a Burn bundle)
        @{ Code = 1605; Class = 'NotInstalled' }
        @{ Code = 1614; Class = 'NotInstalled' }
        @{ Code = 1618; Class = 'Busy' }
        @{ Code = -2147023278; Class = 'Busy' }               # 0x80070652
        @{ Code = 1603; Class = 'Failed' }
        @{ Code = -2147023293; Class = 'Failed' }             # 0x80070643 = 1603 as an HRESULT
        @{ Code = 1602; Class = 'Failed' }
        @{ Code = 740; Class = 'Failed' }
        @{ Code = 12345; Class = 'Failed' }
        @{ Code = -532462766; Class = 'Failed' }              # 0xE0434352, a .NET exception, not a Win32 code
        @{ Code = 1707; Class = 'Success' }
        @{ Code = 3011; Class = 'RebootRequired' }
        @{ Code = 350; Class = 'RebootFirst' }                # a Burn bundle with a restart pending: "no action was taken"
        @{ Code = -2147024546; Class = 'RebootFirst' }        # 0x8007015E = 350 as an HRESULT
        @{ Code = 1604; Class = 'RebootFirst' }
        @{ Code = 3017; Class = 'RebootFirst' }
        @{ Code = 3018; Class = 'RebootFirst' }
        @{ Code = 1612; Class = 'NoSource' }
        @{ Code = 1619; Class = 'NoSource' }
        @{ Code = 1620; Class = 'NoSource' }
        @{ Code = 1706; Class = 'NoSource' }
        @{ Code = 1625; Class = 'Blocked' }
        @{ Code = 1643; Class = 'Blocked' }
        @{ Code = 1644; Class = 'Blocked' }
        @{ Code = 1260; Class = 'Blocked' }
    ) {
        (Get-UninstallExitClass -ExitCode $Code).Class | Should -BeExactly $Class
    }

    It 'writes the code the way logs and vendors do: plain for a Win32 code, with the wrapping HRESULT, or in hex for anything bigger' {
        (Get-UninstallExitClass -ExitCode 350).Display | Should -BeExactly '350'
        (Get-UninstallExitClass -ExitCode 0).Display | Should -BeExactly '0'
        (Get-UninstallExitClass -ExitCode -2147023293).Display | Should -BeExactly '1603 (0x80070643)'
        (Get-UninstallExitClass -ExitCode -2147024546).Display | Should -BeExactly '350 (0x8007015E)'
        (Get-UninstallExitClass -ExitCode -2147467259).Display | Should -BeExactly '0x80004005'     # E_FAIL, not a Win32 code
        (Get-UninstallExitClass -ExitCode -1).Display | Should -BeExactly '0xFFFFFFFF'
        (Get-UninstallExitClass -ExitCode -1073741819).Display | Should -BeExactly '0xC0000005'      # an access violation
        (Get-UninstallExitClass -ExitCode 1707).Text | Should -BeExactly 'success'
    }

    It 'says in words that a pending restart is why nothing happened' {
        (Get-UninstallExitClass -ExitCode 350).Text | Should -BeLike '*restart*pending*'
        (Get-UninstallExitClass -ExitCode 1612).Text | Should -BeLike '*source*missing*'
        (Get-UninstallExitClass -ExitCode 1625).Text | Should -BeLike '*policy*'
    }

    It 'unwraps an HRESULT to the Win32 code it carries' {
        (Get-UninstallExitClass -ExitCode -2147023293).Code | Should -Be 1603
        (Get-UninstallExitClass -ExitCode -2147021886).Code | Should -Be 3010
    }

    It 'explains the common failures in words' {
        (Get-UninstallExitClass -ExitCode 1603).Text | Should -BeLike '*fatal*'
        (Get-UninstallExitClass -ExitCode 1618).Text | Should -BeLike '*another installation*'
        (Get-UninstallExitClass -ExitCode 1605).Text | Should -BeLike '*not installed*'
        (Get-UninstallExitClass -ExitCode 3010).Text | Should -BeLike '*restart*'
    }

    It 'treats a missing exit code, a timeout and a process that never started as what they are' {
        (Get-UninstallExitClass -ExitCode $null).Class | Should -BeExactly 'Unknown'
        (Get-UninstallExitClass -ExitCode 0 -TimedOut $true).Class | Should -BeExactly 'TimedOut'
        (Get-UninstallExitClass -ExitCode $null -Started $false).Class | Should -BeExactly 'NotStarted'
    }
}

Describe 'ConvertTo-BurnUninstallArguments' {
    It 'always asks for /uninstall /quiet /norestart' {
        ConvertTo-BurnUninstallArguments -ExistingArguments '' | Should -BeExactly '/uninstall /quiet /norestart'
    }

    It 'drops switches that would show a window or restart, keeps the vendor''s own, and adds a log' {
        $burnArgs = ConvertTo-BurnUninstallArguments -ExistingArguments '/uninstall /passive /forcerestart -burn.unelevated' -LogPath 'C:\Temp\x.log'
        $burnArgs | Should -BeExactly '/uninstall /quiet /norestart -burn.unelevated /log "C:\Temp\x.log"'
    }

    It 'drops /modify, /repair and /layout, which would override the /uninstall (Burn obeys the last action switch)' {
        ConvertTo-BurnUninstallArguments -ExistingArguments '/modify' | Should -BeExactly '/uninstall /quiet /norestart'
        ConvertTo-BurnUninstallArguments -ExistingArguments '-repair /Modify' | Should -BeExactly '/uninstall /quiet /norestart'
    }
}

Describe 'ConvertTo-MsiUninstallArguments' {
    It 'removes the product quietly, without a restart, and ignoring WiX dependents (as a Burn bundle does)' {
        ConvertTo-MsiUninstallArguments -ProductCode '{65043213-393F-49BF-B658-5B06C5F713FF}' |
            Should -BeExactly '/x {65043213-393F-49BF-B658-5B06C5F713FF} IGNOREDEPENDENCIES=ALL /qn /norestart'
    }

    It 'adds a verbose log when it is given a path' {
        ConvertTo-MsiUninstallArguments -ProductCode '{65043213-393F-49BF-B658-5B06C5F713FF}' -LogPath 'C:\Temp\a b.log' |
            Should -BeExactly '/x {65043213-393F-49BF-B658-5B06C5F713FF} IGNOREDEPENDENCIES=ALL /qn /norestart /L*v "C:\Temp\a b.log"'
    }

    It 'leaves the dependency check on for software that others share' {
        ConvertTo-MsiUninstallArguments -ProductCode '{65043213-393F-49BF-B658-5B06C5F713FF}' -IgnoreDependencies $false |
            Should -BeExactly '/x {65043213-393F-49BF-B658-5B06C5F713FF} /qn /norestart'
        ConvertTo-MsiUninstallArguments -ProductCode '{65043213-393F-49BF-B658-5B06C5F713FF}' -LogPath 'C:\a.log' -IgnoreDependencies $false |
            Should -BeExactly '/x {65043213-393F-49BF-B658-5B06C5F713FF} /qn /norestart /L*v "C:\a.log"'
    }
}

Describe 'Get-OemUninstallLayer' {
    It 'turns an msiexec string into a quiet msiexec /x with a verbose log' {
        $e = New-TestEntry -Name 'Dell SupportAssist' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}'
        $l = Get-OemUninstallLayer -Entry $e -LogPath 'C:\Temp\sa.log'
        $l.Kind | Should -BeExactly 'Msi'
        $l.ProductCode | Should -BeExactly '{65043213-393F-49BF-B658-5B06C5F713FF}'
        $l.ArgumentList | Should -BeExactly '/x {65043213-393F-49BF-B658-5B06C5F713FF} IGNOREDEPENDENCIES=ALL /qn /norestart /L*v "C:\Temp\sa.log"'
    }

    It 'falls back to the key name when an msiexec string carries no GUID' {
        $e = New-TestEntry -Name 'X' -Key '{12345678-1234-1234-1234-123456789ABC}' -Uninstall 'msiexec.exe /X SomeName /quiet'
        (Get-OemUninstallLayer -Entry $e).ProductCode | Should -BeExactly '{12345678-1234-1234-1234-123456789ABC}'
    }

    It 'treats an entry without any uninstall string as an MSI product when it is registered by Windows Installer under a GUID key' {
        $e = New-TestEntry -Name 'X' -Key '{12345678-1234-1234-1234-123456789ABC}' -Uninstall '' -WindowsInstaller 1
        $l = Get-OemUninstallLayer -Entry $e
        $l.Kind | Should -BeExactly 'Msi'
        $l.ArgumentList | Should -BeExactly '/x {12345678-1234-1234-1234-123456789ABC} IGNOREDEPENDENCIES=ALL /qn /norestart'
    }

    It 'has nothing to run for an entry without an uninstall string that is not an MSI product' {
        (Get-OemUninstallLayer -Entry (New-TestEntry -Name 'X' -Key 'SomeKey' -Uninstall '')).Kind | Should -BeExactly 'None'
    }

    It 'recognises a WiX Burn bundle in the Package Cache and builds its quiet uninstall' {
        $e = New-TestEntry -Name 'Dell SupportAssist Remediation' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall '"C:\ProgramData\Package Cache\{400b816d-1b36-426f-9595-5742bfd07ec4}\DellSupportAssistRemediationServiceInstaller.exe" /uninstall'
        $l = Get-OemUninstallLayer -Entry $e -LogPath 'C:\Temp\b.log'
        $l.Kind | Should -BeExactly 'Bundle'
        $l.FilePath | Should -BeExactly 'C:\ProgramData\Package Cache\{400b816d-1b36-426f-9595-5742bfd07ec4}\DellSupportAssistRemediationServiceInstaller.exe'
        $l.ArgumentList | Should -BeExactly '/uninstall /quiet /norestart /log "C:\Temp\b.log"'
    }

    It 'recognises an InstallShield wrapper' {
        $e = New-TestEntry -Name 'Dell Optimizer' -Key 'K' -Uninstall '"C:\Program Files (x86)\InstallShield Installation Information\{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}\DellOptimizer_MyDell.exe" -remove -runfromtemp'
        $l = Get-OemUninstallLayer -Entry $e
        $l.Kind | Should -BeExactly 'Wrapper'
        $l.ArgumentList | Should -BeExactly '-remove -runfromtemp'
    }

    It 'treats any other uninstaller as a plain Exe and keeps the vendor''s silent switch' {
        $l = Get-OemUninstallLayer -Entry (New-TestEntry -Name 'X' -Key 'K' -Uninstall '"C:\Program Files\Vendor\uninstall.exe" -silent')
        $l.Kind | Should -BeExactly 'Exe'
        $l.ArgumentList | Should -BeExactly '-silent'
    }

    It 'reports a command it cannot read' {
        (Get-OemUninstallLayer -Entry (New-TestEntry -Name 'X' -Key 'K' -Uninstall 'this is not a command')).Kind | Should -BeExactly 'Unparseable'
    }

    It 'builds an MSI command without IGNOREDEPENDENCIES when asked to respect dependents' {
        $e = New-TestEntry -Name 'Dell Core Services' -Key '{12345678-1234-1234-1234-123456789ABC}' -Uninstall 'MsiExec.exe /X{12345678-1234-1234-1234-123456789ABC}'
        (Get-OemUninstallLayer -Entry $e -IgnoreDependencies $false).ArgumentList | Should -BeExactly '/x {12345678-1234-1234-1234-123456789ABC} /qn /norestart'
        (Get-OemUninstallLayer -Entry $e).ArgumentList | Should -BeLike '*IGNOREDEPENDENCIES=ALL*'
        $keyOnly = New-TestEntry -Name 'Dell Core Services' -Key '{12345678-1234-1234-1234-123456789ABC}' -Uninstall '' -WindowsInstaller 1
        (Get-OemUninstallLayer -Entry $keyOnly -IgnoreDependencies $false).ArgumentList | Should -BeExactly '/x {12345678-1234-1234-1234-123456789ABC} /qn /norestart'
    }

    It 'reads an unquoted path with spaces (Dell Pair) as a plain Exe with the default silent switch' {
        $e = New-TestEntry -Name 'Dell Pair' -Key 'DellPair' -Uninstall 'C:\Program Files\Dell\Dell Pair\Uninstall.exe'
        $l = Get-OemUninstallLayer -Entry $e
        $l.Kind | Should -BeExactly 'Exe'
        $l.FilePath | Should -BeExactly 'C:\Program Files\Dell\Dell Pair\Uninstall.exe'
        $l.ArgumentList | Should -BeExactly '/S'
    }

    It 'replaces the arguments of an Exe or a wrapper with the hint''s silent switches, and leaves MSI and bundle commands alone' {
        $wrapper = New-TestEntry -Name 'Dell Optimizer' -Key 'K' -Uninstall '"C:\Program Files (x86)\InstallShield Installation Information\{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}\DellOptimizer_MyDell.exe" -remove -runfromtemp'
        (Get-OemUninstallLayer -Entry $wrapper -SilentArgs '-remove -runfromtemp /Silent').ArgumentList | Should -BeExactly '-remove -runfromtemp /Silent'
        $exe = New-TestEntry -Name 'X' -Key 'K' -Uninstall '"C:\Program Files\Vendor\uninstall.exe" -wizard'
        (Get-OemUninstallLayer -Entry $exe -SilentArgs '/quiet').ArgumentList | Should -BeExactly '/quiet'
        $msi = New-TestEntry -Name 'X' -Key '{12345678-1234-1234-1234-123456789ABC}' -Uninstall 'MsiExec.exe /X{12345678-1234-1234-1234-123456789ABC}'
        (Get-OemUninstallLayer -Entry $msi -SilentArgs '/quiet').ArgumentList | Should -BeExactly '/x {12345678-1234-1234-1234-123456789ABC} IGNOREDEPENDENCIES=ALL /qn /norestart'
        $bundle = New-TestEntry -Name 'X' -Key 'K' -Uninstall '"C:\ProgramData\Package Cache\{400b816d-1b36-426f-9595-5742bfd07ec4}\s.exe" /uninstall'
        (Get-OemUninstallLayer -Entry $bundle -SilentArgs '/quiet').ArgumentList | Should -BeExactly '/uninstall /quiet /norestart'
    }

    It 'finds the real file when the registry string names it badly (a folder called "x.exe y", an unexpanded variable)' {
        $folder = Join-Path $TestDrive 'Vendor.exe Tools\Setup'
        $null = New-Item -ItemType Directory -Path $folder -Force
        $real = Join-Path $folder 'uninst.exe'
        Set-Content -LiteralPath $real -Value 'x'
        $l = Get-OemUninstallLayer -Entry (New-TestEntry -Name 'X' -Key 'K' -Uninstall "$real -x")
        $l.Kind | Should -BeExactly 'Exe'
        $l.FilePath | Should -BeExactly $real
        $l.ArgumentList | Should -BeExactly '-x'

        $env:OEM_TEST_FOLDER = $folder
        try {
            $l2 = Get-OemUninstallLayer -Entry (New-TestEntry -Name 'X' -Key 'K' -Uninstall '%OEM_TEST_FOLDER%\uninst.exe /quiet')
            $l2.FilePath | Should -BeExactly $real
            $l2.ArgumentList | Should -BeExactly '/quiet'
        } finally {
            Remove-Item Env:\OEM_TEST_FOLDER -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Resolve-UninstallExecutable' {
    BeforeAll {
        $script:dir = Join-Path $TestDrive 'Program Files\Some Vendor\Some Product'
        $null = New-Item -ItemType Directory -Path $script:dir -Force
        $script:exe = Join-Path $script:dir 'Uninstall.exe'
        Set-Content -LiteralPath $script:exe -Value 'x'
    }

    It 'finds a quoted file that exists, with its arguments' {
        $r = Resolve-UninstallExecutable -CommandLine ('"' + $script:exe + '" /S /v"/qn"')
        $r.FilePath | Should -BeExactly $script:exe
        $r.Arguments | Should -BeExactly '/S /v"/qn"'
    }

    It 'finds an unquoted file whose path contains spaces' {
        $r = Resolve-UninstallExecutable -CommandLine "$script:exe /S"
        $r.FilePath | Should -BeExactly $script:exe
        $r.Arguments | Should -BeExactly '/S'
    }

    It 'finds an unquoted file with no arguments at all' {
        (Resolve-UninstallExecutable -CommandLine $script:exe).Arguments | Should -BeExactly ''
    }

    It 'finds the file when the vendor quoted the WHOLE command, arguments included' {
        $r = Resolve-UninstallExecutable -CommandLine ('"' + $script:exe + ' /S /norestart"')
        $r.FilePath | Should -BeExactly $script:exe
        $r.Arguments | Should -BeExactly '/S /norestart'
        (Resolve-UninstallExecutable -CommandLine ('"' + $script:exe + '"')).FilePath | Should -BeExactly $script:exe
    }

    It 'answers nothing when no such file exists, whatever the string looks like' {
        Resolve-UninstallExecutable -CommandLine (Join-Path $TestDrive 'no such\folder\Uninstall.exe /S') | Should -BeNullOrEmpty
        Resolve-UninstallExecutable -CommandLine ('"' + (Join-Path $TestDrive 'no such\Uninstall.exe') + '" /S') | Should -BeNullOrEmpty
        Resolve-UninstallExecutable -CommandLine 'this is not a command' | Should -BeNullOrEmpty
        Resolve-UninstallExecutable -CommandLine '' | Should -BeNullOrEmpty
    }

    It 'raises no error for the longer candidates of a command line whose arguments hold a quoted path' {
        $Error.Clear()
        Resolve-UninstallExecutable -CommandLine 'C:\nowhere\b.exe /p "C:\c d\e.exe " /y' | Should -BeNullOrEmpty
        $Error.Count | Should -Be 0
    }

    It 'does not take a folder for the uninstaller' {
        $folderNamedLikeExe = Join-Path $TestDrive 'Folder.exe'
        $null = New-Item -ItemType Directory -Path $folderNamedLikeExe -Force
        Resolve-UninstallExecutable -CommandLine $folderNamedLikeExe | Should -BeNullOrEmpty
    }
}

Describe 'Test-PathQuiet' {
    It 'answers like Test-Path for ordinary paths' {
        $dir = Join-Path $TestDrive 'quiet'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $file = Join-Path $dir 'a.txt'
        Set-Content -LiteralPath $file -Value 'x'
        Test-PathQuiet -Path $file | Should -BeTrue
        Test-PathQuiet -Path $file -PathType Leaf | Should -BeTrue
        Test-PathQuiet -Path $file -PathType Container | Should -BeFalse
        Test-PathQuiet -Path $dir -PathType Container | Should -BeTrue
        Test-PathQuiet -Path $dir -PathType Leaf | Should -BeFalse
        Test-PathQuiet -Path (Join-Path $dir 'missing.txt') | Should -BeFalse
    }

    It 'answers false, without an error, for a string that cannot be a path (it would make Test-Path write "Illegal characters in path")' {
        foreach ($odd in 'C:\Program Files\Foo\I"rundll32', 'C:\a<b>\Uninstall.exe', 'C:\x|y', '"C:\Program Files\X\u.exe"', "C:\bad`0name") {
            $Error.Clear()
            Test-PathQuiet -Path $odd | Should -BeFalse -Because $odd
            Test-PathQuiet -Path $odd -PathType Leaf | Should -BeFalse -Because $odd
            $Error.Count | Should -Be 0 -Because $odd
        }
    }

    It 'answers false for nothing at all' {
        Test-PathQuiet -Path '' | Should -BeFalse
        Test-PathQuiet -Path $null | Should -BeFalse
    }
}

Describe 'Test-OemProgramFolderPresent' {
    It 'is true for a program folder that still holds files' {
        $dir = Join-Path $TestDrive 'Program Files\Vendor\App'
        $null = New-Item -ItemType Directory -Path $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'app.dll') -Value 'x'
        Test-OemProgramFolderPresent -UninstallerPath (Join-Path $dir 'Uninstall.exe') | Should -BeTrue
    }

    It 'is false for an empty folder, a missing folder, and no path at all' {
        $empty = Join-Path $TestDrive 'Program Files\Vendor\Empty'
        $null = New-Item -ItemType Directory -Path $empty -Force
        Test-OemProgramFolderPresent -UninstallerPath (Join-Path $empty 'Uninstall.exe') | Should -BeFalse
        Test-OemProgramFolderPresent -UninstallerPath (Join-Path $TestDrive 'nowhere\Uninstall.exe') | Should -BeFalse
        Test-OemProgramFolderPresent -UninstallerPath '' | Should -BeFalse
        Test-OemProgramFolderPresent -UninstallerPath $null | Should -BeFalse
    }

    It 'answers without an error for a registry string that holds characters a path cannot (a quote, angle brackets)' {
        foreach ($odd in 'C:\Program Files\Foo\I"rundll32.exe', 'C:\a<b>\Uninstall.exe', 'C:\x|y\u.exe', '"', 'no-folder-at-all.exe', '\', 'C:') {
            $Error.Clear()
            Test-OemProgramFolderPresent -UninstallerPath $odd | Should -BeFalse -Because $odd
            $Error.Count | Should -Be 0 -Because $odd
        }
    }

    It 'does not count an installer cache as the program''s folder' {
        foreach ($cacheName in 'Package Cache', 'InstallShield Installation Information') {
            $cache = Join-Path $TestDrive "$cacheName\{22222222-2222-2222-2222-222222222222}"
            $null = New-Item -ItemType Directory -Path $cache -Force
            Set-Content -LiteralPath (Join-Path $cache 'payload.cab') -Value 'x'
            Test-OemProgramFolderPresent -UninstallerPath (Join-Path $cache 'setup.exe') | Should -BeFalse -Because $cacheName
        }
    }
}

Describe 'Get-OemProgramEvidence' {
    AfterEach { if ($script:savedRoot) { $env:SystemRoot = $script:savedRoot; $script:savedRoot = $null } }
    BeforeEach {
        $noHint = [PSCustomObject]@{ Services = @(); Processes = @() }
        Mock Get-Service {}
    }

    It 'finds nothing for a program that is really gone' {
        $layer = [PSCustomObject]@{ Kind = 'Exe'; FilePath = (Join-Path $TestDrive 'gone\Uninstall.exe'); InstallLocation = ''; DisplayIcon = '' }
        @(Get-OemProgramEvidence -Layer $layer -Hint $noHint).Count | Should -Be 0
    }

    It 'finds the registered install folder' {
        $dir = Join-Path $TestDrive 'Program Files\Vendor\Prog'
        $null = New-Item -ItemType Directory -Path $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'app.dll') -Value 'x'
        $layer = [PSCustomObject]@{ Kind = 'Exe'; FilePath = (Join-Path $TestDrive 'gone\Uninstall.exe'); InstallLocation = $dir; DisplayIcon = '' }
        (Get-OemProgramEvidence -Layer $layer -Hint $noHint) -join '|' | Should -BeLike "*the program's folder still exists ($dir)*"
    }

    It 'does not take an EMPTY install folder (what an uninstaller leaves behind) for a program that is still installed' {
        $dir = Join-Path $TestDrive 'Program Files\Vendor\EmptyProg'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $layer = [PSCustomObject]@{ Kind = 'Exe'; FilePath = (Join-Path $TestDrive 'gone\Uninstall.exe'); InstallLocation = $dir; DisplayIcon = '' }
        @(Get-OemProgramEvidence -Layer $layer -Hint $noHint) | Should -BeNullOrEmpty
    }

    It 'finds the folder the uninstaller sat in when no install folder is registered' {
        $dir = Join-Path $TestDrive 'Program Files\Vendor\Prog2'
        $null = New-Item -ItemType Directory -Path $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'app.dll') -Value 'x'
        $layer = [PSCustomObject]@{ Kind = 'Exe'; FilePath = (Join-Path $dir 'Uninstall.exe'); InstallLocation = ''; DisplayIcon = '' }
        (Get-OemProgramEvidence -Layer $layer -Hint $noHint) -join '|' | Should -BeLike "*the program's folder still exists ($dir)*"
    }

    It 'finds the file the Apps icon points at, with or without the icon index, quotes or variables' {
        # (the icon file lies in $TestDrive, which is under the Windows folder when Pester runs as SYSTEM; icons in the Windows folder do not count)
        $script:savedRoot = $env:SystemRoot
        $env:SystemRoot = 'Z:\OemNoSuchWindowsFolder'
        $dir = Join-Path $TestDrive 'Icons'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $exe = Join-Path $dir 'prog.exe'
        Set-Content -LiteralPath $exe -Value 'x'
        foreach ($icon in "$exe,0", "`"$exe`",-12", $exe) {
            $layer = [PSCustomObject]@{ Kind = 'Bundle'; FilePath = (Join-Path $TestDrive 'Package Cache\{x}\setup.exe'); InstallLocation = ''; DisplayIcon = $icon }
            (Get-OemProgramEvidence -Layer $layer -Hint $noHint) -join '|' | Should -BeLike '*Apps icon points at still exists*' -Because $icon
        }
        $layerGone = [PSCustomObject]@{ Kind = 'Bundle'; FilePath = ''; InstallLocation = ''; DisplayIcon = (Join-Path $dir 'missing.exe') + ',0' }
        @(Get-OemProgramEvidence -Layer $layerGone -Hint $noHint).Count | Should -Be 0
    }

    It 'finds a service the product hint names, by name or by display name' {
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist' } }
        $layer = [PSCustomObject]@{ Kind = 'Exe'; FilePath = ''; InstallLocation = ''; DisplayIcon = '' }
        $hint = [PSCustomObject]@{ Services = @('*SupportAssist*'); Processes = @() }
        (Get-OemProgramEvidence -Layer $layer -Hint $hint) -join '|' | Should -BeLike "*its service 'SupportAssistAgent' still exists*"
    }

    It 'does not take an installer cache for the program''s folder' {
        $cache = Join-Path $TestDrive 'Package Cache\{33333333-3333-3333-3333-333333333333}'
        $null = New-Item -ItemType Directory -Path $cache -Force
        Set-Content -LiteralPath (Join-Path $cache 'payload.cab') -Value 'x'
        $layer = [PSCustomObject]@{ Kind = 'Bundle'; FilePath = (Join-Path $cache 'setup.exe'); InstallLocation = ''; DisplayIcon = '' }
        @(Get-OemProgramEvidence -Layer $layer -Hint $noHint).Count | Should -Be 0
    }
}

Describe 'Test-OemProductPresent' {
    It 'finds a product by its name however it is cased or padded' {
        Mock Get-UninstallEntries { @([PSCustomObject]@{ DisplayName = 'Dell Optimizer ' }, [PSCustomObject]@{ DisplayName = 'Something Else' }) }
        Test-OemProductPresent -Name 'Dell Optimizer' | Should -BeTrue
        Test-OemProductPresent -Name 'DELL OPTIMIZER' | Should -BeTrue
        Test-OemProductPresent -Name ' Dell Optimizer ' | Should -BeTrue
        Test-OemProductPresent -Name 'Dell Pair' | Should -BeFalse
    }

    It 'is false when nothing is installed at all' {
        Mock Get-UninstallEntries { @() }
        Test-OemProductPresent -Name 'Dell Optimizer' | Should -BeFalse
    }
}

Describe 'Wait-OemProductGone' {
    BeforeEach {
        $global:OemTestPolls = 0
        Mock Start-Sleep {}
    }

    AfterAll {
        Remove-Variable -Name OemTestPolls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'returns at once, without waiting, when the product is already gone' {
        Mock Test-OemProductPresent { $false }
        Wait-OemProductGone -Name 'X' -TimeoutSec 30 | Should -BeTrue
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'waits for a product that goes away a little later (an uninstaller that relaunched itself and exited)' {
        Mock Test-OemProductPresent { $global:OemTestPolls++; $global:OemTestPolls -le 3 }
        Wait-OemProductGone -Name 'X' -TimeoutSec 30 | Should -BeTrue
        Should -Invoke Start-Sleep -Times 3 -Exactly -ParameterFilter { $Seconds -eq 3 }
    }

    It 'gives up once the time limit is reached while the product stays' {
        Mock Test-OemProductPresent { $true }
        Wait-OemProductGone -Name 'X' -TimeoutSec 9 | Should -BeFalse
        Should -Invoke Start-Sleep -Times 3 -Exactly
    }
}

Describe 'Get-OemProductHint' {
    It 'merges the services, processes, switches and time limit of every hint that fits the product' {
        $OemProductHints = @(
            [PSCustomObject]@{ match = 'Dell SupportAssist*'; services = @('SupportAssistAgent', 'DellHwSvc'); processes = @('SupportAssistAgent') }
            [PSCustomObject]@{ match = 'Dell SupportAssist Remediation'; services = @('SupportAssistAgent', 'Dell SupportAssist Remediation'); silentArgs = '/uninstall /quiet'; timeoutSec = 240 }
            [PSCustomObject]@{ match = 'Dell SupportAssist*'; silentArgs = 'IGNORED'; timeoutSec = 99 }
            [PSCustomObject]@{ match = 'Dell Optimizer*'; services = @('Dell Optimizer') }
        )
        $h = Get-OemProductHint -ProductName 'Dell SupportAssist Remediation'
        $h.Services | Should -BeExactly @('SupportAssistAgent', 'DellHwSvc', 'Dell SupportAssist Remediation')
        $h.Processes | Should -BeExactly @('SupportAssistAgent')
        $h.SilentArgs | Should -BeExactly '/uninstall /quiet'
        $h.TimeoutSec | Should -Be 240
    }

    It 'answers with empty lists, never an error, when nothing fits or there are no hints' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell Optimizer*'; services = @('Dell Optimizer') })
        $h = Get-OemProductHint -ProductName 'Something Else'
        @($h.Services).Count | Should -Be 0
        @($h.Processes).Count | Should -Be 0
        $h.SilentArgs | Should -BeExactly ''
        $h.TimeoutSec | Should -Be 0
        $OemProductHints = @()
        @((Get-OemProductHint -ProductName 'Dell Optimizer').Services).Count | Should -Be 0
        $OemProductHints = $null
        @((Get-OemProductHint -ProductName 'Dell Optimizer').Services).Count | Should -Be 0
    }

    It 'says when a product is shared software whose dependents must be respected' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell Core Services'; respectDependencies = $true }, [PSCustomObject]@{ match = 'Dell Optimizer*'; services = @('x') })
        (Get-OemProductHint -ProductName 'Dell Core Services').RespectDependencies | Should -BeTrue
        (Get-OemProductHint -ProductName 'Dell Optimizer').RespectDependencies | Should -BeFalse
        (Get-OemProductHint -ProductName 'Nothing').RespectDependencies | Should -BeFalse
    }

    It 'ignores a hint without a match pattern' {
        $OemProductHints = @([PSCustomObject]@{ services = @('Everything') }, $null)
        @((Get-OemProductHint -ProductName 'Dell Optimizer').Services).Count | Should -Be 0
    }
}

Describe 'Invoke-OemUninstallLayer time limits' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        Mock Start-Sleep {}
        Mock Wait-WindowsInstallerIdle { $true }
        Mock Get-MsiLogFailureSummary { '' }
        Mock Get-OemMsiEventSummary { @() }
        Mock Start-ProcessLowPriority { $global:OemTestCalls.Add("$TimeoutMs"); New-TestRun -ExitCode 0 }
    }

    It 'gives <Kind> <Seconds> seconds' -ForEach @(
        @{ Kind = 'Msi'; Seconds = 600 }
        @{ Kind = 'Bundle'; Seconds = 600 }
        @{ Kind = 'Exe'; Seconds = 300 }
        @{ Kind = 'Wrapper'; Seconds = 240 }
    ) {
        $layer = [PSCustomObject]@{ Kind = $Kind; FilePath = 'x.exe'; ArgumentList = '/x'; LogPath = '' }
        $null = Invoke-OemUninstallLayer -Layer $layer -ProductName 'X'
        $global:OemTestCalls[0] | Should -BeExactly ([string]($Seconds * 1000))
    }

    It 'waits for an idle Windows Installer before <Kind>: <Times> time(s)' -ForEach @(
        @{ Kind = 'Msi'; Times = 1 }
        @{ Kind = 'Bundle'; Times = 1 }
        @{ Kind = 'Exe'; Times = 0 }
        @{ Kind = 'Wrapper'; Times = 0 }
    ) {
        $layer = [PSCustomObject]@{ Kind = $Kind; FilePath = 'x.exe'; ArgumentList = '/x'; LogPath = '' }
        $null = Invoke-OemUninstallLayer -Layer $layer -ProductName 'X'
        Should -Invoke Wait-WindowsInstallerIdle -Times $Times -Exactly
    }

    It 'takes the limit a product hint asks for' {
        $layer = [PSCustomObject]@{ Kind = 'Wrapper'; FilePath = 'x.exe'; ArgumentList = '/x'; LogPath = '' }
        $null = Invoke-OemUninstallLayer -Layer $layer -ProductName 'X' -TimeoutSec 45
        $global:OemTestCalls[0] | Should -BeExactly '45000'
    }
}

Describe 'Group-OemProductEntries' {
    BeforeAll {
        $script:remediationMsi = New-TestEntry -Name 'Dell SupportAssist Remediation' -Key '{2FF8590E-7853-4A49-8AAF-594975FD2B6C}' -Uninstall 'MsiExec.exe /X{2FF8590E-7853-4A49-8AAF-594975FD2B6C}'
        $script:remediationBundle = New-TestEntry -Name 'Dell SupportAssist Remediation' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall '"C:\ProgramData\Package Cache\{400b816d-1b36-426f-9595-5742bfd07ec4}\x.exe" /uninstall'
        $script:agent = New-TestEntry -Name 'Dell SupportAssist' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}'
        $script:other = New-TestEntry -Name 'Some Other Program' -Key '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        $script:entries = @($script:other, $script:remediationMsi, $script:agent, $script:remediationBundle)
    }

    It 'handles a product that several overlapping patterns match once, with all its installer layers together' {
        $products = @(Group-OemProductEntries -Entries $script:entries -Patterns @('Dell SupportAssist*', 'Dell SupportAssist Remediation', 'Dell SupportAssist OS Recovery*'))
        $products.Count | Should -Be 2
        ($products | ForEach-Object { $_.Name }) | Should -BeExactly @('Dell SupportAssist Remediation', 'Dell SupportAssist')
        @($products[0].Entries).Count | Should -Be 2
        @($products[1].Entries).Count | Should -Be 1
    }

    It 'leaves out everything the patterns do not match' {
        $products = @(Group-OemProductEntries -Entries $script:entries -Patterns @('Dell SupportAssist*'))
        ($products | ForEach-Object { $_.Name }) | Should -Not -Contain 'Some Other Program'
    }

    It 'returns one product for one match, and nothing for no match (always an array)' {
        @(Group-OemProductEntries -Entries $script:entries -Patterns @('Some Other*')).Count | Should -Be 1
        @(Group-OemProductEntries -Entries $script:entries -Patterns @('Nothing Like This*')).Count | Should -Be 0
    }

    It 'groups names that differ only in case, and does not list an entry twice' {
        $a = New-TestEntry -Name 'DELL Optimizer' -Key 'K1' -Uninstall 'MsiExec.exe /X{11111111-1111-1111-1111-111111111111}'
        $b = New-TestEntry -Name 'Dell Optimizer' -Key 'K2' -Uninstall '"C:\x\u.exe" /S'
        $products = @(Group-OemProductEntries -Entries @($a, $b, $a) -Patterns @('Dell Optimizer*', 'DELL*'))
        $products.Count | Should -Be 1
        @($products[0].Entries).Count | Should -Be 2
    }
}

Describe 'Remove-OemWin32Product (the engine, with the registry and the uninstallers stood in)' {
    AfterEach { if ($script:savedRoot) { $env:SystemRoot = $script:savedRoot; $script:savedRoot = $null } }
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $global:OemTestStopCalls = 0
        $global:OemTestRuns = New-Object System.Collections.Generic.Queue[object]
        $global:OemTestInstalled = @()
        $DryRun = $false
        $workDir = $TestDrive
        $OemProductHints = @()
        # a bundle setup in a Package Cache folder, as WiX Burn bundles sit on a real machine
        $bundleDir = Join-Path $TestDrive 'Package Cache\{400b816d-1b36-426f-9595-5742bfd07ec4}'
        $null = New-Item -ItemType Directory -Path $bundleDir -Force
        $fakeExe = Join-Path $bundleDir 'bundle-setup.exe'
        Set-Content -LiteralPath $fakeExe -Value 'x'
        $missingExe = Join-Path $TestDrive 'gone\Uninstall.exe'

        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Start-Sleep {}
        Mock Wait-WindowsInstallerIdle { $true }
        Mock Stop-OemProductActivity { $global:OemTestStopCalls++ }
        Mock Get-MsiLogFailureSummary { '' }
        Mock Get-OemMsiEventSummary { @() }
        Mock Remove-StaleUninstallEntry { $true }
        # The next queued run is what the "uninstaller" returns; a run marked Removes also takes the product out of the registry.
        Mock Start-ProcessLowPriority {
            $global:OemTestCalls.Add("$FilePath $ArgumentList")
            $next = $global:OemTestRuns.Dequeue()
            if ($next.Removes) { $global:OemTestInstalled = @() }
            $next.Run
        }
    }

    BeforeAll {
        function New-TestProduct {
            param([object[]]$Entries)
            [PSCustomObject]@{ Name = $Entries[0].DisplayName; Version = $Entries[0].DisplayVersion; Entries = $Entries }
        }
        function Add-TestRun { param($Run, [bool]$Removes = $false) $global:OemTestRuns.Enqueue([PSCustomObject]@{ Run = $Run; Removes = $Removes }) }
        $msiEntry = New-TestEntry -Name 'Dell SupportAssist' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}'
    }

    It 'removes a product whose MSI uninstall succeeds and the entry is gone' {
        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $r.Status | Should -BeExactly 'Removed'
        $r.Attempts.Count | Should -Be 1
        $global:OemTestCalls[0] | Should -BeLike 'msiexec.exe /x {65043213-393F-49BF-B658-5B06C5F713FF} IGNOREDEPENDENCIES=ALL /qn /norestart /L*v *'
        $global:OemTestLog -join "`n" | Should -BeLike '*exit 0 (success)*'
    }

    It 'says so when a restart finishes the job (3010)' {
        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode 3010) -Removes $true
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $r.Status | Should -BeExactly 'RemovedRestartNeeded'
        $r.RestartNeeded | Should -BeTrue
    }

    It 'tries the bundle first, then the MSI, and stops as soon as the product is gone' {
        $bundleEntry = New-TestEntry -Name 'Dell SupportAssist' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall ('"' + $fakeExe + '" /uninstall')
        $global:OemTestInstalled = @($msiEntry, $bundleEntry)
        Add-TestRun (New-TestRun -ExitCode 1603)                    # the bundle fails
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true       # the MSI works
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry, $bundleEntry))
        $r.Status | Should -BeExactly 'Removed'
        $global:OemTestCalls.Count | Should -Be 2
        $global:OemTestCalls[0] | Should -BeLike "*bundle-setup.exe /uninstall /quiet /norestart*"
        $global:OemTestCalls[1] | Should -BeLike 'msiexec.exe /x *'
        @($r.Attempts | ForEach-Object { $_.Class }) | Should -BeExactly @('Failed', 'Success')
    }

    It 'does not run the second layer when the first one already removed everything' {
        $bundleEntry = New-TestEntry -Name 'Dell SupportAssist' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall ('"' + $fakeExe + '" /uninstall')
        $global:OemTestInstalled = @($msiEntry, $bundleEntry)
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry, $bundleEntry))
        $r.Status | Should -BeExactly 'Removed'
        $global:OemTestCalls.Count | Should -Be 1
    }

    It 'waits out a busy Windows Installer (1618) and tries again' {
        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode 1618)
        Add-TestRun (New-TestRun -ExitCode 1618)
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $r.Status | Should -BeExactly 'Removed'
        $global:OemTestCalls.Count | Should -Be 3
        Should -Invoke Start-Sleep -ParameterFilter { $Seconds -eq 20 } -Times 2 -Exactly
    }

    It 'reports a product that keeps failing, with the exit codes, after a second try (its services are stopped before each try)' {
        $bundleEntry = New-TestEntry -Name 'Dell SupportAssist' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall ('"' + $fakeExe + '" /uninstall')
        $global:OemTestInstalled = @($msiEntry, $bundleEntry)
        1..4 | ForEach-Object { Add-TestRun (New-TestRun -ExitCode 1603) }
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry, $bundleEntry))
        $r.Status | Should -BeExactly 'Failed'
        $r.Attempts.Count | Should -Be 4
        $global:OemTestStopCalls | Should -Be 2 -Because 'the services are stopped before the first and before the second try'
        $r.Detail | Should -BeLike '*Bundle: exit 1603*'
        $r.Detail | Should -BeLike '*Msi: exit 1603 (fatal error during the uninstall)*'
        # the same failure in both passes is said once, with the count
        $r.Detail | Should -BeExactly 'Bundle: exit 1603 (fatal error during the uninstall) (tried 2 times) | Msi: exit 1603 (fatal error during the uninstall) (tried 2 times)'
        $global:OemTestLog -join "`n" | Should -BeLike '*still installed - stopping its services and processes and trying once more*'
    }

    It 'puts the Windows Installer''s own explanation of a failed MSI uninstall into the report' {
        Mock Get-MsiLogFailureSummary { "failed in action 'DellSA_StopServices'; Error 1722. There is a problem with this Windows Installer package" }
        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode 1603)
        Add-TestRun (New-TestRun -ExitCode 1603)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $r.Status | Should -BeExactly 'Failed'
        $r.Detail | Should -BeLike "*Windows Installer says: failed in action 'DellSA_StopServices'; Error 1722*"
        $global:OemTestLog -join "`n" | Should -Match ([regex]::Escape("[WARN]   Windows Installer says: failed in action 'DellSA_StopServices'"))
    }

    It 'falls back to the Application event log when there is no usable verbose log' {
        Mock Get-OemMsiEventSummary { @('event 11708: Product: Dell SupportAssist -- Installation failed.') }
        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode 1603)
        Add-TestRun (New-TestRun -ExitCode 1603)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $r.Detail | Should -BeLike '*Windows Installer says: event 11708: Product: Dell SupportAssist*'
    }

    It 'does not believe an uninstaller that says "success" while the program is still listed' {
        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode 0)
        Add-TestRun (New-TestRun -ExitCode 0)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $r.Status | Should -BeExactly 'Failed'
        $r.Detail | Should -BeLike '*yet the program is still listed in Apps*'
    }

    It 'reports an uninstaller that hung (killed after the time limit), and does not run it a second time to hang again' {
        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode $null -TimedOut $true)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $r.Status | Should -BeExactly 'Failed'
        $r.Detail | Should -BeLike '*did not finish in time*'
        $r.Attempts.Count | Should -Be 1
    }

    It 'reports an uninstaller that could not even be started, and does not try it again' {
        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode $null -Started $false -ErrorText 'Access is denied')
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $r.Status | Should -BeExactly 'Failed'
        $r.Detail | Should -BeLike '*Access is denied*'
        $r.Attempts.Count | Should -Be 1
    }

    It 'runs layers of the same kind in the order the registry lists them (Sort-Object is not stable in Windows PowerShell 5.1)' {
        $codes = '{11111111-1111-1111-1111-111111111111}', '{22222222-2222-2222-2222-222222222222}', '{33333333-3333-3333-3333-333333333333}', '{44444444-4444-4444-4444-444444444444}'
        $entries = @($codes | ForEach-Object { New-TestEntry -Name 'Dell Multi' -Key $_ -Uninstall "MsiExec.exe /X$_" -WindowsInstaller 1 })
        $global:OemTestInstalled = $entries
        1..4 | ForEach-Object { Add-TestRun (New-TestRun -ExitCode 1603) }
        $null = Remove-OemWin32Product -Product (New-TestProduct $entries) -Passes 1
        $global:OemTestCalls.Count | Should -Be 4
        for ($i = 0; $i -lt 4; $i++) { $global:OemTestCalls[$i] | Should -BeLike "msiexec.exe /x $($codes[$i]) *" }
    }

    It 'logs the exact command line of every attempt, and the installer''s log path with the reason it failed' {
        $bundleEntry = New-TestEntry -Name 'Dell SupportAssist' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall ('"' + $fakeExe + '" /uninstall')
        $global:OemTestInstalled = @($bundleEntry)
        Mock Start-ProcessLowPriority {
            # a Burn bundle writes its log where /log says
            $logPath = [regex]::Match($ArgumentList, '/log "([^"]+)"').Groups[1].Value
            if ($logPath) { Set-Content -LiteralPath $logPath -Value 'burn log' }
            $global:OemTestCalls.Add("$FilePath $ArgumentList")
            New-TestRun -ExitCode -2147023293
        }
        $r = Remove-OemWin32Product -Product (New-TestProduct @($bundleEntry))
        $text = $global:OemTestLog -join "`n"
        $text | Should -BeLike "*Running the Bundle uninstaller for 'Dell SupportAssist': `"$fakeExe`" /uninstall /quiet /norestart /log *"
        $text | Should -BeLike '*exit 1603 (0x80070643) (fatal error during the uninstall)*'
        $r.Detail | Should -BeLike '*Bundle: exit 1603 (0x80070643) (fatal error during the uninstall)*; verbose log *uninstall_Dell_SupportAssist_*'
    }

    It 'does not announce another try when every layer has hit a wall' {
        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode 1612)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $r.Status | Should -BeExactly 'Failed'
        $r.Attempts.Count | Should -Be 1
        $global:OemTestStopCalls | Should -Be 1
        $global:OemTestLog -join "`n" | Should -Not -BeLike '*trying once more*'
    }

    It 'runs an InstallShield wrapper before the MSI it wraps, and a plain EXE after the MSI' {
        $wrapperDir = Join-Path $TestDrive 'Program Files (x86)\InstallShield Installation Information\{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}'
        $null = New-Item -ItemType Directory -Path $wrapperDir -Force
        $wrapper = Join-Path $wrapperDir 'DellOptimizer_MyDell.exe'
        Set-Content -LiteralPath $wrapper -Value 'x'
        $plainExe = Join-Path $TestDrive 'Program Files\Vendor\uninst.exe'
        $null = New-Item -ItemType Directory -Path (Split-Path $plainExe -Parent) -Force
        Set-Content -LiteralPath $plainExe -Value 'x'
        $opt = New-TestEntry -Name 'Dell Optimizer' -Key '{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}' -Uninstall ('"' + $wrapper + '" -remove -runfromtemp')
        $optMsi = New-TestEntry -Name 'Dell Optimizer' -Key '{1344E072-D68B-48FF-BD2A-C1CCCC511A50}' -Uninstall 'MsiExec.exe /X{1344E072-D68B-48FF-BD2A-C1CCCC511A50}' -WindowsInstaller 1
        $mcafeeUi = New-TestEntry -Name 'Dell Optimizer' -Key 'UiFrontEnd' -Uninstall ('"' + $plainExe + '" -interactive')
        $global:OemTestInstalled = @($optMsi, $opt, $mcafeeUi)
        1..3 | ForEach-Object { Add-TestRun (New-TestRun -ExitCode 1603) }
        $null = Remove-OemWin32Product -Product (New-TestProduct @($optMsi, $opt, $mcafeeUi)) -Passes 1
        $global:OemTestCalls.Count | Should -Be 3
        $global:OemTestCalls[0] | Should -BeLike '*DellOptimizer_MyDell.exe*'
        $global:OemTestCalls[1] | Should -BeLike 'msiexec.exe /x *'
        $global:OemTestCalls[2] | Should -BeLike '*uninst.exe*'
    }

    It 'does not repeat a layer that was told a restart is pending, and says to restart' {
        $bundleEntry = New-TestEntry -Name 'Dell SupportAssist' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall ('"' + $fakeExe + '" /uninstall')
        $global:OemTestInstalled = @($msiEntry, $bundleEntry)
        Add-TestRun (New-TestRun -ExitCode -2147024546)    # the bundle: 0x8007015E, "no action was taken as a system reboot is required"
        Add-TestRun (New-TestRun -ExitCode 1603)           # the MSI
        Add-TestRun (New-TestRun -ExitCode 1603)           # the MSI again in the second pass; the bundle is not asked again
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry, $bundleEntry))
        $r.Status | Should -BeExactly 'Failed'
        @($r.Attempts | ForEach-Object { $_.Class }) | Should -BeExactly @('RebootFirst', 'Failed', 'Failed')
        $r.Detail | Should -BeLike '*Bundle: exit 350*restart the PC, then run the clean-up again*'
    }

    It 'does not repeat a layer whose cached installer is gone (1612) or that a policy blocks (1625)' {
        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode 1612)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $r.Attempts.Count | Should -Be 1
        $r.Status | Should -BeExactly 'Failed'

        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode 1625)
        (Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))).Attempts.Count | Should -Be 1
    }

    It 'removes shared software without overriding the dependency check, and says why it may stay' {
        $dcs = New-TestEntry -Name 'Dell Core Services' -Key '{12345678-1234-1234-1234-123456789ABC}' -Uninstall 'MsiExec.exe /X{12345678-1234-1234-1234-123456789ABC}' -WindowsInstaller 1
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell Core Services'; respectDependencies = $true })
        $global:OemTestInstalled = @($dcs)
        Add-TestRun (New-TestRun -ExitCode 0)    # the dependency check skips the uninstall: exit 0, nothing removed
        Add-TestRun (New-TestRun -ExitCode 0)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($dcs))
        $global:OemTestCalls[0] | Should -Not -BeLike '*IGNOREDEPENDENCIES*'
        $r.Status | Should -BeExactly 'Failed'
        $r.Detail | Should -BeLike '*yet the program is still listed in Apps*'
        $r.Detail | Should -BeLike '*shared with other Dell software*'
    }

    It 'does nothing for a product that is already gone when its turn comes (taken along by an earlier program), and leaves its services alone' {
        $global:OemTestInstalled = @()
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $r.Status | Should -BeExactly 'Removed'
        $global:OemTestCalls.Count | Should -Be 0
        $global:OemTestStopCalls | Should -Be 0
        $global:OemTestLog -join "`n" | Should -BeLike "*'Dell SupportAssist' is already gone - nothing to uninstall*"
    }

    It 'does not run an uninstaller that an earlier layer took away, and clears its leftover entry (an MSI that removes the folder of an EXE uninstaller)' {
        $exeDir = Join-Path $TestDrive 'Program Files\McAfee\LiveSafe'
        $null = New-Item -ItemType Directory -Path $exeDir -Force
        $ui = Join-Path $exeDir 'mcuihost.exe'
        Set-Content -LiteralPath $ui -Value 'x'
        $mcMsi = New-TestEntry -Name 'McAfee LiveSafe' -Key '{AAAAAAAA-0000-0000-0000-000000000001}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-0000-0000-0000-000000000001}' -WindowsInstaller 1
        $mcUi = New-TestEntry -Name 'McAfee LiveSafe' -Key 'McAfeeUi' -Uninstall ('"' + $ui + '" /uninstall')
        $global:OemTestInstalled = @($mcMsi, $mcUi)
        Mock Start-ProcessLowPriority {
            $global:OemTestCalls.Add("$FilePath $ArgumentList")
            # the MSI works: it removes its own entry AND the folder with the EXE uninstaller, but the EXE's Apps entry stays behind
            Remove-Item -LiteralPath $ui -Force
            $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.PSChildName -eq 'McAfeeUi' })
            New-TestRun -ExitCode 0
        }
        Mock Remove-StaleUninstallEntry { $global:OemTestInstalled = @(); $true }
        $r = Remove-OemWin32Product -Product (New-TestProduct @($mcMsi, $mcUi))
        $r.Status | Should -BeExactly 'Removed' -Because 'an uninstaller really ran and worked; the dead entry was only the leftover of it'
        $global:OemTestCalls.Count | Should -Be 1
        Should -Invoke Remove-StaleUninstallEntry -Times 1 -Exactly -ParameterFilter { $PsPath -like '*\McAfeeUi' }
        $global:OemTestLog -join "`n" | Should -BeLike "*The Exe uninstaller of 'McAfee LiveSafe' is gone*an earlier step removed it*"
    }

    It 'does not run a layer whose own Apps entry an earlier layer already unregistered' {
        $bundleEntry = New-TestEntry -Name 'Dell SupportAssist' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall ('"' + $fakeExe + '" /uninstall')
        $global:OemTestInstalled = @($msiEntry, $bundleEntry)
        Mock Start-ProcessLowPriority {
            $global:OemTestCalls.Add("$FilePath $ArgumentList")
            # the bundle fails, but takes the chained MSI's entry away on its way out
            $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.PSChildName -ne '{65043213-393F-49BF-B658-5B06C5F713FF}' })
            New-TestRun -ExitCode 1603
        }
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry, $bundleEntry))
        @($global:OemTestCalls | Where-Object { $_ -like 'msiexec*' }).Count | Should -Be 0
        $global:OemTestLog -join "`n" | Should -BeLike "*The Msi entry of 'Dell SupportAssist' is gone already - nothing left to run for it*"
    }

    It 'does not repeat a layer that says the product is not installed, and does not wait for it to disappear' {
        Mock Wait-OemProductGone { $true }
        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode 1605)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $r.Attempts.Count | Should -Be 1
        Should -Invoke Wait-OemProductGone -Times 0 -Exactly
    }

    It 'gives a product hint''s time limit to its own EXE, wrapper and bundle uninstallers, and leaves the MSI its own' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell SupportAssist*'; timeoutSec = 123 })
        $bundleEntry = New-TestEntry -Name 'Dell SupportAssist' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall ('"' + $fakeExe + '" /uninstall')
        $global:OemTestInstalled = @($msiEntry, $bundleEntry)
        Mock Start-ProcessLowPriority { $global:OemTestCalls.Add("$TimeoutMs"); New-TestRun -ExitCode 1603 }
        $null = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry, $bundleEntry)) -Passes 1
        @($global:OemTestCalls) | Should -BeExactly @('123000', '600000')
    }

    It 'skips the layers it is told hit a wall earlier, and reports the ones that hit a wall now' {
        $bundleEntry = New-TestEntry -Name 'Dell SupportAssist' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall ('"' + $fakeExe + '" /uninstall')
        $global:OemTestInstalled = @($msiEntry, $bundleEntry)
        Add-TestRun (New-TestRun -ExitCode 1603)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry, $bundleEntry)) -Passes 1 -SkipPsPaths @($bundleEntry.PSPath)
        $global:OemTestCalls.Count | Should -Be 1
        $global:OemTestCalls[0] | Should -BeLike 'msiexec.exe /x *'

        $global:OemTestCalls.Clear()
        Add-TestRun (New-TestRun -ExitCode -2147024546)    # the bundle: restart pending
        Add-TestRun (New-TestRun -ExitCode 1603)
        $r2 = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry, $bundleEntry)) -Passes 1
        $r2.WallPsPaths | Should -Be @($bundleEntry.PSPath)
    }

    It 'says to restart when an uninstaller finished and asked for one but the program is still listed, and marks the result' {
        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode 3010)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry)) -Passes 1
        $r.Status | Should -BeExactly 'Failed'
        $r.RestartNeeded | Should -BeTrue
        $r.Detail | Should -BeLike '*exit 3010*yet the program is still listed in Apps; restart the PC, then run the clean-up again*'
    }

    It 'makes a single pass when asked to' {
        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode 1603)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry)) -Passes 1
        $r.Attempts.Count | Should -Be 1
        $global:OemTestStopCalls | Should -Be 1
    }

    It 'tries the next layer when one hangs' {
        $bundleEntry = New-TestEntry -Name 'Dell SupportAssist' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall ('"' + $fakeExe + '" /uninstall')
        $global:OemTestInstalled = @($msiEntry, $bundleEntry)
        Add-TestRun (New-TestRun -ExitCode $null -TimedOut $true)    # the bundle hangs
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true         # the MSI still works
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry, $bundleEntry))
        $r.Status | Should -BeExactly 'Removed'
        @($r.Attempts | ForEach-Object { $_.Class }) | Should -BeExactly @('TimedOut', 'Success')
    }

    It 'clears a dead registration: Windows Installer says "not installed" but the entry stays' {
        # the entry must really exist in a registry for the engine to try clearing it: Pester's throw-away registry stands in
        $null = New-Item -Path 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\DeadMsi' -Force
        $dead = New-TestEntry -Name 'Dell SupportAssist' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}' -Location (Join-Path $TestDrive 'gone\Dell\SupportAssistAgent')
        $dead.PSPath = (Get-Item -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\DeadMsi').PSPath
        $global:OemTestInstalled = @($dead)
        Add-TestRun (New-TestRun -ExitCode 1605)
        Add-TestRun (New-TestRun -ExitCode 1605)
        Mock Remove-StaleUninstallEntry { $global:OemTestInstalled = @(); $true }
        $r = Remove-OemWin32Product -Product (New-TestProduct @($dead))
        $r.Status | Should -BeExactly 'StaleEntryCleared'
        Should -Invoke Remove-StaleUninstallEntry -Times 1 -Exactly
    }

    It 'clears an entry whose uninstaller file is gone (Dell Pair) instead of skipping it' {
        $pair = New-TestEntry -Name 'Dell Pair' -Key 'DellPair' -Uninstall ('"' + $missingExe + '"')
        $global:OemTestInstalled = @($pair)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($pair))
        $r.Status | Should -BeExactly 'StaleEntryCleared'
        $global:OemTestCalls.Count | Should -Be 0
        Should -Invoke Remove-StaleUninstallEntry -Times 1 -Exactly -ParameterFilter { $PsPath -like '*\DellPair' }
    }

    It 'does not clear an entry whose uninstaller is gone while the folder that held it is still full of files' {
        $folder = Join-Path $TestDrive 'Program Files\Dell\Dell Pair2'
        $null = New-Item -ItemType Directory -Path $folder -Force
        Set-Content -LiteralPath (Join-Path $folder 'pair.exe') -Value 'x'
        $pair = New-TestEntry -Name 'Dell Pair' -Key 'DellPair' -Uninstall ('"' + (Join-Path $folder 'Uninstall.exe') + '"')
        $global:OemTestInstalled = @($pair)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($pair))
        $r.Status | Should -BeExactly 'Failed'
        $r.Detail | Should -BeLike "*the program's folder still exists ($folder)*"
        Should -Invoke Remove-StaleUninstallEntry -Times 0 -Exactly
    }

    It 'finds and runs an uninstaller when the vendor quoted the whole command (it must not be taken for a leftover)' {
        $folder = Join-Path $TestDrive 'Program Files\Dell\Dell Widget'
        $null = New-Item -ItemType Directory -Path $folder -Force
        $uninstaller = Join-Path $folder 'uninstall.exe'
        Set-Content -LiteralPath $uninstaller -Value 'x'
        $widget = New-TestEntry -Name 'Dell Widget' -Key 'DellWidget' -Uninstall ('"' + $uninstaller + ' /S"')
        $global:OemTestInstalled = @($widget)
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true
        $r = Remove-OemWin32Product -Product (New-TestProduct @($widget))
        $r.Status | Should -BeExactly 'Removed'
        $global:OemTestCalls[0] | Should -BeExactly "$uninstaller /S"
        Should -Invoke Remove-StaleUninstallEntry -Times 0 -Exactly
    }

    It 'does not clear an entry whose icon file, or whose service, shows the program is still there' {
        # (the icon file lies in $TestDrive, which is under the Windows folder when Pester runs as SYSTEM; icons in the Windows folder do not count)
        $script:savedRoot = $env:SystemRoot
        $env:SystemRoot = 'Z:\OemNoSuchWindowsFolder'
        $dir = Join-Path $TestDrive 'Program Files\Dell\Dell Icon'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $icon = Join-Path $dir 'app.ico'
        Set-Content -LiteralPath $icon -Value 'x'
        $gone = Join-Path $TestDrive 'elsewhere\Uninstall.exe'
        $withIcon = New-TestEntry -Name 'Dell Icon' -Key 'DellIcon' -Uninstall ('"' + $gone + '"')
        $withIcon | Add-Member -NotePropertyName DisplayIcon -NotePropertyValue "$icon,0" -Force
        $global:OemTestInstalled = @($withIcon)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($withIcon))
        $r.Status | Should -BeExactly 'Failed'
        $r.Detail | Should -BeLike '*the program still seems to be installed*Apps icon points at still exists*'

        $OemProductHints = @([PSCustomObject]@{ match = 'Dell Svc'; services = @('DellSvcAgent') })
        Mock Get-Service { [PSCustomObject]@{ Name = 'DellSvcAgent'; DisplayName = 'Dell Svc Agent' } }
        $withService = New-TestEntry -Name 'Dell Svc' -Key 'DellSvc' -Uninstall ('"' + $gone + '"')
        $global:OemTestInstalled = @($withService)
        $r2 = Remove-OemWin32Product -Product (New-TestProduct @($withService))
        $r2.Status | Should -BeExactly 'Failed'
        $r2.Detail | Should -BeLike "*its service 'DellSvcAgent' still exists*"
        Should -Invoke Remove-StaleUninstallEntry -Times 0 -Exactly
    }

    It 'says in a dry run what would happen to an entry nothing can be run for' {
        $DryRun = $true
        $gone = Join-Path $TestDrive 'dry\Uninstall.exe'
        $stale = New-TestEntry -Name 'Dell Stale' -Key 'DellStale' -Uninstall ('"' + $gone + '"')
        $odd = New-TestEntry -Name 'Dell Odd' -Key 'DellOdd' -Uninstall 'launch the thing somehow'
        $null = Remove-OemWin32Product -Product (New-TestProduct @($stale))
        $null = Remove-OemWin32Product -Product (New-TestProduct @($odd))
        $text = $global:OemTestLog -join "`n"
        $text | Should -BeLike "*DRYRUN: Dell Stale - no usable uninstaller; its Apps entry would be cleared as a leftover (a .reg backup is saved first)*"
        $text | Should -BeLike "*DRYRUN: Dell Odd - no usable uninstaller; it would be reported as NOT REMOVED*"
        Should -Invoke Remove-StaleUninstallEntry -Times 0 -Exactly
    }

    It 'still clears it when the folder that held the uninstaller is empty or is only an installer cache' {
        $empty = Join-Path $TestDrive 'Program Files\Dell\Dell Pair3'
        $null = New-Item -ItemType Directory -Path $empty -Force
        $pair = New-TestEntry -Name 'Dell Pair' -Key 'DellPair' -Uninstall ('"' + (Join-Path $empty 'Uninstall.exe') + '"')
        $global:OemTestInstalled = @($pair)
        (Remove-OemWin32Product -Product (New-TestProduct @($pair))).Status | Should -BeExactly 'StaleEntryCleared'

        # (an installer cache is not a program folder; the bundle still registers an install folder - which is gone - so there is something to look at)
        $cache = Join-Path $TestDrive 'Package Cache\{11111111-1111-1111-1111-111111111111}'
        $null = New-Item -ItemType Directory -Path $cache -Force
        Set-Content -LiteralPath (Join-Path $cache 'payload.cab') -Value 'x'
        $bundle = New-TestEntry -Name 'Dell Bundle' -Key '{11111111-1111-1111-1111-111111111111}' -Uninstall ('"' + (Join-Path $cache 'setup.exe') + '" /uninstall') -Location (Join-Path $TestDrive 'gone\Dell Bundle')
        $global:OemTestInstalled = @($bundle)
        (Remove-OemWin32Product -Product (New-TestProduct @($bundle))).Status | Should -BeExactly 'StaleEntryCleared'
    }

    It 'keeps and reports an entry whose uninstaller sat in an installer cache when it registers nothing else that could be looked at' {
        $cache = Join-Path $TestDrive 'Package Cache\{22222222-2222-2222-2222-222222222222}'
        $null = New-Item -ItemType Directory -Path $cache -Force
        Set-Content -LiteralPath (Join-Path $cache 'payload.cab') -Value 'x'
        $bundle = New-TestEntry -Name 'Dell Bundle' -Key '{22222222-2222-2222-2222-222222222222}' -Uninstall ('"' + (Join-Path $cache 'setup.exe') + '" /uninstall')
        $global:OemTestInstalled = @($bundle)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($bundle))
        $r.Status | Should -BeExactly 'Failed'
        Should -Invoke Remove-StaleUninstallEntry -Times 0 -Exactly
        $r.Detail | Should -BeLike '*its uninstaller file is missing*registers nothing that could show whether the program is still installed*delete the key by hand (export it first) (registry key: HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{22222222-2222-2222-2222-222222222222})*'
    }

    It 'reports an entry whose uninstaller is gone and which cannot be cleared' {
        Mock Remove-StaleUninstallEntry { $false }
        $pair = New-TestEntry -Name 'Dell Pair' -Key 'DellPair' -Uninstall ('"' + $missingExe + '"')
        $global:OemTestInstalled = @($pair)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($pair))
        $r.Status | Should -BeExactly 'Failed'
        $r.Detail | Should -BeLike '*its uninstaller file is missing*'
        $r.Detail | Should -BeLike '*could not be cleared*'
    }

    It 'never deletes an entry just because its command cannot be read' {
        $odd = New-TestEntry -Name 'Dell Pair' -Key 'DellPair' -Uninstall 'launch the thing somehow'
        $global:OemTestInstalled = @($odd)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($odd))
        $r.Status | Should -BeExactly 'Failed'
        $r.Detail | Should -BeLike "*its uninstall command cannot be read ('launch the thing somehow')*"
        Should -Invoke Remove-StaleUninstallEntry -Times 0 -Exactly
        $global:OemTestCalls.Count | Should -Be 0
    }

    It 'never deletes an entry that has no uninstall command at all' {
        $empty = New-TestEntry -Name 'Dell Pair' -Key 'DellPair' -Uninstall ''
        $global:OemTestInstalled = @($empty)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($empty))
        $r.Status | Should -BeExactly 'Failed'
        $r.Detail | Should -BeLike '*no uninstall command registered*'
        Should -Invoke Remove-StaleUninstallEntry -Times 0 -Exactly
    }

    It 'does not clear an entry whose uninstaller file is gone while the program''s folder is still there' {
        $folder = Join-Path $TestDrive 'Program Files\Dell\Dell Pair'
        $null = New-Item -ItemType Directory -Path $folder -Force
        Set-Content -LiteralPath (Join-Path $folder 'pair.dll') -Value 'x'
        $pair = New-TestEntry -Name 'Dell Pair' -Key 'DellPair' -Uninstall ('"' + $missingExe + '"') -Location $folder
        $global:OemTestInstalled = @($pair)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($pair))
        $r.Status | Should -BeExactly 'Failed'
        $r.Detail | Should -BeLike "*the program's folder still exists*"
        Should -Invoke Remove-StaleUninstallEntry -Times 0 -Exactly
    }

    It 'does clear an entry whose uninstaller file is gone when the program''s folder is only an EMPTY leftover' {
        $folder = Join-Path $TestDrive 'Program Files\Dell\Dell Pair Empty'
        $null = New-Item -ItemType Directory -Path $folder -Force
        $pair = New-TestEntry -Name 'Dell Pair' -Key 'DellPair' -Uninstall ('"' + $missingExe + '"') -Location $folder
        $global:OemTestInstalled = @($pair)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($pair))
        $r.Status | Should -BeExactly 'StaleEntryCleared'
        Should -Invoke Remove-StaleUninstallEntry -Times 1 -Exactly
    }

    It 'finds and runs an uninstaller whose unquoted path contains spaces (Dell Pair, Dell Peripheral Manager)' {
        $folder = Join-Path $TestDrive 'Program Files\Dell\Dell Pair'
        $null = New-Item -ItemType Directory -Path $folder -Force
        $uninstaller = Join-Path $folder 'Uninstall.exe'
        Set-Content -LiteralPath $uninstaller -Value 'x'
        $pair = New-TestEntry -Name 'Dell Pair' -Key 'DellPair' -Uninstall $uninstaller
        $global:OemTestInstalled = @($pair)
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true
        $r = Remove-OemWin32Product -Product (New-TestProduct @($pair))
        $r.Status | Should -BeExactly 'Removed'
        $global:OemTestCalls[0] | Should -BeExactly "$uninstaller /S"
        Should -Invoke Remove-StaleUninstallEntry -Times 0 -Exactly
    }

    It 'gives an uninstaller that relaunches itself and exits at once (NSIS) longer to disappear from the Apps list' {
        $folder = Join-Path $TestDrive 'Program Files\Dell\Dell Pair'
        $null = New-Item -ItemType Directory -Path $folder -Force
        $uninstaller = Join-Path $folder 'Uninstall.exe'
        Set-Content -LiteralPath $uninstaller -Value 'x'
        $pair = New-TestEntry -Name 'Dell Pair' -Key 'DellPair' -Uninstall ('"' + $uninstaller + '" /S')
        $global:OemTestInstalled = @($pair)
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true
        Mock Wait-OemProductGone { $true }
        $null = Remove-OemWin32Product -Product (New-TestProduct @($pair))
        Should -Invoke Wait-OemProductGone -Times 1 -Exactly -ParameterFilter { $TimeoutSec -eq 90 }
    }

    It 'uses the silent switches a product hint names instead of the ones in the registry string (Dell Optimizer wrapper)' {
        $folder = Join-Path $TestDrive 'Program Files (x86)\InstallShield Installation Information\{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}'
        $null = New-Item -ItemType Directory -Path $folder -Force
        $wrapper = Join-Path $folder 'DellOptimizer_MyDell.exe'
        Set-Content -LiteralPath $wrapper -Value 'x'
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell Optimizer*'; silentArgs = '-remove -runfromtemp /Silent' })
        $opt = New-TestEntry -Name 'Dell Optimizer' -Key '{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}' -Uninstall ('"' + $wrapper + '" -remove -runfromtemp')
        $global:OemTestInstalled = @($opt)
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true
        $r = Remove-OemWin32Product -Product (New-TestProduct @($opt))
        $r.Status | Should -BeExactly 'Removed'
        $global:OemTestCalls[0] | Should -BeExactly "$wrapper -remove -runfromtemp /Silent"
    }

    It 'clears only the MSI entry that Windows Installer calls "not installed", not the other entries of the product' {
        $null = New-Item -Path 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\DeadMsi2' -Force
        $msiPath = (Get-Item -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\DeadMsi2').PSPath
        $dead = New-TestEntry -Name 'Dell SupportAssist' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}' -Location (Join-Path $TestDrive 'gone\Dell\SupportAssistAgent')
        $dead.PSPath = $msiPath
        $bundleEntry = New-TestEntry -Name 'Dell SupportAssist' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall ('"' + $fakeExe + '" /uninstall')
        $global:OemTestInstalled = @($dead, $bundleEntry)
        1..2 | ForEach-Object {                                              # two passes: the bundle first, then the MSI
            Add-TestRun (New-TestRun -ExitCode 1603)
            Add-TestRun (New-TestRun -ExitCode 1605)
        }
        $r = Remove-OemWin32Product -Product (New-TestProduct @($dead, $bundleEntry))
        $r.Status | Should -BeExactly 'Failed'
        Should -Invoke Remove-StaleUninstallEntry -Times 1 -Exactly -ParameterFilter { $PsPath -eq $msiPath }
        $r.Detail | Should -BeLike '*Bundle: exit 1603*'
    }

    It 'keeps the verbose Windows Installer log of a product it could not remove, and hands the logs of one it removed on to be deleted after the last look' {
        $global:OemTestInstalled = @($msiEntry)
        Mock Start-ProcessLowPriority {
            # the real msiexec writes the /L*v log; the stand-in does the same
            $logPath = [regex]::Match($ArgumentList, '/L\*v "([^"]+)"').Groups[1].Value
            Set-Content -LiteralPath $logPath -Value 'verbose log'
            $global:OemTestCalls.Add("$FilePath $ArgumentList")
            New-TestRun -ExitCode 1603
        }
        $failed = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $failed.Status | Should -BeExactly 'Failed'
        $logs = @(Get-ChildItem -LiteralPath $TestDrive -Filter 'uninstall_Dell_SupportAssist_*.log')
        $logs.Count | Should -BeGreaterThan 0
        $failed.Detail | Should -BeLike "*verbose log $TestDrive*uninstall_Dell_SupportAssist_*"

        foreach ($l in $logs) { Remove-Item -LiteralPath $l.FullName -Force }
        Mock Start-ProcessLowPriority {
            $logPath = [regex]::Match($ArgumentList, '/L\*v "([^"]+)"').Groups[1].Value
            Set-Content -LiteralPath $logPath -Value 'verbose log'
            $global:OemTestInstalled = @()
            New-TestRun -ExitCode 0
        }
        $global:OemTestInstalled = @($msiEntry)
        $removed = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $removed.Status | Should -BeExactly 'Removed'
        # (Remove-OemBloatware deletes them after its last look at the Apps list: a program that is listed again keeps its logs)
        @($removed.LogLayers).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $TestDrive -Filter 'uninstall_Dell_SupportAssist_*.log').Count | Should -Be 1
        Remove-OemUninstallLogs -Layers @($removed.LogLayers)
        @(Get-ChildItem -LiteralPath $TestDrive -Filter 'uninstall_Dell_SupportAssist_*.log').Count | Should -Be 0
    }

    It 'starts nothing in a dry run' {
        $DryRun = $true
        $global:OemTestInstalled = @($msiEntry)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $r.Status | Should -BeExactly 'DryRun'
        $global:OemTestCalls.Count | Should -Be 0
        $global:OemTestLog -join "`n" | Should -BeLike '*DRYRUN: Uninstalling: Dell SupportAssist*'
    }
}

Describe 'Remove-OemAppxPackages (Store apps, with the package cmdlets stood in)' {
    BeforeAll {
        # The Store-app cmdlets come with Windows PowerShell; PowerShell 7 reaches them only through its compatibility layer, so
        # give Pester something to mock where they are absent.
        $global:OemTestAppxStubs = @()
        foreach ($cmd in 'Get-AppxPackage', 'Get-AppxProvisionedPackage', 'Remove-AppxProvisionedPackage') {
            if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
                Set-Item -Path "Function:global:$cmd" -Value { param($AllUsers, $Online, $PackageName) }
                $global:OemTestAppxStubs += $cmd
            }
        }
    }

    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $DryRun = $false
        $ProtectWorkTeams = $true
        $OemBloatAppxPatterns = @('DellInc.DellSupportAssistforPCs', '*McAfee*', '*Teams*', 'DellInc.*')
        # what is installed / provisioned right now
        $global:OemTestAppx = @(
            [PSCustomObject]@{ Name = 'DellInc.DellSupportAssistforPCs'; PackageFullName = 'DellInc.DellSupportAssistforPCs_5.2.1.0_x64__htrsf667h5kn2' }
            [PSCustomObject]@{ Name = 'MicrosoftTeams'; PackageFullName = 'MicrosoftTeams_25016.2101.3363.9739_x64__8wekyb3d8bbwe' }
            [PSCustomObject]@{ Name = 'MSTeams'; PackageFullName = 'MSTeams_24000.1.1.0_x64__8wekyb3d8bbwe' }
            [PSCustomObject]@{ Name = 'Microsoft.WindowsCalculator'; PackageFullName = 'Microsoft.WindowsCalculator_1.0.0.0_x64__8wekyb3d8bbwe' }
        )
        $global:OemTestProvisioned = @(
            [PSCustomObject]@{ DisplayName = 'DellInc.DellSupportAssistforPCs'; PackageName = 'DellInc.DellSupportAssistforPCs_5.2.1.0_x64__htrsf667h5kn2' }
            [PSCustomObject]@{ DisplayName = 'MSTeams'; PackageName = 'MSTeams_24000.1.1.0_x64__8wekyb3d8bbwe' }
        )
        $global:OemTestDeprovisionFails = @()
        $global:OemTestRemoveFails = @()
        Mock Get-AppxPackage { $global:OemTestAppx }
        Mock Get-AppxProvisionedPackage { $global:OemTestProvisioned }
        Mock Remove-AppxProvisionedPackage {
            $global:OemTestCalls.Add("deprovision $PackageName")
            if ($global:OemTestDeprovisionFails -contains $PackageName) { throw 'The system cannot find the file specified.' }
            $global:OemTestProvisioned = @($global:OemTestProvisioned | Where-Object { $_.PackageName -ne $PackageName })
        }
        # the real one runs the removals in background runspaces, where no stand-in could reach: simulate the outcome here
        Mock Invoke-ThrottledSteps {
            foreach ($step in $Steps) {
                $global:OemTestCalls.Add("remove $($step.Args.FullName)")
                if ($global:OemTestRemoveFails -notcontains $step.Args.FullName) {
                    $global:OemTestAppx = @($global:OemTestAppx | Where-Object { $_.PackageFullName -ne $step.Args.FullName })
                }
            }
        }
    }

    AfterAll {
        foreach ($cmd in @($global:OemTestAppxStubs)) { Remove-Item -Path "Function:global:$cmd" -ErrorAction SilentlyContinue }
        Remove-Variable -Name OemTestAppx, OemTestProvisioned, OemTestDeprovisionFails, OemTestRemoveFails, OemTestAppxStubs -Scope Global -ErrorAction SilentlyContinue
    }

    It 'de-provisions first and removes for all users after, and reports both done' {
        $r = Remove-OemAppxPackages
        $global:OemTestCalls[0] | Should -BeLike 'deprovision DellInc.DellSupportAssistforPCs_*'
        $calls = $global:OemTestCalls.ToArray()
        $firstDeprovision = 0..($calls.Count - 1) | Where-Object { $calls[$_] -like 'deprovision *' } | Select-Object -First 1
        $firstRemove = 0..($calls.Count - 1) | Where-Object { $calls[$_] -like 'remove *' } | Select-Object -First 1
        $firstDeprovision | Should -BeLessThan $firstRemove
        $r.Removed | Should -Be 2
        $r.Failed | Should -Be 0
        $global:OemTestLog -join "`n" | Should -BeLike '*De-provisioned: DellInc.DellSupportAssistforPCs*'
        @($global:OemTestLog | Where-Object { $_ -like '`[WARN`]*' -and $_ -notlike '*work/school Teams*' }).Count | Should -Be 0
    }

    It 'never touches work/school Teams (MSTeams) while it is protected, and says so' {
        $r = Remove-OemAppxPackages
        ($global:OemTestCalls | Where-Object { $_ -like '*MSTeams*' }).Count | Should -Be 0
        $global:OemTestLog -join "`n" | Should -BeLike "*Skipping removal of 'MSTeams'*protected by -ProtectWorkTeams*"
    }

    It 'treats a de-provisioning error as harmless when the package is no longer provisioned afterwards (the old false alarm)' {
        Mock Remove-AppxProvisionedPackage {
            $global:OemTestCalls.Add("deprovision $PackageName")
            $global:OemTestProvisioned = @($global:OemTestProvisioned | Where-Object { $_.PackageName -ne $PackageName })
            throw 'The system cannot find the file specified.'
        }
        $r = Remove-OemAppxPackages
        $r.Failed | Should -Be 0
        @($global:OemTestLog | Where-Object { $_ -like '`[WARN`]*Still provisioned*' }).Count | Should -Be 0
    }

    It 'warns when a package is still provisioned after the pass, with the reason' {
        $global:OemTestDeprovisionFails = @('DellInc.DellSupportAssistforPCs_5.2.1.0_x64__htrsf667h5kn2')
        $r = Remove-OemAppxPackages
        $global:OemTestLog -join "`n" | Should -Match ([regex]::Escape('[WARN] Still provisioned after de-provisioning: DellInc.DellSupportAssistforPCs'))
        $global:OemTestLog -join "`n" | Should -BeLike '*cannot find the file specified*'
    }

    It 'names a package that is still installed after the removal' {
        $global:OemTestRemoveFails = @('MicrosoftTeams_25016.2101.3363.9739_x64__8wekyb3d8bbwe')
        $r = Remove-OemAppxPackages
        $r.Failed | Should -Be 1
        $r.FailedNames | Should -Contain 'MicrosoftTeams_25016.2101.3363.9739_x64__8wekyb3d8bbwe'
        $r.Removed | Should -Be 1
    }

    It 'does not count Store apps as removed when the list they must be checked against cannot be read afterwards' {
        $global:OemTestAfterFails = $false
        Mock Get-AppxPackage { if ($global:OemTestAfterFails) { throw 'The Appx deployment service is not available' } else { $global:OemTestAppx } }
        Mock Invoke-ThrottledSteps { $global:OemTestAfterFails = $true }    # the removals ran; from now on the installed list cannot be read
        $r = Remove-OemAppxPackages
        $r.Removed | Should -Be 0
        $r.Unverified | Should -Be 2
        $global:OemTestLog -join "`n" | Should -BeLike '*[[]WARN] Could not read the installed Store apps (The Appx deployment service is not available) after the removal, so 2 Store app(s) could not be checked and are not counted as removed*'
        Remove-Variable -Name OemTestAfterFails -Scope Global -ErrorAction SilentlyContinue
    }

    It 'counts a package that is still provisioned afterwards as not removed' {
        $global:OemTestDeprovisionFails = @('DellInc.DellSupportAssistforPCs_5.2.1.0_x64__htrsf667h5kn2')
        $r = Remove-OemAppxPackages
        $r.Failed | Should -Be 1
        $r.FailedNames | Should -Contain 'DellInc.DellSupportAssistforPCs_5.2.1.0_x64__htrsf667h5kn2'
    }

    It 'counts a package that was only provisioned (installed for nobody) as removed once it is de-provisioned' {
        $global:OemTestAppx = @([PSCustomObject]@{ Name = 'Microsoft.WindowsCalculator'; PackageFullName = 'Microsoft.WindowsCalculator_1.0.0.0_x64__8wekyb3d8bbwe' })
        $global:OemTestProvisioned = @([PSCustomObject]@{ DisplayName = 'DellInc.DellPair'; PackageName = 'DellInc.DellPair_1.0.0.0_x64__htrsf667h5kn2' })
        $OemBloatAppxPatterns = @('DellInc.*')
        $r = Remove-OemAppxPackages
        $r.Removed | Should -Be 1
        $r.Failed | Should -Be 0
        $r.Unverified | Should -Be 0
    }

    It 'does not claim a Store app was removed before it is known (the step description is logged ahead of any error)' {
        Mock Invoke-ThrottledSteps { foreach ($step in $Steps) { $global:OemTestCalls.Add($step.Description) } }
        Remove-OemAppxPackages | Out-Null
        $descriptions = @($global:OemTestCalls | Where-Object { $_ -like '*AppX package*' })
        $descriptions.Count | Should -BeGreaterThan 0
        foreach ($d in $descriptions) { $d | Should -BeLike 'Removal requested for AppX package (all users): *' }
    }

    It 'handles a package that several patterns match only once' {
        Remove-OemAppxPackages | Out-Null
        @($global:OemTestCalls | Where-Object { $_ -like 'remove DellInc.DellSupportAssistforPCs*' }).Count | Should -Be 1
        @($global:OemTestCalls | Where-Object { $_ -like 'deprovision DellInc.DellSupportAssistforPCs*' }).Count | Should -Be 1
    }

    It 'changes nothing in a dry run' {
        $DryRun = $true
        $r = Remove-OemAppxPackages
        $global:OemTestCalls.Count | Should -Be 0
        $r.Removed | Should -Be 0
        $global:OemTestLog -join "`n" | Should -BeLike '*DRYRUN: Removing AppX package: DellInc.DellSupportAssistforPCs*'
    }
}

Describe 'Stop-OemProductActivity' {
    AfterEach { $env:windir = $script:savedWindir }
    BeforeEach {
        # (when the tests run as SYSTEM, $TestDrive is under C:\WINDOWS\Temp and the "never from the Windows folder" rule would protect the fake processes)
        $script:savedWindir = $env:windir
        $env:windir = 'Z:\OemNoSuchWindowsFolder'
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestPolls = 0
        Mock Get-Process { @() }
        Mock Start-Sleep {}
    }

    It 'asks a running service to stop without waiting for it, and goes on as soon as it has stopped' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell SupportAssist*'; services = @('SupportAssistAgent') })
        Mock Get-Service {
            $global:OemTestPolls++
            # the first look finds it running; the next look (after the stop request) finds it stopped
            [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Status = $(if ($global:OemTestPolls -le 1) { 'Running' } else { 'Stopped' }); StartType = 'Disabled' }
        }
        Mock Stop-Service {}
        Mock Set-Service {}
        Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation ''
        Should -Invoke Stop-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'SupportAssistAgent' -and $NoWait }
        Should -Invoke Start-Sleep -Times 0 -Exactly
        $global:OemTestLog -join "`n" | Should -Not -BeLike '*still not stopped*'
    }

    It 'gives up on a service that stays in "stopping" after 30 seconds, says so, and does not hang the run' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell SupportAssist*'; services = @('SupportAssistAgent') })
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Status = 'StopPending'; StartType = 'Disabled' } }
        Mock Stop-Service {}
        Mock Set-Service {}
        Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation ''
        Should -Invoke Start-Sleep -Times 15 -Exactly -ParameterFilter { $Seconds -eq 2 }
        $global:OemTestLog -join "`n" | Should -Match ([regex]::Escape("[WARN] Service 'SupportAssistAgent' is still not stopped after 30 s"))
    }

    It 'stops the services and processes the hints name for the product, and only for that product' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell SupportAssist*'; services = @('SupportAssistAgent'); processes = @('SupportAssistAgent') })
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Status = 'Running'; StartType = 'Automatic' } }
        Mock Stop-Service {}
        Mock Set-Service {}
        Mock Get-Process { [PSCustomObject]@{ Id = 4242; ProcessName = 'SupportAssistAgent'; Path = 'C:\x\SupportAssistAgent.exe' } } -ParameterFilter { $Name -eq 'SupportAssistAgent' }
        Mock Stop-Process {}
        Stop-OemProductActivity -ProductName 'Dell SupportAssist Remediation' -InstallLocation ''
        Should -Invoke Stop-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'SupportAssistAgent' }
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 4242 }

        Stop-OemProductActivity -ProductName 'Dell Optimizer' -InstallLocation ''
        Should -Invoke Stop-Service -Times 1 -Exactly
    }

    It 'also disables the service, so that a service which restarts itself cannot put its files back in use mid-uninstall' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell SupportAssist*'; services = @('SupportAssistAgent') })
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Status = 'Running'; StartType = 'Automatic' } }
        Mock Stop-Service {}
        Mock Set-Service {}
        Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation ''
        Should -Invoke Set-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'SupportAssistAgent' -and $StartupType -eq 'Disabled' }
    }

    It 'leaves a service alone that is already stopped and disabled' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell SupportAssist*'; services = @('SupportAssistAgent'); processes = @() })
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Status = 'Stopped'; StartType = 'Disabled' } }
        Mock Stop-Service {}
        Mock Set-Service {}
        Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation ''
        Should -Invoke Stop-Service -Times 0 -Exactly
        Should -Invoke Set-Service -Times 0 -Exactly
    }

    It 'disables a service that is stopped but could still start again' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell SupportAssist*'; services = @('SupportAssistAgent') })
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Status = 'Stopped'; StartType = 'Manual' } }
        Mock Stop-Service {}
        Mock Set-Service {}
        Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation ''
        Should -Invoke Stop-Service -Times 0 -Exactly
        Should -Invoke Set-Service -Times 1 -Exactly
    }

    It 'handles every service a wildcard in the hint matches, by name or by display name' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell SupportAssist*'; services = @('*SupportAssist*') })
        Mock Get-Service {
            @(
                [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Status = 'Running'; StartType = 'Automatic' }
                [PSCustomObject]@{ Name = 'Dell SupportAssist Remediation'; DisplayName = 'Dell SupportAssist Remediation'; Status = 'Running'; StartType = 'Automatic' }
            )
        }
        Mock Stop-Service {}
        Mock Set-Service {}
        Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation ''
        Should -Invoke Stop-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'SupportAssistAgent' }
        Should -Invoke Stop-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'Dell SupportAssist Remediation' }
    }

    It 'does nothing without hints and without an install folder' {
        $OemProductHints = @()
        Mock Stop-Service {}
        Mock Stop-Process {}
        Stop-OemProductActivity -ProductName 'Whatever' -InstallLocation ''
        Should -Invoke Stop-Service -Times 0 -Exactly
        Should -Invoke Stop-Process -Times 0 -Exactly
    }

    It 'stops what runs from the product''s own folder' {
        $OemProductHints = @()
        $dir = Join-Path $TestDrive 'Program Files\Dell\Dell Pair'
        $null = New-Item -ItemType Directory -Path $dir -Force
        Mock Get-Process {
            @(
                [PSCustomObject]@{ Id = 7; ProcessName = 'pairhelper'; Path = (Join-Path $dir 'helper.exe') }
                [PSCustomObject]@{ Id = 8; ProcessName = 'other'; Path = 'C:\Windows\System32\other.exe' }
            )
        }
        Mock Stop-Process {}
        Stop-OemProductActivity -ProductName 'Dell Pair' -InstallLocation $dir
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 7 }
        Should -Invoke Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -eq 8 }
    }

    It 'says in the log what a service was set to before it is disabled (nothing else records it)' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell SupportAssist*'; services = @('SupportAssistAgent') })
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Status = 'Stopped'; StartType = 'Manual' } }
        Mock Stop-Service {}
        Mock Set-Service {}
        Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation ''
        $global:OemTestLog -join "`n" | Should -BeLike "*Disabling service 'Dell SupportAssist' (SupportAssistAgent; it was set to Manual and was Stopped)*"
    }

    It 'never stops the product''s own uninstaller, even when a hint pattern or the folder rule would match it' {
        $dir = Join-Path $TestDrive 'Program Files\Dell\Dell Optimizer'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $uninstaller = Join-Path $dir 'DellOptimizer_MyDell.exe'
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell Optimizer*'; processes = @('DellOptimizer*') })
        Mock Get-Process {
            @(
                [PSCustomObject]@{ Id = 11; ProcessName = 'DellOptimizer'; Path = (Join-Path $dir 'DellOptimizer.exe') }
                [PSCustomObject]@{ Id = 12; ProcessName = 'DellOptimizer_MyDell'; Path = $uninstaller }
            )
        }
        Mock Stop-Process {}
        Stop-OemProductActivity -ProductName 'Dell Optimizer' -InstallLocation $dir -ProtectPaths @($uninstaller)
        # (the stand-in lists the same processes for the by-name pass and the by-folder pass, so the product's own process is hit by both)
        Should -Invoke Stop-Process -ParameterFilter { $Id -eq 11 }
        Should -Invoke Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -eq 12 }
    }

    It 'never stops the folder rule''s victims that must stay: this worker, PowerShell, Dell Command | Update, the Windows folder' {
        $dir = Join-Path $TestDrive 'Program Files\Dell\Shared'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $OemProductHints = @()
        Mock Get-Process {
            @(
                [PSCustomObject]@{ Id = $PID; ProcessName = 'whatever'; Path = (Join-Path $dir 'self.exe') }
                [PSCustomObject]@{ Id = 21; ProcessName = 'powershell'; Path = (Join-Path $dir 'powershell.exe') }
                [PSCustomObject]@{ Id = 22; ProcessName = 'msiexec'; Path = (Join-Path $dir 'msiexec.exe') }
                [PSCustomObject]@{ Id = 23; ProcessName = 'DellCommandUpdate'; Path = (Join-Path $dir 'CommandUpdate\DellCommandUpdate.exe') }
                [PSCustomObject]@{ Id = 24; ProcessName = 'sysproc'; Path = (Join-Path $env:windir 'System32\sysproc.exe') }
                [PSCustomObject]@{ Id = 25; ProcessName = 'productproc'; Path = (Join-Path $dir 'product.exe') }
            )
        }
        Mock Stop-Process {}
        Stop-OemProductActivity -ProductName 'Dell Shared' -InstallLocation $dir
        Should -Invoke Stop-Process -Times 1 -Exactly
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 25 }
    }

    It 'never stops processes by a folder that other software shares (a vendor root, a system folder)' {
        $OemProductHints = @()
        Mock Get-Process { @([PSCustomObject]@{ Id = 9; ProcessName = 'dcu'; Path = 'C:\Windows\System32\Dell\CommandUpdate\dcu.exe' }) }
        Mock Stop-Process {}
        Stop-OemProductActivity -ProductName 'Dell Something' -InstallLocation 'C:\Windows\System32'
        Stop-OemProductActivity -ProductName 'Dell Something' -InstallLocation 'C:\Windows'
        Should -Invoke Stop-Process -Times 0 -Exactly
    }
}

Describe 'Get-PendingRestartReasons' {
    It 'finds nothing on a machine with no restart waiting' {
        @(Get-PendingRestartReasons -Hklm 'TestRegistry:\NoneWaiting').Count | Should -Be 0
    }

    It 'reports Windows servicing, Windows Update and a Burn bundle that are waiting for a restart' {
        $base = 'TestRegistry:\Waiting\SOFTWARE\Microsoft\Windows\CurrentVersion'
        $null = New-Item -Path "$base\Component Based Servicing\RebootPending" -Force
        $null = New-Item -Path "$base\WindowsUpdate\Auto Update\RebootRequired" -Force
        $null = New-Item -Path "$base\Uninstall\{400b816d-1b36-426f-9595-5742bfd07ec4}.RebootRequired" -Force
        $null = New-Item -Path "$base\Uninstall\{400b816d-1b36-426f-9595-5742bfd07ec4}" -Force
        $reasons = @(Get-PendingRestartReasons -Hklm 'TestRegistry:\Waiting')
        $reasons.Count | Should -Be 3
        ($reasons -join '|') | Should -BeLike '*servicing*'
        ($reasons -join '|') | Should -BeLike '*Windows Update*'
        ($reasons -join '|') | Should -BeLike '*{400b816d-1b36-426f-9595-5742bfd07ec4}*waiting for a restart*'
    }

    It 'looks at the 32-bit view of the Uninstall list too' {
        $null = New-Item -Path 'TestRegistry:\Wow\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{AAAA}.RebootRequired' -Force
        @(Get-PendingRestartReasons -Hklm 'TestRegistry:\Wow').Count | Should -Be 1
    }
}

Describe 'Test-OemResultRetryable' {
    It 'says a second go is worth it when something other than a wall was hit' {
        Test-OemResultRetryable -Result ([PSCustomObject]@{ Attempts = @([PSCustomObject]@{ Class = 'Failed' }) }) | Should -BeTrue
        Test-OemResultRetryable -Result ([PSCustomObject]@{ Attempts = @([PSCustomObject]@{ Class = 'Success' }) }) | Should -BeTrue
        Test-OemResultRetryable -Result ([PSCustomObject]@{ Attempts = @([PSCustomObject]@{ Class = 'TimedOut' }, [PSCustomObject]@{ Class = 'Failed' }) }) | Should -BeTrue
    }

    It 'says it is not when every attempt hit a wall repeating will not move' {
        foreach ($wall in 'TimedOut', 'NotStarted', 'RebootFirst', 'NoSource', 'Blocked') {
            Test-OemResultRetryable -Result ([PSCustomObject]@{ Attempts = @([PSCustomObject]@{ Class = $wall }) }) | Should -BeFalse -Because $wall
        }
    }

    It 'says it is not when nothing was even attempted' {
        Test-OemResultRetryable -Result ([PSCustomObject]@{ Attempts = @() }) | Should -BeFalse
        Test-OemResultRetryable -Result ([PSCustomObject]@{ Attempts = $null }) | Should -BeFalse
    }
}

Describe 'Get-OemRemovalSummaryLines' {
    It 'counts what was removed and names, with the reason, everything that was not' {
        $products = @(
            [PSCustomObject]@{ Name = 'Dell Digital Delivery Services'; Version = '5.6'; Status = 'Removed'; Detail = '' }
            [PSCustomObject]@{ Name = 'Dell Pair'; Version = ''; Status = 'StaleEntryCleared'; Detail = '' }
            [PSCustomObject]@{ Name = 'Dell Optimizer'; Version = '2.0'; Status = 'RemovedRestartNeeded'; Detail = '' }
            [PSCustomObject]@{ Name = 'Dell SupportAssist'; Version = '4.1'; Status = 'Failed'; Detail = 'Msi: exit 1603 (fatal error during the uninstall)' }
        )
        $appx = [PSCustomObject]@{ Removed = 4; Failed = 1; FailedNames = @('DellInc.Something_1.0_x64__abc') }
        $lines = @(Get-OemRemovalSummaryLines -AppxResult $appx -ProductResults $products)
        $lines[0].Level | Should -BeExactly 'INFO'
        $lines[0].Message | Should -BeLike '*Store apps: 4 removed, 1 not removed*programs: 2 removed, 1 leftover Apps entry cleared, 1 NOT removed*'
        (@($lines | Where-Object { $_.Level -eq 'WARN' })).Count | Should -Be 2
        ($lines | Where-Object { $_.Message -like "*NOT REMOVED: 'Dell SupportAssist' 4.1 - Msi: exit 1603*" }) | Should -Not -BeNullOrEmpty
        ($lines | Where-Object { $_.Message -like "*NOT REMOVED (Store app): DellInc.Something*" }) | Should -Not -BeNullOrEmpty
        ($lines | Where-Object { $_.Message -like "*'Dell Optimizer' is removed; a restart*" }) | Should -Not -BeNullOrEmpty
    }

    It 'advises a restart when an uninstaller finished and asked for one but the program is still listed' {
        $failed = [PSCustomObject]@{ Name = 'X'; Version = ''; Status = 'Failed'; Detail = 'Msi: exit 3010'; Attempts = @([PSCustomObject]@{ Class = 'RebootRequired' }) }
        $lines = @(Get-OemRemovalSummaryLines -AppxResult $null -ProductResults @($failed))
        ($lines | Where-Object { $_.Message -like '*finished and asked for a restart*restart the PC, then check again*' }) | Should -Not -BeNullOrEmpty
    }

    It 'ends what stayed with how to remove it by hand, and only when something stayed' {
        $failed = [PSCustomObject]@{ Name = 'X'; Version = ''; Status = 'Failed'; Detail = 'Msi: exit 1603'; Attempts = @([PSCustomObject]@{ Class = 'Failed' }) }
        $lines = @(Get-OemRemovalSummaryLines -AppxResult $null -ProductResults @($failed))
        ($lines | Where-Object { $_.Message -like '*can usually be removed by hand in Settings > Apps*' }) | Should -Not -BeNullOrEmpty
        $fine = [PSCustomObject]@{ Name = 'Y'; Version = ''; Status = 'Removed'; Detail = ''; Attempts = @() }
        $linesFine = @(Get-OemRemovalSummaryLines -AppxResult $null -ProductResults @($fine))
        ($linesFine | Where-Object { $_.Message -like '*by hand*' }) | Should -BeNullOrEmpty
        $storeFailed = [PSCustomObject]@{ Removed = 0; Failed = 1; FailedNames = @('Pkg_1.0_x64__abc'); Unverified = 0 }
        (@(Get-OemRemovalSummaryLines -AppxResult $storeFailed -ProductResults @()) | Where-Object { $_.Message -like '*by hand*' }) | Should -Not -BeNullOrEmpty
    }

    It 'says how many Store apps could not be checked' {
        $appx = [PSCustomObject]@{ Removed = 1; Failed = 0; FailedNames = @(); Unverified = 2 }
        $lines = @(Get-OemRemovalSummaryLines -AppxResult $appx -ProductResults @())
        $lines[0].Message | Should -BeLike '*Store apps: 1 removed, 0 not removed, 2 could not be checked*'
    }

    It 'counts leftover Apps entries on their own, never as removed programs, and says "entries" for several' {
        $products = @(
            [PSCustomObject]@{ Name = 'A'; Version = ''; Status = 'StaleEntryCleared'; Detail = '' }
            [PSCustomObject]@{ Name = 'B'; Version = ''; Status = 'StaleEntryCleared'; Detail = '' }
        )
        $lines = @(Get-OemRemovalSummaryLines -AppxResult $null -ProductResults $products)
        $lines[0].Message | Should -BeLike '*programs: 0 removed, 2 leftover Apps entries cleared, 0 NOT removed*'
    }

    It 'says plainly when nothing matched' {
        $lines = @(Get-OemRemovalSummaryLines -AppxResult $null -ProductResults @())
        $lines.Count | Should -Be 1
        $lines[0].Message | Should -BeLike '*Store apps: none matched; programs: none matched*'
    }

    It 'tells the technician to restart when a pending restart is why the uninstallers did nothing' {
        $failed = [PSCustomObject]@{ Name = 'Dell SupportAssist Remediation'; Version = '5.5'; Status = 'Failed'; Detail = 'Bundle: exit 350'; Attempts = @([PSCustomObject]@{ Class = 'RebootFirst' }) }
        $lines = @(Get-OemRemovalSummaryLines -AppxResult $null -ProductResults @($failed))
        ($lines | Where-Object { $_.Level -eq 'WARN' -and $_.Message -like '*restart the PC and run the clean-up again*' }) | Should -Not -BeNullOrEmpty
    }

    It 'does not mention a restart when nothing was held up by one' {
        $failed = [PSCustomObject]@{ Name = 'X'; Version = ''; Status = 'Failed'; Detail = 'Msi: exit 1603'; Attempts = @([PSCustomObject]@{ Class = 'Failed' }) }
        $lines = @(Get-OemRemovalSummaryLines -AppxResult $null -ProductResults @($failed))
        ($lines | Where-Object { $_.Message -like '*restart*' }) | Should -BeNullOrEmpty
    }
}

Describe 'Remove-OemBloatware (Phase 1 as a whole, with the pieces stood in)' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $global:OemTestInstalled = @()
        $global:OemTestResults = @{}
        $global:OemTestSkips = New-Object System.Collections.Generic.List[string]
        $DryRun = $false
        $ProtectWorkTeams = $true
        $Win32BloatPatterns = @('Dell A*', 'Dell B*', 'Teams Machine-Wide Installer*')
        Mock Start-Sleep {}
        Mock Get-PendingRestartReasons { @() }
        Mock Remove-OemAppxPackages { [PSCustomObject]@{ Removed = 0; Failed = 0; FailedNames = @() } }
        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Test-Path { $false }
        # What each product's removal returns, in order; a result with Status Removed also takes the program out of the registry.
        Mock Remove-OemWin32Product {
            $global:OemTestCalls.Add("$($Product.Name)|passes=$Passes")
            $global:OemTestSkips.Add("$($Product.Name)=$($SkipPsPaths -join ',')")
            $next = $global:OemTestResults[$Product.Name].Dequeue()
            if ($next.Status -eq 'Removed') { $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.DisplayName -ne $Product.Name }) }
            $next
        }
    }

    BeforeAll {
        function New-TestResult {
            param([string]$Name, [string]$Status, [string[]]$AttemptClasses = @())
            [PSCustomObject]@{ Name = $Name; Version = ''; Status = $Status; Detail = $(if ($Status -eq 'Failed') { 'it failed' } else { '' }); RestartNeeded = $false; WallPsPaths = @()
                Attempts = @($AttemptClasses | ForEach-Object { [PSCustomObject]@{ Class = $_ } }) }
        }
        function Set-TestPlan {
            param([string]$Name, [object[]]$Results)
            $q = New-Object System.Collections.Generic.Queue[object]
            foreach ($r in $Results) { $q.Enqueue($r) }
            $global:OemTestResults[$Name] = $q
        }
    }

    AfterAll {
        Remove-Variable -Name OemTestResults -Scope Global -ErrorAction SilentlyContinue
    }

    It 'removes each product once and reports them in the order the patterns name them' {
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell A One' -Key 'K1' -Uninstall 'x'), (New-TestEntry -Name 'Dell B Two' -Key 'K2' -Uninstall 'x'))
        Set-TestPlan 'Dell A One' @(New-TestResult 'Dell A One' 'Removed')
        Set-TestPlan 'Dell B Two' @(New-TestResult 'Dell B Two' 'Removed')
        Remove-OemBloatware
        @($global:OemTestCalls) | Should -BeExactly @('Dell A One|passes=2', 'Dell B Two|passes=2')
        $global:OemTestLog -join "`n" | Should -BeLike '*programs: 2 removed, 0 NOT removed*'
    }

    It 'gives what is left a second look when something else WAS removed, once, with a single pass' {
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell A One' -Key 'K1' -Uninstall 'x'), (New-TestEntry -Name 'Dell B Two' -Key 'K2' -Uninstall 'x'))
        Set-TestPlan 'Dell A One' @((New-TestResult 'Dell A One' 'Failed' @('Failed')), (New-TestResult 'Dell A One' 'Removed'))
        Set-TestPlan 'Dell B Two' @(New-TestResult 'Dell B Two' 'Removed')
        Remove-OemBloatware
        @($global:OemTestCalls) | Should -BeExactly @('Dell A One|passes=2', 'Dell B Two|passes=2', 'Dell A One|passes=1')
        $global:OemTestLog -join "`n" | Should -BeLike '*Some programs are still installed although others were removed - taking a second look at them.*'
        $global:OemTestLog -join "`n" | Should -BeLike '*programs: 2 removed, 0 NOT removed*'
    }

    It 'does not look again when nothing was removed in the first pass' {
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell A One' -Key 'K1' -Uninstall 'x'))
        Set-TestPlan 'Dell A One' @(New-TestResult 'Dell A One' 'Failed' @('Failed'))
        Remove-OemBloatware
        $global:OemTestCalls.Count | Should -Be 1
        $global:OemTestLog -join "`n" | Should -BeLike "*NOT REMOVED: 'Dell A One'*"
    }

    It 'does not look again at a program that failed against a wall repeating cannot move (a hang, a pending restart)' {
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell A One' -Key 'K1' -Uninstall 'x'), (New-TestEntry -Name 'Dell B Two' -Key 'K2' -Uninstall 'x'))
        Set-TestPlan 'Dell A One' @(New-TestResult 'Dell A One' 'Failed' @('RebootFirst'))
        Set-TestPlan 'Dell B Two' @(New-TestResult 'Dell B Two' 'Removed')
        Remove-OemBloatware
        $global:OemTestCalls.Count | Should -Be 2
        $global:OemTestLog -join "`n" | Should -BeLike '*restart the PC and run the clean-up again*'
    }

    It 'looks again only at what could come out differently: not at a program that hung' {
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell A One' -Key 'K1' -Uninstall 'x'), (New-TestEntry -Name 'Dell B Two' -Key 'K2' -Uninstall 'x'), (New-TestEntry -Name 'Dell C Three' -Key 'K3' -Uninstall 'x'))
        $Win32BloatPatterns = @('Dell A*', 'Dell B*', 'Dell C*')
        Set-TestPlan 'Dell A One' @((New-TestResult 'Dell A One' 'Failed' @('Failed')), (New-TestResult 'Dell A One' 'Removed'))
        Set-TestPlan 'Dell B Two' @(New-TestResult 'Dell B Two' 'Removed')
        Set-TestPlan 'Dell C Three' @((New-TestResult 'Dell C Three' 'Failed' @('TimedOut')), (New-TestResult 'Dell C Three' 'Removed'))
        Remove-OemBloatware
        @($global:OemTestCalls) | Should -BeExactly @('Dell A One|passes=2', 'Dell B Two|passes=2', 'Dell C Three|passes=2', 'Dell A One|passes=1')
        $global:OemTestLog -join "`n" | Should -BeLike "*NOT REMOVED: 'Dell C Three'*"
    }

    It 'does not look again for anything once an uninstaller has said the whole PC must restart first' {
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell A One' -Key 'K1' -Uninstall 'x'), (New-TestEntry -Name 'Dell B Two' -Key 'K2' -Uninstall 'x'))
        # A hit the wall AND failed in a way that could be retried on its own - a restart is still the first thing to do.
        Set-TestPlan 'Dell A One' @((New-TestResult 'Dell A One' 'Failed' @('RebootFirst', 'Failed')), (New-TestResult 'Dell A One' 'Removed'))
        Set-TestPlan 'Dell B Two' @(New-TestResult 'Dell B Two' 'Removed')
        Remove-OemBloatware
        @($global:OemTestCalls) | Should -BeExactly @('Dell A One|passes=2', 'Dell B Two|passes=2')
        $global:OemTestLog -join "`n" | Should -Not -BeLike '*taking a second look at them*'
        $global:OemTestLog -join "`n" | Should -BeLike '*restart the PC and run the clean-up again*'
    }

    It 'counts a program that vanished together with another as removed' {
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell A One' -Key 'K1' -Uninstall 'x'), (New-TestEntry -Name 'Dell B Two' -Key 'K2' -Uninstall 'x'))
        Set-TestPlan 'Dell A One' @(New-TestResult 'Dell A One' 'Failed' @('Failed'))
        Set-TestPlan 'Dell B Two' @((New-TestResult 'Dell B Two' 'Removed'))
        # removing B takes A out of the registry as well
        Mock Remove-OemWin32Product {
            $global:OemTestCalls.Add("$($Product.Name)|passes=$Passes")
            $next = $global:OemTestResults[$Product.Name].Dequeue()
            if ($next.Status -eq 'Removed') { $global:OemTestInstalled = @() }
            $next
        }
        Remove-OemBloatware
        $global:OemTestCalls.Count | Should -Be 2 -Because 'A is not tried a third time: it is no longer there'
        $global:OemTestLog -join "`n" | Should -BeLike '*programs: 2 removed, 0 NOT removed*'
    }

    It 'leaves work/school Teams alone while it is protected, and says so once' {
        $global:OemTestInstalled = @((New-TestEntry -Name 'Teams Machine-Wide Installer' -Key 'K1' -Uninstall 'x'), (New-TestEntry -Name 'Dell A One' -Key 'K2' -Uninstall 'x'))
        Set-TestPlan 'Dell A One' @((New-TestResult 'Dell A One' 'Failed' @('Failed')), (New-TestResult 'Dell A One' 'Failed' @('Failed')))
        Remove-OemBloatware
        @($global:OemTestCalls | Where-Object { $_ -like 'Teams*' }).Count | Should -Be 0
        @($global:OemTestLog | Where-Object { $_ -like "*Skipping uninstall of 'Teams Machine-Wide Installer'*" }).Count | Should -Be 1
    }

    It 'warns about a restart that is already pending before it starts' {
        Mock Get-PendingRestartReasons { @('Windows Update is waiting for a restart') }
        Remove-OemBloatware
        $global:OemTestLog -join "`n" | Should -Match ([regex]::Escape('[WARN] A restart is pending on this PC (Windows Update is waiting for a restart)'))
    }

    It 'points out that Dell Command | Update can bring removed programs back, when it is installed and something was removed' {
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell A One' -Key 'K1' -Uninstall 'x'))
        Set-TestPlan 'Dell A One' @(New-TestResult 'Dell A One' 'Removed')
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*dcu-cli.exe' }
        Remove-OemBloatware
        $global:OemTestLog -join "`n" | Should -BeLike "*Dell Command | Update is installed and can download some of these programs again*"
    }

    It 'stays quiet about Dell Command | Update when nothing was removed' {
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell A One' -Key 'K1' -Uninstall 'x'))
        Set-TestPlan 'Dell A One' @(New-TestResult 'Dell A One' 'Failed' @('Failed'))
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*dcu-cli.exe' }
        Remove-OemBloatware
        $global:OemTestLog -join "`n" | Should -Not -BeLike '*Dell Command | Update*'
    }

    It 'tells the second look which layers already hit a wall, and keeps the first look''s attempts and its restart in the story' {
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell A One' -Key 'K1' -Uninstall 'x'), (New-TestEntry -Name 'Dell B Two' -Key 'K2' -Uninstall 'x'))
        $firstA = New-TestResult 'Dell A One' 'Failed' @('Failed')
        $firstA.WallPsPaths = @('PSPATH-OF-A-BUNDLE')
        $firstA.RestartNeeded = $true
        # The real Remove-OemWin32Product returns its attempts as a List, not an array - and in Windows PowerShell 5.1 @(<a List held in an
        # object's property>) throws "Argument types do not match", which once aborted the whole phase at exactly this point.
        $realShapeFirst = New-Object System.Collections.Generic.List[object]
        $realShapeFirst.Add([PSCustomObject]@{ Class = 'Failed' })
        $firstA.Attempts = $realShapeFirst
        $secondA = New-TestResult 'Dell A One' 'Removed' @('Success')
        $realShapeSecond = New-Object System.Collections.Generic.List[object]
        $realShapeSecond.Add([PSCustomObject]@{ Class = 'Success' })
        $secondA.Attempts = $realShapeSecond
        Set-TestPlan 'Dell A One' @($firstA, $secondA)
        Set-TestPlan 'Dell B Two' @(New-TestResult 'Dell B Two' 'Removed')
        Remove-OemBloatware
        @($global:OemTestSkips | Where-Object { $_ -like 'Dell A One=*' }) | Should -BeExactly @('Dell A One=', 'Dell A One=PSPATH-OF-A-BUNDLE')
        $global:OemTestLog -join "`n" | Should -BeLike "*'Dell A One' is removed; a restart finishes the clean-up*" -Because 'the first look needed a restart and the second look removed it'
    }

    It 'reports what is on the PC at the end: a program that failed but is gone by then counts as removed' {
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell A One' -Key 'K1' -Uninstall 'x'))
        Set-TestPlan 'Dell A One' @(New-TestResult 'Dell A One' 'Failed' @('TimedOut'))
        # the installer that had been given up on finishes late: the entry is gone when the report is made
        Mock Remove-OemWin32Product {
            $global:OemTestCalls.Add("$($Product.Name)|passes=$Passes")
            $next = $global:OemTestResults[$Product.Name].Dequeue()
            $global:OemTestInstalled = @()
            $next
        }
        Remove-OemBloatware
        $text = $global:OemTestLog -join "`n"
        $text | Should -BeLike '*programs: 1 removed, 0 NOT removed*'
        $text | Should -Not -BeLike "*NOT REMOVED: 'Dell A One'*"
    }

    It 'leaves a failure standing when the program is still there at the end' {
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell A One' -Key 'K1' -Uninstall 'x'))
        Set-TestPlan 'Dell A One' @(New-TestResult 'Dell A One' 'Failed' @('TimedOut'))
        Remove-OemBloatware
        $global:OemTestLog -join "`n" | Should -BeLike "*NOT REMOVED: 'Dell A One'*"
    }

    It 'only notes a pending restart in a dry run (nothing is being attempted, so nothing can fail because of it)' {
        $DryRun = $true
        Mock Get-PendingRestartReasons { @('Windows Update is waiting for a restart') }
        Remove-OemBloatware
        $global:OemTestLog -join "`n" | Should -Match ([regex]::Escape('[INFO] A restart is pending on this PC'))
    }

    It 'in a dry run only plans: no report, no second look' {
        $DryRun = $true
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell A One' -Key 'K1' -Uninstall 'x'))
        Set-TestPlan 'Dell A One' @(New-TestResult 'Dell A One' 'DryRun')
        Remove-OemBloatware
        $global:OemTestCalls.Count | Should -Be 1
        $global:OemTestLog -join "`n" | Should -Not -BeLike '*Phase 1 result*'
    }
}

Describe 'Remove-StaleUninstallEntry' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $workDir = $TestDrive
    }

    It 'refuses anything that is not a direct Uninstall entry' {
        Remove-StaleUninstallEntry -PsPath 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion' -ProductName 'X' | Should -BeFalse
        Remove-StaleUninstallEntry -PsPath 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Foo' -ProductName 'X' | Should -BeFalse
        Remove-StaleUninstallEntry -PsPath 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Foo\Bar' -ProductName 'X' | Should -BeFalse
        $global:OemTestLog -join "`n" | Should -BeLike '*not a direct Uninstall entry*'
    }

    It 'backs the key up to a .reg file and then removes it (in Pester''s throw-away registry)' {
        $null = New-Item -Path 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Stale1' -Force
        New-ItemProperty -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Stale1' -Name 'DisplayName' -Value 'Stale One' -PropertyType String | Out-Null
        $item = Get-Item -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Stale1'
        Remove-StaleUninstallEntry -PsPath $item.PSPath -ProductName 'Stale One' | Should -BeTrue
        Test-Path -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Stale1' | Should -BeFalse
        $backup = @(Get-ChildItem -LiteralPath $TestDrive -Filter 'removed-uninstall-entry_Stale_One_*.reg')
        $backup.Count | Should -Be 1
        (Get-Content -LiteralPath $backup[0].FullName -Raw) | Should -BeLike '*Stale One*'
        $backup[0].Name | Should -BeLike '*_Stale1_*' -Because 'the key''s own name is in the backup name'
    }

    It 'keeps a backup for EVERY entry of one product cleared in the same second (the second must not overwrite the first)' {
        foreach ($k in 'PairA', 'PairB') {
            $null = New-Item -Path "TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\$k" -Force
            New-ItemProperty -LiteralPath "TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\$k" -Name 'Marker' -Value "marker-of-$k" -PropertyType String | Out-Null
        }
        $a = Get-Item -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\PairA'
        $b = Get-Item -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\PairB'
        Remove-StaleUninstallEntry -PsPath $a.PSPath -ProductName 'Dell Pair' | Should -BeTrue
        Remove-StaleUninstallEntry -PsPath $b.PSPath -ProductName 'Dell Pair' | Should -BeTrue
        $backups = @(Get-ChildItem -LiteralPath $TestDrive -Filter 'removed-uninstall-entry_Dell_Pair_*.reg')
        $backups.Count | Should -Be 2
        $text = ($backups | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $text | Should -BeLike '*marker-of-PairA*'
        $text | Should -BeLike '*marker-of-PairB*'
    }

    It 'never reuses a backup file name that is already taken' {
        $null = New-Item -Path 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Again' -Force
        $item = Get-Item -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Again'
        Remove-StaleUninstallEntry -PsPath $item.PSPath -ProductName 'Again Product' | Should -BeTrue
        $null = New-Item -Path 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Again' -Force
        Remove-StaleUninstallEntry -PsPath $item.PSPath -ProductName 'Again Product' | Should -BeTrue
        @(Get-ChildItem -LiteralPath $TestDrive -Filter 'removed-uninstall-entry_Again_Product_Again_*.reg').Count | Should -Be 2
    }
}

Describe 'Get-MsiLogFailureSummary' {
    It 'names the failing action, the custom-action code, the installer error and the final status' {
        $log = Join-Path $TestDrive 'failed.log'
        Set-Content -LiteralPath $log -Value @(
            'MSI (s) (5C:A4) [12:34:56:123]: Doing action: DellSA_StopServices'
            'Action start 12:34:56: DellSA_StopServices.'
            'CustomAction DellSA_StopServices returned actual error code 1603 (note this may not be 100% accurate if translation happened inside sandbox)'
            'Action ended 12:35:01: DellSA_StopServices. Return value 3.'
            'MSI (s) (5C:A4) [12:35:01:456]: Note: 1: 1722 2: DellSA_StopServices'
            'Error 1722. There is a problem with this Windows Installer package. A program run as part of the setup did not finish as expected.'
            'MSI (s) (5C:A4) [12:35:02:000]: Product: Dell SupportAssist -- Removal failed.'
            'MSI (s) (5C:A4) [12:35:02:100]: Windows Installer removed the product. Product Name: Dell SupportAssist. Removal success or error status: 1603.'
        )
        $s = Get-MsiLogFailureSummary -Path $log
        $s | Should -BeLike "*failed in action 'DellSA_StopServices'*"
        $s | Should -BeLike '*custom action DellSA_StopServices returned 1603*'
        $s | Should -BeLike '*Error 1722. There is a problem with this Windows Installer package*'
        $s | Should -BeLike '*final status 1603*'
    }

    It 'says nothing for a log of a successful run, a missing log or an empty path' {
        $ok = Join-Path $TestDrive 'ok.log'
        Set-Content -LiteralPath $ok -Value @('Action ended 12:35:01: InstallFinalize. Return value 1.', 'Windows Installer removed the product. Removal success or error status: 0.')
        Get-MsiLogFailureSummary -Path $ok | Should -BeExactly ''
        Get-MsiLogFailureSummary -Path (Join-Path $TestDrive 'nope.log') | Should -BeExactly ''
        Get-MsiLogFailureSummary -Path '' | Should -BeExactly ''
    }
}

Describe 'Get-OemMsiEventSummary' {
    It 'turns the installer''s error events into one line each' {
        Mock Get-WinEvent {
            @(
                [PSCustomObject]@{ Id = 11708; Message = "Product: Dell SupportAssist -- Installation failed.`r`n`r`n" }
                [PSCustomObject]@{ Id = 1033; Message = ('x' * 400) }
            )
        }
        $lines = @(Get-OemMsiEventSummary -Since (Get-Date).AddMinutes(-5))
        $lines.Count | Should -Be 2
        $lines[0] | Should -BeExactly 'event 11708: Product: Dell SupportAssist -- Installation failed.'
        $lines[1].Length | Should -BeLessThan 270
    }

    It 'returns nothing, quietly, when the log has no such events' {
        Mock Get-WinEvent { throw 'No events were found that match the specified selection criteria.' }
        @(Get-OemMsiEventSummary -Since (Get-Date).AddMinutes(-5)).Count | Should -Be 0
    }
}

Describe 'Test-WindowsInstallerBusy and Wait-WindowsInstallerIdle' {
    It 'answer without throwing, and an idle installer is not waited for' {
        (Test-WindowsInstallerBusy) -is [bool] | Should -BeTrue
        Mock Test-WindowsInstallerBusy { $false }
        Wait-WindowsInstallerIdle -TimeoutSec 5 | Should -BeTrue
    }

    It 'gives up after the time limit while the installer stays busy' {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        Mock Test-WindowsInstallerBusy { $true }
        Mock Start-Sleep {}
        Wait-WindowsInstallerIdle -TimeoutSec 0 | Should -BeFalse
    }
}

Describe 'Stop-ServiceBounded' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestPolls = 0
        Mock Start-Sleep {}
    }

    It 'asks the service to stop without waiting for it, and returns at once when it has stopped' {
        Mock Stop-Service {}
        Mock Get-Service { [PSCustomObject]@{ Name = 'Svc'; Status = 'Stopped' } }
        Stop-ServiceBounded -Name 'Svc' | Should -BeTrue
        Should -Invoke Stop-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'Svc' -and $NoWait -and $Force }
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'polls until the service has stopped' {
        Mock Stop-Service {}
        Mock Get-Service { $global:OemTestPolls++; [PSCustomObject]@{ Name = 'Svc'; Status = $(if ($global:OemTestPolls -le 2) { 'StopPending' } else { 'Stopped' }) } }
        Stop-ServiceBounded -Name 'Svc' | Should -BeTrue
        Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 2 }
    }

    It 'gives up after the time limit instead of waiting for ever, and says so' {
        Mock Stop-Service {}
        Mock Get-Service { [PSCustomObject]@{ Name = 'Svc'; Status = 'StopPending' } }
        Stop-ServiceBounded -Name 'Svc' -TimeoutSec 10 | Should -BeFalse
        Should -Invoke Start-Sleep -Times 5 -Exactly
        $global:OemTestLog -join "`n" | Should -Match ([regex]::Escape("[WARN] Service 'Svc' is still not stopped after 10 s."))
    }

    It 'takes a service that has disappeared for a stopped one' {
        Mock Stop-Service {}
        Mock Get-Service {}
        Stop-ServiceBounded -Name 'Svc' | Should -BeTrue
    }

    It 'reports a service that refuses to stop, without polling it' {
        Mock Stop-Service { throw 'Cannot stop service because it is protected' }
        Mock Get-Service { [PSCustomObject]@{ Name = 'Svc'; Status = 'Running' } }
        Stop-ServiceBounded -Name 'Svc' | Should -BeFalse
        Should -Invoke Start-Sleep -Times 0 -Exactly
        $global:OemTestLog -join "`n" | Should -BeLike "*[[]WARN] Could not stop service 'Svc': Cannot stop service because it is protected*"
    }
}

Describe 'Disable-OemScheduledTasksAndServices (Phase 1b)' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $DryRun = $false
        $OemTaskFolders = @()
        $OemTaskKeepPatterns = @()
        $OemServicePatterns = @('*SupportAssist*')
        Mock Get-ScheduledTask {}
        Mock Stop-ServiceBounded { $true }
        Mock Set-Service {}
    }

    It 'stops a running leftover service with a deadline (never with a plain Stop-Service) and disables it' {
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Status = 'Running' } }
        Disable-OemScheduledTasksAndServices
        Should -Invoke Stop-ServiceBounded -Times 1 -Exactly -ParameterFilter { $Name -eq 'SupportAssistAgent' }
        Should -Invoke Set-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'SupportAssistAgent' -and $StartupType -eq 'Disabled' }
    }

    It 'only disables a service that is already stopped' {
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Status = 'Stopped' } }
        Disable-OemScheduledTasksAndServices
        Should -Invoke Stop-ServiceBounded -Times 0 -Exactly
        Should -Invoke Set-Service -Times 1 -Exactly
    }

    It 'changes nothing in a dry run' {
        $DryRun = $true
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Status = 'Running' } }
        Disable-OemScheduledTasksAndServices
        Should -Invoke Stop-ServiceBounded -Times 0 -Exactly
        Should -Invoke Set-Service -Times 0 -Exactly
    }
}

Describe 'Invoke-OemUninstallLayer: the budget for a busy Windows Installer' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $OemBudget = @{ BusySeconds = 0; BusyLimitSec = 30 }
        Mock Start-Sleep {}
        Mock Wait-WindowsInstallerIdle { $true }
        Mock Get-MsiLogFailureSummary { '' }
        Mock Get-OemMsiEventSummary { @() }
        Mock Start-ProcessLowPriority { $global:OemTestCalls.Add('run'); New-TestRun -ExitCode 1618 }
        $msiLayer = [PSCustomObject]@{ Kind = 'Msi'; FilePath = 'msiexec.exe'; ArgumentList = '/x {x}'; LogPath = '' }
    }

    It 'stops waiting once the whole run has spent its allowance, says so, and does not call it a failure of the program' {
        $a = Invoke-OemUninstallLayer -Layer $msiLayer -ProductName 'X'
        # try 1: waits for the installer (about 0 s here), 1618, +20 s; try 2: 20 < 30, waits, 1618, +20 s = 40; try 3: allowance spent, no wait, 1618, stop
        $global:OemTestCalls.Count | Should -Be 3
        Should -Invoke Wait-WindowsInstallerIdle -Times 2 -Exactly
        $a.Class | Should -BeExactly 'Busy'
        $OemBudget.BusySeconds | Should -BeGreaterOrEqual 40
        $global:OemTestLog -join "`n" | Should -BeLike '*Windows Installer has been busy for * minutes of this run - not waiting for it any longer*restart the PC*'
    }

    It 'does not wait for the installer at all when the allowance is already spent, but still runs the uninstaller once' {
        $OemBudget.BusySeconds = 31
        $null = Invoke-OemUninstallLayer -Layer $msiLayer -ProductName 'X'
        $global:OemTestCalls.Count | Should -Be 1
        Should -Invoke Wait-WindowsInstallerIdle -Times 0 -Exactly
    }

    It 'counts the time it waited for the installer against the allowance' {
        Mock Wait-WindowsInstallerIdle { Start-Sleep -Milliseconds 1; $true }
        Mock Start-ProcessLowPriority { New-TestRun -ExitCode 0 }
        $null = Invoke-OemUninstallLayer -Layer $msiLayer -ProductName 'X'
        $OemBudget.BusySeconds | Should -BeGreaterThan 0
    }

    It 'works without a budget (older callers)' {
        Remove-Variable -Name OemBudget -ErrorAction SilentlyContinue
        $global:OemTestCalls.Clear()
        { Invoke-OemUninstallLayer -Layer $msiLayer -ProductName 'X' } | Should -Not -Throw
    }
}
