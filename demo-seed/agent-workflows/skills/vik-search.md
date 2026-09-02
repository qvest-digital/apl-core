---
name: vik-search
description: Find Vikunja tickets matching keywords. Use before creating, to check for duplicates.
allowed-tools: [bash]
---
# vik search
Run: `vik search "<keywords>"`
Quote the keywords. Output: up to 8 lines, `#<id> [open|done] <title>`. Empty output means no matches. Run this (and `vik-similar`) BEFORE creating any ticket.
