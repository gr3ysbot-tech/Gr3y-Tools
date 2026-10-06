# Pester tests for how the Install Apps tab lays out debloat/apps-catalog.json: Get-AppCatalogLayout (splits a category such as
# Utilities into the named groups the catalog lists for it) and the code in Gr3ysUtilities.ps1 that builds the list and hides
# whatever the active filter does not show (the population loop and Update-AppVisibility). All of it is the REAL code, cut out of
# the script with the PowerShell parser. The layout function and the real catalog are checked without a window; the population
# loop and the filter run against real WPF controls in a StackPanel that is never shown (they need an STA thread and WPF, as in
# Windows PowerShell 5.1 and PowerShell 7 on Windows; they are skipped in a session without those, and CI fails instead of
# skipping them). Nothing is installed and no app is looked up. ASCII only.

BeforeDiscovery {
    # the owner's own grouping of the Utilities apps (their list, 2026-10-06), in their order
    $script:ownerGroups = @(
        @{ Group = 'Security & Privacy'; Apps = @('1Password', 'Bitwarden', 'Cloudflare WARP') }
        @{ Group = 'File Management & Archiving'; Apps = @('7-Zip', 'Everything', 'Files', 'NanaZip', 'PeaZip', 'Total Commander', 'WinSCP', 'TreeSize Free', 'WizTree') }
        @{ Group = 'System Info, Diagnostics & Benchmarking'; Apps = @('CPU-Z', 'Crystal Disk Info', 'Crystal Disk Mark', 'HWiNFO') }
        @{ Group = 'System Optimization, Maintenance & Tweaks'; Apps = @('Notepad++', 'Policy Plus', 'Process Lasso', 'Revo Uninstaller', 'TranslucentTB', 'Wise Program Uninstaller') }
        @{ Group = 'Networking, Remote Access & IT Tools'; Apps = @('Advanced IP Scanner', 'AnyDesk', 'PuTTY', 'Snappy Driver Installer Origin', 'TeamViewer', 'TightVNC', 'Wireshark') }
        @{ Group = 'Cloud Storage & Sync'; Apps = @('Dropbox', 'Google Drive') }
        @{ Group = 'Disk Partitioning, Imaging & Virtualization'; Apps = @('MiniTool Partition Wizard', 'Oracle VirtualBox', 'Rufus Imager') }
        @{ Group = 'Automation & Productivity'; Apps = @('AutoHotkey') }
        @{ Group = 'Media & Entertainment'; Apps = @('VLC media player') }
    )
    # the ten Utilities apps that were not in that list: all of them are hidden from Business Baseline, and each was put where it fits
    $script:unlistedApps = @(
        @{ App = 'F.lux'; Group = 'System Optimization, Maintenance & Tweaks' }
        @{ App = 'MSEdgeRedirect'; Group = 'System Optimization, Maintenance & Tweaks' }
        @{ App = 'NVCleanstall'; Group = 'System Optimization, Maintenance & Tweaks' }
        @{ App = 'OFGB (Oh Frick Go Back)'; Group = 'System Optimization, Maintenance & Tweaks' }
        @{ App = 'OpenRGB'; Group = 'System Optimization, Maintenance & Tweaks' }
        @{ App = 'Nmap'; Group = 'Networking, Remote Access & IT Tools' }
        @{ App = 'Parsec'; Group = 'Networking, Remote Access & IT Tools' }
        @{ App = 'qBittorrent'; Group = 'Networking, Remote Access & IT Tools' }
        @{ App = 'Deskflow'; Group = 'Automation & Productivity' }
        @{ App = 'GlazeWM'; Group = 'Automation & Productivity' }
    )

    # the control tests need an STA thread and a session in which WPF controls can be created (nothing is ever shown)
    $script:canRunWindow = $false
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
        try {
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction Stop
            $null = New-Object System.Windows.Controls.StackPanel
            $script:canRunWindow = $true
        } catch { $script:canRunWindow = $false }
    }
    # CI must really run these tests: a runner that cannot (no STA thread, no WPF) fails here instead of skipping them silently
    if (-not $script:canRunWindow -and $env:CI) { throw 'The Install Apps list tests need an STA session with WPF (Windows PowerShell 5.1) and CI must not skip them.' }
}

