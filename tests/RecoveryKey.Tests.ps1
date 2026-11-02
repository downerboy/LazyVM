# RecoveryKey.Tests.ps1
# Exporting the BitLocker recovery passwords to a file the user keeps
# offline, and the reminders until they are (#286). LazyVM's own copy is in
# its credential store; if that is lost, only the exported file can unlock
# the VMs' disks. The credential store is kept in memory, and the guest,
# Hyper-V and the registry are mocked.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # The guest-side helpers, loaded here as they are into the guest, with a
    # stand-in for the BitLocker cmdlet they call, so it can be mocked.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')
    Set-Item -Path 'function:script:Get-BitLockerVolume' -Value ([scriptblock]::Create('param($MountPoint)'))

    $osGuid = '{AAAAAAAA-0000-0000-0000-000000000001}'
    $sqlGuid = '{BBBBBBBB-0000-0000-0000-000000000002}'
    $osPassword = '111111-222222-333333-444444-555555-666666-777777-888888'
    $sqlPassword = '000011-000022-000033-000044-000055-000066-000077-000088'

    function Use-MemorySecretStore {
        <# The credential store, in memory, so no test writes an encrypted file. What a test stores lands in $script:Secrets, keyed by file. #>
        $script:Secrets = @{}
        Mock -ModuleName $module Get-StoredSecretTable { if ($script:Secrets.ContainsKey($Path)) { $script:Secrets[$Path].Clone() } else { @{} } }
        Mock -ModuleName $module Save-StoredSecretTable { $script:Secrets[$Path] = $Secrets.Clone() }
    }

    function New-TestSetting {
        <# The settings the recovery key functions read, for VM $Name under $Root. #>
        param(
            [Parameter(Mandatory)][string]$Root,
            [string]$Name = 'Alpha'
        )

        return @{
            VMName                = $Name
            Root                  = $Root
            BitLockerCredFile     = Join-Path -Path $Root -ChildPath "$Name/Credentials/bitlocker.cred"
            RecoveryKeyExportFile = Join-Path -Path $Root -ChildPath "$Name/Config/RecoveryKeyExport.json"
        }
    }

    function Add-TestKey {
        <# Stores the recovery password $Recovery for $Name's disk $Guid, with BitLocker's key ID $KeyId when given. #>
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$Guid,
            [Parameter(Mandatory)][string]$Disk,
            [Parameter(Mandatory)][string]$Recovery,
            [string]$KeyId,
            [string]$Name = 'Alpha'
        )

        $path = (New-TestSetting -Root $Root -Name $Name).BitLockerCredFile
        if (-not $script:Secrets.ContainsKey($path)) { $script:Secrets[$path] = @{} }
        $entry = @{ Disk = $Disk; RecoveryPassword = $Recovery; Recorded = '2026-10-01T09:30:00.0000000+00:00' }
        if ($KeyId) { $entry.KeyId = $KeyId }
        $script:Secrets[$path][$Guid] = $entry
    }

    function New-TestVM {
        <# The context of VM $Name under $Root. #>
        param(
            [Parameter(Mandatory)][string]$Root,
            [string]$Name = 'Alpha'
        )

        return InModuleScope $module -Parameters @{ Settings = (New-TestSetting -Root $Root -Name $Name) } { param($Settings) [VMContext]::new($Settings) }
    }

    function New-TestRoot {
        <# An empty LazyVM folder for one test. #>
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }
}

Describe 'Get-StoredRecoveryKey' {
    BeforeEach { Use-MemorySecretStore }

    It 'returns each stored recovery password with its VM, disk, disk GUID, BitLocker key ID and date' {
        $root = New-TestRoot
        Add-TestKey -Root $root -Guid $sqlGuid -Disk 'SQL data disk' -Recovery $sqlPassword -KeyId '{C0FFEE00-0000-0000-0000-000000000000}'
        Add-TestKey -Root $root -Guid $osGuid -Disk 'OS disk' -Recovery $osPassword

        $keys = @(InModuleScope $module -Parameters @{ VM = (New-TestVM -Root $root) } { param($VM) Get-StoredRecoveryKey -VM $VM })

        $keys.Count | Should -Be 2
        $keys[0].Name | Should -Be 'Alpha'
        $keys[0].Disk | Should -Be 'OS disk'
        $keys[0].KeyId | Should -Be ''
        $keys[1].Disk | Should -Be 'SQL data disk'
        $keys[1].DiskGuid | Should -Be $sqlGuid
        $keys[1].KeyId | Should -Be '{C0FFEE00-0000-0000-0000-000000000000}'
        $keys[1].RecoveryPassword | Should -Be $sqlPassword
    }
}

