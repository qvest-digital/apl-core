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

After the line ===TICKET COMMENT=== output ONLY the final ticket description as
clean HTML (<p>, <ul>/<li>, <strong>, <code>) -- the context/why plus the agreed
acceptance criteria, ready to save as the ticket body. Vikunja renders HTML, not
markdown. No preamble, no questions, no commentary."""
else:
    prompt = f"""Coach this Vikunja ticket.
Ticket #{TASK_ID} (team {TEAM})
Title: {title}
Description: {desc or '(empty)'}
Comment thread:
{thread or '(none)'}

Coach it now."""

# 2. Open the workstream on the team's review node, tell the ticket where to
#    watch it live, then run it. We do NOT close it -- it stays watchable, and
#    Turnstone auto-closes idle workstreams later. project_id (optional) scopes
#    visibility to a Turnstone project so non-admin members can watch too.
from turnstone.sdk import TurnstoneServer  # noqa: E402

PROJECT_ID = os.environ.get("PROJECT_ID", "")
with TurnstoneServer(NODE_URL, token=TS_PAT) as c:
    ws = c.create_workstream(
        persona="the-product-owner", skill="vikunja-ticket-coach",
        name=f"ticket-{TASK_ID}", project_id=PROJECT_ID,
    )
    # Deep-link is /node/<node_id>/?ws_id=<id> -- the console-home /?ws_id= form
    # only lands on the dashboard. The review node is given a stable node id
    # (<team>-review-agent via TURNSTONE_NODE_ID) so this is deterministic.
    watch_url = f"https://turnstone.{DOMAIN}/node/{TEAM}-review-agent/?ws_id={ws.ws_id}"
    vik("PUT", f"/tasks/{TASK_ID}/comments",
        {"comment": f'<p>🤖 Coaching this ticket &mdash; '
                    f'<a href="{watch_url}">watch the agent live in Turnstone</a>. '
                    f'The proposed description &amp; acceptance criteria will follow here shortly.</p>'})
    print(f"posted watch link for ws {ws.ws_id}")
    # Fire the message and POLL for completion. We do NOT use send_and_wait: it
    # blocks on a ws_state="idle" SSE event, which does not reliably reach this
    # non-mesh pipeline pod, so it would hang until timeout even though the turn
    # finishes in seconds. Poll list_workstreams for state and read the answer
    # from history once idle -- state is the shared-DB truth, no SSE needed.
    import time  # noqa: E402

    def _assistant_text(hist):
        for m in reversed(getattr(hist, "messages", None) or []):
            if (m.get("role") or m.get("type") or "") != "assistant":
                continue
            c2 = m.get("content")
            if isinstance(c2, str) and c2.strip():
                return c2.strip()
            if isinstance(c2, list):
                t = "".join(p.get("text", "") if isinstance(p, dict) else str(p) for p in c2).strip()
                if t:
                    return t
            if (m.get("text") or "").strip():
                return m["text"].strip()
        return ""

    c.send(prompt, ws.ws_id)
    reply = ""
    deadline = time.time() + 300
    while time.time() < deadline:
        time.sleep(3)
        try:
            infos = c.list_workstreams()
            st = next((w.state for w in getattr(infos, "workstreams", []) if w.ws_id == ws.ws_id), "")
        except Exception:
            st = ""
        if (st or "").lower() in ("idle", "attention", "error"):
            reply = _assistant_text(c.get_history(ws.ws_id))
            if reply or (st or "").lower() == "error":
                break
    print(f"turn done, state={st}, reply {len(reply)} chars")
    # deliberately not closed -- leave it watchable

# 3. Actuate (the pipeline is the sole writer -- the agent has no vikunja tool).
# Take only what follows the sentinel, dropping the agent's exploration narration.
SENTINEL = "===TICKET COMMENT==="
body = (reply.split(SENTINEL)[-1] if SENTINEL in reply else reply).strip()
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
