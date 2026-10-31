# OfficialInstaller.ps1 - Installing what winget and the Marketplace do not have (#24).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  OFFICIAL INSTALLERS
#
#  The tooling list's Installers name, for a program or a per-user extension,
#  the publisher's own download and its silent-install arguments. A build
#  runs one only for an item the guest still lacks, and only when:
#    - the entry is complete: an HTTPS URL, a publisher, arguments without
#      quotes or line breaks, a well-formed hash if one is pinned
#    - the download, made in the guest into a folder only administrators can
#      change, is an .exe or .msi by its content, not its name
#    - it has a valid Authenticode signature from the named publisher, and
#      the pinned hash when there is one
#  The installer then runs as a guest task that holds the file open against
#  changes and checks its hash again first, so what runs is exactly what was
#  checked. Nothing is ever run through Invoke-Expression. Anything refused
#  or failed is logged and stays on the reinstall-by-hand list.
# ─────────────────────────────────────────────────────────────────────────────

# The guest task's work: runs the checked file and returns its exit code.
# Runs in a fresh powershell.exe with no helpers loaded, so it is
# self-contained. The file stays open, shared for reading only, until the
# installer has finished, so nothing can change or replace it meanwhile.
$script:OfficialInstallerWork = {
    param($filePath, $sha256, $command, $arguments)
    $lock = [IO.File]::Open($filePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $actual = -join ($hasher.ComputeHash($lock) | ForEach-Object { $_.ToString('X2') }) }
        finally { $hasher.Dispose() }
        if ($actual -ne $sha256) { throw "the installer changed after it was checked (SHA-256 $actual), so it was not run" }

        $process = if ($arguments) {
            Start-Process -FilePath $command -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
        }
        else {
            Start-Process -FilePath $command -Wait -PassThru -WindowStyle Hidden
        }
        return $process.ExitCode
    }
    finally { $lock.Dispose() }
}

function Get-OfficialInstallerProblem {
    <# Why an installer entry must not be used, one line each; nothing when it may. #>
    param([Parameter(Mandatory)][OfficialInstaller]$Installer)

    if (-not "$($Installer.Name)".Trim()) { 'it names no program or extension' }

    $uri = $null
    if (-not [uri]::TryCreate($Installer.Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        "its download is not an HTTPS URL: '$($Installer.Url)'"
    }
    elseif ($uri.UserInfo) { 'its download URL carries a user name or password' }

    if (-not "$($Installer.Publisher)".Trim()) { 'it names no publisher to check the signature against' }
    if ($Installer.Sha256 -and $Installer.Sha256 -notmatch '^[0-9A-Fa-f]{64}$') { 'its Sha256 is not a SHA-256 hash' }

    foreach ($argument in @($Installer.Arguments)) {
        if ("$argument" -match '["\x00-\x1F]') { "an argument has a quote or a control character: '$argument'" }
    }
}

function Join-CommandLineArgument {
    <#
      Joins arguments into one command line, quoting each that is empty or
      has a space, so each reaches the program whole. Arguments never hold
      quotes (Get-OfficialInstallerProblem refuses them); a quoted one's
      trailing backslashes are doubled so they do not escape its closing quote.
    #>
    param([AllowEmptyCollection()][string[]]$ArgumentList = @())

    $quoted = foreach ($argument in $ArgumentList) {
        if ($argument -and $argument -notmatch '\s') { $argument; continue }
        $trailing = ([regex]::Match($argument, '\\*$')).Value
        '"{0}{1}"' -f $argument, $trailing
    }
    return (@($quoted) -join ' ')
}

function Install-OfficialInstaller {
    <#
      Runs the official installer of each program and per-user extension in
      the tooling list that the guest lacks and that has one. Each is
      independent: one refused or failed is logged and the rest carry on,
      and nothing here stops the build.
    #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][ToolingRecord]$Tooling
    )

    $hasInstaller = @($Tooling.Programs | Where-Object { $_ -and $Tooling.FindInstaller($_.Name) }).Count -gt 0 -or
    @($Tooling.Products | ForEach-Object { $_.UserExtensions } | Where-Object { $_ -and $Tooling.FindInstaller($_.Id) }).Count -gt 0
    if (-not $hasInstaller) { return }

    $observed = ConvertTo-ToolingRecord -Inventory (Get-GuestToolingInventory -VM $VM) -WingetExclude $VM.Settings.ToolingWingetExclude
    $present = @($observed.Programs | ForEach-Object { $_.Name })
    $missing = @($Tooling.Programs | Where-Object { $_ -and $present -notcontains $_.Name } | ForEach-Object { $_.Name }) +
    @(foreach ($product in @($Tooling.Products)) {
            Get-MissingProductExtension -Product $product -Observed $observed.FindProduct($product.Key()) | Where-Object { $_.Id } | ForEach-Object { $_.Id }
        })
    $installers = @($missing | ForEach-Object { $Tooling.FindInstaller($_) } | Where-Object { $_ } | Sort-Object Name -Unique)
    if ($installers.Count -eq 0) { return }

    Write-LogEntry "Installing $($installers.Count) item(s) from their official installers..." 'INFO'
    foreach ($installer in $installers) {
        Install-OfficialInstallerItem -VM $VM -Installer $installer
    }
}

