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
#   tier      registry override > detected-on-CRAN > unimportant (default)
#   private   auto-detected from repo visibility   -> drives GITHUB_PAT (PRIVATE_ACTIONS_PAT)
#   jags      auto-detected from DESCRIPTION / workflows
#   cran      detected on CRAN (independent of tier) -> adds check-no-suggests caller + vendored rhub.yaml
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
EXCLUDE="dksandbox chktemplate poissontemplate"
KEEP_FLEDGE="fledge-bump.yml fledge-tag-on-merge.yml"
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
  for i in 1 2 3 4 5; do
    out=$(gh api -H "Accept: application/vnd.github.raw" "repos/$ORG/$1/contents/$2" </dev/null 2>/dev/null || true)
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    sleep 2
  done
  printf '%s' "$out"
}
is_cran() { curl -fsS -o /dev/null "https://cran.r-project.org/web/packages/$1/index.html" 2>/dev/null; }

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

# Render the caller workflows into $1=.github/workflows dir using tier/jags/private/cran in scope.
render_callers() {
  local wf="$1" eng="$ENGINE_REF"
  cat > "$wf/R-CMD-check.yml" <<YAML
name: R-CMD-check
on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]
permissions:
  contents: read
jobs:
  R-CMD-check:
    uses: $ORG/.github/.github/workflows/R-CMD-check.yml@$eng
    with:
      tier: $tier
      jags: $jags
      private: $private
    secrets: inherit
YAML
  cat > "$wf/test-coverage.yml" <<YAML
name: test-coverage
on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]
permissions:
  contents: read
jobs:
  test-coverage:
    uses: $ORG/.github/.github/workflows/test-coverage.yml@$eng
    with:
      private: $private
    secrets: inherit
YAML
  cat > "$wf/pkgdown.yml" <<YAML
name: pkgdown
on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]
  release:
    types: [published]
  workflow_dispatch:
permissions:
  contents: write
jobs:
  pkgdown:
    uses: $ORG/.github/.github/workflows/pkgdown.yml@$eng
    with:
      private: $private
    secrets: inherit
YAML
  if [ "$cran" = true ]; then
    cat > "$wf/check-no-suggests.yml" <<YAML
name: check-no-suggests
on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]
permissions:
  contents: read
jobs:
  check-no-suggests:
    uses: $ORG/.github/.github/workflows/check-no-suggests.yml@$eng
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

cran_n=0 imp_n=0 unimp_n=0 priv_n=0 jags_n=0 act=0 failed=""

while IFS= read -r repo <&3; do
  [ -n "$repo" ] || continue
  case " $EXCLUDE " in *" $repo "*) continue ;; esac
  case "$repo" in *-book|*-docs) continue ;; esac
  sleep 1

  desc=$(raw_gate "$repo" DESCRIPTION)
  printf '%s\n' "$desc" | grep -q '^Package:' || continue
  printf '%s\n' "$(raw_gate "$repo" NEWS.md)" | grep -qi 'fledge' || continue

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
  jags=false
  printf '%s\n' "$desc" | grep -qiE '\b(rjags|runjags|jagsUI|R2jags)\b' && jags=true
  printf '%s\n' "$desc" | grep -qiE '^SystemRequirements:.*JAGS' && jags=true

  owner=$(printf '%s\n' "$(raw "$repo" .github/CODEOWNERS)" | grep -E '^\*[[:space:]]' | head -n1 | grep -oE '@[A-Za-z0-9_-]+' | head -n1 | sed 's/@//' || true)
  route=normal; [ "$owner" != joethorley ] && route="review -> @${owner:-???}"

  case "$tier" in cran) cran_n=$((cran_n+1));; important) imp_n=$((imp_n+1));; *) unimp_n=$((unimp_n+1));; esac
  [ "$private" = true ] && priv_n=$((priv_n+1)); [ "$jags" = true ] && jags_n=$((jags_n+1)); act=$((act+1))

  if [ "$MODE" != apply ]; then
    printf 'TODO  %-22s tier=%-11s cran=%-5s private=%-5s jags=%-5s route=%s\n' "$repo" "$tier" "$cran" "$private" "$jags" "$route"
    continue
  fi

  if [ -n "$(gh pr list --repo "$ORG/$repo" --head "$BRANCH" --state open --json number --jq '.[0].number // empty' </dev/null)" ]; then
    echo "SKIP  $repo (open $BRANCH PR exists)"; continue
  fi

  echo "APPLY $repo (tier=$tier private=$private jags=$jags route=$route)"
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
    cp "$kp"/* .github/workflows/ 2>/dev/null || true
    git add -A
    git commit -q -m "Standardize CI via reusable workflows (tier: $tier)

Replace ad hoc workflows with thin callers to the reusable CI in
$ORG/.github (R-CMD-check, test-coverage, pkgdown$([ "$cran" = true ] && echo ', check-no-suggests')),
keeping the fledge callers.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
    git push -q -u --force origin "$BRANCH"
    body="Standardizes CI onto the reusable workflows in \`$ORG/.github\` (tier **$tier**, private=$private, jags=$jags). Callers: R-CMD-check, test-coverage, pkgdown$([ "$cran" = true ] && echo ', check-no-suggests'); fledge callers unchanged."
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
done 3< <(repo_source)

echo
echo "packages: $act | cran: $cran_n | important: $imp_n | unimportant: $unimp_n | private: $priv_n | jags: $jags_n"
[ -n "$failed" ] && echo "FAILED (re-run):$failed"
[ "$MODE" = apply ] || echo "Dry run. Re-run with --apply (optionally package names) to act."
