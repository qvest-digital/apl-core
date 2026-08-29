# Turnstone execution-model research

Repo: /home/lambda/repos/turnstone, branch main. All line refs are file:line in that checkout.

## 1. "Node" — VERIFIED: a node is a `turnstone-server` process/replica, NOT a workflow graph node.

- `compose.yaml` runs a fleet `node-1`..`node-10`, each just `turnstone-server --host 0.0.0.0 --port 8080 ...`
  with a unique `TURNSTONE_NODE_ID` / `TURNSTONE_ADVERTISE_URL` (compose.yaml lines ~230-300).
  Comment: "Each node registers itself in Postgres on boot (unique TURNSTONE_NODE_ID +
  TURNSTONE_ADVERTISE_URL) and the console discovers it automatically — no static node list anywhere."
- CLAUDE.md (turnstone repo) confirms: "Single-node vs. multi-node. Single-node is just client → server
  over HTTP+SSE. Multi-node adds `turnstone-console` in front, which routes each workstream to a server
  node via **rendezvous (HRW) hashing** over the live service registry — a pure function of
  `(ws_id, live_nodes)` with no stored bucket state, so a node joining/leaving only re-routes the keys
  that score highest on that node."
- So a "node" = one replica of the `turnstone-server` HTTP+SSE service, registered in a shared Postgres
  `services` table, heartbeating, discovered by the console, and used as a routing target for
  workstreams (via HRW hash of ws_id). It is a **compute/service replica**, not a DAG/graph node and
  not a per-agent sandbox. There is no separate "workflow node" concept found so far (continuing to
  verify in docs/architecture.md and code below).

## 1b. VERIFIED — Node ↔ workstream binding, the rendezvous proxy, load balancing, capacity, lifecycle

This section directly answers the coordinator's follow-up scope. Every claim is file:line.

### 1b.1 What binds a unit of work to a node

The unit of work is the **workstream** (`ws_id`) — see §2 below for what that is. The binding is
**not stored as an assignment row for the normal case; it is derived**, by a pure function, from the
`ws_id` string itself plus the current list of live nodes:

- `turnstone/core/rendezvous.py:82-93` `select(key, nodes)` — Highest Random Weight (HRW) rendezvous
  hashing: `score(node_id, key, weight) = FNV1a32(f"{node_id}\x00{key}") * weight`
  (`rendezvous.py:71-78`), pick the node with the max score. Pure function of `(ws_id, live_nodes)`,
  no stored bucket state (module docstring, `rendezvous.py:1-9`).
- `turnstone/console/router.py:153-169` `ConsoleRouter.route(ws_id)`: checks a `ws_id -> NodeRef`
  **override** dict first (`self._overrides`), else calls `select(ws_id, self._nodes)`.
- So for an ordinary (non-pinned) workstream, "the node" is **re-derived on every single routed HTTP
  call** from `(ws_id, current live-node set)` — it is not looked up from a persisted
  workstream→node column. It is "sticky" only in the sense that the same `ws_id` hashes to the same
  node **as long as the live-node set is unchanged** — a node joining or leaving reshuffles which
  node wins for a given `ws_id` (this is the whole point of HRW — minimal disruption, not zero).
  `workstreams.node_id` (`docs/architecture.md:1436`, `workstreams` table) is described as an
  "owning service cache / routing hint" — advisory bookkeeping, not the routing source of truth.
- **Pinning** (explicit, opt-in) is the one case where the mapping *is* forced: `spawn_workstream`'s
  `target_node` parameter (`turnstone/tools/spawn_workstream.json` "target_node" field) causes the
  console to *generate a ws_id* that HRW happens to route to that node
  (`ConsoleRouter.generate_ws_id_for_node`, `router.py:226-247`, brute-force up to 65,536 random
  candidates, `router.py:33-38`), used from `console/server.py:2233` and `:2287`. This is a hard
  constraint: if the target node isn't live, the spawn fails outright with "No available node for
  routing" rather than falling back (`spawn_workstream.json`'s own CAVEAT text, and `console/server.py`
  target_node branch sets `pin = True` at `console/server.py:2236`, which later disables the
  capacity-based fallback — see §1b.4).
