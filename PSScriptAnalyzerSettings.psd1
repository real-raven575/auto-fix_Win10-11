@{
    ExcludeRules = @(
        # The console front end is meant to write coloured lines to the host.
        'PSAvoidUsingWriteHost',
        # Get-Af*Evidence returns many records; plural nouns read better here.
        'PSUseSingularNouns',
        # New-Af* helpers build in-memory records and change no system state.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
