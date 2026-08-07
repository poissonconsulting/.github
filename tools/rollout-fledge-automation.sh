#!/usr/bin/env bash
#
# Roll out the fledge automation caller workflows to poissonconsulting R packages.
#
# Targets every non-forked, non-archived repo that contains a root DESCRIPTION file
# (i.e. an R package). For each, it adds, on a branch, the two caller workflows copied
# from this repo's workflow-templates and opens a draft pull request:
#   .github/workflows/fledge-bump.yaml
#   .github/workflows/fledge-tag-on-merge.yaml
#
# Idempotent: skips repos that already have a fledge-bump caller (either
# extension) or an open rollout PR.
# Uses the GitHub API only (no per-repo clone). Run from a checkout of
# poissonconsulting/.github.
#
# Prerequisites (see fledge-automation.md):
#   * poissonconsulting/.github tagged v1 (the callers pin @v1).
#   * The poisson-fledge-bot App installed and FLEDGE_APP_* org secrets set, otherwise
#     the workflows will fail once they run.
#
# Usage:
#   tools/rollout-fledge-automation.sh                     # dry run: list target repos and actions
#   tools/rollout-fledge-automation.sh --apply             # create branches + draft PRs
#   tools/rollout-fledge-automation.sh [--apply] pkg ...   # explicit packages only; skips the
#                                                          # fledge-managed (NEWS banner) gate
#
# Requires: gh (authenticated with repo + PR scope), git, base64.

set -euo pipefail

ORG=poissonconsulting
ENGINE_REF=v1                  # version the caller workflows pin
BRANCH=f-fledge-automation     # branch created in each target repo

APPLY=false
[ "${1:-}" = "--apply" ] && { APPLY=true; shift; }
NAMES=("$@")

repo_root=$(git rev-parse --show-toplevel)

# Repos to exclude even when fledge-managed (sandboxes and templates); shared with
# tools/sync-ci.sh and tools/set-fledge-branch-protection.sh.
source "$repo_root/tools/excluded-repos.sh"
EXCLUDE="$ROLLOUT_EXCLUDE"

bump_tpl="$repo_root/workflow-templates/fledge-bump.yaml"
tag_tpl="$repo_root/workflow-templates/fledge-tag-on-merge.yaml"
for f in "$bump_tpl" "$tag_tpl"; do
  [ -f "$f" ] || { echo "Missing template: $f" >&2; exit 1; }
done

# Pre-flight: warn if the engine version the callers pin does not exist yet.
if ! gh api "repos/$ORG/.github/git/ref/tags/$ENGINE_REF" --jq '.ref' >/dev/null 2>&1; then
  echo "WARNING: $ORG/.github tag '$ENGINE_REF' does not exist yet." >&2
  echo "         Callers pin @$ENGINE_REF and will not run until it is created." >&2
fi

$APPLY || echo "DRY RUN (pass --apply to create branches and draft PRs)"
echo

# PUT a file onto $BRANCH in $full, creating or updating it.
put_file() {
  local full="$1" path="$2" local_file="$3" msg="$4"
  local content sha args
  content=$(base64 < "$local_file" | tr -d '\n')
  sha=$(gh api "repos/$full/contents/$path?ref=$BRANCH" --jq '.sha' 2>/dev/null || echo "")
  if [ -n "$sha" ]; then
    gh api -X PUT "repos/$full/contents/$path" \
      -f message="$msg" -f content="$content" -f branch="$BRANCH" -f sha="$sha" >/dev/null
  else
    gh api -X PUT "repos/$full/contents/$path" \
      -f message="$msg" -f content="$content" -f branch="$BRANCH" >/dev/null
  fi
}

added=0; skipped=0; nonpkg=0

while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  full="$ORG/$repo"

  case " $EXCLUDE " in
    *" $repo "*) echo "SKIP  $repo (excluded)"; skipped=$((skipped + 1)); continue ;;
  esac

  # R package? DESCRIPTION must have a Package: field (excludes bookdown books,
  # websites and other repos that carry a DESCRIPTION but are not packages).
  desc=$(gh api -H "Accept: application/vnd.github.raw" "repos/$full/contents/DESCRIPTION" 2>/dev/null || echo "")
  if ! printf '%s\n' "$desc" | grep -q '^Package:'; then
    nonpkg=$((nonpkg + 1)); continue
  fi
  # Already fledge-managed? NEWS.md must carry the fledge banner. Skipped for explicitly
  # named packages: the engine no-ops until a v* tag exists and generates NEWS.md itself
  # on its first bump, so the callers are safe to deploy ahead of fledge initialisation.
  if [ ${#NAMES[@]} -eq 0 ]; then
    news=$(gh api -H "Accept: application/vnd.github.raw" "repos/$full/contents/NEWS.md" 2>/dev/null || echo "")
    if ! printf '%s\n' "$news" | grep -qi 'fledge'; then
      echo "SKIP  $repo (not fledge-managed)"; skipped=$((skipped + 1)); continue
    fi
  fi
  # Already rolled out? (either extension during the .yml -> .yaml migration)
  if gh api "repos/$full/contents/.github/workflows/fledge-bump.yaml" --jq '.path' >/dev/null 2>&1 \
     || gh api "repos/$full/contents/.github/workflows/fledge-bump.yml" --jq '.path' >/dev/null 2>&1; then
    echo "SKIP  $repo (fledge-bump caller already present)"; skipped=$((skipped + 1)); continue
  fi
  # Open rollout PR already exists?
  if [ -n "$(gh pr list --repo "$full" --head "$BRANCH" --state open --json number --jq '.[0].number // empty')" ]; then
    echo "SKIP  $repo (open $BRANCH PR exists)"; skipped=$((skipped + 1)); continue
  fi

  if ! $APPLY; then
    echo "TODO  $repo (would add 2 workflows + open draft PR)"; added=$((added + 1)); continue
  fi

  default=$(gh api "repos/$full" --jq '.default_branch')
  base_sha=$(gh api "repos/$full/git/ref/heads/$default" --jq '.object.sha')
  gh api -X POST "repos/$full/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$base_sha" >/dev/null 2>&1 || true

  put_file "$full" ".github/workflows/fledge-bump.yaml"        "$bump_tpl" "Add fledge-bump workflow"
  put_file "$full" ".github/workflows/fledge-tag-on-merge.yaml" "$tag_tpl"  "Add fledge-tag-on-merge workflow"

  gh pr create --repo "$full" --draft --base "$default" --head "$BRANCH" \
    --title "Add fledge dev-version bump automation" \
    --body "Adds the \`fledge-bump\` and \`fledge-tag-on-merge\` caller workflows (engine: poissonconsulting/.github@$ENGINE_REF).

Requires the \`poisson-fledge-bot\` GitHub App and the \`FLEDGE_APP_ID\` / \`FLEDGE_APP_PRIVATE_KEY\` org secrets to be active. See poissonconsulting/.github/fledge-automation.md." >/dev/null
  echo "ADDED $repo (draft PR opened)"; added=$((added + 1))
done < <(
  if [ ${#NAMES[@]} -gt 0 ]; then
    printf '%s\n' "${NAMES[@]}"
  else
    gh repo list "$ORG" --no-archived --source --limit 400 \
      --json name,defaultBranchRef \
      --jq '.[] | select(.defaultBranchRef.name != null) | .name'
  fi
)

echo
echo "Done. packages targeted: $added, skipped: $skipped, non-packages scanned: $nonpkg"
$APPLY || echo "Re-run with --apply to act."
