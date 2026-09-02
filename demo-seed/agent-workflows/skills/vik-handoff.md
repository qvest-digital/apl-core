---
name: vik-handoff
description: File a change request into another team's inbox (cross-team handoff).
allowed-tools: [bash]
---
# vik handoff
Run: `vik handoff <team> <source-id> "<title>" "<html body>"`

Use this when a ticket needs a change in ANOTHER team's service. This ONE command does the whole
cross-team flow deterministically:
- creates a ticket in that team's public inbox (`<team>-inbox`),
- sets its description to your body PLUS a "Cross-team request from <your team>" provenance line
  that links back to the source ticket,
- comments a link to the new request on the SOURCE ticket.

You do NOT need to add provenance, links, or a back-reference yourself, and you do NOT run
`vik comment` afterwards -- `vik handoff` already cross-links both sides. Do NOT use `vik new` to
create a ticket in another team's inbox.

Arguments:
- `<team>`     the target team (e.g. `reviews`); the inbox `<team>-inbox` must exist.
- `<source-id>` the id of the ticket this request comes from (for the two-way cross-link).
- `<title>`    a short, clear request title.
- `<html body>` the request: what you need + why + acceptance criteria. Vikunja renders HTML
  (`<p>`, `<ul><li>`, `<strong>`).

Prints `filed request #<id> in <team>-inbox: <title> (source #<source-id> cross-linked)`.
