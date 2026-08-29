# Turnstone AuthZ / Tenancy research

Repo: /home/lambda/repos/turnstone, branch main (2026-08-29 checkout)
Method: read-only source inspection. All line numbers verified by grep/sed against the checked-out tree unless marked INFERRED.

---

## 1. Permission model — roles, permissions, scopes

VERIFIED. Two layers, described in `docs/architecture.md:2161-2192` and `docs/governance.md:9-38`:

**Layer A — legacy scopes** (`docs/architecture.md:1765-1770`, `docs/console.md:333-346`):
| Scope | Grants |
|---|---|
| `read` | GET endpoints: SSE streams, workstream listing, history |
| `write` | `read` + send, command, workstream create/close |
| `approve` | `write` + tool approval, admin operations |

Checked by `AuthMiddleware` per URL-path classification (`docs/architecture.md:1774-1789`).

**Layer B — granular permissions**, checked per-endpoint by `require_permission()` (`docs/governance.md:14-16`). Built-in roles seeded by migration 008 (`turnstone/core/storage/migrations/versions/008_governance.py:1-18`):

| Role | Permissions |
|---|---|
| admin (`builtin-admin`) | "Admin-default baseline" — ordinary admin, lifecycle, tool-approval, coordinator, project, persona capabilities; explicit opt-ins like `model.skills.write` stay ungranted (`docs/governance.md:20`) |
| operator (`builtin-operator`) | read, write, workstreams.create, workstreams.close, conversation.modify |
| viewer (`builtin-viewer`) | read |

Migration 008 seeds the initial permission string: `"read,write,approve,admin.users,admin.roles,admin.orgs,"` (008_governance.py:18) onto builtin-admin; later feature migrations append more (e.g. migration 062 appends `project.create/read/write/delete` to builtin-admin only — `062_projects.py:14-15,49`; migration 063 appends `persona.create/read/write`).

Custom roles: any subset of `_VALID_PERMISSIONS` allowlist (`docs/governance.md:151-152` cites `_VALID_PERMISSIONS`); role CRUD is `admin.roles` gated.

Auth flow (`docs/governance.md:32-36`): login → `_load_user_permissions()` aggregates permissions from all assigned roles → `_permissions_to_scopes()` derives legacy scopes (any `admin.*` → `approve`) → JWT carries both `scopes` and `permissions` claims → middleware checks scope, handler checks permission via `require_permission()`.

Permission strings seen in source (non-exhaustive, by grep): `admin.users`, `admin.roles`, `admin.orgs`, `admin.policies`, `admin.skills`, `admin.schedules`, `admin.watches`, `admin.usage`, `admin.audit`, `admin.judge`, `admin.models`, `workstreams.create`, `workstreams.close`, `conversation.modify`, `persona.create/read/write`, `project.create/read/write/delete` (`turnstone/core/auth.py:298-299`, `turnstone/core/storage/migrations/versions/062_projects.py:49`).

Tool policies (separate mechanism, not RBAC): glob (`fnmatch`) pattern → `allow`/`deny`/`ask`, priority-ordered first-match-wins, admin-authored, enforced in `evaluate_tool_policies_batch()` (`turnstone/core/policy.py:96-134`), called from `WebUI.approve_tools()` before auto-approve (`docs/governance.md:44-46`). MCP resources/prompts get their own glob namespace (`mcp_resource__{uri}`, `mcp__{server}__{prompt}`) — `docs/governance.md:48-53`.

---

## 2. Organization / team / tenant concept

VERIFIED — exists as `orgs` table, but is single-tenant in practice today; no true team concept exists at all.

- Schema: `turnstone/core/storage/_schema.py:513` (`orgs` table, PK `org_id`); `org_id` columns added to `users`, `roles`, `tool_policies`, `prompt_templates`, `prompt_policies` etc. (`_schema.py:246,531,569,588,928,974`, all `server_default=""`).
- Migration 008 **seeds exactly one default org** and gives every seeded role `org_id=""` (`008_governance.py:135-164`, comment at line 135: "Seed default org and built-in roles").
- `docs/governance.md:167`: `orgs` table description literally says **"Organizations (single default org for now)"**.
- **No API to create a second org.** `console_spec.py:513-537` defines only `GET /v1/api/admin/orgs` (list), `GET /v1/api/admin/orgs/{org_id}` (get), `PUT /v1/api/admin/orgs/{org_id}` (update) — no POST. Storage-layer `create_org()` exists (`_protocol.py:1966`, implemented in `_postgresql.py:3594`, `_sqlite.py:3651`) but the only caller in the whole tree is the migration seed — `grep -n "create_org(" -r turnstone` returns only the three definition sites, no call site outside migrations.
- Consequence: every role, tool policy, skill/prompt-template, and prompt-policy in a real deployment carries `org_id=""` — there is exactly one tenant. The org schema is multi-tenant-*ready* (present for a future feature) but not multi-tenant-*functional* today.
- No "org admin" concept distinct from platform admin — `admin.orgs` just gates editing the single org's display name/settings blob.

