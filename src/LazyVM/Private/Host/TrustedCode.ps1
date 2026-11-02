# TrustedCode.ps1 - The code LazyVM's scheduled tasks run as SYSTEM (#284).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# A task runs PowerShell and this module as SYSTEM. If anyone but an
# administrator could change either, they could run their own code as
# SYSTEM. So Install.ps1 puts the module in Program Files, where only
# administrators and SYSTEM can change it, and a task is registered only
# when PowerShell, the module and the folder the task imports it from are
# all that way.

# The accounts that may change the code the tasks run: Administrators,
# SYSTEM and TrustedInstaller.
$script:TrustedCodeWriters = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')

# Rights that change a folder or what is in it: write and append data,
# extended attributes and attributes, delete (the folder, or anything in
# it), change permissions, take ownership, and generic write or all.
$script:WriteRights = [long]0x500D0156

function Get-InstalledModuleFolder {
    <# Where Install.ps1 puts LazyVM: %ProgramFiles%\LazyVM\Modules. Install.ps1 names the same folder. #>
    [OutputType([string])]
    param()

    return Join-Path -Path $env:ProgramFiles -ChildPath 'LazyVM/Modules'
}

function Get-ModuleImportPath {
    <#
      What a scheduled task imports, by path: the tasks run as SYSTEM, whose
      module path does not include the user's. Installed (in
      <folder>\LazyVM\<version>), the LazyVM folder above the version, so
      PowerShell loads the newest version installed and an update needs no
      new tasks; otherwise the manifest it was loaded from.
    #>
    [OutputType([string])]
    param()

    $moduleBase = (Get-LazyVMModuleBase).TrimEnd('\', '/')
    $parent = Split-Path -Path $moduleBase -Parent
    if ((Split-Path -Path $moduleBase -Leaf) -as [version] -and (Split-Path -Path $parent -Leaf) -eq 'LazyVM') { return $parent }
    return [IO.Path]::Combine($moduleBase, 'LazyVM.psd1')
}

function Get-UntrustedWriter {
    <#
      The accounts, as security identifiers, that the access rules $Rule
      let change a folder, other than administrators, SYSTEM and
      TrustedInstaller. A rule for what is inside only does not count.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rule)

    $Rule | Where-Object { -not $_.InheritOnly -and ([long]$_.Rights -band $script:WriteRights) -and $script:TrustedCodeWriters -notcontains $_.Sid } |
        ForEach-Object { $_.Sid } | Select-Object -Unique
}

function Get-FolderWriteRule {
    <# The allow rules on $Path, as security identifier, rights and whether each applies to what is inside only. #>
    param([Parameter(Mandatory)][string]$Path)

    foreach ($rule in (Get-Acl -LiteralPath $Path).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ("$($rule.AccessControlType)" -ne 'Allow') { continue }
        [pscustomobject]@{
            Sid         = $rule.IdentityReference.Value
            Rights      = [long]$rule.FileSystemRights
            InheritOnly = [bool]($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly)
        }
    }
}

function Assert-TrustedFolder {
    <# Stops when anyone but administrators, SYSTEM and TrustedInstaller can change the folder or file at $Path. #>
    param([Parameter(Mandatory)][string]$Path)

    $writers = @(Get-UntrustedWriter -Rule @(Get-FolderWriteRule -Path $Path))
    if ($writers.Count -gt 0) {
        throw "$Path can be changed by $(@($writers | ForEach-Object { ConvertTo-AccountName -Sid $_ }) -join ', '), so LazyVM's scheduled tasks, which run as SYSTEM, must not run code from it."
    }
}

function Assert-TrustedCode {
    <#
      Stops unless the code a scheduled task runs can be changed by
      administrators, SYSTEM and TrustedInstaller only: this module, the
      folder the task imports it from, and PowerShell.
    #>
    $moduleBase = Get-LazyVMModuleBase
    foreach ($path in @($moduleBase, (Get-ModuleImportPath), $PSHOME) | Select-Object -Unique) {
        Assert-TrustedFolder -Path $path
    }
}
