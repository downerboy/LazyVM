using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>
/// A command runner that answers from memory instead of PowerShell. Each
/// command has its own queue of answers, and each call's parameters are kept.
/// </summary>
internal sealed class FakeCommandRunner : PowerShellCommandRunner
{
    private readonly Answers<LazyVMDashboard> _Dashboards = new();
    private readonly Answers<VMCheck> _Checks = new();
    private readonly Answers<VMLogEntry> _Logs = new();

    public int DashboardCalls
    {
        get; private set;
    }

    public List<(string? Name, bool HostOnly)> CheckCalls { get; } = [];

    public List<(string Name, int Tail)> LogCalls { get; } = [];

    public void Returns(params LazyVMDashboard[] entries)
    {
        _Dashboards.Returns(entries);
    }

    public void Throws(Exception exception)
    {
        _Dashboards.Throws(exception);
    }

    /// <summary>The next call waits until it is cancelled.</summary>
    public void WaitsForCancel()
    {
        _Dashboards.WaitsForCancel();
    }

    public void ReturnsChecks(params VMCheck[] results)
    {
        _Checks.Returns(results);
    }

    public void ChecksThrow(Exception exception)
    {
        _Checks.Throws(exception);
    }

    public void ChecksWaitForCancel()
    {
        _Checks.WaitsForCancel();
    }

    public void ReturnsLog(params VMLogEntry[] entries)
    {
        _Logs.Returns(entries);
    }

    public void LogThrows(Exception exception)
    {
        _Logs.Throws(exception);
    }

    public override Task<IReadOnlyList<LazyVMDashboard>> GetLazyVMDashboardAsync(CancellationToken cancellationToken)
    {
        DashboardCalls++;
        return _Dashboards.Next(cancellationToken);
    }

    public override Task<IReadOnlyList<VMCheck>> GetLazyVMChecksAsync(string? name, bool hostOnly, CancellationToken cancellationToken)
    {
        CheckCalls.Add((name, hostOnly));
        return _Checks.Next(cancellationToken);
    }

    public override Task<IReadOnlyList<VMLogEntry>> GetLazyVMLogAsync(string name, int tail, CancellationToken cancellationToken)
    {
        LogCalls.Add((name, tail));
        return _Logs.Next(cancellationToken);
    }

    private readonly Answers<LazyVMDashboard> _VMs = new();
    private readonly Answers<VMRun> _Stops = new();

    public IReadOnlyList<BuildPhase> Phases
    {
        get; set;
    } =
    [
        new(0, "HyperVHealth", "Check Hyper-V is working"),
        new(1, "Readiness", "Check the host is ready"),
        new(7, "Windows", "Install Windows and the tools"),
        new(8, "Finish", "Finish SQL Server and Visual Studio"),
    ];

    public IReadOnlyList<ConfigTemplate> Templates
    {
        get; set;
    } =
    [
        new("DevBox-latest", BuiltIn: false, Automatic: true),
        new("Developer", BuiltIn: true, Automatic: false),
        new("PlainWindows", BuiltIn: true, Automatic: false),
    ];

    public Exception? TemplatesFail
    {
        get; set;
    }

    public Exception? ModuleFolderFails
    {
        get; set;
    }

    public List<string> VMCalls { get; } = [];

    public List<string> StopCalls { get; } = [];

    /// <summary>The next Get-LazyVMDashboard -Name finds the VM with this run.</summary>
    public void ReturnsRun(VMRun? run, string name = "DevBox")
    {
        _VMs.Returns([Sample.VM(name) with { Run = run }]);
    }

    public void VMThrows(Exception exception)
    {
        _VMs.Throws(exception);
    }

    /// <summary>The next Stop-LazyVMBuild returns this run.</summary>
    public void StopReturns(VMRun? run)
    {
        _Stops.Returns(run is null ? [] : [run]);
    }

    public void StopThrows(Exception exception)
    {
        _Stops.Throws(exception);
    }

    public override async Task<LazyVMDashboard?> GetLazyVMAsync(string name, CancellationToken cancellationToken)
    {
        VMCalls.Add(name);
        return (await _VMs.Next(cancellationToken)).FirstOrDefault();
    }

