# PSScriptAnalyzer settings for LazyVM. Used by Invoke-AnalyzerAndTest.ps1,
# by CI, and by the VS Code PowerShell extension
# (powershell.scriptAnalysis.settingsPath).
#
# A rule left out here is kept on purpose; each exception in the code itself
# is a SuppressMessageAttribute on the one function it applies to, with its
# reason.
@{
    Severity     = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        # Only the public commands change things on the user's behalf, and
        # every one of them that does supports -WhatIf and -Confirm
        # (tests\Module.Tests.ps1 checks this). The private functions they
        # call do not ask again.
        'PSUseShouldProcessForStateChangingFunctions'
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
