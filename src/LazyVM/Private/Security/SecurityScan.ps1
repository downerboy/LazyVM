# SecurityScan.ps1 - The nightly security scan of each guest, and where its findings go (#290).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The last step of the nightly maintenance. A self-contained script runs in
# the guest as SYSTEM (Data\Guest.SecurityScan.ps1, Windows PowerShell 5.1,
# without the guest helpers): a Defender quick scan, then the facts each
# check needs, as JSON. The host turns them into findings (SecurityFinding.ps1),
# keeps them in <VM>\Logs\SecurityFindings.json, logs each one, and writes
# them to LazyVM Findings.txt on the guest's desktop. When the scan found
# something new that is High or Medium, the file opens in Notepad at the
# next sign-in, once for that scan. The scan only reports: it changes nothing
# in the guest but that file and what opens it.

# The guest script's time budget: the quick scan gets most of it.
$script:SecurityScanTimeoutMinutes = 20
$script:SecurityQuickScanMinutes = 15

# In the guest: the findings file, on the desktop every user sees, and the
# task that opens it at sign-in (Data\Guest.SecurityFindingOpener.ps1). The
# scan sets the alert value under the guest's LazyVM key to its stamp when
# the file is to open; the opener records in the user's own key the stamp
# it opened it for, so it opens once for each such scan.
$script:GuestSecurityFindingsFileName = 'LazyVM Findings.txt'
$script:GuestSecurityFindingsTaskName = "${script:TaskPrefix}SecurityFindings"
$script:GuestSecurityFindingOpenerFileName = 'SecurityFindingOpener.ps1'
$script:GuestSecurityAlertValueName = 'SecurityFindingsAlert'

function Invoke-GuestSecurityScan {
    <#
      The nightly scan: collects the guest's facts, turns them into findings,
      marks each New, Still open or Resolved against the last scan, keeps
      them, logs them, and puts them on the guest's desktop. Skipped when
      GuestSecurityScan is off.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not $VM.Settings.GuestSecurityScan) {
        Write-LogEntry 'Security scan turned off in the settings (GuestSecurityScan) - skipping' 'INFO'
        return
    }

    Write-LogEntry 'Security scan: Defender quick scan, then the security settings...' 'INFO'
    $facts = Get-GuestSecurityFact -VM $VM
    $scannedAt = [datetimeoffset]::Now
    $previous = Read-SecurityFindingRecord -VM $VM
    $since = $null
    $previousFindings = @()
    if ($previous) {
        $since = $previous.ScannedAt
        $previousFindings = $previous.Findings
    }
    $current = @(ConvertTo-SecurityFinding -Check $facts.Checks -Since $since -ScannedAt $scannedAt)
    $findings = @(Compare-SecurityFinding -Current $current -Previous $previousFindings -ScannedAt $scannedAt -Unchecked (Get-UncheckedSecurityArea -Check $facts.Checks))

    Save-SecurityFindingRecord -VM $VM -ScannedAt $scannedAt -Finding $findings
    Write-SecurityFindingLog -Finding $findings
    $alertScanId = if (Test-SecurityFindingAlert -Finding $findings) { $scannedAt.ToString($script:StampFormat) } else { '' }
    Publish-GuestSecurityFinding -VM $VM -Text (Format-SecurityFindingReport -Finding $findings -VMName $VM.Name -ScannedAt $scannedAt) -AlertScanId $alertScanId
}

