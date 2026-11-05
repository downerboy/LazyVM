# SecurityBaseline.ps1 - Where the security scan's known-good baseline and the approved findings are kept (#290, #334).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Both are in <VM>\Config\SecurityBaseline.json:
#   Persistence  for each persistence area, when its baseline was recorded
#                and, for each item name, the fingerprints known for it
#                (Persistence.ps1)
#   Approvals    each approved finding's Id, severity, title, when and why
#                (the SecurityApproval class, SecurityApproval.ps1)
#
# Readers (Read-SecurityBaseline) never fail: a file that cannot be read is
# logged and reads as Readable = $false, with nothing in it. Every write goes
# through Update-SecurityBaseline, which reads the file again under an
# exclusive lock, lets its caller change only its own part, and writes it
# back. A file that cannot be read is never written over: it is moved aside
# to SecurityBaseline.json.bad, and the write fails, saying so.

# How long a write waits for another to finish with the file.
$script:SecurityBaselineLockSeconds = 60

function Read-SecurityBaseline {
    <#
      The VM's baseline: Readable, Persistence (area -> RecordedAt, Items:
      name -> fingerprints) and Approvals. Empty before the first one is
      recorded. When the file cannot be read, that is logged, and it reads
      as Readable = $false with nothing in it.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][VMContext]$VM)

    $path = $VM.Settings.SecurityBaselineFile
    try {
        $record = Read-SecurityBaselineFile -Path $path
        $record | Add-Member -NotePropertyName Readable -NotePropertyValue $true
        return $record
    }
    catch {
        Write-LogEntry "The security baseline ($path) could not be read: $($_.Exception.Message). Until it is fixed or moved aside, no finding counts as approved, and the scan does not check the places programs start from." 'WARN'
        return [pscustomobject]@{ Persistence = [ordered]@{}; Approvals = [SecurityApproval[]]@(); Readable = $false }
    }
}

function Update-SecurityBaseline {
    <#
      The one way to write the baseline. Under an exclusive lock on
      SecurityBaseline.json.lock, reads the file as it is now, runs $Change
      with it (Persistence and Approvals, to change in place), and writes it
      back. When the file cannot be read, moves it aside to
      SecurityBaseline.json.bad and throws, so it is never written over.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][scriptblock]$Change
    )

    $path = $VM.Settings.SecurityBaselineFile
    New-Folder -Path (Split-Path -Path $path -Parent)
    $lock = Lock-SecurityBaseline -Path "$path.lock"
    try {
        try { $record = Read-SecurityBaselineFile -Path $path }
        catch {
            $bad = "$path.bad"
            Move-CheckedItem -Path $path -Destination $bad
            throw "The security baseline ($path) could not be read, so LazyVM did not change it, and moved it aside to $bad. The next build or nightly scan records a new one. $($_.Exception.Message)"
        }
        $null = & $Change $record
        Write-TextFileAtomic -Path $path -Text (ConvertTo-SecurityBaselineJson -Record $record)
    }
    finally { $lock.Dispose() }
}

function Lock-SecurityBaseline {
    <# Opens $Path so that nothing else can, waiting while another write has it. Returns the open file, to Dispose when done. #>
    [OutputType([System.IO.FileStream])]
    param([Parameter(Mandatory)][string]$Path)

    Assert-NoReparsePoint -Path $Path
    $deadline = [datetime]::UtcNow.AddSeconds($script:SecurityBaselineLockSeconds)
    while ($true) {
        try { return [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) }
        catch [System.IO.IOException] {
            if ([datetime]::UtcNow -gt $deadline) { throw "The security baseline is being changed by something else, for more than $script:SecurityBaselineLockSeconds seconds. Try again." }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Read-SecurityBaselineFile {
    <# The baseline in $Path: Persistence and Approvals, empty when there is no file. Throws when it cannot be read. #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    $record = [pscustomobject]@{ Persistence = [ordered]@{}; Approvals = [SecurityApproval[]]@() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $record }

    $kept = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -DateKind String
    $areas = [RecordReader]::Field($kept, 'Persistence')
    foreach ($area in @(if ($areas) { $areas.PSObject.Properties })) {
        $items = @([RecordReader]::Field($area.Value, 'Items'))
        # One kept as Ids (LazyVM 6.6 before #334) is left out, for the next scan to record again.
        if (@($items | Where-Object { $_ -is [string] }).Count -gt 0) { continue }
        $known = New-PersistenceKnownTable
        foreach ($item in @($items | Where-Object { $_ })) {
            foreach ($fingerprint in [RecordReader]::Strings($item, 'Fingerprints')) {
                Add-PersistenceKnownFingerprint -Known $known -Name ([RecordReader]::Text($item, 'Name')) -Fingerprint $fingerprint
            }
        }
        $record.Persistence[$area.Name] = @{
            RecordedAt = [datetimeoffset]::Parse([RecordReader]::Text($area.Value, 'RecordedAt'), [cultureinfo]::InvariantCulture)
            Items      = $known
        }
    }
    $record.Approvals = [SecurityApproval[]]@(@([RecordReader]::Field($kept, 'Approvals')) | Where-Object { $_ } | ForEach-Object { [SecurityApproval]::FromObject($_) })
    return $record
}

function ConvertTo-SecurityBaselineJson {
    <# The baseline $Record as SecurityBaseline.json keeps it. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Record)

    $areas = [ordered]@{}
    foreach ($area in $Record.Persistence.Keys) {
        $known = $Record.Persistence[$area].Items
        $areas[$area] = [ordered]@{
            RecordedAt = ([datetimeoffset]$Record.Persistence[$area].RecordedAt).ToString('o', [cultureinfo]::InvariantCulture)
            Items      = @($known.Keys | Sort-Object | ForEach-Object { [ordered]@{ Name = $_; Fingerprints = @($known[$_]) } })
        }
    }
    $document = [ordered]@{ Persistence = $areas; Approvals = @($Record.Approvals | ForEach-Object { $_.ToRecord() }) }
    return (ConvertTo-Json -InputObject $document -Depth 6)
}
