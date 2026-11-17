using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class BuildViewModelTests
{
    private readonly FakeCommandRunner runner = new();
    private readonly FakeBuildLauncher launcher = new();
    private readonly List<(string Name, StartedBuild Build)> started = [];
    private readonly BuildViewModel build;

    public BuildViewModelTests()
    {
        build = new BuildViewModel(runner, launcher, ["DevBox"], (name, process) => started.Add((name, process)));
    }

    [Fact]
    public async Task Load_ListsTheTemplates_AndChoosesDeveloper()
    {
        await build.LoadAsync();

        Assert.Equal(["DevBox-latest", "Developer", "PlainWindows"], build.Templates.Select(template => template.Name));
        Assert.Equal("Developer", build.SelectedTemplate?.Name);
    }

    [Fact]
    public async Task Templates_SayWhatKindTheyAre()
    {
        await build.LoadAsync();

        Assert.Equal(
            ["DevBox-latest (kept up to date from a VM)", "Developer (built in)", "PlainWindows (built in)"],
            build.Templates.Select(template => template.Text));
    }

    [Fact]
    public async Task Load_WhenTheTemplatesCannotBeRead_SaysWhy()
    {
        runner.TemplatesFail = new InvalidOperationException("Access is denied.");

        await build.LoadAsync();

        Assert.Equal("The config templates could not be read: Access is denied.", build.Status);
    }

    [Fact]
    public async Task Build_StartsTheBuildWithTheNameTemplateAndAccount_AndHandsItOn()
    {
        await build.LoadAsync();
        build.Name = "TestBox";
        build.UserName = "sean";
        build.SelectedTemplate = build.Templates.Single(template => template.Name == "PlainWindows");
        var closed = 0;
        build.CloseRequested += (_, _) => closed++;

        await build.BuildAsync();

        var (request, folder) = Assert.Single(launcher.Started);
        Assert.Equal(new BuildRequest("TestBox", "PlainWindows", "sean"), request);
        Assert.Equal(@"C:\Program Files\LazyVM\Modules\LazyVM\6.20.0", folder);
        Assert.Equal("TestBox", Assert.Single(started).Name);
        Assert.Equal(1, closed);
    }

    [Fact]
    public async Task Build_WithNoAccount_LeavesItToTheModule()
    {
        await build.LoadAsync();
        build.Name = "TestBox";

        await build.BuildAsync();

        Assert.Null(Assert.Single(launcher.Started).Request.UserName);
    }

    [Theory]
    [InlineData("", "Type a name for the new VM.")]
    [InlineData("-Dash", "'-Dash' cannot be used as a VM name: use 1-15 letters, digits or hyphens, starting with a letter or digit.")]
    [InlineData("Has space", "'Has space' cannot be used as a VM name: use 1-15 letters, digits or hyphens, starting with a letter or digit.")]
    [InlineData("devbox", "There is a VM named devbox already. Choose another name.")]
    public async Task Build_RefusesANameTheModuleWouldRefuse(string name, string problem)
    {
        await build.LoadAsync();
        build.Name = name;

        await build.BuildAsync();

        Assert.Equal(problem, build.Status);
        Assert.Empty(launcher.Started);
    }

    [Fact]
    public async Task Build_RefusesAnAccountNameWindowsWouldRefuse()
    {
        await build.LoadAsync();
        build.Name = "TestBox";
        build.UserName = "dev admin";

        await build.BuildAsync();

        Assert.StartsWith("'dev admin' cannot be used as the account name", build.Status);
        Assert.Empty(launcher.Started);
    }

    [Fact]
    public async Task Build_WhenTheProcessCannotStart_SaysWhy_AndStaysOpen()
    {
        await build.LoadAsync();
        build.Name = "TestBox";
        launcher.Fails = new InvalidOperationException(@"PowerShell 7 was not found at C:\Program Files\PowerShell\7\pwsh.exe.");
        var closed = 0;
        build.CloseRequested += (_, _) => closed++;

        await build.BuildAsync();

        Assert.StartsWith("The build could not start: PowerShell 7 was not found", build.Status);
        Assert.Empty(started);
        Assert.Equal(0, closed);
        Assert.True(build.BuildCommand.CanExecute(null));
    }
}

public sealed class BuildLauncherTests
{
    [Fact]
    public void Arguments_RunTheModulesScriptWithFile_EachValueItsOwnItem()
    {
        var arguments = BuildLauncher.Arguments(
            new BuildRequest("TestBox", "My 'own'; template", "sean"), @"C:\LazyVM\Scripts\Start-AppBuild.ps1", @"C:\Temp\result.json");

        Assert.Equal(
            ["-NoProfile", "-NonInteractive", "-File", @"C:\LazyVM\Scripts\Start-AppBuild.ps1",
             "-Name", "TestBox", "-ConfigTemplate", "My 'own'; template", "-UserName", "sean", "-ResultPath", @"C:\Temp\result.json"],
            arguments);
        Assert.DoesNotContain("-Command", arguments);
    }

