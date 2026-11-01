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
      Applies the Visual Studio settings (Import-GuestVisualStudioSetting)
      while the guest records them as pending: a build or restore started
      applying them and devenv did not finish. It waits, and says why, until
      Visual Studio has been opened once, its user is signed in, and Visual
      Studio is closed, so an IDE someone has open is never touched. A guest
      that records nothing about them, a VM from before #266, has them
      recorded as applied, without applying them again.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $target = Get-VisualStudioSettingTarget -VM $VM
    if (-not $target) { return }
    $instanceId = $target.VisualStudio.InstanceId
    $state = Get-GuestVisualStudioSettingState -VM $VM -InstanceId $instanceId

    if (-not $state.Marker) {
        Write-VisualStudioSettingMarker -VM $VM -InstanceId $instanceId -AppliedHash $target.Settings.BackupHash
        Write-LogEntry 'Visual Studio settings: recorded as applied (this VM was built by an earlier LazyVM)' 'INFO'
        return
    }
    if (-not (Test-VisualStudioSettingPending -Marker $state.Marker)) {
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
    Import-GuestVisualStudioSetting -VM $VM -VisualStudio $target.VisualStudio -Settings $target.Settings
}
