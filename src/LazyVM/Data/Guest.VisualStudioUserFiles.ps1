# Guest.VisualStudioUserFiles.ps1 - Visual Studio's files in the user's profile, captured and put back as that user (#310, #330).
#
# Runs in the GUEST, under Windows PowerShell 5.1, as the guest account
# under its limited token: no PowerShell 7 syntax. It is copied into the
# folder of its task, under C:\Program Files\LazyVM\Tasks, as
# VisualStudioUserFiles.ps1; that account can read the folder but only
# administrators can change it. The places of the files are known here
# only, for both directions:
#
# - NuGet.Config, in AppData\NuGet;
# - .gitconfig, in the profile;
# - the snippets, templates and settings, in Documents\Visual Studio <n>.
#
# Restore (the default): the captured files, given beside it, go into the
# profile. Capture (-OutputFolder): those files, and the .vssettings file
# -SettingsFile names, are copied into the task's Output folder, the
# Documents folders as one zip archive, which the restore extracts.
#
# Only that account's own processes write in these places, so the files are
# read and written with that account's rights: a junction or link someone
# planted there leads nowhere that account could not reach anyway. Even so,
# nothing is read or written through one. Before each file is read or
# written, the folder it is under (-ProfileRoot, -Documents for the
# snippets and templates, or -OutputFolder), every folder below it on the
# way, and the file itself, are checked, and a junction, link or mount
# point refuses that file; a capture also refuses the whole archive when it
# finds one inside the Documents folders, never walking into it. A OneDrive file or
# folder kept in the cloud looks the same and is refused too. The folders
# above the root are not walked: when Documents is redirected, as LazyVM
# puts it on the User disk, the walk for the snippets and templates starts
# at the Documents folder itself. An archive entry whose name could lead
# out of the Visual Studio folder is refused. A file over -MaximumBytes is
# not captured: on its own it is refused, and in the snippets and templates
# it is left out of the archive. A refused or failed file is a WARN note and
# the rest carry on.
#
# Returns @{ Notes }, each note @{ Level; Text } (New-GuestNote in
# Guest.Helpers.ps1, which a task does not have). A capture returns
# @{ Notes; Files; Unread }: Files, the names of the files it wrote in
# -OutputFolder; Unread, those of the files that are there but it refused
# or could not read, which the host then keeps from its previous capture.
# The archive is Unread when anything in the Documents folders was, so a
# capture never drops a snippet or template the previous one had.

[CmdletBinding(DefaultParameterSetName = 'Restore')]
param(
    [Parameter(Mandatory)][string]$ProfileRoot,
    [Parameter(Mandatory)][string]$AppData,
    [Parameter(Mandatory)][string]$Documents,
    [Parameter(Mandatory)][string]$ProductLine,
    [Parameter(ParameterSetName = 'Restore')][string]$NuGetConfig,
    [Parameter(ParameterSetName = 'Restore')][string]$GitConfig,
    [Parameter(ParameterSetName = 'Restore')][string]$UserItems,
    [Parameter(Mandatory, ParameterSetName = 'Capture')][string]$OutputFolder,
    [Parameter(ParameterSetName = 'Capture')][string]$SettingsFile,
    [Parameter(Mandatory, ParameterSetName = 'Capture')][long]$MaximumBytes
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

function New-Note {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Text
    )

    return [pscustomobject]@{ Level = $Level; Text = $Text }
}

function Get-LinkText {
    <# Why the junction or link at $Path is refused. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    return "$Path is a junction or link, or a OneDrive file or folder kept in the cloud, and LazyVM never reads or writes through one"
}

function Get-PathProblem {
    <#
      Why $Path must not be read or written, or '' when it may: $Path is not
      inside $Root, or $Root, a folder below it on the way to $Path, or
      $Path itself is a reparse point. The attributes are those of the item
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
            return (Get-LinkText -Path $current)
        }
        if ($index -ge $parts.Count) { return '' }
        $current = [IO.Path]::Combine($current, $parts[$index])
    }
}

