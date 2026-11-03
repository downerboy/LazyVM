# EventLogging.ps1 - The guest's event logs, audit policy and PowerShell logging (#291).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# What Windows records about what happens in the VM, kept at the Microsoft
# security baseline for Windows 11 (version 25H2, from the Security
# Compliance Toolkit: the "MSFT Windows 11 25H2 - Computer" policy) at every
# build and every night, so a change by hand or by an installer is put
# back. The in-depth security scan reads these logs.
# https://learn.microsoft.com/windows/security/operating-system-security/device-management/windows-security-configuration-framework/windows-security-baselines
#
# Only ever adds: a log someone made bigger keeps its size, and auditing
# someone turned on is never turned off. The work in the guest is in
# Data\Guest.Helpers.ps1.

# The smallest size of each log. The Sysmon log is Set-GuestSysmon's (#236).
$script:GuestEventLogMinimumSize = [ordered]@{
    # The baseline's "Specify the maximum log file size (KB)": 32768, 196608 and 32768.
    'Application'                              = 32MB
    'Security'                                 = 192MB
    'System'                                   = 32MB
    # The baseline sets no size for the PowerShell logs. The engine log gets
    # the size of Application and System; script block logging fills the
    # Operational log, so it is sized as Sysmon's.
    'Windows PowerShell'                       = 32MB
    'Microsoft-Windows-PowerShell/Operational' = $script:GuestBusyEventLogSize
}

