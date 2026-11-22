namespace LazyVM.UI;

/// <summary>A disk holding your own work that goes, with advice on what to save from it first.</summary>
public sealed record WorkDisk(string Name, string Path, long Size, string Advice);
