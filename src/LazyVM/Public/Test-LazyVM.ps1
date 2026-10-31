function Test-LazyVM {
    <#
    .SYNOPSIS
    Reports what LazyVM can see of a VM, to find out why it is not working. Changes nothing.

    .DESCRIPTION
    Checks, without changing anything:

      - the LazyVM folder and where it was found (-Root or the registry);
      - the Windows and SQL Server ISO paths, and whether each is a valid image;
      - the VM's state and heartbeat;
      - whether PowerShell Direct works with the stored guest account;
      - the guest's last boot time, OOBE state and provisioning marker;
      - automatic sign-in: whether it is on, and for which user;
      - the maintenance task's last run and result.

    The VM is never started: when it is not running, the guest checks are
    skipped. Opening the guest session waits up to a minute. Nothing is
    written to the VM's settings or its log; the only file written is the
    report, when -ReportPath is given.

    .PARAMETER Name
    The VM. May be left out while there is only one.

    .PARAMETER ReportPath
    Also writes the result as a text report to this file, replacing it if it
    is there.

    .EXAMPLE
    Test-LazyVM -Name DevBox

    .EXAMPLE
    Test-LazyVM -Name DevBox -ReportPath .\DevBox-diagnostic.txt

    .EXAMPLE
    (Test-LazyVM -Name DevBox).Isos

    .OUTPUTS
    LazyVM.Diagnostic
    #>
    [CmdletBinding()]
    [OutputType('LazyVM.Diagnostic')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Name,

        [ValidateNotNullOrEmpty()]
        [string]$ReportPath
    )

    process {
        Assert-Administrator
        $vm = $null
        try {
            $root = Resolve-LazyVMRoot
            $configuration = Read-VMSetting -Root $root.Path -VMName $Name -Unattended:(Test-Unattended)
            $vm = [VMContext]::new($configuration.Settings)
            $diagnostic = Get-VMDiagnostic -VM $vm -Root $root

            if ($ReportPath) {
                $path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($ReportPath)
                Write-TextFileAtomic -Path $path -Text (Format-VMDiagnostic -Diagnostic $diagnostic)
            }
            $diagnostic
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
        finally {
            if ($vm) { Remove-GuestSession -VM $vm }
        }
    }
}
