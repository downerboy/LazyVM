# PathSafety.ps1 - No write under the LazyVM folder goes through a reparse point (#284).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The LazyVM folder belongs to its user, and LazyVM's scheduled tasks write
# in it as SYSTEM. A junction or symbolic link the user made there would
# send such a write somewhere else, such as a system folder. So the helpers
# every write goes through (New-Folder, Write-TextFileAtomic, the log, the
# deletes of Remove-LazyVM) first check that no folder from the LazyVM
# folder down to the path is a reparse point.

# The LazyVM folder of the command running now, set by Initialize-CommandRun.
$script:RunRoot = $null

function Test-ReparsePoint {
    <# Whether the file or folder at $Path is a reparse point: a junction, a symbolic link, or a cloud placeholder. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    return ([long](Get-Item -LiteralPath $Path -Force).Attributes -band [long][IO.FileAttributes]::ReparsePoint) -ne 0
}

function Assert-NoReparsePoint {
    <#
      Stops when $Path is inside $Root (the running command's LazyVM folder
      by default) and the LazyVM folder, or any file or folder from it down
      to $Path that is there, is a reparse point. A path outside the LazyVM
      folder is not checked here: Assert-HostPathTrusted decides about those.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Root = $script:RunRoot
    )

    if (-not $Root -or -not (Test-PathWithin -Path $Path -Folder $Root)) { return }
    $current = $Root.TrimEnd('\', '/')
    $below = $Path.TrimEnd('\', '/').Substring($current.Length) -split '[\\/]' | Where-Object { $_ }
    foreach ($name in @('') + @($below)) {
        if ($name) { $current = Join-Path -Path $current -ChildPath $name }
        if (-not (Test-Path -LiteralPath $current)) { return }
        if (Test-ReparsePoint -Path $current) {
            throw "$current is a reparse point (a junction or link) inside the LazyVM folder, so LazyVM will not write through it. Remove it, then run the command again."
        }
    }
}
