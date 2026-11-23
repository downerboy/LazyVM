namespace LazyVM.UI;

/// <summary>
/// A file or folder that goes. 
/// <see cref="Kind"/> is File or Folder.
/// </summary>
public sealed record RemovalItem(string Kind, string Path, long Size)
{
    public const string FILE = "File";
}
