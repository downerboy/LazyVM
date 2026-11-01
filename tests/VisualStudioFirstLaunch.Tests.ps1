# VisualStudioFirstLaunch.Tests.ps1
# Visual Studio's first launch, driven with Windows UI Automation so the
# build can import the captured settings straight away (#268). On any
# mismatch the build goes on and nightly maintenance imports them (#266).
# The guest is mocked; the UI Automation script itself runs only in a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
    $guestScript = Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.VisualStudioFirstLaunch.ps1'
    $settings = @{
        VMName              = 'Alpha'
        GuestSetupDir       = 'C:\LazyVMSetup'
        GuestAdminUser      = 'devadmin'
        InstallVisualStudio = $true
    }
}

Describe 'Complete-GuestVisualStudioFirstLaunch' {
    BeforeEach {
        $logged = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Write-LogEntry { $logged.Add("$($Level): $Message") }
        $states = [System.Collections.Generic.Queue[object]]::new()
        $states.Enqueue([pscustomobject]@{ Marker = 'Pending'; OpenedOnce = $false; DevenvRunning = $false })
        $states.Enqueue([pscustomobject]@{ Marker = 'Pending'; OpenedOnce = $true; DevenvRunning = $false })
        Mock -ModuleName $module Get-GuestVisualStudioSettingState { $states.Dequeue() }
        $copied = @{ Text = $null; GuestPath = $null }
        Mock -ModuleName $module Copy-ToGuest { $copied.Text = Get-Content -LiteralPath $HostPath -Raw; $copied.GuestPath = $GuestPath }
        Mock -ModuleName $module Invoke-GuestScriptAsInteractiveUser { }
        Mock -ModuleName $module Stop-GuestVisualStudioFirstLaunch { }
        $vs = [pscustomobject]@{ DisplayName = 'Visual Studio Community 2026'; DevEnvPath = 'C:\VS\devenv.exe'; InstanceId = 'a1b2c3d4' }
        $complete = { InModuleScope $module -Parameters @{ Settings = $settings; VisualStudio = $vs } { param($Settings, $VisualStudio) Complete-GuestVisualStudioFirstLaunch -VM ([VMContext]::new($Settings)) -VisualStudio $VisualStudio } }
    }

    It 'does nothing when Visual Studio has been opened once already' {
        $states.Clear()
        $states.Enqueue([pscustomobject]@{ Marker = 'Pending'; OpenedOnce = $true; DevenvRunning = $false })

        & $complete | Should -BeTrue

        Should -Invoke -ModuleName $module Invoke-GuestScriptAsInteractiveUser -Times 0 -Exactly
    }

    It 'puts the UI Automation script in the guest, where it can also be run by hand, and runs it in the signed-in user''s session' {
        & $complete | Should -BeTrue

        # ? for the path separators, which are / where the tests run on Linux.
        $copied.GuestPath | Should -BeLike 'C:?LazyVMSetup?VisualStudioFirstLaunch.ps1'
        $copied.Text | Should -Be (Get-Content -LiteralPath $guestScript -Raw)
        Should -Invoke -ModuleName $module Invoke-GuestScriptAsInteractiveUser -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -like 'C:?LazyVMSetup?VisualStudioFirstLaunch.ps1' -and
            $ArgumentList[1] -like 'C:?LazyVMSetup?VisualStudioFirstLaunch.txt' -and
            $ArgumentList[2] -like 'C:?LazyVMSetup?VisualStudioFirstLaunch.pid' -and
            $ArgumentList[3] -eq 'C:\VS\devenv.exe'
        }
    }

    It 'presses the controls in the one table of AutomationIds, in its order' {
        $table = InModuleScope $module { $script:VisualStudioFirstLaunchControl }

        & $complete

        Should -Invoke -ModuleName $module Invoke-GuestScriptAsInteractiveUser -Times 1 -Exactly -ParameterFilter {
            (@($ArgumentList[4] | ForEach-Object { $_.AutomationId }) -join ',') -eq (@($table | ForEach-Object { $_.AutomationId }) -join ',')
        }
    }

    It 'gives the guest task longer than the script gets, so the guest stops Visual Studio and says why' {
        & $complete

        Should -Invoke -ModuleName $module Invoke-GuestScriptAsInteractiveUser -Times 1 -Exactly -ParameterFilter { $TimeoutMinutes -gt $ArgumentList[5] }
    }

    It 'returns false and logs the guest''s reason, without throwing, when the first launch cannot be automated' {
        $states.Clear()
        $states.Enqueue([pscustomobject]@{ Marker = 'Pending'; OpenedOnce = $false; DevenvRunning = $false })
        $states.Enqueue([pscustomobject]@{ Marker = 'Pending'; OpenedOnce = $false; DevenvRunning = $false })
        Mock -ModuleName $module Invoke-GuestScriptAsInteractiveUser { throw "Visual Studio's first launch failed in the guest: did not show 'Start Visual Studio'" }

        & $complete | Should -BeFalse

        $logged | Where-Object { $_ -like "WARN:*first launch*did not show 'Start Visual Studio'*" } | Should -Not -BeNullOrEmpty
    }

    It 'goes by whether Visual Studio was opened, not by how the guest task ended' {
        Mock -ModuleName $module Invoke-GuestScriptAsInteractiveUser { throw 'the host gave up waiting' }

        & $complete | Should -BeTrue
    }

    It 'stops the Visual Studio it started, by its process id, when the guest task did not finish' {
        Mock -ModuleName $module Invoke-GuestScriptAsInteractiveUser { throw 'the host gave up waiting' }

        & $complete

        Should -Invoke -ModuleName $module Stop-GuestVisualStudioFirstLaunch -Times 1 -Exactly -ParameterFilter { $ProcessIdPath -like 'C:?LazyVMSetup?VisualStudioFirstLaunch.pid' }
    }

    It 'stops nothing when the guest task finished' {
        & $complete

        Should -Invoke -ModuleName $module Stop-GuestVisualStudioFirstLaunch -Times 0 -Exactly
    }

    It 'returns false and logs why when Visual Studio closed without saving its settings backup' {
        $states.Clear()
        $states.Enqueue([pscustomobject]@{ Marker = 'Pending'; OpenedOnce = $false; DevenvRunning = $false })
        $states.Enqueue([pscustomobject]@{ Marker = 'Pending'; OpenedOnce = $false; DevenvRunning = $false })

        & $complete | Should -BeFalse

        $logged | Where-Object { $_ -like 'WARN:*settings backup*' } | Should -Not -BeNullOrEmpty
    }

    It 'leaves a Visual Studio that is already running alone' {
        $states.Clear()
        $states.Enqueue([pscustomobject]@{ Marker = 'Pending'; OpenedOnce = $false; DevenvRunning = $true })

        & $complete | Should -BeFalse

        Should -Invoke -ModuleName $module Invoke-GuestScriptAsInteractiveUser -Times 0 -Exactly
        $logged | Where-Object { $_ -like 'WARN:*running*' } | Should -Not -BeNullOrEmpty
    }

    It 'returns false and logs why, without throwing, when the guest cannot be asked' {
        Mock -ModuleName $module Get-GuestVisualStudioSettingState { throw 'session dropped' }

        & $complete | Should -BeFalse

        $logged | Where-Object { $_ -like 'WARN:*session dropped*' } | Should -Not -BeNullOrEmpty
    }
}

