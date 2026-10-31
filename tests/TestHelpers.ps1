# TestHelpers.ps1 - shared setup for the LazyVM Pester tests.
# Dot-sourced from each test file's BeforeAll; not meant to be run on its own.
#
# Run every test from the repository root with:
#   Invoke-Pester -Path .\tests -Output Detailed

# The module under test, from the source tree.
$script:LazyVMModuleDir = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'src\LazyVM'

function Import-LazyVMModule {
    <# Imports the LazyVM module, fresh, from the source tree. #>
    Import-Module -Name (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'LazyVM.psd1') -Force -DisableNameChecking
}

function Add-MissingCommandStub {
    <#
      Defines each command in $Stub (name -> script block) as a global
      function, but only when no command of that name exists, so Pester can
      mock it. A real command is left alone.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Stub)

    foreach ($name in $Stub.Keys) {
        if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "Function:\global:$name" -Value $Stub[$name]
        }
    }
}

# The Hyper-V cmdlets the tests mock, for a runner without Hyper-V (#28).
# Each takes the parameters the module passes, so a mock's parameter filter
# can read them, and throws when it is called without being mocked.
$script:HyperVCommandStubs = [ordered]@{
    'Get-VM'                   = { [CmdletBinding()] param([string[]]$Name) throw "$($MyInvocation.MyCommand.Name) is a test stub; mock it ($($PSBoundParameters.Keys -join ', '))." }
    'Start-VM'                 = { [CmdletBinding()] param([string[]]$Name) throw "$($MyInvocation.MyCommand.Name) is a test stub; mock it ($($PSBoundParameters.Keys -join ', '))." }
    'Stop-VM'                  = { [CmdletBinding()] param([string[]]$Name, [switch]$Force, [switch]$TurnOff) throw "$($MyInvocation.MyCommand.Name) is a test stub; mock it ($($PSBoundParameters.Keys -join ', '))." }
    'Restart-VM'               = { [CmdletBinding()] param([string[]]$Name, [switch]$Force, [switch]$Wait) throw "$($MyInvocation.MyCommand.Name) is a test stub; mock it ($($PSBoundParameters.Keys -join ', '))." }
    'Get-VMIntegrationService' = { [CmdletBinding()] param([string[]]$VMName, [string[]]$Name) throw "$($MyInvocation.MyCommand.Name) is a test stub; mock it ($($PSBoundParameters.Keys -join ', '))." }
    'Get-VMHardDiskDrive'      = { [CmdletBinding()] param([string[]]$VMName, $ControllerType, $ControllerNumber, $ControllerLocation) throw "$($MyInvocation.MyCommand.Name) is a test stub; mock it ($($PSBoundParameters.Keys -join ', '))." }
    'Get-VMDvdDrive'           = { [CmdletBinding()] param([string[]]$VMName, $ControllerNumber, $ControllerLocation) throw "$($MyInvocation.MyCommand.Name) is a test stub; mock it ($($PSBoundParameters.Keys -join ', '))." }
    'Add-VMHardDiskDrive'      = { [CmdletBinding()] param([string[]]$VMName, $ControllerType, $ControllerNumber, $ControllerLocation, [string]$Path) throw "$($MyInvocation.MyCommand.Name) is a test stub; mock it ($($PSBoundParameters.Keys -join ', '))." }
}
Add-MissingCommandStub -Stub $script:HyperVCommandStubs
