# Rebuild.ps1 - Rebuild orchestration, retiring the old VM, verifying the new one.
# Dot-sourced by Massokissed.LazyVM.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  REBUILD ORCHESTRATION
#
#  capture -> shut down -> retire the old disk by RENAME -> build -> install ->
#  configure -> restore -> verify -> only then delete the retired disk.
#
#  The old OS VHDX is never deleted until the new guest has been verified
#  against the capture manifest, so a failed rebuild is recoverable. The SQL
#  data disk is never touched: it carries the database backups across.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-Rebuild {
    param(
        [switch]$SkipCapture,
        [switch]$NoUnattend
    )

    Write-LogEntry 'REBUILD - Capture, Rebuild, Restore' 'PHASE'
    $started = Get-Date

    if (-not (Test-HyperVModule)) {
        Stop-WithError 'The Hyper-V PowerShell module is not available.'
    }

    # ── 1. capture ──────────────────────────────────────────────────────────
    $manifest = $null
    if ($SkipCapture) {
        Write-LogEntry 'Skipping capture (-SkipCapture): using the existing manifest' 'WARN'
        $manifest = Get-CaptureManifest
        if (-not $manifest) { Stop-WithError "No existing capture manifest, and -SkipCapture was given. Capture first with: Save-LazyVMState -Name $($CFG.VMName)" }
    }
    elseif (Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue) {
        $manifest = Save-GuestState
    }
    else {
        Write-LogEntry 'No existing VM - this is a first build rather than a rebuild' 'INFO'
    }

    $expectedDatabases = @()
    if ($manifest -and $manifest.Databases) { $expectedDatabases = @($manifest.Databases) }

    # ── 2. retire the old VM ────────────────────────────────────────────────
    $retired = $null
    if (Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue) {
        $retired = Invoke-RetireCurrentVM
    }

    # ── 3. rebuild ──────────────────────────────────────────────────────────
    $rebuildOk = $false
    try {
        Initialize-HostFolder
        Confirm-InstallMedia
        Initialize-SqlDataVhd
        Initialize-DevDriveVhd

        $useUnattend = $false
        if (-not $NoUnattend) {
            $guestCredential = Get-GuestCredential -CreateIfMissing
            New-UnattendSeedDisk -GuestCredential $guestCredential
            $useUnattend = $true
        }
        New-GuestVM -UseUnattend:$useUnattend

        $seedAttached = @(Get-VMDvdDrive -VMName $CFG.VMName -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -eq $CFG.SeedDiskPath }).Count -gt 0
        Install-GuestSoftware -UsedUnattend:($useUnattend -or $seedAttached)
        Complete-GuestConfiguration

        if ($manifest) { Restore-GuestState | Out-Null }

        $rebuildOk = $true
    }
    catch {
        Write-LogError 'Rebuild failed' $_
    }

    # ── 4. verify ───────────────────────────────────────────────────────────
    $verification = $null
    if ($rebuildOk) {
        try { $verification = Test-RebuiltVM -ExpectedDatabases $expectedDatabases }
        catch {
            Write-LogError 'Verification failed' $_
            $verification = [pscustomobject]@{ Passed = $false; Checks = @(); Failures = @("verification threw: $($_.Exception.Message)") }
        }
    }

    # ── 5. dispose of, or keep, the retired disk ────────────────────────────
    $elapsed = [int]((Get-Date) - $started).TotalMinutes

    if ($rebuildOk -and $verification -and $verification.Passed) {
        Write-LogEntry "Rebuild verified in $elapsed minutes" 'OK'
        if ($retired) { Remove-RetiredVM -Retired $retired }
        return $true
    }

    Write-LogEntry "Rebuild did NOT complete cleanly (after $elapsed minutes)" 'ERROR'
    if ($verification) {
        foreach ($failure in @($verification.Failures)) { Write-LogEntry "  $failure" 'ERROR' }
    }
    if ($retired) {
        Write-LogEntry '' 'INFO'
        Write-LogEntry 'The previous VM has been KEPT. To roll back:' 'WARN'
        Write-LogEntry "  Stop-VM -Name '$($CFG.VMName)' -TurnOff -Force -ErrorAction SilentlyContinue" 'INFO'
        Write-LogEntry "  Remove-VM -Name '$($CFG.VMName)' -Force" 'INFO'
        Write-LogEntry "  Remove-Item '$($retired.NewOsPath)' -Force" 'INFO'
        Write-LogEntry "  Rename-Item '$($retired.RetiredOsPath)' '$([IO.Path]::GetFileName($retired.NewOsPath))'" 'INFO'
        Write-LogEntry "  Build-LazyVM -Name '$($CFG.VMName)' -FromPhase 6" 'INFO'
        Write-LogEntry '' 'INFO'
        Write-LogEntry "Retired OS disk: $($retired.RetiredOsPath)" 'WARN'
    }
    return $false
}

