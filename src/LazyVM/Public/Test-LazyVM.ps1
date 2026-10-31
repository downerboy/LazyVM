function Test-LazyVM {
    <#
    .SYNOPSIS
    Checks what a VM's build and maintenance depend on, changing nothing.

    .DESCRIPTION
    Reports, one check per line:

      - the LazyVM folder and where it was found
      - the Windows and SQL Server ISOs, and whether each is a real ISO image
      - the VM's state and heartbeat
      - whether PowerShell Direct works with the stored account
      - the guest's boot time, Windows set-up state, LazyVM's provisioning
        marker and automatic sign-in
      - the maintenance task's last result and next run

    Each check is OK, INFO, WARN or FAIL. Nothing is changed: a VM that is
    not running is not started, and its guest is not checked. Automatic
    sign-in is shown as on or off with its user name, never its password.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .PARAMETER ReportPath
    Also write the checks to this text file, for sharing or keeping.

    .EXAMPLE
    Test-LazyVM -Name DevBox

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

        [string]$ReportPath
    )

    process {
        Assert-Administrator
        $checks = @(Get-LazyVMDiagnostic -Name $Name)

        if ($ReportPath) {
            $lines = @("LazyVM check of $(if ($checks) { $checks[0].Name } else { $Name }), $(Get-Date -Format 'yyyy-MM-dd HH:mm'), module $($MyInvocation.MyCommand.Module.Version)", '')
            $lines += $checks | ForEach-Object { '{0,-5} {1,-9} {2,-20} {3}' -f $_.Status, $_.Area, $_.Check, $_.Detail }
            Set-Content -LiteralPath $ReportPath -Value $lines -Encoding utf8
        }
        foreach ($check in $checks) { $check }
    }
}
