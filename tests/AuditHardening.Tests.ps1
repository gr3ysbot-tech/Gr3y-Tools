BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $engine = Join-Path $PSScriptRoot '..\debloat\Deploy-DellOfficeSetup.ps1'
    foreach ($name in @('Write-ProtectedTextFile','Invoke-OfficeSetup','Get-OfficeDeploymentTool','Get-OfficeProductIds','Test-OfficeBusinessConfiguration','New-OfficeInstallXml')) {
        . ([scriptblock]::Create((Get-FunctionSource $engine $name)))
    }
    function Write-Log { param($Message, $Level) }
}

Describe 'Protected secret-file creation' {
    It 'creates an explicit Administrators/SYSTEM DACL before writing and refuses to overwrite' {
        $path = Join-Path $TestDrive 'fixture.txt'
        try {
            Write-ProtectedTextFile -Path $path -Text 'nonsecret-test-marker'
            $acl = Get-Acl -LiteralPath $path
            $acl.AreAccessRulesProtected | Should -BeTrue
            $rules = @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
            $rules.Count | Should -Be 2
            @($rules.IdentityReference.Value | Sort-Object) -join ',' | Should -Be 'S-1-5-18,S-1-5-32-544'
            { Write-ProtectedTextFile -Path $path -Text 'replacement' } | Should -Throw
        } finally {
            if (Test-Path -LiteralPath $path) {
                # Fixture owner restores test-runner access for assertion and cleanup.
                $acl = New-Object Security.AccessControl.FileSecurity
                $acl.SetAccessRuleProtection($true, $false)
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,'FullControl','Allow'))
                [IO.File]::SetAccessControl($path, $acl)
            }
        }
        [IO.File]::ReadAllText($path) | Should -Be 'nonsecret-test-marker'
    }
}

Describe 'Office installer provenance' {
    BeforeEach {
        $script:workDir = $TestDrive
        Mock Write-Log {}
        Mock Invoke-WebRequest {}
    }
    It 'rejects an invalid signature even with a Microsoft-looking subject' {
        Mock Get-AuthenticodeSignature { @{ Status='HashMismatch'; SignerCertificate=@{ Subject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US' } } }
        { Get-OfficeDeploymentTool } | Should -Throw '*signature*'
    }
    It 'rejects a valid signature from another publisher' {
        Mock Get-AuthenticodeSignature { @{ Status='Valid'; SignerCertificate=@{ Subject='O=Other Corporation' } } }
        { Get-OfficeDeploymentTool } | Should -Throw '*signature*'
    }
    It 'accepts a valid Microsoft signature' {
        Mock Get-AuthenticodeSignature { @{ Status='Valid'; SignerCertificate=@{ Subject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US' } } }
        Get-OfficeDeploymentTool | Should -Be (Join-Path $TestDrive 'setup.exe')
    }
}

Describe 'Office final configuration verification' {
    BeforeEach {
        Mock Write-Log {}
        $script:config = @{ ProductReleaseIds='O365BusinessRetail'; Platform='x64'; UpdateChannel='https://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6'; VersionToReport='16.0.1' }
    }
    It 'accepts the exact requested business configuration' {
        Test-OfficeBusinessConfiguration $config MonthlyEnterprise | Should -BeTrue
    }
    It 'rejects a missing target product, wrong architecture, wrong channel or consumer leftovers' -TestCases @(
        @{ Name='ProductReleaseIds'; Value='O365HomePremRetail' }
        @{ Name='Platform'; Value='x86' }
        @{ Name='UpdateChannel'; Value='unknown' }
        @{ Name='ProductReleaseIds'; Value='O365HomePremRetail,O365BusinessRetail' }
    ) {
        param($Name,$Value)
        $config[$Name] = $Value
        Test-OfficeBusinessConfiguration $config MonthlyEnterprise | Should -BeFalse
    }
    It 'preserves MSI Visio and Project editions in generated deployment XML' {
        $OfficeChannel='MonthlyEnterprise'; $OfficeLanguage='en-us'; $OfficeExcludeApps=''; $OfficeSharedComputerLicensing=$false
        $path = Join-Path $TestDrive 'install.xml'
        New-OfficeInstallXml $path 'C:\OfficeSource'
        [xml]$xml = Get-Content $path -Raw
        @($xml.Configuration.RemoveMSI.IgnoreProduct.ID | Sort-Object) -join ',' | Should -Be 'PrjPro,PrjStd,VisPro,VisStd'
    }
}

Describe 'Office waiting and time limits' {
    BeforeEach { Mock Write-Log {}; $script:officePreflightOk = $true }
    It 'blocks subsequent phases at the deadline without killing the installer' {
        $fake = [pscustomobject]@{ Id=1234 }
        $fake | Add-Member ScriptMethod WaitForExit { param($milliseconds) return $false }
        Mock Start-Process { $fake }
        { Invoke-OfficeSetup 'setup.exe' '/download fixture.xml' 'download' -TimeoutSeconds 0 } | Should -Throw '*may still be running*'
        $script:officePreflightOk | Should -BeFalse
    }
}

Describe 'Cancellation survivor tracking' {
    BeforeAll {
        $gui = Join-Path $PSScriptRoot '..\debloat\Gr3ysUtilities.ps1'
        . ([scriptblock]::Create((Get-FunctionSource $gui 'Get-TrackedProcessSurvivors')))
    }
    It 'does not confuse a reused PID with the original child' {
        Mock Get-CimInstance { [pscustomobject]@{ CreationDate='new-instance' } }
        @(Get-TrackedProcessSurvivors @([pscustomobject]@{ ProcessId=1234; CreationDate='old-instance' })).Count | Should -Be 0
    }
    It 'keeps a surviving original process visible' {
        Mock Get-CimInstance { [pscustomobject]@{ CreationDate='original' } }
        @(Get-TrackedProcessSurvivors @([pscustomobject]@{ ProcessId=1234; CreationDate='original' })).Count | Should -Be 1
    }
    It 'does not treat an unreadable process as stopped' {
        Mock Get-CimInstance { throw 'fixture access denied' }
        @(Get-TrackedProcessSurvivors @([pscustomobject]@{ ProcessId=1234; CreationDate='original' })).Count | Should -Be 1
    }
}
