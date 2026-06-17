# fledge automation go-live runbook

Sequence for enabling the fledge dev-version bump automation across `poissonconsulting` packages.
See `fledge-automation.md` for the design and component reference.

## Stage 0: test packages

These two packages exercise both code paths and have commits since their last tag, so a trigger does real work.

| Path | Package | Latest tag | Commits since | CODEOWNERS |
| --- | --- | --- | --- | --- |
| Dev / auto | `gsdd` | `v0.3.0.9000` (dev) | 12 | yes |
| Release / PR | `subreport` | `v0.1.0` (release) | 35 | yes |

Classification is on the most recent tag, not the `DESCRIPTION` version.
`evrfish` was the original release candidate but its latest tag is a dev version, so `subreport` is used for the release path instead.

## Stage 1: identity and settings (org admin, nothing runs yet)

### 1a. Create the App

Org -> Settings -> Developer settings -> GitHub Apps -> New GitHub App.

- Name `poisson-fledge-bot`; disable the webhook (uncheck Active).
- Repository permissions: Contents read and write, Pull requests read and write, Metadata read (automatic).
- Restrict to "Only on this account", create, then note the App ID and generate a private key (downloads a `.pem`).

### 1b. Install it

App -> Install App -> poissonconsulting -> All repositories (simplest; it only acts where caller files exist).

### 1c. Org secrets

Org -> Settings -> Secrets and variables -> Actions -> New organization secret.

- `FLEDGE_APP_ID` = the numeric App ID.
- `FLEDGE_APP_PRIVATE_KEY` = the full `.pem` contents including the BEGIN and END lines.
- Grant both to the package repos (or all repos); `secrets: inherit` works because callers and engine are in the same org.

### 1d. Branch settings on each package default branch

Fold these into the existing repo-governance settings.

- Add `poisson-fledge-bot` to the push / required-PR bypass list so the dev path can push the bump and tag directly.
- Require a pull request, require review from Code Owners, and at least one approval, so the release path waits for the codeowner.
- Repo -> Settings -> General -> Pull Requests -> Allow auto-merge, so `gh pr merge --auto` can arm.

The bypass and code-owner-review changes can be applied to all packages at once with
`tools/set-fledge-branch-protection.sh` (dry run by default, `--apply` to act, idempotent).
Run it only after the App is installed (1a, 1b), since it adds the App to each bypass list.
A dry run confirmed all 79 packages have a required-PR rule and none require signed commits.
Auto-merge is already enabled on the packages checked, so it is not part of the script.

Gate: nothing runs yet; safe to pause here indefinitely.

## Stage 2: validate headless fledge (the one real risk)

Do this before tagging `v1` or rolling out.
Pin the test callers to the branch (`@f-fledge-automation`), not `@v1`.

### 2a. Dev / auto path on `gsdd`

Add to `gsdd` default branch:

```yaml
# .github/workflows/fledge-bump.yml
name: fledge-bump
on: { workflow_dispatch: {}, schedule: [{cron: "0 7 * * *"}] }
permissions: { contents: write, pull-requests: write }
jobs:
  fledge-bump:
    uses: poissonconsulting/.github/.github/workflows/fledge-bump.yml@f-fledge-automation
    secrets: inherit
```

Run it from the Actions tab.
Verify: the token is minted, fledge installs, `bump_version()` runs without prompting (the headless risk), a commit bumps `DESCRIPTION` to `0.3.0.9001` with an updated `NEWS.md`, tag `v0.3.0.9001` is pushed, and `R-CMD-check` / `pkgdown` then fire (proving the App token triggers downstream workflows).

### 2b. Release path on `subreport`

Add both `fledge-bump.yml` (as above) and `fledge-tag-on-merge.yml`, pinned to `@f-fledge-automation`.
Dispatch `fledge-bump`.
Verify: a `fledge-bump` PR opens bumping to `0.1.0.9000`, `joethorley` is requested as reviewer, and auto-merge is enabled.
Approve it; it merges, then `fledge-tag-on-merge` tags `v0.1.0.9000` on the default branch.

### 2c. PR recreation

With that PR still open and unapproved, push a trivial commit to `subreport` default branch and re-dispatch; the old PR closes and a new one opens including the change.
Re-dispatch with no new commit; the PR is left untouched.

Gate: if `bump_version()` prompts or errors in 2a, fix the `Rscript -e` invocation (non-interactive options) before continuing.
This is the make-or-break check.

## Stage 3: merge engine and cut `v1`

```sh
cd ~/Code/poissonconsulting/.github
# mark the PR ready, get approval, merge into main, then:
git checkout main && git pull
git tag v1 && git push origin v1
```

The callers pin `@v1`, so `v1` must point at the merged engine.
Later engine fixes: re-point with `git tag -f v1 && git push -f origin v1`.

## Stage 4: roll out

```sh
cd ~/Code/poissonconsulting/.github && git pull
tools/rollout-fledge-automation.sh            # dry run; the v1 warning should be gone now
tools/rollout-fledge-automation.sh --apply    # opens the draft PRs
```

Review and merge the draft PRs through the governance flow.
Merging is what activates each package, since scheduled workflows only run once the file is on the default branch.

Expect:

- The script skips repos that already have `fledge-bump.yml`, including `gsdd` and `subreport` from Stage 2; update those two callers' `uses:` from `@f-fledge-automation` to `@v1` by hand.
- On the first 07:00 UTC tick (or a manual dispatch) every dev-tagged package with pending commits bumps at once, so expect a burst of tags and commits and a batch of `fledge-bump` PRs for the release-tagged ones.

Rollback: disable a package's workflow in its Actions tab, or revert its rollout PR.
To stop everything, move or delete the `v1` tag.
