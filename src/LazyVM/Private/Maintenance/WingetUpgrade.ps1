# WingetUpgrade.ps1 - Upgrading the guest's winget packages nightly (#235).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Everything winget can upgrade from its own source, as winget upgrade --all
# would, except Visual Studio and SQL Server ($script:WingetUpgradeNever) and
# programs that are running. Packages pinned with winget pin are left alone:
# winget leaves them out of what it lists. Upgrades change versions, not
# which packages are installed, so the tooling list does not change; the
# Store's own apps are updated by the Store (#233).

function Test-WingetUpgradeAllowed {
    <# Whether the nightly upgrades may upgrade the winget package $Id. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Id)

    return -not @($script:WingetUpgradeNever | Where-Object { $Id -like $_ }).Count
}

function Get-GuestWingetUpgrade {
    <#
      The packages winget can upgrade from its own source, each as
      @{ Id; Name; Folders }: Folders are where Windows says the program is
      installed (Get-GuestProgramFolder), for telling whether it is running.
      Id is '' when winget cut it short in its table and it could not be
      completed. Read over the session, where the guest helpers are.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$Winget
    )

    return Invoke-GuestScript -VM $VM -Activity 'listing winget upgrades' -TimeoutMinutes 10 -ArgumentList @($Winget, $VM.Settings.GuestSetupDir) -ScriptBlock {
        param($winget, $setupDir)

        $lines = @(& $winget upgrade --source winget --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { "$_" })
        $rows = @(ConvertFrom-GuestWingetTable -Lines $lines)

        # winget export lists whole ids, to complete any the table cut short.
        $knownIds = @()
        if (@($rows | Where-Object { $_.Id.EndsWith([string][char]0x2026) }).Count -gt 0) {
            New-GuestFolder -Path $setupDir
            $exportFile = Join-Path $setupDir 'upgrade-winget.json'
            Remove-Item -LiteralPath $exportFile -Force -ErrorAction SilentlyContinue
            & $winget export --output $exportFile --source winget --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
            if (Test-Path -LiteralPath $exportFile) {
                $export = Get-Content -LiteralPath $exportFile -Raw | ConvertFrom-Json
                $knownIds = @(foreach ($source in @($export.Sources)) { foreach ($package in @($source.Packages)) { "$($package.PackageIdentifier)" } })
                Remove-Item -LiteralPath $exportFile -Force -ErrorAction SilentlyContinue
            }
        }

        foreach ($row in $rows) {
            [pscustomobject]@{
                Id      = Resolve-GuestWingetId -Id $row.Id -KnownId $knownIds
                Name    = $row.Name
                Folders = @(Get-GuestProgramFolder -Name $row.Name)
            }
        }
    }
}

function Update-GuestWingetPackage {
    <#
      Upgrades the guest's winget packages, leaving out Visual Studio and SQL
      Server, packages pinned with winget pin, and any program that is
      running when its turn comes, so nobody's open editor or tool is closed
      under them. A program whose folder Windows does not record is left
      out too: whether it is running cannot be told. Each is logged.

      The upgrades run as a guest task as the guest account under its full
      token, as the installs do (Install-WingetPackage), so per-user packages
      upgrade too. Such a task runs only while that account is signed in,
      which automatic sign-in sees to whenever the VM starts; when it is not,
      the upgrades wait for another night. Nothing here stops maintenance.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $winget = Invoke-GuestScript -VM $VM -Activity 'finding winget' -TimeoutMinutes 5 -ScriptBlock { Find-GuestWinget }
    if (-not $winget) {
        Write-LogEntry 'winget upgrades: skipped - winget is not available in the guest' 'WARN'
        return
    }
    $account = $VM.Runtime.GuestAdminUser
    if (@(Get-GuestSignedInUser -VM $VM) -notcontains $account) {
        Write-LogEntry "winget upgrades: skipped tonight - they run as '$account', who is not signed in to the guest" 'INFO'
        return
    }

    $packages = [System.Collections.Generic.List[object]]::new()
    foreach ($upgrade in @(Get-GuestWingetUpgrade -VM $VM -Winget "$winget")) {
        if (-not $upgrade.Id) {
            Write-LogEntry "winget upgrades: skipped $($upgrade.Name) - winget cut its id short and it could not be completed" 'INFO'
        }
        elseif (-not (Test-WingetUpgradeAllowed -Id $upgrade.Id)) {
            Write-LogEntry "winget upgrades: left $($upgrade.Id) to its own installer" 'INFO'
        }
        elseif (@($upgrade.Folders).Count -eq 0) {
            Write-LogEntry "winget upgrades: skipped $($upgrade.Id) - Windows does not record where it is installed, so whether it is running cannot be told" 'INFO'
        }
        else {
            $packages.Add(@{ Id = "$($upgrade.Id)"; Folders = @($upgrade.Folders | ForEach-Object { "$_" }) })
        }
    }
    if ($packages.Count -eq 0) {
        Write-LogEntry 'winget upgrades: everything winget may upgrade is up to date' 'OK'
        return
    }

    Write-LogEntry "winget upgrades: upgrading $($packages.Count) package(s)..." 'INFO'
    $report = Invoke-GuestTask -VM $VM -TaskName "${script:TaskPrefix}winget-upgrade" -Activity 'winget upgrades' -TimeoutMinutes 60 `
        -AsGuestUser -Elevated -RestartAttempts 1 -ArgumentList @("$winget", $packages.ToArray(), $script:WingetExitMeanings) -Work {
        # $exitMeanings is $script:WingetExitMeanings; after the trip as JSON, its keys are properties.
        param($winget, $packages, $exitMeanings)
        $ErrorActionPreference = 'Continue'
        $upToDate = -1978335189

        $notes = @()
        foreach ($package in @($packages)) {
            $id = "$($package.Id)"
            # Checked just before its turn, as a program may have been opened since the list was made.
            $running = @(Get-CimInstance -ClassName Win32_Process | Where-Object { $path = "$($_.ExecutablePath)"; $path -and @($package.Folders | Where-Object { $path -like "$_\*" }).Count -gt 0 })
            if ($running.Count -gt 0) {
                $notes += [pscustomobject]@{ Level = 'INFO'; Text = "skipped: $id - running ($(@($running | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', ')); tried again tomorrow" }
                continue
            }

            & $winget upgrade --id $id --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
            $exit = $LASTEXITCODE
            if ($exit -eq 0) { $notes += [pscustomobject]@{ Level = 'OK'; Text = "upgraded: $id" } }
            elseif ($exit -eq $upToDate) { $notes += [pscustomobject]@{ Level = 'INFO'; Text = "up to date: $id" } }
            else {
                $known = $exitMeanings.PSObject.Properties["$exit"]
                $meaning = if ($known) { $known.Value } else { 'see the winget documentation for this code' }
                # An Int32 formats as its two's-complement hex, which is how winget documents its codes.
                $notes += [pscustomobject]@{ Level = 'WARN'; Text = ('upgrade failed: {0} - exit {1} [0x{1:X8}] {2}' -f $id, [int]$exit, $meaning) }
            }
        }
        # The task's result is one line of text, so the report goes back as JSON.
        return (ConvertTo-Json -InputObject @($notes) -Compress)
    }
    Write-GuestNote -Notes @(ConvertFrom-Json -InputObject $report)
}
