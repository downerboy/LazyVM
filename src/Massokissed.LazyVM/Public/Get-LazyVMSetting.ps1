function Get-LazyVMSetting {
    <#
    .SYNOPSIS
    Shows a VM's settings: each value, where it came from, and what it does.

    .DESCRIPTION
    Lists every setting as the VM will use it, after your
    LazyVM.Settings.json and the VM's own VM.json have been applied over the
    defaults. Source says which of those set the value. Paths are shown in
    full, as LazyVM will use them.

    To change a setting, add it to Config\LazyVM.Settings.json in the LazyVM
    folder (every VM) or to Config\VMs\<Name>\VM.json (one VM). Opened in VS
    Code, both files offer autocomplete and check your values as you type.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .PARAMETER Setting
    Which settings to show. Wildcards are allowed. All of them by default.

    .EXAMPLE
    Get-LazyVMSetting

    .EXAMPLE
    Get-LazyVMSetting -Name DevBox -Setting Mem*

    .EXAMPLE
    Get-LazyVMSetting | Where-Object Source -ne 'Default'

    Only the settings you have changed.

    .OUTPUTS
    LazyVM.Setting
    #>
    [CmdletBinding()]
    [OutputType('LazyVM.Setting')]
    param(
        [Parameter(Position = 0)]
        [string]$Name,

        [Parameter(Position = 1)]
        [SupportsWildcards()]
        [string[]]$Setting = '*'
    )

    $root = (Resolve-LazyVMRoot).Path
    $configuration = Read-LazyVMSettings -Root $root -VMName $Name
    foreach ($warning in $configuration.Warnings) { Write-Warning $warning }

    $schema = Get-SettingsSchema
    foreach ($settingName in @($schema.properties.Keys | Where-Object { $_ -ne '$schema' })) {
        if (-not ($Setting | Where-Object { $settingName -like $_ })) { continue }

        [pscustomobject]@{
            PSTypeName  = 'LazyVM.Setting'
            VMName      = $configuration.VMName
            Setting     = $settingName
            Value       = $configuration.Settings[$settingName]
            Source      = $configuration.Sources[$settingName]
            Description = Get-SettingDescription -Name $settingName
        }
    }
}
