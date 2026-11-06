# SecurityScan.ps1 - The nightly security scan of each guest, and where its findings go (#290, #334).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# It also records the known-good baseline after a build and a rebuild
# (SecurityBaseline.ps1 keeps it). The last step of the nightly maintenance. Two collectors run in the guest
# as SYSTEM: $script:GuestSecurityScanWork, a Defender quick scan, then the
# facts each settings check needs, and $script:GuestPersistenceWork, the
# places a program can start itself again. The host turns them into findings
# (SecurityFinding.ps1, Persistence.ps1), leaves out the approved ones
# (SecurityApproval.ps1), logs each one, writes them to LazyVM Findings.txt
# on the guest's desktop, and keeps them in <VM>\Logs\SecurityFindings.json.
# When the scan found something new of a severity that alerts
# (GuestSecurityScanAlertSeverity, every one by default), the file opens in
# Notepad the next time someone signs in, connects or unlocks, once for that
# scan for each user. The scan only reports: it changes nothing in the guest
# but that file and what opens it.

# The collector's time budget: the quick scan gets most of it.
$script:SecurityScanTimeoutMinutes = 20
$script:SecurityQuickScanMinutes = 15

# In the guest: the findings file, on the desktop every user sees, and the
# task that opens it ($script:SecurityFindingOpener). A scan that finds
# something new that is High or Medium sets the alert value under the
# guest's LazyVM key to its stamp; the opener records in the user's own key
# the stamp it opened the file for.
$script:GuestSecurityFindingsFileName = 'LazyVM Findings.txt'
$script:GuestSecurityFindingsTaskName = "${script:TaskPrefix}SecurityFindings"
$script:GuestSecurityAlertValueName = 'SecurityFindingsAlert'
# Besides sign-in, the opener runs when a session is connected at the
# console (1), connected remotely (3) or unlocked (8): the
# MSFT_TaskSessionStateChangeTrigger states.
$script:GuestSecurityFindingsSessionStates = @(1, 3, 8)

function Invoke-GuestSecurityScan {
    <#
      The nightly scan: collects the guest's facts, turns them into findings
      (the persistence ones against the baseline, which it records for any
      area that has none yet), leaves out the approved ones, marks each New,
      Still open or Resolved against the last scan, logs them, puts them on
      the guest's desktop, and only then keeps them and the baseline, so a
      scan whose findings did not reach the guest counts as not done and its
      new findings are still new the next night. With a baseline that cannot
      be read, every persistence area counts as not read, and the baseline
      is left as it is. Skipped when GuestSecurityScan is off.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not $VM.Settings.GuestSecurityScan) {
        Write-LogEntry 'Security scan turned off in the settings (GuestSecurityScan) - skipping' 'INFO'
        return
    }

    Write-LogEntry 'Security scan: Defender quick scan, then the security settings, what happened since the last scan and the places programs start from...' 'INFO'
    # The last scan first: what happened since then is what the guest reads.
    $previous = Read-SecurityFindingRecord -VM $VM
    $since = $null
    $previousFindings = @()
    $previouslyUnchecked = @()
    if ($previous) {
        $since = $previous.ScannedAt
        $previousFindings = $previous.Findings
        $previouslyUnchecked = $previous.Unchecked
    }
    $facts = Get-GuestSecurityFact -VM $VM -Since $since
    # Registered before the persistence is read, so the opener's task is as LazyVM leaves it.
    Install-GuestSecurityFindingOpener -VM $VM
    $persistence = Get-GuestPersistenceItem -VM $VM
    $scannedAt = [datetimeoffset]::Parse([string]$facts.CollectedAt, [cultureinfo]::InvariantCulture).ToLocalTime()
    $baseline = Read-SecurityBaseline -VM $VM
    if (-not $baseline.Readable) { $persistence = $null }
    $upgraded = @(Update-LegacyPersistenceBaseline -Baseline $baseline.Persistence -Item $persistence)
    foreach ($area in $upgraded) {
        Write-LogEntry "Security scan: baseline upgraded for the $($script:PersistenceCheck[$area].Things): each item LazyVM 6.6.0 knew by name is known with its new fingerprint; any other is reported." 'INFO'
    }
    $added = Get-MissingPersistenceBaseline -Baseline $baseline.Persistence -Item $persistence -RecordedAt $scannedAt
    foreach ($area in $added.Keys) { $baseline.Persistence[$area] = $added[$area] }

    $unchecked = @(Get-UncheckedSecurityArea -Check $facts.Checks) + @(Get-UncheckedSecurityArea -Check $persistence -Area @($script:PersistenceCheck.Keys))
    $found = @(ConvertTo-SecurityFinding -Check $facts.Checks -Since $since -ScannedAt $scannedAt)
    $found += @(ConvertTo-PersistenceFinding -Item $persistence -Baseline $baseline.Persistence)
    $found += @(Get-UnreadablePersistenceAreaFinding -Unchecked $unchecked -PreviouslyUnchecked $previouslyUnchecked)
    $reported = @(Select-UnapprovedSecurityFinding -Finding $found -Approval $baseline.Approvals)
    $earlier = @(Select-UnapprovedSecurityFinding -Finding $previousFindings -Approval $baseline.Approvals)
    $findings = @(Compare-SecurityFinding -Current $reported -Previous $earlier -ScannedAt $scannedAt -Unchecked $unchecked)

    $alertSeverity = @($VM.Settings.GuestSecurityScanAlertSeverity)
    Write-SecurityFindingLog -Finding $findings -AlertSeverity $alertSeverity
    $approvedCount = $found.Count - $reported.Count
    if ($approvedCount -gt 0) {
        Write-LogEntry "Security scan: $approvedCount approved finding(s) not reported. List them with: Get-LazyVMSecurityFinding -Name $($VM.Name) -Approved" 'INFO'
    }
    $alertScanId = if (Test-SecurityFindingAlert -Finding $findings -AlertSeverity $alertSeverity) { $scannedAt.ToString($script:StampFormat) } else { '' }
    Publish-GuestSecurityFinding -VM $VM -Text (Format-SecurityFindingReport -Finding $findings -VMName $VM.Name -ScannedAt $scannedAt) -AlertScanId $alertScanId
    Save-SecurityFindingRecord -VM $VM -ScannedAt $scannedAt -Finding $findings -Unchecked $unchecked
    if (-not $baseline.Readable) {
        Write-LogEntry 'Security scan: the security baseline could not be read, so it was left as it is. Approving or revoking a finding moves it aside; then the next scan records a new one.' 'WARN'
        return
    }
    $foundId = @($found | ForEach-Object { $_.Id })
    Update-SecurityBaseline -VM $VM -Change {
        param($record)
        # An area upgraded tonight, unless something else upgraded it meanwhile.
        foreach ($area in @($upgraded | Where-Object { $record.Persistence.Contains($_) -and (Get-PersistenceNameToUpgrade -Area $record.Persistence[$_]) })) {
            $record.Persistence[$area] = $baseline.Persistence[$area]
        }
        Add-PersistenceBaselineArea -Record $record -Baseline $added
        Remove-EndedSecurityApproval -Record $record -FoundId $foundId -Unchecked $unchecked
    }
}

