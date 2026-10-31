# BitLocker.Tests.ps1
# BitLocker on C: and on every persistent disk (#175). Each disk's recovery
# password is made on the host and stored, encrypted, before the guest
# encrypts anything with it, so the store always holds a password that
# works. A rebuilt guest unlocks the disks with those passwords, and stops
# when one stays locked. The guest-side helpers run here with the BitLocker
# cmdlets mocked; the guest and Hyper-V are mocked too.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')

    # Stand-ins for the BitLocker module, which a test host may not have, so
    # the helpers' calls can be mocked. They take the parameters the helpers
    # use, and are made from text so the analyzer does not take them for
    # real commands that ignore their parameters.
    $stubs = [ordered]@{
        'Get-BitLockerVolume'        = '$MountPoint'
        'Enable-BitLocker'           = '$MountPoint, [switch]$TpmProtector, [switch]$RecoveryPasswordProtector, $RecoveryPassword, $EncryptionMethod, [switch]$UsedSpaceOnly, [switch]$SkipHardwareTest'
        'Add-BitLockerKeyProtector'  = '$MountPoint, [switch]$RecoveryPasswordProtector, $RecoveryPassword, [switch]$TpmProtector'
        'Resume-BitLocker'           = '$MountPoint'
        'Enable-BitLockerAutoUnlock' = '$MountPoint'
        'Disable-BitLocker'          = '$MountPoint'
        'Unlock-BitLocker'           = '$MountPoint, $RecoveryPassword'
    }
    foreach ($name in $stubs.Keys) { Set-Item -Path "function:script:$name" -Value ([scriptblock]::Create("param($($stubs[$name]))")) }

    function New-TestVolume {
        <# A volume as Get-BitLockerVolume reports it, with a recovery password protector for each of $Protectors, and a TPM protector with -Tpm. #>
        param(
            [string]$Status = 'FullyDecrypted',
            [string]$Lock = 'Unlocked',
            [string[]]$Protectors = @(),
            [bool]$AutoUnlock = $false,
            [string]$Protection = 'On',
            [switch]$Tpm
        )

        $keys = @($Protectors | ForEach-Object { [pscustomobject]@{ KeyProtectorType = 'RecoveryPassword'; RecoveryPassword = $_ } })
        if ($Tpm) { $keys += [pscustomobject]@{ KeyProtectorType = 'Tpm'; RecoveryPassword = '' } }
        return [pscustomobject]@{
            VolumeStatus      = $Status
            LockStatus        = $Lock
            ProtectionStatus  = $Protection
            AutoUnlockEnabled = $AutoUnlock
            KeyProtector      = $keys
        }
    }

    function New-TestRoot {
        <# A root folder holding one VM, Alpha, whose VM.json is $VMJson, and its key folder. #>
        param([string]$VMJson = '{}')

        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'Shared/Config') -Force | Out-Null
        $configDir = Join-Path -Path $root -ChildPath 'Alpha/Config'
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $configDir -ChildPath 'VM.json') -Value $VMJson
        return $root
    }

    function New-TestSetting {
        <# The settings a BitLocker step reads, for a VM under $Root. #>
        param([Parameter(Mandatory)][string]$Root)

        return @{
            VMName            = 'Alpha'
            Root              = $Root
            CredKeyFile       = "$Root\Shared\Credentials\.lazyvm.key"
            BitLockerCredFile = "$Root\Alpha\Credentials\bitlocker.cred"
            SQLDiskPath       = "$Root\Alpha\Disks\Alpha-SQL.vhdx"
            DevDrivePath      = "$Root\Alpha\Disks\Alpha-DevDrive.vhdx"
            UserDiskPath      = "$Root\Alpha\Disks\Alpha-User.vhdx"
            UseDevDrive       = $true
        }
    }

    function Use-MemorySecretStore {
        <#
          The credential store, in memory: the real one needs a key file only
          SYSTEM and Administrators can read. What a test stores lands in
          $script:Secrets, keyed by file.
        #>
        $script:Secrets = @{}
        Mock -ModuleName $module Get-StoredSecretTable { if ($script:Secrets.ContainsKey($Path)) { $script:Secrets[$Path].Clone() } else { @{} } }
        Mock -ModuleName $module Save-StoredSecretTable { $script:Secrets[$Path] = $Secrets.Clone() }
    }

    $password = '111111-222222-333333-444444-555555-666666-777777-888888'
    $sqlGuid = '{11111111-2222-3333-4444-555555555555}'
}

