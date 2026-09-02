---
name: vik-unassign
description: Remove an assignee from a Vikunja ticket (defaults to yourself).
allowed-tools: [bash]
---
# vik unassign
Run: `vik unassign <id> [<user-id>]`
Removes an assignee from ticket #<id>. With no user id it removes YOURSELF (the agent) -- use this when handing a ticket back to the PO, so you are no longer its assignee. `vik me` prints your own user id if you need it. Prints `unassigned user <id> from #<id>`.
