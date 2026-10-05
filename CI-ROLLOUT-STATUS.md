# CI standardization rollout: status and remaining work

Snapshot as of 2026-10-05 (previous snapshot 2026-06-22).
Tracks the migration of every active R package onto the centrally-managed reusable workflows (`poissonconsulting/.github@v1`), with all caller files using the `.yaml` extension.
See `CI-SYSTEM.md` for the system design and `tools/sync-ci.sh` for the generator.

## State

103 packages call `R-CMD-check.yaml@v1`.
No package calls the four CI `.yml` forwarding shims (`R-CMD-check.yml`, `test-coverage.yml`, `pkgdown.yml`, `check-no-suggests.yml`), so they have been deleted.
The two fledge `.yml` shims remain because three packages still call them (below).

Do not reintroduce `read-all` or `write-all` in any reusable workflow; a called workflow that requests more than its caller grants is rejected before any job runs.
This permissions-escalation bug failed all CI at startup fleet-wide during the June rollout.

## Done since 2026-06-22

- No `f-ci` PRs remain open except the two below.
- `dttr2` and `ssdsims` migrated to `.yaml` callers.
- CI `.yml` shims and the obsolete `tools/set-fledge-branch-protection.sh` (classic branch protection, removed org-wide 2026-07-17) deleted.

## Remaining work

### 1. Finish the `.yaml` migration

- Open `f-ci` PRs assigned to @nehill197 since 2026-07-14: `bisonpictools#63` and `bisonpicsuite#35`.
  Both packages still call the fledge `.yml` shims until these merge.
- `hmstimer` still has `fledge-bump.yml` and `fledge-tag-on-merge.yml` callers.
- `ghpois` pins its fledge caller to `@main` instead of `@v1`.
- Once no caller references `fledge-bump.yml` or `fledge-tag-on-merge.yml`, delete those two shims.

### 2. Packages failing R-CMD-check on the default branch

23 of the 103 packages failed their most recent push-triggered R-CMD-check run on the default branch (three more have no such run: `aquarius2r2`, `harvestapi`, `rescale`).
These are package-level issues, not CI defects, but a fleet this red masks regressions from reusable-workflow changes.

- Since June/July: `bisonpicsuite`, `bisonpictools`, `evrfish`, `bbousims`, `curtisquadata`, `fishobspgr`, `hobolink`, `shinygis`, `shinylcrstranding`, `tscbh`, `aquariusapi`, `baserowapi`, `dbflobr`, `mcmcdata`, `poisaws2`, `poisslack`, `ssdsuite`, `subreport`, `checkr`, `arcgisevr`, `readwriteaws`.
- Recent: `tmbr` (2026-09-01), `poispkgs` (2026-10-05).

Known causes from the June snapshot still apply to many of these: unguarded live network/API tests (need `skip_on_ci()`, `skip_if_offline()`, or mocking), and `check-no-suggests` dependency-resolution failures in `dbflobr`.

## Notes

- Releasing a reusable-workflow change goes through `tools/promote-v1.sh`, which canary-tests `main` before moving `v1`; do not move `v1` by hand.
