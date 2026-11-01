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
# Describes a config template file; refers to the settings schema beside it.
$script:TemplateSchemaFileName = 'LazyVM.Template.schema.json'
# The folder of config templates (Template.ps1): the built-in ones in the
# module's Data folder, the user's own in <Root>\Shared. A template's name
# is the Name field in its file; LazyVM.Template.schema.json has the same rule.
$script:TemplatesFolderName = 'Templates'
$script:TemplateNamePattern = '^[A-Za-z0-9][A-Za-z0-9-]{0,63}$'
# The setting in VM.json that holds the VM's tooling list.
$script:ToolingSettingName = 'Tooling'
# What a winget package identifier looks like (WingetMatch.ps1); anything
# else read back from the guest is not taken as one.
$script:WingetIdPattern = '^[A-Za-z0-9][A-Za-z0-9._+-]*$'
# The setting in VM.json that holds the guest's environment (GuestEnvironment.ps1).
$script:GuestEnvironmentSettingName = 'GuestEnvironment'
# The setting in VM.json that holds the guest's own firewall rules (GuestFirewall.ps1).
$script:GuestFirewallSettingName = 'GuestFirewallRules'
# The setting in VM.json that holds the guest's own scheduled tasks (GuestScheduledTask.ps1).
$script:GuestScheduledTaskSettingName = 'GuestScheduledTasks'
# The setting in VM.json that holds the guest's SQL logins and instance settings (GuestSql.ps1).
$script:GuestSqlSettingName = 'GuestSql'
# The setting in VM.json that holds the values under the AppSettings keys (GuestAppSetting.ps1).
$script:GuestAppSettingName = 'GuestAppSettings'
# What LazyVM records from inside a VM: it belongs to that VM alone (and the
# VM that replaces it on a rebuild), so it is never copied to another VM or
# put in a config template. GuestSql holds logins with password hashes.
$script:RecordedGuestStateSettings = @(
    $script:GuestEnvironmentSettingName
    $script:GuestFirewallSettingName
    $script:GuestScheduledTaskSettingName
    $script:GuestSqlSettingName
    $script:GuestAppSettingName
)

# Environment variables Windows sets itself: a fresh install has its own, so
# they are neither recorded nor put back.
$script:WindowsVariableNames = @(
    'ComSpec', 'DriverData', 'NUMBER_OF_PROCESSORS', 'OneDrive', 'OneDriveConsumer', 'OS', 'Path', 'PATHEXT',
    'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER', 'PROCESSOR_LEVEL', 'PROCESSOR_REVISION',
    'PSModulePath', 'TEMP', 'TMP', 'USERNAME', 'windir'
)
# An environment variable or registry value whose name matches this is taken
# to hold a secret: its value is kept encrypted, never in VM.json. Short words
# count only as a whole part of the name, split by _ (ADO_PAT, not PATHEXT) or
# by case (AccessKey, not KeyboardLayout).
$script:SecretVariablePattern = '(?i)SECRET|PASSWORD|PASSWD|PASSPHRASE|TOKEN|CONNECTIONSTRING|CREDENTIAL|APIKEY|(^|_)(KEY|PAT|PWD)(_|$)|(?-i:[a-z](Key|Pat|Pwd)(?![a-z]))'

# Every version of VM.json LazyVM writes is kept in <Name>\Config\History as
# VM-<stamp>.json: the newest few, and any a tooling checkpoint still needs.
$script:HistoryFolderName = 'History'
$script:ProfileVersionsToKeep = 3

# Before #130 the tooling list had files of its own beside VM.json. A VM
# that still has them gets them folded into VM.json once (ToolingMigration.ps1).
$script:LegacyToolingFileName = 'Tooling.json'
$script:LegacyToolingTemplateFileName = 'Tooling.Template.json'

# winget's exit code for a package that is already installed and up to date.
$script:WingetUpToDateExitCode = -1978335189

