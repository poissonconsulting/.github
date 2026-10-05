#!/usr/bin/env bash
#
# Promote origin/main to the v1 tag that every package caller pins, but only after the
# candidate commit has passed actionlint and every canary package has run the reusable
# workflows at that exact commit.
#
# main is the staging ref and v1 the release ref: merging to main reaches only the canary
# packages (tools/canary-packages.txt, whose dispatch-only canary.yaml callers pin @main);
# the rest of the fleet sees a change only when this script moves v1.
#
# Steps:
#   1. resolve the candidate (origin/main) and the current v1; stop if they match;
#   2. require a successful actionlint check run on the candidate;
#   3. dispatch canary.yaml in each canary package and wait for every run;
#   4. require each run to have succeeded and to have resolved its reusables at the candidate
#      SHA (so a commit landing on main mid-run cannot be promoted untested);
#   5. with --apply, move v1 to the candidate (asks first when run from a terminal).
#
# Usage:
#   tools/promote-v1.sh            # run the canaries against main and report; v1 is not moved
#   tools/promote-v1.sh --apply    # also move v1 to the candidate when everything passed
#
# Requires: gh (authenticated, repo + workflow scopes), git (SSH), jq.

set -euo pipefail

ORG=poissonconsulting
REPO="$ORG/.github"

APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true
command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }

repo_root=$(git rev-parse --show-toplevel)
CANARIES=$(sed 's/#.*//' "$repo_root/tools/canary-packages.txt" | awk 'NF{print $1}')
[ -n "$CANARIES" ] || { echo "ERROR no canary packages listed in tools/canary-packages.txt" >&2; exit 1; }

git -C "$repo_root" fetch -q origin main
git -C "$repo_root" fetch -q --force origin 'refs/tags/v1:refs/tags/v1'
candidate=$(git -C "$repo_root" rev-parse origin/main)
current=$(git -C "$repo_root" rev-parse 'v1^{commit}')

echo "candidate (origin/main): $candidate"
echo "current   (v1):          $current"
if [ "$candidate" = "$current" ]; then
  echo "v1 already points at origin/main; nothing to promote."
  exit 0
fi
if ! git -C "$repo_root" merge-base --is-ancestor "$current" "$candidate"; then
  echo "ERROR v1 is not an ancestor of origin/main; refusing to move it (inspect by hand)" >&2
  exit 1
fi
echo
echo "Commits to promote:"
git -C "$repo_root" log --oneline "$current..$candidate"
echo

lint=$(gh api "repos/$REPO/commits/$candidate/check-runs?check_name=actionlint" \
         --jq '[.check_runs[].conclusion] | if length == 0 then "missing" else (if all(. == "success") then "success" else "failure" end) end')
if [ "$lint" != success ]; then
  echo "ERROR actionlint on $candidate: $lint (wait for it to finish or fix the workflows)" >&2
  exit 1
fi
echo "actionlint: success"
echo

# Dispatch every canary first so they run concurrently, then wait on each.
# ("pkg:run-id" pairs rather than an associative array, for macOS's bash 3.2.)
runs=""
for pkg in $CANARIES; do
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  gh workflow run canary.yaml --repo "$ORG/$pkg" >/dev/null
  id=""
  for _ in $(seq 1 20); do
    sleep 3
    id=$(gh run list --repo "$ORG/$pkg" --workflow canary.yaml --event workflow_dispatch --limit 5 \
           --json databaseId,createdAt \
           --jq "[.[] | select(.createdAt >= \"$since\")] | sort_by(.createdAt) | last | .databaseId // empty")
    [ -n "$id" ] && break
  done
  [ -n "$id" ] || { echo "ERROR could not find the dispatched canary run in $pkg" >&2; exit 1; }
  runs="$runs $pkg:$id"
  echo "dispatched $pkg: https://github.com/$ORG/$pkg/actions/runs/$id"
done
echo

failed=""
for pair in $runs; do
  pkg=${pair%%:*}; id=${pair#*:}
  gh run watch "$id" --repo "$ORG/$pkg" --exit-status --interval 30 >/dev/null 2>&1 || true
  run=$(gh api "repos/$ORG/$pkg/actions/runs/$id")
  conclusion=$(printf '%s' "$run" | jq -r '.conclusion')
  shas=$(printf '%s' "$run" | jq -r '[.referenced_workflows[].sha] | unique | join(" ")')
  if [ "$conclusion" != success ]; then
    echo "FAIL  $pkg: $conclusion"; failed="$failed $pkg"
  elif [ "$shas" != "$candidate" ]; then
    echo "FAIL  $pkg: ran reusables at [$shas], not the candidate"; failed="$failed $pkg"
  else
    echo "OK    $pkg"
  fi
done
echo

if [ -n "$failed" ]; then
  echo "Canaries failed:$failed. v1 not moved."
  exit 1
fi
if ! $APPLY; then
  echo "All canaries passed. Re-run with --apply to move v1 to $candidate."
  exit 0
fi
if [ -t 0 ]; then
  printf 'Move v1 from %s to %s for every package? [y/N] ' "${current:0:7}" "${candidate:0:7}"
  read -r ans </dev/tty || ans=""
  case "$ans" in [Yy]*) ;; *) echo "v1 not moved."; exit 0 ;; esac
fi
git -C "$repo_root" push --force origin "$candidate:refs/tags/v1"
echo "v1 -> $candidate"
