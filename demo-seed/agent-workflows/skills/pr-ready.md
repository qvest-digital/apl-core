---
name: pr-ready
description: Mark a draft (WIP) pull request ready for review.
allowed-tools: [bash]
---
# pr ready
Run (from inside the repo checkout): `pr ready <pr-index>`
Marks the PR ready for review (strips the "WIP:" prefix). The pipeline opens your PR as a DRAFT
(work-in-progress) so a preview environment exists while you work; call `pr ready` only when the
change is actually done, `citest` is green, and you want reviewers to treat it as merge-ready.
