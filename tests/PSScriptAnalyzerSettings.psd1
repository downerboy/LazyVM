# PSScriptAnalyzer settings for the Pester tests: the module's settings, plus
# one rule Pester's structure trips. Variables set in BeforeAll or
# BeforeDiscovery are used in It blocks the analyzer cannot connect them to.
@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}
