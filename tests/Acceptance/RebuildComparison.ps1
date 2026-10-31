# RebuildComparison.ps1 - Compares the guest before and after a rebuild
# from VM.json (#39). Dot-sourced by RebuildFromProfile.Tests.ps1 and by
# its unit tests, tests\RebuildComparison.Tests.ps1.
#
# A snapshot is a dictionary of areas (Tooling, Environment, Databases,
# UserData...), each a list of entries: strings, or objects whose property
# order does not matter. Areas are compared as sets.

function ConvertTo-SnapshotValue {
    <# The value with every dictionary's and object's properties sorted by name, so equal values serialize the same. #>
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject -or $InputObject -is [string] -or $InputObject -is [ValueType]) {
        return $InputObject
    }
    $properties = Get-SnapshotProperty -InputObject $InputObject
    if ($null -ne $properties) {
        $sorted = [ordered]@{}
        foreach ($name in @($properties.Keys | Sort-Object)) {
            $sorted[$name] = ConvertTo-SnapshotValue -InputObject $properties[$name]
        }
        return $sorted
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        return , @(foreach ($item in $InputObject) { ConvertTo-SnapshotValue -InputObject $item })
    }
    return "$InputObject"
}

function Get-SnapshotProperty {
    <# A dictionary's or an object's properties as a hashtable; $null for anything else. #>
    param([AllowNull()][object]$InputObject)

    if ($InputObject -is [System.Collections.IDictionary]) {
        $properties = @{}
        foreach ($key in $InputObject.Keys) { $properties["$key"] = $InputObject[$key] }
        return $properties
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $properties = @{}
        foreach ($property in $InputObject.PSObject.Properties) { $properties[$property.Name] = $property.Value }
        return $properties
    }
    return $null
}

function ConvertTo-SnapshotEntry {
    <# One snapshot entry as text: a string as it is, anything else as compact JSON with its properties sorted. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()][object]$InputObject)

    if ($InputObject -is [string]) { return $InputObject }
    return ConvertTo-Json -InputObject (ConvertTo-SnapshotValue -InputObject $InputObject) -Compress -Depth 20
}

function Get-SnapshotAreaEntry {
    <# The area's entries as text, without repeats; empty when the snapshot does not have the area. #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [Parameter(Mandatory)][string]$Area
    )

    if (-not $Snapshot.Contains($Area)) { return @() }
    return @(@($Snapshot[$Area]) | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-SnapshotEntry -InputObject $_ } | Sort-Object -Unique)
}

function Compare-GuestSnapshot {
    <#
      What differs between the guest before a rebuild and after it: one
      result per entry (Area, Change, Entry), where Change is Lost (only
      before) or Gained (only after). Nothing when they match.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Before,
        [Parameter(Mandatory)][System.Collections.IDictionary]$After,
        [string[]]$IgnoreArea = @()
    )

    $areas = @(@($Before.Keys) + @($After.Keys) | ForEach-Object { "$_" } | Sort-Object -Unique | Where-Object { $_ -notin $IgnoreArea })
    foreach ($area in $areas) {
        $old = @(Get-SnapshotAreaEntry -Snapshot $Before -Area $area)
        $new = @(Get-SnapshotAreaEntry -Snapshot $After -Area $area)
        foreach ($entry in $old) {
            if ($entry -cnotin $new) { [pscustomobject]@{ Area = $area; Change = 'Lost'; Entry = $entry } }
        }
        foreach ($entry in $new) {
            if ($entry -cnotin $old) { [pscustomobject]@{ Area = $area; Change = 'Gained'; Entry = $entry } }
        }
    }
}

function Test-SnapshotEntryMatch {
    <# Whether a snapshot entry matches an expected one: equal strings, or every property the expected object has, equal. #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][object]$Expected
    )

    $wanted = Get-SnapshotProperty -InputObject $Expected
    if ($null -eq $wanted) {
        return (ConvertTo-SnapshotEntry -InputObject $Entry) -ceq (ConvertTo-SnapshotEntry -InputObject $Expected)
    }
    $actual = Get-SnapshotProperty -InputObject $Entry
    if ($null -eq $actual) { return $false }
    foreach ($name in $wanted.Keys) {
        if (-not $actual.ContainsKey($name)) { return $false }
        if ((ConvertTo-SnapshotEntry -InputObject $actual[$name]) -cne (ConvertTo-SnapshotEntry -InputObject $wanted[$name])) { return $false }
    }
    return $true
}

function Find-MissingHandChange {
    <#
      The hand changes ($HandChange: areas of expected entries) the snapshot
      does not hold, one result per change (Area, Entry). An expected object
      matches an entry that has each of its properties with the same value.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$HandChange
    )

    foreach ($area in @($HandChange.Keys | ForEach-Object { "$_" } | Sort-Object)) {
        $entries = if ($Snapshot.Contains($area)) { @($Snapshot[$area]) } else { @() }
        foreach ($expected in @($HandChange[$area])) {
            $found = @($entries | Where-Object { $null -ne $_ -and (Test-SnapshotEntryMatch -Entry $_ -Expected $expected) })
            if ($found.Count -eq 0) {
                [pscustomobject]@{ Area = $area; Entry = ConvertTo-SnapshotEntry -InputObject $expected }
            }
        }
    }
}
