# fledge version-bump automation

Daily automated fledge dev-version bumping for non-forked, non-archived `poissonconsulting` R packages.

## What it does

Every day at 07:00 UTC each package checks `main` for commits since the most recent `v*` tag.
If there are none, it does nothing.
If there are commits, it classifies the most recent tag and acts:

- Last tag is a **dev** version (`X.Y.Z.9XXX`, four components).
  `fledge::bump_version("dev")` regenerates `NEWS.md`, bumps `DESCRIPTION`, commits, and tags.
  The commit and tag are pushed straight to `main`.
- Last tag is a **release** version (`X.Y.Z`, three components).
  The same bump is committed onto a `fledge-bump` branch and opened as a pull request assigned to the codeowner, with auto-merge enabled.
  The version tag is not pushed yet; the companion *fledge-tag-on-merge* workflow tags `main` after the PR merges.

If a `fledge-bump` PR is still open the next day and new commits have landed on `main`, the PR is closed and recreated to include them.
If no new commits have landed, the open PR is left untouched so its approval and pending auto-merge survive.

## Components

| File | Repo | Role |
| --- | --- | --- |
| `.github/workflows/fledge-bump.yaml` | `poissonconsulting/.github` | Reusable engine (bump + classify + PR). A `.yml` forwarding shim aliases the old path during migration. |
| `.github/workflows/fledge-tag-on-merge.yaml` | `poissonconsulting/.github` | Reusable engine (tag on merge). A `.yml` forwarding shim aliases the old path during migration. |
| `workflow-templates/fledge-bump.yaml` | `poissonconsulting/.github` | Per-package caller (schedule + dispatch). |
| `workflow-templates/fledge-tag-on-merge.yaml` | `poissonconsulting/.github` | Per-package caller (PR closed). |
| `.github/workflows/fledge-bump.yaml` | each package | Thin caller (copied from the template). |
| `.github/workflows/fledge-tag-on-merge.yaml` | each package | Thin caller (copied from the template). |

## One-time setup (org admin)

These steps require organization-owner access and are not done by the workflow files.

### 1. GitHub App

Create an org-owned GitHub App (suggested name `poisson-fledge-bot`) with repository permissions:

- Contents: read and write
- Pull requests: read and write
- Metadata: read

The default `GITHUB_TOKEN` is deliberately not used: events it creates do not trigger other workflows, so a tag it pushed would never start `pkgdown` / `R-CMD-check`, and it cannot bypass branch protection.
A GitHub App token does both.

Install the app on every non-forked, non-archived package repo.

### 2. Org secrets

Store the app credentials as organization secrets available to the package repos:

- `FLEDGE_APP_ID` — the app's numeric ID.
- `FLEDGE_APP_PRIVATE_KEY` — the app's PEM private key.

The caller workflows forward these to the reusable workflows with `secrets: inherit`.

### 3. Branch protection and merge settings

The default branch is governed by the organization ruleset **"Packages"** (id `17373396`),
which already requires a PR, code-owner review, and one approval on the default branch of all
packages. Auto-merge is already enabled at the repo level. So the only setting to change is:

- Add the App to the **"Packages" ruleset bypass list** with mode **Always** (Org -> Settings -> Rules -> Rulesets -> Packages -> Bypass list -> Apps -> `poisson-fledge-bot`), so the dev path can push the bump commit and tag directly. This is one org-level change covering all packages. The "Always" bypass does not defeat the release path: a queued `gh pr merge --auto` still waits for the code-owner review.

The App's integration id is `4076501` (the value of `FLEDGE_APP_ID`).
Classic per-repo branch protection, if any, is redundant where the ruleset is the active control.

### 4. CODEOWNERS dependency

The release path reads the owner of `*` from `.github/CODEOWNERS` to request review.
This depends on the paused org-wide CODEOWNERS rollout.
Until a repo has CODEOWNERS, the release-path PR still opens but logs a warning and skips reviewer assignment, and auto-merge will not have a code-owner approval to wait on.

### 5. Pin the engine version

Tag `poissonconsulting/.github` `v1` once tested so the callers' `@v1` reference is stable.
For initial testing, temporarily change the caller `uses:` line to `@<test-branch>`.

## Rollout

`tools/rollout-fledge-automation.sh` adds the two caller workflows to every non-forked, non-archived repo with a root `DESCRIPTION` (an R package) and opens a draft PR for each.
It is idempotent (skips repos already carrying `fledge-bump.yml` or an open rollout PR) and handles `main` and `master` default branches.
Run it from a checkout of this repo after the `v1` tag exists:

```sh
tools/rollout-fledge-automation.sh            # dry run: list target repos and actions
tools/rollout-fledge-automation.sh --apply    # create branches + draft PRs
```

The PRs are opened as drafts; they are harmless until the App and org secrets are active.
This pairs with the same governance process that handles CODEOWNERS.

## Testing checklist

Use non-CRAN packages where Joe is the maintainer, so a dev bump cannot affect a CRAN release.

1. **Dev / auto path** on a dev-version package (e.g. `gsdd`, `0.3.0.9000`).
   Trigger `fledge-bump` via `workflow_dispatch`.
   Confirm it bumps to `0.3.0.9001`, updates `NEWS.md`, commits to `main`, pushes the tag, and that `R-CMD-check` / `pkgdown` fire.
2. **Release path** on a release-version package (e.g. `evrfish`, `0.7.0`) with a `.github/CODEOWNERS` naming Joe.
   Confirm a `fledge-bump` PR opens, Joe is requested as reviewer, and auto-merge is enabled.
   Approve it and confirm *fledge-tag-on-merge* tags `0.7.0.9000` on `main`.
3. **PR recreation** with an open `fledge-bump` PR: push a commit to `main`, re-run, and confirm the old PR closes and a new one opens including the change.
   Re-run with no new commits and confirm the PR is left untouched.
4. **No-op**: re-run with no commits since the last tag and confirm a clean exit.

## Known risks

- fledge is built for interactive use; running `bump_version()` / `tag_version()` headless must be validated on the first dry run before rollout.
- NEWS quality depends on commit-message content, unchanged from current local fledge use.
- Recreating a PR for new commits discards any prior approval, by design.
- Scheduled workflows are disabled after 60 days of repo inactivity.
