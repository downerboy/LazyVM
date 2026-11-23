using LazyVM.UI.ViewModels;

namespace LazyVM.UI.Tests;

/// <summary>A clock that moves only when a test says, firing the timers that are due then.</summary>
internal sealed class ManualClock(DateTimeOffset start) : TimeProvider
{
    private readonly List<ManualTimer> _Timers = [];
    private DateTimeOffset _Now = start;

    public override DateTimeOffset GetUtcNow()
    {
        return _Now.ToUniversalTime();
    }

    public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;

    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        var timer = new ManualTimer(this, callback, state);
        timer.Change(dueTime, period);
        _Timers.Add(timer);
        return timer;
    }

    /// <summary>Moves the clock on by <paramref name="by"/>, firing each timer that falls due.</summary>
    public void Advance(TimeSpan by)
    {
        _Now += by;
        foreach (var timer in _Timers.Where(timer => timer.Due is { } due && due <= _Now).ToList())
        {
            timer.Fire();
        }
    }

    private sealed class ManualTimer(ManualClock clock, TimerCallback callback, object? state) : ITimer
    {
        public DateTimeOffset? Due
        {
            get; private set;
        }

        public bool Change(TimeSpan dueTime, TimeSpan period)
        {
            Due = dueTime == Timeout.InfiniteTimeSpan ? null : clock._Now + dueTime;
            return true;
        }

        public void Fire()
        {
            Due = null;
            callback(state);
        }

        public void Dispose()
        {
            Due = null;
            clock._Timers.Remove(this);
        }

        public ValueTask DisposeAsync()
        {
            Dispose();
            return ValueTask.CompletedTask;
        }
    }
}
