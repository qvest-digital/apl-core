# Gitea Actions CI — the per-team merge gate

Fork-only, not intended for upstream. Read `CLAUDE.md` first for how this file fits with the others.

This records **why** the four Bookinfo teams' lint/build gate is built the way it is. The *what* is
executable: `.taskfiles/seed.yml`'s `seed:runners` and `seed:gates`, and the vendored trees under
`demo-seed/bookinfo/`. Read this before changing either, or before concluding that some part of it
is gratuitous — most of it is a scar.

## What exists

Each of the four teams (`prodpage`, `details`, `reviews`, `ratings`) owns one Gitea repo containing
its Bookinfo microservice, and that repo carries three things this fork added:

| Path | What it is |
|---|---|
| `.gitea/workflows/ci.yml` | the lint + build gate, run on every push and PR to `main` |
| lint config (`.rubocop.yml`, `eslint.config.js`, `.gitea/checkstyle.xml`) | what "lint" means for that language. productpage needs none — ruff's rules are inline |
| `.gitea/runner/` | the Dockerfile, entrypoint and Helm chart for **that team's own Actions runner** |

`main` is protected: direct pushes are refused, and merging requires the `ci / ci (pull_request)`
check to pass.

Runners are created **on demand, one pod per queued job**, and deleted when the job finishes — at
rest a team has zero runner pods and no registered runners. That chart therefore deploys an
EventListener rather than a Deployment; "How a runner is created" below is the whole mechanism, and
the reason it is not a Deployment is measured, not stylistic.

## Why Actions for the gate, and not Tekton

Tekton was already here and already builds every team's image. It was not extended to run lint,
for one decisive reason and two supporting ones.

**A Tekton PipelineRun cannot block a merge.** There is no relationship between a PipelineRun's
result and Gitea's mergeability check. A gate that cannot say no is not a gate. Gitea Actions
reports a commit status that branch protection consumes, which is the entire mechanism.

Supporting: extending `charts/team-ns/templates/builds/docker.yaml` and `values-schema.yaml` would
touch **upstream-shared** files, adding merge-conflict surface on every `UPSTREAM-SYNC.md` run
forever, for a demo-only capability. And the split is conventional anyway: pre-merge checks in the
SCM's CI, post-merge artifact production in the delivery system.

The security argument is the one worth keeping in mind. PR CI runs **untrusted code** — anyone who
can open a PR controls what executes. The Harbor push credential
(`harbor-pushsecret-builds`) lives only in the Tekton PipelineRun and never in a runner, so a
malicious PR cannot reach the registry. That boundary is the point, not an accident.

**The known gap:** you build twice, and the thing tested is not the thing shipped. The PR proves
`gradle build` and the linter pass; Tekton then independently builds a container image from the
same source. A Dockerfile-only change can break `main` with a green PR. Closing that properly means
either building the image in PR CI and having Tekton merely promote it, or gating merges on Tekton
— both more machinery than this lab warrants. It is an accepted trade, not an oversight.

## Runner isolation — what was chosen and what was rejected

Runners execute in **host mode**: each job runs as a plain process on the runner pod, with no
Docker and no per-step container. That is a real limitation, and it is why every workflow's checkout
is a hand-written `git clone` rather than `actions/checkout` (a Node action, which several of these
images have no Node for).

Three tiers were considered:

| Tier | What it is | Verdict |
|---|---|---|
| 1 | **Ephemeral runner pods**, host-mode execution | **Adopted.** |
| 2 | Shared Docker daemon (`DOCKER_HOST` at one DinD Deployment), container-per-job | **Rejected.** |
| 3 | Genuinely unprivileged container-per-job | Out of scope. |

**Tier 2 was rejected on portability, not laziness.** It needs a privileged pod, which a real
cluster's Kyverno policies or a `baseline`/`restricted` Pod Security level will refuse outright — so
it would be a lab-only construct that cannot follow this pattern anywhere real. It also only
concentrates the privilege rather than removing it: access to a Docker socket is root-equivalent on
that daemon, so one malicious job still reaches every other.

