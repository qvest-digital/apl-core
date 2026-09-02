# Agent runtime security audit (2026-09-02)

A live audit of what a **dev/agent node** can see and reach beyond its own ephemeral service.
Context: this is a single-node demo lab; agent nodes run LLM-driven (i.e. prompt-injectable) code
and — by Turnstone's node model — are **full peers** that hold the platform's shared secrets. Nothing
here is an active exploit *on this trusted lab*; it is what would bite the moment untrusted input
reaches a credentialed agent. One fix is shipped; the root-cause fix is **deliberately deferred**
(recorded below, not done).

## What an agent node can see / reach

| Surface | Access | Notes |
|---|---|---|
| Kubernetes API | reachable but **unauthenticated** | SA `turnstone`, `automountServiceAccountToken: false`, no token mounted → no resource access. Can't read PipelineRuns/pods → agents can't self-diagnose builds past logs |
| Own-namespace logs (Loki) | ✅ scoped to own team | tenant-isolated (query for another team → 0 lines); includes its own Tekton build + Actions runner pod logs |
| Other teams' logs | ❌ | Loki tenant isolation holds |
| Own Gitea repo / PRs / Actions | ✅ | PAT scope `write:repository,write:issue,read:user` |
| **Other teams' Gitea repos (code)** | ✅ read | `team-reviews/reviews` → 200. Cross-team code is readable; logs are isolated but repos are not (inconsistent — decide if teams are meant to be isolated) |
| Harbor | reachable, anonymous only | no creds mounted → public projects |
| Other teams' running apps (HTTP) | ✅ | no NetworkPolicy; Istio allowed |
| Public internet | **was wide open → now blocked** | see "Fixed" below |

## ⭐ The critical finding: agent can read the node server's secret env

The agent's `bash` runs at the **same UID (1000) as the node's `turnstone-server` (PID 1)**. So
`cat /proc/1/environ` — run live — returns the server's platform secrets:

- **`TURNSTONE_JWT_SECRET`** — JWTs are **symmetric HMAC (HS256)** and shared across nodes by design
  (`turnstone/docs/security.md`, `doctor.py`). Same key signs *and* verifies → a holder can **forge a
  token for any user/role, incl. `platform-admin`**. Full auth bypass.
- **`POSTGRES_PASSWORD`** — direct login to the shared-brain DB (every org's data).
- **`TURNSTONE_OIDC_CLIENT_SECRET`**, **`ANTHROPIC_API_KEY`**.

Turnstone's env-scrub (`core/env.py`) sanitises the bash **child's** env but the **parent server**
keeps the real secrets in its own `os.environ`; same-UID `/proc/1/environ` bypasses the scrub. The
pod hardening (runAsNonRoot, drop ALL caps, seccomp) is orthogonal — this is same-UID file access,
not privilege escalation.

**Why "limit the agent user" does not contain it:** the leaked items are *platform* secrets, not the
agent's identity. A forged JWT impersonates a *different* user (admin), so scoping `agent-<team>`'s
own role/PAT changes nothing for the JWT/DB leak. (It does help for the agent's *own* Gitea/Vikunja
tokens.)

## Fixed (shipped)

**Egress containment** — commit `9e7bf9702`, `demo-seed/agent-workflows/agent-node-egress.yaml`,
applied by `seed:turnstone-agents`. A scoped Istio `Sidecar` (`workloadSelector turnstone-node=tsnode`
— agent/review nodes only; the hub lacks the label) with `outboundTrafficPolicy: REGISTRY_ONLY`, plus
a `ServiceEntry` for `api.anthropic.com`. The node reaches only mesh-registry services (all platform
apps are registered MESH_INTERNAL) + the LLM; **arbitrary internet is blocked**, so a leaked secret
**cannot be exfiltrated**. Verified live; scoped to 2 pods; reversible. This is the highest-value
control: even though the agent can still *read* the secrets, it can no longer *send* them out.

**Why not OpenShell** (turnstone ships `deploy/openshell/` + `docs/openshell.md`): it must create
user/network namespaces, but the hardened pod denies it — `unshare(CLONE_NEWUSER)` → **EPERM** (dropped
caps). Landlock is available (ABI v9) but netns needs userns. Forcing OpenShell means undoing the pod
hardening. Istio does host-aware egress natively, no in-pod caps — better fit here.

## ⛔ Deferred — root-cause fix (decided NOT to do now, recorded for later)

Egress containment stops *external* exfil but not *internal* lateral movement: `REGISTRY_ONLY` still
permits in-cluster services, so a **forged admin JWT can still reach the console / other nodes** (and
the node's own loopback API). The class of finding is only truly retired by **upstream Turnstone
changes**:

1. **Asymmetric JWT** — nodes hold a *verify-only* public key; only a central issuer signs. Reading
   the node's key material then yields nothing forgeable. Kills the admin-forge path.
2. **Scoped Postgres role per node** — the node connects with a role that can touch only its own
   workstreams, not every org's data. Bounds the DB-password leak.

These are Turnstone-repo work (deliverable via `turnstone-patches`), not apl-core config. Deferred by
decision on 2026-09-02.

## Lower-priority / optional (not scheduled)

- **LLM-proxy sidecar** — scoped out 2026-09-02, **considered and declined** by the maintainer.
  Recorded here so it isn't re-proposed from scratch.
  - *Idea (= k8s-native version of OpenShell's inference routing):* add a small proxy **sidecar
    container** to the node pod that holds the real `ANTHROPIC_API_KEY`; point turnstone-server at
    `http://localhost:<port>` with a **dummy** key (turnstone's CLI supports a dummy key + custom
    `base_url` — `cli.py`) and **remove `ANTHROPIC_API_KEY` from the server container**. The proxy
    injects the real `x-api-key` and forwards (streaming SSE) to `api.anthropic.com`. Because the pod
    does **not** share a PID namespace (`shareProcessNamespace` unset) and containers are isolated, the
    agent's bash in the `server` container cannot read the proxy container's env/`/proc` — so the key
    leaves the agent's reach.
  - *Involved:* a ~50-line proxy (or nginx / LiteLLM — the last also buys per-agent rate/cost limits +
    request logging) built into an image; a broker `create-node` edit (add the container, mount the
    secret into it only, drop the key from `server`); and pointing the node at the proxy. **Open
    question:** model `base_url` lives in the shared DB (global), so use the per-node
    `turnstone-server --base-url` flag to route only agent nodes — needs a precedence check that the
    flag overrides the DB model's base_url.
  - *Why declined:* it protects **only the LLM key** — `TURNSTONE_JWT_SECRET` and `POSTGRES_PASSWORD`
    stay in the server container's env and remain readable via `/proc` — and since egress is already
    contained (shipped), the key can't be exfiltrated anyway. So it's defense-in-depth on a key that
    can no longer leave: real but marginal. The root-cause fix (asymmetric JWT + scoped DB role) is the
    better spend. The only standalone upside is operational (rate/cost limiting via a LiteLLM-style
    gateway), not security.
- **Internal-egress trimming** (restrict `egress.hosts` to only the services the node needs, blocking
  the console/other-nodes): partial — the node's own loopback API remains; asymmetric JWT is the real fix.
- **Scoped read-only Tekton `Role`** (`get`/`list` on `pipelineruns`/`taskruns`/`pods` in the team ns)
  + `kubectl`/`tkn` in the image: gives agents *limited, controlled* self-debug of their own builds —
  explicitly wanted (not a total ban), low risk (read-only, namespaced).
