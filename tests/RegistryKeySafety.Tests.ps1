# Pester tests for "never empty a registry key that already exists".
#
# New-Item -Path <existing key> -Force EMPTIES that key (every value and subkey - verified on Windows PowerShell 5.1 and 7),
# so using it as "make sure the key is there" before writing one value silently wiped other settings: for example
# HKLM\...\Policies\System (UAC), HKLM\...\Session Manager\Power, HKCU\Control Panel\Desktop, Explorer\Advanced.
# The engine (Deploy-DellOfficeSetup.ps1) now creates keys only through Confirm-RegistryKey, which creates a key
# only when it is missing. These tests check the helper (in Pester's throw-away TestRegistry:, never a real key)
# and keep the pattern from coming back. ASCII only.

Describe 'Confirm-RegistryKey' {
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        . (Join-Path $repo 'tests/TestHelpers.ps1')
        . ([scriptblock]::Create((Get-FunctionSource -ScriptPath (Join-Path $repo 'debloat/Deploy-DellOfficeSetup.ps1') -FunctionName 'Confirm-RegistryKey')))
    }

    It 'creates a missing key, parents included, and says so' {
        Confirm-RegistryKey -Path 'TestRegistry:\Fresh\Level1\Level2' | Should -BeTrue
        Test-Path -LiteralPath 'TestRegistry:\Fresh\Level1\Level2' | Should -BeTrue
    }

    It 'leaves an existing key exactly as it is: every value and every subkey survive' {
        New-Item -Path 'TestRegistry:\Existing' -Force | Out-Null
        New-ItemProperty -LiteralPath 'TestRegistry:\Existing' -Name 'KeepMe' -Value 7 -PropertyType DWord | Out-Null
        New-ItemProperty -LiteralPath 'TestRegistry:\Existing' -Name 'AlsoKeepMe' -Value 'text' -PropertyType String | Out-Null
        New-Item -Path 'TestRegistry:\Existing\Sub' -Force | Out-Null
        New-ItemProperty -LiteralPath 'TestRegistry:\Existing\Sub' -Name 'Inner' -Value 1 -PropertyType DWord | Out-Null

        Confirm-RegistryKey -Path 'TestRegistry:\Existing' | Should -BeTrue

        $item = Get-ItemProperty -LiteralPath 'TestRegistry:\Existing'
        $item.KeepMe | Should -Be 7
        $item.AlsoKeepMe | Should -Be 'text'
        (Get-ItemProperty -LiteralPath 'TestRegistry:\Existing\Sub').Inner | Should -Be 1
        @(Get-ChildItem -LiteralPath 'TestRegistry:\Existing').Count | Should -Be 1
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

    It 'returns $false instead of throwing when the key cannot be made' {
        { Confirm-RegistryKey -Path 'Q:\no-such-drive-for-sure\Key' } | Should -Not -Throw
        Confirm-RegistryKey -Path 'Q:\no-such-drive-for-sure\Key' | Should -BeFalse
        Confirm-RegistryKey -Path '' | Should -BeFalse
    }

    It 'can be called twice in a row and a value written between the calls survives the second call' {
        Confirm-RegistryKey -Path 'TestRegistry:\Twice' | Should -BeTrue
        New-ItemProperty -LiteralPath 'TestRegistry:\Twice' -Name 'Written' -Value 5 -PropertyType DWord | Out-Null
        Confirm-RegistryKey -Path 'TestRegistry:\Twice' | Should -BeTrue
        (Get-ItemProperty -LiteralPath 'TestRegistry:\Twice').Written | Should -Be 5
    }
}

Describe 'the scripts never use New-Item -Force to "make sure a registry key exists"' {
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        # New-Item with -ItemType (creating a directory or file) is fine. A New-Item without it creates a registry key.
        # The only places allowed to create one are the helper itself and (GUI, if present) a function that checks
        # Test-Path first.
        $script:allowed = @('Confirm-RegistryKey', 'Set-PreventDeviceEncryption')
        function Get-KeyCreatingNewItems([string]$Path) {
            $tokens = $null; $errs = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
            $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-Item' }, $true)
            $found = foreach ($c in $calls) {
                $hasItemType = @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -like 'ItemType*' }).Count -gt 0
                $hasType = @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Type' }).Count -gt 0
                if ($hasItemType -or $hasType) { continue }
                $p = $c.Parent
                while ($p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $p = $p.Parent }
                [pscustomobject]@{
                    Line     = $c.Extent.StartLineNumber
                    Function = $(if ($p) { $p.Name } else { '(script level)' })
                    Guarded  = $(if ($p) { @($p.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Test-Path' }, $true)).Count -gt 0 } else { $false })
                    Text     = $c.Extent.Text
                }
            }
            return @($found)
        }
    }

    It 'in the engine: the only key-creating New-Item is inside Confirm-RegistryKey, behind a Test-Path' {
        $hits = @(Get-KeyCreatingNewItems -Path (Join-Path $repo 'debloat/Deploy-DellOfficeSetup.ps1'))
        $bad = @($hits | Where-Object { $_.Function -ne 'Confirm-RegistryKey' -or -not $_.Guarded })
        ($bad | ForEach-Object { "line $($_.Line) in $($_.Function): $($_.Text)" }) -join "`n" | Should -BeNullOrEmpty
        @($hits | Where-Object { $_.Function -eq 'Confirm-RegistryKey' }).Count | Should -Be 1
    }

    It 'in the GUI: any key-creating New-Item sits in an allowed function that checks Test-Path first' {
        $hits = @(Get-KeyCreatingNewItems -Path (Join-Path $repo 'debloat/Gr3ysUtilities.ps1'))
        $bad = @($hits | Where-Object { $script:allowed -notcontains $_.Function -or -not $_.Guarded })
        ($bad | ForEach-Object { "line $($_.Line) in $($_.Function): $($_.Text)" }) -join "`n" | Should -BeNullOrEmpty
    }

    It 'the call sites use the helper (a sample of the places that used to wipe keys)' {
        $text = Get-Content -LiteralPath (Join-Path $repo 'debloat/Deploy-DellOfficeSetup.ps1') -Raw
        foreach ($needle in "Confirm-RegistryKey -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'", '$null = Confirm-RegistryKey -Path $lockPath', '$null = Confirm-RegistryKey -Path $powerKey', '$null = Confirm-RegistryKey -Path $entry.path') {
            $text.Contains($needle) | Should -BeTrue -Because $needle
        }
    }
}
