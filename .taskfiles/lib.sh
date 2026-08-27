# Shared output/logging helpers, sourced by every task in Taskfile.yml and .taskfiles/*.yml.
#
# Why this exists: a real `task setup` run dumped raw tool noise from end to end -- BuildKit
# step timestamps, whole jest suites, OpenSSL's key-generation dots, helm's NOTES, per-poll JSON
# blobs. This file gives every task one line per step instead, without throwing the raw output
# away.
#
# One symbol set, used the same way everywhere -- deliberately small, and nothing else:
#
#   == X ==   a top-level section (apl_header)         ✅  success / a passing check
#   -- X      a subsection within one (apl_section)    ⚠️   warning, prints in BOTH modes
#   ▶         a step starting (apl_run)                ❌  failure
#   [k/N]     that step's place in a counted group     ⏭️   deliberately skipped
#
# Anything that wants to print its own progress art (kind, helm, docker) is captured, not
# streamed -- one loud multi-emoji block in the middle of a plain run is the inconsistency this
# is here to avoid.
#
# Two modes, chosen by the VERBOSE env var (declared in Taskfile.yml's env: block, so it works
# as `VERBOSE=true task setup`, `task setup VERBOSE=true`, or an exported shell var):
#
#   VERBOSE=false (default)  each wrapped step prints "> doing X ... " and then a green tick
#                            with its duration. The command's raw output is captured to
#                            .taskfiles/state/logs/<slug>.log (gitignored) -- nothing is
#                            discarded, it is just not on screen. If the step fails, the last
#                            $APL_TAIL lines of that log are printed inline, so the real error
#                            is visible without going and reading a file.
#   VERBOSE=true             nothing is captured, nothing is suppressed: every command streams
#                            live, exactly as it did before this file existed.
#
# CLAUDE.md rule 2 ("never trust an exit code that passed through a pipe") is the reason
# apl_run redirects with `>` rather than piping to `tee`, and the reason $status is captured
# on the line immediately after the command with nothing in between. Success/failure is
# decided by that exit code and *only* by that exit code -- log contents are never grepped to
# decide it, because this repo's own build logs print handled errors on the way to passing
# (see CLAUDE.md's note about apl-api/apl-console test suites).

APL_STATE_DIR="${APL_STATE_DIR:-.taskfiles/state}"
APL_LOG_DIR="${APL_LOG_DIR:-$APL_STATE_DIR/logs}"
APL_PROGRESS_FILE="$APL_STATE_DIR/progress"
APL_TAIL="${APL_TAIL:-40}"
VERBOSE="${VERBOSE:-false}"

# Bold only when stdout is a terminal, so a redirected/CI run stays clean.
if [ -t 1 ]; then
  APL_B=$(printf '\033[1m')
  APL_D=$(printf '\033[2m')
  APL_R=$(printf '\033[0m')
else
  APL_B=''
  APL_D=''
  APL_R=''
fi

apl_verbose() { [ "$VERBOSE" = "true" ]; }

# --- plain messages -------------------------------------------------------------------------
# Warnings and skips print in BOTH modes: quiet mode hides noise, never signal.
apl_header()  { printf '\n%s== %s ==%s\n' "$APL_B" "$*" "$APL_R"; }
apl_section() { printf '\n%s-- %s%s\n' "$APL_B" "$*" "$APL_R"; }
apl_info()    { printf '   %s\n' "$*"; }
apl_dim()     { printf '   %s%s%s\n' "$APL_D" "$*" "$APL_R"; }
apl_ok()      { printf '✅ %s\n' "$*"; }
apl_warn()    { printf '⚠️  %s\n' "$*" >&2; }
apl_fail()    { printf '❌ %s\n' "$*" >&2; }
apl_skip()    { printf '⏭️  %s\n' "$*"; }

apl_logfile() {
  mkdir -p "$APL_LOG_DIR"
  printf '%s/%s.log' "$APL_LOG_DIR" "$1"
}

# --- progress over a multi-item step --------------------------------------------------------
# The total is always passed in by the caller, computed at run time from what is actually
# enabled/discovered -- never a literal. (install:watch-argocd's TOTAL=$(kubectl get
# applications ... | wc -l) is the pattern this mirrors.) Kept in a file rather than an env
# var because each `task:` reference in a cmds: list is a separate shell.
#
# The counter counts *deliverables*, not commands. images:build-all opens it with N = the
# number of images actually going up, and only the "build this image" step of each one calls
# apl_run (counted); the clone/patch/schema-sync commands that get an image to the point of
# being buildable run through apl_run_sub (uncounted, indented). Before that distinction
# existed a 4-image run counted to [7/4], because every wrapped command advanced the counter.
apl_progress_begin() {
  mkdir -p "$APL_STATE_DIR"
  printf '0 %s\n' "$1" > "$APL_PROGRESS_FILE"
}

