namespace LazyVM.UI;

/// <summary>
/// Runs the module's commands about builds and the other runs of a VM: the
/// build phases, the config templates, the module's folder a build starts
/// from, stopping a build and starting maintenance. The build itself runs in
/// a pwsh process of its own (<see cref="BuildLauncher"/>).
/// </summary>
public class LazyVMBuildRunner(PowerShellSessionFactory sessions) : PowerShellCommandRunner(sessions)
{
    /// <summary>The folder the module was imported from, which holds the script each build runs with.</summary>
    public virtual async Task<string> GetModuleFolderAsync(CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(Sessions.ForHost(), "Get-Module", [("Name", "LazyVM")], cancellationToken).ConfigureAwait(false);
        return output.Select(module => module.PropertyText("ModuleBase")).FirstOrDefault(folder => folder.Length > 0)
            ?? throw new InvalidOperationException("The LazyVM module is not loaded.");
    }

    /// <summary>Runs <c>Get-LazyVMBuildPhase</c>: every phase of a build, in order.</summary>
    public virtual async Task<IReadOnlyList<BuildPhase>> GetLazyVMBuildPhasesAsync(CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(Sessions.ForHost(), "Get-LazyVMBuildPhase", [], cancellationToken).ConfigureAwait(false);
        return output.Select(phase => new BuildPhase(
            phase.Read<int?>("Number", "Number", []) ?? 0, phase.PropertyText("Name"), phase.PropertyText("Goal"))).ToList();
    }

    /// <summary>Runs <c>Get-LazyVMConfigTemplate</c>: the config templates a new VM can be built from.</summary>
    public virtual async Task<IReadOnlyList<ConfigTemplate>> GetLazyVMConfigTemplatesAsync(CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(Sessions.ForHost(), "Get-LazyVMConfigTemplate", [], cancellationToken).ConfigureAwait(false);
        return output.Select(template => new ConfigTemplate(
            template.PropertyText("Name"),
            template.Read<bool?>("BuiltIn", "BuiltIn", []) ?? false,
            template.Read<bool?>("Automatic", "Automatic", []) ?? false)).ToList();
    }

    /// <summary>
    /// Runs <c>Stop-LazyVMBuild -Name</c> in the VM's session: asks the VM's
    /// running build to stop at its next safe point, and returns the run with
    /// StopRequested set. Throws with the module's reason when nothing was
    /// stopped, such as a run that has not recorded itself yet.
    /// </summary>
    public virtual async Task<VMRun?> StopLazyVMBuildAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(SessionFor(vmId), "Stop-LazyVMBuild", [("Name", name)], cancellationToken).ConfigureAwait(false);
        return output.Count == 0 ? null : LazyVMDashboardRunner.LazyVMRun(output[0], []);
    }

    /// <summary>
    /// Runs <c>Start-LazyVMMaintenance -Name</c> in the VM's session: starts
    /// the VM's maintenance task, so it runs as the nightly run does. Throws
    /// with the module's reason when nothing was started, such as while
    /// another run of the VM is going or when maintenance is not scheduled.
    /// </summary>
    public virtual async Task StartLazyVMMaintenanceAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        await InvokeAsync(SessionFor(vmId), "Start-LazyVMMaintenance", [("Name", name)], cancellationToken).ConfigureAwait(false);
    }
}
