---
name: vik-new
description: Create a Vikunja ticket in a project. Always duplicate-check first.
allowed-tools: [bash]
---
# vik new
Run: `vik new "<title>" <project-id>`
Quote the title; pass the numeric project id (from `vik-projects`). Prints `created #<id> <title>`. ALWAYS run `vik-search` / `vik-similar` first and confirm with the PO before creating.
