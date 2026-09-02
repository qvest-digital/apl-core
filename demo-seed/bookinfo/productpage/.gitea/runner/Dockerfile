# Gitea Actions runner for team-prodpage -- Python toolchain (ruff).
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
# from this image, so a runtime `pip install` would be paid on every single run.
FROM python:3.13.3-slim

# git + ca-certificates: every workflow's checkout step is a plain `git clone` (the runner is in
# host mode, so Node-based actions/checkout cannot run).
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir "ruff==0.16.5"

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
# --- Agent shell toolbox (baked in; this image is also the agent node) -------------------------
# A generous set of general CLI tools so the agent (and CI) can probe HTTP, slice JSON, search code
# fast, inspect process/network, and view/edit files -- things a minimal -slim base lacks. All four
# team bases are Debian/Ubuntu, so this apt block is identical across them. Debian renames two
# binaries (fd-find->fdfind, bat->batcat); symlink the friendly names the agent is told to use.
# yq (mikefarah) rides in via /opt/platform from agent-base.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       curl wget jq ripgrep fd-find bat tree less vim-tiny nano file \
       procps htop iproute2 dnsutils netcat-openbsd iputils-ping \
       unzip xz-utils socat rsync ca-certificates \
    && ln -sf "$(command -v fdfind)" /usr/local/bin/fd \
    && ln -sf "$(command -v batcat)" /usr/local/bin/bat \
    && rm -rf /var/lib/apt/lists/*

COPY --from=__AGENT_BASE_IMAGE__ /opt/platform /opt/platform
# APPENDED, never prepended. The platform layer ships its own Python, and putting it first
# shadows the team's toolchain: on the python-based runner `python3`, `pip` and `pip3` all resolved
# to /opt/platform, so the team's own dependencies (installed into the image's interpreter) simply
# vanished and CI failed. Confirmed live -- prodpage's merge gate went red on exactly this.
# Appending keeps the team's toolchain first and still finds tea/logcli/vikunja-cli/turnstone,
# which nothing else provides. Turnstone's console scripts carry an absolute shebang into
# /opt/platform/python/bin, so they are unaffected by the ordering either way.
ENV PATH=$PATH:/opt/platform/bin:/opt/platform/python/bin

COPY gitea-runner /usr/local/bin/gitea-runner
COPY config.yaml /data/config.yaml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/gitea-runner /entrypoint.sh && mkdir -p /data && chmod 777 /data

WORKDIR /data
ENTRYPOINT ["/entrypoint.sh"]