function Get-MissingPersistenceBaseline {
    <#
      The baseline, from tonight's facts $Item, of each area $Baseline
      lacks, such as one the guest could not read when the baseline was
      recorded, or on a VM built before LazyVM had one. Logs each area.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Baseline,
        [AllowNull()][object]$Item,
        [Parameter(Mandatory)][datetimeoffset]$RecordedAt
    )

    $missing = @($script:PersistenceCheck.Keys | Where-Object { -not $Baseline.Contains($_) })
    $added = New-PersistenceBaseline -Item $Item -RecordedAt $RecordedAt -Area $missing
    foreach ($area in $added.Keys) {
        Write-LogEntry "Security scan: recorded the baseline of $($script:PersistenceCheck[$area].Things) ($($added[$area].Items.Count)). Changes from it are reported from the next scan on." 'INFO'
    }
    return $added
}

function Add-PersistenceBaselineArea {
    <# Puts into the baseline $Record each area of $Baseline it does not have yet; never changes or removes one it has. #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Record,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Baseline
    )

    foreach ($area in @($Baseline.Keys | Where-Object { -not $Record.Persistence.Contains($_) })) { $Record.Persistence[$area] = $Baseline[$area] }
}

function Get-GuestPersistenceItem {
    <#
      Tonight's persistence items by area, or $null when the collector could
      not run, which is logged and leaves every persistence finding open, as
      for an area the guest could not read.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][VMContext]$VM)

    try { return (Get-GuestPersistenceFact -VM $VM).Items }
    catch {
        Write-LogError 'Security scan: the places programs start from could not be read (non-fatal); their findings stay as they were' $_
        return $null
    }
}

function Get-GuestPersistenceSnapshot {
    <#
      The guest's persistence as a baseline, as it is now, with the findings
      opener registered first so it is part of it. $null, logged, when the
      guest cannot be read.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][VMContext]$VM)

    try {
        Install-GuestSecurityFindingOpener -VM $VM
        return (New-PersistenceBaseline -Item (Get-GuestPersistenceFact -VM $VM).Items -RecordedAt ([datetimeoffset]::Now))
    }
    catch {
        Write-LogError 'Reading the places programs start from for the security baseline failed (non-fatal); the next nightly scan records what is missing' $_
        return $null
    }
}

