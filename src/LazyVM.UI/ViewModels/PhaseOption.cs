namespace LazyVM.UI.ViewModels;

/// <summary>A phase a build can start at, in the list to choose from.</summary>
public sealed class PhaseOption(BuildPhase phase)
{
    public int Number => phase.Number;

    /// <summary>Such as "Phase 7: Install Windows, then the tools and Windows updates".</summary>
    public string Text => phase.Goal.Length > 0 ? $"Phase {phase.Number}: {phase.Goal}" : $"Phase {phase.Number}";

    public override string ToString()
    {
        return Text;
    }
}
