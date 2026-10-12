function Set-LazyVMRoot {
    <#
    .SYNOPSIS
    Chooses the folder LazyVM keeps everything in on this host.

    .DESCRIPTION
    Every VM's disks, the ISO and installers, logs, encrypted passwords,
    captured state and your settings live under one folder, the LazyVM
    folder. Set-LazyVMRoot records it once, in the registry, for every later
    command and for the scheduled tasks.

    The folder is created if needed, along with Config\LazyVM.Settings.json
    (your settings) and a copy of the settings schema beside it, so VS Code
    can offer autocomplete and check the file as you type.

    Upgrading from LazyVM 1.x: point this at the folder that held the 1.x
    kit, the one with Scripts in it. Its settings, VM profiles, tooling lists
    and tooling history are converted and copied into the new Config folder.
    Nothing existing is overwritten and the old files are left as they are.
    Daily maintenance tasks registered by 1.x are registered again so they
    run the new commands, and credentials and tasks a VM from MsDevVM, the
    version before 1.x, kept under its own names are carried across.

    .PARAMETER Path
    A folder on a local drive, such as D:\DevVM. Not the top of a drive.

    .EXAMPLE
    Set-LazyVMRoot -Path D:\DevVM

    .EXAMPLE
    Set-LazyVMRoot -Path S:\Source\Massokissed.LazyVM-1.0.0

    Upgrades a 1.x kit in place: its VMs, disks and settings carry on where
    they are.

    .OUTPUTS
    LazyVM.Root: the folder, the settings file, and what was brought across
    from 1.x.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('LazyVM.Root')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    Assert-Administrator
    $root = Resolve-SettingsRoot -Path $Path -Source 'the -Path parameter'

    $previous = Get-RegisteredRoot
    if ($previous -and $previous -ne $root) {
        Write-Warning "LazyVM was using $previous. Nothing there is moved: VMs built under it keep their disks there, but LazyVM will now look for VMs in $root."
    }

    if (-not $PSCmdlet.ShouldProcess($root, 'Keep LazyVM''s VMs and settings in this folder')) {
        return
    }

    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    Set-RegisteredRoot -Path $root

    $configDir = Get-ConfigDir -Root $root
    Initialize-ConfigFolder -ConfigDir $configDir
    $imported = Import-LegacyConfiguration -LegacyConfigDir (Join-Path -Path $root -ChildPath 'Scripts\Config') -ConfigDir $configDir

    # Maintenance tasks registered by 1.x still run the old script, some
    # under names LazyVM no longer uses. Each is registered again, under the
    # current name, to run Invoke-LazyVMMaintenance, and an old-named one is
    # then removed, so a VM is never maintained twice.
    $tasksUpdated = @()
    foreach ($vmName in @(Get-VMProfileName -ConfigDir $configDir)) {
        $candidates = @("LazyVM-Maintain-$vmName") + @($imported.LegacyTasks | Where-Object VMName -eq $vmName | ForEach-Object { $_.TaskName })
        $oldTasks = @(
            foreach ($taskName in $candidates) {
                $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if ($task -and (@($task.Actions) | Where-Object { "$($_.Arguments)" -like '*.ps1*' })) { $task }
            }
        )
        if ($oldTasks.Count -eq 0) { continue }

        try {
            $null = Initialize-CommandRun -Title 'Moving the maintenance task to LazyVM 2' -Name $vmName
            Register-RebuildSchedule
            foreach ($oldTask in $oldTasks | Where-Object TaskName -ne $CFG.ScheduleTaskName) {
                Unregister-ScheduledTask -TaskName $oldTask.TaskName -Confirm:$false
                Write-LogEntry "Removed the 1.x task '$($oldTask.TaskName)'; '$($CFG.ScheduleTaskName)' replaces it" 'OK'
            }
            $tasksUpdated += $CFG.ScheduleTaskName
        }
        catch {
            Write-Warning "The maintenance task for '$vmName' still runs LazyVM 1.x: $($_.Exception.Message) Fix that, then run: Register-LazyVMMaintenance -Name $vmName"
        }
        finally {
            Complete-CommandRun
        }
    }

    [pscustomobject]@{
        PSTypeName   = 'LazyVM.Root'
        Root         = $root
        SettingsFile = Join-Path -Path $configDir -ChildPath $script:SettingsFileName
        Imported     = @($imported.Messages)
        TasksUpdated = $tasksUpdated
    }
}
