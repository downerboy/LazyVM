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

function Get-RootAccess {
    <# Who the LazyVM folder at $Root lets in, as security identifiers, and whether it inherits access from the folder above. #>
    param([Parameter(Mandatory)][string]$Root)

    $acl = Get-Acl -LiteralPath $Root
    return [pscustomobject]@{
        Protected = $acl.AreAccessRulesProtected
        Sids      = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
                Where-Object { "$($_.AccessControlType)" -eq 'Allow' } |
                ForEach-Object { $_.IdentityReference.Value } | Select-Object -Unique)
    }
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
    Get-IsoCheck -Name $vmName -Check 'Windows ISO' -Path $settings.ISOPath
    Get-IsoCheck -Name $vmName -Check 'SQL Server ISO' -Path $settings.SQLIsoPath -Downloadable

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
    if (Test-TaskLogonFailure -TaskName $settings.ScheduleTaskName) { $last = Get-TaskLogonFailureMessage -VMName $vmName }
    New-DiagnosticCheck -Name $vmName -Area Schedule -Check 'Maintenance task' -Status $taskStatus -Detail "$last; next run $($info.NextRunTime)"
}
