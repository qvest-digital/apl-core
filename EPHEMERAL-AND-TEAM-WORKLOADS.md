# Ephemeral and per-team workloads on this platform

What was learned building the demo teams' CI runners: how to run a pod that exists only while there
is work for it, and how per-team resources actually fit together on this platform. Written after
doing it wrong several times on a live cluster — every claim here was observed, not reasoned about.

`GITEA-ACTIONS-CI.md` is the narrative for the CI runner specifically, with the numbered traps.
This file is the reusable part: the shapes to copy for the *next* ephemeral or per-team workload,
whatever it runs.

## 1. Ephemeral means a Job, never a Deployment

A workload that does one unit of work and exits cleanly cannot be a Deployment.

`CrashLoopBackOff` is not about failure. It is about **repeated restarts** under
`restartPolicy: Always`, and a Deployment forces `Always` onto its pod template — there is no way to
set anything else. So a process that exits `0` after each job is restarted, and restarted, and
after a few cycles the pod is in `CrashLoopBackOff` despite never having failed at anything.

Verified on this cluster, because it is counter-intuitive enough to be worth proving:

- a baseline Deployment whose container exits `0` reached 5 restarts and 4 BackOff events
- the same Deployment with `restartPolicyRules` explicitly restarting on exit code `0` reached the
  *same* 5 restarts and 4 BackOff events, and still ended in `CrashLoopBackOff`

`restartPolicyRules` (k8s 1.32+) decides **whether** to restart on a given exit code. It does not
touch backoff accounting. It is not a fix for this.

The shape that works:

```yaml
kind: Job
spec:
  ttlSecondsAfterFinished: 300   # event-driven cleanup, see §2
  backoffLimit: 0                # a pod that cannot start must not become a hot loop
  activeDeadlineSeconds: 3600    # bound one that starts but is never given work
  template:
    spec:
      restartPolicy: Never
```

`backoffLimit: 0` matters as much as the rest. The recovery path for a runner that never registers
is the *next* event, not an immediate retry — retrying in place rebuilds the hot loop the Job was
adopted to avoid.

## 2. Cleanup is event-driven, and it is not your pod's job

`ttlSecondsAfterFinished` is handled by the built-in TTL-after-finished controller: it watches Jobs
and deletes them (and their pods) once they have been finished for the TTL. It is a watch, not a
poll, and it needs no CronJob, no reaper, and above all no cooperation from the workload.

Three approaches were rejected before landing here, and the reasons generalize:

- **a CronJob sweeper** — time-based cleanup for an event-based problem. It runs when nothing has
  happened and lags when things have.
- **the pod deleting itself** — a workload that has to ask the API server to remove it needs
  credentials, needs RBAC, and fails exactly when it is already unhealthy.
- **leaving finished pods to accumulate** — pod replacement does avoid backoff entirely (32 pods in
  120s with `backoff-events=0`), but leaves 32 `Completed` pods behind. Correct restart semantics,
  no cleanup story.

Verified: Job and pod both gone within the TTL of finishing, leaving zero pods at rest.

Deployments and ReplicaSets have no TTL equivalent. That is another reason this shape must be a Job.

## 3. Create pods from events, not from a replica count

The runner is created by a webhook, through Tekton Triggers:

```
webhook → EventListener → (CEL filter) → TriggerBinding → TriggerTemplate → Job
```

`generateName: ci-runner-$(tt.params.runid)-` rather than a fixed `name`: several events can be in
flight at once and each must get its own pod. Two concurrent runners were confirmed working, each
draining its own queued job and cleaning itself up. That is autoscaling a single-replica Deployment
could not do at all, and it costs zero pods at rest.

Filter in the EventListener, not in the workload — a CEL interceptor on
`body.action == 'queued' && "<label>" in body.workflow_job.labels` means an irrelevant event creates
nothing, rather than creating a pod that discovers it has nothing to do.

## 4. The EventListener's ServiceAccount needs explicit rights for what it creates

A TriggerTemplate creating a `Job` requires the EventListener's ServiceAccount to be allowed to
create `jobs.batch` **in that namespace**. It is not implied by the Tekton Triggers roles, which
cover Tekton's own kinds.

