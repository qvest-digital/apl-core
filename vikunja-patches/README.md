# Vikunja integration — the other two repositories

Vikunja is a three-repo change. Everything that lives in `apl-core` is committed normally; this
directory carries the parts that belong to the other two, because forking and publishing two more
repositories is a decision for the reader, not for this branch.

Each patch was generated against `main` of the upstream repository and verified with
`git apply --check` on a fresh clone at the time of writing. If upstream has moved, expect to
re-roll them.

| File | Repo | What it does | Needed for |
| --- | --- | --- | --- |
| `apl-api.patch` | `linode/apl-api` | adds `vikunja` to the `AppList` enum | **everything** — nothing is visible without it |
| `apl-console/public/logos/vikunja_logo.svg` | `linode/apl-console` | the Console tile logo | cosmetic |
| `apl-tasks.patch` | `linode/apl-tasks` | seeds a `vikunja_groups` claim mapper + per-team Keycloak group attribute | team sync (optional) |

There used to be a different `apl-tasks.patch`: a standing operator that pushed platform teams and
their Keycloak group membership into Vikunja teams (plus, later, a per-team project). Removed
2026-08-27 (`dd885ca9a`) — not because it didn't work; both the team sync and the later
project-sync extension were built, debugged and verified live. The decision was that a standing
operator pushing platform state into every team's Vikunja workspace was more ongoing risk (see the
commit that added project sync for the specific concern: it acts on *any* team in `teamConfig`, not
just demo ones, with a hardcoded "Demo project" description) than the team was getting value from,
for now. The removal commit and everything it deleted is in `git log`, not gone, if the operator
approach is ever wanted back.

**What's below is a different, much smaller `apl-tasks.patch`, added the same day.** It implements
the OIDC-native claim-driven alternative Appendix B recorded as proven-working but never wired
in — `apl-keycloak-operator` writes a `vikunja_groups` attribute onto each `team-<id>` Keycloak
group and a matching claim mapper on the `otomi` client; Vikunja itself creates and maintains the
team from that claim on first login. No standing process touches Vikunja's API at all — the write
only ever lands on Keycloak, which already owns team/group membership regardless of Vikunja. That
sidesteps exactly the concern the removal commit raised. Trade-off, from Appendix B, still true:
pull not push (a team doesn't exist until a member first logs in), and once a team exists this way
it can't also be managed through Vikunja's API.

---

## apl-api — required

```bash
git clone https://github.com/linode/apl-api.git && cd apl-api
git apply /path/to/apl-core/vikunja-patches/apl-api.patch

# The image bakes in a copy of apl-core's values-schema.yaml. It must be the one from THIS
# branch, or the app's settings schema is missing and the Console renders an empty form.
APL_CORE_PATH=/path/to/apl-core npm run schema:sync

docker build -t docker.io/linode/apl-api:v0.0.0-vikunja .
docker images docker.io/linode/apl-api:v0.0.0-vikunja   # verify; do not trust the exit code
kind load docker-image docker.io/linode/apl-api:v0.0.0-vikunja --name apl
```

Then point the platform at it from your `values.yaml`:

```yaml
versions:
  api: 0.0.0-vikunja
```

`0.0.0-…` matters: `values/otomi-api/otomi-api.gotmpl` treats a version starting with a digit as a
semver, which prefixes the tag with `v` and sets `pullPolicy: IfNotPresent` — exactly what a
kind-loaded image needs. A tag like `vikunja` would be treated as a branch and pulled `Always`.

`versions` being settable from values at all is a change on this branch
(`helmfile.d/snippets/derived.gotmpl`); upstream reads `versions.yaml` and nothing else.

## apl-console — cosmetic

The Console builds the logo path as `/logos/${appId}_logo.svg` with no lookup table, so the file
name has to be exactly `vikunja_logo.svg`. The tile works without it; it just shows a broken image.

```bash
git clone https://github.com/linode/apl-console.git && cd apl-console
cp /path/to/apl-core/vikunja-patches/apl-console/public/logos/vikunja_logo.svg public/logos/
docker build -t docker.io/linode/apl-console:v0.0.0-vikunja .
kind load docker-image docker.io/linode/apl-console:v0.0.0-vikunja --name apl
```

```yaml
versions:
  console: 0.0.0-vikunja
```

The SVG is Vikunja's own `frontend/src/assets/logo.svg` at v2.5.0, AGPL-3.0 like the rest of the
project.

## apl-tasks — optional, team sync

`apl-tasks`' own `Dockerfile` runs `npm ci` against GitHub Packages, which needs an `NPM_TOKEN`
with `read:packages` — GitHub Packages requires auth even for public packages. Build with
`apl-tasks-teams.Dockerfile` instead: it borrows the resolved `node_modules` from the published
`linode/apl-tasks:main` image (which already has the `@linode/*` packages), and only pulls the
TypeScript compiler and its `@types` from public npm. No credentials needed.

```bash
git clone https://github.com/linode/apl-tasks.git && cd apl-tasks
git apply /path/to/apl-core/vikunja-patches/apl-tasks.patch

docker build -f /path/to/apl-core/vikunja-patches/apl-tasks-teams.Dockerfile \
  -t docker.io/linode/apl-tasks:v0.0.0-vikunja-teams .
docker images docker.io/linode/apl-tasks:v0.0.0-vikunja-teams   # verify; do not trust the exit code
kind load docker-image docker.io/linode/apl-tasks:v0.0.0-vikunja-teams --name apl
```

```yaml
versions:
  tasks: 0.0.0-vikunja-teams
```

⚠ **On an already-bootstrapped cluster, this needs one more step.** Keycloak's `ClientScope` PUT
endpoint silently ignores changes to an *existing* scope's nested `protocolMappers` — already
flagged in `apl-tasks` itself (`// @NOTE this PUT operation is almost pointless...`), true for
every mapper in that list, not just this one. `apl-keycloak-operator` adds the new
`vikunja-groups` mapper to the `openid` client scope's definition, but if that scope already
existed before this image was deployed, the mapper never actually lands — verified live, 2026-08-27.
On a **fresh** install the scope is created via `POST` with the full mapper list from the start,
which should not hit this limitation, but that path is not yet verified end to end; only the claim
mechanism itself and the group-attribute half were proven live (see `SETUP.md`'s "Team sync"
section under step 10). If testing on a running cluster, add the mapper by hand first:

```bash
curl -sk -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  "https://keycloak.<domainSuffix>/admin/realms/otomi/clients/otomi/protocol-mappers/models" -d '{
    "name": "vikunja-groups", "protocol": "openid-connect",
    "protocolMapper": "oidc-usermodel-attribute-mapper",
    "config": {
      "user.attribute": "vikunja_groups", "claim.name": "vikunja_groups",
      "jsonType.label": "JSON", "multivalued": "true", "aggregate.attrs": "true",
      "id.token.claim": "true", "access.token.claim": "true", "userinfo.token.claim": "true"
    }
  }'
```