Describe 'Set-RecoveryKeyId' {
    BeforeEach { Use-MemorySecretStore }

    It 'records the key ID BitLocker gave a stored recovery password' {
        $root = New-TestRoot
        Add-TestKey -Root $root -Guid $sqlGuid -Disk 'SQL data disk' -Recovery $sqlPassword

        InModuleScope $module -Parameters @{ VM = (New-TestVM -Root $root); Guid = $sqlGuid.ToLowerInvariant() } {
            param($VM, $Guid)
            Set-RecoveryKeyId -VM $VM -Guid $Guid -KeyId '{C0FFEE00-0000-0000-0000-000000000000}'
        }

        $stored = $script:Secrets[(New-TestSetting -Root $root).BitLockerCredFile][$sqlGuid]
        $stored.KeyId | Should -Be '{C0FFEE00-0000-0000-0000-000000000000}'
        $stored.RecoveryPassword | Should -Be $sqlPassword
    }

    It 'stores nothing when the key ID is <Case>' -ForEach @(
        @{ Case = 'already recorded'; KeyId = '{C0FFEE00-0000-0000-0000-000000000000}' }
        @{ Case = 'not known'; KeyId = '' }
    ) {
        $root = New-TestRoot
        Add-TestKey -Root $root -Guid $sqlGuid -Disk 'SQL data disk' -Recovery $sqlPassword -KeyId '{C0FFEE00-0000-0000-0000-000000000000}'

        InModuleScope $module -Parameters @{ VM = (New-TestVM -Root $root); Guid = $sqlGuid; KeyId = $KeyId } {
            param($VM, $Guid, $KeyId)
            Set-RecoveryKeyId -VM $VM -Guid $Guid -KeyId $KeyId
        }

        Should -Invoke -ModuleName $module Save-StoredSecretTable -Times 0
    }
}

Describe 'Get-GuestRecoveryKeyId' {
    It 'returns the key protector ID of the volume''s protector with that recovery password' {
        Mock Get-BitLockerVolume {
            [pscustomobject]@{
                KeyProtector = @(
                    [pscustomobject]@{ KeyProtectorType = 'Tpm'; KeyProtectorId = '{11111111-0000-0000-0000-000000000000}'; RecoveryPassword = '' }
                    [pscustomobject]@{ KeyProtectorType = 'RecoveryPassword'; KeyProtectorId = '{22222222-0000-0000-0000-000000000000}'; RecoveryPassword = 'another' }
                    [pscustomobject]@{ KeyProtectorType = 'RecoveryPassword'; KeyProtectorId = '{33333333-0000-0000-0000-000000000000}'; RecoveryPassword = $osPassword }
                )
            }
        }

        Get-GuestRecoveryKeyId -MountPoint 'C:' -RecoveryPassword $osPassword | Should -Be '{33333333-0000-0000-0000-000000000000}'
    }

    It 'returns nothing when the volume does not have that recovery password' {
        Mock Get-BitLockerVolume { [pscustomobject]@{ KeyProtector = @() } }

        Get-GuestRecoveryKeyId -MountPoint 'C:' -RecoveryPassword $osPassword | Should -Be ''
    }
}

