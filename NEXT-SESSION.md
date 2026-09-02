# NEXT-SESSION — building & running agents on this platform

Fork-only working notes. **Read `CLAUDE.md` first.** This is the extensive handover
for the agent work: exact state, every mechanism, every trap, and the TODO. A fresh
session should be able to continue from this alone.

- Branch: `feat/agent-ephemeral-envs`.
- Domain: **always derive it** (`cat .taskfiles/state/seed_domain.txt`), never
  hardcode — the MetalLB range moves across rebuilds (CLAUDE.md rule 5).
- Turnstone source is checked out at **`/home/lambda/repos/turnstone`** — read it
  when unsure; the API/behaviour below was verified against it.
- **This state assumes a FRESH rebuild** (`task down CONFIRM=yes` → `task setup` →
  `go-task seed:demo`). Everything below is in source/seed; nothing is hand-applied.

---

# ⭐ SESSION UPDATE 2026-09-01 (part 2) — READ THIS FIRST

A long session. All work is **committed AND pushed** on `feat/agent-ephemeral-envs`
(HEAD `a1fe30a22`, GitHub `qvest-digital/apl-core`). Sections 0–5 below predate the big
lifecycle rework — treat THIS section as the current truth where they disagree.

## A. Where things stand right now (state at hand-off)
- The dev-bot was **reworked into a To-Do-driven, assignee-gated lifecycle** (see §B). All
  source is committed+pushed; **NOT yet tested on a live cluster** — a fresh rebuild is the
  test.
- **A rebuild was in progress at hand-off** and hit a runner-build failure (see §D) that was
  root-caused and fixed at source. The user was about to **rebuild again from clean**. If the
  cluster is up when you read this: verify §B end-to-end. If not: `task down CONFIRM=yes` →
  `task setup` (with `ANTHROPIC_API_KEY`) → `go-task seed:demo`, then verify §B.
- The **catalog was cleaned up**: charts are now `agent-node-broker` (infra), `dev-agent`,
  `po-agent`. `pull-request-agent` was **deleted** (obsolete). `po-desk` chart was **renamed
  to `po-agent`** (the internal `po-desk` SKILL and `the-po-desk` persona keep their names —
  not catalog-visible). ⚠ A live catalog push removes `charts/po-desk` → a running
  `team-<t>-poagent` install breaks until reinstalled as po-agent (moot after a fresh seed).

## B. THE NEW DEV-BOT LIFECYCLE (the headline feature — commits 302596de5, 427df1d7c, 988f4eb5e, 558c1172b)
The environment's EXISTENCE is now decoupled from whether the agent WORKS. Buckets are
literally `To-Do` / `Doing` / `Done` (verified live).

**State machine** (team-side `reconcile-ticket`, `charts/dev-agent/templates/pipeline.yaml`):
| Ticket state | Action forwarded to broker |
|---|---|
| enters **To-Do** (fresh) or **Doing** | `provision-dev` — env exists for ANY ticket |
| **Done**, task `done:true`, ticket removed from board, or **Doing→To-Do regression** | `teardown-dev` |

- Regression (Doing→To-Do closes) needs the PREVIOUS bucket. Kept per-ticket in a **team-ns
  ConfigMap `dev-ticket-<n>`**. The team default SA can't touch ConfigMaps, so the reconcile
  runs under a **dedicated `dev-agent-reconcile` SA** (new `reconcile-rbac.yaml`; the trigger's
  PipelineRun sets `taskRunTemplate.serviceAccountName`).
- reconcile passes **`assignedToAgent`** (is the ticket assigned to `agent-<team>`?) through to
  the broker — this is now decoupled from the bucket.

**Assignee-gated agent** (broker `provision-dev-env`, `charts/agent-node-broker/templates/dev-pipeline.yaml`):
- `bootstrap-workstream` sends the **KICKOFF** message (start feasibility→implement→citest→push)
  if `assignedToAgent=true`, else a **STANDBY** seed (workstream is aware of the ticket; a human
  drives it in the Turnstone UI; it must NOT start). Annotates `apl.io/dev-kicked` accordingly.
- New **`activate-agent`** task (runs `when exists=yes`, i.e. re-provision on an existing env):
  if the ticket is now assigned to the agent and `dev-kicked!=true`, sends the kickoff and flips
  the marker. So unassigned→assigned mid-life starts the agent; guarded so it never re-kicks.
