BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:engine = Join-Path $PSScriptRoot '..\debloat\Deploy-DellOfficeSetup.ps1'
    $script:gui = Join-Path $PSScriptRoot '..\debloat\Gr3ysUtilities.ps1'
    $script:helpers = @('Get-OfficeExecutableEdition', 'Get-OfficeArchitectureInventory', 'Resolve-OfficeClientEdition')
    foreach ($name in ($helpers + @('New-OfficeInstallXml', 'Test-OfficeBusinessConfiguration', 'Get-OfficeProductIds', 'Uninstall-ExistingOffice', 'Invoke-OfficeDeployment'))) {
        . ([scriptblock]::Create((Get-FunctionSource $engine $name)))
    }
    function Write-Log { param($Message, $Level) }
    function Invoke-Step { param($Message, $Action) & $Action }
    function Invoke-OfficeSetup { param($SetupPath, $Arguments, $Operation) }
    function Get-OfficeDeploymentTool {}
    function Invoke-OfficePreflight { param($SetupPath, $InstallXmlPath) }
    function Install-Microsoft365Business { param($SetupPath, $InstallXmlPath) }
    function New-PeFixture {
        param([string]$Path, [uint16]$Machine)
        $bytes = New-Object byte[] 134
        $bytes[0] = 0x4D; $bytes[1] = 0x5A
        [BitConverter]::GetBytes([int]128).CopyTo($bytes, 60)
        $bytes[128] = 0x50; $bytes[129] = 0x45
        [BitConverter]::GetBytes($Machine).CopyTo($bytes, 132)
        [IO.File]::WriteAllBytes($Path, $bytes)
    }
    function New-InventoryEntry {
        param([string]$Edition, [string]$Kind = 'ClickToRun', [bool]$Protected = $false)
        [pscustomobject]@{ Edition = $Edition; Kind = $Kind; Protected = $Protected; Name = 'test Office component' }
    }
}

Describe 'Office executable bitness' {
    It 'reads <Edition>-bit PE machine <Machine> rather than inferring from the folder name' -TestCases @(
        @{ Machine = 0x014C; Edition = '32' }
        @{ Machine = 0x8664; Edition = '64' }
        @{ Machine = 0xAA64; Edition = '64' }
        @{ Machine = 0x0200; Edition = 'Unknown' }
    ) {
        param($Machine, $Edition)
        $path = Join-Path $TestDrive 'EXCEL.EXE'
        New-PeFixture $path $Machine
        Get-OfficeExecutableEdition $path | Should -Be $Edition
        # The probe releases its file handle.
        [IO.File]::WriteAllText($path, 'replacement')
    }
    It 'reports unreadable, truncated and invalid binaries as unknown' {
        Get-OfficeExecutableEdition (Join-Path $TestDrive 'missing.exe') | Should -Be 'Unknown'
        $path = Join-Path $TestDrive 'broken.exe'
        [IO.File]::WriteAllText($path, 'not a PE file')
        Get-OfficeExecutableEdition $path | Should -Be 'Unknown'
        New-PeFixture $path 0x014C
        $bytes = [IO.File]::ReadAllBytes($path)
        [BitConverter]::GetBytes([int]10000).CopyTo($bytes, 60)
        [IO.File]::WriteAllBytes($path, $bytes)
        Get-OfficeExecutableEdition $path | Should -Be 'Unknown'
    }
}