function Get-GuestSecurityFact {
    <#
      Runs Data\Guest.SecurityScan.ps1 in the guest as SYSTEM, which the
      Defender cmdlets and some of the settings need, within its time
      budget, and logs what it reports about itself, such as a check it
      could not read. Returns its facts: Notes, and Checks by area. Its only
      argument is the quick scan's time limit; nothing secret is passed.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $work = [scriptblock]::Create((Get-Content -LiteralPath (Join-Path -Path $script:DataDir -ChildPath 'Guest.SecurityScan.ps1') -Raw))
    $json = Invoke-GuestTask -VM $VM -TaskName "${script:TaskPrefix}security-scan" -Activity 'security scan' -TimeoutMinutes $script:SecurityScanTimeoutMinutes `
        -Work $work -ArgumentList @($script:SecurityQuickScanMinutes)
    $facts = ConvertFrom-Json -InputObject $json -DateKind String
    Write-GuestNote -Notes @($facts.Notes)
    return $facts
}

function Read-SecurityFindingRecord {
    <#
      The VM's last scan: when it ran (ScannedAt) and its Findings. $null
      before the first scan, or when the record cannot be read, which then
      counts as no scan, and is logged.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $path = $VM.Settings.SecurityFindingsFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -DateKind String
        return [pscustomobject]@{
            ScannedAt = [datetimeoffset]::Parse([string]$record.ScannedAt, [cultureinfo]::InvariantCulture)
            Findings  = @($record.Findings)
        }
    }
    catch {
        Write-LogEntry "The last security findings ($path) could not be read, so this counts as the first scan: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Save-SecurityFindingRecord {
    <# Keeps the scan's findings in <VM>\Logs\SecurityFindings.json, with when it ran. Holds no secrets. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][datetimeoffset]$ScannedAt,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Finding
    )

    $record = [ordered]@{
        ScannedAt = $ScannedAt.ToString('o', [cultureinfo]::InvariantCulture)
        Findings  = @($Finding)
    }
    Write-TextFileAtomic -Path $VM.Settings.SecurityFindingsFile -Text (ConvertTo-Json -InputObject $record -Depth 4)
}

function Write-SecurityFindingLog {
    <# Logs how many findings the scan has, then each finding one field to a line: new High and Medium ones as warnings, resolved ones as done. #>
    param([AllowEmptyCollection()][object[]]$Finding = @())

    $summary = if ($Finding.Count -eq 0) { 'no findings' } else { Format-SecurityFindingCount -Finding $Finding }
    Write-LogEntry "Security scan: $summary" $(if (Test-SecurityFindingAlert -Finding $Finding) { 'WARN' } else { 'OK' })
    for ($i = 0; $i -lt $Finding.Count; $i++) {
        $level = if ($Finding[$i].Status -eq 'Resolved') { 'OK' } elseif (Test-SecurityFindingAlert -Finding @($Finding[$i])) { 'WARN' } else { 'INFO' }
        Write-LogList -Heading "  Security finding $($i + 1) of $($Finding.Count)" -Items (Format-SecurityFinding -Finding $Finding[$i]) -Level $level
    }
}

function Publish-GuestSecurityFinding {
    <#
      Writes $Text to LazyVM Findings.txt on the guest's public desktop,
      which every user's desktop shows, and makes sure the sign-in task that
      opens it is there. With an $AlertScanId, the file opens at the next
      sign-in, once; without one, it does not open.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][AllowEmptyString()][string]$AlertScanId
    )

    $openerText = Get-Content -LiteralPath (Join-Path -Path $script:DataDir -ChildPath 'Guest.SecurityFindingOpener.ps1') -Raw
    $arguments = @($Text, $openerText, $VM.Settings.GuestSetupDir, $script:GuestSecurityFindingsTaskName, $script:GuestMarkerKey, $script:GuestSecurityAlertValueName, $AlertScanId,
        $script:GuestSecurityFindingsFileName, $script:GuestSecurityFindingOpenerFileName)
    $null = Invoke-GuestScript -VM $VM -Activity 'security findings file' -TimeoutMinutes 5 -ArgumentList $arguments -ScriptBlock {
        param($text, $openerText, $setupDir, $taskName, $markerKey, $alertName, $alertScanId, $fileName, $openerFileName)
        $ErrorActionPreference = 'Stop'
        # With a byte order mark, so Windows PowerShell 5.1 and Notepad read it as UTF-8.
        $encoding = New-Object System.Text.UTF8Encoding $true

        $file = Join-Path -Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) -ChildPath $fileName
        [System.IO.File]::WriteAllText($file, $text, $encoding)
        New-GuestFolder -Path $setupDir
        $opener = Join-Path -Path $setupDir -ChildPath $openerFileName
        [System.IO.File]::WriteAllText($opener, $openerText, $encoding)

        if (-not (Test-Path -LiteralPath $markerKey)) { New-Item -Path $markerKey -Force | Out-Null }
        if ($alertScanId) { Set-ItemProperty -LiteralPath $markerKey -Name $alertName -Value $alertScanId }
        else { Remove-ItemProperty -LiteralPath $markerKey -Name $alertName -ErrorAction SilentlyContinue }

        # At every user's sign-in, in their own session with their normal rights (BUILTIN\Users, by its SID).
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$opener`" -Path `"$file`""
        $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Principal $principal -Settings $settings -Force | Out-Null
    }
}

function Write-SecurityFindingReminder {
    <#
      Reminds, in one line with the command to see them, when the VM's last
      scan has open High or Medium findings. Never throws: a reminder must
      not stop the command it runs in.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    try {
        $record = Read-SecurityFindingRecord -VM $VM
        if (-not $record) { return }
        $message = Get-SecurityFindingReminderMessage -Finding $record.Findings -VMName $VM.Name
    }
    catch {
        Write-LogError "Could not check the security findings of $($VM.Name) (non-fatal)" $_
        return
    }
    if ($message) { Write-LogWarning $message }
}

function Get-SecurityFindingList {
    <# Get-LazyVMSecurityFinding: the last scan's findings, each with the VM's name. Says so when no scan has run yet. #>
    [OutputType('LazyVM.SecurityFinding')]
    param([Parameter(Mandatory)][VMContext]$VM)

    $record = Read-SecurityFindingRecord -VM $VM
    if (-not $record) {
        Write-LogWarning "No security scan has run on $($VM.Name) yet. The nightly maintenance runs one (GuestSecurityScan)."
        return
    }
    foreach ($finding in $record.Findings) {
        [pscustomobject]@{
            PSTypeName   = 'LazyVM.SecurityFinding'
            Name         = $VM.Name
            Id           = $finding.Id
            Severity     = $finding.Severity
            Title        = $finding.Title
            WhatWeFound  = $finding.WhatWeFound
            WhyItMatters = $finding.WhyItMatters
            HowToFix     = $finding.HowToFix
            FirstSeen    = $finding.FirstSeen
            Status       = $finding.Status
        }
    }
}
