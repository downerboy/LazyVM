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
    }

    It 'captures no project folders: personal files are on the User disk, which no rebuild touches (#137)' {
        $stateDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))

        $null = Invoke-TestCapture -StateDir $stateDir -Stamp '20261029-200000'

        $manifest = Get-Content -LiteralPath (Join-Path $stateDir 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.PSObject.Properties.Name | Should -Not -Contain 'Projects'
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

Describe 'Save-GuestSqlState (#180)' {
    It 'records no databases, rather than failing, when SQL Server has no user databases' {
        $result = InModuleScope $module {
            Mock Write-LogEntry {}
            Mock Connect-GuestSqlInstance { $true }
            Mock Update-GuestSqlRecord {}
            Mock Invoke-GuestScript { [pscustomobject]@{ Instance = 'MSSQLSERVER'; Version = '17.0'; Edition = 'Developer'; NotMigrated = @() } }
            Mock Backup-GuestUserDatabase {}

            Save-GuestSqlState -VM ([VMContext]::new(@{ VMName = 'Alpha'; InstallSqlServer = $true }))
        }

        @($result.Databases).Count | Should -Be 0
    }
}
Describe 'Save-GuestVisualStudioState reads the user''s files as the user (#330)' {
    BeforeEach {
        $logged = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Write-LogEntry { $logged.Add("$($Level): $Message") }
        Mock -ModuleName $module Write-GuestNote { }
        Mock -ModuleName $module Get-GuestStagingFolder { 'C:\Program Files\LazyVM\Staging' }
        Mock -ModuleName $module Get-GuestVisualStudio { [pscustomobject]@{ DisplayName = 'Visual Studio Community 2026'; Version = '18.0'; ProductLine = '18'; InstanceId = 'a1b2c3d4' } }
        $guest = @{ SettingsFile = 'C:\Users\devadmin\AppData\Local\Microsoft\VisualStudio\18.0_a1b2c3d4\Settings\CurrentSettings.vssettings'; Marker = 'Pending' }
        Mock -ModuleName $module Invoke-GuestScript { [pscustomobject]@{ SettingsFile = $guest.SettingsFile; SettingsMarker = $guest.Marker } }
        # Each file read back holds "fresh <name>".
        Mock -ModuleName $module Invoke-GuestScript { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("fresh $($ArgumentList[1])")) } -ParameterFilter { "$ScriptBlock" -match 'Read-GuestTaskOutputFile' }
        Mock -ModuleName $module Wait-GuestSignedIn { $true }
        $report = @{
            Notes = @(@{ Level = 'WARN'; Text = 'did not capture .gitconfig: planted' })
            Files = @('VisualStudio.vssettings', 'NuGet.Config', 'gitconfig', 'vs-useritems.zip')
        }
        Mock -ModuleName $module Invoke-GuestTask { ConvertTo-Json -InputObject $report -Compress -Depth 4 }
        Mock -ModuleName $module Copy-FromGuest { }
        Mock -ModuleName $module Write-VisualStudioSettingMarker { }
        Mock -ModuleName $module Get-CaptureManifest { $null }

        $guestScript = Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.VisualStudioUserFiles.ps1'
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $captureDir = Join-Path $root 'new'
        $vsDir = Join-Path $captureDir 'vs'
        $null = New-Item -ItemType Directory -Path $root -Force
        $backup = Join-Path $root 'VisualStudio.vssettings'
        Set-Content -LiteralPath $backup -Value 'backup' -NoNewline
        $vmSettings = @{ VMName = 'Alpha'; GuestAdminUser = 'devadmin'; InstallVisualStudio = $true; VSSettingsBackup = $backup }
        $capture = {
            InModuleScope $module -Parameters @{ Settings = $vmSettings; CaptureDir = $captureDir } {
                param($Settings, $CaptureDir) Save-GuestVisualStudioState -VM ([VMContext]::new($Settings)) -CaptureDir $CaptureDir
            }
        }
        # The previous capture, with each file holding "previous <name>".
        $previousDir = Join-Path $root 'old\vs'
        $null = New-Item -ItemType Directory -Path $previousDir -Force
        $previousFiles = [ordered]@{}
        foreach ($file in @(@{ Key = 'Settings'; Name = 'VisualStudio.vssettings' }, @{ Key = 'NuGetConfig'; Name = 'NuGet.Config' }, @{ Key = 'GitConfig'; Name = 'gitconfig' }, @{ Key = 'UserItems'; Name = 'vs-useritems.zip' })) {
            $path = Join-Path $previousDir $file.Name
            Set-Content -LiteralPath $path -Value "previous $($file.Name)" -NoNewline
            $previousFiles[$file.Key] = $path
        }
        $usePrevious = {
            Mock -ModuleName $module Get-CaptureManifest {
                InModuleScope $module -Parameters @{ Files = $previousFiles } { param($Files) $m = [CaptureManifest]::new(); $m.VisualStudio = [pscustomobject]@{ Files = [pscustomobject]$Files }; $m }
            }
        }
        $content = { param([string]$Name) Get-Content -LiteralPath (Join-Path $vsDir $Name) -Raw }
    }

    It 'reads the files with a task under the guest account''s limited token, given only its script and the settings file''s place' {
        $null = & $capture

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'LazyVM-VSUserFilesCapture' -and $AsGuestUser -and -not $Elevated -and
            (@($InputFile.Keys) -join ',') -eq 'VisualStudioUserFiles.ps1' -and $InputFile['VisualStudioUserFiles.ps1'] -eq $guestScript -and
            "$Work" -match "Join-Path \`$TaskFolder 'VisualStudioUserFiles\.ps1'" -and "$Work" -match '-OutputFolder \$TaskOutput' -and
            $ArgumentList[0] -eq '18' -and $ArgumentList[1] -eq $guest.SettingsFile
        }
    }

    It 'reads nothing in the profile as the administrator, and stages nothing' {
        $null = & $capture

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 0 -Exactly -ParameterFilter { "$ScriptBlock" -match '(?i)Copy-Item|NuGet|gitconfig|MyDocuments|Zip|Get-Content|ReadAll' }
        Should -Invoke -ModuleName $module Get-GuestStagingFolder -Times 0 -Exactly
    }

    It 'reads each file the task wrote from its Output folder in the call that checks it, up to 50 MB, into the capture' {
        $result = & $capture

        foreach ($name in $report.Files) {
            Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter {
                "$ScriptBlock" -match 'Read-GuestTaskOutputFile' -and $ArgumentList[0] -eq 'LazyVM-VSUserFilesCapture' -and $ArgumentList[1] -eq $name -and $ArgumentList[2] -eq 50MB
            }
            & $content -Name $name | Should -Be "fresh $name"
        }
        Should -Invoke -ModuleName $module Copy-FromGuest -Times 0 -Exactly
        @($result.Files.Keys) | Should -Be @('Settings', 'NuGetConfig', 'GitConfig', 'UserItems')
        $result.Files['NuGetConfig'] | Should -Be (Join-Path $vsDir 'NuGet.Config')
    }

    It 'reads only the files it knows of that the task says it wrote' {
        $report.Files = @('NuGet.Config', '..\..\Windows\System32\config\SAM', 'other.txt')

        $result = & $capture

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { "$ScriptBlock" -match 'Read-GuestTaskOutputFile' }
        @($result.Files.Keys) | Should -Be @('NuGetConfig')
    }

    It 'leaves out, with a WARN, a file the guest refuses to read, and reads the rest' {
        Mock -ModuleName $module Invoke-GuestScript { throw 'gitconfig is a junction or link' } -ParameterFilter { "$ScriptBlock" -match 'Read-GuestTaskOutputFile' -and $ArgumentList[1] -eq 'gitconfig' }

        $result = & $capture

        @($logged | Where-Object { $_ -like 'WARN:*gitconfig*junction or link*' }).Count | Should -Be 1
        $result.Files.Contains('GitConfig') | Should -BeFalse
        @($result.Files.Keys).Count | Should -Be 3
    }

    It 'logs what the task reported' {
        $null = & $capture

        Should -Invoke -ModuleName $module Write-GuestNote -Times 1 -Exactly -ParameterFilter { @($Notes).Text -contains 'did not capture .gitconfig: planted' }
    }

    It 'starts no task, and says why, when the account is not signed in, and still records Visual Studio' {
        Mock -ModuleName $module Wait-GuestSignedIn { $false }

        $result = & $capture

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 0 -Exactly
        $logged | Should -Contain "WARN:   'devadmin' is not signed in - Visual Studio files not captured"
        $result.DisplayName | Should -Be 'Visual Studio Community 2026'
        $result.Files.Count | Should -Be 0
    }

    It 'logs one WARN, reads nothing and carries on, when <Case>' -ForEach @(
        @{ Case = 'what the task reported cannot be read'; Fails = $false }
        @{ Case = 'the task fails'; Fails = $true }
    ) {
        if ($Fails) { Mock -ModuleName $module Invoke-GuestTask { throw 'Visual Studio files capture failed in the guest: no' } }
        else { Mock -ModuleName $module Invoke-GuestTask { 'not { json' } }

        $result = & $capture

        @($logged | Where-Object { $_ -like 'WARN:*Visual Studio files*' }).Count | Should -Be 1
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 0 -Exactly -ParameterFilter { "$ScriptBlock" -match 'Read-GuestTaskOutputFile' }
        $result.DisplayName | Should -Be 'Visual Studio Community 2026'
    }

    It 'keeps the previous capture''s files, and says so, when <Case>' -ForEach @(
        @{ Case = 'the account is not signed in'; Skip = 'SignedOut' }
        @{ Case = 'the task fails'; Skip = 'Fails' }
        @{ Case = 'what the task reported cannot be read'; Skip = 'Unreadable' }
    ) {
        & $usePrevious
        switch ($Skip) {
            'SignedOut' { Mock -ModuleName $module Wait-GuestSignedIn { $false } }
            'Fails' { Mock -ModuleName $module Invoke-GuestTask { throw 'failed in the guest' } }
            'Unreadable' { Mock -ModuleName $module Invoke-GuestTask { 'not { json' } }
        }

        $result = & $capture

        @($result.Files.Keys) | Should -Be @('Settings', 'NuGetConfig', 'GitConfig', 'UserItems')
        foreach ($key in $previousFiles.Keys) {
            $name = Split-Path -Path $previousFiles[$key] -Leaf
            $result.Files[$key] | Should -Be (Join-Path $vsDir $name)
            & $content -Name $name | Should -Be "previous $name"
            $logged | Should -Contain "INFO:   $name carried forward from the previous capture, as it could not be read this time"
        }
    }

    It 'keeps the previous capture''s copy of a file the guest refused to read, and the fresh copies of the rest' {
        & $usePrevious
        Mock -ModuleName $module Invoke-GuestScript { throw 'too big' } -ParameterFilter { "$ScriptBlock" -match 'Read-GuestTaskOutputFile' -and $ArgumentList[1] -eq 'gitconfig' }

        $result = & $capture

        & $content -Name 'gitconfig' | Should -Be 'previous gitconfig'
        & $content -Name 'NuGet.Config' | Should -Be 'fresh NuGet.Config'
        $result.Files.Contains('GitConfig') | Should -BeTrue
        @($logged | Where-Object { $_ -like 'INFO:*carried forward*' }).Count | Should -Be 1
    }

    It 'carries nothing forward for a file the task did not find, which the user may have removed' {
        & $usePrevious
        $report.Files = @('NuGet.Config')

        $result = & $capture

        @($result.Files.Keys) | Should -Be @('NuGetConfig')
        @($logged | Where-Object { $_ -like '*carried forward*' }) | Should -BeNullOrEmpty
    }

    It 'carries nothing forward, and carries on, when there is no previous capture' {
        Mock -ModuleName $module Wait-GuestSignedIn { $false }

        $result = & $capture

        $result.Files.Count | Should -Be 0
        @($logged | Where-Object { $_ -like '*carried forward*' }) | Should -BeNullOrEmpty
    }

    It 'never refreshes the settings backup from settings carried forward, which may be older than the guest''s' {
        & $usePrevious
        $guest.Marker = 'OLDHASH'
        Mock -ModuleName $module Wait-GuestSignedIn { $false }

        $null = & $capture

        Get-Content -LiteralPath $backup -Raw | Should -Be 'backup'
        Should -Invoke -ModuleName $module Write-VisualStudioSettingMarker -Times 0 -Exactly
    }

    It 'says when Visual Studio has saved no settings yet, and still reads the other files' {
        $guest.SettingsFile = $null

        $null = & $capture

        @($logged | Where-Object { $_ -like 'WARN:*no .vssettings backup found*' }).Count | Should -Be 1
        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter { $ArgumentList[1] -eq '' }
    }
}

