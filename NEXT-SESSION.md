# Next session

Handover written 2026-08-30, end of the agent-environments session. Everything below is committed
and pushed on `feat/agent-ephemeral-envs` (`82e4a7e70`); the working tree is clean.

## 1. The user's TODO list — quote this back verbatim, first thing

The user asked that this list be reproduced **exactly as written**, as the first action of the next
session, before anything else:

```
speicher freimachen
total rebuild

Turnstone node in harbor -> Test
persist haiku4 -> Test
clis gittea vikunja und loki -> Test
habour teams public read
agenten pipeline bauen&git checkout für den agent
tatsächlich die workflows ausdenken
Debug and wiring
otel stuff alles darin umziehn. 
Catalog für "ALLES" DEPLOYEN
grafana logstash etc als defautl aktivieren
mcp setup
```

Do not reword, translate, correct the typos, or reorder it. Quote it, then work from it.

## 2. Where the cluster was left

Live, running, and mid-repair. `kubectl` context `kind-apl`, domain `172.18.255.200.nip.io`.

- **94 Argo apps Healthy, 1 Degraded** — `team-platform-tekton-dashboard-platform-artifacts`, the
  new platform team's Tekton dashboard. Never used by any of this work; not diagnosed.
- **`docker-build-reviews-runner` is `Failed`.** It died with kaniko exit 255 while the host disk
  was at 98%. Disk is now 93% (35G free) after the user ran a prune. **The rerun was never done**:
  `SEED_FORCE_RUNNER_BUILD=true go-task seed:runners` is the outstanding command. The other three
  teams' runner images rebuilt correctly and will now correctly report "already in Harbor".
- **The merge gates never passed**, so `seed:demo` has not completed and `main` is unprotected in
  all four demo repos. Vikunja provisioning (the last seed step) also never ran.
- **`docker system prune -a` was run on the host.** The cluster is unaffected (its images live
  inside the kind node container), but every locally built image is gone, so the next
  `task setup` rebuilds `apl-core-local` and the `apl-api`/`apl-console` forks — add ~10-15 minutes
  to that run.

Given the first two TODO lines are "speicher freimachen" and "total rebuild", the simplest opening
move is a clean rebuild rather than continuing to repair this cluster. On a fresh install none of
the outstanding breakage applies: the seed builds every runner image from the corrected Dockerfiles
because there is no pre-existing Harbor tag.

## 3. What the TODO items map onto in this repo

| TODO line | where it already stands |
|---|---|
| `Turnstone node in harbor -> Test` | **Built and seeded.** `demo-seed/agent-base/` → `team-platform/agent-base:main`. `seed:agent-base` creates the team, user, repo, build and waits for the image. Needs a clean end-to-end run to call it tested. `AGENT-ENVIRONMENTS.md` §18. |
| `persist haiku4 -> Test` | **Done**, committed in `values/turnstone/turnstone-raw.gotmpl` (`9e080f9c8`) with `base_url` and `context_window` spelled out. Survives a rebuild; only needs verifying in the console's model picker. |
| `clis gittea vikunja und loki -> Test` | **Baked into the image**: `tea` 0.15.1, `vikunja-cli` 1.0.0, `logcli` 3.7.7, plus the `logs` wrapper. Verified present on `PATH`; none of them exercised against live Gitea/Vikunja/Loki yet. |
| `habour teams public read` | **Not done for the four demo teams.** Only `team-platform` is flipped public (by `harbor_make_project_public` in `seed:agent-base`). The demo teams' projects are still private, which blocks a single-namespace ephemeral environment (§10). `harbor_ensure_project` already creates projects public and is still unused. |
| `agenten pipeline bauen&git checkout für den agent` | Not started. Every step was proven **by hand** in §13-§14; nothing is triggered. Needs the admin-side EventListener, the per-environment token mint/revoke, and teardown. |
| `tatsächlich die workflows ausdenken` | Not started — this is the design question the rest hangs off. |
| `Debug and wiring` | Not started. |
| `otel stuff alles darin umziehn.` | Not started. Note the distinction found in §17: container logs come from the `platform-logs` OTel **collector daemonset** and need no per-workload change; `k8s-deployment-otel` adds *auto-instrumentation* (traces/metrics) and is a separate concern. Its values default to `replicaCount: 2` and `autoscaling.minReplicas: 2`. |
| `Catalog für "ALLES" DEPLOYEN` | Not started. `research/catalogs-and-workloads.md` and §11 have the mechanism and its two traps: a team's copy is **frozen** at instantiation, and `prune: false` means deleting a workload orphans its objects. |
| `grafana logstash etc als defautl aktivieren` | Not started. Loki + Grafana were enabled by hand via the Console; the OTel collector came with them. Prometheus also came along and costs ~818Mi for nothing we use. |
| `mcp setup` | Not started. Keep distinct from the forge **skill** — `MCP.md`'s `gitea-mcp` is general-purpose infrastructure; the forge tool is a Turnstone skill for token-efficient tool calling. The user corrected this conflation once. |