- The dev **persona** (`files/dev-persona.txt`) teaches STANDBY vs GO: read your first message;
  STANDBY = don't implement, wait for a human/the go-ahead.

**PR-merge → Done** (commit 988f4eb5e): dev-agent EL gains a **`pr-merged` trigger**
(`X-Gitea-Event pull_request`, `action closed`, `pull_request.merged==true`) → **`complete-ticket`**
pipeline: posts a milestone ticket comment linking the retired PR, sets the ticket `done:true`,
and forwards `teardown-dev`. reconcile also treats `done:true` as close, so the teardown is
belt-and-suspenders. The **`pull_request`** webhook event is registered (dev-agent install hook +
the broker's ensure/teardown re-ensure), alongside `issue_comment`/`pull_request_comment`.

**Comment flow** (commit 558c1172b): ticket↔PR are cross-linked BOTH ways (PR body links the
ticket; the ticket's single evolving `<!-- dev-agent -->` comment links PR + session + preview);
standby/working states are explicit; merge posts a SEPARATE milestone comment. **Deliberately NO
teardown comment** — it would clobber the agent's handback (same evolving comment). ⚠ TODO: the
user asked for a **deeper comment-flow polish pass** (wording/edge-cases) — not yet done.

**Verify §B after rebuild**: install `dev-agent` on a team from the Console catalog, then:
1. new ticket → To-Do: env + draft PR + preview up, ticket comment links PR/session/preview,
   agent workstream on STANDBY (open the session link — aware but idle).
2. assign `agent-<team>`: agent kicks off and works (activate-agent).
3. merge the PR: ticket → Done + milestone comment + teardown.
4. Doing→To-Do regression: env closes.

## C. Earlier dev-bot fixes THIS session (all committed+pushed, deployed live on the prior cluster before the rebuild)
- `b357d038c` **atomic provision lease** — the two Vikunja webhooks (assignee+bucket) raced two
  provisions → two "On it" comments. `dedupe` now does an atomic `kubectl create configmap
  dev-lease-<team>-tk<n>`; only the first proceeds. teardown releases it unconditionally.
- `8c8154d9b` **writable HOME + verify-preview + `pr preview`** — node runs UID 1000 but image
  bakes `/home/gradle` root:root 755, so `citest`(~/.cache) and pip(~/.local) failed; mount
  emptyDirs there (+ XDG_CACHE_HOME). AND the agent posted "ready" before the preview rolled →
  new `pr preview` verb (python urllib, no curl on the node) + persona/skill now VERIFY the
  change on the live preview before reporting.
- `284c7419c` **bootstrap readiness race** — node pod goes Ready a few secs before its
  turnstone API accepts calls; the kickoff `send` raced it and failed under `set -eu`, leaving an
  empty idle workstream ("agent never starts"). Now polls the node API, annotates ws-id
  immediately, retries the send.
- `3c274f74a` + `b1f8d1123` **the /rework,/resolve webhook** — (1) the operator's webhook-
  reconcile (on per-PR AplTeamBuild create) DELETES the `issue_comment` hook; `ensure-ci-webhook`
  now re-ensures it too. (2) **this Gitea fires `pull_request_comment` (NOT issue_comment) for a
  comment ON A PR** — the hook must subscribe to BOTH; the webhook still ARRIVES with the
  issue_comment header/shape so the EL CEL/binding are unchanged. Verified live.
- `f802addc4` **`pr reply`** — a NEW branded comment (no `<!-- dev-agent -->` marker) for
  answering /rework,/resolve so it lands in-thread, vs `pr note` (the evolving status comment).
- `1408c71d0` **/rework reads the PR comments** (feedback is usually a separate comment, not in
  the `/rework` line) + surfaces questions/blockers to the PR/ticket (humans watch those, not the
  session).

## D. THE BUILD SAGA — storm, serial runners, Harbor blob corruption (commits 16473949d, a1fe30a22)
Three linked issues, all about kaniko builds on the single kind node:
1. **Build storm** (`16473949d`, `charts/team-ns/templates/builds/docker.yaml`): the operator
   registers each build's Gitea push webhook with an EMPTY `branch_filter`, and the build EL had
   no interceptor → **one push to any branch rebuilt EVERY image at once**. Fix: a CEL interceptor
   on each build's EventListener matching `body.ref == 'refs/heads/<revision>'` so a build only
   fires on a push to its own branch. **This is a `charts/` (platform) change → GitHub push +
   operator renders at APPS_REVISION** (see §E).
2. **Serial runner builds** (`a1fe30a22`, `.taskfiles/seed.yml` `seed:runners`): the seed fanned
   out all 4 CI-runner IMAGE builds in parallel → concurrent kaniko on one node collide at init
   (an unlucky build fails BEFORE any output; isolated builds always succeed; NO node resource
   pressure). Seen live: reviews' runner failed twice while ratings succeeded. Fix: build them
   **one at a time** (a plain `for` loop with `apl_run` per team).
3. **Corrupt Harbor blob** (the reason the rebuild stuck at `seed:gates`): the parallel churn left
   a **corrupt layer blob** in Harbor (`ci-runner:main` layer `sha256:560b8bd0…` — containerd
   downloads it and it hashes to a DIFFERENT digest → `ImagePullBackOff` "wrong diff id / unexpected
   commit digest"). **`SEED_FORCE_RUNNER_BUILD` could NOT fix it**: kaniko reproducibly builds the
   same layer digest, and **Harbor deduplicates by digest** → the corrupt blob is reused. The only
   fix is to PURGE the blob. **Manual recovery that worked** (keep for if it ever recurs):
   ```
   PW=$(kubectl get secret harbor-admin-password -n harbor -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d)
   H=https://harbor.$DOMAIN/api/v2.0
   curl -sk -u admin:$PW -X DELETE "$H/projects/team-reviews/repositories/ci-runner"      # drop manifests
   curl -sk -u admin:$PW -X POST "$H/system/gc/schedule" -d '{"schedule":{"type":"Manual"},"parameters":{"delete_untagged":true}}'  # GC evicts the blob
   # wait for GC Success (GET $H/system/gc?page_size=1), then rebuild the runner -> fresh clean push
   ```
   After GC + a fresh (serial) rebuild the image **pulled clean** (verified). The serialize fix
   PREVENTS the corruption on a fresh rebuild, so a clean `task down`+`setup`+`seed:demo` should
   just work. High confidence, not a 100% guarantee — if "wrong diff id" recurs even serially it's
   a deeper kaniko↔containerd↔Harbor issue to escalate.

## E. DEPLOY MECHANICS learned this session (all verified live)
- **Catalog charts** (`demo-seed/agent-workflows/charts/*` = `dev-agent`, `po-agent`,
  `agent-node-broker`) render from the **in-cluster Gitea** `team-platform/agent-workflows`@main.
  Live-update = push those files to that Gitea repo (mirror `seed.yml`'s `setup_catalog_repo`:
  clone, wholesale-replace `charts/`, `sed __DOMAIN__`, commit-on-top, push — NEVER force-push,
  trap 22) + `kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=hard`.
  Personas are the broker chart's `dev-persona`/`po-desk-persona` ConfigMaps (upserted by the
  broker on provision) + `files/*.txt`. The `dev` SKILL is a Turnstone admin-API object (upsert
  via `turnstone_admin_jar` + `turnstone_upsert_skill`); the `pr`/`vik`/`citest` WRAPPERS are the
  live `dev-tools` ConfigMap in `turnstone` (update it from `demo-seed/agent-base/bin/*`).
- **`charts/*` (PLATFORM, e.g. `team-ns`)** render from **GitHub** at `APPS_REVISION`. To deploy
  WITHOUT a full rebuild (verified — see memory `deploy-charts-change-without-rebuild`):
  push to GitHub, then **`kubectl set env deploy/apl-operator -n apl-operator APPS_REVISION=<sha>`**
  — the operator reads `env.APPS_REVISION` (`src/cmd/apply-as-apps.ts`) and regenerates every team
  Application at that commit. Patching an Application's `targetRevision` directly does NOT persist
  (the operator reverts it, rule 6). The env override is Argo-tracked so it CAN be self-healed;
  it held this session. Durable path is a real `task setup` (bakes APPS_REVISION into the image).

## F. Catalog cleanup + research + no-rebuild deploy — see memory
Written to `/home/lambda/.claude/.../memory/`: `dev-bot-built-not-live-tested.md` (the full
lifecycle + all fixes), `agent-browser-and-lsp-eval.md` (evaluated both — integrate LATER via a
bash-CLI wrapper, NOT MCP; browser read-tier already met by `pr preview`; LSP pilot =
pyright/multilspy wrapper for prodpage), `deploy-charts-change-without-rebuild.md` (§E).

## G. TODO (priority order for the next session)
1. **Verify the rebuild + the new §B lifecycle end-to-end** — this is the untested headline work.
2. **Deeper comment-flow polish** (user explicitly asked): wording, edge-cases, the standby/active
   transitions, whether teardown/regression deserves any note without clobbering handback.
3. Confirm the build-storm interceptor + serial-runner fixes hold on the fresh rebuild (watch the
   runner pulls for any "wrong diff id" recurrence — if it recurs, escalate per §D).
4. Consider the `lsp` wrapper pilot (memory `agent-browser-and-lsp-eval`).
5. The `pull-request-agent` chart is gone; if anything still references it, it's a stray.

---

## 0. The mental model

Turnstone is **one shared brain (Postgres) + N nodes**. A *node* is a
`turnstone-server` process (its own pod); all nodes see the same users, personas,
skills, tool policies, projects, and workstream rows. Node-local is only *which
workstreams run there* and the node's filesystem (checked-out repos, `bash`).

A *workstream* = one `ChatSession` + worker thread + a durable `ws_id` row.
States `IDLE / THINKING / RUNNING / ATTENTION / ERROR`.

Agents are built from four Turnstone primitives + a node + (for automation) a
Tekton pipeline:
- **Persona** — identity + capability envelope. 4 levers (below).
- **Skill** — reusable prompt snippet + session config + tool allow/approve.
- **Tool policy** — global allow/deny/ask per tool.
- **Project** — visibility/memory container for workstreams (we don't use it; see 2g).

**Nodes are made by the broker, not by hand.** The `agent-node-broker` (admin team)
is the node factory: given a request it clones `turnstone-server` and patches it into
a node in the `turnstone` namespace, on the team's baked `ci-runner:main` image.

---

## 1. Current state (after a fresh rebuild)

**Only the broker runs at rest. Every agent is installed on demand from the Console
catalog.** This is deliberate (the demo comes up clean).

### 1a. Running by default
- **`agent-node-broker`** (admin, `charts/agent-node-broker`) — the node factory.
  Two node types: ephemeral PR nodes (`provision-agent-node`) and the standing
  **review node** (`provision-review-node`). Its EventListener triggers on
  `body.action` = `provision` / `teardown` / `provision-review`. Idle until pinged.
- Per team: only the **`agent-creds`** secret (identity + PATs) — a secret, not a
  running agent, seeded ready so the broker/charts work the moment a team enables one.
- Global: **personas, skills, tool policies** (`seed:turnstone-agents`).

### 1b. Installed on demand from the catalog (`team-platform/agent-workflows`)
- **`pull-request-agent`** — the PR agent + its own doorbell/translator (per-team
  EventListener + Gitea `pull_request` webhook, wired to the broker). Install → open
  a PR → broker builds an ephemeral node. (To be reworked next session — for now it
  "runs like before".)
- **`po-desk`** — one install gives a team the whole Product-Owner desk:
  1. a PostSync hook pings the broker (`action: provision-review`) → the standing
     **`<team>-review-agent`** node comes up in `turnstone`;
  2. the **ticket coach** (EventListener + pipeline + `coach.py` + Vikunja webhook).
  This is the folded-in old `vikunja-ticket-coach` chart (that standalone chart was
  removed; the Turnstone *skill* of that name is unchanged).

### 1c. Personas (`seed:turnstone-agents`, as platform-admin over OIDC)
Prompt files: `demo-seed/agent-workflows/personas/*.md` (`__DOMAIN__` substituted).

| slug | display | tool_allowlist | mcp | memory | role |
|---|---|---|---|---|---|
| `the-architect` | The Architect | `read_file,search,web_fetch,recall` | off | on | read-only code Q&A |
| `vikunja-ticket-support` | Vikunja Ticket Support | `read_file,search,web_fetch,recall` | off | off | passive-coach identity — **provably write-free** (no bash) |
| `the-po-desk` | **The Product Owner** | `bash,read_file,search,skills` | off | on | interactive desk (bash for `vik` only) |

Note the tool is **`skills`** (plural), not `skill` — the latter is not a tool and
would be a silent no-op in the hard allowlist.

### 1d. Skills (`demo-seed/agent-workflows/skills/*.md`)
- **`vikunja-ticket-coach`** — the passive coach's output rules: HTML (Vikunja
  renders HTML) after a `===TICKET COMMENT===` sentinel; `agent_max_turns=8`.
- **`po-desk`** — the CREATION skill the PO picks with the persona. Its
  `allowed_tools=[bash,read_file,search]` is the scoped auto-approval lever (2d).
  Routes the agent to the `vik-*` skills.
- **`vik-projects/search/similar/show/comments/new/desc/comment/done`** — one per
  `vik` op, `allowed-tools:[bash]`, `hidden_from_menu`. The desk consults one via
  `skills(action=get)` for exact syntax, then runs it.

### 1e. Tool policies
`allow-read_file`, `allow-search` (`action=allow`) so the coach's read tools auto-fire
via `AutoApproveReason.POLICY`. The desk's `bash` is NOT policy-allowed (that would be
global) — it's scoped through the `po-desk` skill's `allowed_tools` (2d).

### 1f. The review node (made by the broker, not by hand)
`provision-review-node` (in the broker chart) clones `turnstone-server` and patches:
image → team `ci-runner:main`, **stable `TURNSTONE_NODE_ID=<team>-review-agent`** (env
entry replaced to drop the `fieldRef`), `workingDir /home/gradle/repos`, an
`initContainer clone-repos` (the `repos` values list), a **`git-sync` sidecar**
(fetch+reset origin/main every 30s), mounts `agent-<team>-creds`, label
`apl.io/review-agent=true` (NOT `ephemeral`, so PR teardown never reaps it). Inherits
all of turnstone-server's env (DB/OIDC/keys/JWT) — that's why clone-and-patch beats a
standalone chart.

### 1g. `vik` helper — BAKED INTO THE IMAGE
`demo-seed/agent-base/bin/vik` → `/opt/platform/bin/vik` via the agent-base
Dockerfile's `COPY bin/ /opt/platform/bin/`. On **every** team node's PATH as bare
`vik` (turnstone/vikunja-cli/tea/logcli are baked the same way). **Never cp to
`/tmp`** — a workstream can land on any node; the cp only reaches one, and `/tmp` dies
on restart (both hit live: see traps 19–20). Verbs: `projects`, `search`, `similar`,
`show`, `comments`, `new` (also posts a one-time coach-commands hint comment), `desc`
(sets the DESCRIPTION), `comment`, `done` (closes). Parses vikunja-cli's `{"data":…}`
with `/opt/platform/python` (no jq on the node).

### 1h. Credentials
`agent-creds` (per-team SealedSecret via apl-api): `agent-username`, `agent-password`
(Keycloak), `gitea-token` (`write:repository,write:issue,read:user`), `vikunja-token`
(`tk_`), `turnstone-token` (`ts_` PAT). The broker's `copy-creds` derives
`agent-<team>-creds` in the `turnstone` ns from these + the loki tenant pw.

---

## 2. Mechanisms & lessons

### 2a. Auth — three distinct credentials
- **Admin** (personas/skills/policies): platform-admin **over OIDC** —
  `turnstone_admin_jar` returns a cookie jar; call `/v1/api/admin/…` with `-b jar`. A
  raw Keycloak bearer is 401'd.
- **Agent** (SDK from a pipeline): a Turnstone **PAT** (`ts_…`, a bearer, NOT the
  cookie). Mint with `turnstone-admin create-token` (helper `turnstone_mint_agent_pat`).
- **id gotcha**: public `/v1/api/personas|skills` OMIT the id; read
  `/v1/api/admin/personas|skills` for `persona_id`/`template_id`.

### 2b. Personas
Four levers: `base_prompt`, `tool_allowlist` (a **hard frozenset** — the enforced
read-only/write boundary), `mcp_enabled`, `memory_enabled`. Resolved **once at
workstream creation** and stamped; editing only affects new workstreams. Create `POST`
/ update `PATCH` `/v1/api/admin/personas`.

### 2c. Skills
Prompt + session config in `prompt_templates`. `allowed_tools` is a **top-level
JSON-string field on the create body — NOT parsed from the .md frontmatter** (the
frontmatter is documentation only). `hidden_from_menu` keeps a skill out of the human
picker. `agent_max_turns` caps tool round-trips. Create `POST` / update `PUT`
`/v1/api/admin/skills`. Loading a skill mid-chat is the **`skills`** tool
(action=load, needs approval; find/get auto-approve).

### 2d. Tool approval — scope it, never skip it (verified in turnstone source)
- The desk PO is a **`builtin-operator`** = `read,write,workstreams.create,
  workstreams.close` — it **lacks `tools.approve`**, so it can't approve a gated tool.
- A skill's **`allowed_tools` → `auto_approve_tools`** is applied **once at workstream
  creation** (server.py, "only for new workstreams with a skill"). In `approve_tools`
  the auto-approve branch **empties `pending` before the human gate**, so a call whose
  name is in that set fires with **no approver needed**. That's how the non-admin desk
  runs `vik` (bash) hands-free — the PO picks persona **The Product Owner** + skill
  **po-desk**, whose `allowed_tools=[bash,read_file,search]`.
- Applied at *creation* only — loading a skill mid-chat does NOT update
  `auto_approve_tools`. So bash auto-approval must come from the creation skill (or a
  global tool policy, which we avoid).
- A skill's scan `risk_level` is `0.25·(content+supply+vuln+capability)`; a bash skill
  lands low/medium (capability averaged), so it's model-loadable (not principal-only).

### 2e. Driving a workstream headlessly — POLL, don't `send_and_wait`
`send_and_wait` blocks on a `ws_state="idle"` SSE that doesn't reach a non-mesh
pipeline pod → hangs to timeout. Instead `c.send()` then poll `list_workstreams` for
state and read the answer from `get_history` once idle (see `coach.py`). Run with
`/opt/platform/python/bin/python3` (the venv that has `turnstone.sdk`).

### 2f. Deep-linking a workstream
`https://turnstone.<domain>/node/<node_id>/?ws_id=<ws_id>` (the console-home
`/?ws_id=` only lands on the dashboard). Needs the stable `TURNSTONE_NODE_ID` (1f).

### 2g. Projects — NOT used
We evaluated a per-team Turnstone project so non-admin POs could watch coach
workstreams, and **dropped it**: it needed a `builtin-operator` `project.create/read/
write` grant + per-team projects + membership + per-user Turnstone logins, which run
into the authorize rate limit (trap 21). The PO gets the coach's answer as a Vikunja
comment regardless; admins can watch any workstream. (Membership *is* the visibility
grant in `WorkstreamProjectVisibility` if ever revisited.)

### 2h. Vikunja
- Comments/descriptions render **HTML**, not markdown.
- create task `PUT /projects/{id}/tasks`; comment `PUT /tasks/{id}/comments` (returns
  id) / update `POST /tasks/{id}/comments/{cid}`; set description `POST /tasks/{id}`;
  get `GET /tasks/{id}` (has `created_by`).
- Webhooks: `PUT /projects/{id}/webhooks`; use `task.created` + `task.comment.created`;
  task id at **`body.data.task.id`** for both. Never subscribe `task.updated`.
- **SSRF guard** drops delivery to in-cluster `10.x` unless
  `VIKUNJA_OUTGOINGREQUESTS_ALLOWNONROUTABLEIPS=true` (in `values/vikunja/vikunja.gotmpl`).
- **Loop guard**: skip when the newest comment's author id == the agent's own
  (`GET /user`). Agent-authored comments (coach output, the desk hint) never re-fire.

### 2i. The coach's behaviour (`po-desk/coach.py`)
- **Notice-first.** On a fresh ticket it posts a one-time NOTICE offering commands and
  waits — it does **not** auto-draft. It drafts only on **`/coach`** (draft
  description + acceptance criteria), or on plain feedback **after it has engaged**
  (engagement = a prior agent comment carrying the "above this line is AI-generated"
  note; the notice/help deliberately omit it).
- Commands: `/coach`, `/estimate`, `/risks`, `/tests`, `/plan`, `/split`, `/accept`
  (writes the description), `/help`. Unknown `/x` → the real list.
- **Skips desk-created tickets**: if `created_by` is the agent and no human PO has
  commented, the desk is handling it live (a later PO comment still gets a reply).
- One comment that **morphs**: starts as a watch-link, edited in place into the answer;
  the workstream is then closed.

### 2j. Live-change vs rebuild mechanics
- Catalog charts render from the **Gitea repo** `team-platform/agent-workflows`@`main`
  via Argo. Live change = push there + `kubectl annotate application <app> -n argocd
  argocd.argoproj.io/refresh=hard --overwrite`. **Push by committing on top, never
  force-push / `git init`** — apl-api ff-pulls its clone and a rewritten history makes
  the Console catalog go empty (trap 22; `setup_catalog_repo` now clones-and-commits).
- Personas/skills/policies are **not** charts — admin API (live) AND the
  `demo-seed/…` file (the seed reads local files).
- `git push` is blocked by a husky pre-push hook needing `helmfile`:
  `git config --unset core.hooksPath` first (recurs after any `npm install`).
- **Renames orphan** (no Argo auto-prune, no persona/skill auto-delete) — delete the
  old objects / archive the old persona.

---

## 3. Trap catalog (symptom → cause → fix), all hit live

1. **Operator build aborts immediately** — HEAD not pushed (Argo renders at the pushed
   commit). Push first.
2. **`git push` fails on `helmfile: not found`** — husky pre-push hook. `git config
   --unset core.hooksPath`.
3. **Pipeline never syncs (`CouldntGetPipeline`)** — a `$(params.x)` used but not
   declared → Tekton rejects the whole object. Declare every param.
4. **Node checkout invisible to the agent** — set the container `workingDir`.
5. **agent can't comment on a PR** — Gitea models PRs as issues → PAT needs
   `write:issue`, not just `write:repository`.
6. **Vikunja webhook never reaches the EL** — SSRF guard (2h).
7. **EL rejects the event (`id not found`)** — use `body.data.task.id`.
8. **`ModuleNotFoundError: turnstone`** — use `/opt/platform/python/bin/python3`.
9. **Result posts ~280s late** — `send_and_wait` on an SSE that never arrives. Poll (2e).
10. **Loop of coach comments** — the bot's comment re-fires the webhook. Loop guard (2h).
11. **Raw `###`/`**` in a comment** — Vikunja renders HTML. Emit HTML.
12. **Agent narration leaks into the comment** — use the `===TICKET COMMENT===` sentinel.
13. **Deep-link opens the dashboard** — `/node/<node_id>/?ws_id=` + stable node id.
14. **`upsert` PUT/PATCH 404** — public list endpoints omit the id; read `/v1/api/admin/…`.
15. **`--skip-permissions` banner** — a skill's `auto_approve=true`. Use `allowed_tools`
    / policies (2d).
16. **Duplicate Vikunja webhook → double runs** — a manual re-register raced the
    idempotent PostSync hook. Don't also register by hand.
17. **`vik` "string indices must be integers"** — vikunja-cli wraps `{"data":…}`; unwrap.
18. **Renamed objects linger / OutOfSync** — no auto-prune; delete orphans.
19. **Desk "which ticketing system are you using?" / generic** — the workstream used the
    **wrong persona** (the platform default `engineer`, not The Product Owner). The PO
    must pick the persona; there is no per-node default (a global default would hit every
    node). Don't make a persona global-default to fix this.
20. **Desk bash "`/tmp/vik`: No such file or directory"** — `vik` was `kubectl cp`'d to
    ONE node's `/tmp`, but the workstream ran on another node (same `ci-runner` image, no
    `vik`). Root cause of the "bake vik into the image" work — a wrapper on every node's
    PATH is the only correct fix; `/opt/platform/bin` is read-only at runtime and no PATH
    dir is writable.
