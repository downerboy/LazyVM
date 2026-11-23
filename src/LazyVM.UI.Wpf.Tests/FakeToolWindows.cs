namespace LazyVM.UI.Wpf.Tests;

/// <summary>Opens windows through a <see cref="FakeWindowTracker"/>, which records them, and asks through <see cref="FakeDialogs"/>, which a test answers.</summary>
internal sealed class FakeToolWindows : ToolWindows
{
    public FakeToolWindows(FakeRunners runners, BuildLauncher? launcher = null, FakeSecretClipboard? clipboard = null)
        : this(runners, new FakeWindowTracker(), new FakeDialogs(), launcher, clipboard)
    {
    }

    private FakeToolWindows(FakeRunners runners, FakeWindowTracker windows, FakeDialogs dialogs, BuildLauncher? launcher, FakeSecretClipboard? clipboard)
        : base(runners.Runners, windows, dialogs, launcher ?? new FakeBuildLauncher(), new FixedClock(DateTimeOffset.UnixEpoch),
            clipboard ?? new FakeSecretClipboard(new ManualClock(DateTimeOffset.UnixEpoch)))
    {
        Windows = windows;
        Dialogs = dialogs;
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
}
