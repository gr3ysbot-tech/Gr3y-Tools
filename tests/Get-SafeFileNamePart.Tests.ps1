BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $scriptPath = Join-Path $PSScriptRoot '..\debloat\Gr3ysUtilities.ps1'
    . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $scriptPath -FunctionName 'Get-SafeFileNamePart')))
}

Describe 'Get-SafeFileNamePart' {
    It 'returns Unknown for an empty string' {
        Get-SafeFileNamePart -Value '' | Should -Be 'Unknown'
    }

    It 'returns Unknown for null' {
        Get-SafeFileNamePart -Value $null | Should -Be 'Unknown'
    }

    It 'returns Unknown for a whitespace-only string (trims to empty)' {
        Get-SafeFileNamePart -Value '   ' | Should -Be 'Unknown'
    }

    It 'leaves an already-safe value unchanged' {
        Get-SafeFileNamePart -Value 'ABC123' | Should -Be 'ABC123'
    }

    It 'replaces internal whitespace with a hyphen' {
        Get-SafeFileNamePart -Value 'Dell Latitude 5420' | Should -Be 'Dell-Latitude-5420'
    }

    It 'strips illegal filename characters without leaving gaps' {
        Get-SafeFileNamePart -Value 'A\B/C:D*E?F"G<H>I|J' | Should -Be 'ABCDEFGHIJ'
    }

    It 'trims leading and trailing hyphens produced by stripped characters' {
        Get-SafeFileNamePart -Value '\\Serial123\\' | Should -Be 'Serial123'
    }

    It 'returns Unknown when the value is made entirely of illegal characters' {
        Get-SafeFileNamePart -Value '\/:*?"<>|' | Should -Be 'Unknown'
    }

    It 'collapses multiple consecutive spaces into a single hyphen' {
        Get-SafeFileNamePart -Value 'Foo    Bar' | Should -Be 'Foo-Bar'
    }
}
