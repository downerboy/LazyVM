# Contributing

LazyVM uses [GitHub Flow](https://docs.github.com/en/get-started/using-github/github-flow): `main` always builds and passes its tests, every change reaches it through a pull request, and a release is a tag on `main`.

## Making a change

1. Branch from an up-to-date `main`. Name the branch for what it does, with the issue number when there is one:
   - `fix/42-rearm-count` for a bug
   - `feature/17-template-export` for something new
   - `docs/…`, `refactor/…` or `chore/…` for the rest
2. Before pushing, run the same checks CI runs:

   ```powershell
   ./Invoke-AnalyzerAndTest.ps1
   ```

3. Push the branch and open a pull request into `main`, with a title in the form described under [Versioning](#versioning). Put `Fixes #42` in the description to close the issue when it merges.
4. CI (**Build, analyze and test**) and the title check (**Conventional Commits title**) must pass before the pull request can merge. `main` does not accept direct pushes, from anyone.
5. Squash-merge, so the pull request becomes one commit on `main` whose message is its title. GitHub then deletes the branch (**Automatically delete head branches** is on).
6. Release: merge the release pull request that the merge opened or updated (see [Releasing](#releasing)). Only `feat`, `fix`, `perf` and `revert` changes make one; anything else waits for the next of those.

Every issue goes through these steps on its own branch: one issue, one branch, one pull request.

## Versioning

LazyVM follows [Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`, held in `ModuleVersion` in `src/LazyVM/LazyVM.psd1`. Nobody edits it by hand; it is worked out from the titles of the merged pull requests, which follow [Conventional Commits](https://www.conventionalcommits.org):

| Pull request title | Next version |
|---|---|
| `fix: rearm count off by one` | patch: 2.0.0 → 2.0.1 |
| `feat: export VM templates` | minor: 2.0.1 → 2.1.0 |
| `feat!: rename Build-LazyVM`, or `BREAKING CHANGE:` in the description | major: 2.1.0 → 3.0.0 |
| `perf:` or `revert:` | patch |
| `docs:`, `refactor:`, `test:`, `build:`, `ci:`, `chore:`, `style:` | no release of their own |

A scope in brackets is optional: `fix(maintenance): …`.

## Releasing

Releases are made by [release-please](https://github.com/googleapis/release-please). Every time a pull request merges into `main`, the [Release Please workflow](.github/workflows/release-please.yml) opens or updates one **release pull request**, titled `chore(main): release 2.1.0`. It holds the next version: the `ModuleVersion` bump and the new section of [CHANGELOG.md](CHANGELOG.md).

To release, merge the release pull request. That tags `main` with `v` and the version (`v2.1.0`), publishes the GitHub release with the changelog, and attaches the built and tested `LazyVM-2.1.0.zip`.

Releases are immutable once published: their files and tag cannot change. So release-please first makes a draft, and the workflow publishes it only once the zip is attached. If that job fails, the draft stays; fix the cause, then run the Release Please workflow by hand with the draft's tag (`v2.1.0`) to finish it.

While LazyVM is in alpha, releases are marked as pre-releases on GitHub. To stop, set `PRERELEASE` to `'false'` in the workflow.

## Patching an older release

Release branches are made only when an older version needs a fix after `main` has moved on. Branch from that version's tag:

```powershell
git switch -c release/2.0 v2.0.0
git push -u origin release/2.0
```

Then make the fix through a pull request into `release/2.0`, titled `fix: …`. The branch gets its own release pull request, and merging it releases `v2.0.1`. If `main` has the same bug, fix it there too.
