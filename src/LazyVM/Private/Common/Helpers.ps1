# Helpers.ps1 - Small shared helpers: files, sizes and waiting.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function Test-IsoFile {
    <#
      A real ISO 9660 image carries the 'CD001' volume descriptor identifier at
      offset 0x8001. This tells a genuine image from the HTML page Microsoft's
      evaluation link returns instead of the file.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -lt 0x8006) { return $false }

    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        $null = $stream.Seek(0x8001, [IO.SeekOrigin]::Begin)
        $buffer = [byte[]]::new(5)
        if ($stream.Read($buffer, 0, 5) -ne 5) { return $false }
        return ([Text.Encoding]::ASCII.GetString($buffer) -eq 'CD001')
    }
    catch { return $false }
    finally { if ($stream) { $stream.Dispose() } }
}

function Write-TextFileAtomic {
    <#
      Writes a text file so that it is either the old file or the new one,
      never half of each: the text goes to a temporary file in the same
      folder, which then replaces the original in one step. UTF-8, no BOM.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $folder = Split-Path -Path $Path -Parent
    if ($folder -and -not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    $temp = Join-Path -Path $folder -ChildPath ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temp, $Text, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function New-Folder {
    <# Creates a folder, and any parents, if it is not there yet. #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-FreeSpaceGB {
    <# Free space on the volume that holds $Path, or -1 when it cannot be read. #>
    param([Parameter(Mandatory)][string]$Path)

    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
    $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($root.TrimEnd('\'))'"
    if (-not $drive) { return -1 }
    return [math]::Round($drive.FreeSpace / 1GB, 1)
}

function Format-Size {
    <# Bytes as a readable size: 4.2 MB rather than 0 GB. #>
    param([Parameter(Mandatory)][double]$Bytes)

    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} bytes' -f $Bytes)
}

function Get-Stamp {
    <# The current date and time as used in checkpoint and file names. #>
    return (Get-Date -Format $script:StampFormat)
}

function Wait-Until {
    <#
      Runs $Condition every $Interval until it returns something true, and
      returns that. On timeout, throws "<Activity> did not finish within ...",
      or returns $null with -NoThrow.

      $Condition runs in a scope of its own: anything it must remember from
      one try to the next goes in a table the caller passes in as $State.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [Parameter(Mandatory)][timespan]$Timeout,
        [timespan]$Interval = [timespan]::FromSeconds(10),
        [string]$Activity = 'the wait',
        [hashtable]$State = @{},
        [switch]$NoThrow
    )

    $waitDeadline = [datetime]::UtcNow + $Timeout
    while ($true) {
        $waitResult = & $Condition $State
        if ($waitResult) { return $waitResult }
        if ([datetime]::UtcNow + $Interval -gt $waitDeadline) { break }
        Start-Sleep -Milliseconds ([int]$Interval.TotalMilliseconds)
    }

    if ($NoThrow) { return $null }
    $limit = if ($Timeout.TotalMinutes -ge 1) { "$([int]$Timeout.TotalMinutes) minute(s)" } else { "$([int]$Timeout.TotalSeconds) second(s)" }
    throw "$Activity did not finish within $limit."
}
