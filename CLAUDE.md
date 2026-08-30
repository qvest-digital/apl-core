# Working in this repository

This is `qvest-digital/apl-core`, a fork of `linode/apl-core`. This file is fork-only and is not
intended for upstream.

Its purpose: let an agent reproduce the local lab from `SETUP.md` without rediscovering the traps
that cost a full session to find.

## What the documents in here are for

Fork-only documents, none intended for upstream. They have different jobs, and reading the
wrong one for the task wastes a session.

| File | What it is | Read it when |
|---|---|---|
| `CLAUDE.md` | this file — operational rules and traps that apply to *any* work here | always, first |
| `Taskfile.yml` + `.taskfiles/*.yml` | the actual, current way to bring the lab up — a deterministic `go-task` reproduction of `SETUP.md`'s Quickstart, written by an agent after running it by hand | you are asked to install, rebuild or verify the lab — run `task setup` (or `go-task setup` if `task` isn't the installed binary name), don't re-derive the steps yourself |
| `SETUP.md` | the runbook `Taskfile.yml` encodes, and the *why* behind each of its steps | the Taskfile fails and you need to understand a step to debug it, or you're changing what the lab does and need to update both |
| `INTEGRATING-AN-APP.md` | a generic playbook: add any third-party app as a platform app | you are asked to integrate a new app |
| `VIKUNJA.md` | the worked example behind that playbook — a record of one real integration | you need the concrete detail a rule in the playbook is abbreviating |
| `TURNSTONE.md` | a second worked example — an app needing an upstream LLM API, and the certificate trap that came with it | your app is not a Go web app, or anything TLS fails in a way `openssl` says is fine |
| `UPSTREAM-SYNC.md` | an executable runbook: pull new commits from `linode/apl-core` into this fork | you are asked to merge in, sync with, or catch up on upstream |
| `MCP.md` | a record of deploying MCP servers for Gitea and Vikunja, and every credential/session trap proving them live turned up | you are touching either app's MCP server, wiring an MCP client (Turnstone or otherwise) to them, or need a platform-user credential neither app's OIDC login hands you directly |
| `VIKUNJA-TURNSTONE-PIPELINE.md` | a proof-of-flow: a Vikunja webhook triggers a Tekton pipeline that calls Turnstone through its real Python SDK | you are wiring any app event to trigger a Tekton pipeline, or need a working example of the `turnstone` PyPI SDK from inside a pod |
| `TEAM-WORKLOAD-CATALOG.md` | the preferred, correct way to give a team a pipeline or other workload: a git-tracked chart + the platform's own `workloads`/`catalogs` mechanism, not raw `kubectl apply` | you are asked to add a pipeline, a workload, or anything a team should own and iterate on going forward |
| `GITEA-ACTIONS-CI.md` | why the demo teams' lint/build merge gate is built the way it is: Actions rather than Tekton, ephemeral host-mode runners, runner images built by the platform itself | you are touching `seed:runners`/`seed:gates`, any `demo-seed/bookinfo/*/.gitea/` file, or branch protection |
| `EPHEMERAL-AND-TEAM-WORKLOADS.md` | the reusable shapes behind that CI work: how to run a pod that exists only while there is work for it (Job + TTL, not a Deployment), how per-team namespaces are actually laid out, and the diagnosis order when an event-created pod misbehaves | you are adding any ephemeral or per-team workload, or an event-created pod of any kind — read it before `GITEA-ACTIONS-CI.md`, which is the Gitea-specific narrative |
| `AGENT-ENVIRONMENTS.md` | working notes on giving AI agents ephemeral environments, and the first full loop proven end to end: an agent on a per-environment Turnstone node that clones, commits, pushes and opens a real pull request, whose branch is then built and served by the environment. Covers the forge identity and its token lifecycle, why the credential must be a file rather than an env var, per-node config as a tenancy lever, and two agent bugs that compiled and passed CI but only failed when run | you are working on agent environments, Turnstone nodes, giving an agent a git credential, or anything in the agentic-platform direction — it is a record of what was proven live, not a design |

The distinction that matters: **`SETUP.md` and `INTEGRATING-AN-APP.md` are instructions to follow.
`VIKUNJA.md` is evidence, not a plan** — its work is already done and on `feat/vikunja-integration`.
Do not execute it.

