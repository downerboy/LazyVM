# Persistence.ps1 - The places a program can start itself again, compared with the known-good baseline (#290).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The guest collector ($script:GuestPersistenceWork) lists, for each area,
# every item there: its name, a fingerprint of what it runs, the program it
# starts and whether that program is in a folder users can write to. These
# functions, which only compute, turn that into a baseline and into findings.
#
# An item's Id is '<area>:<name>:<fingerprint>', such as
# 'Service:MySvc:3f9a1c2b7d4e'. The fingerprint changes when what the item
# runs changes, so the Id does too. An item whose Id is not in the baseline
# is a finding: new when the baseline has nothing of that name, changed when
# it has. What was removed is not reported: it can no longer start anything.

# Each area the persistence collector reads, in its order: what one item is
# called (Thing, Things), the severity of a new or changed one, why it
# matters and how to fix it. An item whose program is in a folder users can
# write to is High, whatever its area.
$script:PersistenceCheck = [ordered]@{
    ScheduledTask   = @{
        Thing = 'scheduled task'; Things = 'scheduled tasks'; Severity = 'Medium'
        Why   = 'Malware often adds or changes a scheduled task, so it starts again after a restart.'
        Fix   = 'In the VM, open Task Scheduler, find the task by its path, and look at what it runs. If you do not know it, disable it, and run a full Defender scan.'
    }
    Service         = @{
        Thing = 'service'; Things = 'services'; Severity = 'Medium'
        Why   = 'A service starts with Windows, often as SYSTEM, so malware adds or changes one to run with full rights.'
        Fix   = 'In the VM, open Services (services.msc), find the service by its name, and look at what it runs. If you do not know it, stop it, set its startup type to Disabled, and run a full Defender scan.'
    }
    RunKey          = @{
        Thing = 'Run key entry'; Things = 'Run key entries'; Severity = 'Medium'
        Why   = 'What the Run and RunOnce keys name starts whenever someone signs in. Malware uses them to start again.'
        Fix   = 'In the VM, open Registry Editor at the key in the entry''s name, and look at what the entry runs. If you do not know it, delete the entry, and run a full Defender scan.'
    }
    StartupFolder   = @{
        Thing = 'startup folder item'; Things = 'startup folder items'; Severity = 'Medium'
        Why   = 'What is in a startup folder starts whenever someone signs in. Malware uses it to start again.'
        Fix   = 'In the VM, open the startup folder: in File Explorer, type shell:common startup for All users, or shell:startup for your own, in the address bar. If you do not know the item, delete it, and run a full Defender scan.'
    }
    WmiSubscription = @{
        Thing = 'WMI event subscription'; Things = 'WMI event subscriptions'; Severity = 'High'
        Why   = 'A WMI event subscription runs a command when something happens in Windows. They are rare in normal use, and malware uses them because they are hard to see.'
        Fix   = 'In the VM, as administrator, list them with: Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding. If you do not know this one, remove the binding, its filter and its consumer, and run a full Defender scan.'
    }
    LocalUser       = @{
        Thing = 'local user'; Things = 'local users'; Severity = 'Medium'
        Why   = 'An account nobody expects can be an attacker''s way back in.'
        Fix   = 'In the VM, open Computer Management, then Local Users and Groups. If you do not know the account, disable it, as administrator: Disable-LocalUser -Name <its name>.'
    }
    Administrators  = @{
        Thing = 'member of Administrators'; Things = 'members of Administrators'; Severity = 'High'
        Why   = 'Members of Administrators can change everything in the VM. Attackers add an account they control to keep full rights.'
        Fix   = 'If you do not know the account, remove it from Administrators, as administrator in the VM: Remove-LocalGroupMember -SID S-1-5-32-544 -Member <its name>.'
    }
}

# How every persistence finding ends: the way to accept a change you expect.
$script:SecurityApprovalHint = 'If you know it and expect it, approve it on the host with Approve-LazyVMSecurityFinding and this Id. LazyVM then stops reporting it until it changes.'

function Get-PersistenceItemId {
    <# An item's Id: its area, its name and its fingerprint. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][object]$Item
    )

    return "${Area}:$($Item.Name):$($Item.Fingerprint)"
}

