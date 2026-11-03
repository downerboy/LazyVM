# Restore.Tests.ps1
# Restore-GuestState returns exactly one result, so callers can use it as it
# is (#160). The helpers it calls are mocked to write stray output, which
# must not reach the caller. A rebuild attaches the user databases' files
# left on the SQL data disk (#132). Nothing here needs Hyper-V or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # Classes defined in a module are only visible inside it.
    $testVM = InModuleScope $module { [VMContext]::new(@{ VMName = 'Alpha' }) }

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')
}

Describe 'Restore-GuestState' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Get-CaptureManifest { [pscustomobject]@{ CapturedAt = '2026-10-29' } }
        Mock -ModuleName $module Open-GuestSession { 'stray' }
        Mock -ModuleName $module Initialize-GuestSqlDisk { 'stray' }
        Mock -ModuleName $module Invoke-IsolatedStep { [pscustomobject]@{ Results = @{}; Failures = @() } }
    }

    It 'returns only $true when every area is restored' {
        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Restore-GuestState -VM $VM })

        $result.Count | Should -Be 1
        $result[0] | Should -BeTrue
    }
}

Describe 'Mount-GuestSqlDatabase (#132)' {
    BeforeEach {
        $dataDir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'SQLData') -Force
        $primary = Join-Path $dataDir 'Sales.mdf'
        $log = Join-Path $dataDir 'Sales_log.ldf'
        Set-Content -LiteralPath $primary -Value 'data'
        Set-Content -LiteralPath $log -Value 'log'
        $letter = $primary.Substring(0, 1)
        $script:statements = @()
        Mock Get-GuestSqlScalar { 0 }
        Mock Invoke-GuestSql { $script:statements += $Sql }
    }

    It 'attaches the database from its recorded files, primary first, with the name and paths quoted' {
        $status = Mount-GuestSqlDatabase -Connection 'connection' -Name 'Sa]les' -Files @($primary, $log) -DriveLetter $letter

        $status | Should -Be 'Attached'
        $script:statements | Should -Be @("CREATE DATABASE [Sa]]les] ON (FILENAME = N'$($primary.Replace("'", "''"))'), (FILENAME = N'$($log.Replace("'", "''"))') FOR ATTACH")
    }

    It 'finds the files on the data disk''s new drive letter when they are not at their recorded paths' {
        $recorded = @($primary, $log) | ForEach-Object { 'Q' + $_.Substring(1) }

        $status = Mount-GuestSqlDatabase -Connection 'connection' -Name 'Sales' -Files $recorded -DriveLetter $letter

        $status | Should -Be 'Attached'
        $script:statements[0] | Should -BeLike "*FILENAME = N'$primary'*FILENAME = N'$log'*"
    }

    It 'attaches nothing and says so when a file is on neither drive' {
        Remove-Item -LiteralPath $log

        $status = Mount-GuestSqlDatabase -Connection 'connection' -Name 'Sales' -Files @($primary, $log) -DriveLetter $letter

        $status | Should -Be 'Missing'
        $script:statements | Should -BeNullOrEmpty
    }

    It 'leaves a database that already exists alone' {
        Mock Get-GuestSqlScalar { 1 }

        $status = Mount-GuestSqlDatabase -Connection 'connection' -Name 'Sales' -Files @($primary, $log) -DriveLetter $letter

        $status | Should -Be 'Exists'
        $script:statements | Should -BeNullOrEmpty
    }
}

