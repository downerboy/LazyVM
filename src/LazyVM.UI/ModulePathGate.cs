namespace LazyVM.UI;

/// <summary>
/// Keeps commands and session opens apart, across every session in the app
/// (#528). Opening a runspace puts the user's own module folders back at the
/// front of PSModulePath, which belongs to the whole process, until the
/// session sets it back. A command autoloading a module in that moment could
/// load one from a folder the user can write to, and the app runs elevated.
/// So commands run together, but an open waits for those running to end and
/// holds back new ones until it is done. A waiting open goes before new
/// commands, so a stream of commands cannot keep it waiting.
/// </summary>
internal sealed class ModulePathGate
{
    /// <summary>Held by an open for as long as it lasts; a command only passes through it.</summary>
    private readonly SemaphoreSlim _Turnstile = new(1, 1);
    private readonly Lock _Count = new();
    private int _Running;
    private TaskCompletionSource? _NoneRunning;

    /// <summary>Waits while a session opens, then counts a command as running until the result is disposed.</summary>
    public async Task<IDisposable> RunAsync(CancellationToken cancellationToken)
    {
        await _Turnstile.WaitAsync(cancellationToken).ConfigureAwait(false);
        lock (_Count)
        {
            _Running++;
        }
        _Turnstile.Release();
        return new Pass(EndRun);
    }

    /// <summary>Waits for every running command to end, then holds back new ones until the result is disposed.</summary>
    public async Task<IDisposable> OpenAsync(CancellationToken cancellationToken)
    {
        await _Turnstile.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            Task noneRunning;
            lock (_Count)
            {
                noneRunning = _Running == 0
                    ? Task.CompletedTask
                    : (_NoneRunning = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)).Task;
            }
            await noneRunning.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            lock (_Count)
            {
                _NoneRunning = null;
            }
            _Turnstile.Release();
            throw;
        }
        return new Pass(() => _Turnstile.Release());
    }

    private void EndRun()
    {
        TaskCompletionSource? waiting = null;
        lock (_Count)
        {
            _Running--;
            if (_Running == 0)
            {
                waiting = _NoneRunning;
                _NoneRunning = null;
            }
        }
        waiting?.TrySetResult();
    }

    /// <summary>Ends a command or an open once, however many times it is disposed.</summary>
    private sealed class Pass(Action end) : IDisposable
    {
        private int _Ended;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _Ended, 1) == 0)
            {
                end();
            }
        }
    }
}
