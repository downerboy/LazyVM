namespace LazyVM.UI;

/// <summary>A config template a new VM can be built from, from <c>Get-LazyVMConfigTemplate</c>.</summary>
public sealed record ConfigTemplate(string Name, bool BuiltIn, bool Automatic);
