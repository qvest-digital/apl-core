# Agent workflows as catalog items

**This is a design, not a record.** Every other fork document in this repository describes something
that was built and run; this one describes something intended. Claims marked **VERIFIED** were
checked against the live cluster on 2026-08-31 and are facts about the platform. Everything else is
a decision, and decisions are cheap to revisit — say so rather than treating this file the way you
would treat `AGENT-ENVIRONMENTS.md`.

Read `AGENT-ENVIRONMENTS.md` first: it is the evidence this design is built on, and §1-§19 there are
what was actually proven live. `research/catalogs-and-workloads.md` holds the mechanism reading with
`file:line` citations; two of its conclusions are corrected below.

## 1. The idea: a catalog item is a workflow, not an environment

The environment does not exist when a team installs a catalog item. It does not exist until an event
fires. What a team installs is the **wiring** — the thing that listens, and the recipe it runs.

Everything follows from that split:

| | install time (once per team) | run time (once per event) |
|---|---|---|
| who | a person, in the APL Console | a Gitea webhook |
| what appears | EventListener + Pipeline in `team-<id>` | environment, agent node, one agent run |
| lifetime | until uninstalled | minutes |

Team-specific choices are frozen into workload values at install time. Event-specific choices — which
commit, which branch, which pull request — are decided by the pipeline at run time.

## 2. What a workflow chart contains

Very little, deliberately:

```
review-agent/
  Chart.yaml          the catalog tile: name, description, icon
  values.yaml         the parameters a team fills in
  templates/
    eventlistener.yaml    EventListener + TriggerBinding + TriggerTemplate
    pipeline.yaml         the Pipeline and its Tasks
```

No Deployments, no environment, no agent — those are created by the pipeline and destroyed after.

This is not a new shape. **VERIFIED**: `demo-seed/bookinfo/reviews/.gitea/runner/chart/templates/`
contains an EventListener, a TriggerBinding and a TriggerTemplate and nothing else, installed as an
ordinary `AplTeamWorkload`. Every team already runs a chart of exactly this form.

## 3. What one run does

1. **Build the environment** — the app workloads, pinned to this pull request's images.
2. **Get an agent** — ask the node broker (§4) for a Turnstone node in the `turnstone` namespace,
   running this team's image with this workflow's `config.toml`.
3. **Ask it to do something** — open a workstream on that node and send the prompt.
4. **Tear it all down.**

There is no concurrency cap and no slot mechanism. One pull request, one environment. The
`wait-for-slot` task sketched in `AGENT-ENVIRONMENTS.md` §1 is **not** part of this design.

Step 3 needs no Turnstone change. `POST /v1/api/workstreams/new` then `send` is enough; there is no
inbound webhook receiver in Turnstone and none is needed. Prefer the Python SDK over hand-rolled
HTTP.

## 4. The node broker is an admin-team workload, not a service

The pipeline needs one thing it cannot do from a team namespace: **create the Turnstone node**. The
node must live in the `turnstone` namespace, because putting it in a team namespace means copying
`TURNSTONE_JWT_SECRET` there — the one credential on this platform that is not capability-scoped
(`AGENT-ENVIRONMENTS.md` §3). A team's Argo project is pinned to `team-<id>` and nothing else.

**This does not need a new service.** A rejected earlier draft proposed a small Python "environment
broker"; it is unnecessary, and standing infrastructure that acts on every future team is exactly
what got the Vikunja team-sync operator deleted. The platform already has everything required:

- **VERIFIED** `team-admin` carries the full Tekton Triggers stack — `sa-team-admin`,
  `tekton-triggers-team-admin`, and this fork's `tekton-triggers-createjob-team-admin`.
- **VERIFIED** `charts/team-ns/templates/argocd/argocd-application-workload.yaml`: a workload with
  `teamId == "admin"` **and** a `namespace` set gets `project: default` — unrestricted — and the
  admin AppProject carries `clusterResourceWhitelist: [{group: '*', kind: '*'}]`.

**VERIFIED 2026-08-31 end to end.** An `AplTeamWorkload` POSTed to `/api/v2/teams/admin/workloads`
with `namespace: turnstone` produced an Argo Application with `project: default`,
`destination.namespace: turnstone`, which created a RoleBinding **in `turnstone`** binding a
ServiceAccount in `team-admin` to a ClusterRole there. `Synced`/`Healthy`, no special casing.

