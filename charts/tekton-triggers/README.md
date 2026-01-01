# tekton-triggers — the upstream release manifests, verbatim, in a chart-shaped box

**If you are here to bump Tekton Triggers: run `tools/vendor-tekton-triggers.sh <version>` from the
repo root and read the section "Bumping" below. Do not edit anything under `manifests/` by hand.**

## Why this chart looks nothing like a normal chart

Tekton Triggers does not publish a Helm chart. It publishes two plain Kubernetes manifests per
release, `release.yaml` (controller, webhook, CRDs, RBAC, config) and `interceptors.yaml` (the core
interceptors), at

    https://github.com/tektoncd/triggers/releases/download/<version>/release.yaml
    https://github.com/tektoncd/triggers/releases/download/<version>/interceptors.yaml

The platform installs everything through Helm (helmfile → Argo CD Applications with a Helm
source), so Tekton Triggers has to be *a chart*. Historically that was done by hand: somebody
downloaded the two manifests, split them into `templates/<kind>.yaml` files, moved the CRDs to
`crds/`, and inserted `{{ .Values... }}` in the six places the platform wants to influence. Because
that was manual, the chart was not listed in `charts/dependencies.yaml`, the dependency-update bot
never touched it, and it fell 12 minor versions behind before anyone noticed (0.25.0 → 0.37.0,
2026-08). Every bump meant re-doing the split, a ~600-line diff of CRDs and RBAC nobody could review.

This chart removes the split. `manifests/release.yaml` and `manifests/interceptors.yaml` are the
upstream files, **byte for byte** — verify with the checksums in `manifests/SHA256SUMS`. A single
template, `templates/manifests.yaml`, streams them through and edits exactly three Deployments on
the way. A bump is "replace two files"; the diff is upstream's diff.

## What the chart changes about upstream's manifests

Nothing, except on the three Deployments `tekton-triggers-controller`, `tekton-triggers-webhook`
and `tekton-triggers-core-interceptors`, first container only:

| value | effect | default |
|---|---|---|
| `<component>.resources` | replaces the container's `resources` block | unset → upstream's (none) |
| `<component>.image.repository` | replaces the image's `<registry>/<path>` part, keeping upstream's `<tag>@<digest>` | unset → upstream's image |
| `<component>.image.tag` | replaces the tag (and digest) too | unset → upstream's |

`<component>` is `controller`, `webhook` or `interceptors`. These are the same three values the
hand-split chart exposed, with the same names, so `values/tekton-triggers/tekton-triggers.gotmpl`
(resources from `apps.tekton.resources.triggers*`, repository from `otomi.linodeLkeImageRepository`)
is unchanged.

Rendering with the platform's values produces the **same 50 objects, field for field**, as the
hand-split 0.37.0 chart did — checked by parsing both renders and comparing object by object when
this chart was introduced (2026-09-03).

## How `templates/manifests.yaml` works, line by line

- `.Files.Get` reads a file from the chart **without templating it**. That is the whole trick:
  upstream YAML is never parsed as a Go template, so a literal `{{` in an upstream comment or
  annotation cannot break the render. (Helm only templates files under `templates/`.)
- The file is split on `\n---\n` into documents. A leading `\n` is prepended so a file that begins
  with `---` splits cleanly.
- Each document is parsed with `fromYaml` **only to look at it**. If it is not one of the three
  Deployments, the *original text* is emitted, not the re-serialised object — so for 47 of 50 objects
  the output is upstream's bytes, comments included.
- For the three Deployments the parsed object is mutated in place (`set` on the container map, which
  is a reference) and emitted with `toYaml`. Only these three objects lose upstream's comments and
  key order; their content is unchanged apart from the knobs.
- The image rewrite strips everything up to and including the last `/<segment>:` of upstream's
  reference, greedy, so `host:5000/ns/img:tag@sha256:…` yields `tag@sha256:…` — a registry with a
  port does not confuse it.

## Why `crds/` exists (and why it is a derived file)

The first version of this wrapper kept the CRDs in the rendered stream and had no `crds/`. It broke
the install: apl-core's operator does `kubectl apply -f charts/tekton-triggers/crds --server-side`
**before** helmfile runs (`src/cmd/install.ts`), so that the team-namespace charts can create
`EventListener` objects in the same install. Without the directory the operator retried the install
until it gave up (seen live 2026-09-03, "attempt is climbing").

So `crds/crds.yaml` is the seven `CustomResourceDefinition` documents of `manifests/release.yaml`,
extracted **mechanically and verbatim** by `tools/vendor-tekton-triggers.sh`, with a header saying
so. `templates/manifests.yaml` skips CRD documents in the stream, so each CRD object exists once in
the render (Helm `--include-crds` emits `crds/`), and the operator's pre-apply touches the same
objects. Never edit `crds/crds.yaml` by hand; re-run the vendor script.

## Bumping

```bash
tools/vendor-tekton-triggers.sh v0.38.0       # downloads both files into build/apl-core/charts/tekton-triggers/manifests/,
                                              # re-derives crds/crds.yaml, rewrites SHA256SUMS, bumps Chart.yaml
```

The script edits the **assembled** tree, because this chart lives in `patches/apl-core/` (it replaces
an upstream directory, so it cannot be an overlay path). After it has run:

1. `helm template x build/apl-core/charts/tekton-triggers -n tekton-pipelines --include-crds` must
   succeed and contain three `kind: Deployment`. If upstream renamed a Deployment, the knob for it
   silently stops applying — the names are the keys of `$knobs` in the template; check them against
   `grep -A3 'kind: Deployment' manifests/release.yaml`.
2. Commit the change on top of the assembled tree and refresh the patch series with the
   `format-patch` line in `SYNC-UPSTREAM.md`; the tekton-triggers patch is the only one that changes.
3. `task setup`. Triggers is exercised by every seeded build (EventListeners), so `go-task seed:demo`
   is the functional test.

## What this is not

It is not a way to configure Tekton Triggers. Feature flags, logging, leader election and the
webhook configuration are upstream ConfigMaps in `release.yaml` and are applied as upstream ships
them; if the platform ever needs to change one, that is a new knob in `templates/manifests.yaml`
of the same shape as the three Deployments, not an edit under `manifests/`.
