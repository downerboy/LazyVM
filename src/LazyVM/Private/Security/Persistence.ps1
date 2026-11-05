# Persistence.ps1 - The places a program can start itself again, compared with the known-good baseline (#290, #334).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# The guest collector ($script:GuestPersistenceWork) lists, for each area,
# every item there: its name, a fingerprint of what it runs, the program it
# starts and whether it points into a folder users can write to. These
# functions, which only compute, turn that into a baseline and into findings.
#
# A baseline area holds, for each item name, the fingerprints known for it.
# An item is a finding when its fingerprint is not known for its name: new
# when the name is not in the baseline, changed when it is. A name the
# baseline knows that the guest no longer has is reported as removed: Low,
# or High for one of Defender's or Sysmon's own tasks and services, which
# malware turns off. Its Id is '<area>:<name>:<fingerprint>'
# (Get-PersistenceItemId, the only place that makes one); nothing takes an
# Id apart again, except Read-SecurityBaselineFile once, for a baseline
# LazyVM 6.6.0 kept as Ids.

# Each area the persistence collector reads, in its order: what one item is
# called (Thing, Things), the severity of a new or changed one, why it
# matters and how to fix it. An item that points into a folder users can
# write to is High, whatever its area.
$script:PersistenceCheck = [ordered]@{
    ScheduledTask     = @{
        Thing = 'scheduled task'; Things = 'scheduled tasks'; Severity = 'Medium'
        Why   = 'Malware often adds or changes a scheduled task, so it starts again after a restart.'
        Fix   = 'In the VM, open Task Scheduler, find the task by its path, and look at what it runs. If you do not know it, disable it, and run a full Defender scan.'
    }
    Service           = @{
        Thing = 'service'; Things = 'services'; Severity = 'Medium'
        Why   = 'A service starts with Windows, often as SYSTEM, so malware adds or changes one to run with full rights.'
        Fix   = 'In the VM, open Services (services.msc), find the service by its name, and look at what it runs and what it does when it fails. If you do not know it, stop it, set its startup type to Disabled, and run a full Defender scan.'
    }
    RunKey            = @{
        Thing = 'Run key entry'; Things = 'Run key entries for all users'; Severity = 'Medium'
        Why   = 'What the Run and RunOnce keys name starts whenever someone signs in. Malware uses them to start again.'
        Fix   = 'In the VM, open Registry Editor at the key in the entry''s name, and look at what the entry runs. If you do not know it, delete the entry, and run a full Defender scan.'
    }
    UserRunKey        = @{
        Thing = 'Run key entry'; Things = 'Run key entries of the guest account'; Severity = 'Medium'
        Why   = 'What the Run and RunOnce keys name starts whenever someone signs in. Malware uses them to start again.'
        Fix   = 'In the VM, signed in as the guest account, open Registry Editor at the key in the entry''s name, and look at what the entry runs. If you do not know it, delete the entry, and run a full Defender scan.'
    }
    StartupFolder     = @{
        Thing = 'startup folder item'; Things = 'startup folder items for all users'; Severity = 'Medium'
        Why   = 'What is in a startup folder starts whenever someone signs in. Malware uses it to start again.'
        Fix   = 'In the VM, open the startup folder: in File Explorer, type shell:common startup in the address bar. If you do not know the item, delete it, and run a full Defender scan.'
    }
    UserStartupFolder = @{
        Thing = 'startup folder item'; Things = 'startup folder items of the guest account'; Severity = 'Medium'
        Why   = 'What is in a startup folder starts whenever someone signs in. Malware uses it to start again.'
        Fix   = 'In the VM, signed in as the guest account, open the startup folder: in File Explorer, type shell:startup in the address bar. If you do not know the item, delete it, and run a full Defender scan.'
    }
    WmiSubscription   = @{
        Thing = 'WMI event subscription'; Things = 'WMI event subscriptions'; Severity = 'High'
        Why   = 'A WMI event subscription runs a command when something happens in Windows. They are rare in normal use, and malware uses them because they are hard to see.'
        Fix   = 'In the VM, as administrator, list them with: Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding. If you do not know this one, remove the binding, its filter and its consumer, and run a full Defender scan.'
    }
    LocalUser         = @{
        Thing = 'local user'; Things = 'local users'; Severity = 'Medium'
        Why   = 'An account nobody expects can be an attacker''s way back in.'
        Fix   = 'In the VM, open Computer Management, then Local Users and Groups. If you do not know the account, disable it, as administrator: Disable-LocalUser -Name <its name>.'
    }
    Administrators    = @{
        Thing = 'member of Administrators'; Things = 'members of Administrators'; Severity = 'High'
        Why   = 'Members of Administrators can change everything in the VM. Attackers add an account they control to keep full rights.'
        Fix   = 'If you do not know the account, remove it from Administrators, as administrator in the VM: Remove-LocalGroupMember -SID S-1-5-32-544 -Member <its name>.'
    }
}

