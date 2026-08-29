# Ephemeral environments for agents

Working notes from standing up the first piece of an AI internal developer platform on this lab:
an ephemeral environment that an AI agent can act on, with the agent running in a Turnstone node
created for that environment.

**Everything below was verified live on 2026-08-29/30** against Turnstone 1.8.1 and the platform at
`bf610ada5`, unless marked otherwise. Where something is unproven it says so. This is a record of
what the platform actually does, not a design — the architecture is still open.

Read `EPHEMERAL-AND-TEAM-WORKLOADS.md` first for the general shapes (Job + TTL, per-team
namespaces, diagnosis order); this file is the Turnstone-and-environments layer on top, and
`research/` holds the underlying code reading with `file:line` citations.

## 1. The target shape

A webhook (a merge request opened, say) triggers a Tekton pipeline. The pipeline creates an
ephemeral environment, creates a Turnstone **node** for it, runs an agentic workload on that node
against that environment, and tears the whole lot down. The agent is one pipeline step among
others, so teardown is the pipeline's job and needs no controller.

One node, one environment, one workstream — ephemeral, gone after the run. Longer-lived
environments are a later problem.

**Concurrency** is deliberately capped: five tickets must not become five environments. The
mechanism chosen for now is a `wait-for-slot` Tekton task (FIFO by `creationTimestamp`, a slot
held only while `completionTime == null`, so a crashed run frees its own slot). Kueue is the
grown-up answer — it has a dashboard (KueueViz) and a Tekton integration via the separate
`tektoncd/tekton-kueue` controller — and is deferred until per-team quotas or a Grafana view
justify two more services.

## 2. A Turnstone node per environment — proven

A node is just another `turnstone-server` process. It self-registers into the `services` table in
Turnstone's Postgres and heartbeats; the console discovers it from there. Nothing needs to be
told about it.

**Derive the manifest from the running `turnstone-server`, do not hand-write it.** Copy the
Deployment and change only name, labels, selector, and add a plain pod label for netpol
selection. That carries across all 20 env vars, both init containers (`build-ca-bundle`,
`wait-for-keycloak`) and the model ConfigMap — every one of which is load-bearing, and several of
which are non-obvious. Node identity needs no templating at all:

```yaml
TURNSTONE_NODE_ID:       {fieldRef: metadata.name}     # node id == pod name
POD_IP:                  {fieldRef: status.podIP}
TURNSTONE_ADVERTISE_URL: http://$(POD_IP):8080
```

Verified: the new node appeared in `services` alongside the original within seconds, the console's
node list showed `NODES · 2`, work routed to it, and its `bash` tool reported its own pod name and
IP matching its registration row exactly.

## 3. Put the node in the `turnstone` namespace, not the team's

The obvious placement — a node inside `team-<id>` alongside the environment — requires copying
`TURNSTONE_JWT_SECRET` and the Postgres password into that namespace. **Do not do this.** That
secret is the platform-wide signing key: anyone holding it can mint a valid token for any user,
any role, on any node.

It is worth being precise about why this differs from everything else a team namespace holds:

| credential | scope | if leaked |
|---|---|---|
| `gitea-actions-runner-token` | that team's repo registration | register a runner for that team; revocable |
| `gitea-credentials` | that team's Gitea account | that team's repos |
| `harbor-push/pullsecret` | that team's Harbor project | that team's images |
| `kubectl-token` | that namespace's ServiceAccount | that namespace |
| **`TURNSTONE_JWT_SECRET`** | **the whole Turnstone estate** | **mint a token as any user, any role, on any node** |

Every credential the platform already distributes is capability-scoped and independently
revocable. The Turnstone one is not, so keep it where it already is: run the node in `turnstone`
and let it *act on* the environment in the team namespace. Nothing is copied, and the console
reaches the node intra-namespace so no NetworkPolicy is needed for that hop at all.

The residual risk is honest and unsolved: nodes still share a namespace and a signing key with
each other, so node-to-node isolation is network-level only. Turnstone gaining per-node identity
is what actually fixes it. Giving each node its own ServiceAccount plus a matching Istio
`AuthorizationPolicy` is the compensating control — an Istio SPIFFE identity is a real boundary,
where `target_node` is only placement.

## 4. Per-node config is a real tenancy lever

