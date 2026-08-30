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

## 10. A whole-environment copy — solved by making Harbor projects public

A full Bookinfo environment is four services owned by four teams, and it originally would not fit
in one namespace: Harbor projects are created **private** and `harbor-pullsecret` is team-scoped, so
`team-reviews` could not pull `team-prodpage/productpage`.

The fix chosen is the same one already applied to Gitea: in this demo lab "public" means *company
internal*, so a read-only public project is the right visibility. Every project is now public:

```
library  team-details  team-prodpage  team-ratings  team-reviews   -> all public=true
```

With that, a single namespace can run the whole environment, and `team-reviews` hosts all four
`env-demo-*` services.

**This is not yet in the seed.** It was applied live. `.taskfiles/seed-lib.sh` already carries an
unused `harbor_ensure_project` helper that creates projects with `"public":true` — folding it into
`seed:apps` is the outstanding work, and until then a rebuilt lab returns to private projects and
this blocker comes back.

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

## 13. The full loop, proven end to end

On 2026-08-30 an agent running on an ephemeral node did what a human developer does, and the change
was visible in a browser. Every step was performed by hand — nothing is wired to a trigger yet — but
each one is now known to work:

1. mint a scoped Gitea token for the team's `agent-<team>` user (§14)
2. create the node with that credential mounted as a file (§14)
3. the agent clones, edits, commits, pushes a branch, and opens a pull request
4. the team's existing merge gate runs on the PR — unchanged, no special casing
5. build an image from the PR branch (§15)
6. repoint the environment's workload at that image through apl-api (§15)

The result, same page, two environments, differing only by an open pull request:

