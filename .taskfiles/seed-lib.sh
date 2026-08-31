# Shared Keycloak Admin REST helpers for .taskfiles/seed.yml -- separate from lib.sh because
# these are seed-domain logic (specific curl calls against Keycloak), not the generic
# output/logging helpers lib.sh provides. Sourced the same way: `. "{{.SEED_LIB}}"`.
#
# Every function here expects $KIND_CTX and $DOMAIN already set by the caller (Task's
# {{.KIND_CONTEXT}}/{{.STATE_DIR}}-derived values can't be templated into a plain .sh file --
# only the `. "..."` line in seed.yml itself goes through Task's templater) -- and returns
# non-zero with a message on stderr on failure, same contract as everything in lib.sh.

# kc_master_token -- prints an access token for Keycloak's own master-realm bootstrap admin
# (the keycloak-x chart's initial admin, "keycloak-initial-admin" secret), via the built-in
# admin-cli client. admin-cli is public and has Direct Access Grants on by default, unlike the
# platform's own "otomi" client (see seed:auth) -- this is the only account that can call the
# Admin REST API at all, platform-admin/team users cannot.
kc_master_token() {
  _user=$(kubectl --context "$KIND_CTX" --request-timeout=15s get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.username}' | base64 -d)
  _pass=$(kubectl --context "$KIND_CTX" --request-timeout=15s get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d)
  [ -n "$_user" ] && [ -n "$_pass" ] || { echo "error: keycloak-initial-admin secret came back empty" >&2; return 1; }
  # --data-urlencode, not -d: plain -d does not URL-encode its value, so a generated password
  # containing a reserved form character (&, =, +, %% -- exactly what happened live with one of
  # the demo users' auto-generated passwords) silently truncates or corrupts the request body.
  curl -sk --max-time 15 -f "https://keycloak.$DOMAIN/realms/master/protocol/openid-connect/token" \
    --data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
    --data-urlencode username="$_user" --data-urlencode password="$_pass" \
    | jq -er '.access_token'
}

# kc_platform_admin_token <client-secret-name> -- prints a FRESH platform-admin access token via
# the Resource Owner Password grant against the platform's own shared "otomi" OIDC client (same
# grant seed:auth originally used, extracted here so every caller can get a live token instead of
# reusing one cached to disk). Re-derives credentials and the client secret from their live
# Kubernetes Secrets on every call (cheap, ~4 kubectl gets) rather than caching a token to a file
# -- confirmed live: a long bounded wait elsewhere in the same task chain (e.g. enable-apps's
# up-to-20-minute app-readiness wait) can comfortably outlive Keycloak's access-token lifetime, so
# a token fetched before such a wait and reused after it 401s with "JWT verification failed:
# \"exp\" claim timestamp check failed". Call this immediately before each use that follows any
# nontrivial wait, never rely on a previously-fetched token surviving one.
kc_platform_admin_token() {
  _client_secret_name=$1
  _admin_user=$(kubectl --context "$KIND_CTX" --request-timeout=15s get secret platform-admin-initial-credentials \
    -n keycloak -o jsonpath='{.data.username}' | base64 -d)
  _admin_pass=$(kubectl --context "$KIND_CTX" --request-timeout=15s get secret platform-admin-initial-credentials \
    -n keycloak -o jsonpath='{.data.password}' | base64 -d)
  [ -n "$_admin_user" ] && [ -n "$_admin_pass" ] || { echo "error: platform-admin-initial-credentials came back empty" >&2; return 1; }

  _client_ns=$(kubectl --context "$KIND_CTX" --request-timeout=15s get secret -A \
    --field-selector "metadata.name=$_client_secret_name" -o jsonpath='{.items[0].metadata.namespace}')
  [ -n "$_client_ns" ] || { echo "error: secret $_client_secret_name not found in any namespace" >&2; return 1; }
  _client_id=$(kubectl --context "$KIND_CTX" --request-timeout=15s get secret "$_client_secret_name" \
    -n "$_client_ns" -o jsonpath='{.data.client-id}' | base64 -d)
  _client_secret=$(kubectl --context "$KIND_CTX" --request-timeout=15s get secret "$_client_secret_name" \
    -n "$_client_ns" -o jsonpath='{.data.client-secret}' | base64 -d)
  [ -n "$_client_id" ] && [ -n "$_client_secret" ] || { echo "error: client-id/client-secret came back empty from $_client_ns/$_client_secret_name" >&2; return 1; }

  _resp=$(curl -sk --max-time 15 "https://keycloak.$DOMAIN/realms/otomi/protocol/openid-connect/token" \
    --data-urlencode grant_type=password \
    --data-urlencode client_id="$_client_id" \
    --data-urlencode client_secret="$_client_secret" \
    --data-urlencode username="$_admin_user" \
    --data-urlencode password="$_admin_pass" \
    --data-urlencode scope=openid)
  printf '%s' "$_resp" | jq -er '.access_token'
}

# kc_user_id_by_email <token> <email> -- prints the Keycloak user id in the "otomi" realm, or
# nothing (empty string, not an error) if no such user exists.
#
# `jq -r`, not `jq -er`: "no such user" is a normal outcome this function exists to report, and
# -er turns it into exit 4. Callers assign this in a command substitution under
# `set -euo pipefail` (seed:fix-first-login's fix(), kc_resolve_pending), so that nonzero status
# aborted the caller outright -- making their own `[ -n "$USER_ID" ] || echo "error: ..."` guard
# unreachable and the failure silent.
kc_user_id_by_email() {
  _token=$1
  _email=$2
  curl -sk --max-time 15 "https://keycloak.$DOMAIN/admin/realms/otomi/users?email=$_email&exact=true" \
    -H "Authorization: Bearer $_token" 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null || true
}

# kc_make_password_permanent <token> <user_id> <password> -- resets the credential to the given
# password with temporary:false, then clears requiredActions outright. reset-password alone does
# NOT clear a requiredAction already recorded on the user object -- without the second call, a
# direct grant still fails with "Account is not fully set up" even though the password matches.
kc_make_password_permanent() {
  _token=$1
  _id=$2
  _password=$3
  curl -sk --max-time 15 -f -X PUT "https://keycloak.$DOMAIN/admin/realms/otomi/users/$_id/reset-password" \
    -H "Authorization: Bearer $_token" -H "Content-Type: application/json" \
    -d "{\"type\":\"password\",\"value\":$(printf '%s' "$_password" | jq -Rs .),\"temporary\":false}" \
    || return 1
  curl -sk --max-time 15 -f -X PUT "https://keycloak.$DOMAIN/admin/realms/otomi/users/$_id" \
    -H "Authorization: Bearer $_token" -H "Content-Type: application/json" \
    -d '{"requiredActions":[]}'
}

# kc_resolve_pending <pending_tsv> <resolved_tsv> -- given a TSV file of "email<TAB>password"
# lines for users just created via apl-api, waits ONCE for apl-tasks's Keycloak operator to
# reconcile ALL of them together (bounded: 24 tries, 5s apart, ~120s cap total) -- not one
# 120s-capped wait per user run back-to-back, which is needlessly serial when a single batch of
# git commits gets debounced and reconciled by apl-tasks together anyway. Appends
# "email<TAB>id<TAB>password" to <resolved_tsv> as each is found, and rewrites <pending_tsv> down
# to just what's still unresolved on return -- a non-empty <pending_tsv> after the call means
# those specific users never showed up in Keycloak within the bound; the caller decides whether
# that's fatal.
kc_resolve_pending() {
  _pending=$1
  _resolved=$2
  _tries=0
  while [ -s "$_pending" ] && [ "$_tries" -lt 24 ]; do
    _token=$(kc_master_token) || return 1
    _next=$(mktemp)
    while IFS=$'\t' read -r _email _password; do
      [ -n "$_email" ] || continue
      _id=$(kc_user_id_by_email "$_token" "$_email") || true
      if [ -n "$_id" ]; then
        printf '%s\t%s\t%s\n' "$_email" "$_id" "$_password" >> "$_resolved"
      else
        printf '%s\t%s\n' "$_email" "$_password" >> "$_next"
      fi
    done < "$_pending"
    mv "$_next" "$_pending"
    _tries=$((_tries + 1))
    if [ -s "$_pending" ]; then
      echo "waiting for apl-tasks to reconcile $(wc -l < "$_pending" | tr -d ' ') user(s) in Keycloak (try $_tries/24)..."
      sleep 5
    fi
  done
}

# --- Gitea: scripted OIDC login (no browser) -------------------------------------------------
#
# Gitea accounts are OIDC-JIT-provisioned: they're created only the first time that user
# completes a real SSO login, never proactively. The whole Authorization Code flow is plain HTTP
# redirects + one Keycloak login-form POST + cookies (this lab's Keycloak has no MFA/CAPTCHA), so
# it's fully scriptable with curl -- confirmed live 2026-08-28 for two real users. The one real
# trap: curl's `-L` preserves POST across a redirect (HTTP semantics), but Gitea's OAuth callback
# only accepts GET -- following the POST's Location automatically gets a silent 405 that LOOKS
# like it worked (empty 0-byte body, no error). Do the POST and the callback GET as two separate
# curl calls, never `-L` through both in one.

# gitea_user_by_email <email> -- prints "id username" (space-separated) for an existing Gitea
# user with this email, or nothing if none exists yet. Uses the Gitea CLI inside the pod (admin
# user list), not the API -- no token needed, and this has to work before any token can exist.
gitea_user_by_email() {
  _email=$1
  kubectl --context "$KIND_CTX" --request-timeout=15s exec -n gitea deploy/gitea -c gitea -- gitea admin user list 2>/dev/null \
    | awk -v email="$_email" '$3 == email {print $1, $2}'
}

# gitea_oidc_login <email> <password> -- completes a real Keycloak SSO login against Gitea's
# "otomi-idp" OAuth2 source. ALWAYS actually logs in, even if the account already exists --
# confirmed live: Gitea's OIDC source is configured with --group-claim-name/--group-team-map
# (apl-tasks' gitea-oidc.ts), so org/team membership is (re-)synced from the JWT's `groups`
# claim on EVERY login, not just applied once at account creation. Skipping the login for an
# already-existing account (tried first) leaves that account permanently stuck with whatever
# org membership existed at its very first login -- which can be none at all, if that first
# login happened before the team existed in Gitea's group-team-map. Prints the resulting Gitea
# username either way.
gitea_oidc_login() {
  _email=$1
  _password=$2

  _jar=$(mktemp)
  _s1_headers=$(mktemp)
  _s1_body=$(mktemp)
  curl -sk --max-time 15 -c "$_jar" -D "$_s1_headers" -o "$_s1_body" -L --max-redirs 5 \
    "https://gitea.$DOMAIN/user/oauth2/otomi-idp"
  _action_url=$(grep -o 'action="[^"]*"' "$_s1_body" | head -1 | sed 's/action="//; s/"$//; s/&amp;/\&/g')
  [ -n "$_action_url" ] || { echo "error: no Keycloak login form found at Gitea's otomi-idp entrypoint" >&2; return 1; }

  _s2_headers=$(mktemp)
  curl -sk --max-time 15 -b "$_jar" -c "$_jar" -D "$_s2_headers" -o /dev/null \
    --data-urlencode "username=$_email" --data-urlencode "password=$_password" --data-urlencode "credentialId=" \
    -X POST "$_action_url"
  _callback_url=$(grep -i '^location:' "$_s2_headers" | sed 's/^[Ll]ocation: //; s/\r$//')
  [ -n "$_callback_url" ] || { echo "error: Keycloak login did not redirect -- check the password" >&2; return 1; }

  # Fresh GET, deliberately not -L from the POST above -- see the header comment.
  _s3_headers=$(mktemp)
  curl -sk --max-time 15 -b "$_jar" -c "$_jar" -D "$_s3_headers" -o /dev/null -L --max-redirs 10 -X GET "$_callback_url"
  rm -f "$_jar" "$_s1_headers" "$_s1_body" "$_s2_headers" "$_s3_headers"

  _existing=$(gitea_user_by_email "$_email")
  [ -n "$_existing" ] || { echo "error: Gitea account for $_email was not provisioned after OIDC login" >&2; return 1; }
  printf '%s' "$_existing" | awk '{print $2}'
}

# platform_admin_sso_ready -- 0 if platform-admin can actually complete an SSO login right now.
#
# On a FRESH install Keycloak stamps platform-admin with an UPDATE_PASSWORD required action, so the
# authorization-code flow ends at .../login-actions/required-action?execution=UPDATE_PASSWORD
# instead of at the app's callback -- the app sets no session cookie and the login helper fails
# with something that reads like an app fault but is not one. Confirmed live on the 2026-08-30
# rebuild. `go-task seed:fix-first-login` clears it (and the seed chain depends on that task), so
# anything authenticating as platform-admin before the seed has run must say so rather than guess.
platform_admin_sso_ready() {
  _pasr_token=$(kc_master_token) || return 1
  _pasr_user=$(kubectl --context "$KIND_CTX" --request-timeout=15s get secret platform-admin-initial-credentials \
    -n keycloak -o jsonpath='{.data.username}' | base64 -d)
  [ -n "$_pasr_user" ] || return 1
  _pasr_id=$(kc_user_id_by_email "$_pasr_token" "$_pasr_user") || return 1
  [ -n "$_pasr_id" ] || return 1
  _pasr_n=$(curl -sk --max-time 15 -f "https://keycloak.$DOMAIN/admin/realms/otomi/users/$_pasr_id" \
    -H "Authorization: Bearer $_pasr_token" | jq -r '(.requiredActions // []) | length' 2>/dev/null || echo 1)
  [ "${_pasr_n:-1}" -eq 0 ]
}

