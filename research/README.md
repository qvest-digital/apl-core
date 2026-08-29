# Research notes

Findings gathered while working out how to give AI agents ephemeral environments on this platform.

**These are observations, not a design.** Nothing here proposes an architecture or forecloses one.
Each file records what the code and docs actually say, with `file:line` citations, so that a later
design conversation argues from evidence rather than from recollection. Where a researcher could not
verify something it says so; where it inferred, it says that too. Read the caveats — several claims
are explicitly marked as unverified.

Gathered 2026-08-29/30, against `apl-core` at `bf610ada5` and `turnstone` at `main`. Code moves;
re-check anything load-bearing before relying on it.

| File | Subject |
|---|---|
| `catalogs-and-workloads.md` | How the platform's catalogs and workloads mechanism delivers a chart to a team: the file-kind convention in the values repo, the path from catalog entry to Argo CD Application, what is scoped per team, and the traps found in a prior worked example |
| `turnstone-execution-model.md` | What a Turnstone "node" is, how a workstream binds to one, the console's rendezvous routing, load balancing and capacity, node lifecycle, what execution can reach outside the process, the tool/MCP mechanism, workspace handling, concurrency, and external triggering |
| `turnstone-rbac-and-tenancy.md` | Turnstone's permission model, OIDC claim mapping, what org/team/project concepts exist in the schema versus what is actually enforced, the admin API and token minting, per-team credential isolation, and where tenancy sits relative to the multi-node topology |

## Reading order

`turnstone-execution-model.md` first if the question is *how work runs and where*;
`turnstone-rbac-and-tenancy.md` first if the question is *who may do what, and on whose behalf*.
The two overlap on the multi-node topology and were deliberately cross-briefed, so they can be read
in either order — but they were written independently and their emphases differ.

`catalogs-and-workloads.md` is separate from both: it is about how anything gets delivered to a
team's namespace at all, and it applies regardless of what that thing turns out to be.

## Related documents in this repository

- `EPHEMERAL-AND-TEAM-WORKLOADS.md` — the reusable shapes learned from building the demo teams' CI
  runners: ephemeral pods, per-team resources, and the order to diagnose them in
- `GITEA-ACTIONS-CI.md` — the CI runner narrative and its numbered traps
- `TEAM-WORKLOAD-CATALOG.md` — the earlier worked example of shipping a team a workload through a
  git-tracked chart, which `catalogs-and-workloads.md` re-derives from the implementation

## Known gaps in this round

- `apl-api`, `apl-console` and `apl-tasks` are **not checked out on this machine**. Claims about the
  Console's workload form and apl-api's chart-listing cache come from this repository's own docs and
  Akamai's public documentation, not from those sources.
- Akamai's public documentation and the implementation disagree in at least one place: the docs
  describe catalogs producing an `ApplicationSet`, while the chart emits a plain `Application`.
  Treat the public docs as a guide to intent, not to behaviour.
- Nothing here was tested against a running cluster. It is a reading of code and documentation.
