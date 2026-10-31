# WingetMatch.ps1 - winget packages for programs installed some other way (#24).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  WINGET MATCHES FOR OTHER PROGRAMS
#
#  A program installed from its own installer is not in winget's export, but
#  winget may still have a package for it. Each one is searched for in the
#  winget source by its exact name, and the result is accepted only when
#  exactly one package has that name AND winget names the same publisher as
#  the program's uninstall entry, so a similarly named package is never
#  installed in its place. A rebuild then installs the match with winget.
#
#  The answer, found or not, is kept in the tooling list (Program.WingetId)
#  and reused, so each program is looked up once. A failed lookup (no
#  winget, no network) is retried on the next run.
# ─────────────────────────────────────────────────────────────────────────────

function Get-ProgramWingetMatch {
    <# Each looked-up program as "Name = Id", or "Name = none" when winget had no package for it. #>
    param([AllowEmptyCollection()][ToolingProgram[]]$Programs = @())

    foreach ($program in @($Programs | Where-Object { $_ -and $null -ne $_.WingetId })) {
        $id = if ($program.WingetId) { $program.WingetId } else { 'none' }
        "$($program.Name) = $id"
    }
}

function Add-ProgramWingetId {
    <# Gives each program in $Record its WingetId, reusing $Previous's answers. Updates $Record in place. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][ToolingRecord]$Record,
        [AllowNull()][ToolingRecord]$Previous
    )

    $known = @{}
    if ($Previous) {
        foreach ($program in @($Previous.Programs + $Previous.Awaiting().Programs)) {
            if ($program -and $null -ne $program.WingetId) { $known[$program.Name] = "$($program.WingetId)" }
        }
    }

    $unknown = @()
    foreach ($program in @($Record.Programs | Where-Object { $_ })) {
        if ($known.ContainsKey($program.Name)) { $program.WingetId = $known[$program.Name] }
        elseif ($null -eq $program.WingetId) { $unknown += $program }
    }
    if ($unknown.Count -eq 0) { return }

    $queries = @($unknown | ForEach-Object { @{ Name = $_.Name; Publisher = "$($_.Publisher)" } })
    try {
        $answers = Invoke-GuestScript -VM $VM -Activity 'winget package lookup' -TimeoutMinutes 30 -ArgumentList @(, $queries) -ScriptBlock {
            param($queries)
            $ErrorActionPreference = 'Continue'
            $noMatch = -1978335212

            $winget = Find-GuestWinget
            if (-not $winget) { return @() }

            foreach ($query in $queries) {
                $name = "$($query['Name'])"
                $publisher = "$($query['Publisher'])".Trim()
                # Without a publisher to compare, a match cannot be confirmed.
                if (-not $publisher) { [pscustomobject]@{ Name = $name; WingetId = '' }; continue }

                $found = @(& $winget search --name $name --exact --source winget --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { "$_" })
                if ($LASTEXITCODE -eq $noMatch) { [pscustomobject]@{ Name = $name; WingetId = '' }; continue }
                if ($LASTEXITCODE -ne 0) { continue }

                $id = Select-GuestWingetMatch -Lines $found -Name $name
                if ($id) {
                    $shown = @(& $winget show --id $id --exact --source winget --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { "$_" })
                    if ($LASTEXITCODE -ne 0) { continue }
                    if ((Get-GuestWingetPublisher -Lines $shown) -ne $publisher) { $id = '' }
                }
                [pscustomobject]@{ Name = $name; WingetId = $id }
            }
        }
    }
    catch {
        Write-LogEntry "  winget package lookup failed: $($_.Exception.Message)" 'WARN'
        return
    }

    # The guest's answers are checked again here: only a well-formed id for
    # a program that was asked about is taken.
    $byName = @{}
    foreach ($answer in @($answers | Where-Object { $_ })) {
        $id = [RecordReader]::Text($answer, 'WingetId')
        if ($id -and $id -notmatch $script:WingetIdPattern) { continue }
        $byName[[RecordReader]::Text($answer, 'Name')] = $id
    }
    foreach ($program in $unknown) {
        if ($byName.ContainsKey($program.Name)) { $program.WingetId = $byName[$program.Name] }
    }
}
