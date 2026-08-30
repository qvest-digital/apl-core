# Platform agent base -- everything the platform supplies to a team's runner/agent image.
#
# Owned by the platform-admin team, built once, consumed by all four team images. It is NOT a base
# in the `FROM` sense: teams keep their own curated toolchain pins (python:3.13.3-slim,
# ruby:3.4.3-slim, gradle:8.13.0-jdk8, node:21.6-slim -- none of which are reproducible from Debian
# apt at those versions, and at least one of which is a deliberate, documented version choice).
# They pull this layer in instead:
#
#     FROM ruby:3.4.3-slim
#     COPY --from=harbor.<domain>/team-admin/agent-base:main /opt/platform /opt/platform
#     ENV PATH=/opt/platform/bin:/opt/platform/python/bin:$PATH
#
# Everything under /opt/platform must therefore be RELOCATABLE and must not depend on anything in
# the image it lands in. That is why Python is a standalone build rather than the distro's: a venv
# is bound to its interpreter, and the four team images have four different Pythons (or none).
#
# One image serves both roles on purpose. A team's image is its CI runner AND the image its agent
# node runs, so the agent reproduces the merge gate with the same toolchain and the same host-mode
# workarounds by construction -- there is only one artifact, so the two cannot drift.
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/platform/bin

# --- Python + Turnstone ------------------------------------------------------------------------
#
# python-build-standalone: a fully self-contained CPython that runs from any prefix, so it survives
# COPY --from into a Ruby/Node/JDK image that has no Python at all. Installed at a FIXED path --
# console-script shebangs bake it in, so /opt/platform must be the same path in the consuming image.
#
# No venv: packages go straight into this interpreter, so there is one directory to copy and one
# PATH entry (/opt/platform/python/bin) rather than two.
ARG PYTHON_RELEASE=20260825
ARG PYTHON_VERSION=3.13.15
RUN curl -sSLf -o /tmp/python.tar.gz \
      "https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-x86_64-unknown-linux-gnu-install_only.tar.gz" \
    && tar -xzf /tmp/python.tar.gz -C /opt/platform \
    && rm -f /tmp/python.tar.gz \
    && /opt/platform/python/bin/python3 -c 'import sys; assert sys.version_info >= (3, 11), sys.version'

# `turnstone-server` is a real console script (pyproject.toml [project.scripts]). A node Deployment
# overrides the image ENTRYPOINT with
#   command: ["turnstone-server", "--host", "0.0.0.0", "--port", "8080"]
# so all that matters is that it is on PATH.
ARG TURNSTONE_VERSION=1.8.1
RUN /opt/platform/python/bin/pip install --no-cache-dir "turnstone==${TURNSTONE_VERSION}" \
    && /opt/platform/python/bin/turnstone-server --help > /dev/null

# --- CLIs the agent calls as tools -------------------------------------------------------------
#
# Baked in as CLIs rather than reached through MCP servers, deliberately: a tool call that shells
# out to a pinned binary costs a fraction of the tokens an improvised REST conversation does, and it
# gives a call surface that can be reviewed. Before this image existed the agent hand-rolled `curl`
# against Gitea's API, having read the raw credential file to do it.
#
# All static Go, so they relocate with no runtime dependencies.
#   tea          Gitea's official CLI -- the forge tool.
#   logcli       Grafana's Loki CLI -- this environment's logs, including services owned by other
#                teams that are co-located in the same namespace.
#   vikunja-cli  Chosen over `vja` because it emits JSON an agent can parse. Vikunja's own
#                `vikunja` CLI is server administration, not a user client.
#
# Pinned on purpose -- see CLAUDE.md on how stale pins hide in this repo. Each install ends in a
# version check so a bad URL fails the build rather than the pod.
ARG TEA_VERSION=0.15.1
ARG LOGCLI_VERSION=3.7.7
ARG VIKUNJA_CLI_VERSION=1.0.0

RUN curl -sSLf -o /opt/platform/bin/tea \
      "https://dl.gitea.com/tea/${TEA_VERSION}/tea-${TEA_VERSION}-linux-amd64" \
    && chmod +x /opt/platform/bin/tea \
    && /opt/platform/bin/tea --version

RUN curl -sSLf -o /tmp/logcli.zip \
      "https://github.com/grafana/loki/releases/download/v${LOGCLI_VERSION}/logcli-linux-amd64.zip" \
    && unzip -q -o /tmp/logcli.zip -d /tmp \
    && install -m 0755 /tmp/logcli-linux-amd64 /opt/platform/bin/logcli \
    && rm -f /tmp/logcli.zip /tmp/logcli-linux-amd64 \
    && /opt/platform/bin/logcli --version

RUN curl -sSLf -o /tmp/vikunja-cli.tar.gz \
      "https://github.com/jo-nike/vikunja-cli/releases/download/v${VIKUNJA_CLI_VERSION}/vikunja-cli-linux-amd64.tar.gz" \
    && tar -xzf /tmp/vikunja-cli.tar.gz -C /tmp \
    && install -m 0755 "$(find /tmp -maxdepth 2 -type f -name 'vikunja-cli*' ! -name '*.tar.gz' | head -1)" \
       /opt/platform/bin/vikunja-cli \
    && rm -f /tmp/vikunja-cli.tar.gz \
    && /opt/platform/bin/vikunja-cli --help > /dev/null

# --- Gitea Actions runner ----------------------------------------------------------------------
#
# The runner binary and its config move here from the four team contexts, where they were four
# byte-identical copies fetched by four concurrent downloads into one shared path. That race needed
# a lock and a PID-unique temp file to survive (GITEA-ACTIONS-CI.md trap 16); owning it here deletes
# the race instead of guarding it.
#
# `gitea-runner` is NOT committed to apl-core: the seed downloads it on the host, verifies it
# against a pinned sha256, and drops it into this build context immediately before pushing.
COPY gitea-runner /opt/platform/bin/gitea-runner
COPY config.yaml /opt/platform/config.yaml
COPY entrypoint.sh /opt/platform/entrypoint.sh

# --- Credential wrappers -----------------------------------------------------------------------
#
# These read credentials from FILES, never the environment, and that is not a style choice:
# Turnstone strips every variable ending in _TOKEN/_PASSWORD/_KEY/_SECRET/_CREDENTIAL(S) from the
# agent's subprocess environment (turnstone/core/env.py), and scrubbed_env()'s passthrough= escape
# hatch has no production caller in 1.8.1. LOKI_PASSWORD would simply be absent at runtime, with no
# error explaining why. The credentials themselves are mounted per environment by whatever creates
# the node -- never baked in here.
COPY bin/ /opt/platform/bin/
RUN chmod +x /opt/platform/bin/* /opt/platform/entrypoint.sh

ENV PATH=/opt/platform/bin:/opt/platform/python/bin:$PATH