function Write-ProfileFile {
    <#
      Writes $Destination, under $Root, after Get-PathProblem, making the
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
        $problem = Get-PathProblem -Root $Root -Path $Destination
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

function Get-EntryNameProblem {
    <#
      Why the archive entry named $Name must not be extracted, or '' when it
      may: a part that is . or .., or holds a : or a character a file name
      cannot have, could lead out of the folder it is extracted into.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    $invalid = [char[]](@([IO.Path]::GetInvalidFileNameChars()) + ':')
    foreach ($part in $Name.Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($part -eq '.' -or $part -eq '..' -or $part.IndexOfAny($invalid) -ge 0) { return "its name has the part '$part', which could lead out of the folder" }
    }
    return ''
}

function Restore-ProfileArchive {
    <#
      Extracts each file in the zip archive $Archive into $Destination,
      under $Root (Write-ProfileFile), and returns a WARN note for each file
      that was not, then one saying how many were. An archive that cannot be
      opened is one WARN note.
    #>
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Destination
    )

    try { $zip = [IO.Compression.ZipFile]::OpenRead($Archive) }
    catch { return New-Note -Level WARN -Text "did not restore the snippets and templates: $($_.Exception.Message)" }
    $restored = 0
    try {
        # An entry with no name is a folder; the folders a file needs are made for it.
        foreach ($entry in @($zip.Entries | Where-Object { $_.Name })) {
            try {
                $problem = Get-EntryNameProblem -Name $entry.FullName
                if (-not $problem) {
                    $target = [IO.Path]::Combine([string[]](@($Destination) + $entry.FullName.Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)))
                    $problem = Write-ProfileFile -Root $Root -Destination $target -Entry $entry
                }
            }
            catch { $problem = $_.Exception.Message }
            if ($problem) { New-Note -Level WARN -Text "did not restore $($entry.FullName): $problem" }
            else { $restored++ }
        }
    }
    finally { $zip.Dispose() }
    New-Note -Level OK -Text "restored $restored snippet and template file(s)"
}

function New-Outcome {
    <# How capturing one file or the archive went: State Missing (nothing there), Copied or Refused, and why when Refused. #>
    param(
        [Parameter(Mandatory)][ValidateSet('Missing', 'Copied', 'Refused')][string]$State,
        [string]$Reason = ''
    )

    return [pscustomobject]@{ State = $State; Reason = $Reason }
}

function Get-SizeText {
    <# Why a file of $Length bytes is over $MaximumBytes. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][long]$Length,
        [Parameter(Mandatory)][long]$MaximumBytes
    )

    return "it is $Length bytes, over the $MaximumBytes LazyVM captures"
}

function Save-ProfileFile {
    <#
      Copies the file $Source, under $Root, to $Destination, under
      $OutputFolder (Write-ProfileFile), once Get-PathProblem finds no
      reason not to read it and it is no more than $MaximumBytes. Returns
      New-Outcome: Missing when there is no file at $Source. A link at
      $Source, even one that leads nowhere, is Refused.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)][long]$MaximumBytes
    )

    $problem = Get-PathProblem -Root $Root -Path $Source
    if ($problem) { return New-Outcome -State Refused -Reason $problem }
    if (-not [IO.File]::Exists($Source)) { return New-Outcome -State Missing }
    $length = ([IO.FileInfo]$Source).Length
    if ($length -gt $MaximumBytes) { return New-Outcome -State Refused -Reason (Get-SizeText -Length $length -MaximumBytes $MaximumBytes) }
    $problem = Write-ProfileFile -Root $OutputFolder -Destination $Destination -Source $Source
    if ($problem) { return New-Outcome -State Refused -Reason $problem }
    return New-Outcome -State Copied
}

function Get-ArchiveFile {
    <#
      The files in the folder $Path and below, each @{ Path; Entry; Length;
      Problem }, Entry being its name in the archive: $Entry, then its own.
      A junction or link found, which is not walked into, and a folder that
      cannot be read, come back with only Entry and Problem.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Entry
    )

    try { $items = @(([IO.DirectoryInfo]$Path).GetFileSystemInfos()) }
    catch { return [pscustomobject]@{ Entry = $Entry; Problem = "what is in $Path cannot be read: $($_.Exception.Message)" } }
    foreach ($item in $items) {
        $name = "$Entry/$($item.Name)"
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { [pscustomobject]@{ Entry = $name; Problem = (Get-LinkText -Path $item.FullName) } }
        elseif ($item -is [IO.DirectoryInfo]) { Get-ArchiveFile -Path $item.FullName -Entry $name }
        else { [pscustomobject]@{ Path = $item.FullName; Entry = $name; Length = $item.Length; Problem = '' } }
    }
}

