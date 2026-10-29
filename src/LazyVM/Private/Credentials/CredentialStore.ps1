# CredentialStore.ps1 - Encrypted store for the guest and certificate passwords.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# A machine key file, readable by SYSTEM and Administrators only, rather than
# DPAPI: credentials stored by an administrator must be readable by the
# scheduled maintenance, which runs as SYSTEM. Anyone who is an administrator
# on the host can therefore read them, which is acceptable for a developer VM
# on the developer's own machine.
#
# Get- functions only read. A missing key or credential file is created only
# by Initialize-CredentialKey and Get-OrNewStoredCredential, and nothing here
# ever deletes a stored credential.

function Get-CredentialKey {
    <# The key from $Path, or $null when there is none yet. Throws when the file is not a key. #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $key = [IO.File]::ReadAllBytes($Path)
    if ($key.Length -ne 32) {
        throw "The credential key $Path is damaged ($($key.Length) bytes instead of 32), so the stored passwords cannot be read. Restore it from a backup, or delete it and store each VM's password again with Set-LazyVMCredential."
    }
    return $key
}

function New-CredentialKey {
    <#
      Creates a new key at $Path, readable by SYSTEM and Administrators only.
      The file is created with that access in one step, so it is never
      readable by anyone else, even for a moment. Returns the key.
    #>
    param([Parameter(Mandatory)][string]$Path)

    New-Folder -Path (Split-Path -Path $Path -Parent)

    $security = [System.Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    # SYSTEM and Administrators.
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
        $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                [System.Security.Principal.SecurityIdentifier]::new($sid),
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow))
    }

    $key = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($key)
    $stream = [System.IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($Path), [IO.FileMode]::CreateNew,
        [System.Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $security)
    try { $stream.Write($key, 0, $key.Length) }
    finally { $stream.Dispose() }

    $file = Get-Item -LiteralPath $Path -Force
    $file.Attributes = $file.Attributes -bor [IO.FileAttributes]::Hidden
    Write-LogEntry 'Generated a new credential key (SYSTEM and Administrators only)' 'OK'
    return $key
}

function Initialize-CredentialKey {
    <# The key at $Path, created first if there is none. #>
    param([Parameter(Mandatory)][string]$Path)

    $key = Get-CredentialKey -Path $Path
    if ($key) { return $key }
    return New-CredentialKey -Path $Path
}

function Save-StoredCredential {
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][securestring]$Password
    )

    $key = Initialize-CredentialKey -Path $KeyPath
    $blob = [pscustomobject]@{
        UserName = $UserName
        Password = ConvertFrom-SecureString -SecureString $Password -Key $key
    }
    Write-TextFileAtomic -Path $Path -Text (ConvertTo-Json -InputObject $blob)
}

function Get-StoredCredential {
    <#
      The credential stored at $Path, or $null when none is stored. Throws
      when one is stored but cannot be read, so "not stored" and "cannot be
      read" are never mistaken for each other.
    #>
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $key = Get-CredentialKey -Path $KeyPath
    if (-not $key) {
        throw "The credential at $Path cannot be read: its key, $KeyPath, is missing. Store the password again with Set-LazyVMCredential."
    }
    try {
        $blob = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $secure = ConvertTo-SecureString -String $blob.Password -Key $key
        return [pscredential]::new($blob.UserName, $secure)
    }
    catch {
        throw "The credential at $Path cannot be read ($($_.Exception.Message)). Store the password again with Set-LazyVMCredential."
    }
}

function Get-StoredSecretTable {
    <# The name -> value table stored, encrypted, at $Path; empty when none is stored. #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Path
    )

    $stored = Get-StoredCredential -KeyPath $KeyPath -Path $Path
    if (-not $stored) { return @{} }
    $values = ConvertTo-PlainText -Secure $stored.Password | ConvertFrom-Json -AsHashtable
    if (-not $values) { return @{} }
    return $values
}

function Save-StoredSecretTable {
    <# Stores a name -> value table, encrypted, at $Path, replacing what was stored. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The values come out of the guest as text and are encrypted here, straight away.')]
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Secrets
    )

    $text = ConvertTo-Json -InputObject $Secrets -Depth 5 -Compress
    Save-StoredCredential -KeyPath $KeyPath -Path $Path -UserName $UserName -Password (ConvertTo-SecureString -String $text -AsPlainText -Force)
}

function New-RandomPassword {
    <#
      A random password that always meets Windows' complexity rules: one of
      each character class, then random characters, shuffled.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The generated password becomes a SecureString straight away, here and nowhere else.')]
    [OutputType([securestring])]
    param([int]$Length = 24)

    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'.ToCharArray()
    $lower = 'abcdefghijkmnopqrstuvwxyz'.ToCharArray()
    $digit = '23456789'.ToCharArray()
    $punct = '!@#$%^&*-_=+'.ToCharArray()
    $all = $upper + $lower + $digit + $punct

    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $upper, $lower, $digit, $punct) { $chars.Add($set[[Security.Cryptography.RandomNumberGenerator]::GetInt32($set.Length)]) }
    while ($chars.Count -lt $Length) { $chars.Add($all[[Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }

    # Fisher-Yates, so the guaranteed classes are not always first.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        $chars[$i], $chars[$j] = $chars[$j], $chars[$i]
    }
    return ConvertTo-SecureString -String (-join $chars) -AsPlainText -Force
}

function Get-OrNewStoredCredential {
    <#
      The credential stored at $Path, or, when none is stored, a new one for
      $UserName with a generated password, stored first. Returns it with
      Generated saying which.
    #>
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$UserName
    )

    $existing = Get-StoredCredential -KeyPath $KeyPath -Path $Path
    if ($existing) { return [pscustomobject]@{ Credential = $existing; Generated = $false } }

    $password = New-RandomPassword
    Save-StoredCredential -KeyPath $KeyPath -Path $Path -UserName $UserName -Password $password
    return [pscustomobject]@{ Credential = [pscredential]::new($UserName, $password); Generated = $true }
}

function ConvertTo-PlainText {
    param([Parameter(Mandatory)][securestring]$Secure)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
