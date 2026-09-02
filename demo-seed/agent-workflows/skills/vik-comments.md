---
name: vik-comments
description: Read a Vikunja ticket's comments (to see prior refinement/coaching before acting).
allowed-tools: [bash]
---
# vik comments
Run: `vik comments <id>`
Pass the numeric ticket id. Prints one line per comment, `[<author>] <text-snippet>` (HTML stripped, truncated). Read these BEFORE refining or de-duplicating -- earlier decisions and the ticket coach's suggestions live in comments, not the description. `vik-show` shows only the description.