# What the winget exit codes that actually come up mean, so the log explains
# itself; the installs and the upgrades both use it. The keys are strings
# because the table travels to a guest task as JSON, and Windows PowerShell
# 5.1 writes only string keys.
$script:WingetExitMeanings = @{
    '-2147012889' = 'DNS could not be resolved - the guest has no working internet'
    '-2147012894' = 'the connection timed out - the guest network is slow or blocked'
    '-2147012867' = 'could not connect to the server'
    '-2147012721' = 'content decoding failed - check for a proxy intercepting HTTPS'
    '-2147012739' = 'a secure channel error - check the date, time and certificates in the guest'
    "$script:WingetUpToDateExitCode" = 'already installed and up to date'
    '-1978335212' = 'no package matched that identifier'
    '-1978335215' = 'no applicable installer for this system'
    '-1978334972' = 'the installer hash did not match'
    '-1978335216' = 'the source could not be updated'
    '-1978335226' = 'the package''s own installer failed'
}

# winget packages the nightly upgrades never touch (#235): Visual Studio and
# SQL Server are serviced by their own installers, and a winget upgrade can
# break a working install of either. Wildcards as -like takes them.
$script:WingetUpgradeNever = @('Microsoft.VisualStudio.*', 'Microsoft.SQLServer.*', 'Microsoft.SQLServerManagementStudio*')

# Every scheduled task LazyVM registers, on the host or in the guest, starts
# with this; the guest capture leaves such tasks out.
$script:TaskPrefix = 'LazyVM-'

# Settings LazyVM once had and no longer uses, deleted from the schema. A
# settings file that still names one is read without it rather than
# refused, and VM.json is written back without it (#273).
$script:RetiredSettingNames = @('GuestProjectPaths', 'ProjectExcludeDirs', 'MaxProjectCaptureGB', 'GuestRestoreRoot')

# Checkpoint names: '<prefix> <yyyyMMdd-HHmmss>[ <note>]'.
$script:ToolingCheckpointPrefix = 'Tooling'
$script:ExpansionCheckpointPrefix = 'C: expansion'
$script:UserDiskBackupCheckpointPrefix = 'User disk backup'
$script:StampFormat = 'yyyyMMdd-HHmmss'

# The capture manifest in each VM's StateDir: a copy of the newest capture's,
# which restore reads. Each capture has a folder of its own, named by its
# stamp, under StateDir\Captures; the newest few are kept (#21).
$script:ManifestFileName = 'manifest.json'
$script:CaptureFolderName = 'Captures'
$script:CapturesToKeep = 3

# The folders on the User disk (#137), each named for its folder there.
# A ShellFolder is redirected through the User Shell Folders key, with any
# Aliases Windows keeps for it; a Link, under %USERPROFILE%, becomes a
# junction to the folder.
$script:UserDiskFolders = @(
    @{ Name = 'Documents'; ShellFolder = 'Personal'; Aliases = @('{F42EE2D3-909F-4907-8871-4C22FC0BF756}') }
    @{ Name = 'Desktop'; ShellFolder = 'Desktop'; Aliases = @() }
    @{ Name = 'Downloads'; ShellFolder = '{374DE290-123F-4565-9164-39C4925E467B}'; Aliases = @('{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}') }
    @{ Name = '.ssh'; Link = '.ssh' }
    @{ Name = 'repos'; Link = 'source\repos' }
)

# The User disk's copy (#139) warns when its files fill more than this share
# of UserDiskSizeGB: a disk that full is slow to copy and close to running out.
$script:UserDiskLargeShare = 0.75

# The SQL Server edition every VM gets (#136): Standard Developer, so code
# cannot come to depend on Enterprise-only features. The Enterprise Developer
# ISO installs it when given this product key.
$script:SqlEditionName = 'SQL Server 2025 Standard Developer'
$script:SqlEditionProductKey = '33333-00000-00000-00000-00000'
