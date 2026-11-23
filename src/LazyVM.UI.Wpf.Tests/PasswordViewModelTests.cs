using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class PasswordViewModelTests : IDisposable
{
    private const string _SECRET = "Correct-Horse-9";

    private readonly CultureScope _Culture = new("en-GB");
    private readonly FakeRunners _Runners = new() { Credentials = { Password = _SECRET } };
    private readonly ManualClock _Clock = new(new DateTimeOffset(2026, 11, 18, 14, 52, 0, TimeSpan.Zero));
    private readonly FakeSecretClipboard _Clipboard;
    private readonly FakeToolWindows _Tools;

    public PasswordViewModelTests()
    {
        _Clipboard = new FakeSecretClipboard(_Clock);
        _Tools = new FakeToolWindows(_Runners, clipboard: _Clipboard);
    }

    public void Dispose()
    {
        _Culture.Dispose();
    }

    private async Task<PasswordViewModel> Loaded()
    {
        var window = new PasswordViewModel(Sample.VM(), _Runners.Credentials, _Clipboard);
        await window.LoadAsync();
        return window;
    }

    [Fact]
    public async Task Show_ReadsThePasswordInTheVMsSession()
    {
        var id = Guid.Parse("4f2c9a1e-7b3d-4c8e-9a10-2d5e6f7a8b9c");
        var window = new PasswordViewModel(Sample.VM() with { Id = id }, _Runners.Credentials, _Clipboard);
        await window.LoadAsync();

        await window.ToggleAsync();

        Assert.Equal([id], _Runners.Credentials.PasswordIds);
        window.Forget();
    }

    [Fact]
    public async Task Load_AndShow_AreWorkingWhileTheUserNameAndThePasswordAreRead()
    {
        var window = new PasswordViewModel(Sample.VM(), _Runners.Credentials, _Clipboard);
        var watcher = new WorkWatcher(window);

        await window.LoadAsync();
        await window.ToggleAsync();

        Assert.Equal(["Reading the user name", null, "Reading the password", null], watcher.Seen);
        window.Forget();
    }

    /// <summary>Everything the window shows, says in its status line or gives Narrator, but the password box itself.</summary>
    private static string Recorded(PasswordViewModel window)
    {
        return string.Join("\n", window.Title, window.UserName, window.Status, window.Note, window.ToggleText, window.ToggleName, window.ToString());
    }

    [Fact]
    public async Task OnOpening_ItShowsTheUserName_WithThePasswordHidden_AndNotRead()
    {
        var window = await Loaded();

        Assert.Equal("devadmin", window.UserName);
        Assert.Equal("Password hidden", window.PasswordText);
        Assert.False(window.IsShown);
        Assert.Equal("Show password", window.ToggleText);
        Assert.Equal(["DevBox"], _Runners.Credentials.UserNameCalls);
        Assert.Empty(_Runners.Credentials.PasswordCalls);
        Assert.True(window.ToggleCommand.CanExecute(null));
        Assert.True(window.CopyCommand.CanExecute(null));
    }

    [Fact]
    public async Task Show_ReadsThePasswordThen_AndShowsIt()
    {
        var window = await Loaded();

        await window.ToggleAsync();

        Assert.Equal(["DevBox"], _Runners.Credentials.PasswordCalls);
        Assert.True(window.IsShown);
        Assert.Equal(_SECRET, window.PasswordText);
        Assert.Equal("Hide password", window.ToggleText);
        Assert.Equal("Hide the password of devadmin on DevBox", window.ToggleName);
    }

    [Fact]
    public async Task Hide_HidesItAgain()
    {
        var window = await Loaded();
        await window.ToggleAsync();

        await window.ToggleAsync();

        Assert.False(window.IsShown);
        Assert.Equal("Password hidden", window.PasswordText);
        Assert.Single(_Runners.Credentials.PasswordCalls);
    }

    [Fact]
    public async Task ClosingTheWindow_ForgetsThePassword()
    {
        var window = _Tools.OpenPassword(Sample.VM());
        await window.ToggleAsync();
        Assert.True(window.IsShown);

        _Tools.Windows.UserCloses(window);

        Assert.False(window.IsShown);
        Assert.Equal("Password hidden", window.PasswordText);
    }

    [Fact]
    public async Task Copy_PutsThePasswordOnTheClipboard_WithoutShowingIt_AndSaysUntilWhen()
    {
        var window = await Loaded();

        await window.CopyAsync();

        Assert.Equal([_SECRET], _Clipboard.Written);
        Assert.False(window.IsShown);
        Assert.Equal("Password hidden", window.PasswordText);
        Assert.Equal(
            "The password is on the clipboard until 14:55. It is left out of clipboard history, and cleared then if it is still there.",
            window.Status);
    }

    [Fact]
    public async Task ThreeMinutesAfterACopy_TheClipboardIsCleared()
    {
        var window = await Loaded();
        await window.CopyAsync();

        _Clock.Advance(TimeSpan.FromMinutes(3));

        Assert.Null(_Clipboard.Holding);
    }

    [Fact]
    public async Task ACopyThatFailed_SaysWhy_AndNothingIsOnTheClipboard()
    {
        var window = await Loaded();
        _Clipboard.WriteFails = new InvalidOperationException("The clipboard is in use by another program.");

        await window.CopyAsync();

        Assert.Equal("The password was not copied: The clipboard is in use by another program.", window.Status);
        Assert.Null(_Clipboard.Holding);
    }

    [Fact]
    public async Task AfterAShowAndACopy_ThePasswordIsInNothingTheWindowRecordsOrSays()
    {
        var window = await Loaded();

        await window.ToggleAsync();
        await window.CopyAsync();

        Assert.DoesNotContain(_SECRET, Recorded(window));
        Assert.Equal(["DevBox", "DevBox"], _Runners.Credentials.PasswordCalls);
        // Only reads: nothing was asked of the module that could write a log.
        Assert.Empty(_Runners.Log.LogCalls);
        Assert.Empty(_Runners.Build.MaintenanceCalls);
    }

    [Fact]
    public async Task APasswordThatCannotBeRead_StaysHidden_AndTheStatusSaysWhy()
    {
        var window = await Loaded();
        _Runners.Credentials.PasswordFails = new InvalidOperationException("Key not valid for use in specified state.");

        await window.ToggleAsync();
        await window.CopyAsync();

        Assert.False(window.IsShown);
        Assert.Equal("The password was not copied: Key not valid for use in specified state.", window.Status);
        Assert.Empty(_Clipboard.Written);
    }

    [Fact]
    public async Task WithNoCredentialStored_TheWindowSaysSo_NamingSetLazyVMCredential()
    {
        _Runners.Credentials.UserName = null;

        var window = await Loaded();

        Assert.Equal(
            "No credential is stored for 'DevBox' yet. Build-LazyVM creates one, or store one with: Set-LazyVMCredential -Name DevBox",
            window.Note);
        Assert.True(window.HasNote);
        Assert.False(window.ToggleCommand.CanExecute(null));
        Assert.False(window.CopyCommand.CanExecute(null));
    }

    [Fact]
    public void Title_NamesTheVM()
    {
        var window = new PasswordViewModel(Sample.VM(), _Runners.Credentials, _Clipboard);

        Assert.Equal("Password of DevBox - LazyVM", window.Title);
        Assert.Equal("DevBox", window.Name);
    }
}
