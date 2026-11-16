# LogReader.ps1 - Reads a VM's log back as entries, for Get-LazyVMLog (#305).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Write-LogEntry writes each entry as one line: the time, a marker for the
# level, then the message. A phase is the exception: its prefix starts with
# a line break, so the time stands alone on one line and "====== <phase>"
# follows on the next. A message with line breaks of its own goes on over
# the lines after it, which have no time.

# The marker Write-LogEntry writes for each level, and the level in words.
$script:LogLevelByMarker = @{ ' ' = 'Info'; '+' = 'OK'; '!' = 'Warning'; 'X' = 'Error' }
$script:LogTimeFormat = 'yyyy-MM-dd HH:mm:ss'

function New-LogEntry {
    <# One entry of a VM's log. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Makes a value; changes nothing.')]
    [OutputType('LazyVM.LogEntry')]
    param(
        [Parameter(Mandatory)][datetime]$Time,
        [Parameter(Mandatory)][string]$Level,
        [AllowEmptyString()][string]$Message = ''
    )

    return [pscustomobject]@{ PSTypeName = 'LazyVM.LogEntry'; Time = $Time; Level = $Level; Message = $Message }
}

function ConvertFrom-LogLine {
    <# The entries in the lines $Line of a log, in order. A line before the first entry that has no time is skipped. #>
    [OutputType('LazyVM.LogEntry')]
    param([AllowEmptyCollection()][AllowEmptyString()][string[]]$Line = @())

    $entry = $null
    $phaseTime = $null
    foreach ($text in $Line) {
        if ($null -ne $phaseTime) {
            # The line after a phase's time holds the phase.
            if ($text.StartsWith('====== ')) {
                if ($entry) { $entry }
                $entry = New-LogEntry -Time $phaseTime -Level Phase -Message $text.Substring(7).TrimEnd()
                $phaseTime = $null
                continue
            }
            $phaseTime = $null
        }

        $time = [datetime]::MinValue
        if ($text.Length -ge 19 -and [datetime]::TryParseExact($text.Substring(0, 19), $script:LogTimeFormat, [cultureinfo]::InvariantCulture, 'None', [ref]$time)) {
            $rest = $text.Substring(19)
            if ($rest.Trim() -eq '') {
                $phaseTime = $time
                continue
            }
            if ($rest -match '^  \[(.)\] ?(.*)$' -and $script:LogLevelByMarker.ContainsKey($Matches[1])) {
                if ($entry) { $entry }
                $entry = New-LogEntry -Time $time -Level $script:LogLevelByMarker[$Matches[1]] -Message $Matches[2].TrimEnd()
                continue
            }
        }

        # A line without a time goes on with the message before it.
        if ($entry) { $entry.Message = "$($entry.Message)`n$($text.TrimEnd())" }
    }
    if ($entry) { $entry }
}

function Read-LogLine {
    <#
      The lines of the log file $Path, read without locking it: a build or a
      maintenance run may be writing to it at the same time. Nothing when
      there is no log yet.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $stream = [System.IO.FileStream]::new($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false))
        while ($null -ne ($text = $reader.ReadLine())) { $text }
    }
    finally { $stream.Dispose() }
}
