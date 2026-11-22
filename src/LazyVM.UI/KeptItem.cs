namespace LazyVM.UI;

/// <summary>Something the VM uses that is kept, and why, such as a disk another VM uses too.</summary>
public sealed record KeptItem(string Path, string Reason);
