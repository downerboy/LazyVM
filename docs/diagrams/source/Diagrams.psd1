@{
    # The page docs\Diagrams.md: its introduction and the order of the
    # diagrams. Each diagram's own source is <id>.psd1 beside this file.
    # After changing any of them, run ./Update-Diagram.ps1.
    Title     = 'LazyVM diagrams'
    Intro     = 'One diagram per thing you do with LazyVM. Each shows the calls in order down the middle, data read on the left and data written on the right. Every diagram is followed by the same information as a numbered list.'
    HowToRead = @(
        '**Blue arrows** are calls, numbered in the order they run.'
        '**Dashed orange arrows** are data, numbered D1, D2 and so on. An arrow into a call is data read; an arrow out of it is data written.'
        'Host paths are relative to the LazyVM folder (`HKLM:\SOFTWARE\LazyVM` `Root`), for example `D:\DevVM`. Inside the VM, `D:` is the SQL data disk, `W:` is the Dev Drive and `U:` is the User disk.'
        'Every command that works on one VM runs inside `Invoke-CommandRun`: it starts with `Initialize-CommandRun`, which builds the VM context and opens the log, and ends with `Complete-CommandRun`, which closes the guest session and the log. `Show-LazyVM`, `Set-LazyVMRoot`, `New-LazyVM`, `Export-LazyVMTemplate`, `Get-LazyVM`, `Get-LazyVMSetting`, `Get-LazyVMCredential` and `Test-LazyVM` do not.'
        'A call that happens only in some cases says so in its box. **Also runs** lists the functions a step calls for its work.'
    )
    Groups    = @(
        @{ Name = 'Install'; Diagrams = @('install-from-repo', 'install-from-release') }
        @{ Name = 'Set up'; Diagrams = @('show', 'set-root', 'new-profile', 'set-credential') }
        @{ Name = 'Build'; Diagrams = @('build') }
        @{ Name = 'Maintain'; Diagrams = @('maintenance', 'register-maintenance', 'rebuild') }
        @{ Name = 'Tooling'; Diagrams = @('tooling-record', 'tooling-view', 'restore-points', 'tooling-revert') }
        @{ Name = 'State'; Diagrams = @('capture', 'restore') }
        @{ Name = 'Templates'; Diagrams = @('export-template') }
        @{ Name = 'Remove'; Diagrams = @('remove') }
        @{ Name = 'Check'; Diagrams = @('status', 'settings', 'license', 'credential-view', 'test') }
    )
    Footer    = 'Drawn by `./Update-Diagram.ps1` from `docs/diagrams/source`, one source per diagram. When a command''s calls change, change its source and run it: the tests fail while a diagram names a function that does not exist, leaves out a call the code it covers makes, or has not been redrawn.'
}
