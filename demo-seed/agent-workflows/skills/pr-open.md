---
name: pr-open
description: Open a Gitea pull request from the current branch (the merge request for your work).
allowed-tools: [bash]
---
# pr open
Run (from INSIDE the repo checkout): `pr open "<title>" "<html/markdown body>" [base-branch]`
Opens a PR from your current branch to the repo's default branch (or `[base-branch]`). Push your branch first (`git push -u origin <branch>`). The body should say what changed and why, and reference the ticket. A hidden machine tag is appended automatically (do not add one) so the platform can map the PR back to this node. Prints `opened PR #<n> <url>`.
Do NOT open a second PR for the same branch. One ticket → one branch → one PR.
