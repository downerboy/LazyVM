# SecurityEvent.ps1 - The security scan's review of what happened in the guest since the last scan (#290).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The guest script ($script:GuestSecurityScanWork) only collects the events
# and files; these functions, which only compute, decide what is a finding:
# cleared logs, brute-force and spraying sign-ins, accounts and services
# created, what Sysmon saw, script blocks that look like obfuscation, and new
# crash files. Defender's detections (events 1116 and 1117) are not read here:
# Get-DefenderDetectionFinding already reports every detection Defender lists.
# Nothing secret leaves the guest: not a script block's text, only whether it
# matched, and why.

# How long failed sign-ins may take to count as one burst, and how long after
# the last failure a success still counts as having followed it.
$script:SignInWindow = [timespan]::FromMinutes(5)
$script:BruteForceMinimumFailures = 5
$script:SprayingMinimumAccounts = 3

# The first scan has no earlier scan to count from, so it reads this many hours back.
$script:SecurityEventFirstScanHours = 24

# Script block text (event 4104) that looks like obfuscation. The guest tests
# each script block against these (by position) and reports only which matched;
# the Reason is what the finding says. LazyVM's own guest code matches none
# (SecurityEvent.Tests.ps1 checks).
$script:SuspiciousPowerShell = @(
    @{ Pattern = '(?i)\s-e(nc(odedcommand)?)?\s+[A-Za-z0-9+/=]{40,}'; Reason = 'starts PowerShell with an encoded command' }
    @{ Pattern = '(?is)(?=.*FromBase64String)(?=.*(\biex\b|Invoke-Expression))'; Reason = 'decodes text and runs it' }
    @{ Pattern = '(?is)(DownloadString|DownloadFile|DownloadData|Invoke-WebRequest|\biwr\b|Invoke-RestMethod|\birm\b).{0,300}(\biex\b|Invoke-Expression)|(\biex\b|Invoke-Expression).{0,300}(DownloadString|Invoke-WebRequest|\biwr\b|Invoke-RestMethod|\birm\b)'; Reason = 'downloads text and runs it' }
    @{ Pattern = '(?i)(\[char\]\s*\d+\s*\)?\s*\+\s*){3,}'; Reason = 'builds its text one character at a time' }
)

# What the logs are called in a finding, by the name the guest reports them under.
$script:PowerShellLogName = @{ PowerShell = 'Windows PowerShell'; PowerShellCore = 'PowerShell 7' }
# Where each PowerShell log is in Event Viewer.
$script:PowerShellLogEventViewerPath = @{ PowerShell = 'Microsoft, Windows, PowerShell, Operational'; PowerShellCore = 'PowerShellCore, Operational' }

function ConvertTo-SecurityEventTime {
    <# A time the guest reported (ISO 8601). #>
    [OutputType([datetimeoffset])]
    param([Parameter(Mandatory)][string]$Text)

    return [datetimeoffset]::Parse($Text, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
}

function Format-SecurityEventStamp {
    <# A time in UTC, for a finding's Id, which must not depend on the host's time zone. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][datetimeoffset]$Time)

    return $Time.UtcDateTime.ToString('yyyyMMddHHmmss', [cultureinfo]::InvariantCulture)
}

function Format-SecurityEventTime {
    <# A time as the findings say it: the host's local time. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][datetimeoffset]$Time)

    return $Time.ToLocalTime().ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture)
}

