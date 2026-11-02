# CredentialStore.ps1 - Encrypted store for the guest and certificate passwords.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Encrypted with DPAPI for the current user (#284): only the Windows account
# that stored a secret can read it back, so no other account can decrypt
# it, local administrators and SYSTEM included. LazyVM's scheduled tasks run
# as that same account, so they can read it too.
#
# DPAPI keys follow the account's password. Changing your own password keeps
# them; a password reset by someone else loses them, and with them every
# secret stored here.
#
# Get- functions only read. A missing credential file is created only by
# Save-StoredCredential and Get-OrNewStoredCredential, and nothing here ever
# deletes a stored credential.

# Marks a file as encrypted this way. Older LazyVM versions wrote files
# without it, encrypted with a machine key file (Convert-LazyVMInstallation
# moves them over).
$script:CredentialProtection = 'DPAPI-CurrentUser'

function ConvertTo-StoredCredentialText {
    <# The text of a credential file: the user name, and the password encrypted for the current user. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][securestring]$Password
    )

    # Without -Key, ConvertFrom-SecureString encrypts with DPAPI for the current user.
    $blob = [pscustomobject]@{
        UserName   = $UserName
        Password   = ConvertFrom-SecureString -SecureString $Password
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
        $secure = ConvertTo-SecureString -String $blob.Password
        return [pscredential]::new($blob.UserName, $secure)
    }
    catch {
        throw "The credential at $Path cannot be read ($($_.Exception.Message)): only the Windows account that stored it can read it, and only while that account's password has not been reset by someone else. Store the password again with Set-LazyVMCredential."
    }
}

function Test-ProtectedCredentialBlob {
    <# Whether a credential file's content is encrypted for the current user, rather than with an older LazyVM's machine key. #>
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
