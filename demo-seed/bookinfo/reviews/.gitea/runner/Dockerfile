# Gitea Actions runner for team-reviews -- Java toolchain (checkstyle + gradle).
#
# Built by this platform's OWN pipeline: pushed to the team's Gitea repo, built by Tekton/kaniko as
# a second AplTeamBuild (mode.docker.path = .gitea/runner/Dockerfile), pushed to Harbor, and pulled
# back by the runner Deployment. Nothing here is built on the host.
#
# The `gitea-runner` binary is NOT committed to apl-core: the seed downloads it on the host,
# verifies it against a pinned sha256, and drops it into this directory immediately before pushing.
# See .taskfiles/seed.yml's runner task.
FROM gradle:8.13.0-jdk8
USER root

# TWO JDKs on purpose, and they must not be collapsed into one:
#   * the image's default JDK is 8, because the reviews app itself builds under 8 (`gradle build`).
#   * checkstyle 14.0.0 is compiled for Java 21 and cannot run on 8.
# So JRE 21 is installed ALONGSIDE and the workflow invokes it by explicit path
# (/usr/lib/jvm/java-21-openjdk-amd64/bin/java), leaving `java`/JAVA_HOME pointing at 8 for gradle.
# Do not "simplify" this by making 21 the default -- the gradle build breaks.
#
# This is baked in rather than apt-get'd at job time specifically BECAUSE the runner is ephemeral:
# a runtime install would re-run on every single job instead of once at build time.
#
# git + ca-certificates: every workflow's checkout step is a plain `git clone` (host-mode runner,
# so Node-based actions/checkout cannot run).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       openjdk-21-jre-headless git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
RUN curl -sSL -o /opt/checkstyle.jar \
      https://github.com/checkstyle/checkstyle/releases/download/checkstyle-14.0.0/checkstyle-14.0.0-all.jar

COPY gitea-runner /usr/local/bin/gitea-runner
COPY config.yaml /data/config.yaml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/gitea-runner /entrypoint.sh && mkdir -p /data && chmod 777 /data

WORKDIR /data
ENTRYPOINT ["/entrypoint.sh"]
