# ToolingMigration.ps1 - Folds a VM's tooling files from before #130 into VM.json, once.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Before #130 each VM kept its tooling list in files of its own. Each goes
# into the file that holds it now:
#
#   Tooling.json                  -> VM.json, as its Tooling setting
#   Tooling.Template.json         -> VM.Template.json, likewise
#   History\Tooling-<stamp>.json  -> History\VM-<stamp>.json, the version of
#                                    VM.json its restore point needs
#
# An old file is deleted only once the file it went into reads back with the
# same list. Otherwise it stays, with a warning, and the next run tries again.

function Read-LegacyTooling {
    <# A tooling list from one of the old files, as the value of the Tooling setting. #>
    param([Parameter(Mandatory)][string]$Path)

    return ConvertTo-PlainValue -Value (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -DateKind String)
}

function Complete-ToolingFold {
    <#
      Deletes the old file $From once $Into reads back with the same tooling
      list. Returns whether it did; warns, keeping $From, when it did not.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$Into,
        [Parameter(Mandatory)]$List
    )

    $readBack = (Read-SettingsFile -Path $Into)[$script:ToolingSettingName]
    if ((ConvertTo-ComparableJson $readBack) -ne (ConvertTo-ComparableJson $List)) {
        Write-LogEntry "$From was kept: $Into holds a different tooling list. Compare the two, keep the list you want in $Into, then delete $From." 'WARN'
        return $false
    }
    Remove-Item -LiteralPath $From -Force
    Write-LogEntry "Folded $From into $Into, and deleted it" 'OK'
    return $true
}

function Move-LegacyToolingHistory {
    <#
      Makes each History\Tooling-<stamp>.json a version of VM.json under the
      same date-time: VM.json as it is now, with that tooling list.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name
    )

    $files = @(Get-ChildItem -LiteralPath (Get-ProfileHistoryDir -Root $Root -Name $Name) -Filter 'Tooling-*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^Tooling-\d{8}-\d{6}\.json$' })
    if ($files.Count -eq 0) { return }

    $current = Read-SettingsFile -Path (Get-VMProfilePath -Root $Root -Name $Name)
    foreach ($file in $files) {
        $stamp = $file.BaseName -replace '^Tooling-', ''
        $list = Read-LegacyTooling -Path $file.FullName
        $versionPath = Get-ProfileVersionPath -Root $Root -Name $Name -Stamp $stamp
        if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
            $version = Read-SettingsFile -Path $versionPath
        }
        else {
            $version = @{} + $current
            $version.Remove($script:ToolingSettingName)
        }
        if (-not $version.ContainsKey($script:ToolingSettingName)) {
            $version[$script:ToolingSettingName] = $list
            Write-TextFileAtomic -Path $versionPath -Text (ConvertTo-SettingsJson -Settings $version -ForProfile)
        }
        $null = Complete-ToolingFold -From $file.FullName -Into $versionPath -List $list
    }
}

function Move-LegacyTooling {
    <# Folds Tooling.json into VM.json. Returns whether VM.json changed. #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name
    )

    $legacy = Join-Path -Path (Get-VMProfileDir -Root $Root -Name $Name) -ChildPath $script:LegacyToolingFileName
    if (-not (Test-Path -LiteralPath $legacy -PathType Leaf)) { return $false }

    $path = Get-VMProfilePath -Root $Root -Name $Name
    $list = Read-LegacyTooling -Path $legacy
    $changed = $false
    if (-not (Read-SettingsFile -Path $path).ContainsKey($script:ToolingSettingName)) {
        $changed = @(Update-VMProfile -Root $Root -Name $Name -Change @{ $script:ToolingSettingName = $list } -Reason "tooling list folded in from $script:LegacyToolingFileName").Count -gt 0
    }
    $null = Complete-ToolingFold -From $legacy -Into $path -List $list
    return $changed
}

function Move-LegacyToolingTemplate {
    <#
      Folds Tooling.Template.json into VM.Template.json: the one change ever
      made to the template. Waits while there is no VM.Template.json yet.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name
    )

    $configDir = Get-VMProfileDir -Root $Root -Name $Name
    $legacy = Join-Path -Path $configDir -ChildPath $script:LegacyToolingTemplateFileName
    $templatePath = Join-Path -Path $configDir -ChildPath $script:ProfileTemplateFileName
    if (-not (Test-Path -LiteralPath $legacy -PathType Leaf) -or -not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { return }

    $list = Read-LegacyTooling -Path $legacy
    $template = Read-SettingsFile -Path $templatePath
    if (-not $template.ContainsKey($script:ToolingSettingName)) {
        $template[$script:ToolingSettingName] = $list
        Write-TextFileAtomic -Path $templatePath -Text (ConvertTo-SettingsJson -Settings $template -ForProfile)
    }
    $null = Complete-ToolingFold -From $legacy -Into $templatePath -List $list
}

function Move-ToolingIntoProfile {
    <#
      Folds a VM's tooling files from before #130 into VM.json, its template
      and its history. Returns whether VM.json changed, so the caller can read
      its settings again. Never throws: whatever cannot be folded in stays as
      it is, with a warning, and the next run tries again.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name
    )

    $changed = $false
    try {
        # The history first, so the versions it adds are there when VM.json
        # changes and the oldest are removed.
        Move-LegacyToolingHistory -Root $Root -Name $Name
        $changed = Move-LegacyTooling -Root $Root -Name $Name
        Move-LegacyToolingTemplate -Root $Root -Name $Name
    }
    catch {
        Write-LogEntry "The tooling files from before LazyVM kept the list in VM.json could not all be folded in, so they are left as they are: $($_.Exception.Message)" 'WARN'
    }
    return $changed
}
