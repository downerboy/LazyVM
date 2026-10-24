# Constants.ps1 - Names LazyVM uses in more than one place, defined once.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

# Where the root folder is recorded for every later run, including the
# scheduled tasks, which run as SYSTEM. Each VM's resume point is a subkey.
$script:RootRegistryKey = 'HKLM:\SOFTWARE\LazyVM'

# Inside the guest: the answer file's first-logon command sets Provisioned=1
# here once Windows Setup and OOBE are done.
$script:GuestMarkerKey = 'HKLM:\SOFTWARE\LazyVM'

# The settings files in <Root>\Config, and each VM's files in Config\VMs\<Name>.
$script:SettingsFileName = 'LazyVM.Settings.json'
$script:ProfileFileName = 'VM.json'
$script:SchemaFileName = 'LazyVM.Settings.schema.json'
$script:ToolingFileName = 'Tooling.json'
$script:DefaultToolingFileName = 'Tooling.Default.json'

# Every scheduled task LazyVM registers, on the host or in the guest, starts
# with this; the guest capture leaves such tasks out.
$script:TaskPrefix = 'LazyVM-'

# Checkpoint names: '<prefix> <yyyyMMdd-HHmmss>[ <note>]'.
$script:ToolingCheckpointPrefix = 'Tooling'
$script:ExpansionCheckpointPrefix = 'C: expansion'
$script:StampFormat = 'yyyyMMdd-HHmmss'

# The capture manifest in each VM's StateDir.
$script:ManifestFileName = 'manifest.json'
