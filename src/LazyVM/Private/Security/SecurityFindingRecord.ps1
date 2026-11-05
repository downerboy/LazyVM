# SecurityFindingRecord.ps1 - Where the security scan keeps what it found (#290).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# <VM>\Logs\SecurityFindings.json holds the last scan's findings, when the
# guest collected them, and the areas it could not read.

function Read-SecurityFindingRecord {
    <#
      The VM's last scan: when the guest collected its facts (ScannedAt),
      its Findings, and the areas it could not read (Unchecked). $null
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
            Findings  = [SecurityFinding[]]@(@($record.Findings) | ForEach-Object { [SecurityFinding]::FromObject($_) })
            Unchecked = [RecordReader]::Strings($record, 'Unchecked')
        }
    }
    catch {
        Write-LogEntry "The last security findings ($path) could not be read, so this counts as the first scan: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Save-SecurityFindingRecord {
    <# Keeps the scan's findings in <VM>\Logs\SecurityFindings.json, with when the guest collected them and the areas it could not read. Holds no secrets. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][datetimeoffset]$ScannedAt,
        [Parameter(Mandatory)][AllowEmptyCollection()][SecurityFinding[]]$Finding,
        [AllowEmptyCollection()][string[]]$Unchecked = @()
    )

    $record = [ordered]@{
        ScannedAt = $ScannedAt.ToString('o', [cultureinfo]::InvariantCulture)
        Findings  = @($Finding | ForEach-Object { $_.ToRecord() })
        Unchecked = @($Unchecked)
    }
    Write-TextFileAtomic -Path $VM.Settings.SecurityFindingsFile -Text (ConvertTo-Json -InputObject $record -Depth 4)
}
