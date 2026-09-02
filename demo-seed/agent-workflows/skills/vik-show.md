---
name: vik-show
description: Read one Vikunja ticket (title, status, project, description).
allowed-tools: [bash]
---
# vik show
Run: `vik show <id>`
Pass the numeric ticket id (no `#`). Output: title, status, project id, and the first ~500 chars of the description (HTML stripped).
