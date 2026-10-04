# Pester tests for the small pure helpers behind the access-code GUI: cleaning a typed access
# code, parsing the guest-code list, and the winget-list id set. Extracted from
# Gr3ysUtilities.ps1 with the repo's Get-FunctionSource helper. No relay and no Node needed.
#
# CI runs Pester under Windows PowerShell 5.1, where ConvertFrom-Json emits a JSON array as ONE
# pipeline object and PowerShell unrolls an empty collection on return - the two quirks these
# helpers exist to absorb (both shipped as real bugs, found by driving the GUI). ASCII only.

Describe 'Relay key helpers' {
    BeforeAll {
        $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $gui = Join-Path $repo 'debloat/Gr3ysUtilities.ps1'
        . (Join-Path $repo 'tests/TestHelpers.ps1')
        foreach ($fn in 'ConvertTo-RelayKey', 'ConvertFrom-RelayKeyList', 'Get-WingetListedIds', 'New-PairingCode', 'Invoke-RelayRequest', 'Start-RelayPairing') {
            . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $gui -FunctionName $fn)))
        }
    }

    Context 'ConvertTo-RelayKey' {
        It 'leaves a normal guest code alone' {
            ConvertTo-RelayKey -Text 'ABCD-EFGH-JKMN' | Should -BeExactly 'ABCD-EFGH-JKMN'
        }

        It 'trims spaces and a trailing newline' {
            ConvertTo-RelayKey -Text "  ABCD-EFGH-JKMN`r`n" | Should -BeExactly 'ABCD-EFGH-JKMN'
        }

        It 'turns look-alike dashes (non-breaking hyphen, en-dash, minus sign) back into hyphens' {
            $pasted = 'ABCD' + [char]0x2011 + 'EFGH' + [char]0x2013 + 'JKMN' + [char]0x2212 + 'PQRS'
            ConvertTo-RelayKey -Text $pasted | Should -BeExactly 'ABCD-EFGH-JKMN-PQRS'
        }

        It 'drops zero-width characters and non-breaking spaces at the ends' {
            $pasted = [char]0xA0 + 'AB' + [char]0x200B + 'CD' + [char]0xFEFF + [char]0xA0
            ConvertTo-RelayKey -Text $pasted | Should -BeExactly 'ABCD'
        }

        It 'keeps a space inside a pass-phrase style admin code' {
            ConvertTo-RelayKey -Text 'correct horse battery staple' | Should -BeExactly 'correct horse battery staple'
        }

        It 'returns $null when a character that cannot be sent is left' {
            ConvertTo-RelayKey -Text ('caf' + [char]0xE9 + '-1234') | Should -BeNullOrEmpty
            ConvertTo-RelayKey -Text ('ABCD' + [char]0x65E5 + 'EFGH') | Should -BeNullOrEmpty
            ConvertTo-RelayKey -Text ('AB' + [char]7 + 'CD') | Should -BeNullOrEmpty
        }

        It 'returns $null for nothing, or only whitespace' {
            ConvertTo-RelayKey -Text '' | Should -BeNullOrEmpty
            ConvertTo-RelayKey -Text '   ' | Should -BeNullOrEmpty
            ConvertTo-RelayKey -Text $null | Should -BeNullOrEmpty
        }
    }

    Context 'Start-RelayPairing with an unsendable access code' {
        It 'reports badkey without contacting the relay' {
            # Port 1 is closed: had a request been attempted, Failure would be "network".
            $p = Start-RelayPairing -RelayUrl 'http://127.0.0.1:1' -AccessKey ('ABCD' + [char]0x2011 + 'EFGH')
            $p.Ok | Should -BeFalse
            $p.Failure | Should -Be 'badkey'
        }
    }

    Context 'ConvertFrom-RelayKeyList' {
        BeforeAll {
            $script:two = '[{"key":"AAAA-BBBB-CCCC","label":"alpha","enabled":true,"created":"2026-10-04"},{"key":"DDDD-EEEE-FFFF","label":"bravo","enabled":false,"created":"2026-10-04"}]'
            $script:one = '[{"key":"AAAA-BBBB-CCCC","label":"alpha","enabled":true,"created":"2026-10-04"}]'
        }

        It 'returns an empty array for an empty list (no phantom row)' {
            $r = ConvertFrom-RelayKeyList -Json '[]'
            ($r -is [array]) | Should -BeTrue
            $r.Count | Should -Be 0
        }

        It 'returns one entry for a single code' {
            $r = ConvertFrom-RelayKeyList -Json $script:one
            $r.Count | Should -Be 1
            $r[0].key | Should -Be 'AAAA-BBBB-CCCC'
        }

        It 'returns one entry per code, not one mashed entry (Windows PowerShell 5.1 unrolling)' {
            $r = ConvertFrom-RelayKeyList -Json $script:two
            $r.Count | Should -Be 2
            $r[0].key | Should -BeExactly 'AAAA-BBBB-CCCC'
            $r[0].label | Should -BeExactly 'alpha'
            $r[1].key | Should -BeExactly 'DDDD-EEEE-FFFF'
            $r[1].enabled | Should -BeFalse
        }

        It 'treats junk, a bare object or nothing as no codes' {
            (ConvertFrom-RelayKeyList -Json 'this is not json').Count | Should -Be 0
            (ConvertFrom-RelayKeyList -Json '{"error":"nope"}').Count | Should -Be 0
            (ConvertFrom-RelayKeyList -Json '').Count | Should -Be 0
            (ConvertFrom-RelayKeyList -Json $null).Count | Should -Be 0
        }
    }

    Context 'Get-WingetListedIds' {
        BeforeAll {
            # A `winget list` style table: every column padded to a fixed width, header row,
            # a rule line, then one row per package.
            $script:table = {
                param([string[]]$Rows)
                $lines = @(('Name'.PadRight(16) + 'Id'.PadRight(16) + 'Version'.PadRight(8) + 'Source'), ('-' * 46))
                foreach ($r in $Rows) {
                    $name, $id = $r -split '\|'
                    $lines += ($name.PadRight(16) + $id.PadRight(16) + '1.0'.PadRight(8) + 'winget')
                }
                $lines
            }
        }

        It 'returns an empty set (not $null) when the file does not exist' {
            $ids = Get-WingetListedIds -Path (Join-Path $TestDrive 'missing.txt')
            ($null -eq $ids) | Should -BeFalse
            ($ids -is [System.Collections.Generic.HashSet[string]]) | Should -BeTrue
            $ids.Count | Should -Be 0
        }

        It 'returns an empty set (not $null) when the output has no table' {
            $f = Join-Path $TestDrive 'notable.txt'
            Set-Content -Path $f -Value 'No installed package found matching input criteria.' -Encoding ASCII
            $ids = Get-WingetListedIds -Path $f
            ($null -eq $ids) | Should -BeFalse
            ($ids -is [System.Collections.Generic.HashSet[string]]) | Should -BeTrue
            $ids.Count | Should -Be 0
        }

        It 'returns a set even for a single id (not a bare string, so .Contains is an exact match)' {
            $f = Join-Path $TestDrive 'one.txt'
            Set-Content -Path $f -Value (& $script:table @('7-Zip|7zip.7zip')) -Encoding ASCII
            $ids = Get-WingetListedIds -Path $f
            ($ids -is [System.Collections.Generic.HashSet[string]]) | Should -BeTrue
            $ids.Count | Should -Be 1
            $ids.Contains('7zip.7zip') | Should -BeTrue
            $ids.Contains('7zip') | Should -BeFalse
        }

        It 'returns every id from a table' {
            $f = Join-Path $TestDrive 'many.txt'
            Set-Content -Path $f -Value (& $script:table @('7-Zip|7zip.7zip', 'Nmap|Insecure.Nmap', 'PuTTY|PuTTY.PuTTY')) -Encoding ASCII
            $ids = Get-WingetListedIds -Path $f
            $ids.Count | Should -Be 3
            $ids.Contains('Insecure.Nmap') | Should -BeTrue
        }
    }
}
