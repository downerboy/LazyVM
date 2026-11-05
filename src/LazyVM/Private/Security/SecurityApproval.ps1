# SecurityApproval.ps1 - The findings the VM's owner approved, so the security scan stops reporting them (#290, #334).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# An approved finding is left out of what the scan reports while it is
# found with the same Id. Once a scan no longer finds it, because it
# changed, was fixed or, for an event, is over, its approval ends. A change
# gives a new Id, so it is reported again. The approvals are kept with the
# baseline (SecurityBaseline.ps1), never with what was found.

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

    $approval = [SecurityApproval]::new($Finding.Id, $Finding.Severity, $Finding.Title, [datetimeoffset]::Now, $Reason)
    Update-SecurityBaseline -VM $VM -Change { param($record) $record.Approvals = [SecurityApproval[]]@(@($record.Approvals) + $approval) }
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

    Update-SecurityBaseline -VM $VM -Change { param($record) $record.Approvals = [SecurityApproval[]]@($record.Approvals | Where-Object { $_.Id -ne $Id }) }
    Write-LogEntry "Revoked the approval of the security finding $Id. The next nightly scan reports it again if it still finds it." 'OK'
}

function Remove-EndedSecurityApproval {
    <#
      After a scan: removes the approvals that no longer hold
      (Select-LiveSecurityApproval), logging each. Changes only the
      approvals, and reads them as they are now, so one made while the scan
      ran is kept.
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Record,
        [AllowEmptyCollection()][string[]]$FoundId = @(),
        [AllowEmptyCollection()][string[]]$Unchecked = @()
    )

    $live = @(Select-LiveSecurityApproval -Approval $Record.Approvals -FoundId $FoundId -Unchecked $Unchecked)
    foreach ($ended in @($Record.Approvals | Where-Object { $_ -notin $live })) {
        Write-LogEntry "Security scan: the approval of $($ended.Id) ended, because the scan no longer finds it. If it comes back, it is reported again." 'INFO'
    }
    $Record.Approvals = [SecurityApproval[]]$live
}

function Add-DefaultSecurityApproval {
    <#
      Approves, in the baseline $Record, what LazyVM does by design:
      automatic sign-in. Once for the VM (DefaultsApproved), so a later build
      does not approve it again after it was revoked.
    #>
    param([Parameter(Mandatory)][pscustomobject]$Record)

    if ($Record.DefaultsApproved) { return }
    if ($script:AutoLogonFindingId -notin @($Record.Approvals | ForEach-Object { $_.Id })) {
        $approval = [SecurityApproval]::new($script:AutoLogonFindingId, 'Info', $script:AutoLogonFindingTitle, [datetimeoffset]::Now, 'LazyVM turns on autologon by design')
        $Record.Approvals = [SecurityApproval[]]@(@($Record.Approvals) + $approval)
        Write-LogEntry "Approved the security finding $($script:AutoLogonFindingId): LazyVM turns on automatic sign-in by design. Revoke-LazyVMSecurityFinding undoes it." 'OK'
    }
    $Record.DefaultsApproved = $true
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
    foreach ($approval in $approvals) { ConvertTo-VMRecordView -VMName $VM.Name -TypeName 'LazyVM.SecurityApproval' -Record $approval }
}