Describe 'Restore-GuestVisualStudioState (#310)' {
    BeforeEach {
        $logged = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Write-LogEntry { $logged.Add("$($Level): $Message") }
        Mock -ModuleName $module Write-GuestNote { }
        Mock -ModuleName $module Invoke-GuestScript { }
        Mock -ModuleName $module Wait-GuestSignedIn { $true }
        Mock -ModuleName $module Get-GuestVisualStudio { [pscustomobject]@{ ProductLine = '18'; InstanceId = 'a1b2c3d4' } }
        Mock -ModuleName $module Invoke-GuestTask { '[{"Level":"OK","Text":"restored NuGet.Config"}]' }

        $captured = Join-Path $TestDrive 'vs'
        $null = New-Item -ItemType Directory -Path $captured -Force
        foreach ($name in 'NuGet.Config', 'gitconfig', 'vs-useritems.zip') { Set-Content -LiteralPath (Join-Path $captured $name) -Value $name }
        $files = [ordered]@{
            NuGetConfig = (Join-Path $captured 'NuGet.Config')
            GitConfig   = (Join-Path $captured 'gitconfig')
            UserItems   = (Join-Path $captured 'vs-useritems.zip')
        }
        $guestScript = Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.VisualStudioUserFiles.ps1'
        $restore = {
            param([System.Collections.IDictionary]$Files)
            InModuleScope $module -Parameters @{ Files = $Files } {
                param($Files)
                $manifest = [CaptureManifest]::new()
                $manifest.VisualStudio = [pscustomobject]@{ Files = [pscustomobject]$Files }
                Restore-GuestVisualStudioState -VM ([VMContext]::new(@{ VMName = 'Alpha'; GuestAdminUser = 'devadmin'; InstallVisualStudio = $true })) -Manifest $manifest
            }
        }
    }

    It 'copies the files as the guest account under its limited token, never as the administrator' {
        & $restore -Files $files

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'LazyVM-VSUserFiles' -and $AsGuestUser -and -not $Elevated
        }
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 0 -Exactly
    }

    It 'gives the task the captured files, each under a fixed name, and the script that copies them, in its own folder' {
        & $restore -Files $files

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            (@($InputFile.Keys | Sort-Object) -join ',') -eq 'gitconfig,NuGet.Config,UserItems.zip,VisualStudioUserFiles.ps1' -and
            $InputFile['VisualStudioUserFiles.ps1'] -eq $guestScript -and
            $InputFile['NuGet.Config'] -eq $files.NuGetConfig -and
            $InputFile['UserItems.zip'] -eq $files.UserItems -and
            "$Work" -match "Join-Path \`$TaskFolder 'VisualStudioUserFiles\.ps1'" -and
            $ArgumentList[0] -eq '18' -and $ArgumentList[1] -eq 'NuGet.Config' -and $ArgumentList[2] -eq 'gitconfig' -and $ArgumentList[3] -eq 'UserItems.zip'
        }
    }

    It 'leaves out a file the capture does not have' {
        $files.Remove('GitConfig')

        & $restore -Files $files

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            -not $InputFile.Contains('gitconfig') -and $ArgumentList[2] -eq ''
        }
    }

    It 'logs what the task reported' {
        & $restore -Files $files

        Should -Invoke -ModuleName $module Write-GuestNote -Times 1 -Exactly -ParameterFilter { @($Notes).Text -contains 'restored NuGet.Config' }
    }

    It 'logs one WARN, and does not stop, when what the task reported cannot be read' {
        Mock -ModuleName $module Invoke-GuestTask { 'not { json' }

        { & $restore -Files $files } | Should -Not -Throw

        @($logged | Where-Object { $_ -like 'WARN:*Visual Studio files*' }).Count | Should -Be 1
        Should -Invoke -ModuleName $module Write-GuestNote -Times 0 -Exactly
    }

    It 'starts no task when the capture has none of the files' {
        & $restore -Files ([ordered]@{})

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 0 -Exactly
    }

    It 'waits for the account to be signed in, as the settings import does' {
        & $restore -Files $files

        $minutes = InModuleScope $module { $script:VisualStudioSignInWaitMinutes }
        Should -Invoke -ModuleName $module Wait-GuestSignedIn -Times 1 -Exactly -ParameterFilter { $TimeoutMinutes -eq $minutes }
    }

    It 'starts no task, and says why, when the account is not signed in' {
        Mock -ModuleName $module Wait-GuestSignedIn { $false }

        & $restore -Files $files

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 0 -Exactly
        $logged | Should -Contain "WARN:   'devadmin' is not signed in - Visual Studio files not restored"
    }
}

