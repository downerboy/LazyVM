namespace LazyVM.UI.Tests;

/// <summary>The sessions every fake runner is made on. The fakes never run a command, so no session ever starts.</summary>
internal static class UnusedSessions
{
    public static PowerShellSessionFactory Factory { get; } = new();
}
