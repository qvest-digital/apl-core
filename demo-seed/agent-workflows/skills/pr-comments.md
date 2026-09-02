---
name: pr-comments
description: Read the discussion on a Gitea pull request (for /rework).
allowed-tools: [bash]
---
# pr comments
Run (from inside the repo checkout): `pr comments <pr-index>`
Lists the PR's comments as `[author] text` lines (machine tags and HTML stripped). This is how you read reviewer feedback before a `/rework`: read the comments, then revise the code accordingly.
