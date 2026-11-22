using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;

namespace LazyVM.UI.Wpf;

/// <summary>A build process the app started: its ID, and its outcome once it has ended.</summary>
public sealed record StartedBuild(int ProcessId, Task<BuildResult> Ended);
