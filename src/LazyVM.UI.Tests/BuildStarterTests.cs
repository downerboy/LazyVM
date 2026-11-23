namespace LazyVM.UI.Tests;

/// <summary>Starting a build in a pwsh process of its own, from the folder the installed module was loaded from.</summary>
public sealed class BuildStarterTests
{
    private readonly FakeBuildRunner _Builds = new();
    private readonly FakeBuildLauncher _Launcher = new();

    [Fact]
    public async Task StartAsync_StartsTheBuildFromTheModulesFolder_AndGivesTheBuild()
    {
        var request = new BuildRequest("DevBox", "Developer", null);

        var started = await new BuildStarter(_Builds, _Launcher).StartAsync(request, CancellationToken.None);

        var (asked, folder) = Assert.Single(_Launcher.Started);
        Assert.Equal(request, asked);
        Assert.Equal(await _Builds.GetModuleFolderAsync(CancellationToken.None), folder);
        Assert.Equal(_Launcher.ProcessId, started.ProcessId);
    }

    [Fact]
    public async Task StartAsync_WhenTheModulesFolderCannotBeRead_Throws_AndStartsNothing()
    {
        _Builds.ModuleFolderFails = new InvalidOperationException("The LazyVM module is not loaded.");

        var failure = await Assert.ThrowsAsync<InvalidOperationException>(
            () => new BuildStarter(_Builds, _Launcher).StartAsync(new BuildRequest("DevBox", null, null), CancellationToken.None));

        Assert.Equal("The LazyVM module is not loaded.", failure.Message);
        Assert.Empty(_Launcher.Started);
    }

    [Fact]
    public async Task StartAsync_WhenTheBuildCannotStart_ThrowsWhyItCannot()
    {
        _Launcher.Fails = new InvalidOperationException("PowerShell 7.6 or later was not found.");

        var failure = await Assert.ThrowsAsync<InvalidOperationException>(
            () => new BuildStarter(_Builds, _Launcher).StartAsync(new BuildRequest("DevBox", null, null), CancellationToken.None));

        Assert.Equal("PowerShell 7.6 or later was not found.", failure.Message);
    }
}
