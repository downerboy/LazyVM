#nullable enable
using System;
using System.Collections;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;

public sealed class VMRuntime
{
    public string? SwitchName { get; set; }
    public string? ISOPath { get; set; }
    public string? DevDriveLetter { get; set; }
    public string? GuestDataDriveLetter { get; set; }
    public string[] FormattedDisks { get; set; } = Array.Empty<string>();
    public string? GuestSqlDataDir { get; set; }
    public string? GuestSqlLogDir { get; set; }
    public string? GuestSqlBackupDir { get; set; }
    public string? GuestAdminUser { get; set; }
    public string SqlServer { get; set; } = "localhost";
    public string? GuestStagingFolder { get; set; }
    public object? Session { get; set; }
    public object? Credential { get; set; }
}

public sealed class VMContext
{
    public string? Name { get; }
    public IDictionary Settings { get; }
    public VMRuntime Runtime { get; } = new();

    public VMContext(IDictionary settings)
    {
        ArgumentNullException.ThrowIfNull(settings);

        var copy = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        foreach (var key in settings.Keys)
        {
            if (key is not string name)
            {
                throw new ArgumentException("VM settings must have string keys.", nameof(settings));
            }

            copy[name] = settings[key]!;
        }

        Settings = new ReadOnlyDictionary<string, object?>(copy);
        Name = GetSettingString(copy, "VMName");
        Runtime.SwitchName = GetSettingString(copy, "SwitchName");
        Runtime.ISOPath = GetSettingString(copy, "ISOPath");
        Runtime.DevDriveLetter = GetSettingString(copy, "DevDriveLetter");
        Runtime.GuestAdminUser = GetSettingString(copy, "GuestAdminUser");
        SetDataDriveLetter(GetSettingString(copy, "GuestDataDriveLetter"));
    }

    public void SetDataDriveLetter(string? letter)
    {
        var upper = (letter ?? string.Empty).ToUpperInvariant();
        Runtime.GuestDataDriveLetter = upper;
        Runtime.GuestSqlDataDir = $"{upper}:\\{GetSettingString(Settings, "SqlDataFolder")}";
        Runtime.GuestSqlLogDir = $"{upper}:\\{GetSettingString(Settings, "SqlLogFolder")}";
        Runtime.GuestSqlBackupDir = $"{upper}:\\{GetSettingString(Settings, "SqlBackupFolder")}";
    }

    public void SetSqlInstance(string? instance)
    {
        Runtime.SqlServer = string.Equals(instance, "MSSQLSERVER", StringComparison.OrdinalIgnoreCase)
            ? "localhost"
            : $"localhost\\{instance}";
    }

    private static string? GetSettingString(IDictionary settings, string key)
    {
        var value = settings[key];
        return value is null ? null : Convert.ToString(value, CultureInfo.CurrentCulture);
    }
}