So an admin-team workload chart can grant its own ServiceAccount a RoleBinding *in the `turnstone`
namespace*. The broker is then just another catalog item, installed once by the platform admin:

```
node-broker/
  templates/
    rbac.yaml            RoleBinding in `turnstone` for the broker SA
    eventlistener.yaml   EventListener + Pipeline in `team-admin`
```

Team pipelines POST to its sink to create or destroy a node. Ingress to it is the same shape as the
existing `default-from-gitea` policy: an `AplTeamNetworkControl` on `team-admin` admitting the team
namespaces.

## 5. Credentials

**Files, never environment variables.** Turnstone's `scrubbed_env()` strips every name ending in
`_KEY`, `_SECRET`, `_TOKEN`, `_PASSWORD`, `_CREDENTIAL(S)` before every subprocess, and the
`passthrough=` escape hatch has no production caller. A `LOKI_PASSWORD` in the pod environment is
simply absent when the agent runs, with no error explaining why (`AGENT-ENVIRONMENTS.md` §5, §14).

**Per-team and long-lived, not per-environment.** Gitea and Vikunja PATs can be minted and revoked
per environment. **Loki cannot** — Loki OSS has no token concept at all; the tenant is chosen by the
basic-auth username and the password is a long-lived per-team value stored as plaintext in the
`reverse-proxy-auth-config` Secret. There is nothing to mint. So at least one credential the agent
needs is a standing team credential no matter how the others are handled.

That settles two things:

- The credential is stored through apl-api as an **`AplTeamSecret`** (**VERIFIED**: the kind is real,
  `src/common/repo.ts:339`, sealed-secret backed, delivered by the team's `values-gitops` Argo app to
  `team-<id>`), so it appears in the team's own Secrets view in the Console.
- The **earlier draft's per-environment token minting is dropped.** It required cluster-level
  `gitea admin` at run time to buy revocation the Loki credential cannot have anyway. Minting happens
  once, at seed time, where admin rights already exist.

**Delivery: the admin side reads, the admin side injects.** The team pipeline cannot write into
`turnstone`, and passing credentials in a webhook body would put them in the EventListener's logs.
So the broker gets a **narrow read grant on one named Secret per team namespace** and copies what the
node needs into that node's own per-environment Secret when it creates it. More setup than passing
them along; the credentials never travel through an event payload.

## 6. Talk to the node directly, not through the console

Turnstone stores no "workstream X lives on node Y". It recomputes the answer on **every request**,
by hashing the workstream id against the list of currently-live nodes (HRW rendezvous hashing,
`turnstone/core/rendezvous.py`). Change the node list and the answer changes for workstreams that
are already running.

That matters because **each node is a separate pod with its own filesystem** — one working directory
per node *process*, shared by every workstream on it, with no per-workstream sandbox
(`research/turnstone-execution-model.md` §5). A workstream that moves gets its history rehydrated
from Postgres but **not its files**: it wakes up with an empty working directory.

Pinning via `target_node` does not fully fix this. It works by brute-forcing a workstream id that
*currently* hashes to the wanted node — a lucky number, not a lock — and a pinned create at capacity
fails outright rather than spilling to another node.

**So the pipeline talks to the node's own Service, bypassing the console's routing entirely.** No
hash, no churn, no pin. The console still works for a human watching.

This design also keeps churn from mattering in the first place: one node, one task, destroyed after.
The condition is worth stating because drifting off it silently reintroduces the problem — **churn
only stops mattering because nothing long-lived is routed through the console while nodes come and
go.** A longer-lived node is fine for the same reason: a person using the GUI *on that node* is
talking to that node.

## 7. Constraints verified on the live cluster

**A workload chart CAN emit a NetworkPolicy today — because of an upstream bug.** This reverses
what this section claimed before it was tested. **VERIFIED** by building a disposable chart
(`test-charts/appproject-probe`, branch `test/appproject-probe`) and installing it as a real workload
on `team-reviews`:

| kind the chart emitted | outcome |
|---|---|
| `ConfigMap` | created |
| `NetworkPolicy` | **created** — app stayed `Synced`/`Healthy` |
| `ResourceQuota` | **refused** — `resource :ResourceQuota is not permitted in project team-reviews` |