    public override Task<IReadOnlyList<BuildPhase>> GetLazyVMBuildPhasesAsync(CancellationToken cancellationToken)
    {
        return PhasesFail is { } failure ? Task.FromException<IReadOnlyList<BuildPhase>>(failure) : Task.FromResult(Phases);
    }

    public override Task<IReadOnlyList<ConfigTemplate>> GetLazyVMConfigTemplatesAsync(CancellationToken cancellationToken)
    {
        return TemplatesFail is { } failure ? Task.FromException<IReadOnlyList<ConfigTemplate>>(failure) : Task.FromResult(Templates);
    }

    public override async Task<VMRun?> StopLazyVMBuildAsync(string name, CancellationToken cancellationToken)
    {
        StopCalls.Add(name);
        return (await _Stops.Next(cancellationToken)).FirstOrDefault();
    }

    public List<string> MaintenanceCalls { get; } = [];

    /// <summary>Start-LazyVMMaintenance fails with this, as the module does when it starts nothing.</summary>
    public Exception? MaintenanceFails
    {
        get; set;
    }

    public Exception? PhasesFail
    {
        get; set;
    }

    public override Task StartLazyVMMaintenanceAsync(string name, CancellationToken cancellationToken)
    {
        MaintenanceCalls.Add(name);
        return MaintenanceFails is { } failure ? Task.FromException(failure) : Task.CompletedTask;
    }

    public List<HelpTopic> HelpCalls { get; } = [];

    /// <summary>Show-LazyVMHelp fails with this, as it does when no browser opens.</summary>
    public Exception? HelpFails
    {
        get; set;
    }

    public override Task ShowLazyVMHelpAsync(HelpTopic topic, CancellationToken cancellationToken)
    {
        HelpCalls.Add(topic);
        return HelpFails is { } failure ? Task.FromException(failure) : Task.CompletedTask;
    }

    private readonly Answers<RemovalPlan> _RemovalPlans = new();

    public List<string> RemovalPlanCalls { get; } = [];

    public List<string> RemoveCalls { get; } = [];

    /// <summary>Remove-LazyVM fails with this, as the module does for a partial removal.</summary>
    public Exception? RemoveFails
    {
        get; set;
    }

    /// <summary>When set, Remove-LazyVM runs until the test completes it.</summary>
    public TaskCompletionSource? RemoveGate
    {
        get; set;
    }

    /// <summary>The next Get-LazyVMRemovalPlan returns this plan.</summary>
    public void ReturnsRemovalPlan(RemovalPlan plan)
    {
        _RemovalPlans.Returns([plan]);
    }

    public void RemovalPlanThrows(Exception exception)
    {
        _RemovalPlans.Throws(exception);
    }

    public override async Task<RemovalPlan> GetLazyVMRemovalPlanAsync(string name, CancellationToken cancellationToken)
    {
        RemovalPlanCalls.Add(name);
        return (await _RemovalPlans.Next(cancellationToken))[0];
    }

    public override async Task RemoveLazyVMAsync(string name)
    {
        RemoveCalls.Add(name);
        if (RemoveGate is { } gate)
        {
            await gate.Task;
        }
        if (RemoveFails is { } failure)
        {
            throw failure;
        }
    }

    private readonly Answers<VMRestorePoint> _RestorePoints = new();

    public List<string> RestorePointCalls { get; } = [];

    public List<(string Name, string Stamp)> RestoreCalls { get; } = [];

    /// <summary>Restore-LazyVMTooling fails with this.</summary>
    public Exception? RestoreFails
    {
        get; set;
    }

    /// <summary>When set, Restore-LazyVMTooling runs until the test completes it.</summary>
    public TaskCompletionSource? RestoreGate
    {
        get; set;
    }

    /// <summary>The next Get-LazyVMRestorePoint returns these points, oldest first as the module does.</summary>
    public void ReturnsRestorePoints(params VMRestorePoint[] points)
    {
        _RestorePoints.Returns(points);
    }

