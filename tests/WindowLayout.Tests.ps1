BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:gui = Join-Path $PSScriptRoot '..\debloat\Gr3ysUtilities.ps1'
    foreach ($name in @('Get-MainWindowSize', 'Set-MainWindowLayout')) {
        . ([scriptblock]::Create((Get-FunctionSource $gui $name)))
    }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    function New-LayoutWindow {
        $xml = [regex]::Match([IO.File]::ReadAllText($gui), '(?s)<Window\s.*?</Window>').Value
        $result = [Windows.Markup.XamlReader]::Parse($xml)
        $result.FindName('LogoImage').Visibility = 'Visible'
        $result.FindName('SacStatusBorder').Visibility = 'Visible'
        $result.FindName('SacStatusText').Text = 'Smart App Control: Evaluation'
        return $result
    }
    function Arrange-LayoutWindow {
        param($Window, [double]$Width, [double]$Height, [int]$Tab = 0)
        $Window.MinWidth = [Math]::Min($Width, 860)
        $Window.MinHeight = [Math]::Min($Height, 480)
        $Window.Width = $Width; $Window.Height = $Height
        $Window.FindName('MainTabs').SelectedIndex = $Tab
        Set-MainWindowLayout $Window
        $size = [Windows.Size]::new($Width, $Height)
        $Window.Content.Measure($size)
        $Window.Content.Arrange([Windows.Rect]::new($size))
        $Window.Content.UpdateLayout()
    }
    function Assert-InClient {
        param($Window, [string[]]$Names)
        foreach ($name in $Names) {
            $control = $Window.FindName($name)
            $bounds = $control.TransformToAncestor($Window.Content).TransformBounds([Windows.Rect]::new($control.RenderSize))
            $bounds.Width | Should -BeGreaterThan 0 -Because $name
            $bounds.Height | Should -BeGreaterThan 0 -Because $name
            $bounds.Left | Should -BeGreaterOrEqual -1 -Because $name
            $bounds.Top | Should -BeGreaterOrEqual -1 -Because $name
            $bounds.Right | Should -BeLessOrEqual ($Window.Width + 1) -Because $name
            $bounds.Bottom | Should -BeLessOrEqual ($Window.Height + 1) -Because $name
        }
    }
}

Describe 'Laptop window startup bounds' {
    It 'fits the effective work area without growing to fill the screen: <Width>x<Height>' -TestCases @(
        @{ Width = 1366; Height = 728 }
        @{ Width = 1280; Height = 680 }
        @{ Width = 1024; Height = 576 }
        @{ Width = 854; Height = 472 }
        @{ Width = 3840; Height = 2120 }
    ) {
        param($Width, $Height)
        $size = Get-MainWindowSize $Width $Height
        $size.Width | Should -BeLessOrEqual ($Width - 32)
        $size.Height | Should -BeLessOrEqual ($Height - 32)
        $size.Width | Should -BeLessOrEqual 960
        $size.Height | Should -BeLessOrEqual 640
        $size.MinWidth | Should -BeLessOrEqual $size.Width
        $size.MinHeight | Should -BeLessOrEqual $size.Height
    }
}

Describe 'Real WPF controls at laptop sizes' {
    It 'keeps navigation, running-job actions and logs reachable at <Width>x<Height>' -TestCases @(
        @{ Width = 960; Height = 640 }
        @{ Width = 860; Height = 480 }
        @{ Width = 822; Height = 440 }
    ) {
        param($Width, $Height)
        $window = New-LayoutWindow
        foreach ($name in @('BtnStop', 'BtnReboot', 'BtnDownloadLog', 'BannerBorder')) { $window.FindName($name).Visibility = 'Visible' }
        $window.FindName('BannerText').Text = 'Run finished with warnings. Review the log before handing over this machine.'
        Arrange-LayoutWindow $window $Width $Height
        $window.FindName('DebloatOptionsScroll').ScrollToEnd()
        $window.Content.UpdateLayout()
        Assert-InClient $window @('NavProvisioning', 'BtnWinClose', 'BtnScan', 'BtnStart', 'BtnStop', 'BtnDownloadLog', 'BtnReboot', 'LogBox')
        $window.FindName('LogBox').ActualHeight | Should -BeGreaterThan 50
        $window.FindName('DebloatOptionsScroll').ScrollableHeight | Should -BeGreaterThan 0
        $window.FindName('SacStatusText').ToolTip | Should -Be 'Smart App Control: Evaluation'
    }
    It 'wraps filters and keeps export, comparison and install actions on screen at <Width>x<Height>' -TestCases @(
        @{ Width = 960; Height = 640 }
        @{ Width = 860; Height = 480 }
    ) {
        param($Width, $Height)
        $window = New-LayoutWindow
        foreach ($name in @('CatCompareResults', 'BtnInstallWinGet', 'BtnStopInstall')) { $window.FindName($name).Visibility = 'Visible' }
        $window.FindName('InstallStatusText').Text = 'Choose one Office edition: 32-bit or 64-bit. Clear the other checkbox.'
        Arrange-LayoutWindow $window $Width $Height 1
        Assert-InClient $window @('CatCompareResults', 'BtnSelectAll', 'BtnClearSelection', 'BtnInstallWinGet', 'BtnInstallSelected', 'BtnExportInstalled', 'BtnCompareBaseline', 'BtnStopInstall', 'InstallLogBox')
        $window.FindName('InstallLogBox').ActualHeight | Should -BeGreaterThan 100
    }
    It 'stacks Config content and log at laptop widths and restores the wide layout when enlarged' {
        $window = New-LayoutWindow
        Arrange-LayoutWindow $window 960 640 2
        [Windows.Controls.Grid]::GetRow($window.FindName('ConfigLogPanel')) | Should -Be 1
        Assert-InClient $window @('BtnFixSystemRepair', 'BtnFixWinGet', 'FixesLogBox')
        Arrange-LayoutWindow $window 1400 820 2
        [Windows.Controls.Grid]::GetColumn($window.FindName('ConfigLogPanel')) | Should -Be 2
        Assert-InClient $window @('BtnFixSystemRepair', 'FixesLogBox')
        Arrange-LayoutWindow $window 860 480 2
        [Windows.Controls.Grid]::GetRow($window.FindName('ConfigLogPanel')) | Should -Be 1
        Assert-InClient $window @('BtnFixSystemRepair', 'FixesLogBox')
    }
}
