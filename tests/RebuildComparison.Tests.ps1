# RebuildComparison.Tests.ps1
# The comparison the rebuild acceptance test (#39) makes between the guest
# before and after a rebuild from VM.json: snapshots are areas of entries,
# compared as sets, and the hand changes made before capture must still be
# there. Pure functions; nothing here touches Hyper-V or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'Acceptance/RebuildComparison.ps1')
}

Describe 'ConvertTo-SnapshotEntry' {
    It 'keeps a string as it is' {
        ConvertTo-SnapshotEntry -InputObject 'Git.Git' | Should -Be 'Git.Git'
    }

    It 'gives the same entry for the same properties in any order' {
        $first = ConvertTo-SnapshotEntry -InputObject ([pscustomobject]@{ Name = 'A'; Value = '1' })
        $second = ConvertTo-SnapshotEntry -InputObject ([ordered]@{ Value = '1'; Name = 'A' })

        $first | Should -Be $second
    }

    It 'orders the properties of nested objects too' {
        $first = ConvertTo-SnapshotEntry -InputObject @{ Rule = [ordered]@{ Port = 80; Name = 'Web' } }
        $second = ConvertTo-SnapshotEntry -InputObject @{ Rule = [ordered]@{ Name = 'Web'; Port = 80 } }

        $first | Should -Be $second
    }

    It 'tells different values apart' {
        $first = ConvertTo-SnapshotEntry -InputObject @{ Name = 'A'; Value = '1' }
        $second = ConvertTo-SnapshotEntry -InputObject @{ Name = 'A'; Value = '2' }

        $first | Should -Not -Be $second
    }
}

Describe 'Compare-GuestSnapshot' {
    It 'returns nothing when both snapshots hold the same entries in any order' {
        $before = @{ Tooling = @('Git.Git', 'Microsoft.PowerShell'); Databases = @(@{ Name = 'Shop'; Rows = 3 }) }
        $after = @{ Tooling = @('Microsoft.PowerShell', 'Git.Git'); Databases = @([ordered]@{ Rows = 3; Name = 'Shop' }) }

        $result = @(Compare-GuestSnapshot -Before $before -After $after)

        $result | Should -BeNullOrEmpty
    }

    It 'reports an entry the rebuilt guest lost' {
        $result = @(Compare-GuestSnapshot -Before @{ Tooling = @('Git.Git', '7zip.7zip') } -After @{ Tooling = @('Git.Git') })

        $result.Count | Should -Be 1
        $result[0].Area | Should -Be 'Tooling'
        $result[0].Change | Should -Be 'Lost'
        $result[0].Entry | Should -Be '7zip.7zip'
    }

    It 'reports an entry the rebuilt guest gained' {
        $result = @(Compare-GuestSnapshot -Before @{ Tooling = @('Git.Git') } -After @{ Tooling = @('Git.Git', '7zip.7zip') })

        $result.Count | Should -Be 1
        $result[0].Change | Should -Be 'Gained'
        $result[0].Entry | Should -Be '7zip.7zip'
    }

    It 'reports a changed value as one entry lost and one gained' {
        $result = @(Compare-GuestSnapshot -Before @{ UserData = @(@{ Path = 'a.txt'; Hash = 'AA' }) } -After @{ UserData = @(@{ Path = 'a.txt'; Hash = 'BB' }) })

        @($result.Change | Sort-Object) | Should -Be @('Gained', 'Lost')
    }

    It 'reports every entry of an area only one snapshot has' {
        $result = @(Compare-GuestSnapshot -Before @{ Firewall = @('Web', 'Sql') } -After @{})

        @($result | Where-Object { $_.Area -eq 'Firewall' -and $_.Change -eq 'Lost' }).Count | Should -Be 2
    }

    It 'treats an empty area and a missing area alike' {
        $result = @(Compare-GuestSnapshot -Before @{ Firewall = @() } -After @{})

        $result | Should -BeNullOrEmpty
    }

    It 'leaves out the areas it is told to ignore' {
        $result = @(Compare-GuestSnapshot -Before @{ Programs = @('Edge 1') } -After @{ Programs = @('Edge 2') } -IgnoreArea 'Programs')

        $result | Should -BeNullOrEmpty
    }
}

Describe 'Find-MissingHandChange' {
    It 'returns nothing when every hand change is in the snapshot' {
        $snapshot = @{ Tooling = @('Git.Git', '7zip.7zip'); Environment = @(@{ Scope = 'Machine'; Name = 'LAZYVM_E2E'; Value = '39' }) }
        $handChange = @{ Tooling = @('7zip.7zip'); Environment = @(@{ Name = 'LAZYVM_E2E'; Value = '39' }) }

        $result = @(Find-MissingHandChange -Snapshot $snapshot -HandChange $handChange)

        $result | Should -BeNullOrEmpty
    }

    It 'reports a hand change missing from the snapshot' {
        $result = @(Find-MissingHandChange -Snapshot @{ Tooling = @('Git.Git') } -HandChange @{ Tooling = @('7zip.7zip') })

        $result.Count | Should -Be 1
        $result[0].Area | Should -Be 'Tooling'
        $result[0].Entry | Should -Be '7zip.7zip'
    }

    It 'reports a hand change whose value differs in the snapshot' {
        $snapshot = @{ Environment = @(@{ Scope = 'Machine'; Name = 'LAZYVM_E2E'; Value = 'other' }) }

        $result = @(Find-MissingHandChange -Snapshot $snapshot -HandChange @{ Environment = @(@{ Name = 'LAZYVM_E2E'; Value = '39' }) })

        $result.Count | Should -Be 1
    }

    It 'reports a hand change in an area the snapshot does not have' {
        $result = @(Find-MissingHandChange -Snapshot @{} -HandChange @{ Databases = @(@{ Name = 'LazyVMAcceptance' }) })

        $result[0].Area | Should -Be 'Databases'
    }
}