# The baseline's advanced audit policy (its audit.csv), by subcategory GUID,
# which auditpol reads in any language of Windows. Process Creation is event 4688.
$script:GuestAuditPolicy = @(
    @{ Name = 'Credential Validation'; Guid = '{0CCE923F-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $true }
    @{ Name = 'Security Group Management'; Guid = '{0CCE9237-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $false }
    @{ Name = 'User Account Management'; Guid = '{0CCE9235-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $true }
    @{ Name = 'PNP Activity'; Guid = '{0CCE9248-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $false }
    @{ Name = 'Process Creation'; Guid = '{0CCE922B-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $false }
    @{ Name = 'Account Lockout'; Guid = '{0CCE9217-69AE-11D9-BED3-505054503030}'; Success = $false; Failure = $true }
    @{ Name = 'Group Membership'; Guid = '{0CCE9249-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $false }
    @{ Name = 'Logon'; Guid = '{0CCE9215-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $true }
    @{ Name = 'Other Logon/Logoff Events'; Guid = '{0CCE921C-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $true }
    @{ Name = 'Special Logon'; Guid = '{0CCE921B-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $false }
    @{ Name = 'Detailed File Share'; Guid = '{0CCE9244-69AE-11D9-BED3-505054503030}'; Success = $false; Failure = $true }
    @{ Name = 'File Share'; Guid = '{0CCE9224-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $true }
    @{ Name = 'Other Object Access Events'; Guid = '{0CCE9227-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $true }
    @{ Name = 'Removable Storage'; Guid = '{0CCE9245-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $true }
    @{ Name = 'Audit Policy Change'; Guid = '{0CCE922F-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $false }
    @{ Name = 'Authentication Policy Change'; Guid = '{0CCE9230-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $false }
    @{ Name = 'MPSSVC Rule-Level Policy Change'; Guid = '{0CCE9232-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $true }
    @{ Name = 'Other Policy Change Events'; Guid = '{0CCE9234-69AE-11D9-BED3-505054503030}'; Success = $false; Failure = $true }
    @{ Name = 'Sensitive Privilege Use'; Guid = '{0CCE9228-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $true }
    @{ Name = 'Other System Events'; Guid = '{0CCE9214-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $true }
    @{ Name = 'Security State Change'; Guid = '{0CCE9210-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $false }
    @{ Name = 'Security System Extension'; Guid = '{0CCE9211-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $false }
    @{ Name = 'System Integrity'; Guid = '{0CCE9212-69AE-11D9-BED3-505054503030}'; Success = $true; Failure = $true }
)

# The baseline's policies behind the audit policy and PowerShell logging, as
# the DWORD registry values the policies write.
#
# Module logging is left off, as the baseline leaves it: its events record
# every parameter a command is given, so the recovery passwords LazyVM
# unlocks BitLocker with and the passwords of the certificates it captures
# would sit in the log in clear text. Script block logging records the code
# that runs, not the values it is given.
$script:GuestLoggingPolicyValues = @(
    # "Audit: Force audit policy subcategory settings to override audit policy category settings": Enabled,
    # so the subcategories above are the ones Windows uses.
    @{ What = 'audit subcategories used over the old categories'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; Name = 'SCENoApplyLegacyAuditPolicy'; Value = 1 }
    # "Include command line in process creation events": Enabled, new in the 25H2 baseline.
    @{ What = 'command lines in process creation events (4688)'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit'; Name = 'ProcessCreationIncludeCmdLine_Enabled'; Value = 1 }
    # "Turn on PowerShell Script Block Logging": Enabled, without invocation events (also CIS 18.10.88.1, DISA STIG WN11-CC-000326).
    @{ What = 'PowerShell script block logging (4104)'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'; Name = 'EnableScriptBlockLogging'; Value = 1 }
)

function Get-EventLogSizeFix {
    <#
      The logs to resize, from what the guest reports ($Log: Name,
      MaximumSizeInBytes, LogMode): each one smaller than its size, or not
      overwriting its oldest events. A full log that keeps its events stops
      recording, and one that archives them fills C:. A bigger log keeps its
      size. Each fix has the Name, MaximumSizeInBytes and Text for the log.
    #>
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Log)

    $fixes = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($current in $Log) {
        if (-not $script:GuestEventLogMinimumSize.Contains($current.Name)) { continue }
        $size = [math]::Max([long]$current.MaximumSizeInBytes, [long]$script:GuestEventLogMinimumSize[$current.Name])
        if ($size -eq $current.MaximumSizeInBytes -and $current.LogMode -eq 'Circular') { continue }
        $fixes.Add([pscustomobject]@{
                Name               = $current.Name
                MaximumSizeInBytes = $size
                Text               = "$($current.Name) log holds $($size / 1MB) MB, then overwrites its oldest events"
            })
    }
    return $fixes.ToArray()
}

function Get-AuditPolicyFix {
    <#
      The audit subcategories to turn on, from what the guest reports
      ($Audit: subcategory GUID to auditpol's setting value, 1 success,
      2 failure, 3 both): each one of the baseline's that does not audit all
      the baseline asks. A subcategory the guest did not report audits
      nothing. Only ever adds. Each fix has the Guid, Success and Failure to
      turn on, and Text for the log.
    #>
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][hashtable]$Audit)

    # The guest's GUIDs may be in either case.
    $current = @{}
    foreach ($guid in $Audit.Keys) { $current[$guid.ToUpperInvariant()] = [int]$Audit[$guid] }

    $fixes = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($entry in $script:GuestAuditPolicy) {
        $setting = if ($current.ContainsKey($entry.Guid)) { $current[$entry.Guid] } else { 0 }
        $missesSuccess = $entry.Success -and -not ($setting -band 1)
        $missesFailure = $entry.Failure -and -not ($setting -band 2)
        if (-not ($missesSuccess -or $missesFailure)) { continue }
        $audited = @(if ($entry.Success) { 'success' }) + @(if ($entry.Failure) { 'failure' })
        $fixes.Add([pscustomobject]@{
                Guid    = $entry.Guid
                Success = $entry.Success
                Failure = $entry.Failure
                Text    = "audit $($entry.Name): $($audited -join ' and ')"
            })
    }
    return $fixes.ToArray()
}

function Get-LoggingPolicyValueFix {
    <#
      The policy values to set, from what the guest reports ($Value: Path,
      Name, Value, $null when missing): each one of LazyVM's that differs.
      Each fix has the Path, Name, Value and Text for the log.
    #>
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Value)

    $fixes = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($wanted in $script:GuestLoggingPolicyValues) {
        $current = @($Value | Where-Object { $_.Path -eq $wanted.Path -and $_.Name -eq $wanted.Name }) | Select-Object -First 1
        if ($current -and $current.Value -eq $wanted.Value) { continue }
        $fixes.Add([pscustomobject]@{ Path = $wanted.Path; Name = $wanted.Name; Value = $wanted.Value; Text = "turned on $($wanted.What)" })
    }
    return $fixes.ToArray()
}

function Set-GuestEventLogging {
    <#
      Keeps the guest's event logs, audit policy and PowerShell logging at
      LazyVM's settings, at every build and every night: reads them, works
      out what differs (Get-EventLogSizeFix, Get-AuditPolicyFix,
      Get-LoggingPolicyValueFix) and fixes only that, logging each fix.
      Runs in the PowerShell Direct session as the guest administrator,
      which may set all of it; nothing here needs SYSTEM. Nothing restarts.

      Forgiving: any failure is logged, and the build or maintenance run
      carries on. The next night tries again.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not $VM.Settings.GuestEventLogging) {
        Write-LogEntry 'Event logging turned off in the settings (GuestEventLogging) - skipping' 'INFO'
        return
    }

    try {
        $readArguments = @(@($script:GuestEventLogMinimumSize.Keys), @($script:GuestLoggingPolicyValues | ForEach-Object { @{ Path = $_.Path; Name = $_.Name } }), (Get-GuestStagingFolder -VM $VM))
        $state = Invoke-GuestScript -VM $VM -Activity 'event logging check' -TimeoutMinutes 5 -ArgumentList $readArguments -ScriptBlock {
            param($logNames, $policyValues, $stagingFolder)
            $ErrorActionPreference = 'Stop'
            Get-GuestLoggingState -LogName $logNames -PolicyValue $policyValues -Folder $stagingFolder
        }

        $logFixes = @(Get-EventLogSizeFix -Log @($state.Logs))
        $auditFixes = @(Get-AuditPolicyFix -Audit $state.Audit)
        $valueFixes = @(Get-LoggingPolicyValueFix -Value @($state.Values))
        $fixes = @($logFixes) + @($auditFixes) + @($valueFixes)
        if ($fixes.Count -eq 0) {
            Write-LogEntry 'Event logging: already at LazyVM''s settings' 'INFO'
            return
        }

        $null = Invoke-GuestScript -VM $VM -Activity 'event logging' -TimeoutMinutes 5 -ArgumentList @($logFixes, $auditFixes, $valueFixes) -ScriptBlock {
            param($logFixes, $auditFixes, $valueFixes)
            $ErrorActionPreference = 'Stop'
            foreach ($fix in @($logFixes)) { Set-GuestEventLogSize -Name $fix.Name -MaximumSizeInBytes $fix.MaximumSizeInBytes }
            foreach ($fix in @($auditFixes)) { Enable-GuestAuditSubcategory -SubcategoryGuid $fix.Guid -Success:$fix.Success -Failure:$fix.Failure }
            foreach ($fix in @($valueFixes)) { Set-GuestPolicyValue -Path $fix.Path -Name $fix.Name -Value $fix.Value }
        }
        foreach ($fix in $fixes) { Write-LogEntry "Event logging: $($fix.Text)" 'OK' }
    }
    catch {
        Write-LogError 'Event logging set-up failed (non-fatal)' $_
    }
}
