---
name: vik-projects
description: List Vikunja projects (id + title). Use to find the team's <team> project id.
allowed-tools: [bash]
---
# vik projects
Run: `vik projects`
Output: one line per project, `#<id> <title>`. The team's tickets live in the project named `<team>` (same as the team name) -- read its id from this list before creating or searching within it.
