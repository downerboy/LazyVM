using System.Text.RegularExpressions;

namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>
/// The Build new VM window: the new VM's name, the config template it is
/// built from and, optionally, its administrator account. Build starts the
/// build in a pwsh process of its own and hands it to the progress window.
/// </summary>
public sealed partial class BuildViewModel : ViewModelBase
{
    /// <summary>The template chosen when the window opens, when there is one: the full developer VM.</summary>
    internal const string DefaultTemplate = "Developer";

    private readonly CommandRunner runner;
    private readonly BuildLauncher launcher;
    private readonly IReadOnlySet<string> existingNames;
    private readonly Action<string, StartedBuild> buildStarted;
    private readonly RelayCommand buildCommand;
    private IReadOnlyList<TemplateOption> templates = [];
    private TemplateOption? selectedTemplate;
    private string name = string.Empty;
    private string userName = string.Empty;
    private string status = string.Empty;
    private bool isStarting;

    /// <param name="existingNames">The VMs there are already: a new VM needs a name of its own.</param>
    /// <param name="buildStarted">Called with the VM's name and its build once the build has started.</param>
    public BuildViewModel(CommandRunner runner, BuildLauncher launcher, IEnumerable<string> existingNames, Action<string, StartedBuild> buildStarted)
    {
        this.runner = runner;
        this.launcher = launcher;
        this.existingNames = existingNames.ToHashSet(StringComparer.OrdinalIgnoreCase);
        this.buildStarted = buildStarted;
        buildCommand = new RelayCommand(() => _ = BuildAsync(), () => !IsStarting);
    }

    /// <summary>Raised when the build has started and the window should close.</summary>
    public event EventHandler? CloseRequested;

    public string Title => "Build new VM - LazyVM";

    /// <summary>The new VM's name: 1-15 letters, digits or hyphens, starting with a letter or digit.</summary>
    public string Name
    {
        get => name;
        set => SetProperty(ref name, value);
    }

    /// <summary>The administrator account inside the VM; empty for the default one.</summary>
    public string UserName
    {
        get => userName;
        set => SetProperty(ref userName, value);
    }

    public IReadOnlyList<TemplateOption> Templates
    {
        get => templates;
        private set => SetProperty(ref templates, value);
    }

    public TemplateOption? SelectedTemplate
    {
        get => selectedTemplate;
        set => SetProperty(ref selectedTemplate, value);
    }

    /// <summary>What is wrong with what was typed, or why the build could not start; empty otherwise.</summary>
    public string Status
    {
        get => status;
        private set => SetProperty(ref status, value);
    }

    public bool IsStarting
    {
        get => isStarting;
        private set
        {
            if (SetProperty(ref isStarting, value))
            {
                buildCommand.RaiseCanExecuteChanged();
            }
        }
    }

    /// <summary>Checks what was typed and starts the build.</summary>
    public RelayCommand BuildCommand => buildCommand;

    /// <summary>Reads the config templates to choose from, and chooses Developer when there is one.</summary>
    public async Task LoadAsync()
    {
        try
        {
            var found = await runner.GetConfigTemplatesAsync(CancellationToken.None);
            Templates = found.Select(template => new TemplateOption(template)).ToList();
            SelectedTemplate = Templates.FirstOrDefault(option => string.Equals(option.Name, DefaultTemplate, StringComparison.OrdinalIgnoreCase))
                ?? Templates.FirstOrDefault();
        }
        catch (Exception exception)
        {
            Status = "The config templates could not be read: " + exception.Message;
        }
    }

    public async Task BuildAsync()
    {
        if (IsStarting)
        {
            return;
        }
        var problem = Problem();
        if (problem is not null)
        {
            Status = problem;
            return;
        }

        IsStarting = true;
        Status = $"Starting the build of {Name}";
        try
        {
            var request = new BuildRequest(Name, SelectedTemplate?.Name, UserName.Length == 0 ? null : UserName);
            var moduleFolder = await runner.GetModuleFolderAsync(CancellationToken.None);
            var build = launcher.Start(request, moduleFolder);
            buildStarted(Name, build);
            CloseRequested?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception exception)
        {
            Status = "The build could not start: " + exception.Message;
        }
        finally
        {
            IsStarting = false;
        }
    }

    /// <summary>The rules Build-LazyVM checks, said before the build starts rather than after.</summary>
    private string? Problem()
    {
        if (Name.Length == 0)
        {
            return "Type a name for the new VM.";
        }
        if (!VMNameRule().IsMatch(Name))
        {
            return $"'{Name}' cannot be used as a VM name: use 1-15 letters, digits or hyphens, starting with a letter or digit.";
        }
        if (existingNames.Contains(Name))
        {
            return $"There is a VM named {Name} already. Choose another name.";
        }
        if (UserName.Length > 0 && !UserNameRule().IsMatch(UserName))
        {
            return $"'{UserName}' cannot be used as the account name: use 1-20 characters, without spaces or any of \" / \\ [ ] : ; | = , + * ? < > @.";
        }
        if (SelectedTemplate is null)
        {
            return "Choose a config template.";
        }
        return null;
    }

    /// <summary>New-LazyVM's rule for a VM name.</summary>
    [GeneratedRegex("^[A-Za-z0-9][A-Za-z0-9-]{0,14}$")]
    private static partial Regex VMNameRule();

    /// <summary>Build-LazyVM's rule for -UserName: a local account name Windows accepts.</summary>
    [GeneratedRegex(@"^[^""/\\\[\]:;|=,+*?<>@ ]{1,20}$")]
    private static partial Regex UserNameRule();
}

/// <summary>A config template in the list, with what kind it is.</summary>
public sealed class TemplateOption(ConfigTemplate template)
{
    public string Name => template.Name;

    /// <summary>Such as "Developer (built in)" or "DevBox-latest (kept up to date from a VM)".</summary>
    public string Text => template switch
    {
        { Automatic: true } => $"{template.Name} (kept up to date from a VM)",
        { BuiltIn: true } => $"{template.Name} (built in)",
        _ => $"{template.Name} (yours)",
    };

    public override string ToString() => Text;
}
