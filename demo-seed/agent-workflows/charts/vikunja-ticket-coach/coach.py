#!/usr/bin/env python3
"""Vikunja ticket coach: fetch a ticket, run the coach workstream on the team's
review node, and actuate its structured verdict back onto the ticket.

The AGENT never writes to Vikunja -- it only produces the verdict; THIS pipeline
step is the sole actuator (posts the comment, and applies the description on
action=apply). That is what makes "always comments" true and stops the bot
deciding not to.

Auth: turnstone PAT + vikunja token, both from the mounted agent-creds secret.
Everything reads from env + /creds; no arguments.
"""
import json
import os
import re
import ssl
import urllib.request

DOMAIN = os.environ["DOMAIN"]
TEAM = os.environ["TEAM"]
TASK_ID = os.environ["TASK_ID"]
NODE_URL = os.environ["NODE_URL"]  # http://<team>-review-agent.turnstone.svc.cluster.local:8080

VIK_TOKEN = open("/creds/vikunja-token").read().strip()
TS_PAT = open("/creds/turnstone-token").read().strip()

_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def vik(method, path, body=None):
    url = f"https://vikunja.{DOMAIN}/api/v1{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"Authorization": f"Bearer {VIK_TOKEN}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, context=_CTX) as r:
        return json.load(r)


def strip_html(s):
    return re.sub("<[^>]+>", "", s or "").strip()


# 1. Fetch the ticket + its comment thread for full context.
task = vik("GET", f"/tasks/{TASK_ID}")
title = task.get("title", "")
desc = strip_html(task.get("description", ""))
comments = vik("GET", f"/tasks/{TASK_ID}/comments") or []

# Loop guard (payload-shape-independent): the coach posts a comment as the agent,
# which itself fires task.comment.created. If the newest comment is the agent's
# own, this is that echo -- do nothing. Match on the agent's OWN Vikunja user id
# (asked from /user with our token) rather than a guessed username, because the
# Vikunja username is the email form and differs from the gitea/keycloak login.
# task.created (no comments yet) and a real PO comment (newest author = a human)
# both proceed. We never subscribe to task.updated, so applying a description
# does not re-trigger either.
try:
    my_id = (vik("GET", "/user") or {}).get("id")
except Exception:
    my_id = None
if comments and my_id is not None and (comments[-1].get("author") or {}).get("id") == my_id:
    print("newest comment is the agent's own -- skipping (loop guard)")
    raise SystemExit(0)

thread = "\n".join(
    f"- {(c.get('author') or {}).get('username', '?')}: {strip_html(c.get('comment', ''))}"
    for c in comments
)

# /accept is handled here in the pipeline, not by the agent: if the newest
# non-agent (PO) comment is an /accept, we ask the agent for ONLY the final
# ticket body and apply it to the ticket description. Otherwise we coach.
newest_po = next(
    (c for c in reversed(comments) if (c.get("author") or {}).get("id") != my_id), None
)
newest_po_text = strip_html((newest_po or {}).get("comment", "")).strip().lower()
accept = newest_po_text.startswith("/accept") or newest_po_text == "accept"

if accept:
    prompt = f"""The product owner approved this ticket with /accept.
Ticket #{TASK_ID} (team {TEAM})
Title: {title}
Current description: {desc or '(empty)'}
Comment thread (your latest proposed draft is in here):
{thread or '(none)'}

Output ONLY the final ticket description in clean markdown -- the context/why
plus the agreed acceptance criteria, ready to save as the ticket body. No
preamble, no questions, no commentary, no code fences around the whole thing."""
else:
    prompt = f"""Coach this Vikunja ticket.
Ticket #{TASK_ID} (team {TEAM})
Title: {title}
Description: {desc or '(empty)'}
Comment thread:
{thread or '(none)'}

Coach it now."""

# 2. Run the coach on the team's review node (persona = product-owner voice,
#    skill = the ticket-coaching workflow). send_and_wait drives one turn to
#    completion; the skill's auto_approve lets its read tools run unattended.
from turnstone.sdk import TurnstoneServer  # noqa: E402

with TurnstoneServer(NODE_URL, token=TS_PAT) as c:
    ws = c.create_workstream(
        persona="the-product-owner", skill="vikunja-ticket-coach", name=f"ticket-{TASK_ID}"
    )
    result = c.send_and_wait(prompt, ws.ws_id, timeout=280)
    reply = result.content
    try:
        c.close_workstream(ws.ws_id)
    except Exception:
        pass

# 3. Actuate (the pipeline is the sole writer -- the agent has no vikunja tool).
body = (reply or "").strip()
if not body:
    print("empty reply -- nothing to do")
    raise SystemExit(0)
if accept:
    # PO approved: apply the agent's final body to the ticket description, then
    # confirm in a comment.
    vik("POST", f"/tasks/{TASK_ID}", {"description": body})
    vik("PUT", f"/tasks/{TASK_ID}/comments",
        {"comment": "✅ Applied the agreed description to this ticket."})
    print(f"applied description to task {TASK_ID} ({len(body)} chars) and confirmed")
else:
    # Normal coaching: the reply IS the comment, posted verbatim.
    vik("PUT", f"/tasks/{TASK_ID}/comments", {"comment": body})
    print(f"posted comment to task {TASK_ID} ({len(body)} chars)")
print("done")
