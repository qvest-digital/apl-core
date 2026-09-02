---
name: citest
description: Rehearse the team's real CI pipeline locally (host mode, no Docker) before opening/updating a PR.
allowed-tools: [bash]
---
# citest
Run (from INSIDE the repo checkout): `citest`
Runs the team's real `.gitea/workflows/ci.yml` locally in HOST mode using the toolchain baked into
this node -- the same engine (gitea-runner = nektos/act), workflow, and tools the cluster's
merge-gate runner uses. **A green `citest` means the merge gate will go green.** No Docker, no
per-step containers. It derives the Gitea token/URL from the node itself, so pass nothing.
ALWAYS run `citest` and get it green BEFORE `pr open`, and again after every `/rework` / `/resolve`.
If it fails, read the output, fix the code, and re-run until green -- do not open/leave a red PR.
Do NOT reach for Docker, dind, or a build.sh: host mode is the whole point.
