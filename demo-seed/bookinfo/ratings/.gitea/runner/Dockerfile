# Gitea Actions runner for team-ratings -- Node toolchain (eslint).
#
# Built by this platform's OWN pipeline: pushed to the team's Gitea repo, built by Tekton/kaniko as
# a second AplTeamBuild (mode.docker.path = .gitea/runner/Dockerfile), pushed to Harbor, and pulled
# back by the runner Deployment. Nothing here is built on the host.
#
# The `gitea-runner` binary is NOT committed to apl-core: the seed downloads it on the host,
# verifies it against a pinned sha256, and drops it into this directory immediately before pushing.
# See .taskfiles/seed.yml's runner task.
#
# Toolchain is baked in, never installed at job time -- under an ephemeral runner every job starts
# from this image, so a runtime `npm install -g` would be paid on every single run.
#
# node 21.6 here vs node 23.11 in the ratings APP Dockerfile is a deliberate, known mismatch: 21.6
# is the version this eslint 9 setup was verified against. The runner only lints the app, it never
# runs it, so the versions do not have to agree.
FROM node:21.6-slim

# git + ca-certificates: every workflow's checkout step is a plain `git clone` (the runner is in
# host mode, so Node-based actions/checkout cannot run -- and would resolve against github.com
# anyway, which is not what this lab serves).
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# Installed GLOBALLY on purpose: the app repo's package.json gains no devDependencies, so the
# workflow points NODE_PATH at `npm root -g` for eslint.config.js's requires.
RUN npm install -g eslint@9 @eslint/js@9 globals@15

# --- Platform agent layer ------------------------------------------------------------------------
#
# Supplied by the `platform` team, built once, consumed by every team: Turnstone plus the CLIs an
# agent calls as tools (tea, logcli, vikunja-cli). See AGENT-ENVIRONMENTS.md section 18.
#
# COPY --from, not FROM, so this image keeps its own curated toolchain pin above -- none of the four
# team bases are reproducible from Debian apt at those versions, and at least one is a deliberate,
# documented version choice. Everything under /opt/platform is relocatable and self-contained (its
# Python is a standalone build, not the distro's), so it lands cleanly even on a base with no Python
# at all. The path must stay /opt/platform: console-script shebangs bake it in.
#
# One image, two roles. This is the team's CI runner AND the image its agent node runs, so the agent
# reproduces the merge gate with the same toolchain and the same host-mode workarounds by
# construction -- there is only one artifact, so the two cannot drift.
#
# The image reference on the COPY line below is a placeholder, substituted by
# stage_service_tree at seed time: the reference is domain-dependent, and this build context is
# already seed-assembled (see the gitea-runner note above), so it cannot be hardcoded here.
COPY --from=__AGENT_BASE_IMAGE__ /opt/platform /opt/platform
ENV PATH=/opt/platform/bin:/opt/platform/python/bin:$PATH

COPY gitea-runner /usr/local/bin/gitea-runner
COPY config.yaml /data/config.yaml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/gitea-runner /entrypoint.sh && mkdir -p /data && chmod 777 /data

WORKDIR /data
ENTRYPOINT ["/entrypoint.sh"]
