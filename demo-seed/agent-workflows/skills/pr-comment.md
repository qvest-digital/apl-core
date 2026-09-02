---
name: pr-comment
description: Add a comment to a Gitea pull request.
allowed-tools: [bash]
---
# pr comment
Run (from inside the repo checkout): `pr comment <pr-index> "<html/markdown>"`
Adds a comment to PR #<pr-index>. Use it to post the console deep link when you open the PR, to report progress, and to summarise what a `/rework` or `/resolve` changed. Prints `commented on PR #<n>`.