Describe 'Stop-GuestVisualStudioFirstLaunch' {
    BeforeAll {
        # Mock replaces only a command that exists, and taskkill.exe exists only on Windows.
        function taskkill.exe { }
    }

    BeforeEach {
        $task = @{ Work = $null; Arguments = $null }
        Mock -ModuleName $module Invoke-GuestScript { $task.Work = $ScriptBlock; $task.Arguments = $ArgumentList }
        InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) Stop-GuestVisualStudioFirstLaunch -VM ([VMContext]::new($Settings)) -ProcessIdPath 'C:\LazyVMSetup\VisualStudioFirstLaunch.pid' }

        <# The guest work, from its text, with the process id file holding $Recorded and Get-Process finding $Process. #>
        $runWork = {
            param($Recorded, $Process)
            $guest = @{ Recorded = $Recorded; Process = $Process }
            Mock Test-Path { $null -ne $guest.Recorded }
            Mock Get-Content { $guest.Recorded }
            Mock Get-Process { $guest.Process }
            Mock Remove-Item { }
            Mock taskkill.exe { }
            $work = [scriptblock]::Create($task.Work.ToString())
            & $work @($task.Arguments)
        }
    }

    It 'stops the process tree of the devenv whose id the script recorded, by id' {
        & $runWork '4242' ([pscustomobject]@{ Id = 4242; ProcessName = 'devenv' })

        Should -Invoke taskkill.exe -Times 1 -Exactly -ParameterFilter { "$args" -eq '/PID 4242 /T /F' }
        Should -Invoke Get-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 4242 }
        Should -Invoke Remove-Item -Times 1 -Exactly
    }

    It 'leaves a process alone that is not devenv, as when the id was reused' {
        & $runWork '4242' ([pscustomobject]@{ Id = 4242; ProcessName = 'notepad' })

        Should -Invoke taskkill.exe -Times 0 -Exactly
    }

    It 'stops nothing when the script recorded no process' {
        & $runWork $null $null

        Should -Invoke taskkill.exe -Times 0 -Exactly
        Should -Invoke Get-Process -Times 0 -Exactly
    }
}

