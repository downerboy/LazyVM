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
  - the code a task runs (the module in `%ProgramFiles%\LazyVM`, the folders above it up to there, and PowerShell) must be owned and changeable by administrators, SYSTEM and TrustedInstaller only, or the task is not registered and `Test-LazyVM` fails;
  - a task's name must end in a VM name (letters, digits and hyphens) for LazyVM to make its command, so a task someone else named cannot carry code into it;
  - the task's command names the LazyVM folder and its owner's security identifier, which only an administrator can change, and LazyVM uses the folder only if it is not a reparse point and is locked to that owner and SYSTEM;
  - every place a VM's settings name must be inside that folder, unless the owner, elevated, allowed it (kept under `HKLM:\SOFTWARE\LazyVM\<SID>\HostPaths`). A path with a `.` or `..` part is refused (one leading `.\` is fine). Allowing a place asks first, naming it, and a drive's root, the Windows, Program Files and ProgramData folders and other users' profiles are never allowed;
  - no write, delete, move or copy in the folder or an allowed place goes through a junction or link, and, running as SYSTEM, LazyVM writes nowhere else but its temporary folder;
  - what LazyVM downloads and opens are fixed Microsoft addresses, not settings.

What it does not protect against: a local administrator can take ownership of the files, the VM disks included, or run a program as SYSTEM, and so read LazyVM's files and decrypt its stored passwords. The data inside each VM stays protected by BitLocker. Keep a copy of the BitLocker recovery passwords offline, such as on a USB drive: `Export-LazyVMRecoveryKey -Path <file>` writes them, and LazyVM reminds you until every key is exported. The file holds the passwords in plain text, so keep it somewhere safe.
