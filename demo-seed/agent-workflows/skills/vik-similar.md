---
name: vik-similar
description: Find Vikunja tickets similar to a proposed title (duplicate check).
allowed-tools: [bash]
---
# vik similar
Run: `vik similar "<title>"`
Pass the proposed ticket title. Output: up to 8 candidate lines, `#<id> [open|done] <title>`. Use alongside `vik-search` to avoid creating duplicates; report near-matches to the PO.
