namespace LazyVM.UI.Wpf;

/// <summary>
/// A finding approved with <c>Approve-LazyVMSecurityFinding</c>, as
/// <c>Get-LazyVMSecurityFinding -Approved</c> lists it: its Id, severity and
/// title, when it was approved and why.
/// </summary>
public sealed record VMSecurityApproval(string Id, string Severity, string Title, DateTime? ApprovedOn, string Reason);
