# Diagnostic.ps1 - Test-LazyVM: what a build or maintenance run depends on, checked without changing anything (#33).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function New-DiagnosticCheck {
    <# One line of the report. Status is OK, INFO, WARN or FAIL. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Makes a value; changes nothing.')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Host', 'VM', 'Guest', 'Schedule')][string]$Area,
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][ValidateSet('OK', 'INFO', 'WARN', 'FAIL')][string]$Status,
        [string]$Detail = ''
    )

    return [pscustomobject]@{ PSTypeName = 'LazyVM.Check'; Name = $Name; Area = $Area; Check = $Check; Status = $Status; Detail = $Detail }
}

function Get-IsoCheck {
    <# Whether the ISO at $Path is there and really an ISO image. A missing SQL Server ISO is only a warning: the build downloads it. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][string]$Path,
        [switch]$Downloadable
    )

    if (Test-IsoFile -Path $Path) {
        return New-DiagnosticCheck -Name $Name -Area Host -Check $Check -Status OK -Detail "$Path ($(Format-Size (Get-Item -LiteralPath $Path).Length))"
    }
    $status = if ($Downloadable -and -not (Test-Path -LiteralPath $Path)) { 'WARN' } else { 'FAIL' }
    $why = if (Test-Path -LiteralPath $Path) { 'is not an ISO image' } elseif ($Downloadable) { 'is not there yet; the build downloads it' } else { 'is not there' }
    return New-DiagnosticCheck -Name $Name -Area Host -Check $Check -Status $status -Detail "$Path $why"
}

function ConvertTo-AccountName {
    <# The account name for a security identifier, or the identifier itself when it has no name. #>
    param([Parameter(Mandatory)][string]$Sid)

    try { return [System.Security.Principal.SecurityIdentifier]::new($Sid).Translate([System.Security.Principal.NTAccount]).Value }
    catch { return $Sid }
}

function Get-RootAccessCheck {
    <# Whether the LazyVM folder is open to the current user and SYSTEM only, as Initialize-RootFolder leaves it (#284). #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Root
    )

    try { $access = Get-RootAccess -Root $Root }
    catch { return New-DiagnosticCheck -Name $Name -Area Host -Check 'LazyVM folder access' -Status FAIL -Detail $_.Exception.Message }
    $allowed = @((Get-CurrentUserSid).Value, 'S-1-5-18')
    $others = @($access.Sids | Where-Object { $allowed -notcontains $_ } | ForEach-Object { ConvertTo-AccountName -Sid $_ })
    $problems = @()
    if (-not $access.Protected) { $problems += 'it inherits access from the folder above' }
    if ($others.Count -gt 0) { $problems += "it is also open to $($others -join ', ')" }
    if ($problems.Count -eq 0) {
        return New-DiagnosticCheck -Name $Name -Area Host -Check 'LazyVM folder access' -Status OK -Detail 'only you and SYSTEM'
    }
    return New-DiagnosticCheck -Name $Name -Area Host -Check 'LazyVM folder access' -Status WARN -Detail "$($problems -join '; '). Lock it again with: Set-LazyVMRoot -Path $Root"
}

function Get-TrustedCodeCheck {
    <# Whether only administrators, SYSTEM and TrustedInstaller can change the code the scheduled tasks run (#284). #>
    param([Parameter(Mandatory)][string]$Name)

    try { Assert-TrustedCode }
    catch {
        return New-DiagnosticCheck -Name $Name -Area Host -Check 'Code the tasks run' -Status FAIL -Detail "$($_.Exception.Message) Install LazyVM with Install.ps1, as administrator."
    }
    return New-DiagnosticCheck -Name $Name -Area Host -Check 'Code the tasks run' -Status OK -Detail "only administrators can change it ($(Get-ModuleImportPath))"
}

function Get-CloudSyncCheck {
    <#
      Whether the LazyVM folder or the module LazyVM runs from is in
      OneDrive (#284), where files can be online-only while the tasks run
      and are copied to the cloud.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Root
    )

    $synced = @(@($Root, (Get-LazyVMModuleBase)) | Where-Object { Test-CloudSyncedPath -Path $_ })
    if ($synced.Count -eq 0) {
        return New-DiagnosticCheck -Name $Name -Area Host -Check 'OneDrive' -Status OK -Detail 'the LazyVM folder and the module are outside OneDrive'
    }
    return New-DiagnosticCheck -Name $Name -Area Host -Check 'OneDrive' -Status WARN -Detail "$($synced -join ' and ') in OneDrive: files there can be online-only while the tasks run, and are copied to the cloud. Install the module with Install.ps1, and move the LazyVM folder outside OneDrive."
}

