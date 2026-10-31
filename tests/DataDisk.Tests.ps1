# DataDisk.Tests.ps1
# Finding the SQL data disk and the Dev Drive in the guest. The guest step
# initialises and formats the disk it finds, so it must find it by the
# identity VM.json records (GPT disk GUID, then the SCSI location recorded at
# attach, then the location of its VHDX file), never by size, and stop when
# nothing matches. The guest and Hyper-V are mocked; nothing here touches a
# VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')

    function New-TestDisk {
        <# A disk as the guest's Get-Disk reports it. #>
        param(
            [int]$Number,
            [int]$Lun,
            [string]$Guid = '',
            [long]$SizeGB = 100,
            [switch]$Boot
        )

        return [pscustomobject]@{
            Number         = $Number
            Guid           = $Guid
            Location       = "Integrated : Adapter 0 : Port 0 : Target 0 : LUN $Lun"
            Size           = $SizeGB * 1GB
            IsBoot         = [bool]$Boot
            IsSystem       = [bool]$Boot
            PartitionStyle = if ($Guid) { 'GPT' } else { 'RAW' }
        }
    }

    function New-TestRoot {
        <# A root folder holding one VM, Alpha, whose VM.json is $VMJson. #>
        param([string]$VMJson = '{}')

        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'Shared/Config') -Force | Out-Null
        $configDir = Join-Path -Path $root -ChildPath 'Alpha/Config'
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $configDir -ChildPath 'VM.json') -Value $VMJson
        return $root
    }

    function Read-TestProfile {
        param([Parameter(Mandatory)][string]$Root)
        return Get-Content -LiteralPath (Join-Path -Path $Root -ChildPath 'Alpha/Config/VM.json') -Raw | ConvertFrom-Json -AsHashtable
    }

    $sqlGuid = '{11111111-2222-3333-4444-555555555555}'
    $otherGuid = '{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}'
}