# The fingerprints the collector gives an item it could not fingerprint:
# one it could not read, and a link (reparse point) it does not follow.
# They are never known, so such an item is always a finding.
$script:UnreadableFingerprint = 'unreadable'
$script:LinkFingerprint = 'link'
# The fingerprint of a finding about an item the baseline knows and the guest no longer has.
$script:RemovedFingerprint = 'removed'

# Defender's and Sysmon's own scheduled tasks and services, by name (-like):
# one of them removed is High.
$script:ProtectedPersistenceItem = @{
    ScheduledTask = @('\Microsoft\Windows\Windows Defender\*', '*Sysmon*')
    Service       = @('WinDefend', 'WdNisSvc', 'MDCoreSvc', 'Sense', $script:SysmonServicePattern)
}

# How every persistence finding ends: the way to accept a change you expect.
$script:SecurityApprovalHint = 'If you know it and expect it, approve it on the host with Approve-LazyVMSecurityFinding and this Id. LazyVM then stops reporting it until it changes.'

function Get-PersistenceItemId {
    <# An item's Id: its area, its name and its fingerprint. The only place one is made. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][pscustomobject]$Item
    )

    return "${Area}:$($Item.Name):$($Item.Fingerprint)"
}

function Get-PersistenceAreaItem {
    <#
      The items the guest's facts $Item list for $Area, each as Name,
      Fingerprint, Program and InUserFolder, with the guest's text made
      printable (ConvertTo-PrintableText) before anything is made from it.
      $null when the guest could not read the area.
    #>
    [OutputType([pscustomobject[]])]
    param(
        [AllowNull()][object]$Item,
        [Parameter(Mandatory)][string]$Area
    )

    $found = [RecordReader]::Field($Item, $Area)
    if ($null -eq $found) { return $null }
    $items = foreach ($entry in @($found | Where-Object { $_ })) {
        [pscustomobject]@{
            Name         = ConvertTo-PrintableText -Text ([RecordReader]::Text($entry, 'Name'))
            Fingerprint  = ConvertTo-PrintableText -Text ([RecordReader]::Text($entry, 'Fingerprint'))
            Program      = ConvertTo-PrintableText -Text ([RecordReader]::Text($entry, 'Program'))
            InUserFolder = [bool][RecordReader]::Field($entry, 'InUserFolder')
        }
    }
    return , [pscustomobject[]]@($items)
}

function Test-PersistenceFingerprintKnowable {
    <# Whether a fingerprint can be known: not one the collector gives an item it could not fingerprint. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Fingerprint)

    return $Fingerprint -and $Fingerprint -notin $script:UnreadableFingerprint, $script:LinkFingerprint, $script:RemovedFingerprint
}

function New-PersistenceBaseline {
    <#
      The baseline of the areas $Area (every one, by default) that the facts
      $Item have: for each, when it was recorded and, for each item name,
      its fingerprint. An area the guest could not read is left out, for a
      later scan to record, and so is an item it could not fingerprint.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()][object]$Item,
        [Parameter(Mandatory)][datetimeoffset]$RecordedAt,
        [string[]]$Area = @($script:PersistenceCheck.Keys)
    )

    $baseline = [ordered]@{}
    foreach ($name in $Area) {
        $items = Get-PersistenceAreaItem -Item $Item -Area $name
        if ($null -eq $items) { continue }
        $known = New-PersistenceKnownTable
        foreach ($entry in @($items | Where-Object { Test-PersistenceFingerprintKnowable -Fingerprint $_.Fingerprint })) {
            Add-PersistenceKnownFingerprint -Known $known -Name $entry.Name -Fingerprint $entry.Fingerprint
        }
        $baseline[$name] = @{ RecordedAt = $RecordedAt; Items = $known }
    }
    return $baseline
}

function New-PersistenceKnownTable {
    <# An empty table of item name -> the fingerprints known for it, names compared as Windows does, ignoring case. #>
    [OutputType([System.Collections.Generic.Dictionary[string, string[]]])]
    param()

    return , [System.Collections.Generic.Dictionary[string, string[]]]::new([StringComparer]::OrdinalIgnoreCase)
}

function Add-PersistenceKnownFingerprint {
    <# Adds $Fingerprint to those known for $Name in $Known, once. #>
    param(
        [Parameter(Mandatory)][System.Collections.Generic.Dictionary[string, string[]]]$Known,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Fingerprint
    )

    $current = @(if ($Known.ContainsKey($Name)) { $Known[$Name] })
    if ($Fingerprint -notin $current) { $Known[$Name] = [string[]]@($current + $Fingerprint) }
}

