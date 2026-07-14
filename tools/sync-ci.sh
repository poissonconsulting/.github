#!/usr/bin/env bash
#
# Sync standardized CI to poissonconsulting R packages from the tier registry.
#
# Per fledge-managed package it renders thin caller workflows that invoke the reusable
# workflows in poissonconsulting/.github (R-CMD-check, test-coverage, pkgdown, and, for CRAN
# packages, check-no-suggests). CRAN packages also get the vendored R-hub workflow (rhub.yaml,
# dispatch-triggered and r-hub-owned, so distributed as a template not a caller). The fledge
# callers and the bespoke paper.yaml / slack-check-package.yaml workflows are preserved; all
# other pre-existing workflows are replaced. Opens one routed PR (normal PR for joethorley-owned
# repos; issue + ready-for-review PR assigned to the owner with review requested otherwise).
#
# Classification per package:
#   tier      registry override > active-on-CRAN > unimportant (default)
#   private   auto-detected from repo visibility   -> drives GITHUB_PAT (PRIVATE_ACTIONS_PAT)
#   jags      auto-detected from DESCRIPTION / workflows
#   cmdstan   auto-detected from DESCRIPTION (cmdstanr/smbr2 dep or CmdStan SystemRequirements)
#             -> installs the CmdStan toolchain in check, coverage, and pkgdown builds
#   tex       auto-detected from repo contents (PDF vignettes / PDF-rendering R code) -> installs TinyTeX
#   cran      active on CRAN (independent of tier; archived packages excluded) -> adds check-no-suggests caller + vendored rhub.yaml
#
# Before rolling out, a pre-flight flags important-tier candidates: packages whose deployed
# R-CMD-check caller says tier: important but which are neither in the registry nor active on
# CRAN, so this sync would otherwise downgrade them to unimportant. In --apply with a TTY you are
# asked per candidate whether to add it to tools/package-tiers.tsv (kept important for this run;
# commit that registry change to .github separately); a declined candidate is downgraded. A
# non-interactive --apply skips candidates (no PR) rather than silently downgrade them, and a dry
# run just lists them.
#
# Usage:
#   tools/sync-ci.sh                      # dry run: classify every package + planned action
#   tools/sync-ci.sh --apply              # render callers + open routed PRs
#   tools/sync-ci.sh --apply pkgA pkgB    # restrict to named packages (piloting)
#   tools/sync-ci.sh --close-old          # close the old f-standardize-actions PRs/issues/branches
#   ENGINE_REF=f-ci-reusable tools/sync-ci.sh --apply pkgA   # pin callers to a branch (pre-v1 pilot)
#
# Requires: gh (authenticated, `workflow` scope for --apply), git (SSH), curl.

set -euo pipefail

ORG=poissonconsulting
BRANCH=f-ci
OLD_BRANCH=f-standardize-actions
ENGINE_REF="${ENGINE_REF:-v1}"
EXCLUDE="dksandbox chktemplate"
# Fledge callers are migrated, not preserved: a package with a fledge caller under either
# extension gets the current .yaml templates and any .yml copy is dropped.
KEEP_FLEDGE="fledge-bump.yaml fledge-tag-on-merge.yaml fledge-bump.yml fledge-tag-on-merge.yml"
# Bespoke per-package workflows preserved across standardization (not replaced by a
# reusable caller): JOSS paper build and the Slack package-check notifier.
KEEP_PRESERVE="paper.yaml slack-check-package.yaml"
root=$(git rev-parse --show-toplevel)
REGISTRY="$root/tools/package-tiers.tsv"
RHUB_TPL="$root/workflow-templates/rhub.yaml"

MODE=dry
case "${1:-}" in
  --apply) MODE=apply; shift ;;
  --close-old) MODE=close; shift ;;
esac
ONLY="$*"