Describe 'Guest.VisualStudioUserFiles.ps1 capturing the files as the user (#330)' {
    BeforeAll {
        $userFiles = Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.VisualStudioUserFiles.ps1'
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    }

    BeforeEach {
        # TestDrive lasts for the whole Describe, so each test has a folder of its own.
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $profileRoot = Join-Path $base 'Users\dev'
        $appData = Join-Path $profileRoot 'AppData\Roaming'
        $documents = Join-Path $base 'U\Documents'
        $vsFolder = Join-Path $documents 'Visual Studio 18'
        # Stands for what only an administrator may read.
        $elsewhere = Join-Path $base 'Elsewhere'
        $output = Join-Path $base 'Task\Output'
        foreach ($made in $appData, $documents, $elsewhere, $output) { $null = New-Item -ItemType Directory -Path $made -Force }

        $settingsFile = Join-Path $profileRoot 'AppData\Local\Microsoft\VisualStudio\18.0_a1b2c3d4\Settings\CurrentSettings.vssettings'
        $writeFile = {
            param([string]$Path, [string]$Text)
            $null = New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force
            Set-Content -LiteralPath $Path -Value $Text
        }
        & $writeFile -Path (Join-Path $appData 'NuGet\NuGet.Config') -Text 'nuget'
        & $writeFile -Path (Join-Path $profileRoot '.gitconfig') -Text 'git'
        & $writeFile -Path $settingsFile -Text 'settings'
        & $writeFile -Path (Join-Path $vsFolder 'Code Snippets\Visual C#\loop.snippet') -Text 'snippet'
        & $writeFile -Path (Join-Path $vsFolder 'Templates\class.zip') -Text 'template'
        & $writeFile -Path (Join-Path $vsFolder 'Settings\CurrentSettings.vssettings') -Text 'documents settings'
        & $writeFile -Path (Join-Path $elsewhere 'secret.txt') -Text 'secret'

        $run = @{ ProfileRoot = $profileRoot; AppData = $appData; Documents = $documents; ProductLine = '18'; OutputFolder = $output; SettingsFile = $settingsFile }
        $zip = Join-Path $output 'vs-useritems.zip'

        # Replaces what is at $Path with a link of $Type to $Target.
        $makeLink = {
            param([string]$Path, [string]$Target, [string]$Type = 'SymbolicLink')
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
            $null = New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force
            $null = New-Item -ItemType $Type -Path $Path -Value $Target
        }
        $skipJunctionOffWindows = { param([string]$Type) if ($Type -eq 'Junction' -and -not $IsWindows) { Set-ItResult -Skipped -Because 'junctions exist only on Windows' } }
        # The names in the archive the script wrote, with / between folders.
        $entries = {
            $archive = [IO.Compression.ZipFile]::OpenRead($zip)
            try { @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') } | Sort-Object) }
            finally { $archive.Dispose() }
        }
        # Nothing the administrator could read and the user could not ends up in Output.
        $nothingSecret = {
            foreach ($file in @(Get-ChildItem -LiteralPath $output -Recurse -Force -File)) {
                Get-Content -LiteralPath $file.FullName -Raw | Should -Not -BeLike '*secret*'
            }
            if (Test-Path -LiteralPath $zip) { & $entries | Should -Not -Contain 'secret.txt' }
        }
    }

    It 'copies NuGet.Config, .gitconfig and the settings, and zips the snippets, templates and settings folders, into Output' {
        $result = & $userFiles @run

        @($result.Notes) | Should -BeNullOrEmpty
        @($result.Files) | Should -Be @('NuGet.Config', 'gitconfig', 'VisualStudio.vssettings', 'vs-useritems.zip')
        Get-Content -LiteralPath (Join-Path $output 'NuGet.Config') | Should -Be 'nuget'
        Get-Content -LiteralPath (Join-Path $output 'gitconfig') | Should -Be 'git'
        Get-Content -LiteralPath (Join-Path $output 'VisualStudio.vssettings') | Should -Be 'settings'
        & $entries | Should -Be @('Code Snippets/Visual C#/loop.snippet', 'Settings/CurrentSettings.vssettings', 'Templates/class.zip')
    }

    It 'makes an archive the restore puts back where it was' {
        $null = & $userFiles @run
        $newDocuments = Join-Path $base 'New\Documents'
        $null = New-Item -ItemType Directory -Path $newDocuments -Force

        $null = & $userFiles -ProfileRoot $profileRoot -AppData $appData -Documents $newDocuments -ProductLine '18' -UserItems $zip

        Get-Content -LiteralPath (Join-Path $newDocuments 'Visual Studio 18\Code Snippets\Visual C#\loop.snippet') | Should -Be 'snippet'
        Get-Content -LiteralPath (Join-Path $newDocuments 'Visual Studio 18\Templates\class.zip') | Should -Be 'template'
    }

    It 'refuses NuGet.Config, naming the link, when <Folder> on its way is a <LinkType>, and captures the rest' -ForEach @(
        foreach ($folder in 'AppData', 'AppData\Roaming', 'AppData\Roaming\NuGet') {
            foreach ($type in 'SymbolicLink', 'Junction') { @{ Folder = $folder; LinkType = $type } }
        }
    ) {
        & $skipJunctionOffWindows -Type $LinkType
        # What the link leads to holds a NuGet.Config where the profile's would be.
        $rest = [IO.Path]::GetRelativePath((Join-Path $profileRoot $Folder), (Join-Path $appData 'NuGet\NuGet.Config'))
        & $writeFile -Path (Join-Path $elsewhere $rest) -Text 'secret'
        $link = Join-Path $profileRoot $Folder
        & $makeLink -Path $link -Target $elsewhere -Type $LinkType
        $run.SettingsFile = ''

        $result = & $userFiles @run

        & $nothingSecret
        @($result.Files) | Should -Not -Contain 'NuGet.Config'
        @($result.Files) | Should -Contain 'gitconfig'
        $warnings = @($result.Notes | Where-Object { $_.Level -eq 'WARN' })
        $warnings.Count | Should -Be 1
        $warnings[0].Text | Should -BeLike "*NuGet.Config*$link*"
    }

    It 'refuses <What> when it is itself a link, and captures the rest' -ForEach @(
        @{ What = '.gitconfig'; Name = 'gitconfig' }
        @{ What = 'the Visual Studio settings'; Name = 'VisualStudio.vssettings' }
    ) {
        $link = if ($Name -eq 'gitconfig') { Join-Path $profileRoot '.gitconfig' } else { $settingsFile }
        & $makeLink -Path $link -Target (Join-Path $elsewhere 'secret.txt')

        $result = & $userFiles @run

        & $nothingSecret
        @($result.Files) | Should -Not -Contain $Name
        @($result.Files) | Should -Contain 'NuGet.Config'
        @($result.Notes | Where-Object { $_.Level -eq 'WARN' }).Text | Should -BeLike "*$What*$link*"
    }

    It 'refuses a settings file outside the profile' {
        $run.SettingsFile = Join-Path $elsewhere 'secret.txt'

        $result = & $userFiles @run

        & $nothingSecret
        @($result.Files) | Should -Not -Contain 'VisualStudio.vssettings'
        @($result.Notes | Where-Object { $_.Level -eq 'WARN' }).Text | Should -BeLike '*the Visual Studio settings*not inside*'
    }

    It 'leaves out, naming it, a <LinkType> to a folder inside the snippets, and zips the rest' -ForEach @(@{ LinkType = 'SymbolicLink' }, @{ LinkType = 'Junction' }) {
        & $skipJunctionOffWindows -Type $LinkType
        $link = Join-Path $vsFolder 'Code Snippets\Visual C#\Planted'
        & $makeLink -Path $link -Target $elsewhere -Type $LinkType

        $result = & $userFiles @run

        & $nothingSecret
        & $entries | Should -Be @('Code Snippets/Visual C#/loop.snippet', 'Settings/CurrentSettings.vssettings', 'Templates/class.zip')
        $warnings = @($result.Notes | Where-Object { $_.Level -eq 'WARN' })
        $warnings.Count | Should -Be 1
        $warnings[0].Text | Should -BeLike "*$link*"
    }

    It 'leaves out, naming it, a link to a file inside the templates' {
        $link = Join-Path $vsFolder 'Templates\planted.zip'
        & $makeLink -Path $link -Target (Join-Path $elsewhere 'secret.txt')

        $result = & $userFiles @run

        & $nothingSecret
        & $entries | Should -Not -Contain 'Templates/planted.zip'
        & $entries | Should -Contain 'Templates/class.zip'
        @($result.Notes | Where-Object { $_.Level -eq 'WARN' }).Text | Should -BeLike "*$link*"
    }

    It 'leaves out the <Folder> folder when it is a <LinkType>, and zips the others' -ForEach @(
        foreach ($type in 'SymbolicLink', 'Junction') { @{ Folder = 'Code Snippets'; LinkType = $type } }
    ) {
        & $skipJunctionOffWindows -Type $LinkType
        $link = Join-Path $vsFolder $Folder
        & $makeLink -Path $link -Target $elsewhere -Type $LinkType

        $result = & $userFiles @run

        & $nothingSecret
        & $entries | Should -Be @('Settings/CurrentSettings.vssettings', 'Templates/class.zip')
        @($result.Notes | Where-Object { $_.Level -eq 'WARN' }).Text | Should -BeLike "*$link*"
    }

    It 'zips nothing when the Visual Studio folder itself is a <LinkType>' -ForEach @(@{ LinkType = 'SymbolicLink' }, @{ LinkType = 'Junction' }) {
        & $skipJunctionOffWindows -Type $LinkType
        $real = Join-Path $base 'RealVisualStudio'
        Move-Item -LiteralPath $vsFolder -Destination $real
        & $makeLink -Path $vsFolder -Target $real -Type $LinkType

        $result = & $userFiles @run

        Test-Path -LiteralPath $zip | Should -BeFalse
        @($result.Files) | Should -Not -Contain 'vs-useritems.zip'
        $warnings = @($result.Notes | Where-Object { $_.Level -eq 'WARN' })
        $warnings | Should -Not -BeNullOrEmpty
        $warnings.Text | ForEach-Object { $_ | Should -BeLike "*$vsFolder*" }
    }

    It 'does not write through a link someone planted in Output' {
        $planted = Join-Path $elsewhere 'planted'
        & $makeLink -Path (Join-Path $output 'gitconfig') -Target $planted

        $result = & $userFiles @run

        Test-Path -LiteralPath $planted | Should -BeFalse
        @($result.Files) | Should -Not -Contain 'gitconfig'
        @($result.Notes | Where-Object { $_.Level -eq 'WARN' }).Text | Should -BeLike '*.gitconfig*gitconfig*'
    }

    It 'captures nothing, and says nothing, of files that are not there' {
        Remove-Item -LiteralPath $profileRoot, $vsFolder -Recurse -Force
        $null = New-Item -ItemType Directory -Path $profileRoot -Force
        $run.SettingsFile = ''

        $result = & $userFiles @run

        @($result.Notes) | Should -BeNullOrEmpty
        @($result.Files) | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $output -Force) | Should -BeNullOrEmpty
    }
}
