function Get-LazyVMLog {
    <#
    .SYNOPSIS
    Shows a VM's log as entries: when, how it went and what happened.

    .DESCRIPTION
    Reads the VM's log, the one its build, maintenance and rebuilds write,
    and returns one entry per line written to it: Time, Level (Info, OK,
    Warning, Error or Phase) and Message. A message that goes on over
    several lines is one entry. Phase entries mark where each phase of a
    build or maintenance run starts.

    It only reads, and does not lock the log, so it can be read while a
    build is still writing it. A VM with no log yet gives nothing. Older
    logs, renamed when the log grew past LogMaxSizeMB, are not read.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .PARAMETER Tail
    Only the newest entries, this many.

    .EXAMPLE
    Get-LazyVMLog -Name DevBox -Tail 50

    .EXAMPLE
    Get-LazyVMLog -Name DevBox | Where-Object Level -in 'Warning', 'Error'

    The warnings and errors in DevBox's log.

    .OUTPUTS
    LazyVM.LogEntry
    #>
    [CmdletBinding()]
    [OutputType('LazyVM.LogEntry')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$Tail
    )

    process {
        $root = (Resolve-LazyVMRoot).Path
        $path = (Read-VMSetting -Root $root -VMName $Name -ReadOnly).Settings.LogFile
        Assert-NoReparsePoint -Path $path -Root $root
        $entries = ConvertFrom-LogLine -Line @(Read-LogLine -Path $path)
        if ($Tail) { $entries | Select-Object -Last $Tail } else { $entries }
    }
}
