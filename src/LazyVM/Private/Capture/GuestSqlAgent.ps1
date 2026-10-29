# GuestSqlAgent.ps1 - The guest's SQL Server Agent jobs, operators and alerts, recorded in VM.json.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Agent objects live in msdb, which a rebuild replaces with a fresh one, so
# they are recorded in VM.json's GuestSql.Agent (#131) with the logins
# (GuestSql.ps1) and recreated after the databases are back: a job step
# names its database, and SQL Server checks that it exists. Only local jobs
# are recorded, and not the ones SQL Server creates itself.

function Get-GuestSqlAgentSnapshot {
    <#
      Reads the instance's operators, its local jobs with their steps and
      schedules, and its alerts with whom they notify, from the instance
      Connect-GuestSqlInstance found.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    return Invoke-GuestScript -VM $VM -Activity 'SQL Agent check' -TimeoutMinutes 10 -ArgumentList @($VM.Runtime.SqlServer) -ScriptBlock {
        param($server)
        $ErrorActionPreference = 'Stop'
        $connection = Open-GuestSqlConnection -Server $server
        try {
            $operators = @(Get-GuestSqlRow -Connection $connection -Sql @'
SELECT o.name AS Name, CAST(o.enabled AS bit) AS Enabled, ISNULL(o.email_address, N'') AS EmailAddress, ISNULL(c.name, N'') AS Category
FROM msdb.dbo.sysoperators o LEFT JOIN msdb.dbo.syscategories c ON c.category_id = o.category_id
'@)

            # SQL Server's own jobs come back with a fresh install anyway.
            $jobs = @(foreach ($job in @(Get-GuestSqlRow -Connection $connection -Sql @'
SELECT CONVERT(nvarchar(36), j.job_id) AS JobId, j.name AS Name, CAST(j.enabled AS bit) AS Enabled,
       ISNULL(j.description, N'') AS Description, ISNULL(c.name, N'') AS Category,
       ISNULL(SUSER_SNAME(j.owner_sid), N'') AS Owner, j.start_step_id AS StartStepId,
       j.notify_level_eventlog AS NotifyLevelEventLog, j.notify_level_email AS NotifyLevelEmail,
       ISNULL(o.name, N'') AS NotifyEmailOperator, j.delete_level AS DeleteLevel
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
LEFT JOIN msdb.dbo.sysoperators o ON o.id = j.notify_email_operator_id
WHERE j.name NOT IN (N'syspolicy_purge_history', N'SSIS Server Maintenance Job')
  AND EXISTS (SELECT 1 FROM msdb.dbo.sysjobservers s WHERE s.job_id = j.job_id AND s.server_id = 0)
'@)) {
                    $id = ConvertTo-SqlString -Text "$($job.JobId)"
                    $steps = @(Get-GuestSqlRow -Connection $connection -Sql @"
SELECT s.step_id AS Id, s.step_name AS Name, s.subsystem AS Subsystem, ISNULL(s.command, N'') AS Command,
       ISNULL(s.database_name, N'') AS [Database], s.on_success_action AS OnSuccessAction, s.on_success_step_id AS OnSuccessStepId,
       s.on_fail_action AS OnFailAction, s.on_fail_step_id AS OnFailStepId, s.retry_attempts AS RetryAttempts,
       s.retry_interval AS RetryInterval, ISNULL(s.output_file_name, N'') AS OutputFile, s.flags AS Flags, ISNULL(p.name, N'') AS Proxy
FROM msdb.dbo.sysjobsteps s LEFT JOIN msdb.dbo.sysproxies p ON p.proxy_id = s.proxy_id
WHERE s.job_id = $id
"@)
                    $schedules = @(Get-GuestSqlRow -Connection $connection -Sql @"
SELECT sc.name AS Name, CAST(sc.enabled AS bit) AS Enabled, sc.freq_type AS FreqType, sc.freq_interval AS FreqInterval,
       sc.freq_subday_type AS FreqSubdayType, sc.freq_subday_interval AS FreqSubdayInterval,
       sc.freq_relative_interval AS FreqRelativeInterval, sc.freq_recurrence_factor AS FreqRecurrenceFactor,
       sc.active_start_date AS ActiveStartDate, sc.active_end_date AS ActiveEndDate,
       sc.active_start_time AS ActiveStartTime, sc.active_end_time AS ActiveEndTime
FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules sc ON sc.schedule_id = js.schedule_id
WHERE js.job_id = $id
"@)
                    $job | Add-Member -NotePropertyName Steps -NotePropertyValue $steps
                    $job | Add-Member -NotePropertyName Schedules -NotePropertyValue $schedules -PassThru
                })

            $alerts = @(foreach ($alert in @(Get-GuestSqlRow -Connection $connection -Sql @'
SELECT a.id AS AlertId, a.name AS Name, CAST(a.enabled AS bit) AS Enabled, a.message_id AS MessageId, a.severity AS Severity,
       a.delay_between_responses AS DelayBetweenResponses, ISNULL(a.notification_message, N'') AS NotificationMessage,
       a.include_event_description AS IncludeEventDescription, ISNULL(a.database_name, N'') AS [Database],
       ISNULL(a.event_description_keyword, N'') AS EventDescriptionKeyword, ISNULL(j.name, N'') AS Job,
       ISNULL(a.performance_condition, N'') AS PerformanceCondition, ISNULL(c.name, N'') AS Category
FROM msdb.dbo.sysalerts a
LEFT JOIN msdb.dbo.sysjobs j ON j.job_id = a.job_id
LEFT JOIN msdb.dbo.syscategories c ON c.category_id = a.category_id
'@)) {
                    $notifications = @(Get-GuestSqlRow -Connection $connection -Sql "SELECT o.name AS Operator, n.notification_method AS Method FROM msdb.dbo.sysnotifications n JOIN msdb.dbo.sysoperators o ON o.id = n.operator_id WHERE n.alert_id = $([int]$alert.AlertId)")
                    $alert | Add-Member -NotePropertyName Notifications -NotePropertyValue $notifications -PassThru
                })

            return [pscustomobject]@{ Operators = $operators; Jobs = $jobs; Alerts = $alerts }
        }
        finally { $connection.Close() }
    }
}

function ConvertTo-GuestSqlAgentRecord {
    <#
      Turns what the guest reported ($Snapshot, from
      Get-GuestSqlAgentSnapshot) into VM.json's GuestSql.Agent: operators,
      jobs and alerts sorted by name and steps in step order, so the same
      objects always compare equal.
    #>
    param([Parameter(Mandatory)][object]$Snapshot)

    $operators = @(foreach ($operator in @($Snapshot.Operators | Where-Object { $_ } | Sort-Object -Property Name)) {
            [ordered]@{ Name = [string]$operator.Name; Enabled = [bool]$operator.Enabled; EmailAddress = [string]$operator.EmailAddress; Category = [string]$operator.Category }
        })

    $jobs = @(foreach ($job in @($Snapshot.Jobs | Where-Object { $_ } | Sort-Object -Property Name)) {
            $steps = @(foreach ($step in @($job.Steps | Where-Object { $_ } | Sort-Object -Property { [int]$_.Id })) {
                    [ordered]@{
                        Id = [int]$step.Id; Name = [string]$step.Name; Subsystem = [string]$step.Subsystem; Command = [string]$step.Command
                        Database = [string]$step.Database
                        OnSuccessAction = [int]$step.OnSuccessAction; OnSuccessStepId = [int]$step.OnSuccessStepId
                        OnFailAction = [int]$step.OnFailAction; OnFailStepId = [int]$step.OnFailStepId
                        RetryAttempts = [int]$step.RetryAttempts; RetryInterval = [int]$step.RetryInterval
                        OutputFile = [string]$step.OutputFile; Flags = [int]$step.Flags; Proxy = [string]$step.Proxy
                    }
                })
            $schedules = @(foreach ($schedule in @($job.Schedules | Where-Object { $_ } | Sort-Object -Property Name)) {
                    [ordered]@{
                        Name = [string]$schedule.Name; Enabled = [bool]$schedule.Enabled
                        FreqType = [int]$schedule.FreqType; FreqInterval = [int]$schedule.FreqInterval
                        FreqSubdayType = [int]$schedule.FreqSubdayType; FreqSubdayInterval = [int]$schedule.FreqSubdayInterval
                        FreqRelativeInterval = [int]$schedule.FreqRelativeInterval; FreqRecurrenceFactor = [int]$schedule.FreqRecurrenceFactor
                        ActiveStartDate = [int]$schedule.ActiveStartDate; ActiveEndDate = [int]$schedule.ActiveEndDate
                        ActiveStartTime = [int]$schedule.ActiveStartTime; ActiveEndTime = [int]$schedule.ActiveEndTime
                    }
                })
            [ordered]@{
                Name = [string]$job.Name; Enabled = [bool]$job.Enabled; Description = [string]$job.Description
                Category = [string]$job.Category; Owner = [string]$job.Owner; StartStepId = [int]$job.StartStepId
                NotifyLevelEventLog = [int]$job.NotifyLevelEventLog; NotifyLevelEmail = [int]$job.NotifyLevelEmail
                NotifyEmailOperator = [string]$job.NotifyEmailOperator; DeleteLevel = [int]$job.DeleteLevel
                Steps = $steps; Schedules = $schedules
            }
        })

    $alerts = @(foreach ($alert in @($Snapshot.Alerts | Where-Object { $_ } | Sort-Object -Property Name)) {
            $notifications = @(foreach ($notification in @($alert.Notifications | Where-Object { $_ } | Sort-Object -Property Operator)) {
                    [ordered]@{ Operator = [string]$notification.Operator; Method = [int]$notification.Method }
                })
            [ordered]@{
                Name = [string]$alert.Name; Enabled = [bool]$alert.Enabled; MessageId = [int]$alert.MessageId; Severity = [int]$alert.Severity
                DelayBetweenResponses = [int]$alert.DelayBetweenResponses; NotificationMessage = [string]$alert.NotificationMessage
                IncludeEventDescription = [int]$alert.IncludeEventDescription; Database = [string]$alert.Database
                EventDescriptionKeyword = [string]$alert.EventDescriptionKeyword; Job = [string]$alert.Job
                PerformanceCondition = [string]$alert.PerformanceCondition; Category = [string]$alert.Category
                Notifications = $notifications
            }
        })

    return [ordered]@{ Operators = $operators; Jobs = $jobs; Alerts = $alerts }
}

function Restore-GuestSqlAgent {
    <#
      Recreates the recorded operators, then the jobs, then the alerts and
      whom they notify, skipping any the instance already has by name. A job
      that cannot be created whole is removed again rather than left half
      made. Returns the guest's notes.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][object]$Agent
    )

    $agentJson = ConvertTo-Json -InputObject $Agent -Depth 10 -Compress
    return Invoke-GuestScript -VM $VM -Activity 'SQL Agent restore' -TimeoutMinutes 15 -ArgumentList @($VM.Runtime.SqlServer, $agentJson) -ScriptBlock {
        param($server, $agentJson)
        $ErrorActionPreference = 'Stop'
        $agent = $agentJson | ConvertFrom-Json
        $notes = @()
        $connection = Open-GuestSqlConnection -Server $server

        function Test-AgentObject {
            param([string]$Table, [string]$Name)
            return [int](Get-GuestSqlScalar -Connection $connection -Sql "SELECT COUNT(*) FROM msdb.dbo.$Table WHERE name = $(ConvertTo-SqlString -Text $Name)") -gt 0
        }
        function Initialize-AgentCategory {
            <# Creates a job, alert or operator category the new instance lacks. #>
            param([ValidateSet('JOB', 'ALERT', 'OPERATOR')][string]$Class, [string]$Name)
            if (-not $Name) { return }
            $classId = @{ JOB = 1; ALERT = 2; OPERATOR = 3 }[$Class]
            $exists = [int](Get-GuestSqlScalar -Connection $connection -Sql "SELECT COUNT(*) FROM msdb.dbo.syscategories WHERE category_class = $classId AND name = $(ConvertTo-SqlString -Text $Name)") -gt 0
            if (-not $exists) {
                $type = if ($Class -eq 'JOB') { 'LOCAL' } else { 'NONE' }
                $null = Invoke-GuestSqlProcedure -Connection $connection -Name 'msdb.dbo.sp_add_category' -Parameter @{ class = $Class; type = $type; name = $Name }
            }
        }

        try {
            $added = @{ Operators = 0; Jobs = 0; Alerts = 0 }

            foreach ($operator in @($agent.Operators)) {
                if (-not $operator -or (Test-AgentObject -Table 'sysoperators' -Name $operator.Name)) { continue }
                try {
                    Initialize-AgentCategory -Class OPERATOR -Name $operator.Category
                    $parameters = @{ name = $operator.Name; enabled = [int]$operator.Enabled }
                    if ($operator.EmailAddress) { $parameters.email_address = $operator.EmailAddress }
                    if ($operator.Category) { $parameters.category_name = $operator.Category }
                    $null = Invoke-GuestSqlProcedure -Connection $connection -Name 'msdb.dbo.sp_add_operator' -Parameter $parameters
                    $added.Operators++
                }
                catch { $notes += New-GuestNote -Level WARN -Text "SQL Agent operator '$($operator.Name)' failed: $($_.Exception.Message)" }
            }

            foreach ($job in @($agent.Jobs)) {
                if (-not $job -or (Test-AgentObject -Table 'sysjobs' -Name $job.Name)) { continue }
                try {
                    Initialize-AgentCategory -Class JOB -Name $job.Category
                    $parameters = @{
                        job_name = $job.Name; enabled = [int]$job.Enabled; description = $job.Description
                        notify_level_eventlog = $job.NotifyLevelEventLog; notify_level_email = $job.NotifyLevelEmail; delete_level = $job.DeleteLevel
                    }
                    if ($job.Category) { $parameters.category_name = $job.Category }
                    # An owner whose login did not come back leaves the job to whoever restores it.
                    if ($job.Owner) {
                        $ownerSid = Get-GuestSqlScalar -Connection $connection -Sql "SELECT SUSER_SID($(ConvertTo-SqlString -Text $job.Owner))"
                        if ($null -ne $ownerSid -and $ownerSid -isnot [DBNull]) { $parameters.owner_login_name = $job.Owner }
                        else { $notes += New-GuestNote -Level WARN -Text "SQL Agent job '$($job.Name)': its owner '$($job.Owner)' has no login, so it was given to the account restoring it" }
                    }
                    if ($job.NotifyEmailOperator -and (Test-AgentObject -Table 'sysoperators' -Name $job.NotifyEmailOperator)) { $parameters.notify_email_operator_name = $job.NotifyEmailOperator }
                    else { $parameters.notify_level_email = 0 }
                    $null = Invoke-GuestSqlProcedure -Connection $connection -Name 'msdb.dbo.sp_add_job' -Parameter $parameters

                    try {
                        foreach ($step in @($job.Steps | Sort-Object -Property Id)) {
                            $stepParameters = @{
                                job_name = $job.Name; step_id = $step.Id; step_name = $step.Name; subsystem = $step.Subsystem; command = $step.Command
                                on_success_action = $step.OnSuccessAction; on_success_step_id = $step.OnSuccessStepId
                                on_fail_action = $step.OnFailAction; on_fail_step_id = $step.OnFailStepId
                                retry_attempts = $step.RetryAttempts; retry_interval = $step.RetryInterval; flags = $step.Flags
                            }
                            if ($step.Database) { $stepParameters.database_name = $step.Database }
                            if ($step.OutputFile) { $stepParameters.output_file_name = $step.OutputFile }
                            if ($step.Proxy) { $stepParameters.proxy_name = $step.Proxy }
                            $null = Invoke-GuestSqlProcedure -Connection $connection -Name 'msdb.dbo.sp_add_jobstep' -Parameter $stepParameters
                        }
                        if (@($job.Steps).Count -gt 0) {
                            $null = Invoke-GuestSqlProcedure -Connection $connection -Name 'msdb.dbo.sp_update_job' -Parameter @{ job_name = $job.Name; start_step_id = $job.StartStepId }
                        }
                        foreach ($schedule in @($job.Schedules)) {
                            $null = Invoke-GuestSqlProcedure -Connection $connection -Name 'msdb.dbo.sp_add_jobschedule' -Parameter @{
                                job_name = $job.Name; name = $schedule.Name; enabled = [int]$schedule.Enabled
                                freq_type = $schedule.FreqType; freq_interval = $schedule.FreqInterval
                                freq_subday_type = $schedule.FreqSubdayType; freq_subday_interval = $schedule.FreqSubdayInterval
                                freq_relative_interval = $schedule.FreqRelativeInterval; freq_recurrence_factor = $schedule.FreqRecurrenceFactor
                                active_start_date = $schedule.ActiveStartDate; active_end_date = $schedule.ActiveEndDate
                                active_start_time = $schedule.ActiveStartTime; active_end_time = $schedule.ActiveEndTime
                            }
                        }
                        $null = Invoke-GuestSqlProcedure -Connection $connection -Name 'msdb.dbo.sp_add_jobserver' -Parameter @{ job_name = $job.Name; server_name = '(local)' }
                    }
                    catch {
                        # Half a job could run without the steps that make it safe.
                        $failure = $_
                        try { $null = Invoke-GuestSqlProcedure -Connection $connection -Name 'msdb.dbo.sp_delete_job' -Parameter @{ job_name = $job.Name } } catch { $null = $_ }
                        throw $failure
                    }
                    $added.Jobs++
                }
                catch { $notes += New-GuestNote -Level WARN -Text "SQL Agent job '$($job.Name)' failed: $($_.Exception.Message)" }
            }

            foreach ($alert in @($agent.Alerts)) {
                if (-not $alert -or (Test-AgentObject -Table 'sysalerts' -Name $alert.Name)) { continue }
                try {
                    Initialize-AgentCategory -Class ALERT -Name $alert.Category
                    $parameters = @{
                        name = $alert.Name; enabled = [int]$alert.Enabled; message_id = $alert.MessageId; severity = $alert.Severity
                        delay_between_responses = $alert.DelayBetweenResponses; include_event_description_in = $alert.IncludeEventDescription
                    }
                    foreach ($pair in @(
                            @{ Key = 'notification_message'; Value = $alert.NotificationMessage }
                            @{ Key = 'database_name'; Value = $alert.Database }
                            @{ Key = 'event_description_keyword'; Value = $alert.EventDescriptionKeyword }
                            @{ Key = 'performance_condition'; Value = $alert.PerformanceCondition }
                            @{ Key = 'category_name'; Value = $alert.Category })) {
                        if ($pair.Value) { $parameters[$pair.Key] = $pair.Value }
                    }
                    if ($alert.Job -and (Test-AgentObject -Table 'sysjobs' -Name $alert.Job)) { $parameters.job_name = $alert.Job }
                    $null = Invoke-GuestSqlProcedure -Connection $connection -Name 'msdb.dbo.sp_add_alert' -Parameter $parameters
                    foreach ($notification in @($alert.Notifications | Where-Object { $_ -and (Test-AgentObject -Table 'sysoperators' -Name $_.Operator) })) {
                        $null = Invoke-GuestSqlProcedure -Connection $connection -Name 'msdb.dbo.sp_add_notification' -Parameter @{ alert_name = $alert.Name; operator_name = $notification.Operator; notification_method = $notification.Method }
                    }
                    $added.Alerts++
                }
                catch { $notes += New-GuestNote -Level WARN -Text "SQL Agent alert '$($alert.Name)' failed: $($_.Exception.Message)" }
            }

            if (($added.Operators + $added.Jobs + $added.Alerts) -gt 0) {
                $notes += New-GuestNote -Level OK -Text "recreated $($added.Jobs) SQL Agent job(s), $($added.Operators) operator(s) and $($added.Alerts) alert(s)"
            }
        }
        finally { $connection.Close() }
        return $notes
    }
}
