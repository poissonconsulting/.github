# fledge version-bump automation

Nightly automated fledge dev-version bumps for non-forked, non-archived `poissonconsulting` R packages.
Since October 2026 this runs centrally from the private repository [`poissonconsulting/poisrunner`](https://github.com/poissonconsulting/poisrunner), not from workflows inside each package.
poisrunner was called `fledgerunner` until 2026-10-22; links using the old name redirect.

## In short (for package maintainers)

**What fledge does:** it keeps each package's development version number and `NEWS.md` up to date automatically.
Every night it checks for new commits since the last version.
If there are any, it bumps the dev version (e.g. 0.3.0.9001 to 0.3.0.9002), adds the commit messages to `NEWS.md`, and tags the new version.

**What changed in October 2026:** only *where* that nightly job runs.
Each package used to carry its own copy of the job (`.github/workflows/fledge-bump.yaml` and `fledge-tag-on-merge.yaml`).
It now runs from one central place, `poissonconsulting/poisrunner`, which handles every package.
A package moves over when the PR removing its two fledge files is merged; the central job takes over from the next night.

**Why:**

1. **The old setup quietly stopped working for about half the packages.** GitHub switches off scheduled jobs in public repos after 60 days without a commit. On 2026-10-06, 49 of 96 packages had stopped getting bumps since mid-September, with no warning. One central job in a private repo does not have this problem.
2. **Security.** Each package's copy needed the fledge bot's private key, which was readable from every repo in the organisation, and the bot can push straight to `main`. The key now only needs to be available to one private repo.
3. **One place to check.** Problems show up in one place instead of across ~100 repos.

**What changes for you as a maintainer: almost nothing.**

- Keep committing as usual. Version bumps and `NEWS.md` still update overnight from your commit messages, so clear commit messages still matter.
- Do not hand-edit `NEWS.md` or the dev version (unchanged).
- CRAN releases are unchanged: committing the `CRAN-SUBMISSION` file pauses bumps until the release is accepted and the file is removed.
  If CRAN accepts the release but the file is left committed, the nightly run opens a PR removing it and merges it straight away (you are notified as reviewer).
- After a release you still get a "Start dev cycle" PR to review and merge. The new version tag is now added by the next nightly run rather than straight after the merge.
- To bump straight away instead of waiting for the night, the job is started from poisrunner's Actions tab (see [Operations](#operations)). poisrunner is private: the Infrastructure team can view its runs and logs; starting a run needs write access, so ask Joe.

## Is my package fledge-managed?

To see exactly what happens to a package, open the latest `fledge` run in poisrunner's Actions tab: the `plan` job lists every package with its decision (for example `include`, `skip:up-to-date`, `skip:fork`), and each bumped package has a job named after it.

Look at the package's `NEWS.md`, not its workflow files.
If it starts with the fledge banner, the package is fledge-managed and the central job bumps it each night:

```
<!-- NEWS.md is maintained by https://fledge.cynkra.com, contributors should not edit this file -->
<!-- NEWS.md is maintained by https://cynkra.github.io/fledge, do not edit -->
```

Signs it is working: commits titled `fledge: Bump version to X.Y.Z.9NNN` by `poisson-fledge-bot[bot]`, and matching `v*` tags.

A package with the banner is still skipped if it:

- is a fork (a fork's `main` stays a mirror of upstream);
- is listed in poisrunner's `config/fledge-exclude.txt` (sandboxes and templates);
- has no `v*` tag yet (fledge was never started there; nothing happens until the first tag exists);
- still carries the old `fledge-bump` workflow file (it stays on the old per-package setup until its migration PR merges).

## What it does

Every day at 07:00 UTC, for each fledge-managed package (root `DESCRIPTION` plus a fledge-maintained `NEWS.md`) that no longer carries its own fledge caller workflows:

- No `v*` tag reachable from `HEAD`: nothing happens (fledge is not initialised for that package).
- A release-path `fledge-bump` PR has merged and its merge commit is untagged: `fledge::tag_version()` tags the merge commit, then the steps below continue in the same run.
- A `fledge: Bump version to <DESCRIPTION version>` commit exists whose tag never landed (for example GitHub rejected the tag push): that commit is tagged instead of bumping again.
- No commits since the nearest `v*` tag: nothing happens.
- `CRAN-SUBMISSION` (or legacy `CRAN-RELEASE`) committed on the default branch: a notice is logged and nothing is bumped.
  If the version recorded in the file is already on CRAN (checked against CRAN's `PACKAGES` index), the file is stale: a `fledge-cran-accepted` PR removing it is opened, requesting review from the CODEOWNERS owner and noting a missing GitHub release for that version, and is merged immediately (the bot bypasses review; the change only deletes the file). Nothing is opened if such a PR is already open, the package is not yet on CRAN, or the file records no version.
- Last tag is a **dev** version (`X.Y.Z.9XXX`): `fledge::bump_version("dev")` regenerates `NEWS.md`, bumps `DESCRIPTION`, commits, tags, and pushes the commit and tag to the default branch together (`git push --atomic`, retried).
- Last tag is a **release** version (`X.Y.Z`): the bump goes onto a `fledge-bump` branch and is opened as a "Start dev cycle" PR requesting review from the CODEOWNERS owner, who merges it (auto-merge is not armed, so the regenerated `NEWS.md` is reviewed). An open PR is left alone if `main` has not moved, and closed and recreated if it has.

The bumps are pushed by the `poisson-fledge-bot` GitHub App, so they trigger the package's own CI (R-CMD-check, pkgdown, test-coverage) like any other push.

## Where it runs

| Path in `poissonconsulting/poisrunner` | Role |
| --- | --- |
| `.github/workflows/fledge.yaml` | Nightly schedule and manual dispatch. A `plan` job selects packages; a matrix `bump` job runs one package per job with an App token scoped to that package. |
| `tools/fledge-targets.sh` | Selects packages: fledge-managed, not a fork, not excluded, no own fledge caller, and with commits since the tag for its `DESCRIPTION` version (or no such tag). |
| `tools/fledge-detect.sh`, `tools/fledge-classify.sh` | Decide per package: tag, dev bump, release PR, hold, or nothing. Unit-tested in `tools/tests/`. |
| `.github/actions/fledge-run/action.yml` | Runs fledge for one checked-out package. |
| `config/fledge-exclude.txt` | Repositories never processed (sandboxes and templates). |

poisrunner is private because its logs name private packages and echo commit messages.
Forks are always skipped: a fork's `main` stays a clean mirror of upstream.

The fledge version is pinned to a fixed commit (`cynkra/fledge@9453c2b`, r-universe 0.1.99.9060) in `fledge-run/action.yml`; it changes only when that SHA is deliberately edited.

## Operations

```sh
gh workflow run fledge.yaml -R poissonconsulting/poisrunner -f packages=<pkg>                 # bump one package now
gh workflow run fledge.yaml -R poissonconsulting/poisrunner -f packages=<pkg> -f dry-run=true # report only
gh run list -R poissonconsulting/poisrunner --workflow fledge.yaml                            # recent runs
```

Each package's result is in the job named after it.
A failed job affects only that package; the others in the run continue.

Common failures:

- `Can't parse version headers` / `duplicate version names` / `Result must be length 1, not 0`: a malformed heading in the package's `NEWS.md`. Fix the heading (every top-level heading must be `# <pkg> <version>`, unique, without trailing spaces); the package bumps on the next run.
- `[remote rejected]` on a tag: a GitHub-side push failure. The atomic push means neither the commit nor the tag landed, so the next run simply retries.

## Migration from per-package callers

Until October 2026 each package carried two caller workflows that invoked reusable workflows in this repository (`.github/workflows/fledge-bump.yaml`, `fledge-tag-on-merge.yaml`, plus `.yml` forwarding shims).
`tools/sync-ci.sh` now removes those callers; the central job skips any package that still has one, so a package is never bumped by both.
Once no package carries a caller, the reusable fledge workflows, shims, `workflow-templates/fledge-*`, and `tools/rollout-fledge-automation.sh` will be deleted from this repository, and the App secrets restricted to poisrunner.

## One-time setup (org admin)

### 1. GitHub App

The org-owned GitHub App `poisson-fledge-bot` (integration id `4076501`) has repository permissions:

- Contents: read and write
- Pull requests: read and write
- Metadata: read

The default `GITHUB_TOKEN` is not used: events it creates do not trigger other workflows, so a tag it pushed would never start `pkgdown` / `R-CMD-check`, and it cannot bypass the Packages ruleset.
The App is installed on all repositories.

### 2. Secrets

`FLEDGE_APP_ID` and `FLEDGE_APP_PRIVATE_KEY` are organization secrets.
They are currently visible to all repositories because packages that have not yet migrated still use them; after migration they will be restricted to `poisrunner` only.

### 3. Branch rules

The App is on the bypass list of the organization ruleset **"Packages"** (id `17373396`) so the dev path can push the bump commit and tag to `main`.
Because the App bypasses the ruleset, a `gh pr merge --auto` it arms merges immediately rather than waiting for review; it is therefore only used for the mechanical CRAN-SUBMISSION cleanup PR, never for "Start dev cycle" PRs (which merged unreviewed until October 2026).

### 4. CODEOWNERS

The release path requests review from the owner of `*` in `.github/CODEOWNERS`.
Without it the "Start dev cycle" PR still opens but has no reviewer requested.

## Known risks

- fledge is built for interactive use; a package whose `NEWS.md` it cannot parse fails nightly until the file is fixed.
- NEWS quality depends on commit-message content.
- Recreating a release-path PR for new commits discards any prior approval, by design.
- A `CRAN-SUBMISSION` file for a submission CRAN never accepts holds the bump indefinitely; the run logs a notice each time. (A file left behind after acceptance is cleared by a PR, which still needs the owner's review.)
- The release path (Start dev cycle PR, then tag on the next run) had not yet run centrally at the time of the October 2026 migration; watch the first one.
- GitHub disables scheduled workflows after 60 days without activity in *public* repositories; poisrunner is private, and its Dependabot PRs also keep it active.
