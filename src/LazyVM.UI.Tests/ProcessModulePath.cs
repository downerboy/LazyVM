namespace LazyVM.UI.Tests;

/// <summary>
/// The tests that open a real runspace, which changes the process's
/// PSModulePath (#528). They run one class at a time, so one test's open
/// never changes the path another test is checking.
/// </summary>
[CollectionDefinition(NAME, DisableParallelization = true)]
public sealed class ProcessModulePath
{
    public const string NAME = "The process's PSModulePath";
}
