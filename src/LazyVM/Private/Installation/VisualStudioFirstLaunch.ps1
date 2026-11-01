# VisualStudioFirstLaunch.ps1 - Visual Studio's first launch, answered during the build (#268).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# On a fresh build Visual Studio has never been opened, and devenv, asked to
# import settings, waits on its first-launch window (sign-in, theme) that no
# one answers (#262). Microsoft documents no switch, policy or registry value
# that skips it, so the build answers it with Windows UI Automation, in the
# guest user's desktop session (Data\Guest.VisualStudioFirstLaunch.ps1), and
# then imports the settings. When that does not work, nightly maintenance
# imports them once Visual Studio has been opened by hand (#266).

# The controls of Visual Studio's first-launch window that the build presses,
# in order, found by AutomationId, which does not change with the language.
# THESE ARE GUESSES until confirmed on a real VM: run the script in the guest
# by hand (docs\Guide.md, Visual Studio settings) to see the real ones, and
# change them here only.
$script:VisualStudioFirstLaunchControl = @(
    [pscustomobject]@{ Name = 'Skip and add accounts later'; AutomationId = 'SkipAndAddAccountsLater' }
    [pscustomobject]@{ Name = 'Start Visual Studio'; AutomationId = 'StartVisualStudio' }
)

function Complete-GuestVisualStudioFirstLaunch {
    <#
      Makes sure the Visual Studio $VisualStudio (Get-GuestVisualStudio) has
      been opened and closed once, so devenv can import settings without
      waiting on its first-launch window: when it has not, opens it in the
      signed-in guest user's desktop session, presses the controls in
      $script:VisualStudioFirstLaunchControl, and lets it close itself.
      The script gets $timeoutMinutes; on any mismatch it describes Visual
      Studio's windows in <GuestSetupDir>\VisualStudioFirstLaunch.txt and
      stops Visual Studio with everything it started. When the guest task
      does not finish, the Visual Studio it started is stopped by its process
      id (Stop-GuestVisualStudioFirstLaunch). Whether Visual Studio has been
      opened once decides the result, however the task ended; when it has
      not, logs why. Never throws: the build goes on, and nightly maintenance
      imports the settings later. A Visual Studio already running is left
      alone.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][object]$VisualStudio
    )

    $setupDir = $VM.Settings.GuestSetupDir
    $guestScript = Join-Path -Path $setupDir -ChildPath 'VisualStudioFirstLaunch.ps1'
    $treePath = Join-Path -Path $setupDir -ChildPath 'VisualStudioFirstLaunch.txt'
    $processIdPath = Join-Path -Path $setupDir -ChildPath 'VisualStudioFirstLaunch.pid'
    # The guest task gets a few minutes more than the script, so it is the
    # guest that stops Visual Studio and says why, not the host giving up.
    $timeoutMinutes = 10
    try {
        $state = Get-GuestVisualStudioSettingState -VM $VM -InstanceId $VisualStudio.InstanceId
        if ($state.OpenedOnce) { return $true }
        if ($state.DevenvRunning) {
            Write-LogEntry 'Visual Studio is running in the guest, so its first launch was not answered automatically' 'WARN'
            return $false
        }

        Write-LogEntry "Opening Visual Studio once to answer its first-launch window (up to $timeoutMinutes minutes)..." 'INFO'
        Copy-ToGuest -VM $VM -HostPath (Join-Path -Path $script:DataDir -ChildPath 'Guest.VisualStudioFirstLaunch.ps1') -GuestPath $guestScript
        $guestError = $null
        try {
            Invoke-GuestScriptAsInteractiveUser -VM $VM -TaskName "${script:TaskPrefix}VSFirstLaunch" -Activity "Visual Studio's first launch" -TimeoutMinutes ($timeoutMinutes + 3) `
                -ArgumentList @($guestScript, $treePath, $processIdPath, $VisualStudio.DevEnvPath, $script:VisualStudioFirstLaunchControl, $timeoutMinutes) -ScriptBlock {
                param($scriptPath, $treePath, $processIdPath, $devenv, $control, $timeoutMinutes)
                & $scriptPath -TreePath $treePath -ProcessIdPath $processIdPath -DevenvPath $devenv -Control $control -TimeoutMinutes $timeoutMinutes
            }
        }
        catch {
            $guestError = $_.Exception.Message
            try { Stop-GuestVisualStudioFirstLaunch -VM $VM -ProcessIdPath $processIdPath }
            catch { Write-LogEntry "  Could not stop the Visual Studio its first launch started: $($_.Exception.Message)" 'WARN' }
        }

        if ((Get-GuestVisualStudioSettingState -VM $VM -InstanceId $VisualStudio.InstanceId).OpenedOnce) {
            Write-LogEntry "Visual Studio's first launch answered" 'OK'
            return $true
        }
        $why = if ($guestError) { $guestError } else { 'Visual Studio closed without saving its automatic settings backup, which the settings import waits for' }
        Write-LogEntry "Visual Studio's first launch could not be answered automatically: $why" 'WARN'
        return $false
    }
    catch {
        Write-LogEntry "Visual Studio's first launch could not be answered automatically: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Stop-GuestVisualStudioFirstLaunch {
    <#
      Stops, with everything it started, the devenv the first-launch script
      recorded in $ProcessIdPath, for when its guest task did not finish and
      so could not stop it itself. By process id only, and only while that
      process is devenv, so a Visual Studio someone opened is never touched.
      The script removes the file once it has stopped devenv itself.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$ProcessIdPath
    )

    $null = Invoke-GuestScript -VM $VM -Activity 'stopping the Visual Studio of its first launch' -TimeoutMinutes 2 -ArgumentList @($ProcessIdPath) -ScriptBlock {
        param($processIdPath)
        if (-not (Test-Path -LiteralPath $processIdPath)) { return }
        $processId = [int](@(Get-Content -LiteralPath $processIdPath)[0])
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($process -and $process.ProcessName -eq 'devenv') { $null = taskkill.exe /PID $processId /T /F }
        Remove-Item -LiteralPath $processIdPath -Force -ErrorAction SilentlyContinue
    }
}