Describe 'New-BitLockerRecoveryPassword' {
    It 'makes 8 groups of 6 digits, each divisible by 11 and no more than 720885, as BitLocker requires' {
        $made = InModuleScope $module { New-BitLockerRecoveryPassword }

        $groups = $made -split '-'
        $groups.Count | Should -Be 8
        foreach ($group in $groups) {
            $group | Should -Match '^\d{6}$'
            [int]$group % 11 | Should -Be 0
            [int]$group | Should -BeLessOrEqual 720885
        }
    }

    It 'makes a different password each time' {
        $first, $second = InModuleScope $module { New-BitLockerRecoveryPassword; New-BitLockerRecoveryPassword }

        $first | Should -Not -Be $second
    }
}

Describe 'Protect-GuestVolume' {
    BeforeEach {
        Mock Get-BitLockerVolume { New-TestVolume -Status 'FullyEncrypted' } -ParameterFilter { $MountPoint -eq $env:SystemDrive }
        Mock Enable-BitLocker { }
        Mock Add-BitLockerKeyProtector { }
        Mock Enable-BitLockerAutoUnlock { }
        Mock Disable-BitLocker { }
        Mock Resume-BitLocker { }
    }

    Context 'when Windows encrypted the volume itself and left protection off (#185)' {
        It 'gives C: a TPM protector, then turns its protection on' {
            Mock Get-BitLockerVolume { New-TestVolume -Status 'FullyEncrypted' -Protection 'Off' -Protectors $password } -ParameterFilter { $MountPoint -eq 'C:' }
            $script:order = @()
            Mock Add-BitLockerKeyProtector { $script:order += 'tpm' } -ParameterFilter { $TpmProtector }
            Mock Resume-BitLocker { $script:order += 'resume' }

            $notes = @(Protect-GuestVolume -MountPoint 'C:' -RecoveryPassword $password -System)

            $script:order | Should -Be @('tpm', 'resume')
            @($notes | Where-Object { $_.Level -eq 'OK' -and $_.Text -like '*protection*on*C:*' }).Count | Should -Be 1
        }

        It 'leaves C: suspended when it already has a TPM protector, since Windows resumes it after the next restart' {
            Mock Get-BitLockerVolume { New-TestVolume -Status 'FullyEncrypted' -Protection 'Off' -Protectors $password -Tpm } -ParameterFilter { $MountPoint -eq 'C:' }

            $null = Protect-GuestVolume -MountPoint 'C:' -RecoveryPassword $password -System

            Should -Invoke Resume-BitLocker -Times 0
            Should -Invoke Add-BitLockerKeyProtector -Times 0
        }

        It 'turns a data volume''s protection on once it has the password and auto-unlock' {
            Mock Get-BitLockerVolume { New-TestVolume -Status 'FullyEncrypted' -Protection 'Off' } -ParameterFilter { $MountPoint -eq 'D:' }
            $script:order = @()
            Mock Add-BitLockerKeyProtector { $script:order += 'password' }
            Mock Enable-BitLockerAutoUnlock { $script:order += 'auto-unlock' }
            Mock Resume-BitLocker { $script:order += 'resume' } -ParameterFilter { $MountPoint -eq 'D:' }

            $null = Protect-GuestVolume -MountPoint 'D:' -RecoveryPassword $password

            $script:order | Should -Be @('password', 'auto-unlock', 'resume')
        }
    }

    It 'encrypts a new data volume''s used space with the recovery password, then turns on auto-unlock' {
        Mock Get-BitLockerVolume { New-TestVolume } -ParameterFilter { $MountPoint -eq 'U:' }

        $null = Protect-GuestVolume -MountPoint 'U:' -RecoveryPassword $password -UsedSpaceOnly

        Should -Invoke Enable-BitLocker -Times 1 -Exactly -ParameterFilter { $RecoveryPasswordProtector -and $RecoveryPassword -eq $password -and $UsedSpaceOnly -and $EncryptionMethod -eq 'XtsAes256' }
        Should -Invoke Enable-BitLockerAutoUnlock -Times 1 -Exactly -ParameterFilter { $MountPoint -eq 'U:' }
    }

    It 'encrypts the whole of a data volume that already holds data' {
        Mock Get-BitLockerVolume { New-TestVolume } -ParameterFilter { $MountPoint -eq 'D:' }

        $null = Protect-GuestVolume -MountPoint 'D:' -RecoveryPassword $password

        Should -Invoke Enable-BitLocker -Times 1 -Exactly -ParameterFilter { -not $UsedSpaceOnly }
    }

    It 'leaves a data volume as it was when C: is not encrypted, since it could not unlock itself' {
        Mock Get-BitLockerVolume { New-TestVolume } -ParameterFilter { $MountPoint -eq $env:SystemDrive }
        Mock Get-BitLockerVolume { New-TestVolume } -ParameterFilter { $MountPoint -eq 'D:' }

        { Protect-GuestVolume -MountPoint 'D:' -RecoveryPassword $password } | Should -Throw -ExpectedMessage '*C: is not encrypted*left as it was*'

        Should -Invoke Enable-BitLocker -Times 0
    }

    It 'turns BitLocker off again when auto-unlock cannot be turned on, and never puts the password in the error' {
        Mock Get-BitLockerVolume { New-TestVolume } -ParameterFilter { $MountPoint -eq 'D:' }
        Mock Enable-BitLockerAutoUnlock { throw 'auto-unlock refused' }

        { Protect-GuestVolume -MountPoint 'D:' -RecoveryPassword $password } | Should -Throw -ExpectedMessage '*auto-unlock refused*turned off again*'

        Should -Invoke Disable-BitLocker -Times 1 -Exactly -ParameterFilter { $MountPoint -eq 'D:' }
        try { Protect-GuestVolume -MountPoint 'D:' -RecoveryPassword $password } catch { $_.Exception.Message | Should -Not -BeLike "*$password*" }
    }

    It 'adds the stored recovery password to an encrypted volume that lacks it, and turns on auto-unlock, as after a rebuild' {
        Mock Get-BitLockerVolume { New-TestVolume -Status 'FullyEncrypted' -Protectors '000000-000000-000000-000000-000000-000000-000000-000000' } -ParameterFilter { $MountPoint -eq 'D:' }

        $null = Protect-GuestVolume -MountPoint 'D:' -RecoveryPassword $password

        Should -Invoke Add-BitLockerKeyProtector -Times 1 -Exactly -ParameterFilter { $RecoveryPassword -eq $password }
        Should -Invoke Enable-BitLockerAutoUnlock -Times 1 -Exactly
        Should -Invoke Enable-BitLocker -Times 0
    }

    It 'changes nothing on a volume that is encrypted, has the password and unlocks itself' {
        Mock Get-BitLockerVolume { New-TestVolume -Status 'FullyEncrypted' -Protectors $password -AutoUnlock $true } -ParameterFilter { $MountPoint -eq 'D:' }

        $null = Protect-GuestVolume -MountPoint 'D:' -RecoveryPassword $password

        Should -Invoke Add-BitLockerKeyProtector -Times 0
        Should -Invoke Enable-BitLockerAutoUnlock -Times 0
        Should -Invoke Enable-BitLocker -Times 0
    }

    It 'gives C: its recovery password first, then encrypts it with the TPM' {
        Mock Get-BitLockerVolume { New-TestVolume } -ParameterFilter { $MountPoint -eq 'C:' }
        $script:order = @()
        Mock Add-BitLockerKeyProtector { $script:order += 'password' }
        Mock Enable-BitLocker { $script:order += 'tpm' } -ParameterFilter { $TpmProtector }

        $null = Protect-GuestVolume -MountPoint 'C:' -RecoveryPassword $password -System -UsedSpaceOnly

        $script:order | Should -Be @('password', 'tpm')
        Should -Invoke Enable-BitLockerAutoUnlock -Times 0
    }

    It 'leaves a volume that is being decrypted as it is, and says so' {
        Mock Get-BitLockerVolume { New-TestVolume -Status 'DecryptionInProgress' } -ParameterFilter { $MountPoint -eq 'D:' }

        $notes = @(Protect-GuestVolume -MountPoint 'D:' -RecoveryPassword $password)

        $notes[0].Level | Should -Be 'WARN'
        Should -Invoke Enable-BitLocker -Times 0
        Should -Invoke Add-BitLockerKeyProtector -Times 0
    }
}

