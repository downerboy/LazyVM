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
- The scheduled tasks run as SYSTEM, with no stored password. Their command names the LazyVM folder, and LazyVM uses it only if it is still locked to its owner and SYSTEM.

What it does not protect against: a local administrator can take ownership of the files, the VM disks included, or run a program as SYSTEM, and so read LazyVM's files and decrypt its stored passwords. The data inside each VM stays protected by BitLocker. Keep a copy of the BitLocker recovery passwords (`Get-LazyVMCredential -RecoveryPassword`) somewhere safe.
