# Which workflow files tools/sync-ci.sh writes, keeps, or drops. Sourced, not executed.
#
# caller_wanted FILE EXISTED FIRST_SYNC PRIVATE CRAN CANARY -> yes | no | keep
#   FILE        workflow file name in the package's .github/workflows/
#   EXISTED     the package already has this file
#   FIRST_SYNC  the package has no R-CMD-check caller yet (never synced)
#   PRIVATE, CRAN, CANARY  the package's classification
# yes  = render the managed caller; no = do not write it (drop it if present);
# keep = not managed by sync-ci (e.g. bookdown.yaml, paper.yaml): leave it untouched.
# Optional callers (test-coverage, pkgdown) follow the owner's choice once a package has been
# synced: they are refreshed when present and never re-added. On a first sync they are added,
# except pkgdown on private repos (only public packages get a website).
caller_wanted() {
  local file="$1" existed="$2" first="$3" private="$4" cran="$5" canary="$6"
  case "$file" in
    R-CMD-check.yaml) echo yes ;;
    test-coverage.yaml)
      if [ "$existed" = true ] || [ "$first" = true ]; then echo yes; else echo no; fi ;;
    pkgdown.yaml)
      if [ "$existed" = true ]; then echo yes
      elif [ "$first" = true ] && [ "$private" != true ]; then echo yes
      else echo no; fi ;;
    check-no-suggests.yaml|rhub.yaml)
      if [ "$cran" = true ]; then echo yes; else echo no; fi ;;
    canary.yaml)
      if [ "$canary" = true ]; then echo yes; else echo no; fi ;;
    fledge-bump.yaml|fledge-bump.yml|fledge-tag-on-merge.yaml|fledge-tag-on-merge.yml)
      echo no ;;
    # Legacy .yml copies of managed callers are superseded by the .yaml ones.
    R-CMD-check.yml|test-coverage.yml|pkgdown.yml|check-no-suggests.yml|rhub.yml)
      echo no ;;
    *) echo keep ;;
  esac
}

# sync_workflows WF RENDERED PRIVATE CRAN CANARY
#   Update the workflow folder WF in place from freshly rendered managed callers in RENDERED:
#   drop managed files that are no longer wanted, write the wanted ones, and leave every
#   unmanaged workflow untouched. "Existed" is judged on WF as it was before any change, so a
#   legacy .yml caller (e.g. test-coverage.yml) counts as the owner keeping that caller.
sync_workflows() {
  local wf="$1" rendered="$2" private="$3" cran="$4" canary="$5" before first=true f name existed
  mkdir -p "$wf"
  before=" $(ls "$wf" | tr '\n' ' ') "
  case "$before" in *" R-CMD-check.yaml "*|*" R-CMD-check.yml "*) first=false ;; esac
  for f in "$wf"/*; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    if [ "$(caller_wanted "$name" true "$first" "$private" "$cran" "$canary")" = no ]; then rm -f "$f"; fi
  done
  for f in "$rendered"/*; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    existed=false
    case "$before" in *" $name "*|*" ${name%.yaml}.yml "*) existed=true ;; esac
    if [ "$(caller_wanted "$name" "$existed" "$first" "$private" "$cran" "$canary")" = yes ]; then cp "$f" "$wf/$name"; fi
  done
}