The failure mode is the reason this deserves its own section: the EventListener **accepts the
webhook, resolves the parameters, and then logs**

```
jobs.batch is forbidden: User "system:serviceaccount:team-x:tekton-triggers-team-x"
cannot create resource "jobs" in API group "batch" in the namespace "team-x"
```

Nothing surfaces at the sender. Gitea shows a delivered webhook, the run sits `queued` forever, and
it reads exactly like the webhook never arrived or the CEL filter rejected it. **Read the
EventListener's own logs before suspecting the sender.**

Grant it as a namespaced `Role` + `RoleBinding` in the team chart, never by editing an upstream
aggregate ClusterRole — additive, scoped to one namespace, and it survives an upstream sync that
rewrites that ClusterRole. It is not an escalation: the same ServiceAccount can already create
PipelineRuns, which run arbitrary pods under the team's service account.

## 5. Build and CI pods must opt out of the mesh

Anything that installs dependencies from the public internet — `pip`, `bundle`, `npm`, `gradle` —
needs `sidecar.istio.io/inject: "false"` on **the pod template**.

Measured directly, two pods in the same team namespace, same image, same command:

| pod | `curl https://pypi.org/simple/blinker/` |
|---|---|
| default | `HTTP=000`, curl exit 35 |
| `sidecar.istio.io/inject: "false"` | `HTTP=200` |

The platform's own Tekton build pods already carry this annotation
(`charts/team-ns/templates/builds/docker.yaml`), which is why kaniko builds pull public base images
and run `pip install` without trouble. Copy that, and check it first when comparing a failing pod to
a working one: `kubectl get pod <p> -o json | jq .metadata.annotations` answers in one command what
mesh config and NetworkPolicy dumps will not.

What it looks like when missing: five `pip` retries against
`ConnectionResetError(104, 'Connection reset by peer')`, then
`ERROR: No matching distribution found for <pkg>`. The connection is established and then reset, so
it is not DNS and not a NetworkPolicy — a team namespace has **no egress NetworkPolicy at all**, so
that lead is a dead end.

One observation left deliberately unexplained: the blocked pod listed only its own container, with
no `istio-proxy` alongside, yet its egress was still intercepted. Whatever the interception
mechanism, the annotation is what controls it. Do not conclude "no sidecar container, therefore not
the mesh" — that inference cost time here.

## 6. Ingress to an EventListener is label-gated

The team namespace carries `default-from-gitea`, which admits traffic from the Gitea namespace
**only to pods labelled `app.kubernetes.io/managed-by: EventListener`**. An EventListener whose
sink lacks that label is simply unreachable, and the first webhook delivery times out.

When testing a sink by hand, `kubectl port-forward` goes API server → kubelet → pod and **bypasses
NetworkPolicy entirely** — so a replay through a port-forward can succeed against a sink that real
webhook traffic cannot reach. Useful for isolating cause; useless as proof the path works.

## 7. What each team namespace actually contains

Observed on `team-details`, and worth knowing before adding anything:

- **ServiceAccounts** — `sa-team-<id>` (what build pods run as), `tekton-triggers-team-<id>` (what
  EventListeners run as), plus `app`, `kubectl`, `tekton-dashboard`, `default`
- **Roles** — `tekton-triggers-createwebhook-…`, `tekton-triggers-secrets-…`,
  `tekton-triggers-createjob-…` (added by this fork, §4), `tty-admin`, dashboard info
- **NetworkPolicies** — `default-ingress-deny`, `default-ingress-platform`, `default-from-gitea`,
  plus one per allowed cross-team caller. **No egress policy** — egress is governed by the mesh.
- **Tekton Triggers** — one EventListener per event source, each with its own TriggerBinding and
  TriggerTemplate. Builds and CI runners are separate listeners on purpose: the build webhook is
  push-only and the runner webhook must not be, so they cannot be merged.

Workloads are delivered as an `AplTeamWorkload` pointing at a chart path in the **team's own Gitea
repo** (`chartProvider: git`, `path: .gitea/runner/chart`, `revision: main`), which Argo then syncs.
That is what makes a team able to iterate on its own workload without touching this repository.

## 8. Two ordering hazards, both timing-dependent

