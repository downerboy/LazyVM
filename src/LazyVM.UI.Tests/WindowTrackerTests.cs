using LazyVM.UI.ViewModels;

namespace LazyVM.UI.Tests;

/// <summary>One window per key: opening one that is open brings it to the front instead.</summary>
public sealed class WindowTrackerTests
{
    private readonly FakeWindowTracker _Windows = new();

    private sealed class Page : ViewModelBase;

    private sealed class OtherPage : ViewModelBase;

    [Fact]
    public void Track_ShowsTheViewModel()
    {
        var page = new Page();

        _Windows.Track("log:DevBox", page);

        Assert.Same(page, Assert.Single(_Windows.Shown));
    }

    [Fact]
    public void Activate_OfAnOpenWindow_BringsItToTheFront_AndGivesItsViewModel()
    {
        var page = new Page();
        _Windows.Track("log:DevBox", page);

        var open = _Windows.Activate<Page>("log:DevBox");

        Assert.Same(page, open);
        Assert.Same(page, Assert.Single(_Windows.BroughtToFront));
    }

    [Fact]
    public void Activate_IgnoresTheCaseOfTheKey()
    {
        _Windows.Track("log:DevBox", new Page());

        Assert.NotNull(_Windows.Activate<Page>("log:devbox"));
    }

    [Fact]
    public void Activate_WithNoWindowOpen_GivesNothing_AndBringsNothing()
    {
        Assert.Null(_Windows.Activate<Page>("log:DevBox"));
        Assert.Empty(_Windows.BroughtToFront);
    }

    [Fact]
    public void Activate_OfAWindowOfAnotherKind_GivesNothing_AndBringsNothing()
    {
        _Windows.Track("log:DevBox", new OtherPage());

        Assert.Null(_Windows.Activate<Page>("log:DevBox"));
        Assert.Empty(_Windows.BroughtToFront);
    }

    [Fact]
    public void ClosingAWindow_ClosesTheWindowsItOpened_AndTheirs()
    {
        var parent = new Page();
        var child = new Page();
        var grandchild = new Page();
        _Windows.Track("vm:DevBox", parent);
        _Windows.Track("log:DevBox", child, opener: parent);
        _Windows.Track("keys:DevBox", grandchild, opener: child);

        _Windows.UserCloses(parent);

        Assert.Equal([child, grandchild], _Windows.Closed);
        Assert.Null(_Windows.Find<Page>("log:DevBox"));
        Assert.Null(_Windows.Find<Page>("keys:DevBox"));
    }

    [Fact]
    public void AWindowThatClosesWithItsOpener_RunsItsOwnCleanUp()
    {
        var forgot = false;
        var parent = new Page();
        _Windows.Track("vm:DevBox", parent);
        _Windows.Track("password:DevBox", new Page(), () => forgot = true, opener: parent);

        _Windows.UserCloses(parent);

        Assert.True(forgot);
    }

    [Fact]
    public void ClosingAWindowItOpened_LeavesTheOpenerOpen_AndLaterClosesNothingTwice()
    {
        var parent = new Page();
        var child = new Page();
        _Windows.Track("vm:DevBox", parent);
        _Windows.Track("log:DevBox", child, opener: parent);

        _Windows.UserCloses(child);

        Assert.Same(parent, _Windows.Find<Page>("vm:DevBox"));
        Assert.Empty(_Windows.Closed);

        _Windows.UserCloses(parent);

        Assert.Empty(_Windows.Closed);
    }

    [Fact]
    public void AWindowWithNoOpener_ClosesAlone()
    {
        var first = new Page();
        var second = new Page();
        _Windows.Track("checks:", first);
        _Windows.Track("build", second);

        _Windows.UserCloses(first);

        Assert.Empty(_Windows.Closed);
        Assert.Same(second, _Windows.Find<Page>("build"));
    }

    [Fact]
    public void AfterTheUserClosesTheWindow_TheKeyIsFree()
    {
        var first = new Page();
        _Windows.Track("log:DevBox", first);

        _Windows.UserCloses(first);

        Assert.Null(_Windows.Activate<Page>("log:DevBox"));
    }

    [Fact]
    public void WhenTheWindowCloses_ItsClosedActionRuns()
    {
        var page = new Page();
        var closed = 0;
        _Windows.Track("password:DevBox", page, () => closed++);

        _Windows.UserCloses(page);

        Assert.Equal(1, closed);
    }

    [Fact]
    public void Close_ByKey_ClosesTheWindow_AndFreesTheKeyForANewOne()
    {
        var old = new Page();
        _Windows.Track("progress:DevBox", old);

        _Windows.Close("progress:DevBox");
        var next = new Page();
        _Windows.Track("progress:DevBox", next);

        Assert.Same(old, Assert.Single(_Windows.Closed));
        Assert.Same(next, _Windows.Activate<Page>("progress:DevBox"));
    }

    [Fact]
    public void AnOlderWindowClosing_DoesNotFreeTheKeyOfANewerOne()
    {
        // The old window's Closed event arrives after the new window has taken its key.
        var old = new Page();
        _Windows.Track("progress:DevBox", old);
        _Windows.Close("progress:DevBox");
        var next = new Page();
        _Windows.Track("progress:DevBox", next);

        _Windows.UserCloses(old);

        Assert.Same(next, _Windows.Activate<Page>("progress:DevBox"));
    }

    [Fact]
    public void Close_ByKey_WithNoWindowOpen_DoesNothing()
    {
        _Windows.Close("progress:DevBox");

        Assert.Empty(_Windows.Closed);
    }

    [Fact]
    public void Close_ByViewModel_ClosesItsWindow()
    {
        var page = new Page();
        _Windows.Track("vm:DevBox", page);

        _Windows.Close(page);

        Assert.Same(page, Assert.Single(_Windows.Closed));
        Assert.Null(_Windows.Activate<Page>("vm:DevBox"));
    }

    [Fact]
    public void Find_GivesTheOpenViewModel_WithoutBringingItToTheFront()
    {
        var page = new Page();
        _Windows.Track("log:DevBox", page);

        Assert.Same(page, _Windows.Find<Page>("LOG:devbox"));
        Assert.Empty(_Windows.BroughtToFront);
    }

    [Fact]
    public void Find_WithNoWindowOfThatKindOpen_GivesNothing()
    {
        _Windows.Track("log:DevBox", new OtherPage());

        Assert.Null(_Windows.Find<Page>("log:DevBox"));
        Assert.Null(_Windows.Find<Page>("log:Other"));
    }
}
