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
    Daily maintenance tasks registered by 1.x are re-registered so they run
    the new commands.

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
    $imported = @(Import-LegacyConfiguration -LegacyConfigDir (Join-Path -Path $root -ChildPath 'Scripts\Config') -ConfigDir $configDir)

    # Maintenance tasks registered by 1.x still run the old script. Each is
    # registered again, so it runs Invoke-LazyVMMaintenance instead.
    $tasksUpdated = @()
    foreach ($vmName in @(Get-VMProfileName -ConfigDir $configDir)) {
        $task = Get-ScheduledTask -TaskName "LazyVM-Maintain-$vmName" -ErrorAction SilentlyContinue
        if (-not $task -or -not (@($task.Actions) | Where-Object { "$($_.Arguments)" -like '*Build-LazyVM.ps1*' })) {
            continue
        }
        try {
            $null = Initialize-CommandRun -Title 'Moving the maintenance task to LazyVM 2' -Name $vmName
            Register-RebuildSchedule
            $tasksUpdated += $task.TaskName
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
        Imported     = $imported
        TasksUpdated = $tasksUpdated
    }
}
