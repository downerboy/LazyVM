# Logging.ps1 - Progress to the console and to the VM's log file.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The log is the one thing every function writes to, so it keeps its own
# state: the file the current command writes, set by Start-Log and cleared by
# Stop-Log. Lines written before Start-Log go to the console only.

$script:Log = @{ Path = $null }
$script:LogEncoding = [Text.UTF8Encoding]::new($false)

function Start-Log {
    <#
      Starts writing to $Path. A log bigger than $MaxSizeMB is renamed with a
      date-time first, so it cannot grow without limit across rebuilds.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][double]$MaxSizeMB
    )

    New-Folder -Path (Split-Path -Path $Path -Parent)
    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).Length / 1MB) -gt $MaxSizeMB) {
        $stem = [IO.Path]::Combine((Split-Path -Path $Path -Parent), [IO.Path]::GetFileNameWithoutExtension($Path))
        Move-Item -LiteralPath $Path -Destination ('{0}.{1}.log' -f $stem, (Get-Stamp)) -Force
    }
    $script:Log.Path = $Path
}

function Stop-Log {
    <# Stops writing to the log file; later lines go to the console only. #>
    $script:Log.Path = $null
}

function Test-LogStarted {
    return [bool]$script:Log.Path
}

function Write-LogEntry {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'LazyVM is a console tool: progress must show as it happens, and every line also goes to the log file. Write-Output would mix it into each function''s results.')]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$Message = '',

        # Position 1 must be explicit: declaring a Position on any parameter
        # removes the automatic positions from all the others.
        [Parameter(Position = 1)]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'PHASE')]
        [string]$Level = 'INFO'
    )

    $prefix, $color = switch ($Level) {
        'PHASE' { "`n====== ", 'Cyan' }
        'OK' { '  [+] ', 'Green' }
        'WARN' { '  [!] ', 'Yellow' }
        'ERROR' { '  [X] ', 'Red' }
        default { '  [ ] ', 'Gray' }
    }

    $line = '{0}{1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $prefix, $Message
    Write-Host $line -ForegroundColor $color

    if (-not $script:Log.Path) { return }
    # The logger must never throw: it runs inside catch blocks, and an
    # exception here would hide the error being reported. The encoding is
    # pinned because interpolated Windows messages and paths are not ASCII.
    try {
        [IO.File]::AppendAllText($script:Log.Path, ($line + "`r`n"), $script:LogEncoding)
    }
    catch {
        Write-Host "  [!] (log write failed: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

function Write-LogError {
    <# Logs an exception with its message, type and stack trace. #>
    param(
        [string]$Context,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    Write-LogEntry "$Context - $($ErrorRecord.Exception.Message)" 'ERROR'
    Write-LogEntry "    type : $($ErrorRecord.Exception.GetType().FullName)" 'INFO'
    foreach ($frame in @("$($ErrorRecord.ScriptStackTrace)" -split "`r?`n" | Where-Object { $_.Trim() })) {
        Write-LogEntry "    at   : $($frame.Trim())" 'INFO'
    }
}

function Write-LogList {
    <# Logs a heading, then each item indented under it, all at one level. #>
    param(
        [Parameter(Mandatory)][string]$Heading,
        [AllowEmptyCollection()][string[]]$Items = @(),
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )

    Write-LogEntry $Heading $Level
    foreach ($item in $Items) { Write-LogEntry "  $item" $Level }
}

function Write-GuestNote {
    <#
      Logs what a guest script reported. Guest scripts report each event as
      @{ Level; Text } (New-GuestNote in Guest.Helpers.ps1), so the level is
      decided where the event happens, never guessed from its wording.
    #>
    param([AllowNull()][object[]]$Notes = @())

    foreach ($note in @($Notes | Where-Object { $_ })) {
        $level = [RecordReader]::Text($note, 'Level')
        if ($level -notin 'INFO', 'WARN', 'ERROR', 'OK') { $level = 'INFO' }
        Write-LogEntry "  $([RecordReader]::Text($note, 'Text'))" $level
    }
}

function Test-GuestNoteFailed {
    <# True when a guest script reported a warning or an error. #>
    param([AllowNull()][object[]]$Notes = @())

    return [bool](@($Notes | Where-Object { $_ -and [RecordReader]::Text($_, 'Level') -in 'WARN', 'ERROR' }).Count)
}
