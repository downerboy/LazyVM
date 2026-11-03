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
        $text | Should -Match 'Set-InstallFolderAccess -Path \$installDir'
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
        foreach ($name in 'Test-ReparsePoint', 'Test-ContainsReparsePoint', 'Test-ModuleCopy', 'Get-EarlierCopyProblem', 'Remove-EarlierCopy', 'Move-EarlierCopy', 'Reset-InheritedAccess', 'Get-FirstModuleCopy', 'Write-ShadowingCopyWarning', 'Test-SameFolder') {
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
