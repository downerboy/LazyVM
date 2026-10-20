function Build-LazyVM {
    <#
    .SYNOPSIS
    Builds a VM, unattended. One command does everything.

    .DESCRIPTION
    Build-LazyVM -Name DevBox is all it takes. On first use it also:

      - chooses the LazyVM folder, if none has been: <drive>:\LazyVM on the
        local drive with the most free space (Set-LazyVMRoot chooses another)
      - creates the VM's profile, if it has none (New-LazyVM is optional)
      - finds the Windows ISO, including in your Downloads folder, and moves
        it into the LazyVM folder; with no ISO anywhere it opens the download
        page and stops, so you download it and run the same command again
      - creates the administrator account inside the VM
      - schedules the daily maintenance, once the build has succeeded

    The build runs these phases, skipping whatever is already done, so it is
    safe to run again after a failure:

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

    .PARAMETER Name
    The VM to build. Created if it does not exist yet. May be left out while
    there is only one.

    .PARAMETER FromPhase
    Start at this phase, skipping the earlier ones. Mostly for picking up
    after fixing a problem in a later phase.

    .PARAMETER NoUnattend
    Do not give the VM an answer file: Windows Setup has to be completed by
    hand in VMConnect, and Phase 7 waits for that.

    .EXAMPLE
    Build-LazyVM -Name DevBox

    Builds DevBox, setting up everything it needs on first use.

    .EXAMPLE
    Build-LazyVM -Name DevBox -FromPhase 7

    Carries on with the installs after fixing what stopped them.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [ValidateRange(0, 8)]
        [int]$FromPhase = 0,

        [switch]$NoUnattend
    )

    process {
        Assert-Administrator
        try {
            Initialize-BuildTarget -Name $Name
            $null = Initialize-CommandRun -Title 'Build' -Name $Name

            $result = Invoke-VMBuild -FromPhase $FromPhase -NoUnattend:$NoUnattend
            if ($result -eq 'RestartPending') {
                Write-LogEntry 'The host is restarting to finish turning on Hyper-V. The build carries on by itself afterwards.' 'WARN'
                return
            }

            # The daily maintenance, so nothing has to be remembered. A problem
            # here is reported but does not undo a good build.
            try {
                Register-RebuildSchedule
            }
            catch {
                Write-LogEntry "The daily maintenance could not be scheduled: $($_.Exception.Message)" 'WARN'
                Write-LogEntry "  Schedule it with: Register-LazyVMMaintenance -Name $($CFG.VMName)" 'INFO'
            }

            Write-LogEntry '' 'INFO'
            Write-LogEntry '========================================================' 'INFO'
            Write-LogEntry "  All phases complete. $($CFG.VMName) is ready."          'OK'
            Write-LogEntry "  Log : $($CFG.LogFile)"                                 'INFO'
            Write-LogEntry '========================================================' 'INFO'
        }
        catch {
            if ($script:LogReady) { Write-LogError 'Build stopped' $_ }
            $PSCmdlet.ThrowTerminatingError($_)
        }
        finally {
            Complete-CommandRun
        }
    }
}
