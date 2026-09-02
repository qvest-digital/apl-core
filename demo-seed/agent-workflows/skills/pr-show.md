---
name: pr-show
description: Show a Gitea pull request's title, state, CI, branches, and body.
allowed-tools: [bash]
---
# pr show
Run (from inside the repo checkout): `pr show <pr-index>`
Prints `#<n> [state] title`, its head/base branches, CI state, and a trimmed body. Use it to reorient on an existing PR (e.g. after being handed a `/rework`).