21. **Turnstone OIDC login rate limit / `oidc_error=Too+many+login+attempts`** — the
    limiter is **5 records / 300s per IP**, hardcoded (`LoginRateLimiter`, not
    env-configurable), and **a single OIDC login costs TWO records** — `handle_oidc_
    authorize` (auth.py ~2112) AND `handle_oidc_callback` (~2229) both `record(ip:…)`.
    So only ~2 full logins fit per window. The seed does 5 logins (4 agent-PAT mints in
    `seed:agents` + 1 admin login in `seed:turnstone-agents`) and overflows badly.
    **Mitigation in place:** `turnstone_oidc_login` retries (waits 60s ×8) to ride the
    window out — **correct but slow** (a fresh seed can stall several minutes at the
    mints + `turnstone-agents`). A blocked authorize does NOT record (the check precedes
    the record), so retrying is safe; **never poll `/authorize` to probe status — that
    call DOES record and keeps the window full.**
    - **UPSTREAM FIX REQUIRED** (the retry is a workaround, not the fix): turnstone
      should not count a single login twice, and/or the limit should be configurable so
      a trusted seed host can raise it. Until then the stall stays.
    - **Deferred in-fork speedup** (chosen NOT to build, 2026-09-01): mint each agent's
      `turnstone-token` LAZILY when the broker provisions its node (agents are on-demand
      now, so the token isn't needed at seed time), leaving the seed with just the 1
      admin login. Needs the broker's `copy-creds` to do the OIDC login + mint (via
      `kubectl exec … turnstone-admin create-token`, a `pods/exec` RBAC grant) and the
      mint dropped from `seed:agents`. Real speedup + more correct; ~30 lines + 1 RBAC.
