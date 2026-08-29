# Upstream apl-api bugfixes — patched, not forked

Same convention as `vikunja-patches/`/`turnstone-patches/`: a real bug found in
`linode/apl-api` while working on this fork, fixed as a patch rather than a fork, applied by
`.taskfiles/images.yml`'s `build-api` task on top of `vikunja-patches/apl-api.patch` and
`turnstone-patches/apl-api.patch` (order doesn't matter for this one — it touches an unrelated
file, `src/otomi-stack.ts`, not `src/openapi/app.yaml` — but it's applied last to match the
build task's own comment ordering).

Generated against `main` of `linode/apl-api` (commit `33793bfce03007547143771a8f542ab6212b8c99`,
2026-08-25) and verified with `git apply --check` on a fresh clone, both alone and stacked after
the other two patches, at the time of writing.

| File | Repo | What it does | Needed for |
| --- | --- | --- | --- |
| `apl-api.patch` | `linode/apl-api` | fixes `DELETE /v1/users/{id}` 500ing for ~62.5% of users | deleting any demo/team user whose server-generated id happens to start with a digit |

## The bug

`apl-api` generates each user's `id` as a raw `uuidv4()` (`src/otomi-stack.ts`, `createUser`).
`deleteUser` unconditionally also tries to clean up a "legacy `AplUser` file" at a path built by
`getResourceFilePath('AplUser', id)` (`src/fileStore/file-map.ts`). That helper validates its
`name` argument against `ID_NAME_PATTERN = /^[a-z](?:[-a-zA-Z0-9]{0,61}[a-zA-Z0-9])?$/` — a
Kubernetes-slug rule meant for human-chosen resource names (team ids, app names) — not the UUID
contract the endpoint's own OpenAPI spec (`src/openapi/definitions.yaml#/uuid`) declares for
`userId`. A `uuidv4()`'s first hex character is uniform over `0-9a-f`; 10/16 (62.5%) of the time
it's a digit, which fails `^[a-z]` and throws a plain `Error` — surfaced as an opaque
`HTTP 500 {"error":"<id> is not a valid identifier"}` — before the actual deletion/deployment
step ever runs.

The "legacy" cleanup this validation guards was already dead code by the time this bug was
found: today's `createUser`/`saveUser` only ever write a SealedSecret at
`env/manifests/namespaces/apl-users/sealedsecrets/{id}.yaml`, never the legacy
`env/users/{name}.yaml` path this call was trying to also remove — so no user created via the
current code path could ever have had a legacy file for it to find. The fix removes that dead
call entirely; the real SealedSecret removal and git deployment above it are untouched.

Confirmed live on 2026-08-28: `DELETE /v1/users/{id}` succeeded for an id starting with a
lowercase hex letter (`eb98465e-...`) and 500'd for every id starting with a digit
(`92369144-...`, `14cd3c6c-...`, and 3 others) on the same real cluster, before this fix; not yet
reported upstream (searched `linode/apl-api`'s issues via `gh`, nothing found).

---

## apl-api — required (to delete any affected user)

> **You normally do not run any of this by hand.** `.taskfiles/images.yml`'s `build-api` task
> already clones the repo, applies all three `apl-api.patch` files in order, syncs the schema,
> builds and `kind load`s. The commands here are the manual equivalent, for debugging the
> Taskfile or re-rolling the patch. `npm` must run inside `linode/apl-tools`, not the host — see
> `CLAUDE.md` and `SETUP.md`'s "Do not run npm on the host".

```bash
git clone https://github.com/linode/apl-api.git && cd apl-api
git apply /path/to/apl-core/vikunja-patches/apl-api.patch
git apply /path/to/apl-core/turnstone-patches/apl-api.patch
git apply /path/to/apl-core/bugfix-patches/apl-api.patch
```

Then rebuild/reload the image the same way `task setup`/`images:build-api` already does, and
restart the `otomi-api` Deployment (namespace `otomi`) so it picks up the new image content —
`IfNotPresent` means a `kind load` alone does not restart a running pod.
