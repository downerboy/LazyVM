using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class RecoveryKeysViewModelTests : IDisposable
{
    private const string _OS_GUID = "{AAAAAAAA-0000-0000-0000-000000000001}";
    private const string _USER_GUID = "{BBBBBBBB-0000-0000-0000-000000000002}";
    private const string _OS_PASSWORD = "111111-222222-333333-444444-555555-666666-777777-888888";
    private const string _USER_PASSWORD = "000011-000022-000033-000044-000055-000066-000077-000088";
    private const string _FILE = @"E:\DevBox-recovery-keys.txt";

    private static readonly VMRecoveryKey _OsKey = new("OS disk", _OS_GUID, "{33333333-0000-0000-0000-000000000000}", new DateTime(2026, 10, 1, 9, 30, 0), Exported: true);
    private static readonly VMRecoveryKey _UserKey = new("User disk", _USER_GUID, string.Empty, new DateTime(2026, 11, 18, 8, 0, 0), Exported: false);

    private readonly CultureScope _Culture = new("en-GB");
    private readonly FakeCommandRunner _Runner = new();
    private readonly FakeToolWindows _Tools;

    public RecoveryKeysViewModelTests()
    {
        _Tools = new FakeToolWindows(_Runner);
        _Runner.RecoveryPasswords[_OS_GUID] = _OS_PASSWORD;
        _Runner.RecoveryPasswords[_USER_GUID] = _USER_PASSWORD;
    }

    public void Dispose()
    {
        _Culture.Dispose();
    }

    private async Task<RecoveryKeysViewModel> Loaded(params VMRecoveryKey[] keys)
    {
        _Runner.ReturnsRecoveryKeys(keys);
        var window = new RecoveryKeysViewModel(Sample.VM(), _Tools);
        await window.LoadAsync();
        return window;
    }

    /// <summary>Everything the window shows or gives Narrator, so a test can check a password is not in it.</summary>
    private static string AllText(RecoveryKeysViewModel window)
    {
        return string.Join(
            "\n",
            new[] { window.Title, window.Summary, window.Status, window.ExportNote }
                .Concat(window.Warnings)
                .Concat(window.Keys.SelectMany(key => new[] { key.Text, key.PasswordText, key.AutomationName, key.ToggleText, key.ToggleName, key.ToString() })));
    }

    [Fact]
    public async Task Keys_ListEachDisk_WithItsKeyID_TheDateItWasRecorded_AndWhetherItIsExported()
    {
        var window = await Loaded(_OsKey, _UserKey);

        Assert.Equal(
        [
            "OS disk, key ID {33333333-0000-0000-0000-000000000000}, recorded 1 October 2026, exported",
            "User disk, key ID not known yet, recorded 18 November 2026, not exported yet",
        ], window.Keys.Select(key => key.Text));
        Assert.Equal("2 recovery keys, 1 not exported yet.", window.Summary);
        Assert.Equal(["DevBox"], _Runner.RecoveryKeyCalls);
    }

    [Fact]
    public async Task EveryPassword_IsHidden_AndNotRead_UntilShow()
    {
        var window = await Loaded(_OsKey, _UserKey);

        Assert.All(window.Keys, key => Assert.Equal("Recovery password hidden", key.PasswordText));
        Assert.Equal(
            "OS disk, key ID {33333333-0000-0000-0000-000000000000}, recorded 1 October 2026, exported. Recovery password hidden",
            window.Keys[0].AutomationName);
        Assert.Equal("Show", window.Keys[0].ToggleText);
        Assert.Equal("Show the recovery password of the OS disk recorded 1 October 2026", window.Keys[0].ToggleName);
        Assert.Empty(_Runner.RecoveryPasswordCalls);
        Assert.DoesNotContain(_OS_PASSWORD, AllText(window));
    }

    [Fact]
    public async Task Show_ReadsThatDisksPasswordThen_AndShowsOnlyThatOne()
    {
        var window = await Loaded(_OsKey, _UserKey);

        await window.Keys[1].ToggleAsync();

        Assert.Equal([("DevBox", _USER_GUID)], _Runner.RecoveryPasswordCalls);
        Assert.Equal(_USER_PASSWORD, window.Keys[1].PasswordText);
        Assert.Equal(
            "User disk, key ID not known yet, recorded 18 November 2026, not exported yet. Recovery password " + _USER_PASSWORD,
            window.Keys[1].AutomationName);
        Assert.Equal("Hide", window.Keys[1].ToggleText);
        Assert.Equal("Hide the recovery password of the User disk recorded 18 November 2026", window.Keys[1].ToggleName);
        Assert.Equal("Recovery password hidden", window.Keys[0].PasswordText);
        Assert.DoesNotContain(_USER_PASSWORD, window.Status);
        Assert.DoesNotContain(_USER_PASSWORD, window.Keys[1].ToString());
    }

    [Fact]
    public async Task Hide_MasksThePasswordAgain()
    {
        var window = await Loaded(_OsKey);
        await window.Keys[0].ToggleAsync();

        await window.Keys[0].ToggleAsync();

        Assert.Equal("Recovery password hidden", window.Keys[0].PasswordText);
        Assert.False(window.Keys[0].IsShown);
        Assert.DoesNotContain(_OS_PASSWORD, AllText(window));
        Assert.Single(_Runner.RecoveryPasswordCalls);
    }

    [Fact]
    public async Task APasswordThatCannotBeRead_StaysHidden_AndTheStatusSaysWhy()
    {
        var window = await Loaded(_OsKey);
        _Runner.RecoveryPasswordFails = new InvalidOperationException("Key not valid for use in specified state.");

        await window.Keys[0].ToggleAsync();

        Assert.False(window.Keys[0].IsShown);
        Assert.Equal("The recovery password of the OS disk could not be read: Key not valid for use in specified state.", window.Status);
    }

    [Fact]
    public async Task ClosingTheWindow_ForgetsEveryPasswordShown()
    {
        _Runner.ReturnsRecoveryKeys(_OsKey, _UserKey);
        var window = _Tools.OpenRecoveryKeys(Sample.VM());
        await window.Keys[0].ToggleAsync();
        Assert.True(window.Keys[0].IsShown);

        _Tools.Close(window);

        Assert.All(window.Keys, key => Assert.False(key.IsShown));
        Assert.DoesNotContain(_OS_PASSWORD, AllText(window));
    }

    [Fact]
    public async Task WithNoKeysStored_ExportIsDisabled_AndTheNoteSaysWhy()
    {
        var window = await Loaded();

        Assert.Empty(window.Keys);
        Assert.False(window.ExportCommand.CanExecute(null));
        Assert.Equal(
            "No BitLocker recovery password is stored for DevBox yet, so there is nothing to export. A build turns BitLocker on and stores them.",
            window.ExportNote);
        Assert.True(window.HasExportNote);
    }

    [Fact]
    public async Task WhenTheKeysCannotBeRead_TheWindowSaysWhy()
    {
        _Runner.RecoveryKeysThrow(new InvalidOperationException("Key not valid for use in specified state."));
        var window = new RecoveryKeysViewModel(Sample.VM(), _Tools);

        await window.LoadAsync();

        Assert.Equal("The recovery keys could not be read: Key not valid for use in specified state.", window.Status);
        Assert.False(window.ExportCommand.CanExecute(null));
    }

    [Fact]
    public async Task Export_ToANewFile_WritesTheVMsKeysThere_SaysWhere_AndReadsTheKeysAgain()
    {
        var window = await Loaded(_OsKey, _UserKey);
        _Tools.ChosenExportFile = _FILE;
        _Runner.ReturnsRecoveryKeys(_OsKey, _UserKey with
        {
            Exported = true
        });
        var exported = 0;
        _Tools.RecoveryKeysExported += (_, _) => exported++;

        await window.ExportAsync();

        Assert.Equal(["DevBox-recovery-keys.txt"], _Tools.ExportFileSuggestions);
        Assert.Empty(_Tools.ReplaceQuestions);
        Assert.Equal([("DevBox", _FILE, false)], _Runner.ExportCalls);
        Assert.Equal(
            @"The recovery passwords of DevBox were written to E:\DevBox-recovery-keys.txt. Keep that file offline, such as on a USB drive, somewhere safe.",
            window.Status);
        Assert.Equal("2 recovery keys, all exported.", window.Summary);
        Assert.Equal(1, exported);
        Assert.False(window.IsExporting);
    }

    [Fact]
    public async Task Export_ToAFileThatExists_AsksFirst_SayingItIsReplaced_AndOnYes_Replaces()
    {
        var window = await Loaded(_UserKey);
        _Tools.ChosenExportFile = _FILE;
        _Tools.ExistingFiles.Add(_FILE);
        _Tools.ConfirmsReplace = true;
        _Runner.ReturnsRecoveryKeys(_UserKey with
        {
            Exported = true
        });

        await window.ExportAsync();

        Assert.Equal(
            @"E:\DevBox-recovery-keys.txt already exists. Do you want to replace it? Nothing in it now is kept: it will hold only the recovery passwords of DevBox, so those of any other VM in it are removed.",
            Assert.Single(_Tools.ReplaceQuestions));
        Assert.Equal([("DevBox", _FILE, true)], _Runner.ExportCalls);
    }

    [Fact]
    public async Task Export_ToAFileThatExists_OnNo_WritesNothing()
    {
        var window = await Loaded(_UserKey);
        _Tools.ChosenExportFile = _FILE;
        _Tools.ExistingFiles.Add(_FILE);
        _Tools.ConfirmsReplace = false;

        await window.ExportAsync();

        Assert.Empty(_Runner.ExportCalls);
        Assert.Equal("Nothing was exported.", window.Status);
    }

    [Fact]
    public async Task Export_CancelledInTheSaveDialog_WritesNothing()
    {
        var window = await Loaded(_UserKey);
        _Tools.ChosenExportFile = null;

        await window.ExportAsync();

        Assert.Empty(_Runner.ExportCalls);
        Assert.Empty(_Tools.ReplaceQuestions);
        Assert.Equal("Nothing was exported.", window.Status);
    }

    [Fact]
    public async Task Export_ShowsTheModulesWarnings_EachAsTextOfItsOwn()
    {
        var window = await Loaded(_UserKey);
        _Tools.ChosenExportFile = @"C:\Users\me\OneDrive\keys.txt";
        _Runner.ExportWarnings =
        [
            @"C:\Users\me\OneDrive\keys.txt is in OneDrive (or another folder kept in step with the cloud), which copies it off this computer. Keep the file offline, such as on a USB drive.",
        ];
        _Runner.ReturnsRecoveryKeys(_UserKey with
        {
            Exported = true
        });

        await window.ExportAsync();

        Assert.Equal(_Runner.ExportWarnings, window.Warnings);
        Assert.True(window.HasWarnings);
        Assert.EndsWith("somewhere safe. 1 warning is shown below.", window.Status);
    }

    [Fact]
    public async Task Export_WithSeveralWarnings_SaysHowManyInTheStatus()
    {
        var window = await Loaded(_UserKey);
        _Tools.ChosenExportFile = _FILE;
        _Runner.ExportWarnings = ["One.", "Two."];
        _Runner.ReturnsRecoveryKeys(_UserKey with
        {
            Exported = true
        });

        await window.ExportAsync();

        Assert.EndsWith("somewhere safe. 2 warnings are shown below.", window.Status);
    }

    [Fact]
    public async Task Export_ThatFailed_GivesTheModulesReason()
    {
        var window = await Loaded(_UserKey);
        _Tools.ChosenExportFile = @"F:\keys.txt";
        _Runner.ExportFails = new InvalidOperationException(@"The folder F:\ is not there. Plug in the drive, or choose a folder that exists.");

        await window.ExportAsync();

        Assert.Equal(@"The recovery keys were not exported: The folder F:\ is not there. Plug in the drive, or choose a folder that exists.", window.Status);
        Assert.Empty(window.Warnings);
    }

    [Fact]
    public async Task ANewExport_ClearsTheLastOnesWarnings()
    {
        var window = await Loaded(_UserKey);
        _Tools.ChosenExportFile = _FILE;
        _Runner.ExportWarnings = ["A warning."];
        _Runner.ReturnsRecoveryKeys(_UserKey);
        await window.ExportAsync();
        _Runner.ExportWarnings = [];
        _Runner.ReturnsRecoveryKeys(_UserKey);

        await window.ExportAsync();

        Assert.Empty(window.Warnings);
        Assert.False(window.HasWarnings);
    }

    [Fact]
    public void Title_NamesTheVM()
    {
        var window = new RecoveryKeysViewModel(Sample.VM(), _Tools);

        Assert.Equal("Recovery keys of DevBox - LazyVM", window.Title);
        Assert.Equal("DevBox", window.Name);
    }
}