So the AppProject blacklist *is* enforced. The `NetworkPolicy` entry simply never matches, because
`charts/team-ns/templates/argocd/argocd-project.yaml` declares it under the **core** API group:

```yaml
  - group: ''
    kind: NetworkPolicy      # <- NetworkPolicy is networking.k8s.io, not core
```

`ResourceQuota` and `LimitRange` on either side of it genuinely are core, so those two work and this
one does not. Argo matches group *and* kind, and an empty group never equals `networking.k8s.io`.

**Do not build on this.** A workload chart emitting its own NetworkPolicy works right now, and stops
working the day upstream fixes the group string — silently, on an upstream sync, with no error until
a sync fails. Environment netpols go through `AplTeamNetworkControl`
(`AGENT-ENVIRONMENTS.md` §7), which is supported rather than accidental.

Two details worth keeping. The refusal message **does not name the offending kind** in
`status.conditions` — it says only `one or more synchronization tasks are not valid. Retrying attempt
#N`, and the app reports `OutOfSync`/`Healthy` while retrying forever. The kind appears only in
`status.operationState.syncResult.resources[]`. And a branch-targeted workload can render a **stale
commit** for a couple of minutes after a push; `status.sync.revisions[0]` is the honest answer to
"which commit is this", and it lagged the branch head by ~40s here even after a hard refresh.

This **corrects `research/catalogs-and-workloads.md`** in the opposite direction from what was
expected: its `agentic-sdlc` example shipping a NetworkPolicy was not a mistake in the notes — it
really does work, for the wrong reason.

**`sourceRepos` is self-authorizing, and catalogs play no part in it.**
`charts/team-ns/templates/argocd/argocd-project.yaml` builds the allow-list by ranging over *the
team's own workloads' `url` fields*, plus the team repo and the values repo. So a shared central
chart repo is whitelisted the moment a workload points at it — and, equally, adding an `AplCatalog`
entry authorizes nothing.

**The catalog is the picker, not the deployment path.** The four production workloads on this lab
were never created through a catalog: `env/catalogs/` holds only `default`, and each workload names
`https://github.com/linode/apl-charts.git` + `path: k8s-deployment` directly (`.taskfiles/seed.yml`).
A pipeline creating an environment does the same thing. The catalog entry is worth having so a human
can pick the workflow from a tile, but nothing on the machine path reads it.

**Teardown works — `prune: false` is not the blocker earlier notes claimed. VERIFIED end to end.**
`DELETE /api/v2/teams/reviews/workloads/probe` removed the Application *and* both objects it had
created, in the team namespace; the same against the admin workload removed its RoleBinding from
`turnstone`. The chain is: the workload Application carries
`finalizers: [resources-finalizer.argocd.argoproj.io]`, its parent `team-<id>-team-ns-<id>` app has
`automated.prune: true`, so removing the workload prunes the child Application and the finalizer
cascade-deletes its resources. `prune: false` only means "do not delete resources that vanish from
the manifest while the app still exists".

**But budget ~1-2 minutes each way, and know where it goes.** Deletion itself is fast; what is slow
is *detection*. Every create and every delete is a commit to the values repo, picked up by the
operator's git-poll reconcile, re-rendered into `team-ns`, and only then acted on by Argo. Measured
here: workload deleted at `23:57:51`, everything gone by `23:58:30`; the create side was similar, and
a branch-targeted chart took another ~40s to stop serving a cached commit.

**This is the real cost of making an ephemeral environment a platform object**, and it is worth
stating before the first pipeline is written: a per-pull-request environment pays a git-poll tax at
both ends. Anything that must happen in seconds cannot go through the values repo — it has to be a
plain Kubernetes object the pipeline creates directly, which buys speed and loses Console
visibility. That trade has not been made yet.

## 8. Webhook registration has no platform object

**VERIFIED**: the Console's "create webhook" checkbox is `trigger: true` on `AplTeamBuild`
(`values-schema.yaml:1199`), which `apl-gitea-operator` turns into a *push* webhook pointing at that
build's EventListener. It is build-specific. There is no generic "register this webhook" resource.

Decided: register them by hand while the first two or three workflows land. A `setup` workflow in the
same catalog is the intended answer later — preferred over a Helm install hook, because a hook that
fails during an Argo sync fails where nobody looks, while a setup pipeline has logs, a retry, and a
visible record of what it did.

## 9. Vikunja webhooks need one setting, and it is not set

