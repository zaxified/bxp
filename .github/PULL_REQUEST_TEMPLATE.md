# Pull request

<!--
Thanks for sending a PR. Before opening, a quick note on scope: bxp values
small, focused changes. If your PR touches more than one logical area, please
consider splitting it.
-->

## Summary

<!-- One or two sentences: what does this change and why? -->

## Type of change

<!-- Mark with [x] the one that fits best -->

- [ ] Bug fix (broker parser, expression evaluator, UI, …)
- [ ] New feature (new builtin, new config option, new broker support, …)
- [ ] Refactor / cleanup (no behavior change)
- [ ] Documentation only
- [ ] Build / CI / release tooling

## Test plan

<!--
List what you ran locally. The minimum bar for non-trivial code changes is
`bash scripts/test.sh` (or at least the suite covering your area). For UI
changes, describe what you exercised in bxp-gui.
-->

- [ ] `bash scripts/test.sh` (or relevant subset) is green
- [ ] Added/updated unit tests where it made sense
- [ ] For broker parser changes: regression sample under `datasets/` updated

## Notes for reviewers

<!--
Anything reviewers should look at first, tricky bits, deliberate trade-offs,
follow-up work intentionally deferred, etc. Link related issues with
`Closes #N` to auto-close on merge.
-->