# turnstone_oidc_login <email> <password> -- completes the same Keycloak SSO round trip
# gitea_oidc_login does, against Turnstone's console, and prints the path to a cookie jar holding
# the resulting `turnstone_auth_console` session. Caller uses `curl -b "$jar"` and rm's it after.
#
# This is the ONLY way in for a platform identity: Turnstone answers 401 to a raw Keycloak bearer
# exactly as it does to a bogus one (verified live 2026-08-30 on /v1/api/admin/settings and
# /v1/api/models), because it issues its own JWT after the flow rather than trusting Keycloak's.
# What the session then carries is real admin: /v1/api/auth/whoami reports admin.settings,
# admin.models, admin.nodes and the rest for platform-admin, and PUT
# /v1/api/admin/settings/model.default_alias succeeds with it. See CLAUDE.md's OIDC rule.
turnstone_oidc_login() {
  _tol_email=$1
  _tol_password=$2

  _tol_jar=$(mktemp)
  _tol_body=$(mktemp)
  curl -sk --max-time 20 -c "$_tol_jar" -o "$_tol_body" -L --max-redirs 10 \
    "https://turnstone.$DOMAIN/v1/api/auth/oidc/authorize"
  _tol_action=$(grep -o 'action="[^"]*"' "$_tol_body" | head -1 | sed 's/action="//; s/"$//; s/&amp;/\&/g')
  rm -f "$_tol_body"
  [ -n "$_tol_action" ] || { echo "error: no Keycloak login form at Turnstone's oidc/authorize entrypoint" >&2; rm -f "$_tol_jar"; return 1; }

  _tol_headers=$(mktemp)
  curl -sk --max-time 20 -b "$_tol_jar" -c "$_tol_jar" -D "$_tol_headers" -o /dev/null \
    --data-urlencode "username=$_tol_email" --data-urlencode "password=$_tol_password" --data-urlencode "credentialId=" \
    -X POST "$_tol_action"
  _tol_cb=$(grep -i '^location:' "$_tol_headers" | sed 's/^[Ll]ocation: //; s/\r$//')
  rm -f "$_tol_headers"
  [ -n "$_tol_cb" ] || { echo "error: Keycloak did not redirect for $_tol_email -- check the password" >&2; rm -f "$_tol_jar"; return 1; }

  # Fresh GET rather than -L off the POST, same as gitea_oidc_login: curl would replay the POST
  # body at the callback otherwise.
  curl -sk --max-time 20 -b "$_tol_jar" -c "$_tol_jar" -o /dev/null -L --max-redirs 10 -X GET "$_tol_cb"
  grep -q turnstone_auth_console "$_tol_jar" || { echo "error: no turnstone_auth_console cookie after the OIDC callback" >&2; rm -f "$_tol_jar"; return 1; }
  printf '%s' "$_tol_jar"
}

# turnstone_mint_agent_pat <email> <password> [name] -- mint a long-lived Turnstone API PAT bound
# to the agent's user, the same shape as gitea_mint_pat / vikunja_mint_api_token. The Turnstone
# user is OIDC-provisioned, so this first does the agent's OIDC login (which CREATES the user on a
# cold cluster) to resolve its user_id, then mints an opaque `ts_` PAT with turnstone-admin (no
# password needed for the mint; the PAT carries the agent user's own permissions). The SDK needs a
# BEARER token -- the OIDC session cookie is NOT one (it hits the coordinator-gated console
# surface), which is why the pipeline uses this PAT, not the cookie. Prints the ts_ token.
turnstone_mint_agent_pat() {
  _tma_email=$1; _tma_pw=$2; _tma_name=${3:-agent-node}
  _tma_jar=$(turnstone_oidc_login "$_tma_email" "$_tma_pw") \
    || { echo "error: turnstone OIDC login failed for $_tma_email (needed to provision the user)" >&2; return 1; }
  _tma_uid=$(curl -sk --max-time 15 -b "$_tma_jar" "https://turnstone.$DOMAIN/v1/api/auth/whoami" | jq -r '.user_id // empty' 2>/dev/null)
  rm -f "$_tma_jar"
  [ -n "$_tma_uid" ] || { echo "error: could not resolve Turnstone user_id for $_tma_email" >&2; return 1; }
  _tma_tok=$(kubectl --context "$KIND_CTX" --request-timeout=30s exec -n turnstone deploy/turnstone-server -c server -- \
    turnstone-admin create-token --user "$_tma_uid" --name "${_tma_name}-$(date +%s)" --expires-days 3650 2>/dev/null \
    | tr -d '\r' | grep -oE 'ts_[A-Za-z0-9._-]+' | head -1)
  [ -n "$_tma_tok" ] || { echo "error: turnstone-admin create-token produced no token for $_tma_email" >&2; return 1; }
  printf '%s' "$_tma_tok"
}

# turnstone_admin_jar -- OIDC-login as platform-admin and print the cookie-jar path holding a
# turnstone_auth_console session with full admin (persona.create, admin.skills, admin.policies).
# The OIDC login itself provisions the platform-admin Turnstone user on first call. Caller rm's it.
turnstone_admin_jar() {
  _taj_u=$(kubectl --context "$KIND_CTX" --request-timeout=15s get secret platform-admin-initial-credentials \
    -n keycloak -o jsonpath='{.data.username}' | base64 -d)
  _taj_p=$(kubectl --context "$KIND_CTX" --request-timeout=15s get secret platform-admin-initial-credentials \
    -n keycloak -o jsonpath='{.data.password}' | base64 -d)
  [ -n "$_taj_u" ] && [ -n "$_taj_p" ] || { echo "error: platform-admin-initial-credentials came back empty" >&2; return 1; }
  turnstone_oidc_login "$_taj_u" "$_taj_p"
}

# turnstone_upsert_persona <jar> <name> <create-json> -- create the persona (POST
# /v1/api/admin/personas) if <name> is absent, else PATCH its mutable levers
# (/v1/api/admin/personas/<id>). <create-json> is a full CreatePersonaRequest; on PATCH,
# `name` and `applies_to_kinds` are immutable and dropped. Idempotent -- safe to re-run.
turnstone_upsert_persona() {
  _tup_jar=$1; _tup_name=$2; _tup_body=$3
  _tup_id=$(curl -sk --max-time 15 -b "$_tup_jar" "https://turnstone.$DOMAIN/v1/api/personas" \
    | jq -r --arg n "$_tup_name" '.personas[]? | select(.name==$n) | .persona_id' 2>/dev/null | head -1)
  if [ -z "$_tup_id" ]; then
    _tup_h=$(curl -sk --max-time 15 -b "$_tup_jar" -o /dev/null -w '%{http_code}' -X POST \
      "https://turnstone.$DOMAIN/v1/api/admin/personas" -H "Content-Type: application/json" -d "$_tup_body")
    [ "${_tup_h:-0}" -lt 300 ] || { echo "error: create persona $_tup_name -> HTTP $_tup_h" >&2; return 1; }
    echo "persona $_tup_name created" >&2
  else
    _tup_patch=$(printf '%s' "$_tup_body" | jq 'del(.name, .applies_to_kinds, .enabled)')
    _tup_h=$(curl -sk --max-time 15 -b "$_tup_jar" -o /dev/null -w '%{http_code}' -X PATCH \
      "https://turnstone.$DOMAIN/v1/api/admin/personas/$_tup_id" -H "Content-Type: application/json" -d "$_tup_patch")
    [ "${_tup_h:-0}" -lt 300 ] || { echo "error: update persona $_tup_name -> HTTP $_tup_h" >&2; return 1; }
    echo "persona $_tup_name updated" >&2
  fi
}

# turnstone_upsert_skill <jar> <name> <create-json> -- create the skill (POST /v1/api/admin/skills)
# if <name> is absent, else replace it (PUT /v1/api/admin/skills/<id>). Idempotent.
turnstone_upsert_skill() {
  _tus_jar=$1; _tus_name=$2; _tus_body=$3
  _tus_id=$(curl -sk --max-time 15 -b "$_tus_jar" "https://turnstone.$DOMAIN/v1/api/skills" \
    | jq -r --arg n "$_tus_name" '((.skills // .)[]? | select(.name==$n) | .template_id)' 2>/dev/null | head -1)
  if [ -z "$_tus_id" ]; then
    _tus_h=$(curl -sk --max-time 15 -b "$_tus_jar" -o /dev/null -w '%{http_code}' -X POST \
      "https://turnstone.$DOMAIN/v1/api/admin/skills" -H "Content-Type: application/json" -d "$_tus_body")
    [ "${_tus_h:-0}" -lt 300 ] || { echo "error: create skill $_tus_name -> HTTP $_tus_h" >&2; return 1; }
    echo "skill $_tus_name created" >&2
  else
    _tus_h=$(curl -sk --max-time 15 -b "$_tus_jar" -o /dev/null -w '%{http_code}' -X PUT \
      "https://turnstone.$DOMAIN/v1/api/admin/skills/$_tus_id" -H "Content-Type: application/json" -d "$_tus_body")
    [ "${_tus_h:-0}" -lt 300 ] || { echo "error: update skill $_tus_name -> HTTP $_tus_h" >&2; return 1; }
    echo "skill $_tus_name updated" >&2
  fi
}