**The platform's auto-generated root CA cannot be validated by Python.** `createCustomCA` in
`src/cmd/bootstrap.ts` emits no subject key identifier, so cert-manager's leaves carry no authority
key identifier, and Python 3.13+ (`VERIFY_X509_STRICT`, enforced by OpenSSL 3.5) refuses them with
`Missing Authority Key Identifier`. Go apps are unaffected, and `openssl verify` calls the same chain
`OK` — so this hides from every CLI check. Any Python app talking to Keycloak needs a root CA with
`subjectKeyIdentifier=hash` supplied through `apps.cert-manager.customRootCA` +
`customRootCAKey`, **set before bootstrap, never retrofitted**. Full account in `TURNSTONE.md` §3.

Also: `vikunja-patches/README.md` and `turnstone-patches/README.md` — read before touching any sibling repository
(`apl-api`, `apl-console`, `apl-tasks`). It explains why they ship as patches rather than forks, and
carries the build and load commands, including the one that needs no registry token.

## The task, if you were asked to install, rebuild or verify the lab

**Run `task setup` (binary may be installed as `go-task` instead — check `which task go-task`),
not a manual walk through `SETUP.md`.** That was the point of building it: this lab should no
longer need an agent driving `kubectl`/`docker`/`helm` by hand, session after session, to come up
the same way SETUP.md already proved works. Useful sub-tasks (see `task --list`):

- `task setup` — interactive: asks Y/n per optional app (gitea/harbor/tekton/vikunja/turnstone
  default yes, everything else — including prometheus — defaults no), Enter accepts the
  suggestion. **As an agent, you almost never want the interactive prompts** — run
  `NONINTERACTIVE=true task setup` instead so every `*_ENABLED` var falls back to its documented
  default without blocking on a terminal read you cannot answer; this is also what CI should use.
  (Passing any `*_ENABLED=` explicitly answers just that one app either way, interactive or not.)
- `ANTHROPIC_API_KEY=sk-ant-... NONINTERACTIVE=true task setup` — fully unattended, for Turnstone.
  ⛔ **Supply the key even if Turnstone is off for this run.** `install:prompt` asks for it
  unconditionally and `install:values` seals it either way, because `bootstrapSealedSecrets`
  (`src/cmd/bootstrap.ts`, `src/common/sealed-secrets.ts`) seals every schema `x-secret` exactly
  once, at the initial `helm install`, independent of any app's `enabled` flag, and the operator's
  git-poll reconcile loop never re-runs it. This is the **one** exception to "any app can be
  switched on later from the Console with no extra step": turning Turnstone on afterwards flips
  `apps.turnstone.enabled` and nothing else — the only way to add a key later is
  `task down CONFIRM=yes` followed by a fresh `task setup` with the key. Turnstone itself no longer
  *fails* without one (the env var's `secretKeyRef` is `optional: true`, so the pod starts and SSO
  works); only chat does.
