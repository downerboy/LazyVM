@{
    Id         = 'remove'
    Title      = 'Remove a VM'
    Command    = 'Remove-LazyVM'
    Parameters = @('-Name <VM>', '-WhatIf  (lists everything)', '-Force  (optional)')
    Summary    = 'Deletes the VM and everything created for it, Dev Drive and User disk included. Anything another VM also uses is kept and listed with the reason.'
    Covers     = @('Remove-LazyVM', 'Invoke-VMRemoval')
    Omits      = @{
        'Test-PathWithin' = 'a path test used to sort what to delete'
        'Write-LogList'   = 'writes what is left to the log'
        'Format-Size'     = 'formats sizes for the log'
    }
    Steps      = @(
        @{
            Function = 'Initialize-CommandRun'
            Area     = 'Common'
            Note     = 'builds the VM context and opens the log'
            Reads    = @(
                @{ Label = 'settings, VM profile, guest user name'; Kind = 'settings'; Store = 'VM context sources'; Items = @('HKLM:\SOFTWARE\LazyVM  Root', 'Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json', '<VM>\Credentials\guest.cred') }
            )
            Writes   = @(
                @{ Label = 'run log'; Kind = 'file'; Store = '<VM>\Logs\'; Items = @('<VM>.log  (appended)') }
            )
        }
        @{
            Function = 'Get-VMRemovalContext'
            Area     = 'Maintenance'
            Note     = 'Get-VMRemovalPlan decides what to delete and keep; lists it with sizes'
            Reads    = @(
                @{ Label = 'other VMs'' paths'; Kind = 'file'; Store = '*\Config\'; Items = @('other VMs'' VM.json') }
                @{ Label = 'attached disks'; Kind = 'Hyper-V'; Store = 'Hyper-V'; Items = @('disks of <VM>', 'disks of other VMs') }
            )
            Writes   = @(
                @{ Label = 'removal list'; Kind = 'output'; Store = 'Log and screen'; Items = @('what will be deleted', 'what is kept', 'and why') }
            )
        }
        @{
            Function = 'Invoke-VMRemoval'
            Area     = 'Maintenance'
            Note     = 'after you confirm; stops at the VM if it cannot be removed'
            Writes   = @(
                @{ Label = 'tasks deleted'; Kind = 'task'; Store = 'Task Scheduler'; Items = @('LazyVM-Maintain-<VM>', 'LazyVM-ResumeAfterReboot-<VM>') }
                @{ Label = 'registry key deleted'; Kind = 'registry'; Store = 'HKLM:\SOFTWARE\LazyVM\<VM>'; Items = @('deleted') }
                @{ Label = 'VM deleted'; Kind = 'Hyper-V'; Store = 'Hyper-V'; Items = @('VM <VM> turned off', 'removed') }
            )
        }
        @{
            Function = 'Remove-PathWithRetry'
            Area     = 'Maintenance'
            Caller   = 'Invoke-VMRemoval'
            Note     = 'what is outside the VM folder first, then the folder; the log goes last, after Stop-Log closes it'
            Includes = @('Stop-Log')
            Writes   = @(
                @{ Label = 'files deleted'; Kind = 'file'; Store = 'Files outside the VM folder'; Items = @('Shared\Credentials\.lazyvm.key if no other VM uses it', 'disks', 'state or backups that a setting put elsewhere; anything another VM uses is kept') }
                @{ Label = 'VM folder deleted'; Kind = 'folder'; Store = 'VM folder'; Items = @('<VM>\ and everything in it: Config', 'Disks', 'Checkpoints', 'State', 'Backups', 'Credentials', 'Logs', 'Virtual Machines; the log last') }
            )
        }
    )
}