function Get-LogClearedFinding {
    <# Each time the Security or System log was cleared: whoever does it is hiding what they did. #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    foreach ($item in @($Fact.Events)) {
        $time = ConvertTo-SecurityEventTime -Text ([string]$item.Time)
        $by = if ([RecordReader]::Field($item, 'By')) { " by $($item.By)" } else { '' }
        New-SecurityFinding -Id "LogCleared:$($item.Log):$(Format-SecurityEventStamp -Time $time)" -Severity High -Title "The $($item.Log) event log was cleared" `
            -WhatWeFound "The $($item.Log) log was cleared on $(Format-SecurityEventTime -Time $time)$by." `
            -WhyItMatters 'Clearing the logs is how someone who got into the VM hides what they did. Nothing in this log from before that time can be trusted to be complete.' `
            -HowToFix 'If you did not do it, treat the VM as compromised: copy out what you need, then rebuild it with Invoke-LazyVMRebuild. Look at the Sysmon log and the other findings for what happened before.'
    }
}

function Get-SignInFinding {
    <#
      A sign-in that followed failed ones, from the sign-in events ($Fact:
      4625 wrong-password and unknown-user failures, and the 4624 successes
      to interactive, network and remote sign-in; each with Time, Account,
      Source and Type). Brute force, High: at least 5 failures for one
      account from one source within 5 minutes, then a success for that
      account from that source within 5 minutes of the last failure.
      Spraying, Medium: failures for at least 3 accounts from one source
      within 5 minutes, then a success for one of them from that source
      within 5 minutes. Failures that no success follows are not reported.
      One finding for each burst, whatever the sign-ins after it.
    #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    $events = @($Fact.Events | ForEach-Object {
            [pscustomobject]@{ Id = [int]$_.Id; Time = ConvertTo-SecurityEventTime -Text ([string]$_.Time); Account = [string]$_.Account; Source = [string]$_.Source }
        })
    $failures = @($events | Where-Object { $_.Id -eq 4625 })
    $window = $script:SignInWindow
    $reported = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($success in @($events | Where-Object { $_.Id -eq 4624 } | Sort-Object -Property Time)) {
        $fromSource = @($failures | Where-Object { $_.Source -eq $success.Source -and $_.Time -le $success.Time -and ($success.Time - $_.Time) -le $window })
        if ($fromSource.Count -eq 0) { continue }
        $stamp = Format-SecurityEventStamp -Time $success.Time
        $when = Format-SecurityEventTime -Time $success.Time

        $own = @($fromSource | Where-Object { $_.Account -ieq $success.Account })
        if ($own.Count -gt 0) {
            $last = ($own | Sort-Object -Property Time -Descending | Select-Object -First 1).Time
            $burst = @($failures | Where-Object { $_.Source -eq $success.Source -and $_.Account -ieq $success.Account -and $_.Time -le $last -and ($last - $_.Time) -le $window })
            if ($burst.Count -ge $script:BruteForceMinimumFailures) {
                if ($reported.Add("brute|$($success.Account.ToLowerInvariant())|$($success.Source)|$last")) {
                    New-SecurityFinding -Id "SignIn:BruteForce:$($success.Account):$($success.Source):$stamp" -Severity High -Title "Someone guessed the password of $($success.Account)" `
                        -WhatWeFound "$($burst.Count) failed sign-ins for $($success.Account) from $($success.Source) within 5 minutes were followed by a successful one on $when." `
                        -WhyItMatters 'Repeated wrong passwords and then a success is what guessing a password looks like. Whoever signed in may now control the account.' `
                        -HowToFix "Change the password of $($success.Account) in the VM. Check what that account did after $when (the Security and Sysmon logs). If you are not sure, rebuild the VM with Invoke-LazyVMRebuild. Do not leave Remote Desktop or file sharing open to a network you do not trust."
                }
                continue
            }
        }

        $last = ($fromSource | Sort-Object -Property Time -Descending | Select-Object -First 1).Time
        $sprayed = @($failures | Where-Object { $_.Source -eq $success.Source -and $_.Time -le $last -and ($last - $_.Time) -le $window })
        $accounts = @($sprayed | ForEach-Object { $_.Account.ToLowerInvariant() } | Select-Object -Unique)
        if ($accounts.Count -ge $script:SprayingMinimumAccounts -and $success.Account.ToLowerInvariant() -in $accounts) {
            if ($reported.Add("spray|$($success.Account.ToLowerInvariant())|$($success.Source)|$last")) {
                New-SecurityFinding -Id "SignIn:Spraying:$($success.Account):$($success.Source):$stamp" -Severity Medium -Title "Someone tried one password on many accounts, and $($success.Account) signed in" `
                    -WhatWeFound "$($accounts.Count) accounts failed to sign in from $($success.Source) within 5 minutes ($($sprayed.Count) failures), and then $($success.Account) signed in from there on $when." `
                    -WhyItMatters 'Trying a few passwords on many accounts is how people avoid being locked out while they guess. The account that then signed in may be one they guessed.' `
                    -HowToFix "Change the password of $($success.Account) in the VM, and look at what it did after $when (the Security and Sysmon logs). Do not leave Remote Desktop or file sharing open to a network you do not trust."
            }
        }
    }
}

function Get-AccountChangeFinding {
    <# Users created, users added to Administrators and services installed since the last scan (events 4720, 4732, 7045 and 4697). The Sysmon service, which LazyVM installs, is left out. #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    foreach ($item in @($Fact.Events)) {
        $time = ConvertTo-SecurityEventTime -Text ([string]$item.Time)
        $stamp = Format-SecurityEventStamp -Time $time
        $when = Format-SecurityEventTime -Time $time
        $by = if ([RecordReader]::Field($item, 'By')) { " by $($item.By)" } else { '' }
        switch ([int]$item.Id) {
            4720 {
                New-SecurityFinding -Id "AccountChange:UserCreated:$($item.Name):$stamp" -Severity Medium -Title "The user $($item.Name) was created" `
                    -WhatWeFound "The user account $($item.Name) was created on $when$by." `
                    -WhyItMatters 'A new account is a way back into the VM that the password of your own account does not close.' `
                    -HowToFix "If you did not create it, disable it (Computer Management, then Local Users and Groups) and look at what it did. If you did, approve this finding: Approve-LazyVMSecurityFinding."
            }
            4732 {
                New-SecurityFinding -Id "AccountChange:AdminAdded:$($item.Name):$stamp" -Severity High -Title "$($item.Name) was added to Administrators" `
                    -WhatWeFound "$($item.Name) was added to the Administrators group on $when$by." `
                    -WhyItMatters 'An administrator can change anything in the VM, and turn off what protects it.' `
                    -HowToFix "If you did not do it, remove $($item.Name) from Administrators (Computer Management, then Local Users and Groups) and look at what the account did. If you did, approve this finding: Approve-LazyVMSecurityFinding."
            }
            { $_ -in 7045, 4697 } {
                if ($item.Name -like $script:SysmonServicePattern) { continue }
                $path = @(if ([RecordReader]::Field($item, 'Path')) { [string]$item.Path })
                New-SecurityFinding -Id "AccountChange:ServiceInstalled:$($item.Name):$stamp" -Severity Medium -Title "The service $($item.Name) was installed" `
                    -WhatWeFound "The service $($item.Name) was installed on $when$by." `
                    -WhyItMatters 'A service starts with Windows and runs with high rights, which is what malware wants. Installers add services too.' `
                    -HowToFix 'If you installed a program that does this, approve this finding: Approve-LazyVMSecurityFinding. If you do not know the program, look up the file it runs, and remove the service with: sc.exe delete <name>.' -Where $path
            }
        }
    }
}