22. **Console catalog shows "No charts found" (apl-api returns `[]`)** — apl-api keeps a
    local clone of the catalog repo and updates via **fast-forward pull**; a force-push /
    `git init` rewrite makes it abort ("Not possible to fast-forward"). Commit on top
    (fixed in `setup_catalog_repo`). Not `otomi-api` down — check its logs
    (`kubectl logs -n otomi deploy/otomi-api`).
23. **Role override PUT is a silent no-op** — `admin_role_overrides` reads **singular**
    `grant`/`revoke` keys (the schema documents plural). Send `{grant:[…],revoke:[…]}`.
24. **`sed` with `#` delimiter AND `#` in the content mangles the file** — use `|` or an
    Edit; always syntax-check after a bulk sed.

---

## 4. TODO
1. **Verify the rebuild** — after `task setup` + `seed:demo`: catalog shows 3 charts
   (broker/pull-request-agent/po-desk) for a dev user; installing **po-desk** brings up
   `<team>-review-agent` in `turnstone` with `vik` on PATH and the coach firing;
   installing **pull-request-agent** + opening a PR builds an ephemeral node.
2. **Rework the `pull-request-agent`** (explicitly deferred by the user) — the current
   chart "runs like before"; redesign it next session.
3. **Second-wave coach actuation** (optional): `/split!` create sub-tickets, `/priority`,
   `/label` — verify Vikunja relations/priority/label API first.
