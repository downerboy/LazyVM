# Verify.ps1 - Checking a rebuilt VM against what its capture said should be there.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# This is the gate that decides whether the retired OS disk may be deleted.

function New-VerificationCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [string]$Detail
    )

    return [pscustomobject]@{ Name = $Name; Passed = $Passed; Detail = $Detail }
}

function Get-GuestVerificationCheck {
    <# The checks that need the guest: its products, SQL Server and databases, the Dev Drive and the data disk. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [AllowEmptyCollection()][string[]]$ExpectedDatabases = @()
    )

    $installed = @(Get-GuestInstallerProduct -VM $VM)
    foreach ($product in @((Get-BuildTooling -VM $VM -Quiet).Products)) {
        $found = @($installed | Where-Object { [ToolingProduct]::KeyFor($_.ProductId, $_.ChannelId) -eq $product.Key() }).Count -gt 0
        New-VerificationCheck -Name "$($product.DisplayName) installed" -Passed $found -Detail $(if ($found) { $product.ChannelId } else { 'not found' })
    }

    $sql = Connect-GuestSqlInstance -VM $VM
    New-VerificationCheck -Name 'SQL Server installed' -Passed ($null -ne $sql) -Detail $(if ($sql) { "$($sql.Instance) ($($sql.Edition))" } else { 'not found' })

    if ($sql -and $ExpectedDatabases.Count -gt 0) {
        $present = @(Invoke-GuestScript -VM $VM -Activity 'database verification' -TimeoutMinutes 10 -ArgumentList @($VM.Runtime.SqlServer) -ScriptBlock {
                param($server)
                $connection = Open-GuestSqlConnection -Server $server
                try { @(Get-GuestSqlRow -Connection $connection -Sql "SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE'" | ForEach-Object { "$($_.name)" }) }
                finally { $connection.Close() }
            })
        $missing = @($ExpectedDatabases | Where-Object { $present -notcontains $_ })
        New-VerificationCheck -Name 'databases restored' -Passed ($missing.Count -eq 0) `
            -Detail $(if ($missing.Count -eq 0) { "$($present.Count) online: $($present -join ', ')" } else { "missing: $($missing -join ', ')" })
    }

    if ($VM.Settings.UseDevDrive) {
        $dev = Invoke-GuestScript -VM $VM -Activity 'Dev Drive verification' -TimeoutMinutes 5 -ArgumentList @($VM.Settings.DevDriveLabel) -ScriptBlock {
            param($label)
            $volume = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq $label -and $_.DriveLetter })
            if ($volume.Count -eq 0) { return $null }
            $letter = "$($volume[0].DriveLetter)"
            return [pscustomobject]@{
                Letter  = $letter
                Fs      = "$($volume[0].FileSystem)"
                Trusted = ((& fsutil devdrv query "${letter}:" 2>&1) -join ' ') -match '(?i)trusted developer volume'
            }
        }
        $detail = if ($dev) { "$($dev.Letter): $($dev.Fs)" + $(if ($dev.Trusted) { ' (trusted)' } else { ' (NOT trusted)' }) } else { 'not found' }
        New-VerificationCheck -Name 'Dev Drive mounted' -Passed ([bool]$dev) -Detail $detail
    }

    $dataDir = $VM.Runtime.GuestSqlDataDir
    $diskOk = Invoke-GuestScript -VM $VM -Activity 'data disk verification' -TimeoutMinutes 5 -ArgumentList @($dataDir) -ScriptBlock { param($dir) Test-Path $dir }
    New-VerificationCheck -Name 'SQL data disk mounted' -Passed ([bool]$diskOk) -Detail $dataDir
}

function Test-RebuiltVM {
    <# Runs every check, logs each, and returns Passed, Checks and Failures. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [AllowEmptyCollection()][string[]]$ExpectedDatabases = @()
    )

    Write-LogEntry 'Verifying the rebuilt VM...' 'INFO'
    $checks = [System.Collections.Generic.List[object]]::new()

    $machine = Get-VM -Name $VM.Name -ErrorAction SilentlyContinue
    $checks.Add((New-VerificationCheck -Name 'VM exists' -Passed ($null -ne $machine) -Detail $(if ($machine) { "state $($machine.State)" } else { 'not found' })))
    if ($machine) {
        $checks.Add((New-VerificationCheck -Name 'VM running' -Passed ($machine.State -eq 'Running') -Detail "state $($machine.State)"))
        try {
            Connect-Guest -VM $VM -Credential (Assert-GuestCredential -VM $VM) -TimeoutMinutes 10 | Out-Null
            $checks.Add((New-VerificationCheck -Name 'guest reachable' -Passed $true -Detail 'PowerShell Direct'))
            try { foreach ($check in @(Get-GuestVerificationCheck -VM $VM -ExpectedDatabases $ExpectedDatabases)) { $checks.Add($check) } }
            catch { $checks.Add((New-VerificationCheck -Name 'guest checks' -Passed $false -Detail $_.Exception.Message)) }
        }
        catch {
            # An unreachable guest is itself the result; the other checks are reported as they stand.
            $checks.Add((New-VerificationCheck -Name 'guest reachable' -Passed $false -Detail $_.Exception.Message))
        }
    }

    foreach ($check in $checks) {
        if ($check.Passed) { Write-LogEntry "  PASS  $($check.Name) - $($check.Detail)" 'OK' }
        else { Write-LogEntry "  FAIL  $($check.Name) - $($check.Detail)" 'ERROR' }
    }
    $failures = @($checks | Where-Object { -not $_.Passed } | ForEach-Object { "$($_.Name): $($_.Detail)" })
    $passed = ($failures.Count -eq 0)
    Write-LogEntry "Verification: $(@($checks | Where-Object Passed).Count)/$($checks.Count) checks passed" $(if ($passed) { 'OK' } else { 'ERROR' })
    return [pscustomobject]@{ Passed = $passed; Checks = @($checks); Failures = $failures }
}