Describe 'Get-AppCatalogLayout (synthetic catalogs)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
        $gui = Join-Path $PSScriptRoot '..\debloat\Gr3ysUtilities.ps1'
        . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $gui -FunctionName 'Get-AppCatalogLayout')))

        # one line per group: "Category > Group: app, app" (a category without groups: "Category: app, app")
        function Format-Layout {
            param($Blocks)
            foreach ($b in @($Blocks)) {
                foreach ($g in @($b.Groups)) {
                    $where = if ($g.Name) { $b.Category + ' > ' + $g.Name } else { $b.Category }
                    $where + ': ' + (@($g.Apps | ForEach-Object { $_.name }) -join ', ')
                }
            }
        }
    }

    It 'splits a category into its listed groups, in the listed order, and sorts the apps by name inside each group' {
        $catalog = @'
{ "categoryGroups": { "Tools": ["Zeta", "Alpha", "Mid"] },
  "apps": [
    { "name": "banana", "category": "Tools", "group": "Alpha", "wingetId": "y.banana" },
    { "name": "Mid One", "category": "Tools", "group": "Mid", "wingetId": "x.mid1" },
    { "name": "Zed", "category": "Tools", "group": "Zeta", "wingetId": "x.zed" },
    { "name": "Apple", "category": "Tools", "group": "Alpha", "wingetId": "z.apple" },
    { "name": "Cherry", "category": "Tools", "group": "Alpha", "wingetId": "x.cherry" }
  ] }
'@ | ConvertFrom-Json
        @(Format-Layout (Get-AppCatalogLayout -Catalog $catalog)) | Should -BeExactly @(
            'Tools > Zeta: Zed'
            'Tools > Alpha: Apple, banana, Cherry'
            'Tools > Mid: Mid One')
    }

    It 'keeps a category that has no groups listed as one list with no group name' {
        $catalog = @'
{ "apps": [
    { "name": "Beta", "category": "Plain", "wingetId": "x.a" },
    { "name": "Alpha", "category": "Plain", "wingetId": "x.b" }
  ] }
'@ | ConvertFrom-Json
        $blocks = @(Get-AppCatalogLayout -Catalog $catalog)
        $blocks.Count | Should -Be 1
        $blocks[0].Groups.Count | Should -Be 1
        $blocks[0].Groups[0].Name | Should -Be ''
        @(Format-Layout $blocks) | Should -BeExactly @('Plain: Alpha, Beta')
    }

    It 'sorts the categories alphabetically, grouped or not' {
        $catalog = @'
{ "categoryGroups": { "Mine": ["One"] },
  "apps": [
    { "name": "z", "category": "Zebra", "wingetId": "x.z" },
    { "name": "m", "category": "Mine", "group": "One", "wingetId": "x.m" },
    { "name": "a", "category": "Apple", "wingetId": "x.a" }
  ] }
'@ | ConvertFrom-Json
        @(Get-AppCatalogLayout -Catalog $catalog | ForEach-Object { $_.Category }) | Should -BeExactly @('Apple', 'Mine', 'Zebra')
    }

    It 'leaves out a listed group that no app uses' {
        $catalog = @'
{ "categoryGroups": { "Tools": ["Empty", "Used", "AlsoEmpty"] },
  "apps": [ { "name": "A", "category": "Tools", "group": "Used", "wingetId": "x.a" } ] }
'@ | ConvertFrom-Json
        @(Format-Layout (Get-AppCatalogLayout -Catalog $catalog)) | Should -BeExactly @('Tools > Used: A')
    }

    It 'puts an app that names no group last, under Other, so that it is never lost' {
        $catalog = @'
{ "categoryGroups": { "Tools": ["First", "Second"] },
  "apps": [
    { "name": "Loose", "category": "Tools", "wingetId": "x.a" },
    { "name": "B", "category": "Tools", "group": "Second", "wingetId": "x.b" },
    { "name": "A", "category": "Tools", "group": "First", "wingetId": "x.a2" },
    { "name": "Blank", "category": "Tools", "group": "", "wingetId": "x.z" }
  ] }
'@ | ConvertFrom-Json
        @(Format-Layout (Get-AppCatalogLayout -Catalog $catalog)) | Should -BeExactly @(
            'Tools > First: A'
            'Tools > Second: B'
            'Tools > Other: Blank, Loose')
    }

    It 'puts an app whose group is not in the list under Other, also when only the case differs' {
        $catalog = @'
{ "categoryGroups": { "Tools": ["Security & Privacy"] },
  "apps": [
    { "name": "Typo", "category": "Tools", "group": "Security and Privacy", "wingetId": "x.typo" },
    { "name": "Case", "category": "Tools", "group": "security & privacy", "wingetId": "x.case" },
    { "name": "Right", "category": "Tools", "group": "Security & Privacy", "wingetId": "x.right" }
  ] }
'@ | ConvertFrom-Json
        @(Format-Layout (Get-AppCatalogLayout -Catalog $catalog)) | Should -BeExactly @(
            'Tools > Security & Privacy: Right'
            'Tools > Other: Case, Typo')
    }

    It 'keeps two groups whose names differ only in case apart' {
        $catalog = @'
{ "categoryGroups": { "Tools": ["Alpha", "alpha"] },
  "apps": [
    { "name": "Upper", "category": "Tools", "group": "Alpha", "wingetId": "x.upper" },
    { "name": "Lower", "category": "Tools", "group": "alpha", "wingetId": "x.lower" }
  ] }
'@ | ConvertFrom-Json
        @(Format-Layout (Get-AppCatalogLayout -Catalog $catalog)) | Should -BeExactly @('Tools > Alpha: Upper', 'Tools > alpha: Lower')
    }

    It 'sorts the apps by name, whatever their ids and their order in the file are' {
        # ids that sort the other way round from the names, a file order that matches neither, and names that differ in case
        $catalog = @'
{ "categoryGroups": { "Tools": ["Named"] },
  "apps": [
    { "name": "Mango", "category": "Tools", "group": "Named", "wingetId": "a.zzz" },
    { "name": "apple", "category": "Tools", "group": "Named", "wingetId": "c.yyy" },
    { "name": "Banana", "category": "Tools", "group": "Named", "wingetId": "b.xxx" },
    { "name": "Zeta", "category": "Tools", "group": "Named", "wingetId": "a.aaa" },
    { "name": "orange", "category": "Tools", "wingetId": "a.bbb" },
    { "name": "Kiwi", "category": "Tools", "wingetId": "z.aaa" },
    { "name": "Fig", "category": "Tools", "group": "Unlisted", "wingetId": "y.aaa" },
    { "name": "Plum", "category": "Plain", "wingetId": "a.zzz" },
    { "name": "Date", "category": "Plain", "wingetId": "b.yyy" },
    { "name": "cherry", "category": "Plain", "wingetId": "c.xxx" }
  ] }
'@ | ConvertFrom-Json
        @(Format-Layout (Get-AppCatalogLayout -Catalog $catalog)) | Should -BeExactly @(
            'Plain: cherry, Date, Plum'
            'Tools > Named: apple, Banana, Mango, Zeta'
            'Tools > Other: Fig, Kiwi, orange')
    }

    It 'builds a group that is listed twice only once' {
        $catalog = @'
{ "categoryGroups": { "Tools": ["First", "First", "Second", "First"] },
  "apps": [
    { "name": "A", "category": "Tools", "group": "First", "wingetId": "x.a" },
    { "name": "B", "category": "Tools", "group": "Second", "wingetId": "x.b" }
  ] }
'@ | ConvertFrom-Json
        @(Format-Layout (Get-AppCatalogLayout -Catalog $catalog)) | Should -BeExactly @('Tools > First: A', 'Tools > Second: B')
    }

    It 'never makes a second Other group when the list names one' {
        $catalog = @'
{ "categoryGroups": { "Tools": ["First", "Other", "Second"] },
  "apps": [
    { "name": "A", "category": "Tools", "group": "First", "wingetId": "x.a" },
    { "name": "B", "category": "Tools", "group": "Other", "wingetId": "x.b" },
    { "name": "C", "category": "Tools", "wingetId": "x.c" },
    { "name": "D", "category": "Tools", "group": "Second", "wingetId": "x.d" }
  ] }
'@ | ConvertFrom-Json
        @(Format-Layout (Get-AppCatalogLayout -Catalog $catalog)) | Should -BeExactly @('Tools > First: A', 'Tools > Second: D', 'Tools > Other: B, C')
    }

    It 'lays a category out as one plain list when the only group it lists is Other' {
        $catalog = @'
{ "categoryGroups": { "Tools": ["Other"] },
  "apps": [
    { "name": "B", "category": "Tools", "group": "Other", "wingetId": "x.b" },
    { "name": "A", "category": "Tools", "wingetId": "x.a" }
  ] }
'@ | ConvertFrom-Json
        @(Format-Layout (Get-AppCatalogLayout -Catalog $catalog)) | Should -BeExactly @('Tools: A, B')
    }

    It 'shows everything under Other when the catalog lists groups but no app names one' {
        $catalog = @'
{ "categoryGroups": { "Tools": ["First"] },
  "apps": [ { "name": "A", "category": "Tools", "wingetId": "x.a" }, { "name": "B", "category": "Tools", "wingetId": "x.b" } ] }
'@ | ConvertFrom-Json
        @(Format-Layout (Get-AppCatalogLayout -Catalog $catalog)) | Should -BeExactly @('Tools > Other: A, B')
    }

    It 'ignores a group on an app whose category the catalog does not split into groups' {
        $catalog = @'
{ "categoryGroups": { "Tools": ["First"] },
  "apps": [
    { "name": "B", "category": "Plain", "group": "Whatever", "wingetId": "x.b" },
    { "name": "A", "category": "Plain", "group": "Another", "wingetId": "x.a" },
    { "name": "T", "category": "Tools", "group": "First", "wingetId": "x.t" }
  ] }
'@ | ConvertFrom-Json
        @(Format-Layout (Get-AppCatalogLayout -Catalog $catalog)) | Should -BeExactly @('Plain: A, B', 'Tools > First: T')
    }

    It 'ignores a listed category that has no apps' {
        $catalog = @'
{ "categoryGroups": { "Gaming": ["Shooters"], "Tools": ["First"] },
  "apps": [ { "name": "T", "category": "Tools", "group": "First", "wingetId": "x.t" } ] }
'@ | ConvertFrom-Json
        @(Format-Layout (Get-AppCatalogLayout -Catalog $catalog)) | Should -BeExactly @('Tools > First: T')
    }

    It 'treats an empty or null categoryGroups as none' {
        $apps = '"apps": [ { "name": "A", "category": "Tools", "group": "First", "wingetId": "x.a" } ]'
        foreach ($head in '"categoryGroups": {},', '"categoryGroups": null,', '') {
            $catalog = ('{ ' + $head + ' ' + $apps + ' }') | ConvertFrom-Json
            @(Format-Layout (Get-AppCatalogLayout -Catalog $catalog)) | Should -BeExactly @('Tools: A') -Because "head: $head"
        }
    }

    It 'keeps arrays for a single category, a single group and a single app' {
        $catalog = @'
{ "categoryGroups": { "Tools": ["Only"] },
  "apps": [ { "name": "Solo", "category": "Tools", "group": "Only", "wingetId": "x.solo" } ] }
'@ | ConvertFrom-Json
        $blocks = @(Get-AppCatalogLayout -Catalog $catalog)
        $blocks.Count | Should -Be 1
        $blocks[0].Groups -is [array] | Should -BeTrue
        $blocks[0].Groups.Count | Should -Be 1
        $blocks[0].Groups[0].Apps -is [array] | Should -BeTrue
        $blocks[0].Groups[0].Apps.Count | Should -Be 1
        $blocks[0].Groups[0].Apps[0].name | Should -BeExactly 'Solo'
    }

    It 'returns no blocks for an empty catalog' {
        @(Get-AppCatalogLayout -Catalog ('{ "apps": [] }' | ConvertFrom-Json)).Count | Should -Be 0
        @(Get-AppCatalogLayout -Catalog ('{ "categoryGroups": { "Tools": ["First"] }, "apps": [] }' | ConvertFrom-Json)).Count | Should -Be 0
    }

    It 'hands over the catalog entries themselves, so every field the installer needs is still there' {
        $catalog = @'
{ "categoryGroups": { "Tools": ["First"] },
  "apps": [ { "name": "A", "category": "Tools", "group": "First", "wingetId": "x.a", "url": "https://example.invalid/a", "msp": false, "sacRisk": true } ] }
'@ | ConvertFrom-Json
        $app = (@(Get-AppCatalogLayout -Catalog $catalog))[0].Groups[0].Apps[0]
        [object]::ReferenceEquals($app, $catalog.apps[0]) | Should -BeTrue
        $app.wingetId | Should -BeExactly 'x.a'
        $app.url | Should -BeExactly 'https://example.invalid/a'
        $app.msp | Should -BeFalse
        $app.sacRisk | Should -BeTrue
    }

    It 'lists every app exactly once, whatever the grouping' {
        $catalog = @'
{ "categoryGroups": { "Tools": ["First", "Second", "Unused"] },
  "apps": [
    { "name": "T1", "category": "Tools", "group": "First", "wingetId": "x.t1" },
    { "name": "T2", "category": "Tools", "group": "Second", "wingetId": "x.t2" },
    { "name": "T3", "category": "Tools", "group": "Nope", "wingetId": "x.t3" },
    { "name": "T4", "category": "Tools", "wingetId": "x.t4" },
    { "name": "P1", "category": "Plain", "group": "Ignored", "wingetId": "x.p1" },
    { "name": "P2", "category": "Plain", "wingetId": "x.p2" },
    { "name": "Q1", "category": "Quiet", "wingetId": "x.q1" }
  ] }
'@ | ConvertFrom-Json
        $names = @(Get-AppCatalogLayout -Catalog $catalog | ForEach-Object { $_.Groups } | ForEach-Object { $_.Apps } | ForEach-Object { $_.name })
        ($names | Sort-Object) -join ',' | Should -BeExactly 'P1,P2,Q1,T1,T2,T3,T4'
    }
}

