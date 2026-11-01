# WingetUpgrade.Tests.ps1
# The nightly winget upgrades in the guest (#235): everything winget can
# upgrade, except Visual Studio and SQL Server, packages pinned with
# winget pin, and programs that are running. The guest is mocked; nothing
# here touches a VM.

BeforeDiscovery {
    # What Windows sets, for a test runner that is not Windows. Set before
    # discovery, as the test cases below are built from them.
    $windowsFolders = @{
        'windir'            = 'C:\Windows'
        'ProgramData'       = 'C:\ProgramData'
        'ProgramFiles'      = 'C:\Program Files'
        'ProgramFiles(x86)' = 'C:\Program Files (x86)'
        'LOCALAPPDATA'      = 'C:\Users\lazy\AppData\Local'
        'APPDATA'           = 'C:\Users\lazy\AppData\Roaming'
    }
    foreach ($name in $windowsFolders.Keys) {
        if (-not [Environment]::GetEnvironmentVariable($name)) { [Environment]::SetEnvironmentVariable($name, $windowsFolders[$name]) }
    }
}

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')

    $testVM = InModuleScope $module {
        $vm = [VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = 'C:\LazyVM\Setup' })
        $vm.Runtime.GuestAdminUser = 'lazy'
        $vm
    }
    $winget = 'C:\Users\lazy\AppData\Local\Microsoft\WindowsApps\winget.exe'
    # Get-CimInstance is Windows-only; the tests mock it.
    Add-MissingCommandStub -Stub @{ 'Get-CimInstance' = { param([string]$ClassName) throw "Get-CimInstance is a test stub; mock it ($ClassName)." } }

    function New-Upgrade {
        <# One package winget can upgrade, as Get-GuestWingetUpgrade reports it. #>
        param([string]$Id, [string[]]$Folders = @("C:\Program Files\$Id"))

        return [pscustomobject]@{ Id = $Id; Name = $Id; Folders = $Folders }
    }
}

Describe 'Test-WingetUpgradeAllowed (#235)' {
    It 'allows <Id>' -ForEach @(
        @{ Id = 'Git.Git' }
        @{ Id = 'Microsoft.VisualStudioCode' }
        @{ Id = 'Microsoft.Sqlcmd' }
        @{ Id = 'Microsoft.DotNet.SDK.10' }
    ) {
        InModuleScope $module -Parameters @{ Id = $Id } { param($Id) Test-WingetUpgradeAllowed -Id $Id } | Should -BeTrue
    }

    It 'never allows <Id>, which its own installer services' -ForEach @(
        @{ Id = 'Microsoft.VisualStudio.Community' }
        @{ Id = 'Microsoft.VisualStudio.2022.Professional' }
        @{ Id = 'Microsoft.SQLServer.2025.Developer' }
        @{ Id = 'Microsoft.SQLServerManagementStudio' }
    ) {
        InModuleScope $module -Parameters @{ Id = $Id } { param($Id) Test-WingetUpgradeAllowed -Id $Id } | Should -BeFalse
    }
}

Describe 'Resolve-GuestWingetId (#235)' {
    BeforeAll {
        $known = @('Git.Git', 'JetBrains.Toolbox', 'Microsoft.DotNet.DesktopRuntime.8', 'Microsoft.DotNet.DesktopRuntime.9')
        $ellipsis = [string][char]0x2026
    }

    It 'returns a whole id as it is' {
        Resolve-GuestWingetId -Id 'Git.Git' -KnownId $known | Should -Be 'Git.Git'
    }

    It 'completes an id winget cut short, from the one known id it starts' {
        Resolve-GuestWingetId -Id "JetBrains.Tool$ellipsis" -KnownId $known | Should -Be 'JetBrains.Toolbox'
    }

    It 'returns nothing when an id cut short could be more than one package' {
        Resolve-GuestWingetId -Id "Microsoft.DotNet.Desktop$ellipsis" -KnownId $known | Should -Be ''
    }
}

Describe 'Test-GuestWingetId (#235)' {
    BeforeAll {
        $ellipsis = [string][char]0x2026
    }

    It 'accepts a whole winget id' {
        Test-GuestWingetId -Id 'Git.Git' | Should -BeTrue
        Test-GuestWingetId -Id 'Microsoft.DotNet.SDK.10' | Should -BeTrue
    }

    It 'rejects text that is not an id, such as part of a footer line' {
        Test-GuestWingetId -Id '' | Should -BeFalse
        Test-GuestWingetId -Id "rade. Use the 'winget pin" | Should -BeFalse
        Test-GuestWingetId -Id 'numbers that cannot be de' | Should -BeFalse
    }

    It 'accepts an id winget cut short only when told to' {
        Test-GuestWingetId -Id "JetBrains.Tool$ellipsis" | Should -BeFalse
        Test-GuestWingetId -Id "JetBrains.Tool$ellipsis" -AllowCutShort | Should -BeTrue
    }
}

