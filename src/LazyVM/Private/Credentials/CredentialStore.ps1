# CredentialStore.ps1 - Encrypted store for the guest and certificate passwords.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Encrypted with DPAPI for this computer (LocalMachine), with LazyVM's own
# entropy (#284): LazyVM's scheduled tasks run as SYSTEM and the user runs
# LazyVM elevated, and both must read the same secrets. What keeps other
# accounts out is the LazyVM folder's access, the installing user and
# SYSTEM only: a standard user cannot open the files. A local administrator
# can, by taking ownership or running as SYSTEM, and could then decrypt
# them. The files are useless on another computer.
#
# Get- functions only read. A missing credential file is created only by
# Save-StoredCredential and Get-OrNewStoredCredential, and nothing here ever
# deletes a stored credential.

# Marks a file as encrypted this way. Older LazyVM versions wrote files
# without it, encrypted with a machine key file (Convert-LazyVMInstallation
# moves them over).
$script:CredentialProtection = 'DPAPI-LocalMachine'
# Mixed into every encryption, so another program using DPAPI on this
# computer cannot decrypt LazyVM's secrets by accident.
$script:CredentialEntropy = [Text.Encoding]::UTF8.GetBytes('LazyVM credential store')

function Protect-CredentialSecret {
    <# $Secret encrypted with DPAPI for this computer and LazyVM's entropy, as Base64. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][securestring]$Secret)

    Add-Type -AssemblyName System.Security.Cryptography.ProtectedData
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlainText -Secure $Secret))
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $script:CredentialEntropy, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        return [Convert]::ToBase64String($protected)
    }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Unprotect-CredentialSecret {
    <# The secret Protect-CredentialSecret encrypted. Throws when it cannot be decrypted. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'DPAPI hands the secret back as bytes; it becomes a SecureString straight away.')]
    [OutputType([securestring])]
    param([Parameter(Mandatory)][string]$Text)

    Add-Type -AssemblyName System.Security.Cryptography.ProtectedData
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Text), $script:CredentialEntropy, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    try { return ConvertTo-SecureString -String ([Text.Encoding]::UTF8.GetString($bytes)) -AsPlainText -Force }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function ConvertTo-StoredCredentialText {
    <# The text of a credential file: the user name, and the password encrypted for this computer. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][securestring]$Password
    )

    $blob = [pscustomobject]@{
        UserName   = $UserName
        Password   = Protect-CredentialSecret -Secret $Password
        Protection = $script:CredentialProtection
    }
    return ConvertTo-Json -InputObject $blob
}

function ConvertFrom-StoredCredentialText {
    <# The credential in the text of a credential file read from $Path. Throws when it cannot be read. #>
    [OutputType([pscredential])]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Path
    )

    $blob = $Text | ConvertFrom-Json
    if (-not (Test-ProtectedCredentialBlob -Blob $blob)) {
        throw "The credential at $Path was stored by an older LazyVM, with a key every administrator could read. Move it over first: Convert-LazyVMInstallation"
    }
    try {
        return [pscredential]::new($blob.UserName, (Unprotect-CredentialSecret -Text $blob.Password))
    }
    catch {
        throw "The credential at $Path cannot be read ($($_.Exception.Message)): it can only be read on the computer that stored it. Store the password again with Set-LazyVMCredential."
    }
}

function Test-ProtectedCredentialBlob {
    <# Whether a credential file's content is encrypted the way this LazyVM does it, rather than with an older LazyVM's machine key. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][psobject]$Blob)

    return [bool]($Blob.PSObject.Properties['Protection'] -and $Blob.Protection -eq $script:CredentialProtection)
}

function Save-StoredCredential {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][securestring]$Password
    )

    Write-TextFileAtomic -Path $Path -Text (ConvertTo-StoredCredentialText -UserName $UserName -Password $Password)
}

function Get-StoredCredential {
    <#
      The credential stored at $Path, or $null when none is stored. Throws
      when one is stored but cannot be read, so "not stored" and "cannot be
      read" are never mistaken for each other.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return ConvertFrom-StoredCredentialText -Text (Get-Content -LiteralPath $Path -Raw) -Path $Path
}

function Get-StoredSecretTable {
    <# The name -> value table stored, encrypted, at $Path; empty when none is stored. #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $stored = Get-StoredCredential -Path $Path
    if (-not $stored) { return @{} }
    $values = ConvertTo-PlainText -Secure $stored.Password | ConvertFrom-Json -AsHashtable
    if (-not $values) { return @{} }
    return $values
}

function Save-StoredSecretTable {
    <# Stores a name -> value table, encrypted, at $Path, replacing what was stored. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The values come out of the guest as text and are encrypted here, straight away.')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Secrets
    )

    $text = ConvertTo-Json -InputObject $Secrets -Depth 5 -Compress
    Save-StoredCredential -Path $Path -UserName $UserName -Password (ConvertTo-SecureString -String $text -AsPlainText -Force)
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
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$UserName
    )

    $existing = Get-StoredCredential -Path $Path
    if ($existing) { return [pscustomobject]@{ Credential = $existing; Generated = $false } }

    $password = New-RandomPassword
    Save-StoredCredential -Path $Path -UserName $UserName -Password $password
    return [pscustomobject]@{ Credential = [pscredential]::new($UserName, $password); Generated = $true }
}

function ConvertTo-PlainText {
    param([Parameter(Mandatory)][securestring]$Secure)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
