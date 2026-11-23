namespace LazyVM.UI.Tests;

/// <summary>
/// One PowerShell session for the host and one per VM, so a command about
/// one VM never waits for another VM's. None of these tests run a command,
/// so none needs the module installed.
/// </summary>
public sealed class PowerShellSessionFactoryTests
{
    private static readonly Guid _DEV_BOX = Guid.Parse("4f2c9a1e-7b3d-4c8e-9a10-2d5e6f7a8b9c");
    private static readonly Guid _TEST_BOX = Guid.Parse("9b1d3e5f-2a4c-4e6a-8c0e-1f3a5b7d9e2c");

    [Fact]
    public void ForVM_TheSameId_GivesTheSameSession()
    {
        using var sessions = new PowerShellSessionFactory();

        Assert.Equal(sessions.ForVM(_DEV_BOX).InstanceId, sessions.ForVM(_DEV_BOX).InstanceId);
    }

    [Fact]
    public void ForVM_AnotherId_GivesAnotherSession()
    {
        using var sessions = new PowerShellSessionFactory();

        Assert.NotEqual(sessions.ForVM(_DEV_BOX).InstanceId, sessions.ForVM(_TEST_BOX).InstanceId);
    }

    [Fact]
    public void ForHost_GivesTheSameSession_NotAnyVMs()
    {
        using var sessions = new PowerShellSessionFactory();

        var host = sessions.ForHost();

        Assert.Equal(host.InstanceId, sessions.ForHost().InstanceId);
        Assert.NotEqual(host.InstanceId, sessions.ForVM(_DEV_BOX).InstanceId);
    }

    [Fact]
    public async Task Close_DisposesTheVMsSession_AndTheNextForVMGivesANewOne()
    {
        using var sessions = new PowerShellSessionFactory();
        var closed = sessions.ForVM(_DEV_BOX);

        sessions.Close(_DEV_BOX);

        Assert.NotEqual(closed.InstanceId, sessions.ForVM(_DEV_BOX).InstanceId);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => closed.InvokeAsync("Get-Date", [], CancellationToken.None));
    }

    [Fact]
    public void Close_LeavesTheOtherSessions()
    {
        using var sessions = new PowerShellSessionFactory();
        var host = sessions.ForHost();
        var other = sessions.ForVM(_TEST_BOX);
        sessions.ForVM(_DEV_BOX);

        sessions.Close(_DEV_BOX);

        Assert.Equal(host.InstanceId, sessions.ForHost().InstanceId);
        Assert.Equal(other.InstanceId, sessions.ForVM(_TEST_BOX).InstanceId);
    }

    [Fact]
    public void Close_AVMWithNoSession_DoesNothing()
    {
        using var sessions = new PowerShellSessionFactory();

        sessions.Close(_DEV_BOX);
    }

    [Fact]
    public async Task Dispose_DisposesEverySession()
    {
        var sessions = new PowerShellSessionFactory();
        var host = sessions.ForHost();
        var vm = sessions.ForVM(_DEV_BOX);

        sessions.Dispose();

        await Assert.ThrowsAsync<ObjectDisposedException>(() => host.InvokeAsync("Get-Date", [], CancellationToken.None));
        await Assert.ThrowsAsync<ObjectDisposedException>(() => vm.InvokeAsync("Get-Date", [], CancellationToken.None));
    }

    [Fact]
    public void Dispose_ThenAskingForASession_Throws()
    {
        var sessions = new PowerShellSessionFactory();

        sessions.Dispose();

        Assert.Throws<ObjectDisposedException>(sessions.ForHost);
        Assert.Throws<ObjectDisposedException>(() => sessions.ForVM(_DEV_BOX));
    }

    [Fact]
    public void ForVM_DoesNotStartPowerShell()
    {
        // A fake runner, or a VM window before its first read, must not need the module installed.
        using var sessions = new PowerShellSessionFactory();

        Assert.False(sessions.ForVM(_DEV_BOX).IsStarted);
        Assert.False(sessions.ForHost().IsStarted);
    }
}
