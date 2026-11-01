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
#
# Once Visual Studio has been opened, this tries for at most
# $script:VisualStudioSettingRetryNights nights, counted from the night it
# first finds it opened; after that it keeps the settings Visual Studio has.

# How many nights, from the night Visual Studio is first found opened, the
# settings are tried before LazyVM keeps the ones Visual Studio has.
$script:VisualStudioSettingRetryNights = 7

# How the guest records that night: a date only, the same in any culture.
$script:VisualStudioSettingFirstOpenedFormat = 'yyyy-MM-dd'

function Get-GuestVisualStudioSettingState {
    <#
      What the guest has of the settings of the Visual Studio with instance
      $InstanceId, as @{ Marker; FirstOpened; OpenedOnce; DevenvRunning }:
      what it records of them (Get-GuestVisualStudioSettingMarker), the night
      maintenance first found Visual Studio opened while they were pending
      (a [datetime], or $null), whether Visual Studio has been opened and
      closed at least once, and whether it is running now.
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$InstanceId
    )

    $state = Invoke-GuestScript -VM $VM -Activity 'checking the Visual Studio settings' -TimeoutMinutes 2 -ArgumentList @($InstanceId) -ScriptBlock {
        param($instanceId)
        [pscustomobject]@{
            Marker        = Get-GuestVisualStudioSettingMarker -InstanceId $instanceId
            FirstOpened   = Get-GuestVisualStudioFirstOpened -InstanceId $instanceId
            OpenedOnce    = [bool](Get-GuestVisualStudioSettingsFile -InstanceId $instanceId)
            DevenvRunning = @(Get-Process -Name devenv -ErrorAction SilentlyContinue).Count -gt 0
        }
    }
    $firstOpened = $null
    if ($state.FirstOpened) {
        $firstOpened = [datetime]::ParseExact($state.FirstOpened, $script:VisualStudioSettingFirstOpenedFormat, [cultureinfo]::InvariantCulture)
    }
    return [pscustomobject]@{
        Marker        = $state.Marker
        FirstOpened   = $firstOpened
        OpenedOnce    = $state.OpenedOnce
        DevenvRunning = $state.DevenvRunning
    }
}

function Write-VisualStudioSettingFirstOpened {
    <#
      Records in the guest $Date as the night maintenance first found the
      Visual Studio with instance $InstanceId opened while its settings were
      pending. Writing the marker (Write-VisualStudioSettingMarker) forgets it.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][datetime]$Date
    )

    $night = $Date.ToString($script:VisualStudioSettingFirstOpenedFormat, [cultureinfo]::InvariantCulture)
    $null = Invoke-GuestScript -VM $VM -Activity 'recording when Visual Studio was first opened' -TimeoutMinutes 2 -ArgumentList @($InstanceId, $night) -ScriptBlock {
        param($instanceId, $night)
        Set-GuestVisualStudioFirstOpened -InstanceId $instanceId -Date $night
    }
}

function Update-GuestVisualStudioSetting {
    <#
      Applies the Visual Studio settings (Import-GuestVisualStudioSetting)
      while the guest records them as pending: a build or restore started
      applying them and devenv did not finish, or a VM built before LazyVM
      recorded them. It waits, and says why, until Visual Studio has been
      opened once, its user is signed in, and Visual Studio is closed, so an
      IDE someone has open is never touched. From the night it first finds
      Visual Studio opened, it tries for $script:VisualStudioSettingRetryNights
      nights; then it records the settings Visual Studio has as applied and
      says so once, and the next capture saves them as the settings backup.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $target = Get-VisualStudioSettingTarget -VM $VM
    if (-not $target) { return }
    $instanceId = $target.VisualStudio.InstanceId
    $state = Get-GuestVisualStudioSettingState -VM $VM -InstanceId $instanceId

    if (-not (Test-VisualStudioSettingPending -Marker $state.Marker)) {
        Write-LogEntry 'Visual Studio settings: applied already' 'INFO'
        return
    }
    if (-not $state.OpenedOnce) {
        Write-LogEntry 'Visual Studio settings: waiting for Visual Studio''s first launch - they are applied the night after it has been opened and closed in the VM' 'INFO'
        return
    }
    $tonight = (Get-Date).Date
    $firstOpened = $state.FirstOpened
    if (-not $firstOpened) {
        $firstOpened = $tonight
        Write-VisualStudioSettingFirstOpened -VM $VM -InstanceId $instanceId -Date $firstOpened
    }
    if (($tonight - $firstOpened).Days -ge $script:VisualStudioSettingRetryNights) {
        Write-VisualStudioSettingMarker -VM $VM -InstanceId $instanceId -AppliedHash $target.Settings.BackupHash
        Write-LogEntry ("Visual Studio settings: not applied in the $script:VisualStudioSettingRetryNights nights since Visual Studio was first found opened on " +
            "$($firstOpened.ToString($script:VisualStudioSettingFirstOpenedFormat, [cultureinfo]::InvariantCulture)) - its user was not signed in, it was open, or the import failed. " +
            'LazyVM stops trying and keeps the settings Visual Studio has; the next capture saves them as the settings backup') 'WARN'
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