- A separate, unused-by-current-code persistence path exists: `StorageBackend.set_workstream_override
  / delete_workstream_override / list_workstream_overrides`
  (`turnstone/core/storage/_protocol.py:1801-1809`) backs a `workstream_overrides` DB table that
  `ConsoleRouter.route()` also consults (`router.py:154-156`, `_refresh_locked` at `router.py:135-141`
  loads it from storage). **VERIFIED**: no call site in the current tree calls
  `set_workstream_override` (`grep -rn "\.set_workstream_override(" turnstone --include=*.py` →
  no output) — the override table exists in the schema/protocol and is read, but nothing in this
  checkout writes to it; the only pinning mechanism actually exercised by code is
  `generate_ws_id_for_node`. (This may be wired from an admin UI/API not present in this checkout, or
  may be vestigial — worth flagging, not asserting either way.)

### 1b.2 Is it re-evaluated per message/step?

Yes, per HTTP call, at the console's routing layer — every `route_create` / proxy request calls
`router.route(ws_id)` fresh (`console/server.py:2218-2240` for create; the general per-request proxy
path, e.g. `console/server.py:2687` region for send/approve/etc.). There is a **404-triggered
re-route**: if the node the router picked returns 404 (doesn't have that workstream — e.g. it just
joined and lost the HRW race, or the previous owner died and this is a new pick), the console calls
`router.force_refresh()` (blocking, coalesced) and retries **once** on the freshly computed route
(`console/server.py:2687-2701`, comment: "Transparent retry on 404 (at most once)... If the route is
the same, return the 404 as-is — no loop, no scan."). So: routing itself is stateless/recomputed
every call; the actual conversation state (`ChatSession`, worker thread) lives in-process on whichever
node last had it, and is rehydrated from Postgres by the newly-routed node on demand
(`docs/architecture.md`'s Rehydration paragraph, §Atomic Create and Fork Lifecycle: "Rehydration binds
the private token before constructing the session... a concurrent lifecycle change retires the hybrid
candidate and retries from a fresh snapshot").

### 1b.3 What happens when a node disappears mid-work — VERIFIED

- Liveness = heartbeat freshness only. Each node calls `register_service("server", node_id, url)` once
  at boot (`turnstone/server.py:5292`) and `heartbeat_service("server", node_id)` every 30s
  (`server.py:5344-5362`, `_heartbeat_loop`). `list_services("server", max_age_seconds=120)`
  (`storage/_protocol.py:1734`, used by `router._refresh_locked` at `router.py:127`) is the sole
  liveness source — **there is no active health probe, no graceful failure detection**, just "have we
  heard a heartbeat in the last 120s".
- On graceful shutdown the node calls `deregister_service("server", node_id)`
  (`server.py:5392-5399`), removing it from `services` immediately. On a **crash** (no graceful
  shutdown), the row simply ages out after ~120s and drops out of the console's next
  `refresh_cache()`/discovery tick (collector runs discovery every 60s per `docs/console.md:43`).
  Until that expiry, the dead node still "wins" HRW for its keys, so requests 502 (`httpx.HTTPError`
  → "upstream node ... unreachable", `console/server.py:2219-2226`ish / the analogous send-path
  handler) rather than being detected and rerouted immediately.
- Once the dead node ages out of the live-node list, HRW naturally reassigns its `ws_id`s to the next-
  highest-scoring **live** node. The next request for that `ws_id` gets routed there, 404s (new node
  has no in-memory `ChatSession` for it), triggers the force-refresh-and-retry-once path
  (`console/server.py:2687-2701`), and the new node **rehydrates from Postgres** (canonical Turn
  history + `workstream_config`) rather than resuming any in-memory state — anything that was
  in-flight on the dead node (a running tool call, an unpublished streamed response) is lost.
  `docs/architecture.md`'s State Transitions section documents the recovery contract for exactly this:
  "Every unanswered tool call receives a synthetic TOOL Turn: effect_status is 'unknown' when its
  outcome was not observed, 'none' when it definitely never started..." (`docs/architecture.md`
  ~line 283). **INFERRED** (not separately re-verified against a live crash) that this generic
  unanswered-tool-call handling is what covers a dead-node mid-tool-execution case specifically, since
  the doc text is written generically about cancellation/crash, not node-loss specifically — but it is
  the documented mechanism and no other recovery path was found.

### 1b.4 Load balancing — VERIFIED: weighted rendezvous hashing + capacity-based one-retry spillover, no queue

- **Primary strategy**: rendezvous/HRW hashing keyed by `ws_id`, weighted by a per-node `node.weight`
  setting (`turnstone/core/settings_registry.py:904-913`: "Relative capacity of this server node. A
  node with weight 2 wins twice... as a node with weight 1."). This is **not** round-robin, not
  least-loaded-first, and not capability/label matching — it is a deterministic hash so that the same
  workstream always lands in the same place absent membership change, with weight only biasing the
  probability distribution across *new* workstreams. There is **no per-node "labels"/"tags"/"team"
  setting** in the codebase — `grep -n "\"node\.\|'node\." turnstone/core/settings_registry.py` finds
  only `node.weight` (`settings_registry.py:904`). Any team-affinity must be built entirely on the
  explicit `target_node` pin (§1b.1), not on any automatic capability/label match.
- **Capacity check and overload behavior**: each node enforces its own hard cap,
  `server.max_workstreams` (default 50, `docs/console.md`/`docs/settings.md`), implemented as
  `SessionManager._max_active` (`turnstone/core/session_manager.py:312-319, 405-406`). `create()`
  raises/returns a capacity failure once `len(self._workstreams) >= self._max_active`
  (`session_manager.py:2838, 2874, 2910` — "All {max_active} slots are active"); the manager first
  tries to evict the oldest IDLE, worker-free workstream to make room (`docs/architecture.md`'s "Idle
  Workstream Lifecycle" §, "Workstream eviction at capacity"). If eviction can't free a slot, the node
  answers the console's create request with HTTP 503.
- **Console-side spillover on 503**: `console/server.py:2306-2336` — on a 503 from the chosen node,
  *if the create was not pinned/resumed/caller-fixed-id* (`not pin and not resume_ws and not
  fixed_ws_id`), the console retries up to 10 times with a **freshly random `ws_id`** hoping HRW
  selects a different node (`for _ in range(10): ws_id = secrets.token_hex(16); ... if
  ref.node_id != failed_node: found_alt = True; break`). This is the entire "spill to another node"
  mechanism — one-shot, best-effort, and explicitly disabled for pinned (`target_node`) creates: a
  pinned create at capacity just fails (`spawn_workstream.json`'s own text: "the spawn fails with 'No
  available node for routing' rather than falling back").
- **No queue**: there is no work queue anywhere in this path — either a node accepts the new
  workstream synchronously (HTTP 200) or the create attempt fails/retries against a different node.
  Confirmed by reading the entire create-routing block, `console/server.py:2024-2336`; no queuing
  primitive (no `queue.Queue`/broker) appears in that file for this purpose. (The **watch** and
  **scheduler** subsystems use polling loops and a distributed *lock*, not a work queue, for their own
  unrelated timers — `console/scheduler.py` and `turnstone/tools/watch.json`.)
- Per-workstream, once *inside* one workstream's tool-execution phase, concurrency is a **process-local
  `ThreadPoolExecutor(max_workers=4)`** (`docs/architecture.md` Tool Execution Pipeline, "Phase 3:
  EXECUTE (parallel)") — that is intra-turn parallel tool calls, unrelated to inter-node load
  balancing.

### 1b.5 Node lifecycle — VERIFIED

- **Start/register**: a node is literally a `turnstone-server` process. On boot it reads
  `TURNSTONE_NODE_ID` / computes `advertise_url`, and if both are set calls
  `storage.register_service("server", node_id, url)` once (`server.py:5288-5293`) then starts a 30s
  heartbeat loop (`server.py:5344-5362`). Node identity/URL are plain env vars / CLI flags — nothing
  auto-derives them beyond `_default_node_id()` (`server.py:6062`, not fully read but named for
  hostname-based default).
- **Remove/deregister**: graceful shutdown → explicit `deregister_service` (`server.py:5388-5399`).
  Crash → passive 120s heartbeat expiry, no operator action needed or possible to hasten it besides
  editing the `services` table directly (not exposed as an API in this checkout — see §1b.3).
- **No drain/cordon operation exists.** Searched the whole tree for a "drain"/"cordon" node operation
  (`grep -rn "drain" turnstone --include=*.py`) — every hit is unrelated (SSE queue draining, request
  draining, generation draining), none is a "stop routing new workstreams to this node but let
  existing ones finish" operation. `docs/console.md`'s only node-lifecycle sentence
  (`docs/console.md:43`) is: "queries the `services` database table every 60 seconds. Adds newly
  discovered nodes, removes expired ones (stale heartbeats), emits `node_joined`/`node_lost` events" —
  fully automatic, heartbeat-driven, no manual control surface. **This is a real gap for the
  "ephemeral per-agent node" idea**: there is no supported way to tell the cluster "stop sending this
  node new work, but don't kill in-flight work" before deleting the pod — you would have to build that
  yourself (e.g., stop advertising the node, wait out in-flight workstreams via `list_nodes`'s
  `ws_total`, then terminate).
- **Scale-out**: purely "start another `turnstone-server` process with a unique `TURNSTONE_NODE_ID`".
  Confirmed by `compose.yaml`'s `node-1`..`node-10` (10 near-identical services, each just a
  `TURNSTONE_NODE_ID`/`TURNSTONE_ADVERTISE_URL` override) and the bare-metal "join a host" recipe in
  `compose.yaml`'s header comment. **This is entirely manual** — nothing in Turnstone itself creates,
  destroys, or scales node processes; that is left to whatever deploys it (compose replica count,
  Helm chart `server.replicas`, or an external autoscaler). No autoscaling logic found anywhere in
  `turnstone/` (no HPA, no node-pool logic, no k8s client — see §"Can Turnstone execute things outside
  its own process" below).
- **Pinning a team to "their" node**: supported, but only via the manual `target_node` mechanism per
  spawn (§1b.1) — there is no first-class "this node belongs to team X, route all of that team's work
  here automatically" concept. You would have to have every spawn/create call for a team pass
  `target_node=<that team's node id>` yourself (e.g. baked into whatever wrapper/coordinator config
  issues the spawn), and there is no admission-time enforcement stopping other teams' work from also
  landing on that node via ordinary HRW hashing (weight/pin only affect *placement*, not *access
  control* — nothing in the codebase gates who may target which node; that would have to be enforced
  at your calling layer, e.g. only the team's own coordinator ever receives that team's `target_node`
  value).

### 1b.6 Is "singleton-plus-per-team-node" a first-class supported topology?

**No — INFERRED/inspected directly, this is not a shipped topology, it is a pattern you would build
on top of two independent, already-existing primitives:**

1. The **console is already architecturally a singleton** — `turnstone-console` is the one thing every
   node registers with and every routed request passes through (`docs/architecture.md`'s Module Map:
   `console/collector.py`, `console/server.py`, `console/scheduler.py`; Helm chart's separate
   `deployment-console.yaml` with its own `console.replicas` knob, default effectively 1 — nothing in
   the chart coordinates >1 console replica, e.g. no leader election beyond the scheduler's DB-row
   lock at `console/scheduler.py:_try_acquire_lock`, `scheduler.py:105-...`). So "one control-plane
   instance" is a natural, already-supported deployment (`deploy/helm/turnstone/values.yaml:52-63`
   `console: replicas: 1` default).
2. **"One node per team"** is achievable only by hand-building it out of `target_node` pinning
   (§1b.1/§1b.5) — there is no config key, chart value, or code path that says "node N belongs to
   team T" or "route project P's workstreams only to node N". The Helm chart's `server` block
   (`deploy/helm/turnstone/values.yaml:31-45`) is a single `Deployment` with one `replicas:` count —
   **all replicas are anonymous, interchangeable members of the same HRW ring**; the chart has no
   per-team Deployment templating, no `nodeSelector`-per-team pattern beyond the single shared
   `server.nodeSelector` value applied uniformly (`deployment-server.yaml`'s
   `{{- with .Values.server.nodeSelector }}` block, `templates/deployment-server.yaml:20-23`).
   Building "team-labteam gets its own node" on this platform would mean: deploy a second `server`
   Deployment (a second Helm release, or a forked template) with a distinct `TURNSTONE_NODE_ID`
   prefix/scheme, and make sure only that team's spawn calls carry
   `target_node=<that node's id>` — nothing in Turnstone enforces the pairing; it is entirely a
   convention your own wrapper would need to keep.

**Conclusion for the ephemeral-per-agent-environment design**: rendezvous routing gives you node-level
placement (which *process* runs a workstream), not environment-level isolation — a "node" is a shared,
long-lived Python process serving up to `max_workstreams` (default 50) concurrent workstreams via
threads, all sharing one filesystem/cwd (§ workspace section below) and one `bash` subprocess pool. It
is a reasonable substrate for "this team's chat/agent traffic is confined to this pod" (via pinning),
but it does **not**, by itself, give you "one throwaway sandboxed environment per agent invocation" —
that would have to be layered on top (e.g., spin up a node-per-agent-run instead of node-per-team, and
kill it after; or wrap `bash` execution in something like the already-documented OpenShell sandbox,
which is applied per node-process, not per-workstream — see the "outside its own process" section
below).

---

## 2. Task/run/session/workflow concept and lifecycle — VERIFIED

- The unit of everything is the **workstream** (`turnstone/core/workstream.py`). CLAUDE.md (turnstone
  repo) states it precisely: "A workstream = one `ChatSession` + `SessionUI` + worker thread + durable
  lifecycle row, and is the persistence identity (`ws_id`) — there is no separate session ID."
- `WorkstreamState` has 5 states: `IDLE, THINKING, RUNNING, ATTENTION, ERROR`
  (`docs/architecture.md:415-424`, backed by `turnstone/core/workstream.py`).
- Two `WorkstreamKind`s share the same `SessionManager`/lifecycle: **interactive** (a normal chat) and
  **coordinator** (multi-agent orchestrator — see `spawn_workstream`/`tasks`/`send_to_workstream` tools,
  §"Tools" below). A coordinator workstream's own `tasks` tool (`turnstone/tools/tasks.json`) is a
  **planning list it owns**, not an execution engine — it's literally "add/update/remove/reorder/list"
  items with a free-form `child_ws_id` label the coordinator manages itself; the platform does not
  interpret or execute these task rows.
- Lifecycle: `creating` (hidden DB row, atomic reservation) → `idle`/live states → `closed`/`deleted`
  (`docs/architecture.md`'s "Atomic Create and Fork Lifecycle" §, `session_manager.py`'s `create`,
  `commit_create`, `discard`, `close`, `delete_persisted`). A crash mid-create is auto-reaped after 2h
  (`reap_stale_creating_reservations`, `session_manager.py`, doc'd at `docs/architecture.md`
  "Crash-Abandoned Create Recovery").
- **What persists**: append-only `conversations` table (one canonical `Turn` per row — user/assistant/
  tool/system), `workstreams` (identity/state/kind/owner/project/persona), `workstream_config`
  (key/value settings), `memory_index_snapshots` (per-workstream memory binding) — full schema at
  `docs/architecture.md:1426-1472`. Nothing is destructively summarized; compaction adds a checkpoint
  watermark, never deletes rows (`docs/architecture.md:1373-1394`).
- **Where it starts/ends**: starts at `POST /v1/api/workstreams/new` (or CLI `/ws new`, or a scheduled
  task firing, or a channel adapter routing an inbound Discord/Slack message to a workstream). Ends at
  an explicit `close`/`delete`, or auto-close of an IDLE workstream past `--workstream-idle-timeout`
  (default 120 min, `docs/architecture.md` "Idle Workstream Lifecycle").
- There is **no separate "task" or "job" execution primitive distinct from a workstream** — a
  "task_agent" (see below) is a nested, synchronous, in-process sub-loop **inside** a single tool call
  of a parent workstream, not a separate schedulable unit with its own row/lifecycle.

## 3. Executing things OUTSIDE Turnstone's own process

**VERIFIED — subprocess execution (in-process, same host/container as the node), no container/pod
creation, no Kubernetes client anywhere in the codebase.**

- **`bash` tool**: plain `subprocess.Popen` on the node's own OS (`turnstone/core/session.py:24311-24314`,
  and the tracked-for-kill set `self._active_procs: set[subprocess.Popen[str]] = set()` at
  `session.py:3404`). Runs as whatever user the node process runs as (Docker image creates a
  non-root `turnstone` user, `Dockerfile` — "Non-root user" `RUN useradd ...`). `run_in_background=true`
  keeps a shell alive across tool calls until the workstream closes or it's killed
  (`turnstone/tools/bash.json`'s description) — this is the closest thing to a "long lived job", but
  it's still just an OS process on the same host as the node, tracked in that node's memory
  (`_active_procs`), not portable/re-attachable from another node.
- **No sandboxing per call.** The only sandboxing available is **OpenShell**
  (`docs/openshell.md`), a *whole-process* kernel sandbox (Landlock filesystem, network namespace +
  seccomp, setuid drop) wrapping the entire `turnstone-server` invocation — i.e. every workstream/tool
  call on that node shares one sandbox boundary; there is no per-workstream or per-tool-call sandbox.
  Quick-start: `openshell sandbox run --policy deploy/openshell/turnstone-policy.yaml ... -- python3 -m
  turnstone.server ...` (`docs/openshell.md:23-40`).
- **No Kubernetes/Docker client library usage** anywhere in `turnstone/` — verified by
  `grep -rniE "kubernetes|k8s|docker|container|\bpod\b" turnstone --include=*.py`; every hit is either
  (a) `doctor.py`'s read-only diagnostics, which literally shells out to `docker info` / `docker
  compose ps` / `docker compose logs` for *installation health reporting*, never to create/manage
  anything (`turnstone/doctor.py:394-397, 1343-1400`), or (b) unrelated uses of the English word
  "container" (Slack message JSON keys, audio container formats, Dockerfile comments). No
  `kubernetes` Python client import, no in-repo CRD/manifest generation, no `docker.py`/`docker-run`
  helper for spawning workloads.
- **No RBAC for cluster mutation.** The Helm chart's `serviceaccount.yaml`
  (`deploy/helm/turnstone/templates/serviceaccount.yaml`) creates a bare `ServiceAccount` with **no**
  bound Role/ClusterRole anywhere in the chart (`grep -rn "Role\|RBAC\|ServiceAccount"
  deploy/helm/turnstone/templates/*.yaml` finds only the ServiceAccount object itself) — consistent
  with there being no in-cluster API usage to grant permissions for.
- **Outbound network calls that reach infrastructure**: `web_fetch` (arbitrary URL fetch, SSRF-guarded
  by `turnstone/core/web.py`) and `web_search` (via bundled SearxNG or provider-native search) are the
  built-in tools that reach the outside world over HTTP; `notify` (`turnstone/tools/notify.json`) can
  push a message to a linked Discord/Slack channel/user — this is a one-way notification, not a
  webhook-trigger-back-in mechanism. **MCP tools** are the general-purpose way an agent reaches
  infrastructure (see §4) — an MCP server is exactly how this platform would expose Gitea/Vikunja/
  Tekton/Kubernetes-shaped actions to a Turnstone agent, and nothing about MCP tool calls is
  special-cased or restricted differently from built-in tools (same PREPARE→APPROVE→EXECUTE→GUARD
  pipeline, same tool-schema-driven surface).
- **Queues to publish to**: none found. No message-broker client (no kafka/rabbitmq/redis-queue
  import) anywhere in `turnstone/`. The two background dispatch mechanisms in the codebase
  (`console/scheduler.py`'s cron/at `TaskScheduler`, and `watch.py`'s per-workstream shell-polling
  `WatchRunner`) are both simple poll loops with a DB-row distributed lock, not queues.

## 4. Tools / plugin mechanism, MCP client — VERIFIED

- Each built-in tool = one JSON schema file in `turnstone/tools/*.json` (list: `bash`, `bash_output`,
  `kill_shell`, `read_file`, `write_file`, `edit_file`, `diff_file`, `search`, `web_fetch`,
  `web_search`, `memory`, `recall`, `skills`, `use_prompt`, `notify`, `watch`, `open_preview`,
  `read_resource`, and the coordinator-only set `spawn_workstream`, `spawn_batch`,
  `send_to_workstream`, `wait_for_workstream`, `inspect_workstream`, `list_workstreams`,
  `cancel_workstream`, `close_workstream`, `close_all_children`, `delete_workstream`, `list_nodes`,
  `tasks`, `task_agent`). Registering a new *built-in* tool means adding a JSON schema here plus a
  matching `_prepare_{name}`/`_exec_{name}` method pair on `ChatSession` (`docs/architecture.md`
  "Schema Format"/"Prepare / Execute Pattern" §§).
- Registering a new **external** tool is via **MCP** — `turnstone/core/mcp_client.py`'s
  `MCPClientManager`. Config sources: TOML/JSON config file or DB-backed rows managed through the
  console's admin "MCP Servers" tab; DB rows win over file config
  (`docs/architecture.md` "MCP Tool Integration" §). Supports stdio-subprocess MCP servers and HTTP MCP
  servers (`_connect_all()` handles both). Tool names are namespaced `mcp__{server}__{tool}`. Live
  reload without restart: push (`tools.listChanged`) or `/mcp refresh`. There's also an MCP **registry
  discovery** UI backed by `registry.modelcontextprotocol.io` (`turnstone/core/mcp_registry.py`).
  This is exactly the mechanism by which this platform's existing Gitea-MCP and Vikunja-MCP sidecars
  (per `apl-core`'s `MCP.md`) would be wired to a Turnstone workstream — nothing turnstone-specific
  needs to be built for that, it's a config-file or admin-panel MCP-server registration.
- **Is there an MCP client?** Yes — confirmed above; Turnstone is an **MCP client**, not an MCP server
  itself (nothing in the tree exposes Turnstone's own tools as an MCP server for another client to
  call).

## 5. Workspace / working directory / filesystem — VERIFIED, and this is a real limitation for per-agent isolation

- There is **one working directory per node process**, not one per workstream/session/agent.
  `turnstone/core/session.py:4599-4605`: `working_dir = os.getcwd()` (the process's cwd, shared by
  every workstream/thread in that process); `workspace_dir = get_workspace_dir()` is a single
  config/env value (`turnstone/core/config.py:239-263`, precedence `config.toml [tools] workspace_dir`
  → `$TURNSTONE_WORKSPACE`) — again one value for the whole process, not parameterized by `ws_id`.
  `bash.json`'s own `cwd_note`: "Commands run in `{working_dir}` — each call starts a fresh shell
  there; cd does not persist across calls." — confirming all bash calls on a node, from any
  workstream, share the same starting directory.
- `compose.yaml` backs this up operationally: **one** `workspace` docker volume, mounted at
  `/workspace` on every `node-N` service (`compose.yaml`'s `node-1: &node` volumes block:
  `- ${WORKSPACE_MOUNT:-workspace}:/workspace`), i.e. all ten compose nodes in the default stack share
  the same workspace filesystem.
- **No per-session sandbox directory, chroot, or temp-workdir-per-workstream was found.** This is a
  genuine gap relative to "give each agent an ephemeral environment" — as shipped, isolation between
  concurrently running agents on the *same node* is achieved only by discipline in what paths they
  touch (or by running literally separate node processes/pods per team, per §1b), not by the
  application itself scoping a filesystem per workstream.
- Persisted artifacts *of the conversation* (attachments, images, PDFs) go through a content-addressed
  **blob store** referenced by `AttachmentRef`s in the canonical `Turn` (`docs/architecture.md`
  "Canonical Trajectory" §: "Attachment bytes never ride in a `Turn`; each output boundary resolves its
  ordered references from the blob store.") — this is conversation-attachment storage, unrelated to a
  working directory for code/build artifacts.

## 6. Concurrency model — VERIFIED

- **Within one node process**: one `threading.Thread` (daemon) per active workstream, running
  `ChatSession.send()` synchronously to completion or until it blocks on an `ApprovalCycle.event`
  (`docs/architecture.md` "Server" threading diagram, `docs/architecture.md:1865-1892`). Multiple
  workstreams are therefore concurrent Python threads in one process/one address space/one Python
  GIL — not separate processes, not separate containers. Isolation between them is via per-workstream
  locks (`Workstream._lock`, `_lifecycle_lock`, `_state_tail_lock` — full list at
  `docs/architecture.md:1935-1956` "Thread Safety" §) and via DB rows, not OS-level isolation. Up to
  `server.max_workstreams` (default 50) workstreams can be concurrently loaded per node
  (`session_manager.py:312-319`, `:2838-2874`).
- **Within one workstream's turn**: up to 4 tool calls execute in parallel via
  `ThreadPoolExecutor(max_workers=4)` (`docs/architecture.md` "Tool Execution Pipeline" Phase 3).
  Parallel task-agents (nested `task_agent` calls) can each independently hit an approval gate at the
  same time — handled by `SessionUIBase` storing an insertion-ordered registry of `ApprovalCycle`
  objects rather than one global pending event (`docs/architecture.md` "Tool Execution Pipeline" §
  and "Approve" phase text).
- **Across nodes**: full process/container isolation — each node is a separate OS process (in compose,
  a separate container; in the Helm chart, a separate pod replica of the same Deployment). Routing
  between them is the HRW rendezvous scheme in §1b. This is the *only* true isolation boundary
  Turnstone gives you out of the box: node = process = (in k8s) pod.

## 7. Deployment shape — VERIFIED

- **`compose.yaml`** (repo root): one build (`Dockerfile`) reused by every service. Services: Postgres,
  `console` (singleton dashboard), `caddy` (TLS termination for the dashboard only), `channel`
  (Discord/Slack gateway), `searxng` (web_search backend), and **`node-1` through `node-10`** — ten
  near-identical `turnstone-server` replicas, each with a unique `TURNSTONE_NODE_ID`/
  `TURNSTONE_ADVERTISE_URL`, sharing one Postgres and one `workspace` volume (see §5). This is the
  reference "cluster" shape: 1 console + N interchangeable server nodes.
- **`deploy/helm/turnstone/`**: a real Helm chart (`Chart.yaml` v0.2.0, depends on Bitnami
  `postgresql` subchart). Templates: `deployment-server.yaml` (the node fleet, `server.replicas`,
  default unspecified/1 unless set — no autoscaling object in the chart), `deployment-console.yaml`
  (`console.replicas`, default 1), `service-server.yaml`, `service-console.yaml`, `job-migrate.yaml`
  (DB migration Job, a Helm post-install/pre-upgrade hook), `ingress.yaml`, `configmap.yaml`,
  `secret.yaml`, `serviceaccount.yaml` (bare, no RBAC — §3). **Every server pod computes its own
  `TURNSTONE_ADVERTISE_URL` from its own pod IP** (`deployment-server.yaml`'s `POD_IP` downward-API
  env var + comment explaining exactly why: a Service DNS name would load-balance console traffic for
  node A onto an arbitrary pod, and the default hostname-based advertise isn't resolvable in-cluster —
  `templates/deployment-server.yaml:55-68`). **No StatefulSet, no per-replica identity beyond pod IP,
  no HPA/autoscaler object anywhere in the chart** — `server.replicas` is a static count you set by
  hand (or via whatever external tooling you point at `helm upgrade --set server.replicas=N`).
- **`deploy/systemd/`**: unit files for a non-container bare-metal/VM deployment (`turnstone-server.service`,
  a `.slice`, and a per-node override example `node.conf.example`) — a third deployment shape, not
  container-based at all.
- **No queue/worker split.** There is no separate "worker" process type distinct from the server node
  — a node *is* both the API-serving process and the thing that executes tool calls/bash/model calls,
  all in the same process via the threading model in §6. "Workers" in the codebase means thread-pool
  workers for tool execution (§6), not a distinct deployable role.

## 8. Scheduling/triggering agent work from an external event — VERIFIED

- **Cron/at scheduler**: `turnstone/console/scheduler.py`'s `TaskScheduler`, a daemon thread inside the
  **console** process, ticking every `check_interval` (default 15s, `docs/console.md` "Scheduled
  Tasks" §). Supports `schedule_type: "cron"` (5-field cron via `croniter`) and `schedule_type: "at"`
  (one-shot ISO8601 timestamp, auto-disables after firing). On each due task it dispatches an
  `initial_message` as a new workstream creation, routed via `auto` (best-capacity node), `pool`
  (alias for the same), `all` (fan-out to all reachable nodes, capped by `max_fan_out`, default 20), or
  a specific `<node_id>` (`docs/console.md` "Target Modes" table). Full REST CRUD at
  `/v1/api/admin/schedules` (`docs/console.md:591-660`+), capped at 200 schedules, `approve` scope
  required. **This is the closest thing to a generic "trigger agent work from a timer" mechanism**,
  and it is real/first-class, not a stub.
- **Inbound webhook receiver**: **none found for generic events.** The only inbound-event-driven
  workstream triggers are the **channel adapters** (Discord, Slack — `turnstone/channels/`), which map
  an inbound chat message/DM to a workstream via `ChannelRouter` (`turnstone/channels/_routing.py`) —
  i.e. "a person messages a bot" is supported, "an arbitrary CI/webhook event creates a workstream" is
  not something Turnstone listens for out of the box.
- **API-call trigger** (the general mechanism you'd actually use for "Gitea/Tekton webhook → agent
  run"): a plain authenticated `POST /v1/api/workstreams/new` + `send` via the REST API or the
  bundled SDK (`docs/sdk.md`'s `create_workstream(...)` / `send_and_wait(...)`) is enough to let any
  external system (a Tekton Task, a webhook receiver you write, cron outside Turnstone) start and drive
  a workstream. This is not a "scheduling" feature per se, just the ordinary API — but it is the
  practical answer to "can something external trigger agent work", and needs no code change to use
  today: point an existing webhook consumer at the console/server API instead of a channel bot.

---
Research complete. See executive summary delivered to the caller.
