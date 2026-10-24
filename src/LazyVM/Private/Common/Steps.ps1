# Steps.ps1 - Running a list of steps where one failing must not stop the rest.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function Invoke-IsolatedStep {
    <#
      Runs each step's Action in turn. A step that throws is logged and the
      rest still run: a firewall rule that cannot be added must not cost the
      databases. Returns Results (each step's output, by Name) and Failures
      (one line per failed step).
    #>
    param(
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][object[]]$Steps
    )

    $results = @{}
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($step in $Steps) {
        try {
            $results[$step.Name] = & $step.Action
        }
        catch {
            $failures.Add("$($step.Name): $($_.Exception.Message)")
            Write-LogError "$($step.Name) failed" $_
            Write-LogEntry "  Carrying on with the remaining $What steps." 'INFO'
        }
    }
    if ($failures.Count -gt 0) {
        Write-LogEntry "$What finished with $($failures.Count) of $($Steps.Count) steps failing" 'WARN'
    }
    return [pscustomobject]@{ Results = $results; Failures = @($failures) }
}