# gitea_refire_push_hook <org> <repo> <pat> -- re-send a push delivery for every push webhook on
# the repo, via Gitea's own hook test endpoint (it delivers a real payload for the default branch's
# latest commit, not a synthetic one).
#
# Gitea fires `push` EXACTLY ONCE and never retries. A delivery lost for any reason -- the
# EventListener still starting, a NetworkPolicy mid-apply, Gitea restarting -- means the build is
# never triggered, and the seed then fails minutes later in a completely different place: a Harbor
# tag that never appears, or a PipelineRun that was never created. Confirmed live 2026-08-30, when
# the agent-base build never started: the EventListener's log was EMPTY while a probe POST from the
# Gitea pod reached it with HTTP 202, so connectivity was fine and the delivery simply never
# happened. Re-firing this one endpoint fixed it in seconds.
#
# Same reasoning as runner_drain_queued, which recovers the equivalent loss for `workflow_job`.
gitea_refire_push_hook() {
  _grh_org=$1
  _grh_repo=$2
  _grh_pat=$3
  _grh_ids=$(curl -sk --max-time 15 -H "Authorization: token $_grh_pat" \
    "https://gitea.$DOMAIN/api/v1/repos/$_grh_org/$_grh_repo/hooks" \
    | jq -r '.[]? | select((.events // []) | index("push")) | .id' 2>/dev/null || true)
  [ -n "$_grh_ids" ] || { echo "  no push webhook on $_grh_org/$_grh_repo to re-fire" >&2; return 1; }
  for _grh_id in $_grh_ids; do
    _grh_code=$(curl -sk --max-time 20 -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: token $_grh_pat" \
      "https://gitea.$DOMAIN/api/v1/repos/$_grh_org/$_grh_repo/hooks/$_grh_id/tests" 2>/dev/null || true)
    echo "  re-fired the push delivery for hook $_grh_id on $_grh_org/$_grh_repo (HTTP $_grh_code)"
  done
}

# gitea_mint_pat <username> <scopes-csv> -- mints a fresh Personal Access Token for an existing
# Gitea user via the CLI (no login needed once the account exists), and prints it. Token names
# must be unique per user in Gitea and can't be reused once consumed, so this always mints a
# freshly-named one rather than trying to reuse/detect an old one -- cheap, and these are
# lab-only automation tokens.
gitea_mint_pat() {
  _username=$1
  _scopes=$2
  _name="seed-$(mktemp -u XXXXXX)"
  kubectl --context "$KIND_CTX" --request-timeout=15s exec -n gitea deploy/gitea -c gitea -- \
    gitea admin user generate-access-token -u "$_username" -t "$_name" --scopes "$_scopes" --raw
}

# gitea_wait_for_org_permission <username> <org> <pat> <permission-field> -- safety-net check,
# NOT the actual sync mechanism: gitea_oidc_login's login (via Gitea's --group-team-map OIDC
# config) is what grants org membership, synchronously, at login time -- confirmed live, it's
# already in place by the time this runs. This just guards against any residual propagation
# delay: bounded 6 tries, 3s apart, ~18s cap. If this is still false after 18s, something is
# actually wrong (e.g. the team doesn't exist yet in Gitea's group-team-map) -- not a matter of
# waiting longer. <permission-field> is a key from GET .../orgs/{org}/permissions -- typically
# "can_create_repository" for a team-admin (dev, mapped to the org's Owners team) or "can_read"
# for a plain member (po/agent, who should never get create rights, only membership).
gitea_wait_for_org_permission() {
  _username=$1
  _org=$2
  _pat=$3
  _field=$4
  _tries=0
  while [ "$_tries" -lt 6 ]; do
    # `|| true` on the whole pipeline: this runs under the caller's `set -euo pipefail`, where a
    # single transient curl/jq failure would otherwise abort the step instead of being retried by
    # the very loop that exists to retry it.
    _can=$(curl -sk --max-time 10 "https://gitea.$DOMAIN/api/v1/users/$_username/orgs/$_org/permissions" \
      -H "Authorization: token $_pat" 2>/dev/null | jq -r --arg f "$_field" '.[$f] // false' 2>/dev/null || true)
    [ "$_can" = "true" ] && return 0
    _tries=$((_tries + 1))
    echo "waiting for $_username to show $_field in Gitea org $_org (try $_tries/6)..."
    sleep 3
  done
  echo "error: $_username never got $_field in Gitea org $_org within 18s" >&2
  return 1
}

# gitea_ensure_team_credentials <team> [<team>...] -- make sure every named team namespace really
# has the `gitea-credentials` Secret that apl-gitea-operator is supposed to put there, nudging the
# operator at most once if it doesn't.
#
# WHY THIS EXISTS -- an upstream bug in linode/apl-tasks, not something wrong in this repo.
# Confirmed live 2026-08-29 with three brand-new teams (red/yellow/purple), exact timeline from
# `kubectl get ... -o custom-columns=...CREATED` and the operator's own --timestamps log:
#
#   01:35:36  namespace team-red created (ArgoCD, team-ns chart)
#   01:35:41  apl-gitea-operator: "Replacing secret for gitea-credentials in namespace team-red"
#             -> HTTP 403 "...cannot update resource \"secrets\"... in the namespace \"team-red\""
#   01:35:49  Role/RoleBinding apl-gitea-operator-service-account{,-binding} created in team-red
#             (charts/team-ns/templates/rbac.yaml -- EIGHT SECONDS AFTER the operator needed them)
#
# So the operator raced its own RBAC grant. That alone would be survivable; what makes it fatal is
# what the operator does next -- nothing, forever:
#
#   * apl-tasks' `setUserSecret` (dist/src/operators/gitea/lib/managers/gitea-users.js, read
#     straight out of the running linode/apl-tasks:main image) has a retry path for exactly ONE
#     error code -- 404, "secret doesn't exist yet, create it instead". Every other error, 403
#     included, falls through to a bare `console.error(...)` and `return password`. It is not
#     rethrown, and it is not pushed onto the `errors` array `setupGitea` checks -- so the very
#     same run still logs "Success! Gitea setup/reconfiguration completed".
#   * `setupGitea` is purely event-driven. It runs only from `secretsAndConfigmapsCallback`, on an
#     Added/Modified watch event for `apl-gitea-operator-cm` / `apl-gitea-operator-secret` in the
#     operator's own namespace. The only periodic timer in the whole operator is the 30s Gitea
#     OIDC-config check, which does not touch team secrets. Adding a team fires the configmap
#     watch once; if that one pass 403s, nothing ever fires it again.
#
# Measured: team-red sat with no secret for ~9 minutes (01:35:41 -> 01:44:27) with the operator
# alive and logging its OIDC check every 30s the whole time. It does NOT self-heal.
#
# Downstream symptom, which is how this was found: the git-clone Task's `fetch-source` pod for the
# team's first build sits at Init:0/2 forever with
#   Warning FailedMount ... MountVolume.SetUp failed for volume "ws-xxxxx": secret
#   "gitea-credentials" not found
# and seed:apps' PipelineRun wait times out -- for new teams only. Teams created on an earlier pass
# are unaffected, which is what makes this look like a SEED_TEAMS parameterization bug and isn't.
#
# THE NUDGE. On startup the operator's watches replay Added events for the existing cm/secret, so
# `setupGitea` runs again -- and `createUsers` regenerates and rewrites `gitea-credentials` for
# EVERY team org unconditionally, not just missing ones. So restarting the operator heals every
# stuck team in one pass. Verified live: deleting the pod at 01:44:2x produced
# gitea-credentials in team-red, team-yellow AND team-purple all stamped 01:44:27Z.
#
# Deleting the POD, never `rollout restart` and never a patch: this is asking a controller to
# re-run its own reconcile loop, which CLAUDE.md rule 6 is not about. `rollout restart` would stamp
# `kubectl.kubernetes.io/restartedAt` onto the Deployment's pod template -- a real spec diff that
# ArgoCD's selfHeal would fight. A plain pod delete changes no spec at all; the Deployment's own
# ReplicaSet recreates it, and ArgoCD has nothing to revert.
#
# Bounded and at most one nudge per call (CLAUDE.md rule 1), and idempotent: on an already-healthy
# cluster phase 1 returns on its first poll and nothing is restarted.
gitea_ensure_team_credentials() {
  set -euo pipefail
  _gtc_teams="$*"

  # Prints the teams still missing the secret, space-separated (empty == all present).
  _gtc_missing() {
    _out=""
    for _t in $_gtc_teams; do
      kubectl --context "$KIND_CTX" --request-timeout=15s get secret gitea-credentials \
        -n "team-$_t" -o name >/dev/null 2>&1 || _out="$_out$_t "
    done
    printf '%s' "$_out"
  }

  # Phase 1 -- just wait. On a healthy run the operator has already written these (green/blue got
  # theirs within seconds of the namespace existing) and this returns on the first poll. 60s, not
  # longer: when it works at all it works within ~5s of the namespace existing, so this is already
  # 12x the observed latency, and every second past that is dead time on every new-team run.
  _tries=0
  while [ "$_tries" -lt 6 ]; do
    _miss=$(_gtc_missing)
    [ -z "$_miss" ] && { echo "gitea-credentials present in every team namespace: $_gtc_teams"; return 0; }
    _tries=$((_tries + 1))
    echo "waiting for apl-gitea-operator to write gitea-credentials for: $_miss(try $_tries/6)..."
    sleep 10
  done

  # Phase 2 -- still missing after 60s. Before nudging, confirm the RBAC grant the operator needs
  # has actually landed in each missing namespace. Restarting while the RoleBinding is still absent
  # would just reproduce the same 403 and waste the one nudge this function allows itself.
  _tries=0
  while [ "$_tries" -lt 12 ]; do
    _rbac_ok=true
    for _t in $_miss; do
      kubectl --context "$KIND_CTX" --request-timeout=15s get rolebinding \
        apl-gitea-operator-service-account-binding -n "team-$_t" -o name >/dev/null 2>&1 || _rbac_ok=false
    done
    [ "$_rbac_ok" = "true" ] && break
    _tries=$((_tries + 1))
    echo "waiting for apl-gitea-operator-service-account-binding in: $_miss(try $_tries/12)..."
    sleep 10
  done
  [ "$_rbac_ok" = "true" ] || {
    echo "error: apl-gitea-operator-service-account-binding never appeared in team-ns for: $_miss" >&2
    echo "       (that RoleBinding is charts/team-ns/templates/rbac.yaml -- if it is missing after" >&2
    echo "        4 minutes the team's ArgoCD Application itself is not syncing; this is NOT the" >&2
    echo "        403 race this function works around)" >&2
    return 1
  }

  echo "nudging apl-gitea-operator: RBAC is in place but gitea-credentials is still missing for: $_miss"
  echo "(upstream linode/apl-tasks swallows the 403 it hit before that RBAC landed and never retries"
  echo " -- restarting its pod replays the configmap watch and rewrites the secret for every team)"
  kubectl --context "$KIND_CTX" --request-timeout=30s delete pod -n apl-gitea-operator \
    -l app.kubernetes.io/name=apl-gitea-operator

  # Phase 3 -- poll again. The restart also re-waits for Gitea availability before its watches
  # start, so allow the same 120s rather than expecting it within seconds.
  _tries=0
  while [ "$_tries" -lt 12 ]; do
    _miss=$(_gtc_missing)
    [ -z "$_miss" ] && { echo "gitea-credentials written after the nudge for every team: $_gtc_teams"; return 0; }
    _tries=$((_tries + 1))
    echo "waiting for gitea-credentials after the operator nudge for: $_miss(try $_tries/12)..."
    sleep 10
  done

  echo "error: gitea-credentials still missing after a bounded operator restart for: $_miss" >&2
  echo "       check 'kubectl logs -n apl-gitea-operator deploy/apl-gitea-operator | grep gitea-credentials'" >&2
  return 1
}

# --- Harbor -----------------------------------------------------------------------------------

# harbor_oidc_login <email> <password> -- completes Harbor's own Keycloak SSO round trip, the same
# shape as gitea_oidc_login. Returns 0 on success; prints nothing on the happy path.
#
# Harbor needs this ONCE per identity before its API will treat that identity as anything at all.
# A raw Keycloak bearer for a user Harbor has never seen is handled as ANONYMOUS: reads return only
# public projects and writes fail with 401 (not 403 -- the 401/403 distinction is how you tell
# "unknown identity" from "known identity, wrong role"). After one login the user row exists and
# the same bearer is a full identity. Verified live 2026-08-30 on a fresh cluster.
harbor_oidc_login() {
  _hol_email=$1
  _hol_password=$2

  _hol_jar=$(mktemp)
  _hol_body=$(mktemp)
  curl -sk --max-time 20 -c "$_hol_jar" -o "$_hol_body" -L --max-redirs 10 "https://harbor.$DOMAIN/c/oidc/login"
  _hol_action=$(grep -o 'action="[^"]*"' "$_hol_body" | head -1 | sed 's/action="//; s/"$//; s/&amp;/\&/g')
  rm -f "$_hol_body"
  [ -n "$_hol_action" ] || { echo "error: no Keycloak login form at Harbor's /c/oidc/login" >&2; rm -f "$_hol_jar"; return 1; }

  _hol_headers=$(mktemp)
  curl -sk --max-time 20 -b "$_hol_jar" -c "$_hol_jar" -D "$_hol_headers" -o /dev/null \
    --data-urlencode "username=$_hol_email" --data-urlencode "password=$_hol_password" --data-urlencode "credentialId=" \
    -X POST "$_hol_action"
  _hol_cb=$(grep -i '^location:' "$_hol_headers" | sed 's/^[Ll]ocation: //; s/\r$//')
  rm -f "$_hol_headers"
  case "$_hol_cb" in
    *required-action*)
      echo "error: $_hol_email has a pending Keycloak required action -- run 'go-task seed:fix-first-login'" >&2
      rm -f "$_hol_jar"; return 1 ;;
    "")
      echo "error: Keycloak did not redirect for $_hol_email -- check the password" >&2
      rm -f "$_hol_jar"; return 1 ;;
  esac

  curl -sk --max-time 20 -b "$_hol_jar" -c "$_hol_jar" -o /dev/null -L --max-redirs 10 -X GET "$_hol_cb"
  grep -qi 'sid' "$_hol_jar" || { echo "error: no Harbor session cookie after the OIDC callback" >&2; rm -f "$_hol_jar"; return 1; }
  rm -f "$_hol_jar"
}

# harbor_ensure_platform_admin -- log platform-admin into Harbor once, so harbor_token's bearer is a
# real identity. Call it ONCE in a task preamble, before any parallel work; it is deliberately NOT
# called from harbor_token, because apl_run_parallel would then run one login per team subshell,
# concurrently, for no benefit.
#
# platform-admin specifically, because it is the only identity that can do what the seed needs:
# Harbor's oidc_admin_group is set to `platform-admin`, so that group's members act as Harbor
# sysadmins. A TEAM ADMIN cannot -- apl-harbor-operator binds `team-<team>` as **developer** and
# gives projectAdmin to `all-teams-admin`, which has no members, so a team admin gets 403 flipping
# its own project's visibility even though the Console shows it as team admin. Verified live
# 2026-08-30 for dev-ratings, and by hand in the Harbor web UI. Changing that would be an
# apl-harbor-operator change in apl-tasks, not a seed change.
_HARBOR_PLATFORM_ADMIN_READY=""
harbor_ensure_platform_admin() {
  [ -n "${_HARBOR_PLATFORM_ADMIN_READY:-}" ] && return 0
  _hepa_user=$(kubectl --context "$KIND_CTX" --request-timeout=15s get secret platform-admin-initial-credentials \
    -n keycloak -o jsonpath='{.data.username}' | base64 -d)
  _hepa_pass=$(kubectl --context "$KIND_CTX" --request-timeout=15s get secret platform-admin-initial-credentials \
    -n keycloak -o jsonpath='{.data.password}' | base64 -d)
  [ -n "$_hepa_user" ] && [ -n "$_hepa_pass" ] || { echo "error: platform-admin-initial-credentials came back empty" >&2; return 1; }
  harbor_oidc_login "$_hepa_user" "$_hepa_pass" || return 1
  _HARBOR_PLATFORM_ADMIN_READY=1
  echo "platform-admin signed in to Harbor (its API bearer is now a real identity, with sysadmin via oidc_admin_group)"
}

# harbor_token -- a platform-admin OIDC access token, accepted by Harbor's API as a bearer
# credential. Harbor runs in auth_mode oidc_auth against the same Keycloak realm as everything
# else here, so the platform's own admin identity IS a Harbor admin identity -- no second
# credential, no bootstrap password, nothing app-specific. Verified live 2026-08-30: GET /users
# and GET /configurations (both admin-only, both 401 for anonymous AND for a bogus bearer) return
# 200, and a PUT to /projects/{id} succeeds, all with this token.
#
# What does NOT work, and is the trap worth remembering: platform-admin's Keycloak PASSWORD as
# HTTP basic auth. Harbor rejects it with 401, identically to anonymous -- OIDC-provisioned
# accounts carry no local password the API accepts, exactly as MCP.md records for Gitea. The
# credential is the token, not the password. (Beware measuring this against a PUBLIC project's
# read endpoints: those answer 200 for anyone, including a bogus credential, so they cannot tell
# you whether authentication happened. Use an admin-only endpoint.)
#
# Minted fresh on every call rather than cached: these helpers are called around multi-minute image
# builds, and kc_platform_admin_token's own comment records tokens expiring across exactly such a
# wait. Four kubectl gets and one curl is cheap next to what it sits between.
harbor_token() {
  kc_platform_admin_token "${OAUTH2_PROXY_CLIENT_SECRET_NAME:-oauth2-proxy-client-access}"
}

# harbor_ensure_project is NOT used by the Bookinfo seed below: Bookinfo's four
# Dockerfiles keep their upstream public `FROM` lines (python/ruby/node/gradle/open-liberty) and
# kaniko pulled every one of them straight from the public registry, confirmed live 2026-08-29 --
# all four `docker-trigger-build-*` PipelineRuns Succeeded. Those same builds also install packages
# over the network (pip/bundle/npm/gradle/featureUtility), so in-cluster builds on this lab reach
# both public registries and public package indexes fine.
#
# harbor_ensure_project is kept, unused, as the ready-made fallback if that ever stops being true
# on some future cluster. harbor_mirror, which used to sit beside it, was DELETED on 2026-08-30:
# it was the last thing reaching for the Harbor bootstrap password, and since nothing sets that
# variable any more it could not have run as written. The recipe it encoded is preserved here in
# full, which is all it was ever worth -- three commands, no state, run from the HOST because that
# is what has unrestricted egress:
#
#   1. harbor_ensure_project "<project>"                       # e.g. the team's own project
#   2. docker run --rm --network host quay.io/skopeo/stable:latest \
#        copy --dest-tls-verify=false --dest-creds "admin:<harbor bootstrap password>" \
#        "docker://python:3.13.3-slim" \
#        "docker://harbor.$DOMAIN/<project>/python:3.13.3-slim"          # once per base image
#   3. sed -i "s|^FROM python:3.13.3-slim|FROM harbor.$DOMAIN/<project>/python:3.13.3-slim|" \
#        <pushed Dockerfile>                                   # repoint FROM at the Harbor copy
#
# `--dest-tls-verify=false` is required in step 2: the host's Docker daemon does not trust the
# platform's self-signed CA any more than a pod does, which is also why a plain `docker push` fails
# here (see CLAUDE.md's CA note). skopeo copy is idempotent -- it overwrites the same tag.
#
# Step 2 is the one place the bootstrap password is still the right credential and OIDC is not:
# skopeo talks to the REGISTRY, not the API, and registry auth for an OIDC user is a per-user CLI
# secret rather than a bearer token. Everything API-shaped moved to OIDC; this cannot.
# `kubectl get secret harbor-admin-password -n harbor -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}'`
# still yields it, base64-decoded.
#
# The seed deliberately does not rewrite `FROM`: the unmodified upstream source IS the demo
# content, and rewriting it would make the demo a fork of Bookinfo rather than a copy of it.

# harbor_ensure_project <project> -- creates a public Harbor project if it doesn't already exist.
harbor_ensure_project() {
  _project=$1
  _hep_tok=$(harbor_token) || return 1
  _http=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $_hep_tok" \
    -X POST "https://harbor.$DOMAIN/api/v2.0/projects" -H "Content-Type: application/json" \
    -d "{\"project_name\":\"$_project\",\"public\":true}")
  case "$_http" in
    201) echo "created Harbor project '$_project'" ;;
    409) echo "Harbor project '$_project' already exists" ;;
    *) echo "error: Harbor project creation for '$_project' returned HTTP $_http" >&2; return 1 ;;
  esac
}

