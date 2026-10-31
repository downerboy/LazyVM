# PostConfiguration.ps1 - Build phase 8: SQL data onto the data disk, Visual Studio settings.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function Complete-GuestConfiguration {
    <#
      Phase 8. Each step is isolated: one that fails is logged and the rest
      still run, and the phase returns CompleteWithProblems. Databases are
      not restored here: a rebuild and Restore-LazyVMState put them back with
      Restore-GuestSqlState (#225).
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $machine = Get-VM -Name $VM.Name -ErrorAction SilentlyContinue
    if (-not $machine) {
        Write-LogEntry "VM '$($VM.Name)' not found - skipping Phase 8" 'WARN'
        return
    }
    if ($machine.State -ne 'Running') {
        Write-LogEntry "VM is '$($machine.State)' - skipping Phase 8 (start the VM and re-run with -FromPhase 8)" 'WARN'
        return
    }
    Connect-Guest -VM $VM -Credential (Assert-GuestCredential -VM $VM) | Out-Null

    $run = Invoke-IsolatedStep -What 'Phase 8' -Steps @(
        # Run even when the disk was attached already: it is what finds the
        # data disk's actual letter, which the later steps need. A run from
        # phase 8 may find the disk still locked by BitLocker (#175).
        [pscustomobject]@{ Name = '8a - SQL data disk'; Action = { Add-SqlDataDisk -VM $VM; Unlock-GuestDataDisk -VM $VM; Initialize-GuestSqlDisk -VM $VM } }
        [pscustomobject]@{ Name = '8b - move SQL data files'; Action = { Move-GuestSqlDataFile -VM $VM } }
        [pscustomobject]@{ Name = '8c - Visual Studio settings'; Action = { Restore-GuestVisualStudioSetting -VM $VM } }
    )
    if ($run.Failures.Count -eq 0) { Write-LogEntry 'Phase 8 complete' 'OK' }
    else { return [BuildOutcome]::CompleteWithProblems }
}
