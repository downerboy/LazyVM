# PathSafety.ps1 - No write of LazyVM's goes through a reparse point (#284).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The LazyVM folder belongs to its user, and LazyVM's scheduled tasks write
# in it as SYSTEM, as they do in the places outside it its owner allowed. A
# junction or symbolic link the user made there would send such a write
# somewhere else, such as a system folder. So every write, delete, move and
# copy goes through a helper (New-Folder, Write-TextFileAtomic, the log,
# Remove-CheckedItem, Move-CheckedItem, Copy-CheckedItem) that first checks
# that no folder from the LazyVM folder, or the allowed place, down to the
# path is a reparse point. Running as SYSTEM, a path in none of those places
# is refused: the check fails closed.

# The LazyVM folder of the command running now, set by Initialize-BuildTarget
# and Initialize-CommandRun, and the places outside it its owner allowed.
$script:RunRoot = $null
$script:RunAllowedPaths = @()

function Test-RunningAsSystem {
    <# Whether LazyVM runs as SYSTEM, as its scheduled tasks do. #>
    [OutputType([bool])]
    param()

    if (-not $IsWindows) { return $false }
    return [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
}

function Test-ReparsePoint {
    <# Whether the file or folder at $Path is a reparse point: a junction, a symbolic link, or a cloud placeholder. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    return ([long](Get-Item -LiteralPath $Path -Force).Attributes -band [long][IO.FileAttributes]::ReparsePoint) -ne 0
}

function Assert-NoReparsePoint {
    <#
      Stops when the folder $Path is in (the LazyVM folder $Root, a place
      outside it in $Allowed, or the temporary folder), or any file or
      folder from there down to $Path that exists, is a reparse point.
      Running as SYSTEM, also stops when $Path is in none of those places.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Root = $script:RunRoot,
        [string[]]$Allowed = $script:RunAllowedPaths
    )

    $base = @($Root) + @($Allowed) + [IO.Path]::GetTempPath() |
        Where-Object { $_ -and (Test-PathWithin -Path $Path -Folder $_) } |
        Select-Object -First 1
    if (-not $base) {
        if (Test-RunningAsSystem) {
            throw "$Path is not in the LazyVM folder or a place its owner allowed, so LazyVM, running as SYSTEM, will not write there."
        }
        return
    }
    $current = ConvertTo-FullPath -Path $base
    $below = (ConvertTo-FullPath -Path $Path).Substring($current.Length) -split '[\\/]' | Where-Object { $_ }
    foreach ($name in @('') + @($below)) {
        if ($name) { $current = Join-Path -Path $current -ChildPath $name }
        if (-not (Test-Path -LiteralPath $current)) { return }
        if (Test-ReparsePoint -Path $current) {
            throw "$current is a reparse point (a junction or link) where LazyVM writes, so LazyVM will not write through it. Remove it, then run the command again."
        }
    }
}

function Remove-CheckedItem {
    <# Deletes the file or folder $Path, after Assert-NoReparsePoint; with -Quiet, says nothing when it fails. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Recurse,
        [switch]$Quiet
    )

    Assert-NoReparsePoint -Path $Path
    $errorAction = if ($Quiet) { 'SilentlyContinue' } else { 'Stop' }
    Remove-Item -LiteralPath $Path -Recurse:$Recurse -Force -ErrorAction $errorAction
}

function Move-CheckedItem {
    <# Moves $Path to $Destination, after Assert-NoReparsePoint on both. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )

    Assert-NoReparsePoint -Path $Path
    Assert-NoReparsePoint -Path $Destination
    Move-Item -LiteralPath $Path -Destination $Destination -Force -ErrorAction Stop
}

function Copy-CheckedItem {
    <# Copies $Path to $Destination, folders with their content, after Assert-NoReparsePoint on both. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination
    )

    Assert-NoReparsePoint -Path $Path
    Assert-NoReparsePoint -Path $Destination
    Copy-Item -LiteralPath $Path -Destination $Destination -Recurse -Force -ErrorAction Stop
}
