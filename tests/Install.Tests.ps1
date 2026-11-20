# Install.Tests.ps1
# Install.ps1, the installer in a release download: what it says when the
# folder it is given holds no built module, that it installs for the
# current user only, outside OneDrive, and how it adds its folder to the
# user's PSModulePath (#284), and how it removes earlier copies that would
# load instead of the installed version (#311). Nothing is installed.

BeforeAll {
    $installScript = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'src\Install.ps1'
}

Describe 'Install.ps1' {
    It 'says how to install when given <Case>' -ForEach @(
        @{ Case = 'the repository''s src folder, which holds the module''s source (#90)'; Folders = @('LazyVM\Classes', 'LazyVM\Data', 'LazyVM\Private', 'LazyVM\Public') }
        @{ Case = 'a folder with no LazyVM folder at all'; Folders = @('Other') }
    ) {
        $path = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        foreach ($folder in $Folders) {
            New-Item -ItemType Directory -Path (Join-Path -Path $path -ChildPath $folder) -Force | Out-Null
        }

        { & $installScript -Path $path } | Should -Throw -ExpectedMessage '*There is no LazyVM module folder*./Invoke-AnalyzerAndTest.ps1 && ./src/Install.ps1 -Path out*'
    }

    It 'installs in Program Files, locked so only administrators can change it, which needs elevation (#284)' {
        $text = Get-Content -LiteralPath $installScript -Raw

        $text | Should -Match '#Requires -RunAsAdministrator'
        $text | Should -Match '\$installDir = Join-Path -Path \$programFiles -ChildPath \$moduleName'
        $text | Should -Match "\`$programFiles = \[Environment\]::GetFolderPath\('ProgramFiles'\)"
        $text | Should -Match 'Set-LockedAccess -Path \$installDir'
    }
}