function Install-OfficialInstallerItem {
    <# Downloads, checks and runs one official installer (see Install-OfficialInstaller). Never throws. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][OfficialInstaller]$Installer
    )

    $label = $Installer.Name
    $problems = @(Get-OfficialInstallerProblem -Installer $Installer)
    if ($problems.Count -gt 0) {
        Write-LogList -Heading "$label - not installed: its installer entry in the tooling list is not usable:" -Items $problems -Level WARN
        return
    }

    $folder = Join-Path -Path $VM.Settings.GuestSetupDir -ChildPath ('installers\{0}' -f [guid]::NewGuid().ToString('N'))
    try {
        $prepared = Invoke-GuestScript -VM $VM -Activity "$label download" -TimeoutMinutes 45 `
            -ArgumentList @($Installer.Url, $Installer.Publisher, $Installer.Sha256, $folder) -ScriptBlock {
            param($url, $publisher, $sha256, $folder)
            $ErrorActionPreference = 'Stop'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            New-GuestPrivateFolder -Path $folder
            try {
                $download = Join-Path $folder 'download'
                $response = Invoke-WebRequest -Uri $url -OutFile $download -UseBasicParsing -TimeoutSec 1800 -PassThru
                # .NET never follows a redirect from HTTPS to HTTP; checked all the same.
                if ($response.BaseResponse.ResponseUri.Scheme -ne 'https') { throw "the download ended up at $($response.BaseResponse.ResponseUri), not HTTPS" }

                $kind = Get-GuestInstallerKind -Path $download
                if (-not $kind) { throw 'the download is not an .exe or .msi installer' }
                $file = Join-Path $folder "installer.$kind"
                Move-Item -LiteralPath $download -Destination $file

                $problem = Get-GuestInstallerProblem -Path $file -Publisher $publisher -Sha256 $sha256
                if ($problem) { throw "the download was refused: $problem" }
                return [pscustomobject]@{ FilePath = $file; Kind = $kind; Sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash }
            }
            catch {
                Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
                throw
            }
        }
    }
    catch {
        Write-LogEntry "$label - not installed: $($_.Exception.Message)" 'WARN'
        return
    }

    # What the guest returned is checked before it is used.
    $kind = [RecordReader]::Text($prepared, 'Kind')
    $filePath = [RecordReader]::Text($prepared, 'FilePath')
    $sha256 = [RecordReader]::Text($prepared, 'Sha256')
    if ($kind -notin 'exe', 'msi' -or $sha256 -notmatch '^[0-9A-Fa-f]{64}$' -or -not $filePath.StartsWith("$folder\", [StringComparison]::OrdinalIgnoreCase)) {
        Write-LogEntry "$label - not installed: the guest's check of the download returned something unexpected" 'WARN'
        return
    }

    if ($kind -eq 'msi') {
        $command = 'msiexec.exe'
        $arguments = Join-CommandLineArgument -ArgumentList (@('/i', $filePath) + @($Installer.Arguments))
    }
    else {
        $command = $filePath
        $arguments = Join-CommandLineArgument -ArgumentList @($Installer.Arguments)
    }

    Write-LogEntry "$label - installing from $($Installer.Url) (signed by $($Installer.Publisher))..." 'INFO'
    try {
        $exitCode = Invoke-GuestTask -VM $VM -TaskName "${script:TaskPrefix}official-installer" -Work $script:OfficialInstallerWork `
            -ArgumentList @($filePath, $sha256, $command, $arguments) -TimeoutMinutes 60 -Activity "the $label install" -RestartAttempts 1
        $null = Test-InstallExitCode -Product $label -ExitCode $exitCode
    }
    catch {
        Write-LogEntry "$label - not installed: $($_.Exception.Message)" 'WARN'
    }
    finally {
        try {
            $null = Invoke-GuestScript -VM $VM -Activity "tidying up after $label" -TimeoutMinutes 2 -ArgumentList @($folder) -ScriptBlock {
                param($folder) Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch { Write-LogEntry "  could not remove $folder in the guest: $($_.Exception.Message)" 'INFO' }
    }
}
