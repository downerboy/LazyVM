@{
    Id         = 'rebuild'
    Title      = 'Rebuild a VM'
    Command    = 'Invoke-LazyVMRebuild'
    Parameters = @('-Name <VM>', '-SkipCapture  (optional)', '-NoUnattend  (optional)', '-Force  (optional)')
    Summary    = 'Capture, retire the old VM, build a new one, restore, verify. The old Windows disk is deleted only after the new VM builds without problems and passes verification. The data disk, Dev Drive and User disk are never touched.'
    CalledBy   = @{ Name = 'Invoke-LazyVMMaintenance'; Kind = 'command'; Notes = @('no rearms left,', 'or the rearm failed') }
    Covers     = @('Invoke-LazyVMRebuild', 'Invoke-Rebuild')
    Omits      = @{}
    Steps      = @(
        @{
            Function = 'Initialize-CommandRun'
            Area     = 'Common'
            Note     = 'builds the VM context, opens the log and records any hardware change made in Hyper-V'
            Reads    = @(@{ Label = 'settings, VM profile, guest user name'; Kind = 'settings'; Store = 'VM context sources'; Items = @('HKLM:\SOFTWARE\LazyVM  Root', 'Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json', '<VM>\Credentials\guest.cred') })
            Writes   = @(@{ Label = 'run log'; Kind = 'file'; Store = '<VM>\Logs\'; Items = @('<VM>.log  (appended)') })
        }
        @{
            Function = 'Sync-VMProfile'
            Area     = 'Settings'
            Note     = 'fills in any setting VM.json lacks from the shared template'
            Reads    = @(@{ Label = 'shared template'; Kind = 'file'; Store = 'Shared\Config\'; Items = @('LazyVM.Settings.json') })
            Writes   = @(@{ Label = 'complete profile'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json') })
        }
        @{
            Function = 'Invoke-Rebuild'
            Area     = 'Maintenance'
            Note     = 'steps 4-11 are its calls'
        }
        @{
            Function = 'Install-UserDisk'
            Area     = 'Disks'
            Caller   = 'Invoke-Rebuild'
            Note     = 'only if the VM exists: copies the personal folders to the User disk; nothing is retired if it cannot'
            Writes   = @(@{ Label = 'personal folders'; Kind = 'file'; Store = '<VM>\Disks\'; Items = @('<VM>-User.vhdx  (U:)') })
        }
        @{
            Function = 'Save-GuestState'
            Area     = 'Capture'
            Caller   = 'Invoke-Rebuild'
            Note     = 'only if the VM exists, without -SkipCapture (see Capture state)'
            Reads    = @(@{ Label = 'state to keep'; Kind = 'guest'; Store = 'Running guest'; Items = @('VS settings', 'SQL databases + logins', 'env, certs, tasks, apps') })
            Writes   = @(@{ Label = 'captured state'; Kind = 'folder'; Store = '<VM>\State\'; Items = @('Captures\<stamp>\  vs\  windows\', 'manifest.json', 'D:\SQLBackup\<database>.bak') })
        }
        @{
            Function = 'Get-CaptureManifest'
            Area     = 'Capture'
            Caller   = 'Invoke-Rebuild'
            Note     = 'with -SkipCapture: the newest capture instead; stops if there is none'
            Reads    = @(@{ Label = 'last capture'; Kind = 'folder'; Store = '<VM>\State\'; Items = @('manifest.json') })
        }
        @{
            Function = 'Invoke-RetireCurrentVM'
            Area     = 'Maintenance'
            Caller   = 'Invoke-Rebuild'
            Note     = 'only if the VM exists: shuts down, removes checkpoints and the VM definition; keeps the disks'
            Reads    = @(@{ Label = 'old VM'; Kind = 'Hyper-V'; Store = 'VM <VM>'; Items = @('old VM, checkpoints') })
            Writes   = @(@{ Label = 'old Windows disk set aside'; Kind = 'file'; Store = '<VM>\'; Items = @('Disks\<VM>-OS.retired-<stamp>.vhdx', 'Virtual Machines.retired-<stamp>\', 'Disks\<VM>-Seed.iso deleted') })
        }
        @{
            Function  = 'Invoke-BuildPhase'
            Arguments = '-FromPhase 3'
            Area      = 'Host'
            Caller    = 'Invoke-Rebuild'
            Note      = 'phases 3 to 8 of Build a VM: folders, media, disks (existing ones are kept), a new VM, installs and configuration'
            Reads     = @(@{ Label = 'tooling list'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json  Tooling') })
            Writes    = @(@{ Label = 'new VM'; Kind = 'Hyper-V'; Store = 'VM <VM>'; Items = @('new Disks\<VM>-OS.vhdx', 'old D:, W: and U: attached') })
        }
        @{
            Function = 'Restore-GuestState'
            Area     = 'Restore'
            Caller   = 'Invoke-Rebuild'
            Note     = 'when there is a capture: Windows, VS, SQL, app settings; a failed step does not stop the rest (see Restore state)'
            Reads    = @(@{ Label = 'captured state'; Kind = 'folder'; Store = '<VM>\State\'; Items = @('manifest.json and', 'captured files') })
            Writes   = @(@{ Label = 'restored state'; Kind = 'guest'; Store = 'New guest'; Items = @('state put back') })
        }
        @{
            Function = 'Test-RebuiltVM'
            Area     = 'Maintenance'
            Caller   = 'Invoke-Rebuild'
            Note     = 'VM running and reachable, products, SQL, databases online, D: and W: mounted'
            Reads    = @(
                @{ Label = 'products expected'; Kind = 'file'; Store = '<VM>\Config\'; Items = @('VM.json') }
                @{ Label = 'databases expected'; Kind = 'folder'; Store = '<VM>\State\'; Items = @('manifest.json  Databases') }
            )
        }
        @{
            Function = 'Remove-RetiredVM'
            Area     = 'Maintenance'
            Caller   = 'Invoke-Rebuild'
            Note     = 'only when the build had no problems and verification passed; otherwise the old disk is kept and the log says how to roll back'
            Writes   = @(@{ Label = 'disk space reclaimed'; Kind = 'file'; Store = '<VM>\'; Items = @('Disks\<VM>-OS.retired-<stamp>.vhdx,', 'Virtual Machines.retired-<stamp>\', 'deleted (DeleteRetiredDiskOnSuccess)') })
        }
    )
}