# harbor_has_tag <project> <repo> <tag> -- 0 if that exact tag exists in Harbor. Needs
# a platform-admin OIDC token via harbor_token (same as the others). Used to answer "is there
# already a built image for this repo?" without re-running a build -- the seed only rebuilds when
# the pushed source actually changed, so on a rerun this is what proves the previous run's build
# really produced something.
# Retried, because an EMPTY %{http_code} is not an answer. Under real load from concurrent Tekton
# builds curl returns no status at all (see the note on apl_create_if_missing below), and treating
# that as "no tag" is a SILENT false negative: seed:runners rebuilds an image it already had, and
# seed:apps takes the rebuild branch for source it already built. Confirmed live 2026-08-30 -- all
# four teams got an empty status within the same second, which is why nothing skipped that run.
# A persistent non-answer still returns 1 (callers use this in an `if`), but says so on stderr
# rather than passing silently for "no".
harbor_has_tag() {
  _ht_tok=$(harbor_token) || return 1
  _ht_i=0
  while [ "$_ht_i" -lt 3 ]; do
    _ht_i=$((_ht_i + 1))
    _ht_code=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $_ht_tok" \
      "https://harbor.$DOMAIN/api/v2.0/projects/$1/repositories/$2/artifacts/$3" 2>/dev/null || true)
    case "$_ht_code" in
      # Written out rather than `[ ... ]; return $?`: a bare failing test is fatal under errexit,
      # and this function must stay safe to call outside an `if` condition.
      [0-9][0-9][0-9])
        if [ "$_ht_code" = "200" ]; then return 0; else return 1; fi ;;
      *) sleep 5 ;;
    esac
  done
  echo "error: Harbor never returned a status for $1/$2:$3 in 3 tries -- treating as absent, which may cause a needless rebuild" >&2
  return 1
}

# harbor_make_project_public <project> -- flip an EXISTING Harbor project to public. Authenticates
# with a platform-admin OIDC token via harbor_token, like the others.
#
# Separate from harbor_ensure_project because the platform operator creates a team's project itself,
# as PRIVATE -- so the create call 409s and the visibility never changes. A private project is fine
# until something outside the team has to pull from it, which is exactly the platform agent layer's
# job: every team's kaniko build does COPY --from against team-platform/agent-base.
harbor_make_project_public() {
  _hmp_project=$1
  _hmp_tok=$(harbor_token) || return 1
  _hmp_id=$(curl -sk --max-time 15 -H "Authorization: Bearer $_hmp_tok" \
    "https://harbor.$DOMAIN/api/v2.0/projects?name=$_hmp_project" 2>/dev/null | jq -r '.[0].project_id // empty')
  [ -n "$_hmp_id" ] || { echo "error: Harbor project '$_hmp_project' not found" >&2; return 1; }
  _hmp_code=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $_hmp_tok" \
    -X PUT "https://harbor.$DOMAIN/api/v2.0/projects/$_hmp_id" -H "Content-Type: application/json" \
    -d '{"metadata":{"public":"true"}}')
  case "$_hmp_code" in
    200) echo "Harbor project '$_hmp_project' is public" ;;
    *) echo "error: making Harbor project '$_hmp_project' public returned HTTP $_hmp_code" >&2; return 1 ;;
  esac
}

# harbor_delete_tag <project> <repo> <tag> -- delete one tag's artifact. Authenticates with a
# platform-admin OIDC token via harbor_token, like the others.
#
# Used only by SEED_FORCE_RUNNER_BUILD. The runner build is trigger:false and seed:runners skips it
# when the tag exists, so deleting the tag is what makes a changed .gitea/runner/Dockerfile
# actually rebuild on a cluster that already has the image.
harbor_delete_tag() {
  # Same empty-status retry as harbor_has_tag, and for the same reason: this runs at the very start
  # of seed:runners, four teams at once, which is exactly when Harbor is least likely to answer.
  _hdt_tok=$(harbor_token) || return 1
  _hdt_i=0
  _hdt_code=""
  while [ "$_hdt_i" -lt 3 ]; do
    _hdt_i=$((_hdt_i + 1))
    _hdt_code=$(curl -sk --max-time 20 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $_hdt_tok" \
      -X DELETE "https://harbor.$DOMAIN/api/v2.0/projects/$1/repositories/$2/artifacts/$3" 2>/dev/null || true)
    case "$_hdt_code" in
      [0-9][0-9][0-9]) break ;;
      *) sleep 5 ;;
    esac
  done
  case "$_hdt_code" in
    200|404) echo "harbor tag $1/$2:$3 removed (HTTP $_hdt_code)" ;;
    *) echo "error: deleting harbor tag $1/$2:$3 returned HTTP $_hdt_code" >&2; return 1 ;;
  esac
}

# --- apl-api: create-if-missing ---------------------------------------------------------------

# apl_create_if_missing <get_url> <post_url> <token> <body> <label> -- unlike /v2/teams (which
# upserts cleanly on a repeat POST), coderepos/builds/workloads/services all 409 on a repeat POST
# -- confirmed live 2026-08-28 for all four. GETs <get_url> first; only POSTs if that 404s.
#
# Confirmed live 2026-08-29: a transient connection failure (node under real load from concurrent
# Tekton builds) makes curl's `%{http_code}` come back EMPTY rather than a real status -- `-s`
# suppresses curl's own error text, so there is no diagnostic at all. The numeric comparison
# `[ "$_post_http" -ge 300 ]` against that empty string is not just false, it is a shell error
# ("integer expression expected") -- which an `if` condition swallows as "false" rather than
# propagating, so the function fell through to `rm -f`/implicit success, having created NOTHING,
# with zero output anywhere. This is what silently broke a workload/service creation deep inside
# a 9-team rollout with nothing in the log to explain it. Every HTTP-code variable is now
# validated as exactly 3 digits before being compared or trusted.
apl_create_if_missing() {
  # Serialised across concurrent teams. Every object this creates is a COMMIT to the one shared
  # git values repo behind apl-api, so four teams calling this at once is a push race on a single
  # repository. The lock also makes the check-then-act below atomic, which it never was: two
  # callers could both see 404 and both POST.
  #
  # The lock is held for the two HTTP calls only -- seconds. What actually takes the time in a
  # parallel seed is the waiting around them (180s for a webhook, 90s for an EventListener,
  # minutes for a build), and none of that is serialised.
  apl_with_api_lock _apl_create_if_missing_locked "$@"
}

_apl_create_if_missing_locked() {
  _get_url=$1
  _post_url=$2
  _token=$3
  _body=$4
  _label=$5
  _get_http=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' "$_get_url" -H "Authorization: Bearer $_token")
  case "$_get_http" in
    [0-9][0-9][0-9]) ;;
    *) echo "error: checking whether $_label exists got no valid HTTP status back (curl said: '$_get_http') -- likely a transient connection failure" >&2; return 1 ;;
  esac
  if [ "$_get_http" = "200" ]; then
    echo "$_label already exists -- skipping create"
    return 0
  fi
  _out=$(mktemp)
  _post_http=$(curl -sk --max-time 15 -o "$_out" -w '%{http_code}' -X POST "$_post_url" \
    -H "Authorization: Bearer $_token" -H "Content-Type: application/json" -d "$_body")
  case "$_post_http" in
    [0-9][0-9][0-9]) ;;
    *) echo "error: creating $_label got no valid HTTP status back (curl said: '$_post_http') -- likely a transient connection failure" >&2; rm -f "$_out"; return 1 ;;
  esac
  if [ "$_post_http" -ge 300 ]; then
    echo "error: creating $_label returned HTTP $_post_http: $(cat "$_out")" >&2
    rm -f "$_out"
    return 1
  fi
  rm -f "$_out"
}

# --- Gitea: repo content ----------------------------------------------------------------------

# gitea_create_org_repo <org> <repo> <pat> -- creates a repo under a team's Gitea org, auto-
# initialized (gets a main branch immediately, needed before anything can be pushed to it).
# Idempotent: an already-existing repo (409/422) is treated as success, and its visibility is
# re-asserted below either way, so a repo left private by an older seed converges on a re-run.
#
# `private: false`, deliberately, and it is load-bearing in two ways.
#
# It models what this demo is simulating. In a real engineering org every team can READ every other
# team's source; only the owning team can WRITE. Gitea gives exactly that here without any extra
# machinery, because write permission comes from ORG MEMBERSHIP -- which the platform already drives
# from each user's Keycloak group claims on every OIDC login (Gitea's --group-team-map). So flipping
# visibility changes only the read side. Private repos would instead mean team-ratings cannot read
# team-reviews' code, which is a strange thing to demonstrate.
#
# And it removes a credential entirely. Argo CD clones these repos to sync the runner workload whose
# chart lives in them; against a private repo that needs a stored Gitea credential in the argocd
# namespace, and since a repo-creds entry matches by URL PREFIX, one entry would need a credential
# able to read every org -- i.e. the Gitea admin, handed permanent instance-wide access to read four
# repos. A public repo is cloned anonymously. The best fix for a credential is not needing one.
#
# Note what "public" does and does not mean on this lab: gitea.gotmpl sets service.REQUIRE_SIGNIN_VIEW
# false but service.explore.REQUIRE_SIGNIN_VIEW true, so these repos are not discoverable by browsing
# without signing in, but are readable by anyone holding the URL who can reach the ingress. Gitea has
# no true "internal" visibility tier. Making it strictly internal means instance-wide
# REQUIRE_SIGNIN_VIEW, which would put Argo CD back to needing a credential.
gitea_create_org_repo() {
  _org=$1
  _repo=$2
  _pat=$3
  _out=$(mktemp)
  _http=$(curl -sk --max-time 15 -o "$_out" -w '%{http_code}' -X POST "https://gitea.$DOMAIN/api/v1/org/$_org/repos" \
    -H "Authorization: token $_pat" -H "Content-Type: application/json" \
    -d "{\"name\":\"$_repo\",\"private\":false,\"auto_init\":true}")
  case "$_http" in
    201) echo "created Gitea repo $_org/$_repo (readable org-wide, writable by team-$_org members)" ;;
    409 | 422) echo "Gitea repo $_org/$_repo already exists" ;;
    *) echo "error: creating Gitea repo $_org/$_repo returned HTTP $_http: $(cat "$_out")" >&2; rm -f "$_out"; return 1 ;;
  esac
  # Re-asserted unconditionally so a repo an older seed created private becomes readable on re-run.
  _vis_http=$(curl -sk --max-time 15 -o "$_out" -w '%{http_code}' -X PATCH "https://gitea.$DOMAIN/api/v1/repos/$_org/$_repo" \
    -H "Authorization: token $_pat" -H "Content-Type: application/json" -d '{"private":false}')
  [ "$_vis_http" = "200" ] \
    || { echo "error: making $_org/$_repo readable returned HTTP $_vis_http: $(cat "$_out")" >&2; rm -f "$_out"; return 1; }
  rm -f "$_out"
}

# stage_service_tree <role> -- prints a local path holding the exact tree to push for that
# Bookinfo service: the vendored source from demo-seed/bookinfo/<role> PLUS the gitea-runner
# binary dropped into .gitea/runner/.
#
# The source is vendored in this repo rather than cloned from istio/istio at seed time. It is the
# upstream Bookinfo tree plus the CI this demo exists to show (.gitea/workflows/ci.yml, the lint
# config it needs, the source fixes that gate demanded, and .gitea/runner/ for the team's own
# Actions runner image). That makes the seed deterministic: no network on the critical path and no
# chance of upstream drift changing the demo mid-run.
#
# The runner BINARY is deliberately not vendored -- it is an 18MB release artifact, so it is
# fetched once on the host by runner_fetch_binary, checksum-verified, and copied in here. Staging
# into the state dir (rather than mutating demo-seed/ in place) keeps the checkout clean, which
# matters because a stray binary under demo-seed/ would end up inside the operator image build.
stage_service_tree() {
  _sst_role=$1
  _sst_vendor="${SEED_VENDOR_DIR:-demo-seed/bookinfo}/$_sst_role"
  [ -d "$_sst_vendor" ] || { echo "error: vendored tree $_sst_vendor does not exist" >&2; return 1; }
  _sst_bin=$(runner_fetch_binary) || return 1
  _sst_dir="${APL_STATE_DIR:-.taskfiles/state}/seed_tree_$_sst_role"
  rm -rf "$_sst_dir"
  mkdir -p "$_sst_dir"
  cp -a "$_sst_vendor/." "$_sst_dir/"
  # Prune build/lint artifacts a developer's local run may have left in the vendored tree. This
  # copies the WORKING tree, not `git ls-files`, on purpose -- iterating on the demo should not
  # require staging every edit first -- so anything on disk would otherwise be force-pushed into
  # the team's repo. Root-owned junk has actually appeared here (a containerised ruff run left a
  # root-owned .ruff_cache under productpage/). Prune by name rather than by gitignore status:
  # ruff and pytest write self-ignoring caches, so `git status` shows a clean tree either way.
  for _sst_junk in .ruff_cache .pytest_cache __pycache__ node_modules .gradle build .bundle vendor; do
    find "$_sst_dir" -name "$_sst_junk" -prune -exec rm -rf {} + 2>/dev/null
  done
  [ -f "$_sst_dir/.gitea/runner/Dockerfile" ] \
    || { echo "error: $_sst_vendor has no .gitea/runner/Dockerfile" >&2; return 1; }
  cp "$_sst_bin" "$_sst_dir/.gitea/runner/gitea-runner"
  chmod +x "$_sst_dir/.gitea/runner/gitea-runner"

  # The platform agent layer (AGENT-ENVIRONMENTS.md section 18) is pulled into every team's runner
  # image with COPY --from, and its reference is domain-dependent -- so it is substituted here
  # rather than hardcoded in the vendored Dockerfile. Same reasoning as the gitea-runner binary
  # above: this build context is assembled by the seed, not committed ready-to-build.
  _sst_agent_base="harbor.$DOMAIN/team-${SEED_PLATFORM_TEAM:-platform}/agent-base:main"
  sed -i "s|__AGENT_BASE_IMAGE__|$_sst_agent_base|g" "$_sst_dir/.gitea/runner/Dockerfile"
  # Fail loudly rather than shipping a Dockerfile kaniko will choke on with an opaque message:
  # an unsubstituted placeholder is not a valid image reference.
  if grep -q '__AGENT_BASE_IMAGE__' "$_sst_dir/.gitea/runner/Dockerfile"; then
    echo "error: __AGENT_BASE_IMAGE__ left unsubstituted in $_sst_role's runner Dockerfile" >&2
    return 1
  fi
  printf '%s' "$_sst_dir"
}

