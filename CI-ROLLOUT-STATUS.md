# CI standardization rollout: status and remaining work

Snapshot as of 2026-06-22.
Tracks the migration of every active R package onto the centrally-managed reusable workflows (`poissonconsulting/.github@v1`), with all caller files using the `.yaml` extension.
See `CI-SYSTEM.md` for the system design and `tools/sync-ci.sh` for the generator.

## State

All 72 fledge-managed packages have been standardized: each has an `f-ci` pull request that replaces its ad-hoc workflows with thin `.yaml` callers.
`v1` points at the permissions-fix merge commit and is verified green; there are no `startup_failure` runs across the fleet.

A permissions-escalation bug (reusables declared `read-all`, shims `write-all`, exceeding the callers' `contents: read` grant) had been failing all CI at startup fleet-wide.
It was fixed by giving every reusable and shim the minimal permissions matching its caller.
Do not reintroduce `read-all` or `write-all` in any reusable or shim; a called workflow that requests more than its caller grants is rejected before any job runs.

## Done

- 35 stale PRs from the previous flat rollout (`f-standardize-actions`) closed.
- 30 joethorley-owned `f-ci` PRs merged to `main`.
- Four `check-no-suggests` Suggests-leaks fixed and merged: `batchr`, `chk`, `mcmcderive`, `universals`.

## Remaining work

### 1. Merge the open `f-ci` PRs

- 20 joethorley-owned PRs remain open, blocked by the pre-existing test failures listed below.
- 20 teammate-owned PRs await review (`@aylapear` 11, `@sebdalgarno` 6, `@nehill197` 3).

### 2. Pre-existing test failures surfaced by the new CI

These are package-level issues, not rollout defects.
The standardized CI exposed them; it did not cause them.

- Live network/API tests run unguarded in CI (need `skip_on_ci()`, `skip_if_offline()`, or mocking): `aquarius2r2`, `aquariusapi`, `arcgisevr`, `baserowapi`, `harvestapi`, `mcmcdata`, `poisaws2`, `poisslack`, `poisspatial`, `readwriteaws`, `fishobspgr`, `bisonpictools`, `rpdo` (download test).
- `pkgdown` plus check failures: `poispkgs`, `shinylcrstranding`, `ssdsuite`, `ssdvignettes`.
- fledge plus check failure: `subreport`.
- Genuine code/test bugs that also fail the full R CMD check: `flobr` (a `Path extension must match '.pdf'` assertion), `rpdo` (a `library(ggplot2)` call in a roxygen `@examples` block).

### 3. `check-no-suggests` failures that are not Suggests-leaks

- `nlist`: pak reports `Build process failed` while installing under the no-suggests profile; a dependency-resolution problem, not a missing test guard.
- `dbflobr`: pak reports a dependency conflict and cannot install its hard dependency `flobr` under the no-suggests profile.
- These two need their dependency trees untangled; the reusable itself is sound (`batchr`, `chk`, `mcmcderive`, `universals` install and test cleanly under the same profile).

### 4. Finish the `.yaml` migration

- Migrate the fledge callers fleet-wide from `.yml` to `.yaml`.
  This is not done by `sync-ci.sh` (it preserves existing fledge callers under either extension) nor by `rollout-fledge-automation.sh` (it skips packages that already have a fledge caller); a dedicated step is needed.
- Migrate `dttr2` and `ssdsims`, which were merged earlier with legacy `.yml` callers.
- Once every caller across all packages (CI and fledge) references `.yaml@v1`, delete the six `.yml` forwarding shims in `.github/.github/workflows/` and re-tag `v1`.
  Do not delete the shims before then.

## Notes

- `git push --force origin v1` moves the tag; it affects every package's next CI run, so keep `v1` on a commit that is on `main`.
- The four phase-1 PRs (`embr`, `chk`, `bboutools`, `fwatlasbc`) were created before the permissions fix; their checks were re-run so they resolve against the fixed `v1`.