Turnstone's `config.toml` is mounted per node, so **anything it configures can differ per node**.
The sections it accepts include:

```
[model]  [models.*]  [mcp]  [mcp.servers.<name>]  [mcp.servers.<name>.env]
[tools]  [security]  [auth]  [oidc]  [oidc.role_map]  [api]  [console]  [database]
```

This matters because Turnstone has no working tenant concept below a thin "Projects" layer — the
`mcp_servers` and `model_definitions` tables have no tenant column at all (see
`research/turnstone-rbac-and-tenancy.md`). A per-team node with its own config recovers much of
that **through deployment rather than through the schema**: that team's MCP servers, with that
team's credentials, its own model set, its own tool policy.

Proven for models: a second ConfigMap giving one node `claude-haiku-4-5` alongside the default
took effect on that node only, and the console's model picker showed it for conversations landing
there. A cheap model for trivial agent work — "which node am I on", "is this tool wired up" — is
worth having, since on a lab that is most of the traffic.

Note the delivery detail: the shared `turnstone-model-config` ConfigMap is Argo-managed, so
patching it is reverted by `selfHeal`. A node we create ourselves is not Argo-managed, so it keeps
its own ConfigMap. That asymmetry is the whole trick.

## 5. Secrets and the agent's shell

Turnstone scrubs its subprocess environment (`turnstone/core/env.py`, `scrubbed_env()`), so an
agent's `bash` tool **cannot** read the signing key — `env | grep -c TURNSTONE_JWT_SECRET` returns
`0` while `echo $TURNSTONE_NODE_ID` still works. This was tested directly rather than assumed,
because the opposite would have been serious.

But it is a **denylist**, not an allowlist. It strips names ending in `_KEY`, `_SECRET`, `_TOKEN`,
`_PASSWORD`, `_CREDENTIAL`, `_CREDENTIALS`, plus an explicit list (`TURNSTONE_JWT_SECRET`,
`ANTHROPIC_API_KEY`, `TURNSTONE_DB_URL`, and others). **Anything we add later that does not match
a pattern reaches the agent's shell.** A per-team credential named `GITEA_PAT` leaks; named
`GITEA_PAT_TOKEN` it does not. Turnstone's own documentation says to keep such secrets in
`config.toml` rather than the environment, precisely because an in-process LLM with shell access
can read `os.environ` — and `config.toml` is the per-node file from §4.

## 6. Reaching the environment: front door only

Measured from an agent on a node, against a team's app:

| target | result |
|---|---|
| `https://app-reviews.<domain>/` (public hostname) | reachable — `404` at `/` is Bookinfo answering, it serves `/reviews/<id>` |
| `http://app.team-reviews.svc.cluster.local:9080/` | **blocked** |

So an agent reaches team workloads exactly like an external client, through the gateway. The
in-cluster path is denied because `team-<id>` admits only `istio-system`, `knative-serving`,
`monitoring/prometheus` and `tekton-pipelines` — plus whatever `AplTeamNetworkControl` adds.

**A NetworkPolicy denial here does not look like a denial.** The packets are dropped, so the
sidecar's upstream connect times out: DNS resolves, TCP connects to the *service* IP, the request
is sent, and ~30 seconds later Envoy returns `503 upstream connect error ... connection timeout`.
"The app is slow", "the app is down" and "the app is unreachable by policy" are indistinguishable
from the client. Check policy before chasing the workload.

## 7. `AplTeamNetworkControl` accepts any namespace

The platform's own netpol API takes a plain namespace string, not a team reference:

```json
{"kind":"AplTeamNetworkControl","metadata":{"name":"allow-turnstone"},
 "spec":{"ruleType":{"type":"ingress","ingress":{
   "toLabelName":"turnstone-node","toLabelValue":"tsnode",
   "mode":"AllowOnly","allow":[{"fromNamespace":"turnstone"}]}}}}
```

Verified accepted (HTTP 200) and rendered for a platform namespace, not just `team-*`. This is the
right way to open a path: it goes through the platform's API, shows up in the Console mapped like
any other netpol, needs no fork of `charts/team-ns`, and — unlike a chart change — takes effect on
a running cluster, since `charts/` renders from GitHub at the pinned `APPS_REVISION`.

Two traps, both of which cost time:

