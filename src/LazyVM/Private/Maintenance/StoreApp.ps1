# StoreApp.ps1 - Asking the Microsoft Store in the guest to update its apps (#233).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function Start-GuestStoreAppUpdate {
    <#
      Asks the Microsoft Store in the guest to check for app updates now.
      The Store updates its apps by itself only while Windows is on and
      idle, and a LazyVM VM is often off, so maintenance asks it every
      night. This only starts the scan: the Store downloads and installs in
      the background as it always does, an app that is open is updated when
      it closes, and downloads cut short by a shutdown carry on next time.

      UpdateScanMethod is the WMI bridge to the EnterpriseModernAppManagement
      CSP's UpdateScan node; it returns 0 when the scan started. The bridge
      answers only LocalSystem, so the call runs as a guest task as SYSTEM
      rather than in the PowerShell Direct session.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $result = Invoke-GuestTask -VM $VM -TaskName "${script:TaskPrefix}store-app-update" -Activity 'Store app updates' -TimeoutMinutes 5 -Work {
        $ErrorActionPreference = 'Stop'
        $appManagement = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction SilentlyContinue
        if (-not $appManagement) { return 'unavailable' }
        return [int]($appManagement | Invoke-CimMethod -MethodName UpdateScanMethod).ReturnValue
    }

    if ("$result" -eq 'unavailable') {
        Write-LogEntry 'Store app updates: the Store''s app management is not available in the guest; Windows still updates Store apps by itself when the VM is idle' 'WARN'
        return
    }
    $returnValue = [int]$result
    if ($returnValue -eq 0) { Write-LogEntry 'Store app updates: the Store is checking for updates and installs them in the background' 'OK' }
    else { Write-LogEntry "Store app updates: the Store did not start its update check (code $returnValue); it still updates apps by itself when the VM is idle" 'WARN' }
}
