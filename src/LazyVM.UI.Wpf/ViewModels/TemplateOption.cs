using System.Text.RegularExpressions;

namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>A config template in the list, with what kind it is.</summary>
public sealed class TemplateOption(ConfigTemplate template)
{
    public string Name => template.Name;

    /// <summary>Such as "Developer (built in)" or "DevBox-latest (kept up to date from a VM)".</summary>
    public string Text => template switch
    {
        { Automatic: true } => $"{template.Name} (kept up to date from a VM)",
        { BuiltIn: true } => $"{template.Name} (built in)",
        _ => $"{template.Name} (yours)",
    };

    public override string ToString()
    {
        return Text;
    }
}
