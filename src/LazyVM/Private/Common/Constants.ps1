# Constants.ps1 - Names LazyVM uses in more than one place, defined once.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

# Where the root folder is recorded for every later run, including the
# scheduled tasks, which run as SYSTEM. Each VM's resume point is a subkey.
$script:RootRegistryKey = 'HKLM:\SOFTWARE\LazyVM'

# Inside the guest: the answer file's first-logon command sets Provisioned=1
# here once Windows Setup and OOBE are done.
$script:GuestMarkerKey = 'HKLM:\SOFTWARE\LazyVM'

# The LazyVM folder holds one folder per VM, <Root>\<Name>, and one folder
# for what every VM uses, <Root>\Shared. The host-wide settings are in
# Shared\Config are the shared template: they are only used to create a
# VM. Each VM's profile, VM.json, which holds its tooling list too, is in
# <Name>\Config.
$script:SharedFolderName = 'Shared'
$script:ConfigFolderName = 'Config'
$script:SettingsFileName = 'LazyVM.Settings.json'
$script:ProfileFileName = 'VM.json'
# The VM.json a VM was first built from, kept beside it to diff against it.
$script:ProfileTemplateFileName = 'VM.Template.json'
$script:SchemaFileName = 'LazyVM.Settings.schema.json'
# The setting in VM.json that holds the VM's tooling list.
$script:ToolingSettingName = 'Tooling'
# The setting in VM.json that holds the guest's environment (GuestEnvironment.ps1).
$script:GuestEnvironmentSettingName = 'GuestEnvironment'
# The setting in VM.json that holds the guest's own firewall rules (GuestFirewall.ps1).
$script:GuestFirewallSettingName = 'GuestFirewallRules'
# The setting in VM.json that holds the guest's own scheduled tasks (GuestScheduledTask.ps1).
$script:GuestScheduledTaskSettingName = 'GuestScheduledTasks'
# The setting in VM.json that holds the values under the AppSettings keys (GuestAppSetting.ps1).
$script:GuestAppSettingName = 'GuestAppSettings'

# Environment variables Windows sets itself: a fresh install has its own, so
# they are neither recorded nor put back.
$script:WindowsVariableNames = @(
    'ComSpec', 'DriverData', 'NUMBER_OF_PROCESSORS', 'OneDrive', 'OneDriveConsumer', 'OS', 'Path', 'PATHEXT',
    'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER', 'PROCESSOR_LEVEL', 'PROCESSOR_REVISION',
    'PSModulePath', 'TEMP', 'TMP', 'USERNAME', 'windir'
)
# A variable whose name matches this is taken to hold a secret: its value is
# kept encrypted, never in VM.json. Short words count only as a whole part of
# the name (ADO_PAT, not PATHEXT).
$script:SecretVariablePattern = '(?i)SECRET|PASSWORD|PASSWD|TOKEN|CONNECTIONSTRING|CREDENTIAL|APIKEY|(^|_)(KEY|PAT|PWD)(_|$)'

# Every version of VM.json LazyVM writes is kept in <Name>\Config\History as
# VM-<stamp>.json: the newest few, and any a tooling checkpoint still needs.
$script:HistoryFolderName = 'History'
$script:ProfileVersionsToKeep = 3

# Before #130 the tooling list had files of its own beside VM.json. A VM
# that still has them gets them folded into VM.json once (ToolingMigration.ps1).
$script:LegacyToolingFileName = 'Tooling.json'
$script:LegacyToolingTemplateFileName = 'Tooling.Template.json'

# Every scheduled task LazyVM registers, on the host or in the guest, starts
# with this; the guest capture leaves such tasks out.
$script:TaskPrefix = 'LazyVM-'

# Checkpoint names: '<prefix> <yyyyMMdd-HHmmss>[ <note>]'.
$script:ToolingCheckpointPrefix = 'Tooling'
$script:ExpansionCheckpointPrefix = 'C: expansion'
$script:StampFormat = 'yyyyMMdd-HHmmss'

# The capture manifest in each VM's StateDir.
$script:ManifestFileName = 'manifest.json'
