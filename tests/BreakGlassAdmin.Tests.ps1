# Pester tests for two things around the break-glass local administrator (Provisioning tab):
#  * New-BreakGlassPassword / New-BreakGlassLocalAdmin in Deploy-DellOfficeSetup.ps1. The password used to come from
#    [RandomNumberGenerator]::Fill(), which does not exist on Windows PowerShell 5.1 (.NET Framework) - the host the GUI
#    always uses - so the whole step failed before it created the account. These tests run the real functions with
#    stand-ins for the account cmdlets (nothing real is created) and fail if that static call ever comes back.
#  * Remove-OldWorkDirFiles in Gr3ysUtilities.ps1: the 30-day clean-up of the work folder must never delete the
#    credential file (on a PC that is not Entra-joined it is the ONLY copy of that password) or the Revert Last Run
#    snapshots. ASCII only.

Describe 'New-BreakGlassPassword' {
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        . (Join-Path $repo 'tests/TestHelpers.ps1')
        $script:engine = Join-Path $repo 'debloat/Deploy-DellOfficeSetup.ps1'
        foreach ($fn in 'Test-PasswordClasses', 'New-BreakGlassPassword') { . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $script:engine -FunctionName $fn))) }
    }

    It 'counts the character classes (at least three of upper, lower, digit, other)' {
        Test-PasswordClasses -Password 'abcdefghijklmnopqrstuvwx' | Should -BeFalse            # lower only
        Test-PasswordClasses -Password 'ABCDEFGHIJKLMNOPQRSTUVWX' | Should -BeFalse            # upper only
        Test-PasswordClasses -Password 'Abcdefghijklmnopqrstuvwx' | Should -BeFalse            # upper + lower
        Test-PasswordClasses -Password 'abcdefghijklmnopqrstuvw2' | Should -BeFalse            # lower + digit
        Test-PasswordClasses -Password 'Abcdefghijklmnopqrstuvw2' | Should -BeTrue             # upper + lower + digit
        Test-PasswordClasses -Password 'abcdefghijklmnopqrstuv2!' | Should -BeTrue             # lower + digit + other
        Test-PasswordClasses -Password 'Abcdefghijklmnopqrstu2!&' | Should -BeTrue             # all four
        Test-PasswordClasses -Password 'abcdefghijklmnopqrstuv2!' -Minimum 4 | Should -BeFalse
        Test-PasswordClasses -Password '' | Should -BeFalse
    }

    It 'makes 24 characters from the allowed set, with at least three of the four character classes' {
        $allowed = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#$%^&*'
        for ($i = 0; $i -lt 300; $i++) {
            $p = New-BreakGlassPassword
            $p.Length | Should -Be 24
            foreach ($c in $p.ToCharArray()) { $allowed.Contains([string]$c) | Should -BeTrue -Because "'$c' is not in the character set" }
            $classes = 0
            foreach ($pattern in '[A-Z]', '[a-z]', '[0-9]', '[^A-Za-z0-9]') { if ($p -cmatch $pattern) { $classes++ } }
            $classes | Should -BeGreaterOrEqual 3
        }
    }

    It 'draws again until the password passes the class check, and gives up with an error after 20 draws' {
        $script:calls = 0
        function Test-PasswordClasses { param([string]$Password, [int]$Minimum = 3) $script:calls++; return ($script:calls -ge 3) }
        (New-BreakGlassPassword).Length | Should -Be 24
        $script:calls | Should -Be 3
        $script:calls = -100
        { New-BreakGlassPassword } | Should -Throw '*complexity*'
        $script:calls | Should -Be (-100 + 20)
    }

    It 'does not repeat itself' {
        $set = @{}
        for ($i = 0; $i -lt 200; $i++) { $set[(New-BreakGlassPassword)] = $true }
        $set.Count | Should -Be 200
    }

    It 'does not use the static RandomNumberGenerator.Fill, which .NET Framework (Windows PowerShell 5.1) does not have' {
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:engine, [ref]$tokens, [ref]$errs)
        $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static -and $n.Member.Value -eq 'Fill' }, $true))
        $calls.Count | Should -Be 0
        # and the real call it uses works in THIS host (CI runs Windows PowerShell 5.1)
        { $r = [System.Security.Cryptography.RandomNumberGenerator]::Create(); $b = New-Object byte[] 8; $r.GetBytes($b); $r.Dispose() } | Should -Not -Throw
    }
}

