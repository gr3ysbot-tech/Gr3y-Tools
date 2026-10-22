BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $engine = Join-Path $PSScriptRoot '..\debloat\Deploy-DellOfficeSetup.ps1'
    foreach ($name in @('Get-OfficeProductIds', 'Uninstall-ExistingOffice')) {
        . ([scriptblock]::Create((Get-FunctionSource $engine $name)))
    }
    function Write-Log { param($Message, $Level) }
    function Invoke-Step { param($Message, $Action) & $Action }
    $script:OfficeChannel = 'MonthlyEnterprise'
}

Describe 'Office product inventory and removal guard' {
    BeforeEach {
        $script:workDir = $TestDrive
        Mock Test-Path { $true }
        Mock Write-Log {}
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
    }
    It 'normalizes comma/semicolon lists, whitespace, and duplicates' {
        $ids = @(Get-OfficeProductIds ' O365HomePremRetail,OneNoteFreeRetail; O365HomePremRetail; ')
        $ids.Count | Should -Be 2
        $ids[0] | Should -Be 'O365HomePremRetail'
        $ids[1] | Should -Be 'OneNoteFreeRetail'
    }
    It 'removes the consumer Office and free OneNote combination from the reported laptop' {
        Mock Get-ItemProperty { [pscustomobject]@{ ProductReleaseIds = 'O365HomePremRetail,OneNoteFreeRetail' } }
        Uninstall-ExistingOffice -SetupPath 'setup.exe'
        Should -Invoke Start-Process -Times 1 -Exactly
        [xml]$xml = Get-Content (Join-Path $TestDrive 'remove-all.xml') -Raw
        $xml.Configuration.Remove.All | Should -Be 'TRUE'
    }
    It 'preserves all products when a protected or unknown SKU is present' -TestCases @(
        @{ Ids = 'O365HomePremRetail,VisioProRetail' }
        @{ Ids = 'O365HomePremRetail;ProjectProRetail' }
        @{ Ids = 'O365HomePremRetail,UnknownProduct' }
        @{ Ids = '' }
    ) {
        param($Ids)
        Mock Get-ItemProperty { [pscustomobject]@{ ProductReleaseIds = $Ids } }
        Uninstall-ExistingOffice -SetupPath 'setup.exe'
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Write-Log -ParameterFilter { $Level -eq 'WARN' } -Times 1
    }
    It 'reconfigures the target business SKU on its channel without uninstalling' {
        Mock Get-ItemProperty { [pscustomobject]@{
            ProductReleaseIds = 'O365BusinessRetail'
            UpdateChannel = 'https://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6'
        } }
        Uninstall-ExistingOffice -SetupPath 'setup.exe'
        Should -Invoke Start-Process -Times 0 -Exactly
    }
}