function Save-GuestPersistenceBaseline {
    <#
      After Build-LazyVM: records the guest's persistence as the known-good
      baseline when the VM has none yet, its first build; on a VM that has
      one, only the areas it lacks, so running the build again never makes
      a change known-good. Approves, once for the VM, what LazyVM does by
      design (Add-DefaultSecurityApproval). Never throws. Skipped when
      GuestSecurityScan is off.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not $VM.Settings.GuestSecurityScan) {
        Write-LogEntry 'Security baseline turned off in the settings (GuestSecurityScan) - skipping' 'INFO'
        return
    }
    $snapshot = Get-GuestPersistenceSnapshot -VM $VM
    try {
        Update-SecurityBaseline -VM $VM -Change {
            param($record)
            if ($snapshot) {
                $first = $record.Persistence.Count -eq 0
                Add-PersistenceBaselineArea -Record $record -Baseline $snapshot
                if ($first) { Write-LogEntry "Security baseline recorded: $(Format-PersistenceBaselineCount -Baseline $record.Persistence)" 'OK' }
                else { Write-LogEntry 'Security baseline kept as it was; only an area it lacked, if any, was added' 'INFO' }
            }
            Add-DefaultSecurityApproval -Record $record
        }
    }
    catch { Write-LogError 'Saving the security baseline failed (non-fatal)' $_ }
}

function Get-RebuildPersistenceBaseline {
    <#
      During a rebuild, after the build and before the restore: the new
      VM's persistence, which Save-RebuildPersistenceBaseline joins to the
      old baseline once the rebuild passes its check. $null, logged, when
      the guest cannot be read or GuestSecurityScan is off; the old
      baseline is then kept.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not $VM.Settings.GuestSecurityScan) { return $null }
    return (Get-GuestPersistenceSnapshot -VM $VM)
}

function Save-RebuildPersistenceBaseline {
    <#
      Once a rebuild passed its check: the new VM's baseline $Baseline,
      recorded before the restore, with the fingerprints the old baseline
      knows added, so an item the restore put back counts as known only if
      it was known before. Areas $Baseline lacks keep the old baseline.
      Nothing is written without $Baseline. Never throws.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [AllowNull()][System.Collections.IDictionary]$Baseline
    )

    if (-not $Baseline) { return }
    try {
        Update-SecurityBaseline -VM $VM -Change {
            param($record)
            $record.Persistence = Join-PersistenceBaseline -Baseline $Baseline -Earlier $record.Persistence
            Write-LogEntry "Security baseline recorded for the rebuilt VM: $(Format-PersistenceBaselineCount -Baseline $record.Persistence)" 'OK'
        }
    }
    catch { Write-LogError 'Saving the security baseline of the rebuilt VM failed (non-fatal); the old one is kept' $_ }
}

