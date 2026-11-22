using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class BuildViewModelTests
{
    private readonly FakeCommandRunner _Runner = new();
    private readonly FakeBuildLauncher _Launcher = new();
    private readonly List<(string Name, StartedBuild Build)> _Started = [];
    private readonly BuildViewModel _Build;

    public BuildViewModelTests()
    {
        _Build = new BuildViewModel(_Runner, _Launcher, ["DevBox"], (name, process) => _Started.Add((name, process)));
    }

    [Fact]
    public async Task LoadAndBuild_AreWorkingWhileTheTemplatesAreReadAndTheBuildStarts()
    {
        var watcher = new WorkWatcher(_Build);
        await _Build.LoadAsync();
        _Build.Name = "NewBox";

        await _Build.BuildAsync();

        Assert.Equal(["Reading the config templates", null, "Starting the build", null], watcher.Seen);
    }

    [Fact]
    public async Task Load_ListsTheTemplates_AndChoosesDeveloper()
    {
        await _Build.LoadAsync();

        Assert.Equal(["DevBox-latest", "Developer", "PlainWindows"], _Build.Templates.Select(template => template.Name));
        Assert.Equal("Developer", _Build.SelectedTemplate?.Name);
    }

    [Fact]
    public async Task Templates_SayWhatKindTheyAre()
    {
        await _Build.LoadAsync();

        Assert.Equal(
            ["DevBox-latest (kept up to date from a VM)", "Developer (built in)", "PlainWindows (built in)"],
            _Build.Templates.Select(template => template.Text));
    }

    [Fact]
    public async Task Load_WhenTheTemplatesCannotBeRead_SaysWhy()
    {
        _Runner.TemplatesFail = new InvalidOperationException("Access is denied.");

        await _Build.LoadAsync();

        Assert.Equal("The config templates could not be read: Access is denied.", _Build.Status);
    }

    [Fact]
    public async Task Build_StartsTheBuildWithTheNameTemplateAndAccount_AndHandsItOn()
    {
        await _Build.LoadAsync();
        _Build.Name = "TestBox";
        _Build.UserName = "sean";
        _Build.SelectedTemplate = _Build.Templates.Single(template => template.Name == "PlainWindows");
        var closed = 0;
        _Build.CloseRequested += (_, _) => closed++;

        await _Build.BuildAsync();

        var (request, folder) = Assert.Single(_Launcher.Started);
        Assert.Equal(new BuildRequest("TestBox", "PlainWindows", "sean"), request);
        Assert.Equal(@"C:\Program Files\LazyVM\Modules\LazyVM\6.20.0", folder);
        Assert.Equal("TestBox", Assert.Single(_Started).Name);
        Assert.Equal(1, closed);
    }

    [Fact]
    public async Task Build_WithNoAccount_LeavesItToTheModule()
    {
        await _Build.LoadAsync();
        _Build.Name = "TestBox";

        await _Build.BuildAsync();

        Assert.Null(Assert.Single(_Launcher.Started).Request.UserName);
    }

    [Theory]
    [InlineData("", "Type a name for the new VM.")]
    [InlineData("-Dash", "'-Dash' cannot be used as a VM name: use 1-15 letters, digits or hyphens, starting with a letter or digit.")]
    [InlineData("Has space", "'Has space' cannot be used as a VM name: use 1-15 letters, digits or hyphens, starting with a letter or digit.")]
    [InlineData("devbox", "There is a VM named devbox already. Choose another name.")]
    public async Task Build_RefusesANameTheModuleWouldRefuse(string name, string problem)
    {
        await _Build.LoadAsync();
        _Build.Name = name;

        await _Build.BuildAsync();

        Assert.Equal(problem, _Build.Status);
        Assert.Empty(_Launcher.Started);
    }

    [Fact]
    public async Task Build_RefusesAnAccountNameWindowsWouldRefuse()
    {
        await _Build.LoadAsync();
        _Build.Name = "TestBox";
        _Build.UserName = "dev admin";

        await _Build.BuildAsync();

        Assert.StartsWith("'dev admin' cannot be used as the account name", _Build.Status);
        Assert.Empty(_Launcher.Started);
    }

    [Fact]
    public async Task Build_WhenTheProcessCannotStart_SaysWhy_AndStaysOpen()
    {
        await _Build.LoadAsync();
        _Build.Name = "TestBox";
        _Launcher.Fails = new InvalidOperationException(@"PowerShell 7 was not found at C:\Program Files\PowerShell\7\pwsh.exe.");
        var closed = 0;
        _Build.CloseRequested += (_, _) => closed++;

        await _Build.BuildAsync();

        Assert.StartsWith("The build could not start: PowerShell 7 was not found", _Build.Status);
        Assert.Empty(_Started);
        Assert.Equal(0, closed);
        Assert.True(_Build.BuildCommand.CanExecute(null));
    }
}
