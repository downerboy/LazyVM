# GuestScriptSafety.Tests.ps1
# Script block logging (event 4104) is on in every guest (#291): it writes
# the text of every script that runs there to the event log. So a secret
# must reach the guest only as an argument (-ArgumentList), never inside
# the script's text. These checks parse the module's code and fail on the
# two ways a value could end up in a script's text: a script block made
# from a string at run time, and a string with variables in it passed as
# -ScriptBlock or -Work.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')

    function Get-ScriptBlockFromStringUse {
        <#
          Each place in $Ast that makes a script block from a string,
          [scriptblock]::Create(...) or ...NewScriptBlock(...), as
          "<function>: <code>", the function being the one it is in.
        #>
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)

        $uses = $Ast.FindAll({
                param($node)
                if ($node -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst]) { return $false }
                $member = "$($node.Member)"
                ($member -eq 'Create' -and $node.Static -and "$($node.Expression)" -match '^\[(System\.Management\.Automation\.)?ScriptBlock\]$') -or $member -eq 'NewScriptBlock'
            }, $true)
        foreach ($use in $uses) {
            $function = $use.Parent
            while ($function -and $function -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $function = $function.Parent }
            "$(if ($function) { $function.Name } else { '<script>' }): $($use.Extent.Text)"
        }
    }

    function Get-ExpandableScriptArgument {
        <# Each command in $Ast given a string with variables in it as -ScriptBlock or -Work, as its code. #>
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)

        $isExpandable = { param($node) $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }
        foreach ($command in $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $elements = $command.CommandElements
            for ($i = 0; $i -lt $elements.Count; $i++) {
                $element = $elements[$i]
                if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                if ($element.ParameterName -notin 'ScriptBlock', 'Work') { continue }
                $value = if ($element.Argument) { $element.Argument } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] } else { $null }
                if ($value -and (& $isExpandable $value)) { $command.Extent.Text }
            }
        }
    }

    function Get-SystemFolderVariableUse {
        <#
          Each $env: variable in $Ast that names a system folder, the system
          drive or the temporary folder, as "<function>: <variable>". The
          guest admin's environment includes HKCU\Environment, which that
          account can change without elevating, so none of these can say
          where LazyVM trusts, writes or deletes (#317). Profile folders
          (APPDATA, LOCALAPPDATA, USERPROFILE) are the user's own (#310).
        #>
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)

        $systemFolders = @('ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'CommonProgramFiles', 'CommonProgramFiles(x86)', 'CommonProgramW6432',
            'ProgramData', 'ALLUSERSPROFILE', 'PUBLIC', 'SystemRoot', 'windir', 'SystemDrive', 'TEMP', 'TMP')
        $uses = $Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.DriveName -eq 'env' -and
                $systemFolders -contains ($node.VariablePath.UserPath -replace '^env:', '')
            }, $true)
        foreach ($use in $uses) {
            $function = $use.Parent
            while ($function -and $function -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $function = $function.Parent }
            "$(if ($function) { $function.Name } else { '<script>' }): $($use.Extent.Text)"
        }
    }

    function ConvertTo-TestAst {
        param([Parameter(Mandatory)][string]$Code)

        return [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$null)
    }

    $moduleDir = (Resolve-Path -LiteralPath $script:LazyVMModuleDir).ProviderPath
    $moduleAsts = @(Get-ChildItem -LiteralPath $moduleDir -Filter '*.ps1' -Recurse -File | ForEach-Object {
            [pscustomobject]@{
                File = $_.FullName.Substring($moduleDir.Length + 1) -replace '/', '\'
                Ast  = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
            }
        })
}

