# AppSettingFiles.Tests.ps1
# The files AppSettingFiles lists, such as the Start menu's pins (#325): read
# and written in the guest by a task under the guest account's limited
# token, never by the administrator (#310, #330), and put back by a build
# as well as a restore. Nothing here needs Hyper-V or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
    $startPins = '%LOCALAPPDATA%\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin'
    $testVM = InModuleScope $module -Parameters @{ File = $startPins } {
        param($File)
        $vm = [VMContext]::new(@{ VMName = 'Alpha'; AppSettingFiles = @(@{ Name = 'Start menu pins'; File = $File; StopProcess = 'StartMenuExperienceHost' }) })
        $vm.Runtime.GuestAdminUser = 'devadmin'
        $vm
    }
}

Describe 'Get-GuestAppSettingFileSnapshot' {
    BeforeEach {
        Mock -ModuleName $module Wait-GuestSignedIn { $true }
        Mock -ModuleName $module Get-GuestTaskOutputFileData { 'AAE=' }
    }

    It 'reads the files with a task as the guest account under its limited token, never as the administrator' {
        Mock -ModuleName $module Invoke-GuestTask { '{"Notes":[],"Failed":[],"Files":[]}' }

        $null = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Get-GuestAppSettingFileSnapshot -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'LazyVM-AppSettingFilesCapture' -and $AsGuestUser -and -not $Elevated -and $InputFile.Contains('AppSettingFiles.ps1')
        }
    }

    It 'takes only a file AppSettingFiles lists, under its listed name, from what the task reports' {
        $report = ConvertTo-Json -Compress -InputObject @{
            Notes = @(); Failed = @()
            Files = @(
                @{ Name = 'Start menu pins'; File = $startPins; Output = 'file0.bin' }
                @{ Name = 'Startup'; File = '%APPDATA%\x\evil.cmd'; Output = 'file1.bin' }
                @{ Name = 'Start menu pins'; File = $startPins; Output = '..\..\SAM' }
            )
        }
        Mock -ModuleName $module Invoke-GuestTask { $report }.GetNewClosure()

        $snapshot = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Get-GuestAppSettingFileSnapshot -VM $VM }

        @($snapshot.Files).Name | Should -Be @('Start menu pins')
        $snapshot.Files[0].Data | Should -Be 'AAE='
        Should -Invoke -ModuleName $module Get-GuestTaskOutputFileData -Times 1 -Exactly -ParameterFilter { $Name -eq 'file0.bin' }
    }

    It 'counts every file as not read when no one is signed in, so what was recorded is kept' {
        Mock -ModuleName $module Wait-GuestSignedIn { $false }
        Mock -ModuleName $module Invoke-GuestTask { }

        $snapshot = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Get-GuestAppSettingFileSnapshot -VM $VM }

        $snapshot.Failed | Should -Be @('Start menu pins')
        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 0 -Exactly
    }

    It 'counts every file as not read when the task fails' {
        Mock -ModuleName $module Invoke-GuestTask { throw 'the task timed out' }

        $snapshot = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Get-GuestAppSettingFileSnapshot -VM $VM }

        $snapshot.Failed | Should -Be @('Start menu pins')
        $snapshot.Notes[0].Level | Should -Be 'WARN'
    }
}

Describe 'Restore-GuestAppSettingFile' {
    BeforeEach {
        Mock -ModuleName $module Wait-GuestSignedIn { $true }
        Mock -ModuleName $module Invoke-GuestTask { '{"Notes":[{"Level":"OK","Text":"restored Start menu pins"}]}' }
        $recorded = @([ordered]@{ Name = 'Start menu pins'; File = $startPins; Data = 'AAE='; StopProcess = 'StartMenuExperienceHost' })
    }

    It 'writes the files with a task as the guest account under its limited token, and returns its notes' {
        $notes = @(InModuleScope $module -Parameters @{ VM = $testVM; Recorded = $recorded } { param($VM, $Recorded) Restore-GuestAppSettingFile -VM $VM -Recorded $Recorded })

        $notes.Text | Should -Be @('restored Start menu pins')
        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'LazyVM-AppSettingFiles' -and $AsGuestUser -and -not $Elevated -and $ArgumentList[0] -match 'StartMenuExperienceHost'
        }
    }

    It 'skips the files with a WARN when no one is signed in' {
        Mock -ModuleName $module Wait-GuestSignedIn { $false }

        $notes = @(InModuleScope $module -Parameters @{ VM = $testVM; Recorded = $recorded } { param($VM, $Recorded) Restore-GuestAppSettingFile -VM $VM -Recorded $Recorded })

        $notes[0].Level | Should -Be 'WARN'
        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 0 -Exactly
    }
}

