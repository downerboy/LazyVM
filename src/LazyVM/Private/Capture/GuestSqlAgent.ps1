# GuestSqlAgent.ps1 - The guest's SQL Agent operators, alerts and jobs, recorded in VM.json.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# They live in msdb, which a rebuild makes fresh, so they are recorded in
# VM.json's GuestSqlAgent (#131) on every maintenance run and every capture,
# whenever they changed. A job keeps its steps and schedules; an alert keeps
# the operators it notifies. Proxies are not kept, since the credentials
# they use are not migrated either.

function Get-GuestSqlAgentSnapshot {
    <#
      Reads msdb's operators, alerts and their notifications, and local jobs
      with their steps and schedules, from the instance
      Connect-GuestSqlInstance found. Each step and schedule carries its
      job's JobId, for ConvertTo-GuestSqlAgentRecord to group them.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    return Invoke-GuestScript -VM $VM -Activity 'SQL Agent check' -TimeoutMinutes 10 -ArgumentList @($VM.Runtime.SqlServer) -ScriptBlock {
        param($server)
        $ErrorActionPreference = 'Stop'
        $connection = Open-GuestSqlConnection -Server $server
        try {
            return [pscustomobject]@{
                Operators     = @(Get-GuestSqlRow -Connection $connection -Sql @'
SELECT name AS Name, CAST(enabled AS bit) AS Enabled,
       ISNULL(email_address, '') AS EmailAddress, ISNULL(pager_address, '') AS PagerAddress
FROM msdb.dbo.sysoperators
'@)
                Alerts        = @(Get-GuestSqlRow -Connection $connection -Sql @'
SELECT a.name AS Name, CAST(a.enabled AS bit) AS Enabled, a.message_id AS MessageId, a.severity AS Severity,
       ISNULL(a.database_name, '') AS DatabaseName, ISNULL(a.event_description_keyword, '') AS EventDescriptionKeyword,
       ISNULL(a.performance_condition, '') AS PerformanceCondition, a.delay_between_responses AS DelayBetweenResponses,
       a.include_event_description AS IncludeEventDescription, ISNULL(j.name, '') AS JobName
FROM msdb.dbo.sysalerts a
LEFT JOIN msdb.dbo.sysjobs j ON j.job_id = a.job_id
'@)
                Notifications = @(Get-GuestSqlRow -Connection $connection -Sql @'
SELECT a.name AS AlertName, o.name AS OperatorName, n.notification_method AS Method
FROM msdb.dbo.sysnotifications n
JOIN msdb.dbo.sysalerts a ON a.id = n.alert_id
JOIN msdb.dbo.sysoperators o ON o.id = n.operator_id
'@)
                Jobs          = @(Get-GuestSqlRow -Connection $connection -Sql @'
SELECT CONVERT(varchar(36), j.job_id) AS JobId, j.name AS Name, CAST(j.enabled AS bit) AS Enabled,
       ISNULL(j.description, '') AS Description, ISNULL(c.name, '') AS CategoryName,
       ISNULL(SUSER_SNAME(j.owner_sid), '') AS OwnerLogin, j.start_step_id AS StartStepId,
       j.notify_level_eventlog AS NotifyLevelEventlog, j.notify_level_email AS NotifyLevelEmail,
       ISNULL(o.name, '') AS NotifyEmailOperator
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
LEFT JOIN msdb.dbo.sysoperators o ON o.id = j.notify_email_operator_id
WHERE j.originating_server_id = 0
'@)
                Steps         = @(Get-GuestSqlRow -Connection $connection -Sql @'
SELECT CONVERT(varchar(36), job_id) AS JobId, step_id AS StepId, step_name AS Name, subsystem AS Subsystem,
       ISNULL(command, '') AS Command, ISNULL(database_name, '') AS DatabaseName,
       on_success_action AS OnSuccessAction, on_success_step_id AS OnSuccessStepId,
       on_fail_action AS OnFailAction, on_fail_step_id AS OnFailStepId,
       retry_attempts AS RetryAttempts, retry_interval AS RetryInterval, ISNULL(output_file_name, '') AS OutputFileName
FROM msdb.dbo.sysjobsteps
'@)
                Schedules     = @(Get-GuestSqlRow -Connection $connection -Sql @'
SELECT CONVERT(varchar(36), js.job_id) AS JobId, s.name AS Name, CAST(s.enabled AS bit) AS Enabled,
       s.freq_type AS FreqType, s.freq_interval AS FreqInterval, s.freq_subday_type AS FreqSubdayType,
       s.freq_subday_interval AS FreqSubdayInterval, s.freq_relative_interval AS FreqRelativeInterval,
       s.freq_recurrence_factor AS FreqRecurrenceFactor, s.active_start_date AS ActiveStartDate,
       s.active_end_date AS ActiveEndDate, s.active_start_time AS ActiveStartTime, s.active_end_time AS ActiveEndTime
FROM msdb.dbo.sysjobschedules js
JOIN msdb.dbo.sysschedules s ON s.schedule_id = js.schedule_id
'@)
            }
        }
        finally { $connection.Close() }
    }
}

function ConvertTo-GuestSqlAgentRecord {
    <#
      Turns what the guest reported ($Snapshot, from Get-GuestSqlAgentSnapshot)
      into VM.json's GuestSqlAgent: each job's steps (in step order) and
      schedules under it, each alert's notifications under it, everything
      else sorted by name so the same state always compares equal. The
      guest's job ids are dropped, since a new instance gives new ones.
    #>
    param([Parameter(Mandatory)][object]$Snapshot)

    $operators = @(foreach ($operator in @($Snapshot.Operators | Where-Object { $_ } | Sort-Object -Property Name)) {
            [ordered]@{
                Name         = [string]$operator.Name
                Enabled      = [bool]$operator.Enabled
                EmailAddress = [string]$operator.EmailAddress
                PagerAddress = [string]$operator.PagerAddress
            }
        })

    $notifications = @($Snapshot.Notifications | Where-Object { $_ })
    $alerts = @(foreach ($alert in @($Snapshot.Alerts | Where-Object { $_ } | Sort-Object -Property Name)) {
            [ordered]@{
                Name                    = [string]$alert.Name
                Enabled                 = [bool]$alert.Enabled
                MessageId               = [int]$alert.MessageId
                Severity                = [int]$alert.Severity
                DatabaseName            = [string]$alert.DatabaseName
                EventDescriptionKeyword = [string]$alert.EventDescriptionKeyword
                PerformanceCondition    = [string]$alert.PerformanceCondition
                DelayBetweenResponses   = [int]$alert.DelayBetweenResponses
                IncludeEventDescription = [int]$alert.IncludeEventDescription
                JobName                 = [string]$alert.JobName
                Notifications           = @(foreach ($notification in @($notifications | Where-Object { $_.AlertName -eq $alert.Name } | Sort-Object -Property OperatorName)) {
                        [ordered]@{ OperatorName = [string]$notification.OperatorName; Method = [int]$notification.Method }
                    })
            }
        })

    $steps = @($Snapshot.Steps | Where-Object { $_ })
    $schedules = @($Snapshot.Schedules | Where-Object { $_ })
    $jobs = @(foreach ($job in @($Snapshot.Jobs | Where-Object { $_ } | Sort-Object -Property Name)) {
            [ordered]@{
                Name                = [string]$job.Name
                Enabled             = [bool]$job.Enabled
                Description         = [string]$job.Description
                CategoryName        = [string]$job.CategoryName
                OwnerLogin          = [string]$job.OwnerLogin
                StartStepId         = [int]$job.StartStepId
                NotifyLevelEventlog = [int]$job.NotifyLevelEventlog
                NotifyLevelEmail    = [int]$job.NotifyLevelEmail
                NotifyEmailOperator = [string]$job.NotifyEmailOperator
                Steps               = @(foreach ($step in @($steps | Where-Object { $_.JobId -eq $job.JobId } | Sort-Object -Property { [int]$_.StepId })) {
                        [ordered]@{
                            StepId          = [int]$step.StepId
                            Name            = [string]$step.Name
                            Subsystem       = [string]$step.Subsystem
                            Command         = [string]$step.Command
                            DatabaseName    = [string]$step.DatabaseName
                            OnSuccessAction = [int]$step.OnSuccessAction
                            OnSuccessStepId = [int]$step.OnSuccessStepId
                            OnFailAction    = [int]$step.OnFailAction
                            OnFailStepId    = [int]$step.OnFailStepId
                            RetryAttempts   = [int]$step.RetryAttempts
                            RetryInterval   = [int]$step.RetryInterval
                            OutputFileName  = [string]$step.OutputFileName
                        }
                    })
                Schedules           = @(foreach ($schedule in @($schedules | Where-Object { $_.JobId -eq $job.JobId } | Sort-Object -Property Name)) {
                        [ordered]@{
                            Name                 = [string]$schedule.Name
                            Enabled              = [bool]$schedule.Enabled
                            FreqType             = [int]$schedule.FreqType
                            FreqInterval         = [int]$schedule.FreqInterval
                            FreqSubdayType       = [int]$schedule.FreqSubdayType
                            FreqSubdayInterval   = [int]$schedule.FreqSubdayInterval
                            FreqRelativeInterval = [int]$schedule.FreqRelativeInterval
                            FreqRecurrenceFactor = [int]$schedule.FreqRecurrenceFactor
                            ActiveStartDate      = [int]$schedule.ActiveStartDate
                            ActiveEndDate        = [int]$schedule.ActiveEndDate
                            ActiveStartTime      = [int]$schedule.ActiveStartTime
                            ActiveEndTime        = [int]$schedule.ActiveEndTime
                        }
                    })
            }
        })

    return [ordered]@{ Operators = $operators; Alerts = $alerts; Jobs = $jobs }
}

function Update-GuestSqlAgentRecord {
    <#
      Records the guest's SQL Agent operators, alerts and jobs as they are now
      in VM.json. A guest without SQL Server keeps what was recorded, so an
      install that failed cannot erase the jobs a rebuild needs. Writes
      nothing when nothing changed. Returns whether anything did.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][VMContext]$VM)

    if (-not (Connect-GuestSqlInstance -VM $VM)) {
        Write-LogEntry '  SQL Server is not installed - its Agent jobs were not recorded' 'INFO'
        return $false
    }
    $record = ConvertTo-GuestSqlAgentRecord -Snapshot (Get-GuestSqlAgentSnapshot -VM $VM)

    $change = @{ $script:GuestSqlAgentSettingName = $record }
    $changed = @(Update-VMProfile -Root $VM.Settings.Root -Name $VM.Name -Change $change -Reason 'guest SQL Agent jobs changed').Count -gt 0
    if ($changed) { Write-LogEntry "Guest SQL Agent recorded: $($record.Jobs.Count) job(s), $($record.Operators.Count) operator(s), $($record.Alerts.Count) alert(s)" 'OK' }
    return $changed
}

function Get-GuestSqlAgentRestore {
    <#
      What a restore puts back into the guest's SQL Agent: VM.json's
      GuestSqlAgent as the file holds it now, as Operators, Alerts and Jobs.
      $null when it was never recorded.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $current = Read-SettingsFile -Path (Get-VMProfilePath -Root $VM.Settings.Root -Name $VM.Name)
    $agent = $current[$script:GuestSqlAgentSettingName]
    if ($null -eq $agent) { return $null }
    return [pscustomobject]@{ Operators = @($agent.Operators); Alerts = @($agent.Alerts); Jobs = @($agent.Jobs) }
}