Describe 'the real apps-catalog.json, laid out' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
        $repo = Split-Path -Parent $PSScriptRoot
        . ([scriptblock]::Create((Get-FunctionSource -ScriptPath (Join-Path $repo 'debloat/Gr3ysUtilities.ps1') -FunctionName 'Get-AppCatalogLayout')))
        $realCatalog = Get-Content -LiteralPath (Join-Path $repo 'debloat/apps-catalog.json') -Raw | ConvertFrom-Json
        $realBlocks = @(Get-AppCatalogLayout -Catalog $realCatalog)
        $utilities = @($realBlocks | Where-Object { $_.Category -eq 'Utilities' })
    }

    It 'splits Utilities into the groups the owner asked for, in the owner order, with nothing left over under Other' {
        $utilities.Count | Should -Be 1
        @($utilities[0].Groups | ForEach-Object { $_.Name }) | Should -BeExactly @(
            'Security & Privacy'
            'File Management & Archiving'
            'System Info, Diagnostics & Benchmarking'
            'System Optimization, Maintenance & Tweaks'
            'Networking, Remote Access & IT Tools'
            'Cloud Storage & Sync'
            'Disk Partitioning, Imaging & Virtualization'
            'Automation & Productivity'
            'Media & Entertainment')
    }

    It 'puts the apps the owner listed under <Group> in that group, and keeps them in Business Baseline' -ForEach $script:ownerGroups {
        $found = @($utilities[0].Groups | Where-Object { $_.Name -ceq $Group })
        $found.Count | Should -Be 1
        $inGroup = @($found[0].Apps | ForEach-Object { $_.name })
        foreach ($app in $Apps) {
            $inGroup | Should -Contain $app -Because "$app belongs under $Group"
            $entry = @($realCatalog.apps | Where-Object { $_.name -ceq $app })
            $entry.Count | Should -Be 1 -Because $app
            ($entry[0].msp -ne $false) | Should -BeTrue -Because "$app is in the owner's Business Baseline list"
        }
    }

    It 'puts <App> (not in the owner list) under <Group> and keeps it out of Business Baseline' -ForEach $script:unlistedApps {
        $found = @($utilities[0].Groups | Where-Object { $_.Name -ceq $Group })
        $found.Count | Should -Be 1
        @($found[0].Apps | ForEach-Object { $_.name }) | Should -Contain $App
        $entry = @($realCatalog.apps | Where-Object { $_.name -ceq $App })
        $entry.Count | Should -Be 1
        # an explicit "msp": false (a missing msp reads as true, and Should -BeFalse would also accept $null)
        ($entry[0].msp -eq $false) | Should -BeTrue -Because "$App is not in the owner's Business Baseline list"
    }

    It 'leaves every other category as one list with no group name' {
        $others = @($realBlocks | Where-Object { $_.Category -ne 'Utilities' })
        $others.Count | Should -BeGreaterThan 0
        foreach ($b in $others) {
            $b.Groups.Count | Should -Be 1 -Because $b.Category
            $b.Groups[0].Name | Should -Be '' -Because $b.Category
        }
    }

    It 'shows every app of the catalog exactly once' {
        $laidOut = @($realBlocks | ForEach-Object { $_.Groups } | ForEach-Object { $_.Apps } | ForEach-Object { $_.wingetId + '|' + $_.name })
        $inCatalog = @($realCatalog.apps | ForEach-Object { $_.wingetId + '|' + $_.name })
        $laidOut.Count | Should -Be $inCatalog.Count
        (($laidOut | Sort-Object) -join "`n") | Should -BeExactly (($inCatalog | Sort-Object) -join "`n")
    }
}

