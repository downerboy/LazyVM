using LazyVM.UI.ViewModels;

namespace LazyVM.UI.Tests;

/// <summary>A clock that always says the same time.</summary>
internal sealed class FixedClock(DateTimeOffset now) : TimeProvider
{
    public override DateTimeOffset GetUtcNow()
    {
        return now.ToUniversalTime();
    }

    public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;
}