Describe 'The user''s PSModulePath, in Install.ps1 (#284)' {
    BeforeAll {
        # The function on its own, without running the installer.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
        foreach ($name in 'Add-PathListEntry', 'Remove-PathListEntry', 'Test-SameFolder') {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }

    It 'adds <Entry> to ''<List>'', giving ''<Expected>''' -ForEach @(
        @{ List = ''; Entry = 'C:\Users\sean\AppData\Local\LazyVM\Modules'; Expected = 'C:\Users\sean\AppData\Local\LazyVM\Modules' }
        @{ List = 'D:\Modules'; Entry = 'C:\L\Modules'; Expected = 'D:\Modules;C:\L\Modules' }
        @{ List = 'D:\Modules;'; Entry = 'C:\L\Modules'; Expected = 'D:\Modules;C:\L\Modules' }
    ) {
        Add-PathListEntry -List $List -Entry $Entry | Should -Be $Expected
    }

    It 'leaves the list as it is when it has the entry already, <Case>' -ForEach @(
        @{ Case = 'written the same'; List = 'D:\Modules;C:\L\Modules' }
        @{ Case = 'in other case, with a trailing backslash'; List = 'D:\Modules;c:\l\modules\' }
        @{ Case = 'as an environment variable'; List = 'D:\Modules;%LAZYVM_TEST_ROOT%\Modules' }
    ) {
        $env:LAZYVM_TEST_ROOT = 'C:\L'
        try { Add-PathListEntry -List $List -Entry 'C:\L\Modules' | Should -Be $List }
        finally { Remove-Item -Path Env:\LAZYVM_TEST_ROOT }
    }

    It 'takes out an earlier module folder however it is written, keeping the rest' {
        $env:LAZYVM_TEST_ROOT = 'C:\L'
        try { Remove-PathListEntry -List 'D:\Modules;%LAZYVM_TEST_ROOT%\Modules\;E:\M' -Entry 'C:\L\Modules' | Should -Be 'D:\Modules;E:\M' }
        finally { Remove-Item -Path Env:\LAZYVM_TEST_ROOT }
    }
}

Describe 'Earlier copies, in Install.ps1 (#311)' {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
        foreach ($name in 'Test-ReparsePoint', 'Test-ReparsePointOnPath', 'Test-ContainsReparsePoint', 'Test-ModuleCopy', 'Get-EarlierCopyProblem', 'Remove-EarlierCopy', 'Move-EarlierCopy', 'Reset-InheritedAccess', 'Get-FirstModuleCopy', 'Write-ShadowingCopyWarning', 'Test-SameFolder') {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        # A junction, as Windows makes without elevation; elsewhere, a symbolic link.
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }

        function New-TestModuleCopy {
            <# A LazyVM module folder in $Folder, with a version folder holding LazyVM.psd1 for each of $Version. #>
            param([string]$Folder, [string[]]$Version)
            foreach ($name in $Version) {
                New-Item -ItemType Directory -Path (Join-Path -Path $Folder -ChildPath "LazyVM/$name") -Force | Out-Null
                Set-Content -LiteralPath (Join-Path -Path $Folder -ChildPath "LazyVM/$name/LazyVM.psd1") -Value '@{}'
            }
            return Join-Path -Path $Folder -ChildPath 'LazyVM'
        }
    }

    BeforeEach {
        # The moved copy's access is checked on its own, on Windows, below.
        if (-not $IsWindows) { Mock Reset-InheritedAccess { } }
        $folder = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $copy = New-TestModuleCopy -Folder $folder -Version '5.2.0'
        $outside = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $outside -ChildPath 'keep.txt') -Value 'keep'
    }

    It 'removes an earlier copy and says where' {
        $said = Remove-EarlierCopy -Path $copy 6>&1

        Test-Path -LiteralPath $copy | Should -BeFalse
        "$said" | Should -BeLike "*Removed*$copy*"
    }

    It 'does nothing when there is no copy' {
        $said = Remove-EarlierCopy -Path (Join-Path -Path $folder -ChildPath 'Missing/LazyVM') 6>&1 3>&1

        $said | Should -BeNullOrEmpty
    }

    It 'with -Except, removes every other version and keeps that one' {
        $copy = New-TestModuleCopy -Folder $folder -Version '6.3.1', '6.4.0'

        $said = Remove-EarlierCopy -Path $copy -Except '6.4.0' 6>&1

        @(Get-ChildItem -LiteralPath $copy | ForEach-Object { $_.Name }) | Should -Be @('6.4.0')
        "$said" | Should -BeLike '*Removed*5.2.0*Removed*6.3.1*'
    }

    It 'keeps a copy that is a link, warning, and leaves what it points to alone' {
        $link = Join-Path -Path $folder -ChildPath 'Linked/LazyVM'
        New-Item -ItemType Directory -Path (Split-Path -Path $link -Parent) | Out-Null
        New-Item -ItemType $linkType -Path $link -Target $outside | Out-Null

        $warning = Remove-EarlierCopy -Path $link 3>&1

        Test-Path -LiteralPath $link | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $outside -ChildPath 'keep.txt') | Should -BeTrue
        "$warning" | Should -BeLike "*Kept*$link*junction, link or cloud placeholder*"
    }

    It 'keeps a copy that holds a link, warning, and removes nothing from it' {
        New-Item -ItemType $linkType -Path (Join-Path -Path $copy -ChildPath '5.2.0/Data') -Target $outside | Out-Null

        $warning = Remove-EarlierCopy -Path $copy 3>&1

        Test-Path -LiteralPath (Join-Path -Path $copy -ChildPath '5.2.0/LazyVM.psd1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $outside -ChildPath 'keep.txt') | Should -BeTrue
        "$warning" | Should -BeLike "*Kept*$copy*"
    }

    It 'keeps a copy reached through a link in a folder above it, warning, and removes nothing through it' {
        $target = New-TestModuleCopy -Folder (Join-Path -Path $outside -ChildPath 'Modules') -Version '6.0.0'
        $above = Join-Path -Path $folder -ChildPath 'AppDataLink'
        New-Item -ItemType $linkType -Path $above -Target $outside | Out-Null
        $throughLink = Join-Path -Path $above -ChildPath 'Modules/LazyVM'

        $warning = Remove-EarlierCopy -Path $throughLink 3>&1

        Test-Path -LiteralPath (Join-Path -Path $target -ChildPath '6.0.0/LazyVM.psd1') | Should -BeTrue
        "$warning" | Should -BeLike "*Kept*$throughLink*junction, link or cloud placeholder*"
    }

    It 'keeps a folder that is not a LazyVM copy (<Case>), warning, and removes nothing from it' -ForEach @(
        @{ Case = 'it holds a file of its own'; Stray = 'notes.txt'; Leaf = 'LazyVM' }
        @{ Case = 'a version folder has no LazyVM.psd1'; Stray = '6.0.0/other.txt'; Leaf = 'LazyVM' }
        @{ Case = 'a folder that is not a version'; Stray = 'Data/other.txt'; Leaf = 'LazyVM' }
        @{ Case = 'it is not named LazyVM'; Stray = $null; Leaf = 'Modules' }
    ) {
        if ($Stray) {
            New-Item -ItemType File -Path (Join-Path -Path $copy -ChildPath $Stray) -Force | Out-Null
        }
        $path = if ($Leaf -eq 'LazyVM') { $copy } else { $folder }

        $warning = Remove-EarlierCopy -Path $path 3>&1

        Test-Path -LiteralPath (Join-Path -Path $copy -ChildPath '5.2.0/LazyVM.psd1') | Should -BeTrue
        "$warning" | Should -BeLike "*Kept*$path*not a LazyVM module folder*"
    }

    It 'turns a failed removal into a warning with the path, so the install goes on' {
        Mock Remove-Item { throw 'Access to the path is denied.' }

        $warning = Remove-EarlierCopy -Path $copy 3>&1

        "$warning" | Should -BeLike "*$copy*Access to the path is denied*"
    }

    It 'moves LazyVM 5''s copy aside, off PSModulePath, and says where' {
        $destination = Join-Path -Path $outside -ChildPath 'Legacy/LazyVM'

        $said = Move-EarlierCopy -Path $copy -Destination $destination 6>&1

        Test-Path -LiteralPath $copy | Should -BeFalse
        Test-Path -LiteralPath (Join-Path -Path $destination -ChildPath '5.2.0/LazyVM.psd1') | Should -BeTrue
        "$said" | Should -BeLike "*Moved*$copy*$destination*"
    }

    It 'gives the moved copy only the access the folder it is moved to passes on, not what it had where it was (N-1)' -Skip:(-not $IsWindows) {
        # Program Files lets Users read and run what is in it; the locked LazyVM folder does not.
        $users = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
        $acl = Get-Acl -LiteralPath $folder
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($users, 'ReadAndExecute', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
        Set-Acl -LiteralPath $folder -AclObject $acl
        $destination = Join-Path -Path $outside -ChildPath 'Legacy/LazyVM'

        Move-EarlierCopy -Path $copy -Destination $destination 6>&1 | Out-Null

        foreach ($item in @(Get-Item -LiteralPath $destination) + @(Get-ChildItem -LiteralPath $destination -Recurse -Force)) {
            $rules = @((Get-Acl -LiteralPath $item.FullName).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
            @($rules | Where-Object { $_.IdentityReference -eq $users }).Count | Should -Be 0 -Because "$($item.FullName) must not let Users in"
            @($rules | Where-Object { -not $_.IsInherited }).Count | Should -Be 0 -Because "$($item.FullName) must only inherit"
        }
    }

    It 'does not move a copy over one moved aside already, warning' {
        $destination = New-TestModuleCopy -Folder (Join-Path -Path $outside -ChildPath 'Legacy') -Version '5.1.0'

        $warning = Move-EarlierCopy -Path $copy -Destination $destination 3>&1

        Test-Path -LiteralPath (Join-Path -Path $copy -ChildPath '5.2.0/LazyVM.psd1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $destination -ChildPath '5.2.0') | Should -BeFalse
        "$warning" | Should -BeLike "*$copy*still loads instead of the version installed*$destination*Convert-LazyVMInstallation*removes both*"
    }

    It 'does not move a copy that holds a link, warning' {
        New-Item -ItemType $linkType -Path (Join-Path -Path $copy -ChildPath '5.2.0/Data') -Target $outside | Out-Null

        $warning = Move-EarlierCopy -Path $copy -Destination (Join-Path -Path $outside -ChildPath 'Legacy/LazyVM') 3>&1

        Test-Path -LiteralPath $copy | Should -BeTrue
        "$warning" | Should -BeLike "*Kept*$copy*junction, link or cloud placeholder*"
    }
}

Describe 'Which LazyVM loads first, in Install.ps1 (#311)' {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
        foreach ($name in 'Get-FirstModuleCopy', 'Write-ShadowingCopyWarning', 'Test-SameFolder') {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $installed = Join-Path -Path $TestDrive -ChildPath 'Program Files/LazyVM/Modules/LazyVM/6.4.0'
        function New-TestCopy { param([string]$Folder, [string]$Version) [pscustomobject]@{ ModuleBase = Join-Path -Path $TestDrive -ChildPath "$Folder/LazyVM/$Version"; Version = [version]$Version } }
    }

    It 'says nothing when the installed version comes first on PSModulePath' {
        Mock Get-Module { New-TestCopy 'Program Files/LazyVM/Modules' '6.4.0'; New-TestCopy 'Program Files/LazyVM/Modules' '6.3.1'; New-TestCopy 'D' '7.0.0' } -ParameterFilter { $ListAvailable }

        Write-ShadowingCopyWarning -Path $installed 3>&1 | Should -BeNullOrEmpty
    }

    It 'warns with the path of <Case>' -ForEach @(
        @{ Case = 'a copy in a folder that comes first'; Before = @('D|5.2.0'); After = @(); Expected = 'D/LazyVM/5.2.0' }
        @{ Case = 'a higher version in the same folder, listed after it'; Before = @(); After = @('Program Files/LazyVM/Modules|6.5.0'); Expected = 'Program Files/LazyVM/Modules/LazyVM/6.5.0' }
    ) {
        $toCopy = { param($Entry) $folder, $version = $Entry -split '\|'; New-TestCopy $folder $version }
        $copies = @($Before | ForEach-Object { & $toCopy $_ }) + (New-TestCopy 'Program Files/LazyVM/Modules' '6.4.0') + @($After | ForEach-Object { & $toCopy $_ })
        Mock Get-Module { $copies }.GetNewClosure() -ParameterFilter { $ListAvailable }

        $warning = Write-ShadowingCopyWarning -Path $installed 3>&1

        "$warning" | Should -BeLike "*$(Join-Path -Path $TestDrive -ChildPath $Expected)*"
    }

    It 'smoke: updates PSModulePath before it removes or moves any earlier copy, and checks which loads first last (CA-3)' {
        $text = Get-Content -LiteralPath $installScript -Raw
        $pathUpdate = $text.IndexOf('$env:PSModulePath = Add-PathListEntry')
        $firstChange = [Math]::Min($text.IndexOf("`nRemove-EarlierCopy -Path"), $text.IndexOf("`n    Move-EarlierCopy -Path"))

        $pathUpdate | Should -BeGreaterThan 0
        $firstChange | Should -BeGreaterThan $pathUpdate
        $text.LastIndexOf('Write-ShadowingCopyWarning -Path $target') | Should -BeGreaterThan $firstChange
    }
}

Describe 'The app, in Install.ps1 (#489)' {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
        foreach ($name in 'Test-ReparsePoint', 'Test-ReparsePointOnPath', 'Test-ContainsReparsePoint', 'Install-App') {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    }

    BeforeEach {
        # A release download with the app in App, and the locked install folder.
        $download = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $source = Join-Path -Path $download -ChildPath 'App'
        New-Item -ItemType Directory -Path (Join-Path -Path $source -ChildPath 'Modules/Microsoft.PowerShell.Utility') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $source -ChildPath 'LazyVM.UI.Wpf.exe') -Value 'new'
        Set-Content -LiteralPath (Join-Path -Path $source -ChildPath 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -Value '@{}'
        $installDir = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $installDir | Out-Null
        $target = Join-Path -Path $installDir -ChildPath 'App'
        $outside = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $outside | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $outside -ChildPath 'keep.txt') -Value 'keep'

        function Get-OldApp {
            <# The app as an earlier install left it: an exe, and a file the new one no longer has. #>
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $target -ChildPath 'LazyVM.UI.Wpf.exe') -Value 'old'
            Set-Content -LiteralPath (Join-Path -Path $target -ChildPath 'Gone.dll') -Value 'old'
        }
    }

    It 'installs the app in App, in the install folder, and says where' {
        $said = Install-App -Source $source -InstallDir $installDir 6>&1

        Get-Content -LiteralPath (Join-Path -Path $target -ChildPath 'LazyVM.UI.Wpf.exe') | Should -Be 'new'
        Test-Path -LiteralPath (Join-Path -Path $target -ChildPath 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') | Should -BeTrue
        "$said" | Should -BeLike "*Installed the LazyVM app in $target*"
    }

    It 'replaces an earlier app whole, so none of its files are left, and leaves nothing beside it' {
        Get-OldApp

        Install-App -Source $source -InstallDir $installDir 6>&1 | Out-Null

        Get-Content -LiteralPath (Join-Path -Path $target -ChildPath 'LazyVM.UI.Wpf.exe') | Should -Be 'new'
        Test-Path -LiteralPath (Join-Path -Path $target -ChildPath 'Gone.dll') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $installDir -Force | ForEach-Object { $_.Name }) | Should -Be @('App')
    }

    It 'keeps an earlier app that is running, says to close it, and leaves nothing beside it' {
        Get-OldApp
        # Windows refuses to rename a folder while a program in it runs.
        Mock Rename-Item { throw 'The process cannot access the file because it is being used by another process.' }

        $warning = Install-App -Source $source -InstallDir $installDir 3>&1

        Get-Content -LiteralPath (Join-Path -Path $target -ChildPath 'LazyVM.UI.Wpf.exe') | Should -Be 'old'
        Test-Path -LiteralPath (Join-Path -Path $target -ChildPath 'Gone.dll') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $installDir -Force | ForEach-Object { $_.Name }) | Should -Be @('App')
        "$warning" | Should -BeLike '*app was not updated*Close LazyVM*Install.ps1 again*'
    }

    It 'installs the module only, and says so, when the download has no App folder' {
        Remove-Item -LiteralPath $source -Recurse -Force

        $said = Install-App -Source $source -InstallDir $installDir 6>&1 3>&1

        Test-Path -LiteralPath $target | Should -BeFalse
        "$said" | Should -BeLike "*no App folder in $download*only the module*"
    }

    It 'does not install an app that holds a link, warning, and leaves what it points to alone' {
        New-Item -ItemType $linkType -Path (Join-Path -Path $source -ChildPath 'Linked') -Target $outside | Out-Null

        $warning = Install-App -Source $source -InstallDir $installDir 3>&1

        Test-Path -LiteralPath $target | Should -BeFalse
        Test-Path -LiteralPath (Join-Path -Path $outside -ChildPath 'keep.txt') | Should -BeTrue
        "$warning" | Should -BeLike "*app was not installed*$source*junction, link or cloud placeholder*"
    }

    It 'does not replace an installed app that is a link, warning, and leaves what it points to alone' {
        New-Item -ItemType $linkType -Path $target -Target $outside | Out-Null

        $warning = Install-App -Source $source -InstallDir $installDir 3>&1

        Test-Path -LiteralPath (Join-Path -Path $outside -ChildPath 'keep.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $outside -ChildPath 'LazyVM.UI.Wpf.exe') | Should -BeFalse
        "$warning" | Should -BeLike "*app was not installed*$target*junction, link or cloud placeholder*"
    }

    It 'smoke: installs the app after the module, from the download''s App folder, into the locked install folder' {
        $text = Get-Content -LiteralPath $installScript -Raw

        $text | Should -Match 'Install-App -Source \(Join-Path -Path \$Path -ChildPath ''App''\) -InstallDir \$installDir'
        $text.IndexOf('Install-App -Source') | Should -BeGreaterThan $text.IndexOf('Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File')
    }
}

Describe 'The Start menu shortcut, in Install.ps1 (#490)' {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
        foreach ($name in 'Test-ReparsePoint', 'Test-ReparsePointOnPath', 'Get-ShortcutFolderProblem', 'Get-FolderAllowRule', 'Set-LockedAccess', 'Install-StartMenuShortcut') {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        $user = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-111-222-333-1001')

        function Get-ShortcutTarget {
            <# Where the shortcut at $Path points. #>
            param([string]$Path)
            return (New-Object -ComObject WScript.Shell).CreateShortcut($Path).TargetPath
        }
    }

    BeforeEach {
        # The all-users Start menu's Programs folder, and the installed app.
        $programs = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $programs | Out-Null
        $shortcut = Join-Path -Path $programs -ChildPath 'LazyVM.lnk'
        $app = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $app | Out-Null
        $exe = Join-Path -Path $app -ChildPath 'LazyVM.UI.Wpf.exe'
        Set-Content -LiteralPath $exe -Value 'app'
        # Only administrators can change the real folder; a test's folder is the user's own.
        Mock Get-ShortcutFolderProblem { }
        # Locking the shortcut to Administrators needs elevation; checked on its own below.
        Mock Set-LockedAccess { }
    }

    It 'adds a LazyVM shortcut to the app, locks it, and says where' -Skip:(-not $IsWindows) {
        $said = Install-StartMenuShortcut -Path $shortcut -Target $exe -User $user 6>&1

        Get-ShortcutTarget -Path $shortcut | Should -Be $exe
        Should -Invoke Set-LockedAccess -Times 1 -ParameterFilter { $Path -eq $shortcut -and $User -eq $user }
        "$said" | Should -BeLike "*Added the LazyVM shortcut*$shortcut*"
    }

    It 'replaces a shortcut an earlier install, or anyone, left there' -Skip:(-not $IsWindows) {
        $old = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
        $old.TargetPath = Join-Path -Path $TestDrive -ChildPath 'other.exe'
        $old.Save()

        Install-StartMenuShortcut -Path $shortcut -Target $exe -User $user 6>&1 | Out-Null

        Get-ShortcutTarget -Path $shortcut | Should -Be $exe
    }

    It 'adds no shortcut to a folder others can change, warning why (security rule 6)' {
        Mock Get-ShortcutFolderProblem { 'it can be changed by MIKEPC\sean' }

        $warning = Install-StartMenuShortcut -Path $shortcut -Target $exe -User $user 3>&1

        Test-Path -LiteralPath $shortcut | Should -BeFalse
        "$warning" | Should -BeLike "*No Start menu shortcut*$programs*can be changed by MIKEPC\sean*$exe*"
    }

    It 'adds no shortcut through a folder that is a link, warning, and leaves what it points to alone' {
        $outside = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $outside | Out-Null
        $linked = Join-Path -Path $programs -ChildPath 'Linked'
        New-Item -ItemType $linkType -Path $linked -Target $outside | Out-Null

        $warning = Install-StartMenuShortcut -Path (Join-Path -Path $linked -ChildPath 'LazyVM.lnk') -Target $exe -User $user 3>&1

        @(Get-ChildItem -LiteralPath $outside -Force).Count | Should -Be 0
        "$warning" | Should -BeLike '*No Start menu shortcut*junction, link or cloud placeholder*'
    }

    It 'does not replace a shortcut that is a link, warning' {
        $outside = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $outside | Out-Null
        New-Item -ItemType $linkType -Path $shortcut -Target $outside | Out-Null

        $warning = Install-StartMenuShortcut -Path $shortcut -Target $exe -User $user 3>&1

        Test-Path -LiteralPath $outside | Should -BeTrue
        "$warning" | Should -BeLike '*No Start menu shortcut*junction, link or cloud placeholder*'
    }

    It 'turns a failure into a warning, so the install still finishes' {
        Mock New-Object { throw 'Class not registered' } -ParameterFilter { $ComObject -eq 'WScript.Shell' }

        $warning = Install-StartMenuShortcut -Path $shortcut -Target $exe -User $user 3>&1

        "$warning" | Should -BeLike "*Could not add the Start menu shortcut*$shortcut*Class not registered*$exe*"
    }

    It 'smoke: adds it to the all-users Start menu, asked of Windows, once the app is installed, and only when it is' {
        $text = Get-Content -LiteralPath $installScript -Raw

        $text | Should -Match "\[Environment\]::GetFolderPath\('CommonPrograms'\)"
        $text | Should -Not -Match '\$env:ProgramData'
        $text.IndexOf('Install-StartMenuShortcut -Path') | Should -BeGreaterThan $text.IndexOf('Install-App -Source (Join-Path')
        $text | Should -Match 'if \(Test-Path -LiteralPath \$appExe -PathType Leaf\) \{\s*Install-StartMenuShortcut'
    }
}

Describe 'The folder the shortcut goes in, in Install.ps1 (#490, security rule 6)' {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
        foreach ($name in 'Get-ShortcutFolderProblem', 'Get-FolderAllowRule') {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        function New-TestRule { param($Sid, $Rights) [pscustomobject]@{ Sid = $Sid; Rights = [long][System.Security.AccessControl.FileSystemRights]$Rights; InheritOnly = $false } }
        $trusted = @(
            (New-TestRule 'S-1-5-32-544' 'FullControl'), (New-TestRule 'S-1-5-18' 'FullControl'),
            (New-TestRule 'S-1-5-32-545' 'ReadAndExecute'), (New-TestRule 'S-1-1-0' 'ReadAndExecute')
        )
    }

    It 'passes the folder as Windows sets it up: others can read it, and the signed-in user can only delete from it' {
        # Windows lets the signed-in user remove shortcuts from it, not add or change one.
        $rules = $trusted + (New-TestRule 'S-1-5-21-111-222-333-1001' 'Delete, DeleteSubdirectoriesAndFiles')
        Mock Get-FolderAllowRule { $rules }.GetNewClosure()

        Get-ShortcutFolderProblem -Path 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs' -Owner 'S-1-5-32-544' | Should -BeNullOrEmpty
    }

    It 'names who can <Case>' -ForEach @(
        @{ Case = 'add a file to it'; Rights = 'CreateFiles' }
        @{ Case = 'add a folder to it'; Rights = 'CreateDirectories' }
        @{ Case = 'change its permissions'; Rights = 'ChangePermissions' }
        @{ Case = 'take ownership of it'; Rights = 'TakeOwnership' }
        @{ Case = 'do anything to it'; Rights = 'FullControl' }
    ) {
        $rules = $trusted + (New-TestRule 'S-1-5-32-545' $Rights)
        Mock Get-FolderAllowRule { $rules }.GetNewClosure()

        Get-ShortcutFolderProblem -Path 'C:\Start' -Owner 'S-1-5-32-544' | Should -BeLike '*can be changed by S-1-5-32-545*'
    }

    It 'passes a right that applies to what is inside only' {
        $rules = $trusted + [pscustomobject]@{ Sid = 'S-1-3-0'; Rights = [long][System.Security.AccessControl.FileSystemRights]::FullControl; InheritOnly = $true }
        Mock Get-FolderAllowRule { $rules }.GetNewClosure()

        Get-ShortcutFolderProblem -Path 'C:\Start' -Owner 'S-1-5-32-544' | Should -BeNullOrEmpty
    }

    It 'names an owner other than administrators, SYSTEM and TrustedInstaller, who can change its permissions' {
        Mock Get-FolderAllowRule { $trusted }.GetNewClosure()

        Get-ShortcutFolderProblem -Path 'C:\Start' -Owner 'S-1-5-21-111-222-333-1001' | Should -BeLike '*owned by S-1-5-21-111-222-333-1001*'
    }
}

Describe 'Uninstalling, with Install.ps1 -Uninstall (#490)' {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
        foreach ($name in 'Test-ReparsePoint', 'Test-ReparsePointOnPath', 'Test-ContainsReparsePoint', 'Get-LazyVMHostTask', 'Get-UninstallPlan', 'Remove-InstalledItem', 'Unregister-LazyVMHostTask', 'Remove-EmptyInstallFolder') {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        function New-TestTask { param([string]$Name, [string]$TaskPath = '\') [pscustomobject]@{ TaskName = $Name; TaskPath = $TaskPath } }
    }

    BeforeEach {
        # An install: the locked folder with the app and the module, and the shortcut.
        $installDir = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        foreach ($folder in 'App', 'Modules/LazyVM/6.36.0') {
            New-Item -ItemType Directory -Path (Join-Path -Path $installDir -ChildPath $folder) -Force | Out-Null
        }
        Set-Content -LiteralPath (Join-Path -Path $installDir -ChildPath 'App/LazyVM.UI.Wpf.exe') -Value 'app'
        Set-Content -LiteralPath (Join-Path -Path $installDir -ChildPath 'Modules/LazyVM/6.36.0/LazyVM.psd1') -Value '@{}'
        $app = Join-Path -Path $installDir -ChildPath 'App'
        $modules = Join-Path -Path $installDir -ChildPath 'Modules'
        $shortcut = Join-Path -Path $TestDrive -ChildPath "$([guid]::NewGuid().ToString('N')).lnk"
        Set-Content -LiteralPath $shortcut -Value 'lnk'
        $outside = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $outside | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $outside -ChildPath 'keep.txt') -Value 'keep'
    }

    It 'finds LazyVM''s tasks on the host, each VM''s maintenance among them, and no other' {
        Mock Get-ScheduledTask {
            New-TestTask 'LazyVM-Maintain-Alpha'; New-TestTask 'LazyVM-ResumeAfterReboot-Beta'; New-TestTask 'LazyVM-Maintain-Beta'
            New-TestTask 'LazyVM-Other'; New-TestTask 'OneDrive Standalone Update Task'; New-TestTask 'LazyVM-Maintain-Gamma' '\Microsoft\'
        }

        @(Get-LazyVMHostTask | ForEach-Object { $_.TaskName }) | Should -Be @('LazyVM-Maintain-Alpha', 'LazyVM-ResumeAfterReboot-Beta', 'LazyVM-Maintain-Beta')
    }

    It 'names the tasks as the module does, so none is missed' {
        $constants = Get-Content -LiteralPath (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'src/LazyVM/Private/Common/Constants.ps1') -Raw
        $text = Get-Content -LiteralPath $installScript -Raw

        $constants | Should -Match '\$script:TaskPrefix = ''LazyVM-'''
        $constants | Should -Match '\$script:MaintenanceTaskPrefix = "\$\{script:TaskPrefix\}Maintain-"'
        $constants | Should -Match '\$script:ResumeTaskPrefix = "\$\{script:TaskPrefix\}ResumeAfterReboot-"'
        $text | Should -Match '\$hostTaskPrefixes = @\(''LazyVM-Maintain-'', ''LazyVM-ResumeAfterReboot-''\)'
    }

    It 'lists what goes and what stays, before anything is removed' {
        $tasks = @((New-TestTask 'LazyVM-Maintain-Alpha'), (New-TestTask 'LazyVM-ResumeAfterReboot-Beta'))
        $legacy = Join-Path -Path $installDir -ChildPath 'Legacy'
        New-Item -ItemType Directory -Path (Join-Path -Path $legacy -ChildPath 'LazyVM') -Force | Out-Null

        $plan = Get-UninstallPlan -InstallDir $installDir -ShortcutPath $shortcut -Task $tasks -DataFolder 'D:\DevVM'

        $plan.Remove | Should -Be @($shortcut, $app, $modules)
        $plan.Text | Should -BeLike "*Removes:*$shortcut*$app*$modules*PSModulePath*LazyVM-Maintain-Alpha*LazyVM-ResumeAfterReboot-Beta*nightly maintenance or security scan*"
        $plan.Text | Should -BeLike '*Keeps:*Hyper-V VMs*disks*D:\DevVM*settings, logs, templates*backups*stored passwords*recovery keys*'
        $plan.Text | Should -BeLike "*$legacy*"
        $plan.Text | Should -BeLike '*Remove-LazyVM*first*'
        Test-Path -LiteralPath $app | Should -BeTrue
    }

    It 'lists only what is there: no shortcut, no app and no tasks' {
        Remove-Item -LiteralPath $shortcut, $app -Recurse -Force

        $plan = Get-UninstallPlan -InstallDir $installDir -ShortcutPath $shortcut -Task @() -DataFolder 'D:\DevVM'

        $plan.Remove | Should -Be @($modules)
        $plan.Text | Should -Not -BeLike "*$shortcut*"
        $plan.Text | Should -Not -BeLike '*LazyVM-Maintain-*'
    }

    It 'removes <Case>, and says so' -ForEach @(
        @{ Case = 'the app'; Leaf = 'App' }
        @{ Case = 'the module'; Leaf = 'Modules' }
    ) {
        $path = Join-Path -Path $installDir -ChildPath $Leaf

        $said = Remove-InstalledItem -Path $path 6>&1

        Test-Path -LiteralPath $path | Should -BeFalse
        @(Get-ChildItem -LiteralPath $installDir -Force | Where-Object { $_.Name -like "$Leaf*" }).Count | Should -Be 0
        "$said" | Should -BeLike "*Removed $path*"
    }

    It 'removes the shortcut' {
        Remove-InstalledItem -Path $shortcut 6>&1 | Out-Null

        Test-Path -LiteralPath $shortcut | Should -BeFalse
    }

    It 'does nothing when it is not there' {
        $said = Remove-InstalledItem -Path (Join-Path -Path $installDir -ChildPath 'Missing') 6>&1 3>&1

        $said | Should -BeNullOrEmpty
    }

    It 'keeps an app that is running whole, and says to close it' {
        # Windows refuses to rename a folder while a program in it runs.
        Mock Rename-Item { throw 'The process cannot access the file because it is being used by another process.' }

        $warning = Remove-InstalledItem -Path $app 3>&1

        Test-Path -LiteralPath (Join-Path -Path $app -ChildPath 'LazyVM.UI.Wpf.exe') | Should -BeTrue
        "$warning" | Should -BeLike "*Could not remove $app*being used*Close LazyVM*Install.ps1 -Uninstall again*"
    }

    It 'keeps a folder that holds a link, warning, and removes nothing through it' {
        New-Item -ItemType $linkType -Path (Join-Path -Path $app -ChildPath 'Linked') -Target $outside | Out-Null

        $warning = Remove-InstalledItem -Path $app 3>&1

        Test-Path -LiteralPath (Join-Path -Path $app -ChildPath 'LazyVM.UI.Wpf.exe') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $outside -ChildPath 'keep.txt') | Should -BeTrue
        "$warning" | Should -BeLike "*Kept $app*junction, link or cloud placeholder*"
    }

    It 'keeps a shortcut that is a link, warning' {
        Remove-Item -LiteralPath $shortcut
        New-Item -ItemType $linkType -Path $shortcut -Target $outside | Out-Null

        $warning = Remove-InstalledItem -Path $shortcut 3>&1

        Test-Path -LiteralPath $shortcut | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $outside -ChildPath 'keep.txt') | Should -BeTrue
        "$warning" | Should -BeLike "*Kept $shortcut*junction, link or cloud placeholder*"
    }

    It 'turns a failed removal into a warning with the path, so the rest is still removed' {
        Mock Remove-Item { throw 'Access to the path is denied.' }

        $warning = Remove-InstalledItem -Path $shortcut 3>&1

        "$warning" | Should -BeLike "*Could not remove $shortcut*Access to the path is denied*"
    }

    It 'unregisters each task without asking again, lists each, and says what no longer runs' {
        Mock Unregister-ScheduledTask { }
        $tasks = @((New-TestTask 'LazyVM-Maintain-Alpha'), (New-TestTask 'LazyVM-ResumeAfterReboot-Beta'))

        $said = Unregister-LazyVMHostTask -Task $tasks 6>&1

        Should -Invoke Unregister-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'LazyVM-Maintain-Alpha' -and $TaskPath -eq '\' -and $Confirm -eq $false }
        Should -Invoke Unregister-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'LazyVM-ResumeAfterReboot-Beta' -and $Confirm -eq $false }
        "$said" | Should -BeLike '*Unregistered*LazyVM-Maintain-Alpha*Unregistered*LazyVM-ResumeAfterReboot-Beta*nightly maintenance*security scan*'
    }

    It 'names a task it could not unregister, and goes on to the next' {
        Mock Unregister-ScheduledTask { throw 'Access is denied.' } -ParameterFilter { $TaskName -eq 'LazyVM-Maintain-Alpha' }
        Mock Unregister-ScheduledTask { } -ParameterFilter { $TaskName -ne 'LazyVM-Maintain-Alpha' }
        $tasks = @((New-TestTask 'LazyVM-Maintain-Alpha'), (New-TestTask 'LazyVM-Maintain-Beta'))

        $said = Unregister-LazyVMHostTask -Task $tasks 3>&1 6>&1

        "$said" | Should -BeLike '*Could not unregister*LazyVM-Maintain-Alpha*Access is denied*Unregistered*LazyVM-Maintain-Beta*'
    }

    It 'says nothing about tasks when there are none' {
        Mock Unregister-ScheduledTask { }

        Unregister-LazyVMHostTask -Task @() 6>&1 3>&1 | Should -BeNullOrEmpty
    }

    It 'removes the install folder once it is empty, and keeps it while it holds anything' {
        Remove-Item -LiteralPath $app, $modules -Recurse -Force
        New-Item -ItemType Directory -Path (Join-Path -Path $installDir -ChildPath 'Legacy') | Out-Null

        Remove-EmptyInstallFolder -Path $installDir 6>&1 | Out-Null
        Test-Path -LiteralPath $installDir | Should -BeTrue

        Remove-Item -LiteralPath (Join-Path -Path $installDir -ChildPath 'Legacy')
        Remove-EmptyInstallFolder -Path $installDir 6>&1 | Out-Null
        Test-Path -LiteralPath $installDir | Should -BeFalse
    }

    It 'smoke: asks first, with the list, before it changes anything, and does not need a download beside it' {
        $text = Get-Content -LiteralPath $installScript -Raw
        $ask = $text.IndexOf('$PSCmdlet.ShouldProcess(')

        $text | Should -Match 'SupportsShouldProcess, ConfirmImpact = ''High'''
        $ask | Should -BeGreaterThan 0
        $ask | Should -BeLessThan $text.IndexOf('Unregister-LazyVMHostTask -Task $plan')
        $ask | Should -BeLessThan $text.IndexOf('Remove-InstalledItem -Path $item')
        $text.IndexOf('if ($Uninstall) {') | Should -BeLessThan $text.IndexOf('$versionDir = Get-ChildItem')
        $text | Should -Match 'Update-UserModulePath -Change \{ param\(\$List\) Remove-PathListEntry -List \$List -Entry \$modulesDir \}'
    }
}

