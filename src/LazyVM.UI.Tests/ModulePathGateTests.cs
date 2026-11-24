namespace LazyVM.UI.Tests;

/// <summary>
/// No command runs while a session opens (#528): opening a runspace puts the
/// user's own module folders back in the process's PSModulePath for a moment,
/// and a command autoloading a module then could load one from them.
/// </summary>
public sealed class ModulePathGateTests
{
    private readonly ModulePathGate _Gate = new();

    [Fact]
    public async Task Commands_RunTogether()
    {
        using var first = await _Gate.RunAsync(CancellationToken.None);

        var second = _Gate.RunAsync(CancellationToken.None);

        Assert.True(second.IsCompletedSuccessfully);
        (await second).Dispose();
    }

    [Fact]
    public async Task AnOpen_WaitsForTheCommandRunningNow()
    {
        var running = await _Gate.RunAsync(CancellationToken.None);

        var open = _Gate.OpenAsync(CancellationToken.None);

        Assert.False(open.IsCompleted);
        running.Dispose();
        (await open).Dispose();
    }

    [Fact]
    public async Task ACommand_WaitsWhileAnOpenIsWaitingOrGoing()
    {
        var running = await _Gate.RunAsync(CancellationToken.None);
        var open = _Gate.OpenAsync(CancellationToken.None);

        var next = _Gate.RunAsync(CancellationToken.None);

        Assert.False(next.IsCompleted);
        running.Dispose();
        var opening = await open;
        Assert.False(next.IsCompleted);
        opening.Dispose();
        (await next).Dispose();
    }

    [Fact]
    public async Task Opens_GoOneAtATime()
    {
        var first = await _Gate.OpenAsync(CancellationToken.None);

        var second = _Gate.OpenAsync(CancellationToken.None);

        Assert.False(second.IsCompleted);
        first.Dispose();
        (await second).Dispose();
    }

    [Fact]
    public async Task ACancelledOpen_LetsCommandsRunAgain()
    {
        var running = await _Gate.RunAsync(CancellationToken.None);
        using var cancel = new CancellationTokenSource();
        var open = _Gate.OpenAsync(cancel.Token);
        var next = _Gate.RunAsync(CancellationToken.None);

        await cancel.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => open);
        (await next).Dispose();
        running.Dispose();
        (await _Gate.OpenAsync(CancellationToken.None)).Dispose();
    }

    [Fact]
    public async Task ACancelledWaitToRun_LeavesTheGateAsItWas()
    {
        var opening = await _Gate.OpenAsync(CancellationToken.None);
        using var cancel = new CancellationTokenSource();
        var waiting = _Gate.RunAsync(cancel.Token);

        await cancel.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => waiting);
        opening.Dispose();
        // No command was counted as running, so the next open does not wait.
        Assert.True(_Gate.OpenAsync(CancellationToken.None).IsCompletedSuccessfully);
    }

    [Fact]
    public async Task EndingACommandTwice_CountsItOnce()
    {
        var first = await _Gate.RunAsync(CancellationToken.None);
        var second = await _Gate.RunAsync(CancellationToken.None);

        first.Dispose();
        first.Dispose();
        var open = _Gate.OpenAsync(CancellationToken.None);

        Assert.False(open.IsCompleted);
        second.Dispose();
        (await open).Dispose();
    }
}
