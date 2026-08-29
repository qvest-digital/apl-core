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

COPY gitea-runner /usr/local/bin/gitea-runner
COPY config.yaml /data/config.yaml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/gitea-runner /entrypoint.sh && mkdir -p /data && chmod 777 /data

WORKDIR /data
ENTRYPOINT ["/entrypoint.sh"]
