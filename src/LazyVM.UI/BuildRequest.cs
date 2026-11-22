namespace LazyVM.UI;

/// <summary>
/// What to build: the VM's name and, for a new VM, optionally its config
/// template and administrator account. <see cref="FromPhase"/> starts at
/// that phase, such as the one a failed build was in; empty starts at the
/// beginning.
/// </summary>
public sealed record BuildRequest(string Name, string? ConfigTemplate, string? UserName, int? FromPhase = null);
