#!/bin/sh
# Gitea Actions runner entrypoint -- EPHEMERAL mode.
#
# `--ephemeral` makes this runner accept exactly one job, then deregister itself server-side and
# exit. The Deployment's restartPolicy brings up a fresh container, which registers again. That is
# the point: no job can leave anything behind (a poisoned ~/.npm, a modified toolchain, a stray
# checkout) for the next one, without needing privileged containers or a Docker daemon.
#
# Because the runner is deregistered after its single job, a persisted .runner file is worthless --
# it names a runner the server has already forgotten. So always register fresh. This also makes the
# container robust to a kubelet restart that somehow preserved the writable layer.
#
# The registration token is reusable across many registrations (verified live 2026-08-29: two
# runners registered from one token, both reported "ephemeral": true), which is what makes this
# recycling loop work at all with a single long-lived Secret.
set -eu
cd /data
rm -f /data/.runner
/usr/local/bin/gitea-runner register --no-interactive -c /data/config.yaml \
  --instance "$GITEA_INSTANCE_URL" \
  --token "$GITEA_RUNNER_REGISTRATION_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --ephemeral
exec /usr/local/bin/gitea-runner daemon -c /data/config.yaml
