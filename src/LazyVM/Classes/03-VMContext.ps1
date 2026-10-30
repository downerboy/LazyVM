# 03-VMContext.ps1 - Everything a command knows about the VM it is working on.
# Loaded before the functions by LazyVM.psm1; not meant to be run on its own.
#
# Functions take the context as -VM rather than reading module-wide state, so
# each one says what it needs and two VMs never share anything by accident.
#
#   Settings  what the settings files say, read once and never changed
#   Runtime   what the run finds out as it goes: the switch actually used,
#             the drive letters the guest gave its disks, the open session

class VMRuntime {
    # The virtual switch the VM is on: SwitchName, or the NAT switch created
    # when that switch does not exist.
    [string]$SwitchName

    # The Windows ISO actually found, which may not be at ISOPath.
    [string]$ISOPath

    # Drive letters the guest actually gave the Dev Drive and the SQL data disk.
    [string]$DevDriveLetter
    [string]$GuestDataDriveLetter

    # The data disks the guest formatted in this run, by their GUID setting
    # (SQLDiskGuid, ...): BitLocker need encrypt only their used space.
    [string[]]$FormattedDisks = @()

    # SQL Server folders on the data disk, following its actual letter.
    [string]$GuestSqlDataDir
    [string]$GuestSqlLogDir
    [string]$GuestSqlBackupDir

    # The account LazyVM signs in to the guest with, from the credential store.
    [string]$GuestAdminUser

    # Where guest-side SQL work connects: localhost, or localhost\<instance>.
    [string]$SqlServer = 'localhost'

    # The PowerShell Direct session, and the credential to reopen it with.
    [object]$Session
    [pscredential]$Credential
}

class VMContext {
    [string]$Name
    [System.Collections.IDictionary]$Settings
    [VMRuntime]$Runtime

    VMContext([System.Collections.IDictionary]$settings) {
        # A read-only copy: nothing after loading may change a setting.
        $copy = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($key in $settings.Keys) { $copy[$key] = $settings[$key] }
        $this.Settings = [System.Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($copy)
        $this.Name = $copy['VMName']

        $this.Runtime = [VMRuntime]::new()
        $this.Runtime.SwitchName = $copy['SwitchName']
        $this.Runtime.ISOPath = $copy['ISOPath']
        $this.Runtime.DevDriveLetter = $copy['DevDriveLetter']
        $this.Runtime.GuestAdminUser = $copy['GuestAdminUser']
        $this.SetDataDriveLetter($copy['GuestDataDriveLetter'])
    }

    # Points the SQL folders at the letter the data disk actually has.
    [void] SetDataDriveLetter([string]$letter) {
        $upper = $letter.ToUpperInvariant()
        $this.Runtime.GuestDataDriveLetter = $upper
        $this.Runtime.GuestSqlDataDir = '{0}:\{1}' -f $upper, $this.Settings['SqlDataFolder']
        $this.Runtime.GuestSqlLogDir = '{0}:\{1}' -f $upper, $this.Settings['SqlLogFolder']
        $this.Runtime.GuestSqlBackupDir = '{0}:\{1}' -f $upper, $this.Settings['SqlBackupFolder']
    }

    # Records the guest's SQL instance as the connection target for later SQL work.
    [void] SetSqlInstance([string]$instance) {
        $this.Runtime.SqlServer = if ($instance -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$instance" }
    }
}
