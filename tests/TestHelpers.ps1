# TestHelpers.ps1 - shared setup for the Massokissed.LazyVM Pester tests.
# Dot-sourced from each test file's BeforeAll; not meant to be run on its own.
#
# Run every test from the repository root with:
#   Invoke-Pester -Path .\tests -Output Detailed

# The module under test, from the source tree.
$script:LazyVMModuleDir = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'src\Massokissed.LazyVM'

function Import-LazyVMModule {
    <# Imports the Massokissed.LazyVM module, fresh, from the source tree. #>
    Import-Module -Name (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Massokissed.LazyVM.psd1') -Force -DisableNameChecking
}
