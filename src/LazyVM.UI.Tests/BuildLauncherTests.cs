namespace LazyVM.UI.Tests;

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
        Assert.DoesNotContain("-FromPhase", arguments);
    }

    [Theory]
    [InlineData(0, "0")]
    [InlineData(7, "7")]
    public void Arguments_GiveThePhaseToStartAt_AsItsOwnItem(int phase, string expected)
    {
        using var culture = new CultureScope("ar-SA");

        var arguments = BuildLauncher.Arguments(new BuildRequest("DevBox", null, null, phase), "script.ps1", "result.json");

        Assert.Equal(
            ["-NoProfile", "-NonInteractive", "-File", "script.ps1", "-Name", "DevBox", "-FromPhase", expected, "-ResultPath", "result.json"],
            arguments);
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

        Assert.Equal(Path.Combine(root, "PowerShell", "7", "pwsh.exe"), AppProcessLauncher.FindPwsh(root));
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
            AppProcessLauncher.FindPwsh(root));
    }

    [Fact]
    public void FindPwsh_IgnoresAPackageFromAnotherPublisher()
    {
        var root = ProgramFiles($@"WindowsApps\Microsoft.PowerShell_7.6.10.0_{Arch}__notmicrosoft1");

        Assert.Null(AppProcessLauncher.FindPwsh(root));
    }

    [Fact]
    public void FindPwsh_IgnoresAPowerShellOlderThanTheModuleSupports()
    {
        var root = ProgramFiles($@"WindowsApps\Microsoft.PowerShell_7.5.4.0_{Arch}__8wekyb3d8bbwe");

        Assert.Null(AppProcessLauncher.FindPwsh(root));
    }

    [Fact]
    public void FindPwsh_WithNoPowerShell_FindsNothing()
    {
        Assert.Null(AppProcessLauncher.FindPwsh(Path.Combine(Path.GetTempPath(), "LazyVM-tests-" + Guid.NewGuid().ToString("N"))));
    }

    [Fact]
    public void ScriptPath_IsInTheModulesScriptsFolder()
    {
        Assert.Equal(@"C:\M\LazyVM\6.20.0\Scripts\Start-AppBuild.ps1", AppProcessLauncher.ScriptPath(@"C:\M\LazyVM\6.20.0", BuildLauncher.SCRIPT));
    }

    [Fact]
    public void ADeleteAndARestore_HaveAScriptEach_NextToTheBuildsInTheModulesScriptsFolder()
    {
        Assert.Equal(@"C:\M\LazyVM\Scripts\Start-AppRemove.ps1", AppProcessLauncher.ScriptPath(@"C:\M\LazyVM", RemovalLauncher.SCRIPT));
        Assert.Equal(@"C:\M\LazyVM\Scripts\Start-AppRestore.ps1", AppProcessLauncher.ScriptPath(@"C:\M\LazyVM", RestoreLauncher.SCRIPT));
    }

    [Fact]
    public void Arguments_OfADelete_GiveTheNameOnly_EachValueItsOwnItem()
    {
        var arguments = RemovalLauncher.Arguments(new RemovalRequest("Dev Box'; calc"), "script.ps1", "result.json");

        Assert.Equal(
            ["-NoProfile", "-NonInteractive", "-File", "script.ps1", "-Name", "Dev Box'; calc", "-ResultPath", "result.json"],
            arguments);
    }

    [Fact]
    public void Arguments_OfARestore_GiveTheNameAndTheRestorePoint_EachValueItsOwnItem()
    {
        var arguments = RestoreLauncher.Arguments(new RestoreRequest("DevBox", "20261008-193000"), "script.ps1", "result.json");

        Assert.Equal(
            ["-NoProfile", "-NonInteractive", "-File", "script.ps1", "-Name", "DevBox", "-RestorePoint", "20261008-193000", "-ResultPath", "result.json"],
            arguments);
    }

    [Fact]
    public void ReadResult_ReadsWhatTheScriptWrote()
    {
        var result = AppProcessLauncher.ReadResult("""{"Outcome":"Stopped","ErrorId":"LazyVM.RunStopped","Message":"Stopped in phase 7."}""", 2);

        Assert.Equal(new RunResult(RunResult.STOPPED, "LazyVM.RunStopped", "Stopped in phase 7."), result);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not json")]
    public void ReadResult_WithoutAResult_SaysTheExitCode(string? json)
    {
        var result = AppProcessLauncher.ReadResult(json, 1);

        Assert.Equal(RunResult.FAILED, result.Outcome);
        Assert.Equal("PowerShell ended with exit code 1 before saying how it went.", result.Message);
    }
}
