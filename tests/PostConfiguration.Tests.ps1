# PostConfiguration.Tests.ps1
# Build phase 8 runs its steps isolated, so a step that calls a command that
# no longer exists fails only at run time, in a real build (#225). Nothing
# here needs Hyper-V or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
}

Describe 'Complete-GuestConfiguration' {
    It 'calls only commands that exist in each of its steps' {
        $missing = InModuleScope $module {
            $definition = (Get-Command -Name Complete-GuestConfiguration).ScriptBlock.Ast
            $actions = $definition.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.HashtableAst] -and
                    @($node.KeyValuePairs | Where-Object { "$($_.Item1)" -eq 'Action' }).Count -gt 0
                }, $true) | ForEach-Object { ($_.KeyValuePairs | Where-Object { "$($_.Item1)" -eq 'Action' }).Item2 }
            $names = foreach ($action in $actions) {
                $action.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() }
            }
            @($names | Sort-Object -Unique | Where-Object { $_ -and -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
        }

        $missing | Should -BeNullOrEmpty
    }
}
