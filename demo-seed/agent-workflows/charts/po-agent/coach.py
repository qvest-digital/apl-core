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


# Static, pipeline-injected footer appended to every comment the coach posts, so
# the reader can tell the AI-generated content (above the line) from this system
# note (below it) and always sees the available commands.
# The command legend -- shown on the opening notice, on /help, and under every
# coaching reply. /coach is the one that makes the coach actually draft.
_LEGEND = (
    '<p><strong>Reply with a command:</strong> '
    '<code>/coach</code> draft a description &amp; acceptance criteria &middot; '
    '<code>/estimate</code> effort &middot; '
    '<code>/risks</code> risks &middot; '
    '<code>/tests</code> test cases &middot; '
    '<code>/plan</code> dev plan &middot; '
    '<code>/split</code> break it up &middot; '
    '<code>/accept</code> save the description &middot; '
    '<code>/handoff &lt;team&gt;</code> file a change request to another team &middot; '
    '<code>/help</code>. Or just reply with feedback to refine.</p>'
)
# The "AI-generated" note -- ONLY on real coaching output. Its presence in a
# prior agent comment is how we detect the coach has already ENGAGED on this
# ticket (see `engaged` below); the opening notice deliberately omits it.
_AI_NOTE = (
    '<p>🤖 <strong>Ticket Coach</strong> &mdash; everything <em>above this line</em> is '
    'AI-generated; this note is added automatically.</p>'
)
_ENGAGED_SIG = "above this line"  # substring unique to _AI_NOTE
FOOTER = '<hr><blockquote>' + _AI_NOTE + _LEGEND + '</blockquote>'

# The OPENING notice: posted once when a ticket first appears, INSTEAD of
# auto-coaching. It offers the commands and gives the PO room to add a draft
# first -- the coach only drafts when explicitly asked (/coach or feedback
# once engaged). No _AI_NOTE, so it does not count as "engaged".
NOTICE_HTML = (
    '<blockquote>'
    '<p>🤖 <strong>Ticket Coach</strong> &mdash; you can refine this ticket from the comments.</p>'
    + _LEGEND +
    '</blockquote>'
)

HELP_HTML = (
    '<h3>Ticket Coach &mdash; commands</h3>'
    '<ul>'
    '<li><code>/coach</code> &mdash; draft a clear description + acceptance criteria (start here)</li>'
    '<li><code>/estimate</code> &mdash; grounded effort estimate (S/M/L) with rationale</li>'
    '<li><code>/risks</code> &mdash; technical risks, edge cases &amp; unknowns</li>'
    '<li><code>/tests</code> &mdash; acceptance / QA test cases (Given/When/Then)</li>'
    '<li><code>/plan</code> &mdash; short implementation outline for the developer</li>'
    '<li><code>/split</code> &mdash; propose breaking a large ticket into smaller ones</li>'
    '<li><code>/accept</code> &mdash; save the proposed description onto this ticket</li>'
    '<li><code>/handoff &lt;team&gt;</code> &mdash; file a change request into another team\'s inbox, cross-linked</li>'
    '<li><code>/help</code> &mdash; this list</li>'
    '<li><em>(once I\'ve drafted, just reply with feedback to refine)</em></li>'
    '</ul>'
)

# The commands the coach actually implements.
KNOWN_CMDS = {"/coach", "/handoff", "/accept", "/estimate", "/risks", "/tests", "/plan", "/split", "/help"}
UNKNOWN_HTML = "<p>Unrecognized command. Here is what I can do:</p>" + HELP_HTML


def with_footer(html):
    return html + FOOTER


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

def _thread_text(c):
    # Include prior comments (the agent's own previous suggestions AND the PO's
    # replies) so a follow-up run builds on the history -- but drop the static
    # footer so it doesn't pollute the context.
    t = strip_html(c.get("comment", "")).strip()
    low = t.lower()
    # Drop the desk's coach-commands hint comment entirely -- pure boilerplate.
    if "the product owner desk" in low and "reply with a command" in low:
        return ""
    t = t.split("🤖 Ticket Coach")[0]
    # Strip the legacy per-comment desk footer from older tickets.
    t = t.split("drafted via the Product Owner desk")[0]
    return t.rstrip(" -—").replace("&mdash;", "").strip()


