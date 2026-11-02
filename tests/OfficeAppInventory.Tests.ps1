BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:gui = Join-Path $PSScriptRoot '..\debloat\Gr3ysUtilities.ps1'
    $script:exporter = Join-Path $PSScriptRoot '..\debloat\Export-InstalledApps.ps1'
    $script:engine = Join-Path $PSScriptRoot '..\debloat\Deploy-DellOfficeSetup.ps1'
    $script:shared = @('Get-OfficeAppInventory', 'Get-OfficeExportSummary', 'New-InstalledAppsExport')
    foreach ($name in ($shared + @('Test-OfficeSuiteDisplayName', 'Test-OfficeCatalogInstalled', 'Get-OfficeComparePlan', 'Test-OfficeCatalogRunSucceeded', 'Start-OfficeCatalogInstall', 'Start-AppQueue', 'Start-NextInQueue'))) {
        . ([scriptblock]::Create((Get-FunctionSource $gui $name)))
    }
    function Get-OfficeArchitectureInventory {}
    function Get-UninstallEntries {}
    function Get-WingetListedIds { param($Lines) @() }
    function Get-RunningToolJobs { @() }
    function Complete-InstallQueueItem {}
    function Update-AppVisibility {}
    function Test-DotNetRuntimeNameMatch { $false }
    function winget.exe { throw 'not installed' }
    function New-OfficeFixture {
        param([string]$Edition = '32', [string[]]$Ids = @('O365BusinessRetail'))
        [pscustomobject]@{ Name = 'Click-to-Run Office'; Edition = $Edition; Kind = 'ClickToRun'; ProductIds = $Ids }
    }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $text = [IO.File]::ReadAllText($gui)
    $start = $text.IndexOf('                    $baseline = $script:installPendingAction.Baseline')
    $end = $text.IndexOf('                } else {' + "`n" + '                    # One consolidated', $start)
    if ($start -lt 0 -or $end -lt 0) { throw 'Real compare handler not found' }
    $script:compareHandler = [scriptblock]::Create($text.Substring($start, $end - $start))
    $exportAst = [Management.Automation.Language.Parser]::ParseFile($exporter, [ref]$null, [ref]$null)
    $script:exportMain = [scriptblock]::Create((@($exportAst.EndBlock.Statements | Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.Extent.Text }) -join "`n"))
}

Describe 'Office export metadata and transport' {
    BeforeEach {
        Mock Get-OfficeArchitectureInventory { New-OfficeFixture }
        Mock Get-UninstallEntries { [pscustomobject]@{ DisplayName = 'Microsoft 365 Apps for business - en-us' } }
        $Code = $null; $OutputPath = $null
    }
    It 'keeps actual architecture, product IDs and names through JSON serialization' {
        $export = New-InstalledAppsExport -WingetIds @('Microsoft.Office') -ProgramNames @('Microsoft 365 Apps for business - en-us')
        $copy = $export | ConvertTo-Json -Depth 4 | ConvertFrom-Json
        $copy.officeDetectionStatus | Should -Be 'Detected'
        $copy.officeInstallations[0].architecture | Should -Be '32'
        $copy.officeInstallations[0].isSuite | Should -BeTrue
        $copy.officeInstallations[0].productIds | Should -Contain 'O365BusinessRetail'
        $copy.wingetIds | Should -Contain 'Microsoft.Office'
        Get-OfficeExportSummary $copy | Should -Be 'Office detected: 32-bit.'
    }
    It 'exports 32-bit Office without winget using the real standalone main block' {
        $json = & $exportMain -WarningAction SilentlyContinue
        $export = $json | ConvertFrom-Json
        @($export.wingetIds).Count | Should -Be 0
        $export.officeInstallations[0].architecture | Should -Be '32'
    }
    It 'sends Office metadata in the pairing payload' {
        $Code = 'ABC123'
        $RelayUrl = 'https://example.invalid'
        $script:sentBody = $null
        Mock Invoke-RestMethod { $script:sentBody = $Body }
        & $exportMain -WarningAction SilentlyContinue | Out-Null
        $received = $sentBody | ConvertFrom-Json
        $received.officeInstallations[0].architecture | Should -Be '32'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }
    It 'distinguishes detection failure from no Office' {
        Mock Get-OfficeArchitectureInventory { throw 'Access denied' }
        $failed = New-InstalledAppsExport
        $failed.officeDetectionStatus | Should -Be 'Failed'
        Get-OfficeExportSummary $failed | Should -Match 'detection failed'
        Mock Get-OfficeArchitectureInventory { @() }
        (New-InstalledAppsExport).officeDetectionStatus | Should -Be 'NotDetected'
    }
    It 'uses identical detection and export logic in GUI and standalone exports' {
        foreach ($name in ($shared + @('Get-OfficeExecutableEdition', 'Get-OfficeArchitectureInventory'))) {
            Get-FunctionSource $gui $name | Should -BeExactly (Get-FunctionSource $exporter $name)
        }
        Get-FunctionSource $gui 'Get-OfficeArchitectureInventory' | Should -BeExactly (Get-FunctionSource $engine 'Get-OfficeArchitectureInventory')
    }
}