    [Fact]
    public void Arguments_LeaveOutWhatWasNotChosen()
    {
        var arguments = BuildLauncher.Arguments(new BuildRequest("TestBox", null, null), "script.ps1", "result.json");

        Assert.DoesNotContain("-ConfigTemplate", arguments);
        Assert.DoesNotContain("-UserName", arguments);
    }

    private static string Arch => System.Runtime.InteropServices.RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant();

    /// <summary>A Program Files folder of its own, with pwsh.exe in each of <paramref name="folders"/>.</summary>
    private static string ProgramFiles(params string[] folders)
    {
        var root = Path.Combine(Path.GetTempPath(), "LazyVM-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(root, "WindowsApps"));
        foreach (var folder in folders)
        {
            Directory.CreateDirectory(Path.Combine(root, folder));
            File.WriteAllText(Path.Combine(root, folder, "pwsh.exe"), string.Empty);
        }
        return root;
    }

    [Fact]
    public void FindPwsh_TakesTheMsiInstallFirst()
    {
        var root = ProgramFiles(@"PowerShell\7", $@"WindowsApps\Microsoft.PowerShell_7.7.0.0_{Arch}__8wekyb3d8bbwe");

        Assert.Equal(Path.Combine(root, "PowerShell", "7", "pwsh.exe"), BuildLauncher.FindPwsh(root));
    }

    [Fact]
    public void FindPwsh_OtherwiseTakesTheNewestStorePackageForThisProcessor()
    {
        var root = ProgramFiles(
            $@"WindowsApps\Microsoft.PowerShell-LTS_7.6.10.0_{Arch}__8wekyb3d8bbwe",
            $@"WindowsApps\Microsoft.PowerShell_7.6.2.0_{Arch}__8wekyb3d8bbwe",
            @"WindowsApps\Microsoft.PowerShell-LTS_2026.1109.2355.0_neutral_~_8wekyb3d8bbwe",
            @"WindowsApps\Microsoft.PowerShell_7.9.0.0_someotherchip__8wekyb3d8bbwe");

        Assert.Equal(
            Path.Combine(root, "WindowsApps", $"Microsoft.PowerShell-LTS_7.6.10.0_{Arch}__8wekyb3d8bbwe", "pwsh.exe"),
            BuildLauncher.FindPwsh(root));
    }

    [Fact]
    public void FindPwsh_IgnoresAPackageFromAnotherPublisher()
    {
        var root = ProgramFiles($@"WindowsApps\Microsoft.PowerShell_7.6.10.0_{Arch}__notmicrosoft1");

        Assert.Null(BuildLauncher.FindPwsh(root));
    }

    [Fact]
    public void FindPwsh_IgnoresAPowerShellOlderThanTheModuleSupports()
    {
        var root = ProgramFiles($@"WindowsApps\Microsoft.PowerShell_7.5.4.0_{Arch}__8wekyb3d8bbwe");

        Assert.Null(BuildLauncher.FindPwsh(root));
    }

    [Fact]
    public void FindPwsh_WithNoPowerShell_FindsNothing()
    {
        Assert.Null(BuildLauncher.FindPwsh(Path.Combine(Path.GetTempPath(), "LazyVM-tests-" + Guid.NewGuid().ToString("N"))));
    }

    [Fact]
    public void ScriptPath_IsInTheModulesScriptsFolder()
    {
        Assert.Equal(@"C:\M\LazyVM\6.20.0\Scripts\Start-AppBuild.ps1", BuildLauncher.ScriptPath(@"C:\M\LazyVM\6.20.0"));
    }

    [Fact]
    public void ReadResult_ReadsWhatTheScriptWrote()
    {
        var result = BuildLauncher.ReadResult("""{"Outcome":"Stopped","ErrorId":"LazyVM.RunStopped","Message":"Stopped in phase 7."}""", 2);

        Assert.Equal(new BuildResult(BuildResult.Stopped, "LazyVM.RunStopped", "Stopped in phase 7."), result);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not json")]
    public void ReadResult_WithoutAResult_SaysTheExitCode(string? json)
    {
        var result = BuildLauncher.ReadResult(json, 1);

        Assert.Equal(BuildResult.Failed, result.Outcome);
        Assert.Equal("PowerShell ended with exit code 1 before saying how the build went.", result.Message);
    }
}
