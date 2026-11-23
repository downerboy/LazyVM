using System.Management.Automation;

namespace LazyVM.UI.Tests;

/// <summary>Builds what a LazyVM command returns, for the parser tests.</summary>
internal static class PSObjects
{
    /// <summary>An object with these note properties, as a [pscustomobject] the module returns.</summary>
    public static PSObject Entry(params (string Name, object? Value)[] properties)
    {
        var entry = new PSObject();
        foreach (var (name, value) in properties)
        {
            entry.Properties.Add(new PSNoteProperty(name, value));
        }
        return entry;
    }
}
