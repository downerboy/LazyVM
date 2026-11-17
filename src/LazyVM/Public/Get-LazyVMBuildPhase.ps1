function Get-LazyVMBuildPhase {
    <#
    .SYNOPSIS
    Lists the phases of a build: each one's number, name and goal.

    .DESCRIPTION
    Returns one entry per phase Build-LazyVM runs, in order: Number, the
    number -FromPhase takes; Name; and Goal, what the phase does in a few
    words. The LazyVM app shows a build's progress as each phase's number
    with its goal.

    It only reads the module's list of phases, so it needs no VM, no
    LazyVM folder and no administrator rights.

    .EXAMPLE
    Get-LazyVMBuildPhase

    .EXAMPLE
    Get-LazyVMBuildPhase | Where-Object Number -ge 6

    The phases a build run with -FromPhase 6 goes through.

    .OUTPUTS
    LazyVM.BuildPhase
    #>
    [CmdletBinding()]
    [OutputType('LazyVM.BuildPhase')]
    param()

    foreach ($phase in Get-BuildPhase) {
        [pscustomobject]@{
            PSTypeName = 'LazyVM.BuildPhase'
            Number     = $phase.Number
            Name       = $phase.Name
            Goal       = $phase.Goal
        }
    }
}
