function Test-LazyVM {
    <#
    .SYNOPSIS
    Checks what a VM's build and maintenance depend on, changing nothing.

    .DESCRIPTION
    Reports, one check per line:

      - the LazyVM folder and where it was found
      - whether Import-Module LazyVM loads this module, or an earlier copy
        that comes before it on PSModulePath
      - the Windows and SQL Server ISOs, and whether each is a real ISO image
      - whether every BitLocker recovery password is exported
        (Export-LazyVMRecoveryKey)
      - the VM's state and heartbeat
      - whether PowerShell Direct works with the stored account
      - the guest's boot time, Windows set-up state, LazyVM's provisioning
        marker and automatic sign-in
      - the maintenance task's last result and next run

    Each check is OK, INFO, WARN or FAIL. Detail says what was found, and
    Fix, when there is a known fix, what to do about it, ending with the
    command to run. Nothing is changed: a VM that is not running is not
    started, and its guest is not checked. Automatic sign-in is shown as on
    or off with its user name, never its password.

    The host checks (the LazyVM folder, its access, OneDrive, the code the
    tasks run and the module copies) come first and need no VM. Before the
    first VM is created they still run, followed by a note that there are no
    VMs yet. With several VMs and no -Name, they run and the VM settings
    check fails, asking which VM.

    .PARAMETER Name
    The VM. May be left out while there is only one, or none yet.

    .PARAMETER HostOnly
    Run only the host checks, touching no VM.

    .PARAMETER ReportPath
    Also write the checks to this text file, for sharing or keeping. Each
    fix goes on its own line under its check.

    .EXAMPLE
    Test-LazyVM -Name DevBox

    .EXAMPLE
    Test-LazyVM -HostOnly

    Checks only this host's LazyVM set-up, for example before the first VM.

    .EXAMPLE
    Test-LazyVM -Name DevBox -ReportPath .\DevBox-check.txt

    .OUTPUTS
    LazyVM.Check
    #>
    [CmdletBinding()]
    [OutputType('LazyVM.Check')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [switch]$HostOnly,

        [string]$ReportPath
    )

    process {
        Assert-Administrator
        $checks = @(Get-LazyVMDiagnostic -Name $Name -HostOnly:$HostOnly)

        if ($ReportPath) {
            $subject = if ($checks -and $checks[0].Name) { $checks[0].Name } elseif ($Name) { $Name } else { $env:COMPUTERNAME }
            $lines = @("LazyVM check of $subject, $(Get-Date -Format 'yyyy-MM-dd HH:mm'), module $($MyInvocation.MyCommand.Module.Version)", '')
            $lines += $checks | ForEach-Object {
                '{0,-5} {1,-9} {2,-20} {3}' -f $_.Status, $_.Area, $_.Check, $_.Detail
                if ($_.Fix) { '{0,-37} Fix: {1}' -f '', $_.Fix }
            }
            Set-Content -LiteralPath $ReportPath -Value $lines -Encoding utf8
        }
        foreach ($check in $checks) { $check }
    }
}