# gh/curl with retries on transient (non-404) failures.
gh_try() {
  local i out err; err=$(mktemp)
  for i in 1 2 3 4 5 6; do
    if out=$("$@" 2>"$err"); then
      # rc 0 but empty body == transient empty 200 (a real absent resource returns 404/rc!=0); retry.
      [ -n "$out" ] && { rm -f "$err"; printf '%s' "$out"; return 0; }
    elif grep -qiE 'HTTP 404|Not Found|Could not resolve to' "$err"; then
      rm -f "$err"; return 1
    fi
    sleep 3
  done
  echo "WARN  API failure, gave up: $* :: $(tr '\n' ' ' < "$err" | tail -c 140)" >&2
  rm -f "$err"; return 2
}
raw() { gh_try gh api -H "Accept: application/vnd.github.raw" "repos/$ORG/$1/contents/$2" || true; }
# For files that must exist on a real package (DESCRIPTION, NEWS.md): retry through transient
# empty/404 responses (GitHub returns spurious 404s for valid resources under load). Returns
# empty only after the file is genuinely absent / persistently unreachable.
raw_gate() {
  local i out
  for i in 1 2 3 4 5 6 7 8; do
    out=$(gh api -H "Accept: application/vnd.github.raw" "repos/$ORG/$1/contents/$2" </dev/null 2>/dev/null || true)
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    sleep 3
  done
  printf '%s' "$out"
}
# Active-on-CRAN detection. The src/contrib/PACKAGES index lists only currently published
# packages, so it is the authoritative source for "active on CRAN": archived packages (e.g.
# rpdo, removed 2024-07-10) are absent. The per-package web/packages/<pkg>/index.html page must
# NOT be used, because it persists for archived packages (showing a "removed from the CRAN
# repository" notice) and so returns 200 for them too, misclassifying them as CRAN. The index is
# ~22k packages; fetch it once, cache, and look packages up by exact name. Retry transient
# failures and abort rather than silently downgrade every CRAN package to unimportant.
CRAN_LIST=""
load_cran_list() {
  [ -n "$CRAN_LIST" ] && return
  local i out
  for i in 1 2 3 4 5 6; do
    out=$(curl -fsS "https://cran.r-project.org/src/contrib/PACKAGES" 2>/dev/null \
            | awk '/^Package:/{print $2}' | sort -u || true)
    if [ "$(printf '%s\n' "$out" | grep -c .)" -ge 10000 ]; then
      CRAN_LIST=$(mktemp); printf '%s\n' "$out" > "$CRAN_LIST"; return
    fi
    sleep 3
  done
  echo "ERROR cannot fetch CRAN PACKAGES index (got $(printf '%s\n' "$out" | grep -c .) names); aborting to avoid misclassifying CRAN packages" >&2
  exit 1
}
is_cran() { load_cran_list; grep -qxF -- "$1" "$CRAN_LIST"; }

# Detect whether a package builds PDFs (and so needs TinyTeX in CI): any Sweave/knitr LaTeX
# vignette (.Rnw), or an .Rmd vignette / R source file that targets a LaTeX output. Reads the
# recursive tree once, then greps only the candidate files, returning at the first hit.
detect_tex() {
  local repo="$1" ref="$2" paths f
  paths=$(gh_try gh api "repos/$ORG/$repo/git/trees/$ref?recursive=1" --jq '.tree[].path' </dev/null 2>/dev/null || true)
  printf '%s\n' "$paths" | grep -qiE '\.Rnw$' && { echo true; return; }
  for f in $(printf '%s\n' "$paths" | grep -iE '^(vignettes|inst)/.*\.Rmd$|^R/.*\.[Rr]$' | head -200); do
    printf '%s\n' "$(raw "$repo" "$f")" \
      | grep -qiE 'pdf_document|latex_engine|beamer_presentation|tufte_handout|pdf_book|pdf_vignette' \
      && { echo true; return; }
  done
  echo false
}

# The tier currently deployed in a package's R-CMD-check caller (.yaml, falling back to the
# pre-migration .yml), e.g. important / cran / unimportant; empty if there is no caller or no
# tier: line. Used by the pre-flight to spot packages a sync would silently downgrade.
deployed_tier() {
  local repo="$1" wf
  wf=$(raw "$repo" .github/workflows/R-CMD-check.yaml)
  [ -n "$wf" ] || wf=$(raw "$repo" .github/workflows/R-CMD-check.yml)
  printf '%s\n' "$wf" | awk -F: '/^[[:space:]]*tier:[[:space:]]*[A-Za-z]/{gsub(/[[:space:]]/,"",$2); print $2; exit}'
}