Describe 'Find-GuestDataDisk' {
    BeforeAll {
        # The OS disk, an initialised data disk and a new, empty one. The
        # empty one is the size the old code looked for, so a size match
        # would pick it.
        $osDisk = New-TestDisk -Number 0 -Lun 0 -Boot -SizeGB 120
        $prepared = New-TestDisk -Number 1 -Lun 1 -Guid $sqlGuid -SizeGB 250
        $empty = New-TestDisk -Number 2 -Lun 2 -SizeGB 100
        $disks = @($osDisk, $prepared, $empty)
    }

    It 'finds the disk by its GPT disk GUID first, whatever the locations say' {
        $found = Find-GuestDataDisk -Label 'SQL data disk' -Guid $sqlGuid -Location 2 -FileLocation 2 -Disks $disks

        $found.Disk.Number | Should -Be 1
        $found.FoundBy | Should -BeLike '*GPT disk GUID*'
    }

    It 'matches the GPT disk GUID whatever its case' {
        (Find-GuestDataDisk -Label 'SQL data disk' -Guid $sqlGuid.ToLowerInvariant() -Disks $disks).Disk.Number | Should -Be 1
    }

    It 'finds a new, empty disk by the SCSI location recorded when it was attached' {
        $found = Find-GuestDataDisk -Label 'SQL data disk' -Location 2 -FileLocation 1 -Disks $disks

        $found.Disk.Number | Should -Be 2
        $found.FoundBy | Should -BeLike '*recorded when it was attached (LUN 2)'
    }

    It 'falls back to the recorded location when no disk has the recorded GPT disk GUID' {
        $found = Find-GuestDataDisk -Label 'SQL data disk' -Guid $otherGuid -Location 2 -Disks $disks

        $found.Disk.Number | Should -Be 2
    }

    It 'uses the location of the VHDX file only when nothing else is recorded' {
        $found = Find-GuestDataDisk -Label 'SQL data disk' -FileLocation 1 -Disks $disks

        $found.Disk.Number | Should -Be 1
        $found.FoundBy | Should -BeLike '*of its VHDX file (LUN 1)'
    }

    It 'goes on to the VHDX file when no disk is at the recorded location' {
        (Find-GuestDataDisk -Label 'SQL data disk' -Location 9 -FileLocation 2 -Disks $disks).Disk.Number | Should -Be 2
    }

    It 'reads the LUN from Get-PhysicalDisk when Get-Disk does not give it' {
        $bare = [pscustomobject]@{ Number = 3; Guid = ''; Location = ''; IsBoot = $false; IsSystem = $false }
        # Pester cannot mock the Storage module's CDXML cmdlets; a function of
        # the same name in this scope is found first instead.
        function Get-PhysicalDisk { [pscustomobject]@{ DeviceId = '3'; PhysicalLocation = 'Integrated : Adapter 0 : Port 0 : Target 0 : LUN 5' } }

        (Find-GuestDataDisk -Label 'Dev Drive disk' -Location 5 -Disks @($osDisk, $bare)).Disk.Number | Should -Be 3
    }

    It 'never chooses the boot or system disk' {
        { Find-GuestDataDisk -Label 'SQL data disk' -Location 0 -Disks $disks } | Should -Throw -ExpectedMessage '*was not found*'
    }

    It 'stops, changing nothing, when <Case>' -ForEach @(
        @{ Case = 'nothing is recorded and the file is not attached'; Guid = ''; Location = $null; FileLocation = $null; Message = '*SQL data disk was not found*nothing recorded*Nothing was initialised or formatted*' }
        @{ Case = 'no disk matches anything recorded'; Guid = '{99999999-2222-3333-4444-555555555555}'; Location = 7; FileLocation = 8; Message = '*was not found*SCSI location 7*Nothing was initialised or formatted*' }
        @{ Case = 'the disk at the location has a different GPT disk GUID'; Guid = '{99999999-2222-3333-4444-555555555555}'; Location = 1; FileLocation = $null; Message = '*LUN 1 has the GPT disk GUID*not the SQL data disk*' }
    ) {
        { Find-GuestDataDisk -Label 'SQL data disk' -Guid $Guid -Location $Location -FileLocation $FileLocation -Disks $disks } |
            Should -Throw -ExpectedMessage $Message
    }

    It 'stops when two disks match, rather than choose between them' {
        $twins = @($osDisk, (New-TestDisk -Number 1 -Lun 1 -Guid $sqlGuid), (New-TestDisk -Number 2 -Lun 2 -Guid $sqlGuid))

        { Find-GuestDataDisk -Label 'SQL data disk' -Guid $sqlGuid -Disks $twins } | Should -Throw -ExpectedMessage '*2 disks*cannot tell*'
    }
}

Describe 'Import-GuestHelper' {
    It 'loads the helpers with a block the guest runs itself, so the script block is made in the guest (#106)' {
        Mock -ModuleName $module Invoke-Command { } -RemoveParameterType Session -RemoveParameterValidation Session

        InModuleScope $module { Import-GuestHelper -VM ([VMContext]::new(@{ VMName = 'Alpha' })) }

        Should -Invoke -ModuleName $module Invoke-Command -Times 1 -Exactly -ParameterFilter {
            # A block PowerShell 7 can turn into a command would be worked out
            # on the host, sending the guest a string instead of a script block.
            $converted = $true
            try { $null = $ScriptBlock.GetPowerShell($true, @('function Test-Me { 1 }')) } catch { $converted = $false }
            -not $converted -and $ArgumentList[0] -like '*function Find-GuestDataDisk*'
        }
    }
}