## 4. Read these, in this order

- `CLAUDE.md` — always first. Gained two traps this session: nothing creates a Gitea repository for
  you (mirror `setup_team_service`), and `team-admin` is not a usable owner for anything.
- `AGENT-ENVIRONMENTS.md` — §13 the proven end-to-end loop, §14 the forge identity and credential
  delivery, §15 building a PR branch, §16 what the environment caught that CI could not, §17 log
  access with a reproducible demo, §18 the platform image, §19 seeded vs still live-only.
- `MCP.md` — last section: Gitea links an incoming SSO identity to whichever account is already
  signed in. Cost a session's confusion; every cheap hypothesis was wrong.
- `GITEA-ACTIONS-CI.md`, `EPHEMERAL-AND-TEAM-WORKLOADS.md` — unchanged, still the CI narrative and
  the reusable shapes.

## 5. Seed bugs found this session — all fixed, none yet validated on a clean run

Three of these are **pre-existing** and were only exposed by changing a runner Dockerfile:

- `seed:runners` never set `HARBOR_ADMIN_PASSWORD`, so every `harbor_has_tag` there authenticated
  as `admin:` , got 401 and answered "no" — the "already in Harbor, skipping" branch had **never
  fired** in this repo's history.
- `wait_for_runner_build` watches a fixed-name PipelineRun with no not-before guard, so a completed
  run from an earlier seed satisfies it in ~3 seconds. Same trap `_push_since` solves for app
  builds. Combined with the above: **the runner image was built once per cluster, ever**, and every
  later Dockerfile change was silently ignored while the seed reported success.
- `SEED_FORCE_RUNNER_BUILD` must be read as `${VAR:-false}` in the shell, not as a go-task template
  var — `VAR=true go-task ...` does not populate `{{.VAR}}`. This repo's other toggles
  (`NONINTERACTIVE`, `*_ENABLED`) are all shell-level.
- `seed:agent-base` needed `gitea_ensure_team_credentials` **before** the push: a brand-new team
  routinely lacks the `gitea-credentials` Secret (upstream swallows a 403 and never retries), and
  the build's fetch-source pod then hangs at `Init:0/2` on a FailedMount.

The one bug that was mine: the platform layer's `ENV PATH` was **prepended**, which shadowed each
team's own toolchain — on the Python runner `python3`/`pip` resolved into `/opt/platform` and
productpage's CI lost its dependencies. Now appended. Verified by running the built image, not by
reading the Dockerfile.

## 6. Working agreements to carry over

- Never start `task setup`, `seed:demo` or `down` — hand the command over and stop.
- Mirror the seed rather than deriving a flow; grep it for the nouns involved first.
- Bounded timeouts on everything, and a watcher that would print something if the thing died.
- **Verify the artifact, not the exit code.** Twice this session a task reported success having
  built nothing; only running the image told the truth.
- `replicaCount: 1` for everything on this lab; change it through apl-api, never `kubectl scale`.
- `go-task`, never `task` (that is Taskwarrior here).
