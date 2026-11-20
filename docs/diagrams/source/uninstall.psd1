@{
    Id         = 'uninstall'
    Title      = 'Uninstall'
    Command    = '.\LazyVM\Install.ps1'
    Parameters = @('-Uninstall')
    External   = $true
    Summary    = 'As administrator. Lists what goes and what stays, and asks first; -Confirm:$false does not ask, and -WhatIf only lists. Unregisters LazyVM''s scheduled tasks on the host, so nothing runs the VMs'' nightly maintenance or security scan, and removes the Start menu shortcut, the app and the module. Keeps the Hyper-V VMs, their disks, your LazyVM folder and the stored passwords and recovery keys: run Remove-LazyVM first to remove a VM fully. Follows no junction or link, and names what it cannot remove without stopping the rest. Uninstall LazyVM.cmd runs the same, as administrator.'
    CalledBy   = @{ Name = 'Uninstall LazyVM.cmd'; Kind = 'double-click'; Notes = @('asks for administrator rights', 'needs PowerShell 7.6') }
    Covers     = @()
    Omits      = @{}
    Steps      = @(
        @{
            Function = 'Get-UninstallPlan'
            External = $true
            Area     = 'Install.ps1'
            Note     = 'what goes and what stays, shown before anything is removed; nothing goes unless you confirm'
            Reads    = @(
                @{ Label = 'LazyVM''s tasks on the host'; Kind = 'task'; Store = 'Task Scheduler'; Items = @('LazyVM-Maintain-<VM>', 'LazyVM-ResumeAfterReboot-<VM>') }
                @{ Label = 'LazyVM folder, named only'; Kind = 'registry'; Store = 'HKCU:\SOFTWARE\LazyVM'; Items = @('Root') }
            )
            Writes   = @(
                @{ Label = 'the list, and the question'; Kind = 'output'; Store = 'Console'; Items = @('Removes: ...', 'Keeps: ...') }
            )
        }
        @{
            Function = 'Unregister-LazyVMHostTask'
            External = $true
            Area     = 'Install.ps1'
            Note     = 'each one listed; one that cannot go is named'
            Writes   = @(
                @{ Label = 'tasks deleted'; Kind = 'task'; Store = 'Task Scheduler'; Items = @('LazyVM-Maintain-<VM>', 'LazyVM-ResumeAfterReboot-<VM>') }
            )
        }
        @{
            Function = 'Remove-InstalledItem'
            External = $true
            Area     = 'Install.ps1'
            Note     = 'a folder is renamed first, so an app that is running is kept whole; nothing that is or holds a link is removed'
            Writes   = @(
                @{ Label = 'shortcut deleted'; Kind = 'file'; Store = 'all-users Start menu'; Items = @('LazyVM.lnk') }
                @{ Label = 'app and module deleted'; Kind = 'folder'; Store = '%ProgramFiles%\LazyVM\'; Items = @('App\', 'Modules\', 'the folder itself, once empty') }
                @{ Label = 'module folder off your PSModulePath'; Kind = 'registry'; Store = 'HKCU:\Environment'; Items = @('PSModulePath') }
            )
        }
    )
}
