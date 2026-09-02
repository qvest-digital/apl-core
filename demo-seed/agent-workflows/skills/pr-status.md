---
name: pr-status
description: Check the CI (merge-gate) state of a Gitea pull request.
allowed-tools: [bash]
---
# pr status
Run (from inside the repo checkout): `pr status <pr-index>`
Prints the PR's CI check state (`success` / `pending` / `failure` / none). This is the real merge gate that runs on the server after you open the PR (separate from your local `act` rehearsal). A green local `act` should mean this goes green; if it does not, read `pr-comments` / the checks and fix.
