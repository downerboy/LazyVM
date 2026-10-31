# Winget.ps1 - Installing the winget packages in the VM's tooling list.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function Install-WingetPackage {
    <#
      Installs the packages the guest does not have yet. The caller has
      already waited for the guest network: PowerShell Direct works long
      before DNS does, and without that wait installs fail with 0x80072EE7.
      Each package is independent: one that fails is reported and the rest
      carry on, and nothing here stops the build.

      The installs run as a scheduled task in the guest (Invoke-GuestTask),
      so a dropped session does not lose them or their report, and a guest
      restart starts them again; packages already installed by then are
      skipped (#27). The task runs as the guest account under its full
      token, as the session did, so a per-user package still goes to that
      account. It runs outside the session, without Guest.Helpers.ps1, so
      winget is found first, and the report comes back as one line of JSON.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [AllowEmptyCollection()][object[]]$Packages = @()
    )

    $tools = @($Packages | Where-Object { $_ -and $_.Id } | ForEach-Object { @{ Id = "$($_.Id)"; Source = "$($_.Source)" } })
    if ($tools.Count -eq 0) { return }

    Write-LogEntry "Checking $($tools.Count) winget package(s) from the tooling list..." 'INFO'
    try {
        $winget = Invoke-GuestScript -VM $VM -Activity 'finding winget' -TimeoutMinutes 5 -ScriptBlock { Find-GuestWinget }
        if (-not $winget) {
            Write-LogEntry 'Skipped every winget package: winget is not available in the guest - install App Installer from the Microsoft Store' 'WARN'
            return
        }

        $report = Invoke-GuestTask -VM $VM -TaskName "${script:TaskPrefix}winget" -Activity 'winget packages' -TimeoutMinutes 60 `
            -AsGuestUser -Elevated -RestartAttempts 3 -ArgumentList @($winget, $tools) -Work {
            param($winget, $tools)
            $ErrorActionPreference = 'Continue'

            # A bare winget exit code says nothing. These are the ones that
            # actually come up, so the log explains itself.
            $exitMeanings = @{
                -2147012889 = 'DNS could not be resolved - the guest has no working internet'
                -2147012894 = 'the connection timed out - the guest network is slow or blocked'
                -2147012867 = 'could not connect to the server'
                -2147012721 = 'content decoding failed - check for a proxy intercepting HTTPS'
                -2147012739 = 'a secure channel error - check the date, time and certificates in the guest'
                -1978335189 = 'already installed and up to date'
                -1978335212 = 'no package matched that identifier'
                -1978335215 = 'no applicable installer for this system'
                -1978334972 = 'the installer hash did not match'
                -1978335216 = 'the source could not be updated'
                -1978335226 = 'the package''s own installer failed'
            }
            $alreadyInstalled = -1978335189
            # Worth one retry; everything else is a real failure.
            $transientCodes = @(-2147012889, -2147012894, -2147012867, -2147012716)

            $notes = @()
            foreach ($tool in @($tools)) {
                $id = "$($tool.Id)"
                $sourceArgs = @()
                if ("$($tool.Source)") { $sourceArgs = @('--source', "$($tool.Source)") }

                # Already present? winget list exits non-zero when nothing matches.
                $listed = & $winget list --id $id --exact --accept-source-agreements 2>&1
                if ($LASTEXITCODE -eq 0 -and ($listed -join ' ') -match [regex]::Escape($id)) {
                    $notes += [pscustomobject]@{ Level = 'INFO'; Text = "present: $id" }
                    continue
                }

                $exit = $null
                foreach ($attempt in 1, 2) {
                    # winget's own output is a progress table whose last line
                    # never explains a failure; the exit code below does.
                    & $winget install --id $id --exact --silent @sourceArgs `
                        --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
                    $exit = $LASTEXITCODE
                    if ($exit -eq 0 -or $transientCodes -notcontains $exit) { break }
                    if ($attempt -eq 1) {
                        $notes += [pscustomobject]@{ Level = 'INFO'; Text = "retrying $id after a network error" }
                        Start-Sleep -Seconds 20
                    }
                }

                if ($exit -eq 0) { $notes += [pscustomobject]@{ Level = 'OK'; Text = "installed: $id" } }
                elseif ($exit -eq $alreadyInstalled) { $notes += [pscustomobject]@{ Level = 'INFO'; Text = "present: $id" } }
                else {
                    $meaning = if ($exitMeanings.ContainsKey($exit)) { $exitMeanings[$exit] } else { 'see the winget documentation for this code' }
                    # An Int32 formats as its two's-complement hex, which is how winget documents its codes.
                    $notes += [pscustomobject]@{ Level = 'WARN'; Text = ('failed: {0} - exit {1} [0x{1:X8}] {2}' -f $id, [int]$exit, $meaning) }
                }
            }
            # The task's result is one line of text, so the report goes back as JSON.
            return (ConvertTo-Json -InputObject @($notes) -Compress)
        }
        Write-GuestNote -Notes @(ConvertFrom-Json -InputObject $report)
    }
    catch {
        Write-LogError 'winget package installation failed (non-fatal)' $_
    }
}
