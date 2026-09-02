# Research: apl-core catalogs & workloads mechanism

## Source 1: TEAM-WORKLOAD-CATALOG.md (fully read, verbatim summary)

- **`workloads`**: a team's `env/teams/<team>/workloads/<name>.yaml`, `kind: AplTeamWorkload`.
  Points at any Helm chart in any git repo (`url`/`revision`/`path`/`chart`). `team-ns` chart turns
  each entry into its own ArgoCD `Application`, scoped to `team-<id>` ArgoCD project + namespace,
  `automated: {prune: false, selfHeal: true}`.
- **`catalogs`**: `env/catalogs/<name>.yaml`, `kind: AplCatalog`. Shape:
  `{repositoryUrl, branch, chartsPath, enabled, name}`. Rendered as "Select Catalog" dropdown in
  console's Workloads -> Add New. Picking a chart there writes a `workloads` entry automatically.
  Platform ships one default catalog pointing at `linode/apl-charts.git`.
- Both are just files in the `otomi/values` git repo — no apl-core code change, no image rebuild,
  no sibling-repo patch needed.
- Backing code cited (sibling repos, not in this checkout): `apl-api`'s `src/otomi-stack.ts`,
  `src/api/v2/{teams,catalogs}.ts`; and here, `charts/team-ns/templates/argocd/argocd-application-workload.yaml`.
- Example catalog entry:
```yaml
kind: AplCatalog
metadata:
    name: team-pipelines
spec:
    branch: main
    chartsPath: charts
    enabled: true
    name: team-pipelines
    repositoryUrl: http://gitea-http.gitea.svc.cluster.local:3000/team-labteam/team-pipelines.git
```
  `chartsPath: charts` needed because default `linode/apl-charts` has charts at repo root; apl-api
  looks at repo root if chartsPath unset.
- Example repo layout: chart-per-subfolder monorepo `team-pipelines/charts/agentic-sdlc/{Chart.yaml,values.yaml,templates/*.yaml}`.
  One chart bundled 3 Tekton pipelines (vikunja-turnstone.yaml: Pipeline, Task, TriggerBinding,
  TriggerTemplate, EventListener, NetworkPolicy; hello-world.yaml: Pipeline, Task;
  scheduled-cleanup.yaml: Pipeline, Task placeholder). Confirms workload mechanism supports
  arbitrary Kubernetes/Tekton object kinds, not just Deployments.
- Registered workload: `env/teams/labteam/workloads/agenticbaseline.yaml`, `chartProvider: git`,
  `imageUpdateStrategy.type: disabled`.
- Traps (verbatim, condensed):
  1. repositoryUrl must be reachable from apl-api's pod (in-cluster Service DNS, e.g.
     `gitea-http.gitea.svc.cluster.local:3000`), not the public nip.io/ingress route — apl-api
     fetches catalog chart listings itself (`getBYOWorkloadCatalog` in otomi-stack.ts).
  2. Chart.yaml `icon:` field is raw `<img src>` string incl. data: URI, no scheme validation
     (apl-console CatalogCard.tsx).
  3. **apl-api caches a catalog's chart listing on disk after first fetch** — new charts pushed to
     git don't appear until "Refresh Charts" clicked in console. Directly relevant to a
     central-catalog/many-teams model: staleness risk.
  4. helm lint/template before pushing.
  5. Base images don't need Harbor mirroring anymore (kaniko pulls public images fine) — historical
     trap only.
  6. **Stale `workloads` entry pointing at deleted chart path doesn't error until ArgoCD's next
     refresh** — ArgoCD serves last-known-good cached manifest; `Synced`/`Healthy` status is not
     proof the chart path still exists.
- "Surviving a rebuild": none of this (Gitea repo, env/catalogs/team-pipelines.yaml,
  env/teams/labteam/workloads/agenticbaseline.yaml) is wired into SETUP.md/Taskfile; a fresh
  install starts Gitea empty and otomi/values fresh from values.yaml, losing all three files.

## Source 2: CLAUDE.md section (already in context, not re-copied here in full)
Summary: says this is the pattern to follow for adding pipelines/workloads, read "Traps found
building this" before repeating mistakes (wrong git URL, catalog caching, image egress, stale
workloads entry surviving deleted chart path). Confirms "Check Surviving a rebuild before assuming
any of the live example still exists."