Describe 'Format-RecoveryKeyExport' {
    It 'lists each key on lines of their own, with the VM, disk, disk GUID, key ID, date and recovery password' {
        $keys = @(
            [pscustomobject]@{ Name = 'Alpha'; Disk = 'OS disk'; DiskGuid = $osGuid; KeyId = '{33333333-0000-0000-0000-000000000000}'; Recorded = '2026-10-01T09:30:00.0000000+00:00'; RecoveryPassword = $osPassword }
            [pscustomobject]@{ Name = 'Alpha'; Disk = 'SQL data disk'; DiskGuid = $sqlGuid; KeyId = ''; Recorded = [datetime]'2026-10-02 10:00'; RecoveryPassword = $sqlPassword }
        )

        $lines = (InModuleScope $module -Parameters @{ Keys = $keys } { param($Keys) Format-RecoveryKeyExport -Keys $Keys }) -split "`r?`n"

        $lines | Should -Contain 'VM: Alpha'
        $lines | Should -Contain '  Disk: OS disk'
        $lines | Should -Contain "  Disk GUID: $osGuid"
        $lines | Should -Contain '  Key ID: {33333333-0000-0000-0000-000000000000}'
        $lines | Should -Contain '  Recorded: 2026-10-01'
        $lines | Should -Contain "  Recovery password: $osPassword"
        $lines | Should -Contain '  Recorded: 2026-10-02'
        @($lines | Where-Object { $_ -like '  Key ID: not known yet*' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -eq 'VM: Alpha' }).Count | Should -Be 1
    }
}

Describe 'Get-UnexportedRecoveryKey' {
    BeforeEach { Use-MemorySecretStore }

    It 'returns every stored key when none has been exported' {
        $root = New-TestRoot
        Add-TestKey -Root $root -Guid $osGuid -Disk 'OS disk' -Recovery $osPassword -KeyId '{33333333-0000-0000-0000-000000000000}'

        $unexported = @(InModuleScope $module -Parameters @{ VM = (New-TestVM -Root $root) } { param($VM) Get-UnexportedRecoveryKey -VM $VM })

        $unexported.Count | Should -Be 1
    }

    It 'returns nothing once the stored keys are recorded as exported, and records no secret' {
        $root = New-TestRoot
        Add-TestKey -Root $root -Guid $osGuid -Disk 'OS disk' -Recovery $osPassword -KeyId '{33333333-0000-0000-0000-000000000000}'
        $vm = New-TestVM -Root $root

        $unexported = @(InModuleScope $module -Parameters @{ VM = $vm } {
                param($VM)
                Save-RecoveryKeyExportRecord -VM $VM -Keys @(Get-StoredRecoveryKey -VM $VM)
                Get-UnexportedRecoveryKey -VM $VM
            })

        $unexported.Count | Should -Be 0
        Get-Content -LiteralPath $vm.Settings.RecoveryKeyExportFile -Raw | Should -Not -BeLike "*$osPassword*"
    }

    It 'returns a key exported before <Case>' -ForEach @(
        @{ Case = 'BitLocker gave it a new key ID'; Guid = '{AAAAAAAA-0000-0000-0000-000000000001}'; KeyId = '{44444444-0000-0000-0000-000000000000}' }
        @{ Case = 'a new disk was encrypted'; Guid = '{BBBBBBBB-0000-0000-0000-000000000002}'; KeyId = '{55555555-0000-0000-0000-000000000000}' }
    ) {
        $root = New-TestRoot
        Add-TestKey -Root $root -Guid $osGuid -Disk 'OS disk' -Recovery $osPassword -KeyId '{33333333-0000-0000-0000-000000000000}'
        $vm = New-TestVM -Root $root
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Save-RecoveryKeyExportRecord -VM $VM -Keys @(Get-StoredRecoveryKey -VM $VM) }
        Add-TestKey -Root $root -Guid $Guid -Disk 'a disk' -Recovery $sqlPassword -KeyId $KeyId

        $unexported = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-UnexportedRecoveryKey -VM $VM })

        $unexported.Count | Should -Be 1
        $unexported[0].KeyId | Should -Be $KeyId
    }

    It 'takes a record it cannot read as nothing exported' {
        $root = New-TestRoot
        Add-TestKey -Root $root -Guid $osGuid -Disk 'OS disk' -Recovery $osPassword
        $vm = New-TestVM -Root $root
        New-Item -ItemType Directory -Path (Split-Path -Path $vm.Settings.RecoveryKeyExportFile -Parent) -Force | Out-Null
        Set-Content -LiteralPath $vm.Settings.RecoveryKeyExportFile -Value 'not json'

        $unexported = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-UnexportedRecoveryKey -VM $VM })

        $unexported.Count | Should -Be 1
    }

    It 'takes a record with an entry it cannot read as nothing exported' {
        $root = New-TestRoot
        Add-TestKey -Root $root -Guid $osGuid -Disk 'OS disk' -Recovery $osPassword
        $vm = New-TestVM -Root $root
        New-Item -ItemType Directory -Path (Split-Path -Path $vm.Settings.RecoveryKeyExportFile -Parent) -Force | Out-Null
        Set-Content -LiteralPath $vm.Settings.RecoveryKeyExportFile -Value '{ "Keys": ["x"] }'

        $unexported = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-UnexportedRecoveryKey -VM $VM })

        $unexported.Count | Should -Be 1
    }
}

