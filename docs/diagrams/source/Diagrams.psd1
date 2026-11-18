@{
    # The page docs\Diagrams.md: its introduction and the order of the
    # diagrams. Each diagram's own source is <id>.psd1 beside this file.
    # After changing any of them, run ./Update-Diagram.ps1.
    Logo      = '<p align="center"><img src="images/logo.svg" alt="LazyVM logo" width="240"></p>'
    Title     = 'LazyVM diagrams'
    Intro     = 'One diagram per thing you do with LazyVM. Each shows the calls in order down the middle, data read on the left and data written on the right. Every diagram is followed by the same information as a numbered list.'
    HowToRead = @(
        '**Blue arrows** are calls, numbered in the order they run.'
        '**Dashed orange arrows** are data, numbered D1, D2 and so on. An arrow into a call is data read; an arrow out of it is data written.'
        'Host paths are relative to the LazyVM folder (`HKCU:\SOFTWARE\LazyVM` `Root`), for example `D:\DevVM`. Inside the VM, `D:` is the SQL data disk, `W:` is the Dev Drive and `U:` is the User disk.'
        'Every command that works on one VM runs inside `Invoke-CommandRun`: it starts with `Initialize-CommandRun`, which builds the VM context and opens the log, and ends with `Complete-CommandRun`, which closes the guest session and the log. A build, maintenance, a rebuild and a restore (`Restore-LazyVMTooling`) also hold the VM''s run lock, `<VM>\Config\Run.lock`, from the start of the run to its end, so only one of them changes a VM at a time; the one holding it records in `Run.json` what is running, its phase and how it ended (`RunState.ps1`). `Remove-LazyVM` holds it too, until the Hyper-V VM is gone and just before the folder that holds it is deleted. A restore or removal you do not confirm leaves `Run.json` as it was. `Stop-LazyVMBuild` asks a running build to stop by writing `<VM>\Config\Run.stop`, which the build checks for between phases, between steps and in `Wait-Until`. `Show-LazyVM`, `Set-LazyVMRoot`, `Convert-LazyVMInstallation`, `New-LazyVM`, `Export-LazyVMTemplate`, `Export-LazyVMRecoveryKey`, `Get-LazyVM`, `Get-LazyVMBuildPhase`, `Get-LazyVMConfigTemplate`, `Get-LazyVMDashboard`, `Get-LazyVMLog`, `Get-LazyVMSetting`, `Get-LazyVMCredential`, `Start-LazyVMMaintenance`, `Stop-LazyVMBuild` and `Test-LazyVM` do not.'
        'A call that happens only in some cases says so in its box. **Also runs** lists the functions a step calls for its work.'
    )
    Groups    = @(
        @{ Name = 'Install'; Diagrams = @('install-from-repo', 'install-from-release', 'convert-installation') }
        @{ Name = 'Set up'; Diagrams = @('show', 'set-root', 'new-profile', 'set-credential') }
        @{ Name = 'Build'; Diagrams = @('build', 'build-phases', 'stop-build') }
        @{ Name = 'Maintain'; Diagrams = @('maintenance', 'register-maintenance', 'start-maintenance', 'rebuild') }
        @{ Name = 'Tooling'; Diagrams = @('tooling-record', 'tooling-view', 'restore-points', 'tooling-revert') }
        @{ Name = 'State'; Diagrams = @('capture', 'restore') }
        @{ Name = 'Templates'; Diagrams = @('config-templates', 'export-template') }
        @{ Name = 'Remove'; Diagrams = @('remove') }
        @{ Name = 'Check'; Diagrams = @('status', 'dashboard', 'log', 'settings', 'license', 'credential-view', 'recovery-key-export', 'security-finding', 'security-approve', 'security-revoke', 'test') }
    )
    Footer    = 'Drawn by `./Update-Diagram.ps1` from `docs/diagrams/source`, one source per diagram. When a command''s calls change, change its source and run it: the tests fail while a diagram names a function that does not exist, leaves out a call the code it covers makes, or has not been redrawn.'
}
