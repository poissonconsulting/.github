#!/usr/bin/env bash
# Unit tests for caller_wanted in tools/sync-ci-callers.sh. Run: bash tools/tests/test-sync-ci-callers.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source "$here/../sync-ci-callers.sh"

fails=0
# check NAME EXPECTED CALLER EXISTED FIRST_SYNC PRIVATE CRAN CANARY
check() {
  local name="$1" expected="$2"; shift 2
  local got; got=$(caller_wanted "$@")
  if [ "$got" = "$expected" ]; then echo "ok   $name"; else echo "FAIL $name: expected $expected, got $got"; fails=$((fails + 1)); fi
}

check "R-CMD-check always"               yes R-CMD-check.yaml      false false true  false false
check "coverage kept when present"       yes test-coverage.yaml    true  false true  false false
check "coverage not re-added"            no  test-coverage.yaml    false false false false false
check "coverage on first sync"           yes test-coverage.yaml    false true  true  false false
check "pkgdown kept when present"        yes pkgdown.yaml          true  false true  false false
check "pkgdown not re-added"             no  pkgdown.yaml          false false false false false
check "pkgdown first sync public"        yes pkgdown.yaml          false true  false false false
check "pkgdown first sync private"       no  pkgdown.yaml          false true  true  false false
check "no-suggests for CRAN"             yes check-no-suggests.yaml false false false true false
check "no-suggests dropped off CRAN"     no  check-no-suggests.yaml true  false false false false
check "rhub for CRAN"                    yes rhub.yaml             false false false true  false
check "canary for canary pkg"            yes canary.yaml           false false false false true
check "canary dropped when not canary"   no  canary.yaml           true  false false false false
check "fledge caller removed"            no  fledge-bump.yaml      true  false false false false
check "fledge tag caller removed"        no  fledge-tag-on-merge.yml true false false false false
check "legacy R-CMD-check.yml replaced"  no  R-CMD-check.yml       true  false false false false
check "legacy pkgdown.yml replaced"      no  pkgdown.yml           true  false false false false
check "legacy coverage.yml replaced"     no  test-coverage.yml     true  false false false false
check "legacy coverage.yaml replaced"    no  coverage.yaml         true  false false false false
check "unknown workflow preserved"       keep bookdown.yaml        true  false true  false false
check "paper preserved"                  keep paper.yaml           true  false false false false

# sync_workflows WF RENDERED PRIVATE CRAN CANARY, on fixture folders
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
rendered="$tmp/rendered"; mkdir -p "$rendered"
for f in R-CMD-check.yaml test-coverage.yaml pkgdown.yaml; do echo "new $f" > "$rendered/$f"; done
setup() { rm -rf "$tmp/wf"; mkdir -p "$tmp/wf"; for f in "$@"; do echo "old $f" > "$tmp/wf/$f"; done; }
listing() { ls "$tmp/wf" | tr '\n' ' ' | sed 's/ $//'; }
expect_files() {
  local name="$1" want="$2" got; got=$(listing)
  if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name: expected [$want], got [$got]"; fails=$((fails + 1)); fi
}

# poissonbook: a book with bookdown + fledge callers only (private, first sync)
setup bookdown.yaml fledge-bump.yaml fledge-tag-on-merge.yaml
sync_workflows "$tmp/wf" "$rendered" true false false
expect_files "book keeps bookdown, gets no pkgdown" "R-CMD-check.yaml bookdown.yaml test-coverage.yaml"

# gevr: private package whose owner removed pkgdown
setup R-CMD-check.yaml test-coverage.yaml fledge-bump.yaml fledge-tag-on-merge.yaml
sync_workflows "$tmp/wf" "$rendered" true false false
expect_files "owner-removed pkgdown stays removed" "R-CMD-check.yaml test-coverage.yaml"
grep -q "^new" "$tmp/wf/test-coverage.yaml" && echo "ok   existing caller refreshed" || { echo "FAIL existing caller refreshed"; fails=$((fails + 1)); }

# bisonpicsuite: legacy .yml callers
setup R-CMD-check.yml test-coverage.yml pkgdown.yml fledge-bump.yml fledge-tag-on-merge.yml paper.yaml
sync_workflows "$tmp/wf" "$rendered" false false false
expect_files "legacy yml migrated, paper kept" "R-CMD-check.yaml paper.yaml pkgdown.yaml test-coverage.yaml"

# slobr: old-style coverage.yaml counts as the owner keeping test coverage
setup R-CMD-check.yaml coverage.yaml pkgdown.yaml
sync_workflows "$tmp/wf" "$rendered" false false false
expect_files "legacy coverage.yaml becomes test-coverage.yaml" "R-CMD-check.yaml pkgdown.yaml test-coverage.yaml"

[ "$fails" -eq 0 ] || { echo "$fails test(s) failed"; exit 1; }
echo "all passed"
