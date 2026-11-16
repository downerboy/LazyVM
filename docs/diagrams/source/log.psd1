@{
    Id         = 'log'
    Title      = 'Read a VM''s log'
    Command    = 'Get-LazyVMLog'
    Parameters = @('-Name <VM>  (optional with one VM)', '-Tail <count>  (optional)')
    Summary    = 'Reads the VM''s log as entries: time, level (Info, OK, Warning, Error or Phase) and message. Only reads, without locking the log, so it works while a build is writing it. No administrator rights needed.'
    Covers     = @('Get-LazyVMLog', 'ConvertFrom-LogLine', 'Read-LogLine', 'New-LogEntry')
    Omits      = @{}
    Steps      = @(
        @{
            Function = 'Resolve-LazyVMRoot'
            Area     = 'Settings'
            Note     = 'the LazyVM folder'
            Reads    = @(
                @{ Label = 'LazyVM folder'; Kind = 'registry'; Store = 'HKCU:\SOFTWARE\LazyVM'; Items = @('Root') }
            )
        }
        @{
            Function = 'Read-VMSetting'
            Area     = 'Settings'
            Note     = 'read-only: where the VM''s log is'
            Reads    = @(
                @{ Label = 'settings'; Kind = 'file'; Store = 'Settings files'; Items = @('Shared\Config\LazyVM.Settings.json', '<VM>\Config\VM.json') }
            )
        }
        @{
            Function = 'Assert-NoReparsePoint'
            Area     = 'Common'
            Note     = 'stops if the log or a folder above it is a link, as the logger does'
        }
        @{
            Function = 'Read-LogLine'
            Area     = 'Logging'
            Note     = 'the lines, read without locking the file; none when there is no log yet'
            Reads    = @(
                @{ Label = 'log'; Kind = 'file'; Store = '<VM>\Logs\'; Items = @('<VM>.log') }
            )
        }
        @{
            Function = 'ConvertFrom-LogLine'
            Area     = 'Logging'
            Note     = 'one entry per line written; a phase''s two lines and a message''s later lines join their entry'
            Includes = @('New-LogEntry')
            Writes   = @(
                @{ Label = 'entries'; Kind = 'output'; Store = 'Pipeline'; Items = @('LazyVM.LogEntry: Time, Level, Message', 'only the newest with -Tail') }
            )
        }
    )
}
