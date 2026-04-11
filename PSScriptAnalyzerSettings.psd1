@{
    ExcludeRules = @(
        # This is a CLI script with colored console output — Write-Host is intentional.
        'PSAvoidUsingWriteHost',

        # Internal helper functions called within a single script — ShouldProcess adds
        # no value here since the top-level script already controls execution flow.
        'PSUseShouldProcessForStateChangingFunctions',

        # Standalone script, not a module — approved verbs and singular nouns are
        # conventions for published cmdlets, not internal automation scripts.
        'PSUseApprovedVerbs',
        'PSUseSingularNouns',

        # Variables assigned for clarity or side effects (e.g. capturing output to discard it).
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}