## Source 3: sibling repos

`ls /home/lambda/repos/` shows NO `apl-api`, `apl-console`, or `apl-tasks` checkouts present on
this machine. All claims about apl-api/apl-console behavior are therefore either (a) quoted from
TEAM-WORKLOAD-CATALOG.md's own prior investigation of those repos (not independently re-verified
here), or (b) from the public docs (WebFetch, below), or (c) INFERRED from this repo's schema/chart
code. Marked accordingly throughout.

## Source 4: apl-core implementation, traced end-to-end (VERIFIED in this checkout)

### 4a. `AplCatalog` and `AplTeamWorkload` are NOT Kubernetes CRDs

They are a **file-kind convention inside the `otomi/values` git repo**, consumed by this repo's own
values-processing code (`src/common/repo.ts`), not real `CustomResourceDefinition`s applied to the
cluster. Verified `src/common/repo.ts:307-325`:

```ts
{
  kind: 'AplTeamWorkload',
  envDir,
  jsonPathExpression: '$.teamConfig.*.workloads[*]',
  pathGlob: `${envDir}/env/teams/*/workloads/*.yaml`,
  processAs: 'arrayItem',
  resourceGroup: 'team',
  resourceDir: 'workloads',
  loadToSpec: true,
},
{
  kind: 'AplTeamWorkloadValues',
  envDir,
  jsonPathExpression: '$.teamConfig.*.workloadValues[*]',
  pathGlob: `${envDir}/env/teams/*/workloadValues/*.yaml`,
  processAs: 'arrayItem',
  resourceGroup: 'team',
  resourceDir: 'workloadValues',
  loadToSpec: false,
},
```

Each `env/teams/<team>/workloads/<name>.yaml` file (`kind: AplTeamWorkload`, `spec: {url, path,
chart, revision, imageUpdateStrategy, ...}`) is flattened by this JSONPath machinery into the
giant assembled `teamConfig.<team>.workloads[]` array of the platform's single values.yaml. Same
pattern for `AplCatalog` -> top-level `catalogs.<name>` (schema at `values-schema.yaml:2536-2539`:
`catalogs: additionalProperties: $ref: '#/definitions/catalog'`).

Verified fixture examples, `tests/fixtures/env/teams/demo/workloads/wd1.yaml`,
`tests/fixtures/env/catalogs/default.yaml` — see raw YAML above. Schema for the `catalog` object:
`values-schema.yaml:231-254`:

```yaml
catalog:
  properties:
    name: {pattern: '^[a-z0-9]([-a-z0-9]*[a-z0-9])$'}
    repositoryUrl: {pattern: '^(https?|git|ssh)://.*'}
    branch: {type: string}
    enabled: {type: boolean}
    chartsPath: {type: string, default: 'charts'}
    secretName: {type: string}   # k8s secret name with git creds, for private repos
  required: [name, repositoryUrl, branch]
```

`secretName` (private-repo support) is schema-verified but not covered by
TEAM-WORKLOAD-CATALOG.md's worked example (which used an unauthenticated in-cluster Gitea URL).

Schema for the `workload` object, `values-schema.yaml:1299-1382`:

```yaml
workload:
  properties:
    name: {$ref: '#/definitions/idName'}
    url: {description: 'URL to either Helm or Git repository'}
    chartProvider: {enum: ['helm','git'], default: git}
    path: {description: 'relative dir path within Git repo, only valid for Git source'}
    chart: {description: 'Helm chart name, required for Helm-repo sourced apps'}
    revision: {description: 'commit/tag/branch for Git, semver tag for Helm chart version', default: HEAD}
    namespace: {description: "Applicable only for team-admin. Default 'team-<team_id>'"}
    createNamespace: {type: boolean, default: false}
    sidecarInject: {type: boolean, default: false}
    imageUpdateStrategy: {digest: {...}, semver: {...}, type: [semver|digest|disabled]}
  required: [name, url]
```

So a workload source is: **git repo URL + path + revision** (chartProvider: git, the default) OR
**Helm repo URL + chart name + semver revision** (chartProvider: helm) — e.g.
`crossplane-team-namespace.yaml` fixture: `chart: crossplane, url: https://charts.crossplane.io/stable,
revision: 1.11.2`, no `path`.

### 4b. Catalog entry -> Workload -> ArgoCD Application -> K8s objects (the actual path)

1. **Catalog entry** (`env/catalogs/<name>.yaml`, `kind: AplCatalog`) is read by `apl-api` (sibling
   repo, not present locally — per TEAM-WORKLOAD-CATALOG.md, `getBYOWorkloadCatalog` in
   `otomi-stack.ts`) which lists Helm chart subfolders under `chartsPath` (default `charts`) at
   `branch` of `repositoryUrl`, and renders them as tiles in the console's "Select Catalog"
   dropdown. **INFERRED/reported, not independently re-verified** (no apl-api checkout here).
2. Console "Create Workload": team member picks a catalog tile -> console writes a new
   `env/teams/<team>/workloads/<name>.yaml` (`kind: AplTeamWorkload`) into the `otomi/values` git
   repo, populated with that chart's `url/path/revision` (or `chart` for a Helm-repo catalog) plus
   whatever `imageUpdateStrategy` the user picked. **Per TEAM-WORKLOAD-CATALOG.md** ("Picking a
   chart there writes a workloads entry for you") and public docs (§5 below) — not independently
   re-verified against apl-api source in this session.
3. This repo's values pipeline (`src/common/repo.ts`) flattens every team's `workloads/*.yaml` into
   `teamConfig.<team>.workloads[]` in the single assembled values.yaml.
4. `helmfile.d/helmfile-60.teams.yaml.gotmpl:135-144` installs one Helm release
   `team-ns-<teamId>` of chart `charts/team-ns`, in namespace `team-<teamId>`, fed by
   `values/team-ns/team-ns.gotmpl`.
5. `values/team-ns/team-ns.gotmpl:38` sets the release's own `workloads:` value from
   `$team | get "workloads" list` (i.e. that team's slice of `teamConfig`) — confirmed live in
   file, line: `workloads: {{- $team | get "workloads" list | toYaml | nindent 2 }}`.
6. `charts/team-ns/templates/argocd/argocd-application-workload.yaml` (full text captured above)
   **ranges over `.Values.workloads`** and emits, per workload, one ArgoCD **`Application`**
   (`apiVersion: argoproj.io/v1alpha1, kind: Application`), named
   `team-{{ $v.teamId }}-{{ .name }}`, in the `argocd` namespace:
   - `spec.project`: `team-<teamId>` (restricted ArgoCD AppProject) unless `teamId == "admin"` and
     an explicit `.namespace` is set, in which case `project: default` (unrestricted — admin
     escape hatch for cluster-wide installs like the `crossplane` fixture).
   - `spec.sources[0]`: `repoURL: {{ .url }}`, `targetRevision: {{ .revision }}`,
     `path: {{ .path }}`, `chart: {{ .chart }}` — i.e. this Application's Helm source is literally
     the workload's `url/path/chart/revision` fields, verbatim.
   - `helm.valueFiles`: pulls `$values/env/teams/<team>/workloadValues/<name>.yaml` (and, if
     `imageUpdateStrategy.type != disabled`, also `<name>.managed.yaml`) from a **second source**,
     `repoURL: {{ $v.gitOps.workloadValuesRepoUrl }}` (the `otomi/values` repo itself, aliased
     `ref: values`) — this is Argo CD's "multiple sources" feature: source 1 is the chart, source 2
     supplies the `-f` values file(s) for it.
   - `spec.destination`: `namespace: team-<teamId>` (or the workload's own `.namespace` for
     `teamId: admin` with `createNamespace` set — the crossplane fixture uses this to install
     outside any team namespace).
   - `syncPolicy.automated: {allowEmpty: false, prune: false, selfHeal: true}` — **prune is off**,
     so deleting a `workloads/*.yaml` file does NOT delete the underlying K8s objects; only new/
     changed manifests self-heal. (Not fully explored further in this session — worth flagging as
     an asymmetry vs the "stale entry" trap below.)
7. ArgoCD reconciles that `Application` by rendering the target Helm chart (from wherever `url`
   points — this platform's own Gitea, GitHub, a public Helm repo, anywhere reachable from the
   ArgoCD `application-controller` pod) with the team-supplied values file layered on top, and
   applies **whatever object kinds that chart's templates emit** — ArgoCD does not restrict kinds.
   TEAM-WORKLOAD-CATALOG.md's own worked example chart emitted `Pipeline, Task, TriggerBinding,
   TriggerTemplate, EventListener, NetworkPolicy` (Tekton + Tekton Triggers objects, no Deployment
   at all) — confirmed by that file's repo tree description. This is strong evidence the mechanism
   is generic Helm-chart delivery, not Deployment-specific.

### 4c. Auto image updates (optional per-workload)

`charts/team-ns/templates/argocd/argocd-image-updater.yaml` (full text captured) emits one
`argocd-image-updater.argoproj.io/v1alpha1 ImageUpdater` per team, listing every workload whose
`imageUpdateStrategy.type != disabled`. It watches Harbor (`pullSecret:
argocd/copy-team-<teamId>-harbor-pullsecret`) for new tags/digests matching the workload's
`imageRepository`, and on match, git-commits an updated
`env/teams/<team>/workloadValues/<name>.managed.yaml` back into the values repo (`writeBackConfig:
method: git`) — which the workload's Application then picks up as its second Helm values source.
This is the **only** part of the pipeline coupled to Harbor; a workload with no image to update
(e.g. a pure-Tekton-objects chart, or anything with `imageUpdateStrategy.type: disabled`) skips
this file's output entirely (`{{ if $autoUpdaterApps }}` guard).

### 4d. RBAC / ServiceAccount

Per-team RBAC objects, `charts/team-ns/templates/rbac.yaml` (full text captured above):
- `ServiceAccount sa-team-<teamId>` in the team namespace, carrying `harbor-pushsecret-builds` and
  `gitea-credentials` as mountable Secrets, plus pull secrets (`otomi-pullsecret-global`,
  `harbor-pullsecret` if Harbor enabled). Bound via `RoleBinding admin-team-<teamId>` to
  **ClusterRole `admin`** scoped to the team namespace (namespaced, not cluster-admin), and via a
  second RoleBinding to ClusterRole `psp:unprivileged`.
- Separate `ServiceAccount kubectl` (no auto-mounted token; explicit `Secret kubectl-token`) bound
  to the same `admin` ClusterRole — apparently for a debug/exec pod, not for workloads.
- `Role tty-admin` — full wildcard `apiGroups: '*', resources: '*', verbs: '*'` scoped to the team
  namespace (very broad; not obviously bound to anything in the excerpt captured — would need a
  further grep of the rest of `rbac.yaml` to find its RoleBinding, not done in this session).
- A separate `ServiceAccount tekton-triggers-team-<teamId>` exists (start of a Tekton-specific RBAC
  block, file continues past what was captured — not fully read).

**Important: none of this is "the workload's ServiceAccount" automatically.** ArgoCD's
`application-controller` (running with its own, cluster-wide service account) is what actually
applies the workload chart's manifests to the cluster — it is not scoped down per team via
Kubernetes RBAC on the apply path itself, only via the ArgoCD **AppProject** (`project: team-<teamId>`)
which ArgoCD enforces at its own admission layer (source repos allow-list, destination
namespace/cluster allow-list, resource kind allow/deny-list) — **not verified in this session**
which AppProject restrictions are actually configured (would require reading
`charts/team-ns/templates/argocd/*project*.yaml`, not opened this session). Whatever
`serviceAccountName` a *pod* the workload chart creates runs under is entirely up to that chart's
own templates (e.g. it could reference `sa-team-<teamId>` if its values wire that in, or fall back
to the namespace's `default` ServiceAccount) — this is chart-author responsibility, not something
the catalog/workload mechanism injects for you. **This is an important gap for a central-catalog
design**: a centrally-authored chart cannot assume a specific SA name exists per team unless the
platform's `sa-team-<teamId>` convention (fixed name, parameterized only by `teamId`) is documented
and charts are written to consume it.

## Source 5: public docs (WebFetch, techdocs.akamai.com)

`https://techdocs.akamai.com/app-platform/docs/manage-catalog` (fetched successfully):
- "A catalog is a library of curated Helm charts available for team members to deploy." Each
  catalog is a Git repo with each chart in its own directory. "The catalog version corresponds to
  Git repository tags, not individual chart versions" (i.e. `branch`/tag in `AplCatalog.spec`
  versions the whole catalog, not per-chart).
- **"Changing a catalog version does not affect existing team workloads. Version changes only
  apply to new workloads deployed from that catalog."** — confirms the workload is a point-in-time
  copy of `url/path/revision` baked into its own YAML file at creation time, not a live reference
  back to the catalog entry. Re-deploying a chart's newer catalog version requires either editing
  the existing workload's `revision`/values or creating a new workload.
- "Removing a catalog does not affect already deployed workloads that use charts from this
  catalog" — same reasoning; the workload's own `url` continues to resolve independent of the
  `AplCatalog` object's existence.
- Page doesn't detail RBAC, repo-type distinctions (team-owned vs central), or parameter UI in the
  fetched summary — WebFetch's extraction may have trimmed detail; treat as partial coverage, not
  proof of absence.

`https://techdocs.akamai.com/app-platform/docs/team-workloads` (fetched successfully) — most
useful public page found:
- Console flow: Team view -> **Workloads** -> **Create Workload**, pick "a template from the
  catalog to use."
- Required inputs: workload name, container image repository+tag (from the team's **Builds**
  section — i.e. the platform's own Tekton-build-to-Harbor pipeline is the expected image source,
  consistent with this fork's MEMORY note "Full pipeline, not prebuilt images"), Helm chart
  template selection from the catalog.
- Optional: Auto Image Updater, `digest` (pin a tag, watch digest changes) or `semver` (watch a
  version-constraint range) strategy — matches `values-schema.yaml`'s `imageUpdateStrategy`
  exactly.
- **Values are edited as free-form YAML** in the console, specifically `image.repository` /
  `image.tag` by default, with `imageParameter`/`tagParameter` override fields "in case your Helm
  application contains more than one image" — i.e. the console does NOT generate a form from the
  target chart's `values.schema.json` (no evidence of JSON-Schema-driven form generation for
  arbitrary chart values); it's a values.yaml text box seeded with image fields, matching this
  repo's `workloadValues/<name>.yaml` file being literally a values file, not a structured object
  in `values-schema.yaml`.
- **"Argo CD resources (one applicationSet per Workload)" are generated on submit** — the public
  doc's wording says `applicationSet`, but the actual chart template in this checkout
  (`charts/team-ns/templates/argocd/argocd-application-workload.yaml`) emits a plain
  `kind: Application`, not an ArgoCD `ApplicationSet`. **Flagging this discrepancy explicitly**:
  either the doc is using "applicationSet" loosely to mean "a set of Application resources", or a
  different/newer version of the platform uses a real `ApplicationSet` generator. Trust the code in
  this checkout (`Application`, one per workload, per the `range $v.workloads` loop) over the
  doc's wording.
- Mentions `otomi.io/auth` and `otomi.io/auth-policy` pod-level labels for auth — not chased
  further in this session (would need to grep this repo's charts for these label keys to see how
  they gate ingress/oauth2-proxy).

`https://techdocs.akamai.com/app-platform/docs/manage-workloads` -> 404, does not exist under that
slug.

## ANSWERS TO THE SPECIFIC QUESTIONS

**1. What IS a catalog entry, concretely?**
A YAML file `env/catalogs/<name>.yaml` in the platform's git values repo (`otomi/values`, itself
Gitea- or externally-hosted per `otomi.git.repoUrl`), `kind: AplCatalog`, schema-validated
(`values-schema.yaml:231`) to `{name, repositoryUrl, branch, enabled, chartsPath, secretName}`. It
is NOT a Kubernetes custom resource — no CRD exists for it; it's a file-format convention read by
this repo's own values-assembly code (`src/common/repo.ts`) and, per TEAM-WORKLOAD-CATALOG.md, by
`apl-api` directly (chart listing). **Owned by whoever can commit to the values repo** — in
practice a platform admin (it lives outside any `env/teams/` tree), though nothing in the schema
itself enforces that; access control is via whatever protects the values repo (git server ACLs),
not the catalog mechanism itself.

**2. Catalog entry -> running thing, full path (VERIFIED in-repo, code cited above):**
`env/catalogs/<name>.yaml` (AplCatalog, chart listing surfaced to console) --[team picks a chart in
console]--> `env/teams/<team>/workloads/<name>.yaml` (AplTeamWorkload, one-time copy of
url/path/chart/revision) --[`src/common/repo.ts` JSONPath flatten]--> assembled
`teamConfig.<team>.workloads[]` --[`helmfile-60.teams.yaml.gotmpl` installs `team-ns` chart per
team]--> `values/team-ns/team-ns.gotmpl` sets release value `workloads: <team's array>` -->
`charts/team-ns/templates/argocd/argocd-application-workload.yaml` ranges over it, emitting one
ArgoCD `Application` (`argoproj.io/v1alpha1`) per workload, named `team-<teamId>-<name>`, in
`argocd` namespace, `project: team-<teamId>` --> ArgoCD's `application-controller` fetches the
chart from `.url`/`.path`/`.chart`@`.revision`, layers on the team's own
`env/teams/<team>/workloadValues/<name>.yaml` (+ `.managed.yaml` if auto-image-update is on) as a
second Helm values source, and applies the rendered manifests to `namespace: team-<teamId>` (or an
admin-chosen namespace for `teamId: admin`).

**3. Chart source shape — confirmed both patterns supported:**
- Git: `url` (any git URL, pattern-checked `^(https?|git|ssh)://.*`) + `path` (subdir) + `revision`
  (branch/tag/commit) + `chartProvider: git` (default).
- Helm repo: `url` (Helm repo endpoint) + `chart` (chart name) + `revision` (semver) +
  `chartProvider: helm`. Confirmed live by the `crossplane-team-namespace.yaml` fixture pointing at
  `https://charts.crossplane.io/stable`.
Which git server: **any**. TEAM-WORKLOAD-CATALOG.md's worked example used the platform's own
in-cluster Gitea (`gitea-http.gitea.svc.cluster.local:3000`, reachable from `apl-api`'s pod — the
*public* nip.io Gitea route was explicitly untested/discouraged for the catalog-listing path, but
for the *workload's own* `url` field, which ArgoCD's controller resolves, either could plausibly
work — not distinguished in the source). A **team's own repo** is fully supported (this is exactly
what the worked example does — `team-labteam/team-pipelines`, a repo the team itself owns).
A **central repo** shared across teams is equally supported and is in fact the *default* shape:
the platform ships with `AplCatalog` default `repositoryUrl: https://github.com/linode/apl-charts.git`
(no team ownership at all) — see `tests/fixtures/env/catalogs/default.yaml`.

**4. Per-team vs shared scoping — confirmed:**
The **catalog** (chart listing) is shared/global — one `AplCatalog` entry can be listed and picked
by every team's console. The **workload** instantiation is always per-team: each team's "Create
Workload" writes its own `env/teams/<team>/workloads/<name>.yaml`, producing its own ArgoCD
`Application` (`team-<teamId>-<name>`), its own `team-<teamId>` namespace destination, its own
`workloadValues/<name>.yaml`. So yes — **one central catalog entry (one chart in one central repo)
can be instantiated by many teams, each getting fully independent, namespace-scoped objects and its
own values file** — this is exactly the "central-definition / per-team-instantiation" model asked
about, and it is what the mechanism already does natively, no extra plumbing needed. Public docs
confirm: changing/removing the catalog entry later does not retroactively affect already-created
per-team workloads (each is a frozen copy of url/path/revision at creation time).

**5. Values/parameters at instantiation time:**
Free-form YAML file per workload, `env/teams/<team>/workloadValues/<name>.yaml`, layered as a
second Helm values source onto the chart's own defaults. Per public docs, the console UI exposes
this as a YAML edit box, pre-seeded with `image.repository`/`image.tag` (or custom-named
equivalents via `imageParameter`/`tagParameter`) when an Auto Image Updater strategy is chosen —
**there is no evidence of JSON-Schema-driven dynamic form generation from the target chart's own
`values.schema.json`**; the platform's `values-schema.yaml` only validates the `workload` envelope
(url/path/chart/revision/imageUpdateStrategy), not the arbitrary values passed through to the
target chart. If auto image update is enabled, a second file `<name>.managed.yaml` is
machine-written by `argocd-image-updater` and layered on top of the user's own values file.

**6. RBAC / ServiceAccount the workload runs under:**
Not automatically anything specific — this is chart-author responsibility (see 4d above in detail).
The platform provisions a per-team `ServiceAccount sa-team-<teamId>` (namespace-scoped `admin`
ClusterRole via RoleBinding, plus registry pull/push secrets), but a workload chart must explicitly
reference it (`serviceAccountName: sa-team-<teamId>`) to use it — nothing forces or auto-injects
this. Absent that, pods run under the namespace's `default` ServiceAccount. The delivery mechanism
itself (ArgoCD applying the chart) runs under ArgoCD's own controller identity, gated by the
`team-<teamId>` AppProject (not fully audited this session — AppProject manifest not opened).

**7. Beyond Deployments — confirmed YES, verified via TEAM-WORKLOAD-CATALOG.md's own example:**
The mechanism is generic Helm delivery; ArgoCD applies whatever kinds a chart's templates emit. The
worked example's `agentic-sdlc` chart templates emitted **Tekton `Pipeline`, `Task`,
`TriggerBinding`, `TriggerTemplate`, `EventListener`, and a `NetworkPolicy`** — zero Deployments.
Nothing in the `workload` schema or the `argocd-application-workload.yaml` template restricts
object kinds.

**8. Traps (from TEAM-WORKLOAD-CATALOG.md, condensed; #3 and #6 are the ones that most directly
bite a central-definition/many-teams model):**
1. Catalog `repositoryUrl` for the *chart-listing* path must be reachable from `apl-api`'s pod
   (in-cluster Service DNS) — the public ingress route was untested and is architecturally fragile
   (hairpin NAT back through the cluster's own external IP).
2. `Chart.yaml`'s `icon:` field is an unsanitized `<img src>` string — `data:` URI is the safe,
   dependency-free choice.
3. **apl-api caches a catalog's chart listing on disk after first fetch** — new charts pushed to
   the central repo don't appear in any team's console picker until someone clicks "Refresh
   Charts". **Directly relevant to the central-catalog model**: a change to the central chart
   library does not propagate to team pickers automatically; there's a manual/latent refresh step,
   and no evidence of a webhook-driven invalidation.
4. Run `helm lint`/`helm template` before pushing any new/changed chart — no platform-side
   validation gate exists before ArgoCD tries to render it.
5. (Historical, resolved) base images no longer need Harbor-mirroring; kaniko/pods pull public
   images fine.
6. **A stale `workloads` entry pointing at a deleted chart path doesn't error until ArgoCD's next
   refresh** — ArgoCD can show `Synced`/`Healthy` on a last-known-good cached manifest for a chart
   path that no longer exists in the source repo. **Relevant to a central-definition model**:
   restructuring or removing a centrally-defined chart can leave every team instance that used it
   showing a false-green status for an indeterminate window.
7. (Not in TEAM-WORKLOAD-CATALOG.md, observed in this session's code read) `syncPolicy.automated:
   {prune: false}` on every workload Application — deleting a team's `workloads/<name>.yaml` does
   not delete the K8s objects it created; they become orphaned/unmanaged. Worth flagging for a
   many-teams model: workload lifecycle (create) is easy and instant, but teardown is not
   symmetric and needs a separate, explicit step (not investigated further this session — no
   `argocd app delete`/finalizer behavior confirmed).
8. Nothing in this repo is wired into `SETUP.md`/Taskfile for catalogs/workloads created ad hoc —
   they live only in the values git repo and Gitea, both reset by a fresh cluster install; a
   central-catalog design meant to survive rebuilds needs its own Taskfile task (per
   TEAM-WORKLOAD-CATALOG.md's "Surviving a rebuild" section).

## Open gaps (explicitly not chased this session)
- `apl-api`/`apl-console` source not available locally to verify catalog-caching, form-generation,
  or ApplicationSet-vs-Application claims firsthand — relying on TEAM-WORKLOAD-CATALOG.md's prior
  investigation and public docs for those.
- ArgoCD `AppProject` manifest for `team-<teamId>` not opened — source/destination/kind
  allow-lists not verified, so the real blast-radius limits per team are not confirmed beyond "a
  restricted project exists".
- `charts/team-ns/templates/rbac.yaml` was only partially read (through the
  `tekton-triggers-team-<teamId>` ServiceAccount) — remainder of the file (likely more Tekton RBAC)
  not captured.
- Private-repo catalog support (`secretName` field) is schema-verified but has no worked example
  anywhere in this repo or in TEAM-WORKLOAD-CATALOG.md.

