# ProgramInstaller.ps1 - Programs a rebuild installs from an official installer the tooling list names (#24).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# A program winget does not install can be given an Installer in the VM's
# tooling list: an https address, silent-install arguments, and the name its
# Authenticode signature must be from. The daily recording keeps it, and a
# rebuild downloads, checks and runs it. One that cannot be installed this
# way stays on the reinstall-by-hand list.

function Test-ToolingInstaller {
    <# Why the tooling list's $Installer cannot be used, or $null when it can. Looks only at what the list says. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][ToolingInstaller]$Installer)

    $address = $null
    if (-not [Uri]::TryCreate($Installer.Url, [UriKind]::Absolute, [ref]$address) -or $address.Scheme -ne 'https') {
        return "its Url must be an https address, not '$($Installer.Url)'"
    }
    if ([IO.Path]::GetExtension($address.AbsolutePath) -notin '.exe', '.msi') {
        return "its Url must name an .exe or .msi installer: $($Installer.Url)"
    }
    if (-not $Installer.SignedBy) {
        return 'it has no SignedBy: the name its signing certificate is issued to'
    }
    return $null
}

function Add-ProgramInstaller {
    <# Gives each program in $Record the Installer $Previous names for it, among its programs or those awaiting reinstall. Updates $Record in place. #>
    param(
        [Parameter(Mandatory)][ToolingRecord]$Record,
        [AllowNull()][ToolingRecord]$Previous
    )

    if (-not $Previous) { return }
    $known = @{}
    foreach ($program in @(@($Previous.Programs) + @($Previous.Awaiting().Programs))) {
        if ($program -and $program.Installer) { $known[$program.Name] = $program.Installer }
    }
    foreach ($program in @($Record.Programs)) {
        if ($program -and -not $program.Installer -and $known.ContainsKey($program.Name)) { $program.Installer = $known[$program.Name] }
    }
}

function Install-ToolingProgram {
    <#
      Installs each program in $Tooling, or awaiting reinstall in it, that
      has an Installer and is not in the guest yet. Each is independent: one
      that cannot be downloaded, fails its signature check or fails to
      install is reported and the rest carry on. Needs the guest network.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][ToolingRecord]$Tooling
    )

    $candidates = @(@($Tooling.Programs) + @($Tooling.Awaiting().Programs) | Where-Object { $_ -and $_.Installer } |
            Group-Object Name | ForEach-Object { $_.Group[0] })
    if ($candidates.Count -eq 0) { return }

    $observed = ConvertTo-ToolingRecord -Inventory (Get-GuestToolingInventory -VM $VM) -WingetExclude $VM.Settings.ToolingWingetExclude
    $present = @($observed.Programs | ForEach-Object { $_.Name })
    foreach ($program in @($candidates | Where-Object { $present -notcontains $_.Name })) {
        Install-ProgramFromInstaller -VM $VM -Program $program
    }
}

function Install-ProgramFromInstaller {
    <# Downloads $Program's installer into the guest, checks its signature there (Save-GuestVerifiedInstaller), and runs it detached. Never throws. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][ToolingProgram]$Program
    )

    $installer = $Program.Installer
    $problem = Test-ToolingInstaller -Installer $installer
    if ($problem) {
        Write-LogEntry "$($Program.Name) - not installed from its installer: $problem" 'WARN'
        return
    }

    $extension = [IO.Path]::GetExtension(([Uri]$installer.Url).AbsolutePath).ToLowerInvariant()
    $safeName = ($Program.Name -replace '[^A-Za-z0-9]+', '-').Trim('-')
    $guestPath = Join-Path -Path $VM.Settings.GuestSetupDir -ChildPath "installer-$safeName$extension"
    try {
        Write-LogEntry "$($Program.Name) - downloading its installer from $($installer.Url)" 'INFO'
        $null = Invoke-GuestScript -VM $VM -Activity "downloading the $($Program.Name) installer" -TimeoutMinutes 30 `
            -ArgumentList @($installer.Url, $guestPath, $installer.SignedBy) -ScriptBlock {
            param($url, $path, $signedBy) Save-GuestVerifiedInstaller -Url $url -Path $path -SignedBy $signedBy
        }

        $run = if ($extension -eq '.msi') { @{ FilePath = 'msiexec.exe'; ArgumentList = @('/i', "`"$guestPath`"", $installer.Arguments) } }
        else { @{ FilePath = $guestPath; ArgumentList = @($installer.Arguments) } }
        $exitCode = Invoke-GuestInstaller -VM $VM @run -Name "program-$safeName" -Activity "$($Program.Name) install" -TimeoutMinutes 60
        $null = Test-InstallExitCode -Product $Program.Name -ExitCode $exitCode
    }
    catch {
        Write-LogEntry "$($Program.Name) - not installed from its installer: $($_.Exception.Message)" 'WARN'
    }
}