Describe 'Office comparison and catalog selection' {
    BeforeEach {
        $script:sourceFixture = New-OfficeFixture
        $script:currentFixture = @()
        Mock Get-OfficeArchitectureInventory { $currentFixture }
        Mock Get-UninstallEntries { @() }
        $script:appEntries = @('32', '64') | ForEach-Object {
            [pscustomobject]@{ Name = "Microsoft 365 Apps ($_-bit)"; OfficeArchitecture = $_; WingetId = $null; CompareMatch = $false; CheckBox = [Windows.Controls.CheckBox]::new() }
        }
        $script:installPendingAction = [pscustomobject]@{ Action = 'compare'; Baseline = [pscustomobject]@{
            hostname = 'OLDPC'; exportedAt = '2026-11-01'; wingetIds = @('Microsoft.Office');
            installedProgramNames = @('Microsoft 365 Apps for business - en-us'); officeDetectionStatus = 'Detected';
            officeInstallations = @([pscustomobject]@{ name = 'Microsoft 365 Apps for business'; architecture = '32'; isSuite = $true; productIds = @('O365BusinessRetail'); installationType = 'ClickToRun' })
        } }
        $installedIds = New-Object 'System.Collections.Generic.HashSet[string]'
        $installLogBox = [Windows.Controls.TextBox]::new()
        $installStatusText = [Windows.Controls.TextBlock]::new()
        $catCompareResultsBtn = [Windows.Controls.Button]::new()
        $accentBrush = [Windows.Media.Brushes]::Cyan
        $script:activeCategory = 'All'
        Mock Update-AppVisibility {}
    }
    It 'checks only 32-bit Office and shows the source bitness on a clean replacement PC' {
        $appEntries[1].CheckBox.IsChecked = $true
        & $compareHandler
        $appEntries[0].CheckBox.IsChecked | Should -BeTrue
        $appEntries[1].CheckBox.IsChecked | Should -BeFalse
        $appEntries[0].CompareMatch | Should -BeTrue
        $installLogBox.Text | Should -Match 'Old machine: Microsoft 365 Apps for business - 32-bit'
        $installLogBox.Text | Should -Match 'Replacement option.*32-bit'
        $script:activeCategory | Should -Be 'Compare Results'
    }
    It 'does not treat 64-bit Office as satisfying a 32-bit source, even when winget IDs match' {
        $script:currentFixture = @(New-OfficeFixture 64)
        [void]$installedIds.Add('Microsoft.Office')
        & $compareHandler
        $appEntries[0].CheckBox.IsChecked | Should -BeTrue
        $installLogBox.Text | Should -Match 'This machine: Click-to-Run Office - 64-bit'
    }
    It 'does not select a replacement when matching 32-bit business Office is already installed' {
        $script:currentFixture = @(New-OfficeFixture 32)
        & $compareHandler
        $appEntries[0].CheckBox.IsChecked | Should -BeFalse
        $installLogBox.Text | Should -Match 'Matching 32-bit.*already installed'
    }
    It 'selects 64-bit when the exported source is 64-bit' {
        $installPendingAction.Baseline.officeInstallations[0].architecture = '64'
        & $compareHandler
        $appEntries[0].CheckBox.IsChecked | Should -BeFalse
        $appEntries[1].CheckBox.IsChecked | Should -BeTrue
    }
    It 'does not invent bitness for an older export and clears a prior compare selection' {
        $appEntries[0].CompareMatch = $true
        $appEntries[0].CheckBox.IsChecked = $true
        $installPendingAction.Baseline.officeInstallations = @()
        $installPendingAction.Baseline.officeDetectionStatus = $null
        & $compareHandler
        $appEntries[0].CheckBox.IsChecked | Should -BeFalse
        $installLogBox.Text | Should -Match 'bitness not recorded'
    }
    It 'does not suggest the Office suite for a Visio-only source or mixed bitness' {
        $emptyCurrent = [pscustomobject]@{ Status = 'NotDetected'; Installations = @() }
        $baseline = $installPendingAction.Baseline
        $baseline.officeInstallations[0].isSuite = $false
        (Get-OfficeComparePlan $baseline $emptyCurrent).Edition | Should -BeNullOrEmpty
        $baseline.officeInstallations[0].isSuite = $true
        $baseline.officeInstallations += [pscustomobject]@{ name = 'Other Office'; architecture = '64'; isSuite = $true }
        (Get-OfficeComparePlan $baseline $emptyCurrent).Edition | Should -BeNullOrEmpty
    }
    It 'does not mark consumer Office as the installed business edition' {
        $script:currentFixture = @(New-OfficeFixture 32 @('O365BusinessRetail', 'O365HomePremRetail'))
        Test-OfficeCatalogInstalled 32 (Get-OfficeAppInventory) | Should -BeFalse
    }
    It 'does not report a failed repair as successful merely because matching Office was already installed' {
        $script:currentFixture = @(New-OfficeFixture 32)
        Test-OfficeCatalogRunSucceeded 32 0 'Office installation failed.' (Get-OfficeAppInventory) | Should -BeFalse
        Test-OfficeCatalogRunSucceeded 32 0 'Office deployment verified: 64-bit.' (Get-OfficeAppInventory) | Should -BeFalse
    }
    It 'accepts only a successful worker verification followed by matching current Office' {
        $script:currentFixture = @(New-OfficeFixture 32)
        Test-OfficeCatalogRunSucceeded 32 0 'Office deployment verified: 32-bit.' (Get-OfficeAppInventory) | Should -BeTrue
        Test-OfficeCatalogRunSucceeded 32 1 'Office deployment verified: 32-bit.' (Get-OfficeAppInventory) | Should -BeFalse
        $script:currentFixture = @(New-OfficeFixture 64)
        Test-OfficeCatalogRunSucceeded 32 0 'Office deployment verified: 32-bit.' (Get-OfficeAppInventory) | Should -BeFalse
    }
}

