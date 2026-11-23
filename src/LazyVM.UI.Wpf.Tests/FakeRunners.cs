namespace LazyVM.UI.Wpf.Tests;

/// <summary>One fake of each runner, for the windows a test opens, and all of them as the app's <see cref="Wpf.Runners"/>.</summary>
internal sealed class FakeRunners
{
    public FakeDashboardRunner Dashboard { get; } = new();

    public FakeBuildRunner Build { get; } = new();

    public FakeRemovalRunner Removal { get; } = new();

    public FakeRestoreRunner Restore { get; } = new();

    public FakeRecoveryKeysRunner RecoveryKeys { get; } = new();

    public FakeCredentialsRunner Credentials { get; } = new();

    public FakeSecurityFindingsRunner SecurityFindings { get; } = new();

    public FakeChecksRunner Checks { get; } = new();

    public FakeLogRunner Log { get; } = new();

    public FakeHelpRunner Help { get; } = new();

    public Runners Runners => new(Dashboard, Build, Removal, Restore, RecoveryKeys, Credentials, SecurityFindings, Checks, Log, Help);
}
