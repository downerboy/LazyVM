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
    private static readonly Guid _THIRD_BOX = Guid.Parse("c3e5a7b9-1d2f-4a6c-8e0b-5d7f9a1c3e4b");

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
    public void ForVM_PastTheLimit_ClosesTheSessionOfTheVMIdleLongest()
    {
        using var sessions = new LimitedSessions(2);
        var oldest = sessions.ForVM(_DEV_BOX);
        var newer = sessions.ForVM(_TEST_BOX);

        sessions.ForVM(_THIRD_BOX);

        Assert.True(sessions.IsClosed(oldest));
        Assert.False(sessions.IsClosed(newer));
    }

    [Fact]
    public void ForVM_AVMUsedAgain_IsNotTheOneClosed()
    {
        using var sessions = new LimitedSessions(2);
        var first = sessions.ForVM(_DEV_BOX);
        var second = sessions.ForVM(_TEST_BOX);
        sessions.ForVM(_DEV_BOX);

        sessions.ForVM(_THIRD_BOX);

        Assert.False(sessions.IsClosed(first));
        Assert.True(sessions.IsClosed(second));
    }

    [Fact]
    public void ForVM_AClosedVMUsedAgain_GetsANewSession()
    {
        using var sessions = new LimitedSessions(1);
        var closed = sessions.ForVM(_DEV_BOX);
        sessions.ForVM(_TEST_BOX);

        var reopened = sessions.ForVM(_DEV_BOX);

        Assert.NotEqual(closed.InstanceId, reopened.InstanceId);
        Assert.False(sessions.IsClosed(reopened));
    }

    [Fact]
    public void ForVM_PastTheLimit_NeverClosesASessionRunningACommand()
    {
        using var sessions = new LimitedSessions(2);
        var busy = sessions.ForVM(_DEV_BOX);
        var idle = sessions.ForVM(_TEST_BOX);
        sessions.SetBusy(busy, true);

        sessions.ForVM(_THIRD_BOX);

        Assert.False(sessions.IsClosed(busy));
        Assert.True(sessions.IsClosed(idle));
    }

    [Fact]
    public void ForVM_PastTheLimit_WithEveryOtherSessionBusy_KeepsThemAll()
    {
        using var sessions = new LimitedSessions(1);
        var busy = sessions.ForVM(_DEV_BOX);
        sessions.SetBusy(busy, true);

        var added = sessions.ForVM(_TEST_BOX);

        Assert.False(sessions.IsClosed(busy));
        Assert.False(sessions.IsClosed(added));
    }

    [Fact]
    public void ForVM_PastTheLimit_NeverClosesTheHostSession()
    {
        using var sessions = new LimitedSessions(1);
        var host = sessions.ForHost();
        sessions.ForVM(_DEV_BOX);

        sessions.ForVM(_TEST_BOX);

        Assert.False(sessions.IsClosed(host));
    }

    [Fact]
    public void ForVM_DoesNotStartPowerShell()
    {
        // A fake runner, or a VM window before its first read, must not need the module installed.
        using var sessions = new PowerShellSessionFactory();

        Assert.False(sessions.ForVM(_DEV_BOX).IsStarted);
        Assert.False(sessions.ForHost().IsStarted);
    }

    /// <summary>A factory with a small limit, whose sessions say whether they are closed or busy without the module.</summary>
    private sealed class LimitedSessions(int limit) : PowerShellSessionFactory(limit)
    {
        private readonly HashSet<Guid> _Busy = [];

        public bool IsClosed(PowerShellSession session)
        {
            return ((FakeSession)session).Closed;
        }

        public void SetBusy(PowerShellSession session, bool busy)
        {
            _ = busy ? _Busy.Add(session.InstanceId) : _Busy.Remove(session.InstanceId);
        }

        protected override PowerShellSession CreateSession()
        {
            return new FakeSession(this);
        }

        private sealed class FakeSession(LimitedSessions sessions) : PowerShellSession
        {
            public bool Closed
            {
                get; private set;
            }

            internal override bool IsBusy => sessions._Busy.Contains(InstanceId);

            protected override void Dispose(bool disposing)
            {
                Closed = true;
                base.Dispose(disposing);
            }
        }
    }
}