Describe 'Office checklist installation' {
    BeforeEach {
        $script:workDir = $TestDrive
        $script:deployScript = $engine
        $script:installDone = 0
        $script:installFailedCount = 0
        $script:installFailedNames = New-Object 'System.Collections.Generic.List[string]'
        $script:installMode = 'install'
        $script:installTotal = 1
        $installLogBox = [Windows.Controls.TextBox]::new()
        $installStatusText = [Windows.Controls.TextBlock]::new()
        Mock Get-RunningToolJobs { @() }
        Mock Start-Process { [pscustomobject]@{ Id = 1234; Handle = [IntPtr]::Zero } }
        Mock Complete-InstallQueueItem {}
    }
    It 'uses the real Office engine with an explicit <Edition>-bit argument and no OEM debloat' -TestCases @(@{ Edition = '32' }, @{ Edition = '64' }) {
        param($Edition)
        Start-OfficeCatalogInstall $Edition (Join-Path $TestDrive 'office.log') | Out-Null
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $index = [array]::IndexOf($ArgumentList, '-OfficeArchitecture')
            $FilePath -eq 'powershell.exe' -and $ArgumentList[$index + 1] -eq $Edition -and
            $ArgumentList -contains '-SkipDebloat' -and $ArgumentList -notcontains '-SkipOfficeRemoval' -and $WindowStyle -eq 'Hidden'
        }
    }
    It 'dispatches the Office checklist item without running winget or treating it as manual-only' {
        $script:installQueue = New-Object 'System.Collections.Generic.Queue[object]'
        $installQueue.Enqueue([pscustomobject]@{ Name = 'Microsoft 365 Apps (32-bit)'; OfficeArchitecture = '32' })
        Mock Start-OfficeCatalogInstall { [pscustomobject]@{ Id = 1234; Handle = [IntPtr]::Zero } }
        Start-NextInQueue
        Should -Invoke Start-OfficeCatalogInstall -Times 1 -Exactly -ParameterFilter { $Edition -eq '32' }
        $script:installDone | Should -Be 1
    }
    It 'blocks contradictory 32-bit and 64-bit selections before any installer starts' {
        $script:appEntries = @('32', '64') | ForEach-Object { [pscustomobject]@{ OfficeArchitecture = $_; CheckBox = [pscustomobject]@{ IsChecked = $true } } }
        Start-AppQueue install
        $installStatusText.Text | Should -Match 'Choose one Office edition'
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It 'does not start queued Office while another deployment job is running' {
        $script:installQueue = New-Object 'System.Collections.Generic.Queue[object]'
        $installQueue.Enqueue([pscustomobject]@{ Name = 'Microsoft 365 Apps (32-bit)'; OfficeArchitecture = '32' })
        Mock Get-RunningToolJobs { 'Debloat / Office' }
        Start-NextInQueue
        $script:installFailedCount | Should -Be 1
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It 'has distinct 32-bit and 64-bit checkboxes in the shipped catalog' {
        $catalog = Get-Content (Join-Path $PSScriptRoot '..\debloat\apps-catalog.json') -Raw | ConvertFrom-Json
        $office = @($catalog.apps | Where-Object { $_.officeArchitecture })
        $office.Count | Should -Be 2
        @($office.officeArchitecture | Sort-Object) | Should -Be @('32', '64')
        @($office | Where-Object { $_.wingetId -or $_.downloadUrl }).Count | Should -Be 0
    }
}