**Closest thing to a team/workspace: "Projects" (added v1.7, migration 062).**
`turnstone/core/storage/migrations/versions/062_projects.py:1-16`: "a governed, shareable resource container that groups workstreams and owns a `('project', project_id)` memory recall rung."

Schema (062_projects.py, `projects` table): `project_id` PK, `name`, `owner_id`, `visibility` (`private`|`public`), `state` (`active`|`archived`), reserved nullable `parent_project_id`. `project_members` table: composite PK `(project_id, user_id)` — the per-project ACL whitelist. `workstreams.project_id` — nullable FK-ish column linking a workstream to a project.

- **Who can create one**: any user holding `project.create` (admin-default only, per role table above; can be opted into other roles via `role_permission_overrides` — `062_projects.py:14`).
- **Access model** (`turnstone/core/auth.py:280-330`, `turnstone/core/project_access.py:85-86`): owner always reads/writes their own project; anyone else needs BOTH the RBAC capability (`project.read`/`project.write`) AND a per-project grant — an explicit `project_members` row, or (read-only) `visibility="public"`. Fail-closed on any missing project/storage error (`auth.py:301-302`).
- **What is scoped to a project**: workstreams (`workstreams.project_id`), and one memory-recall rung — `('project', project_id)` scoped structured memories (`062_projects.py:3-4`; `turnstone/core/memory.py:1409,1496-1543` computes project-reader-visible memory metric sets).
- **What is NOT scoped to a project**: tool policies, skills/prompt templates, MCP server definitions, model definitions/credentials, roles — all of these remain global (see §6/§7 below). A project is a workstream+memory container, not a tenancy boundary for infrastructure or credentials.
- Visibility distinction (`turnstone/core/auth.py:344-360`, `WorkstreamProjectVisibility`) is explicitly called out in a comment as "a tenancy question" separate from the RBAC capability check — but its effect is scoped to *workstream listing visibility*, not to any other resource type.

**Bottom line on Q2**: there is no Gitea-style "org → teams → per-team repo/resource permissions" hierarchy. There is (a) one global org (schema supports more, nothing uses it) and (b) a flat, user-owned "Projects" ACL container that scopes workstreams + one memory rung, with no admin-provisioning path (no OIDC-claim-driven project membership — see §3).

---

## 3. Authentication — OIDC/OAuth, group/role claim mapping

VERIFIED — full OIDC SSO support, with an explicit group→role claim mapping mechanism directly analogous to what's asked about.

`docs/oidc.md` (597 lines) is comprehensive; a worked Keycloak example is given verbatim (`docs/oidc.md:279-296`):

```
TURNSTONE_OIDC_ISSUER=https://keycloak.example.com/realms/your-realm
TURNSTONE_OIDC_CLIENT_ID=turnstone
TURNSTONE_OIDC_CLIENT_SECRET=...
TURNSTONE_OIDC_PROVIDER_NAME=Keycloak
TURNSTONE_OIDC_ROLE_CLAIM=realm_access.roles
TURNSTONE_OIDC_ROLE_MAP="admin:builtin-admin,operator:builtin-operator"
```

