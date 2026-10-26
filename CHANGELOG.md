# Changelog

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