Vikunja vendors `code.dny.dev/ssrf` and refuses outbound calls to `10.0.0.0/8`, which covers this
cluster's Service CIDR — so every webhook to a cluster-internal EventListener fails with
`prohibited IP address ... denied by: 10.0.0.0/8`. This is real, not a misconfiguration.

The fix is one line, `VIKUNJA_OUTGOINGREQUESTS_ALLOWNONROUTABLEIPS: "true"`, and it belongs at
`values/vikunja/vikunja.gotmpl:104` where the other `VIKUNJA_*` vars live — **not** `kubectl set env`,
which Argo's `selfHeal` reverts (this was the live-only hack used the first time round). That file is
baked into the operator image, so it costs a rebuild, which makes it a next-rebuild item.

The control it disables is protecting against something that is not the threat model here: a
company-internal Vikunja reaching a company-internal listener.

## 10. Open questions, in the order they should be answered

1. ~~Does apl-api accept a team member's token and scope writes to that team?~~ **Answered
   2026-08-31: yes, for both reads and writes.** See §12.
2. ~~Does Argo actually refuse a workload chart's NetworkPolicy?~~ **Answered 2026-08-31: no** — the
   blacklist entry names the wrong API group. See §7.
3. **Can the pipeline create and drive a workstream against a node's own Service**, bypassing the
   console? `AGENT-ENVIRONMENTS.md` §12 found one node endpoint that needs a scope a human does not
   have; the create-and-send path is a different one.
4. ~~Does deleting a workload actually delete its pods?~~ **Answered 2026-08-31: yes**, in both a
   team namespace and `turnstone`, in about 40 seconds. See §7.

## 11. Worth twenty minutes before building our own vocabulary

`src/common/repo.ts` declares two kinds nothing here has looked at: **`AkamaiAgent`**
(`env/teams/<team>/agents/`) and **`AkamaiKnowledgeBase`** (`env/teams/<team>/knowledgebases/`), both
delivered by the team's `values-gitops` app and gated behind `aiEnabled` (`values-schema.yaml:2837`,
default `false`). Neither has a schema definition in `values-schema.yaml`. Probably
Akamai-cloud-only — but if upstream ships an agent primitive, it is cheaper to find out now than
after this design has its own nouns.

## 12. apl-api tenancy — VERIFIED, and it is what the design needs

