---
name: vik-handback
description: Hand a ticket back to the PO in one deterministic step (updates your comment + To-Do + unassign).
allowed-tools: [bash]
---
# vik handback
Run: `vik handback <id> "<html reason>"`
Use this the moment you decide you CANNOT implement a ticket (unclear/contradictory spec, needs
another team, out of scope). It does the whole hand-back atomically:
- UPDATES your single status comment (the same one `vik status` maintains) with the reason,
- moves the ticket to "To-Do",
- unassigns you.
Moving out of Doing / unassigning tears the environment down, so this is the clean exit -- do NOT
separately `vik comment`/`move`/`unassign`, and do NOT leave the ticket assigned in Doing. Pass only
the reason BODY as HTML (`<p>`, `<ul><li>`, `<strong>`) with a short "What I checked" and a specific
"What I need to proceed"; the "Dev agent / Handed back" box is added for you. (If your progress
comments went through `vik status`, this updates that same comment -- one clean comment, not a pile.)
