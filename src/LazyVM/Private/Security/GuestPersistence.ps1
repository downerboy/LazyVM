# GuestPersistence.ps1 - What runs in the guest to list the places a program can start itself again (#290, #334).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# $script:GuestPersistenceWork runs as SYSTEM through Invoke-GuestTask, in
# Windows PowerShell 5.1, without the guest helpers, after a build to record
# the known-good baseline and every night to compare with it
# (Persistence.ps1). It only reads; it changes nothing, and it follows no
# link in a startup folder.

# The collector. For each area of $script:PersistenceCheck, in its order,
# every item there: @{ Name; Fingerprint; Program; InUserFolder }. Each area
# reads in a try/catch of its own, so one that cannot be read is a note, its
# items are $null, and the others still run. So does each item: one that
# cannot be read has the fingerprint 'unreadable', and a link in a startup
# folder the fingerprint 'link', which the host always reports. Returns one
# line of JSON: { Notes = @(@{ Level; Text }); Items = @{ <area> = @(...) or $null } }.
# $OwnTaskName is the task it runs as, which it leaves out; $UserName is the
# guest account, whose Run keys and startup folder it reads too.
#
# The fingerprint is the SHA-256, in hex, of what the item runs: its command
# line, account, failure actions and the like, and, for an item that points
# into a folder users can write to, the program file itself. Of what it is
# made from, only the program's path leaves the guest, never the arguments,
# since a command line can hold a password. A version number in a folder
# name ('\4.18.25010.11-0\') is left out of it, so an update that moves a
# program to its new version's folder, as Defender and Edge do, is not a
# change; never for an item that points into a folder users can write to.
#
# Folders users can write to: the user profiles, the Windows temporary
# folder, a folder in ProgramData that its access (or that of a folder above
# it there) lets a user change, any network path, and a path written with one of a
# user's own variables, such as %APPDATA%, which SYSTEM would expand to its
# own profile. Every path on an item's command line is checked, not only the
# program's. Windows' own folders come from Windows, not the environment.
$script:GuestPersistenceWork = {
    param([string]$OwnTaskName, [string]$UserName)

    $ErrorActionPreference = 'Stop'
    $notes = New-Object System.Collections.ArrayList
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $windowsFolder = [Environment]::GetFolderPath('Windows')
    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    # Who counts as a user when deciding whether one can write to a folder
    # in ProgramData: Users, Authenticated Users, Everyone, INTERACTIVE, and
    # the guest account (added once it is found).
    $userSids = @('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0', 'S-1-5-4')
    # Rights that change a folder or what is in it, as $script:GuestWriteRights
    # in Guest.Helpers.ps1 and $script:WriteRights in TrustedCode.ps1: write
    # and append data, extended attributes and attributes, delete (the
    # folder, or anything in it), change permissions, take ownership, and
    # generic write or all.
    $writeRights = [long]0x500D0156
    $writableByUsers = @{}
    $userVariable = '%(APPDATA|LOCALAPPDATA|TEMP|TMP|USERPROFILE|HOMEPATH|HOMEDRIVE|ONEDRIVE)%'

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

    function Read-Item {
        <# The item $Read makes for $Name, or, when it cannot be read, one with the fingerprint 'unreadable' and a note. #>
        param([string]$Area, [string]$Name, [scriptblock]$Read)
        try { return (& $Read) }
        catch {
            Add-ScanNote -Level 'WARN' -Text "Security scan: could not read the $Area item $Name ($($_.Exception.Message))"
            return @{ Name = $Name; Fingerprint = 'unreadable'; Program = ''; InUserFolder = $false }
        }
    }

    function Expand-GuestPath {
        <# $Path with its environment variables expanded, and the forms Windows writes service paths in made full. #>
        param([string]$Path)
        $line = [Environment]::ExpandEnvironmentVariables("$Path".Trim())
        if ($line.StartsWith('\??\')) { $line = $line.Substring(4) }
        if ($line -match '^\\SystemRoot\\') { $line = $windowsFolder + $line.Substring(11) }
        if ($line -match '^system32\\') { $line = "$windowsFolder\" + $line }
        return $line
    }

    function Get-ProgramPath {
        <# The program a command line starts: the part in quotes, or up to the first .exe or the like, or its first word. #>
        param([string]$CommandLine)
        $line = Expand-GuestPath -Path $CommandLine
        if (-not $line) { return '' }
        if ($line.StartsWith('"')) { return $line.Substring(1).Split('"')[0] }
        $program = [regex]::Match($line, '^(.+?\.(exe|com|bat|cmd|dll|ps1|vbs|js))(\s|,|$)', 'IgnoreCase')
        if ($program.Success) { return $program.Groups[1].Value }
        return $line.Split(' ')[0]
    }

    function Test-UserFolderPath {
        <# Whether the path-like text $Token points into a folder users can write to. #>
        param([string]$Token)
        if ($Token -match $userVariable) { return $true }
        $path = (Expand-GuestPath -Path $Token).Trim('"')
        if ($path.StartsWith('\\')) { return $true }
        if (Test-ProgramDataWritable -Path $path) { return $true }
        foreach ($folder in $userFolders) {
            if ($folder -and $path.StartsWith($folder.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    }

    function Test-WritableByUser {
        <# Whether the file or folder $Path gives a user (one of $userSids) a right that changes it ($writeRights). Missing, or unreadable, is no. #>
        param([string]$Path)
        if ($writableByUsers.ContainsKey($Path)) { return $writableByUsers[$Path] }
        $writable = $false
        try {
            $acl = Get-Acl -LiteralPath $Path
            foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
                $insideOnly = [bool]($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly)
                if ("$($rule.AccessControlType)" -ne 'Allow' -or $insideOnly -or "$($rule.IdentityReference.Value)" -notin $userSids) { continue }
                if ([long]$rule.FileSystemRights -band $writeRights) { $writable = $true; break }
            }
        }
        catch { $writable = $false }
        $writableByUsers[$Path] = $writable
        return $writable
    }

    function Test-ProgramDataWritable {
        <#
          Whether $Path, in ProgramData, or a folder above it below
          ProgramData, can be changed by a user. ProgramData itself is left
          out: it lets every user make a folder of their own, which does
          not let them change anyone else's.
        #>
        param([string]$Path)
        $root = $programData.TrimEnd('\')
        if (-not $root -or -not $Path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $current = $Path.TrimEnd('\')
        while ($current.Length -gt $root.Length) {
            if (Test-WritableByUser -Path $current) { return $true }
            $current = $current.Substring(0, $current.LastIndexOf('\'))
        }
        return $false
    }

    function Test-PointsIntoUserFolder {
        <# Whether any path on the command lines $Text points into a folder users can write to. #>
        param([string[]]$Text)
        foreach ($line in @($Text | Where-Object { $_ })) {
            foreach ($token in [regex]::Matches($line, '"[^"]+"|[^\s,;=]+')) {
                if ($token.Value -match '^"?([A-Za-z]:\\|\\\\|%)' -and (Test-UserFolderPath -Token $token.Value)) { return $true }
            }
        }
        return $false
    }

    function New-PersistenceItem {
        <#
          The item $Name, fingerprinted from $Part. $CommandLine is every
          command line it holds, $Program the program it starts.
        #>
        param([string]$Name, [string[]]$Part, [string]$Program = '', [string[]]$CommandLine = @())
        $inUserFolder = Test-PointsIntoUserFolder -Text (@($CommandLine) + $Program)
        $parts = @($Part | ForEach-Object { "$_" })
        if ($inUserFolder) {
            # The program file itself, when it is on a local disk and not a link.
            if ($Program -match '^[A-Za-z]:\\' -and (Test-Path -LiteralPath $Program -PathType Leaf)) {
                $file = Get-Item -LiteralPath $Program -Force
                if (-not ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $parts += (Get-FileHash -LiteralPath $Program -Algorithm SHA256).Hash }
            }
        }
        else {
            $parts = @($parts | ForEach-Object { $_ -replace '\\\d+(\.\d+)+(-\d+)?\\', '\<version>\' })
        }
        $hash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($parts -join "`n"))
        $fingerprint = -join @($hash | ForEach-Object { $_.ToString('x2') })
        return @{ Name = $Name; Fingerprint = $fingerprint; Program = $Program; InUserFolder = $inUserFolder }
    }

    function Read-RunKey {
        <# Every value of the Run and RunOnce keys under $Path, named under $Shown. #>
        param([string]$Area, [string]$Shown, [string]$Path)
        foreach ($run in 'Run', 'RunOnce') {
            $keyPath = "$Path\$run"
            if (-not (Test-Path -LiteralPath $keyPath)) { continue }
            $key = Get-Item -LiteralPath $keyPath
            foreach ($value in @($key.GetValueNames() | Where-Object { $_ })) {
                Read-Item -Area $Area -Name "$Shown\$run\$value" -Read {
                    $command = "$($key.GetValue($value, '', 'DoNotExpandEnvironmentNames'))"
                    New-PersistenceItem -Name "$Shown\$run\$value" -Part @($command) -Program (Get-ProgramPath -CommandLine $command) -CommandLine @($command)
                }
            }
        }
    }

    function Assert-NoLinkOnPath {
        <# Stops when $Folder, or a folder above it up to $Base, is a link (reparse point) or a network path. #>
        param([string]$Folder, [string]$Base)
        if ($Folder.StartsWith('\\')) { throw "$Folder is a network path, which LazyVM does not read" }
        $current = $Folder
        while ($current -and $current.Length -ge $Base.TrimEnd('\').Length) {
            if (Test-Path -LiteralPath $current) {
                if ((Get-Item -LiteralPath $current -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "$current is a link (reparse point), which LazyVM does not follow" }
            }
            $current = Split-Path -Path $current -Parent
        }
    }

    function Read-StartupFolder {
        <# Every file in the startup folder $Folder, named under $Owner: a link is reported as one, never followed. #>
        param([string]$Area, [string]$Owner, [string]$Folder, [string]$Base)
        Assert-NoLinkOnPath -Folder $Folder -Base $Base
        if (-not (Test-Path -LiteralPath $Folder)) { return }
        $shell = New-Object -ComObject WScript.Shell
        foreach ($file in @(Get-ChildItem -LiteralPath $Folder -File -Force)) {
            $name = "$Owner\$($file.Name)"
            Read-Item -Area $Area -Name $name -Read {
                if ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    return @{ Name = $name; Fingerprint = 'link'; Program = ''; InUserFolder = $false }
                }
                $program = if ($file.Extension -eq '.lnk') { "$($shell.CreateShortcut($file.FullName).TargetPath)" } else { $file.FullName }
                New-PersistenceItem -Name $name -Part @((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) -Program $program
            }
        }
    }

    # The folders users can write to, and the guest account's security
    # identifier and profile folder, for its Run keys and startup folder.
    $userFolders = @([System.IO.Path]::Combine($windowsFolder, 'Temp'))
    $user = @{ Sid = ''; Profile = ''; Problem = '' }
    try {
        $profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        $userFolders += [Environment]::ExpandEnvironmentVariables((Get-ItemProperty -LiteralPath $profileList).ProfilesDirectory)
        $user.Sid = (New-Object System.Security.Principal.NTAccount($UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        $userSids += $user.Sid
        $user.Profile = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty -LiteralPath "$profileList\$($user.Sid)").ProfileImagePath)
    }
    catch { $user.Problem = "could not find the account $UserName ($($_.Exception.Message))" }

    $items = [ordered]@{}
    $ownTask = '\' + $OwnTaskName

    $items.ScheduledTask = Read-Area 'ScheduledTask' {
        # A task that cannot be read is reported as one, not left out.
        $taskErrors = @()
        $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue -ErrorVariable taskErrors)
        foreach ($problem in @($taskErrors)) {
            $name = if ($problem.TargetObject) { "$($problem.TargetObject)" } else { '(a task that could not be listed)' }
            Read-Item -Area 'ScheduledTask' -Name $name -Read { throw $problem }
        }
        foreach ($task in $tasks) {
            $name = "$($task.TaskPath)$($task.TaskName)"
            if ($name -eq $ownTask) { continue }
            Read-Item -Area 'ScheduledTask' -Name $name -Read {
                $parts = @("$($task.Principal.UserId)|$($task.Principal.GroupId)|$($task.Principal.RunLevel)")
                $commands = @()
                $program = ''
                foreach ($action in @($task.Actions)) {
                    if ($action.Execute) {
                        $parts += "Run|$($action.Execute)|$($action.Arguments)|$($action.WorkingDirectory)"
                        $commands += @("$($action.Execute)", "$($action.Arguments)", "$($action.WorkingDirectory)")
                        if (-not $program) { $program = Get-ProgramPath -CommandLine $action.Execute }
                    }
                    else { $parts += "Com|$($action.ClassId)|$($action.Data)" }
                }
                New-PersistenceItem -Name $name -Part $parts -Program $program -CommandLine $commands
            }
        }
    }

    $items.Service = Read-Area 'Service' {
        $services = Get-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services'
        foreach ($name in @($services.GetSubKeyNames())) {
            $service = Read-Item -Area 'Service' -Name $name -Read {
                $key = $services.OpenSubKey($name)
                if (-not $key) { throw 'its key cannot be opened' }
                $type = $key.GetValue('Type', $null, 'DoNotExpandEnvironmentNames')
                $image = "$($key.GetValue('ImagePath', '', 'DoNotExpandEnvironmentNames'))"
                # Services in a process of their own or shared (0x10, 0x20),
                # not drivers, and not the copies of a per-user service
                # Windows makes at each sign-in (0x80), whose names change.
                if ($null -eq $type -or -not $image -or ([int]$type -band 0x30) -eq 0 -or ([int]$type -band 0x80)) { return $null }
                # A service in svchost.exe runs its ServiceDll.
                $dll = ''
                $parameters = $key.OpenSubKey('Parameters')
                if ($parameters) {
                    $dll = "$($parameters.GetValue('ServiceDll', '', 'DoNotExpandEnvironmentNames'))"
                    $parameters.Close()
                }
                # What it runs when it fails, and when it starts, can start a program too.
                $failureCommand = "$($key.GetValue('FailureCommand', '', 'DoNotExpandEnvironmentNames'))"
                $failureActions = $key.GetValue('FailureActions', $null, 'DoNotExpandEnvironmentNames')
                $failureText = if ($failureActions -is [byte[]]) { [BitConverter]::ToString($failureActions) } else { "$failureActions" }
                $program = if ($dll) { Get-ProgramPath -CommandLine $dll } else { Get-ProgramPath -CommandLine $image }
                $parts = @($image, $dll, "$($key.GetValue('ObjectName', '', 'DoNotExpandEnvironmentNames'))", "$($key.GetValue('Start', '', 'DoNotExpandEnvironmentNames'))", $failureCommand, $failureText)
                New-PersistenceItem -Name $name -Part $parts -Program $program -CommandLine @($image, $dll, $failureCommand)
            }
            if ($service) { $service }
        }
    }

    # For every user, whether or not the guest account is signed in.
    $items.RunKey = Read-Area 'RunKey' {
        Read-RunKey -Area 'RunKey' -Shown 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion' -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion'
        Read-RunKey -Area 'RunKey' -Shown 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion' -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion'
    }

    $items.UserRunKey = Read-Area 'UserRunKey' {
        if ($user.Problem) { throw $user.Problem }
        $hive = "Registry::HKEY_USERS\$($user.Sid)"
        if (-not (Test-Path -LiteralPath $hive)) { throw "$UserName is not signed in, so their Run keys cannot be read" }
        Read-RunKey -Area 'UserRunKey' -Shown 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion' -Path "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion"
    }

    $items.StartupFolder = Read-Area 'StartupFolder' {
        Read-StartupFolder -Area 'StartupFolder' -Owner 'All users' -Folder ([Environment]::GetFolderPath('CommonStartup')) -Base $programData
    }

    $items.UserStartupFolder = Read-Area 'UserStartupFolder' {
        if ($user.Problem) { throw $user.Problem }
        $folder = Join-Path -Path $user.Profile -ChildPath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
        Read-StartupFolder -Area 'UserStartupFolder' -Owner $UserName -Folder $folder -Base $user.Profile
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
            $commands = @("$($consumer.ExecutablePath)", "$($consumer.CommandLineTemplate)", "$($consumer.ScriptFileName)")
            $consumers["$($consumer.CimClass.CimClassName).$($consumer.Name)"] = @{ Definition = ($definition -join '|'); Program = $program; Commands = $commands }
        }
        foreach ($binding in @(Get-CimInstance -Namespace $namespace -ClassName __FilterToConsumerBinding)) {
            $filterName = "$($binding.Filter.Name)"
            $consumerName = "$($binding.Consumer.CimClass.CimClassName).$($binding.Consumer.Name)"
            Read-Item -Area 'WmiSubscription' -Name "$filterName to $consumerName" -Read {
                $consumer = $consumers[$consumerName]
                if (-not $consumer) { $consumer = @{ Definition = ''; Program = ''; Commands = @() } }
                New-PersistenceItem -Name "$filterName to $consumerName" -Part @($filters[$filterName], $consumer.Definition) -Program $consumer.Program -CommandLine $consumer.Commands
            }
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