# runner_fetch_binary -- prints the path to a verified gitea-runner binary, downloading it once
# per state dir and reusing it for all four teams.
#
# Runs on the HOST, which has unrestricted internet access. Verified against a pinned sha256:
# this binary is COPYed straight into an image that then executes CI jobs, so an unverified
# download here would be the single worst place on this lab to accept whatever the network
# returned.
runner_fetch_binary() {
  # Serialized: the cache path below is SHARED by all four teams, and seed:apps/seed:runners now
  # run them in parallel. Unserialized, every team curl'd the same file at once and one team
  # verified bytes another was still writing -- observed live 2026-08-29, `ratings` failed with a
  # sha256 mismatch mid-seed. 600s because this is a ~5MB download over an unknown link, not the
  # two fast API calls the api lock guards.
  apl_with_lock runner-download 600 _runner_fetch_binary_locked
}

_runner_fetch_binary_locked() {
  _rfb_dir="${APL_STATE_DIR:-.taskfiles/state}/seed_runner"
  _rfb_bin="$_rfb_dir/gitea-runner"
  if [ -f "$_rfb_bin" ] \
     && printf '%s  %s\n' "$SEED_RUNNER_SHA256" "$_rfb_dir/gitea-runner.xz" | sha256sum -c - >/dev/null 2>&1; then
    printf '%s' "$_rfb_bin"; return 0
  fi
  mkdir -p "$_rfb_dir"
  # Downloaded to a PID-unique temp and only renamed into the cache path once it has been verified.
  # The lock alone would be enough today, but a partial file must never be reachable under the real
  # name -- a stale-lock steal, or any future caller that skips the lock, would otherwise find a
  # truncated archive and trust it.
  _rfb_tmp="$_rfb_dir/.gitea-runner.xz.$$"
  # Bounded (CLAUDE.md rule 1): curl gets an explicit timeout, this is a ~5MB download.
  timeout 300 curl -fsSL --max-time 280 -o "$_rfb_tmp" "$SEED_RUNNER_URL" \
    || { rm -f "$_rfb_tmp"; echo "error: downloading gitea-runner from $SEED_RUNNER_URL failed" >&2; return 1; }
  printf '%s  %s\n' "$SEED_RUNNER_SHA256" "$_rfb_tmp" | sha256sum -c - >/dev/null 2>&1 \
    || { echo "error: gitea-runner checksum mismatch -- refusing to use it. Expected $SEED_RUNNER_SHA256, got $(sha256sum "$_rfb_tmp" | cut -d" " -f1)" >&2; rm -f "$_rfb_tmp"; return 1; }
  mv "$_rfb_tmp" "$_rfb_dir/gitea-runner.xz"
  rm -f "$_rfb_bin"
  xz -dk -c "$_rfb_dir/gitea-runner.xz" > "$_rfb_bin" \
    || { echo "error: decompressing gitea-runner failed" >&2; return 1; }
  chmod +x "$_rfb_bin"
  echo "downloaded and verified gitea-runner $SEED_RUNNER_VERSION" >&2
  printf '%s' "$_rfb_bin"
}

# stage_agent_base_tree -- assemble the platform agent-base build context and print its path.
#
# Same shape as stage_service_tree: the vendored tree plus the checksum-verified gitea-runner
# binary, which is deliberately NOT committed to apl-core. The agent-base image owns the runner
# binary and its config for ALL teams now, which is what removes the four-way download race that
# GITEA-ACTIONS-CI.md trap 16 documents (four teams curling one shared path concurrently).
stage_agent_base_tree() {
  _sabt_vendor="${SEED_AGENT_BASE_DIR:-demo-seed/agent-base}"
  [ -d "$_sabt_vendor" ] || { echo "error: vendored tree $_sabt_vendor does not exist" >&2; return 1; }
  _sabt_bin=$(runner_fetch_binary) || return 1
  _sabt_dir="${APL_STATE_DIR:-.taskfiles/state}/seed_tree_agent_base"
  rm -rf "$_sabt_dir"
  mkdir -p "$_sabt_dir"
  cp -a "$_sabt_vendor/." "$_sabt_dir/"
  cp "$_sabt_bin" "$_sabt_dir/gitea-runner"
  chmod +x "$_sabt_dir/gitea-runner"
  printf '%s' "$_sabt_dir"
}

# gitea_push_tree <org> <repo> <pat> <gitea-username> <srcdir> <message> -- force-pushes the whole
# contents of <srcdir> as the single commit on <org>/<repo>'s `main`, over HTTPS, authenticating
# as <gitea-username> with that user's own Gitea PAT (what gitea_mint_pat hands back).
#
# Exit status is three-valued, on purpose:
#   0  pushed (content changed, so Gitea's webhook fired and a build was triggered)
#   2  already identical -- nothing pushed, no webhook, no rebuild
#   1  failure
# Callers must handle 2 explicitly; see seed.yml's setup_team_service.
#
# `--force` is expected, not a conflict: gitea_create_org_repo auto-inits every new repo with a
# README so it has a `main` branch at all, and this replaces that initial commit.
#
# GIT_SSL_NO_VERIFY: Gitea's certificate is signed by the platform's own root CA, which carries no
# Authority Key Identifier (CLAUDE.md's CA note) -- the same reason every Tekton git-clone here
# runs with sslVerify "false".
#
# IDEMPOTENCE, and why it matters more than usual: the commit is built with a FIXED author and
# committer identity AND fixed dates, so identical content yields a byte-identical commit object
# and therefore the same SHA on every run. That makes "is the remote already exactly this?" a
# single SHA comparison -- and skipping the push when it matches is what stops a rerun of the seed
# from firing every team's webhook and re-running every build for nothing.
gitea_push_tree() {
  _pt_org=$1
  _pt_repo=$2
  _pt_pat=$3
  _pt_user=$4
  _pt_src=$5
  _pt_msg=$6

  _pt_work=$(mktemp -d)
  cp -a "$_pt_src/." "$_pt_work/" || { rm -rf "$_pt_work"; echo "error: could not copy $_pt_src" >&2; return 1; }
  rm -rf "$_pt_work/.git"

  _pt_sha=$(
    cd "$_pt_work" || exit 1
    git init -q -b main || exit 1
    git add -A || exit 1
    GIT_AUTHOR_NAME='apl seed' GIT_AUTHOR_EMAIL="seed@$DOMAIN" \
      GIT_COMMITTER_NAME='apl seed' GIT_COMMITTER_EMAIL="seed@$DOMAIN" \
      GIT_AUTHOR_DATE='@0 +0000' GIT_COMMITTER_DATE='@0 +0000' \
      git commit -q -m "$_pt_msg" || exit 1
    git rev-parse HEAD
  ) || { rm -rf "$_pt_work"; echo "error: could not build a local commit for $_pt_org/$_pt_repo from $_pt_src" >&2; return 1; }

  _pt_remote=$(curl -sk --max-time 15 "https://gitea.$DOMAIN/api/v1/repos/$_pt_org/$_pt_repo/branches/main" \
    -H "Authorization: token $_pt_pat" 2>/dev/null | jq -r '.commit.id // empty' 2>/dev/null || true)
  if [ "$_pt_remote" = "$_pt_sha" ]; then
    echo "$_pt_org/$_pt_repo is already at $_pt_sha -- nothing to push, no webhook fired, no rebuild"
    rm -rf "$_pt_work"
    return 2
  fi

  (
    cd "$_pt_work" || exit 1
    GIT_SSL_NO_VERIFY=1 timeout 120 git push --quiet --force \
      "https://$_pt_user:$_pt_pat@gitea.$DOMAIN/$_pt_org/$_pt_repo.git" "HEAD:refs/heads/main"
  ) || { rm -rf "$_pt_work"; echo "error: pushing $_pt_src to $_pt_org/$_pt_repo failed" >&2; return 1; }
  rm -rf "$_pt_work"
  echo "pushed $_pt_src to $_pt_org/$_pt_repo main ($_pt_sha)"
}

# --- Vikunja: OIDC claim-driven team sync -------------------------------------------------------
#
# Vikunja team membership comes from a Keycloak group attribute (`vikunja_groups`), read via a
# protocol mapper on the shared "otomi" client, aggregated from the user's groups -- NOT from us
# calling Vikunja's own team/team-member API. Confirmed live 2026-08-28: this is exactly the
# claim-driven mechanism `VIKUNJA.md` Appendix B recorded as "rejected" for the removed
# continuously-reconciling operator (rejected there because it's pull-not-push and mutually
# exclusive with API-managed membership -- neither concern applies to a one-shot seed script).
# Once the mapper + group attribute are in place, EVERY login (see vikunja_oidc_login) both
# creates the user's Vikunja account (if new) and syncs them into the team.

# keycloak_ensure_vikunja_group_mapper -- idempotent. Adds a group-attribute-aggregating
# oidc-usermodel-attribute-mapper named "vikunja-groups" to the "otomi" client (whose
# Keycloak-internal id is literally the string "otomi", confirmed live -- not a generated UUID,
# no lookup needed). Must use the dedicated protocol-mappers POST endpoint, not a PUT on the
# whole client/client-scope -- confirmed (via VIKUNJA.md's prior work) that PUT silently ignores
# nested protocolMappers changes on an already-existing scope like this one.
keycloak_ensure_vikunja_group_mapper() {
  _token=$(kc_master_token) || return 1
  _existing=$(curl -sk --max-time 15 -f "https://keycloak.$DOMAIN/admin/realms/otomi/clients/otomi/protocol-mappers/models" \
    -H "Authorization: Bearer $_token" | jq -r '.[] | select(.name=="vikunja-groups") | .name')
  if [ -n "$_existing" ]; then
    echo "vikunja-groups protocol mapper already exists on the otomi client"
    return 0
  fi
  curl -sk --max-time 15 -f -X POST "https://keycloak.$DOMAIN/admin/realms/otomi/clients/otomi/protocol-mappers/models" \
    -H "Authorization: Bearer $_token" -H "Content-Type: application/json" \
    -d '{
      "name": "vikunja-groups",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-attribute-mapper",
      "config": {
        "user.attribute": "vikunja_groups",
        "claim.name": "vikunja_groups",
        "jsonType.label": "JSON",
        "multivalued": "true",
        "aggregate.attrs": "true",
        "userinfo.token.claim": "true",
        "id.token.claim": "true",
        "access.token.claim": "true"
      }
    }' > /dev/null
  echo "added vikunja-groups protocol mapper to the otomi client"
}

# keycloak_stamp_team_vikunja_group <team> <display-name> -- idempotent. Merges a vikunja_groups
# attribute onto the "team-<team>" Keycloak group (GET the group first to avoid clobbering its
# other fields/attributes). external_id "kc-team-<team>" is what Vikunja's own claim-sync uses
# as the team's stable identity across logins -- used later to look the team up by id, not name
# (Vikunja appends "(otomi-idp)" to the display name itself, so name-matching is fragile).
keycloak_stamp_team_vikunja_group() {
  _team=$1
  _display_name=$2
  _token=$(kc_master_token) || return 1
  _group_id=$(curl -sk --max-time 15 -f "https://keycloak.$DOMAIN/admin/realms/otomi/groups?search=team-$_team" \
    -H "Authorization: Bearer $_token" | jq -er --arg name "team-$_team" '.[] | select(.name==$name) | .id')
  [ -n "$_group_id" ] || { echo "error: no Keycloak group named team-$_team" >&2; return 1; }

  _group=$(curl -sk --max-time 15 -f "https://keycloak.$DOMAIN/admin/realms/otomi/groups/$_group_id" \
    -H "Authorization: Bearer $_token")
  _current=$(printf '%s' "$_group" | jq -r '.attributes.vikunja_groups[0] // empty')
  _expected=$(jq -nc --arg name "$_display_name" --arg oidc "kc-team-$_team" '{name: $name, oidcID: $oidc}')
  if [ "$_current" = "$_expected" ]; then
    echo "team-$_team's Keycloak group already stamped with the matching vikunja_groups attribute"
    return 0
  fi

  _updated=$(printf '%s' "$_group" | jq --arg v "$_expected" '.attributes = ((.attributes // {}) + {vikunja_groups: [$v]})')
  curl -sk --max-time 15 -f -X PUT "https://keycloak.$DOMAIN/admin/realms/otomi/groups/$_group_id" \
    -H "Authorization: Bearer $_token" -H "Content-Type: application/json" -d "$_updated" > /dev/null
  echo "stamped team-$_team's Keycloak group with vikunja_groups=$_expected"
}

# --- Vikunja: rate-limit pacing ---------------------------------------------------------------
#
# Vikunja hardcodes a 10-requests-per-minute-PER-IP limit on its unauthenticated routes -- the
# OIDC callback included -- as anti-account-enumeration protection. It is not configurable: no
# ratelimit.enabled=false or any other setting touches it (confirmed by Vikunja's own
# maintainers, community.vikunja.io/t/impossible-to-switch-off-the-rate-limits/3873).
#
# Worse, "per IP" collapses to a single shared bucket here: every one of these curl calls reaches
# Vikunja through the Istio mesh as the SAME source IP (127.0.0.6, Envoy's fixed sidecar-loopback
# address -- general Istio behaviour, not specific to this cluster), so all six demo users share
# ONE budget no matter who is logging in or which team they belong to. Per-user or per-team
# spacing therefore cannot work on its own; the budget has to be tracked for the whole run.
#
# Vikunja does answer with X-RateLimit-Limit / X-RateLimit-Remaining / X-RateLimit-Reset on every
# response, the 200s as well as the 429s (confirmed live 2026-08-29). That is the server's own
# accounting, so honouring it is exact -- no fixed sleeps that are either too short (and re-trip
# the same still-open window) or needlessly slow. The state is kept in a file, not a variable,
# because each `task:` cmds: entry is a separate shell and each apl_run body is a subshell.
_vikunja_rl_file() { printf '%s/seed_vikunja_ratelimit' "${APL_STATE_DIR:-.taskfiles/state}"; }

