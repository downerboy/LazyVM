# SecurityBaseline.ps1 - The security scan's known-good baseline and the findings the VM's owner approved (#290).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Both are kept in <VM>\Config\SecurityBaseline.json:
#   Persistence  for each persistence area, when its baseline was recorded
#                and the Ids of its items (Persistence.ps1)
#   Approvals    each approved finding's Id, severity, title, when and why
#                (the SecurityApproval class); never what was found
# The baseline is recorded after each build and rebuild, and an area it
# lacks by the next nightly scan. An approved finding is left out of what
# the scan reports while it is found with the same Id; once a scan no
# longer finds it, because it changed, was fixed or, for an event, is over,
# its approval ends. A change gives a new Id, so it is reported again.

function Read-SecurityBaseline {
    <#
      The VM's baseline: Persistence (area -> RecordedAt, Items) and
      Approvals. Empty before the first one is recorded, or when the file
      cannot be read, which is logged and then counts as none.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $none = [pscustomobject]@{ Persistence = [ordered]@{}; Approvals = [SecurityApproval[]]@() }
    $path = $VM.Settings.SecurityBaselineFile
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $none }
    try {
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -DateKind String
        $persistence = [ordered]@{}
        $areas = [RecordReader]::Field($record, 'Persistence')
        if ($areas) {
            foreach ($area in $areas.PSObject.Properties) {
                $persistence[$area.Name] = @{
                    RecordedAt = [datetimeoffset]::Parse([RecordReader]::Text($area.Value, 'RecordedAt'), [cultureinfo]::InvariantCulture)
                    Items      = [RecordReader]::Strings($area.Value, 'Items')
                }
            }
        }
        $approvals = @(@([RecordReader]::Field($record, 'Approvals')) | Where-Object { $_ } | ForEach-Object { [SecurityApproval]::FromObject($_) })
        return [pscustomobject]@{ Persistence = $persistence; Approvals = [SecurityApproval[]]$approvals }
    }
    catch {
        Write-LogEntry "The security baseline ($path) could not be read, so it counts as none: no findings are approved, and the next nightly scan records the baseline again: $($_.Exception.Message)" 'WARN'
        return $none
    }
}

function Save-SecurityBaseline {
    <# Keeps the baseline $Persistence and the approvals $Approval in <VM>\Config\SecurityBaseline.json. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Persistence,
        [Parameter(Mandatory)][AllowEmptyCollection()][SecurityApproval[]]$Approval
    )

    $areas = [ordered]@{}
    foreach ($area in $Persistence.Keys) {
        $areas[$area] = [ordered]@{
            RecordedAt = ([datetimeoffset]$Persistence[$area].RecordedAt).ToString('o', [cultureinfo]::InvariantCulture)
            Items      = @($Persistence[$area].Items)
        }
    }
    $record = [ordered]@{ Persistence = $areas; Approvals = @($Approval | ForEach-Object { $_.ToRecord() }) }
    Write-TextFileAtomic -Path $VM.Settings.SecurityBaselineFile -Text (ConvertTo-Json -InputObject $record -Depth 5)
}

function Save-GuestPersistenceBaseline {
    <#
      After a build or a rebuild: records the guest's scheduled tasks,
      services, Run keys, startup folders, WMI event subscriptions, local
      users and Administrators as the known-good baseline, in place of any
      earlier one, and keeps the approvals. The findings opener is
      registered first, so it is part of it. Never throws: when the guest
      cannot be read, the baseline is left empty for the next nightly scan
      to record. Skipped when GuestSecurityScan is off.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not $VM.Settings.GuestSecurityScan) {
        Write-LogEntry 'Security baseline turned off in the settings (GuestSecurityScan) - skipping' 'INFO'
        return
    }

    $persistence = [ordered]@{}
    try {
        Install-GuestSecurityFindingOpener -VM $VM
        $facts = Get-GuestPersistenceFact -VM $VM
        $persistence = New-PersistenceBaseline -Item $facts.Items -RecordedAt ([datetimeoffset]::Now)
        Write-LogEntry "Security baseline recorded: $(Format-PersistenceBaselineCount -Baseline $persistence)" 'OK'
    }
    catch {
        Write-LogError 'Recording the security baseline failed (non-fatal); the next nightly scan records it' $_
    }
    try { Save-SecurityBaseline -VM $VM -Persistence $persistence -Approval (Read-SecurityBaseline -VM $VM).Approvals }
    catch { Write-LogError 'Saving the security baseline failed (non-fatal); the next nightly scan records it' $_ }
}

function Add-MissingPersistenceBaseline {
    <#
      Records, from tonight's facts $Item, the baseline of each area
      $Baseline lacks, such as on a VM built before LazyVM had one, or one
      the guest could not read before. Changes $Baseline in place and logs
      each area recorded.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Baseline,
        [AllowNull()][object]$Item,
        [Parameter(Mandatory)][datetimeoffset]$RecordedAt
    )

    $missing = @($script:PersistenceCheck.Keys | Where-Object { -not $Baseline.Contains($_) })
    if ($missing.Count -eq 0) { return }
    $added = New-PersistenceBaseline -Item $Item -RecordedAt $RecordedAt -Area $missing
    foreach ($area in $added.Keys) {
        $Baseline[$area] = $added[$area]
        Write-LogEntry "Security scan: recorded the baseline of $($script:PersistenceCheck[$area].Things) ($(@($added[$area].Items).Count)). Changes from it are reported from the next scan on." 'INFO'
    }
}