# Emit the packages to process. With a whitelist, iterate it directly (reliable for piloting).
# Otherwise fetch the org repo list, retrying until it looks complete (>=300) so a partial
# response can't silently drop packages.
repo_source() {
  if [ -n "$ONLY" ]; then printf '%s\n' $ONLY; return; fi
  local out i
  for i in 1 2 3 4 5 6; do
    out=$(gh repo list "$ORG" --no-archived --source --limit 400 \
            --json name,defaultBranchRef --jq '.[] | select(.defaultBranchRef.name != null) | .name' 2>/dev/null || true)
    [ "$(printf '%s\n' "$out" | grep -c .)" -ge 300 ] && { printf '%s\n' "$out"; return; }
    sleep 3
  done
  echo "WARN  repo list looks incomplete ($(printf '%s\n' "$out" | grep -c .) repos)" >&2
  printf '%s\n' "$out"
}

# Render the caller workflows into $1=.github/workflows dir using tier/jags/cmdstan/private/cran in scope.
render_callers() {
  local wf="$1" eng="$ENGINE_REF"
  cat > "$wf/R-CMD-check.yaml" <<YAML
name: R-CMD-check
on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master, dev]
permissions:
  contents: read
jobs:
  R-CMD-check:
    uses: $ORG/.github/.github/workflows/R-CMD-check.yaml@$eng
    with:
      tier: $tier
      jags: $jags
      cmdstan: $cmdstan
      tex: $tex
      private: $private
    secrets: inherit
YAML
  cat > "$wf/test-coverage.yaml" <<YAML
name: test-coverage
on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master, dev]
permissions:
  contents: read
jobs:
  test-coverage:
    uses: $ORG/.github/.github/workflows/test-coverage.yaml@$eng
    with:
      cmdstan: $cmdstan
      tex: $tex
      private: $private
    secrets: inherit
YAML
  cat > "$wf/pkgdown.yaml" <<YAML
name: pkgdown
on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master, dev]
  release:
    types: [published]
  workflow_dispatch:
permissions:
  contents: write
jobs:
  pkgdown:
    uses: $ORG/.github/.github/workflows/pkgdown.yaml@$eng
    with:
      cmdstan: $cmdstan
      private: $private
    secrets: inherit
YAML
  if [ "$cran" = true ]; then
    cat > "$wf/check-no-suggests.yaml" <<YAML
name: check-no-suggests
on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master, dev]
permissions:
  contents: read
jobs:
  check-no-suggests:
    uses: $ORG/.github/.github/workflows/check-no-suggests.yaml@$eng
    with:
      private: $private
    secrets: inherit
YAML
    # R-hub is dispatch-triggered (rhub::rhub_check()) and r-hub-owned, so it is vendored
    # from the canonical template rather than invoked as a reusable caller. CRAN tier only.
    cp "$RHUB_TPL" "$wf/rhub.yaml"
  fi
}

# ---- --close-old: retire the previous flat rollout -------------------------------------------
if [ "$MODE" = close ]; then
  gh search prs --owner "$ORG" --state open "head:$OLD_BRANCH" --limit 200 --json repository,number </dev/null \
    | jq -r '.[] | "\(.repository.name) \(.number)"' | while read -r repo num; do
      [ -n "$repo" ] || continue
      [ "$repo" = ".github" ] && continue
      gh pr close "$num" --repo "$ORG/$repo" --delete-branch </dev/null 2>/dev/null \
        && echo "closed $repo #$num" || echo "FAIL close $repo #$num"
      # close the backfilled issue if present
      iss=$(gh issue list --repo "$ORG/$repo" --state open --search 'Standardize GitHub Actions in:title' --json number --jq '.[0].number // empty' </dev/null 2>/dev/null || true)
      [ -n "$iss" ] && gh issue close "$iss" --repo "$ORG/$repo" </dev/null 2>/dev/null && echo "  closed issue #$iss"
      sleep 1
    done
  echo "Done closing old rollout."
  exit 0
