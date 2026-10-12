function Build-LazyVM {
    <#
    .SYNOPSIS
    Builds a VM, unattended, from its profile.

    .DESCRIPTION
    Runs the build phases in order, skipping whatever is already done, so it
    is safe to run again after a failure:

      0  Hyper-V service health check
      1  CPU, firmware, memory and disk space readiness
      2  Hyper-V turned on if needed. The host restarts and the build carries
         on by itself afterwards.
      3  The folders under the LazyVM folder
      4  The Windows ISO checked and the SQL Server ISO downloaded
      5  The SQL data disk and the Dev Drive disk (never overwritten)
      6  The VM: Generation 2, Secure Boot, TPM, dynamic memory, with an
         answer-file disc so Windows installs without any input
      7  Windows, then everything in the VM's tooling list: Visual Studio and
         SSMS with their workloads and extensions, SQL Server, and winget
         packages
      8  SQL data moved to the data disk, Visual Studio settings restored

    Progress is shown as it goes and written to the VM's log.

    The Windows 11 Enterprise evaluation ISO cannot be downloaded
    automatically. If none is found, the download page opens in your browser;
    save the ISO in the LazyVM folder's ISO folder and run Build-LazyVM again.

    .PARAMETER Name
    The VM to build. May be left out while there is only one.

    .PARAMETER FromPhase
    Start at this phase, skipping the earlier ones. Mostly for picking up
    after fixing a problem in a later phase.

    .PARAMETER NoUnattend
    Do not give the VM an answer file: Windows Setup has to be completed by
    hand in VMConnect, and Phase 7 waits for that.

    .EXAMPLE
    Build-LazyVM -Name DevBox

    .EXAMPLE
    Build-LazyVM -Name DevBox -FromPhase 7

    Carries on with the installs after fixing what stopped them.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Position = 0)]
        [string]$Name,

        [ValidateRange(0, 8)]
        [int]$FromPhase = 0,

        [switch]$NoUnattend
    )

    Assert-Administrator
    try {
        $null = Initialize-CommandRun -Title 'Build' -Name $Name

        $result = Invoke-VMBuild -FromPhase $FromPhase -NoUnattend:$NoUnattend
        if ($result -eq 'RestartPending') {
            Write-Log 'The host is restarting to finish turning on Hyper-V. The build carries on by itself afterwards.' 'WARN'
            return
        }

        Write-Log '' 'INFO'
        Write-Log '========================================================' 'INFO'
        Write-Log "  All phases complete. $($CFG.VMName) is ready."          'OK'
        Write-Log "  Log : $($CFG.LogFile)"                                 'INFO'
        Write-Log '========================================================' 'INFO'
    }
    catch {
        if ($script:LogReady) { Write-LogError 'Build stopped' $_ }
        $PSCmdlet.ThrowTerminatingError($_)
    }
    finally {
        Complete-CommandRun
    }
}
