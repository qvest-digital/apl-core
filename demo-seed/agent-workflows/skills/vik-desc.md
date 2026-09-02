---
name: vik-desc
description: Set a Vikunja ticket's description (the agreed spec belongs here, not in comments).
allowed-tools: [bash]
---
# vik desc
Run: `vik desc <id> "<html>"`
Pass the numeric ticket id and the description as HTML (Vikunja renders HTML, not markdown -- use <h3>, <p>, <ul>/<li>, <strong>, <code>). Prints `set description on #<id>`.
This is where the AGREED specification, scope, and acceptance criteria go. Use `vik-comment` only for discussion/decisions, not for the spec itself.