Describe 'Get-NoRecoveryKeyMessage' {
    It 'names every VM it is about' {
        InModuleScope $module { Get-NoRecoveryKeyMessage -VMName 'Alpha', 'Beta' } | Should -BeLike "*'Alpha', 'Beta'*"
    }
}

Describe 'Write-RecoveryKeyReminder' {
    BeforeEach {
        Use-MemorySecretStore
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-LogError { }
        Mock -ModuleName $module Test-Unattended { $false }
        InModuleScope $module { Complete-CommandRun -VM $null }
    }

    It 'warns once on screen, and logs to the file only, in one line with the command for every VM' {
        $root = New-TestRoot
        Add-TestKey -Root $root -Guid $osGuid -Disk 'OS disk' -Recovery $osPassword

        $warned = @(InModuleScope $module -Parameters @{ VM = (New-TestVM -Root $root) } { param($VM) Write-RecoveryKeyReminder -VM $VM 3>&1 })

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $FileOnly -and $Level -eq 'WARN' -and $Message -like '*Export-LazyVMRecoveryKey -Path *' -and $Message -notlike "*$osPassword*" }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 0 -ParameterFilter { -not $FileOnly }
        $warned.Count | Should -Be 1
        "$warned" | Should -BeLike '*Export-LazyVMRecoveryKey -Path *'
        "$warned" | Should -Not -BeLike '*-Name*'
        "$warned" | Should -Not -Match '\r|\n'
    }

    It 'only logs in a scheduled run, which nobody sees' {
        Mock -ModuleName $module Test-Unattended { $true }
        $root = New-TestRoot
        Add-TestKey -Root $root -Guid $osGuid -Disk 'OS disk' -Recovery $osPassword

        $warned = @(InModuleScope $module -Parameters @{ VM = (New-TestVM -Root $root) } { param($VM) Write-RecoveryKeyReminder -VM $VM 3>&1 })

        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and -not $FileOnly }
        $warned.Count | Should -Be 0
    }

    It 'reminds again in the same run only when more keys are unexported, and again in the next run' {
        $root = New-TestRoot
        Add-TestKey -Root $root -Guid $osGuid -Disk 'OS disk' -Recovery $osPassword
        $vm = New-TestVM -Root $root

        $first = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Write-RecoveryKeyReminder -VM $VM 3>&1; Write-RecoveryKeyReminder -VM $VM 3>&1 })
        Add-TestKey -Root $root -Guid $sqlGuid -Disk 'SQL data disk' -Recovery $sqlPassword
        $grown = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Write-RecoveryKeyReminder -VM $VM 3>&1 })
        $nextRun = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Complete-CommandRun -VM $null; Write-RecoveryKeyReminder -VM $VM 3>&1 })

        $first.Count | Should -Be 1
        $grown.Count | Should -Be 1
        "$grown" | Should -BeLike '2 *'
        $nextRun.Count | Should -Be 1
    }

    It 'asks for a new export, now that BitLocker''s key ID is known, for a key exported without one' {
        $root = New-TestRoot
        Add-TestKey -Root $root -Guid $osGuid -Disk 'OS disk' -Recovery $osPassword
        $vm = New-TestVM -Root $root
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Save-RecoveryKeyExportRecord -VM $VM -Keys @(Get-StoredRecoveryKey -VM $VM) }
        Add-TestKey -Root $root -Guid $osGuid -Disk 'OS disk' -Recovery $osPassword -KeyId '{33333333-0000-0000-0000-000000000000}'

        $warned = @(InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Write-RecoveryKeyReminder -VM $VM 3>&1 })

        "$warned" | Should -BeLike '*key ID*now known*export again*Export-LazyVMRecoveryKey -Path *'
    }

    It 'says nothing when every key is exported, or none is stored' {
        $root = New-TestRoot

        InModuleScope $module -Parameters @{ VM = (New-TestVM -Root $root) } { param($VM) Write-RecoveryKeyReminder -VM $VM }

        Should -Invoke -ModuleName $module Write-LogEntry -Times 0
    }

    It 'never stops the command it runs in, logging why it could not check' {
        Mock -ModuleName $module Get-StoredSecretTable { throw 'cannot be read' }

        { InModuleScope $module -Parameters @{ VM = (New-TestVM -Root (New-TestRoot)) } { param($VM) Write-RecoveryKeyReminder -VM $VM } } | Should -Not -Throw

        Should -Invoke -ModuleName $module Write-LogError -Times 1 -Exactly
    }
}