function Save-ProfileArchive {
    <#
      Zips the files in each of the folders $Folder of $Source, under
      $Root, into $Archive, under $OutputFolder, each named from its folder
      on (Code Snippets/...), as Restore-ProfileArchive extracts them.
      Returns New-Outcome: Refused when a folder Get-PathProblem refuses,
      anything Get-ArchiveFile finds a problem with, or a file that cannot
      be read; Missing when there is no file. A file that would take the
      archive's files over nine tenths of $MaximumBytes is left out. Adds a
      WARN note to $Notes for each thing refused or left out.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string[]]$Folder,
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)][long]$MaximumBytes,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Notes
    )

    $found = @(foreach ($name in $Folder) {
            $path = [IO.Path]::Combine($Source, $name)
            $problem = Get-PathProblem -Root $Root -Path $path
            if ($problem) { [pscustomobject]@{ Entry = $name; Problem = $problem } }
            elseif ([IO.Directory]::Exists($path)) { Get-ArchiveFile -Path $path -Entry $name }
        })
    $problems = @($found | Where-Object { $_.Problem })
    foreach ($item in $problems) { $Notes.Add((New-Note -Level WARN -Text "did not capture $($item.Entry): $($item.Problem)")) }
    if ($problems.Count -gt 0) { return New-Outcome -State Refused }

    # The archive's own headers need room too, so its files are kept to
    # nine tenths of the most the host reads back.
    $room = [long]($MaximumBytes * 0.9)
    $files = @(foreach ($file in $found) {
            if ($file.Length -gt $room) {
                $Notes.Add((New-Note -Level WARN -Text "did not capture $($file.Entry): $(Get-SizeText -Length $file.Length -MaximumBytes $room)"))
                continue
            }
            $room -= $file.Length
            $file
        })
    if ($files.Count -eq 0) { return New-Outcome -State Missing }

    $problem = Get-PathProblem -Root $OutputFolder -Path $Archive
    if (-not $problem) {
        try {
            $zip = New-Object IO.Compression.ZipArchive([IO.File]::Create($Archive), [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($file in $files) {
                    try { $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.Path, $file.Entry) }
                    catch { $problem = "$($file.Entry) cannot be read: $($_.Exception.Message)"; break }
                }
            }
            finally { $zip.Dispose() }
        }
        catch { $problem = $_.Exception.Message }
    }
    if ($problem) {
        $Notes.Add((New-Note -Level WARN -Text "did not capture the snippets and templates: $problem"))
        return New-Outcome -State Refused
    }
    return New-Outcome -State Copied
}

$nuGetConfigPath = [IO.Path]::Combine($AppData, 'NuGet', 'NuGet.Config')
$gitConfigPath = [IO.Path]::Combine($ProfileRoot, '.gitconfig')
$visualStudioFolder = [IO.Path]::Combine($Documents, "Visual Studio $ProductLine")

if ($PSCmdlet.ParameterSetName -eq 'Capture') {
    $notes = [System.Collections.Generic.List[object]]::new()
    $files = [System.Collections.Generic.List[string]]::new()
    $unread = [System.Collections.Generic.List[string]]::new()
    $captures = @(
        @{ What = 'NuGet.Config'; Source = $nuGetConfigPath; Name = 'NuGet.Config' }
        @{ What = '.gitconfig'; Source = $gitConfigPath; Name = 'gitconfig' }
        @{ What = 'the Visual Studio settings'; Source = $SettingsFile; Name = 'VisualStudio.vssettings' }
    )
    foreach ($capture in @($captures | Where-Object { $_.Source })) {
        $outcome = Save-ProfileFile -Root $ProfileRoot -Source $capture.Source -Destination ([IO.Path]::Combine($OutputFolder, $capture.Name)) `
            -OutputFolder $OutputFolder -MaximumBytes $MaximumBytes
        if ($outcome.State -eq 'Copied') { $files.Add($capture.Name) }
        elseif ($outcome.State -eq 'Refused') {
            $notes.Add((New-Note -Level WARN -Text "did not capture $($capture.What): $($outcome.Reason)"))
            $unread.Add($capture.Name)
        }
    }
    $archiveName = 'vs-useritems.zip'
    $outcome = Save-ProfileArchive -Root $Documents -Source $visualStudioFolder -Folder 'Code Snippets', 'Templates', 'Settings' `
        -Archive ([IO.Path]::Combine($OutputFolder, $archiveName)) -OutputFolder $OutputFolder -MaximumBytes $MaximumBytes -Notes $notes
    # Save-ProfileArchive has said why in the notes.
    if ($outcome.State -eq 'Copied') { $files.Add($archiveName) }
    elseif ($outcome.State -eq 'Refused') { $unread.Add($archiveName) }
    return [pscustomobject]@{ Notes = $notes.ToArray(); Files = $files.ToArray(); Unread = $unread.ToArray() }
}

$restored = @(
    if ($NuGetConfig) {
        Restore-ProfileFile -What 'NuGet.Config' -Source $NuGetConfig -Root $ProfileRoot -Destination $nuGetConfigPath
    }
    if ($GitConfig) {
        Restore-ProfileFile -What '.gitconfig' -Source $GitConfig -Root $ProfileRoot -Destination $gitConfigPath
    }
    if ($UserItems) {
        Restore-ProfileArchive -Archive $UserItems -Root $Documents -Destination $visualStudioFolder
    }
)
return [pscustomobject]@{ Notes = $restored }
