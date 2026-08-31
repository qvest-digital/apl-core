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

prompt = f"""Coach this Vikunja ticket.
Ticket #{TASK_ID} (team {TEAM})
Title: {title}
Description: {desc or '(empty)'}
Comment thread:
{thread or '(none)'}

Coach it now and respond with the required JSON verdict."""

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

# 3. Post the agent's answer verbatim as the comment. The pipeline is the sole
#    actuator (the agent has no vikunja write tool), so it always comments; we do
#    not ask the agent for structured JSON -- its coaching reply IS the comment.
comment = (reply or "").strip()
if comment:
    vik("PUT", f"/tasks/{TASK_ID}/comments", {"comment": comment})
    print(f"posted comment to task {TASK_ID} ({len(comment)} chars)")
else:
    print("empty reply -- nothing to post")
print("done")
