# Guest.SecurityFindingOpener.ps1 - Runs in the guest at every sign-in, as the user signing in (#290).
# Self-contained for Windows PowerShell 5.1. The scheduled task LazyVM-SecurityFindings runs it.
#
# Opens LazyVM Findings.txt in Notepad when the last security scan found
# something new that is High or Medium, once for that scan: the scan sets
# SecurityFindingsAlert under HKLM:\SOFTWARE\LazyVM to its stamp, and this
# records in the user's own HKCU:\SOFTWARE\LazyVM the stamp it opened the
# file for. It changes nothing else.
param([Parameter(Mandatory)][string]$Path)

$ErrorActionPreference = 'Stop'
$alert = Get-ItemProperty -Path 'HKLM:\SOFTWARE\LazyVM' -Name 'SecurityFindingsAlert' -ErrorAction SilentlyContinue
if (-not $alert -or -not $alert.SecurityFindingsAlert -or -not (Test-Path -LiteralPath $Path)) { return }

$userKey = 'HKCU:\SOFTWARE\LazyVM'
$opened = Get-ItemProperty -Path $userKey -Name 'SecurityFindingsOpened' -ErrorAction SilentlyContinue
if ($opened -and $opened.SecurityFindingsOpened -eq $alert.SecurityFindingsAlert) { return }

# Recorded first, so it is never opened twice for the same scan.
if (-not (Test-Path -LiteralPath $userKey)) { New-Item -Path $userKey -Force | Out-Null }
Set-ItemProperty -Path $userKey -Name 'SecurityFindingsOpened' -Value $alert.SecurityFindingsAlert
Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$Path`""