Describe 'Unlock-GuestVolume' {
    BeforeEach {
        Mock Unlock-BitLocker { }
    }

    It 'unlocks a locked volume with its stored recovery password' {
        $script:locked = $true
        Mock Get-BitLockerVolume { New-TestVolume -Status 'FullyEncrypted' -Lock $(if ($script:locked) { 'Locked' } else { 'Unlocked' }) }
        Mock Unlock-BitLocker { $script:locked = $false }

        Unlock-GuestVolume -MountPoint 'D:' -Label 'SQL data disk' -RecoveryPassword $password | Should -BeTrue

        Should -Invoke Unlock-BitLocker -Times 1 -Exactly -ParameterFilter { $RecoveryPassword -eq $password }
    }

    It 'does nothing to a volume that is not locked' {
        Mock Get-BitLockerVolume { New-TestVolume -Status 'FullyEncrypted' }

        Unlock-GuestVolume -MountPoint 'D:' -Label 'SQL data disk' -RecoveryPassword $password | Should -BeFalse

        Should -Invoke Unlock-BitLocker -Times 0
    }

    It 'stops when <Case>' -ForEach @(
        @{ Case = 'no recovery password is stored'; Stored = ''; Message = '*SQL data disk is locked*no recovery password*' }
        @{ Case = 'the volume stays locked'; Stored = '111111-222222-333333-444444-555555-666666-777777-888888'; Message = '*SQL data disk could not be unlocked*' }
    ) {
        Mock Get-BitLockerVolume { New-TestVolume -Status 'FullyEncrypted' -Lock 'Locked' }

        { Unlock-GuestVolume -MountPoint 'D:' -Label 'SQL data disk' -RecoveryPassword $Stored } | Should -Throw -ExpectedMessage $Message
    }
}

