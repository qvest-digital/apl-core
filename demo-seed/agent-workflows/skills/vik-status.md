---
name: vik-status
description: Post/UPDATE your single evolving status comment on a ticket (your ONLY way to report).
allowed-tools: [bash]
---
# vik status
Run: `vik status <id> "<html body>"`
This is your ONLY way to write to a ticket. It maintains ONE comment and UPDATES it in place on
every call (found via a hidden marker) -- so use it for your FIRST report and EVERY update after
("assessing", "implementing X", "opened PR #n", "reworked per feedback"). Each call rewrites the
whole comment, so pass the current full picture, not a delta. NEVER use `vik comment` for your own
progress -- that posts a SEPARATE comment and fragments your report (and then `vik handback` can't
update it). Pass only the BODY as HTML (`<p>`, `<ul><li>`, `<strong>`, `<code>` -- not markdown
`**`/`#`); the branded "Dev agent" box is added for you.
