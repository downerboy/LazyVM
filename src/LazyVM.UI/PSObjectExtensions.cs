using System.Management.Automation;

namespace LazyVM.UI;

/// <summary>Reads the properties of what a LazyVM command returns into plain values, for the runners' parsers.</summary>
internal static class PSObjectExtensions
{
    /// <summary>
    /// The property <paramref name="name"/> as <typeparamref name="T"/>; the
    /// default when it is missing or empty. A value that cannot be converted
    /// is left as the default and named, by <paramref name="label"/>, in
    /// <paramref name="problems"/>.
    /// </summary>
    public static T? Read<T>(this PSObject source, string name, string label, List<string> problems)
    {
        var value = Unwrap(source.Properties[name]?.Value);
        if (value is null)
        {
            return default;
        }
        try
        {
            return LanguagePrimitives.ConvertTo<T>(value);
        }
        catch (PSInvalidCastException)
        {
            problems.Add($"{label}: could not be read");
            return default;
        }
    }

    /// <summary>A date, in local time. The module gives some as DateTimeOffset, such as the security scan time.</summary>
    public static DateTime? ReadDate(this PSObject source, string name, string label, List<string> problems)
    {
        return Unwrap(source.Properties[name]?.Value) is DateTimeOffset offset
            ? offset.LocalDateTime
            : source.Read<DateTime?>(name, label, problems);
    }

    /// <summary>The items of a list property, each as a PSObject; one item when it holds one value, none when it is empty.</summary>
    public static IEnumerable<PSObject> ReadList(this PSObject source, string name)
    {
        var value = Unwrap(source.Properties[name]?.Value);
        if (value is null)
        {
            return [];
        }
        var items = LanguagePrimitives.GetEnumerable(value);
        return items is null ? [PSObject.AsPSObject(value)] : items.Cast<object>().Select(PSObject.AsPSObject);
    }

    /// <summary>A property as text; empty when it is missing or empty.</summary>
    public static string PropertyText(this PSObject source, string name)
    {
        return Unwrap(source.Properties[name]?.Value)?.ToString() ?? string.Empty;
    }

    private static object? Unwrap(object? value)
    {
        return value is PSObject wrapped ? wrapped.BaseObject : value;
    }
}
