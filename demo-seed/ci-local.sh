#!/usr/bin/env bash
#
# Run a demo team's REAL Gitea Actions workflow locally, with `act`.
#
#   ./demo-seed/ci-local.sh                 # all four teams
#   ./demo-seed/ci-local.sh ratings         # just one
#
# Why act rather than a script that re-runs the lint commands: act IS the engine the Gitea runner
# uses. `gitea-runner` vendors nektos/act (the binary's own symbols are gitea.com/gitea/runner/act/*),
# so this executes the same workflow file, through the same engine, in the same image the cluster
# runner uses. A hand-written script that merely repeats `rubocop ...` would be a second copy of the
# truth and would eventually disagree with ci.yml without anyone noticing.
#
# REQUIREMENTS
#   * act on PATH            -- https://github.com/nektos/act (this repo assumes it is installed
#                               globally; it is not vendored here)
#   * docker
#   * a running lab cluster  -- the workflow's checkout step clones from this lab's Gitea, so the
#                               cluster must be up and seeded. That is deliberate and acceptable:
#                               the demo lives inside the cluster by definition.
#
# WHAT IT DOES DIFFERENTLY FROM THE CLUSTER
# The cluster's runners are registered in HOST mode (`ubuntu-latest:host`): a job runs as a plain
# process on the runner pod. act always runs jobs in a container, so `-P ubuntu-latest=<image>` maps
# the label onto that team's own runner image, built locally from the identical
# .gitea/runner/Dockerfile. Same workflow, same toolchain, same engine -- just containerised.
#
# The image is built locally rather than pulled from Harbor because the host Docker daemon does not
# trust this platform's self-signed CA (the same reason the lab uses skopeo instead of docker push).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

command -v act >/dev/null 2>&1 || {
  echo "error: act is not on PATH. Install it globally: https://github.com/nektos/act" >&2
  exit 1; }
command -v docker >/dev/null 2>&1 || { echo "error: docker is not on PATH" >&2; exit 1; }

STATE=.taskfiles/state
DOMAIN=$(cat "$STATE/seed_domain.txt" 2>/dev/null) || {
  echo "error: $STATE/seed_domain.txt missing -- seed the lab first (go-task seed:demo)" >&2
  exit 1; }
# seed-lib's gitea_oidc_login resolves the Gitea account through `kubectl exec` after the SSO
# round-trip, so it needs a context. Derived, never hardcoded (CLAUDE.md rule 5).
KIND_CTX="${KIND_CTX:-$(kubectl config current-context 2>/dev/null)}"
[ -n "$KIND_CTX" ] || { echo "error: no kubectl context -- is the lab cluster up?" >&2; exit 1; }
export KIND_CTX DOMAIN

# shellcheck disable=SC1091
. .taskfiles/lib.sh
# shellcheck disable=SC1091
. .taskfiles/seed-lib.sh
RUNNER_BIN="$STATE/seed_runner/gitea-runner"
[ -f "$RUNNER_BIN" ] || {
  echo "error: $RUNNER_BIN missing -- run 'go-task seed:runners' once so it is fetched and verified" >&2
  exit 1; }

# role:teamId:repo -- kept in step with .taskfiles/seed.yml's SEED_BOOKINFO_SERVICES.
ALL="productpage:prodpage:productpage details:details:details reviews:reviews:reviews ratings:ratings:ratings"
WANT="${1:-}"
RC=0

for SPEC in $ALL; do
  ROLE=${SPEC%%:*}; REST=${SPEC#*:}; TEAM=${REST%%:*}; REPO=${REST#*:}
  [ -n "$WANT" ] && [ "$WANT" != "$ROLE" ] && [ "$WANT" != "$TEAM" ] && continue

  printf '\n########## %s (team-%s) ##########\n' "$ROLE" "$TEAM"
  CTX="$STATE/seed_tree_$ROLE"
  [ -d "$CTX" ] || CTX="demo-seed/bookinfo/$ROLE"

  # Build the runner image from the same Dockerfile the cluster builds. The staged tree already
  # holds the verified gitea-runner binary; fall back to copying it into a temp context.
  BUILD_CTX="$CTX/.gitea/runner"
  if [ ! -f "$BUILD_CTX/gitea-runner" ]; then
    TMP=$(mktemp -d)
    cp -a "demo-seed/bookinfo/$ROLE/.gitea/runner/." "$TMP/"
    cp "$RUNNER_BIN" "$TMP/gitea-runner"
    BUILD_CTX="$TMP"
  fi
  IMG="apl-demo-runner-$ROLE:local"
  docker build -q -t "$IMG" "$BUILD_CTX" >/dev/null || { echo "!! image build failed"; RC=1; continue; }

  # A PAT for the checkout step, minted the same way the seed does, as that team's own dev user.
  PW=$(cat "$STATE/seed_pw_${TEAM}_dev.txt" 2>/dev/null)
  [ -n "$PW" ] || { echo "!! no seeded password for dev-$TEAM"; RC=1; continue; }
  GUSER=$(gitea_oidc_login "dev-$TEAM@$DOMAIN" "$PW") || { echo "!! SSO login failed"; RC=1; continue; }
  PAT=$(gitea_mint_pat "$GUSER" "read:user,read:repository,read:organization")

  # act is run from a real clone of the TEAM repo, not from demo-seed/. That is not a detail:
  # act derives the github context (GITHUB_SHA above all) from the local git repo it is invoked
  # in, and ignores --env GITHUB_SHA. Invoked inside apl-core it therefore hands the workflow
  # apl-core's HEAD, and the checkout step asks Gitea for a commit that repo has never heard of
  # ("upload-pack: not our ref"). Cloning the team repo makes act's own HEAD the right commit,
  # and has the side benefit of running against exactly what the cluster runner would see.
  WORK=$(mktemp -d)
  # GIT_SSL_NO_VERIFY: this lab's Gitea serves its own self-signed root CA (CLAUDE.md's CA note).
  GIT_SSL_NO_VERIFY=1 git clone --quiet \
    "https://$GUSER:$PAT@gitea.$DOMAIN/team-$TEAM/$REPO.git" "$WORK" 2>/dev/null || {
      echo "!! could not clone team-$TEAM/$REPO"; RC=1; rm -rf "$WORK"; continue; }
  echo "running $ROLE's workflow against team-$TEAM/$REPO @ $(git -C "$WORK" rev-parse --short HEAD)"

  # GITHUB_SERVER_URL points act's workflow context at this lab's Gitea, which is what the
  # checkout step clones from. GITHUB_REPOSITORY must be the Gitea path, not act's local default.
  ( cd "$WORK" && \
    act push \
      -W .gitea/workflows/ci.yml \
      -P "ubuntu-latest=$IMG" \
      --env GITHUB_SERVER_URL="https://gitea.$DOMAIN" \
      --env GITHUB_REPOSITORY="team-$TEAM/$REPO" \
      --env GITHUB_API_URL="https://gitea.$DOMAIN/api/v1" \
      -s GITHUB_TOKEN="$PAT" \
      --pull=false ) || RC=1
  rm -rf "$WORK"
done

if [ "$RC" -eq 0 ]; then
  printf '\n########## ALL REQUESTED WORKFLOWS PASSED ##########\n'
else
  printf '\n########## FAILURES ABOVE -- fix before seeding ##########\n'
fi
exit $RC
