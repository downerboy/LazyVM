# Guest.VisualStudioUserFiles.ps1 - Visual Studio's files put back into the user's profile (#310).
#
# Runs in the GUEST, under Windows PowerShell 5.1, as the guest account
# under its limited token: no PowerShell 7 syntax. The restore copies it to
# C:\Program Files\LazyVM\Tasks\LazyVM-VSUserFiles\VisualStudioUserFiles.ps1,
# the folder of its task, with the captured files beside it; that account
# can read the folder but only administrators can change it.
#
# The files go where only that account's own processes write, so they are
# written with that account's rights: a junction or link someone planted
# there leads nowhere that account could not write anyway. Even so, nothing
# is written through one. Before each file is written, the folder it is
# restored under (-ProfileRoot, or -Documents for the snippets and
# templates), every folder below it on the way, and the file itself, are
# checked, and a junction, link or mount point refuses that file. A OneDrive
# folder kept in the cloud looks the same and is refused too. A refused or
# failed file is a WARN note and the rest carry on.
#
# Returns the notes, each @{ Level; Text } (New-GuestNote in Guest.Helpers.ps1,
# which a task does not have).

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfileRoot,
    [Parameter(Mandatory)][string]$AppData,
    [Parameter(Mandatory)][string]$Documents,
    [Parameter(Mandatory)][string]$ProductLine,
    [string]$NuGetConfig,
    [string]$GitConfig,
    [string]$UserItems
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

function New-Note {
    param([string]$Level, [string]$Text)

    return [pscustomobject]@{ Level = $Level; Text = $Text }
}

function Get-WriteProblem {
    <#
      Why $Path must not be written, or '' when it may: $Path is not inside
      $Root, or $Root, a folder below it on the way to $Path, or $Path
      itself is a reparse point. The attributes are those of the item
      itself, never what a link leads to, so a link that leads nowhere yet
      is found too. Nothing below a missing folder can be there.
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
            return "$current is a junction or link, or a OneDrive folder kept in the cloud, and LazyVM never writes through one"
        }
        if ($index -ge $parts.Count) { return '' }
        $current = [IO.Path]::Combine($current, $parts[$index])
    }
}

function Write-ProfileFile {
    <#
      Writes $Destination, under $Root, after Get-WriteProblem, making the
      folders it needs: a copy of the file $Source, or the zip archive
      entry $Entry extracted. Returns '' when it was written, or why it was
      not.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory, ParameterSetName = 'File')][string]$Source,
        [Parameter(Mandatory, ParameterSetName = 'Entry')][IO.Compression.ZipArchiveEntry]$Entry
    )

    try {
        $problem = Get-WriteProblem -Root $Root -Path $Destination
        if ($problem) { return $problem }
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
        if ($Entry) { [IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $Destination, $true) }
        else { [IO.File]::Copy($Source, $Destination, $true) }
        return ''
    }
    catch { return $_.Exception.Message }
}

function Restore-ProfileFile {
    <# Copies the file $Source to $Destination, under $Root (Write-ProfileFile), and returns the note saying how it went. #>
    param(
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Destination
    )

    $problem = Write-ProfileFile -Root $Root -Destination $Destination -Source $Source
    if ($problem) { return New-Note -Level WARN -Text "did not restore ${What}: $problem" }
    return New-Note -Level OK -Text "restored $What"
}

function Restore-ProfileArchive {
    <#
      Extracts each file in the zip archive $Archive into $Destination,
      under $Root (Write-ProfileFile), and returns a WARN note for each file
      that was not, then one saying how many were.
    #>
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Destination
    )

    $restored = 0
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        # An entry with no name is a folder; the folders a file needs are made for it.
        foreach ($entry in @($zip.Entries | Where-Object { $_.Name })) {
            $target = [IO.Path]::Combine([string[]](@($Destination) + $entry.FullName.Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)))
            $problem = Write-ProfileFile -Root $Root -Destination $target -Entry $entry
            if ($problem) { New-Note -Level WARN -Text "did not restore $($entry.FullName): $problem" }
            else { $restored++ }
        }
    }
    finally { $zip.Dispose() }
    New-Note -Level OK -Text "restored $restored snippet and template file(s)"
}

if ($NuGetConfig) {
    Restore-ProfileFile -What 'NuGet.Config' -Source $NuGetConfig -Root $ProfileRoot -Destination ([IO.Path]::Combine($AppData, 'NuGet', 'NuGet.Config'))
}
if ($GitConfig) {
    Restore-ProfileFile -What '.gitconfig' -Source $GitConfig -Root $ProfileRoot -Destination ([IO.Path]::Combine($ProfileRoot, '.gitconfig'))
}
if ($UserItems) {
    Restore-ProfileArchive -Archive $UserItems -Root $Documents -Destination ([IO.Path]::Combine($Documents, "Visual Studio $ProductLine"))
}