Describe 'Add-VMScsiHardDisk' {
    BeforeEach {
        # NewBox after setup (#103): the OS disk at 0 and the Windows ISO at 1;
        # the answer-file disc's drive at 2 has been removed.
        Mock -ModuleName $module Get-VMDvdDrive { [pscustomobject]@{ ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 1; Path = 'C:\ISO\win.iso' } }
        Mock -ModuleName $module Get-VMHardDiskDrive {
            [pscustomobject]@{ ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 0; Path = 'C:\VM\OS.vhdx' }
        } -ParameterFilter { $null -eq $ControllerLocation }
    }

    It 'chooses the gap a removed DVD drive left' {
        # The DVD drive at 1 was removed; the Windows ISO is at 2 and a data disk at 3.
        Mock -ModuleName $module Get-VMDvdDrive { [pscustomobject]@{ ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 2; Path = 'C:\ISO\win.iso' } }
        Mock -ModuleName $module Get-VMHardDiskDrive {
            [pscustomobject]@{ ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 0; Path = 'C:\VM\OS.vhdx' }
            [pscustomobject]@{ ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 3; Path = 'C:\VM\SQL.vhdx' }
        } -ParameterFilter { $null -eq $ControllerLocation }
        Mock -ModuleName $module Add-VMHardDiskDrive { }

        $location = InModuleScope $module { Add-VMScsiHardDisk -VMName 'NewBox' -Path 'C:\VM\DevDrive.vhdx' }

        $location | Should -Be 1
        Should -Invoke -ModuleName $module Add-VMHardDiskDrive -Times 1 -Exactly -ParameterFilter { $ControllerLocation -eq 1 -and $Path -eq 'C:\VM\DevDrive.vhdx' }
    }

    It 'goes on when Hyper-V attaches the disk but then fails to describe it' {
        Mock -ModuleName $module Add-VMHardDiskDrive { throw "Unable to cast object of type 'Microsoft.HyperV.PowerShell.DvdDrive' to type 'Microsoft.HyperV.PowerShell.HardDiskDrive'." }
        Mock -ModuleName $module Get-VMHardDiskDrive {
            [pscustomobject]@{ ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 2; Path = 'C:\VM\SQL.vhdx' }
        } -ParameterFilter { $ControllerLocation -eq 2 }

        $location = InModuleScope $module { Add-VMScsiHardDisk -VMName 'NewBox' -Path 'C:\VM\SQL.vhdx' }

        $location | Should -Be 2
        Should -Invoke -ModuleName $module Add-VMHardDiskDrive -Times 1 -Exactly -ParameterFilter { $ControllerLocation -eq 2 }
    }

    It 'stops when the disk is not attached after all' {
        Mock -ModuleName $module Add-VMHardDiskDrive { throw 'Hyper-V said no' }
        Mock -ModuleName $module Get-VMHardDiskDrive { } -ParameterFilter { $ControllerLocation -eq 2 }

        { InModuleScope $module { Add-VMScsiHardDisk -VMName 'NewBox' -Path 'C:\VM\SQL.vhdx' } } | Should -Throw -ExpectedMessage 'Hyper-V said no'
    }

    It 'stops when another disk is at that location' {
        Mock -ModuleName $module Add-VMHardDiskDrive { throw 'Hyper-V said no' }
        Mock -ModuleName $module Get-VMHardDiskDrive {
            [pscustomobject]@{ ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 2; Path = 'C:\VM\Other.vhdx' }
        } -ParameterFilter { $ControllerLocation -eq 2 }

        { InModuleScope $module { Add-VMScsiHardDisk -VMName 'NewBox' -Path 'C:\VM\SQL.vhdx' } } | Should -Throw -ExpectedMessage 'Hyper-V said no'
    }
}

Describe 'Add-VMDataDisk' {
    It 'takes a disk a checkpoint has wrapped in a differencing disk as attached already (#191)' {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Add-VMScsiHardDisk { 5 }
        Mock -ModuleName $module Update-VMProfile { }
        Mock -ModuleName $module Start-Sleep { }
        Mock -ModuleName $module Get-VMHardDiskDrive { [pscustomobject]@{ ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 4; Path = 'C:\VM\User_3F0A.avhdx' } }
        Mock -ModuleName $module Get-VHD { [pscustomobject]@{ Path = $Path; ParentPath = 'C:\VM\User.vhdx' } } -ParameterFilter { $Path -eq 'C:\VM\User_3F0A.avhdx' }
        Mock -ModuleName $module Get-VHD { [pscustomobject]@{ Path = $Path; ParentPath = '' } } -ParameterFilter { $Path -eq 'C:\VM\User.vhdx' }

        InModuleScope $module {
            Add-VMDataDisk -VM ([VMContext]::new(@{ VMName = 'testvm'; Root = 'C:\LazyVM' })) -Path 'C:\VM\User.vhdx' -Label 'User disk' -LocationSetting 'UserDiskScsiLocation'
        }

        Should -Invoke -ModuleName $module Add-VMScsiHardDisk -Times 0
    }
}