function Get-ModuleShadowCheck {
    <#
      Whether Import-Module LazyVM loads this module (#311). PowerShell takes
      the first folder on PSModulePath that has LazyVM, and the highest
      version in it, so a copy shadows this one when its folder comes first,
      or it is a higher version in the same folder. A module that is not on
      PSModulePath at all, imported by its path, is reported on its own.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $check = @{ Name = $Name; Area = 'Host'; Check = 'Module copies' }
    $running = Get-LazyVMModuleBase
    $copies = @(Get-Module -Name LazyVM -ListAvailable)
    $self = $copies | Where-Object { Test-SamePath -Path $_.ModuleBase -Other $running } | Select-Object -First 1
    if (-not $self) {
        return New-DiagnosticCheck @check -Status WARN -Detail "$running is not on PSModulePath, so Import-Module LazyVM does not load it. Install LazyVM with Install.ps1, as administrator."
    }

    $folder = Get-ParentFolder -Path $self.ModuleBase
    $shadowing = [Collections.Generic.List[string]]::new()
    $reached = $false
    foreach ($copy in $copies) {
        if (Test-SamePath -Path (Get-ParentFolder -Path $copy.ModuleBase) -Other $folder) {
            $reached = $true
            if ($copy.Version -gt $self.Version) { $shadowing.Add($copy.ModuleBase) }
        }
        elseif (-not $reached) { $shadowing.Add($copy.ModuleBase) }
    }
    if ($shadowing.Count -eq 0) {
        return New-DiagnosticCheck @check -Status OK -Detail "Import-Module LazyVM loads this one ($running)"
    }
    return New-DiagnosticCheck @check -Status WARN -Detail "Import-Module LazyVM loads $($shadowing -join ' and ') instead of $running, which comes later on PSModulePath or is an older version. Run Install.ps1 again, as administrator: it removes LazyVM's earlier copies and names any it cannot."
}

function Get-RecoveryKeyCheck {
    <# Whether every stored BitLocker recovery password of the VM's is exported (#286). Reads the store and the export record once each. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $check = @{ Name = $VM.Name; Area = 'Host'; Check = 'Recovery keys' }
    try {
        $stored = @(Get-StoredRecoveryKey -VM $VM)
        $record = Read-RecoveryKeyExportRecord -VM $VM
    }
    catch { return New-DiagnosticCheck @check -Status FAIL -Detail $_.Exception.Message }

    $unexported = @(Select-UnexportedRecoveryKey -Keys $stored -Record $record)
    if ($stored.Count -eq 0) {
        return New-DiagnosticCheck @check -Status INFO -Detail 'none stored yet; the build and the daily maintenance store them'
    }
    if ($unexported.Count -gt 0) {
        return New-DiagnosticCheck @check -Status WARN -Detail "$($unexported.Count) of $($stored.Count) not exported yet: $(Get-RecoveryKeyExportCommand)"
    }
    return New-DiagnosticCheck @check -Status OK -Detail "all $($stored.Count) exported, last on $($record.Exported)"
}

function Get-LazyVMDiagnostic {
    <#
      The checks Test-LazyVM reports, in order. Reads only: a VM that is not
      running is not started, and its guest is not checked. The guest's
      automatic sign-in is read as on or off with its user name, never its
      password. A check that cannot be made is reported as FAIL, and the
      rest still run.
    #>
    param([string]$Name)

    try { $root = Resolve-LazyVMRoot }
    catch {
        New-DiagnosticCheck -Name $Name -Area Host -Check 'LazyVM folder' -Status FAIL -Detail $_.Exception.Message
        return
    }
    try { $configuration = Read-VMSetting -Root $root.Path -VMName $Name -ReadOnly }
    catch {
        New-DiagnosticCheck -Name $Name -Area Host -Check 'LazyVM folder' -Status OK -Detail "$($root.Path) (from $($root.Source))"
        New-DiagnosticCheck -Name $Name -Area Host -Check 'VM settings' -Status FAIL -Detail $_.Exception.Message
        return
    }
    $vmName = $configuration.VMName
    $settings = $configuration.Settings
    New-DiagnosticCheck -Name $vmName -Area Host -Check 'LazyVM folder' -Status OK -Detail "$($root.Path) (from $($root.Source))"
    Get-RootAccessCheck -Name $vmName -Root $root.Path
    Get-CloudSyncCheck -Name $vmName -Root $root.Path
    Get-TrustedCodeCheck -Name $vmName
    Get-ModuleShadowCheck -Name $vmName
    Get-IsoCheck -Name $vmName -Check 'Windows ISO' -Path $settings.ISOPath
    Get-IsoCheck -Name $vmName -Check 'SQL Server ISO' -Path $settings.SQLIsoPath -Downloadable
    Get-RecoveryKeyCheck -VM ([VMContext]::new($settings))

    $machine = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $machine) {
        New-DiagnosticCheck -Name $vmName -Area VM -Check 'VM' -Status WARN -Detail "not built yet: Build-LazyVM -Name $vmName"
    }
    else {
        $vmStatus = if ("$($machine.State)" -eq 'Running' -or "$($machine.State)" -eq 'Off') { 'OK' } else { 'WARN' }
        New-DiagnosticCheck -Name $vmName -Area VM -Check 'VM' -Status $vmStatus -Detail "$($machine.State), heartbeat $(if ($machine.Heartbeat) { $machine.Heartbeat } else { 'none' })"
    }

    if ($machine -and "$($machine.State)" -eq 'Running') {
        try {
            $credential = Get-StoredCredential -Path $settings.GuestCredFile
            if (-not $credential) { throw "No credential is stored for '$vmName'. Store one with: Set-LazyVMCredential -Name $vmName" }
            $guest = Invoke-Command -VMName $vmName -Credential $credential -ErrorAction Stop -ArgumentList $script:GuestMarkerKey -ScriptBlock {
                param($markerKey)
                $winlogon = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
                [pscustomobject]@{
                    BootTime       = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
                    ImageState     = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -ErrorAction SilentlyContinue).ImageState
                    OobeInProgress = (Get-ItemProperty -Path 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue).OOBEInProgress
                    Provisioned    = (Get-ItemProperty -Path $markerKey -ErrorAction SilentlyContinue).Provisioned
                    AutoLogon      = "$($winlogon.AutoAdminLogon)"
                    AutoLogonUser  = "$($winlogon.DefaultUserName)"
                }
            }
            New-DiagnosticCheck -Name $vmName -Area Guest -Check 'PowerShell Direct' -Status OK -Detail "connected as $($credential.UserName)"
            New-DiagnosticCheck -Name $vmName -Area Guest -Check 'Boot time' -Status INFO -Detail "$($guest.BootTime)"
            $setupDone = "$($guest.ImageState)" -eq 'IMAGE_STATE_COMPLETE' -and -not $guest.OobeInProgress
            New-DiagnosticCheck -Name $vmName -Area Guest -Check 'Windows set-up' -Status $(if ($setupDone) { 'OK' } else { 'WARN' }) -Detail $(if ($setupDone) { 'complete' } else { "not finished ($($guest.ImageState))" })
            $provisioned = "$($guest.Provisioned)" -eq '1'
            New-DiagnosticCheck -Name $vmName -Area Guest -Check 'Provisioning marker' -Status $(if ($provisioned) { 'OK' } else { 'WARN' }) -Detail $(if ($provisioned) { 'set by the answer file at first sign-in' } else { "missing from $($script:GuestMarkerKey)" })
            New-DiagnosticCheck -Name $vmName -Area Guest -Check 'Automatic sign-in' -Status INFO -Detail $(if ($guest.AutoLogon -eq '1') { "on, as $($guest.AutoLogonUser)" } else { 'off' })
        }
        catch {
            New-DiagnosticCheck -Name $vmName -Area Guest -Check 'PowerShell Direct' -Status FAIL -Detail $_.Exception.Message
        }
    }
    elseif ($machine) {
        New-DiagnosticCheck -Name $vmName -Area Guest -Check 'PowerShell Direct' -Status INFO -Detail "not checked: the VM is $($machine.State), and Test-LazyVM starts nothing"
    }

    $task = Get-ScheduledTask -TaskName $settings.ScheduleTaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        New-DiagnosticCheck -Name $vmName -Area Schedule -Check 'Maintenance task' -Status WARN -Detail "not scheduled: Register-LazyVMMaintenance -Name $vmName"
        return
    }
    $info = Get-ScheduledTaskInfo -TaskName $settings.ScheduleTaskName -ErrorAction Stop
    # 0x41303 (267011): the task has not run yet.
    $taskStatus = switch ([long]$info.LastTaskResult) { 0 { 'OK' } 267011 { 'INFO' } default { 'FAIL' } }
    $last = if ($taskStatus -eq 'INFO') { 'has not run yet' } else { "last ran $($info.LastRunTime), result 0x$('{0:X}' -f [long]$info.LastTaskResult)" }
    New-DiagnosticCheck -Name $vmName -Area Schedule -Check 'Maintenance task' -Status $taskStatus -Detail "$last; next run $($info.NextRunTime)"
}
