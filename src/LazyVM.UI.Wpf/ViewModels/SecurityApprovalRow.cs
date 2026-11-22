namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>One approved finding in the Security findings window: its severity and title, when it was approved, and why.</summary>
public sealed class SecurityApprovalRow(VMSecurityApproval approval)
{
    public VMSecurityApproval Approval { get; } = approval;

    /// <summary>Such as "Medium severity, Remote Desktop is on, approved 10 November 2026 09:15. Why: I connect to it."</summary>
    public string Text
    {
        get
        {
            var when = Approval.ApprovedOn is { } approvedOn
                ? "approved " + DashboardText.When(approvedOn)
                : "approved, when is not known";
            var why = Approval.Reason.Length > 0 ? $"Why: {Approval.Reason}" : "No reason was given.";
            return $"{SecurityFindingRow.InWords(Approval.Severity)}, {Approval.Title}, {when}. {why}";
        }
    }

    public override string ToString()
    {
        return Text;
    }
}