thread = "\n".join(
    f"- {(c.get('author') or {}).get('username', '?')}: {_thread_text(c)}"
    for c in comments
    if _thread_text(c)
)

# /accept is handled here in the pipeline, not by the agent: if the newest
# non-agent (PO) comment is an /accept, we ask the agent for ONLY the final
# ticket body and apply it to the ticket description. Otherwise we coach.
newest_po = next(
    (c for c in reversed(comments) if (c.get("author") or {}).get("id") != my_id), None
)
newest_po_text = strip_html((newest_po or {}).get("comment", "")).strip()
_cmd_m = re.match(r"\s*(/[a-z!]+)", newest_po_text.lower())
cmd = _cmd_m.group(1) if _cmd_m else ""
# /handoff <team>: file a cross-team change request into <team>'s inbox. The target team
# is the second token; the agent only drafts the request body, coach.py does the rest.
handoff_team = ""
if cmd == "/handoff":
    _hm = re.match(r"\s*/handoff\s+([a-z0-9-]+)", newest_po_text, re.I)
    handoff_team = _hm.group(1).lower() if _hm else ""

# Do NOT double-coach a ticket the DESK created: if this same agent user created
# the ticket and no human PO has commented yet, the interactive "Product Owner"
# desk is already shaping it live -- passive coaching here just duplicates (and
# can contradict) that work. A later human-PO comment sets newest_po, so real
# follow-up requests (e.g. /estimate on an agent-created ticket) still get a reply.
creator_id = (task.get("created_by") or {}).get("id")
if my_id is not None and creator_id == my_id and newest_po is None:
    print("agent-created ticket, no PO comment yet -- the PO desk handles it, skipping")
    raise SystemExit(0)

# Has the coach already ENGAGED (posted real coaching) here? Its opening notice,
# /help and unknown-command replies deliberately omit _AI_NOTE, so they do not
# count -- only a genuine drafted reply does.
engaged = any(
    (c.get("author") or {}).get("id") == my_id and _ENGAGED_SIG in (c.get("comment") or "")
    for c in comments
)
_have_agent_comment = any((c.get("author") or {}).get("id") == my_id for c in comments)

# The coach does NOT auto-draft on a fresh ticket. With nothing explicit to act
# on -- no command, and either no PO comment yet or plain feedback before it has
# engaged -- it posts the opening notice ONCE and waits, giving the PO room to
# add a draft first. It drafts only on an explicit command (/coach, /estimate,
# ...) or on plain feedback AFTER it has engaged.
if not cmd and not engaged:
    if not _have_agent_comment:
        vik("PUT", f"/tasks/{TASK_ID}/comments", {"comment": NOTICE_HTML})
        print("posted opening notice -- waiting for a command")
    else:
        print("notice/hint already present, PO added info but no command yet -- waiting")
    raise SystemExit(0)

# /help needs no agent -- post the command legend and stop.
if cmd == "/help":
    vik("PUT", f"/tasks/{TASK_ID}/comments", {"comment": HELP_HTML + FOOTER})
    print("posted /help legend")
    raise SystemExit(0)

# Unknown slash-command: show what's actually available, don't guess/coach.
if cmd and cmd not in KNOWN_CMDS:
    vik("PUT", f"/tasks/{TASK_ID}/comments", {"comment": UNKNOWN_HTML + FOOTER})
    print(f"posted unknown-command note for {cmd}")
    raise SystemExit(0)

# /handoff needs a target team -- no agent call if it's missing.
if cmd == "/handoff" and not handoff_team:
    vik("PUT", f"/tasks/{TASK_ID}/comments", {"comment":
        "<p>Usage: <code>/handoff &lt;team&gt;</code> &mdash; name the team to send this request "
        "to, e.g. <code>/handoff reviews</code>.</p>" + FOOTER})
    print("handoff missing target team")
    raise SystemExit(0)

