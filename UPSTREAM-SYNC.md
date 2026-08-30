# Pulling in upstream while the fork has kept moving

This is a runbook, not an essay — every command in it has been chosen for a reason stated inline.
Read it when you are asked to bring in new commits from `linode/apl-core` (Akamai's upstream) while
this fork carries its own history on top.

Fork point: `05b2e9499` (`chore(chart-deps): update otel-operator to version 0.122.0 (#3587)`) is the
last commit this fork shares with upstream unmodified. Everything from `6e1860dbc` onward, 39
commits as of this writing, is fork-only: five small upstream-style fixes, then the Vikunja and
Turnstone integrations and their docs. None of that has been offered upstream — `reference/base`
marks the same point and exists only so draft `[reference]` PRs can be read against it; those PRs
are never merged, and neither is `reference/base` itself.

## 1. Fetch upstream — do not assume a remote exists

`origin` is `qvest-digital/apl-core`. There is no upstream remote configured. Add one and fetch it,
bounded:

```bash
git remote add upstream https://github.com/linode/apl-core.git 2>/dev/null || true
timeout 60 git fetch upstream main
```

Then see what actually changed:

```bash
git log --oneline 05b2e9499..upstream/main | wc -l      # how many commits behind
git diff --stat 05b2e9499..upstream/main                 # what upstream touched
```

## 2. Merge, don't rebase

`main` is pushed to `origin` and is the base of `feat/vikunja-integration`, `feat/turnstone-integration`,
and several other fork branches (see repository conventions in `CLAUDE.md`). Rebasing `main` onto
upstream would rewrite a shared, already-pushed branch and orphan every branch built on top of it.
Merge upstream into `main` instead, and let the merge commit carry the record:

```bash
git checkout main
git merge upstream/main   # resolve conflicts per §3, do not --no-commit and hand-assemble
```

## 3. Where the conflict actually is

Upstream's 05b2e9499..HEAD diff and this fork's 05b2e9499..main diff both touch the files below.
Everything else the fork added (new charts, new `values/vikunja/*`, `values/turnstone/*`, the
`*-patches/` directories, `Taskfile.yml` + `.taskfiles/`, the docs) is a new path from this fork's
side — those only conflict if
upstream happens to have added the same path, which is unlikely and worth a second look if it
happens rather than assuming either side wins.

The real hotspots, and which fork commit put fork-local content there (so you know what you're
protecting when you resolve):

| File | Fork commit(s) | What the fork changed here |
|---|---|---|
| `values-schema.yaml` | `d2f85d230`, `d23418379`, `651782eaf`, `0d7cdb107`, `071f013e8` | `cluster.domainSuffix` required (scoped to provider `custom`), image repo/pull-policy settable, Vikunja + Turnstone schema entries |
| `helmfile.d/snippets/defaults.gotmpl` | `6e1860dbc`, `1a6dc238e`, `071f013e8` | `defaultStorageClass` quoting fix, Vikunja DB storage class, Turnstone defaults |
| `helmfile.d/snippets/derived.gotmpl` | `1adee6dc4`, `1a6dc238e`, `071f013e8` | chart source repo/version settability, Vikunja version merge, Turnstone derived values |
| `helmfile.d/snippets/defaults.yaml` | `0d7cdb107`, `071f013e8` | Vikunja + Turnstone default blocks |
| `helmfile.d/helmfile-03.databases.yaml.gotmpl` | `0d7cdb107`, `071f013e8` | Vikunja + Turnstone database releases |
| `helmfile.d/helmfile-70.shared.yaml.gotmpl` | `0d7cdb107`, `071f013e8` | Vikunja + Turnstone shared-app releases |
| `core.yaml` | `0d7cdb107`, `071f013e8`, `0a0668dd9` | Vikunja + Turnstone app registration, SSO/role wiring |
| `apps.yaml` | `0d7cdb107`, `071f013e8` | Vikunja + Turnstone app list entries |
| `charts/dependencies.yaml` | `37a337430` | Vikunja chart vendored at 2.2.1 |
| `values/apl-operator/apl-operator.gotmpl` | `651782eaf` | image repo/pull-policy settable |
| `values/otomi-pipelines/otomi-pipelines.gotmpl` | `651782eaf` | image repo/pull-policy settable |
| `src/operator/installer.ts` (+ its `.test.ts`) | `bbed462e7` | honours `INSTALL_RETRIES` instead of retrying forever |
| `Dockerfile` | `72e3c3b29`, `1adee6dc4` | toolchain base image and chart source overridable |
| `chart/apl/templates/deployment.yaml`, `post-job.yaml` | `651782eaf` | image repo/pull-policy settable |
| `charts/team-ns/templates/builds/docker.yaml` | kaniko/CA-trust comment commits | comment-only in the fork: the `sslVerify: false` / `--skip-tls-verify` block now cites `CLAUDE.md`'s CA-trust section rather than the deleted `POD-EGRESS-INVESTIGATION.md`. Trivial to resolve — keep upstream's logic, keep the fork's comment |
| `values/gitea/gitea.gotmpl`, `values/argocd-image-updater/*.gotmpl` | same | comment-only, same reason as above |
| `.cspell.json` | several docs commits | fork-only jargon (Vikunja, Turnstone, etc.) — trivial, always keep both sides' words |

Two of these are the ones actually likely to fight upstream line-for-line, because they are places
upstream also edits often:

- **`values-schema.yaml`** — upstream adds new provider/app schema entries in the same file. Resolve
  by keeping both sides' keys; do not let a conflict marker silently drop a schema entry, or
  `helm install` will validate nothing for that block with no warning (same failure mode as the
  gitignored-schema trap in `CLAUDE.md`).
- **`helmfile.d/snippets/derived.gotmpl` / `defaults.gotmpl`** — upstream template logic here churns
  across releases. Read both sides of the conflict as template logic, not text — a naive
  keep-both-hunks resolution here has produced duplicate `{{- if }}` blocks before.

## 4. After the merge resolves

Same two steps as any change here, because a merge is exactly as capable of silently invalidating
generated or excluded files as a hand-edit:

```bash
timeout 60 bin/gen-chart-schema.sh                 # values.schema.json is gitignored, regenerate it
git ls-files charts/vikunja charts/turnstone | grep values.yaml   # confirm .git/info/exclude didn't eat one
```

Then run the test suite from a clean context (root `*.md` spellcheck trap applies here same as any
build — see `CLAUDE.md` §"Traps that will cost you an hour each").

## 4b. While you're in here: check for stale pinned tool versions too

A merge only touches what upstream itself has changed — and upstream does not appear to audit
pinned tool versions in `charts/team-ns/templates/tekton-tasks/*.yaml` at all. Confirmed live
2026-08-29: `kaniko.yaml`'s `BUILDER_IMAGE` default has been pinned to `kaniko-project/executor:v1.5.1`
(released 2021-02-23) since the file was first added upstream on 2023-05-09 (`b5b0ba763`) — over two
years of subsequent upstream commits touching that same file (sync-wave annotations, etc.) never
bumped the version. It surfaced as a real bug: v1.5.1 can't build multi-stage Dockerfiles on a `kind`
cluster (`unlinkat //product_uuid: device or resource busy` — kind bind-mounts that path from the
host; kaniko's stage-cleanup can't unlink it; fixed in later kaniko via `--ignore-path=/product_uuid`,
added well after v1.5.1). A merge from upstream will carry this forward unchanged since upstream
hasn't fixed it either.

**Fixed in this fork 2026-08-29** (bumped to `v1.23.2`, verified against a real multi-stage
build), along with the other three pinned images in the same directory (`bash`, `grype`,
`git-init` — see the CLAUDE.md trap entry for exact versions and which of these are actually
verified by a real run vs. just tag-bumped). A future upstream merge won't silently reintroduce
v1.5.1 specifically, but the underlying pattern — upstream not auditing this directory at all —
is unchanged, so take a look at every pinned image tag/digest under
`charts/team-ns/templates/tekton-tasks/` while you're already touching this area for a sync,
rather than assuming a merge keeps any of them current.

## 4c. Known upstream bug, not yet fixed here: a team named `platform` collides

Found live 2026-08-31, recorded rather than fixed — nothing in the lab is blocked by it today, and
it is a candidate for whenever this fork's divergence gets cleaned up.

`values/kubernetes-gateways/kubernetes-gateways-raw.gotmpl` emits one ReferenceGrant per team, named
after the team, and then a platform-level one with a hardcoded name:

```gotmpl
{{- range $teamId := (keys $v.teamConfig | sortAlpha) }}
      name: {{ $teamId }}-oauth2-proxy-apps          # team loop
{{- end }}
      name: platform-oauth2-proxy-apps               # hardcoded, emitted AFTER the loop
```

A team called `platform` therefore produces an object with exactly the platform-level name. Both are
rendered into the same raw chart, the hardcoded one is emitted last, and it wins — so the *team's*
grant silently does not exist. This is the same shape as the `team-admin` collision CLAUDE.md
already documents: a team id colliding with a platform-level identifier.

**Symptom, and why it does not look like a naming bug.** The team's HTTPRoutes may no longer
reference `oauth2-proxy` in `istio-system`, so they report
`ResolvedRefs=False (RefNotPermitted)` and their Argo application sits **Degraded** while every
resource under it shows `Synced` and no individual resource reports a health problem. On the
2026-08-31 lab that was `team-platform-tekton-dashboard-platform-artifacts`, 1 of 95 apps, and it
had been carried in a session handover for two days as "not diagnosed". Compare the grant against a
working team's — the `from:` list is the tell:

```
platform-oauth2-proxy-apps   from: argocd, harbor, monitoring, grafana, kfp, otomi, tekton-dashboard
details-oauth2-proxy-apps    from: team-details
```

The blast radius is every auth-backed route that team owns. It showed up on only one route because
`team-platform` happens to own only one, but any public service that team gains would hit it too —
which matters, because `team-platform` is the team `seed:agent-base` creates to own the shared
agent image (`AGENT-ENVIRONMENTS.md` §18), and CLAUDE.md actively recommends a team named
`platform` for shared, platform-owned assets.

**The fix, when someone takes it:** prefix the per-team name — `team-{{ $teamId }}-oauth2-proxy-apps`
— which removes the whole collision class, since no team-derived name can then match a
platform-level one. One line. It renames the existing per-team grants; they are owned by the
`kubernetes-gateways-artifacts` Argo application with automated prune, so Argo replaces them and
nothing references them by name. Renaming the hardcoded platform grant instead is the smaller edit
but leaves the trap in place for the next collision.

Two caveats worth knowing before starting:

- `values/*.gotmpl` is baked into the **operator image**, not read from the git values repo, so this
  cannot be applied to a running cluster by committing it. It lands at the next `task setup`; doing
  it live means rebuilding the operator image, loading it into the kind node and restarting
  `apl-operator`, and SETUP.md's "Changing values after install" warns that restarting the operator
  can re-run bootstrap.
- The file is upstream (every commit touching it is an upstream PR: #3543, #3325, #3068), so fixing
  it here is new fork divergence in a file a merge may touch — and it is worth reporting upstream,
  since it is a genuine bug for anyone who names a team `platform`.

**Verification** that a fix worked: the grant `team-platform-oauth2-proxy-apps` exists carrying
`from: team-platform`, the team's HTTPRoutes report `ResolvedRefs=True`, and the Argo application
turns Healthy.

## 5. Record the new sync point

Once the merge lands on `main`, move `reference/base` to the new merge commit (or create a new
marker branch if `reference/base`'s existing draft PRs still need their old base) so the next sync
starts from `git log --oneline <new-base>..upstream/main` instead of re-deriving it from scratch.
State which commit you used as the new base in the merge commit message.
