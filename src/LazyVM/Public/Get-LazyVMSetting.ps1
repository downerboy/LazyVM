function Get-LazyVMSetting {
    <#
    .SYNOPSIS
    Shows a VM's settings: each value, where it came from, and what it does.

    .DESCRIPTION
    Lists every setting as the VM will use it. Each VM's VM.json holds all
    of its settings; Source names it, or, for a setting VM.json does not
    have yet, the shared template (LazyVM.Settings.json or Default) the value
    comes from until the next build, maintenance or rebuild writes it in.
    Paths are shown in full, as LazyVM will use them.

    To change a setting for a VM, change it in <Name>\Config\VM.json. The
    shared template, Shared\Config\LazyVM.Settings.json, applies only to VMs
    created afterwards. Opened in VS Code, both files offer autocomplete and
    check your values as you type.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .PARAMETER Setting
    Which settings to show. Wildcards are allowed. All of them by default.

    .EXAMPLE
    Get-LazyVMSetting

    .EXAMPLE
    Get-LazyVMSetting -Name DevBox -Setting Mem*

    .EXAMPLE
    Get-LazyVMSetting -Name DevBox | Where-Object Source -ne 'DevBox\Config\VM.json'

    The settings DevBox's VM.json does not have yet.

    .OUTPUTS
    LazyVM.Setting
    #>
    [CmdletBinding()]
    [OutputType('LazyVM.Setting')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [Parameter(Position = 1)]
        [SupportsWildcards()]
        [string[]]$Setting = '*'
    )

    process {
        $root = (Resolve-LazyVMRoot).Path
        $configuration = Read-VMSetting -Root $root -VMName $Name
        foreach ($warning in $configuration.Warnings) { Write-Warning $warning }

        $schema = Get-SettingsSchema
        foreach ($settingName in @($schema.properties.Keys | Where-Object { $_ -ne '$schema' })) {
            if (-not ($Setting | Where-Object { $settingName -like $_ })) { continue }

            [pscustomobject]@{
                PSTypeName  = 'LazyVM.Setting'
                Name        = $configuration.VMName
                Setting     = $settingName
                Value       = $configuration.Settings[$settingName]
                Source      = $configuration.Sources[$settingName]
                Description = Get-SettingDescription -Name $settingName
            }
        }
    }
}
