# .github
We help organizations understand biological systems through data and decision analysis, database design, and software development.

## Continuous integration

This repo centrally manages GitHub Actions for the org's R packages.
CI logic lives in reusable workflows here; each package carries thin caller workflows that pass its classification (tier, plus auto-detected private/jags/tex/CRAN), so updating a reusable workflow propagates to every package on its next run.

Day-to-day use:

- `tools/sync-ci.sh` (dry run) classifies every package and shows the planned action.
- `tools/sync-ci.sh --apply [pkg ...]` renders the callers and opens routed PRs.
- `tools/package-tiers.tsv` is the tier registry; list a package there only to promote it to `important` or force a tier.

To promote a package to `important`, or to keep a manually promoted one important, run `--apply` from a real terminal: a pre-flight prompts before it would otherwise downgrade such a package.

See [`CI-SYSTEM.md`](CI-SYSTEM.md) for the full reference (components, classification, tier matrices, the candidate gate, and common tasks).
Related: [`fledge-automation.md`](fledge-automation.md), [`GO-LIVE.md`](GO-LIVE.md), [`CI-ROLLOUT-STATUS.md`](CI-ROLLOUT-STATUS.md).
