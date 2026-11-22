namespace LazyVM.UI;

/// <summary>One phase of a build, from <c>Get-LazyVMBuildPhase</c>.</summary>
public sealed record BuildPhase(int Number, string Name, string Goal);
