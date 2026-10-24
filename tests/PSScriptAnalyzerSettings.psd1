# PSScriptAnalyzer settings for the Pester tests: the module's settings, plus
# one rule Pester's structure trips. Variables set in BeforeAll or
# BeforeDiscovery are used in It blocks the analyzer cannot connect them to.
@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseDeclaredVarsMoreThanAssignments'
    )

    # One brace style everywhere: the opening brace on the same line, and else, catch and finally on the line after the closing brace.
    Rules        = @{
        PSPlaceOpenBrace        = @{ Enable = $true; OnSameLine = $true; NewLineAfter = $true; IgnoreOneLineBlock = $true }
        PSPlaceCloseBrace       = @{ Enable = $true; NewLineAfter = $true; IgnoreOneLineBlock = $true; NoEmptyLineBefore = $false }
        PSUseConsistentIndentation = @{ Enable = $true; IndentationSize = 4; Kind = 'space'; PipelineIndentation = 'IncreaseIndentationForFirstPipeline' }
        # Script blocks handed to these run in the caller's scope, so the
        # parameters they use count as used.
        PSReviewUnusedParameter = @{ CommandsToTraverse = @('Invoke-CommandRun', 'Wait-Until') }
    }
}
