# LazyVM

Follow [CONTRIBUTING.md](CONTRIBUTING.md). For every issue:

1. Branch from an up-to-date `main`, named for the change with the issue number: `fix/72-…`, `feature/73-…`, `docs/74-…`.
2. Run `./Invoke-AnalyzerAndTest.ps1` before pushing.
3. Open a pull request into `main` with a Conventional Commits title and `Fixes #<issue>` in the description.
4. When CI passes, squash-merge it. The branch is deleted on merge; if it is not, delete it.
5. Merge the release-please pull request (`chore(main): release x.y.z`) to publish the release. `docs`, `refactor`, `test`, `build`, `ci`, `chore` and `style` changes do not make one on their own.

Work that has no issue gets one first.
