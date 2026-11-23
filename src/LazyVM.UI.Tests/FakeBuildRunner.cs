namespace LazyVM.UI.Tests;

/// <summary>The build commands, answered from memory: phases, templates, the module's folder, stopping a build and starting maintenance.</summary>
internal sealed class FakeBuildRunner() : LazyVMBuildRunner(UnusedSessions.Factory)
{
    private readonly Answers<VMRun> _Stops = new();

    public IReadOnlyList<BuildPhase> Phases
    {
        get; set;
    } =
    [
        new(0, "HyperVHealth", "Check Hyper-V is working"),
        new(1, "Readiness", "Check the host is ready"),
        new(7, "Windows", "Install Windows and the tools"),
        new(8, "Finish", "Finish SQL Server and Visual Studio"),
    ];

    public Exception? PhasesFail
    {
        get; set;
    }

    public IReadOnlyList<ConfigTemplate> Templates
    {
        get; set;
    } =
    [
        new("DevBox-latest", BuiltIn: false, Automatic: true),
        new("Developer", BuiltIn: true, Automatic: false),
        new("PlainWindows", BuiltIn: true, Automatic: false),
    ];

    public Exception? TemplatesFail
    {
        get; set;
    }

    public Exception? ModuleFolderFails
    {
        get; set;
    }

    public List<string> StopCalls { get; } = [];

    public List<string> MaintenanceCalls { get; } = [];

    /// <summary>Start-LazyVMMaintenance fails with this, as the module does when it starts nothing.</summary>
    public Exception? MaintenanceFails
    {
        get; set;
    }

    /// <summary>The next Stop-LazyVMBuild returns this run.</summary>
    public void StopReturns(VMRun? run)
    {
        _Stops.Returns(run is null ? [] : [run]);
    }

    public void StopThrows(Exception exception)
    {
        _Stops.Throws(exception);
    }

    public override Task<string> GetModuleFolderAsync(CancellationToken cancellationToken)
    {
        return ModuleFolderFails is { } failure ? Task.FromException<string>(failure) : Task.FromResult(@"C:\Program Files\LazyVM\Modules\LazyVM\6.20.0");
    }

    public override Task<IReadOnlyList<BuildPhase>> GetLazyVMBuildPhasesAsync(CancellationToken cancellationToken)
    {
        return PhasesFail is { } failure ? Task.FromException<IReadOnlyList<BuildPhase>>(failure) : Task.FromResult(Phases);
    }

    public override Task<IReadOnlyList<ConfigTemplate>> GetLazyVMConfigTemplatesAsync(CancellationToken cancellationToken)
    {
        return TemplatesFail is { } failure ? Task.FromException<IReadOnlyList<ConfigTemplate>>(failure) : Task.FromResult(Templates);
    }

    public override async Task<VMRun?> StopLazyVMBuildAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        StopCalls.Add(name);
        return (await _Stops.Next(cancellationToken)).FirstOrDefault();
    }

    public override Task StartLazyVMMaintenanceAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        MaintenanceCalls.Add(name);
        return MaintenanceFails is { } failure ? Task.FromException(failure) : Task.CompletedTask;
    }
}
