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

# --- running N independent items at once ----------------------------------------------------
# usage: apl_run_parallel <log-slug-prefix> <label> <fn> <item> [item...]
#
# Runs <fn> once per <item>, all at the same time, each item's output captured to its own
# .taskfiles/state/logs/<prefix>-<key>.log. Returns non-zero if ANY item failed.
#
# ⚠ CALL THIS DIRECTLY FROM A TASK'S cmds: BLOCK. Never wrap it in apl_run.
#
# That is not style, it is the whole reason this function exists separately. In quiet mode
# apl_run redirects everything its command prints into a log file (see _apl_run_impl above:
# `( "$@" ) >> "$_log" 2>&1`). A progress heartbeat printed from inside an apl_run'd function
# therefore goes to the LOG, and the terminal is left showing `▶ label ... ` with no newline and
# nothing after it for as long as the work takes. That failure -- a run that looks hung for
# minutes while it is in fact perfectly healthy -- has been re-introduced repeatedly. It is
# indistinguishable from a real hang, to a human and to an agent, and it wastes a session every
# time. apl_run_parallel prints its own progress to the task's real stdout instead, which is why
# it must not be nested inside the wrapper that would capture it.
#
# Two further rules this function follows, for the same reason:
#   * It only ever prints COMPLETE lines. apl_run's `▶ label ... ` (deliberately unterminated,
#     so the ✅ lands on the same line) cannot work when several things finish at once -- the
#     interleaving corrupts it. Concurrency and partial lines are incompatible; pick complete
#     lines.
#   * Its heartbeat reports FAILURE, not just progress (CLAUDE.md rule 1b). A watcher that only
#     ever prints good news stays silent through a crash, and silence reads as "still working".
#
# The task calling this must also be `interactive: true`, or Taskfile.yml's global
# `output: group` buffers the whole block until the script exits and re-creates the same symptom
# from the other direction. Every task in seed.yml carries it.
APL_PARALLEL_TICK=${APL_PARALLEL_TICK:-20}
apl_run_parallel() {
  _arp_slug=$1; shift
  _arp_label=$1; shift
  _arp_fn=$1; shift

  _arp_stat=$(mktemp -d)
  _arp_start=$(date +%s)
  _arp_n=0
  _arp_keys=""
  for _arp_item in "$@"; do
    _arp_n=$((_arp_n + 1))
    # Display/log key: the middle field of a "role:team:repo" spec is the team, which is what a
    # human reading this actually tracks. Falls back to the whole item, sanitised for a filename.
    _arp_key=$(printf '%s' "$_arp_item" | cut -d: -f2)
    [ -n "$_arp_key" ] || _arp_key=$(printf '%s' "$_arp_item" | tr -c 'a-zA-Z0-9_-' '-')
    _arp_keys="$_arp_keys $_arp_key"
    _arp_log=$(apl_logfile "$_arp_slug-$_arp_key")
    : > "$_arp_log"
    # The item's own output goes to its log; only the exit status and elapsed time come back, via
    # a file rather than a pid, so this needs no job-control builtins (the Taskfile runs under
    # mvdan/sh, not bash).
    (
      _arp_t0=$(date +%s)
      # Quoted: the item is passed as exactly ONE argument. Unquoted it would also be glob-expanded,
      # so an item that happened to contain a metacharacter would silently become a different
      # argument list, or none.
      #
      # Wrapped in `if`, never called bare. A bare call is fatal under `set -e`: errexit aborts
      # this subshell the instant the item fails, BEFORE the status file below is written -- so
      # the item never reports, the heartbeat prints "running: <item>" forever, and the driver
      # waits on a status that can never appear. Observed live 2026-08-29: `ratings` died at
      # 21:36:20 and was still being announced as running 10 minutes later, with the whole seed
      # hung behind it. A command inside an `if` condition is exempt from errexit, so failure
      # reaches the status file instead of killing the worker.
      if "$_arp_fn" "$_arp_item" > "$_arp_log" 2>&1; then _arp_rc=0; else _arp_rc=$?; fi
      # Written to a temp name and MOVED into place, never straight to the final path. `>` creates
      # and truncates the file before printf writes to it, so a plain redirect leaves a window in
      # which the file exists and is EMPTY -- and the heartbeat, reading it in that window, gets
      # no status and reports the item as failed. Observed live: a healthy item was announced as
      # "FAILED" mid-run and then finished ✅, which is worse than no heartbeat at all. rename(2)
      # is atomic, so the file only ever appears complete.
      printf '%s %s\n' "$_arp_rc" "$(( $(date +%s) - _arp_t0 ))" > "$_arp_stat/.$_arp_key.tmp"
      mv "$_arp_stat/.$_arp_key.tmp" "$_arp_stat/$_arp_key"
    ) &
  done

  printf '▶ %s%s%s -- %s in parallel, one log each\n' "$APL_B" "$_arp_label" "$APL_R" "$_arp_n"

  # Heartbeat. Prints one complete line per tick naming what is still running AND what has
  # already failed, so a dead item surfaces at the next tick instead of at the end.
  while :; do
    _arp_done=0; _arp_busy=""; _arp_bad=""
    for _arp_key in $_arp_keys; do
      if [ -f "$_arp_stat/$_arp_key" ]; then
        _arp_done=$((_arp_done + 1))
        # Cleared before every read: a failed read leaves the PREVIOUS item's status in place,
        # which silently attributes one item's outcome to another.
        _arp_rc=""; _arp_el=""
        read -r _arp_rc _arp_el < "$_arp_stat/$_arp_key" || true
        [ "${_arp_rc:-1}" -eq 0 ] || _arp_bad="$_arp_bad $_arp_key"
      else
        _arp_busy="$_arp_busy$_arp_key "
      fi
    done
    [ "$_arp_done" -ge "$_arp_n" ] && break
    printf '   [%ss] %s/%s done%s | running: %s\n' \
      "$(( $(date +%s) - _arp_start ))" "$_arp_done" "$_arp_n" \
      "$([ -n "$_arp_bad" ] && printf ', FAILED:%s' "$_arp_bad")" "$_arp_busy"
    sleep "$APL_PARALLEL_TICK"
  done
  wait

  # One complete result line per item, in the order they were given rather than the order they
  # finished, so two runs are diffable.
  _arp_rc_all=0
  for _arp_key in $_arp_keys; do
    _arp_rc=""; _arp_el=""
    read -r _arp_rc _arp_el < "$_arp_stat/$_arp_key" || true
    _arp_log=$(apl_logfile "$_arp_slug-$_arp_key")
    if [ "${_arp_rc:-1}" -eq 0 ]; then
      printf '   ✅ %-12s (%ss)\n' "$_arp_key" "$_arp_el"
    else
      _arp_rc_all=$_arp_rc
      printf '   ❌ %-12s failed (%ss, exit %s)\n' "$_arp_key" "$_arp_el" "$_arp_rc" >&2
      if [ -f "$_arp_log" ]; then
        printf '      last %s lines of %s:\n' "$APL_TAIL" "$_arp_log" >&2
        tail -n "$APL_TAIL" "$_arp_log" | sed 's/^/      | /' >&2
      fi
    fi
  done
  rm -rf "$_arp_stat"
  printf '   %s total: %ss wall clock\n' "$_arp_label" "$(( $(date +%s) - _arp_start ))"
  return "$_arp_rc_all"
}