Describe 'Write-RunReminder' {
    BeforeEach {
        Use-MemorySecretStore
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Test-Unattended { $false }
        Mock -ModuleName $module Test-MaintenanceTaskMissing { $true }
        InModuleScope $module { Complete-CommandRun -VM $null }
    }

    It 'reminds of an unscheduled maintenance and of unexported keys, once on screen each' {
        $root = New-TestRoot
        Add-TestKey -Root $root -Guid $osGuid -Disk 'OS disk' -Recovery $osPassword

        $warned = @(InModuleScope $module -Parameters @{ VM = (New-TestVM -Root $root) } { param($VM) Write-RunReminder -VM $VM 3>&1 })

        $warned.Count | Should -Be 2
        "$($warned[0])" | Should -BeLike '*Register-LazyVMMaintenance*'
        "$($warned[1])" | Should -BeLike '*Export-LazyVMRecoveryKey*'
        Should -Invoke -ModuleName $module Write-LogEntry -Times 0 -ParameterFilter { -not $FileOnly }
    }

    It 'leaves maintenance run by hand to remind of unexported keys once, not again after BitLocker' {
        $root = New-TestRoot
        Add-TestKey -Root $root -Guid $osGuid -Disk 'OS disk' -Recovery $osPassword

        # Invoke-LazyVMMaintenance: Initialize-CommandRun reminds, then Invoke-DailyMaintenance checks again after BitLocker.
        $warned = @(InModuleScope $module -Parameters @{ VM = (New-TestVM -Root $root) } {
                param($VM)
                Write-RunReminder -VM $VM 3>&1
                Write-RecoveryKeyReminder -VM $VM 3>&1
            })

        @($warned | Where-Object { "$_" -like '*Export-LazyVMRecoveryKey*' }).Count | Should -Be 1
    }
}

Describe 'Get-RecoveryKeyCheck' {
    BeforeEach { Use-MemorySecretStore }

    It 'warns, with the command for every VM, when a key is not exported yet' {
        $root = New-TestRoot
        Add-TestKey -Root $root -Guid $osGuid -Disk 'OS disk' -Recovery $osPassword

        $check = InModuleScope $module -Parameters @{ VM = (New-TestVM -Root $root) } { param($VM) Get-RecoveryKeyCheck -VM $VM }

        $check.Status | Should -Be 'WARN'
        $check.Detail | Should -BeLike '*1 of 1*Export-LazyVMRecoveryKey -Path *'
        $check.Detail | Should -Not -BeLike '*-Name*'
    }

    It 'is OK once every key is exported, decrypting the store once' {
        $root = New-TestRoot
        Add-TestKey -Root $root -Guid $osGuid -Disk 'OS disk' -Recovery $osPassword
        $vm = New-TestVM -Root $root
        InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Save-RecoveryKeyExportRecord -VM $VM -Keys @(Get-StoredRecoveryKey -VM $VM) }

        $check = InModuleScope $module -Parameters @{ VM = $vm } { param($VM) Get-RecoveryKeyCheck -VM $VM }

        $check.Status | Should -Be 'OK'
        # One read above, to make the record, and one by the check.
        Should -Invoke -ModuleName $module Get-StoredSecretTable -Times 2 -Exactly
    }

    It 'is INFO while no key is stored yet' {
        $check = InModuleScope $module -Parameters @{ VM = (New-TestVM -Root (New-TestRoot)) } { param($VM) Get-RecoveryKeyCheck -VM $VM }

        $check.Status | Should -Be 'INFO'
    }

    It 'fails when the stored keys cannot be read' {
        Mock -ModuleName $module Get-StoredSecretTable { throw 'cannot be read' }

        $check = InModuleScope $module -Parameters @{ VM = (New-TestVM -Root (New-TestRoot)) } { param($VM) Get-RecoveryKeyCheck -VM $VM }

        $check.Status | Should -Be 'FAIL'
    }
}

