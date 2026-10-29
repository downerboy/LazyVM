# ProfileHistory.ps1 - The kept versions of each VM's VM.json.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Every version of VM.json LazyVM writes is kept in <Name>\Config\History as
# VM-<yyyyMMdd-HHmmss>.json, named after when it was written. A recorded
# tooling change is named after the checkpoint taken with it, so each
# restore point has its tooling list. The newest ProfileVersionsToKeep
# versions are kept, with any older one a tooling checkpoint still needs.

function Get-ProfileHistoryDir {
    <# The folder holding a VM's kept versions of VM.json. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name
    )

    return Join-Path -Path (Get-VMProfileDir -Root $Root -Name $Name) -ChildPath $script:HistoryFolderName
}

function Get-ProfileVersionPath {
    <# Where the version of VM.json written at $Stamp is kept. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Stamp
    )

    return Join-Path -Path (Get-ProfileHistoryDir -Root $Root -Name $Name) -ChildPath "VM-$Stamp.json"
}

function Save-ProfileVersion {
    <#
      Keeps $Text as the version of VM.json written at $Stamp. Two versions
      in the same second each keep their own copy. Returns its path.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Stamp
    )

    $historyDir = Get-ProfileHistoryDir -Root $Root -Name $Name
    $path = Get-ProfileVersionPath -Root $Root -Name $Name -Stamp $Stamp
    for ($n = 2; Test-Path -LiteralPath $path; $n++) { $path = Join-Path -Path $historyDir -ChildPath "VM-$Stamp-$n.json" }
    Write-TextFileAtomic -Path $path -Text $Text
    return $path
}

function Get-ProfileVersion {
    <# A VM's kept versions of VM.json, oldest first: each one's date-time and file. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name
    )

    $historyDir = Get-ProfileHistoryDir -Root $Root -Name $Name
    $versions = foreach ($file in @(Get-ChildItem -LiteralPath $historyDir -Filter 'VM-*.json' -File -ErrorAction SilentlyContinue)) {
        if ($file.Name -notmatch '^VM-(?<stamp>\d{8}-\d{6})(-(?<n>\d+))?\.json$') { continue }
        [pscustomobject]@{
            Stamp  = $Matches.stamp
            Number = if ($Matches.ContainsKey('n')) { [int]$Matches['n'] } else { 1 }
            Path   = $file.FullName
        }
    }
    return @($versions | Sort-Object -Property Stamp, Number)
}

function Remove-OldProfileVersion {
    <#
      Removes the versions of VM.json older than the newest
      ProfileVersionsToKeep, except those whose date-time is in $Needed: the
      ones the VM's tooling checkpoints still need. Removes nothing when
      $Needed is $null, because what the checkpoints need is unknown.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][AllowEmptyCollection()][string[]]$Needed
    )

    if ($null -eq $Needed) {
        Write-LogEntry "Kept every earlier version of VM.json: could not ask Hyper-V which of them '$Name''s checkpoints need" 'WARN'
        return
    }
    $versions = @(Get-ProfileVersion -Root $Root -Name $Name)
    foreach ($version in @($versions | Select-Object -SkipLast $script:ProfileVersionsToKeep)) {
        if ($Needed -contains $version.Stamp) { continue }
        Remove-Item -LiteralPath $version.Path -Force
    }
}