function Get-PersistenceNameToUpgrade {
    <# The names a baseline area kept by LazyVM 6.6.0 knew, still to upgrade; none for any other area. #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Area)

    return [string[]]@($Area['NamesToUpgrade'] | Where-Object { $_ })
}

function Update-LegacyPersistenceBaseline {
    <#
      Upgrades each area of $Baseline that LazyVM 6.6.0 kept as Ids, whose
      fingerprints are not trusted, only its item names (NamesToUpgrade):
      an item tonight's facts $Item have under such a name is known from
      now on with its new fingerprint; a name they do not have is kept with
      none, so it is reported as removed; a name not in the list stays a
      finding. An area the guest could not read tonight waits. Changes
      $Baseline in place; returns the areas it upgraded.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Baseline,
        [AllowNull()][object]$Item
    )

    $upgraded = foreach ($area in @($Baseline.Keys | Where-Object { Get-PersistenceNameToUpgrade -Area $Baseline[$_] })) {
        $items = Get-PersistenceAreaItem -Item $Item -Area $area
        if ($null -eq $items) { continue }
        $recorded = $Baseline[$area]
        $names = @(Get-PersistenceNameToUpgrade -Area $recorded)
        foreach ($entry in @($items | Where-Object { $_.Name -in $names -and (Test-PersistenceFingerprintKnowable -Fingerprint $_.Fingerprint) })) {
            Add-PersistenceKnownFingerprint -Known $recorded.Items -Name $entry.Name -Fingerprint $entry.Fingerprint
        }
        foreach ($name in @($names | Where-Object { -not $recorded.Items.ContainsKey($_) })) { $recorded.Items[$name] = [string[]]@() }
        $Baseline[$area] = @{ RecordedAt = $recorded.RecordedAt; Items = $recorded.Items }
        $area
    }
    return [string[]]@($upgraded)
}

function Join-PersistenceBaseline {
    <#
      The baseline $Baseline with, in each of its areas, the fingerprints
      $Earlier knows too: what a rebuild records, so an item restored from
      the old VM counts as known only if it was known there. An area only
      $Earlier has is kept as it was.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Baseline,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Earlier
    )

    $joined = [ordered]@{}
    foreach ($area in @($Earlier.Keys) + @($Baseline.Keys | Where-Object { -not $Earlier.Contains($_) })) {
        if (-not $Baseline.Contains($area)) {
            $joined[$area] = $Earlier[$area]
            continue
        }
        $known = New-PersistenceKnownTable
        foreach ($source in @($Baseline[$area], $Earlier[$area] | Where-Object { $_ })) {
            foreach ($name in $source.Items.Keys) {
                if (-not $known.ContainsKey($name)) { $known[$name] = [string[]]@() }
                foreach ($fingerprint in $source.Items[$name]) { Add-PersistenceKnownFingerprint -Known $known -Name $name -Fingerprint $fingerprint }
            }
        }
        $joined[$area] = @{ RecordedAt = $Baseline[$area].RecordedAt; Items = $known }
        # Names an old baseline knew without fingerprints are still to upgrade.
        $names = @(if ($Earlier.Contains($area)) { Get-PersistenceNameToUpgrade -Area $Earlier[$area] })
        if ($names.Count -gt 0) { $joined[$area].NamesToUpgrade = [string[]]$names }
    }
    return $joined
}

function Format-PersistenceBaselineCount {
    <# How many items each area of the baseline holds, as one line: 'scheduled tasks: 312, services: 245, ...'. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Baseline)

    $counts = foreach ($area in $script:PersistenceCheck.Keys) {
        if ($Baseline.Contains($area)) { "$($script:PersistenceCheck[$area].Things): $($Baseline[$area].Items.Count)" }
    }
    if (@($counts).Count -eq 0) { return 'nothing' }
    return ($counts -join ', ')
}

