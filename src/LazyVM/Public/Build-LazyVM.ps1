function Build-LazyVM {
    <#
    .SYNOPSIS
    Builds a VM, unattended. One command does everything.

    .DESCRIPTION
    Build-LazyVM -Name DevBox is all it takes. On first use it also:

      - chooses the LazyVM folder, if none has been: <drive>:\LazyVM on the
        local drive with the most free space (Set-LazyVMRoot chooses another)
      - creates the VM's profile, if it has none (New-LazyVM is optional),
        from -ConfigTemplate when given
      - finds the Windows ISO, including in your Downloads folder, and moves
        it into the LazyVM folder; with no ISO anywhere it opens the download
        page and stops, so you download it and run the same command again
      - creates the administrator account inside the VM
      - schedules the daily maintenance, once every phase has run

    The build runs these phases, skipping whatever is already done, so it is
    safe to run again after a failure:

      0  Hyper-V service health check
      1  CPU, firmware, memory and disk space readiness
      2  Hyper-V turned on if needed. The host restarts and the build carries
         on by itself afterwards.
      3  The folders under the LazyVM folder
      4  The Windows ISO checked and the SQL Server ISO downloaded
      5  The SQL data disk, the Dev Drive and the User disk (never
         overwritten)
      6  The VM: Generation 2, Secure Boot, TPM, dynamic memory, with an
         answer-file disc so Windows installs without any input
      7  Windows; the disks attached and prepared, BitLocker, Windows
         appearance and Sysmon; then everything in the VM's tooling list:
         Visual Studio and SSMS with their workloads and extensions, SQL
         Server, winget packages and official installers; then Windows
         updates
      8  SQL data moved to the data disk, Visual Studio's first launch
         answered and its settings restored

    Progress is shown as it goes and written to the VM's log. With -WhatIf,
    says what would be built and changes nothing, not even the first-use
    set-up.

    .PARAMETER Name
    The VM to build. Created if it does not exist yet. May be left out while
    there is only one.

    .PARAMETER ConfigTemplate
    The config template a new VM's profile is created from, such as
    PlainWindows. Press Tab to list them. Used only when the VM has no
    profile yet: an existing VM's VM.json decides how it is built.

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
    Build-LazyVM -Name Clean -ConfigTemplate PlainWindows

    Builds a new VM with plain Windows and no developer tools.

    .EXAMPLE
    Build-LazyVM -Name DevBox -FromPhase 7

    Carries on with the installs after fixing what stopped them.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [string]$ConfigTemplate,

        [ValidateScript({ Test-BuildPhaseNumber -Number $_ }, ErrorMessage = "There is no build phase {0}. Get-Help Build-LazyVM lists the phases.")]
        [int]$FromPhase = 0,

        [switch]$NoUnattend
    )

    process {
        # Before anything, even the first-use set-up: with -WhatIf nothing is created or moved.
        $target = if ($Name) { $Name } else { 'the VM' }
        $setup = if ($NoUnattend) { ', with Windows Setup completed by hand' } else { '' }
        $vmProfile = if ($ConfigTemplate) { "profile (from the config template '$ConfigTemplate')" } else { 'profile' }
        if (-not $PSCmdlet.ShouldProcess($target, "Build from phase $FromPhase$setup, first setting up the LazyVM folder, $vmProfile and Windows ISO if they are missing")) { return }
        Initialize-BuildTarget -Name $Name -ConfigTemplate $ConfigTemplate
        Invoke-CommandRun -Title 'Build' -Name $Name -FailureMessage 'Build stopped' -Cmdlet $PSCmdlet -ScriptBlock {
            param($VM)
            Sync-VMProfile -VM $VM
            $outcome = Invoke-VMBuild -VM $VM -FromPhase $FromPhase -NoUnattend:$NoUnattend
            if ($outcome -eq [BuildOutcome]::RestartPending) {
                Write-LogEntry 'The host is restarting to finish turning on Hyper-V. The build carries on by itself afterwards.' 'WARN'
                return
            }

            # The daily maintenance, so nothing has to be remembered. A problem
            # here is reported but does not undo a good build.
            try {
                Register-RebuildSchedule -VM $VM
            }
            catch {
                Write-LogEntry "The daily maintenance could not be scheduled: $($_.Exception.Message)" 'WARN'
                Write-LogEntry "  Schedule it with: Register-LazyVMMaintenance -Name $($VM.Name)" 'INFO'
            }

            Write-LogEntry '' 'INFO'
            Write-LogEntry '========================================================' 'INFO'
            if ($outcome -eq [BuildOutcome]::CompleteWithProblems) {
                Write-LogEntry "  All phases ran, but some steps failed. $($VM.Name) can be used; fix what the log reports" 'WARN'
                Write-LogEntry '  (install by hand, or re-run the phase it names with -FromPhase).' 'WARN'
            }
            else {
                Write-LogEntry "  All phases complete. $($VM.Name) is ready." 'OK'
            }
            Write-LogEntry "  Log : $($VM.Settings.LogFile)" 'INFO'
            Write-LogEntry '========================================================' 'INFO'
        }
    }
}