Describe 'Guest.VisualStudioUserFiles.ps1 (#310)' {
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
        $elsewhere = Join-Path $base 'Elsewhere'
        foreach ($made in $appData, $documents, $elsewhere) { $null = New-Item -ItemType Directory -Path $made -Force }

        $task = Join-Path $base 'Task'
        $items = Join-Path $base 'items'
        foreach ($sub in 'Code Snippets', 'Templates') { $null = New-Item -ItemType Directory -Path (Join-Path $items $sub) -Force }
        Set-Content -LiteralPath (Join-Path $items 'Code Snippets\loop.snippet') -Value 'snippet'
        Set-Content -LiteralPath (Join-Path $items 'Templates\class.zip') -Value 'template'
        $null = New-Item -ItemType Directory -Path $task -Force
        $zip = Join-Path $task 'UserItems.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($items, $zip)
        Set-Content -LiteralPath (Join-Path $task 'NuGet.Config') -Value 'nuget'
        Set-Content -LiteralPath (Join-Path $task 'gitconfig') -Value 'git'

        $run = @{
            ProfileRoot = $profileRoot; AppData = $appData; Documents = $documents; ProductLine = '18'
            NuGetConfig = (Join-Path $task 'NuGet.Config'); GitConfig = (Join-Path $task 'gitconfig'); UserItems = $zip
        }
        $vsFolder = Join-Path $documents 'Visual Studio 18'

        # Replaces what is at $Path with a link of $Type to $Target.
        $makeLink = {
            param([string]$Path, [string]$Target, [string]$Type = 'SymbolicLink')
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
            $null = New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force
            $null = New-Item -ItemType $Type -Path $Path -Value $Target
        }
        $skipJunctionOffWindows = { param([string]$Type) if ($Type -eq 'Junction' -and -not $IsWindows) { Set-ItResult -Skipped -Because 'junctions exist only on Windows' } }
        $nothingElsewhere = { @(Get-ChildItem -LiteralPath $elsewhere -Recurse -Force -File).Count | Should -Be 0 }
        # A zip archive holding a file under each of $Names.
        $newArchive = {
            param([string[]]$Names)
            $path = Join-Path $task 'Crafted.zip'
            $archive = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($entryName in $Names) {
                    $writer = New-Object IO.StreamWriter($archive.CreateEntry($entryName).Open())
                    try { $writer.Write($entryName) } finally { $writer.Dispose() }
                }
            }
            finally { $archive.Dispose() }
            return $path
        }
    }

    It 'puts NuGet.Config, .gitconfig and the snippets and templates in the profile' {
        $notes = @(& $userFiles @run)

        Get-Content -LiteralPath (Join-Path $appData 'NuGet\NuGet.Config') | Should -Be 'nuget'
        Get-Content -LiteralPath (Join-Path $profileRoot '.gitconfig') | Should -Be 'git'
        Get-Content -LiteralPath (Join-Path $vsFolder 'Code Snippets\loop.snippet') | Should -Be 'snippet'
        Get-Content -LiteralPath (Join-Path $vsFolder 'Templates\class.zip') | Should -Be 'template'
        @($notes | Where-Object { $_.Level -ne 'OK' }) | Should -BeNullOrEmpty
        $notes.Text | Should -Contain 'restored NuGet.Config'
        $notes.Text | Should -Contain 'restored .gitconfig'
        $notes.Text | Should -Contain 'restored 2 snippet and template file(s)'
    }

    It 'replaces files already there' {
        $null = New-Item -ItemType Directory -Path (Join-Path $appData 'NuGet') -Force
        Set-Content -LiteralPath (Join-Path $appData 'NuGet\NuGet.Config') -Value 'old'

        $null = & $userFiles @run

        Get-Content -LiteralPath (Join-Path $appData 'NuGet\NuGet.Config') | Should -Be 'nuget'
    }

    It 'refuses NuGet.Config, naming the link, when <Folder> on its way is a <LinkType>, and restores the rest' -ForEach @(
        foreach ($folder in 'AppData', 'AppData\Roaming', 'AppData\Roaming\NuGet') {
            foreach ($type in 'SymbolicLink', 'Junction') { @{ Folder = $folder; LinkType = $type } }
        }
    ) {
        & $skipJunctionOffWindows -Type $LinkType
        $link = Join-Path $profileRoot $Folder
        & $makeLink -Path $link -Target $elsewhere -Type $LinkType

        $notes = @(& $userFiles @run)

        & $nothingElsewhere
        $warnings = @($notes | Where-Object { $_.Level -eq 'WARN' })
        $warnings.Count | Should -Be 1
        $warnings[0].Text | Should -BeLike "*NuGet.Config*$link*"
        Get-Content -LiteralPath (Join-Path $profileRoot '.gitconfig') | Should -Be 'git'
    }

    It 'refuses a destination that is itself a link, even one that leads nowhere yet' {
        $link = Join-Path $profileRoot '.gitconfig'
        & $makeLink -Path $link -Target (Join-Path $elsewhere 'planted')

        $notes = @(& $userFiles @run)

        & $nothingElsewhere
        @($notes | Where-Object { $_.Level -eq 'WARN' }).Text | Should -BeLike "*.gitconfig*$link*"
    }

    It 'refuses the profile itself when it is a <LinkType>' -ForEach @(@{ LinkType = 'SymbolicLink' }, @{ LinkType = 'Junction' }) {
        & $skipJunctionOffWindows -Type $LinkType
        $real = Join-Path $base 'RealProfile'
        $null = New-Item -ItemType Directory -Path $real -Force
        & $makeLink -Path $profileRoot -Target $real -Type $LinkType

        $notes = @(& $userFiles @run)

        @(Get-ChildItem -LiteralPath $real -Recurse -Force -File).Count | Should -Be 0
        $warnings = @($notes | Where-Object { $_.Level -eq 'WARN' })
        $warnings.Count | Should -Be 2
        $warnings.Text | ForEach-Object { $_ | Should -BeLike "*$profileRoot*" }
    }

    It 'refuses a snippet or template whose folder is a <LinkType>, and restores the others' -ForEach @(@{ LinkType = 'SymbolicLink' }, @{ LinkType = 'Junction' }) {
        & $skipJunctionOffWindows -Type $LinkType
        $link = Join-Path $vsFolder 'Code Snippets'
        & $makeLink -Path $link -Target $elsewhere -Type $LinkType

        $notes = @(& $userFiles @run)

        & $nothingElsewhere
        Get-Content -LiteralPath (Join-Path $vsFolder 'Templates\class.zip') | Should -Be 'template'
        @($notes | Where-Object { $_.Level -eq 'WARN' }).Text | Should -BeLike "*loop.snippet*$link*"
        $notes.Text | Should -Contain 'restored 1 snippet and template file(s)'
    }

    It 'refuses an archive entry named <Name>, which could lead out of the Visual Studio folder, and restores the others' -ForEach @(
        @{ Name = '../escaped.txt' }
        @{ Name = 'Templates/../../escaped.txt' }
        @{ Name = 'Templates/./dotted.txt' }
        @{ Name = 'Templates/C:escaped.txt' }
    ) {
        $run.UserItems = & $newArchive -Names @($Name, 'Templates/kept.txt')

        $notes = @(& $userFiles @run)

        @(Get-ChildItem -LiteralPath $documents -Recurse -Force -File | Where-Object { $_.FullName -notlike "$vsFolder*" }).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $vsFolder -Recurse -Force -File).Name | Should -Be @('kept.txt')
        $warnings = @($notes | Where-Object { $_.Level -eq 'WARN' })
        $warnings.Count | Should -Be 1
        $warnings[0].Text | Should -BeLike "*$Name*"
        $notes.Text | Should -Contain 'restored 1 snippet and template file(s)'
    }

    It 'reports a damaged archive as one WARN and keeps what it restored before it' {
        Set-Content -LiteralPath $zip -Value 'not a zip archive'

        $notes = @(& $userFiles @run)

        $notes.Text | Should -Contain 'restored NuGet.Config'
        $notes.Text | Should -Contain 'restored .gitconfig'
        $warnings = @($notes | Where-Object { $_.Level -eq 'WARN' })
        $warnings.Count | Should -Be 1
        $warnings[0].Text | Should -BeLike 'did not restore the snippets and templates: *'
    }

    It 'does only what it is given' {
        $run.Remove('NuGetConfig')
        $run.Remove('UserItems')

        $notes = @(& $userFiles @run)

        Test-Path -LiteralPath (Join-Path $appData 'NuGet') | Should -BeFalse
        Test-Path -LiteralPath $vsFolder | Should -BeFalse
        $notes.Text | Should -Be @('restored .gitconfig')
    }
}
