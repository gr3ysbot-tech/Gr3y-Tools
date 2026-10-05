# Pester tests for "never empty a registry key that already exists".
#
# New-Item -Path <existing key> -Force EMPTIES that key (every value and subkey - verified on Windows PowerShell 5.1 and 7),
# so using it as "make sure the key is there" before writing one value silently wiped other settings: for example
# HKLM\...\Policies\System (UAC), HKLM\...\Session Manager\Power, HKCU\Control Panel\Desktop, Explorer\Advanced - and,
# on a clean machine, every value but the last one a tweak wrote into the same key.
# The engine (Deploy-DellOfficeSetup.ps1) now creates keys only through Confirm-RegistryKey, which creates a key only
# when it is missing and never uses -Force. These tests check the helper (in Pester's throw-away TestRegistry:, never a
# real key), check one engine function that uses it, and keep the pattern from coming back. ASCII only.

Describe 'Confirm-RegistryKey' {
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        . (Join-Path $repo 'tests/TestHelpers.ps1')
        . ([scriptblock]::Create((Get-FunctionSource -ScriptPath (Join-Path $repo 'debloat/Deploy-DellOfficeSetup.ps1') -FunctionName 'Confirm-RegistryKey')))
    }

    It 'creates a missing key, parents included, and says so' {
        Confirm-RegistryKey -Path 'TestRegistry:\Fresh\Level1\Level2' | Should -BeTrue
        Test-Path -LiteralPath 'TestRegistry:\Fresh\Level1\Level2' | Should -BeTrue
        Test-Path -LiteralPath 'TestRegistry:\Fresh\Level1' | Should -BeTrue
    }

    It 'leaves an existing key exactly as it is: every value and every subkey survive' {
        New-Item -Path 'TestRegistry:\Existing' -Force | Out-Null
        New-ItemProperty -LiteralPath 'TestRegistry:\Existing' -Name 'KeepMe' -Value 7 -PropertyType DWord | Out-Null
        New-ItemProperty -LiteralPath 'TestRegistry:\Existing' -Name 'AlsoKeepMe' -Value 'text' -PropertyType String | Out-Null
        New-Item -Path 'TestRegistry:\Existing\Sub' -Force | Out-Null
        New-ItemProperty -LiteralPath 'TestRegistry:\Existing\Sub' -Name 'Inner' -Value 1 -PropertyType DWord | Out-Null

        Confirm-RegistryKey -Path 'TestRegistry:\Existing' | Should -BeTrue
        $script:LastRegistryKeyError | Should -BeNullOrEmpty -Because 'a key that is already there is not a failure'

        $item = Get-ItemProperty -LiteralPath 'TestRegistry:\Existing'
        $item.KeepMe | Should -Be 7
        $item.AlsoKeepMe | Should -Be 'text'
        (Get-ItemProperty -LiteralPath 'TestRegistry:\Existing\Sub').Inner | Should -Be 1
        @(Get-ChildItem -LiteralPath 'TestRegistry:\Existing').Count | Should -Be 1
    }

    It 'adds a missing key inside an existing, populated parent without touching the parent' {
        New-Item -Path 'TestRegistry:\Parent' -Force | Out-Null
        New-ItemProperty -LiteralPath 'TestRegistry:\Parent' -Name 'ParentValue' -Value 3 -PropertyType DWord | Out-Null
        Confirm-RegistryKey -Path 'TestRegistry:\Parent\NewChild' | Should -BeTrue
        (Get-ItemProperty -LiteralPath 'TestRegistry:\Parent').ParentValue | Should -Be 3
        Test-Path -LiteralPath 'TestRegistry:\Parent\NewChild' | Should -BeTrue
    }

    It 'is the reason the helper exists: New-Item -Force really does empty an existing key' {
        New-Item -Path 'TestRegistry:\Hazard' -Force | Out-Null
        New-ItemProperty -LiteralPath 'TestRegistry:\Hazard' -Name 'WillVanish' -Value 1 -PropertyType DWord | Out-Null
        New-Item -Path 'TestRegistry:\Hazard\SubWillVanish' -Force | Out-Null
        New-Item -Path 'TestRegistry:\Hazard' -Force | Out-Null
        $left = Get-ItemProperty -LiteralPath 'TestRegistry:\Hazard'
        $left.PSObject.Properties['WillVanish'] | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath 'TestRegistry:\Hazard').Count | Should -Be 0
    }

    It 'does not empty a key that another process creates between the check and the creation (no -Force)' {
        # a stand-in New-Item: it first lets "someone else" create the key with a value, then runs the real call
        # with whatever -Force the caller gave (so adding -Force to the helper would make this test fail)
        function New-Item {
            [CmdletBinding()] param([string]$Path, [switch]$Force)
            Microsoft.PowerShell.Management\New-Item -Path $Path | Out-Null
            Microsoft.PowerShell.Management\New-ItemProperty -LiteralPath $Path -Name 'Theirs' -Value 1 -PropertyType DWord | Out-Null
            Microsoft.PowerShell.Management\New-Item -Path $Path -Force:$Force
        }
        try {
            Confirm-RegistryKey -Path 'TestRegistry:\Race' | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath 'function:New-Item' -ErrorAction SilentlyContinue
        }
        (Get-ItemProperty -LiteralPath 'TestRegistry:\Race').Theirs | Should -Be 1
    }

    It 'returns $false instead of throwing when the key cannot be made, and keeps the reason' {
        { Confirm-RegistryKey -Path 'Q:\no-such-drive-for-sure\Key' } | Should -Not -Throw
        Confirm-RegistryKey -Path 'Q:\no-such-drive-for-sure\Key' | Should -BeFalse
        $script:LastRegistryKeyError | Should -Not -BeNullOrEmpty
        Confirm-RegistryKey -Path '' | Should -BeFalse
        $script:LastRegistryKeyError | Should -Match 'no registry path'
        Confirm-RegistryKey -Path $null | Should -BeFalse
        # and a later success clears the reason
        Confirm-RegistryKey -Path 'TestRegistry:\ReasonCleared' | Should -BeTrue
        $script:LastRegistryKeyError | Should -BeNullOrEmpty
    }

    It 'can be called twice in a row and a value written between the calls survives the second call' {
        Confirm-RegistryKey -Path 'TestRegistry:\Twice' | Should -BeTrue
        New-ItemProperty -LiteralPath 'TestRegistry:\Twice' -Name 'Written' -Value 5 -PropertyType DWord | Out-Null
        Confirm-RegistryKey -Path 'TestRegistry:\Twice' | Should -BeTrue
        (Get-ItemProperty -LiteralPath 'TestRegistry:\Twice').Written | Should -Be 5
    }
}