Describe 'Get-OrNewRecoveryPassword' {
    BeforeEach {
        Use-MemorySecretStore
    }

    It 'stores a new recovery password, keyed by the disk''s GUID, before returning it' {
        $root = New-TestRoot

        $made = InModuleScope $module -Parameters @{ Settings = (New-TestSetting -Root $root); Guid = $sqlGuid.ToLowerInvariant() } {
            param($Settings, $Guid)
            Get-OrNewRecoveryPassword -VM ([VMContext]::new($Settings)) -Guid $Guid -Disk 'SQL data disk'
        }

        $stored = InModuleScope $module -Parameters @{ Settings = (New-TestSetting -Root $root) } {
            param($Settings)
            Read-RecoveryPasswordTable -VM ([VMContext]::new($Settings))
        }
        $stored[$sqlGuid].RecoveryPassword | Should -Be $made
        $stored[$sqlGuid].Disk | Should -Be 'SQL data disk'
    }

    It 'returns the password already stored for the disk' {
        $root = New-TestRoot
        $settings = New-TestSetting -Root $root

        $first, $second = InModuleScope $module -Parameters @{ Settings = $settings; Guid = $sqlGuid } {
            param($Settings, $Guid)
            $vm = [VMContext]::new($Settings)
            Get-OrNewRecoveryPassword -VM $vm -Guid $Guid -Disk 'SQL data disk'
            Get-OrNewRecoveryPassword -VM $vm -Guid $Guid -Disk 'SQL data disk'
        }

        $second | Should -Be $first
    }
}

Describe 'Protect-GuestPersistentDisk' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Protect-GuestSystemDrive { }
        Mock -ModuleName $module Protect-GuestDataDisk { }
        $testVM = InModuleScope $module -Parameters @{ Settings = (New-TestSetting -Root 'C:\LazyVM') } { param($Settings) [VMContext]::new($Settings) }
    }

    It 'leaves the data disks as they are when C: cannot be encrypted, and carries on' {
        Mock -ModuleName $module Protect-GuestSystemDrive { throw 'no TPM' }

        { InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Protect-GuestPersistentDisk -VM $VM } } | Should -Not -Throw

        Should -Invoke -ModuleName $module Protect-GuestDataDisk -Times 0
        Should -Invoke -ModuleName $module Write-LogError -Times 1 -Exactly
    }

    It 'goes on to the other disks when one fails, and never stops the run' {
        Mock -ModuleName $module Protect-GuestDataDisk { throw 'refused' } -ParameterFilter { $Disk.Label -eq 'SQL data disk' }

        { InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Protect-GuestPersistentDisk -VM $VM } } | Should -Not -Throw

        Should -Invoke -ModuleName $module Protect-GuestDataDisk -Times 3 -Exactly
        Should -Invoke -ModuleName $module Write-LogError -Times 1 -Exactly
    }

    It 'leaves out the Dev Drive when the VM has none' {
        $settings = New-TestSetting -Root 'C:\LazyVM'
        $settings.UseDevDrive = $false
        $noDevDrive = InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) [VMContext]::new($Settings) }

        InModuleScope $module -Parameters @{ VM = $noDevDrive } { param($VM) Protect-GuestPersistentDisk -VM $VM }

        Should -Invoke -ModuleName $module Protect-GuestDataDisk -Times 2 -Exactly
        Should -Invoke -ModuleName $module Protect-GuestDataDisk -Times 0 -ParameterFilter { $Disk.Label -eq 'Dev Drive disk' }
    }

    It 'encrypts only the used space of a disk formatted in this run, and all of every other' {
        InModuleScope $module -Parameters @{ VM = $testVM } {
            param($VM)
            $VM.Runtime.FormattedDisks += 'UserDiskGuid'
            Protect-GuestPersistentDisk -VM $VM
        }

        Should -Invoke -ModuleName $module Protect-GuestDataDisk -Times 1 -Exactly -ParameterFilter { $UsedSpaceOnly -and $Disk.Label -eq 'User disk' }
        Should -Invoke -ModuleName $module Protect-GuestDataDisk -Times 2 -Exactly -ParameterFilter { -not $UsedSpaceOnly }
    }

    It 'encrypts only the used space of a C: Windows was just installed on' {
        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Protect-GuestPersistentDisk -VM $VM -NewSystemDrive }

        Should -Invoke -ModuleName $module Protect-GuestSystemDrive -Times 1 -Exactly -ParameterFilter { $UsedSpaceOnly }
    }
}