4. **`po-desk` cross-team `repos`** — default clones the whole Bookinfo app; make a
   non-demo team's install clone just its own repo(s).

## 5. Reference map
- `po-desk` chart (review-node hook + coach): `demo-seed/agent-workflows/charts/po-desk/`
  (`coach.py`, `templates/review-node-hook.yaml`, `templates/{eventlistener,webhook-hook,
  netpol,coach-script}.yaml`, `values.yaml`).
- Broker (PR + review nodes): `demo-seed/agent-workflows/charts/agent-node-broker/`
  (`provision-agent-node`, `provision-review-node`, `teardown-agent-node`).
- PR agent chart: `demo-seed/agent-workflows/charts/pull-request-agent/`.
- `vik` (baked): `demo-seed/agent-base/bin/vik`.
- Persona/skill prompt files: `demo-seed/agent-workflows/{personas,skills}/*.md`.
- Seed: `.taskfiles/seed.yml` → `agents` (agent-creds only), `turnstone-agents`
  (personas/skills/policies), `setup_catalog_repo` (catalog push, clone-and-commit).
- Seed helpers: `.taskfiles/seed-lib.sh` → `turnstone_admin_jar`,
  `turnstone_upsert_persona/skill/policy`, `turnstone_mint_agent_pat`,
  `vikunja_mint_api_token`.
- Prior records: `AGENT-ENVIRONMENTS.md`, `AGENT-WORKFLOW-CATALOG.md`,
  `VIKUNJA-TURNSTONE-PIPELINE.md`, `TURNSTONE.md`, `MCP.md`.
- Turnstone source (verify here): `/home/lambda/repos/turnstone`.
