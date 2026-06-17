#!/usr/bin/env bash
#
# Standardize GitHub Actions across the fledge-managed Poisson Consulting packages.
#
# Reduces each package's .github/workflows/ to the standard core 5:
#   R-CMD-check.yaml, pkgdown.yaml, test-coverage.yaml  (from tools/standard-workflows/)
#   fledge-bump.yml, fledge-tag-on-merge.yml            (preserved as-is)
# and deletes everything else (custom composite-action directories, R-CMD-check-dev/-status,
# commit-/format-suggest, copilot-setup-steps, lock, pr-commands, revdep, rhub, slack-check,
# pkgdown-build/-deploy, bookdown, the old fledge.yaml, coverage.yaml, etc.).
#
# R-CMD-check uses the JAGS variant when the package depends on JAGS (rjags/runjags/jagsUI/
# R2jags); Linux system requirements (incl. JAGS, GDAL) are auto-installed by
# setup-r-dependencies, so no other variant is needed. The per-repo PR + its CI are the safety
# net: a red R-CMD-check means that package has a system dep needing manual setup (e.g. Stan/
# cmdstan) -- do not merge it; handle by hand.
#
# Changes go through one PR per repo, routed to the repo's CODEOWNER:
#   * owner == joethorley -> normal PR.
#   * otherwise           -> an issue first, then a DRAFT PR assigned to the owner (never self-merged).
#
# Already-standard packages (exactly the core 5, nothing else) are skipped.
#
# Usage:
#   tools/standardize-actions.sh            # dry run: classify every package and the planned action
#   tools/standardize-actions.sh --apply    # create branches + PRs
#   tools/standardize-actions.sh --apply pkgA pkgB   # restrict --apply to named packages (pilot)
#
# Requires: gh (authenticated, with the `workflow` scope), git (SSH push), base64.

set -euo pipefail

ORG=poissonconsulting
BRANCH=f-standardize-actions
EXCLUDE="dksandbox chktemplate poissontemplate"
KEEP="R-CMD-check.yaml pkgdown.yaml test-coverage.yaml fledge-bump.yml fledge-tag-on-merge.yml"

APPLY=false
[ "${1:-}" = "--apply" ] && { APPLY=true; shift; }
ONLY="$*"   # optional whitelist of package names

repo_root=$(git rev-parse --show-toplevel)
tpl="$repo_root/tools/standard-workflows"
for f in R-CMD-check.yaml R-CMD-check-jags.yaml pkgdown.yaml test-coverage.yaml; do
  [ -f "$tpl/$f" ] || { echo "Missing template: $tpl/$f" >&2; exit 1; }
done

$APPLY || echo "DRY RUN (pass --apply to act)"
echo

# Run a gh command, retrying on transient gateway/rate errors; return immediately on real
# errors (e.g. 404). GitHub's gateway flakes intermittently and a silent drop would
# misclassify a repo, so this guards every read.
gh_try() {
  local i out err; err=$(mktemp)
  for i in 1 2 3 4 5 6; do
    if out=$("$@" 2>"$err"); then rm -f "$err"; printf '%s' "$out"; return 0; fi
    # Only a clear "absent" is non-retryable; everything else is treated as transient.
    if grep -qiE 'HTTP 404|Not Found|Could not resolve to' "$err"; then rm -f "$err"; return 1; fi
    sleep 3
  done
  echo "WARN  API failure, gave up after retries: $* :: $(tr '\n' ' ' < "$err" | tail -c 140)" >&2
  rm -f "$err"; return 2
}

# Fetch a file's raw content from the default branch, empty if absent (or unreachable).
raw() { gh_try gh api -H "Accept: application/vnd.github.raw" "repos/$ORG/$1/contents/$2" || true; }

std=0 skip=0 act=0 jags=0 manualroute=0

while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  [ -n "$ONLY" ] && ! printf '%s\n' $ONLY | grep -qx "$repo" && continue
  case " $EXCLUDE " in *" $repo "*) continue ;; esac
  # Bookdown books and docs sites carry a Package: DESCRIPTION + fledge NEWS but are not R
  # packages; standardizing would wipe their book-build CI, so skip them.
  case "$repo" in *-book|*-docs) continue ;; esac

  # Throttle to avoid secondary rate limiting (which manifests as spurious 404s).
  sleep 1

  # R package + fledge-managed? (fetch each file once and reuse below)
  desc=$(raw "$repo" DESCRIPTION)
  printf '%s\n' "$desc" | grep -q '^Package:' || continue
  news=$(raw "$repo" NEWS.md)
  printf '%s\n' "$news" | grep -qi 'fledge' || continue

  # Current workflow entries (files and dirs).
  entries=$(gh_try gh api "repos/$ORG/$repo/contents/.github/workflows" --jq '.[].name' || true)
  [ -z "$entries" ] && { echo "SKIP  $repo (no workflows dir)"; skip=$((skip+1)); continue; }

  extras=""
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    case " $KEEP " in *" $e "*) ;; *) extras="$extras $e" ;; esac
  done <<EOF