Describe 'The checks for script text made from values' {
    It 'finds <Code>' -ForEach @(
        @{ Code = 'function Get-Thing { [scriptblock]::Create("Unlock $password") }' }
        @{ Code = 'function Get-Thing { [System.Management.Automation.ScriptBlock]::Create($text) }' }
        @{ Code = 'function Get-Thing { $ExecutionContext.InvokeCommand.NewScriptBlock($text) }' }
    ) {
        @(Get-ScriptBlockFromStringUse -Ast (ConvertTo-TestAst -Code $Code)).Count | Should -Be 1
    }

    It 'finds an expandable string given as <Code>' -ForEach @(
        @{ Code = 'Invoke-GuestScript -VM $VM -ScriptBlock "Unlock-BitLocker -RecoveryPassword $key"' }
        @{ Code = 'Invoke-GuestTask -VM $VM -TaskName x -Work:"Set-Thing $secret"' }
    ) {
        @(Get-ExpandableScriptArgument -Ast (ConvertTo-TestAst -Code $Code)).Count | Should -Be 1
    }

    It 'lets a script block with its values in -ArgumentList through' {
        $ast = ConvertTo-TestAst -Code 'Invoke-GuestScript -VM $VM -ArgumentList @($key) -ScriptBlock { param($key) Unlock-BitLocker -RecoveryPassword $key }'

        @(Get-ExpandableScriptArgument -Ast $ast).Count | Should -Be 0
        @(Get-ScriptBlockFromStringUse -Ast $ast).Count | Should -Be 0
    }
}

Describe 'Secrets reach the guest only through -ArgumentList (#291)' {
    It 'makes a script block from a string only where it loads the guest helpers' {
        # Import-GuestHelper turns Data\Guest.Helpers.ps1, a file of the
        # module's own, into a module in the guest. The guest task wrapper's
        # [scriptblock]::Create in Guest.Helpers.ps1 is in a here-string,
        # the wrapper's text, so the parse sees no call there: it runs the
        # work.ps1 Invoke-GuestTask wrote from a script block's own text.
        $known = @('Private\Guest\GuestSession.ps1 Import-GuestHelper: [scriptblock]::Create($text)')

        $found = @(foreach ($file in $moduleAsts) {
                foreach ($use in @(Get-ScriptBlockFromStringUse -Ast $file.Ast)) { "$($file.File) $use" }
            })

        @($found | Where-Object { $_ -notin $known }) | Should -BeNullOrEmpty
    }

    It 'passes no string with variables in it as -ScriptBlock or -Work' {
        $found = @(foreach ($file in $moduleAsts) {
                foreach ($command in @(Get-ExpandableScriptArgument -Ast $file.Ast)) { "$($file.File): $command" }
            })

        $found | Should -BeNullOrEmpty
    }
}

Describe 'The check for system folders taken from the environment' {
    It 'finds <Code>' -ForEach @(
        @{ Code = 'function Get-Thing { Join-Path $env:ProgramFiles ''LazyVM'' }' }
        @{ Code = 'function Get-Thing { "${env:ProgramFiles(x86)}\Microsoft" }' }
        @{ Code = 'function Get-Thing { "$env:SystemRoot\System32" }' }
        @{ Code = 'function Get-Thing { Join-Path $env:TEMP ''x'' }' }
    ) {
        @(Get-SystemFolderVariableUse -Ast (ConvertTo-TestAst -Code $Code)).Count | Should -Be 1
    }

    It 'lets a profile folder and a folder Windows reports through' {
        $ast = ConvertTo-TestAst -Code 'function Get-Thing { Join-Path $env:APPDATA ''NuGet''; [Environment]::GetFolderPath(''ProgramFiles'') }'

        @(Get-SystemFolderVariableUse -Ast $ast).Count | Should -Be 0
    }
}

Describe 'System folders come from Windows, not from the environment (#317)' {
    It 'takes no system folder, system drive or temporary folder from an environment variable' {
        $found = @(foreach ($file in $moduleAsts) {
                foreach ($use in @(Get-SystemFolderVariableUse -Ast $file.Ast)) { "$($file.File) $use" }
            })

        $found | Should -BeNullOrEmpty
    }

    It 'takes none in the guest task wrapper, which runs without the guest helpers' {
        # The wrapper is a here-string in Guest.Helpers.ps1, so its own text is parsed.
        $helpers = @($moduleAsts | Where-Object { $_.File -eq 'Data\Guest.Helpers.ps1' })[0].Ast
        $assignment = $helpers.Find({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($node.Left)" -eq '$script:GuestTaskWrapper'
            }, $true)
        $wrapper = ConvertTo-TestAst -Code $assignment.Right.Expression.Value

        @(Get-SystemFolderVariableUse -Ast $wrapper) | Should -BeNullOrEmpty
    }
}