function Invoke-RetireCurrentVM {
    <# Shuts the guest down and moves its OS disk aside under a dated name.
       Nothing is deleted here. #>

    Write-LogEntry 'Retiring the current VM...' 'INFO'
    Stop-GuestGracefully

    $null = Get-VM -Name $CFG.VMName -ErrorAction Stop   # fail fast if it vanished
    $osDrive = @(Get-VMHardDiskDrive -VMName $CFG.VMName |
            Where-Object { $_.ControllerLocation -eq 0 -and $_.ControllerNumber -eq 0 }) |
        Select-Object -First 1
    if (-not $osDrive) {
        $osDrive = @(Get-VMHardDiskDrive -VMName $CFG.VMName |
                Where-Object {
                    $_.Path -ne $CFG.SQLDiskPath -and
                    $_.Path -ne $CFG.DevDrivePath
                }) |
            Select-Object -First 1
    }
    if (-not $osDrive) { Stop-WithError 'Could not identify the OS disk on the existing VM.' }

    $osPath = $osDrive.Path
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $retiredPath = Join-Path (Split-Path $osPath -Parent) ("{0}.retired-{1}.vhdx" -f [IO.Path]::GetFileNameWithoutExtension($osPath), $stamp)

    # Any checkpoint holds the VHDX open and turns it into a differencing
    # chain, which would make the rename meaningless.
    $checkpoints = @(Get-VMSnapshot -VMName $CFG.VMName -ErrorAction SilentlyContinue)
    if ($checkpoints.Count -gt 0) {
        Write-LogEntry "Removing $($checkpoints.Count) checkpoint(s) before retiring the disk..." 'WARN'
        Remove-VMSnapshot -VMName $CFG.VMName -IncludeAllChildSnapshots -Confirm:$false
        $deadline = (Get-Date).AddMinutes(30)
        while ((Get-Date) -lt $deadline -and @(Get-VMSnapshot -VMName $CFG.VMName -ErrorAction SilentlyContinue).Count -gt 0) {
            Start-Sleep -Seconds 10
        }
    }

    Remove-VM -Name $CFG.VMName -Force
    Write-LogEntry "VM definition '$($CFG.VMName)' removed (disks kept)" 'OK'

    Move-Item -LiteralPath $osPath -Destination $retiredPath -Force
    Write-LogEntry "OS disk retired to $([IO.Path]::GetFileName($retiredPath)) ($(Format-Size (Get-Item $retiredPath).Length))" 'OK'

    # The VM's own config folder would otherwise collide with the new build.
    $configDir = Join-Path $CFG.VHDXRoot $CFG.VMName
    if (Test-Path -LiteralPath $configDir) {
        $retiredConfig = "$configDir.retired-$stamp"
        try {
            Move-Item -LiteralPath $configDir -Destination $retiredConfig -Force
            Write-LogEntry 'VM configuration folder moved aside' 'OK'
        }
        catch {
            Write-LogEntry "Could not move the VM config folder: $($_.Exception.Message)" 'WARN'
            $retiredConfig = $null
        }
    }
    else { $retiredConfig = $null }

    # The answer-file disc is rebuilt from scratch every time.
    if (Test-Path -LiteralPath $CFG.SeedDiskPath) {
        Remove-Item -LiteralPath $CFG.SeedDiskPath -Force -ErrorAction SilentlyContinue
    }

    Write-LogEntry "SQL data disk left untouched: $($CFG.SQLDiskPath)" 'INFO'
    if ($CFG.UseDevDrive -and (Test-Path -LiteralPath $CFG.DevDrivePath)) {
        Write-LogEntry "Dev Drive left untouched: $($CFG.DevDrivePath)" 'INFO'
    }

    return [pscustomobject]@{
        RetiredOsPath  = $retiredPath
        NewOsPath      = $osPath
        RetiredConfig  = $retiredConfig
        Stamp          = $stamp
    }
}

