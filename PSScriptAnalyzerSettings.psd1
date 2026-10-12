# PSScriptAnalyzer settings for LazyVM. Used by build.ps1, by CI, and by the
# VS Code PowerShell extension (powershell.scriptAnalysis.settingsPath).
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
}
