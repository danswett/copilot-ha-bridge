@{
    # Rules excluded as intentional or benign for this codebase; everything else is
    # enforced, and CI fails on any remaining finding.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'                        # installers and hooks write to the console on purpose
        'PSAvoidUsingEmptyCatchBlock'                  # deliberate best-effort suppression, documented at each site
        'PSUseShouldProcessForStateChangingFunctions'  # internal helpers, not public cmdlets
        'PSUseSingularNouns'                           # some Get-* helpers deliberately return collections
        'PSReviewUnusedParameter'                      # hook entry points and test mocks accept params they ignore
        'PSAvoidAssignmentToAutomaticVariable'         # hooks read their payload into $event; no PowerShell eventing is used
        'PSUseBOMForUnicodeEncodedFile'                # UTF-8 without a BOM is the intended, portable encoding
        'PSAvoidOverwritingBuiltInCmdlets'             # tests mock built-in cmdlets to simulate responses
        'PSUseCmdletCorrectly'                         # false positive on Write-Output -NoEnumerate
        'PSAvoidUsingPositionalParameters'             # test helpers (Test-That '...' { ... }) read fine positionally
    )
}