# _vikunja_rl_record <headers-file> -- persists the budget Vikunja just reported. Silently does
# nothing if the headers aren't there (a future Vikunja could drop them; _vikunja_rl_wait then
# simply has nothing to act on and the reactive 429 backoff still covers us).
_vikunja_rl_record() {
  _rl_rem=$(grep -i '^x-ratelimit-remaining:' "$1" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')
  _rl_reset=$(grep -i '^x-ratelimit-reset:' "$1" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')
  case "${_rl_rem:-}" in '' | *[!0-9]*) return 0 ;; esac
  case "${_rl_reset:-}" in '' | *[!0-9]*) return 0 ;; esac
  mkdir -p "${APL_STATE_DIR:-.taskfiles/state}"
  printf '%s %s\n' "$_rl_rem" "$_rl_reset" > "$(_vikunja_rl_file)"
}

# _vikunja_rl_wait -- blocks until the current rate-limit window has room to spare, based on what
# Vikunja itself last reported. Bounded by construction: the window is 60s, and the sleep is
# clamped to 70s so a skewed clock can never turn this into an unbounded wait (CLAUDE.md rule 1).
#
# MUST be called BEFORE the OIDC dance starts, never between obtaining the authorization code and
# redeeming it: this realm's accessCodeLifespan is 60s (confirmed live), so a rate-limit sleep
# placed after the code was issued would expire it and turn a rate-limit problem into Keycloak
# rejecting the exchange with invalid_grant "Code not valid".
_vikunja_rl_wait() {
  _rl_f=$(_vikunja_rl_file)
  [ -f "$_rl_f" ] || return 0
  _rl_rem=''
  _rl_reset=''
  read -r _rl_rem _rl_reset < "$_rl_f" || true
  case "${_rl_rem:-}" in '' | *[!0-9]*) return 0 ;; esac
  case "${_rl_reset:-}" in '' | *[!0-9]*) return 0 ;; esac
  _rl_now=$(date +%s)
  if [ "$_rl_reset" -le "$_rl_now" ]; then
    rm -f "$_rl_f"
    return 0
  fi
  # One full login is one request against this budget, but a retry is another -- keep enough
  # headroom that the caller's own retry loop still has somewhere to go.
  if [ "$_rl_rem" -gt "${VIKUNJA_RL_HEADROOM:-2}" ]; then
    return 0
  fi
  _rl_sleep=$((_rl_reset - _rl_now + 2))
  if [ "$_rl_sleep" -gt 70 ]; then _rl_sleep=70; fi
  echo "vikunja rate-limit budget nearly spent ($_rl_rem of 10 left in this window) -- waiting ${_rl_sleep}s for it to reset before logging in" >&2
  sleep "$_rl_sleep"
  rm -f "$_rl_f"
}

# --- Vikunja: token cache ---------------------------------------------------------------------
#
# Every OIDC login costs one request against the shared budget above, and Vikunja's own JWT is
# good for 10 minutes. Caching it means a rerun of an already-provisioned team spends nothing.
_vikunja_token_cache_file() {
  printf '%s/seed_vikunja_token_%s' "${APL_STATE_DIR:-.taskfiles/state}" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}

# vikunja_cache_token <email> <token> -- stores a freshly obtained token for reuse.
vikunja_cache_token() {
  mkdir -p "${APL_STATE_DIR:-.taskfiles/state}"
  _vc_file=$(_vikunja_token_cache_file "$1")
  printf '%s' "$2" > "$_vc_file"
  chmod 600 "$_vc_file"
}

# _vikunja_token_still_valid <token> -- 0 if the JWT's own exp is more than 120s away. Decodes the
# payload locally rather than asking Vikunja, so the check itself costs no request. base64url, not
# base64: the - and _ have to be translated back and the padding restored, or `base64 -d` fails.
_vikunja_token_still_valid() {
  _vt_payload=$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+')
  case $((${#_vt_payload} % 4)) in
    2) _vt_payload="$_vt_payload==" ;;
    3) _vt_payload="$_vt_payload=" ;;
  esac
  _vt_exp=$(printf '%s' "$_vt_payload" | base64 -d 2>/dev/null | jq -r '.exp // empty' 2>/dev/null || true)
  case "${_vt_exp:-}" in '' | *[!0-9]*) return 1 ;; esac
  [ "$_vt_exp" -gt "$(($(date +%s) + 120))" ]
}

# vikunja_login <email> <password> -- vikunja_oidc_login, but reuses a cached still-valid JWT.
#
# Use this wherever the token itself is what's wanted. Use vikunja_oidc_login directly when the
# LOGIN is what's wanted -- the claim-driven team sync only happens during a real login, so a
# cached token proves nothing about current team membership (see seed.yml's setup_team_vikunja,
# which checks membership explicitly and only then decides whether a real login is needed).
vikunja_login() {
  _vl_email=$1
  _vl_password=$2
  _vl_file=$(_vikunja_token_cache_file "$_vl_email")
  if [ -f "$_vl_file" ]; then
    _vl_token=$(cat "$_vl_file")
    if [ -n "$_vl_token" ] && _vikunja_token_still_valid "$_vl_token"; then
      echo "reusing the cached Vikunja token for $_vl_email (still valid -- no login, no rate-limit budget spent)" >&2
      printf '%s' "$_vl_token"
      return 0
    fi
  fi
  _vl_token=$(vikunja_oidc_login "$_vl_email" "$_vl_password") || return 1
  vikunja_cache_token "$_vl_email" "$_vl_token"
  printf '%s' "$_vl_token"
}

# vikunja_team_members <token> <team_id> -- prints one member username per line (usernames are the
# email addresses here, since that's what the OIDC provider hands Vikunja). Empty on any failure;
# the caller decides what an empty list means. Note GET /teams/<id> answers 200 with an all-null
# body for a team the caller can't see, so "no members" and "no such team" look alike -- always
# resolve the id with vikunja_team_id_by_external_id first.
vikunja_team_members() {
  curl -sk --max-time 15 "https://vikunja.$DOMAIN/api/v1/teams/$2" -H "Authorization: Bearer $1" 2>/dev/null \
    | jq -r '.members[]?.username // empty' 2>/dev/null || true
}

# vikunja_oidc_login <email> <password> -- completes a real Keycloak SSO login against Vikunja's
# "otomi" OIDC provider and returns a bearer JWT directly (unlike Gitea, Vikunja's own callback
# hands the token back in the response body -- no session-cookie/PAT dance needed). Confirmed
# live 2026-08-28. ALWAYS actually logs in (no existing-account short-circuit): this is also what
# re-syncs claim-driven team membership on every call, same reasoning as gitea_oidc_login.
#
# Three legs, not two like Gitea's: (1) GET Keycloak's /auth with redirect_uri set to VIKUNJA'S
# FRONTEND route (https://vikunja.$DOMAIN/auth/openid/otomi -- a SPA route, not an API path;
# "otomi" is the config-map key for the provider, not its display name "otomi-idp"), scrape the
# login form action; (2) POST credentials, capture the redirect Location WITHOUT following it --
# the code is in its query string; (3) POST that code to Vikunja's own callback API, which
# returns {"token": "<jwt>"}.
vikunja_oidc_login() {
  _email=$1
  _password=$2
  # Wraps _once with up to 3 tries. Originally chalked up to transient load (isolated
  # single-user/single-team runs never reproduced it; it only showed up processing multiple
  # teams back to back) -- confirmed live 2026-08-29 it's actually deterministic: Vikunja's own
  # per-IP rate limiter, tripped because every login (any user, any team) reaches it through the
  # mesh as the same source IP. _vikunja_oidc_login_once itself now detects the 429 and sleeps
  # before returning, so this loop's retries land after the window has had a chance to clear
  # rather than re-hitting it instantly. Each retry gets a FRESH code (the whole 3-leg dance
  # re-runs), so it's not just re-trying an already-invalid code.
  _tries=0
  while [ "$_tries" -lt 3 ]; do
    _tries=$((_tries + 1))
    _token=$(_vikunja_oidc_login_once "$_email" "$_password") && [ -n "$_token" ] && { printf '%s' "$_token"; return 0; }
    if [ "$_tries" -lt 3 ]; then
      # Never retry back to back. This realm has bruteForceProtected=true with
      # quickLoginCheckMilliSeconds=1000 / minimumQuickLoginWaitSeconds=60 (confirmed live), so
      # repeated sub-second login attempts for the SAME user are exactly what Keycloak is built
      # to treat as a bot and answer with a 60s temporary lockout -- turning one recoverable
      # failure into three guaranteed ones. _vikunja_oidc_login_once already sleeps out a full
      # rate-limit window when Vikunja is the thing refusing; this covers everything else.
      echo "vikunja login for $_email did not return a token (attempt $_tries/3) -- waiting 3s before retrying" >&2
      sleep 3
    fi
  done
  echo "error: vikunja login for $_email failed after 3 tries -- the reason for each attempt is logged above" >&2
  return 1
}

_vikunja_oidc_login_once() {
  _email=$1
  _password=$2
  _redirect=$(printf '%s' "https://vikunja.$DOMAIN/auth/openid/otomi" | jq -sRr @uri)
  _scope=$(printf '%s' "openid email profile" | jq -sRr @uri)

  # Before leg 1, deliberately -- never between leg 2 and leg 3. See _vikunja_rl_wait: the
  # authorization code this dance is about to obtain is only valid for accessCodeLifespan (60s
  # in this realm), so waiting out a rate-limit window mid-dance would expire it.
  _vikunja_rl_wait

  _jar=$(mktemp)
  _s1_body=$(mktemp)
  _s2_headers=$(mktemp)
  _s2_body=$(mktemp)
  _cb_headers=$(mktemp)
  _cb_body=$(mktemp)

  curl -sk --max-time 15 -c "$_jar" -o "$_s1_body" -L --max-redirs 5 \
    "https://keycloak.$DOMAIN/realms/otomi/protocol/openid-connect/auth?client_id=otomi&redirect_uri=$_redirect&response_type=code&scope=$_scope&state=seed"
  _action_url=$(grep -o 'action="[^"]*"' "$_s1_body" | head -1 | sed 's/action="//; s/"$//; s/&amp;/\&/g' || true)
  if [ -z "$_action_url" ]; then
    # Diagnose, don't just fail: every failure path here prints what actually came back. A bare
    # "did not return a token" is what made this step's earlier failures unreadable.
    echo "error [$_email]: no Keycloak login form at Vikunja's otomi entrypoint -- first 400 bytes of the response instead:" >&2
    head -c 400 "$_s1_body" >&2
    echo >&2
    rm -f "$_jar" "$_s1_body" "$_s2_headers" "$_s2_body" "$_cb_headers" "$_cb_body"
    return 1
  fi

  curl -sk --max-time 15 -b "$_jar" -c "$_jar" -D "$_s2_headers" -o "$_s2_body" \
    --data-urlencode "username=$_email" --data-urlencode "password=$_password" --data-urlencode "credentialId=" \
    -X POST "$_action_url"
  _location=$(grep -i '^location:' "$_s2_headers" | tail -1 | sed 's/^[Ll]ocation: //; s/\r$//' || true)
  if [ -z "$_location" ]; then
    # A 200 here means Keycloak re-rendered the login page: wrong password, a pending required
    # action, or a brute-force lockout (this realm has bruteForceProtected=true). Its own
    # feedback text says which -- print it rather than guessing.
    echo "error [$_email]: Keycloak did not redirect after the login POST ($(grep -i '^HTTP/' "$_s2_headers" | tail -1 | tr -d '\r'))." >&2
    echo "  Keycloak's own message: $(grep -oiE '(kc-feedback-text|input-error[a-z-]*)"[^>]*>[^<]+' "$_s2_body" | sed 's/.*>//' | head -3 | tr '\n' ' ')" >&2
    rm -f "$_jar" "$_s1_body" "$_s2_headers" "$_s2_body" "$_cb_headers" "$_cb_body"
    return 1
  fi
  # Anchored on [?&]code= on purpose: an unanchored (?<=code=) also matches the session_code= of
  # a Keycloak login-actions URL, which would send Keycloak's own session code to Vikunja as if
  # it were an authorization code and come back as invalid_grant "Code not valid".
  _code=$(printf '%s' "$_location" | grep -oP '(?<=[?&]code=)[^&]+' | head -1 || true)
  if [ -z "$_code" ]; then
    echo "error [$_email]: no code= parameter in Keycloak's redirect: $_location" >&2
    rm -f "$_jar" "$_s1_body" "$_s2_headers" "$_s2_body" "$_cb_headers" "$_cb_body"
    return 1
  fi

  # Headers and body to separate files with -w '%{http_code}' on stdout: the status is then the
  # only thing on stdout, with no tail/sed splitting of a combined stream to get it wrong, and
  # the X-RateLimit-* headers stay readable (see _vikunja_rl_record). NOT -f, because a 429 and a
  # 400 both need their body inspected, not collapsed into a bare nonzero exit.
  _cb_status=$(curl -sk --max-time 15 -D "$_cb_headers" -o "$_cb_body" -w '%{http_code}' \
    -X POST "https://vikunja.$DOMAIN/api/v1/auth/openid/otomi/callback" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg code "$_code" --arg redirect "https://vikunja.$DOMAIN/auth/openid/otomi" '{code: $code, redirect_url: $redirect}')")
  _vikunja_rl_record "$_cb_headers"
  _cb_rl=$(grep -i '^x-ratelimit-remaining:' "$_cb_headers" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')

  if [ "$_cb_status" = "429" ]; then
    # Back off to the reset instant Vikunja itself reported, not a guessed fixed sleep. Clamped
    # to 70s (the window is 60s) so a bad clock can't produce an unbounded wait.
    _cb_reset=$(grep -i '^x-ratelimit-reset:' "$_cb_headers" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')
    _cb_sleep=65
    case "${_cb_reset:-}" in
      '' | *[!0-9]*) : ;;
      *) _cb_sleep=$((_cb_reset - $(date +%s) + 2)) ;;
    esac
    if [ "$_cb_sleep" -lt 2 ]; then _cb_sleep=2; fi
    if [ "$_cb_sleep" -gt 70 ]; then _cb_sleep=70; fi
    echo "error [$_email]: vikunja OIDC callback rate-limited (429) -- waiting ${_cb_sleep}s for the window to reset before this attempt is retried" >&2
    rm -f "$_jar" "$_s1_body" "$_s2_headers" "$_s2_body" "$_cb_headers" "$_cb_body"
    sleep "$_cb_sleep"
    return 1
  fi
  if [ "$_cb_status" != "200" ]; then
    echo "error [$_email]: vikunja OIDC callback returned HTTP $_cb_status (rate-limit budget left: ${_cb_rl:-unknown}): $(head -c 400 "$_cb_body")" >&2
    rm -f "$_jar" "$_s1_body" "$_s2_headers" "$_s2_body" "$_cb_headers" "$_cb_body"
    return 1
  fi
  _cb_token=$(jq -r '.token // empty' "$_cb_body" 2>/dev/null || true)
  if [ -z "$_cb_token" ]; then
    echo "error [$_email]: vikunja OIDC callback returned HTTP 200 but no .token: $(head -c 400 "$_cb_body")" >&2
    rm -f "$_jar" "$_s1_body" "$_s2_headers" "$_s2_body" "$_cb_headers" "$_cb_body"
    return 1
  fi
  rm -f "$_jar" "$_s1_body" "$_s2_headers" "$_s2_body" "$_cb_headers" "$_cb_body"
  printf '%s' "$_cb_token"
}