function Select-UnapprovedSecurityFinding {
    <# The findings $Finding without those whose Id is approved in $Approval. #>
    [OutputType([SecurityFinding])]
    param(
        [AllowEmptyCollection()][SecurityFinding[]]$Finding = @(),
        [AllowEmptyCollection()][SecurityApproval[]]$Approval = @()
    )

    $approved = @($Approval | ForEach-Object { $_.Id })
    return @($Finding | Where-Object { $_.Id -notin $approved })
}

function Select-LiveSecurityApproval {
    <#
      The approvals that still hold after a scan: those whose finding it
      found again ($FoundId), and those of an area it could not read
      ($Unchecked). Any other has ended.
    #>
    [OutputType([SecurityApproval])]
    param(
        [AllowEmptyCollection()][SecurityApproval[]]$Approval = @(),
        [AllowEmptyCollection()][string[]]$FoundId = @(),
        [AllowEmptyCollection()][string[]]$Unchecked = @()
    )

    return @($Approval | Where-Object { $_.Id -in $FoundId -or [SecurityFinding]::AreaOf($_.Id) -in $Unchecked })
}

function Save-ScannedSecurityBaseline {
    <#
      After a scan: keeps the persistence baseline $Persistence and the
      approvals that still hold (Select-LiveSecurityApproval), logging each
      that ended. Reads the approvals again first, so one made while the
      scan ran is kept.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Persistence,
        [AllowEmptyCollection()][string[]]$FoundId = @(),
        [AllowEmptyCollection()][string[]]$Unchecked = @()
    )

    $approvals = @((Read-SecurityBaseline -VM $VM).Approvals)
    $live = @(Select-LiveSecurityApproval -Approval $approvals -FoundId $FoundId -Unchecked $Unchecked)
    foreach ($ended in @($approvals | Where-Object { $_ -notin $live })) {
        Write-LogEntry "Security scan: the approval of $($ended.Id) ended, because the scan no longer finds it. If it comes back, it is reported again." 'INFO'
    }
    Save-SecurityBaseline -VM $VM -Persistence $Persistence -Approval $live
}

function Get-ApprovableSecurityFinding {
    <#
      The open finding of the last scan with the Id $Id, which
      Approve-LazyVMSecurityFinding approves. Throws, saying why, when
      there is none to approve.
    #>
    [OutputType([SecurityFinding])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Id
    )

    $approved = @((Read-SecurityBaseline -VM $VM).Approvals | Where-Object { $_.Id -eq $Id })
    if ($approved.Count -gt 0) { throw "The security finding $Id on $($VM.Name) is already approved, since $(Format-SecurityFindingTime -Time $approved[0].ApprovedOn)." }
    $record = Read-SecurityFindingRecord -VM $VM
    if (-not $record) { throw "No security scan has run on $($VM.Name) yet, so there is no finding to approve." }
    $finding = @($record.Findings | Where-Object { $_.Id -eq $Id })
    if ($finding.Count -eq 0) { throw "The last security scan of $($VM.Name) has no finding with the Id $Id. See the Ids with: Get-LazyVMSecurityFinding -Name $($VM.Name)" }
    if ($finding[0].Status -eq 'Resolved') { throw "The security finding $Id on $($VM.Name) is resolved, so there is nothing to approve." }
    return $finding[0]
}

function Add-SecurityApproval {
    <# Approves $Finding: records its Id, severity and title, now, and $Reason. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][SecurityFinding]$Finding,
        [AllowEmptyString()][string]$Reason = ''
    )

    $baseline = Read-SecurityBaseline -VM $VM
    $approval = [SecurityApproval]::new($Finding.Id, $Finding.Severity, $Finding.Title, [datetimeoffset]::Now, $Reason)
    Save-SecurityBaseline -VM $VM -Persistence $baseline.Persistence -Approval (@($baseline.Approvals) + $approval)
    Write-LogEntry "Approved the security finding $($Finding.Id) ($($Finding.Title)). LazyVM no longer reports it. If it changes, or happens again, it has a new Id and is reported." 'OK'
}

function Get-SecurityApproval {
    <# The approval of the finding with the Id $Id, which Revoke-LazyVMSecurityFinding revokes. Throws when there is none. #>
    [OutputType([SecurityApproval])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Id
    )

    $approval = @((Read-SecurityBaseline -VM $VM).Approvals | Where-Object { $_.Id -eq $Id })
    if ($approval.Count -eq 0) { throw "$($VM.Name) has no approved finding with the Id $Id. See the approved ones with: Get-LazyVMSecurityFinding -Name $($VM.Name) -Approved" }
    return $approval[0]
}

function Remove-SecurityApproval {
    <# Revokes the approval of the finding with the Id $Id. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Id
    )

    $baseline = Read-SecurityBaseline -VM $VM
    Save-SecurityBaseline -VM $VM -Persistence $baseline.Persistence -Approval @($baseline.Approvals | Where-Object { $_.Id -ne $Id })
    Write-LogEntry "Revoked the approval of the security finding $Id. The next nightly scan reports it again if it still finds it." 'OK'
}

function Get-SecurityApprovalList {
    <# Get-LazyVMSecurityFinding -Approved: each approval, with the VM's name first. Says so when there is none. #>
    [OutputType('LazyVM.SecurityApproval')]
    param([Parameter(Mandatory)][VMContext]$VM)

    $approvals = @((Read-SecurityBaseline -VM $VM).Approvals)
    if ($approvals.Count -eq 0) {
        Write-LogEntry "No security findings are approved on $($VM.Name)." 'INFO'
        return
    }
    foreach ($approval in $approvals) {
        $shown = [ordered]@{ PSTypeName = 'LazyVM.SecurityApproval'; Name = $VM.Name }
        foreach ($property in $approval.PSObject.Properties) { $shown[$property.Name] = $property.Value }
        [pscustomobject]$shown
    }
}
