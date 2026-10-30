# Capture.Tests.ps1
# Each state capture goes to a folder of its own under StateDir\Captures, so
# the last three can be gone back to; older ones are pruned, and restore
# reads the newest (#21). The guest is mocked; nothing here touches a VM.

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