# The skill sets the output rules (HTML after ===TICKET COMMENT===, product voice,
# read-only, grounded). Each command just supplies the TASK; the pipeline actuates.
accept = cmd == "/accept"
_COACH_INSTR = (
    "Coach this ticket into a ready one: a clear description, concrete testable acceptance "
    "criteria (Given/When/Then) grounded in the code, the affected components, and at most "
    "2-3 clarifying questions."
)
_INSTRUCTIONS = {
    "/coach": _COACH_INSTR,
    "/estimate": "Give a grounded effort estimate (S / M / L, or rough days) with a short "
                 "rationale -- which services/files change and why. Keep it product-focused.",
    "/risks": "List the key technical risks, edge cases, and unknowns to resolve before starting; "
              "ground each in the real code where you can.",
    "/tests": "Propose concrete acceptance / QA test cases as Given/When/Then, focused on how to "
              "verify this ticket is done.",
    "/plan": "Give a short implementation outline for the developer: which files to touch and in "
             "what order. Be concise; this is the how, kept out of the ticket body.",
    "/split": "Assess whether this ticket is too big for one iteration. If yes, propose a breakdown "
              "into smaller tickets (a title + one-line scope each). If it is already right-sized, "
              "say so and why.",
}
if accept:
    task_instr = ("The product owner approved with /accept. Output ONLY the final ticket "
                  "description (context/why + the agreed acceptance criteria), ready to save as "
                  "the ticket body -- no questions, no commentary.")
elif cmd == "/handoff":
    task_instr = (
        f"The {TEAM} team needs a change in the {handoff_team} team's service to complete THIS "
        f"ticket. Draft a cross-team change request TO the {handoff_team} team: in plain product "
        f"terms, what {handoff_team} needs to change and WHY (the outcome {TEAM} needs), with "
        f"concrete testable acceptance criteria, grounded in the code you can read under "
        f"/home/gradle/repos. Write it as a clear, polite, ready-to-work ticket body from the "
        f"{TEAM} team -- no meta-commentary, no questions. Output ONLY the request body.")
else:
    # Fallback covers plain feedback after the coach has engaged -- refine, same
    # shape as /coach, reading the PO's feedback from the thread.
    task_instr = _INSTRUCTIONS.get(cmd, _COACH_INSTR)
prompt = (
    f"{task_instr}\n\n"
    f"You are the {TEAM} team's ticket coach. The {TEAM} app is live at "
    f"https://app-{TEAM}.{DOMAIN}/productpage; the sources of all four Bookinfo services are at "
    f"/home/gradle/repos/<name>. {TEAM} owns one of them -- when a change would reach into ANOTHER "
    f"team's service, call that out explicitly as cross-team work.\n"
    f"Ticket #{TASK_ID} (team {TEAM})\n"
    f"Title: {title}\n"
    f"Description: {desc or '(empty)'}\n"
    f"Comment thread (your earlier suggestions and the PO's replies -- read it):\n{thread or '(none)'}\n\n"
    f"If this is a follow-up, build on your previous suggestions and incorporate the PO's "
    f"feedback rather than starting over. Ground your answer in the code, then respond."
)

# 2. Open the workstream on the team's review node, tell the ticket where to
#    watch it live, then run it. We do NOT close it -- it stays watchable, and
#    Turnstone auto-closes idle workstreams later. project_id (optional) scopes
#    visibility to a Turnstone project so non-admin members can watch too.
from turnstone.sdk import TurnstoneServer  # noqa: E402

PROJECT_ID = os.environ.get("PROJECT_ID", "")
with TurnstoneServer(NODE_URL, token=TS_PAT) as c:
    ws = c.create_workstream(
        persona="vikunja-ticket-support", skill="vikunja-ticket-coach",
        name=f"ticket-{TASK_ID}", project_id=PROJECT_ID,
    )
    # Deep-link is /node/<node_id>/?ws_id=<id> -- the console-home /?ws_id= form
    # only lands on the dashboard. The review node is given a stable node id
    # (<team>-review-agent via TURNSTONE_NODE_ID) so this is deterministic.
    watch_url = f"https://turnstone.{DOMAIN}/node/{TEAM}-review-agent/?ws_id={ws.ws_id}"
    # One comment: it starts as the live watch-link and is EDITED into the answer
    # when the turn finishes. Capture its id so we can update it in place.
    _wc = vik("PUT", f"/tasks/{TASK_ID}/comments",
              {"comment": with_footer(
                  f'<p>🤖 Coaching this ticket &mdash; '
                  f'<a href="{watch_url}">watch the agent live in Turnstone</a>. '
                  f'The proposed description &amp; acceptance criteria will appear here shortly.</p>')})
    comment_id = (_wc or {}).get("id")
    print(f"posted watch link (comment {comment_id}) for ws {ws.ws_id}")
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
    # Close the workstream now that we have the answer -- the result lives on the
    # ticket, so the ephemeral workstream is no longer needed.
    try:
        c.close_workstream(ws.ws_id)
        print(f"closed ws {ws.ws_id}")
    except Exception as e:
        print(f"close failed (non-fatal): {e}")