- `TURNSTONE_OIDC_ROLE_CLAIM` names the ID-token claim carrying group/role membership (dotted path supported, e.g. `realm_access.roles`; also plain `groups` works for Okta/Azure examples at `docs/oidc.md:250-269`).
- `TURNSTONE_OIDC_ROLE_MAP` maps `claim_value:turnstone_role_id` pairs, comma-separated (`docs/oidc.md:296-306`).
- **Behavior** (`docs/oidc.md:308-320`): re-evaluated on every login. Roles are added when new claim values appear and revoked when a previously-granted claim value disappears — but **only roles whose `assigned_by="oidc"` are touched**; manually-assigned roles are untouched. Claim value may be a JSON array or a single string, both handled. Unknown claim values and unknown target role IDs are silently ignored/skipped (no error).
- `assigned_by` markers (`docs/oidc.md:322-333`): `oidc` (claim-driven, revocable) vs `oidc-default` (safety-net `builtin-viewer` grant for brand-new OIDC users with no claim-mapped role, never auto-revoked).
- Source: `turnstone/core/oidc.py` — `apply_role_mapping()` at `oidc.py:1125`, called from both new-user and existing-user paths (`oidc.py:1048,1074`).
- **User provisioning** (`docs/oidc.md:337-357`): first login auto-creates a local user; identity keyed by `(issuer, sub)` stored in `oidc_identities` table; username from `preferred_username` (falls back to email local-part, deduped); password hash set to sentinel `!oidc` (cannot password-login).
- OIDC-only mode: `TURNSTONE_OIDC_PASSWORD_ENABLED=false` disables all password logins including admin, API-token auth still works (`docs/oidc.md:363-383`).
- Any OIDC-compliant IdP works (Google/Okta/Azure AD/Keycloak/Auth0/OneLogin/etc. via discovery document) — `docs/oidc.md:9-11`.
- **Gap vs. what's asked**: role mapping only ever assigns *global permission-bundle roles* (admin/operator/viewer or a custom role) — it does **not** provision `project_members` rows, does not create/join a "team", and does not scope tool policies/MCP servers/model credentials by claim value. There is no equivalent of Gitea's group→**team** map; there is only a group→**role** map. A Keycloak `groups` claim naming a specific platform team cannot, today, be used to auto-scope a Turnstone user into an isolated resource set — only into a global permission level.
- Separately, `oauth_obo` (`docs/oidc.md:117-165`, `docs/mcp-oauth.md:69-116`) lets the *same* OIDC sign-in mint delegated per-user tokens for MCP servers / model gateways (Entra OBO / RFC 8693) — this is per-**user** credential delegation, not per-team.

---

## 4. Admin surface

VERIFIED — both a REST admin API and a console admin UI (18-tab panel per `docs/governance.md:203-217`), permission-gated per tab/endpoint, all under `/v1/api/admin/*` requiring `approve` scope + specific permission (`docs/governance.md:159-172`).

Endpoint groups (`docs/governance.md:159-172`, cross-checked against `turnstone/api/console_spec.py`):
Users/Tokens/Channels (`admin.users`), Roles (`admin.roles`/`admin.users`), Orgs (`admin.orgs`, no create), Tool Policies (`admin.policies`), Skills (`admin.skills`), Personas (`persona.read/create/write`), Schedules (`admin.schedules`), Watches (`admin.watches`), Usage (`admin.usage`), Audit (`admin.audit`), Judge/verdicts (`admin.judge`).

**Can an admin provision on behalf of a user?** Yes, directly:
- `POST /v1/api/admin/users` — create a user (username/password/scopes) with no interactive login (`docs/console.md:263-272`).
- `POST /v1/api/admin/users/{user_id}/tokens` — mint a `ts_`-prefixed API token for that user, returned once, usable for Bearer auth (`docs/console.md:291-301`).
- `POST /v1/api/admin/users/{user_id}/roles` — assign a role to a user (`console_spec.py:492-497`).
- Channel links: `POST /v1/api/admin/users/{user_id}/channels` links an external platform identity (Discord/Slack user id) to a Turnstone user (`docs/console.md:313-320`).

Security guards on the admin surface (`docs/governance.md:227-249`): `admin_assign_role` blocks self-assignment and requires the caller to hold a superset of the target role's permissions (privilege-escalation guard); `admin_delete_user` blocks self-deletion; storage `update_*` methods filter fields against mutable-column allowlists; bootstrap rolls back if the very first admin-role assignment fails (no lockout).

The console admin panel gates *navigation visibility* the same way as the API (permission-gated tabs, not merely hidden-but-reachable) — `docs/governance.md:205-206`.

---

## 5. API for automation — auth, tokens, minting without interactive login

VERIFIED.

- **API is REST + SSE**, OpenAPI 3.1 generated from Pydantic v2 models, served at `/openapi.json`, Swagger at `/docs` (`docs/architecture.md:1900-1905`).
- **Three auth mechanisms**, unified behind `AuthResult{user_id, scopes, token_source}` (`docs/architecture.md:1756-1762`):
  1. API tokens: DB-backed, prefixed `ts_`, stored as SHA-256 hash in `api_tokens` table; exchangeable for a JWT via `POST /v1/api/auth/login`.
  2. JWTs: short-lived (default 24h) HMAC-SHA256, claims `sub`, `scopes`, `src`.
  3. (Console-internal) re-signed short-lived JWTs for proxying — see §"node auth" below.
