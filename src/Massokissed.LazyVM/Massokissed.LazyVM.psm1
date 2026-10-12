# Massokissed.LazyVM.psm1
# The module's root. Loads every function from Private (internal) and
# Public (exported) and sets up the module's own state.
#
# In the published module, build.ps1 replaces this file with one that
# holds all the functions, so nothing is dot-sourced at import time.

# Pinned rather than 'Latest' so a future PowerShell release cannot
# silently change the semantics this module was tested against. A module
# does not inherit the caller's strict mode or preferences, so it sets its own.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# ── Module state ─────────────────────────────────────────────────────────────
# The files that ship with the module: the settings schema and the default
# tooling list.
$script:DataDir = Join-Path -Path $PSScriptRoot -ChildPath 'Data'

# The settings schema, read on first use (see Get-SettingsSchema).
$script:SettingsSchema = $null

# The settings for the VM the current command is working on. Filled in place
# by Import-LazyVMConfiguration; every function reads it as $CFG.
$script:Settings = @{}
$script:CFG = $script:Settings

# The PowerShell Direct session every guest call goes through.
$script:GuestSession = $null

# Connection target for guest-side SQL work. Refined to localhost\<instance>
# by Set-GuestSqlServer once the real instance name is known.
$script:GuestSqlServer = 'localhost'

# Logging: whether the log file has been prepared, and its encoding.
$script:LogReady = $false
$script:LogEncoding = $null

# ── Functions ────────────────────────────────────────────────────────────────
foreach ($folder in 'Private', 'Public') {
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
# -Name on every command completes with the VMs on this host.
$vmNameCompleter = {
    param($commandName, $parameterName, $wordToComplete)
    $root = Get-RegisteredRoot
    if (-not $root) { return }
    Get-VMProfileNames -ConfigDir (Get-ConfigDir -Root $root) |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
}
$vmCommands = @(
    'Build-LazyVM', 'Get-LazyVM', 'Get-LazyVMCredential', 'Get-LazyVMLicense', 'Get-LazyVMRestorePoint',
    'Get-LazyVMSetting', 'Get-LazyVMTooling', 'Invoke-LazyVMMaintenance', 'Invoke-LazyVMRebuild',
    'Register-LazyVMMaintenance', 'Remove-LazyVM', 'Restore-LazyVMState', 'Restore-LazyVMTooling',
    'Save-LazyVMState', 'Save-LazyVMTooling', 'Set-LazyVMCredential'
)
Register-ArgumentCompleter -CommandName $vmCommands -ParameterName 'Name' -ScriptBlock $vmNameCompleter
Remove-Variable -Name vmNameCompleter, vmCommands
