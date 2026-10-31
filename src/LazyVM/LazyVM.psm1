# LazyVM.psm1
# The module's root. Loads the classes, then every function from Private
# (internal) and Public (exported).
#
# In the published module, Invoke-Assemble replaces this file with one that
# holds all the classes and functions, so nothing is dot-sourced at import time.

# Pinned rather than 'Latest' so a future PowerShell release cannot
# silently change the semantics this module was tested against. A module
# does not inherit the caller's strict mode or preferences, so it sets its own.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# ── Module state ─────────────────────────────────────────────────────────────
# The files that ship with the module: the settings schema, the default
# tooling list and the guest helpers.
$script:DataDir = Join-Path -Path $PSScriptRoot -ChildPath 'Data'

# Read on first use (Get-SettingsSchema, Import-GuestHelper).
$script:SettingsSchema = $null
$script:GuestHelperText = $null

# ── Functions ────────────────────────────────────────────────────────────────
# Classes first, in their numbered order, because the functions use them.
foreach ($folder in 'Classes', 'Private', 'Public') {
    $folderPath = Join-Path -Path $PSScriptRoot -ChildPath $folder
    if (-not (Test-Path -LiteralPath $folderPath)) {
        continue
    }
    $files = Get-ChildItem -LiteralPath $folderPath -Filter '*.ps1' -File -Recurse | Sort-Object -Property FullName
    foreach ($file in $files) {
        . $file.FullName
    }
}
Remove-Variable -Name folder, folderPath, files, file -ErrorAction SilentlyContinue

# ── Tab completion ───────────────────────────────────────────────────────────
# -Name completes with the VMs on this host, on every command that works on
# an existing VM.
$vmNameCompleter = {
    # PowerShell passes the command name, the parameter name and the word
    # typed so far; only the word is needed.
    $wordToComplete = $args[2]
    $root = Get-RegisteredRoot
    if (-not $root) { return }
    Get-VMProfileName -Root $root |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
}
$vmCommands = @(Get-ChildItem -Path function: |
        Where-Object { $_.Name -like '*-LazyVM*' -and $_.Verb -ne 'New' -and $_.Parameters.ContainsKey('Name') } |
        ForEach-Object { $_.Name })
Register-ArgumentCompleter -CommandName $vmCommands -ParameterName 'Name' -ScriptBlock $vmNameCompleter
Register-ArgumentCompleter -CommandName 'New-LazyVM' -ParameterName 'Template' -ScriptBlock {
    $wordToComplete = $args[2]
    Get-VMTemplateName |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
}
Remove-Variable -Name vmNameCompleter, vmCommands