function Get-SysmonFinding {
    <#
      What Sysmon saw: a program reading the memory of LSASS (event 10,
      High), a thread started in another process (event 8, Medium), and
      programs started from a Temp or Downloads folder (event 1, Low; one
      finding for each program, whatever the number of times it ran).
    #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    $started = [ordered]@{}
    foreach ($item in @($Fact.Events)) {
        $time = ConvertTo-SecurityEventTime -Text ([string]$item.Time)
        $stamp = Format-SecurityEventStamp -Time $time
        $when = Format-SecurityEventTime -Time $time
        $image = [string]$item.Image
        $leaf = $image.Substring($image.LastIndexOf('\') + 1)
        switch ([int]$item.Id) {
            10 {
                New-SecurityFinding -Id "Sysmon:LsassAccess:${leaf}:$stamp" -Severity High -Title "$leaf read the memory of LSASS" `
                    -WhatWeFound "$leaf opened the Local Security Authority process (lsass.exe) with the access $($item.Access) on $when." `
                    -WhyItMatters 'LSASS holds the passwords and tickets of everyone signed in. Reading its memory is how they are stolen.' `
                    -HowToFix "Find out what $leaf is. If you did not run it, treat the VM as compromised: change the passwords you used in it and rebuild it with Invoke-LazyVMRebuild." -Where @($image)
            }
            8 {
                $target = [string]$item.Target
                $targetLeaf = $target.Substring($target.LastIndexOf('\') + 1)
                New-SecurityFinding -Id "Sysmon:RemoteThread:${leaf}:${targetLeaf}:$stamp" -Severity Medium -Title "$leaf started a thread in $targetLeaf" `
                    -WhatWeFound "$leaf started a thread inside $targetLeaf on $when." `
                    -WhyItMatters 'Starting a thread in another program is how malware runs its code under the name of a program you trust. Some security and accessibility programs do it too.' `
                    -HowToFix "Find out what $leaf is. If you do not know it, run a full Defender scan and look at the other findings. If you do, approve this finding: Approve-LazyVMSecurityFinding." -Where @($image, $target)
            }
            1 {
                if (-not $started.Contains($image)) { $started[$image] = [System.Collections.Generic.List[datetimeoffset]]::new() }
                $started[$image].Add($time)
            }
        }
    }
    foreach ($image in $started.Keys) {
        $times = @($started[$image] | Sort-Object)
        $count = if ($times.Count -eq 1) { 'once' } else { "$($times.Count) times" }
        New-SecurityFinding -Id "Sysmon:StartedFromTemp:$image" -Severity Low -Title "A program ran from a Temp or Downloads folder" `
            -WhatWeFound "$image ran $count, first on $(Format-SecurityEventTime -Time $times[0])." `
            -WhyItMatters 'Installers and downloads run from there, and so does malware that was just downloaded.' `
            -HowToFix 'If you ran it, nothing needs doing; approve this finding with Approve-LazyVMSecurityFinding if it keeps coming back. If you do not know it, run a full Defender scan.' -Where @($image)
    }
}

function Get-PowerShellScriptFinding {
    <# Each script block that matched $script:SuspiciousPowerShell (event 4104; the guest reports its log, time, id and which patterns matched, never its text). #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    foreach ($item in @($Fact.Events)) {
        $time = ConvertTo-SecurityEventTime -Text ([string]$item.Time)
        $reasons = @(@($item.Matched) | ForEach-Object { $script:SuspiciousPowerShell[[int]$_].Reason })
        $log = $script:PowerShellLogName["$($item.Log)"]
        New-SecurityFinding -Id "PowerShellScript:$($item.Log):$($item.BlockId)" -Severity Medium -Title "A $log script looks obfuscated" `
            -WhatWeFound "A script that $($reasons -join ' and ') ran in $log on $(Format-SecurityEventTime -Time $time) (script block $($item.BlockId))." `
            -WhyItMatters 'Hiding what a script does is how malware avoids being read. Some installers and administration tools do it too.' `
            -HowToFix "Read the script block in Event Viewer: Applications and Services Logs, then $($script:PowerShellLogEventViewerPath[$item.Log]), event 4104, script block $($item.BlockId). If you do not know what ran it, run a full Defender scan and look at the other findings."
    }
}

function Get-CrashDumpFinding {
    <# The crash dumps and error reports (Minidump, LiveKernelReports and WER) written since the last scan: one finding for each folder. #>
    [OutputType([SecurityFinding])]
    param([Parameter(Mandatory)][object]$Fact)

    $items = @($Fact.Items | ForEach-Object {
            [pscustomobject]@{ Folder = [string]$_.Folder; Time = ConvertTo-SecurityEventTime -Text ([string]$_.Time) }
        })
    foreach ($group in @($items | Group-Object -Property Folder)) {
        $newest = ($group.Group | Sort-Object -Property Time -Descending | Select-Object -First 1).Time
        $count = if ($group.Count -eq 1) { '1 file' } else { "$($group.Count) files" }
        New-SecurityFinding -Id "CrashDump:$($group.Name):$(Format-SecurityEventStamp -Time $newest)" -Severity Low -Title "New crash files in $($group.Name)" `
            -WhatWeFound "$count appeared in the $($group.Name) crash folder, the newest on $(Format-SecurityEventTime -Time $newest)." `
            -WhyItMatters 'Programs crash for many reasons, but a program that is attacked, or a driver that malware loaded, often crashes too.' `
            -HowToFix 'If a program you use crashed, there is nothing to do. If you see crashes you cannot explain, look at the Application and System logs around that time, and run a full Defender scan.'
    }
}