- **Tokens can be minted administratively, with zero interactive login**, via two independent paths, both verified in source:
  - REST: `POST /v1/api/admin/users` then `POST /v1/api/admin/users/{user_id}/tokens` (`docs/console.md:263-301`).
  - CLI: `turnstone-admin` (`turnstone/admin.py`) exposes `create-user` (line 729), `create-api-key`/`create-user` variants (line 736), `create-token` (line 748), `list-users` (754), `list-tokens` (756), `revoke-token` (759), plus a `bootstrap` subcommand (763) — i.e., a fully scriptable, no-browser path to provision a user and mint a durable API token, suitable for CI/service accounts.
  - This is the closest Turnstone analog to a Gitea PAT / Vikunja bot-account token, and unlike those two apps (per `MCP.md`'s finding), Turnstone's own tokens ARE first-class bearer credentials for its own API from the start — no separate "log in once, harvest the app's own token" dance is required for pure Turnstone automation (it *is* required only for MCP servers that are themselves Gitea/Vikunja — that's an MCP-server-side constraint, not a Turnstone one).
- Both Python and TypeScript SDKs wrap this (`turnstone/sdk/console.py`), including governance methods (`list_roles`, `create_role`, `assign_role`, `list_orgs`, `get_org`, `update_org`, etc. — `docs/governance.md:197-206`).

---

## 6. Agents/personas/skills/tools — shareable, centrally-defined, team-assignable?

VERIFIED, with a caveat: everything is centrally defined and globally visible; nothing is assignable to a specific team/user subset.

- **Personas** (`docs/personas.md`): named, reusable system-message + capability-envelope bundles, resolved once at workstream creation and stamped immutably into `workstream_config` (`docs/personas.md:20-30`). Built-in personas ship as repo files (`prompts/personas/<file>`); operator personas store prose inline via the admin API (`persona.create`/`persona.write`, gated, `docs/personas.md:83-89`). **Selection is per-workstream** (CLI flag / API field / launcher dropdown), by any user who can create a workstream — **not scoped to a role, team, or user set**. There is no "persona X is only available to team Y" concept; visibility is global once created (RBAC gates *editing* a persona, not *using* one).
- **Skills** (`docs/governance.md:57-127`): admin-curated reusable system-message snippets + session config, stored in `prompt_templates`, `org_id` column present (defaults to `""`, single org — see §2), selectable per-workstream (`--skill` flag, `skill` field, console dropdown) or auto-applied (`is_default=true`). Same pattern: centrally defined, globally visible, no team-scoped assignment.
- **Tools**: JSON-schema files in `turnstone/tools/*.json` (`docs/architecture.md:96` module map) define role-specific surfaces (`INTERACTIVE_TOOLS`, `COORDINATOR_TOOLS`, `TASK_AGENT_TOOLS`) — role here means *session kind* (interactive vs coordinator vs task-agent), not RBAC role/team. Tool policies (allow/deny/ask) are admin-global (again `org_id`-columned but single-org in practice).
- **MCP servers**: single global table `mcp_servers` (`_schema.py:837-868`) — no `org_id`/team column at all (see §7). Per-user OAuth consent (`mcp_user_tokens`, keyed by `(user_id, server_name)`) is the only per-identity partition, and it's per-**user**, not per-team.

**Conclusion for Q6**: Yes to "centrally defined, reusable" (personas/skills/tools/MCP servers are all admin-curated, reusable objects) — **No** to "assignable to a specific team or set of users." Everything that exists is either globally visible to all authenticated users, or gated by a global RBAC permission (who may *edit*, not who may *use*). There is no ACL that scopes a persona/skill/tool-policy/MCP-server to a subset of users the way Gitea scopes a repo to a team.

---

## 7. Per-team credential isolation

VERIFIED negative — no such isolation exists today; credentials are global/shared, except where delegated per-**user** (not per-team) via OBO.

- `model_definitions` table (`_schema.py:883-910`): one row per model *alias*, columns include `api_key` (plaintext-stored static credential), `base_url`, `auth_mode` (`static`/`entra_obo`/`rfc8693_obo`/`entra_app`), `obo_audience`, `obo_scopes`. **No `org_id`, `team_id`, or any tenant column at all.** A model alias's credential is single and shared platform-wide; every user who can select that alias uses the same `api_key` (or, for OBO modes, mints against the *same* audience but with *the calling user's own* delegated identity — still not team-scoped, just user-scoped).
- `mcp_servers` table (`_schema.py:837-868`): same story — one row per server, one `auth_type`/credential set (`static` headers or one `oauth_client_id`/`oauth_client_secret_ct` pair for `oauth_user`/`oauth_obo`). No tenant column. Per-(user, server) tokens live separately in `mcp_user_tokens` (`_schema.py:1044-1058`, composite PK `(user_id, server_name)`) — again per-**user**, not per-team.
- `tool_policies` **does** carry `org_id` (`_schema.py:569`, index at 577) and the storage-layer query supports filtering by it (`policy.py:54-90` caches per `org_id`), but every call site in the actual request path calls it with no argument → defaults to `org_id=""` (`turnstone/core/session_ui_base.py:2367`, `turnstone/cli.py:191`, `turnstone/console/server.py:7790` — none pass a non-empty `org_id`). So even the one governance table that is schema-ready for per-org policy is not actually partitioned in code today.
- **Conclusion**: two teams **cannot**, out of the box, share one agent/persona/skill definition while using different secrets/credentials/endpoints. The only lever that comes close is: (a) define two separate `model_definitions` rows (two aliases) with different keys, and have each team's workstreams explicitly select the alias meant for them — this is a *naming convention*, not an enforced isolation (any user who can create a workstream can pick either alias; there's no RBAC gate on "may use model alias X"), or (b) run genuinely separate Turnstone deployments per team (separate DB, separate `config.toml`, separate `model_definitions`) — which is real isolation but is a **multi-instance**, not multi-tenant-single-instance, answer (see §9).

