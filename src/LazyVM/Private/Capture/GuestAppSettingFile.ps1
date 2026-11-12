# GuestAppSettingFile.ps1 - The files AppSettingFiles lists, recorded in VM.json (#325).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Some settings live in a file rather than the registry: the apps pinned to
# Windows 11's Start menu are in start2.bin. Each file AppSettingFiles lists
# is read in the guest and kept in VM.json's GuestAppSettingFiles as Base64,
# recorded on every maintenance run and every capture, whenever it changed,
# and written back by a build or a restore. A file that does not exist yet
# is left out; one larger than AppSettingFileMaxBytes is not recorded.

function Get-GuestAppSettingFileSnapshot {
    <#
      Reads each AppSettingFiles file in the guest: Files (Name, File,
      Data as Base64), the names of those that could not be read as Failed,
      and Notes. The files are in the guest account's profile, so a task
      under that account's limited token reads them
      (Data\Guest.AppSettingFiles.ps1), never the administrator, whose
      rights a junction or link planted there would lead elsewhere (#330);
      the administrator reads each copy in the task's Output folder on one
      handle (Get-GuestTaskOutputFileData). The task needs the account
      signed in: when no one is, every file counts as not read.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $names = @($VM.Settings.AppSettingFiles | ForEach-Object { "$($_['Name'])" })
    $out = [pscustomobject]@{ Files = @(); Failed = @(); Notes = @() }
    if ($names.Count -eq 0) { return $out }
    if (-not (Wait-GuestSignedIn -VM $VM -TimeoutMinutes $script:VisualStudioSignInWaitMinutes)) {
        $out.Failed = $names
        $out.Notes = @([pscustomobject]@{ Level = 'WARN'; Text = "'$($VM.Runtime.GuestAdminUser)' is not signed in - application settings files not read" })
        return $out
    }

    $entries = @(foreach ($entry in @($VM.Settings.AppSettingFiles)) { [ordered]@{ Name = "$($entry['Name'])"; File = "$($entry['File'])" } })
    $taskName = "${script:TaskPrefix}AppSettingFilesCapture"
    try {
        $report = Invoke-GuestTask -VM $VM -TaskName $taskName -Activity 'application settings files check' -TimeoutMinutes 5 -AsGuestUser `
            -InputFile @{ 'AppSettingFiles.ps1' = (Join-Path -Path $script:DataDir -ChildPath 'Guest.AppSettingFiles.ps1') } `
            -ArgumentList @((ConvertTo-Json -InputObject $entries -Compress), $script:AppSettingFileMaxBytes) -Work {
            param($entriesJson, $maximumBytes)
            $result = & (Join-Path $TaskFolder 'AppSettingFiles.ps1') -ProfileRoot ([Environment]::GetFolderPath('UserProfile')) -AppData ([Environment]::GetFolderPath('ApplicationData')) `
                -LocalAppData ([Environment]::GetFolderPath('LocalApplicationData')) -Entries $entriesJson -OutputFolder $TaskOutput -MaximumBytes $maximumBytes
            # The task's result is one line of text, so it goes back as JSON.
            return (ConvertTo-Json -InputObject $result -Compress -Depth 4)
        }
        # What a task under the limited token reports is only that account's word:
        # only a file AppSettingFiles lists is taken, under its listed name.
        $reported = ConvertFrom-Json -InputObject $report
    }
    catch {
        $out.Failed = $names
        $out.Notes = @([pscustomobject]@{ Level = 'WARN'; Text = "the application settings files could not be read: $($_.Exception.Message)" })
        return $out
    }
    $out.Notes = @([RecordReader]::Field($reported, 'Notes'))
    $out.Failed = @([RecordReader]::Strings($reported, 'Failed') | Where-Object { $_ -in $names })
    foreach ($file in @([RecordReader]::Field($reported, 'Files') | Where-Object { $_ })) {
        $entry = @($entries | Where-Object { $_.Name -eq $file.Name -and $_.File -eq $file.File }) | Select-Object -First 1
        if (-not $entry -or "$($file.Output)" -notmatch '^file\d+\.bin$') { continue }
        try {
            $data = Get-GuestTaskOutputFileData -VM $VM -TaskName $taskName -Name $file.Output -MaximumBytes $script:AppSettingFileMaxBytes
            $out.Files += [pscustomobject]@{ Name = $entry.Name; File = $entry.File; Data = $data }
        }
        catch {
            $out.Failed += $entry.Name
            $out.Notes += [pscustomobject]@{ Level = 'WARN'; Text = "$($entry.Name) could not be read: $($_.Exception.Message)" }
        }
    }
    return $out
}

function ConvertTo-GuestAppSettingFileRecord {
    <# The files the guest reported (Get-GuestAppSettingFileSnapshot) as VM.json's GuestAppSettingFiles, sorted so the same files always compare equal. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$File)

    return @(foreach ($item in @($File | Where-Object { $_ } | Sort-Object -Property Name)) {
            [ordered]@{ Name = [string]$item.Name; File = [string]$item.File; Data = [string]$item.Data }
        })
}

function Update-GuestAppSettingFileRecord {
    <#
      Records the AppSettingFiles files as they are now in VM.json. A file
      that is gone is removed from the record too; one that could not be
      read this time keeps what was recorded for it. Writes nothing when
      nothing changed. Returns whether anything did.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $snapshot = Get-GuestAppSettingFileSnapshot -VM $VM
    Write-GuestNote -Notes @($snapshot.Notes)

    $record = @(ConvertTo-GuestAppSettingFileRecord -File @($snapshot.Files))
    $failed = @($snapshot.Failed)
    if ($failed.Count -gt 0) {
        $recordedFiles = Get-GuestAppSettingFileRecord -VM $VM
        $recorded = @($recordedFiles | Where-Object { $_ -and $_['Name'] -in $failed })
        $record = @(@($record) + $recorded | Sort-Object -Property { $_['Name'] })
    }

    $change = @{ $script:GuestAppSettingFileName = $record }
    $changed = @(Update-VMProfile -Root $VM.Settings.Root -Name $VM.Name -Change $change -Reason 'guest application settings files changed').Count -gt 0
    if ($changed) { Write-LogEntry "Guest application settings files recorded: $($record.Count) file(s)" 'OK' }
    return $changed
}

function Get-GuestAppSettingFileRecord {
    <# VM.json's GuestAppSettingFiles as the file holds it now; $null when they were never recorded. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $current = Read-SettingsFile -Path (Get-VMProfilePath -Root $VM.Settings.Root -Name $VM.Name)
    $files = $current[$script:GuestAppSettingFileName]
    if ($null -eq $files) { return $null }
    return , @($files)
}

function Get-GuestAppSettingFileRestore {
    <#
      What a build or a restore puts back into the guest: VM.json's
      GuestAppSettingFiles as the file holds it now, each with the
      StopProcess AppSettingFiles gives it; nothing when there is nothing
      to put back. Only the files AppSettingFiles lists are returned: the
      record came from the guest or a template, so a file it names that
      the user never listed is not trusted.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $files = Get-GuestAppSettingFileRecord -VM $VM
    if ($null -eq $files) { return $null }

    $listed = @{}
    foreach ($entry in @($VM.Settings.AppSettingFiles)) { $listed["$($entry['File'])".ToUpperInvariant()] = $entry }
    return @(foreach ($file in @($files)) {
            $entry = $listed["$($file['File'])".ToUpperInvariant()]
            if (-not $entry) {
                Write-LogEntry "  $($file['Name']) is not restored: $($file['File']) is not in AppSettingFiles" 'WARN'
                continue
            }
            [ordered]@{ Name = $file['Name']; File = $file['File']; Data = $file['Data']; StopProcess = "$($entry['StopProcess'])" }
        })
}

function Restore-GuestAppSettingFile {
    <#
      Writes each file $Recorded (from Get-GuestAppSettingFileRestore) holds
      into the guest account's profile, after stopping its StopProcess so
      that reads it again when it restarts. A task under that account's
      limited token writes them (Data\Guest.AppSettingFiles.ps1), never the
      administrator (#310). The task needs the account signed in, so it
      waits for automatic sign-in, and skips the files with a WARN when no
      one signs in. Returns the guest's notes.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Recorded
    )

    if ($Recorded.Count -eq 0) { return @() }
    if (-not (Wait-GuestSignedIn -VM $VM -TimeoutMinutes $script:VisualStudioSignInWaitMinutes)) {
        return @([pscustomobject]@{ Level = 'WARN'; Text = "'$($VM.Runtime.GuestAdminUser)' is not signed in - application settings files not restored" })
    }

    $report = Invoke-GuestTask -VM $VM -TaskName "${script:TaskPrefix}AppSettingFiles" -Activity 'application settings files restore' -TimeoutMinutes 5 -AsGuestUser `
        -InputFile @{ 'AppSettingFiles.ps1' = (Join-Path -Path $script:DataDir -ChildPath 'Guest.AppSettingFiles.ps1') } `
        -ArgumentList @((ConvertTo-Json -InputObject @($Recorded) -Depth 5 -Compress)) -Work {
        param($entriesJson)
        $result = & (Join-Path $TaskFolder 'AppSettingFiles.ps1') -ProfileRoot ([Environment]::GetFolderPath('UserProfile')) -AppData ([Environment]::GetFolderPath('ApplicationData')) `
            -LocalAppData ([Environment]::GetFolderPath('LocalApplicationData')) -Entries $entriesJson
        # The task's result is one line of text, so it goes back as JSON.
        return (ConvertTo-Json -InputObject $result -Compress -Depth 4)
    }
    return @([RecordReader]::Field((ConvertFrom-Json -InputObject $report), 'Notes'))
}