- The operator image's test suite is **skipped by default** for setup speed
  (`--build-arg SKIP_TESTS=true`, wired in `.taskfiles/images.yml`'s `build-operator`) — pass
  `RUN_OPERATOR_TESTS=true task setup` to run it instead (e.g. before a PR, or when actually
  working on the operator)
- `task setup TURNSTONE_ENABLED=false` (and the other `*_ENABLED` toggles — see
  `.taskfiles/install.yml`'s `prompt` task for the full list, including apps not offered at all:
  git-server and metrics-server are always on, promtail has no working gate at all today)
- `task verify:platform` / `task verify:vikunja` / `task verify:turnstone` — the non-browser
  checklists, safe to re-run any time against an already-up cluster
- `task down CONFIRM=yes` — destructive, deletes the cluster; still needs the same confirmation
  care as any other destructive action in this file
- Output is quiet by default (one status line per step, raw output captured to
  `.taskfiles/state/logs/<step>.log`, last 40 lines printed inline on failure).
  `VERBOSE=true task setup` (or `task setup VERBOSE=true`) streams every command live instead —
  see `.taskfiles/lib.sh` for the whole contract.

If `task setup` fails, don't fall back to re-deriving the fix from first principles — read the
matching step in `SETUP.md` first (the Taskfile's comments cite the exact section), fix the
Taskfile itself if the fix is real and generalizes, and re-run. Only fall back to raw
`kubectl`/`docker`/`helm` commands if the Taskfile genuinely can't express what's needed; if that
happens, that's itself a gap worth fixing in `Taskfile.yml`/`.taskfiles/*.yml`, not just working
around once.

## The task, if you were asked to seed or demo the lab

`go-task seed:demo` — note **`go-task`**, not `task`: on this machine `/usr/bin/task` is
Taskwarrior and will print somebody's personal todo list at you.

It is explicitly opt-in and never part of `task setup`. It builds the whole demo on top of a
running platform: four teams (`prodpage`, `details`, `reviews`, `ratings`), three users each, one
Istio Bookinfo microservice per team wired to the others, and — added later — a real per-team
**merge gate**: a Gitea Actions lint+build check, an ephemeral runner whose image this platform
builds itself, and `main` protected behind that check. Vikunja provisioning runs last.

Sub-tasks, each independently re-runnable (`seed:apps` → `seed:runners` → `seed:gates`):

- `seed:apps` — repos, Tekton builds, workloads, public services, cross-team netpols
- `seed:runners` — each team's ephemeral Actions runner: second `AplTeamBuild` off the same repo,
  registration token, workload. The workload deploys an **EventListener, not a Deployment** —
  runners are created one-pod-per-job from Gitea's `workflow_job: queued` webhook and deleted by
  `ttlSecondsAfterFinished` when the job ends, so at rest a team has **zero** runner pods and no
  registered runners. `verify:ci` checks the trigger, not "is a runner online", because at rest the
  honest answer to that is no. Why it is not a Deployment (a clean exit still earning
  CrashLoopBackOff, and why `restartPolicyRules` does not help) is in `GITEA-ACTIONS-CI.md`.
- `seed:gates` — wait for CI green on `main`, then protect `main` behind it

The pushed source is **vendored** at `demo-seed/bookinfo/<role>/`, not cloned from istio/istio at
seed time — deterministic, and it carries the CI the demo exists to show. Change the demo by
editing those trees; the seed force-pushes them.

To run a team's real workflow locally before seeding — same engine the cluster runner uses, since
`gitea-runner` vendors nektos/act:

```bash
./demo-seed/ci-local.sh            # all four teams
./demo-seed/ci-local.sh ratings    # one team
```

**This requires `act` on PATH** (https://github.com/nektos/act) — a global tool, deliberately not
vendored here — plus Docker and a running, seeded lab (the workflow's checkout clones from this
lab's Gitea).

Everything about *why* the gate is shaped this way — Actions rather than Tekton, why a shared
Docker daemon was rejected, what ephemeral does and does not buy, and ten traps that cost real time
— is in `GITEA-ACTIONS-CI.md`. Read it before changing any of it.

## The task, if you were pointed at SETUP.md directly

Only read this top-to-bottom if you're debugging the Taskfile itself, changing what the lab does,
or were explicitly told to follow it by hand rather than through `task setup`. It is a runbook, not
an essay — every command in it has been run. The expected output is given after each step; compare
against it rather than assuming success.

## The task, if you were pointed at INTEGRATING-AN-APP.md

You are being asked to integrate a new app, usually as "read this file and integrate
`<repo-url>` the same way Vikunja was". Read the whole file before writing anything: **the order of
the phases is the content**, and most of the cost in the integration it generalizes came from doing
those steps in a different order. It also tells you which phases your app does not need.

## The task, if you were pointed at UPSTREAM-SYNC.md

You are being asked to pull in commits from upstream (`linode/apl-core`) that landed while this fork
kept doing its own work. Follow `UPSTREAM-SYNC.md` top to bottom: it names the exact fork point, the
files most likely to conflict and why the fork touched them, and why the merge must not be a rebase
(this fork's feature branches are built on `main` and rebasing it would orphan them). Do not try to
reconstruct that file list from `git log` yourself before reading it — it is already there.

## Every Tekton Task on this lab needs two CA-trust settings

Not egress — **CA trust**. The platform's self-signed root CA is not in any build tool's trust
store, so a Tekton Task acting as a TLS client against Harbor or Gitea fails with
`certificate signed by unknown authority` unless verification is skipped. The two settings are
already baked into every build this platform creates
(`charts/team-ns/templates/builds/docker.yaml`), unconditionally, so a normal pipeline needs no
action:

- `git-clone`'s `sslVerify: "false"`
- `kaniko`'s `EXTRA_ARGS: [--skip-tls-verify, --skip-tls-verify-pull]`

Carry them into any Tekton Task you write by hand. Same root cause as the Python CA trap above; see
also `TURNSTONE.md` §3.

Base images do **not** need mirroring into Harbor first. Bookinfo's four Dockerfiles keep their
upstream public `FROM` lines and kaniko pulls every one straight from the public registry, and those
builds also `pip install` / `bundle install` / `npm install` / `gradle build` over the network —
confirmed live 2026-08-29 across all four `docker-trigger-build-*` PipelineRuns. If a fresh cluster
ever *does* fail pulling a base image, the mirroring recipe is preserved as
`harbor_ensure_project` + `harbor_mirror` in `.taskfiles/seed-lib.sh`, kept deliberately unused for
exactly that case.

## The task, if you were pointed at MCP.md

MCP servers for Gitea and Vikunja are already deployed (`values/gitea/gitea.gotmpl`'s
`gitea-mcp` sidecar, `values/vikunja/vikunja-raw.gotmpl`'s standalone `vikunja-mcp` Deployment) and
proven live — both created real, attributed content (an issue, a task) through their MCP servers
using platform-user credentials, not the bootstrap admin. **The one finding that matters most:
neither app's API accepts a raw Keycloak/OIDC token as a bearer credential** — this is a real
upstream limitation (tracked for Gitea, `go-gitea/gitea#23382`), not something to fix here or route
around with a cleverer curl invocation.

Two separate things follow from that, and conflating them wastes a session:

- **Logging in as a platform user is OIDC-only.** Gitea's accounts are provisioned by Keycloak, so
  they carry no local Gitea password — HTTP basic auth with the platform password is rejected
  (verified live 2026-08-29: `401` against `/api/v1/user`). The valid path is a real SSO login;
  `gitea_oidc_login` in `.taskfiles/seed-lib.sh` performs exactly that with curl and a cookie jar,
  and it must run on **every** login, not just at account creation, because Gitea re-syncs org/team
  membership from the JWT's `groups` claim each time.
- **Getting an API credential does NOT require logging in at all.** For automation, mint a Personal
  Access Token with the admin CLI, which needs no session and no SSO:
  `gitea admin user generate-access-token -u <login> -t <name> --scopes <csv> --raw` — that is what
  `gitea_mint_pat` does, and every Gitea API call in the seed authenticates with a PAT obtained this
  way. (`MCP.md`'s PAT recipe is the *human* route, through the web UI after an SSO login.)

Do not read the OIDC-bearer limitation as "the API is closed unless you complete an SSO dance" — a
mistake made live on 2026-08-29, which led to reading compressed Actions logs out of the Gitea pod's
filesystem instead of asking the API for them. Full detail, including exact API calls,
CLI flags, and every trap that cost real time (a crash-looping sidecar, a session model that
silently dropped auth between requests, a UI search box that can't find the very account you just
created) is in `MCP.md` — read it before touching either server again, and before wiring any MCP
client (Turnstone included) to them.

## The task, if you were pointed at VIKUNJA-TURNSTONE-PIPELINE.md

This is a record of how the pipeline was originally proven out — every object it describes was
first `kubectl apply`'d directly against the live cluster, not committed to any chart or
`values/*.gotmpl`. Read it for the four real bugs it hit (Vikunja's own SSRF protection blocking
cluster-internal webhook targets, a missing NetworkPolicy, a Tekton TriggerTemplate JSON-escaping
trap, and an Alpine-vs-Debian base image trap for `pip install turnstone`) and for the working shape
of the `turnstone` Python SDK. **The pipeline itself has since moved into a git-tracked chart** —
see `TEAM-WORKLOAD-CATALOG.md` for where it actually lives now and how to reproduce or extend it;
this file is history, not the current deployment mechanism.

## The task, if you were pointed at TEAM-WORKLOAD-CATALOG.md

This is the pattern to follow whenever you're asked to add a pipeline or workload for a team —
read it before reaching for raw `kubectl apply` or inventing a new mechanism. It documents the
platform's own `workloads` + `catalogs` feature (git-tracked chart, self-service console picker),
worked out concretely for `team-labteam`'s `agentic-sdlc` chart. Read "Traps found building this"
before repeating any of the six mistakes already made here (wrong git URL, catalog caching, image
egress, a stale `workloads` entry surviving a deleted chart path). Check "Surviving a rebuild"
before assuming any of the live example still exists — it isn't wired into `SETUP.md`.

## The task, if you were pointed at VIKUNJA.md or TURNSTONE.md

Both are records, not plans waiting to be executed — the code is on `feat/vikunja-integration` and
`feat/turnstone-integration`. They are the two worked examples behind `INTEGRATING-AN-APP.md`, so
for a *new* integration start there and come back to these for the specifics. Read the matching
`*-patches/README.md` before touching any sibling repository.

Which one to reach for:

- **`VIKUNJA.md`** — a Go web app with a team concept. The fuller example: three repositories, a
  distroless image. It originally also built a team-sync operator to push platform teams and their
  membership into Vikunja teams — that operator was later removed as a deliberate, revisit-able
  decision (standing infrastructure that would act on every future team, not just demo ones, was
  judged more ongoing risk than value). `VIKUNJA.md`'s Phase 3 and Appendix B still record how it
  worked and the rejected OIDC-native alternative; the removal itself is `git log`, not this file.
- **`TURNSTONE.md`** — an app needing an *upstream API credential*, with no team concept, whose TLS
  stack is stricter than Go's. Read it if your app is not Go, if it needs an operator-supplied
  secret, or if anything TLS fails in a way `openssl` insists is fine.

## Rules that are not negotiable

**1. Nothing runs longer than 60 seconds unbounded.** Every command gets a bounded `timeout`,
or runs in the background. State the timeout before running it. Time estimates are wrong in both
directions, so this is never waived for confidence. The image build and the cluster create both
exceed 60s — background them.

**1b. Backgrounding is not watching.** Rule 1 keeps the foreground free; it does not tell anyone
what is happening. A backgrounded command yields exactly **one** notification, at the end — so for
the ten minutes an image build takes, healthy and hung look identical, to you and to the human.

**Pair every backgrounded step with a watcher that reports once a minute.** Always the same shape:
print one status line, check for failure, check for success, sleep.

```bash
while true; do
  echo "[<step>] $(<one-line status command>)"
  <failure check> && echo "[<step>] !! <what broke>"
  <success check> && { echo "[<step>] DONE"; break; }
  sleep 60
done
```

**The filter must cover failure, not just success.** A watcher that greps only for the good outcome
stays silent through a crash loop — and silence is indistinguishable from "still working". Before
arming one, ask what it would print if the thing died right now. If the answer is nothing, widen it.

⚠ **Do not grep builds for `Error`.** `apl-api` and `apl-console` both run test suites that log
handled errors *on the way to passing* — `errorMiddleware error Unauthorized` from the OpenAPI
validator, a jsdom XHR stack from the console's unit tests. A broad pattern reports a perfectly good
build as broken, once a minute, for the whole build. The three signatures that actually mean a
`docker build` died:

```
failed to solve | did not complete successfully | npm ERR! code
```

For a platform install, watch `kubectl get cm apl-installation-status -n apl-operator`, and treat
two things as failures beside the obvious pod states: **`attempt` climbing above 1**, the
unbounded-retry signature `operator.installRetries` exists to bound, and the operator pod entering
`CrashLoopBackOff` or `ImagePullBackOff`. A concrete watcher for that case is in `SETUP.md` step 8.

Build success markers into the backgrounded command itself, so the watcher has something
unambiguous to match — but keep rule 2 in mind while doing it:

```bash
docker build ... > build.log 2>&1
echo "=== MARKER: built"        # this echo is now what sets $? -- the marker says the stage was
                                # REACHED, never that it succeeded. Only the artifact says that.
```

**2. Never trust an exit code that passed through a pipe.** `docker build ... | tail` reports
*tail's* status. This produced a "successful" build that had in fact failed and produced no image.
After building anything, verify the artifact exists:

```bash
docker images <tag>          # not: echo $?
```

A pipe is not the only way to lose it. **Any** trailing command wins, including the one you added to
report the status:

```bash
docker build ... > build.log 2>&1; echo "EXIT=$?"   # reports echo's status -- always 0
```

That printed `EXIT=0` for a build that had failed, and a backgrounded run of it was reported as
"completed (exit code 0)". Redirect to a log, then check the artifact. If you want the status, put
the check *inside* the same command (`&&`) or use `set -o pipefail` and nothing after it.

**3. Capture raw output before filtering.** Piping to `grep`/`head` before you know the shape of the
output hides real errors and destroys `$?`.

**4. Verify, don't assert.** If you have not run it, say so. Do not report a step as done because it
should have worked.

**5. Derive environment-specific values, never copy them.** The MetalLB range comes from the live
docker network every time. It has been `172.18.x` and `172.19.x` on the same machine across
rebuilds. `cluster.domainSuffix` must agree with it.

**6. Once install is `completed`, configuration lives in the git values repo — never hand-patch the
live cluster to change it.** A raw `helm upgrade`, or patching the generated Secret/`ExternalSecret`
directly, gets reverted by Argo CD's `selfHeal` (the operator Deployment) or by external-secrets
(the Secret itself) within seconds, and repeated attempts have grown the values Secret past
`RequestEntityTooLarge`, leaving the cluster unrecoverable. This applies any time you're touching
this cluster, not just during initial setup — a live debugging session is exactly when the
temptation to hand-patch something "just to test it" shows up. The supported way to change
configuration on a running cluster is a commit to the git values repo (what the Console's own
app-activation tiles do via `apl-api`); the operator's poll/reconcile loop picks it up with no
restart needed. Full account, including the specific failure mode this generalizes from, in
`SETUP.md`'s "Changing values after install" section.

## Traps that will cost you an hour each

**Build from a clean context, not the working directory.** `npm run test:ci` spellchecks every
root-level `*.md`. `docker build .` copies your whole working tree, so stray local notes fail the
build with an error that has nothing to do with the code — and `.git/info/exclude` does not apply to
Docker. Always:

```bash
CTX=$(mktemp -d)
git ls-files -z | tar --null -T - -c | tar -x -C "$CTX"
docker build ... "$CTX"
```

**This checkout excludes `values.yaml` locally.** `.git/info/exclude` carries a bare `values.yaml`
line, for the lab's own root `values.yaml` from `SETUP.md`. It matches at *every* depth, so a newly
vendored chart's `charts/<name>/values.yaml` is silently invisible to `git add -A` — and therefore
to the clean-context build, which is built from `git ls-files`. The symptom is a nil-pointer deep
inside the chart's templates at `helm lint`, and `git status` shows nothing wrong. After adding any
chart:

```bash
git add -f charts/<name>/values.yaml charts/<name>/charts/*/values.yaml
git ls-files charts/<name> | grep values.yaml     # must not be empty
```

**Generate the chart schema before installing.** `chart/apl/values.schema.json` is gitignored and
generated. Without it `helm install ./chart/apl` validates **nothing** — silently, with no warning.
Run `bin/gen-chart-schema.sh`. See `SETUP.md` for why.

**A new Taskfile task that prompts, or that prints progress as it goes, needs
`interactive: true`.** `Taskfile.yml` sets `output: group` globally — required so that
`cluster:up` and `images:build-all`, which `cluster-and-images` runs as parallel `deps:`, don't
interleave their status lines character-by-character. The side effect is that grouping buffers a
task's **entire** stdout until its script block exits. A prompt inside such a task deadlocks
silently (the question sits in the buffer while `read -r` waits for an answer nobody can see), and
a long poll loop prints nothing until it is already over — both indistinguishable from a hang while
they happen. Marking the task `interactive: true` exempts it from grouping. `install:prompt`,
`install:values`, `install:watch`, `install:watch-argocd` and `images:load-all` all carry it for
this reason; any future task of either shape needs it too.

**A half-installed platform is not salvageable.** `helm uninstall apl` removes the operator only;
every release the *operator* created survives. Delete the cluster instead.

**`team-admin` means two different things.** It is a Keycloak group and realm role carried by every
user with `isTeamAdmin` (`apl-tasks` `src/operators/keycloak/keycloak.ts`:
`if (decoded.isTeamAdmin === 'true') groups.push('team-admin')`). It is *also* how the platform's
special **admin team** renders, since teams become `team-<id>`. Any loop over `teamConfig` must
therefore write `omit .Values.teamConfig "admin"`, as `apl-keycloak-operator`, `kubernetes-gateways`
and `turnstone` all do. Miss it and you emit a `team-admin` entry that collides with the role
marker — which is exactly how a phantom Vikunja team appeared, containing every team admin in the
platform. Note the flag is **global**: there is no per-team admin group, so scoping it means
intersecting `team-admin` with the actual `team-<id>` membership.

**Pinned tool versions in `charts/team-ns/templates/tekton-tasks/*.yaml` can be years stale, and
upstream does not audit them.** Confirmed live 2026-08-29: `kaniko.yaml`'s `BUILDER_IMAGE` default
was still `kaniko-project/executor:v1.5.1` (released 2021-02-23) — unchanged since the file was
added upstream on 2023-05-09, through every subsequent upstream commit that touched it. It broke a
real build: v1.5.1 can't build multi-stage Dockerfiles on this `kind` cluster
(`unlinkat //product_uuid: device or resource busy` — kind bind-mounts that path from the host,
kaniko's stage-cleanup can't unlink it; fixed by upgrading kaniko past whichever release added
`--ignore-path`). **Fixed in this fork 2026-08-29**: `kaniko.yaml` bumped to `v1.23.2` (verified
live against a real multi-stage build), and while in there the other three pinned images in the
same directory were bumped too (`bash` 5.1.4→5.2 in `kaniko.yaml`/`buildpacks.yaml`, `grype`
v0.112.0-nonroot→v0.118.0-nonroot, `git-init` v0.40.2→v0.45.0) — the latter two unverified by a
real build at bump time (`git-init` is exercised by every build via `git-clone`, so a real cluster
run will validate it; `grype` is not exercised by anything on this cluster since every seeded
build sets `scanSource: false`, so treat it as unverified until something actually runs with
scanning on). See `UPSTREAM-SYNC.md` §4b for the general pattern — upstream still hasn't fixed
any of this, so a future merge won't reintroduce these specific versions but could easily
reintroduce staleness elsewhere in the same directory; check every pinned image in that directory
any time you're already in there for a sync, not just kaniko.

**A local edit under `charts/` does nothing until it is committed AND pushed.** Argo CD renders
every chart in `charts/` from the *public GitHub repo*, at the commit `APPS_REVISION` pins:

```
repoURL: https://github.com/qvest-digital/apl-core.git
path:    charts/team-ns
targetRevision: <APPS_REVISION>
```

Working-tree state is irrelevant to the cluster, and so is the operator image — **Argo does not read
these charts from the image**, so verifying that a chart file is baked into `apl-core-local` proves
nothing. `helm lint` and `helm template` also pass happily on a change the cluster will never see.

This fails silently and mimics an unrelated bug. Confirmed live 2026-08-29: a Role in
`charts/team-ns/templates/rbac.yaml` granting the team EventListener `jobs.batch` was verified
present *inside the operator image*, while the Argo app reported `Synced` + `Healthy` and the Role
did not exist on the cluster. The visible symptom was a CI run stuck `queued` and
`jobs.batch is forbidden` in the EventListener log — which reads like a webhook, CEL or trigger
fault, not a missing commit. It cost a full rebuild cycle to find.

So: **commit and push any `charts/` change before testing it**, and let the run pin `APPS_REVISION`
to that commit (a fresh `task setup` pins current HEAD). When a chart-defined object is missing from
a running cluster, check the source revision *first*:

```bash
kubectl get application <app> -n argocd -o jsonpath='{.spec.source.targetRevision}'
git diff <that-revision> -- charts/<name>      # non-empty = the cluster cannot see your change
```

**Never run `docker system prune -a`.** It will destroy unrelated containers, images and volumes
belonging to other projects on this machine. If you need disk, `docker builder prune` is safe.

**The host Node may be broken.** Nothing here requires it — all Node work happens inside containers.
If you find yourself needing host Node, you have gone off the documented path.

## Working with the human

**When the permission classifier blocks a command, stop immediately and ask.** Do not look for
another route to the same end, and do not substitute a bigger action that is not blocked. A block is
a signal that the human needs to see what you are about to do — so show them the exact command and
why you want to run it, and wait.

This has a cost record. A blocked two-line `kubectl patch` was worked around by deleting and
rebuilding the entire cluster to add one app. The rebuild took ~25 minutes, destroyed a working
9-hour lab, and then failed on the same unrelated bug the patch would have exposed in seconds.
Escalating instead of asking is always the more expensive branch.

Recommend, do not decide. Present options and a recommendation, then stop. Do not treat your own
suggestion as a decision already taken, and do not continue executing while a question you asked is
unanswered — particularly anything that narrows scope or changes tracked files.

## Repository conventions

- `main` is the fully merged state. Reference PRs against `reference/base` exist for reading only
  and must never be merged; they are drafts and titled `[reference]`.
- Commit messages are conventional commits, with a body explaining *why*, not just what.
- Root `*.md` files are spellchecked. New jargon goes in `.cspell.json`, inserted in alphabetical
  order — do not let a formatter rewrite that file, it will reflow unrelated arrays.
