---
name: vik-move
description: Move a Vikunja ticket to a named kanban bucket (To-Do / Doing / Done).
allowed-tools: [bash]
---
# vik move
Run: `vik move <id> "<bucket>"`
Moves ticket #<id> to the named bucket in its project's Kanban view; the name is resolved to an id (buckets are "To-Do", "Doing", "Done"). Prints `moved #<id> to bucket "<bucket>"`.
Use `vik move <id> "To-Do"` as part of handing a ticket back to the PO when you cannot implement it.
