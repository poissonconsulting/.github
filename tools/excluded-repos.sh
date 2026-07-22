# Shared exclude registry, sourced (not executed) by the fledge/CI sweep tools:
#   tools/rollout-fledge-automation.sh, tools/sync-ci.sh, tools/set-fledge-branch-protection.sh
#
# Each tool excludes these repos even when a repo would otherwise qualify (e.g. has a
# Package: DESCRIPTION and a fledge-managed NEWS.md)
# One variable per tool below, since their exclude lists aren't (currently) identical;
# edit the relevant one by hand and it takes effect immediately.

# tools/rollout-fledge-automation.sh
ROLLOUT_EXCLUDE="dksandbox chktemplate"

# tools/sync-ci.sh
SYNC_CI_EXCLUDE="dksandbox chktemplate"

# tools/set-fledge-branch-protection.sh
BRANCH_PROTECTION_EXCLUDE="dksandbox chktemplate poissontemplate"