---

## 8. State / schema inventory — user- vs team/org- vs global-scoped entities

VERIFIED, compiled from `turnstone/core/storage/_schema.py` and the migrations named per-table above.

| Entity | Scope | Evidence |
|---|---|---|
| `users` | global (has inert `org_id`, single org) | `_schema.py:246` (`org_id` col on users) |
| `api_tokens` | per-user | `docs/architecture.md:1836-1843` |
| `oidc_identities` | per-user | `docs/oidc.md:339` |
| `channel_users` | per-user (external identity link) | `docs/architecture.md:1846-1850` |
| `orgs` | global, single row in practice | `_schema.py:513`, `008_governance.py:135-164` |
| `roles` / `role_permission_overrides` | global (has inert `org_id`) | `_schema.py:531` |
| `user_roles` | per-user (with `assigned_by` marker) | `docs/oidc.md:322-333` |
| `tool_policies` | global in practice (has inert `org_id`) | `_schema.py:569`, `policy.py:54` |
| `prompt_templates` (skills) | global (has inert `org_id`) | `_schema.py:588` (implied), `docs/governance.md:87` |
| `prompt_policies` | global (has inert `org_id`) | `_protocol.py:3047` |
| `usage_events` / `audit_events` | global, queryable per-user | `docs/governance.md:131-149` |
| `mcp_servers` | global, no tenant column | `_schema.py:837-868` |
| `mcp_user_tokens` | per-user × per-server | `_schema.py:1044-1058` |
| `model_definitions` | global, no tenant column | `_schema.py:883-910` |
| `projects` | user-owned container + member ACL | `062_projects.py` |
| `project_members` | per-(project,user) ACL | `062_projects.py` |
| `workstreams` | per-user (`user_id` owner) + optional `project_id` | `docs/architecture.md:1432-1447` |
| `conversations` | per-workstream (inherits workstream owner) | `docs/architecture.md:1449-1464` |
| `structured_memories` | per-`(type, scope, scope_id)` — scope can be `user`/`project`/etc. | `docs/architecture.md:1433`, `062_projects.py:18-21` |
| `services` | global node registry, no tenant column | `_schema.py:391-400` |

Net: the **only** entities with any team-like partition are `projects`/`project_members` (workstreams + one memory rung), and per-user rows (`mcp_user_tokens`, `oidc_identities`, `api_tokens`, `channel_users`, `user_roles`). Every governance/infrastructure table that would need to be team-scoped for Gitea-style isolation (roles, tool policies, skills, MCP servers, model credentials) is either fully global or carries an inert, unused `org_id`.

---

## 9. Multi-node topology and where tenancy actually lives (per coordinator's follow-up)

### 9.1 Topology, VERIFIED

Single-node: client → server over HTTP+SSE, no console (`docs/architecture.md:1512-1514`). Multi-node: `turnstone-console` sits in front and routes each workstream to a server node via rendezvous (HRW) hashing over the live `services` registry — "a pure function of `(ws_id, live_nodes)` with no stored bucket state" (`docs/architecture.md:1515-1519`).

`docs/console.md:1-19`: console is "**one instance**"; discovers nodes via the `services` DB table (nodes register on startup + heartbeat); opens persistent SSE to each node; proxies workstream creation via HTTP; reverse-proxies each node's UI at `/node/{node_id}/` so browsers never touch server nodes directly.