**A push that ships a chart also triggers the CI that depends on it.** Gitea starts the run in about
a second; Argo needs a few more to apply the new chart. A run starting inside that window executes
against the *previous* template. Observed: run started `20:56:52Z`, chart applied `20:56:58Z`, run
failed for want of an annotation the new chart adds — and the next run on the same commit passed.

Note what does *not* protect against this: waiting for the EventListener Deployment to become
Available proves a sink is answering, **not** that it is answering with the current template. Those
are different facts, and only the second decides what the pod looks like. Wait for the workload's
Argo app to report `Synced`.

**A webhook that fires once is a single point of failure.** Gitea sends `workflow_job` exactly once
and **never retries** a failed delivery. Any delivery lost because the listener did not exist yet,
was restarting, or was unreachable, is lost permanently — the run sits `queued` forever. A
listener-side replay path (list queued runs, POST a synthetic payload to the sink) is therefore
permanent infrastructure, not bootstrap scaffolding.

## 9. Getting a Gitea credential, for automation

Not "log in and copy a token from the UI" — that is the human route.

```sh
kubectl exec -n gitea deploy/gitea -c gitea -- \
  gitea admin user generate-access-token -u <login> -t <unique-name> --scopes <csv> --raw
```

No session, no SSO, no browser. `-u` takes Gitea's **login name**, which for OIDC-provisioned users
is the email with `@` and `.` replaced by `-` (`dev-details-172-18-255-200-nip-io`), not the email —
`gitea admin user list` prints the real ones. Token names must be unique per user.

What genuinely does not work: an OIDC/Keycloak bearer token as an API credential, and HTTP basic
auth with the platform password (`401` — these accounts hold no local Gitea password). SSO login is
still required for a different purpose: it provisions the account and re-syncs its org/team
membership from the JWT `groups` claim, on **every** login.

> ### RULE — do not break this one
>
> **The platform identity is the credential, and the OIDC *flow* is how you present it.** Every app
> here federates to the same Keycloak realm, so `platform-admin` already **is** an admin in Gitea,
> Harbor, Vikunja and Turnstone — the identity the Console's apps page signs you in with. Reach an
> app's API by completing its authorization-code round trip with a cookie jar and keeping the
> session/JWT that lands there: `gitea_oidc_login`, `vikunja_oidc_login`, or Turnstone's
> `GET /v1/api/auth/oidc/authorize` (all `.taskfiles/seed-lib.sh` shape). Copy one; never invent a
> flow.
>
> **Do not** reach for a per-app bootstrap admin password out of a Kubernetes Secret because the app
> "has its own admin". **Do not** conclude an API is closed because a raw Keycloak bearer returned
> `401` — a raw bearer is not the OIDC flow. (Harbor is the lone app that also accepts one.)
> **Do not** test auth against an endpoint that answers anonymously; use an admin-only endpoint and
> run a bogus credential as a control. Both of those bad tests produced confidently wrong
> conclusions on 2026-08-30. Full rule in `CLAUDE.md`.



## 10. Diagnosis order, when an event-created pod misbehaves

Cheapest-first, each step ruling out a whole class:

1. **Did the object get created?** `kubectl get jobs -n team-<id>` — if not, read the
   EventListener's logs (§4). A `403` there looks exactly like a webhook that never arrived.
2. **Does the live template match the chart?** `kubectl get triggertemplate -n team-<id> -o json`
   — if not, the workload's Argo app has not synced (§8).
3. **Does the chart even reach the cluster?** For anything under `charts/`, Argo renders from the
   *public GitHub repo* at the pinned revision, so an edit that is uncommitted, or committed but not pushed, is invisible no
   matter how correct it is. `git diff <targetRevision> -- charts/<name>` answers it. This is in
   `CLAUDE.md`'s traps, and it is the single most expensive mistake made this round.
4. **Compare pod annotations against a working pod** before mesh config or NetworkPolicies (§5).
5. **Only then read the workload's own logs.**

The pods vanish on their own, which is the point of them — so capture what you need *while the pod
exists*, or raise `ttlSecondsAfterFinished` temporarily while debugging. More than one
investigation here was slowed by the TTL doing its job correctly.