Describe 'Locking the shortcut, in Install.ps1 (#490)' -Skip:(-not $IsWindows -or -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-LockedAccess' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    It 'gives a file only Administrators and SYSTEM full control, and the user read and run, nothing inherited, owned by Administrators' {
        $file = Join-Path -Path $TestDrive -ChildPath 'LazyVM.lnk'
        Set-Content -LiteralPath $file -Value 'lnk'
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User

        Set-LockedAccess -Path $file -User $user

        $acl = Get-Acl -LiteralPath $file
        $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-544'
        $acl.AreAccessRulesProtected | Should -BeTrue
        $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        @($rules | ForEach-Object { "$($_.IdentityReference.Value)=$($_.FileSystemRights)" } | Sort-Object) |
            Should -Be @(@('S-1-5-18=FullControl', 'S-1-5-32-544=FullControl', "$($user.Value)=ReadAndExecute, Synchronize") | Sort-Object)
    }
}

Describe 'The launchers in the release zip (#490)' {
    BeforeDiscovery {
        $launchers = @(
            @{ Name = 'Install LazyVM.cmd'; Arguments = '' }
            @{ Name = 'Uninstall LazyVM.cmd'; Arguments = ' -Uninstall' }
        )
    }

    BeforeAll {
        $src = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'src'
    }

    It '<Name> asks for elevation, and starts itself again elevated' -ForEach $launchers {
        $text = Get-Content -LiteralPath (Join-Path -Path $src -ChildPath $Name) -Raw

        $text | Should -Match 'fltmc >nul 2>&1\r\nif errorlevel 1 \('
        $text | Should -Match 'Start-Process -FilePath \$env:LAZYVM_SELF -Verb RunAs'
    }

    It '<Name> needs PowerShell 7.6 or later in Program Files, and otherwise says how to get it' -ForEach $launchers {
        $text = Get-Content -LiteralPath (Join-Path -Path $src -ChildPath $Name) -Raw

        $text | Should -Match 'set "PWSH=%ProgramFiles%\\PowerShell\\7\\pwsh\.exe"'
        $text | Should -Match 'if not exist "%PWSH%"'
        $text | Should -Match '\$PSVersionTable\.PSVersion -lt \[version\]''7\.6'''
        $text | Should -Match 'winget install Microsoft\.PowerShell'
    }

    It '<Name> runs Install.ps1<Arguments> beside it, with the execution policy bypassed for that run only, and waits' -ForEach $launchers {
        $text = Get-Content -LiteralPath (Join-Path -Path $src -ChildPath $Name) -Raw

        $text | Should -Match ([regex]::Escape("""%PWSH%"" -NoLogo -NoProfile -ExecutionPolicy Bypass -File ""%~dp0Install.ps1""$Arguments"))
        $text | Should -Match '\r\npause\r\n'
    }

    It '<Name> has Windows line endings and no byte order mark, as cmd.exe needs' -ForEach $launchers {
        $bytes = [IO.File]::ReadAllBytes((Join-Path -Path $src -ChildPath $Name))

        $bytes[0] | Should -Not -Be 0xEF
        ([Text.Encoding]::ASCII.GetString($bytes) -replace "`r`n") | Should -Not -Match "`n"
    }
}