- **`toLabelValue` must not be `"true"` or `"false"`.** It is written into
  `podSelector.matchLabels` and coerced to a YAML boolean, after which Argo refuses the patch with
  `.spec.podSelector.matchLabels.<name>: expected string, got true` and the object never appears.
  Use a non-boolean value (`tsnode`, `bkflag`). This is the seed's documented trap 4 and it was
  still walked into.
- **The rendered name is `<name>-ingress-allow-only`**, not what was POSTed.

## 8. apl-api returning 200 does not mean the object exists

A `POST` to apl-api writes to the values repo. Argo then has to notice, render and apply. In
practice that took ~2 minutes, and while a *previous* render was failing, the app sat `OutOfSync`
retrying the **stale** manifest — so the error message described the old problem for minutes after
it was fixed. Automation must wait on the rendered Kubernetes object, never on the API's status
code. `kubectl annotate application <app> argocd.argoproj.io/refresh=hard` forces a re-read when
debugging.

## 9. An ephemeral app instance — proven

A second instance of a team's application, with its own public hostname, is two API calls: a
workload cloned from the existing one, and a service. Both are ordinary platform objects, visible
in the Console.

```
deployment/pr-demo   2/2
service/pr-demo      9080
httproute/pr-demo    ["pr-demo-reviews.<domain>"]
```

Verified externally: `/health` → `200 {"status": "Reviews is healthy"}` and `/reviews/1` → `200`
with `"podname": "pr-demo-..."`, i.e. genuinely the ephemeral pod and not production's. The
service shape that produces the hostname is
`{ingress: {type: public, useDefaultHost: true}, ingressClassName: platform, port: 9080}` — the
hostname follows the service name, so a service named `pr-demo` becomes `pr-demo-<team>.<domain>`.

## 10. The open blocker for a whole-environment copy

The above is one service. A full Bookinfo environment is four, and they do not fit in one
namespace as things stand:

```
library         public=true
team-admin      public=false
team-details    public=false
team-prodpage   public=false
team-ratings    public=false
team-reviews    public=false
```

Harbor projects are per team and **private**, and `harbor-pullsecret` is team-scoped, so
`team-reviews` cannot pull `team-prodpage/productpage`. A single-namespace environment therefore
needs one of: a Harbor grant (robot account or project visibility), a per-environment pull secret,
or an environment that spans namespaces. Unresolved, and it shapes what the catalog entry in §11
can look like.

## 11. Catalogs are the mechanism for "the entire environment" — not yet built

`research/catalogs-and-workloads.md` establishes that a catalog entry is a chart published
centrally and instantiated per team, that the instantiation is an ordinary Argo `Application` in
the team's namespace, and that the chart may emit **any** object kinds — an earlier worked example
shipped Tekton `Pipeline`, `Task`, `TriggerBinding`, `TriggerTemplate`, `EventListener` and
`NetworkPolicy`, and no Deployments at all.

That is the natural home for "the entire environment": one chart rendering the whole stack plus
its policies, published once, instantiated per merge request with a name prefix and image tags as
values. Two properties of the mechanism matter before relying on it, both from the research:

- a team's copy of a catalog entry is **frozen** at instantiation — changing the central entry does
  not update environments already created
- `syncPolicy.automated.prune` is **false**, so deleting a workload orphans its objects rather than
  tearing them down; ephemeral environments must handle their own cleanup

## 12. Turnstone gaps hit tonight

- **`apl-team-lead` could not approve tool calls.** The approval endpoint gates on the `approve`
  *scope*, and Turnstone derives scopes only from permissions literally named `read`/`write`/
  `approve` or starting with `admin.` (`core/auth.py:_permissions_to_scopes`). The role carried
  `tools.approve`, which matches neither, so every team admin saw the approval prompt, clicked it,
  and got a silent `403` — the tool never ran and the conversation hung with no error shown. Fixed
  by adding a bare `approve` in `values/turnstone/turnstone-raw.gotmpl`. Note `SETUP.md`'s
  verification step 17 asserts this works, which was not true on 1.8.1.
- **`/node/<node-id>/` is not a human entry point.** It serves the UI, and most calls succeed, but
  `GET /v1/api/events/global` requires the `service` scope by design — the code comment says an
  authenticated end-user must not subscribe. A browser there gets a permanent `403` on that
  stream. Use the console's own URL and let it route.
