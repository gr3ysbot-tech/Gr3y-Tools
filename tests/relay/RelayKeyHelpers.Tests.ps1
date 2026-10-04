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
        foreach ($fn in 'ConvertTo-RelayKey', 'ConvertFrom-RelayKeyList', 'Get-GuestRowInfo', 'ConvertTo-HoursQuery', 'ConvertTo-GuestCodeText', 'Get-WingetListedIds', 'New-PairingCode', 'Invoke-RelayRequest', 'Start-RelayPairing') {
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

    Context 'Get-GuestRowInfo' {
        BeforeAll {
            $script:nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        }

        It 'treats a record from a relay without the expiry feature as never expiring' {
            $info = Get-GuestRowInfo -Rec ([pscustomobject]@{ key = 'ABCD-EFGH-JKMN'; label = 'old'; enabled = $true; created = '2026-10-04' })
            $info.State | Should -Be 'On'
            $info.Expires | Should -Be 'Never'
            $info.Expired | Should -BeFalse
            $info.ExpiresMs | Should -BeNullOrEmpty
        }

        It 'shows an explicit null expiry as Never' {
            $info = Get-GuestRowInfo -Rec ([pscustomobject]@{ enabled = $true; expires = $null; expired = $false })
            $info.Expires | Should -Be 'Never'
            $info.State | Should -Be 'On'
        }

        It 'shows a future expiry as local time and keeps the milliseconds' {
            $ms = $script:nowMs + 3 * 3600 * 1000
            $info = Get-GuestRowInfo -Rec ([pscustomobject]@{ enabled = $true; expires = $ms; expired = $false })
            $info.State | Should -Be 'On'
            $info.ExpiresMs | Should -Be $ms
            # The exact text, built another way: the instant moved to this machine's time zone by
            # TimeZoneInfo. (On a runner whose zone is UTC, UTC and local look the same.)
            $utc = [DateTime]::SpecifyKind([DateTimeOffset]::FromUnixTimeMilliseconds($ms).UtcDateTime, [DateTimeKind]::Utc)
            $local = [TimeZoneInfo]::ConvertTimeFromUtc($utc, [TimeZoneInfo]::Local)
            $info.Expires | Should -BeExactly $local.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
        }

        It 'always writes ASCII digits, whatever the machine culture is' {
            $rec = [pscustomobject]@{ enabled = $true; expires = $script:nowMs + 86400000; expired = $false }
            $expected = (Get-GuestRowInfo -Rec $rec).Expires
            $saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                # ar-SA writes the Hijri calendar and Arabic digits unless told otherwise.
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('ar-SA')
                $info = Get-GuestRowInfo -Rec $rec
                $info.Expires | Should -BeExactly $expected
                $info.Expires | Should -Match '^[0-9 :-]+$'
            } finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $saved
            }
        }

        It 'says Expired when the relay says so, even if the code is also switched off' {
            $past = $script:nowMs - 2 * 86400000
            (Get-GuestRowInfo -Rec ([pscustomobject]@{ enabled = $true; expires = $past; expired = $true })).State | Should -Be 'Expired'
            (Get-GuestRowInfo -Rec ([pscustomobject]@{ enabled = $false; expires = $past; expired = $true })).State | Should -Be 'Expired'
            (Get-GuestRowInfo -Rec ([pscustomobject]@{ enabled = $true; expires = $past; expired = $true })).Expired | Should -BeTrue
        }

        It 'says Off for a switched-off code that has not expired' {
            $info = Get-GuestRowInfo -Rec ([pscustomobject]@{ enabled = $false; expires = $null; expired = $false })
            $info.State | Should -Be 'Off'
            $info.Enabled | Should -BeFalse
        }

        It 'copes with an expired record that has no usable time (a hand edit) - it needs an expiry' {
            $info = Get-GuestRowInfo -Rec ([pscustomobject]@{ enabled = $true; expires = $null; expired = $true })
            $info.State | Should -Be 'Expired'
            $info.Expires | Should -Be 'Needs expiry'
            $info.NeedsExpiry | Should -BeTrue
        }

        It 'tells a code that has lapsed from one the relay refuses for want of a usable expiry' {
            # Lapsed in the past, or only just (a clock difference): plainly expired.
            (Get-GuestRowInfo -Rec ([pscustomobject]@{ enabled = $true; expires = $script:nowMs - 2 * 86400000; expired = $true })).NeedsExpiry | Should -BeFalse
            (Get-GuestRowInfo -Rec ([pscustomobject]@{ enabled = $true; expires = $script:nowMs + 120000; expired = $true })).NeedsExpiry | Should -BeFalse
            # Refused although its expiry is well ahead (a short code with a month on it): it needs a nearer expiry.
            $far = Get-GuestRowInfo -Rec ([pscustomobject]@{ enabled = $true; expires = $script:nowMs + 30 * 86400000; expired = $true })
            $far.NeedsExpiry | Should -BeTrue
            $far.Expires | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$'
            # A code that is simply in order.
            (Get-GuestRowInfo -Rec ([pscustomobject]@{ enabled = $true; expires = $script:nowMs + 3600000; expired = $false })).NeedsExpiry | Should -BeFalse
            (Get-GuestRowInfo -Rec ([pscustomobject]@{ enabled = $true; expires = $null; expired = $false })).NeedsExpiry | Should -BeFalse
        }

        It 'copes with an absurd expiry value' {
            $info = Get-GuestRowInfo -Rec ([pscustomobject]@{ enabled = $true; expires = 99999999999999999; expired = $false })
            $info.Expires | Should -Be 'Invalid'
        }

        It 'survives the real guest-code list parse (5.1 array handling) with the new fields' {
            $json = '[{"key":"AAAA-BBBB-CCCC","label":"a","enabled":true,"created":"2026-10-04","expires":1790000000000,"expired":false},{"key":"DDDD-EEEE-FFFF","label":"b","enabled":true,"created":"2026-10-04","expires":null,"expired":false}]'
            $rows = ConvertFrom-RelayKeyList -Json $json
            $rows.Count | Should -Be 2
            (Get-GuestRowInfo -Rec $rows[0]).ExpiresMs | Should -Be 1790000000000
            (Get-GuestRowInfo -Rec $rows[1]).Expires | Should -Be 'Never'
        }
    }

    Context 'ConvertTo-GuestCodeText' {
        It 'treats blank as "no code typed" (a random one will be made)' {
            foreach ($blank in @('', '   ', $null)) {
                $r = ConvertTo-GuestCodeText -Text $blank
                $r.Ok | Should -BeTrue
                $r.Code | Should -Be ''
            }
        }

        It 'upper-cases the code and ignores spaces and dashes' {
            (ConvertTo-GuestCodeText -Text '9989').Code | Should -BeExactly '9989'
            (ConvertTo-GuestCodeText -Text 'ab12cd').Code | Should -BeExactly 'AB12CD'
            (ConvertTo-GuestCodeText -Text ' 99-89 ').Code | Should -BeExactly '9989'
            (ConvertTo-GuestCodeText -Text 'abcd efgh-jkmn').Code | Should -BeExactly 'ABCDEFGHJKMN'
        }

        It 'accepts 4 to 32 characters' {
            (ConvertTo-GuestCodeText -Text 'ABCD').Ok | Should -BeTrue
            (ConvertTo-GuestCodeText -Text ('Z' * 32)).Ok | Should -BeTrue
        }

        It 'refuses codes that are too short or too long' {
            $short = ConvertTo-GuestCodeText -Text 'abc'
            $short.Ok | Should -BeFalse
            $short.Error | Should -Match 'at least 4'
            (ConvertTo-GuestCodeText -Text '9-9-8').Ok | Should -BeFalse
            $long = ConvertTo-GuestCodeText -Text ('Z' * 33)
            $long.Ok | Should -BeFalse
            $long.Error | Should -Match 'at most 32'
        }

        It 'refuses anything but letters, digits, spaces and dashes' {
            foreach ($bad in @('ab_cd', 'ab.cd', 'ab!cd', ('caf' + [char]0xE9 + '99'), ('ab' + [char]0x65E5 + 'cd'), ('ab' + [char]0x2011 + 'cd1'))) {
                $r = ConvertTo-GuestCodeText -Text $bad
                $r.Ok | Should -BeFalse
                $r.Error | Should -Match 'letters and digits'
            }
        }

        It 'refuses look-alike letters that a case-insensitive match would let through' {
            # U+212A KELVIN SIGN and U+0130 (dotted capital I) match [A-Za-z] when case is ignored;
            # the relay refuses them, so the dialog must too (the owner should not lose the entries).
            foreach ($bad in @(('abc' + [char]0x212A + '1'), ('abc' + [char]0x0130 + '1'), ('ab' + [char]0x0131 + 'c1'), ('ab' + [char]0x017F + 'c1'))) {
                $r = ConvertTo-GuestCodeText -Text $bad
                $r.Ok | Should -BeFalse
                $r.Error | Should -Match 'letters and digits'
            }
        }
    }

    Context 'ConvertTo-HoursQuery' {
        It 'writes plain invariant numbers for the relay' {
            ConvertTo-HoursQuery -Hours 168 | Should -BeExactly '168'
            ConvertTo-HoursQuery -Hours 0.5 | Should -BeExactly '0.5'
            ConvertTo-HoursQuery -Hours 0 | Should -BeExactly '0'
            ConvertTo-HoursQuery -Hours 1.25 | Should -BeExactly '1.25'
            ConvertTo-HoursQuery -Hours (1 / 3) | Should -BeExactly '0.333333'
        }

        It 'never uses a comma decimal separator, whatever the machine culture is' {
            $saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
                ConvertTo-HoursQuery -Hours 1.5 | Should -BeExactly '1.5'
            } finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $saved
            }
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
