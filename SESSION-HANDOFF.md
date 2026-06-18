# Session handoff: Poisson GitHub Actions automation + CI standardization

Context for continuing this work in a new Claude Code session.
Two related bodies of work: (1) fledge version-bump automation — **live**; (2) CI standardization redesign — **built, mid-rollout**.

## Key locations

- Central infra repo: `poissonconsulting/.github` (cloned at `~/Code/poissonconsulting/.github`).
- In-repo docs: `fledge-automation.md`, `GO-LIVE.md` (fledge); `CI-SYSTEM.md` (CI redesign).
- Tooling: `tools/rollout-fledge-automation.sh`, `tools/set-fledge-branch-protection.sh`, `tools/standardize-actions.sh` (superseded), `tools/sync-ci.sh` (current), `tools/package-tiers.tsv`.
- Operator: `joethorley`. Org has ~369 non-archived non-fork repos, ~79 fledge-managed R packages.

## Operating constraints (important)

- The Claude Code harness **blocks mass/outward writes** (merging many PRs, org-wide `--apply`, pushing workflow files to default branches). The USER runs those; the assistant builds tools and runs dry-runs / single verifications.
- Per Joe's global rules: never push to a default branch directly; for repos Joe does NOT own (CODEOWNER != joethorley), open an issue first + a draft PR assigned to the owner.
- GitHub's API was flaky this session (secondary rate-limiting from very high call volume) — dry-runs under-report when throttled; wait for it to clear and re-run (tools are idempotent).

## Work item 1 — fledge automation (DONE / live)

- Reusable workflows `fledge-bump.yml` + `fledge-tag-on-merge.yml` in `poissonconsulting/.github`, pinned `@v1`.
- Daily 07:00 UTC: dev-tag -> auto bump+tag to default branch; release-tag -> codeowner-approved auto-merge PR; companion tags on merge.
- Identity: GitHub App `poisson-fledge-bot` (App id `4076501`), org secrets `FLEDGE_APP_ID` / `FLEDGE_APP_PRIVATE_KEY`, installed on all repos.
- Branch protection: the org ruleset **"Packages"** (id `17373396`) enforces PR + code-owner review on the default branch; the App is in its bypass list (Integration `4076501`, mode Always) so the dev path can push directly while the release path still waits for the codeowner (verified).
- Rolled out to 79 packages via `tools/rollout-fledge-automation.sh --apply`. Runbook: `GO-LIVE.md`.

## Work item 2 — CI standardization (BUILT, rollout pending)

### History / why the redesign
First attempt copied a flat "core 5" workflow set into every repo (branch `f-standardize-actions`, ~47 PRs). It produced ~24 red R-CMD-checks because it used one CRAN-grade matrix and a public-only token for every package.
Root causes: private repos (and repos depending on private packages) need `GITHUB_PAT=PRIVATE_ACTIONS_PAT` to install deps; and unimportant packages shouldn't run a CRAN-grade matrix.
**Decision: retire the flat rollout and replace with a parameterized, registry-driven system.**

### Current build (open PR #4 on `poissonconsulting/.github`, branch `f-ci-reusable`)
Reusable workflows (`.github/workflows/`, workflow_call; callers use `secrets: inherit`):
- `R-CMD-check.yml` — inputs `tier` (cran|important|unimportant), `jags`, `private`. A setup job maps tier -> matrix JSON via `fromJSON`; `error_on` per tier.
- `test-coverage.yml`, `pkgdown.yml`, `check-no-suggests.yml` — input `private`.
- All select `GITHUB_PAT = private ? PRIVATE_ACTIONS_PAT : GITHUB_TOKEN`.

Tier matrices: cran = macOS+Windows+Ubuntu{devel,release,oldrel-1} + check-no-suggests, error_on=warning; important = 3-OS release + Ubuntu oldrel, error_on=warning; unimportant = Ubuntu-release, error_on=error.

Registry + tool:
- `tools/package-tiers.tsv` — `<package> <tier>` lines; default unimportant; CRAN auto-detected; seeded `important` list (Bayesian engines + infra) **to review**.
- `tools/sync-ci.sh` — resolves tier (registry > CRAN > unimportant), auto-detects `private` (visibility), `jags` (DESCRIPTION), `cran`; renders thin callers; opens routed PRs (normal for Joe, issue+draft otherwise). Dry-run default; `--apply`; whitelist arg; `--close-old`; `ENGINE_REF` override. Hardened: fd3 loop read, `gh_try` retry-on-(non-404/empty), `raw_gate` bounded retry for DESCRIPTION/NEWS, repo-list count-guard, per-repo failure isolation, force-push, idempotent.

### Verified
Tool logic correct wherever the API responded: `nlist`->cran+jags, private repos->unimportant+private, registry tiers, routing. CI dry-runs under-reported only due to secondary rate-limiting.

### Remaining run sequence (USER runs; see `CI-SYSTEM.md`)
1. Wait for rate-limit to clear, then `tools/sync-ci.sh` (full dry run) — expect ~79 packages, no `WARN`; review/adjust `tools/package-tiers.tsv` tiers.
2. Merge PR #4 into `.github` main; `git tag -f v1 && git push -f origin v1` (callers pin `@v1`).
3. `tools/sync-ci.sh --close-old` — close the 47 `f-standardize-actions` PRs + their "Standardize GitHub Actions" issues + branches.
4. Pilot: `tools/sync-ci.sh --apply nlist embr jmbr poisslack baserowapi`; watch CI (esp. private dep resolution on `poisslack`).
5. Full: `tools/sync-ci.sh --apply`; merge greens; triage genuine reds per package.

### Open PRs from the flat attempt (to be closed by step 3)
Branch `f-standardize-actions`: ~44 open (15 green, 24 red [all dependency-resolution, fixed by the private-PAT design], 4 indeterminate). Already-merged pilots: chk, jmbr, mcmcr.

## Prerequisites already satisfied
- Org secrets: `FLEDGE_APP_ID`, `FLEDGE_APP_PRIVATE_KEY`, `PRIVATE_ACTIONS_PAT`, `CODECOV_TOKEN`.
- gh token needs `workflow` scope for `--apply` (added this session).

## First actions for the continuing session
- Re-read `CI-SYSTEM.md` in `~/Code/poissonconsulting/.github`.
- Run `tools/sync-ci.sh` (dry run) to confirm classification is clean now, then proceed through the run sequence with the user.
