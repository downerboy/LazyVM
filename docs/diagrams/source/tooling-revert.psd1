@{
    Id         = 'tooling-revert'
    Title      = 'Return to an earlier tooling version'
    Command    = 'Restore-LazyVMTooling'
    Parameters = @('-Name <VM>', '-RestorePoint yyyyMMdd-HHmmss', '-Force  (optional)')
    Summary    = 'Returns ALL the VM''s disks to that checkpoint, Dev Drive and data disk included. The revert itself can be undone.'
    Covers     = @('Restore-LazyVMTooling', 'Invoke-ToolingRevert')
    Omits      = @{}
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
            Function = 'Invoke-ToolingRevert'
            Area     = 'Tooling'
            Note     = 'steps 3-6 are its calls; stops before changing anything if the checkpoint or its list is missing'
            Includes = @('Get-ToolingCheckpoint', 'Get-CheckpointStamp', 'Get-ProfileTooling', 'Get-ToolingStamp', 'Get-VMProfilePath')
            Reads    = @(
                @{ Label = 'chosen checkpoint'; Kind = 'Hyper-V'; Store = '<VM>\Checkpoints\'; Items = @('"Tooling <stamp>"') }
                @{ Label = 'that version''s list'; Kind = 'file'; Store = '<VM>\Config\History\'; Items = @('VM-<stamp>.json') }
            )
        }
        @{
            Function = 'New-ToolingCheckpoint'
            Arguments = '-SkipPrune'
            Area     = 'Tooling'
            Caller   = 'Invoke-ToolingRevert'
            Note     = 'the current state, so the revert can be undone'
            Writes   = @(@{ Label = 'safety checkpoint'; Kind = 'Hyper-V'; Store = '<VM>\Checkpoints\'; Items = @('"Tooling <now> before revert"') })
        }
        @{
            Function = 'Save-ProfileVersion'
            Area     = 'Settings'
            Caller   = 'Invoke-ToolingRevert'
            Note     = 'keeps VM.json as it is now under the same date-time'
            Reads    = @(@{ Label = 'current profile'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json') })
            Writes   = @(@{ Label = 'current VM.json kept'; Kind = 'file'; Store = '<VM>\Config\History\'; Items = @('VM-<now>.json') })
        }
        @{
            Function = 'Restore-VMSnapshot'
            External = $true
            Area     = 'Hyper-V'
            Caller   = 'Invoke-ToolingRevert'
            Note     = 'after closing the guest session (Remove-GuestSession); starts the VM again if it was running'
            Includes = @('Remove-GuestSession')
            Writes   = @(@{ Label = 'VM returned to that version'; Kind = 'Hyper-V'; Store = 'VM <VM>'; Items = @('every disk back to <stamp>') })
        }
        @{
            Function = 'Restore-ProfileTooling'
            Area     = 'Settings'
            Caller   = 'Invoke-ToolingRevert'
            Note     = 'puts that version''s tooling list back in VM.json'
            Writes   = @(@{ Label = 'tooling list matches the VM'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json  Tooling') })
        }
    )
}
