# Diagnostic.ps1 - What Test-LazyVM reports about a VM, and its text report.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Everything here only looks: it never starts the VM, writes a setting or
# starts a log, so it can be run while something else is wrong.

function Get-IsoDiagnostic {
    <# The VM's Windows and SQL Server ISO paths, and whether each is there and a valid image. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    foreach ($iso in @(
            @{ Name = 'Windows'; Path = $VM.Settings['ISOPath'] }
            @{ Name = 'SQL Server'; Path = $VM.Settings['SQLIsoPath'] }
        )) {
        $file = if ($iso.Path) { Get-Item -LiteralPath $iso.Path -ErrorAction SilentlyContinue }
        [pscustomobject]@{
            Name      = $iso.Name
            Path      = $iso.Path
            Exists    = [bool]$file
            Valid     = [bool]($file -and (Test-IsoFile -Path $iso.Path))
            SizeBytes = if ($file) { $file.Length } else { $null }
        }
    }
}

function Get-GuestDiagnostic {
    <#
      Whether PowerShell Direct works with the stored account and, when it
      does, the guest's boot time, OOBE state, provisioning marker and
      automatic sign-in. A VM that is not running is left alone. Never
      returns the automatic sign-in password, only whether it is on and for
      whom.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [AllowEmptyString()][string]$State
    )

    $result = [ordered]@{
        PowerShellDirect = $null
        Account          = $null
        LastBootTime     = $null
        OobeState        = $null
        Provisioned      = $null
        AutoLogon        = $null
        AutoLogonUser    = $null
    }

    if ($State -ne 'Running') {
        $result.PowerShellDirect = "Not tried: the VM is $State. Start it, then run Test-LazyVM again."
        return [pscustomobject]$result
    }

    try { $credential = Get-GuestCredential -VM $VM }
    catch {
        $result.PowerShellDirect = "Not tried: the stored guest account could not be read: $($_.Exception.Message)"
        return [pscustomobject]$result
    }
    if (-not $credential) {
        $result.PowerShellDirect = "Not tried: no guest account is stored. Store one with: Set-LazyVMCredential -Name $($VM.Name)"
        return [pscustomobject]$result
    }
    $result.Account = $credential.UserName

    try {
        $session = Connect-Guest -VM $VM -Credential $credential -TimeoutMinutes 1
        $markerKey = $script:GuestMarkerKey
        $facts = Invoke-Command -Session $session -ScriptBlock {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem
            $setup = Get-ItemProperty -Path 'HKLM:\SYSTEM\Setup\State' -Name 'ImageState' -ErrorAction SilentlyContinue
            $marker = Get-ItemProperty -Path $using:markerKey -Name 'Provisioned' -ErrorAction SilentlyContinue
            $winlogon = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
            [pscustomobject]@{
                LastBootTime  = $os.LastBootUpTime
                OobeState     = if ($setup) { $setup.ImageState } else { $null }
                Provisioned   = [bool]($marker -and $marker.Provisioned -eq 1)
                AutoLogon     = [bool]($winlogon -and "$($winlogon.AutoAdminLogon)" -eq '1')
                AutoLogonUser = if ($winlogon) { $winlogon.DefaultUserName } else { $null }
            }
        }
    }
    catch {
        $result.PowerShellDirect = "Failed: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    $result.PowerShellDirect = 'OK'
    foreach ($name in 'LastBootTime', 'OobeState', 'Provisioned', 'AutoLogon', 'AutoLogonUser') {
        $result[$name] = $facts.$name
    }
    return [pscustomobject]$result
}

function Get-MaintenanceTaskDiagnostic {
    <# The VM's daily maintenance task: whether it is registered, and when it last ran and with what result. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $name = $VM.Settings['ScheduleTaskName']
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    $info = if ($task) { Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue }
    return [pscustomobject]@{
        MaintenanceTask           = $name
        MaintenanceTaskRegistered = [bool]$task
        MaintenanceLastRun        = if ($info) { $info.LastRunTime } else { $null }
        MaintenanceLastResult     = if ($info) { $info.LastTaskResult } else { $null }
    }
}

function Get-VMDiagnostic {
    <# Everything Test-LazyVM reports about one VM, as one object. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][pscustomobject]$Root
    )

    $machine = Get-VM -Name $VM.Name -ErrorAction SilentlyContinue
    $state = if ($machine) { "$($machine.State)" } else { 'Not built' }
    $heartbeat = $null
    if ($machine) {
        $service = Get-VMIntegrationService -VMName $VM.Name -Name 'Heartbeat' -ErrorAction SilentlyContinue
        $heartbeat = if ($service) { "$($service.PrimaryStatusDescription)" } else { 'Unknown' }
    }

    $guest = Get-GuestDiagnostic -VM $VM -State $state
    $task = Get-MaintenanceTaskDiagnostic -VM $VM

    $result = [ordered]@{
        PSTypeName = 'LazyVM.Diagnostic'
        Name       = $VM.Name
        Root       = $Root.Path
        RootSource = $Root.Source
        Isos       = @(Get-IsoDiagnostic -VM $VM)
        State      = $state
        Heartbeat  = $heartbeat
    }
    foreach ($part in $guest, $task) {
        foreach ($property in $part.PSObject.Properties) { $result[$property.Name] = $property.Value }
    }
    return [pscustomobject]$result
}

function Format-VMDiagnostic {
    <# The text report of a Get-VMDiagnostic result. #>
    param([Parameter(Mandatory)][pscustomobject]$Diagnostic)

    $show = { param($value) if ($null -eq $value -or "$value" -eq '') { '-' } else { "$value" } }
    $lastResult = if ($null -ne $Diagnostic.MaintenanceLastResult) { '0x{0:X8}' -f [int]$Diagnostic.MaintenanceLastResult } else { '-' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("LazyVM diagnostic - $($Diagnostic.Name) - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add('')
    $lines.Add("Folder            : $($Diagnostic.Root) (from $($Diagnostic.RootSource))")
    foreach ($iso in $Diagnostic.Isos) {
        $status = if ($iso.Valid) { "valid image, $(Format-Size $iso.SizeBytes)" } elseif ($iso.Exists) { 'NOT a valid image' } else { 'missing' }
        $lines.Add(('{0,-18}: {1} ({2})' -f "$($iso.Name) ISO", (& $show $iso.Path), $status))
    }
    $lines.Add("VM state          : $($Diagnostic.State)")
    $lines.Add("Heartbeat         : $(& $show $Diagnostic.Heartbeat)")
    $lines.Add("PowerShell Direct : $($Diagnostic.PowerShellDirect)")
    $lines.Add("Guest account     : $(& $show $Diagnostic.Account)")
    $lines.Add("Last boot         : $(& $show $Diagnostic.LastBootTime)")
    $lines.Add("OOBE state        : $(& $show $Diagnostic.OobeState)")
    $lines.Add("Provisioned       : $(& $show $Diagnostic.Provisioned)")
    $lines.Add("Automatic sign-in : $(& $show $Diagnostic.AutoLogon) (user: $(& $show $Diagnostic.AutoLogonUser))")
    $lines.Add("Maintenance task  : $($Diagnostic.MaintenanceTask) ($(if ($Diagnostic.MaintenanceTaskRegistered) { 'registered' } else { 'not registered' }))")
    $lines.Add("  Last run        : $(& $show $Diagnostic.MaintenanceLastRun)")
    $lines.Add("  Last result     : $lastResult")
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}