| | reviewers rendered |
|---|---|
| ephemeral `env-demo` (PR #3) | `Alice`, `Bob` |
| production `app` (`main`) | `Reviewer1`, `Reviewer2` |

`main` was never touched and the PR stayed open throughout. A second push to the same branch
updated the existing PR rather than opening a new one — the behaviour wanted for production,
working without extra effort.

## 14. Giving the agent a forge identity

**Use the team's `agent-<team>` user, not the org bot.** Every team namespace already holds
`gitea-credentials` for `organization-team-<id>`, which is tempting and wrong: commits must be
attributed to the agent for the demo to mean anything, and the blast radius of a leaked credential
should be one team member.

But note what is *not* true: `agent-<team>` is **not** less privileged. Its token reports
`{"admin": true, "push": true, "pull": true}` on the team's repo, because on this platform every
team member lands as an org owner. **What bounds the agent is token scope, not user identity.**
Mint with `--scopes write:repository` and verify the bound holds — `GET /api/v1/user` returns `403`,
because that needs `read:user`.

The gate itself is safe against a direct push regardless: `enable_push:false` with no whitelist
(`.taskfiles/seed-lib.sh`) refuses everyone, owners included.

**Token lifecycle.** Mint per environment, name it after the environment (`agent-<envid>`), revoke
at teardown. `gitea admin user generate-access-token` takes `--username`, `--token-name`,
`--scopes`, `--raw` and **no expiry option** — tokens live until explicitly revoked. So the security
property depends entirely on teardown running, which is exactly the step that gets skipped when a
run fails or a cluster is rebuilt. Treat a sweeper that revokes `agent-env-*` tokens whose
environment no longer exists as permanent infrastructure, not scaffolding — the same reasoning as
the lost-webhook replay path in `EPHEMERAL-AND-TEAM-WORKLOADS.md` §8.

**Deliver the credential as a file, never an environment variable.** Turnstone strips every variable
matching `_TOKEN`, `_PASSWORD`, `_CREDENTIAL(S)`, `_KEY`, `_SECRET` before every subprocess (§5), and
the `passthrough=` escape hatch in `scrubbed_env()` has **no production caller** in 1.8.1 — its only
use in the tree is a unit test. A `GITEA_TOKEN` in the pod env is simply absent when the agent runs
`git push`, with no error to explain it.

**Do not use `store --file` on a read-only mount.** It authenticates, but git tries to write the
credential back on every operation and emits

```
fatal: unable to get credential storage lock in 1000 ms: Read-only file system
```

— a second of latency and the word `fatal` in the agent's output while the command actually
succeeds, which is precisely the kind of thing that derails an agent. A read-only helper avoids it:

```
[credential]
	helper = "!f() { printf 'url=%s\n' \"$(cat /etc/turnstone-git/credentials)\"; }; f"
[user]
	name = agent-<team>
	email = agent-<team>@<domain>
[http]
	sslVerify = false
```

Mount the credential outside `$HOME` (`/etc/turnstone-git`) and the gitconfig into `$HOME` via
`subPath`, so the volume does not shadow the home directory. `HOME` is on Turnstone's safe list, so
this survives scrubbing; `GIT_CONFIG_GLOBAL` is explicitly scrubbed, so the config must live at the
default path and cannot be pointed at by an env var.

**The file is readable by the agent, and that is the point to be honest about.** The node image
ships no forge CLI — no `gitea`, no `gh`, no `glab`, only `curl`, `jq`, `git` and `python3` — so
when the agent created and closed pull requests it did so by reading the token out of
`/etc/turnstone-git/credentials` and calling the REST API with `curl`. File delivery is not
confinement. The scope on the token is the only real boundary.

That hand-rolled shape is also why a **forge tool, packaged as a Turnstone skill**, is the next
piece of work: tool calling instead of improvised HTTP, for token efficiency and a reviewable call
surface. It is a separate thing from the general-purpose `gitea-mcp` server in `MCP.md`; do not
conflate them.

## 15. Building and deploying a pull request branch

**A hand-written PipelineRun needs the mesh opt-out as a `label`.** The first branch build died with
kaniko unable to reach Docker Hub — `BlackHoleCluster ... index.docker.io` in the istio-proxy log,
`build-push` `StepFailed`, `fetch-source` green. `charts/team-ns/templates/builds/docker.yaml:119`
puts `sidecar.istio.io/inject: "false"` in the PipelineRun's **labels**, and Tekton propagates it to
the pods. This is `EPHEMERAL-AND-TEAM-WORKLOADS.md` §5 resurfacing in a new place: there the
annotation goes on a pod template, here it must be a label on the run.

The team's `Pipeline` hardcodes `revision: main` and the `:main` tag, so a branch build means a
one-off `PipelineRun` with an inline `pipelineSpec` copied from it, with `revision` and `IMAGE`
overridden and every other parameter — the `--build-arg`s especially — left alone.

**Tag by commit SHA, not by branch name.** A branch-named tag is mutable, and this bit immediately:
a build launched before a fix landed finished afterwards and left the broken commit sitting under
the tag a later build expected. Pinning the tag to the SHA makes an environment reference an exact
revision and makes a late-finishing build harmless.

**Change the environment's image through apl-api, never `kubectl patch`.** The `env-demo-*`
deployments carry an Argo tracking-id and are Helm-managed by the central `k8s-deployment` chart, so
a direct patch is reverted by `selfHeal`. The image lives in `spec.values` on the `AplTeamWorkload`:

```
GET  /api/v2/teams/<team>/workloads/<name>     # spec.values holds image.repository / image.tag
PUT  /api/v2/teams/<team>/workloads/<name>     # same object, tag replaced
```

A `PUT` returned `200` and Argo rolled the new pods within 60 seconds. This is `CLAUDE.md` rule 6
holding up in practice, and it has a second benefit: the change is a normal, Console-visible
workload edit rather than a live-only hack.

## 16. What the environment caught that the merge gate could not

Two agent changes passed compile and lint and would have passed the merge gate, and both were only
observable by running them. This is the argument for ephemeral environments, stated in evidence
rather than in principle.

**A change with zero runtime effect.** Asked to make the review stars green, the agent changed the
Java fallback:

```java
System.getenv("STAR_COLOR") == null ? "green" : System.getenv("STAR_COLOR")
```

But `Dockerfile:41` is `ENV STAR_COLOR=${star_color:-black}` and the team's build passes
`--build-arg=star_color=red`, so `STAR_COLOR` is always set and the new default is dead code. The
stars stay red.

The general lesson is sharper than the bug: **`star_color` is configured in the `AplTeamBuild`, which
lives in the platform values, not in the repository.** An agent that can only see its checkout will
confidently produce a correct-looking change to something configured outside it. Either build
arguments move into the repo, or the agent needs visibility into the build configuration.

**Malformed output that compiles.** Asked to rename the reviewers, the agent dropped a trailing
comma:

```java
result += "  \"reviewer\": \"Bob\"";        // was: \"Reviewer2\",
result += "  \"text\": \"Absolutely fun and entertaining...\"";
```

Java concatenates strings happily, so this compiles, lints and passes CI, and emits
`"reviewer": "Bob"  "text": ...` — invalid JSON that breaks only when productpage parses the
response. Correcting it and pushing to the same branch updated the existing PR in place.

## 17. The agent can read the whole environment's logs — proven, with a demo

An agent on an ephemeral node can query the logs of **every service in its environment, including
the ones belonging to other teams**, with no special grant. This is the single most useful
capability found so far, and it needs no per-service instrumentation.

### How the logs get there

`promtail` is vestigial on this platform — `values-schema.yaml:2368` and
`helmfile.d/snippets/defaults.yaml:901` declare it with `enabled: false`, but there is **no chart
for it and no Console tile**, so it cannot be switched on and does not need to be. Enabling Loki
brings up an **OpenTelemetry Collector daemonset** (`platform-logs`, namespace `otel`) which reads
`/var/log/pods/*` and routes by namespace:

```
file_log → k8s_attributes → routing connector
  resource.attributes["namespace"] == "team-reviews"  →  X-Scope-OrgID: reviews
```

So a team's logs land in that team's own Loki tenant, automatically. Everything not matching a team
namespace goes to tenant `admins`.

Two endpoints, and picking the wrong one wastes an hour:

| endpoint | auth |
|---|---|
| `loki-headless.monitoring:3101` | basic auth **only** — a reverse proxy derives the tenant from the username. **Use this.** |
| `loki-gateway.monitoring:80` | basic auth **plus** an explicit `X-Scope-OrgID` header, else `401 no org id` |

The user→tenant table lives in the `reverse-proxy-auth-config` Secret in `monitoring`, one row per
team — as **plaintext** passwords, not hashes.

### Giving the agent access

Same shape as the git credential, and for the same reason: `LOKI_PASSWORD` ends in `_PASSWORD`, so
Turnstone's `scrubbed_env()` strips it and `logcli` would fail with an auth error that looks nothing
like the cause. Mount the credential as a file and ship a wrapper on `PATH`:

```sh
logs                                                    # everything in the namespace
logs '{namespace="team-reviews",deployment="env-demo-reviews"}'
logs '{namespace="team-reviews"} |= "reviews/0"' 50
```

`logcli` (a single Go binary, `LOKI_ADDR`/`LOKI_USERNAME`/`LOKI_PASSWORD`/`LOKI_ORG_ID`) is the
better long-term answer and belongs in the node image; the wrapper needs only `curl` and `jq`,
which the stock image already has.

**Two traps in building that wrapper.** `start_at: "end"` on the collector's `file_log` receiver
means it only reads lines written *after* it started — a freshly enabled Loki looks permanently
broken until something generates traffic, and every tenant returns `{"status":"success"}` with no
data, including tenants that do not exist. And in the script itself, do **not** write
`Q="${1:-{namespace=\"team-reviews\"}}"`: a default value containing `}` terminates the parameter
expansion at its first brace and appends the remainder to the query, producing a malformed LogQL
selector and a `jq` parse error that points nowhere near the cause. Assign the default separately.

### The demo

Prompt, given to the node's own UI:

> You have a `logs` command that queries this environment's logs with LogQL. Run `logs` with no
> arguments first to see what's there. Then curl the productpage a few times, and use `logs` to
> trace one of those requests through the environment. The istio-proxy access lines carry a request
> id — use it to show which services the request hit and in what order, with status codes and
> latencies. Tell me which backends you can see, and whether any of them are services this team does
> not own.

What came back: a rendered request-flow diagram and this table, reconstructed purely from
`istio-proxy` access logs correlated on one request id.

| step | service | endpoint | status | latency |
|---|---|---|---|---|
| 1 | productpage | `GET /productpage?u=normal` | 200 | 183ms |
| 2 | details | `GET /details/0` | 200 | 16ms |
| 3 | reviews | `GET /reviews/0` | 200 | 148ms |
| 4 | ratings | `GET /ratings/0` | 200 | 41ms |

**On `claude-haiku-4-5`, in 6 tool calls, using 12.7% of a 200k context.** Distributed tracing
across four services, with no tracing stack, no instrumentation, and a cheap model — because every
pod's Envoy sidecar already logs the request id, and the sidecar logs are captured for free.

### Two findings from the result

**The ephemeral environment erases the ownership signal.** The agent concluded that all four
services "are owned by this team", because they are all in `team-reviews` with an `env-demo-`
prefix. Read as a statement about the namespace that is correct; read as a statement about the
organisation it is wrong — `productpage`, `details` and `ratings` belong to three other teams and
are only co-located here because an environment is one namespace (§10).

This is the intended trade and it cuts both ways: co-location is exactly what gives the agent
cross-service debugging with no grant, and it is also why the agent cannot tell which backends it
may *change*. An agent asked to fix a bug in this environment would have no signal that three of
these four services are not its to edit. If the pipeline ever lets an agent open PRs against
whatever it debugs, that signal has to be supplied explicitly — the namespace will not carry it.

**Read-only, and on a shared credential.** Unlike the Gitea PAT this is not a per-environment
token: Loki OSS has no token concept, the tenant is chosen by basic-auth username, and the password
is a long-lived per-team value stored in plaintext. A leak means rotating a shared team credential
rather than revoking one environment's. Accepted for now because the access is read-only and
tenant-scoped; recorded here rather than solved.

## 18. The platform agent image — one artifact, two roles

The agent needs Turnstone plus a set of CLIs; the merge gate needs a language toolchain. Making
those two images is a mistake, because they then drift. **One image per team serves both roles**:
it is the team's Gitea Actions CI runner *and* the image its agent node runs, so the agent
reproduces the gate with the same toolchain and the same host-mode workarounds by construction.

### Why the layering is `COPY --from`, not `FROM`

The tempting shape — a platform base image that teams extend — does not survive contact with this
lab. Each team's runner pins a curated upstream toolchain:

```
productpage  python:3.13.3-slim     details  ruby:3.4.3-slim
reviews      gradle:8.13.0-jdk8     ratings  node:21.6-slim
```

None of those are reproducible from Debian apt at those versions, and at least one is a deliberate,
documented version choice. Putting a platform base *underneath* would cost all four pins. So the
platform layer is pulled in instead:

```dockerfile
FROM gradle:8.13.0-jdk8                      # team owns this
COPY --from=harbor.<domain>/team-platform/agent-base:main /opt/platform /opt/platform
ENV PATH=/opt/platform/bin:/opt/platform/python/bin:$PATH
```

Everything under `/opt/platform` must therefore be **relocatable**: it lands on a Ruby, Node or JDK
image that may have no Python at all. That is why Turnstone is installed into a **standalone
CPython** (`astral-sh/python-build-standalone`) rather than a venv over the distro's interpreter — a
venv is bound to its interpreter, and there are four different ones here. The path must stay
`/opt/platform`, because console-script shebangs bake it in.

Verified live on `team-reviews/ci-runner:agent-base-layer` — one image reporting both halves, with
the platform's own Python running on a JDK base that has none:

```
Gradle 8.13 · JDK 8 (default) · JDK 21 (explicit path) · checkstyle.jar
turnstone-server · tea · logcli · vikunja-cli · logs · Python 3.13.15
```

### What is in the layer, and why CLIs rather than MCP

`tea` (Gitea's official CLI), `logcli`, `vikunja-cli`, `gitea-runner`, and the `logs` wrapper — all
static Go except Turnstone. They are baked in **as CLIs the agent calls as tools**, deliberately: a
tool call that shells out to a pinned binary costs a fraction of the tokens an improvised REST
conversation does, and it gives a call surface that can be reviewed. Before this image existed the
agent hand-rolled `curl` against Gitea's API, having read its own credential file to do it.

This is a *separate* concern from the general-purpose `gitea-mcp` server in `MCP.md`; the intended
end state is a forge **skill**, not an MCP client. Do not conflate them.

`vikunja-cli` (jo-nike) was chosen over `vja` because it emits JSON an agent can parse. Vikunja's
own `vikunja` CLI is server administration only, not a user client.

Moving `gitea-runner`, `config.yaml` and `entrypoint.sh` into this layer also **deletes trap 16** in
`GITEA-ACTIONS-CI.md`: they were four byte-identical copies fetched by four concurrent downloads
into one shared path, a race that needed a lock and a PID-unique temp file to survive. Owning them
in one place removes the race rather than guarding it.

### It must live in a normal team, not `team-admin`

`team-admin` looks like the natural owner and is not usable:

- its Gitea org has no human members — only `organization-team-admin` and `otomi-admin` — so
  `platform-admin` is not offered it as a repo owner at all
- the admin team is special-cased throughout, because `team-admin` collides with the `isTeamAdmin`
  group marker (see `CLAUDE.md`); operators deliberately `omit teamConfig "admin"` when looping

A normal team gets everything with no special casing. A team named `platform` was created and every
step worked first time: namespace, Gitea org, Harbor project, coderepo, build, Pipeline,
EventListener. **Its Harbor project must be flipped public** so every team's build can pull the
layer.

### Creating the repo: mirror the seed, do not invent

Costly discovery: **nothing creates the Gitea repository automatically.** `AplTeamCodeRepo` does
not, `apl-gitea-operator` does not (it manages OIDC config and build webhooks only), and
push-to-create is off. The operator will sit in a `createBuildWebHook` error loop against a repo
that does not exist, which reads like a webhook problem and is not.

The seed creates it explicitly, and the order is the content (`seed.yml:678-711`):

1. `gitea_oidc_login` **as the team's dev user** — this provisions the Gitea account *and* its org
   membership from the JWT `groups` claim
2. `gitea_mint_pat`
3. `gitea_wait_for_org_permission … can_create_repository`
4. **`gitea_create_org_repo`**
5. `gitea_unprotect_branch`, then coderepo + build via apl-api, then push

One more step that is easy to miss: a user freshly created through `POST /v1/users` comes back with
`requiredActions: ["UPDATE_PASSWORD"]`, and SSO login fails until `kc_make_password_permanent`
(`seed-lib.sh:81`) resets the credential with `temporary:false` **and** clears `requiredActions` —
`reset-password` alone is not enough.

## 19. What is live-only — the persistence backlog

Everything proven above was done against a running cluster. **None of it is in the seed**, so a
rebuild loses all of it. In rough dependency order:

| change | where | why it matters |
|---|---|---|
| Harbor projects created **public** | `harbor_ensure_project`, already written and unused | without it a single-namespace environment cannot pull the other teams' images, and no team can pull the platform layer |
| `replicaCount: 1` on every workload | wherever the seed POSTs a workload | the `k8s-deployment` chart defaults to **2**, silently doubling every pod on a host that is already swapping |
| a `platform` team + its `dev-platform` user | new, mirrors `setup_team_service` | owner of the shared image |
| `agent-base` repo + build + push | new | the layer does not exist otherwise |
| `COPY --from` in all four runner Dockerfiles | `demo-seed/bookinfo/*/.gitea/runner/Dockerfile` | currently only `reviews`, and only on a branch |
| ordering: `agent-base` before `seed:runners` | `seed.yml` | team builds now depend on the platform image; a missing base fails with a confusing `manifest unknown` |

Note the last row is a genuine new failure mode, and it deserves the same treatment `seed:runners`
already gives the Argo-sync race: an explicit wait, not a hopeful ordering.
