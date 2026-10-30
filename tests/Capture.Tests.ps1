# Capture.Tests.ps1
# Each state capture goes to a folder of its own under StateDir\Captures, so
# the last three can be gone back to; older ones are pruned, and restore
# reads the newest (#21). A capture records a fingerprint of what the daily
# records do not cover, and the daily run captures again only when it has
# changed (#20). The guest is mocked; nothing here touches a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    function Invoke-TestCapture {
        <# Captures Alpha's state into $StateDir, stamped $Stamp, with every area mocked. Returns the folder each area was handed. #>
        param([string]$StateDir, [string]$Stamp)

        InModuleScope $module -Parameters @{ StateDir = $StateDir; Stamp = $Stamp } {
            param($StateDir, $Stamp)
            Mock Write-LogEntry {}
            Mock Open-GuestSession { $false }
            Mock Initialize-GuestSqlDisk {}
            $script:testStamp = $Stamp
            Mock Get-Stamp { $script:testStamp }
            Mock Get-GuestIdentity { [pscustomobject]@{ ComputerName = 'ALPHA' } }
            Mock Save-GuestSqlState { $null }
            Mock Save-GuestAppSetting { $null }
            Mock Get-GuestStateFingerprint { [ordered]@{ Certificates = 'AA11'; VisualStudioSettings = 'HASH1' } }
            $script:handed = @{}
            Mock Save-GuestVisualStudioState { $script:handed.VisualStudio = $CaptureDir; $null }
            Mock Save-GuestWindowsState { $script:handed.Windows = $CaptureDir; $null }
            Mock Save-GuestProjectFolder { $script:handed.Projects = $CaptureDir; $null }

            $null = Save-GuestState -VM ([VMContext]::new(@{ VMName = 'Alpha'; StateDir = $StateDir }))
            $script:handed
        }
    }

    function New-TestCaptureFolder {
        param([string]$StateDir, [string[]]$Stamp)
        foreach ($name in $Stamp) { New-Item -ItemType Directory -Path (Join-Path $StateDir "Captures\$name") -Force | Out-Null }
    }
}

Describe 'Save-GuestState capture generations (#21)' {
    BeforeEach {
        $stateDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It 'writes each capture to a folder of its own, with its own manifest, and hands every area that folder' {
        $handed = Invoke-TestCapture -StateDir $stateDir -Stamp '20261029-200000'

        $folder = Join-Path $stateDir 'Captures\20261029-200000'
        Join-Path $folder 'manifest.json' | Should -Exist
        $handed.VisualStudio | Should -Be $folder
        $handed.Windows | Should -Be $folder
        $handed.Projects | Should -Be $folder
    }

    It 'keeps the newest three captures and deletes older ones' {
        New-TestCaptureFolder -StateDir $stateDir -Stamp '20261001-000000', '20261002-000000', '20261003-000000'

        $null = Invoke-TestCapture -StateDir $stateDir -Stamp '20261029-200000'

        @(Get-ChildItem -LiteralPath (Join-Path $stateDir 'Captures') -Directory | Sort-Object Name).Name |
            Should -Be @('20261002-000000', '20261003-000000', '20261029-200000')
    }

    It 'leaves folders that are not captures alone' {
        New-TestCaptureFolder -StateDir $stateDir -Stamp 'notes', '20261001-000000', '20261002-000000', '20261003-000000'

        $null = Invoke-TestCapture -StateDir $stateDir -Stamp '20261029-200000'

        Join-Path $stateDir 'Captures\notes' | Should -Exist
    }

    It 'removes the stamped manifest copies earlier versions left behind' {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $stateDir 'manifest-20261001-000000.json') -Value '{}'

        $null = Invoke-TestCapture -StateDir $stateDir -Stamp '20261029-200000'

        @(Get-ChildItem -LiteralPath $stateDir -Filter 'manifest-*.json' -File).Count | Should -Be 0
    }

    It 'makes the newest capture the one a restore reads' {
        $null = Invoke-TestCapture -StateDir $stateDir -Stamp '20261028-200000'
        $null = Invoke-TestCapture -StateDir $stateDir -Stamp '20261029-200000'

        $manifest = InModuleScope $module -Parameters @{ StateDir = $stateDir } {
            param($StateDir)
            Mock Write-LogEntry {}
            Get-CaptureManifest -VM ([VMContext]::new(@{ VMName = 'Alpha'; StateDir = $StateDir }))
        }

        $manifest.Stamp | Should -Be '20261029-200000'
    }
}

