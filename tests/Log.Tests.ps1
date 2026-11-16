# Log.Tests.ps1
# Get-LazyVMLog (#305): a VM's log as entries (Time, Level, Message), for the
# GUI's log viewer and, later, build progress. It only reads, and reads while
# a build may still be writing.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    function Set-TestLog {
        <# Writes $Lines to a fresh log file and points the VM's settings at it. #>
        param([string[]]$Lines)
        $script:logPath = Join-Path -Path $TestDrive -ChildPath "$([guid]::NewGuid().ToString('N')).log"
        [System.IO.File]::WriteAllText($script:logPath, (($Lines -join "`r`n") + "`r`n"))
        $path = $script:logPath
        Mock -ModuleName $module Read-VMSetting { [pscustomobject]@{ VMName = 'Alpha'; Settings = @{ LogFile = $path } } }.GetNewClosure()
    }
}

Describe 'Get-LazyVMLog' {
    BeforeEach {
        Mock -ModuleName $module Resolve-LazyVMRoot { [pscustomobject]@{ Path = 'C:\LazyVM'; Source = 'a test' } }
    }

    It 'reads each line as an entry with its time, level in words and message' {
        Set-TestLog @(
            '2026-11-15 02:00:01  [ ] Starting maintenance'
            '2026-11-15 02:00:02  [+] Checkpoint made'
            '2026-11-15 02:00:03  [!] The SQL Server ISO is not there yet'
            '2026-11-15 02:00:04  [X] Windows Update failed'
        )

        $entries = @(Get-LazyVMLog -Name Alpha)

        $entries.Count | Should -Be 4
        $entries[0].Time | Should -Be ([datetime]'2026-11-15 02:00:01')
        @($entries.Level) | Should -Be @('Info', 'OK', 'Warning', 'Error')
        $entries[2].Message | Should -Be 'The SQL Server ISO is not there yet'
        $entries[0].PSObject.TypeNames | Should -Contain 'LazyVM.LogEntry'
    }

    It 'reads a phase, written as its time alone and the phase on the next line, as one entry' {
        Set-TestLog @(
            '2026-11-15 02:00:01  [ ] Before'
            '2026-11-15 02:00:05'
            '====== Phase 3: Windows Update'
            '2026-11-15 02:00:06  [ ] After'
        )

        $entries = @(Get-LazyVMLog -Name Alpha)

        $entries.Count | Should -Be 3
        $entries[1].Level | Should -Be 'Phase'
        $entries[1].Time | Should -Be ([datetime]'2026-11-15 02:00:05')
        $entries[1].Message | Should -Be 'Phase 3: Windows Update'
    }

    It 'adds a line without a time to the entry before it, as a message over several lines' {
        Set-TestLog @(
            '2026-11-15 02:00:01  [X] Could not start: first line'
            'second line'
            '2026-11-15 02:00:02  [ ] Next'
        )

        $entries = @(Get-LazyVMLog -Name Alpha)

        $entries.Count | Should -Be 2
        $entries[0].Message | Should -Be "Could not start: first line`nsecond line"
    }

    It 'keeps an empty entry, and the indent of a listed item' {
        Set-TestLog @(
            '2026-11-15 02:00:01  [ ] '
            '2026-11-15 02:00:02  [ ]   C:\LazyVM\Alpha'
        )

        $entries = @(Get-LazyVMLog -Name Alpha)

        $entries[0].Message | Should -Be ''
        $entries[1].Message | Should -Be '  C:\LazyVM\Alpha'
    }

    It 'gives only the newest entries with -Tail' {
        Set-TestLog @(1..5 | ForEach-Object { "2026-11-15 02:00:0$_  [ ] Line $_" })

        $entries = @(Get-LazyVMLog -Name Alpha -Tail 2)

        @($entries.Message) | Should -Be @('Line 4', 'Line 5')
    }

    It 'gives nothing, and no error, when the VM has no log yet' {
        Set-TestLog @()
        Remove-Item -LiteralPath $script:logPath

        $entries = @(Get-LazyVMLog -Name Alpha -ErrorAction Stop)

        $entries.Count | Should -Be 0
    }

    It 'reads the log while a build still has it open for writing' {
        Set-TestLog @('2026-11-15 02:00:01  [ ] Building')
        $writer = [System.IO.FileStream]::new($script:logPath, 'Append', 'Write', 'ReadWrite')
        try {
            $entries = @(Get-LazyVMLog -Name Alpha)
        }
        finally { $writer.Dispose() }

        $entries.Count | Should -Be 1
    }

    It 'refuses a log path that is a reparse point, as the logger does' {
        Set-TestLog @('2026-11-15 02:00:01  [ ] Building')
        Mock -ModuleName $module Assert-NoReparsePoint { throw 'is a link' }

        { Get-LazyVMLog -Name Alpha } | Should -Throw '*is a link*'
    }

    It 'reads the settings without writing anything' {
        Set-TestLog @('2026-11-15 02:00:01  [ ] Building')

        $null = Get-LazyVMLog -Name Alpha

        Should -Invoke -ModuleName $module Read-VMSetting -Times 1 -ParameterFilter { $ReadOnly -and $VMName -eq 'Alpha' }
    }
}