# vikunja_team_id_by_external_id <token> <external_id> -- prints the Vikunja team id whose
# external_id matches (set by keycloak_stamp_team_vikunja_group's oidcID), or nothing if the
# claim-sync hasn't created it yet. Matching on external_id, not name/title -- Vikunja appends
# "(otomi-idp)" to the display name itself, so name-matching is fragile.
#
# "Not found" is a NORMAL, zero-exit outcome here (empty output), not an error -- this used to be
# `jq -er`, which exits 4 when its filter produces nothing. Callers run under `set -euo pipefail`
# and assign this in a command substitution, so that nonzero status aborted the whole step
# instantly and silently: their own `[ -n "$_id" ] || echo "error: ..."` line could never run.
# Same trap, same fix, in vikunja_create_project_if_missing below.
vikunja_team_id_by_external_id() {
  _token=$1
  _external_id=$2
  curl -sk --max-time 15 "https://vikunja.$DOMAIN/api/v1/teams" -H "Authorization: Bearer $_token" 2>/dev/null \
    | jq -r --arg eid "$_external_id" '[.[]? | select(.external_id==$eid) | .id] | first // empty' 2>/dev/null || true
}

# vikunja_create_project_if_missing <token> <title> <description> -- creates a project as
# whichever user <token> belongs to (so ownership lands on that user), idempotent by title.
#
# `jq -r ... | first // empty`, never `jq -er`: see vikunja_team_id_by_external_id's note. With
# `-er`, the not-yet-created case -- the ONLY case in which this function has any work to do --
# exited 4 and, under the caller's `set -euo pipefail`, aborted the whole step before the create
# below could ever run. Confirmed live: a team could end up with its Vikunja team and all its
# members synced but no project at all, and nothing in the log said why.
vikunja_create_project_if_missing() {
  _token=$1
  _title=$2
  _description=$3
  _existing=$(curl -sk --max-time 15 "https://vikunja.$DOMAIN/api/v1/projects" -H "Authorization: Bearer $_token" 2>/dev/null \
    | jq -r --arg t "$_title" '[.[]? | select(.title==$t) | .id] | first // empty' 2>/dev/null || true)
  if [ -n "$_existing" ]; then
    echo "vikunja project '$_title' already exists (id $_existing)" >&2
    printf '%s' "$_existing"
    return 0
  fi
  _cp_out=$(mktemp)
  _cp_http=$(curl -sk --max-time 15 -o "$_cp_out" -w '%{http_code}' -X PUT "https://vikunja.$DOMAIN/api/v1/projects" \
    -H "Authorization: Bearer $_token" -H "Content-Type: application/json" \
    -d "$(jq -n --arg title "$_title" --arg desc "$_description" '{title: $title, description: $desc}')")
  if [ "$_cp_http" -ge 300 ]; then
    echo "error: creating vikunja project '$_title' returned HTTP $_cp_http: $(head -c 400 "$_cp_out")" >&2
    rm -f "$_cp_out"
    return 1
  fi
  _cp_id=$(jq -r '.id // empty' "$_cp_out" 2>/dev/null || true)
  rm -f "$_cp_out"
  if [ -z "$_cp_id" ]; then
    echo "error: creating vikunja project '$_title' returned HTTP $_cp_http but no .id" >&2
    return 1
  fi
  echo "created vikunja project '$_title' (id $_cp_id)" >&2
  printf '%s' "$_cp_id"
}

# vikunja_rename_project_if_needed <token> <old_title> <new_title> <description> -- migrates a
# project from an old title to a new one, in place, exactly once. Confirmed live 2026-08-29:
# `POST /api/v1/projects/{id}` accepts a partial body (title+description only) and updates just
# those fields. Checks for <new_title> FIRST (idempotent no-op once migrated), then falls back to
# finding <old_title> and renaming it -- never creates a second project under the new title if
# the old one is still there, which a bare vikunja_create_project_if_missing("$new_title", ...)
# would do (title-matching, so an old-titled project is invisible to it and gets left behind as
# an orphaned duplicate). Prints the project id either way; caller still needs to share it with
# the team (sharing is unaffected by a rename).
vikunja_rename_project_if_needed() {
  _token=$1
  _old_title=$2
  _new_title=$3
  _description=$4
  _projects=$(curl -sk --max-time 15 "https://vikunja.$DOMAIN/api/v1/projects" -H "Authorization: Bearer $_token" 2>/dev/null || true)
  _new_id=$(printf '%s' "$_projects" | jq -r --arg t "$_new_title" '[.[]? | select(.title==$t) | .id] | first // empty' 2>/dev/null || true)
  if [ -n "$_new_id" ]; then
    printf '%s' "$_new_id"
    return 0
  fi
  _old_id=$(printf '%s' "$_projects" | jq -r --arg t "$_old_title" '[.[]? | select(.title==$t) | .id] | first // empty' 2>/dev/null || true)
  if [ -z "$_old_id" ]; then
    # Neither title exists yet -- nothing to migrate, let the normal create-if-missing path handle it.
    return 1
  fi
  _rn_out=$(mktemp)
  _rn_http=$(curl -sk --max-time 15 -o "$_rn_out" -w '%{http_code}' -X POST "https://vikunja.$DOMAIN/api/v1/projects/$_old_id" \
    -H "Authorization: Bearer $_token" -H "Content-Type: application/json" \
    -d "$(jq -n --arg title "$_new_title" --arg desc "$_description" '{title: $title, description: $desc}')")
  if [ "$_rn_http" -ge 300 ]; then
    echo "error: renaming vikunja project '$_old_title' (id $_old_id) to '$_new_title' returned HTTP $_rn_http: $(head -c 400 "$_rn_out")" >&2
    rm -f "$_rn_out"
    return 1
  fi
  rm -f "$_rn_out"
  echo "renamed vikunja project '$_old_title' -> '$_new_title' (id $_old_id)" >&2
  printf '%s' "$_old_id"
}

# vikunja_share_with_team_if_missing <token> <project_id> <team_id> <permission> -- idempotent.
# Confirmed live: sharing a project with a claim-created (OIDC-managed) team works fine via this
# API -- VIKUNJA.md's "OIDC-created teams are not editable through its API" is about editing the
# TEAM object itself (membership/properties), not about other objects referencing its id.
# Read-back trap (matches VIKUNJA.md's own documented finding for the same endpoint shape): the
# GET here embeds the shared team's own object, whose id field is plain "id", NOT "team_id" --
# checking "team_id" on the read-back never matches, so every call would re-share needlessly
# (harmless against this API, but not actually idempotent) without this fix.
vikunja_share_with_team_if_missing() {
  _token=$1
  _project_id=$2
  _team_id=$3
  _permission=$4
  _already=$(curl -sk --max-time 15 "https://vikunja.$DOMAIN/api/v1/projects/$_project_id/teams" \
    -H "Authorization: Bearer $_token" 2>/dev/null \
    | jq -r --argjson tid "$_team_id" '[.[]? | select(.id==$tid) | .id] | first // empty' 2>/dev/null || true)
  if [ -n "$_already" ]; then
    echo "project $_project_id already shared with team $_team_id"
    return 0
  fi
  _st_out=$(mktemp)
  _st_http=$(curl -sk --max-time 15 -o "$_st_out" -w '%{http_code}' -X PUT "https://vikunja.$DOMAIN/api/v1/projects/$_project_id/teams" \
    -H "Authorization: Bearer $_token" -H "Content-Type: application/json" \
    -d "$(jq -n --argjson tid "$_team_id" --argjson perm "$_permission" '{team_id: $tid, permission: $perm}')")
  if [ "$_st_http" -ge 300 ]; then
    echo "error: sharing project $_project_id with team $_team_id returned HTTP $_st_http: $(head -c 400 "$_st_out")" >&2
    rm -f "$_st_out"
    return 1
  fi
  rm -f "$_st_out"
  echo "shared project $_project_id with team $_team_id (permission $_permission)"
}

# --- Gitea Actions: runner registration, branch protection, run status -------------------------

# gitea_mint_runner_token <org> <pat> -- prints a runner registration token for that ORG.
#
# Org-scoped on purpose, not instance-scoped: each team registers its own runner, and the
# instance-level endpoint (/api/v1/admin/runners) is not reachable with a team dev's PAT anyway.
#
# The token is REUSABLE across many registrations -- verified live 2026-08-29 by registering two
# runners from one token, both coming back "ephemeral": true. That is what makes an ephemeral
# runner viable here: every pod restart re-registers with this same stored token, so a single
# long-lived Secret serves the whole recycling loop.
gitea_mint_runner_token() {
  _mrt_org=$1
  _mrt_pat=$2
  _mrt_out=$(mktemp)
  _mrt_http=$(curl -sk --max-time 20 -o "$_mrt_out" -w '%{http_code}' -X POST \
    "https://gitea.$DOMAIN/api/v1/orgs/$_mrt_org/actions/runners/registration-token" \
    -H "Authorization: token $_mrt_pat" -H "Content-Type: application/json")
  if [ "$_mrt_http" != "200" ] && [ "$_mrt_http" != "201" ]; then
    echo "error: minting runner registration token for $_mrt_org returned HTTP $_mrt_http: $(cat "$_mrt_out")" >&2
    rm -f "$_mrt_out"; return 1
  fi
  _mrt_token=$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$_mrt_out")
  rm -f "$_mrt_out"
  [ -n "$_mrt_token" ] || { echo "error: no token in registration-token response for $_mrt_org" >&2; return 1; }
  printf '%s' "$_mrt_token"
}

# gitea_ensure_workflowjob_hook <org> <repo> <pat> <el-name> -- idempotently ensures a repo webhook
# delivering `workflow_job` to the on-demand runner's EventListener.
#
# This is the trigger the whole on-demand runner design hangs on: Gitea fires `workflow_job` with
# `action: queued` the moment a job needs a runner, and that event is what creates one. The event
# type arrived in Gitea 1.24 (go-gitea/gitea#33694); this lab runs 1.26.
#
# SEPARATE from the webhook the AplTeamBuild creates. That one is push-only and is reconciled by
# the operator -- adding an event to it would be reverted, and pointing it at a second target is
# not possible. Two hooks on one repo is the supported shape.
#
# The target must be the EventListener's own Service. The platform's `default-from-gitea`
# NetworkPolicy admits traffic from the gitea namespace ONLY to pods labelled
# `app.kubernetes.io/managed-by: EventListener`, which Tekton sets and the chart re-asserts.
gitea_ensure_workflowjob_hook() {
  _ewh_org=$1; _ewh_repo=$2; _ewh_pat=$3; _ewh_el=$4
  _ewh_url="http://$_ewh_el.$_ewh_org.svc.cluster.local:8080/"
  _ewh_out=$(mktemp)
  # Idempotent by TARGET URL, not by id: re-running this task must not pile up duplicate hooks,
  # and a duplicate would create two runners for every queued job.
  if curl -sk --max-time 20 "https://gitea.$DOMAIN/api/v1/repos/$_ewh_org/$_ewh_repo/hooks" \
       -H "Authorization: token $_ewh_pat" 2>/dev/null | grep -qF "$_ewh_url"; then
    echo "workflow_job webhook already present on $_ewh_org/$_ewh_repo"
    rm -f "$_ewh_out"; return 0
  fi
  _ewh_http=$(curl -sk --max-time 20 -o "$_ewh_out" -w '%{http_code}' -X POST \
    "https://gitea.$DOMAIN/api/v1/repos/$_ewh_org/$_ewh_repo/hooks" \
    -H "Authorization: token $_ewh_pat" -H "Content-Type: application/json" \
    -d "$(jq -n --arg url "$_ewh_url" \
      '{type:"gitea", active:true, events:["workflow_job"],
        config:{url:$url, content_type:"json"}}')")
  if [ "$_ewh_http" != "201" ]; then
    echo "error: creating workflow_job webhook on $_ewh_org/$_ewh_repo returned HTTP $_ewh_http: $(head -c 300 "$_ewh_out")" >&2
    rm -f "$_ewh_out"; return 1
  fi
  echo "workflow_job webhook -> $_ewh_url"
  rm -f "$_ewh_out"
}

