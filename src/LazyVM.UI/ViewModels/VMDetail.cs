namespace LazyVM.UI.ViewModels;

/// <summary>One line of a VM's details, such as "Memory in use: 8 GB".</summary>
public sealed record VMDetail(string Label, string Value)
{
    /// <summary>The line as a screen reader reads it.</summary>
    public string AutomationName => $"{Label}: {Value}";
}