Describe 'Set-OneDriveKfm (engine), with its policy key pointed at TestRegistry:' {
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        . (Join-Path $repo 'tests/TestHelpers.ps1')
        $engine = Join-Path $repo 'debloat/Deploy-DellOfficeSetup.ps1'
        . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $engine -FunctionName 'Confirm-RegistryKey')))
        $kfm = Get-FunctionSource -ScriptPath $engine -FunctionName 'Set-OneDriveKfm'
        $realPath = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
        if (-not $kfm.Contains($realPath)) { throw 'the OneDrive policy path was not found in Set-OneDriveKfm' }
        . ([scriptblock]::Create($kfm.Replace($realPath, 'TestRegistry:\OneDrivePolicy')))
        function Invoke-Step { param([string]$Description, [scriptblock]$Action) & $Action }
        function Write-Log { param([string]$Message, [string]$Level) }
    }

    It 'writes the policy for exactly the chosen folders and keeps every other value in the key' {
        New-Item -Path 'TestRegistry:\OneDrivePolicy' -Force | Out-Null
        New-ItemProperty -LiteralPath 'TestRegistry:\OneDrivePolicy' -Name 'SomeOrgPolicy' -Value 5 -PropertyType DWord | Out-Null
        New-ItemProperty -LiteralPath 'TestRegistry:\OneDrivePolicy' -Name 'KFMSilentOptInDesktop' -Value 1 -PropertyType DWord | Out-Null   # left by an earlier run
        New-ItemProperty -LiteralPath 'TestRegistry:\OneDrivePolicy' -Name 'KFMSilentOptInPictures' -Value 1 -PropertyType DWord | Out-Null

        Set-OneDriveKfm -TenantId 'tenant-1' -Desktop $false -Documents $true -Pictures $false

        $p = Get-ItemProperty -LiteralPath 'TestRegistry:\OneDrivePolicy'
        $p.SomeOrgPolicy | Should -Be 5
        $p.SilentAccountConfig | Should -Be 1
        $p.KFMSilentOptIn | Should -Be 'tenant-1'
        $p.KFMSilentOptInDocuments | Should -Be 1
        $p.PSObject.Properties['KFMSilentOptInDesktop'] | Should -BeNullOrEmpty
        $p.PSObject.Properties['KFMSilentOptInPictures'] | Should -BeNullOrEmpty
    }

    It 'works on a machine that has no OneDrive policy key yet' {
        Remove-Item -LiteralPath 'TestRegistry:\OneDrivePolicy' -Recurse -Force -ErrorAction SilentlyContinue
        Set-OneDriveKfm -TenantId 'tenant-2' -Desktop $true -Documents $true -Pictures $true
        $p = Get-ItemProperty -LiteralPath 'TestRegistry:\OneDrivePolicy'
        $p.KFMSilentOptIn | Should -Be 'tenant-2'
        $p.KFMSilentOptInDesktop | Should -Be 1
        $p.KFMSilentOptInDocuments | Should -Be 1
        $p.KFMSilentOptInPictures | Should -Be 1
    }
}

