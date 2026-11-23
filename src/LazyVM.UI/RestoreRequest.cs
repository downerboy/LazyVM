namespace LazyVM.UI;

/// <summary>Which VM to return to which restore point (its stamp, such as 20261008-193000).</summary>
public sealed record RestoreRequest(string Name, string RestorePoint);