Describe 'Save-GuestState fingerprint (#20)' {
    It 'records the fingerprint of the guest it captured in the manifest' {
        $stateDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))

        $null = Invoke-TestCapture -StateDir $stateDir -Stamp '20261029-200000'

        $manifest = Get-Content -LiteralPath (Join-Path $stateDir 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.Fingerprint.Certificates | Should -Be 'AA11'
        $manifest.Fingerprint.VisualStudioSettings | Should -Be 'HASH1'
    }
}

Describe 'ConvertTo-GuestStateFingerprint (#20)' {
    It 'gives the same fingerprint for the same certificates in any order' {
        $first = InModuleScope $module { ConvertTo-GuestStateFingerprint -Snapshot ([pscustomobject]@{ Thumbprints = @('BB22', 'AA11'); VisualStudioSettingsHash = 'HASH1' }) }
        $second = InModuleScope $module { ConvertTo-GuestStateFingerprint -Snapshot ([pscustomobject]@{ Thumbprints = @('AA11', 'BB22', 'AA11'); VisualStudioSettingsHash = 'HASH1' }) }

        $first.Certificates | Should -Be 'AA11,BB22'
        $second.Certificates | Should -Be $first.Certificates
        $first.VisualStudioSettings | Should -Be 'HASH1'
    }
}

Describe 'Test-GuestStateChanged (#20)' {
    BeforeAll {
        function Invoke-TestCheck {
            <# Whether Alpha's state changed, the newest capture having $Recorded (or there being none) and the guest now reporting $Current. #>
            param([object]$Recorded, [object]$Current, [switch]$NoCapture)

            InModuleScope $module -Parameters @{ Recorded = $Recorded; Current = $Current; NoCapture = [bool]$NoCapture } {
                param($Recorded, $Current, $NoCapture)
                Mock Write-LogEntry {}
                $script:testManifest = if ($NoCapture) { $null } else { $m = [CaptureManifest]::new(); $m.Fingerprint = $Recorded; $m }
                Mock Get-CaptureManifest { $script:testManifest }
                $script:testCurrent = $Current
                Mock Get-GuestStateFingerprint { $script:testCurrent }
                Test-GuestStateChanged -VM ([VMContext]::new(@{ VMName = 'Alpha' }))
            }
        }
        $same = [ordered]@{ Certificates = 'AA11'; VisualStudioSettings = 'HASH1' }
    }

    It 'says changed when the VM has no capture yet' {
        Invoke-TestCheck -NoCapture -Current $same | Should -BeTrue
    }

    It 'says changed when the newest capture has no fingerprint, as one from before #20 does' {
        Invoke-TestCheck -Recorded $null -Current $same | Should -BeTrue
    }

    It 'says changed when a certificate was added or removed' {
        Invoke-TestCheck -Recorded ([pscustomobject]@{ Certificates = 'AA11'; VisualStudioSettings = 'HASH1' }) -Current ([ordered]@{ Certificates = 'AA11,BB22'; VisualStudioSettings = 'HASH1' }) | Should -BeTrue
    }

    It 'says changed when the Visual Studio settings changed' {
        Invoke-TestCheck -Recorded ([pscustomobject]@{ Certificates = 'AA11'; VisualStudioSettings = 'HASH1' }) -Current ([ordered]@{ Certificates = 'AA11'; VisualStudioSettings = 'HASH2' }) | Should -BeTrue
    }

    It 'says unchanged when both fingerprints match the newest capture' {
        Invoke-TestCheck -Recorded ([pscustomobject]@{ Certificates = 'AA11'; VisualStudioSettings = 'HASH1' }) -Current $same | Should -BeFalse
    }
}