Tier 3 would need rootless DinD (awkward-to-hostile on `kind`, whose nodes are themselves
containers) or a node-level runtime like Sysbox. `act_runner` has no Kubernetes executor, so Tier 3
means replacing the runner, not configuring it.

> **Correction (2026-08-29).** This section used to add "there is no equivalent of GitHub's ARC that
> schedules each job as its own Pod", and rule Tier 3 out on that basis. That was wrong twice over,
> and the error mattered because a later design decision rested on it. Gitea does ship an
> [Actions Runner Controller](https://docs.gitea.com/enterprise/features/actions-runner-controller/)
> (Enterprise). More importantly, **one pod per job needs no ARC at all**: Gitea emits a
> `workflow_job` webhook with `action: queued` (added in Gitea 1.24, `go-gitea/gitea#33694`; this
> lab runs 1.26), and reacting to it is enough. The runner does not have to be replaced — only the
> thing that *starts* it. That is what this lab now does; see the next section.
>
> Tier 3's actual isolation claim is unaffected: a per-job pod still runs its job in host mode, so
> a job is still not isolated *while it runs*. What the change buys is lifecycle, not isolation.

## How a runner is created: on demand, one pod per job

There is **no runner running at rest.** A team with no CI in flight has zero runner pods, and
`kubectl get runners` at Gitea shows none registered. What exists instead is an EventListener:

```
push/PR → Gitea queues a job → `workflow_job: queued` webhook → EventListener (CEL filter)
        → TriggerTemplate creates a Job → one ephemeral runner → job runs → Job completes
        → ttlSecondsAfterFinished deletes the Job and its pod
```

This replaced a Deployment holding one always-running ephemeral runner. Three things forced it,
all measured on this lab rather than reasoned about:

- **A Deployment penalises a clean exit.** A Deployment forces `restartPolicy: Always`, and the
  kubelet applies CrashLoopBackOff to *any* repeated restart regardless of exit code. The runner
  exits `0` after every job and was still penalised: a test pod exiting 0 every time reached
  `CrashLoopBackOff` with 5 restarts, the delay doubling toward a 5-minute cap. The symptom is a job
  sitting `queued` for minutes with a healthy runner and nothing in any log — indistinguishable from
  the design working slowly.
- **`restartPolicyRules` does not fix it.** Kubernetes 1.32+ lets a container say which exit codes
  should be restarted. It decides *whether* to restart, not how the restart is accounted: a pod with
  an explicit "restart on exit 0" rule accrued **exactly the same** backoff as one without, run
  side by side. Do not reach for it here.
- **A Job is the right noun.** Its pod uses `restartPolicy: Never`, so a clean exit is a
  *completion* and there is nothing to back off from; and `ttlSecondsAfterFinished` has Kubernetes'
  own TTL controller delete the Job and pod when it finishes — event-driven, no CronJob, no reaper,
  no pod-deletion RBAC anywhere. Deployments and ReplicaSets deliberately have no equivalent field,
  which is the clue that one-shot work was never meant to run under one.

Everything else is unchanged: the same image, the same `entrypoint.sh`, the same `--ephemeral`
registration, the same reusable org token. The runner pod additionally sets
`automountServiceAccountToken: false` — it executes arbitrary CI code in host mode and has no reason
to hold a Kubernetes credential.

Two side effects worth having: idle cost drops to zero pods per team, and several queued jobs get
several runners, which the single-replica Deployment could not do at all.

The one new permission is in `charts/team-ns/templates/rbac.yaml`: the team's EventListener
ServiceAccount may create Jobs in its own namespace. That is not an escalation — the same account
could already create PipelineRuns, which run arbitrary pods.

**What Tier 1 does and does not buy.** `--ephemeral` makes a runner accept exactly one job, then
deregister and exit; the Deployment brings up a fresh container, which registers again. That
eliminates **cross-job contamination**: no job can leave a poisoned `~/.npm`, a modified toolchain,
or a stray checkout for the next one. It does **not** isolate a job while it runs. Ephemerality and
isolation are different problems, and only the first is solved here.

Two consequences that are easy to get wrong:

- **Toolchains must be baked into the image, never installed at job time.** Under a long-lived
  runner a runtime `apt-get install` is paid once and cached; under an ephemeral one it re-runs on
  every single job. This is why JRE 21 is baked into the reviews runner rather than installed by
  the workflow, as it originally was.
- **The registration token must be reusable**, because every pod start re-registers. Verified live
  2026-08-29: one org token registered two runners, both reported `"ephemeral": true`. If that ever
  stops being true, ephemeral is not viable as designed.

## Why the runner image is built by the platform itself

The runner images are built the same way everything else here is: pushed to Gitea, built by
Tekton/kaniko, pushed to Harbor, pulled back by the workload. They are not `docker build`+`kind
load`ed from the host, even though that would be faster and more deterministic.

This is possible because in-cluster builds on this lab reach the network fine — the Bookinfo
Dockerfiles already `pip install`, `bundle install`, `npm install` and `gradle build`, and resolve
public `FROM` refs, on every seed (see `CLAUDE.md`). It is desirable because the runner image then
demonstrates the exact capability the platform exists to provide, rather than being a thing smuggled
in from outside it.

**No circular dependency exists.** Tekton builds the runner; Tekton does not need a runner. And if
a workflow lands before its runner is online, Gitea **queues** the job until one registers — so the
ordering is forgiving rather than fragile.

The runner build is a **second `AplTeamBuild` on the same repo**, not a separate repo. apl-api
permits this: `createAplBuild` (`otomi-stack.js`) enforces uniqueness on `metadata.name` only, with
no foreign key to a `codeRepo` and no uniqueness on `repoUrl`. It carries `trigger: false`, so an
app commit does not rebuild the runner and roll its pods mid-demo — which also means the build must
be created *after* the first push, since a `trigger: false` build renders a one-shot `PipelineRun`
that ArgoCD starts at sync, and it would fail against an empty repo.

**To rebuild a runner image after changing its Dockerfile or runner config**, in this order:

1. **Push first** (`go-task seed:apps`). Rebuilding before the push just rebuilds the old content —
   easy to get backwards, and it looks like the fix simply did not work.
2. **Delete the `AplTeamBuild` through apl-api**, then re-run `go-task seed:runners` to recreate it:
   ```
   curl -X DELETE "$API/v2/teams/<team>/builds/<repo>-runner" -H "Authorization: Bearer $TOKEN"
   go-task seed:runners
   ```

Deleting the rendered `PipelineRun` directly and waiting for Argo CD to put it back **does not
reliably work**, and it is worth knowing why before trying it: Argo CD does notice (the team-ns
Application goes `OutOfSync` and lists `PipelineRun/docker-build-<repo>-runner` as the offending
resource, and `syncPolicy.automated.selfHeal` is `true`), but a sync can complete `Succeeded` while
that resource stays `OutOfSync` and never reappears. Observed live on three of four teams; the
fourth self-healed normally, which makes this look intermittent rather than systematic. Recreating
the build object is the path that behaves predictably, and it is also the platform's own mechanism
rather than a poke at rendered output.

Nothing rebuilds the runner automatically in any case — that is the deliberate consequence of
`trigger: false`.

## Running a team's workflow locally, with the same engine

**Requires `act` on PATH** (https://github.com/nektos/act) — a global tool, not vendored here — plus
Docker and a running, seeded lab.

```bash
./demo-seed/ci-local.sh            # all four teams
./demo-seed/ci-local.sh ratings    # one team
```

Use it after editing anything under `demo-seed/bookinfo/`, before seeding.

**Why act specifically, and not a script that re-runs the lint commands.** act *is* the engine the
Gitea runner uses: `gitea-runner` vendors nektos/act, and the binary's own symbols are
`gitea.com/gitea/runner/act/*`. So this executes the same workflow file, through the same engine, in
the same image. A hand-written script repeating `rubocop …` would be a second copy of the truth and
would drift from `ci.yml` without anyone noticing — the earlier version of this tooling was exactly
that, and its own header warned it would eventually lie.

**The one deliberate difference.** Cluster runners are registered in **host mode**
(`ubuntu-latest:host`): a job runs as a plain process on the pod. act always runs jobs in a
container, so `ci-local.sh` maps `-P ubuntu-latest=<that team's runner image>`, built locally from
the identical `.gitea/runner/Dockerfile`. Same workflow, same toolchain, same engine — containerized
rather than host-mode. The image is built locally rather than pulled from Harbor because the host
Docker daemon does not trust this platform's self-signed CA (the same reason the lab uses `skopeo`
rather than `docker push`).

**It needs the cluster up**, because the workflow's checkout step clones from this lab's Gitea. That
is accepted rather than worked around: the demo lives inside the cluster by definition. The
trade-off is that it cannot validate a tree *before* the cluster exists.

**Running act from inside the cluster (unverified, but the mechanism is known).** `ci-local.sh` uses
act's container mode, which needs a Docker daemon and therefore cannot run in a pod here. act also
accepts `-P ubuntu-latest=-self-hosted`, which executes steps as **plain processes with no Docker at
all** — the same thing `act_runner` does in host mode, and the reason our runners need no
privileges. So an agent pod could run a team's real `ci.yml` with zero privileges, passing the same
`baseline`/`restricted` and Kyverno constraints that ruled out Tier 2 above. Three things it would
need, in order of how likely they are to bite:

1. **`node` on PATH.** act probes for a node binary during "Set up job" even when no JS action is
   used (`node --no-warnings -e console.log(process.execPath)` appears in container-mode logs). In
   container mode act supplies it; self-hosted mode does not.
2. **The team's toolchain**, since steps run in the agent's own filesystem — cheapest correct answer
   is to base such an agent image on that team's `ci-runner` image, which already has it.
3. **A local clone of the team repo**, per trap 8 below.

Two things it would *not* give you: any isolation (the job runs in the agent's own container,
sharing its filesystem and identity — fine for trusted code, not a sandbox), and any commit status
in Gitea. It is local validation, not a merge gate; the two are complementary.

## Repo visibility: readable by everyone, writable by the owning team

The four team repos are created **readable**, not private (`gitea_create_org_repo`,
`.taskfiles/seed-lib.sh`). Write access is unchanged and still limited to the owning team, because
in Gitea write comes from **org membership** — which the platform already drives from each user's
Keycloak group claims on every OIDC login (Gitea's `--group-team-map`). Changing visibility
therefore only ever affected the read side.

Two reasons, and the second one is why the design got simpler rather than more complicated.

**It is what the demo is simulating.** In a real engineering organization every team can read every
other team's source; only the owning team can push. Private-by-default would mean `team-ratings`
cannot read `team-reviews`' code, which is an odd thing to put in front of someone as a model of
how a software org works.

**It deletes a credential.** Argo CD clones these repos to sync the runner workload whose chart
lives inside them. Against a *private* repo that requires a stored Gitea credential in the `argocd`
namespace — and because a `repo-creds` entry matches by **URL prefix**, a single entry would need a
credential able to read every org, i.e. the Gitea admin, granted permanent instance-wide access in
order to read four repos. The alternative was four per-repo `repository` secrets each holding a
separate read-only PAT: better, but still four secrets, four PATs and a rotation story. A readable
repo is cloned anonymously and needs none of it.

**What "public" does and does not mean here.** Gitea has only public and private — there is no
"internal" tier. With this lab's config (`service.REQUIRE_SIGNIN_VIEW: false`,
`service.explore.REQUIRE_SIGNIN_VIEW: true`) these repos are *not discoverable* by browsing without
signing in, but are readable by anyone holding the URL who can reach the ingress. On this lab that
is the same audience as "signed-in users", since the whole cluster sits behind one private ingress —
so internal-ness is enforced at the network layer rather than by Gitea. Making it strictly internal
in Gitea means instance-wide `REQUIRE_SIGNIN_VIEW`, which would put Argo CD straight back to
needing a credential.

## Traps found building this

**1. Branch protection blocks the seed's own push.** `gitea_push_tree` force-pushes to `main`;
`enable_push: false` refuses exactly that. So `seed:apps` calls `gitea_unprotect_branch` before
pushing and `seed:gates` re-applies protection after CI is green. Without the bracket the seed works
once and fails on every re-run — the classic "worked on a fresh cluster" bug.

**2. The status-check context string must match exactly.** It is
`"<workflow name> / <job id> (<event>)"`. When one repo's workflow was `name: CI` and the rest were
`name: ci`, that repo's protection silently required a check that never reported. All four workflows
are now `name: ci` with a single job `ci`, so one constant fits them all.

**3. The chart's `values.yaml` is invisible to git here.** `.git/info/exclude` carries a bare
`values.yaml` line that matches at every depth, so `.gitea/runner/chart/values.yaml` was silently
dropped by `git add -A` — 12 chart files on disk, 8 staged, and `git status` showing nothing wrong.
The symptom would have been a nil-pointer deep in template rendering, far from the cause. Always
`git add -f` chart values and verify with `git ls-files`. (This is CLAUDE.md's trap; it fires here.)

**4. Pinning a download without verifying it is worse than not pinning.** The runner binary's
release URL was initially wrong, and the download silently produced an ASCII `Not Found` page — which
would have been `COPY`'d straight into an image that executes CI jobs. The sha256 check caught it.
The binary is fetched on the host, verified against a pinned hash, and pushed inside the repo so it
is never fetched at image-build time.

**5. Argo CD ships no Gitea credential, and the failure does not mention credentials.** The platform
creates repo secrets only for `github.com/linode/apl-core` and the internal `git-server` values repo.
A workload whose chart lives in a private Gitea repo therefore fails to sync, and what you observe
is a workload that never appears — the authentication error is buried in the Argo CD Application's
sync status, nowhere near where you are looking. Resolved by making the repos readable (above)
rather than by adding a credential; if you ever make them private again, this comes back.

**6. `/usr/bin/task` on this machine is Taskwarrior**, not go-task. Use `go-task`. CLAUDE.md says so;
it is repeated here because the failure mode is a confusing list of somebody's personal todos.

**7. A workload chart must split image repository from tag, or the Argo CD Image Updater silently
un-tags it.** `imageUpdateStrategy` rewrites two *separate* values — `imageParameter` gets the bare
repository, `tagParameter` gets the tag, and with `type: digest` that tag is written as
`main@sha256:…` (tag plus digest). A chart taking a single combined `image: repo:tag` therefore has
its tag stripped the first time the updater fires, leaving an untagged reference that Kubernetes
resolves to `:latest` — which does not exist in Harbor. Observed live: two pods, an old one still
serving on `:main` and a new one with an empty `imageID`, unable to pull. The runner chart uses
`image` + `imageTag` joined in the template, mirroring what `k8s-deployment` already does with
`image.repository` + `image.tag`.

**8. `act` takes `GITHUB_SHA` from the git repo it is invoked in, and `--env GITHUB_SHA` does not
override it.** Run act from inside `apl-core` and the workflow is handed *apl-core's* HEAD; its
checkout step then asks the team repo for a commit that repo has never seen, and fails with
`fatal: remote error: upload-pack: not our ref <apl-core sha>`. Passing `--env GITHUB_SHA` looks
like the fix and silently does nothing — act builds the github context from local git and that wins.
`ci-local.sh` therefore clones the team repo to a temp dir and runs act *there*, which fixes the sha
and, as a bonus, runs against exactly what the cluster runner would check out.

**9. `--ephemeral` without `shutdown_timeout` makes a runner kill its own job.** This is the worst
trap here, because it looks like flakiness rather than breakage. An ephemeral runner initiates
shutdown the moment it *accepts* its single job and relies on `runner.shutdown_timeout` to let that
job finish — and the default is **`0s`**. So it logs
`shutdown initiated, waiting 0s for running jobs to complete`, kills the job it just started, Gitea
re-queues it, the pod restarts, and the loop repeats with Kubernetes restart backoff growing each
time. A job that happens to finish inside the ~3s race window succeeds, which is exactly why
`main`'s fast CI went green while a PR check sat `queued` through four pod restarts. Every runner
`config.yaml` here therefore sets `shutdown_timeout: 1h`. If you ever see a check stuck queued while
the runner pod's `restartCount` climbs, this is the first thing to check.

**10. The reviews runner needs two JDKs, and they must not be merged.** The image's default JDK is 8
because the app builds under 8; checkstyle 14 requires 21. JRE 21 is installed alongside and invoked
by absolute path, leaving `java`/`JAVA_HOME` on 8. Making 21 the default breaks the gradle build.

**11. Gitea can only reach pods labelled `app.kubernetes.io/managed-by: EventListener`.** The
platform's `default-from-gitea` NetworkPolicy in every team namespace admits traffic from the
`gitea` namespace to those pods and nothing else. A webhook pointed anywhere else in a team
namespace fails with `context deadline exceeded (Client.Timeout exceeded while awaiting headers)` in
Gitea's log and **nowhere else** — the delivery simply never arrives, and since Gitea does not retry
(trap 8), the queued job is never served. Tekton sets that label on EventListener pods; the runner
chart re-asserts it so the dependency is visible where it is relied on.

**12. The first CI run of every team is queued before anything can hear about it.** `seed:apps`
pushes to `main` minutes before `seed:runners` creates the webhook and EventListener. Gitea fires
`workflow_job` exactly once, at push time, into a void. Nothing retries, so without intervention
that first run sits `queued` forever and `seed:gates` blocks until it times out — on every team, on
every fresh seed. `runner_drain_queued` exists for this: after wiring the trigger it finds queued
runs and replays a synthetic `workflow_job queued` payload at the team's own EventListener, through
`kubectl port-forward` (a pod in the namespace could not reach it — see trap 11 — but port-forward
goes API server → kubelet and bypasses NetworkPolicy). It replays through the **real** EventListener
rather than creating Jobs directly, so the recovery path cannot drift from the production one. It is
also the general recovery for any lost delivery, not just the bootstrap.

**13. A parallel step must not be wrapped in `apl_run`.** In quiet mode `apl_run` redirects
everything its command prints into a log file, so a progress heartbeat printed from inside one goes
to the log and the terminal shows `▶ label ... ` with no newline and nothing after it for as long as
the work takes. That is indistinguishable from a hang, and it has been re-introduced repeatedly.
`apl_run_parallel` prints to the task's real stdout instead and must be called directly from a
`cmds:` block. Its heartbeat also reports failures, not just progress — a watcher that only prints
good news stays silent through a crash.

**14. `mvdan/sh` does not give `flock` its file descriptor.** The usual shell mutex,
`( flock 9; ... ) 9>>lockfile`, silently fails under go-task: the redirect is honoured for builtins
but fd 9 is not passed to an exec'd binary, so `flock` exits 1 having seen no such descriptor. The
other form, `flock <file> <command>`, execs its command and so cannot run a shell function. The lock
in `lib.sh` therefore uses an atomic `mkdir`, which needs no descriptor and behaves identically
under bash and mvdan/sh.

**15. A parallel worker must never call its item function bare, or `set -e` will hang the seed.**
The worker subshell in `apl_run_parallel` runs the item, then writes its exit status to a file the
heartbeat polls. Under `set -e` -- which is active for every go-task `cmds:` block -- a bare call
means errexit kills the subshell the *instant* the item fails, before that status file is written.
The status then never appears, the heartbeat prints `running: <item>` forever, and the whole seed
waits on a dead worker. Observed live 2026-08-29: `ratings` failed at 21:36:20 and was still being
reported as running ten minutes later. Wrapping the call as `if fn item; then rc=0; else rc=$?; fi`
exempts it from errexit, so a failure reaches the status file instead of destroying the worker.
The same trap applies to `apl_with_lock`, where an aborted body would strand the lock; it uses the
same `if` wrapper. Note this is invisible to any test that runs the driver without `set -e` -- the
original testing did exactly that and passed.

**16. Anything cached in a shared state path needs a lock once teams run in parallel.**
`runner_fetch_binary` downloads the `gitea-runner` binary once into
`.taskfiles/state/seed_runner/` and reuses it for all four teams -- correct while teams ran
serially, a data race the moment they do not. Without a lock, all four `curl -o` the same path
concurrently and a team verifies bytes another is still writing; the pinned sha256 then rejects a
half-written archive (which is the check working, not failing). It is now serialized behind
`apl_with_lock runner-download`, and the download goes to a PID-unique temp that is renamed into
the cache only after verification, so a truncated file is never reachable under the real name.
When parallelizing anything else here, audit it for shared write paths first -- the download was
the only one, but it was not obvious from the call site.

**17. The runner pod must opt out of the Istio sidecar, or every dependency install fails.**
CI steps are clients of the public internet -- `pip install`, `bundle install`, `npm install`,
`gradle build`. With a sidecar in the pod that egress is intercepted and the connection is reset:
observed live 2026-08-29, every `pip install` retried five times against
`ConnectionResetError(104, 'Connection reset by peer')` on `/simple/blinker/` and the job died with
`No matching distribution found for blinker==1.9.0`. Nothing in the message points at Istio, and it
is easy to misread as a proxy/DNS/NetworkPolicy problem -- there is no egress NetworkPolicy in a
team namespace at all, so that lead is a dead end. The fix is one annotation on the **Job's pod
template**, `sidecar.istio.io/inject: "false"`, which is exactly what the platform's own build pods
carry (`charts/team-ns/templates/builds/docker.yaml`) and for the same reason: a build is a client
of the outside world, not a mesh workload. The runner still reaches in-cluster Gitea normally. When
comparing a failing pod against a working one, check the annotations before anything else --
`kubectl get pod <p> -o json | jq .metadata.annotations` answered this in one command after a long
detour through mesh config and network policies.

**18. Changing the runner chart makes the next CI run race the chart it depends on.**
`seed:apps`' push does two things at once: it updates `.gitea/runner/chart` AND triggers CI. Gitea
starts the run in about a second; Argo needs a few more to apply the new chart to the
TriggerTemplate. A run that starts inside that window gets a runner built from the *previous*
template. Observed live 2026-08-29: a run started at 20:56:52Z, Argo applied the chart at
20:56:58Z, and the run failed for want of the pod annotation in trap 17 -- while the very next run
on the same commit passed. Note what this defeats: waiting for the EventListener to be Available
proves a sink is answering, not that it is answering with the current template.

Handled by `runner_rerun_stale_failures`, which reruns only a failure that finished BEFORE the
`ci-runner` app's last sync -- provably executed against a superseded template. It is deliberately
not a retry-on-red: a genuinely red build finishes after that sync and is left alone, and a run
with no usable timestamp is skipped rather than rerun (an empty string sorts before every real
time, so a `// ""` fallback would quietly turn this into the blanket retry it exists to avoid).
This only affects the edit-a-chart-and-reseed loop. A fresh cluster cannot hit it: `seed:apps`
pushes before any EventListener exists, so the run simply queues (trap 12) and `seed:runners`
creates the template fresh before draining.

## What the seed leaves behind

All four repos end with CI **green on `main`** and `main` protected — no open PRs, deliberately, so
the seeded state is deterministic. That means the gate is provable by inspection but is never seen
*firing*. To demo it actually blocking, open a PR with a deliberate lint error and watch the merge
button refuse; that is the one thing the seeded end state cannot show on its own.