Describe 'Use-RunRoot' {
    It 'checks writes against the LazyVM folder while the script block runs, and stops after, even when it throws' {
        $during, $after = InModuleScope $module {
            try { Use-RunRoot -Root 'C:\LazyVM' -ScriptBlock { $script:seenRoot = $script:RunRoot; throw 'boom' } }
            catch { $null = $_ }
            $script:seenRoot
            "$script:RunRoot"
        }

        $during | Should -Be 'C:\LazyVM'
        $after | Should -Be ''
    }

    It 'gives back the folder and allowed places of a call around it' {
        $inner, $outer, $outerAllowed, $after = InModuleScope $module {
            Use-RunRoot -Root 'C:\Outer' -ScriptBlock {
                $script:RunAllowedPaths = @('E:\Allowed')
                Use-RunRoot -Root 'C:\Inner' -ScriptBlock { $script:RunRoot }
                $script:RunRoot
                , @($script:RunAllowedPaths)
            }
            "$script:RunRoot"
        }

        $inner | Should -Be 'C:\Inner'
        $outer | Should -Be 'C:\Outer'
        $outerAllowed | Should -Be @('E:\Allowed')
        $after | Should -Be ''
    }
}

Describe 'Export-LazyVMRecoveryKey' {
    BeforeEach {
        Use-MemorySecretStore
        $root = New-TestRoot
        $target = Join-Path -Path (New-TestRoot) -ChildPath 'keys.txt'
        Add-TestKey -Root $root -Guid $osGuid -Disk 'OS disk' -Recovery $osPassword -KeyId '{33333333-0000-0000-0000-000000000000}'
        Add-TestKey -Root $root -Guid $sqlGuid -Disk 'SQL data disk' -Recovery $sqlPassword -Name 'Beta'
        Mock -ModuleName $module Assert-Administrator { }
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = $root; Source = 'a test' } }.GetNewClosure()
        Mock -ModuleName $module Get-VMProfileName { 'Alpha', 'Beta' }
        Mock -ModuleName $module Read-VMSetting { [pscustomobject]@{ VMName = $VMName; Settings = (New-TestSetting -Root $Root -Name $VMName) } }
        Mock -ModuleName $module Test-CloudSyncedPath { $false }
    }

    It 'writes the named VM''s keys to the file, records them as exported and returns the file' {
        $file = Export-LazyVMRecoveryKey -Name Alpha -Path $target -WarningAction SilentlyContinue

        $file.FullName | Should -Be $target
        $text = Get-Content -LiteralPath $target -Raw
        $text | Should -BeLike "*$osPassword*"
        $text | Should -Not -BeLike "*$sqlPassword*"
        $unexported = @(InModuleScope $module -Parameters @{ VM = (New-TestVM -Root $root) } { param($VM) Get-UnexportedRecoveryKey -VM $VM })
        $unexported.Count | Should -Be 0
    }

    It 'writes every VM''s keys when no VM is named' {
        Export-LazyVMRecoveryKey -Path $target

        $text = Get-Content -LiteralPath $target -Raw
        $text | Should -BeLike "*$osPassword*"
        $text | Should -BeLike "*$sqlPassword*"
    }

    It 'takes wildcards in -Name' {
        Export-LazyVMRecoveryKey -Name 'B*' -Path $target

        $text = Get-Content -LiteralPath $target -Raw
        $text | Should -BeLike "*$sqlPassword*"
        $text | Should -Not -BeLike "*$osPassword*"
    }

    It 'stops, writing nothing, when a name without wildcards matches no VM' {
        { Export-LazyVMRecoveryKey -Name Alpha, Gamma -Path $target } | Should -Throw -ExpectedMessage "*no VM named 'Gamma'*"
        $target | Should -Not -Exist
    }

    It 'checks its writes in the LazyVM folder for reparse points' {
        $seen = @{}
        Mock -ModuleName $module Save-RecoveryKeyExportRecord { $seen.Root = & (Get-Module LazyVM) { $script:RunRoot } }.GetNewClosure()

        $null = Export-LazyVMRecoveryKey -Name Alpha -Path $target

        $seen.Root | Should -Be $root
        InModuleScope $module { "$script:RunRoot" } | Should -Be ''
    }

    It 'never writes over a file without -Force, even with -WhatIf' {
        Set-Content -LiteralPath $target -Value 'kept'

        { Export-LazyVMRecoveryKey -Name Alpha -Path $target -WhatIf } | Should -Throw -ExpectedMessage '*already exists*-Force*'
        Get-Content -LiteralPath $target -Raw | Should -BeLike 'kept*'
    }

    It 'replaces the file with -Force, warning when -Name leaves other VMs'' keys out of it' {
        Set-Content -LiteralPath $target -Value 'OLD-CONTENT'

        $null = Export-LazyVMRecoveryKey -Name Alpha -Path $target -Force -WarningVariable warnings -WarningAction SilentlyContinue

        Get-Content -LiteralPath $target -Raw | Should -BeLike "*$osPassword*"
        Get-Content -LiteralPath $target -Raw | Should -Not -BeLike '*OLD-CONTENT*'
        "$warnings" | Should -BeLike '*replaced*other VM*removed*'
    }

    It 'replaces the file with -Force without that warning when every VM is exported' {
        Set-Content -LiteralPath $target -Value 'kept'

        $null = Export-LazyVMRecoveryKey -Path $target -Force -WarningVariable warnings -WarningAction SilentlyContinue

        "$warnings" | Should -Not -BeLike '*other VM*'
    }

    It 'says in its help that -Force replaces the file rather than adding to it' {
        ((Get-Help -Name Export-LazyVMRecoveryKey -Parameter Force).Description | Out-String) | Should -BeLike '*replace*not merge*'
    }

    It 'writes and records nothing with -WhatIf' {
        Export-LazyVMRecoveryKey -Name Alpha -Path $target -WhatIf

        $target | Should -Not -Exist
        (New-TestSetting -Root $root).RecoveryKeyExportFile | Should -Not -Exist
    }

    It 'warns when the file would be <Case>, which defeats the purpose' -ForEach @(
        @{ Case = 'inside the LazyVM folder'; InRoot = $true; Synced = $false; Expected = '*LazyVM folder*' }
        @{ Case = 'in OneDrive'; InRoot = $false; Synced = $true; Expected = '*OneDrive*' }
    ) {
        if ($InRoot) { $target = Join-Path -Path $root -ChildPath 'keys.txt' }
        Mock -ModuleName $module Test-CloudSyncedPath { $Synced }.GetNewClosure()

        $null = Export-LazyVMRecoveryKey -Name Alpha -Path $target -WarningVariable warnings -WarningAction SilentlyContinue

        "$warnings" | Should -BeLike $Expected
    }

    It 'stops, writing nothing, when the folder is not there' {
        $missing = Join-Path -Path $TestDrive -ChildPath 'no-such-folder/keys.txt'

        { Export-LazyVMRecoveryKey -Name Alpha -Path $missing } | Should -Throw -ExpectedMessage '*folder*not there*'
    }

    It 'stops when no recovery password is stored yet' {
        $script:Secrets = @{}

        { Export-LazyVMRecoveryKey -Name Alpha -Path $target } | Should -Throw -ExpectedMessage '*No BitLocker recovery password is stored*'
        $target | Should -Not -Exist
    }
}
