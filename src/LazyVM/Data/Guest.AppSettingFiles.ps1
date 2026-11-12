# Guest.AppSettingFiles.ps1 - The AppSettingFiles files, read and written as the user (#325).
#
# Runs in the GUEST, under Windows PowerShell 5.1, as the guest account
# under its limited token: no PowerShell 7 syntax. It is copied into the
# folder of its task, under C:\Program Files\LazyVM\Tasks, as
# AppSettingFiles.ps1; that account can read the folder but only
# administrators can change it.
#
# -Entries is JSON: a list of @{ Name; File }, each File starting
# %LOCALAPPDATA%\, %APPDATA%\ or %USERPROFILE%\, which stand for
# -LocalAppData, -AppData and -ProfileRoot; the task gives the folders
# Windows reports for them. As in Guest.VisualStudioUserFiles.ps1
# (#310, #330), the files are in places only this account's own processes
# write, so they are read and written with its rights, and still never
# through a junction or link: the profile, every folder below it on the
# way, and the file itself are checked first.
#
# Capture (-OutputFolder): each file that is there is copied into the
# task's Output folder as file<n>.bin. Returns @{ Notes; Files; Failed }:
# Files, @{ Name; File; Output } for each one copied; Failed, the names of
# those that are there but were refused, too large or could not be read,
# for which the host keeps what it recorded before.
#
# Restore (the default): each entry also has Data, the file's content as
# Base64, and StopProcess, a process to stop first so it reads the file
# again when it restarts. Returns @{ Notes }.
#
# Each note is @{ Level; Text } (New-GuestNote in Guest.Helpers.ps1, which a
# task does not have).

[CmdletBinding(DefaultParameterSetName = 'Restore')]
param(
    [Parameter(Mandatory)][string]$ProfileRoot,
    [Parameter(Mandatory)][string]$AppData,
    [Parameter(Mandatory)][string]$LocalAppData,
    [Parameter(Mandatory)][string]$Entries,
    [Parameter(Mandatory, ParameterSetName = 'Capture')][string]$OutputFolder,
    [Parameter(Mandatory, ParameterSetName = 'Capture')][long]$MaximumBytes
)

$ErrorActionPreference = 'Stop'

function New-Note {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Text
    )

    return [pscustomobject]@{ Level = $Level; Text = $Text }
}

function Get-PathProblem {
    <#
      Why $Path must not be read or written, or '' when it may: it is not
      inside $Root, or $Root, a folder below it on the way to $Path, or
      $Path itself is a junction or link (as in Guest.VisualStudioUserFiles.ps1).
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $separators = [char[]]@('\', '/')
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd($separators)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        return "$Path is not inside $Root"
    }

    $current = $rootPath
    $parts = @($fullPath.Substring($rootPath.Length).Split($separators, [StringSplitOptions]::RemoveEmptyEntries))
    for ($index = 0; ; $index++) {
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] { return '' }
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
            return "$current is a junction or link, and LazyVM never reads or writes through one"
        }
        if ($index -ge $parts.Count) { return '' }
        $current = [IO.Path]::Combine($current, $parts[$index])
    }
}

function Resolve-SettingFile {
    <# The full path of $File, in the folder of $Folders its first part stands for. Throws when it names another folder. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][hashtable]$Folders
    )

    if ($File -notmatch '^%(?<folder>[A-Za-z]+)%\\(?<rest>.+)$' -or -not $Folders.ContainsKey($Matches.folder.ToUpperInvariant())) {
        throw "$File does not start with %LOCALAPPDATA%\, %APPDATA%\ or %USERPROFILE%\"
    }
    $rest = $Matches.rest
    return [IO.Path]::GetFullPath([IO.Path]::Combine($Folders[$Matches.folder.ToUpperInvariant()], $rest))
}

$folders = @{ LOCALAPPDATA = $LocalAppData; APPDATA = $AppData; USERPROFILE = $ProfileRoot }
$notes = @()
$files = @()
$failed = @()
$index = 0
foreach ($entry in @($Entries | ConvertFrom-Json)) {
    try {
        $path = Resolve-SettingFile -File $entry.File -Folders $folders
        $problem = Get-PathProblem -Root $ProfileRoot -Path $path
        if ($problem) { throw $problem }

        if ($PSCmdlet.ParameterSetName -eq 'Capture') {
            if (-not [IO.File]::Exists($path)) { continue }
            if ((New-Object IO.FileInfo $path).Length -gt $MaximumBytes) { throw "$($entry.File) is larger than $($MaximumBytes / 1MB) MB" }
            $output = "file$index.bin"
            $index++
            $problem = Get-PathProblem -Root $OutputFolder -Path (Join-Path $OutputFolder $output)
            if ($problem) { throw $problem }
            [IO.File]::Copy($path, (Join-Path $OutputFolder $output), $true)
            $files += [pscustomobject]@{ Name = $entry.Name; File = $entry.File; Output = $output }
        }
        else {
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            if ($entry.StopProcess) { Get-Process -Name $entry.StopProcess -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
            [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($entry.Data))
            $notes += New-Note -Level OK -Text "restored $($entry.Name)"
        }
    }
    catch {
        $failed += $entry.Name
        $notes += New-Note -Level WARN -Text "$($entry.Name) could not be $(if ($PSCmdlet.ParameterSetName -eq 'Capture') { 'read' } else { 'restored' }): $($_.Exception.Message)"
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Capture') { return @{ Notes = $notes; Files = $files; Failed = $failed } }
return @{ Notes = $notes }
