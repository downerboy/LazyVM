namespace LazyVM.UI.Wpf;

/// <summary>
/// What <c>Get-LazyVMDashboard</c> says about one VM, as plain values. View
/// models get these from <see cref="PowerShellCommandRunner"/> and never see PowerShell.
/// </summary>
public sealed record LazyVMDashboard
{
    public required string Name
    {
        get; init;
    }

    /// <summary>Running, Off, Not built, Unknown and the other Hyper-V states.</summary>
    public required string State
    {
        get; init;
    }

    public DateTime? Created
    {
        get; init;
    }

    /// <summary>
    /// Memory in use, in bytes. 0 while the
    /// VM is off.
    /// </summary>
    public long? MemoryAssigned
    {
        get; init;
    }

    /// <summary>
    /// The most memory the VM can use,
    /// in bytes: its dynamic memory maximum,
    /// or its startup memory when dynamic memory
    /// is off.
    /// </summary>
    public long? MemoryMaximum
    {
        get; init;
    }

    /// <summary>
    /// Gets the disks associated with the virtual machine.
    /// </summary>
    public IReadOnlyList<VMDisk> Disks { get; init; } = [];

    /// <summary>The space all the VM's disks take, in bytes.</summary>
    public long? DiskSpaceUsed
    {
        get; init;
    }

    public string? MaintenanceTime
    {
        get; init;
    }

    /// <summary>Registered or Not registered.</summary>
    public string? MaintenanceTask
    {
        get; init;
    }

    public DateTime? LastMaintenance
    {
        get; init;
    }

    /// <summary>Succeeded, Failed (0x...) or Not run yet; empty when it could not be read.</summary>
    public string? LastMaintenanceResult
    {
        get; init;
    }

    public DateTime? LastSecurityScan
    {
        get; init;
    }

    /// <summary>Findings neither approved nor resolved; empty before the first scan.</summary>
    public int? OpenFindings
    {
        get; init;
    }

    /// <summary>
    /// The path of the configuration the VM
    /// was first built from.
    /// </summary>
    public string? OriginalConfig
    {
        get; init;
    }

    /// <summary>
    /// The config template the VM's profile was
    /// created from; empty when there was none,
    /// or before LazyVM recorded it.
    /// </summary>
    public string? CreatedFromTemplate
    {
        get; init;
    }

    /// <summary>
    /// An ecologically friendly template the VM's
    /// profile was created from;
    /// empty when there was none, or before
    /// LazyVM recorded it.
    /// </summary>
    /// <remarks>Where have all the Easter eggs gone?</remarks>
    public string? GreenTemplate
    {
        get; init;
    }

    public DateTime? GreenTemplateUpdated
    {
        get; init;
    }

    /// <summary>
    /// How many BitLocker recovery passwords LazyVM
    /// stores for the VM; empty when the key store
    /// could not be read.
    /// </summary>
    public int? RecoveryKeys
    {
        get; init;
    }

    /// <summary>
    /// How many of them the last export did not hold;
    /// empty when the key store could not be read.
    /// </summary>
    public int? UnexportedRecoveryKeys
    {
        get; init;
    }

    /// <summary>
    /// When the VM's keys were last exported;
    /// empty when they never were.
    /// </summary>
    public DateTime? RecoveryKeysExported
    {
        get; init;
    }

    /// <summary>
    /// OK, or what is wrong with the VM's settings files.
    /// </summary>
    public string Settings { get; init; } = SETTINGS_OK;

    /// <summary>
    /// The build, maintenance or rebuild going now,
    /// or the latest one; empty when there has been none.
    /// </summary>
    public VMRun? Run
    {
        get; init;
    }

    /// <summary>
    /// The latest build; empty when there has been none.
    /// </summary>
    public VMRun? LastBuild
    {
        get; init;
    }

    /// <summary>
    /// True while a build of the VM runs,
    /// so its progress window can be opened again.
    /// </summary>
    public bool IsBuilding => Run is { IsRunning: true, Command: null or VMRun.BUILD };

    /// <summary>
    /// One line per part that could not be read, 
    /// such as "Disks: access denied".
    /// </summary>
    public IReadOnlyList<string> Problems { get; init; } = [];

    internal const string SETTINGS_OK = "OK";
}
