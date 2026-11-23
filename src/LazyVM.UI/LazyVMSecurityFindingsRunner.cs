using System.Management.Automation;

namespace LazyVM.UI;

/// <summary>Runs the module's commands about a VM's security findings: listing them and the approved ones, approving and revoking.</summary>
public class LazyVMSecurityFindingsRunner(PowerShellSessionFactory sessions) : PowerShellCommandRunner(sessions)
{
    /// <summary>
    /// Runs <c>Get-LazyVMSecurityFinding -Name</c> in the VM's session: the
    /// last scan's findings, less the approved ones. None before the first
    /// scan, and none when it found nothing: the module tells those apart only
    /// in a warning, so the window tells them apart by the dashboard's
    /// <c>LastSecurityScan</c>.
    /// </summary>
    public virtual async Task<IReadOnlyList<VMSecurityFinding>> GetLazyVMSecurityFindingsAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(SessionFor(vmId), "Get-LazyVMSecurityFinding", [("Name", name)], cancellationToken, failsOnlyByThrowing: true)
            .ConfigureAwait(false);
        return output.Select(LazyVMSecurityFinding).ToList();
    }

    /// <summary>
    /// Runs <c>Get-LazyVMSecurityFinding -Name -Approved</c> in the VM's
    /// session: the approved findings, with when and why. None while none is
    /// approved.
    /// </summary>
    public virtual async Task<IReadOnlyList<VMSecurityApproval>> GetLazyVMSecurityApprovalsAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(
            SessionFor(vmId), "Get-LazyVMSecurityFinding", [("Name", name), ("Approved", true)], cancellationToken, failsOnlyByThrowing: true)
            .ConfigureAwait(false);
        return output.Select(LazyVMSecurityApproval).ToList();
    }

    /// <summary>
    /// Runs <c>Approve-LazyVMSecurityFinding -Name -Id -Reason -Confirm:$false</c>
    /// in the VM's session, without the question the app has already asked.
    /// Throws with the module's reason when it refused the Id, such as a
    /// finding no longer open.
    /// </summary>
    public virtual async Task ApproveLazyVMSecurityFindingAsync(Guid? vmId, string name, string id, string reason)
    {
        await InvokeAsync(
            SessionFor(vmId), "Approve-LazyVMSecurityFinding", [("Name", name), ("Id", id), ("Reason", reason), ("Confirm", false)], CancellationToken.None,
            failsOnlyByThrowing: true, failsByItsOwnErrors: true)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// Runs <c>Revoke-LazyVMSecurityFinding -Name -Id -Confirm:$false</c> in
    /// the VM's session, without the question the app has already asked.
    /// Throws with the module's reason when it refused the Id, such as one
    /// not approved.
    /// </summary>
    public virtual async Task RevokeLazyVMSecurityFindingAsync(Guid? vmId, string name, string id)
    {
        await InvokeAsync(
            SessionFor(vmId), "Revoke-LazyVMSecurityFinding", [("Name", name), ("Id", id), ("Confirm", false)], CancellationToken.None,
            failsOnlyByThrowing: true, failsByItsOwnErrors: true)
            .ConfigureAwait(false);
    }

    /// <summary>Reads one <c>LazyVM.SecurityFinding</c> object. A time that cannot be read is left empty.</summary>
    internal static VMSecurityFinding LazyVMSecurityFinding(PSObject finding)
    {
        return new(
            finding.PropertyText("Id"),
            finding.PropertyText("Severity"),
            finding.PropertyText("Title"),
            finding.PropertyText("WhatWeFound"),
            finding.ReadList("Where").Select(file => file.BaseObject.ToString() ?? string.Empty).Where(file => file.Length > 0).ToList(),
            finding.PropertyText("WhyItMatters"),
            finding.PropertyText("HowToFix"),
            finding.ReadDate("FirstSeen", "FirstSeen", []),
            finding.PropertyText("Status"));
    }

    /// <summary>Reads one <c>LazyVM.SecurityApproval</c> object. A time that cannot be read is left empty.</summary>
    internal static VMSecurityApproval LazyVMSecurityApproval(PSObject approval)
    {
        return new(
            approval.PropertyText("Id"),
            approval.PropertyText("Severity"),
            approval.PropertyText("Title"),
            approval.ReadDate("ApprovedOn", "ApprovedOn", []),
            approval.PropertyText("Reason"));
    }
}
