# Contributing

LazyVM uses [GitHub Flow](https://docs.github.com/en/get-started/using-github/github-flow): `main` always builds and passes its tests, every change reaches it through a pull request, and a release is a tag on `main`.

## Making a change

1. Branch from an up-to-date `main`. Name the branch for what it does, with the issue number when there is one:
   - `fix/42-rearm-count` for a bug
   - `feature/17-template-export` for something new
   - `docs/…`, `refactor/…` or `chore/…` for the rest
2. Before pushing, run the same checks CI runs:

   ```powershell
   ./build.ps1
   ```

3. Push the branch and open a pull request into `main`. Put `Fixes #42` in the description to close the issue when it merges.
4. CI (**Build, analyze and test**) must pass before the pull request can merge. `main` does not accept direct pushes, from anyone.
5. Merge, and the branch is deleted.

## Releasing

A release is a tag on `main`. The [Release workflow](.github/workflows/release.yml) builds, tests and packages the tagged commit and publishes it as a GitHub release.

1. In a pull request, set `ModuleVersion` (and `Prerelease`, for a prerelease) in `src/LazyVM/LazyVM.psd1`, and merge it.
2. Tag the merge commit on `main` and push the tag:

   ```powershell
   git switch main
   git pull
   git tag v2.1.0
   git push origin v2.1.0
   ```

Tags start with a lowercase `v` and match the manifest exactly: `v2.1.0`, or `v2.1.0-alpha1` for a prerelease. The workflow refuses a tag that does not match.

## Patching an older release

Release branches are made only when an older version needs a fix after `main` has moved on. Branch from that version's tag, then make the fix through a pull request into the release branch, the same way as into `main`:

```powershell
git switch -c release/2.0 v2.0.0
git push -u origin release/2.0
```

Bump the patch version on the release branch, tag it (`v2.0.1`), and push the tag. If `main` has the same bug, fix it there too.
