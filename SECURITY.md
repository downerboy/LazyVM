# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately instead:

1. Open the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Describe the problem and how to reproduce it.

Only the maintainer can see the report. You will get an answer there.

## Supported versions

Only the latest release gets security fixes.

## What LazyVM protects, and from whom

LazyVM is installed for one Windows user. Other standard users on the computer cannot use it or read what it stores:

- Stored passwords and the VMs' BitLocker recovery passwords are encrypted with Windows DPAPI for the computer, with LazyVM's own entropy, so they cannot be read on another computer. Both the user and LazyVM's scheduled tasks can decrypt them.
- The LazyVM folder is open to that user and SYSTEM only, with nothing inherited from the folder above; this is what keeps other users out. Hyper-V adds each VM's own access to its files. LazyVM refuses a folder in OneDrive.
- The scheduled tasks run as SYSTEM, with no stored password. Because SYSTEM reads the user's own folder, LazyVM treats it as untrusted:
  - the code a task runs (the module in `%ProgramFiles%\LazyVM`, and PowerShell) must be changeable by administrators, SYSTEM and TrustedInstaller only, or the task is not registered and `Test-LazyVM` fails;
  - the task's command names the LazyVM folder and its owner's security identifier, which only an administrator can change, and LazyVM uses the folder only if it is not a reparse point and is locked to that owner and SYSTEM;
  - every place a VM's settings name must be inside that folder, unless the owner, elevated, allowed it (kept under `HKLM:\SOFTWARE\LazyVM\<SID>\HostPaths`);
  - no write under the folder goes through a junction or link;
  - what LazyVM downloads and opens are fixed Microsoft addresses, not settings.

What it does not protect against: a local administrator can take ownership of the files, the VM disks included, or run a program as SYSTEM, and so read LazyVM's files and decrypt its stored passwords. The data inside each VM stays protected by BitLocker. Keep a copy of the BitLocker recovery passwords (`Get-LazyVMCredential -RecoveryPassword`) somewhere safe.