Describe 'New-BreakGlassLocalAdmin (real function, stand-ins for the account cmdlets)' {
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        . (Join-Path $repo 'tests/TestHelpers.ps1')
        $script:engine = Join-Path $repo 'debloat/Deploy-DellOfficeSetup.ps1'
        foreach ($fn in 'Get-SafeFileNamePart', 'Test-PasswordClasses', 'New-BreakGlassPassword', 'Confirm-RegistryKey') {
            . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $script:engine -FunctionName $fn)))
        }
        # the LAPS policy key is pointed at Pester's throw-away TestRegistry: (never the real policy key)
        $lapsReal = 'HKLM:\SOFTWARE\Microsoft\Policies\LAPS'
        $bg = Get-FunctionSource -ScriptPath $script:engine -FunctionName 'New-BreakGlassLocalAdmin'
        if (-not $bg.Contains($lapsReal)) { throw 'the LAPS policy path was not found in New-BreakGlassLocalAdmin' }
        . ([scriptblock]::Create($bg.Replace($lapsReal, 'TestRegistry:\LAPS')))

        # --- stand-ins: nothing real is created, changed or run ---
        function Invoke-Step { param([string]$Description, [scriptblock]$Action) & $Action }
        function Write-Log { param([string]$Message, [string]$Level) $script:logLines.Add("[$Level] $Message") }
        function Get-LocalUser { [CmdletBinding()] param([string]$Name) if ($script:existingUser) { return [pscustomobject]@{ Name = $Name } } }
        function New-LocalUser {
            [CmdletBinding()] param([string]$Name, [securestring]$Password, [switch]$PasswordNeverExpires, [switch]$AccountNeverExpires)
            $script:created.Add($Name)
            $script:passwordGiven = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
        }
        function Add-LocalGroupMember { [CmdletBinding()] param([string]$Group, [string]$Member) $script:added.Add("$Group|$Member") }
        function Disable-LocalUser { [CmdletBinding()] param([string]$Name) $script:disabled.Add($Name) }
        function dsregcmd { if ($script:entra) { 'AzureAdJoined : YES' } else { 'AzureAdJoined : NO' } }
        function icacls { $script:icaclsCalls.Add(($args -join ' ')); return '' }
        function Invoke-LapsPolicyProcessing { [CmdletBinding()] param() $script:lapsRan = $true }
    }

    BeforeEach {
        $script:logLines = New-Object System.Collections.Generic.List[string]
        $script:created = New-Object System.Collections.Generic.List[string]
        $script:added = New-Object System.Collections.Generic.List[string]
        $script:disabled = New-Object System.Collections.Generic.List[string]
        $script:icaclsCalls = New-Object System.Collections.Generic.List[string]
        $script:existingUser = $false
        $script:entra = $false
        $script:lapsRan = $false
        $script:passwordGiven = $null
        $workDir = Join-Path $TestDrive ('work-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir | Out-Null
        $machineSerial = 'SER 123/4'
        $script:workDirNow = $workDir
    }

    It 'creates the account, adds it to Administrators and writes the only copy of the password to a restricted file (non-Entra PC)' {
        $workDir = $script:workDirNow; $machineSerial = 'SER 123/4'
        New-BreakGlassLocalAdmin -AccountName 'BgTest'
        @($script:created) -join ',' | Should -Be 'BgTest'
        @($script:added) -join ',' | Should -Be 'Administrators|BgTest'
        @($script:disabled) -join ',' | Should -Be 'Guest'
        $files = @(Get-ChildItem -LiteralPath $workDir -Filter 'breakglass-admin_*.txt' -File)
        $files.Count | Should -Be 1
        $files[0].Name | Should -Match '^breakglass-admin_[^\\/:*?"<>| ]+_SER-1234\.txt$'    # the serial is made file-name safe (space -> -, "/" dropped)
        $text = Get-Content -LiteralPath $files[0].FullName -Raw
        $text | Should -Match 'Account: BgTest'
        $script:passwordGiven | Should -Not -BeNullOrEmpty
        $script:passwordGiven.Length | Should -Be 24
        $text.Contains("Password: $($script:passwordGiven)") | Should -BeTrue
        $text | Should -Match 'NOT Entra-joined'
        $text | Should -Match 'only copy'
        @($script:icaclsCalls).Count | Should -Be 1
        $script:icaclsCalls[0] | Should -Match '/inheritance:r'
        # the password is never logged
        (@($script:logLines) -join "`n").Contains($script:passwordGiven) | Should -BeFalse
        (@($script:logLines) -join "`n") | Should -Not -Match 'Could not create'
    }

    It 'leaves an existing account and its password alone' {
        $workDir = $script:workDirNow; $machineSerial = 'SER 123/4'
        $script:existingUser = $true
        New-BreakGlassLocalAdmin -AccountName 'BgTest'
        $script:created.Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $workDir -Filter 'breakglass-admin_*.txt' -File).Count | Should -Be 0
        (@($script:logLines) -join "`n") | Should -Match 'already exists'
    }

    It 'on an Entra-joined PC sets the LAPS policy values and keeps every other value in that key' {
        $workDir = $script:workDirNow; $machineSerial = 'SER 123/4'
        $script:entra = $true
        New-Item -Path 'TestRegistry:\LAPS' -Force | Out-Null
        New-ItemProperty -LiteralPath 'TestRegistry:\LAPS' -Name 'PostAuthenticationActions' -Value 3 -PropertyType DWord | Out-Null   # an organisation's own LAPS setting
        New-BreakGlassLocalAdmin -AccountName 'BgTest'
        $p = Get-ItemProperty -LiteralPath 'TestRegistry:\LAPS'
        $p.BackupDirectory | Should -Be 1
        $p.AdministratorAccountName | Should -Be 'BgTest'
        $p.PasswordLength | Should -Be 20
        $p.PasswordComplexity | Should -Be 4
        $p.PasswordAgeDays | Should -Be 30
        $p.PostAuthenticationActions | Should -Be 3 -Because 'the policy key must not be emptied'
        $script:lapsRan | Should -BeTrue
        $text = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $workDir -Filter 'breakglass-admin_*.txt' -File)[0].FullName -Raw
        $text | Should -Match 'Entra-joined - Windows LAPS is configured'
    }

    It 'says so (and writes nothing) when the account cannot be created' {
        $workDir = $script:workDirNow; $machineSerial = 'SER 123/4'
        function New-LocalUser { [CmdletBinding()] param([string]$Name, [securestring]$Password, [switch]$PasswordNeverExpires, [switch]$AccountNeverExpires) throw 'The password does not meet the password policy requirements (stand-in).' }
        New-BreakGlassLocalAdmin -AccountName 'BgTest'
        (@($script:logLines) -join "`n") | Should -Match 'Could not create the break-glass administrator account'
        @(Get-ChildItem -LiteralPath $workDir -Filter 'breakglass-admin_*.txt' -File).Count | Should -Be 0
    }
}

