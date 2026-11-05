# SecurityScan.ps1 - The nightly security scan of each guest, and where its findings go (#290).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The last step of the nightly maintenance. Two collectors run in the guest
# as SYSTEM: $script:GuestSecurityScanWork, a Defender quick scan, then the
# facts each settings check needs, and $script:GuestPersistenceWork, the
# places a program can start itself again. The host turns them into findings
# (SecurityFinding.ps1, Persistence.ps1), leaves out the approved ones
# (SecurityBaseline.ps1), logs each one, writes them to LazyVM Findings.txt
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
      new findings are still new the next night. Skipped when
      GuestSecurityScan is off.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not $VM.Settings.GuestSecurityScan) {
        Write-LogEntry 'Security scan turned off in the settings (GuestSecurityScan) - skipping' 'INFO'
        return
    }

    Write-LogEntry 'Security scan: Defender quick scan, then the security settings and the places programs start from...' 'INFO'
    $facts = Get-GuestSecurityFact -VM $VM
    # Registered before the persistence is read, so the opener's task is as LazyVM leaves it.
    Install-GuestSecurityFindingOpener -VM $VM
    $persistence = Get-GuestPersistenceItem -VM $VM
    $scannedAt = [datetimeoffset]::Parse([string]$facts.CollectedAt, [cultureinfo]::InvariantCulture).ToLocalTime()
    $previous = Read-SecurityFindingRecord -VM $VM
    $since = $null
    $previousFindings = @()
    if ($previous) {
        $since = $previous.ScannedAt
        $previousFindings = $previous.Findings
    }
    $baseline = Read-SecurityBaseline -VM $VM
    Add-MissingPersistenceBaseline -Baseline $baseline.Persistence -Item $persistence -RecordedAt $scannedAt

    $found = @(ConvertTo-SecurityFinding -Check $facts.Checks -Since $since -ScannedAt $scannedAt) + @(ConvertTo-PersistenceFinding -Item $persistence -Baseline $baseline.Persistence)
    $unchecked = @(Get-UncheckedSecurityArea -Check $facts.Checks) + @(Get-UncheckedSecurityArea -Check $persistence -Area @($script:PersistenceCheck.Keys))
    $reported = @(Select-UnapprovedSecurityFinding -Finding $found -Approval $baseline.Approvals)
    $earlier = @(Select-UnapprovedSecurityFinding -Finding $previousFindings -Approval $baseline.Approvals)
    $findings = @(Compare-SecurityFinding -Current $reported -Previous $earlier -ScannedAt $scannedAt -Unchecked $unchecked)

    $alertSeverity = @($VM.Settings.GuestSecurityScanAlertSeverity)
    Write-SecurityFindingLog -Finding $findings -AlertSeverity $alertSeverity
    $approvedCount = $found.Count - $reported.Count
    if ($approvedCount -gt 0) {
        Write-LogEntry "Security scan: $approvedCount approved finding(s) not reported. List them with: Get-LazyVMSecurityFinding -Name $($VM.Name) -Approved" 'INFO'
    }
    $alertScanId = if (Test-SecurityFindingAlert -Finding $findings -Severity $alertSeverity) { $scannedAt.ToString($script:StampFormat) } else { '' }
    Publish-GuestSecurityFinding -VM $VM -Text (Format-SecurityFindingReport -Finding $findings -VMName $VM.Name -ScannedAt $scannedAt) -AlertScanId $alertScanId
    Save-SecurityFindingRecord -VM $VM -ScannedAt $scannedAt -Finding $findings
    Save-ScannedSecurityBaseline -VM $VM -Persistence $baseline.Persistence -FoundId @($found | ForEach-Object { $_.Id }) -Unchecked $unchecked
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

function Get-GuestSecurityFact {
    <#
      Runs the collector in the guest as SYSTEM, which the Defender cmdlets
      and some of the settings need, within its time budget, and logs what
      it reports about itself, such as an area it could not read. Returns
      its facts: CollectedAt, Notes, and Checks by area. Its only argument
      is the quick scan's time limit; nothing secret is passed.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $json = Invoke-GuestTask -VM $VM -TaskName "${script:TaskPrefix}security-scan" -Activity 'security scan' -TimeoutMinutes $script:SecurityScanTimeoutMinutes `
        -Work $script:GuestSecurityScanWork -ArgumentList @($script:SecurityQuickScanMinutes)
    $facts = ConvertFrom-Json -InputObject $json -DateKind String
    Write-GuestNote -Notes @($facts.Notes)
    return $facts
}

function Read-SecurityFindingRecord {
    <#
      The VM's last scan: when the guest collected its facts (ScannedAt) and
      its Findings. $null before the first scan, or when the record cannot
      be read, which then counts as no scan, and is logged.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $path = $VM.Settings.SecurityFindingsFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -DateKind String
        return [pscustomobject]@{
            ScannedAt = [datetimeoffset]::Parse([string]$record.ScannedAt, [cultureinfo]::InvariantCulture)
            Findings  = [SecurityFinding[]]@(@($record.Findings) | ForEach-Object { [SecurityFinding]::FromObject($_) })
        }
    }
    catch {
        Write-LogEntry "The last security findings ($path) could not be read, so this counts as the first scan: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Save-SecurityFindingRecord {
    <# Keeps the scan's findings in <VM>\Logs\SecurityFindings.json, with when the guest collected them. Holds no secrets. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][datetimeoffset]$ScannedAt,
        [Parameter(Mandatory)][AllowEmptyCollection()][SecurityFinding[]]$Finding
    )

    $record = [ordered]@{
        ScannedAt = $ScannedAt.ToString('o', [cultureinfo]::InvariantCulture)
        Findings  = @($Finding | ForEach-Object { $_.ToRecord() })
    }
    Write-TextFileAtomic -Path $VM.Settings.SecurityFindingsFile -Text (ConvertTo-Json -InputObject $record -Depth 4)
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
    Write-LogEntry "Security scan: $summary" $(if (Test-SecurityFindingAlert -Finding $Finding -Severity $AlertSeverity) { 'WARN' } else { 'OK' })
    for ($i = 0; $i -lt $Finding.Count; $i++) {
        $level = if ($Finding[$i].Status -eq 'Resolved') { 'OK' } elseif (Test-SecurityFindingAlert -Finding @($Finding[$i]) -Severity $AlertSeverity) { 'WARN' } else { 'INFO' }
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
        $message = Get-SecurityFindingReminderMessage -Finding $open -VMName $VM.Name -Severity @($VM.Settings.GuestSecurityScanAlertSeverity)
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
        $shown = [ordered]@{ PSTypeName = 'LazyVM.SecurityFinding'; Name = $VM.Name }
        foreach ($property in $finding.PSObject.Properties) { $shown[$property.Name] = $property.Value }
        [pscustomobject]$shown
    }
}
