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
