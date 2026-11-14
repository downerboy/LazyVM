# Dashboard.ps1 - What Get-LazyVMDashboard shows for each VM (#305).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Everything here only reads. Each part is read on its own, so a part that
# cannot be read is named in the VM's Problems and the rest is still shown.

function New-DashboardEntry {
    <# The dashboard's row for the VM Get-LazyVM described as $VM, read from Hyper-V, Task Scheduler and the VM's files under $Root. #>
    [OutputType('LazyVM.Dashboard')]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][pscustomobject]$VM
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    $entry = [ordered]@{
        PSTypeName            = 'LazyVM.Dashboard'
        Name                  = $VM.Name
        State                 = $VM.State
        Created               = $null
        MemoryAssigned        = $null
        Disks                 = @()
        DiskSpaceUsed         = $null
        MaintenanceTime       = $VM.MaintenanceTime
        MaintenanceTask       = $VM.MaintenanceTask
        LastMaintenance       = $null
        LastMaintenanceResult = $null
        LastSecurityScan      = $null
        OpenFindings          = $null
        OriginalConfig        = $null
        GreenTemplate         = $null
        GreenTemplateUpdated  = $null
        Settings              = $VM.Settings
        ProfilePath           = $VM.ProfilePath
        Problems              = @()
    }

    if ($VM.State -notin 'Not built', 'Unknown') {
        try {
            $machine = Get-VM -Name $VM.Name -ErrorAction Stop
            $entry.Created = $machine.CreationTime
            $entry.MemoryAssigned = [long]$machine.MemoryAssigned
        }
        catch { $problems.Add("Hyper-V: $($_.Exception.Message)") }

        try {
            $entry.Disks = @(Get-VMDiskUsage -VMName $VM.Name)
            $total = [long]0
            foreach ($disk in $entry.Disks) { $total += $disk.Used }
            $entry.DiskSpaceUsed = $total
        }
        catch { $problems.Add("Disks: $($_.Exception.Message)") }
    }

    $settings = $null
    if ($VM.Settings -eq 'OK') {
        try { $settings = (Read-VMSetting -Root $Root -VMName $VM.Name -ReadOnly).Settings }
        catch { $problems.Add("Settings: $($_.Exception.Message)") }
    }

    if ($settings -and $VM.MaintenanceTask -eq 'Registered') {
        try {
            $run = Get-MaintenanceRunSummary -TaskName $settings.ScheduleTaskName
            $entry.LastMaintenance = $run.LastRun
            $entry.LastMaintenanceResult = $run.Result
        }
        catch { $problems.Add("Maintenance: $($_.Exception.Message)") }
    }

    if ($settings) {
        try {
            $scan = Get-SecurityFindingSummary -VM ([VMContext]::new($settings))
            $entry.LastSecurityScan = $scan.ScannedAt
            $entry.OpenFindings = $scan.Open
        }
        catch { $problems.Add("Security findings: $($_.Exception.Message)") }
    }

    try {
        $templates = Get-VMTemplateSummary -Root $Root -Name $VM.Name
        $entry.OriginalConfig = $templates.OriginalConfig
        $entry.GreenTemplate = $templates.GreenTemplate
        $entry.GreenTemplateUpdated = $templates.GreenTemplateUpdated
    }
    catch { $problems.Add("Templates: $($_.Exception.Message)") }

    $entry.Problems = $problems.ToArray()
    return [pscustomobject]$entry
}

function Get-VMDiskUsage {
    <#
      The virtual hard disks attached to the VM $VMName: each one's file
      name and path, the space it takes with its checkpoint files, and its
      maximum size. A disk with checkpoints is attached through its newest
      .avhdx; it is named after the .vhdx at the start of that chain.
    #>
    [OutputType('LazyVM.DashboardDisk')]
    param([Parameter(Mandatory)][string]$VMName)

    foreach ($drive in @(Get-VMHardDiskDrive -VMName $VMName -ErrorAction Stop)) {
        $disk = Get-VHD -Path $drive.Path -ErrorAction Stop
        $maximum = [long]$disk.Size
        $used = [long]$disk.FileSize
        while ($disk.ParentPath) {
            $disk = Get-VHD -Path $disk.ParentPath -ErrorAction Stop
            $used += [long]$disk.FileSize
        }
        [pscustomobject]@{
            PSTypeName = 'LazyVM.DashboardDisk'
            Name       = Split-Path -Path $disk.Path -Leaf
            Path       = $disk.Path
            Used       = $used
            Maximum    = $maximum
        }
    }
}

function Get-MaintenanceRunSummary {
    <# When the maintenance task $TaskName last ran (LastRun) and how it ended (Result): Succeeded, Failed (0x...) or Not run yet. #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$TaskName)

    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
    $result = [long]$info.LastTaskResult
    if ($result -eq $script:TaskNotRunYetResult) {
        return [pscustomobject]@{ LastRun = $null; Result = 'Not run yet' }
    }
    $outcome = if ($result -eq 0) { 'Succeeded' } else { 'Failed (0x{0:X})' -f $result }
    return [pscustomobject]@{ LastRun = $info.LastRunTime; Result = $outcome }
}

function Get-SecurityFindingSummary {
    <# When the VM's last security scan ran (ScannedAt) and how many of its findings are still open (Open): neither approved nor resolved. Both empty before the first scan. #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $record = Read-SecurityFindingRecord -VM $VM
    if (-not $record) { return [pscustomobject]@{ ScannedAt = $null; Open = $null } }
    $unapproved = @(Select-UnapprovedSecurityFinding -Finding $record.Findings -Approval (Read-SecurityBaseline -VM $VM).Approvals)
    $open = @($unapproved | Where-Object { $_.Status -ne 'Resolved' })
    return [pscustomobject]@{ ScannedAt = $record.ScannedAt; Open = $open.Count }
}

function Get-VMTemplateSummary {
    <#
      The VM's configuration as first built (OriginalConfig: the path of its
      VM.Template.json), and its green template, the <VM>-latest config
      template LazyVM keeps up to date with every change to the VM
      (GreenTemplate: its name; GreenTemplateUpdated: when it last changed).
      Each empty when its file does not exist.
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name
    )

    $summary = [pscustomobject]@{ OriginalConfig = $null; GreenTemplate = $null; GreenTemplateUpdated = $null }
    $asBuilt = Get-VMAsBuiltProfilePath -Root $Root -Name $Name
    if (Test-Path -LiteralPath $asBuilt -PathType Leaf) { $summary.OriginalConfig = $asBuilt }

    $greenName = Get-AutomaticTemplateName -Name $Name
    $green = Get-Item -LiteralPath (Get-UserTemplatePath -Root $Root -TemplateName $greenName) -ErrorAction SilentlyContinue
    if ($green) {
        $summary.GreenTemplate = $greenName
        $summary.GreenTemplateUpdated = $green.LastWriteTime
    }
    return $summary
}