function Remove-RetiredVM {
    param([Parameter(Mandatory)]$Retired)

    if (-not $CFG.DeleteRetiredDiskOnSuccess) {
        Write-LogEntry "Keeping the retired disk as configured: $($Retired.RetiredOsPath)" 'INFO'
        Write-LogEntry '  Delete it by hand once you are happy with the new VM.' 'INFO'
        return
    }

    $freed = 0
    foreach ($path in @($Retired.RetiredOsPath)) {
        if (Test-Path -LiteralPath $path) {
            $freed += (Get-Item -LiteralPath $path).Length
            Remove-Item -LiteralPath $path -Force
        }
    }
    if ($Retired.RetiredConfig -and (Test-Path -LiteralPath $Retired.RetiredConfig)) {
        Remove-Item -LiteralPath $Retired.RetiredConfig -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-LogEntry "Retired VM deleted - $(Format-Size $freed) reclaimed" 'OK'
}

function Test-RebuiltVM {
    <# Verifies the new guest against what the capture said should be there.
       This is the gate that decides whether the old disk can be deleted. #>
    param([string[]]$ExpectedDatabases = @())

    Write-LogEntry 'Verifying the rebuilt VM...' 'INFO'

    # Filled by Add-Check which, being nested, adds to this function's list.
    $checks = [System.Collections.Generic.List[object]]::new()

    function Add-Check {
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][bool]$Passed,
            [string]$Detail
        )
        $checks.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Detail = $Detail })
        if ($Passed) { Write-LogEntry "  PASS  $Name - $Detail" 'OK' }
        else { Write-LogEntry "  FAIL  $Name - $Detail" 'ERROR' }
    }

    $vm = Get-VM -Name $CFG.VMName -ErrorAction SilentlyContinue
    Add-Check -Name 'VM exists' -Passed ($null -ne $vm) -Detail $(if ($vm) { "state $($vm.State)" } else { 'not found' })
    if (-not $vm) {
        return [pscustomobject]@{ Passed = $false; Checks = @($checks); Failures = @('VM does not exist') }
    }

    Add-Check -Name 'VM running' -Passed ($vm.State -eq 'Running') -Detail "state $($vm.State)"

    $credential = Get-GuestCredential
    $reachable = $false
    $reachError = ''
    try {
        Connect-Guest -Credential $credential -TimeoutMinutes 10 | Out-Null
        $reachable = $true
    }
    catch {
        # Recorded rather than thrown: an unreachable guest is itself the
        # verification result, and the remaining checks still get reported.
        $reachError = $_.Exception.Message
    }
    Add-Check -Name 'guest reachable' -Passed $reachable -Detail $(if ($reachable) { 'PowerShell Direct' } else { $reachError })

    if ($reachable) {
        # Every Visual Studio Installer product in the VM's tooling list.
        $installedProducts = @(Get-GuestInstallerProduct)
        foreach ($product in @((Get-BuildTooling -Quiet).Products)) {
            $found = @($installedProducts | Where-Object { $_.ProductId -eq $product.ProductId -and $_.ChannelId -eq $product.ChannelId }).Count -gt 0
            Add-Check -Name "$($product.DisplayName) installed" -Passed $found -Detail $(if ($found) { $product.ChannelId } else { 'not found' })
        }

        $sql = Get-GuestSqlInstance
        Add-Check -Name 'SQL Server installed' -Passed ($null -ne $sql) -Detail $(if ($sql) { "$($sql.Instance) ($($sql.Edition))" } else { 'not found' })

        if ($sql -and $ExpectedDatabases.Count -gt 0) {
            $present = Invoke-GuestScript -Activity 'database verification' -TimeoutMinutes 10 `
                -ArgumentList @((Get-GuestSqlServer)) -ScriptBlock {
                param($server)
                $cs = "Server=$server;Database=master;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=30"
                $conn = New-Object System.Data.SqlClient.SqlConnection($cs)
                $conn.Open()
                try {
                    $cmd = $conn.CreateCommand()
                    $cmd.CommandText = "SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE'"
                    $r = $cmd.ExecuteReader(); $names = @()
                    try { while ($r.Read()) { $names += "$($r['name'])" } } finally { $r.Close() }
                    return $names
                }
                finally { $conn.Close() }
            }
            $present = @($present)
            $missing = @($ExpectedDatabases | Where-Object { $present -notcontains $_ })
            Add-Check -Name 'databases restored' -Passed ($missing.Count -eq 0) `
                -Detail $(if ($missing.Count -eq 0) { "$($present.Count) online: $($present -join ', ')" } else { "missing: $($missing -join ', ')" })
        }

        if ($CFG.UseDevDrive) {
            $devOk = $false
            $devDetail = 'not found'
            try {
                $dev = Invoke-GuestScript -Activity 'Dev Drive verification' -TimeoutMinutes 5 `
                    -ArgumentList @($CFG.DevDriveLabel) -ScriptBlock {
                    param($label)
                    $vol = @(Get-Volume -ErrorAction SilentlyContinue |
                            Where-Object { $_.FileSystemLabel -eq $label -and $_.DriveLetter })
                    if ($vol.Count -eq 0) { return $null }
                    $letter = "$($vol[0].DriveLetter)"
                    $query = & fsutil devdrv query "${letter}:" 2>&1
                    return [pscustomobject]@{
                        Letter  = $letter
                        Fs      = "$($vol[0].FileSystem)"
                        Trusted = (($query -join ' ') -match '(?i)trusted developer volume')
                    }
                }
                if ($dev) {
                    $devOk = $true
                    $devDetail = "$($dev.Letter): $($dev.Fs)" + $(if ($dev.Trusted) { ' (trusted)' } else { ' (NOT trusted)' })
                }
            }
            catch { $devDetail = $_.Exception.Message }
            Add-Check -Name 'Dev Drive mounted' -Passed $devOk -Detail $devDetail
        }

        $diskOk = $false
        $diskDetail = $CFG.GuestSqlDataDir
        try {
            $diskOk = Invoke-GuestScript -Activity 'data disk verification' -TimeoutMinutes 5 `
                -ArgumentList @($CFG.GuestSqlDataDir) -ScriptBlock { param($dir) Test-Path $dir }
        }
        catch {
            $diskDetail = "$($CFG.GuestSqlDataDir) - $($_.Exception.Message)"
        }
        Add-Check -Name 'SQL data disk mounted' -Passed ([bool]$diskOk) -Detail $diskDetail
    }

    $failures = @($checks | Where-Object { -not $_.Passed } | ForEach-Object { "$($_.Name): $($_.Detail)" })
    $passed = ($failures.Count -eq 0)

    Write-LogEntry "Verification: $(@($checks | Where-Object Passed).Count)/$($checks.Count) checks passed" $(if ($passed) { 'OK' } else { 'ERROR' })
    return [pscustomobject]@{ Passed = $passed; Checks = @($checks); Failures = $failures }
}