    public void RestorePointsThrow(Exception exception)
    {
        _RestorePoints.Throws(exception);
    }

    public override Task<IReadOnlyList<VMRestorePoint>> GetLazyVMRestorePointsAsync(string name, CancellationToken cancellationToken)
    {
        RestorePointCalls.Add(name);
        return _RestorePoints.Next(cancellationToken);
    }

    public override async Task RestoreLazyVMToolingAsync(string name, string stamp)
    {
        RestoreCalls.Add((name, stamp));
        if (RestoreGate is { } gate)
        {
            await gate.Task;
        }
        if (RestoreFails is { } failure)
        {
            throw failure;
        }
    }

    private readonly Answers<VMRecoveryKey> _RecoveryKeys = new();

    public List<string> RecoveryKeyCalls { get; } = [];

    /// <summary>The recovery password Get-LazyVMCredential -RecoveryPassword gives for each disk GUID.</summary>
    public Dictionary<string, string> RecoveryPasswords { get; } = new(StringComparer.OrdinalIgnoreCase);

    public List<(string Name, string DiskGuid)> RecoveryPasswordCalls { get; } = [];

    /// <summary>Get-LazyVMCredential -RecoveryPassword fails with this.</summary>
    public Exception? RecoveryPasswordFails
    {
        get; set;
    }

    public List<(string Name, string Path, bool Force)> ExportCalls { get; } = [];

    /// <summary>Export-LazyVMRecoveryKey fails with this.</summary>
    public Exception? ExportFails
    {
        get; set;
    }

    /// <summary>The warnings Export-LazyVMRecoveryKey writes.</summary>
    public IReadOnlyList<string> ExportWarnings { get; set; } = [];

    /// <summary>The next Get-LazyVMRecoveryKey returns these keys.</summary>
    public void ReturnsRecoveryKeys(params VMRecoveryKey[] keys)
    {
        _RecoveryKeys.Returns(keys);
    }

    public void RecoveryKeysThrow(Exception exception)
    {
        _RecoveryKeys.Throws(exception);
    }

    public override Task<IReadOnlyList<VMRecoveryKey>> GetLazyVMRecoveryKeysAsync(string name, CancellationToken cancellationToken)
    {
        RecoveryKeyCalls.Add(name);
        return _RecoveryKeys.Next(cancellationToken);
    }

    public override Task<string> GetLazyVMRecoveryPasswordAsync(string name, string diskGuid, CancellationToken cancellationToken)
    {
        RecoveryPasswordCalls.Add((name, diskGuid));
        return RecoveryPasswordFails is { } failure ? Task.FromException<string>(failure) : Task.FromResult(RecoveryPasswords[diskGuid]);
    }

    public override Task<RecoveryKeyExport> ExportLazyVMRecoveryKeysAsync(string name, string path, bool force)
    {
        ExportCalls.Add((name, path, force));
        return ExportFails is { } failure
            ? Task.FromException<RecoveryKeyExport>(failure)
            : Task.FromResult(new RecoveryKeyExport(path, ExportWarnings));
    }

    private readonly Answers<VMSecurityFinding> _SecurityFindings = new();
    private readonly Answers<VMSecurityApproval> _SecurityApprovals = new();

    public List<string> SecurityFindingCalls { get; } = [];

    public List<string> SecurityApprovalCalls { get; } = [];

    /// <summary>The next Get-LazyVMSecurityFinding returns these findings.</summary>
    public void ReturnsSecurityFindings(params VMSecurityFinding[] findings)
    {
        _SecurityFindings.Returns(findings);
    }

    public void SecurityFindingsThrow(Exception exception)
    {
        _SecurityFindings.Throws(exception);
    }

    /// <summary>The next Get-LazyVMSecurityFinding -Approved returns these approvals.</summary>
    public void ReturnsSecurityApprovals(params VMSecurityApproval[] approvals)
    {
        _SecurityApprovals.Returns(approvals);
    }

    public void SecurityApprovalsThrow(Exception exception)
    {
        _SecurityApprovals.Throws(exception);
    }