fi

[ "$MODE" = apply ] || echo "DRY RUN (--apply to act, --close-old to retire the old rollout)"
echo

cran_n=0 imp_n=0 unimp_n=0 priv_n=0 jags_n=0 cmdstan_n=0 tex_n=0 act=0 failed=""

# Capture the package list once: the pre-flight and the main loop iterate the same set.
PKGS=$(repo_source)

# ---- pre-flight: important-tier candidates ---------------------------------------------------
# Flag packages whose deployed caller says tier: important but which are neither registry-pinned
# nor active on CRAN (computed tier unimportant) -> this sync would downgrade them. The deployed
# tier is fetched only for these computed-unimportant packages. Confirmed candidates are appended
# to the registry now, so the main loop (which resolves tier by awk over the registry per package)
# picks them up as important with no further change.
SKIP_CANDIDATES=""
for repo in $PKGS; do
  [ -n "$repo" ] || continue
  case " $EXCLUDE " in *" $repo "*) continue ;; esac
  case "$repo" in *-book|*-docs) continue ;; esac
  [ -n "$(awk -v p="$repo" '$1==p{print $2}' "$REGISTRY" | head -1)" ] && continue   # registry-pinned
  is_cran "$repo" && continue                                                        # active on CRAN
  [ "$(deployed_tier "$repo")" = important ] || continue                             # deployed important only
  if [ "$MODE" != apply ]; then
    echo "CANDIDATE $repo (deployed=important, computed=unimportant)"
  elif [ -t 0 ]; then
    printf '\n%s is deployed tier=important but is not in the registry and not on CRAN.\n' "$repo" >&2
    printf 'Add %s to the important list (tools/package-tiers.tsv) and keep it important? [y/N] ' "$repo" >&2
    read -r ans </dev/tty || ans=""
    case "$ans" in
      [Yy]*) printf '%s important\n' "$repo" >> "$REGISTRY"
             echo "  added $repo to the registry (commit + PR this package-tiers.tsv change to .github separately)" >&2 ;;
      *)     echo "  $repo will be rolled out as unimportant (downgrade)" >&2 ;;
    esac
  else
    SKIP_CANDIDATES="$SKIP_CANDIDATES $repo"
  fi
done
[ -n "$SKIP_CANDIDATES" ] && echo "SKIP (non-interactive; deployed important, not formalized -> left untouched):$SKIP_CANDIDATES" >&2
echo