Describe 'Unlock-GuestDataDisk' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Test-Unattended { $false }
        Mock -ModuleName $module Get-VMHardDiskDrive { }
        Mock -ModuleName $module Test-Path { $true } -ParameterFilter { $LiteralPath -like '*.vhdx' }
        Use-MemorySecretStore
    }

    It 'gives the guest each prepared disk''s stored recovery password, and skips a disk not prepared yet' {
        $root = New-TestRoot -VMJson "{ `"SQLDiskGuid`": `"$sqlGuid`", `"SQLDiskScsiLocation`": 1, `"UserDiskScsiLocation`": 3 }"
        $settings = New-TestSetting -Root $root
        $settings.UseDevDrive = $false
        Mock -ModuleName $module Invoke-GuestScript { }

        $stored = InModuleScope $module -Parameters @{ Settings = $settings; Guid = $sqlGuid } {
            param($Settings, $Guid)
            $vm = [VMContext]::new($Settings)
            Get-OrNewRecoveryPassword -VM $vm -Guid $Guid -Disk 'SQL data disk'
            Unlock-GuestDataDisk -VM $vm
        }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter {
            $targets = @($ArgumentList[0])
            $targets.Count -eq 1 -and $targets[0].Label -eq 'SQL data disk' -and $targets[0].RecoveryPassword -eq $stored
        }
    }

    It 'stops when the guest cannot unlock a disk, so nothing is restored onto it' {
        $root = New-TestRoot -VMJson "{ `"SQLDiskGuid`": `"$sqlGuid`" }"
        Mock -ModuleName $module Invoke-GuestScript { throw 'The SQL data disk is locked by BitLocker and LazyVM has no recovery password stored for it.' }

        { InModuleScope $module -Parameters @{ Settings = (New-TestSetting -Root $root) } { param($Settings) Unlock-GuestDataDisk -VM ([VMContext]::new($Settings)) } } |
            Should -Throw -ExpectedMessage '*locked by BitLocker*'
    }
}

Describe 'Get-LazyVMCredential -RecoveryPassword' {
    BeforeEach {
        Mock -ModuleName $module Assert-Administrator { }
        Use-MemorySecretStore
    }

    It 'returns each disk''s recovery password, with the disk it belongs to' {
        $root = New-TestRoot
        $settings = New-TestSetting -Root $root
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = $root } }.GetNewClosure()
        Mock -ModuleName $module Read-VMSetting { [pscustomobject]@{ VMName = 'Alpha'; Settings = $settings } }.GetNewClosure()
        $made = InModuleScope $module -Parameters @{ Settings = $settings; Guid = $sqlGuid } {
            param($Settings, $Guid)
            Get-OrNewRecoveryPassword -VM ([VMContext]::new($Settings)) -Guid $Guid -Disk 'SQL data disk'
        }

        $result = @(Get-LazyVMCredential -Name Alpha -RecoveryPassword)

        $result.Count | Should -Be 1
        $result[0].Disk | Should -Be 'SQL data disk'
        $result[0].DiskGuid | Should -Be $sqlGuid
        $result[0].RecoveryPassword | Should -Be $made
    }

    It 'says so when no recovery password is stored yet' {
        $root = New-TestRoot
        $settings = New-TestSetting -Root $root
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = $root } }.GetNewClosure()
        Mock -ModuleName $module Read-VMSetting { [pscustomobject]@{ VMName = 'Alpha'; Settings = $settings } }.GetNewClosure()

        { Get-LazyVMCredential -Name Alpha -RecoveryPassword } | Should -Throw -ExpectedMessage '*No BitLocker recovery password is stored*'
    }
}