# --- serialising the parts of a parallel item that must not overlap -------------------------
# usage: apl_with_api_lock <command> [args...]
#
# Wraps a mutating apl-api call so only one runs at a time across concurrent items.
#
# Every team's setup writes to the SAME git values repo through apl-api (team, build, workload,
# service, netpol). Four of those landing at once is a push race on one repository. The waits
# around them -- 180s for a webhook, 90s for an EventListener, minutes for a build -- are what
# actually take the time and are perfectly safe to overlap, so the lock is held for seconds and
# the parallelism is kept.
#
# flock(1) is from util-linux and is present on any Linux host that can run the rest of this
# lab; there is no attempt to emulate it, because a silent no-op lock would be worse than a
# hard failure.
#
# Implemented with `mkdir`, not flock, and NOT because flock is unavailable -- it is installed.
# Neither flock form works here:
#   * `flock <file> <command>` EXECs its command, so it cannot run a shell function, and every
#     caller of this is a function.
#   * `( flock 9; ... ) 9>>lock` -- the usual workaround -- fails under go-task. Taskfile.yml runs
#     commands through mvdan/sh, which honours the `9>>` redirect for its own builtins but does
#     NOT pass fd 9 to an exec'd binary, so flock exits 1 having seen no such descriptor.
#     Verified live: the redirect succeeds and `flock 9` immediately after it fails.
#
# `mkdir` is atomic on any POSIX filesystem and needs no descriptor, so it works identically under
# bash and mvdan/sh. No subshell either, which means the wrapped command's exit status and any
# variables it sets are the caller's, matching how apl_run behaves.
APL_LOCK_STALE=${APL_LOCK_STALE:-120}
# apl_with_lock <lock-name> <stale-seconds> <command> [args...] -- run <command> holding a named
# mutex. Used for any resource that parallel seed items share and that cannot take concurrent
# writers: the apl-api values repo, and the single shared gitea-runner download.
apl_with_lock() {
  _awl_name=$1; shift
  _awl_stale=$1; shift
  _awl_dir="${APL_STATE_DIR:-.taskfiles/state}/.$_awl_name.lock.d"
  mkdir -p "${APL_STATE_DIR:-.taskfiles/state}"
  _awl_waited=0
  while ! mkdir "$_awl_dir" 2>/dev/null; do
    # A holder that died leaves the directory behind and would deadlock every other item forever,
    # so a lock older than its stale window is treated as abandoned rather than slow.
    if [ "$_awl_waited" -ge "$_awl_stale" ]; then
      printf '⚠️  %s lock held for %ss -- assuming a dead holder and taking it\n' "$_awl_name" "$_awl_waited" >&2
      rm -rf "$_awl_dir"
      _awl_waited=0
      continue
    fi
    sleep 1
    _awl_waited=$((_awl_waited + 1))
  done
  # `if`, not a bare call: under `set -e` a failing command would abort this function before the
  # release below, stranding the lock until its stale window expires. Same errexit trap that hung
  # apl_run_parallel -- see the comment on its worker subshell.
  if "$@"; then _awl_rc=0; else _awl_rc=$?; fi
  rmdir "$_awl_dir" 2>/dev/null || rm -rf "$_awl_dir" 2>/dev/null || true
  return "$_awl_rc"
}

apl_with_api_lock() {
  # The critical section is two curl calls with --max-time 15, so anything older than
  # APL_LOCK_STALE is not slow, it is gone.
  apl_with_lock api "$APL_LOCK_STALE" "$@"
}
