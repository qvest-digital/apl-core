---
name: vik-me
description: Print your own Vikunja user id (the agent's identity).
allowed-tools: [bash]
---
# vik me
Run: `vik me`
Prints your own numeric Vikunja user id. Useful before `vik unassign` (though `vik unassign <id>`
already defaults to yourself) or to confirm which assignee is you in `vik assignees`.