Tested 2026-08-31 with a `dev-reviews` token (Keycloak password grant through the
`oauth2-proxy-client-access` client, exactly as `.taskfiles/seed.yml`'s `dev_team_token` does):

| call | result |
|---|---|
| `GET  /api/v2/teams/reviews/workloads` | `200` |
| `GET  /api/v2/teams/details/workloads` | `403` `User not allowed to perform "read" on "Workload"` |
| `GET  /api/v2/teams` | `403` `...on "Team"` |
| `POST /api/v2/teams/reviews/sealedsecrets` | `200` |
| `POST /api/v2/teams/details/sealedsecrets` | `403` `...to perform "create" on "SealedSecret"` |
| `POST /api/v2/teams/reviews/workloads` | `200` |
| `PUT  /api/v2/teams/reviews/workloads/<name>` | `200` |

**A team credential can build and tear down its own environment, and cannot touch another team's.**
That is the whole premise of §4 — the admin side stays narrow because it only has to create nodes.

Three practical notes:

- **The route is `sealedsecrets`; `secrets` is a 404.** And the POST body's `kind` must be
  `SealedSecret`, *not* the `AplTeamSecret` that `src/common/repo.ts` uses for the file on disk.
  Sending the file kind gets `400 must be equal to one of the allowed values: SealedSecret`.
- **apl-api seals for you.** `spec.encryptedData` takes **plaintext** on the way in and comes back
  sealed. Verified end to end: `{"token":"probe-value-123"}` posted, and 89 seconds later
  `kubectl get secret agent-cred-test -n team-reviews` decoded to `probe-value-123`. So the seed
  never needs `kubeseal`.
- **Tokens expire fast and the failure is opaque.** A token fetched a few minutes earlier returns
  `401 JWT verification failed: "exp" claim timestamp check failed`. Fetch one immediately before
  each call, as `seed-lib.sh` already warns.

## 13. Proven live end to end — 2026-08-31

The whole chain was assembled and run against the cluster. **Opening a pull request created a
credentialed ephemeral agent node; closing it destroyed the node.** No new service was written; the
broker is an admin-team workload as designed.

**The pieces, as deployed:**

- **Catalog repo** `team-platform/agent-workflows` (Gitea), two charts under `charts/`:
  `review-agent` (team) and `agent-node-broker` (admin). Pushed with a `dev-platform` PAT.
- **`AplCatalog` `agent-workflows`** pointing at it — so both show in the Console picker. NOTE: the
  catalog `repositoryUrl` pattern **rejects a port and `http://`**, so the in-cluster
  `gitea-http:3000` URL fails validation; use the public `https://gitea.<domain>/...` form, which is
  what Argo already uses for team repos anyway.
- **RBAC** (`turnstone` ns): a `Role` (deployments+services+secrets+pods) bound ONLY to
  `team-admin`'s `sa-team-admin` and `tekton-triggers-team-admin`. `team-reviews` has no turnstone
  rights — verified with `kubectl auth can-i`.
- **`review-agent`** workload in `team-reviews`: an EventListener with two triggers — `pull_request`
  `opened/reopened/synchronized` → forward `provision`; `closed` → forward `teardown` — each a
  PipelineRun that curls the broker sink.
- **`agent-node-broker`** workload in `team-admin`: an EventListener (`provision`/`teardown` CEL on
  `body.action`) whose pipelines create/delete the node. Create derives the node from the running
  `turnstone-server` via `kubectl get ... -o json | jq`, swaps in the team `ci-runner` image, mounts
  the shared `agent-<team>-creds` secret at the six credential paths, and adds a `clone-pr`
  initContainer that checks out the PR branch into an `emptyDir`.
- **Webhook**: a `pull_request` hook on `team-reviews/reviews` → `el-review-agent` sink. Registered
  by hand (still no platform object for this — §8).
- **Netpol**: `AplTeamNetworkControl` on `team-admin` admitting `team-reviews` to the broker EL pods
  (selected by the plain `eventlistener` label — the API rejects a `toLabelName` containing `/`, so
  `app.kubernetes.io/managed-by` cannot be used).

**Verified:** PR #1 opened → `turnstone-node-reviews-pr1` came up `2/2`, checked out to the
`agent-demo` branch (HEAD "agent demo edit"), `tea` logged in as `agent-reviews`, `logs` returning
Loki lines. PR #1 closed → teardown pipeline deleted the node. At rest: **zero** ephemeral nodes,
`turnstone-server` untouched.

**Traps hit while wiring it, all fixed:**

- **Mesh vs Tekton.** Forward/provision/teardown PipelineRuns carry `sidecar.istio.io/inject:false`
  (a mesh sidecar never terminates, so the run hangs). The mesh is **PERMISSIVE** (no
  PeerAuthentication anywhere), so a mesh-off task can still reach the in-mesh broker EL — no mTLS
  wall.
- **`git clone` into an `emptyDir` needs `safe.directory`.** The clone runs as a different UID than
  the volume owner, so git 2.x refuses with "dubious ownership". Added `[safe] directory = *` to the
  mounted gitconfig. Also make the clone idempotent across init-container restarts
  (`cd dir; find . -mindepth 1 -delete; git clone . `) — a partial clone survives a restart in the
  same pod's emptyDir and fails the next attempt with "already exists and not empty".
- **Pod cap.** kind/kubeadm defaults the kubelet to **110 pods** per node; ephemeral environments
  blow through it fast (a per-PR node plus its build/run pods on top of the platform + demo teams),
  and over the cap new pods get `FailedScheduling: Too many pods` or are killed (exit 137). **Raised
  to 250** on 2026-08-31 (the node's pod CIDR is a /24, ~254 usable, so that is the ceiling) and
  persisted in `.taskfiles/kind/cluster-config.yaml`, wired into `cluster:up`. The host still swaps,
  so keep concurrency sane and sweep `Completed` PipelineRun pods; but the hard scheduling wall is
  gone.

**Still live-only (persistence backlog):** the Gitea catalog repo, the `AplCatalog`, both workloads,
the turnstone RBAC, the shared `agent-reviews-creds` secret, and the webhook are all hand-made and a
rebuild loses them — the same "Surviving a rebuild" gap as `TEAM-WORKLOAD-CATALOG.md`. The per-PR
**app** environment is not built by the chain yet (it would need a PR-branch image build, which is
currently blocked by the pinned gradle/JDK jar bug); the node reaches the team's existing app
instead. Per-PR Gitea token minting is also deferred — every node mounts the shared team agent
credential.

## 14. Second team, self-service via the Console — proven, with the traps that cost the session

On 2026-08-31 a **different** team (`prodpage`) self-served the workflow: a `prodpage` dev picked
`pull-request-agent` from the catalog in the Console, deployed it, opened a PR on
`team-prodpage/productpage`, and got a credentialed ephemeral agent node running **prodpage's own**
toolchain. This section is everything learned making that work — most of it applies to any team.

### 14a. The chart is zero-config now

`review-agent` was renamed to **`pull-request-agent`** and made parameter-free for the standard
(seed) layout:

- **team** is derived from the namespace it deploys into (`{{ .Release.Namespace }}` → `team-prodpage`),
  not a value. So the EventListener SA, the forwarded `team`, and the node image all follow the
  namespace.
- **repo to watch** is auto-detected at hook time: the webhook-registration Job lists the team's
  Gitea org and picks its single repo (`team-prodpage/productpage`). Override with a `repo:` value
  only if an org has more than one.
- **node image** defaults to `harbor.<domain>/team-<team>/ci-runner:main` (the team's own runner =
  agent node, §18 of `AGENT-ENVIRONMENTS.md`). `nodeImage` is an optional override, not shown.

`values.yaml` therefore shows only `brokerSink` and `giteaUrl` (both real infra endpoints, no empty
fields). **Console UX note:** the values box shows `values.yaml` verbatim, so never leave empty
"fill me in" fields there — derive them or comment them. And the **workload name is capped at 16
chars** — `pull-request-agent` (18) is rejected; name the workload `pr-agent`.

### 14b. Webhook auto-registration: in-mesh Job + public URL (the mesh-off dead-end)

The hook that registers the `pull_request` webhook is a Helm `post-install`/`post-upgrade` Job
(Argo runs it as a PostSync hook). Getting it to reach Gitea was the single biggest time sink:

- **gitea's internal Service is firewalled from team namespaces.** A pod in `team-prodpage` cannot
  reach `gitea-http.gitea.svc:3000` — mesh-off gets `000`, and **even in-mesh it times out**. Gitea
  only answers the mesh on its public gateway route.
- **The path that works is the public URL through the gateway** — `https://gitea.<domain>` with
  `-k` — exactly how the agent nodes reach Gitea. So the hook Job must run **in the mesh** and use
  the public URL. It's given `giteaUrl` as a value for that.
- **Do not set `sidecar.istio.io/inject:false` on the hook** (my first version did, and it failed
  with `000`). Team namespaces inject a **native** istio sidecar (init container, `restartPolicy:
  Always`), which **terminates when the Job's main container exits**, so the Job completes cleanly —
  no hang, no `quitquitquit` needed (it's kept as a belt-and-suspenders for a classic sidecar).
- The hook authenticates with the team's own `gitea-credentials` secret (org bot,
  `organization-team-<id>`, verified repo-admin) via **basic auth over the public URL** — this is
  the one place basic auth is used, and it's the org bot's local credential, not an OIDC identity.
- One `pull_request` webhook covers **both** open (provision) and close (teardown); the
  EventListener routes on `body.action`.

Reliable webhook registration otherwise (by hand) is `kubectl exec` into the gitea pod against
`localhost:3000` — that bypasses all netpols and is what the seed should keep for its own setup.

### 14c. `HOME` must be set on the node or every mounted config is invisible

The node runs as **UID 1000 with no `/etc/passwd` entry**, so `$HOME` defaults to `/`. Every tool
then looks for its config in the wrong place — `git` reads `//.gitconfig` (fails, "dubious
ownership" and no credential helper), `tea` reports `unable to get or create config file`,
`vikunja-cli` can't find its `config.toml`. The mounts at `/home/gradle/...` are correct; the tools
just never look there. **Fix: set `HOME=/home/gradle` in the node container env** (now in the broker's
create-node). This one missing env var makes the whole toolset look broken. Symptom to recognise:
`whoami: cannot find name for user ID 1000`.

### 14d. The credential model (settled with the user)

`agent-creds` — an **AplTeamSecret**, visible in the team's Console Secrets view, **seeded once per
team**, holds the agent's identity plus the two CLI tokens, each exactly once:

```
agent-username    the agent's Keycloak login (agent-<team>@<domain>)
agent-password    the agent's Keycloak password (persisted for OIDC contexts, even if unused now)
gitea-token       a Gitea PAT  — tea/git cannot do OIDC, so this is persisted
vikunja-token     a Vikunja API token (tk_...) — vikunja-cli cannot do OIDC, so this is persisted
```

Reasoning that took several wrong turns to land:

- **The platform is OIDC-only; basic auth fails everywhere** except the gitea org-bot local
  credential (§14b). So username+password is the agent's real identity.
- **But the CLIs don't do the OIDC flow.** `tea` takes only a PAT; `vikunja-cli`'s `auth login` is
  local-auth (fails for OIDC accounts) — its token is obtained by an OIDC round-trip done *outside*
  the CLI. So the two tokens **must be persisted**; they can't be derived at runtime by the CLIs.
- **Do not store a Vikunja OIDC JWT** — it's short-lived and expired mid-session. Mint a long-lived
  **Vikunja API token** instead (`vikunja-cli tokens create --title … --expires-at 2030-… --permissions <all>`,
  permissions built from `/api/v1/routes`; equivalently `POST /api/v1/tokens`). It's the
  Vikunja equivalent of a Gitea PAT, prefixed `tk_`, and works in `config.toml`'s `token` field.
- **Loki is NOT in `agent-creds`.** It's a per-*team* Loki **tenant** password (Loki is
  multi-tenant; a reverse proxy in `monitoring` maps username→tenant, table in the
  `reverse-proxy-auth-config` secret, plaintext). The broker reads it from `monitoring` at
  provision and injects it — it's a team data-plane credential, not the agent's.

### 14e. The broker GENERATES the node config; it does not copy pre-baked files

Earlier I stored six ready-made config files in the secret, smearing the same token across
`git-credentials` + `tea-config` + `gitconfig`. Now the secret holds only raw values, and the
broker's provision pipeline **generates** the six node files at provision time
(`gitconfig`, `git-credentials`, `tea-config.yml`, `vikunja-config.toml`, `loki-username`,
`loki-password`) from: the team's `agent-creds` (gitea/vikunja tokens), the Loki tenant password
read from `monitoring`, and derived values (gitea login slug =
`agent-<team>-<domain-with-dots-as-dashes>`, urls from `domain`, loki-username = team). It writes
`turnstone/agent-<team>-creds`, which the node mounts.

Broker RBAC, all scoped:
- `turnstone`: create/update Deployment, Service, **Secret** (the generated node creds).
- team namespace: **get only `agent-creds`** — granted by the *team's own chart*
  (`broker-read-agent-creds` Role), so deploying the workflow self-authorizes the broker.
- `monitoring`: **get only `reverse-proxy-auth-config`** (the Loki tenant passwords).

### 14f. Per-team prep that the catalog deploy does NOT do (today)

For a new team, before its PR can spin up a working node, these must exist (the seed will own them):
1. the team's `ci-runner` image in Harbor **and its Harbor project flipped public** (nodes in
   `turnstone` pull anonymously). `prodpage`'s project was private and had to be flipped.
2. `agent-creds` (the four keys above) in the team namespace.
3. the broker netpol admitting the team (`AplTeamNetworkControl` on `team-admin` — `toLabelName`
   can't contain `/`, so select the EL by the plain `eventlistener` label).

### 14g. Operational traps seen this session

- **Argo won't hot-reload an existing workload app to a new chart commit** — `syncedRev` stays
  empty and it keeps rendering an old commit. A **fresh deploy** (delete + recreate the workload)
  applies the current chart cleanly. Iterate by redeploying, not by pushing and waiting.
- **Catalog listing is cached** — after changing a chart, click **REFRESH CHARTS** or the Console
  hands you the stale tile, and a workload created from it points at the old chart path (Argo then
  reports `app path does not exist`).
- **Delete+recreate can deadlock** — the team AppProject drops a repo from `sourceRepos` when its
  last workload referencing it goes away; recreate races the project update, the new app sits
  `InvalidSpecError: repo not permitted`, and its finalizer blocks the team-ns app. Break it by
  removing the stuck app's finalizer (`kubectl patch application … -p '{"metadata":{"finalizers":null}}'`).
- **A PR fires `opened` AND `synchronized`**, so two provisions used to race on the same node.
  **Fixed**: the provision trigger's CEL now matches only `opened`/`reopened`, so one PR open =
  one node. Trade-off: pushing new commits to an open PR no longer refreshes the node's checkout
  (the node reflects the PR at open time); revisit if per-push refresh is wanted.
- **Pod cap** was raised 110→250 (`.taskfiles/kind/cluster-config.yaml`), and finished
  PipelineRun pods still need sweeping.
- **Gradle 'invalid CEN header (bad header size)'** — the default `gradle:8.13.0-jdk8` (jammy)
  fails `gradle build` reading Gradle's own jars (JDK-8302483 ZIP64 validation vs jammy's zlib).
  The JVM property `-Djdk.util.zip.disableZip64ExtraFieldValidation` does **not** clear this check.
  **Fixed** by pinning both reviews Dockerfiles to `gradle:8.13.0-jdk8-focal` **by digest** — focal
  reads the jars fine with the same JDK 8u442, and `openjdk-21-jre-headless` (checkstyle) installs
  there too. Only reviews is gradle-based; the other teams' toolchains are unaffected.

## 15. Seed persistence — DONE (`seed:agents`)

**Implemented 2026-08-31** as the `seed:agents` task (`.taskfiles/seed.yml`; `demo` now depends on
`agents`, which depends on `vikunja`). A rebuild recreates the whole chain. What it does, in order:

1. **Catalog repo** — pushes the vendored charts (`demo-seed/agent-workflows/charts/{pull-request-agent,agent-node-broker}`)
   to `team-platform/agent-workflows` in Gitea, substituting a `__DOMAIN__` placeholder at push time
   (never a baked domain). Force-push; the seed is the source of truth.
2. **`AplCatalog`** — `agent-workflows`, public `https://gitea.<domain>/...` URL.
3. **Broker** — applies the cross-namespace RBAC (`demo-seed/agent-workflows/rbac/broker-rbac.yaml`:
   `turnstone` Deployment/Service/Secret + `monitoring` `reverse-proxy-auth-config` read, bound to
   `team-admin`'s SAs), deploys `agent-node-broker` as an **admin-team workload** (into `team-admin`),
   and adds the cross-team broker netpol.
4. **Per demo team** — mints the **gitea PAT** (`gitea admin generate-access-token`) and the
   **vikunja API token** (`vikunja_mint_api_token` in `seed-lib.sh` → long-lived `tk_`, all
   permissions from the route inventory; NOT a JWT), writes the `agent-creds` AplTeamSecret
   (`agent-username`/`agent-password` + both tokens), and deploys the `pr-agent` workload (zero-config;
   its PostSync hook registers the `pull_request` webhook itself).

The per-team `ci-runner` image + public Harbor project are already handled by `seed:apps`
(`harbor_make_project_public`). The gradle base is pinned to `-focal` in the reviews Dockerfiles so
`gradle build` works (§14g).

The historical checklist (what it took to get here):

None of it survived a rebuild before — it's all live-only, the same gap as
`TEAM-WORKLOAD-CATALOG.md`. To persist, the seed must:

1. **Catalog repo + entry** — create `team-platform/agent-workflows` (both charts), push, and add
   the `AplCatalog` (public `https://gitea.<domain>/...` URL — the API rejects a port/`http://`).
2. **Broker** — deploy `agent-node-broker` as an admin-team workload; apply the `turnstone` Role
   (Deployment/Service/Secret) and `monitoring` Role (`reverse-proxy-auth-config`) bound to
   `team-admin`'s SAs; add the broker netpol per team.
3. **Per team**: ensure the `ci-runner` image + **public** Harbor project; mint the **gitea PAT**
   and **vikunja API token** (`tk_`) and the Keycloak identity, and write them as the `agent-creds`
   AplTeamSecret (via apl-api, which seals plaintext). Do the gitea/vikunja token minting the
   admin way (gitea `generate-access-token`; vikunja `POST /api/v1/tokens`).
4. **Leave the pull-request-agent chart zero-config** — teams add it from the Console with no
   parameters, and its PostSync hook registers the webhook itself.

The demo teams could have the workflow pre-deployed by the seed, or left for a human to pick from
the catalog (the point of the self-service model). Either way, everything in §14 must be in place
first.
