#!/usr/bin/env bash
#
# Apply the fledge branch-protection settings to the fledge-managed packages:
#   * add poisson-fledge-bot to the "bypass required pull requests" list, so the dev/auto
#     path can push the bump commit and tag directly to the default branch;
#   * require review from Code Owners, so the release path waits for the codeowner.
#
# Targets the same set as tools/rollout-fledge-automation.sh (non-forked, non-archived
# repos with a Package: DESCRIPTION and a fledge NEWS.md banner, minus EXCLUDE).
#
# Idempotent: existing bypass users/teams/apps are preserved (the bot is merged in, not
# replaced); repos already configured are reported and left alone. required_signatures is
# never changed, but repos that have it enabled are flagged because the bot pushes unsigned
# commits and their dev path would be blocked.
#
# Repos whose default branch has no protection rule (or no required-PR rule) are reported
# and skipped: creating a baseline rule where none exists is a separate governance decision.
#
# Usage:
#   tools/set-fledge-branch-protection.sh           # dry run: report current vs desired
#   tools/set-fledge-branch-protection.sh --apply   # apply changes
#
# Requires: gh (admin on the target repos), jq.

set -euo pipefail

ORG=poissonconsulting
APP_SLUG=poisson-fledge-bot
EXCLUDE="dksandbox chktemplate poissontemplate"

APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true
command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }

$APPLY || echo "DRY RUN (pass --apply to change branch protection)"
echo

changed=0; ok=0; noprot=0; norule=0; sigwarn=0; noaccess=0

while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  full="$ORG/$repo"

  case " $EXCLUDE " in *" $repo "*) continue ;; esac

  # Same target filter as the rollout script.
  desc=$(gh api -H "Accept: application/vnd.github.raw" "repos/$full/contents/DESCRIPTION" 2>/dev/null || echo "")
  printf '%s\n' "$desc" | grep -q '^Package:' || continue
  news=$(gh api -H "Accept: application/vnd.github.raw" "repos/$full/contents/NEWS.md" 2>/dev/null || echo "")
  printf '%s\n' "$news" | grep -qi 'fledge' || continue

  default=$(gh api "repos/$full" --jq '.default_branch')
  prot=$(gh api "repos/$full/branches/$default/protection" 2>/dev/null || echo "")

  if printf '%s' "$prot" | grep -q 'Branch not protected'; then
    echo "NOPROT $repo ($default) - no branch protection rule"; noprot=$((noprot + 1)); continue
  fi
  if [ -z "$prot" ] || printf '%s' "$prot" | grep -q '"message"'; then
    echo "NOACC  $repo ($default) - cannot read protection (need admin?)"; noaccess=$((noaccess + 1)); continue
  fi

  rpr=$(printf '%s' "$prot" | jq '.required_pull_request_reviews // empty')
  if [ -z "$rpr" ]; then
    echo "NORULE $repo ($default) - protected but no required-PR rule"; norule=$((norule + 1)); continue
  fi

  sig=$(printf '%s' "$prot" | jq -r '.required_signatures.enabled // false')
  co=$(printf '%s' "$rpr" | jq -r '.require_code_owner_reviews // false')
  has_app=$(printf '%s' "$rpr" | jq -r --arg a "$APP_SLUG" '([.bypass_pull_request_allowances.apps[]?.slug] | index($a)) != null')

  sig_note=""
  if [ "$sig" = "true" ]; then sig_note=" [WARN signed-commits required: dev path will be blocked]"; sigwarn=$((sigwarn + 1)); fi

  if [ "$co" = "true" ] && [ "$has_app" = "true" ]; then
    echo "OK     $repo ($default) - already configured$sig_note"; ok=$((ok + 1)); continue
  fi

  if ! $APPLY; then
    echo "TODO   $repo ($default) - codeowner-review=$co bot-bypass=$has_app$sig_note"; changed=$((changed + 1)); continue
  fi

  # Preserve existing review settings and bypass actors; merge the bot into apps.
  body=$(printf '%s' "$rpr" | jq --arg app "$APP_SLUG" '{
    dismiss_stale_reviews: (.dismiss_stale_reviews // false),
    require_code_owner_reviews: true,
    required_approving_review_count: (.required_approving_review_count // 1),
    require_last_push_approval: (.require_last_push_approval // false),
    bypass_pull_request_allowances: {
      users: [ .bypass_pull_request_allowances.users[]?.login ],
      teams: [ .bypass_pull_request_allowances.teams[]?.slug ],
      apps:  ( [ .bypass_pull_request_allowances.apps[]?.slug ] + [$app] | unique )
    }
  }')
  printf '%s' "$body" | gh api -X PATCH \
    "repos/$full/branches/$default/protection/required_pull_request_reviews" --input - >/dev/null
  echo "APPLY  $repo ($default) - configured$sig_note"; changed=$((changed + 1))
done < <(gh repo list "$ORG" --no-archived --source --limit 400 \
           --json name,defaultBranchRef \
           --jq '.[] | select(.defaultBranchRef.name != null) | .name')

echo
echo "$( $APPLY && echo changed || echo to-change): $changed | already ok: $ok | no protection: $noprot | no PR-rule: $norule | unreadable: $noaccess | signed-commit warnings: $sigwarn"
$APPLY || echo "Dry run. Re-run with --apply to act."