function New-PersistenceBaseline {
    <#
      The baseline of the areas $Area (every one, by default) that the facts
      $Item have: for each, when it was recorded and its items' Ids, sorted.
      An area the guest could not read ($null) is left out, for a later scan
      to record.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()][object]$Item,
        [Parameter(Mandatory)][datetimeoffset]$RecordedAt,
        [string[]]$Area = @($script:PersistenceCheck.Keys)
    )

    $baseline = [ordered]@{}
    foreach ($name in $Area) {
        $found = [RecordReader]::Field($Item, $name)
        if ($null -eq $found) { continue }
        $ids = @(@($found) | ForEach-Object { Get-PersistenceItemId -Area $name -Item $_ } | Sort-Object -Unique)
        $baseline[$name] = @{ RecordedAt = $RecordedAt; Items = [string[]]$ids }
    }
    return $baseline
}

function Format-PersistenceBaselineCount {
    <# How many items each area of the baseline holds, as one line: 'scheduled tasks: 312, services: 245, ...'. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Baseline)

    $counts = foreach ($area in $script:PersistenceCheck.Keys) {
        if ($Baseline.Contains($area)) { "$($script:PersistenceCheck[$area].Things): $(@($Baseline[$area].Items).Count)" }
    }
    if (@($counts).Count -eq 0) { return 'nothing' }
    return ($counts -join ', ')
}

function ConvertTo-PersistenceFinding {
    <#
      A finding for each item in the facts $Item whose Id is not in its
      area's $Baseline. An area the guest could not read, or that has no
      baseline yet, gives none.
    #>
    [OutputType([SecurityFinding])]
    param(
        [AllowNull()][object]$Item,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Baseline
    )

    foreach ($area in $script:PersistenceCheck.Keys) {
        $found = [RecordReader]::Field($Item, $area)
        if ($null -eq $found -or -not $Baseline.Contains($area)) { continue }
        $recorded = $Baseline[$area]
        $known = [System.Collections.Generic.HashSet[string]]::new([string[]]@($recorded.Items), [StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($found)) {
            $id = Get-PersistenceItemId -Area $area -Item $entry
            if ($known.Contains($id)) { continue }
            # Changed when the baseline has an item of that name: the same Id up to its fingerprint, the part after the last colon.
            $prefix = "${area}:$($entry.Name):"
            $changed = @($recorded.Items | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and -not $_.Substring($prefix.Length).Contains(':') }).Count -gt 0
            New-PersistenceFinding -Area $area -Item $entry -Id $id -Changed:$changed -RecordedAt $recorded.RecordedAt
        }
    }
}

function New-PersistenceFinding {
    <# The finding for one item that is new or changed since the baseline was recorded at $RecordedAt. #>
    [OutputType([SecurityFinding])]
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][string]$Id,
        [switch]$Changed,
        [Parameter(Mandatory)][datetimeoffset]$RecordedAt
    )

    $check = $script:PersistenceCheck[$Area]
    $since = Format-SecurityFindingTime -Time $RecordedAt
    $what = if ($Changed) { "The $($check.Thing) $($Item.Name) changed since LazyVM recorded the baseline on $since." }
    else { "The $($check.Thing) $($Item.Name) was not there when LazyVM recorded the baseline on $since." }
    # The program's path goes under Where, which the guest's desktop copy shortens to its name.
    $program = "$($Item.Program)"
    if ($program) { $what += ' It starts the program under Where.' }
    if ($Item.InUserFolder) { $what += ' That program is in a folder users can write to, where malware often hides.' }
    $severity = if ($Item.InUserFolder) { 'High' } else { $check.Severity }
    $title = if ($Changed) { "Changed $($check.Thing): $($Item.Name)" } else { "New $($check.Thing): $($Item.Name)" }

    New-SecurityFinding -Id $Id -Severity $severity -Title $title -WhatWeFound $what -WhyItMatters $check.Why `
        -HowToFix "$($check.Fix) $script:SecurityApprovalHint" -Where @(if ($program) { $program })
}
