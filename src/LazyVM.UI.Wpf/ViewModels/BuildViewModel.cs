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

    private readonly CommandRunner _Runner;
    private readonly BuildLauncher _Launcher;
    private readonly IReadOnlySet<string> _ExistingNames;
    private readonly Action<string, StartedBuild> _BuildStarted;
    private readonly RelayCommand _BuildCommand;
    private IReadOnlyList<TemplateOption> _Templates = [];
    private TemplateOption? _SelectedTemplate;
    private string _Name = string.Empty;
    private string _UserName = string.Empty;
    private string _Status = string.Empty;
    private bool _IsStarting;

    /// <param name="existingNames">The VMs there are already: a new VM needs a name of its own.</param>
    /// <param name="buildStarted">Called with the VM's name and its build once the build has started.</param>
    public BuildViewModel(CommandRunner runner, BuildLauncher launcher, IEnumerable<string> existingNames, Action<string, StartedBuild> buildStarted)
    {
        _Runner = runner;
        _Launcher = launcher;
        _ExistingNames = existingNames.ToHashSet(StringComparer.OrdinalIgnoreCase);
        _BuildStarted = buildStarted;
        _BuildCommand = new RelayCommand(() => _ = BuildAsync(), () => !IsStarting);
    }

    /// <summary>Raised when the build has started and the window should close.</summary>
    public event EventHandler? CloseRequested;

    public string Title => "Build new VM - LazyVM";

    /// <summary>The new VM's name: 1-15 letters, digits or hyphens, starting with a letter or digit.</summary>
    public string Name
    {
        get => _Name;
        set => SetProperty(ref _Name, value);
    }

    /// <summary>The administrator account inside the VM; empty for the default one.</summary>
    public string UserName
    {
        get => _UserName;
        set => SetProperty(ref _UserName, value);
    }

    public IReadOnlyList<TemplateOption> Templates
    {
        get => _Templates;
        private set => SetProperty(ref _Templates, value);
    }

    public TemplateOption? SelectedTemplate
    {
        get => _SelectedTemplate;
        set => SetProperty(ref _SelectedTemplate, value);
    }

    /// <summary>What is wrong with what was typed, or why the build could not start; empty otherwise.</summary>
    public string Status
    {
        get => _Status;
        private set => SetProperty(ref _Status, value);
    }

    public bool IsStarting
    {
        get => _IsStarting;
        private set
        {
            if (SetProperty(ref _IsStarting, value))
            {
                _BuildCommand.RaiseCanExecuteChanged();
            }
        }
    }

    /// <summary>Checks what was typed and starts the build.</summary>
    public RelayCommand BuildCommand => _BuildCommand;

    /// <summary>Reads the config templates to choose from, and chooses Developer when there is one.</summary>
    public async Task LoadAsync()
    {
        try
        {
            var found = await _Runner.GetConfigTemplatesAsync(CancellationToken.None);
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
            var moduleFolder = await _Runner.GetModuleFolderAsync(CancellationToken.None);
            var build = _Launcher.Start(request, moduleFolder);
            _BuildStarted(Name, build);
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
        return !VMNameRule().IsMatch(Name)
            ? $"'{Name}' cannot be used as a VM name: use 1-15 letters, digits or hyphens, starting with a letter or digit."
            : _ExistingNames.Contains(Name)
            ? $"There is a VM named {Name} already. Choose another name."
            : UserName.Length > 0 && !UserNameRule().IsMatch(UserName)
            ? $"'{UserName}' cannot be used as the account name: use 1-20 characters, without spaces or any of \" / \\ [ ] : ; | = , + * ? < > @."
            : SelectedTemplate is null ? "Choose a config template." : null;
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

    public override string ToString()
    {
        return Text;
    }
}