Describe 'Installed Office architecture detection' {
    BeforeEach {
        $script:registryFixtures = @{}
        Mock Test-Path { $registryFixtures.ContainsKey([string]$LiteralPath[0]) -or [IO.File]::Exists([string]$LiteralPath[0]) }
        Mock Get-ItemProperty { $registryFixtures[[string]$LiteralPath[0]] }
    }
    It 'detects Click-to-Run <Platform> in <Base>' -TestCases @(
        @{ Platform = 'x86'; Edition = '32'; Base = 'HKLM:\SOFTWARE\Microsoft\Office' }
        @{ Platform = 'x64'; Edition = '64'; Base = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office' }
    ) {
        param($Platform, $Edition, $Base)
        $registryFixtures["$Base\ClickToRun\Configuration"] = @{ Platform = $Platform; ProductReleaseIds = 'O365HomePremRetail,OneNoteFreeRetail' }
        $inventory = @(Get-OfficeArchitectureInventory)
        $inventory.Count | Should -Be 1
        $inventory[0].Edition | Should -Be $Edition
        $inventory[0].Protected | Should -BeFalse
    }
    It 'reports unknown architecture and protected products without guessing' {
        $registryFixtures['HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'] = @{ Platform = ''; ProductReleaseIds = 'O365BusinessRetail;VisioProRetail' }
        $inventory = @(Get-OfficeArchitectureInventory)
        $inventory[0].Edition | Should -Be 'Unknown'
        $inventory[0].Protected | Should -BeTrue
    }
    It 'detects legacy Excel from its binary and ignores stale install roots' {
        $registryFixtures['HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\14.0\Common\InstallRoot'] = @{ Path = $TestDrive }
        @(Get-OfficeArchitectureInventory).Count | Should -Be 0
        New-PeFixture (Join-Path $TestDrive 'EXCEL.EXE') 0x014C
        $inventory = @(Get-OfficeArchitectureInventory)
        $inventory.Count | Should -Be 1
        $inventory[0].Edition | Should -Be '32'
        $inventory[0].Kind | Should -Be 'Legacy'
    }
    It 'protects and deduplicates legacy Visio exposed through multiple registry roots' {
        $root = Join-Path $TestDrive 'Visio'
        $null = New-Item -ItemType Directory -Path $root
        $registryFixtures['HKLM:\SOFTWARE\Microsoft\Office\16.0\Common\InstallRoot'] = @{ Path = $root }
        $registryFixtures['HKLM:\SOFTWARE\Microsoft\Office\16.0\Visio\InstallRoot'] = @{ Path = $root }
        New-PeFixture (Join-Path $root 'VISIO.EXE') 0x8664
        $inventory = @(Get-OfficeArchitectureInventory)
        $inventory.Count | Should -Be 1
        $inventory[0].Protected | Should -BeTrue
        { Resolve-OfficeClientEdition -Requested 32 -Inventory $inventory } | Should -Throw '*preserving*'
    }
    It 'does not interpret an inaccessible registry as a clean machine' {
        Mock Test-Path { throw 'Access denied' }
        { Get-OfficeArchitectureInventory } | Should -Throw '*Access denied*'
    }
    It 'keeps worker and GUI detection and resolution identical' {
        foreach ($name in $helpers) {
            (Get-FunctionSource $engine $name) | Should -BeExactly (Get-FunctionSource $gui $name)
        }
    }
}

Describe 'Office architecture selection and conflicts' {
    It 'uses Windows bitness only when no Office is detected' {
        Resolve-OfficeClientEdition -Is64BitOperatingSystem $true | Should -Be '64'
        Resolve-OfficeClientEdition -Is64BitOperatingSystem $false | Should -Be '32'
    }
    It 'preserves <Edition>-bit Office in Auto on 64-bit Windows' -TestCases @(@{ Edition = '32' }, @{ Edition = '64' }) {
        param($Edition)
        Resolve-OfficeClientEdition -Inventory @(New-InventoryEntry $Edition) -Is64BitOperatingSystem $true | Should -Be $Edition
    }
    It 'allows an explicit 64-to-32 or 32-to-64 reinstall of a recognized suite' {
        Resolve-OfficeClientEdition -Requested 32 -Inventory @(New-InventoryEntry 64) | Should -Be '32'
        Resolve-OfficeClientEdition -Requested 64 -Inventory @(New-InventoryEntry 32) -Is64BitOperatingSystem $true | Should -Be '64'
    }
    It 'requires removal before changing a Click-to-Run architecture' {
        { Resolve-OfficeClientEdition -Requested 32 -Inventory @(New-InventoryEntry 64) -SkipRemoval $true } | Should -Throw '*Uncheck*'
        Resolve-OfficeClientEdition -Requested 32 -Inventory @(New-InventoryEntry 32) -SkipRemoval $true | Should -Be '32'
    }
    It 'rejects conflicting protected products, mixed Auto inventories, unknown architecture and unsupported Windows' {
        { Resolve-OfficeClientEdition -Requested 32 -Inventory @(New-InventoryEntry 64 -Protected $true) } | Should -Throw '*preserving*'
        { Resolve-OfficeClientEdition -Inventory @((New-InventoryEntry 32), (New-InventoryEntry 64)) } | Should -Throw '*Mixed*'
        { Resolve-OfficeClientEdition -Requested 32 -Inventory @(New-InventoryEntry Unknown) } | Should -Throw '*could not be verified*'
        { Resolve-OfficeClientEdition -Requested 64 -Is64BitOperatingSystem $false } | Should -Throw '*64-bit Windows*'
    }
    It 'allows protected products when their architecture matches' {
        Resolve-OfficeClientEdition -Requested 32 -Inventory @(New-InventoryEntry 32 -Protected $true) | Should -Be '32'
    }
}

Describe 'Office deployment architecture' {
    BeforeEach {
        Mock Write-Log {}
        $script:OfficeChannel = 'MonthlyEnterprise'
        $script:OfficeLanguage = 'en-us'
        $script:OfficeExcludeApps = 'Access,Teams'
        $script:OfficeSharedComputerLicensing = $true
        $script:workDir = $TestDrive
        $script:officePreflightOk = $true
        Mock Invoke-OfficeSetup { [pscustomobject]@{ ExitCode = 0 } }
    }
    It 'stages <Edition>-bit XML and verifies only that architecture after setup' -TestCases @(
        @{ Edition = '32'; Platform = 'x86'; Other = 'x64' }
        @{ Edition = '64'; Platform = 'x64'; Other = 'x86' }
    ) {
        param($Edition, $Platform, $Other)
        $path = Join-Path $TestDrive 'install.xml'
        New-OfficeInstallXml $path 'C:\OfficeSource' -Edition $Edition
        [xml]$xml = Get-Content $path -Raw
        $xml.Configuration.Add.OfficeClientEdition | Should -Be $Edition
        $xml.Configuration.Add.SourcePath | Should -Be 'C:\OfficeSource'
        $xml.Configuration.Add.Product.ExcludeApp.ID | Should -Contain 'Access'
        $xml.Configuration.Property.Value | Should -Be '1'
        $config = @{ ProductReleaseIds = 'O365BusinessRetail'; Platform = $Platform; UpdateChannel = 'https://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6'; VersionToReport = '16.0.1' }
        Test-OfficeBusinessConfiguration $config MonthlyEnterprise -Edition $Edition | Should -BeTrue
        $config.Platform = $Other
        Test-OfficeBusinessConfiguration $config MonthlyEnterprise -Edition $Edition | Should -BeFalse
    }
    It 'removes business Office on the correct channel when its architecture differs from the target' {
        $script:officeClientEdition = '32'
        Mock Test-Path { $true }
        Mock Get-ItemProperty { @{ ProductReleaseIds = 'O365BusinessRetail'; Platform = 'x64'; UpdateChannel = 'https://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6' } }
        Uninstall-ExistingOffice 'setup.exe'
        Should -Invoke Invoke-OfficeSetup -Times 1 -Exactly -ParameterFilter { $Operation -eq 'removal' }
    }
    It 'reconfigures matching 32-bit business Office without uninstalling' {
        $script:officeClientEdition = '32'
        Mock Test-Path { $true }
        Mock Get-ItemProperty { @{ ProductReleaseIds = 'O365BusinessRetail'; Platform = 'x86'; UpdateChannel = 'https://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6' } }
        Uninstall-ExistingOffice 'setup.exe'
        Should -Invoke Invoke-OfficeSetup -Times 0 -Exactly
    }
}

Describe 'Office deployment phase ordering' {
    BeforeEach {
        $script:workDir = $TestDrive
        $script:OfficeArchitecture = 'Auto'
        $script:SkipOfficeRemoval = $false
        $script:SkipOfficeInstall = $false
        $script:OfficeChannel = 'MonthlyEnterprise'
        $script:OfficeLanguage = 'en-us'
        $script:OfficeExcludeApps = ''
        $script:OfficeSharedComputerLicensing = $false
        Mock Write-Log {}
        Mock Get-OfficeArchitectureInventory { New-InventoryEntry 32 }
        Mock Get-OfficeDeploymentTool { 'setup.exe' }
        Mock Invoke-OfficePreflight {}
        Mock Uninstall-ExistingOffice {}
        Mock Install-Microsoft365Business {}
    }
    It 'resolves Auto before removal and passes staged 32-bit XML to both download and installation' {
        Mock Invoke-OfficePreflight {
            [xml]$xml = Get-Content $InstallXmlPath -Raw
            $xml.Configuration.Add.OfficeClientEdition | Should -Be '32'
        }
        Mock Uninstall-ExistingOffice {
            # Removal changes the inventory, but must not change the already resolved edition.
            Mock Get-OfficeArchitectureInventory { @() }
        }
        Mock Install-Microsoft365Business {
            $script:officeClientEdition | Should -Be '32'
            [xml]$xml = Get-Content $InstallXmlPath -Raw
            $xml.Configuration.Add.OfficeClientEdition | Should -Be '32'
        }
        Invoke-OfficeDeployment
        Should -Invoke Invoke-OfficePreflight -Times 1 -Exactly
        Should -Invoke Uninstall-ExistingOffice -Times 1 -Exactly
        Should -Invoke Install-Microsoft365Business -Times 1 -Exactly
    }
    It 'blocks all Office operations when a protected product conflicts' {
        $script:OfficeArchitecture = '32'
        Mock Get-OfficeArchitectureInventory { New-InventoryEntry 64 -Protected $true }
        Invoke-OfficeDeployment
        $script:officePreflightOk | Should -BeFalse
        Should -Invoke Get-OfficeDeploymentTool -Times 0 -Exactly
        Should -Invoke Uninstall-ExistingOffice -Times 0 -Exactly
        Should -Invoke Install-Microsoft365Business -Times 0 -Exactly
    }
    It 'blocks download and installation when an architecture switch skips removal' {
        $script:OfficeArchitecture = '64'
        $script:SkipOfficeRemoval = $true
        Invoke-OfficeDeployment
        Should -Invoke Get-OfficeDeploymentTool -Times 0 -Exactly
        Should -Invoke Install-Microsoft365Business -Times 0 -Exactly
    }
    It 'blocks removal and installation after a failed source preflight' {
        Mock Invoke-OfficePreflight { $script:officePreflightOk = $false }
        Invoke-OfficeDeployment
        Should -Invoke Uninstall-ExistingOffice -Times 0 -Exactly
        Should -Invoke Install-Microsoft365Business -Times 0 -Exactly
    }
    It 'blocks installation after a failed removal' {
        Mock Uninstall-ExistingOffice { $script:officePreflightOk = $false }
        Invoke-OfficeDeployment
        Should -Invoke Install-Microsoft365Business -Times 0 -Exactly
    }
    It 'does not detect Office or access the network when both Office phases are skipped' {
        $script:SkipOfficeRemoval = $true
        $script:SkipOfficeInstall = $true
        Invoke-OfficeDeployment
        Should -Invoke Get-OfficeArchitectureInventory -Times 0 -Exactly
        Should -Invoke Get-OfficeDeploymentTool -Times 0 -Exactly
    }
}

Describe 'Native Office architecture selection' {
    BeforeAll {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        . ([scriptblock]::Create((Get-FunctionSource $gui 'Update-OfficeArchitectureStatus')))
        $script:guiText = [IO.File]::ReadAllText($gui)
        $ast = [Management.Automation.Language.Parser]::ParseFile($gui, [ref]$null, [ref]$null)
        $handler = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Expression -is [Management.Automation.Language.VariableExpressionAst] -and
            $node.Expression.VariablePath.UserPath -eq 'btnStart' -and $node.Member.Value -eq 'Add_Click'
        }, $true)
        $script:startHandler = $handler.Arguments[0].ScriptBlock.GetScriptBlock()
    }
    BeforeEach {
        $xml = [regex]::Match($guiText, '(?s)<Window\s.*?</Window>').Value
        $window = [Windows.Markup.XamlReader]::Parse($xml)
        # Bind the real named controls without executing GUI startup or showing a window.
        foreach ($match in [regex]::Matches($xml, '\bName="([A-Za-z0-9]+)"')) {
            Set-Variable -Name $match.Groups[1].Value -Value $window.FindName($match.Groups[1].Value)
        }
        $officeDetected = $window.FindName('OfficeDetected')
        $script:deployProc = $null
        $script:workDir = $TestDrive
        $deployScript = $engine
        $optDryRun.IsChecked = $true
        Mock Get-OfficeArchitectureInventory { New-InventoryEntry 32 }
        Mock Start-Process { [pscustomobject]@{ Id = 1234; HasExited = $false } }
    }
    It 'passes selection <Value> from the real ComboBox into the worker command' -TestCases @(
        @{ Index = 0; Value = 'Auto' }
        @{ Index = 1; Value = '32' }
        @{ Index = 2; Value = '64' }
    ) {
        param($Index, $Value)
        $optOfficeArchitecture.SelectedIndex = $Index
        & $startHandler
        $officeDetected.Text | Should -Be 'Detected Office: 32-bit'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $position = [array]::IndexOf($ArgumentList, '-OfficeArchitecture')
            $position -ge 0 -and $ArgumentList[$position + 1] -eq $Value -and $ArgumentList -contains '-DryRun'
        }
    }
}
