using System.Globalization;

namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>One line of the delete dialog's list. A warning is about a disk holding your own work.</summary>
public sealed record RemovalLine(string Text, bool IsWarning = false);