Describe 'Remove-OldWorkDirFiles' {
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        . (Join-Path $repo 'tests/TestHelpers.ps1')
        . ([scriptblock]::Create((Get-FunctionSource -ScriptPath (Join-Path $repo 'debloat/Gr3ysUtilities.ps1') -FunctionName 'Remove-OldWorkDirFiles')))
        function New-AgedFile([string]$Dir, [string]$Name, [int]$DaysOld) {
            $p = Join-Path $Dir $Name
            Set-Content -LiteralPath $p -Value 'x' -Encoding ASCII
            (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddDays(-$DaysOld)
            return $p
        }
    }

    It 'deletes old logs and downloads, but never the break-glass credential, the Revert Last Run snapshots or the backups of cleared Uninstall entries' {
        $dir = Join-Path $TestDrive 'sweep'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $old = 'run_20260101_000000_x.log', 'gui_run_20260101_000000.out.log', 'gui_fix_20260101_000000.err.log', 'winget_install_20260101.log', 'dism_restorehealth.log', 'setup.exe', 'wu_resume_state.json'
        $keep = 'breakglass-admin_PC_SER123.txt', 'undo_PC_20260101_000000.json', 'undo_PC_20260101_000000_HKCU_Software_X.reg', 'removed-uninstall-entry_Dell_Pair_20260101_000000.reg'
        foreach ($n in $old + $keep) { $null = New-AgedFile $dir $n 45 }
        $recent = New-AgedFile $dir 'run_recent.log' 10
        New-Item -ItemType Directory -Path (Join-Path $dir 'handoff') | Out-Null
        $null = New-AgedFile (Join-Path $dir 'handoff') 'inventory.json' 90

        Remove-OldWorkDirFiles -Path $dir

        foreach ($n in $old) { Test-Path -LiteralPath (Join-Path $dir $n) | Should -BeFalse -Because "$n is old and sweepable" }
        foreach ($n in $keep) { Test-Path -LiteralPath (Join-Path $dir $n) | Should -BeTrue -Because "$n must never be swept" }
        Test-Path -LiteralPath $recent | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dir 'handoff\inventory.json') | Should -BeTrue -Because 'sub-folders are not swept'
    }

    It 'does nothing, quietly, for a folder that is not there' {
        { Remove-OldWorkDirFiles -Path (Join-Path $TestDrive 'no-such-folder') } | Should -Not -Throw
    }
}
