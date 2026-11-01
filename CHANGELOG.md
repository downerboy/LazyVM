# Changelog

## [5.0.1](https://github.com/downerboy/LazyVM/compare/v5.0.0...v5.0.1) (2026-11-01)


### Bug Fixes

* always delete the answer-file disc when ejecting it fails ([#256](https://github.com/downerboy/LazyVM/issues/256)) ([5379388](https://github.com/downerboy/LazyVM/commit/53793881fd31cfea0fa13128b1acfab015ea41e9))

## [5.0.0](https://github.com/downerboy/LazyVM/compare/v4.21.1...v5.0.0) (2026-10-31)


### ⚠ BREAKING CHANGES

* `New-LazyVM -Template` is renamed `-ConfigTemplate`, and the built-in `Minimal` template is removed (use `PlainWindows`, or your own template).

### Features

* add Export-LazyVMTemplate to save a VM's configuration as a config template ([#253](https://github.com/downerboy/LazyVM/issues/253)) ([3a5ca8d](https://github.com/downerboy/LazyVM/commit/3a5ca8d76da6b1dd283e0f417e067612d72aa523))
* config templates with a Name, -ConfigTemplate on Build-LazyVM, Developer and PlainWindows ([#252](https://github.com/downerboy/LazyVM/issues/252)) ([0102a72](https://github.com/downerboy/LazyVM/commit/0102a721fd2975d70e40e373a52c4a5300cb945d))


### Bug Fixes

* remove the answer-file disc whenever a build phase fails ([#251](https://github.com/downerboy/LazyVM/issues/251)) ([5b2b908](https://github.com/downerboy/LazyVM/commit/5b2b9084cfcdc460a6f378416506759ebcdff1a3))

## [4.21.1](https://github.com/downerboy/LazyVM/compare/v4.21.0...v4.21.1) (2026-10-31)


### Bug Fixes

* keep the retired OS disk when a rebuild finished with problems ([#245](https://github.com/downerboy/LazyVM/issues/245)) ([67a2008](https://github.com/downerboy/LazyVM/commit/67a2008d2a85255154563183973357d6a1a9d231))

## [4.21.0](https://github.com/downerboy/LazyVM/compare/v4.20.0...v4.21.0) (2026-10-31)


### Features

* add named templates and a Minimal template without Visual Studio or SQL Server ([#242](https://github.com/downerboy/LazyVM/issues/242)) ([5c2b4f0](https://github.com/downerboy/LazyVM/commit/5c2b4f046bc11f930acecdc085619804281ba0c3))
* ask the Store to update its apps during nightly maintenance ([#240](https://github.com/downerboy/LazyVM/issues/240)) ([4da2de4](https://github.com/downerboy/LazyVM/commit/4da2de48f68c61b686809b799dfba2927d098bcb))
* install Visual Studio only when the VM's VM.json says so ([#241](https://github.com/downerboy/LazyVM/issues/241)) ([e800935](https://github.com/downerboy/LazyVM/commit/e800935a32d5e208a4c8ba9cc81d52698bf93a54))


### Bug Fixes

* pass an empty database list to rebuild verification, not $null ([#244](https://github.com/downerboy/LazyVM/issues/244)) ([1e6b078](https://github.com/downerboy/LazyVM/commit/1e6b07845573d2d5978db17ae463a7318d315e96))

## [4.20.0](https://github.com/downerboy/LazyVM/compare/v4.19.1...v4.20.0) (2026-10-31)


### Features

* turn on Developer Mode in the VM ([#239](https://github.com/downerboy/LazyVM/issues/239)) ([5d65277](https://github.com/downerboy/LazyVM/commit/5d652778105bd920a1ee3958fbd8843280e3ca70))


### Bug Fixes

* clean up after a failed build and give the real reason it stopped ([#237](https://github.com/downerboy/LazyVM/issues/237)) ([bb9367c](https://github.com/downerboy/LazyVM/commit/bb9367cd2e470eea3803c85f0f7de3b2c2da6606))

## [4.19.1](https://github.com/downerboy/LazyVM/compare/v4.19.0...v4.19.1) (2026-10-31)


### Bug Fixes

* do not report success after build steps failed ([#230](https://github.com/downerboy/LazyVM/issues/230)) ([25faaf7](https://github.com/downerboy/LazyVM/commit/25faaf7bcd6a436bb5f305b85b7c64482e5e31de))
* drop Phase 8's database step, which called a removed command ([#229](https://github.com/downerboy/LazyVM/issues/229)) ([6acf9cc](https://github.com/downerboy/LazyVM/commit/6acf9cc36966fca2e01b053d5d8809facdfd7dc8))
* send winget the path, not @{value=...} ([#228](https://github.com/downerboy/LazyVM/issues/228)) ([b48fbc5](https://github.com/downerboy/LazyVM/commit/b48fbc5a158e96b879f77964c3cb049aad5f1729))

## [4.19.0](https://github.com/downerboy/LazyVM/compare/v4.18.0...v4.19.0) (2026-10-31)


### Features

* install programs and extensions from official installers ([#217](https://github.com/downerboy/LazyVM/issues/217)) ([111522b](https://github.com/downerboy/LazyVM/commit/111522bce23a8aba85c07ccd34d946dd0c1fbbf7))


### Bug Fixes

* keep Test-LazyVM from writing a lastgood copy of the settings ([#219](https://github.com/downerboy/LazyVM/issues/219)) ([94ca342](https://github.com/downerboy/LazyVM/commit/94ca3422dc57b8b059ad48b4e7b3cc4c7616f674))

## [4.18.0](https://github.com/downerboy/LazyVM/compare/v4.17.0...v4.18.0) (2026-10-31)


### Features

* -WhatIf for Invoke-LazyVMMaintenance and Build-LazyVM ([#206](https://github.com/downerboy/LazyVM/issues/206)) ([80e7c62](https://github.com/downerboy/LazyVM/commit/80e7c625fabfe177fb3ef39d4aed5a6cb8273104))
* Get-LazyVMCredential -ToClipboard for VMConnect's sign-in box ([#199](https://github.com/downerboy/LazyVM/issues/199)) ([2e1e76d](https://github.com/downerboy/LazyVM/commit/2e1e76dca5ccbbc59b8344d289a8dbe7309f38d4))
* install SQL Server only when the VM's VM.json says so ([#205](https://github.com/downerboy/LazyVM/issues/205)) ([3dc8bb7](https://github.com/downerboy/LazyVM/commit/3dc8bb76c7305f1aef7112105a78458b514d3a21))
* point Visual Studio's projects folder at the Dev Drive ([#203](https://github.com/downerboy/LazyVM/issues/203)) ([6e8d1bb](https://github.com/downerboy/LazyVM/commit/6e8d1bbb0a9e7a84c0be3a033c0586b57c3abf76))
* run winget package installs detached, as a guest task ([#209](https://github.com/downerboy/LazyVM/issues/209)) ([90af52a](https://github.com/downerboy/LazyVM/commit/90af52acfd6b32c5c2505f66bc2166007234bd98))
* Test-LazyVM, a read-only check of what a VM depends on ([#211](https://github.com/downerboy/LazyVM/issues/211)) ([a847db8](https://github.com/downerboy/LazyVM/commit/a847db846a2507062a58bbed6db88927f903e106))

## [4.17.0](https://github.com/downerboy/LazyVM/compare/v4.16.0...v4.17.0) (2026-10-31)


### Features

* back up the User disk when it changes ([#204](https://github.com/downerboy/LazyVM/issues/204)) ([e122593](https://github.com/downerboy/LazyVM/commit/e1225936162bc6be08445f822714ad9bad99e06d))
* record the VM's tooling list at the end of a build ([#197](https://github.com/downerboy/LazyVM/issues/197)) ([6be0458](https://github.com/downerboy/LazyVM/commit/6be0458621a6229614eb7a28a6e82dbe4c127ffd))


### Bug Fixes

* set the guest's language and keyboard from GuestLocale ([#200](https://github.com/downerboy/LazyVM/issues/200)) ([ec837c0](https://github.com/downerboy/LazyVM/commit/ec837c08ec423f240a895cd01870088817f6c28f))

## [4.16.0](https://github.com/downerboy/LazyVM/compare/v4.15.5...v4.16.0) (2026-10-31)


### Features

* refuse to attach a persistent disk that belongs to another VM ([#198](https://github.com/downerboy/LazyVM/issues/198)) ([76701c1](https://github.com/downerboy/LazyVM/commit/76701c12dddb76c74b34f24dd5fc42fa071a811e))

## [4.15.5](https://github.com/downerboy/LazyVM/compare/v4.15.4...v4.15.5) (2026-10-31)


### Bug Fixes

* delete each checkpoint once when retiring a VM ([#195](https://github.com/downerboy/LazyVM/issues/195)) ([cee56fb](https://github.com/downerboy/LazyVM/commit/cee56fb7ffd483aca51803e15c52eca1ff5efdfb))

## [4.15.4](https://github.com/downerboy/LazyVM/compare/v4.15.3...v4.15.4) (2026-10-31)


### Bug Fixes

* see a checkpointed data disk as already attached ([#192](https://github.com/downerboy/LazyVM/issues/192)) ([21865c6](https://github.com/downerboy/LazyVM/commit/21865c6cfa133ed3c09386290d83d84602764f70))

## [4.15.3](https://github.com/downerboy/LazyVM/compare/v4.15.2...v4.15.3) (2026-10-31)


### Bug Fixes

* eject the install ISO before BitLocker uses the TPM ([#189](https://github.com/downerboy/LazyVM/issues/189)) ([beb1c00](https://github.com/downerboy/LazyVM/commit/beb1c00a6f6b06e0e533d12b78f78a899eeeed31))

## [4.15.2](https://github.com/downerboy/LazyVM/compare/v4.15.1...v4.15.2) (2026-10-31)


### Bug Fixes

* turn BitLocker protection on for disks Windows already encrypted ([#186](https://github.com/downerboy/LazyVM/issues/186)) ([8ff17e8](https://github.com/downerboy/LazyVM/commit/8ff17e863aa3903686f8abf4d7c58c6e3dce550e))

## [4.15.1](https://github.com/downerboy/LazyVM/compare/v4.15.0...v4.15.1) (2026-10-31)


### Bug Fixes

* no "Sum cannot be found" when there is nothing to add up ([#181](https://github.com/downerboy/LazyVM/issues/181)) ([6a5791a](https://github.com/downerboy/LazyVM/commit/6a5791aaaf04a5d393dc10a638fef9d8dd21a229))
* resume a VM that a failed tooling checkpoint left paused ([#183](https://github.com/downerboy/LazyVM/issues/183)) ([eba9400](https://github.com/downerboy/LazyVM/commit/eba94002fe0f58339f594457adf093b5f23b523e))

## [4.15.0](https://github.com/downerboy/LazyVM/compare/v4.14.0...v4.15.0) (2026-10-30)


### Features

* BitLocker on every persistent disk, unlockable after a rebuild ([#178](https://github.com/downerboy/LazyVM/issues/178)) ([86aeb2d](https://github.com/downerboy/LazyVM/commit/86aeb2df7e7c2b09185432ab0885d440869ce956))

## [4.14.0](https://github.com/downerboy/LazyVM/compare/v4.13.0...v4.14.0) (2026-10-30)


### Features

* capture the VM's state when it changes ([#173](https://github.com/downerboy/LazyVM/issues/173)) ([ab73a93](https://github.com/downerboy/LazyVM/commit/ab73a93347c7b5749683432452f8bd91ff548501))
* give each VM a User disk for its personal folders ([#177](https://github.com/downerboy/LazyVM/issues/177)) ([a5e425d](https://github.com/downerboy/LazyVM/commit/a5e425d4444f471720e67d7010c43f9854303a7f))

## [4.13.0](https://github.com/downerboy/LazyVM/compare/v4.12.0...v4.13.0) (2026-10-30)


### Features

* keep the last three state captures, each in its own folder ([#171](https://github.com/downerboy/LazyVM/issues/171)) ([f83bc92](https://github.com/downerboy/LazyVM/commit/f83bc92c5b70a5e17f5129fde44f554a23017dc0))

## [4.12.0](https://github.com/downerboy/LazyVM/compare/v4.11.0...v4.12.0) (2026-10-30)


### Features

* **sql:** check databases and keep one good backup ([#169](https://github.com/downerboy/LazyVM/issues/169)) ([ead216b](https://github.com/downerboy/LazyVM/commit/ead216bd5ef3e951961104b76619b2d7a48bdeeb))

## [4.11.0](https://github.com/downerboy/LazyVM/compare/v4.10.1...v4.11.0) (2026-10-30)


### Features

* **sql:** keep tempdb on C: and attach the databases on rebuild ([#167](https://github.com/downerboy/LazyVM/issues/167)) ([bfa5e5b](https://github.com/downerboy/LazyVM/commit/bfa5e5bf3672f8c797a2460d3436efda7390ccd3))

## [4.10.1](https://github.com/downerboy/LazyVM/compare/v4.10.0...v4.10.1) (2026-10-30)


### Bug Fixes

* **sql:** make the VM's administrator a sysadmin ([#165](https://github.com/downerboy/LazyVM/issues/165)) ([50c7dbb](https://github.com/downerboy/LazyVM/commit/50c7dbbad588bbbcfc49502d66fe141777079bcf))

## [4.10.0](https://github.com/downerboy/LazyVM/compare/v4.9.0...v4.10.0) (2026-10-30)


### Features

* **sql:** install the Standard Developer edition ([#163](https://github.com/downerboy/LazyVM/issues/163)) ([3a69c60](https://github.com/downerboy/LazyVM/commit/3a69c60d481baf814356ef17f5044024c40c4932))

## [4.9.0](https://github.com/downerboy/LazyVM/compare/v4.8.0...v4.9.0) (2026-10-29)


### Features

* record and restore the SQL Agent jobs, operators and alerts in VM.json ([#155](https://github.com/downerboy/LazyVM/issues/155)) ([6c516f5](https://github.com/downerboy/LazyVM/commit/6c516f51c298ca61871f12222b276f97c6bf9f12)), closes [#131](https://github.com/downerboy/LazyVM/issues/131)
* record the SQL logins and instance settings in VM.json ([#154](https://github.com/downerboy/LazyVM/issues/154)) ([ee7bfa1](https://github.com/downerboy/LazyVM/commit/ee7bfa1df27af748fa10ac8ec2e99f6c7ccb3220))

## [4.8.0](https://github.com/downerboy/LazyVM/compare/v4.7.0...v4.8.0) (2026-10-29)


### Features

* record the AppSettings registry values in VM.json ([#152](https://github.com/downerboy/LazyVM/issues/152)) ([3a783a8](https://github.com/downerboy/LazyVM/commit/3a783a8469e13b00622ca92e3bd34de39f112616))

## [4.7.0](https://github.com/downerboy/LazyVM/compare/v4.6.0...v4.7.0) (2026-10-29)


### Features

* record the guest's scheduled tasks in VM.json ([#150](https://github.com/downerboy/LazyVM/issues/150)) ([992f146](https://github.com/downerboy/LazyVM/commit/992f146e37cc3a6820aa5d70a4d9549481a53734))

## [4.6.0](https://github.com/downerboy/LazyVM/compare/v4.5.0...v4.6.0) (2026-10-29)


### Features

* record the guest's firewall rules in VM.json ([#148](https://github.com/downerboy/LazyVM/issues/148)) ([690ce6d](https://github.com/downerboy/LazyVM/commit/690ce6dc6f8ee7636444a00189082554321b3a66))

## [4.5.0](https://github.com/downerboy/LazyVM/compare/v4.4.0...v4.5.0) (2026-10-29)


### Features

* record the guest's environment in VM.json ([#146](https://github.com/downerboy/LazyVM/issues/146)) ([8d07fe2](https://github.com/downerboy/LazyVM/commit/8d07fe265fbd61ae0b76cdf88368174fd130c2ac))

## [4.4.0](https://github.com/downerboy/LazyVM/compare/v4.3.2...v4.4.0) (2026-10-29)


### Features

* record hardware changes made in Hyper-V in VM.json ([#144](https://github.com/downerboy/LazyVM/issues/144)) ([b0e48ac](https://github.com/downerboy/LazyVM/commit/b0e48acbb2324584292473f6f86bf6c22ad16d5d))

## [4.3.2](https://github.com/downerboy/LazyVM/compare/v4.3.1...v4.3.2) (2026-10-27)


### Bug Fixes

* repair an incomplete Visual Studio instance instead of skipping it ([#127](https://github.com/downerboy/LazyVM/issues/127)) ([7feabb3](https://github.com/downerboy/LazyVM/commit/7feabb3b6613a6c56d85f54a823d3f12d6fa841d))

## [4.3.1](https://github.com/downerboy/LazyVM/compare/v4.3.0...v4.3.1) (2026-10-26)


### Bug Fixes

* complete -Name with the VMs in the LazyVM folder ([#120](https://github.com/downerboy/LazyVM/issues/120)) ([18f2e96](https://github.com/downerboy/LazyVM/commit/18f2e96dadf3a6883dcc882c63c26e19058f74d0))
* pull latest changes before install ([#121](https://github.com/downerboy/LazyVM/issues/121)) ([c56b87a](https://github.com/downerboy/LazyVM/commit/c56b87a932d9d2201e71874584962215a2236838))

## [4.3.0](https://github.com/downerboy/LazyVM/compare/v4.2.4...v4.3.0) (2026-10-26)


### Features

* show the version, folder, VMs, install path and commands when LazyVM is typed alone ([#115](https://github.com/downerboy/LazyVM/issues/115)) ([c52eb56](https://github.com/downerboy/LazyVM/commit/c52eb561d9473f46c363d6c53ddd4a8ddf6aed09))

## [4.2.4](https://github.com/downerboy/LazyVM/compare/v4.2.3...v4.2.4) (2026-10-26)


### Bug Fixes

* drop the unsigned extensions from the default tooling list ([#113](https://github.com/downerboy/LazyVM/issues/113)) ([3ee1f4c](https://github.com/downerboy/LazyVM/commit/3ee1f4c3ebf4cccfd2178e77d4fe8ff892e4f5e3))

## [4.2.3](https://github.com/downerboy/LazyVM/compare/v4.2.2...v4.2.3) (2026-10-26)


### Bug Fixes

* install Visual Studio before its extensions, so a refused extension cannot stop it ([#110](https://github.com/downerboy/LazyVM/issues/110)) ([bda8718](https://github.com/downerboy/LazyVM/commit/bda8718ccba0b6588d10ce0194a70022a0741721))

## [4.2.2](https://github.com/downerboy/LazyVM/compare/v4.2.1...v4.2.2) (2026-10-26)


### Bug Fixes

* build the guest helpers' script block in the guest ([#107](https://github.com/downerboy/LazyVM/issues/107)) ([ed29e39](https://github.com/downerboy/LazyVM/commit/ed29e391ae4a1c37f49da31aaaeacd37f60ac52a))

## [4.2.1](https://github.com/downerboy/LazyVM/compare/v4.2.0...v4.2.1) (2026-10-26)


### Bug Fixes

* go on when Hyper-V attaches a data disk but reports a DvdDrive cast error ([#104](https://github.com/downerboy/LazyVM/issues/104)) ([4b8e2eb](https://github.com/downerboy/LazyVM/commit/4b8e2ebcc07c89ffea9cec42ae615cdd277d5adc))

## [4.2.0](https://github.com/downerboy/LazyVM/compare/v4.1.0...v4.2.0) (2026-10-26)


### Features

* find the SQL data disk and Dev Drive by recorded identity, never by size ([#101](https://github.com/downerboy/LazyVM/issues/101)) ([6365242](https://github.com/downerboy/LazyVM/commit/636524215d69a43ec88819ca805bd2a34145181d))

## [4.1.0](https://github.com/downerboy/LazyVM/compare/v4.0.1...v4.1.0) (2026-10-26)


### Features

* make VM.json the VM's complete, living configuration ([#98](https://github.com/downerboy/LazyVM/issues/98)) ([559fdcc](https://github.com/downerboy/LazyVM/commit/559fdcc1d0b56db1eb9721be81b3f9637de741a9))

## [4.0.1](https://github.com/downerboy/LazyVM/compare/v4.0.0...v4.0.1) (2026-10-25)


### Bug Fixes

* say how to install when Install.ps1 is run from src ([#91](https://github.com/downerboy/LazyVM/issues/91)) ([3c55adf](https://github.com/downerboy/LazyVM/commit/3c55adfaf4930be2f6ca93d7d0d7885347e72eef)), closes [#90](https://github.com/downerboy/LazyVM/issues/90)

## [4.0.0](https://github.com/downerboy/LazyVM/compare/v3.1.1...v4.0.0) (2026-10-25)


### ⚠ BREAKING CHANGES

* LazyVM no longer installs or imports on PowerShell 7.4 or 7.5. Upgrade with `winget upgrade Microsoft.PowerShell`.

### Features

* require PowerShell 7.6 LTS ([#78](https://github.com/downerboy/LazyVM/issues/78)) ([61ce9da](https://github.com/downerboy/LazyVM/commit/61ce9da2024ff1dce3e9f3dcdcbeb0d3c72b824d)), closes [#17](https://github.com/downerboy/LazyVM/issues/17)

## [3.1.1](https://github.com/downerboy/LazyVM/compare/v3.1.0...v3.1.1) (2026-10-25)


### Bug Fixes

* save a tooling list that has no Visual Studio products ([#83](https://github.com/downerboy/LazyVM/issues/83)) ([d4508a3](https://github.com/downerboy/LazyVM/commit/d4508a36e71a5d965b09c6a1800b1f66ba0bab6c)), closes [#82](https://github.com/downerboy/LazyVM/issues/82)

## [3.1.0](https://github.com/downerboy/LazyVM/compare/v3.0.0...v3.1.0) (2026-10-24)


### Features

* keep a copy of the build template ([#80](https://github.com/downerboy/LazyVM/issues/80)) ([06f8393](https://github.com/downerboy/LazyVM/commit/06f8393609a4143ed105f62cbad63c27885015b0)), closes [#71](https://github.com/downerboy/LazyVM/issues/71)

## [3.0.0](https://github.com/downerboy/LazyVM/compare/v2.0.1...v3.0.0) (2026-10-24)


### ⚠ BREAKING CHANGES

* the VHDXRoot setting is now DiskDir, the default host paths have moved, and 'Shared' is no longer a valid VM name. Existing installs are not migrated.

### Features

* keep each VM's files in its own folder ([#77](https://github.com/downerboy/LazyVM/issues/77)) ([74a52d1](https://github.com/downerboy/LazyVM/commit/74a52d1bcf5c3694105dc2f330a5a93553adb344)), closes [#73](https://github.com/downerboy/LazyVM/issues/73) [#72](https://github.com/downerboy/LazyVM/issues/72)

## [2.0.1](https://github.com/downerboy/LazyVM/compare/v2.0.0...v2.0.1) (2026-10-24)


### Bug Fixes

* attach the release zip by publishing releases as drafts ([#44](https://github.com/downerboy/LazyVM/issues/44)) ([6d868f1](https://github.com/downerboy/LazyVM/commit/6d868f14acd7bdca5d00ebe633ece48aa5d61ecf))

## 2.0.0 (2026-10-24)


### Features

* automate versioning and releases with release-please ([#41](https://github.com/downerboy/LazyVM/issues/41)) ([67e0cdf](https://github.com/downerboy/LazyVM/commit/67e0cdfd4e7bef11b15013882baf19ea646245e8))