Describe 'Install Apps list (real population code and filter, real WPF controls)' -Skip:(-not $script:canRunWindow) {
    BeforeAll {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
        $repo = Split-Path -Parent $PSScriptRoot
        $gui = Join-Path $repo 'debloat/Gr3ysUtilities.ps1'

        # The script keeps the list state in $script: variables; the copy of the code under test uses $global: ones instead, which
        # are removed again in AfterAll. Nothing else of the script is run.
        . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $gui -FunctionName 'Get-AppCatalogLayout')))
        . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $gui -FunctionName 'Update-AppVisibility').Replace('$script:', '$global:')))
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($gui, [ref]$null, [ref]$parseErrors)
        $loops = @($ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.ForEachStatementAst] -and $n.Condition.Extent.Text -like '*Get-AppCatalogLayout*'
        }, $true))
        if ($loops.Count -ne 1) { throw "expected exactly one Install Apps population loop in Gr3ysUtilities.ps1, found $($loops.Count)" }
        $populateSource = $loops[0].Extent.Text.Replace('$script:', '$global:')

        # runs the real population loop for a catalog and returns the StackPanel it filled (what the Install Apps tab shows)
        function New-InstallAppsList {
            param($Catalog)
            $global:appEntries = New-Object System.Collections.Generic.List[object]
            $global:categoryBlocks = New-Object System.Collections.Generic.List[object]
            $global:activeCategory = 'Business Baseline'
            $installAppsPanel = New-Object System.Windows.Controls.StackPanel
            $headerBrush = [System.Windows.Media.Brushes]::SteelBlue
            $window = [PSCustomObject]@{ Resources = @{ HintBrush = [System.Windows.Media.Brushes]::Gray } }
            $catalog = $Catalog
            . ([scriptblock]::Create($populateSource))
            return $installAppsPanel
        }

        function Set-AppFilter {
            param([string]$Name)
            $global:activeCategory = $Name
            Update-AppVisibility
        }

        # What is on screen, top to bottom: "H:<text>" for a category heading, "G:<text>" for a group heading and "A:<apps>" for a list
        # of apps (visible ones only); the text is what the control shows. A control the loop does not record as a heading or a list
        # shows as "?".
        function Get-VisibleOutline {
            param($Panel)
            $out = New-Object System.Collections.Generic.List[string]
            foreach ($child in $Panel.Children) {
                if ($child.Visibility -ne 'Visible') { continue }
                $text = '?'
                foreach ($b in $global:categoryBlocks) {
                    if ($b.Header -and [object]::ReferenceEquals($b.Header, $child)) { $text = 'H:' + $child.Text }
                    elseif ($b.SubHeader -and [object]::ReferenceEquals($b.SubHeader, $child)) { $text = 'G:' + $child.Text }
                    elseif ($b.Wrap -and [object]::ReferenceEquals($b.Wrap, $child)) {
                        $names = @($child.Children | Where-Object { $_.Visibility -eq 'Visible' } | ForEach-Object { $_.Children[0].Content })
                        $text = 'A:' + ($names -join ', ')
                    }
                }
                $out.Add($text)
            }
            return $out.ToArray()
        }

        $toolsCatalog = @'
{ "categoryGroups": { "Tools": ["Alpha", "Beta", "Gamma"] },
  "apps": [
    { "name": "A1", "category": "Tools", "group": "Alpha", "wingetId": "x.a1" },
    { "name": "B1", "category": "Tools", "group": "Beta", "wingetId": "x.b1", "msp": false },
    { "name": "G2", "category": "Tools", "group": "Gamma", "wingetId": "x.g2", "msp": false },
    { "name": "G1", "category": "Tools", "group": "Gamma", "wingetId": "x.g1" },
    { "name": "Z1", "category": "Tools", "wingetId": "x.z1", "msp": false },
    { "name": "P1", "category": "Plain", "wingetId": "x.p1", "url": "https://example.invalid/p1", "sacRisk": true, "downloadUrl": "https://example.invalid/p1.exe", "dynamicDownloadPage": "https://example.invalid/p1-page" },
    { "name": "P2", "category": "Plain", "wingetId": "x.p2", "msp": false },
    { "name": "Q1", "category": "Quiet", "wingetId": "x.q1", "msp": false }
  ] }