Describe 'Restore-GuestVisualStudioSetting with the first launch automated' {
    BeforeEach {
        $logged = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Write-LogEntry { $logged.Add("$($Level): $Message") }
        $vs = [pscustomobject]@{ DisplayName = 'Visual Studio Community 2026'; DevEnvPath = 'C:\VS\devenv.exe'; InstanceId = 'a1b2c3d4' }
        $toApply = [pscustomobject]@{ Text = '<UserSettings/>'; HasBackup = $true; BackupHash = 'HASH'; ProjectsLocation = $null }
        Mock -ModuleName $module Get-VisualStudioSettingTarget { [pscustomobject]@{ VisualStudio = $vs; Settings = $toApply } }
        Mock -ModuleName $module Get-GuestSignedInUser { @('devadmin') }
        $calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName $module Write-VisualStudioSettingMarker { $calls.Add('marker') }
        Mock -ModuleName $module Complete-GuestVisualStudioFirstLaunch { $calls.Add('first launch'); $true }
        Mock -ModuleName $module Import-GuestVisualStudioSetting { $calls.Add('import') }
        $restore = { InModuleScope $module -Parameters @{ Settings = $settings } { param($Settings) Restore-GuestVisualStudioSetting -VM ([VMContext]::new($Settings)) } }
    }

    It 'imports the settings straight after Visual Studio''s first launch' {
        & $restore

        $calls -join ',' | Should -Be 'marker,first launch,import'
    }

    It 'leaves the settings pending for nightly maintenance, and does not fail, when the first launch could not be automated' {
        Mock -ModuleName $module Complete-GuestVisualStudioFirstLaunch { $calls.Add('first launch'); $false }

        { & $restore } | Should -Not -Throw

        $calls -join ',' | Should -Be 'marker,first launch'
        $logged | Where-Object { $_ -like 'WARN:*retried automatically*nightly*' } | Should -Not -BeNullOrEmpty
    }

    It 'does not open Visual Studio when it is turned off in the settings' {
        Mock -ModuleName $module Get-VisualStudioSettingTarget { $null }

        & $restore

        Should -Invoke -ModuleName $module Complete-GuestVisualStudioFirstLaunch -Times 0 -Exactly
    }
}

Describe 'The first-launch UI Automation script' {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($guestScript, [ref]$tokens, [ref]$errors)
    }

    It 'parses' {
        $errors | Should -BeNullOrEmpty
    }

    It 'dumps the UI Automation tree with only -TreePath, for running by hand in a guest' {
        $mandatory = @($ast.ParamBlock.Parameters | Where-Object {
                $_.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' -and $_.NamedArguments.ArgumentName -contains 'Mandatory' -and -not ($_.NamedArguments | Where-Object ArgumentName -EQ 'ParameterSetName') }
            } | ForEach-Object { $_.Name.VariablePath.UserPath })
        $mandatory | Should -Be @('TreePath')
    }

    It 'takes a time limit of at least one minute' {
        $timeout = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'TimeoutMinutes' }
        $timeout.Attributes.TypeName.Name | Should -Contain 'ValidateRange'
    }

    It 'records the devenv it starts in -ProcessIdPath, so the host can stop it by id' {
        @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Contain 'ProcessIdPath'
    }

    It 'holds no AutomationId of its own: they live in one table in the module' {
        $text = Get-Content -LiteralPath $guestScript -Raw
        foreach ($control in (InModuleScope $module { $script:VisualStudioFirstLaunchControl })) {
            $text | Should -Not -BeLike "*$($control.AutomationId)*"
        }
    }
}
