# BuildPhases.ps1 - The build, as a list of phases run in order.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# A build and a rebuild run the same phases; a rebuild starts at phase 3,
# after retiring the old VM. A phase is added by adding it to the list.

function Get-BuildPhase {
    <#
      Every build phase, in order. Each Action takes the VM and a table, $Run,
      holding -NoUnattend and phase 6's UseUnattend, which phase 7 reads. An
      Action that returns RestartPending stops the build for a host restart.
    #>
    return @(
        [pscustomobject]@{ Number = 0; Name = 'Hyper-V Service Health Check'; Action = {
                if (Repair-HyperVService) {
                    Write-LogEntry 'Hyper-V looks missing or broken; Phase 2 turns it on' 'WARN'
                }
            }
        }
        [pscustomobject]@{ Number = 1; Name = 'CPU, Firmware and Capacity Readiness'; Action = { param($VM) Test-HostReadiness -VM $VM } }
        [pscustomobject]@{ Number = 2; Name = 'Hyper-V Feature Installation'; Action = {
                param($VM)
                if (Enable-HyperVFeature -VM $VM) { return [BuildOutcome]::RestartPending }
            }
        }
        [pscustomobject]@{ Number = 3; Name = 'Folder Structure'; Action = { param($VM) Initialize-HostFolder -VM $VM } }
        [pscustomobject]@{ Number = 4; Name = 'SQL Server Media'; Action = { param($VM) Initialize-SqlServerIso -VM $VM } }
        [pscustomobject]@{ Number = 5; Name = 'SQL Data Disk, Dev Drive and User Disk'; Action = {
                param($VM)
                Initialize-SqlDataVhd -VM $VM
                Initialize-DevDriveVhd -VM $VM
                Initialize-UserDataVhd -VM $VM
            }
        }
        [pscustomobject]@{ Number = 6; Name = 'VM Build'; Action = {
                param($VM, $Run)
                # The answer-file disc is only worth building for a VM that
                # does not exist yet.
                $Run.UseUnattend = $false
                if ($Run.NoUnattend) {
                    Write-LogEntry '-NoUnattend: Windows Setup and OOBE will have to be completed by hand' 'WARN'
                }
                elseif (Get-VM -Name $VM.Name -ErrorAction SilentlyContinue) {
                    Write-LogEntry 'VM already exists - not rebuilding the answer-file disc' 'INFO'
                }
                else {
                    New-UnattendSeedDisk -VM $VM -GuestCredential (Initialize-GuestCredential -VM $VM)
                    $Run.UseUnattend = $true
                }
                New-GuestVM -VM $VM -UseUnattend:$Run.UseUnattend
            }
        }
        [pscustomobject]@{ Number = 7; Name = 'Guest Provisioning and Silent Installs'; Action = {
                param($VM, $Run)
                Install-GuestSoftware -VM $VM -UsedUnattend:([bool]$Run.UseUnattend -or (Test-SeedDiskAttached -VM $VM))
            }
        }
        [pscustomobject]@{ Number = 8; Name = 'Post-Configuration'; Action = { param($VM) Complete-GuestConfiguration -VM $VM } }
    )
}

function Test-BuildPhaseNumber {
    <# True for a phase that exists, for -FromPhase. #>
    param([int]$Number)

    return $Number -in @(Get-BuildPhase | ForEach-Object { $_.Number })
}

function Invoke-BuildPhase {
    <#
      Runs the phases from $FromPhase on. The Windows ISO is found first,
      before anything changes on the host, while whoever started the run is
      still there to fetch it; a host restart would hand it to the resume
      task, which runs as SYSTEM and can only log it. Returns a BuildOutcome:
      CompleteWithProblems when a phase returned it, because a step in it
      failed and the phase carried on.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [int]$FromPhase = 0,
        [switch]$NoUnattend
    )

    Initialize-InstallationIso -VM $VM

    $run = @{ NoUnattend = [bool]$NoUnattend; UseUnattend = $false }
    $withProblems = [System.Collections.Generic.List[int]]::new()
    foreach ($phase in @(Get-BuildPhase | Where-Object { $_.Number -ge $FromPhase })) {
        Write-LogEntry "PHASE $($phase.Number) - $($phase.Name)" 'PHASE'
        $outcome = @(& $phase.Action $VM $run) | Where-Object { $_ -is [BuildOutcome] } | Select-Object -Last 1
        if ($outcome -eq [BuildOutcome]::RestartPending) { return [BuildOutcome]::RestartPending }
        if ($outcome -eq [BuildOutcome]::CompleteWithProblems) {
            $withProblems.Add($phase.Number)
            Write-LogEntry "Phase $($phase.Number) finished with problems - see the errors above" 'WARN'
        }
        else {
            Write-LogEntry "Phase $($phase.Number) complete" 'OK'
        }
    }
    if ($withProblems.Count -gt 0) {
        Write-LogEntry "Phases with problems: $($withProblems -join ', ') - re-run with -FromPhase $($withProblems[0]) once the cause is fixed" 'WARN'
        return [BuildOutcome]::CompleteWithProblems
    }
    return [BuildOutcome]::Complete
}

function Invoke-VMBuild {
    <#
      Runs the build from $FromPhase or the resume point left before a host
      restart, whichever is later. The resume point is cleared only once the
      build completes, so a crash while resuming keeps it.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [int]$FromPhase = 0,
        [switch]$NoUnattend
    )

    $resumePhase = Get-ResumePhase -VM $VM
    if ($resumePhase -gt 0) { Write-LogEntry "Resuming after reboot from Phase $resumePhase" 'INFO' }
    $startPhase = [math]::Max($FromPhase, $resumePhase)
    if ($startPhase -gt 0) { Write-LogEntry "Starting at Phase $startPhase" 'INFO' }

    $outcome = Invoke-BuildPhase -VM $VM -FromPhase $startPhase -NoUnattend:$NoUnattend
    if ($outcome -ne [BuildOutcome]::RestartPending) { Unregister-ResumeTask -VM $VM }
    return $outcome
}
