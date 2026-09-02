---
name: vik-done
description: Close/complete a Vikunja ticket (mark it done).
allowed-tools: [bash]
---
# vik done
Run: `vik done <id>`
Pass the numeric ticket id. Marks the ticket complete. Prints `closed #<id>`. Use this to formally close tickets (e.g. duplicates you've consolidated) -- a comment saying "closed" does NOT close a ticket.