Describe 'the scripts never use New-Item to "make sure a registry key exists"' {
    BeforeAll {
        $script:repo = Split-Path -Parent $PSScriptRoot
        # What counts: New-Item, ni, md, mkdir - and a New-Item hidden behind & $variable or Invoke-Expression with -Force.
        # The registry provider IGNORES -ItemType, so "New-Item -ItemType Directory -Path <registry key> -Force" empties a
        # key too. So: a call whose text names a registry path is always a finding; a call with -ItemType is accepted
        # only for a folder variable that is on this list on purpose (anything else must be added here deliberately);
        # a call without -ItemType is accepted only inside the helper (no -Force) or an allowed function that checks
        # Test-Path first. 'Set-PreventDeviceEncryption' is the GUI's own guarded function from the Disable BitLocker work.
        $script:folderVars = @{
            'Deploy-DellOfficeSetup.ps1' = @('workDir', 'reportDir', 'cacheDir', 'handoffDir')
            'Gr3ysUtilities.ps1'         = @('workDir', 'dir')
        }
        $script:allowedFunctions = @('Confirm-RegistryKey', 'Set-PreventDeviceEncryption')
        function Get-KeyCreatingNewItems([string]$Path) {
            $tokens = $null; $errs = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
            $names = @('New-Item', 'ni', 'md', 'mkdir')
            $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | Where-Object {
                $cn = $_.GetCommandName()
                ($cn -and ($names -contains $cn)) -or
                (-not $cn -and $_.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Unknown -and
                    @($_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Force' }).Count -gt 0)
            }
            $leaf = Split-Path -Leaf $Path
            $okVars = @($script:folderVars[$leaf])
            $found = foreach ($c in $calls) {
                $text = $c.Extent.Text
                $params = @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })
                $hasForce = @($params | Where-Object { $_.ParameterName -eq 'Force' }).Count -gt 0
                $hasType = @($params | Where-Object { $_.ParameterName -like 'ItemType*' -or $_.ParameterName -eq 'Type' }).Count -gt 0
                $p = $c.Parent
                while ($p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $p = $p.Parent }
                $fn = $(if ($p) { $p.Name } else { '(script level)' })
                $guarded = $(if ($p) { @($p.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Test-Path' }, $true)).Count -gt 0 } else { $false })
                # the path argument, when it is a plain variable
                $pathVar = ''
                for ($i = 0; $i -lt $c.CommandElements.Count; $i++) {
                    $el = $c.CommandElements[$i]
                    if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -like 'Path*' -and $i + 1 -lt $c.CommandElements.Count) {
                        $next = $c.CommandElements[$i + 1]
                        if ($next -is [System.Management.Automation.Language.VariableExpressionAst]) { $pathVar = $next.VariablePath.UserPath }
                    }
                }
                $problem = $null
                if ($text -match 'HK[A-Z_]{2,}:|Registry::|HKEY_') { $problem = 'names a registry path' }
                elseif ($hasType) { if ($okVars -notcontains $pathVar) { $problem = "-ItemType with an unlisted path ('$pathVar')" } }
                elseif ($fn -eq 'Confirm-RegistryKey') { if ($hasForce) { $problem = 'the helper itself must not use -Force' } }
                elseif ($script:allowedFunctions -contains $fn -and $guarded) { }
                else { $problem = 'creates a key without a guard' }
                if ($problem) { [pscustomobject]@{ Line = $c.Extent.StartLineNumber; Function = $fn; Problem = $problem; Text = $text } }
            }
            return @($found)
        }
    }

    It 'in the engine: nothing creates a registry key except Confirm-RegistryKey, and that never uses -Force' {
        $bad = @(Get-KeyCreatingNewItems -Path (Join-Path $script:repo 'debloat/Deploy-DellOfficeSetup.ps1'))
        ($bad | ForEach-Object { "line $($_.Line) in $($_.Function) ($($_.Problem)): $($_.Text)" }) -join "`n" | Should -BeNullOrEmpty
    }

    It 'in the GUI: the same rule holds' {
        $bad = @(Get-KeyCreatingNewItems -Path (Join-Path $script:repo 'debloat/Gr3ysUtilities.ps1'))
        ($bad | ForEach-Object { "line $($_.Line) in $($_.Function) ($($_.Problem)): $($_.Text)" }) -join "`n" | Should -BeNullOrEmpty
    }

    It 'the rule itself catches every way of writing the pattern (so it cannot be dodged quietly)' {
        # named like the engine so the engine's folder-variable list applies to it
        $sample = Join-Path $TestDrive 'Deploy-DellOfficeSetup.ps1'
        $lines = @(
            'function A { New-Item -Path $p -Force | Out-Null }',
            'function B { New-Item -ItemType Directory -Path $reg -Force | Out-Null }',
            'function C { ni HKCU:\Software\X -Force }',
            'function D { mkdir -Path $k -Force }',
            'function E { & $cmd -Path $k -Force }',
            'function F { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }',
            "function G { New-Item -Path 'Registry::HKEY_USERS\X' -ItemType Directory -Force }"
        )
        Set-Content -LiteralPath $sample -Value $lines -Encoding ASCII
        $hits = @(Get-KeyCreatingNewItems -Path $sample)
        @($hits | ForEach-Object { $_.Function } | Sort-Object) -join ',' | Should -Be 'A,B,C,D,E,G'
    }

    It 'the call sites use the helper (a sample of the places that used to wipe keys)' {
        $text = Get-Content -LiteralPath (Join-Path $script:repo 'debloat/Deploy-DellOfficeSetup.ps1') -Raw
        foreach ($needle in "Confirm-RegistryKey -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'", '$null = Confirm-RegistryKey -Path $lockPath', '$null = Confirm-RegistryKey -Path $powerKey', '$null = Confirm-RegistryKey -Path $entry.path') {
            $text.Contains($needle) | Should -BeTrue -Because $needle
        }
    }
}