while IFS= read -r repo <&3; do
  [ -n "$repo" ] || continue
  case " $EXCLUDE " in *" $repo "*) continue ;; esac
  case "$repo" in *-book|*-docs) continue ;; esac
  case " $SKIP_CANDIDATES " in *" $repo "*) echo "SKIP  $repo (important-candidate, non-interactive run)"; continue ;; esac
  sleep 1

  # Package/fledge gate. The contents API returns spurious empties under load, so a transient
  # miss must never silently drop a repo. With an explicit name list the operator has already
  # vetted the packages: trust the list, warn (don't drop) if DESCRIPTION can't be confirmed,
  # and skip the NEWS fledge requirement. Only the full org sweep applies the strict gate.
  desc=$(raw_gate "$repo" DESCRIPTION)
  if [ -n "$ONLY" ]; then
    printf '%s\n' "$desc" | grep -q '^Package:' \
      || echo "WARN  $repo: DESCRIPTION not confirmed after retries (proceeding; jags may default to false)"
  else
    printf '%s\n' "$desc" | grep -q '^Package:' || continue
    printf '%s\n' "$(raw_gate "$repo" NEWS.md)" | grep -qi 'fledge' || continue
  fi

  # tier: registry override > CRAN > unimportant
  oncran=false; is_cran "$repo" && oncran=true
  tier=$(awk -v p="$repo" '$1==p{print $2}' "$REGISTRY" | head -1)
  if [ -z "$tier" ]; then if [ "$oncran" = true ]; then tier=cran; else tier=unimportant; fi; fi
  # The CRAN-only checks (check-no-suggests + vendored rhub) key off actual CRAN
  # membership, independent of tier, so a registry-pinned tier (e.g. important) on a
  # CRAN package still gets them.
  cran=false; { [ "$tier" = cran ] || [ "$oncran" = true ]; } && cran=true

  # private from visibility
  vis=$(gh_try gh repo view "$ORG/$repo" --json visibility --jq '.visibility' || echo PUBLIC)
  private=false; [ "$vis" = PRIVATE ] && private=true

  # jags from DESCRIPTION: a JAGS R dependency or a JAGS SystemRequirements.
  # Match the package names as whole words (not a bare "jags" substring, which also hit
  # prose in the Description field and added the JAGS installs to packages that don't use it).
  # jmbr pulls in rjags transitively, but its name appears in prose too (embr's Description
  # names the whole family), so match it only as a tidy one-per-line dependency entry.
  jags=false
  printf '%s\n' "$desc" | grep -qiE '\b(rjags|runjags|jagsUI|R2jags)\b' && jags=true
  printf '%s\n' "$desc" | grep -qiE '^[[:space:]]+jmbr,?[[:space:]]*$' && jags=true
  printf '%s\n' "$desc" | grep -qiE '^SystemRequirements:.*JAGS' && jags=true

  # cmdstan from DESCRIPTION: a cmdstanr/smbr2 dependency (tidy one-per-line entries, since
  # smbr appears in prose) or a CmdStan SystemRequirements. Drives the CmdStan toolchain
  # install in the pkgdown build, where articles fit Stan models for real.
  cmdstan=false
  printf '%s\n' "$desc" | grep -qiE '^[[:space:]]+(cmdstanr|smbr2),?[[:space:]]*$' && cmdstan=true
  printf '%s\n' "$desc" | grep -qiE '^SystemRequirements:.*CmdStan' && cmdstan=true

  # tex auto-detected from repo contents (PDF vignettes or PDF-rendering R code).
  default=$(gh_try gh api "repos/$ORG/$repo" --jq '.default_branch' </dev/null || echo main)
  tex=$(detect_tex "$repo" "$default")

  owner=$(printf '%s\n' "$(raw "$repo" .github/CODEOWNERS)" | grep -E '^\*[[:space:]]' | head -n1 | grep -oE '@[A-Za-z0-9_-]+' | head -n1 | sed 's/@//' || true)
  route=normal; [ "$owner" != joethorley ] && route="review -> @${owner:-???}"

  case "$tier" in cran) cran_n=$((cran_n+1));; important) imp_n=$((imp_n+1));; *) unimp_n=$((unimp_n+1));; esac
  [ "$private" = true ] && priv_n=$((priv_n+1)); [ "$jags" = true ] && jags_n=$((jags_n+1)); [ "$cmdstan" = true ] && cmdstan_n=$((cmdstan_n+1)); [ "$tex" = true ] && tex_n=$((tex_n+1)); act=$((act+1))

  if [ "$MODE" != apply ]; then
    printf 'TODO  %-22s tier=%-11s cran=%-5s private=%-5s jags=%-5s cmdstan=%-5s tex=%-5s route=%s\n' "$repo" "$tier" "$cran" "$private" "$jags" "$cmdstan" "$tex" "$route"
    continue
  fi

  # If the CI system already has an open PR for this repo (identified by the f-ci head branch, so
  # only ever its own PRs, never hand-authored ones), close it and reopen a fresh one rather than
  # skip, so a re-run always reflects the current classification. Closing (vs merging) leaves any
  # linked tracking issue open, so close that too. The force-push + gh pr create below then open
  # the replacement. If the close fails, skip the repo to avoid leaving two open PRs.
  existing=$(gh pr list --repo "$ORG/$repo" --head "$BRANCH" --state open --json number --jq '.[0].number // empty' </dev/null)
  if [ -n "$existing" ]; then
    iss_old=$(gh pr view "$existing" --repo "$ORG/$repo" --json body --jq '.body // ""' </dev/null 2>/dev/null \
                | grep -oiE 'closes #[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
    if gh pr close "$existing" --repo "$ORG/$repo" --delete-branch </dev/null 2>/dev/null; then
      echo "CLOSE $repo #$existing (stale $BRANCH PR; replacing)"
      [ -n "$iss_old" ] && gh issue close "$iss_old" --repo "$ORG/$repo" </dev/null 2>/dev/null \
        && echo "  closed linked issue #$iss_old"
    else
      echo "WARN  $repo: could not close existing $BRANCH PR #$existing; skipping to avoid a duplicate"; continue
    fi
  fi

  echo "APPLY $repo (tier=$tier private=$private jags=$jags cmdstan=$cmdstan tex=$tex route=$route)"
  work=$(mktemp -d)
  if (
    set -e
    git clone -q --depth 1 "git@github.com:$ORG/$repo.git" "$work/$repo"
    cd "$work/$repo"
    git checkout -b "$BRANCH" -q
    kp="$work/.keep"; mkdir -p "$kp"
    for k in $KEEP_FLEDGE $KEEP_PRESERVE; do [ -f ".github/workflows/$k" ] && cp ".github/workflows/$k" "$kp/"; done
    rm -rf .github/workflows && mkdir -p .github/workflows
    render_callers .github/workflows
    for k in $KEEP_PRESERVE; do [ -f "$kp/$k" ] && cp "$kp/$k" .github/workflows/; done
    # Migrate fledge callers: any package that had one (either extension) gets the
    # current .yaml templates; stale .yml copies are not restored.
    for f in fledge-bump fledge-tag-on-merge; do
      { [ -f "$kp/$f.yaml" ] || [ -f "$kp/$f.yml" ]; } && cp "$root/workflow-templates/$f.yaml" .github/workflows/
    done
    git add -A
    git commit -q -m "Standardize CI via reusable workflows (tier: $tier)

Replace ad hoc workflows with thin callers to the reusable CI in
$ORG/.github (R-CMD-check, test-coverage, pkgdown$([ "$cran" = true ] && echo ', check-no-suggests')),
migrating any fledge callers to the current .yaml templates.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
    git push -q -u --force origin "$BRANCH"
    body="Standardizes CI onto the reusable workflows in \`$ORG/.github\` (tier **$tier**, private=$private, jags=$jags, cmdstan=$cmdstan, tex=$tex). Callers: R-CMD-check, test-coverage, pkgdown$([ "$cran" = true ] && echo ', check-no-suggests'); fledge callers migrated to the .yaml templates where present."
    default=$(gh api "repos/$ORG/$repo" --jq '.default_branch')
    if [ "$owner" = joethorley ]; then
      gh pr create --repo "$ORG/$repo" --base "$default" --head "$BRANCH" \
        --title "Standardize CI (tier: $tier)" --body "$body" >/dev/null
    else
      iss=$(gh issue create --repo "$ORG/$repo" --title "Standardize CI onto reusable workflows" --body "$body" 2>/dev/null | grep -oE '[0-9]+$' || true)
      gh pr create --repo "$ORG/$repo" --base "$default" --head "$BRANCH" \
        --title "Standardize CI (tier: $tier)" ${owner:+--assignee "$owner" --reviewer "$owner"} \
        --body "${iss:+Closes #$iss.

}$body" >/dev/null
    fi
  ); then echo "  done $repo"; else echo "FAIL  $repo (re-run to retry)"; failed="$failed $repo"; fi
  rm -rf "$work"
done 3< <(printf '%s\n' "$PKGS")

echo
echo "packages: $act | cran: $cran_n | important: $imp_n | unimportant: $unimp_n | private: $priv_n | jags: $jags_n | cmdstan: $cmdstan_n | tex: $tex_n"
[ -n "$failed" ] && echo "FAILED (re-run):$failed"
[ "$MODE" = apply ] || echo "Dry run. Re-run with --apply (optionally package names) to act."
