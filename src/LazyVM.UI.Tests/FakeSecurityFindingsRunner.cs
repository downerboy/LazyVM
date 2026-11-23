namespace LazyVM.UI.Tests;

/// <summary>The security findings commands, answered from memory: findings, approvals, approving and revoking.</summary>
internal sealed class FakeSecurityFindingsRunner() : LazyVMSecurityFindingsRunner(UnusedSessions.Factory)
{
    private readonly Answers<VMSecurityFinding> _SecurityFindings = new();
    private readonly Answers<VMSecurityApproval> _SecurityApprovals = new();

    public List<string> SecurityFindingCalls { get; } = [];

    public List<string> SecurityApprovalCalls { get; } = [];

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

    public override Task<IReadOnlyList<VMSecurityFinding>> GetLazyVMSecurityFindingsAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        SecurityFindingCalls.Add(name);
        return _SecurityFindings.Next(cancellationToken);
    }

    public override Task<IReadOnlyList<VMSecurityApproval>> GetLazyVMSecurityApprovalsAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        SecurityApprovalCalls.Add(name);
        return _SecurityApprovals.Next(cancellationToken);
    }

    public override async Task ApproveLazyVMSecurityFindingAsync(Guid? vmId, string name, string id, string reason)
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

    public override Task RevokeLazyVMSecurityFindingAsync(Guid? vmId, string name, string id)
    {
        RevokeCalls.Add((name, id));
        return RevokeFails is { } failure ? Task.FromException(failure) : Task.CompletedTask;
    }
}