    public override Task<IReadOnlyList<VMSecurityFinding>> GetLazyVMSecurityFindingsAsync(string name, CancellationToken cancellationToken)
    {
        SecurityFindingCalls.Add(name);
        return _SecurityFindings.Next(cancellationToken);
    }

    public override Task<IReadOnlyList<VMSecurityApproval>> GetLazyVMSecurityApprovalsAsync(string name, CancellationToken cancellationToken)
    {
        SecurityApprovalCalls.Add(name);
        return _SecurityApprovals.Next(cancellationToken);
    }

    public List<(string Name, string Id, string Reason)> ApproveCalls { get; } = [];

    public List<(string Name, string Id)> RevokeCalls { get; } = [];

    /// <summary>Approve-LazyVMSecurityFinding fails with this, as a refused Id does.</summary>
    public Exception? ApproveFails
    {
        get; set;
    }

    /// <summary>Revoke-LazyVMSecurityFinding fails with this, as a refused Id does.</summary>
    public Exception? RevokeFails
    {
        get; set;
    }

    /// <summary>When set, Approve-LazyVMSecurityFinding runs until the test completes it.</summary>
    public TaskCompletionSource? ApproveGate
    {
        get; set;
    }

    public override async Task ApproveLazyVMSecurityFindingAsync(string name, string id, string reason)
    {
        ApproveCalls.Add((name, id, reason));
        if (ApproveGate is { } gate)
        {
            await gate.Task;
        }
        if (ApproveFails is { } failure)
        {
            throw failure;
        }
    }

    public override Task RevokeLazyVMSecurityFindingAsync(string name, string id)
    {
        RevokeCalls.Add((name, id));
        return RevokeFails is { } failure ? Task.FromException(failure) : Task.CompletedTask;
    }

    /// <summary>The user name Get-LazyVMCredential gives; empty for a VM with no credential stored, which fails as the module does.</summary>
    public string? UserName { get; set; } = "devadmin";

    /// <summary>The password Get-LazyVMCredential -AsPlainText gives.</summary>
    public string Password { get; set; } = "Correct-Horse-9";

    /// <summary>Get-LazyVMCredential -AsPlainText fails with this.</summary>
    public Exception? PasswordFails
    {
        get; set;
    }

    public List<string> UserNameCalls { get; } = [];

    public List<string> PasswordCalls { get; } = [];

    public override Task<string> GetLazyVMUserNameAsync(string name, CancellationToken cancellationToken)
    {
        UserNameCalls.Add(name);
        return UserName is { } userName
            ? Task.FromResult(userName)
            : Task.FromException<string>(new InvalidOperationException(
                $"No credential is stored for '{name}' yet. Build-LazyVM creates one, or store one with: Set-LazyVMCredential -Name {name}"));
    }

    public override Task<string> GetLazyVMPasswordAsync(string name, CancellationToken cancellationToken)
    {
        PasswordCalls.Add(name);
        return PasswordFails is { } failure ? Task.FromException<string>(failure) : Task.FromResult(Password);
    }

    public override Task<string> GetModuleFolderAsync(CancellationToken cancellationToken)
    {
        return ModuleFolderFails is { } failure ? Task.FromException<string>(failure) : Task.FromResult(@"C:\Program Files\LazyVM\Modules\LazyVM\6.20.0");
    }

    private sealed class Answers<T>
    {
        private readonly Queue<Func<CancellationToken, Task<IReadOnlyList<T>>>> _Queue = new();

        public void Returns(T[] values)
        {
            _Queue.Enqueue(_ => Task.FromResult<IReadOnlyList<T>>(values));
        }

        public void Throws(Exception exception)
        {
            _Queue.Enqueue(_ => Task.FromException<IReadOnlyList<T>>(exception));
        }

        public void WaitsForCancel()
        {
            _Queue.Enqueue(async token =>
            {
                await Task.Delay(Timeout.Infinite, token);
                return [];
            });
        }

        public Task<IReadOnlyList<T>> Next(CancellationToken cancellationToken)
        {
            return _Queue.Dequeue()(cancellationToken);
        }
    }
}
