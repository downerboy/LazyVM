namespace LazyVM.UI;

/// <summary>
/// The app's runners, one per area of the module, all on the same
/// sessions. <see cref="ToolWindows"/> takes them all, to make the view
/// model of each window it opens; each view model takes only the runners
/// it uses.
/// </summary>
public sealed record Runners(
    LazyVMDashboardRunner Dashboard,
    LazyVMBuildRunner Build,
    LazyVMRemovalRunner Removal,
    LazyVMRestoreRunner Restore,
    LazyVMRecoveryKeysRunner RecoveryKeys,
    LazyVMCredentialsRunner Credentials,
    LazyVMSecurityFindingsRunner SecurityFindings,
    LazyVMChecksRunner Checks,
    LazyVMLogRunner Log,
    LazyVMHelpRunner Help)
{
    /// <summary>Every runner, on <paramref name="sessions"/>.</summary>
    public static Runners On(PowerShellSessionFactory sessions)
    {
        return new(
            new LazyVMDashboardRunner(sessions),
            new LazyVMBuildRunner(sessions),
            new LazyVMRemovalRunner(sessions),
            new LazyVMRestoreRunner(sessions),
            new LazyVMRecoveryKeysRunner(sessions),
            new LazyVMCredentialsRunner(sessions),
            new LazyVMSecurityFindingsRunner(sessions),
            new LazyVMChecksRunner(sessions),
            new LazyVMLogRunner(sessions),
            new LazyVMHelpRunner(sessions));
    }
}