function ConvertTo-PersistenceFinding {
    <#
      A finding for each item in the facts $Item whose fingerprint its
      area's $Baseline does not know for its name, and for each name it
      knows that the guest no longer has. An area the guest could not read,
      or that has no baseline yet, gives none.
    #>
    [OutputType([SecurityFinding])]
    param(
        [AllowNull()][object]$Item,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Baseline
    )

    foreach ($area in $script:PersistenceCheck.Keys) {
        $items = Get-PersistenceAreaItem -Item $Item -Area $area
        if ($null -eq $items -or -not $Baseline.Contains($area)) { continue }
        $recorded = $Baseline[$area]
        foreach ($entry in $items) {
            $named = $recorded.Items.ContainsKey($entry.Name)
            if ($named -and $entry.Fingerprint -in $recorded.Items[$entry.Name] -and (Test-PersistenceFingerprintKnowable -Fingerprint $entry.Fingerprint)) { continue }
            New-PersistenceFinding -Area $area -Item $entry -Changed:$named -RecordedAt $recorded.RecordedAt
        }
        $present = [System.Collections.Generic.HashSet[string]]::new([string[]]@($items | ForEach-Object { $_.Name }), [StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @($recorded.Items.Keys | Where-Object { -not $present.Contains($_) } | Sort-Object)) {
            $removed = [pscustomobject]@{ Name = $name; Fingerprint = $script:RemovedFingerprint; Program = ''; InUserFolder = $false }
            New-PersistenceFinding -Area $area -Item $removed -RecordedAt $recorded.RecordedAt
        }
    }
}

function Test-ProtectedPersistenceItem {
    <# Whether $Name in $Area is one of Defender's or Sysmon's own tasks or services. #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Name
    )

    return @(@($script:ProtectedPersistenceItem[$Area]) | Where-Object { $_ -and $Name -like $_ }).Count -gt 0
}

function New-PersistenceFinding {
    <# The finding for one item that is new, changed, unreadable or a link since the baseline was recorded at $RecordedAt. #>
    [OutputType([SecurityFinding])]
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][pscustomobject]$Item,
        [switch]$Changed,
        [Parameter(Mandatory)][datetimeoffset]$RecordedAt
    )

    $check = $script:PersistenceCheck[$Area]
    $thing = "$($check.Thing) $($Item.Name)"
    $since = Format-SecurityFindingTime -Time $RecordedAt
    $severity = $check.Severity
    $why = $check.Why
    switch ($Item.Fingerprint) {
        $script:RemovedFingerprint {
            $title = "Removed $($check.Thing): $($Item.Name)"
            $what = "The $thing was there when LazyVM recorded the baseline on $since, and is gone."
            $why = 'Malware removes what protects the VM, such as Defender''s and Sysmon''s own tasks and services. Something you removed, or a program you uninstalled took with it, is fine.'
            $severity = if (Test-ProtectedPersistenceItem -Area $Area -Name $Item.Name) { 'High' } else { 'Low' }
        }
        $script:UnreadableFingerprint {
            $title = "Unreadable $($check.Thing): $($Item.Name)"
            $what = "LazyVM could not read the $thing, so it cannot tell whether it changed. A program can stop SYSTEM reading what it added, to hide it from checks like this one."
        }
        $script:LinkFingerprint {
            $title = "Link in a startup folder: $($Item.Name)"
            $what = "The $thing is a link (a reparse point) to somewhere else. LazyVM does not follow links, so it did not read what it leads to."
        }
        default {
            $title = if ($Changed) { "Changed $($check.Thing): $($Item.Name)" } else { "New $($check.Thing): $($Item.Name)" }
            $what = if ($Changed) { "The $thing changed since LazyVM recorded the baseline on $since." } else { "The $thing was not there when LazyVM recorded the baseline on $since." }
        }
    }
    # The program's path goes under Where, which the guest's desktop copy shortens to its name.
    if ($Item.Program) { $what += ' It starts the program under Where.' }
    if ($Item.InUserFolder) {
        $what += ' It points into a folder users can write to, where malware often hides.'
        $severity = 'High'
    }

    New-SecurityFinding -Id (Get-PersistenceItemId -Area $Area -Item $Item) -Severity $severity -Title $title -WhatWeFound $what -WhyItMatters $why `
        -HowToFix "$($check.Fix) $script:SecurityApprovalHint" -Where @(if ($Item.Program) { $Item.Program })
}

function Get-UnreadablePersistenceAreaFinding {
    <#
      A Medium finding for each persistence area the guest could not read
      tonight ($Unchecked) nor at the scan before ($PreviouslyUnchecked):
      while it cannot be read, a change there goes unnoticed.
    #>
    [OutputType([SecurityFinding])]
    param(
        [AllowEmptyCollection()][string[]]$Unchecked = @(),
        [AllowEmptyCollection()][string[]]$PreviouslyUnchecked = @()
    )

    foreach ($area in @($script:PersistenceCheck.Keys | Where-Object { $_ -in $Unchecked -and $_ -in $PreviouslyUnchecked })) {
        $things = $script:PersistenceCheck[$area].Things
        New-SecurityFinding -Id "UnreadableArea:$area" -Severity Medium -Title "LazyVM could not read the $things two scans running" `
            -WhatWeFound "The last two nightly scans could not read the $things, so a change there goes unnoticed." `
            -WhyItMatters 'Malware can stop SYSTEM reading the places it starts from, to hide from checks like this one.' `
            -HowToFix "The VM's log says why, in the line that begins: Security scan: could not read $area. If the guest account was not signed in, sign it in. Otherwise, run a full Defender scan."
    }
}
