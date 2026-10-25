# Changelog

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
