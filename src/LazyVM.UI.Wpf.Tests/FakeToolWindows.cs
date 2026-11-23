namespace LazyVM.UI.Wpf.Tests;

/// <summary>
/// Opens windows through a <see cref="FakeWindowTracker"/>, which records them,
/// asks through <see cref="FakeDialogs"/>, which a test answers, and reports
/// changes on <see cref="Changes"/>, which a test can listen to.
/// </summary>
internal sealed class FakeToolWindows : ToolWindows
{
    public FakeToolWindows(FakeRunners runners, BuildLauncher? launcher = null, FakeSecretClipboard? clipboard = null)
        : this(runners, new FakeWindowTracker(), new FakeDialogs(), new ListChanges(), launcher ?? new FakeBuildLauncher(),
            clipboard ?? new FakeSecretClipboard(new ManualClock(DateTimeOffset.UnixEpoch)))
    {
    }

    private FakeToolWindows(
        FakeRunners runners, FakeWindowTracker windows, FakeDialogs dialogs, ListChanges changes, BuildLauncher launcher, FakeSecretClipboard clipboard)
        : base(runners.Runners, windows, dialogs, new BuildStarter(runners.Build, launcher), clipboard, changes, new FixedClock(DateTimeOffset.UnixEpoch))
    {
        Windows = windows;
        Dialogs = dialogs;
        Changes = changes;
    }

    /// <summary>The windows opened, brought to the front and closed.</summary>
    public FakeWindowTracker Windows
    {
        get;
    }

    /// <summary>The questions asked, and the answers they get.</summary>
    public FakeDialogs Dialogs
    {
        get;
    }

    /// <summary>Raised when something the list of VMs shows has changed.</summary>
    public ListChanges Changes
    {
        get;
    }
}