# runner_drain_queued <team> <repo> <pat> -- create a runner for every job already sitting queued.
#
# Gitea fires `workflow_job` EXACTLY ONCE per job and never retries a failed or unrouted delivery
# (the same no-retry behaviour that cost a whole PipelineRun in GITEA-ACTIONS-CI.md's trap 8). So
# any job queued before the webhook and EventListener existed -- which on a fresh seed is every
# team's first CI run, queued by seed:apps minutes earlier -- would otherwise wait forever.
#
# Rather than duplicating the Job spec here (which would then drift from the chart), this REPLAYS a
# synthetic `workflow_job queued` payload at the team's own EventListener. The CEL filter, the
# TriggerBinding and the TriggerTemplate all run exactly as they would for a real delivery, so this
# path cannot silently diverge from the production one.
#
# Reaching the EventListener goes through `kubectl port-forward`, not a pod in the namespace: the
# team namespace has a default-deny ingress policy, so a scratch pod there could not reach the
# EventListener, while port-forward goes API server -> kubelet -> pod and bypasses NetworkPolicy.
runner_drain_queued() {
  _rdq_team=$1; _rdq_repo=$2; _rdq_pat=$3
  _rdq_el="el-gitea-workflowjob-$_rdq_team"
  _rdq_runs=$(curl -sk --max-time 20 \
    "https://gitea.$DOMAIN/api/v1/repos/team-$_rdq_team/$_rdq_repo/actions/runs?limit=50" \
    -H "Authorization: token $_rdq_pat" 2>/dev/null \
    | jq -r '[.workflow_runs[]?|select(.status=="queued")|.id]|join(" ")' 2>/dev/null || true)
  if [ -z "$_rdq_runs" ]; then
    echo "nothing queued in team-$_rdq_team/$_rdq_repo -- no drain needed"
    return 0
  fi
  echo "draining queued run(s) in team-$_rdq_team: $_rdq_runs"
  # Port 0 lets the kernel pick a free local port, so four teams draining in parallel (once
  # seed:runners is parallelised) cannot collide on a fixed one.
  _rdq_pf_log=$(mktemp)
  kubectl --context "$KIND_CTX" -n "team-$_rdq_team" port-forward "svc/$_rdq_el" :8080 \
    >"$_rdq_pf_log" 2>&1 &
  _rdq_pf_pid=$!
  # shellcheck disable=SC2064
  # EXIT only. mvdan/sh -- the shell go-task runs -- rejects INT with
  # "trap: INT: invalid signal specification" (rc 2), and that aborts the whole trap command, so
  # `EXIT INT TERM` installs NO handler at all, not even the EXIT one. Observed live 2026-08-29:
  # every team leaked its `kubectl port-forward` for the rest of the seed. EXIT alone is honoured
  # and is what actually matters here; on a Ctrl-C the port-forward dies with the process group.
  trap "kill $_rdq_pf_pid 2>/dev/null || true" EXIT
  _rdq_port=""
  _rdq_i=0
  while [ "$_rdq_i" -lt 30 ]; do
    _rdq_i=$((_rdq_i + 1))
    _rdq_port=$(sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p' "$_rdq_pf_log" | head -1)
    [ -n "$_rdq_port" ] && break
    sleep 1
  done
  if [ -z "$_rdq_port" ]; then
    echo "error: port-forward to $_rdq_el never reported a local port: $(head -c 300 "$_rdq_pf_log")" >&2
    kill "$_rdq_pf_pid" 2>/dev/null || true; trap - EXIT; rm -f "$_rdq_pf_log"; return 1
  fi
  _rdq_rc=0
  for _rdq_run in $_rdq_runs; do
    # Only the fields the TriggerBinding and the CEL filter actually read. The label must match
    # what the chart registers with, or the filter correctly refuses to make a runner.
    _rdq_http=$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' \
      -X POST "http://127.0.0.1:$_rdq_port/" -H "Content-Type: application/json" \
      -d "$(jq -n --argjson rid "$_rdq_run" --arg repo "team-$_rdq_team/$_rdq_repo" \
        '{action:"queued",
          workflow_job:{run_id:$rid, status:"queued", labels:["ubuntu-latest"]},
          repository:{full_name:$repo}}')")
    case "$_rdq_http" in
      20*|202) echo "  replayed run $_rdq_run -> HTTP $_rdq_http" ;;
      *) echo "error: replaying run $_rdq_run to $_rdq_el returned HTTP $_rdq_http" >&2; _rdq_rc=1 ;;
    esac
  done
  kill "$_rdq_pf_pid" 2>/dev/null || true
  trap - EXIT
  rm -f "$_rdq_pf_log"
  return "$_rdq_rc"
}

# runner_rerun_stale_failures <team> <repo> <pat> -- reruns a CI run that failed only because it
# raced the chart it depends on.
#
# seed:apps' push does two things at once: it updates .gitea/runner/chart AND triggers CI. Gitea
# starts the run in about a second; Argo CD needs a few more to apply the new chart to the
# EventListener's TriggerTemplate. A run that starts inside that window gets a runner built from
# the PREVIOUS template. Observed live 2026-08-29: a run started 6s before Argo applied a pod
# annotation it needed, so its runner came up with an Istio sidecar, every `pip install` was reset
# by the mesh, and the run failed -- while the very next run on the same commit passed.
#
# Deliberately NOT a blanket retry-on-red: it only reruns a failure that finished BEFORE the
# ci-runner app's last sync completed, i.e. one provably executed against a superseded template.
# A genuinely red build finishes after that sync and is left exactly as it is.
runner_rerun_stale_failures() {
  _rrs_team=$1; _rrs_repo=$2; _rrs_pat=$3
  _rrs_sync=$(kubectl --context "$KIND_CTX" --request-timeout=15s -n argocd \
    get application "team-$_rrs_team-ci-runner" \
    -o jsonpath='{.status.operationState.finishedAt}' 2>/dev/null || true)
  if [ -z "$_rrs_sync" ]; then
    echo "  no recorded ci-runner sync time for team-$_rrs_team -- skipping stale-failure check"
    return 0
  fi
  _rrs_stale=$(curl -sk --max-time 20 \
    "https://gitea.$DOMAIN/api/v1/repos/team-$_rrs_team/$_rrs_repo/actions/runs?limit=20" \
    -H "Authorization: token $_rrs_pat" 2>/dev/null \
    | jq -r --arg sync "$_rrs_sync" \
        '[.workflow_runs[]?
          | select(.conclusion=="failure")
          # A run with NO usable timestamp is skipped, never rerun: an empty string sorts before
          # every real time, so a `// ""` fallback here would silently turn this into the blanket
          # retry-on-red this function exists to avoid.
          | select((.started_at // "") != "")
          | select(.started_at < $sync)
          | .id] | join(" ")' 2>/dev/null || true)
  [ -n "$_rrs_stale" ] || return 0
  for _rrs_id in $_rrs_stale; do
    _rrs_http=$(curl -sk --max-time 20 -o /dev/null -w '%{http_code}' -X POST \
      "https://gitea.$DOMAIN/api/v1/repos/team-$_rrs_team/$_rrs_repo/actions/runs/$_rrs_id/rerun" \
      -H "Authorization: token $_rrs_pat")
    case "$_rrs_http" in
      20*) echo "  rerunning run $_rrs_id -- it finished before the runner chart synced (HTTP $_rrs_http)" ;;
      *)   echo "  warning: rerun of stale run $_rrs_id returned HTTP $_rrs_http" >&2 ;;
    esac
  done
  return 0
}

# gitea_unprotect_branch <org> <repo> <pat> [branch] -- removes the branch protection rule if one
# exists. 404 is success (nothing to remove).
#
# This exists because of a genuine ordering hazard: gitea_push_tree force-pushes to `main`, and the
# protection rule this seed installs sets enable_push:false, which blocks exactly that. On a FIRST
# run the repo is unprotected and nothing is needed; on a RE-RUN against an existing cluster the
# rule is already there and the push would fail. So every push is bracketed
# unprotect -> push -> protect.
gitea_unprotect_branch() {
  _ub_org=$1; _ub_repo=$2; _ub_pat=$3; _ub_branch=${4:-main}
  _ub_http=$(curl -sk --max-time 20 -o /dev/null -w '%{http_code}' -X DELETE \
    "https://gitea.$DOMAIN/api/v1/repos/$_ub_org/$_ub_repo/branch_protections/$_ub_branch" \
    -H "Authorization: token $_ub_pat")
  case "$_ub_http" in
    204 | 404) return 0 ;;
    *) echo "error: removing branch protection on $_ub_org/$_ub_repo:$_ub_branch returned HTTP $_ub_http" >&2; return 1 ;;
  esac
}

# gitea_protect_branch <org> <repo> <pat> <status-check-context> [branch] -- requires a passing
# status check before <branch> can be merged into, and forbids pushing to it directly.
#
# required_approvals is 0 deliberately: the point being demonstrated is an automated merge GATE,
# and a demo where a single-person team can never merge its own PR demonstrates the wrong thing.
gitea_protect_branch() {
  _pb_org=$1; _pb_repo=$2; _pb_pat=$3; _pb_ctx=$4; _pb_branch=${5:-main}
  _pb_body=$(printf '{"branch_name":"%s","rule_name":"%s","enable_push":false,"enable_force_push":false,"enable_status_check":true,"status_check_contexts":["%s"],"required_approvals":0}' \
    "$_pb_branch" "$_pb_branch" "$_pb_ctx")
  _pb_out=$(mktemp)
  _pb_http=$(curl -sk --max-time 20 -o "$_pb_out" -w '%{http_code}' -X POST \
    "https://gitea.$DOMAIN/api/v1/repos/$_pb_org/$_pb_repo/branch_protections" \
    -H "Authorization: token $_pb_pat" -H "Content-Type: application/json" -d "$_pb_body")
  case "$_pb_http" in
    200 | 201) echo "protected $_pb_org/$_pb_repo:$_pb_branch requiring '$_pb_ctx'" ;;
    # 403/409 means a rule already exists -- patch it so re-runs converge on the same rule rather
    # than leaving whatever an older seed installed.
    403 | 409 | 422)
      _pb_http2=$(curl -sk --max-time 20 -o "$_pb_out" -w '%{http_code}' -X PATCH \
        "https://gitea.$DOMAIN/api/v1/repos/$_pb_org/$_pb_repo/branch_protections/$_pb_branch" \
        -H "Authorization: token $_pb_pat" -H "Content-Type: application/json" -d "$_pb_body")
      [ "$_pb_http2" = "200" ] \
        || { echo "error: patching branch protection on $_pb_org/$_pb_repo returned HTTP $_pb_http2: $(cat "$_pb_out")" >&2; rm -f "$_pb_out"; return 1; }
      echo "updated protection on $_pb_org/$_pb_repo:$_pb_branch requiring '$_pb_ctx'" ;;
    *) echo "error: protecting $_pb_org/$_pb_repo returned HTTP $_pb_http: $(cat "$_pb_out")" >&2; rm -f "$_pb_out"; return 1 ;;
  esac
  rm -f "$_pb_out"
}

# gitea_wait_actions_run <org> <repo> <pat> <sha> [tries] [sleep] -- waits for the Actions run on
# <sha> to reach a terminal state; returns 0 only on success.
#
# Bounded (CLAUDE.md rule 1). Treats "no run found yet" as still-waiting, since the runner may not
# have picked the job up: Gitea QUEUES a job when no runner is online, which is exactly what makes
# the ordering here forgiving -- a workflow can land before its runner exists and still run later.
gitea_wait_actions_run() {
  _war_org=$1; _war_repo=$2; _war_pat=$3; _war_sha=$4
  _war_tries=${5:-60}; _war_sleep=${6:-10}
  _war_out=$(mktemp)
  _war_i=0
  while [ "$_war_i" -lt "$_war_tries" ]; do
    _war_i=$((_war_i + 1))
    curl -sk --max-time 20 -o "$_war_out" \
      "https://gitea.$DOMAIN/api/v1/repos/$_war_org/$_war_repo/actions/runs?limit=20" \
      -H "Authorization: token $_war_pat" >/dev/null 2>&1 || true
    # Filtered client-side with jq rather than trusting a head_sha query parameter (not relied on
    # here) and rather than sed: a greedy sed over this JSON matches the LAST "status" in the
    # payload, not this run's, which is how a passing run can be misread as queued.
    _war_status=$(jq -r --arg sha "$_war_sha" \
      '[.workflow_runs[]? | select(.head_sha==$sha)] | .[0] | (.conclusion // .status) // "none"' \
      "$_war_out" 2>/dev/null || echo none)
    case "$_war_status" in
      success) rm -f "$_war_out"; echo "Actions run on $(printf '%s' "$_war_sha" | cut -c1-7) succeeded"; return 0 ;;
      failure | cancelled)
        echo "error: Actions run for $_war_org/$_war_repo @ $_war_sha ended '$_war_status'" >&2
        echo "       see https://gitea.$DOMAIN/$_war_org/$_war_repo/actions" >&2
        rm -f "$_war_out"; return 1 ;;
      *) : ;;
    esac
    [ $((_war_i % 6)) -eq 0 ] && echo "  waiting for Actions run on $_war_org/$_war_repo ($_war_status, ${_war_i}/${_war_tries})"
    sleep "$_war_sleep"
  done
  echo "error: Actions run for $_war_org/$_war_repo @ $_war_sha never reached a terminal state" >&2
  rm -f "$_war_out"; return 1
}

# gitea_head_sha <org> <repo> <pat> [branch] -- prints the current commit sha of <branch>.
gitea_head_sha() {
  _hs_org=$1; _hs_repo=$2; _hs_pat=$3; _hs_branch=${4:-main}
  # jq, not sed: the payload contains several "id" fields and a greedy pattern picks the wrong one.
  curl -sk --max-time 20 "https://gitea.$DOMAIN/api/v1/repos/$_hs_org/$_hs_repo/branches/$_hs_branch" \
    -H "Authorization: token $_hs_pat" | jq -r '.commit.id // empty'
}

# vikunja_mint_api_token <email> <password> [title] -- mint a LONG-LIVED Vikunja API token (tk_...)
# for the agent and print it. This is the Vikunja equivalent of a Gitea PAT (a "bot" token), NOT an
# OIDC JWT: JWTs are short-lived and expire mid-session, so vikunja-cli must be given a real API
# token. Authenticates once via the OIDC flow to get a JWT, reads the route inventory (Vikunja
# validates token permissions against it), grants every listed action, and sets a far expiry.
# See AGENT-WORKFLOW-CATALOG.md 14d.
vikunja_mint_api_token() {
  _vt_email=$1
  _vt_pass=$2
  _vt_title=${3:-agent}
  _vt_jwt=$(vikunja_oidc_login "$_vt_email" "$_vt_pass") || return 1
  [ -n "$_vt_jwt" ] || { echo "vikunja_mint_api_token: no JWT for $_vt_email" >&2; return 1; }
  # Build permissions {resource: [actions...]} from the live route inventory -- grant all.
  _vt_perms=$(curl -sk --max-time 20 "https://vikunja.$DOMAIN/api/v1/routes" \
    -H "Authorization: Bearer $_vt_jwt" \
    | jq -c 'to_entries | map(select(.value|type=="object")) | map({(.key): (.value|keys)}) | add')
  [ -n "$_vt_perms" ] && [ "$_vt_perms" != "null" ] || { echo "vikunja_mint_api_token: could not read routes" >&2; return 1; }
  _vt_body=$(jq -n --arg t "$_vt_title" --argjson p "$_vt_perms" \
    '{title:$t, permissions:$p, expires_at:"2035-01-01T00:00:00Z"}')
  curl -sk --max-time 20 -X PUT "https://vikunja.$DOMAIN/api/v1/tokens" \
    -H "Authorization: Bearer $_vt_jwt" -H 'Content-Type: application/json' -d "$_vt_body" \
    | jq -r '.token // empty'
}
