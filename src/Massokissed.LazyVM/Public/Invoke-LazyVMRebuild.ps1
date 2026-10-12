function Invoke-LazyVMRebuild {
    <#
    .SYNOPSIS
    Rebuilds a VM from scratch, keeping its work.

    .DESCRIPTION
    Captures the VM's state, retires its Windows disk by renaming it, builds
    a fresh VM from the profile and tooling list, puts the captured state
    back and checks the result. The old Windows disk is deleted only once the
    new VM has passed the check; if anything goes wrong it is kept, and the
    log says how to go back to it.

    The SQL data disk and the Dev Drive are never touched.

    The daily maintenance does this by itself when the Windows evaluation is
    about to expire and no rearms are left.

    .PARAMETER Name
    The VM to rebuild.

    .PARAMETER SkipCapture
    Use the capture already on the host instead of taking a new one.

    .PARAMETER NoUnattend
    Do not give the new VM an answer file: Windows Setup has to be completed
    by hand.

    .PARAMETER Force
    Do not ask for confirmation.

    .EXAMPLE
    Invoke-LazyVMRebuild -Name DevBox
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [switch]$SkipCapture,

        [switch]$NoUnattend,

        [switch]$Force
    )

    if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
        $ConfirmPreference = 'None'
    }

    Assert-Administrator
    try {
        $null = Initialize-CommandRun -Title 'Rebuild' -Name $Name
        $action = 'Rebuild from scratch. State is captured first and restored afterwards, and the old Windows disk is kept until the new VM is checked'
        if (-not $PSCmdlet.ShouldProcess($CFG.VMName, $action)) {
            Write-Log 'Rebuild cancelled' 'INFO'
            return
        }

        $ok = @(Invoke-Rebuild -SkipCapture:$SkipCapture -NoUnattend:$NoUnattend)[-1]
        if ($ok -ne $true) {
            throw "The rebuild of '$($CFG.VMName)' did not complete cleanly. The log says what happened and how to go back: $($CFG.LogFile)"
        }
    }
    catch {
        if ($script:LogReady) { Write-LogError 'The rebuild stopped' $_ }
        $PSCmdlet.ThrowTerminatingError($_)
    }
    finally {
        Complete-CommandRun
    }
}
