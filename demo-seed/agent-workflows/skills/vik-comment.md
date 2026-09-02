---
name: vik-comment
description: Add a comment to a Vikunja ticket.
allowed-tools: [bash]
---
# vik comment
Run: `vik comment <id> "<text>"`
Pass the numeric ticket id and the comment text (quoted). Vikunja renders HTML in comments. Prints `commented on #<id>`.