function Get-GuestSecurityFact {
    <#
      Runs the collector in the guest as SYSTEM, which the Defender cmdlets
      and some of the settings need, within its time budget, and logs what
      it reports about itself, such as an area it could not read. Returns
      its facts: CollectedAt, Notes, and Checks by area. Its arguments are
      the quick scan's time limit, when the last scan collected ($Since,
      $null for the first scan: the events and crash files since then are
      read), the patterns script blocks are tested against and how many
      hours the first scan reads back; nothing secret is passed.
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [AllowNull()][object]$Since
    )

    $sinceText = if ($null -ne $Since) { ([datetimeoffset]$Since).UtcDateTime.ToString('o', [cultureinfo]::InvariantCulture) } else { '' }
    $scriptPattern = @($script:SuspiciousPowerShell | ForEach-Object { $_.Pattern })

    $json = Invoke-GuestTask -VM $VM -TaskName "${script:TaskPrefix}security-scan" -Activity 'security scan' -TimeoutMinutes $script:SecurityScanTimeoutMinutes `
        -Work $script:GuestSecurityScanWork -ArgumentList @($script:SecurityQuickScanMinutes, $sinceText, $scriptPattern, $script:SecurityEventFirstScanHours)
    $facts = ConvertFrom-Json -InputObject $json -DateKind String
    Write-GuestNote -Notes @($facts.Notes)
    return $facts
}

function Write-SecurityFindingLog {
    <#
      Logs how many findings the scan has, then each finding one field to a
      line: new ones of a severity in $AlertSeverity as warnings, resolved
      ones as done, every one whatever its severity.
    #>
    param(
        [AllowEmptyCollection()][SecurityFinding[]]$Finding = @(),
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AlertSeverity
    )

    $summary = if ($Finding.Count -eq 0) { 'no findings' } else { Format-SecurityFindingCount -Finding $Finding }
    Write-LogEntry "Security scan: $summary" $(if (Test-SecurityFindingAlert -Finding $Finding -AlertSeverity $AlertSeverity) { 'WARN' } else { 'OK' })
    for ($i = 0; $i -lt $Finding.Count; $i++) {
        $level = if ($Finding[$i].Status -eq 'Resolved') { 'OK' } elseif (Test-SecurityFindingAlert -Finding @($Finding[$i]) -AlertSeverity $AlertSeverity) { 'WARN' } else { 'INFO' }
        Write-LogList -Heading "  Security finding $($i + 1) of $($Finding.Count)" -Items (Format-SecurityFinding -Finding $Finding[$i]) -Level $level
    }
}

function Install-GuestSecurityFindingOpener {
    <#
      Registers, again each night, the guest task that runs the opener at
      every user's sign-in, console or remote connect and unlock, in their
      own session with their normal rights (BUILTIN\Users, by its SID). The
      opener is the task's -Command, so no file holds it.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $arguments = @($script:GuestSecurityFindingsTaskName, (Get-SecurityFindingOpenerArgument), $script:GuestSecurityFindingsSessionStates)
    $null = Invoke-GuestScript -VM $VM -Activity 'security findings opener' -TimeoutMinutes 5 -ArgumentList $arguments -ScriptBlock {
        param($taskName, $openerArgument, $sessionStates)
        $ErrorActionPreference = 'Stop'

        $sessionClass = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskSessionStateChangeTrigger'
        $triggers = @(New-ScheduledTaskTrigger -AtLogOn)
        foreach ($state in $sessionStates) {
            $trigger = New-CimInstance -CimClass $sessionClass -ClientOnly
            $trigger.StateChange = [int]$state
            $trigger.Enabled = $true
            $triggers += $trigger
        }
        $action = New-ScheduledTaskAction -Execute (Get-GuestWindowsPowerShell) -Argument $openerArgument
        $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
    }
}

function Publish-GuestSecurityFinding {
    <#
      Writes $Text to LazyVM Findings.txt on the guest's public desktop,
      which every user's desktop shows. With an $AlertScanId, records it as
      the scan the file is to open for; without one the stamp is left as it
      is, so a file not opened yet still opens.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][AllowEmptyString()][string]$AlertScanId
    )

    $arguments = @($Text, $script:GuestSecurityFindingsFileName, $script:GuestMarkerKey, $script:GuestSecurityAlertValueName, $AlertScanId)
    $null = Invoke-GuestScript -VM $VM -Activity 'security findings file' -TimeoutMinutes 5 -ArgumentList $arguments -ScriptBlock {
        param($text, $fileName, $markerKey, $alertName, $alertScanId)
        $ErrorActionPreference = 'Stop'

        # With a byte order mark, so Notepad reads it as UTF-8.
        $file = Join-Path -Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) -ChildPath $fileName
        [System.IO.File]::WriteAllText($file, $text, (New-Object System.Text.UTF8Encoding $true))
        if ($alertScanId) {
            if (-not (Test-Path -LiteralPath $markerKey)) { New-Item -Path $markerKey -Force | Out-Null }
            Set-ItemProperty -LiteralPath $markerKey -Name $alertName -Value $alertScanId
        }
    }
}

function Write-SecurityFindingReminder {
    <#
      Reminds, in one line with the command to see them, when the VM's last
      scan has open findings, not approved since, of a severity that alerts
      (GuestSecurityScanAlertSeverity). Never throws: a reminder must not
      stop the command it runs in.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    try {
        $record = Read-SecurityFindingRecord -VM $VM
        if (-not $record) { return }
        $open = @(Select-UnapprovedSecurityFinding -Finding $record.Findings -Approval (Read-SecurityBaseline -VM $VM).Approvals)
        $message = Get-SecurityFindingReminderMessage -Finding $open -VMName $VM.Name -AlertSeverity @($VM.Settings.GuestSecurityScanAlertSeverity)
    }
    catch {
        Write-LogError "Could not check the security findings of $($VM.Name) (non-fatal)" $_
        return
    }
    if ($message) { Write-LogWarning $message }
}

function Get-SecurityFindingList {
    <# Get-LazyVMSecurityFinding: the last scan's findings, but those approved since, each with the VM's name first. Says so when no scan has run yet. #>
    [OutputType('LazyVM.SecurityFinding')]
    param([Parameter(Mandatory)][VMContext]$VM)

    $record = Read-SecurityFindingRecord -VM $VM
    if (-not $record) {
        Write-LogWarning "No security scan has run on $($VM.Name) yet. The nightly maintenance runs one (GuestSecurityScan)."
        return
    }
    foreach ($finding in @(Select-UnapprovedSecurityFinding -Finding $record.Findings -Approval (Read-SecurityBaseline -VM $VM).Approvals)) {
        ConvertTo-VMRecordView -VMName $VM.Name -TypeName 'LazyVM.SecurityFinding' -Record $finding
    }
}
