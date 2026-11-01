# VisualStudioSetting.ps1 - Applying the Visual Studio settings nightly until they are applied (#266).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# A build applies the captured settings in step 8c, but on a fresh build
# Visual Studio has never been opened: devenv waits on its first-launch
# dialog and the import fails (#262). The guest then records the settings
# as pending, and every night this applies them once it safely can.
#
# "Opened once" is read from the automatic settings backup Visual Studio
# saves each time it closes, in %LOCALAPPDATA%\Microsoft\VisualStudio\
# <version>_<instance id>\Settings (Get-GuestVisualStudioSettingsFile).
# The instance folder and its privateregistry.bin are not enough: the
# devenv that 8c started and stopped at the first-launch dialog leaves them.
# https://learn.microsoft.com/visualstudio/ide/personalizing-the-visual-studio-ide#export-settings
# https://learn.microsoft.com/visualstudio/ide/synchronized-settings-in-visual-studio#side-by-side-synchronized-settings

function Get-GuestVisualStudioSettingState {
    <#
      What the guest has of the settings of the Visual Studio with instance
      $InstanceId, as @{ Marker; OpenedOnce; DevenvRunning }: what it records
      of them (Get-GuestVisualStudioSettingMarker), whether Visual Studio has
      been opened and closed at least once, and whether it is running now.
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$InstanceId
    )

    return Invoke-GuestScript -VM $VM -Activity 'checking the Visual Studio settings' -TimeoutMinutes 2 -ArgumentList @($InstanceId) -ScriptBlock {
        param($instanceId)
        [pscustomobject]@{
            Marker        = Get-GuestVisualStudioSettingMarker -InstanceId $instanceId
            OpenedOnce    = [bool](Get-GuestVisualStudioSettingsFile -InstanceId $instanceId)
            DevenvRunning = @(Get-Process -Name devenv -ErrorAction SilentlyContinue).Count -gt 0
        }
    }
}

function Update-GuestVisualStudioSetting {
    <#
      Applies the Visual Studio settings (Restore-GuestVisualStudioSetting)
      while the guest is still to have them applied: after a build or
      restore that could not apply them, or when the settings backup has
      settings the guest has not had. It waits, and says why, until Visual
      Studio has been opened once, its user is signed in, and Visual Studio
      is closed, so an IDE someone has open is never touched. A guest that
      records nothing about them, a VM from before #266, has them recorded
      as applied, without applying them again.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not $VM.Settings.InstallVisualStudio) {
        Write-LogEntry 'Visual Studio settings: Visual Studio turned off in the settings (InstallVisualStudio) - skipping' 'INFO'
        return
    }
    $settings = Get-VisualStudioSettingToApply -VM $VM
    if (-not $settings) {
        Write-LogEntry 'Visual Studio settings: no settings backup to apply' 'INFO'
        return
    }
    $vs = Get-GuestVisualStudio -VM $VM
    if (-not $vs) {
        Write-LogEntry 'Visual Studio settings: Visual Studio is not installed in the guest' 'INFO'
        return
    }

    $state = Get-GuestVisualStudioSettingState -VM $VM -InstanceId $vs.InstanceId
    if (-not $state.Marker) {
        Write-VisualStudioSettingMarker -VM $VM -InstanceId $vs.InstanceId -Value $settings.Hash
        Write-LogEntry 'Visual Studio settings: recorded as applied (this VM was built by an earlier LazyVM)' 'INFO'
        return
    }
    if (-not (Test-VisualStudioSettingPending -Marker $state.Marker -Hash $settings.Hash)) {
        Write-LogEntry 'Visual Studio settings: applied already' 'INFO'
        return
    }
    if (-not $state.OpenedOnce) {
        Write-LogEntry 'Visual Studio settings: waiting for Visual Studio''s first launch - they are applied the night after it has been opened and closed in the VM' 'INFO'
        return
    }
    $account = $VM.Runtime.GuestAdminUser
    if (@(Get-GuestSignedInUser -VM $VM) -notcontains $account) {
        Write-LogEntry "Visual Studio settings: '$account' is not signed in to the guest - tried again tomorrow" 'INFO'
        return
    }
    if ($state.DevenvRunning) {
        Write-LogEntry 'Visual Studio settings: Visual Studio is open - tried again tomorrow, so it is not disturbed' 'INFO'
        return
    }
    Write-LogEntry 'Visual Studio settings: applying the captured settings...' 'INFO'
    Restore-GuestVisualStudioSetting -VM $VM
}
