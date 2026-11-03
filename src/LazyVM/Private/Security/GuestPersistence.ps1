# GuestPersistence.ps1 - What runs in the guest to list the places a program can start itself again (#290).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# $script:GuestPersistenceWork runs as SYSTEM through Invoke-GuestTask, in
# Windows PowerShell 5.1, without the guest helpers, after the build to
# record the known-good baseline and every night to compare with it
# (Persistence.ps1). It only reads; it changes nothing.

# The collector. For each area of $script:PersistenceCheck, in its order,
# every item there: @{ Name; Fingerprint; Program; InUserFolder }. Each area
# reads in a try/catch of its own, so one that cannot be read is a note, its
# items are $null, and the others still run. Returns one line of JSON:
# { Notes = @(@{ Level; Text }); Items = @{ <area> = @(...) or $null } }.
# $OwnTaskName is the task it runs as, which it leaves out; $UserName is the
# guest account, whose Run keys and startup folder it reads too.
#
# The fingerprint is the first 12 hex digits of a SHA-256 of what the item
# runs: its command line, account and the like. Only the fingerprint leaves
# the guest, never what it is made from, since a command line can hold a
# password. A version number in a folder name ('\4.18.25010.11-0\') is left
# out of it, so an update that moves a program to its new version's folder,
# as Defender and Edge do, is not a change.
$script:GuestPersistenceWork = {
    param([string]$OwnTaskName, [string]$UserName)

    $ErrorActionPreference = 'Stop'
    $notes = New-Object System.Collections.ArrayList
    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    function Add-ScanNote {
        param([string]$Level, [string]$Text)
        [void]$notes.Add(@{ Level = $Level; Text = $Text })
    }

    function Read-Area {
        <# The items $Read lists for the area $Area, as a list even of one or none, or $null and a note when it cannot be read. #>
        param([string]$Area, [scriptblock]$Read)
        try { return , @(& $Read) }
        catch {
            Add-ScanNote -Level 'WARN' -Text "Security scan: could not read $Area ($($_.Exception.Message)); the next night tries again"
            return $null
        }
    }

    function Get-ProgramPath {
        <# The program a command line starts, with its environment variables expanded: the part in quotes, or up to the first .exe or the like, or its first word. #>
        param([string]$CommandLine)
        $line = [Environment]::ExpandEnvironmentVariables("$CommandLine".Trim())
        if ($line.StartsWith('\??\')) { $line = $line.Substring(4) }
        if ($line -match '^\\SystemRoot\\') { $line = "$env:SystemRoot" + $line.Substring(11) }
        if ($line -match '^system32\\') { $line = "$env:SystemRoot\" + $line }
        if (-not $line) { return '' }
        if ($line.StartsWith('"')) { return $line.Substring(1).Split('"')[0] }
        $program = [regex]::Match($line, '^(.+?\.(exe|com|bat|cmd|dll|ps1|vbs|js))(\s|,|$)', 'IgnoreCase')
        if ($program.Success) { return $program.Groups[1].Value }
        return $line.Split(' ')[0]
    }

    function Test-InUserFolder {
        <# Whether $Path is in a folder users can write to: the user profiles, or the Windows temporary folder. #>
        param([string]$Path)
        foreach ($folder in $userFolders) {
            if ($Path -and $folder -and $Path.StartsWith($folder.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    }

    function New-PersistenceItem {
        param([string]$Name, [string[]]$Part, [string]$Program = '')
        $text = (@($Part | ForEach-Object { "$_" -replace '\\\d+(\.\d+)+(-\d+)?\\', '\<version>\' }) -join "`n")
        $hash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
        $fingerprint = -join @($hash[0..5] | ForEach-Object { $_.ToString('x2') })
        return @{ Name = $Name; Fingerprint = $fingerprint; Program = $Program; InUserFolder = (Test-InUserFolder -Path $Program) }
    }

    # The guest account's security identifier and profile folder, for its
    # Run keys and startup folder, and the folder every profile is in.
    $userFolders = @([System.IO.Path]::Combine("$env:SystemRoot", 'Temp'))
    $user = @{ Sid = ''; Profile = ''; Problem = '' }
    try {
        $profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        $userFolders += [Environment]::ExpandEnvironmentVariables((Get-ItemProperty -LiteralPath $profileList).ProfilesDirectory)
        $user.Sid = (New-Object System.Security.Principal.NTAccount($UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        $user.Profile = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty -LiteralPath "$profileList\$($user.Sid)").ProfileImagePath)
    }
    catch { $user.Problem = "could not find the account $UserName ($($_.Exception.Message))" }

    $items = [ordered]@{}
    $ownTask = '\' + $OwnTaskName

    $items.ScheduledTask = Read-Area 'ScheduledTask' {
        foreach ($task in @(Get-ScheduledTask)) {
            $name = "$($task.TaskPath)$($task.TaskName)"
            if ($name -eq $ownTask) { continue }
            $parts = @("$($task.Principal.UserId)|$($task.Principal.GroupId)|$($task.Principal.RunLevel)")
            $program = ''
            foreach ($action in @($task.Actions)) {
                if ($action.Execute) {
                    $parts += "Run|$($action.Execute)|$($action.Arguments)|$($action.WorkingDirectory)"
                    if (-not $program) { $program = Get-ProgramPath -CommandLine $action.Execute }
                }
                else { $parts += "Com|$($action.ClassId)|$($action.Data)" }
            }
            New-PersistenceItem -Name $name -Part $parts -Program $program
        }
    }

    $items.Service = Read-Area 'Service' {
        foreach ($key in @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services')) {
            $type = $key.GetValue('Type', $null, 'DoNotExpandEnvironmentNames')
            $image = "$($key.GetValue('ImagePath', '', 'DoNotExpandEnvironmentNames'))"
            # Services in a process of their own or shared (0x10, 0x20), not
            # drivers, and not the copies of a per-user service Windows makes
            # at each sign-in (0x80), whose names change.
            if ($null -eq $type -or -not $image -or ([int]$type -band 0x30) -eq 0 -or ([int]$type -band 0x80)) { continue }
            # A service in svchost.exe runs its ServiceDll.
            $dll = ''
            $parameters = $key.OpenSubKey('Parameters')
            if ($parameters) {
                $dll = "$($parameters.GetValue('ServiceDll', '', 'DoNotExpandEnvironmentNames'))"
                $parameters.Close()
            }
            $program = if ($dll) { Get-ProgramPath -CommandLine $dll } else { Get-ProgramPath -CommandLine $image }
            New-PersistenceItem -Name $key.PSChildName -Part @($image, $dll, "$($key.GetValue('ObjectName', '', 'DoNotExpandEnvironmentNames'))") -Program $program
        }
    }

    $items.RunKey = Read-Area 'RunKey' {
        if ($user.Problem) { throw $user.Problem }
        $hive = "Registry::HKEY_USERS\$($user.Sid)"
        if (-not (Test-Path -LiteralPath $hive)) { throw "$UserName is not signed in, so their Run keys cannot be read" }
        $keys = [ordered]@{
            'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion'             = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion'
            'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion' = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion'
            'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion'             = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion"
        }
        foreach ($shown in $keys.Keys) {
            foreach ($run in 'Run', 'RunOnce') {
                $path = "$($keys[$shown])\$run"
                if (-not (Test-Path -LiteralPath $path)) { continue }
                $key = Get-Item -LiteralPath $path
                foreach ($value in @($key.GetValueNames() | Where-Object { $_ })) {
                    $command = "$($key.GetValue($value, '', 'DoNotExpandEnvironmentNames'))"
                    New-PersistenceItem -Name "$shown\$run\$value" -Part @($command) -Program (Get-ProgramPath -CommandLine $command)
                }
            }
        }
    }

    $items.StartupFolder = Read-Area 'StartupFolder' {
        if ($user.Problem) { throw $user.Problem }
        $folders = [ordered]@{
            'All users' = [Environment]::GetFolderPath('CommonStartup')
            $UserName   = Join-Path -Path $user.Profile -ChildPath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
        }
        $shell = New-Object -ComObject WScript.Shell
        foreach ($owner in $folders.Keys) {
            $folder = $folders[$owner]
            if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -Force)) {
                $program = if ($file.Extension -eq '.lnk') { $shell.CreateShortcut($file.FullName).TargetPath } else { $file.FullName }
                New-PersistenceItem -Name "$owner\$($file.Name)" -Part @((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) -Program $program
            }
        }
    }

    $items.WmiSubscription = Read-Area 'WmiSubscription' {
        $namespace = 'root\subscription'
        $filters = @{}
        foreach ($filter in @(Get-CimInstance -Namespace $namespace -ClassName __EventFilter)) {
            $filters["$($filter.Name)"] = "$($filter.EventNamespace)|$($filter.QueryLanguage)|$($filter.Query)"
        }
        $consumers = @{}
        foreach ($consumer in @(Get-CimInstance -Namespace $namespace -ClassName __EventConsumer)) {
            $definition = @($consumer.CimInstanceProperties | Where-Object { $_.Name -notlike '__*' } | Sort-Object -Property Name | ForEach-Object { "$($_.Name)=$($_.Value)" })
            $program = if ($consumer.ExecutablePath) { "$($consumer.ExecutablePath)" } elseif ($consumer.CommandLineTemplate) { Get-ProgramPath -CommandLine $consumer.CommandLineTemplate } else { "$($consumer.ScriptFileName)" }
            $consumers["$($consumer.CimClass.CimClassName).$($consumer.Name)"] = @{ Definition = ($definition -join '|'); Program = $program }
        }
        foreach ($binding in @(Get-CimInstance -Namespace $namespace -ClassName __FilterToConsumerBinding)) {
            $filterName = "$($binding.Filter.Name)"
            $consumerName = "$($binding.Consumer.CimClass.CimClassName).$($binding.Consumer.Name)"
            $consumer = $consumers[$consumerName]
            $definition = if ($consumer) { $consumer.Definition } else { '' }
            $program = if ($consumer) { $consumer.Program } else { '' }
            New-PersistenceItem -Name "$filterName to $consumerName" -Part @($filters[$filterName], $definition) -Program $program
        }
    }

    $items.LocalUser = Read-Area 'LocalUser' {
        foreach ($account in @(Get-LocalUser)) { New-PersistenceItem -Name "$($account.Name)" -Part @("$($account.SID)") }
    }

    # Administrators by its well-known SID, whatever its name.
    $items.Administrators = Read-Area 'Administrators' {
        foreach ($member in @(Get-LocalGroupMember -SID 'S-1-5-32-544')) { New-PersistenceItem -Name "$($member.Name)" -Part @("$($member.SID)") }
    }

    # The task's result is one line of text, so the facts go back as JSON.
    return (ConvertTo-Json -InputObject @{ Notes = @($notes); Items = $items } -Depth 6 -Compress)
}

function Get-GuestPersistenceFact {
    <#
      Runs the persistence collector in the guest as SYSTEM and logs what it
      reports about itself, such as an area it could not read. Returns its
      facts: Notes, and Items by area. Its arguments are its own task's name
      and the guest account's; nothing secret is passed.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $taskName = "${script:TaskPrefix}persistence-scan"
    $json = Invoke-GuestTask -VM $VM -TaskName $taskName -Activity 'persistence scan' -TimeoutMinutes 10 `
        -Work $script:GuestPersistenceWork -ArgumentList @($taskName, $VM.Runtime.GuestAdminUser)
    $facts = ConvertFrom-Json -InputObject $json -DateKind String
    Write-GuestNote -Notes @($facts.Notes)
    return $facts
}