Describe 'Restore-GuestRecordedAppSetting' {
    BeforeEach {
        Mock -ModuleName $module Write-GuestNote { }
        Mock -ModuleName $module Restore-GuestAppSettingFile { }
        Mock -ModuleName $module Restore-GuestAppSettingValue { }
    }

    It 'puts back the recorded files and registry values, and says the registry values were recorded' {
        Mock -ModuleName $module Get-GuestAppSettingFileRestore { , @([ordered]@{ Name = 'Start menu pins' }) }
        Mock -ModuleName $module Get-GuestAppSettingRestore { [pscustomobject]@{ Keys = @(); Secrets = @{} } }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Restore-GuestRecordedAppSetting -VM $VM })

        $result | Should -Be @($true)
        Should -Invoke -ModuleName $module Restore-GuestAppSettingFile -Times 1 -Exactly
        Should -Invoke -ModuleName $module Restore-GuestAppSettingValue -Times 1 -Exactly
    }

    It 'puts back the files even when no registry values were recorded, and says so, so a restore can use an older capture' {
        Mock -ModuleName $module Get-GuestAppSettingFileRestore { , @([ordered]@{ Name = 'Start menu pins' }) }
        Mock -ModuleName $module Get-GuestAppSettingRestore { $null }

        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Restore-GuestRecordedAppSetting -VM $VM })

        $result | Should -Be @($false)
        Should -Invoke -ModuleName $module Restore-GuestAppSettingFile -Times 1 -Exactly
        Should -Invoke -ModuleName $module Restore-GuestAppSettingValue -Times 0 -Exactly
    }

    It 'does nothing in the guest for a VM that recorded nothing' {
        Mock -ModuleName $module Get-GuestAppSettingFileRestore { $null }
        Mock -ModuleName $module Get-GuestAppSettingRestore { $null }

        $null = InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Restore-GuestRecordedAppSetting -VM $VM }

        Should -Invoke -ModuleName $module Restore-GuestAppSettingFile -Times 0 -Exactly
    }
}

Describe 'Guest.AppSettingFiles.ps1' -Skip:(-not $IsWindows) {
    BeforeAll {
        $script = Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.AppSettingFiles.ps1'
    }

    BeforeEach {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $profileRoot = Join-Path $base 'Users\dev'
        $localAppData = Join-Path $profileRoot 'AppData\Local'
        $appData = Join-Path $profileRoot 'AppData\Roaming'
        $output = Join-Path $base 'Task\Output'
        $elsewhere = Join-Path $base 'Elsewhere'
        foreach ($made in $localAppData, $appData, $output, $elsewhere) { $null = New-Item -ItemType Directory -Path $made -Force }
        $folders = @{ ProfileRoot = $profileRoot; AppData = $appData; LocalAppData = $localAppData }
        $pins = Join-Path $localAppData 'Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin'
        $entries = ConvertTo-Json -Compress -InputObject @(@{ Name = 'Start menu pins'; File = $startPins })
    }

    It 'copies a file that is there into the Output folder and says which' {
        $null = New-Item -ItemType Directory -Path (Split-Path $pins -Parent) -Force
        [IO.File]::WriteAllBytes($pins, [byte[]](1, 2, 3))

        $result = & $script @folders -Entries $entries -OutputFolder $output -MaximumBytes 1KB

        $result.Files[0].Output | Should -Be 'file0.bin'
        [IO.File]::ReadAllBytes((Join-Path $output 'file0.bin')) | Should -Be @(1, 2, 3)
        @($result.Failed) | Should -BeNullOrEmpty
    }

    It 'leaves out a file that is not there yet' {
        $result = & $script @folders -Entries $entries -OutputFolder $output -MaximumBytes 1KB

        @($result.Files) | Should -BeNullOrEmpty
        @($result.Failed) | Should -BeNullOrEmpty
    }

    It 'refuses a file larger than the limit, as not read' {
        $null = New-Item -ItemType Directory -Path (Split-Path $pins -Parent) -Force
        [IO.File]::WriteAllBytes($pins, [byte[]]::new(2KB))

        $result = & $script @folders -Entries $entries -OutputFolder $output -MaximumBytes 1KB

        $result.Failed | Should -Be @('Start menu pins')
        Join-Path $output 'file0.bin' | Should -Not -Exist
    }

    It 'never reads through a link on the way to the file' {
        [IO.File]::WriteAllBytes((Join-Path $elsewhere 'start2.bin'), [byte[]](9))
        $null = New-Item -ItemType Directory -Path (Split-Path (Split-Path $pins -Parent) -Parent) -Force
        $null = New-Item -ItemType SymbolicLink -Path (Split-Path $pins -Parent) -Value $elsewhere

        $result = & $script @folders -Entries $entries -OutputFolder $output -MaximumBytes 1KB

        $result.Failed | Should -Be @('Start menu pins')
        Join-Path $output 'file0.bin' | Should -Not -Exist
    }

    It 'puts a file back, making its folders' {
        $restore = ConvertTo-Json -Compress -InputObject @(@{ Name = 'Start menu pins'; File = $startPins; Data = [Convert]::ToBase64String([byte[]](4, 5)); StopProcess = '' })

        $result = & $script @folders -Entries $restore

        [IO.File]::ReadAllBytes($pins) | Should -Be @(4, 5)
        $result.Notes[0].Level | Should -Be 'OK'
    }

    It 'refuses a file outside the folders it names, such as <Case>' -ForEach @(
        @{ Case = 'one climbing out with ..'; File = '%APPDATA%\..\..\..\..\escaped.bin' }
        @{ Case = 'another environment variable'; File = '%TEMP%\x.bin' }
    ) {
        $restore = ConvertTo-Json -Compress -InputObject @(@{ Name = 'X'; File = $File; Data = 'AAE='; StopProcess = '' })

        $result = & $script @folders -Entries $restore

        $result.Notes[0].Level | Should -Be 'WARN'
        Join-Path $base 'escaped.bin' | Should -Not -Exist
    }
}
