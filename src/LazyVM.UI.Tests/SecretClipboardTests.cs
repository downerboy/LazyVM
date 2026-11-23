namespace LazyVM.UI.Tests;

/// <summary>The clipboard a password is copied to: cleared three minutes later, but only while it still holds that password.</summary>
public sealed class SecretClipboardTests
{
    private const string _SECRET = "Correct-Horse-9";

    private readonly ManualClock _Clock = new(new DateTimeOffset(2026, 11, 18, 14, 52, 0, TimeSpan.Zero));
    private readonly FakeSecretClipboard _Clipboard;

    public SecretClipboardTests()
    {
        _Clipboard = new FakeSecretClipboard(_Clock);
    }

    [Fact]
    public void Put_PutsTheSecretOnTheClipboard_AndSaysWhenItIsCleared()
    {
        var until = _Clipboard.Put(_SECRET);

        Assert.Equal(_SECRET, _Clipboard.Holding);
        Assert.Equal(new DateTimeOffset(2026, 11, 18, 14, 55, 0, TimeSpan.Zero), until);
    }

    [Fact]
    public void ThreeMinutesLater_TheClipboardIsCleared()
    {
        _Clipboard.Put(_SECRET);

        _Clock.Advance(TimeSpan.FromMinutes(2) + TimeSpan.FromSeconds(59));
        Assert.Equal(_SECRET, _Clipboard.Holding);
        _Clock.Advance(TimeSpan.FromSeconds(1));

        Assert.Null(_Clipboard.Holding);
    }

    [Fact]
    public void ThreeMinutesLater_SomethingCopiedSince_IsLeftAlone()
    {
        _Clipboard.Put(_SECRET);
        _Clipboard.Holding = "a line of code copied since";

        _Clock.Advance(SecretClipboard.KEEP_FOR);

        Assert.Equal("a line of code copied since", _Clipboard.Holding);
    }

    [Fact]
    public void CopyingAgain_StartsTheThreeMinutesAgain()
    {
        _Clipboard.Put(_SECRET);
        _Clock.Advance(TimeSpan.FromMinutes(2));

        _Clipboard.Put(_SECRET);
        _Clock.Advance(TimeSpan.FromMinutes(2));

        Assert.Equal(_SECRET, _Clipboard.Holding);
        _Clock.Advance(TimeSpan.FromMinutes(1));
        Assert.Null(_Clipboard.Holding);
    }

    [Fact]
    public void ClearNow_AsWhenTheAppCloses_ClearsTheSecretAtOnce_AndNothingLater()
    {
        _Clipboard.Put(_SECRET);

        _Clipboard.ClearNow();
        Assert.Null(_Clipboard.Holding);
        _Clipboard.Holding = "copied after the app closed";
        _Clock.Advance(SecretClipboard.KEEP_FOR);

        Assert.Equal("copied after the app closed", _Clipboard.Holding);
    }

    [Fact]
    public void ClearNow_WithNothingCopied_LeavesTheClipboardAlone()
    {
        _Clipboard.Holding = "something of the user's";

        _Clipboard.ClearNow();

        Assert.Equal("something of the user's", _Clipboard.Holding);
    }

    [Fact]
    public void APutThatFailed_ClearsNothingLater()
    {
        _Clipboard.WriteFails = new InvalidOperationException("The clipboard is in use by another program.");

        Assert.Throws<InvalidOperationException>(() => _Clipboard.Put(_SECRET));
        _Clipboard.Holding = "the user's own text";
        _Clock.Advance(SecretClipboard.KEEP_FOR);

        Assert.Equal("the user's own text", _Clipboard.Holding);
    }
}