Describe 'Test-GuestProgramFolderUsable (#235)' {
    It 'accepts a program''s own folder: <Path>' -ForEach @(
        @{ Path = "$env:ProgramFiles\Git" }
        @{ Path = "$env:LOCALAPPDATA\Programs\Microsoft VS Code" }
        @{ Path = 'D:\Tools\Git' }
    ) {
        Test-GuestProgramFolderUsable -Path $Path | Should -BeTrue
    }

    It 'rejects a folder that would match more than the program: <Path>' -ForEach @(
        @{ Path = 'C:' }
        @{ Path = "$env:ProgramFiles" }
        @{ Path = "${env:ProgramFiles(x86)}" }
        @{ Path = "$env:LOCALAPPDATA" }
        @{ Path = "$env:LOCALAPPDATA\Programs" }
        @{ Path = "$env:APPDATA" }
        @{ Path = "$env:windir\Installer\{1234}" }
        @{ Path = "$env:ProgramData\Package Cache\{5678}" }
        @{ Path = '' }
    ) {
        Test-GuestProgramFolderUsable -Path $Path | Should -BeFalse
    }
}

Describe 'Get-GuestProgramFolder (#235)' {
    BeforeAll {
        $ellipsis = [string][char]0x2026
    }

    BeforeEach {
        Mock Get-ItemProperty {
            @(
                [pscustomobject]@{ DisplayName = 'Git'; InstallLocation = 'C:\Program Files\Git\'; DisplayIcon = '' }
                [pscustomobject]@{ DisplayName = 'Notepad++ (64-bit x64)'; InstallLocation = ''; DisplayIcon = '"C:\Program Files\Notepad++\notepad++.exe",0' }
                [pscustomobject]@{ DisplayName = 'Node.js'; InstallLocation = ''; DisplayIcon = 'C:\Windows\Installer\{1234}\icon.ico' }
                [pscustomobject]@{ DisplayName = 'Some Tool'; InstallLocation = ''; DisplayIcon = '' }
                [pscustomobject]@{ DisplayName = 'Bundle'; InstallLocation = ''; DisplayIcon = 'C:\ProgramData\Package Cache\{5678}\setup.exe,0' }
            )
        }
    }

    It 'returns the install location of the program with that name' {
        Get-GuestProgramFolder -Name 'Git' | Should -Be 'C:\Program Files\Git'
    }

    It 'falls back to the folder of its icon' {
        Get-GuestProgramFolder -Name 'Notepad++ (64-bit x64)' | Should -Be 'C:\Program Files\Notepad++'
    }

    It 'matches a name winget cut short by how it starts' {
        Get-GuestProgramFolder -Name "Notepad++ (64$ellipsis" | Should -Be 'C:\Program Files\Notepad++'
    }

    It 'returns nothing for a program whose only clue is in the Windows folder, or that has none' {
        @(Get-GuestProgramFolder -Name 'Node.js').Count | Should -Be 0
        @(Get-GuestProgramFolder -Name 'Some Tool').Count | Should -Be 0
        @(Get-GuestProgramFolder -Name 'Bundle').Count | Should -Be 0
    }
}

Describe 'Update-GuestWingetPackage (#235)' {
    BeforeEach {
        Mock -ModuleName $module Write-LogEntry { }
        Mock -ModuleName $module Write-GuestNote { }
        Mock -ModuleName $module Invoke-GuestScript { $winget } -ParameterFilter { $Activity -eq 'finding winget' }
        Mock -ModuleName $module Get-GuestSignedInUser { 'lazy' }
        Mock -ModuleName $module Get-GuestWingetUpgrade { New-Upgrade -Id 'Git.Git' }
        Mock -ModuleName $module Invoke-GuestTask { '[{"Level":"OK","Text":"upgraded: Git.Git"}]' }
    }

    It 'upgrades from a task running as the guest account elevated, so per-user packages upgrade too' {
        $result = @(InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM })

        $result.Count | Should -Be 0
        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -like '*winget-upgrade' -and $AsGuestUser -and $Elevated -and $TimeoutMinutes -gt 0 -and
            "$Work" -match 'winget upgrade|& \$winget upgrade' -and "$Work" -match 'ExecutablePath'
        }
        Should -Invoke -ModuleName $module Write-GuestNote -Times 1 -Exactly -ParameterFilter { @($Notes).Text -contains 'upgraded: Git.Git' }
    }

    It 'passes the task the packages to upgrade, with the folders that tell whether each is running' {
        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            $packages = @($ArgumentList[1])
            $ArgumentList[0] -eq $winget -and $packages.Count -eq 1 -and $packages[0].Id -eq 'Git.Git' -and @($packages[0].Folders) -contains 'C:\Program Files\Git.Git'
        }
    }

    It 'shares the winget exit-code table with the installs' {
        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[2]['-1978335212'] -eq 'no package matched that identifier'
        }
    }

    It 'never upgrades Visual Studio or SQL Server, and says so' {
        Mock -ModuleName $module Get-GuestWingetUpgrade { New-Upgrade -Id 'Microsoft.VisualStudio.Community'; New-Upgrade -Id 'Microsoft.SQLServer.2025.Developer'; New-Upgrade -Id 'Git.Git' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter { (@($ArgumentList[1]).Id -join ',') -eq 'Git.Git' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 2 -Exactly -ParameterFilter { $Message -match 'Microsoft\.(VisualStudio|SQLServer)' -and $Message -match 'own installer' }
    }

    It 'still upgrades a package whose install folder is unknown, without a running check (Sean, #235)' {
        Mock -ModuleName $module Get-GuestWingetUpgrade { New-Upgrade -Id 'Some.Tool' -Folders @(); New-Upgrade -Id 'Git.Git' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter { (@($ArgumentList[1]).Id -join ',') -eq 'Some.Tool,Git.Git' }
        Should -Invoke -ModuleName $module Write-LogEntry -Times 0 -ParameterFilter { $Message -match 'skipped Some\.Tool' }
    }

    It 'starts no task when nothing is to be upgraded' {
        Mock -ModuleName $module Get-GuestWingetUpgrade { }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Level -eq 'OK' -and $Message -match 'up to date' }
    }

    It 'skips tonight, and says why, when the guest account is not signed in to run the upgrades in' {
        Mock -ModuleName $module Get-GuestSignedInUser { 'someoneelse' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

        Should -Invoke -ModuleName $module Get-GuestWingetUpgrade -Times 0
        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -match 'lazy' -and $Message -match 'not signed in' }
    }

    It 'skips, and says why, when the guest has no winget' {
        Mock -ModuleName $module Invoke-GuestScript { $null } -ParameterFilter { $Activity -eq 'finding winget' }

        InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

        Should -Invoke -ModuleName $module Invoke-GuestTask -Times 0
        Should -Invoke -ModuleName $module Write-LogEntry -Times 1 -Exactly -ParameterFilter { $Message -match 'winget is not available' }
    }

    Context 'the work the task runs' {
        BeforeAll {
            # Stands in for winget.exe, recording each upgrade.
            function Invoke-FakeWinget {
                $script:upgraded.Add($args[2])
                $global:LASTEXITCODE = 0
            }
        }

        BeforeEach {
            $script:upgraded = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName $module Get-GuestWingetUpgrade { New-Upgrade -Id 'Git.Git' -Folders @('D:\Tools\Git'); New-Upgrade -Id 'Some.Tool' -Folders @('D:\Tools\Some') }
            Mock Get-CimInstance { [pscustomobject]@{ Name = 'git.exe'; ExecutablePath = 'D:\Tools\Git\cmd\git.exe' }; [pscustomobject]@{ Name = 'other.exe'; ExecutablePath = 'D:\Tools\Something\other.exe' } }
            # Runs the work as the guest's task wrapper does: the script from
            # text, its arguments through JSON, and only its last line kept.
            Mock -ModuleName $module Invoke-GuestTask {
                $arguments = @(ConvertTo-Json -InputObject @($ArgumentList) -Depth 5 | ConvertFrom-Json)
                $arguments[0] = 'Invoke-FakeWinget'
                "$(@(& ([scriptblock]::Create($Work.ToString())) @arguments)[-1])"
            }
        }

        It 'skips a package whose program is running, matching its folder exactly, and upgrades the rest' {
            InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

            ($script:upgraded -join ',') | Should -Be 'Some.Tool'
            Should -Invoke -ModuleName $module Write-GuestNote -Times 1 -Exactly -ParameterFilter {
                @($Notes).Text -contains 'upgraded: Some.Tool' -and @(@($Notes).Text -like 'skipped: Git.Git - running (git.exe)*').Count -eq 1
            }
        }

        It 'upgrades a package with no known folder, and says it had no running check' {
            Mock -ModuleName $module Get-GuestWingetUpgrade { New-Upgrade -Id 'Some.Tool' -Folders @() }

            InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

            ($script:upgraded -join ',') | Should -Be 'Some.Tool'
            Should -Invoke -ModuleName $module Write-GuestNote -Times 1 -Exactly -ParameterFilter {
                @($Notes | Where-Object { $_.Level -eq 'INFO' -and $_.Text -like 'upgraded without a running check: Some.Tool*' }).Count -eq 1
            }
        }

        It 'starts no upgrade once its time is up, so the task is not stopped in the middle of one, and says they are tried again tomorrow' {
            Mock -ModuleName $module Invoke-GuestTask {
                $arguments = @(ConvertTo-Json -InputObject @($ArgumentList) -Depth 5 | ConvertFrom-Json)
                $arguments[0] = 'Invoke-FakeWinget'
                $arguments[3] = 0
                "$(@(& ([scriptblock]::Create($Work.ToString())) @arguments)[-1])"
            }

            InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

            $script:upgraded.Count | Should -Be 0
            Should -Invoke -ModuleName $module Write-GuestNote -Times 1 -Exactly -ParameterFilter { @(@($Notes).Text -like 'not started: *tried again tomorrow').Count -eq 2 }
        }

        It 'gives itself less time than the task has' {
            InModuleScope $module -Parameters @{ VM = $testVM } { param($VM) Update-GuestWingetPackage -VM $VM }

            Should -Invoke -ModuleName $module Invoke-GuestTask -Times 1 -Exactly -ParameterFilter { $ArgumentList[3] -gt 0 -and $ArgumentList[3] -le $TimeoutMinutes - 10 }
        }
    }
}

Describe 'Get-GuestWingetUpgrade (#235)' {
    BeforeAll {
        $ellipsis = [string][char]0x2026
        # What winget upgrade prints, footer lines and all.
        $script:upgradeOutput = @(
            'Name                       Id                       Version   Available Source'
            '-------------------------------------------------------------------------------'
            'Git                        Git.Git                  2.46.0    2.47.0    winget'
            "JetBrains Toolbox App      JetBrains.Tool$ellipsis          2.4.1     2.5.0     winget"
            "Microsoft Visual Studio C$ellipsis Microsoft.VisualStudio.$ellipsis 17.10.4   17.11.0   winget"
            '3 upgrades available.'
            '1 package(s) have pins that prevent upgrade. Use the ''winget pin'' command to view and edit pins. Using the --include-pinned argument may show more results.'
            '2 package(s) have version numbers that cannot be determined. Use --include-unknown to see all results.'
        )
        $script:exportJson = '{"Sources":[{"Packages":[{"PackageIdentifier":"Git.Git"},{"PackageIdentifier":"JetBrains.Toolbox"},{"PackageIdentifier":"Microsoft.VisualStudio.Community"}],"SourceDetails":{"Name":"winget"}}]}'

        # Stands in for winget.exe: 'upgrade' prints the table, 'export' writes the file.
        function Invoke-FakeWinget {
            if ($args[0] -eq 'upgrade') { return $script:upgradeOutput }
            $output = $args[[array]::IndexOf($args, '--output') + 1]
            Set-Content -LiteralPath $output -Value $script:exportJson
        }
    }

    BeforeEach {
        Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'Git'; InstallLocation = 'D:\Tools\Git'; DisplayIcon = '' } }
        $listVM = InModuleScope $module -Parameters @{ SetupDir = "$TestDrive" } { param($SetupDir) [VMContext]::new(@{ VMName = 'Alpha'; GuestSetupDir = $SetupDir }) }
        # Runs the script block here, as it would run in the guest, where the guest helpers are.
        Mock -ModuleName $module Invoke-GuestScript { & ([scriptblock]::Create($ScriptBlock.ToString())) @ArgumentList }
    }

    It 'lists each package winget can upgrade from its own source, with its folders, and no footer line as a package' {
        $result = @(InModuleScope $module -Parameters @{ VM = $listVM; Winget = 'Invoke-FakeWinget' } { param($VM, $Winget) Get-GuestWingetUpgrade -VM $VM -Winget $Winget })

        ($result.Id -join ',') | Should -Be 'Git.Git,JetBrains.Toolbox,Microsoft.VisualStudio.Community'
        @($result[0].Folders) | Should -Be @('D:\Tools\Git')
        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { "$ScriptBlock" -match 'upgrade --source winget' }
    }

    It 'reads winget''s output as UTF-8, so the ellipsis it cuts names short with survives' {
        $null = InModuleScope $module -Parameters @{ VM = $listVM; Winget = 'Invoke-FakeWinget' } { param($VM, $Winget) Get-GuestWingetUpgrade -VM $VM -Winget $Winget }

        Should -Invoke -ModuleName $module Invoke-GuestScript -Times 1 -Exactly -ParameterFilter { "$ScriptBlock" -match '\[Console\]::OutputEncoding = \[Text\.Encoding\]::UTF8' }
    }
}
