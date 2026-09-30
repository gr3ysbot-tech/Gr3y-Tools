BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $scriptPath = Join-Path $PSScriptRoot '..\debloat\Deploy-DellOfficeSetup.ps1'
    . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $scriptPath -FunctionName 'ConvertFrom-UninstallString')))
}

Describe 'ConvertFrom-UninstallString' {
    It 'returns Type None when both strings are empty' {
        $result = ConvertFrom-UninstallString -UninstallString '' -QuietUninstallString ''
        $result.Type | Should -Be 'None'
    }

    It 'prefers QuietUninstallString over UninstallString when both are present' {
        $result = ConvertFrom-UninstallString `
            -UninstallString 'C:\bad\path.exe' `
            -QuietUninstallString 'C:\real\quiet-uninstall.exe /S'
        $result.EffectiveString | Should -Be 'C:\real\quiet-uninstall.exe /S'
    }

    It 'falls back to UninstallString when QuietUninstallString is absent' {
        $result = ConvertFrom-UninstallString -UninstallString 'C:\only\one.exe /S' -QuietUninstallString ''
        $result.EffectiveString | Should -Be 'C:\only\one.exe /S'
    }

    Context 'MSI uninstall strings' {
        It 'extracts the product code GUID and builds the quiet uninstall args' {
            $result = ConvertFrom-UninstallString -UninstallString 'MsiExec.exe /X{12345678-1234-1234-1234-123456789ABC}'
            $result.Type | Should -Be 'Msi'
            $result.FilePath | Should -Be 'msiexec.exe'
            $result.ProductCode | Should -Be '{12345678-1234-1234-1234-123456789ABC}'
            $result.ArgumentList | Should -Be '/x {12345678-1234-1234-1234-123456789ABC} /qn /norestart'
        }

        It 'returns a null ProductCode when the uninstall string has no GUID (caller falls back to PSChildName)' {
            $result = ConvertFrom-UninstallString -UninstallString 'msiexec.exe /X SomeProductName /quiet'
            $result.Type | Should -Be 'Msi'
            $result.ProductCode | Should -BeNullOrEmpty
        }
    }

    Context 'EXE uninstall strings' {
        It 'correctly extracts a quoted path that contains a space, not truncating at the first word' {
            $result = ConvertFrom-UninstallString -UninstallString '"C:\Program Files\Some Vendor\uninstall.exe" /S'
            $result.Type | Should -Be 'Exe'
            $result.FilePath | Should -Be 'C:\Program Files\Some Vendor\uninstall.exe'
            $result.ArgumentList | Should -Be '/S'
        }

        It 'trusts the vendor-supplied args from a quoted path when present' {
            $result = ConvertFrom-UninstallString -UninstallString '"C:\Program Files\Vendor\uninstall.exe" -silent -norestart'
            $result.ArgumentList | Should -Be '-silent -norestart'
        }

        It 'defaults to /S when a quoted path has no trailing args' {
            $result = ConvertFrom-UninstallString -UninstallString '"C:\Program Files\Vendor\uninstall.exe"'
            $result.ArgumentList | Should -Be '/S'
        }

        It 'parses a bare (unquoted) exe path with no internal spaces' {
            $result = ConvertFrom-UninstallString -UninstallString 'C:\Vendor\uninst.exe /S'
            $result.Type | Should -Be 'Exe'
            $result.FilePath | Should -Be 'C:\Vendor\uninst.exe'
            $result.ArgumentList | Should -Be '/S'
        }

        It 'uses the Inno Setup silent switch set for an unins###.exe uninstaller, overriding any existing args in the string' {
            $result = ConvertFrom-UninstallString -UninstallString '"C:\Program Files\Vendor\unins000.exe" /SOMETHINGELSE'
            $result.ArgumentList | Should -Be '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
        }

        It 'recognizes unins000.exe with no digits too (uninsXXX.exe pattern allows zero digits)' {
            $result = ConvertFrom-UninstallString -UninstallString '"C:\Program Files\Vendor\unins.exe"'
            $result.ArgumentList | Should -Be '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
        }
    }

    It 'returns Type Unparseable for a string that is neither an MSI invocation nor an exe path' {
        $result = ConvertFrom-UninstallString -UninstallString 'this is not a valid uninstall command'
        $result.Type | Should -Be 'Unparseable'
    }
}