Describe 'Refusing a data disk another VM owns (#138)' {
    BeforeAll {
        function Add-TestVM {
            <# Adds a VM named $Name, whose VM.json is $VMJson, to the root folder. #>
            param(
                [Parameter(Mandatory)][string]$Root,
                [Parameter(Mandatory)][string]$Name,
                [string]$VMJson = '{}'
            )

            $configDir = Join-Path -Path $Root -ChildPath "$Name/Config"
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $configDir -ChildPath 'VM.json') -Value $VMJson
        }
    }

    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Test-Unattended { $false }
        Mock -ModuleName $module Start-Sleep { }
        Mock -ModuleName $module Get-VMHardDiskDrive { }
        Mock -ModuleName $module Add-VMScsiHardDisk { 3 }
        Mock -ModuleName $module Mount-VHD { [pscustomobject]@{ Path = $Path; DiskNumber = 7 } }
        Mock -ModuleName $module Dismount-VHD { }
    }

    It 'refuses a disk whose GPT disk GUID another VM records as its <Setting>, and does not attach it' -ForEach @(
        @{ Setting = 'SQLDiskGuid' }
        @{ Setting = 'DevDriveGuid' }
        @{ Setting = 'UserDiskGuid' }
    ) {
        $root = New-TestRoot
        Add-TestVM -Root $root -Name 'Beta' -VMJson "{ `"$Setting`": `"$sqlGuid`" }"
        Mock -ModuleName $module Get-Disk { [pscustomobject]@{ Number = 7; Guid = $sqlGuid.ToLowerInvariant() } }

        { InModuleScope $module -Parameters @{ Root = $root } {
                param($Root)
                $vm = [VMContext]::new(@{ VMName = 'Alpha'; Root = $Root; InstallSqlServer = $true; SQLDiskPath = "$Root\Beta\Disks\Beta-SQL.vhdx" })
                Add-SqlDataDisk -VM $vm
            } } | Should -Throw -ExpectedMessage "*belongs to the VM 'Beta'*"

        Should -Invoke -ModuleName $module Add-VMScsiHardDisk -Times 0
    }

    It 'attaches a disk whose GPT disk GUID only this VM records, as after a rebuild' {
        $root = New-TestRoot -VMJson "{ `"SQLDiskGuid`": `"$sqlGuid`" }"
        Add-TestVM -Root $root -Name 'Beta' -VMJson "{ `"SQLDiskGuid`": `"$otherGuid`" }"
        Mock -ModuleName $module Get-Disk { [pscustomobject]@{ Number = 7; Guid = $sqlGuid } }

        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            $vm = [VMContext]::new(@{ VMName = 'Alpha'; Root = $Root; InstallSqlServer = $true; SQLDiskPath = "$Root\Alpha\Disks\Alpha-SQL.vhdx" })
            Add-SqlDataDisk -VM $vm
        }

        Should -Invoke -ModuleName $module Add-VMScsiHardDisk -Times 1
    }

    It 'attaches a new disk that has no GPT disk GUID yet' {
        $root = New-TestRoot
        Add-TestVM -Root $root -Name 'Beta' -VMJson "{ `"SQLDiskGuid`": `"$otherGuid`" }"
        Mock -ModuleName $module Get-Disk { [pscustomobject]@{ Number = 7; Guid = '' } }

        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            $vm = [VMContext]::new(@{ VMName = 'Alpha'; Root = $Root; InstallSqlServer = $true; SQLDiskPath = "$Root\Alpha\Disks\Alpha-SQL.vhdx" })
            Add-SqlDataDisk -VM $vm
        }

        Should -Invoke -ModuleName $module Add-VMScsiHardDisk -Times 1
    }

    It 'dismounts the disk on the host once its GPT disk GUID is read' {
        $root = New-TestRoot
        Mock -ModuleName $module Get-Disk { throw 'the disk vanished' }

        { InModuleScope $module -Parameters @{ Root = $root } {
                param($Root)
                $vm = [VMContext]::new(@{ VMName = 'Alpha'; Root = $Root; InstallSqlServer = $true; SQLDiskPath = "$Root\Alpha\Disks\Alpha-SQL.vhdx" })
                Add-SqlDataDisk -VM $vm
            } } | Should -Throw

        Should -Invoke -ModuleName $module Dismount-VHD -Times 1
    }

    It 'refuses to attach a disk whose GPT disk GUID cannot be read' {
        $root = New-TestRoot
        Mock -ModuleName $module Mount-VHD { throw 'The process cannot access the file because it is being used by another process.' }

        { InModuleScope $module -Parameters @{ Root = $root } {
                param($Root)
                $vm = [VMContext]::new(@{ VMName = 'Alpha'; Root = $Root; InstallSqlServer = $true; SQLDiskPath = "$Root\Alpha\Disks\Alpha-SQL.vhdx" })
                Add-SqlDataDisk -VM $vm
            } } | Should -Throw

        Should -Invoke -ModuleName $module Add-VMScsiHardDisk -Times 0
    }
}