apl_progress_end() { rm -f "$APL_PROGRESS_FILE"; }

# Echoes "[k/N] " when a progress context is open, nothing otherwise (so the same task run
# standalone just prints its label).
apl_progress_next() {
  [ -f "$APL_PROGRESS_FILE" ] || return 0
  _pn=0
  _pt=0
  # `read` reports failure on a final line with no newline even though it assigned -- check the
  # variables, not read's status.
  read -r _pn _pt < "$APL_PROGRESS_FILE" || true
  [ -n "$_pt" ] || return 0
  _pn=$((_pn + 1))
  printf '%s %s\n' "$_pn" "$_pt" > "$APL_PROGRESS_FILE"
  printf '[%s/%s] ' "$_pn" "$_pt"
}

# --- the wrapper every noisy step goes through ----------------------------------------------
# usage: apl_run     <log-slug> <label> <command> [args...]   -- advances the [k/N] counter
#        apl_run_sub <log-slug> <label> <command> [args...]   -- identical, but uncounted
#        ...where <command> is very often a shell function defined just above the call, which
#        keeps multi-line bodies out of quoted strings.
#
# Both capture/suppress output identically; the only difference is whether the step consumes a
# slot in an open progress context. There is no third mode: nothing is exempt from capture in
# quiet mode, including `kind create cluster`, whose own colourful tick-per-step output used to
# stream and was the one visually inconsistent block in an otherwise plain ▶/✅ run.
#
# Returns the command's real exit status. Callers should write `|| exit $?` so a failure
# propagates (these scripts deliberately do not rely on `set -e` at the wrapper level -- the
# bodies set it themselves, and they run in a subshell so that stays local to them).
apl_run() { _apl_run_impl "$(apl_progress_next)" "$@"; }

# Same, minus the counter. Indented by the width of a "[k/N] " prefix's leading space so the
# sub-steps read as belonging to the counted step they precede.
apl_run_sub() { _apl_run_impl '   ' "$@"; }

_apl_run_impl() {
  _prefix=$1
  shift
  _slug=$1
  shift
  _label=$1
  shift
  _log=$(apl_logfile "$_slug")
  _start=$(date +%s)

  # Preserve the caller's errexit setting across the call rather than assuming it is off.
  case $- in
    *e*) _had_e=1 ;;
    *) _had_e=0 ;;
  esac
  set +e

  if apl_verbose; then
    printf '%s▶ %s%s%s\n' "$_prefix" "$APL_B" "$_label" "$APL_R"
    ( "$@" )
    _status=$?
  else
    printf '%s▶ %s%s%s ... ' "$_prefix" "$APL_B" "$_label" "$APL_R"
    : > "$_log"
    ( "$@" ) >> "$_log" 2>&1
    _status=$?
  fi

  if [ "$_had_e" = 1 ]; then set -e; fi
  _elapsed=$(( $(date +%s) - _start ))

  if [ "$_status" -eq 0 ]; then
    if apl_verbose; then
      printf '✅ %s (%ss)\n' "$_label" "$_elapsed"
    else
      printf '✅ (%ss)\n' "$_elapsed"
    fi
  else
    if apl_verbose; then
      printf '❌ %s failed after %ss (exit %s)\n' "$_label" "$_elapsed" "$_status" >&2
    else
      printf '❌ failed (%ss, exit %s)\n' "$_elapsed" "$_status"
      # The log can be gone if the step itself removed the state dir (task down) -- don't turn a
      # real failure into a confusing tail error on top of it.
      if [ -f "$_log" ]; then
        printf '   last %s lines of %s:\n' "$APL_TAIL" "$_log" >&2
        tail -n "$APL_TAIL" "$_log" | sed 's/^/   | /' >&2
        printf '   (full output: %s -- or re-run with VERBOSE=true)\n' "$_log" >&2
      else
        printf '   (no log captured -- re-run with VERBOSE=true to see the output)\n' >&2
      fi
    fi
  fi
  return $_status
}

# (There used to be an apl_run_shown here -- a third mode whose wrapped command always streamed,
# used only by `kind create cluster`. It is gone deliberately: an always-streaming exception is
# exactly the inconsistency quiet mode exists to remove, and VERBOSE=true already covers the
# "I want to watch it" case. The verify:* tasks, whose output really is the point, never went
# through a wrapper at all -- they print directly.)

# Dump a captured log on demand -- for the handful of places that need to inspect output they
# captured themselves (install:trust-ca) and still show it under VERBOSE.
apl_show_log() {
  apl_verbose || return 0
  [ -f "$1" ] || return 0
  sed 's/^/   | /' "$1"
}