'@ | ConvertFrom-Json
    }

    AfterAll {
        Remove-Variable -Name appEntries, categoryBlocks, activeCategory -Scope Global -ErrorAction SilentlyContinue
    }

    Context 'a catalog with a grouped category, an ungrouped one and a category Business Baseline hides' {
        BeforeEach { $panel = New-InstallAppsList -Catalog $toolsCatalog }

        It 'builds one heading per category, one heading per group and one list per group, in catalog order' {
            Set-AppFilter 'All'
            @(Get-VisibleOutline $panel) | Should -BeExactly @(
                'H:Plain', 'A:P1, P2'
                'H:Quiet', 'A:Q1'
                'H:Tools', 'G:Alpha', 'A:A1', 'G:Beta', 'A:B1', 'G:Gamma', 'A:G1, G2', 'G:Other', 'A:Z1')
            $panel.Children.Count | Should -Be 13
        }

        It 'puts every app in the list of its own group and records that group on the app' {
            ($global:appEntries | Sort-Object Name | ForEach-Object { $_.Name + '=' + $_.Group }) -join ', ' |
                Should -BeExactly 'A1=Alpha, B1=Beta, G1=Gamma, G2=Gamma, P1=, P2=, Q1=, Z1=Other'
            foreach ($e in $global:appEntries) {
                $lists = @($global:categoryBlocks | Where-Object { $_.Wrap -and $_.Category -eq $e.Category -and ($null -eq $_.Group -or $_.Group -ceq $e.Group) })
                $lists.Count | Should -Be 1 -Because $e.Name
                [object]::ReferenceEquals($e.Row.Parent, $lists[0].Wrap) | Should -BeTrue -Because "$($e.Name) must sit in the list of its own group"
            }
        }

        It 'keeps the fields of an app the installer and the Compare feature use' {
            $p1 = @($global:appEntries | Where-Object { $_.Name -eq 'P1' })[0]
            $p1.WingetId | Should -BeExactly 'x.p1'
            $p1.Url | Should -BeExactly 'https://example.invalid/p1'
            $p1.Msp | Should -BeTrue
            $p1.CompareMatch | Should -BeFalse
            @($global:appEntries | Where-Object { $_.Name -eq 'B1' })[0].Msp | Should -BeFalse
            $p1.CheckBox.Tag | Should -BeExactly 'x.p1'
            $p1.SacRisk | Should -BeTrue
            $p1.DownloadUrl | Should -BeExactly 'https://example.invalid/p1.exe'
            $p1.DynamicDownloadPage | Should -BeExactly 'https://example.invalid/p1-page'
            @($global:appEntries | Where-Object { $_.Name -eq 'P2' })[0].SacRisk | Should -BeFalse
            # the "(?)" link to the app's page: one after the check box for an app with a url, none for an app without
            $p1.Row.Children.Count | Should -Be 2
            $p1.Row.Children[1].Text | Should -BeExactly '(?)'
            $p1.Row.Children[1].ToolTip | Should -BeExactly 'Open https://example.invalid/p1'
            @($global:appEntries | Where-Object { $_.Name -eq 'P2' })[0].Row.Children.Count | Should -Be 1
        }

        It 'Business Baseline shows the apps that are business appropriate, and no heading for a group or category with nothing to show' {
            Set-AppFilter 'Business Baseline'
            @(Get-VisibleOutline $panel) | Should -BeExactly @(
                'H:Plain', 'A:P1'
                'H:Tools', 'G:Alpha', 'A:A1', 'G:Gamma', 'A:G1')
        }

        It 'a category filter shows every app of that category in its groups, Other last, and nothing of the other categories' {
            Set-AppFilter 'Tools'
            @(Get-VisibleOutline $panel) | Should -BeExactly @(
                'H:Tools', 'G:Alpha', 'A:A1', 'G:Beta', 'A:B1', 'G:Gamma', 'A:G1, G2', 'G:Other', 'A:Z1')
        }

        It 'a category filter works for a category without groups too' {
            Set-AppFilter 'Plain'
            @(Get-VisibleOutline $panel) | Should -BeExactly @('H:Plain', 'A:P1, P2')
        }

        It 'Compare Results shows only the matched apps, with the heading of each group and category that holds one' {
            @($global:appEntries | Where-Object { $_.Name -in 'B1', 'Q1' }) | ForEach-Object { $_.CompareMatch = $true }
            Set-AppFilter 'Compare Results'
            @(Get-VisibleOutline $panel) | Should -BeExactly @('H:Quiet', 'A:Q1', 'H:Tools', 'G:Beta', 'A:B1')
        }

        It 'Compare Results with nothing matched shows nothing at all' {
            Set-AppFilter 'Compare Results'
            @(Get-VisibleOutline $panel).Count | Should -Be 0
        }

        It 'a filter that names a category nobody has shows nothing at all' {
            Set-AppFilter 'No Such Category'
            @(Get-VisibleOutline $panel).Count | Should -Be 0
        }

        It 'switching filters back and forth leaves nothing stale behind' {
            Set-AppFilter 'All'
            Set-AppFilter 'Tools'
            Set-AppFilter 'Plain'
            Set-AppFilter 'Business Baseline'
            $first = (@(Get-VisibleOutline $panel)) -join ' / '
            Set-AppFilter 'All'
            Set-AppFilter 'Business Baseline'
            (@(Get-VisibleOutline $panel)) -join ' / ' | Should -BeExactly $first
            $first | Should -BeExactly 'H:Plain / A:P1 / H:Tools / G:Alpha / A:A1 / G:Gamma / A:G1'
        }

        It 'every app row follows its list: a row is visible exactly when its app is in the filter' {
            Set-AppFilter 'Business Baseline'
            ($global:appEntries | Where-Object { $_.Row.Visibility -eq 'Visible' } | Sort-Object Name | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly 'A1,G1,P1'
            Set-AppFilter 'Tools'
            ($global:appEntries | Where-Object { $_.Row.Visibility -eq 'Visible' } | Sort-Object Name | ForEach-Object { $_.Name }) -join ',' | Should -BeExactly 'A1,B1,G1,G2,Z1'
        }
    }

    Context 'a category with exactly one named group' {
        It 'still gets its group heading, and hides it together with its list' {
            $solo = @'
{ "categoryGroups": { "Solo": ["Only"] },
  "apps": [
    { "name": "S1", "category": "Solo", "group": "Only", "wingetId": "x.s1", "msp": false },
    { "name": "T1", "category": "Tools", "wingetId": "x.t1" }
  ] }
'@ | ConvertFrom-Json
            $panel = New-InstallAppsList -Catalog $solo
            Set-AppFilter 'Business Baseline'
            @(Get-VisibleOutline $panel) | Should -BeExactly @('H:Tools', 'A:T1')
            Set-AppFilter 'Solo'
            @(Get-VisibleOutline $panel) | Should -BeExactly @('H:Solo', 'G:Only', 'A:S1')
        }
    }

    Context 'a group listed twice in categoryGroups' {
        It 'builds one list and one check box per app' {
            $twice = @'
{ "categoryGroups": { "Tools": ["First", "First"] },
  "apps": [ { "name": "A", "category": "Tools", "group": "First", "wingetId": "x.a" } ] }
'@ | ConvertFrom-Json
            $panel = New-InstallAppsList -Catalog $twice
            $global:appEntries.Count | Should -Be 1
            Set-AppFilter 'All'
            @(Get-VisibleOutline $panel) | Should -BeExactly @('H:Tools', 'G:First', 'A:A')
        }
    }

    Context 'ticking a box' {
        It 'tells the selection counter, ticked or unticked' {
            # the real Update-SelectedCount reads the script state; a counting stand-in is enough to see that the box calls it
            function global:Update-SelectedCount { $global:selectedCountCalls++ }
            try {
                $global:selectedCountCalls = 0
                $panel = New-InstallAppsList -Catalog $toolsCatalog
                $box = @($global:appEntries | Where-Object { $_.Name -eq 'A1' })[0].CheckBox
                $box.IsChecked = $true
                $box.IsChecked = $false
                $global:selectedCountCalls | Should -Be 2
            } finally {
                Remove-Item -Path Function:\Update-SelectedCount -ErrorAction SilentlyContinue
                Remove-Variable -Name selectedCountCalls -Scope Global -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'two groups whose names differ only in case' {
        It 'are hidden and shown independently of each other' {
            $cased = @'
{ "categoryGroups": { "Tools": ["Alpha", "alpha"] },
  "apps": [
    { "name": "Upper", "category": "Tools", "group": "Alpha", "wingetId": "x.upper" },
    { "name": "Lower", "category": "Tools", "group": "alpha", "wingetId": "x.lower", "msp": false }
  ] }
'@ | ConvertFrom-Json
            $panel = New-InstallAppsList -Catalog $cased
            Set-AppFilter 'Business Baseline'
            @(Get-VisibleOutline $panel) | Should -BeExactly @('H:Tools', 'G:Alpha', 'A:Upper')
            Set-AppFilter 'Tools'
            @(Get-VisibleOutline $panel) | Should -BeExactly @('H:Tools', 'G:Alpha', 'A:Upper', 'G:alpha', 'A:Lower')
        }
    }

    Context 'a catalog without any categoryGroups' {
        It 'lays out and filters exactly like a plain list: one heading and one list per category' {
            $plain = @'
{ "apps": [
    { "name": "B", "category": "Two", "wingetId": "x.b", "msp": false },
    { "name": "A", "category": "One", "wingetId": "x.a" },
    { "name": "C", "category": "Two", "wingetId": "x.c" }
  ] }
'@ | ConvertFrom-Json
            $panel = New-InstallAppsList -Catalog $plain
            $panel.Children.Count | Should -Be 4
            Set-AppFilter 'All'
            @(Get-VisibleOutline $panel) | Should -BeExactly @('H:One', 'A:A', 'H:Two', 'A:B, C')
            Set-AppFilter 'Business Baseline'
            @(Get-VisibleOutline $panel) | Should -BeExactly @('H:One', 'A:A', 'H:Two', 'A:C')
            Set-AppFilter 'Two'
            @(Get-VisibleOutline $panel) | Should -BeExactly @('H:Two', 'A:B, C')
        }
    }

    Context 'the real apps-catalog.json' {
        BeforeAll {
            $realCatalog = Get-Content -LiteralPath (Join-Path $repo 'debloat/apps-catalog.json') -Raw | ConvertFrom-Json
            $realPanel = New-InstallAppsList -Catalog $realCatalog
            # the part of an outline that belongs to one category: from its heading to the next category heading
            function Get-OutlineSection {
                param([string[]]$Outline, [string]$Category)
                $start = [array]::IndexOf($Outline, 'H:' + $Category)
                if ($start -lt 0) { return @() }
                $section = New-Object System.Collections.Generic.List[string]
                for ($i = $start + 1; $i -lt $Outline.Count -and -not $Outline[$i].StartsWith('H:'); $i++) { $section.Add($Outline[$i]) }
                return $section.ToArray()
            }
        }

        # the owner list and the ten other apps come in as data (what is set up in BeforeDiscovery is not there while the tests run)
        It 'Business Baseline shows Utilities as the nine groups of the owner list, in order, with all of their apps and none of the ten others' -ForEach @(, @{ Owner = $script:ownerGroups; Unlisted = $script:unlistedApps }) {
            Set-AppFilter 'Business Baseline'
            $section = @(Get-OutlineSection -Outline @(Get-VisibleOutline $realPanel) -Category 'Utilities')
            @($section | Where-Object { $_.StartsWith('G:') } | ForEach-Object { $_.Substring(2) }) | Should -BeExactly @($Owner | ForEach-Object { $_.Group })
            $section.Count | Should -Be 18 -Because 'nine group headings, each followed by one list of apps'
            $shown = @($section | Where-Object { $_.StartsWith('A:') } | ForEach-Object { $_.Substring(2) -split ', ' })
            foreach ($row in $Owner) {
                foreach ($app in $row.Apps) { $shown | Should -Contain $app -Because "$app is in the owner's Business Baseline list" }
            }
            foreach ($u in $Unlisted) { $shown | Should -Not -Contain $u.App -Because "$($u.App) is hidden from Business Baseline" }
        }

        It 'the Utilities filter shows all of the Utilities apps in the nine groups and no other category' -ForEach @(, @{ Owner = $script:ownerGroups }) {
            Set-AppFilter 'Utilities'
            $outline = @(Get-VisibleOutline $realPanel)
            @($outline | Where-Object { $_.StartsWith('H:') }) | Should -BeExactly @('H:Utilities')
            $section = @(Get-OutlineSection -Outline $outline -Category 'Utilities')
            @($section | Where-Object { $_.StartsWith('G:') } | ForEach-Object { $_.Substring(2) }) | Should -BeExactly @($Owner | ForEach-Object { $_.Group })
            $shown = @($section | Where-Object { $_.StartsWith('A:') } | ForEach-Object { $_.Substring(2) -split ', ' })
            $shown.Count | Should -Be @($realCatalog.apps | Where-Object { $_.category -eq 'Utilities' }).Count
        }

        It 'the All filter shows every app of the catalog' {
            Set-AppFilter 'All'
            @($global:appEntries | Where-Object { $_.Row.Visibility -eq 'Visible' }).Count | Should -Be $realCatalog.apps.Count
            @(Get-VisibleOutline $realPanel | Where-Object { $_.StartsWith('?') }).Count | Should -Be 0
        }

        It 'a category that has no groups still shows as one heading and one list' {
            Set-AppFilter 'Browsers'
            $outline = @(Get-VisibleOutline $realPanel)
            $outline.Count | Should -Be 2
            $outline[0] | Should -BeExactly 'H:Browsers'
            $outline[1] | Should -BeLike 'A:*'
        }
    }
}
