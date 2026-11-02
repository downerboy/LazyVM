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

LazyVM is installed for one Windows user, and only that user can use it or read what it stores:

- Stored passwords and the VMs' BitLocker recovery passwords are encrypted with Windows DPAPI for that user's account. No other account can decrypt them, local administrators and SYSTEM included.
- The LazyVM folder is open to that user and SYSTEM only, with nothing inherited from the folder above. Hyper-V adds each VM's own access to its files.
- The scheduled tasks run as that user. Task Scheduler, not LazyVM, keeps the user's Windows password for them.

What it does not protect against: a local administrator can take ownership of the files, the VM disks included, though not decrypt the stored passwords; the data inside each VM is protected by BitLocker. A password reset by someone else, rather than a change made by the user, loses the DPAPI keys and every stored secret with them, so keep a copy of the BitLocker recovery passwords (`Get-LazyVMCredential -RecoveryPassword`) somewhere safe.
