# Acceptance tests

These tests drive a real Hyper-V VM from start to finish. They take hours and need a Hyper-V host, so CI does not run them. `./Invoke-AnalyzerAndTest.ps1` leaves them out too, because they are tagged `Acceptance`.

The comparison logic they use, [RebuildComparison.ps1](RebuildComparison.ps1), is made of pure functions. Its unit tests, [tests/RebuildComparison.Tests.ps1](../RebuildComparison.Tests.ps1), run in CI with the rest of the tests.

## Rebuild from VM.json (#39)

[RebuildFromProfile.Tests.ps1](RebuildFromProfile.Tests.ps1) checks that `VM.json` is the VM's complete, living configuration (#97). It does five things:

1. Builds a new VM from the template (`New-LazyVM`, `Build-LazyVM`).
2. Makes these changes by hand in the guest:
   - **Tooling:** installs the winget package `7zip.7zip`.
   - **Settings:** sets the machine environment variable `LAZYVM_ACCEPTANCE=39` and adds the inbound firewall rule `LazyVM acceptance #39` for TCP port 39039.
   - **SQL state:** creates the `LazyVMAcceptance` database, with one row in `dbo.Marker`.
   - **User data:** writes `LazyVMAcceptance\marker.txt` on the User disk.
3. Captures the VM (`Save-LazyVMTooling`, `Save-LazyVMState`) and takes a snapshot of the guest.
4. Rebuilds it from VM.json alone (`Invoke-LazyVMRebuild -SkipCapture -Force`), with no hand edits to any configuration.
5. Takes another snapshot and compares the two.

It passes when every hand change is still there after the rebuild and the two snapshots match. A snapshot covers the winget packages, the Visual Studio Installer products, the environment variables, the firewall rules added in the guest, the scheduled tasks in the root folder, the user databases with their marker rows, and the marker data on the User disk. On a failure, the test lists each entry the rebuilt guest lost or gained.

### Running it

You need:
- a Hyper-V host
- an elevated PowerShell 7
- LazyVM's root set up (`Set-LazyVMRoot`)
- the install media your settings name

Pick a name for a VM that does not exist yet. The test refuses to start if a Hyper-V VM or a LazyVM profile with that name already exists, so it never touches any other VM.

```powershell
$env:LAZYVM_ACCEPTANCE_VM = 'LazyAccept39'
# Optional: the SQL Server instance in the guest. The default is '.', the default instance.
# $env:LAZYVM_ACCEPTANCE_SQLSERVER = '.\SQLEXPRESS'
Import-Module Pester -MinimumVersion 5.0
$configuration = New-PesterConfiguration
$configuration.Run.Path = 'tests/Acceptance'
$configuration.Filter.Tag = 'Acceptance'
$configuration.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $configuration
```

If `LAZYVM_ACCEPTANCE_VM` is not set, the test is skipped.

The test VM is left in place afterwards so you can inspect it. Delete it when you are done:

```powershell
Remove-LazyVM -Name LazyAccept39
```
