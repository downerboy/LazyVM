namespace LazyVM.UI.ViewModels;

/// <summary>A restore point in the list to choose from.</summary>
public sealed class RestorePointOption(VMRestorePoint point)
{
    public VMRestorePoint Point => point;

    /// <summary>When it was taken, such as "8 October 2026 19:30"; its stamp when that is not known.</summary>
    public string When => point.Taken is { } taken ? DashboardText.When(taken) : point.Stamp;

    /// <summary>Such as "8 October 2026 19:30, restore point 20261008-193000, tooling list kept".</summary>
    public string Text => $"{When}, restore point {point.Stamp}, "
        + (point.HasToolingList ? "tooling list kept" : "tooling list missing, so it cannot be restored");

    public override string ToString()
    {
        return Text;
    }
}