Describe 'Recording a data disk''s identity' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-GuestNote { }
        Mock -ModuleName $module Test-Unattended { $false }
        Mock -ModuleName $module Start-Sleep { }
        # A new disk, which has no GPT disk GUID for another VM to own.
        Mock -ModuleName $module Mount-VHD { [pscustomobject]@{ Path = $Path; DiskNumber = 7 } }
        Mock -ModuleName $module Get-Disk { [pscustomobject]@{ Number = 7; Guid = '' } }
        Mock -ModuleName $module Dismount-VHD { }
    }

    It 'records the SCSI location the host attached the disk at' {
        $root = New-TestRoot
        Mock -ModuleName $module Get-VMHardDiskDrive { }
        Mock -ModuleName $module Add-VMScsiHardDisk { 3 }

        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            $vm = [VMContext]::new(@{ VMName = 'Alpha'; Root = $Root; InstallSqlServer = $true; SQLDiskPath = "$Root\Alpha\Disks\Alpha-SQL.vhdx" })
            Add-SqlDataDisk -VM $vm
        }

        (Read-TestProfile -Root $root).SQLDiskScsiLocation | Should -Be 3
    }

    It 'records nothing for a disk that was already attached' {
        $root = New-TestRoot
        $path = "$root\Alpha\Disks\Alpha-SQL.vhdx"
        Mock -ModuleName $module Get-VMHardDiskDrive { [pscustomobject]@{ Path = $path; ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 1 } }
        Mock -ModuleName $module Add-VMScsiHardDisk { throw 'must not run' }

        InModuleScope $module -Parameters @{ Root = $root; Path = $path } {
            param($Root, $Path)
            $vm = [VMContext]::new(@{ VMName = 'Alpha'; Root = $Root; InstallSqlServer = $true; SQLDiskPath = $Path })
            Add-SqlDataDisk -VM $vm
        }

        (Read-TestProfile -Root $root).Keys | Should -Not -Contain 'SQLDiskScsiLocation'
    }

    It 'gives the guest what VM.json records now, and the VHDX file''s location on SCSI controller 0' {
        $root = New-TestRoot -VMJson '{ "SQLDiskScsiLocation": 2 }'
        $path = "$root\Alpha\Disks\Alpha-SQL.vhdx"
        Mock -ModuleName $module Get-VMHardDiskDrive {
            [pscustomobject]@{ Path = $path; ControllerType = 'SCSI'; ControllerNumber = 1; ControllerLocation = 0 }
            [pscustomobject]@{ Path = $path; ControllerType = 'SCSI'; ControllerNumber = 0; ControllerLocation = 4 }
        }

        $identity = InModuleScope $module -Parameters @{ Root = $root; Path = $path } {
            param($Root, $Path)
            # Loaded before the location was recorded, as in a first build.
            $vm = [VMContext]::new(@{ VMName = 'Alpha'; Root = $Root; SQLDiskPath = $Path })
            Get-DataDiskIdentity -VM $vm -GuidSetting 'SQLDiskGuid' -LocationSetting 'SQLDiskScsiLocation' -Path $Path
        }

        $identity.Guid | Should -BeNullOrEmpty
        $identity.Location | Should -Be 2
        $identity.FileLocation | Should -Be 4
    }

    It 'writes the GPT disk GUID back to VM.json once the guest has prepared the <Label>' -ForEach @(
        @{ Label = 'SQL data disk'; Function = 'Initialize-GuestSqlDisk'; Setting = 'SQLDiskGuid'; LocationSetting = 'SQLDiskScsiLocation' }
        @{ Label = 'Dev Drive'; Function = 'Initialize-GuestDevDrive'; Setting = 'DevDriveGuid'; LocationSetting = 'DevDriveScsiLocation' }
        @{ Label = 'User disk'; Function = 'Initialize-GuestUserDisk'; Setting = 'UserDiskGuid'; LocationSetting = 'UserDiskScsiLocation' }
    ) {
        $root = New-TestRoot -VMJson "{ `"$LocationSetting`": 2 }"
        Mock -ModuleName $module Get-VMHardDiskDrive { }
        Mock -ModuleName $module Invoke-GuestScript {
            [pscustomobject]@{ Letter = 'D'; Formatted = $true; Guid = '{abcdef01-2222-3333-4444-555555555555}'; FileSystem = 'ReFS'; Trusted = $true; SizeGB = 100; FreeGB = 100; Notes = @() }
        }

        InModuleScope $module -Parameters @{ Root = $root; Function = $Function } {
            param($Root, $Function)
            $vm = [VMContext]::new(@{
                    VMName = 'Alpha'; Root = $Root; InstallSqlServer = $true; UseDevDrive = $true; DevDriveLetter = 'W'; DevDriveLabel = 'DevDrive'; DevDriveFilters = @()
                    GuestDataDriveLetter = 'D'; SqlDataFolder = 'SQLData'; SqlLogFolder = 'SQLLog'; SqlTempFolder = 'SQLTemp'; SqlBackupFolder = 'SQLBackup'
                    SQLDiskPath = "$Root\Alpha\Disks\Alpha-SQL.vhdx"; DevDrivePath = "$Root\Alpha\Disks\Alpha-DevDrive.vhdx"
                    UserDiskPath = "$Root\Alpha\Disks\Alpha-User.vhdx"; UserDiskLetter = 'U'
                })
            & $Function -VM $vm
        }

        $vmProfile = Read-TestProfile -Root $root
        $vmProfile[$Setting] | Should -Be '{ABCDEF01-2222-3333-4444-555555555555}'
        $vmProfile[$LocationSetting] | Should -Be 2
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { $ArgumentList[2] -eq 2 }
    }

    It 'writes nothing when the guest reports no GPT disk GUID' {
        $root = New-TestRoot -VMJson '{ "SQLDiskScsiLocation": 2 }'
        $before = Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json') -Raw

        InModuleScope $module -Parameters @{ Root = $root } {
            param($Root)
            $vm = [VMContext]::new(@{ VMName = 'Alpha'; Root = $Root })
            Save-DataDiskGuid -VM $vm -GuidSetting 'SQLDiskGuid' -Guid '' -Label 'SQL data disk'
        }

        Get-Content -LiteralPath (Join-Path -Path $root -ChildPath 'Alpha/Config/VM.json') -Raw | Should -Be $before
    }
}