**A node can be explicitly targeted**, which is the mechanism that would realize "one node per team":
- `console_schemas.py:1450-1466` — workstream-creation request model has `target_node: str` and a `routing_strategy: Literal["rendezvous", "target_node", "resume"]` field.
- `turnstone/console/server.py:2134-2237` — `target_node` is validated (`_VALID_NODE_ID` regex, ≤256 chars, `server.py:2147-2155`) and, if set, the console calls `router.generate_ws_id_for_node(target_node)` (`server.py:2233,2287`) to mint a `ws_id` whose rendezvous hash is guaranteed to land on that specific node — a brute-force loop over random 32-hex-char ids capped at 65,536 attempts (`turnstone/console/router.py:226-244`, cap explained lines 32-38: expected attempts ≈ total-weight / target-weight).
- `turnstone/console/router.py:154-192` — `route(ws_id)` first checks a per-workstream override map (`self._overrides`), falling back to HRW selection; `remember_override()` publishes a just-confirmed placement so a `target_node`-created workstream always subsequently routes back to that same node.
- Node weight (for the plain rendezvous path) is admin-settable per-node metadata (`_parse_weight()`, `router.py:41-56`, reads a `weight` key from the node's `metadata` JSON blob in the `services` row) — and `turnstone-admin set-node-metadata` (`turnstone/admin.py:799-804`) lets an operator tag arbitrary key/value metadata on a node.

**INFERRED (not found in source or docs)**: there is no built-in concept of "this node belongs to team X" or any enforcement that restricts which users/workstreams may land on a given node. `target_node` + `generate_ws_id_for_node` is a *generic placement* primitive; using it to pin "team A always creates workstreams with target_node=node-team-a" is a pattern the operator/caller would have to build and enforce themselves (e.g., in whatever wrapper issues the `POST /v1/api/cluster/workstreams/new` call on the team's behalf) — Turnstone does not gate or validate that a given user/role may only target a given node. Grep for any node↔team/org coupling came back empty: `grep -rn "node.*team\|team.*node\|node_scope\|allowed_org\|restrict.*node" turnstone docs --include=*.py --include=*.md -i` found nothing relevant (only an unrelated docstring "Pass `node_ids` to restrict results to the given set" in `collector.py:908`, about a query filter, not access control).

### 9.2 Where tenancy actually lives — answered directly

**VERIFIED: entirely in the singleton's shared data model — one database, one JWT secret, no per-node data or identity partition.**

- All governance state (`users`, `roles`, `orgs`, `tool_policies`, `prompt_templates`, `mcp_servers`, `model_definitions`, `projects`, `workstreams`, …) lives in one shared storage backend (SQLite or PostgreSQL) that every node and the console connect to (`docs/architecture.md:1414-1421` config via `TURNSTONE_DB_BACKEND`/`TURNSTONE_DB_URL`, shared across processes). Node registration is a plain row upsert into that shared `services` table (`register_service()`, `_postgresql.py:2841-2862`, `_sqlite.py:2869-2890`) — nothing node-local is authoritative for identity or permissions.
- Server nodes are described explicitly as **"a JWT validator only"**: "it validates tokens on each request but never creates users or tokens. Both processes share the same `jwt_secret`" (`docs/architecture.md:1794-1797`). So the credential-issuing authority (console) and every execution node share one secret and one DB — a node has no independent identity store, no independent user/role table, and cannot make an isolated tenancy decision on its own.
- Therefore: **shared/global** — users, roles/permissions, orgs, projects, tool policies, skills, personas, MCP server definitions, model definitions/credentials, audit/usage logs — all one copy, reachable identically from any node. **Genuinely per-node** — only ephemeral runtime state: which workstreams are *currently resident/running* on that process (in-memory `ChatSession` objects, SSE connections), and whatever `services.metadata` (e.g. `weight`) or node-local `config.toml`/env vars (e.g. a node-local `TURNSTONE_JWT_SECRET` override, which would just break auth if it diverged) the operator sets. There is no genuinely-isolated *tenant data* per node — a node is a stateless(-ish) execution replica against one shared brain, not a data boundary.

### 9.3 Node authentication to the singleton/rendezvous proxy — answered directly

**VERIFIED: no node identity credential exists at all (no token, no mTLS, no per-node secret).** Node "authentication" is really just:
1. **Shared database access** — `register_service(service_type, service_id, url, metadata)` is a bare upsert with no signature/credential field in the row (`_schema.py:391-400`: columns are only `service_type, service_id, url, metadata, last_heartbeat, created` — none is a token/cert). Anything that can write to the shared DB can register as a node under any `service_id`/`url` it likes. The only defense mentioned is IP-reuse detection on the *console's SSE subscribe* path — `?expected_node_id=` query param, "server returns 409 on mismatch" (`docs/console.md:35`) — which detects a stale/reused IP for an *already-known* node_id, not an unauthorized new registration.
2. **Shared `jwt_secret`** — the only cryptographic material a node needs is the same HMAC key the console uses to sign JWTs (`docs/architecture.md:1796-1797`); a node validates any JWT signed with that key regardless of which "team" issued the request.

**"Can a node be scoped so it may only serve one team's work?"** Not through any built-in enforcement (confirmed by the grep in §9.1). The only way to *steer* work toward one node is the generic `target_node` placement primitive (§9.1) — an operational convention, not an authorization boundary. Nothing stops any authenticated user from bypassing that convention (e.g. omitting `target_node`, letting HRW land them elsewhere, or explicitly targeting a different team's node) because the JWT that authorizes the request carries global scopes/permissions, not a node/team affinity claim.

### 9.4 Does the permission model follow the work to the node? — answered directly, this is the key finding

**VERIFIED, and the news is good: yes, the real user's identity and permissions travel with the request, per-call — it is not a shared service identity in the normal path.**

`docs/console.md:376-381` ("Authentication" under "Reverse Proxy"), quoted in full because it is precisely on point:

> "The proxy mints a short-lived (5-minute) JWT per request carrying the real user's `user_id`, `scopes`, and `permissions` with `aud: turnstone-server`. The user's console JWT (`aud: turnstone-console`) cannot be forwarded directly — it would be rejected by the server's audience validation — so the console re-signs a new server-audience JWT from the validated `AuthResult`. This preserves audit attribution (the upstream server sees the real user, not a service identity) and enforces scope narrowing as defense in depth (a read-only console user's proxied request carries only `read` scope). Ordinary users are re-minted with `src="console-proxy"`; coordinator tokens retain `src="coordinator"` plus `coord_ws_id`, and only the validated console service identity with `service` scope retains `src="console"` for trusted owner forwarding. When no user context is available, the proxy falls back to a `ServiceTokenManager` identity `console-proxy` carrying `src="console"` and `{read, write, approve, service}` scopes."

Implications:
- The node executing a session **does know the acting user's identity and permission set** on every request — it's re-derived from a freshly minted, audience-scoped JWT per proxied call, not assumed from a static node-level credential. `require_permission()` on the node evaluates the *real user's* permissions (`docs/governance.md:14-16`), so RBAC (including any org/project ACL check like `resolve_project_access`, `turnstone/core/auth.py:280-303`) is enforced with full fidelity regardless of which node serves the call.
- **The one fallback path is a shared service identity**: "When no user context is available" the proxy falls back to `console-proxy` with `src="console"` and a fixed `{read, write, approve, service}` scope set — this is a genuine shared/ambient identity case (e.g., system-internal or scheduled-task-initiated calls where no interactive user is behind the request), and it carries the *maximal* scope set, not a narrowed one. This is the one place where "acting as a single service identity" is real rather than nominal.
- **Consequence for per-team credential isolation (tying back to §7)**: since permission enforcement is genuinely per-user and per-request (not per-node), the *authorization* layer is real even across nodes. What is **not** real is *data/credential* partitioning — a user with the right permission can reach the same global `model_definitions`/`mcp_servers` rows regardless of which node processes their request, because those tables carry no tenant column (§7). So: RBAC follows the user correctly node-to-node; secrets/config do not follow any team boundary at all, because no team boundary is modeled below the "Projects" ACL layer.

### 9.5 Where are per-team credentials resolved (singleton vs. node)?

**VERIFIED for the mechanisms that exist, but they are per-user, not per-team, so the question is somewhat moot** — restated precisely:

- Static `model_definitions.api_key` / `mcp_servers` static headers: resolved by whichever process executes the tool/model call — i.e., **on the node**, reading the row out of the *shared* DB (same row everywhere, no per-node override in schema). The singleton does not "hand down" a per-team-scoped credential to a node; the node reads the identical global row itself.
- OBO-delegated credentials (`entra_obo`/`rfc8693_obo` model auth, `oauth_obo` MCP): minted **at call time**, on whichever node is executing that turn, using the driving user's captured refresh credential (`docs/oidc.md:117-124`: "redeems the driving user's captured credential for its exact `obo_audience`... at call time"). The captured refresh credential itself is written once, at OIDC login, into the shared DB (Fernet-encrypted with a deployment-wide key — "not per-host... every host that reads them needs the same keyring", `docs/oidc.md:206-211`) — so again, the secret material lives centrally in the shared DB, and every node (having the same encryption key) can decrypt and mint from it locally. There is no singleton-side pre-resolution step that hands a node a ready credential; the node does the mint itself from shared encrypted storage.
- Because credentials are keyed by **user** (or globally, for static model/MCP definitions), not by **team/project**, there is no "per-team credential resolved somewhere" to report — the resolution point (node, at call time, from the shared DB) is the same regardless of team, because Turnstone has no representation of team for this purpose.

---

## Executive summary

- Turnstone's RBAC is real and reasonably granular: legacy `read/write/approve` scopes plus fine-grained `permission` strings aggregated from `roles` → `user_roles`, both carried in the JWT and enforced per-endpoint (`require_permission()`). Three built-in roles (admin/operator/viewer), custom roles supported.
- OIDC SSO is fully implemented against any compliant IdP including Keycloak, with a **group/role-claim → Turnstone-role mapping** that is synced on every login (add/revoke, with a distinct "default role for unmapped users" safety net). This directly answers the Keycloak-groups question: yes, an equivalent exists — but it maps a claim to a **global permission bundle**, not to a **team/tenant**.
- There is an `orgs` table and org_id columns scattered through governance tables, but only one org is ever seeded, there is no API to create a second one, and no code path in the request path actually filters by org_id (all defaults to `""`). This is schema readiness, not a working multi-tenant feature.
- The closest real team/workspace concept is **Projects** (v1.7): user-owned, membership-ACL'd containers that scope **workstreams and one memory-recall rung only**. Nothing else (roles, tool policies, skills, personas, MCP servers, model credentials) is scoped by project.
- MCP servers and model definitions (the two places real secrets live) are single global rows with no tenant column at all; the only per-identity partition anywhere is per-**user** (MCP OAuth consents, OIDC-delegated OBO credentials), never per-team.
- The admin surface is strong for automation: admin can create users and mint API tokens (`ts_`-prefixed) via both REST and a `turnstone-admin` CLI, entirely non-interactively — a solid service-account story, better than Gitea/Vikunja's in this fork's own experience (`MCP.md`).
- Multi-node topology is real (console + rendezvous-hashed nodes, `target_node` placement primitive available), but **tenancy lives entirely in the shared singleton DB + shared JWT secret** — nodes hold no independent identity, credential, or data partition. A node cannot be scoped to one team by anything built in; that would be a purely operational convention layered on `target_node`.
- The one genuinely good finding for "does permission follow the work": yes — the console re-signs a short-lived, audience-scoped JWT carrying the *real user's* id/scopes/permissions on every proxied call to a node, so RBAC and audit attribution are correct regardless of which node executes a session. The one exception is a fallback shared `console-proxy` service identity used when no user context exists, which carries maximal scope.
- Net effect: authorization (who may act as whom) travels correctly across the cluster; **authorization of *what tenant's data/secrets* a node may touch does not exist as a concept**, because tenants (teams) aren't modeled below the project layer.

## How close to the Gitea/Tekton per-team-with-central-UI model?

Not close today, and the gap is structural, not superficial. Gitea's model is: org → teams → per-team-scoped resources (repos, permissions), with a central UI administering many isolated tenants. Turnstone has a strong *central UI over one global tenant*, plus a thin, workstream-only "Projects" ACL bolted on top — but no team abstraction, no per-team resource scoping for the things that actually carry sensitive state (MCP servers, model API keys, tool policies, skills), and no admin-provisioning path that creates a team's resources the way Gitea creates an org+team+repo set. The `orgs` table and per-request JWT re-signing show the *shape* of a multi-tenant system was anticipated by whoever built this (org_id columns everywhere, real per-user credential/permission propagation across nodes), but the actual team/tenant layer was never built out — it stops at "one org, N users, N optional user-owned Projects." Getting to the Gitea shape would require: (1) turning on real multi-org (there's a schema and a storage method, just no API/UI and no `org_id` filtering wired into the hot paths), (2) adding a `team_id`/`org_id` column to `mcp_servers` and `model_definitions` and gating their use by team membership, (3) extending OIDC role-mapping (or a new claim) to provision team/project *membership*, not just global role, and (4) if per-team physical isolation via node pinning is wanted, building an actual enforcement layer on top of the existing `target_node` primitive, since today it's an unenforced placement hint, not a boundary.