$entries
EOF

  has_trio=true
  for w in R-CMD-check.yaml pkgdown.yaml test-coverage.yaml; do
    printf '%s\n' "$entries" | grep -qx "$w" || has_trio=false
  done

  if [ -z "${extras# }" ] && $has_trio; then
    echo "OK    $repo (already standard)"; std=$((std+1)); continue
  fi

  # JAGS needed?
  need_jags=false
  if printf '%s\n' "$desc" | grep -qiE 'jags|rjags|runjags|jagsUI|R2jags'; then need_jags=true; fi
  if printf '%s\n' "$(raw "$repo" .github/workflows/R-CMD-check.yaml)" | grep -qi 'jags'; then need_jags=true; fi
  $need_jags && jags=$((jags+1))

  # CODEOWNER + PR route.
  owner=$(printf '%s\n' "$(raw "$repo" .github/CODEOWNERS)" | grep -E '^\*[[:space:]]' | head -n1 | grep -oE '@[A-Za-z0-9_-]+' | head -n1 | sed 's/@//' || true)
  route="normal"; [ "$owner" != "joethorley" ] && { route="issue+draft -> @${owner:-???}"; manualroute=$((manualroute+1)); }

  act=$((act+1))
  if ! $APPLY; then
    echo "TODO  $repo  (remove:$(printf '%s' "$extras" | wc -w | tr -d ' ') extras; jags=$need_jags; route=$route)"
    continue
  fi

  # Open PR already?
  if [ -n "$(gh pr list --repo "$ORG/$repo" --head "$BRANCH" --state open --json number --jq '.[0].number // empty')" ]; then
    echo "SKIP  $repo (open $BRANCH PR exists)"; continue
  fi

  echo "APPLY $repo (jags=$need_jags route=$route)"
  work=$(mktemp -d)
  git clone -q --depth 1 "git@github.com:$ORG/$repo.git" "$work/$repo"
  cd "$work/$repo"
  git checkout -b "$BRANCH" -q
  # preserve the fledge callers
  tmpk=$(mktemp -d)
  for k in fledge-bump.yml fledge-tag-on-merge.yml; do
    [ -f ".github/workflows/$k" ] && cp ".github/workflows/$k" "$tmpk/"
  done
  rm -rf .github/workflows && mkdir -p .github/workflows
  if $need_jags; then cp "$tpl/R-CMD-check-jags.yaml" .github/workflows/R-CMD-check.yaml
  else cp "$tpl/R-CMD-check.yaml" .github/workflows/R-CMD-check.yaml; fi
  cp "$tpl/pkgdown.yaml" "$tpl/test-coverage.yaml" .github/workflows/
  cp "$tmpk"/*.yml .github/workflows/ 2>/dev/null || true
  git add -A
  git commit -q -F - <<'MSG'
Standardize GitHub Actions to the core set

Reduce .github/workflows to the standard Poisson Consulting set (R-CMD-check,
pkgdown, test-coverage + the fledge callers) and remove the rest, including the
old fledge.yaml superseded by fledge-bump.yml.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
MSG
  git push -q -u origin "$BRANCH"

  body="Reduces this package's CI to the standard Poisson Consulting set: \`R-CMD-check.yaml\`, \`pkgdown.yaml\`, \`test-coverage.yaml\` (r-lib/actions@v2$( $need_jags && echo ', JAGS variant' )), plus the unchanged \`fledge-bump.yml\` / \`fledge-tag-on-merge.yml\`. Removes all other workflows and custom action directories, and the old \`fledge.yaml\` (superseded by \`fledge-bump.yml\`). CODEOWNERS and community-health files untouched."
  default=$(gh api "repos/$ORG/$repo" --jq '.default_branch')
  if [ "$owner" = "joethorley" ]; then
    gh pr create --repo "$ORG/$repo" --base "$default" --head "$BRANCH" \
      --title "Standardize GitHub Actions to the core set" --body "$body" >/dev/null
  else
    iss=$(gh issue create --repo "$ORG/$repo" \
      --title "Standardize GitHub Actions to the core Poisson set" \
      --body "$body" --jq '.number' 2>/dev/null || true)
    pr=$(gh pr create --repo "$ORG/$repo" --draft --base "$default" --head "$BRANCH" \
      --title "Standardize GitHub Actions to the core set" \
      ${owner:+--assignee "$owner"} \
      --body "${iss:+Closes #$iss.

}$body")
    [ -n "$owner" ] && gh pr edit "$pr" --repo "$ORG/$repo" --add-reviewer "$owner" >/dev/null 2>&1 || true
  fi
  cd "$repo_root"; rm -rf "$work" "$tmpk"
done < <(gh_try gh repo list "$ORG" --no-archived --source --limit 400 \
           --json name,defaultBranchRef --jq '.[] | select(.defaultBranchRef.name != null) | .name')

echo
echo "already standard: $std | to standardize: $act (jags: $jags, non-Joe-owned routed to issue+draft: $manualroute) | skipped: $skip"
$APPLY || echo "Dry run. Re-run with --apply (optionally with package names) to act."