# 3. Actuate by EDITING the watch-link comment in place (no second comment).
# Take only what follows the sentinel, dropping the agent's exploration narration.
SENTINEL = "===TICKET COMMENT==="
# Take everything after the FIRST sentinel, then drop any repeats: the agent
# sometimes emits a trailing sentinel too, which made split(...)[-1] grab the
# empty tail and post the "no answer" notice over a perfectly good reply.
body = (reply.partition(SENTINEL)[2] if SENTINEL in reply else reply).replace(SENTINEL, "").strip()


def update_comment(html):
    payload = {"comment": with_footer(html)}
    if comment_id:
        vik("POST", f"/tasks/{TASK_ID}/comments/{comment_id}", payload)
    else:  # fallback: the watch comment id was somehow lost
        vik("PUT", f"/tasks/{TASK_ID}/comments", payload)


if not body:
    update_comment("<p>⚠️ The coach finished without producing an answer. Please try again.</p>")
    print("empty reply -- posted a notice")
    raise SystemExit(0)
if accept:
    # PO approved: apply the agent's final body to the ticket description, and turn
    # the watch-link comment into a confirmation.
    vik("POST", f"/tasks/{TASK_ID}", {"description": body})
    update_comment("<p>✅ Applied the agreed description to this ticket.</p>")
    print(f"applied description to task {TASK_ID} ({len(body)} chars) and confirmed")
elif handoff_team:
    # Cross-team handoff: create the request ticket in <team>-inbox (public, shared with all teams,
    # so our token can write it) and cross-link both ways. Everything here is deterministic -- the
    # agent only produced `body`; coach.py resolves the inbox, sets the title/links, and files it.
    inbox_title = f"{handoff_team}-inbox"
    _projs = vik("GET", "/projects") or []
    _projs = _projs if isinstance(_projs, list) else (_projs.get("data") or [])
    _inbox = next((p for p in _projs if p.get("title") == inbox_title), None)
    if not _inbox:
        update_comment(f"<p>⚠️ Could not find <code>{inbox_title}</code> -- is team "
                       f"'{handoff_team}' set up with a public inbox? No handoff filed.</p>")
        print(f"handoff: inbox {inbox_title} not found/visible")
        raise SystemExit(0)
    _src = f"https://vikunja.{DOMAIN}/tasks/{TASK_ID}"
    _ho_title = f"Request from {TEAM}: {title}"
    _ho_desc = body + (f'<hr><p>🤝 Cross-team request from the <strong>{TEAM}</strong> team. '
                       f'Source ticket: <a href="{_src}">#{TASK_ID} {title}</a>.</p>')
    _created = vik("PUT", f"/projects/{_inbox['id']}/tasks", {"title": _ho_title})
    _new_id = (_created or {}).get("id")
    if _new_id:
        vik("POST", f"/tasks/{_new_id}", {"description": _ho_desc})
    _ho_link = f"https://vikunja.{DOMAIN}/tasks/{_new_id}"
    update_comment(f'<p>🤝 Filed a change request with the <strong>{handoff_team}</strong> team: '
                   f'<a href="{_ho_link}">#{_new_id} {_ho_title}</a> (in their inbox).</p>')
    print(f"handoff: created task {_new_id} in {inbox_title}, cross-linked from #{TASK_ID}")
else:
    # Normal coaching: replace the watch-link comment with the answer.
    update_comment(body)
    print(f"updated comment {comment_id} on task {TASK_ID} ({len(body)} chars)")
print("done")
