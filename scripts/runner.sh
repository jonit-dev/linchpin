#!/bin/sh
# The run's lifecycle, as code that waits instead of a model that polls.
#
# The behavior this replaces, measured across 17 field sessions: 1,028
# `write_stdin` calls and 403 outer calls whose only content was reading a lane
# log. A manager assembled each launch command by hand, then spent a model turn
# per interval restating that the lane was still running; one documented batch
# spent 954 thirty-second polls and 739 one-second polls that way. Waiting is a
# mechanism, so the runner owns it: the wait happens inside this file, and a
# timeout is a heartbeat rather than a question put to a model.
#
# Everything durable lives under <repo>/.linchpin/runs/<run-id>/:
#   state.json        authoritative versioned state, one writer at a time
#   events.jsonl      append-only, monotonic cursor, rebuildable from state
#   operations/<id>/  intent, receipt, process identity, exit, raw log
#   run.md            human projection; never a source of approval
set -eu

runner_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runner_self="$runner_script_dir/$(basename -- "$0")"

runner_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

runner_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# ---------------------------------------------------------------- identity ---

process_identity() {
  # PID plus the kernel's start-time token for that PID. A PID alone is not an
  # identity: pids are recycled, and a recycled pid that answers `kill -0` reads
  # exactly like the lane that is still running.
  runner_ident_pid="$1"
  if [ -r "/proc/$runner_ident_pid/stat" ]; then
    # Strip `pid (comm)` first: a command name may contain spaces and
    # parentheses, which would shift every field after it.
    sed 's/.*) //' "/proc/$runner_ident_pid/stat" | awk '{ print $20 }'
    return 0
  fi
  runner_ident_lstart=$(ps -o lstart= -p "$runner_ident_pid" 2>/dev/null | tr -s ' ' '-' | sed 's/^-//; s/-$//')
  [ -n "$runner_ident_lstart" ] || return 1
  printf '%s\n' "$runner_ident_lstart"
}

process_alive() {
  # PID $1 is alive *and* is still the process $2 identified. The second half is
  # the point: without it, a recycled pid resumes as a running lane and the run
  # waits forever on a process that belongs to something else.
  kill -0 "$1" 2>/dev/null || return 1
  [ -n "${2:-}" ] && [ "${2:-}" != unknown ] || return 0
  runner_alive_identity=$(process_identity "$1" 2>/dev/null) || return 1
  [ "$runner_alive_identity" = "$2" ]
}

# ------------------------------------------------------------------- state ---

run_dir_for() {
  printf '%s/.linchpin/runs/%s\n' "$1" "$2"
}

runner_state_read() {
  jq -r "$2" "$1/state.json"
}

runner_state_write() {
  # Same-filesystem temporary file plus rename: a reader sees the whole previous
  # state or the whole next one. A half-written state.json is a run nobody can
  # resume, which is the failure this file exists to prevent.
  runner_write_dir="$1"
  runner_write_tmp="$runner_write_dir/.state.json.$$"
  cat > "$runner_write_tmp"
  jq empty "$runner_write_tmp" 2>/dev/null ||
    { rm -f "$runner_write_tmp"; runner_die 'runner refused to publish malformed state'; }
  mv "$runner_write_tmp" "$runner_write_dir/state.json"
}

runner_state_update() {
  # runner_state_update DIR 'FILTER' [jq options...]. The revision is bumped on
  # every published change, so an event can name the state it was projected
  # from.
  runner_update_dir="$1"
  runner_update_filter="$2"
  shift 2
  jq "$@" "$runner_update_filter | .revision = (.revision + 1)" "$runner_update_dir/state.json" |
    runner_state_write "$runner_update_dir"
}

# -------------------------------------------------------------------- lock ---

runner_lock_acquire() {
  # `mkdir` is the atomic primitive every POSIX filesystem already has. The
  # owner file inside it is what makes a stale lock distinguishable from a live
  # one: a supervisor killed with SIGKILL leaves the directory behind, and a
  # lock nothing can break is a run nobody can resume.
  runner_lock_dir="$1/lock"
  runner_lock_waited=0
  runner_lock_limit="${2:-10}"
  while :; do
    if mkdir "$runner_lock_dir" 2>/dev/null; then
      printf '%s %s\n' "$$" "$(process_identity $$)" > "$runner_lock_dir/owner"
      return 0
    fi
    runner_lock_owner_pid=$(awk '{ print $1; exit }' "$runner_lock_dir/owner" 2>/dev/null || true)
    runner_lock_owner_identity=$(awk '{ print $2; exit }' "$runner_lock_dir/owner" 2>/dev/null || true)
    if [ -n "$runner_lock_owner_pid" ] && ! process_alive "$runner_lock_owner_pid" "$runner_lock_owner_identity"; then
      runner_event "$1" lock_broken '' "the previous writer (pid $runner_lock_owner_pid) is gone; taking the lock"
      rm -rf "$runner_lock_dir"
      continue
    fi
    [ "$runner_lock_waited" -lt "$runner_lock_limit" ] || return 1
    sleep 1
    runner_lock_waited=$((runner_lock_waited + 1))
  done
}

runner_lock_release() {
  [ ! -d "$1/lock" ] || rm -rf "$1/lock"
}

# ------------------------------------------------------------------ events ---

runner_event() {
  # Append-only, one JSON object per line, cursor = line number. Ordinary events
  # carry identities and a concise reason; raw logs stay on disk. An event
  # stream that embeds log tails is the repeated full-log read this replaces,
  # moved one level down.
  #
  # The cursor is assigned inside a short critical section of its own, so a
  # resume announcing itself beside a live supervisor cannot mint the same
  # cursor twice. It is a different lock from the run lock, which the supervisor
  # holds for the whole run.
  runner_event_dir="$1"
  runner_event_tries=0
  while ! mkdir "$runner_event_dir/events.lock" 2>/dev/null; do
    runner_event_tries=$((runner_event_tries + 1))
    [ "$runner_event_tries" -lt 5 ] || { rm -rf "$runner_event_dir/events.lock"; break; }
    sleep 1
  done
  runner_event_revision=0
  [ ! -f "$runner_event_dir/state.json" ] ||
    runner_event_revision=$(runner_state_read "$runner_event_dir" '.revision')
  runner_event_cursor=$(( $(wc -l < "$runner_event_dir/events.jsonl" 2>/dev/null || echo 0) + 1 ))
  jq -c -n --argjson cursor "$runner_event_cursor" --argjson revision "$runner_event_revision" \
    --arg at "$(runner_now)" --arg type "$2" \
    --arg operation "${3:-}" --arg reason "${4:-}" \
    '{cursor: $cursor, revision: $revision, at: $at, type: $type, operation: $operation, reason: $reason}' \
    >> "$runner_event_dir/events.jsonl"
  rm -rf "$runner_event_dir/events.lock"
}

runner_cursor_now() {
  wc -l < "$1/events.jsonl" | tr -d ' '
}

runner_projection() {
  # run.md keeps the terminal vocabulary the coordinator already prints. It is a
  # projection: never read back as state, never a source of approval.
  runner_proj_dir="$1"
  {
    printf '# Linchpin run %s\n\n' "$(runner_state_read "$runner_proj_dir" '.run')"
    printf -- '- status: %s\n' "$(runner_state_read "$runner_proj_dir" '.status')"
    printf -- '- revision: %s\n' "$(runner_state_read "$runner_proj_dir" '.revision')"
    printf -- '- repo: %s\n' "$(runner_state_read "$runner_proj_dir" '.repo')"
    printf -- '- audit: %s (eligible=%s)\n' \
      "$(runner_state_read "$runner_proj_dir" '.audit.mode')" \
      "$(runner_state_read "$runner_proj_dir" '.audit.eligible')"
    printf '\n## Lanes\n\n'
    runner_state_read "$runner_proj_dir" '
      .groups[] as $g | $g.lanes[] |
      "- \($g.id)/\(.id): \(.state)" +
      (if (.operation // "") != "" then " operation=\(.operation)" else "" end) +
      (if .exit != null then " exit=\(.exit)" else "" end)'
    printf '\n## Events\n\n'
    if [ -s "$runner_proj_dir/events.jsonl" ]; then
      jq -r '"- \(.cursor) \(.type) \(.operation) \(.reason)"' "$runner_proj_dir/events.jsonl"
    fi
  } > "$runner_proj_dir/run.md"
}

# --------------------------------------------------------------- bootstrap ---

runner_bootstrap_validate() {
  # A bootstrap file missing a field is refused here. The alternative is the
  # failure this replaces: a manager reconstructing a launch command from
  # memory, which is how a lane gets started in the wrong directory or against
  # the wrong base.
  runner_boot="$1"
  jq empty "$runner_boot" 2>/dev/null || runner_die "bootstrap state is not valid JSON: $runner_boot"
  [ "$(jq -r '.bootstrap_contract // ""' "$runner_boot")" = v1 ] ||
    runner_die "bootstrap state is not bootstrap_contract v1: $runner_boot"
  for runner_boot_key in repo base delivery max_lanes gates groups; do
    [ "$(jq -r --arg k "$runner_boot_key" 'has($k)' "$runner_boot")" = true ] ||
      runner_die "bootstrap state has no $runner_boot_key: $runner_boot (the runner does not guess it)"
  done
  runner_boot_eligible=$(jq -r '.audit.eligible // ""' "$runner_boot")
  [ -n "$runner_boot_eligible" ] ||
    runner_die "bootstrap state carries no resolved audit eligibility: $runner_boot (run linchpin.sh audit --out first)"
  [ "$runner_boot_eligible" != unresolved ] ||
    runner_die "bootstrap state freezes an unresolved audit eligibility: $runner_boot"
  [ "$(jq -r '(.groups // []) | length' "$runner_boot")" -gt 0 ] ||
    runner_die "bootstrap state declares no groups: $runner_boot"
  runner_boot_problem=$(jq -r '
    [ .groups[] |
      (if (.id // "") == "" then "a group has no id" else empty end),
      (if ((.mode // "") != "parallel" and (.mode // "") != "sequential") then "group \(.id // "?") has no parallel/sequential mode" else empty end),
      (if ((.lanes // []) | length) == 0 then "group \(.id // "?") declares no lanes" else empty end),
      ( .lanes[]? |
        (if (.id // "") == "" then "a lane has no id" else empty end),
        (if (.prd // "") == "" then "lane \(.id // "?") names no PRD" else empty end),
        (if ((.command // []) | length) == 0 then "lane \(.id // "?") carries no command argv" else empty end)
      )
    ] | first // ""' "$runner_boot")
  [ -z "$runner_boot_problem" ] || runner_die "incomplete bootstrap state: $runner_boot_problem"
  runner_boot_repo=$(jq -r '.repo' "$runner_boot")
  [ -d "$runner_boot_repo" ] || runner_die "bootstrap repo does not exist: $runner_boot_repo"
  # Every lane's working directory must exist before anything is launched: a
  # lane started in a directory that is not there commits to whichever one it
  # lands in.
  runner_boot_missing=$(jq -r '[.groups[].lanes[] | select((.cwd // "") != "") | .cwd] | .[]' "$runner_boot" |
    while IFS= read -r runner_boot_cwd; do
      [ -n "$runner_boot_cwd" ] || continue
      [ -d "$runner_boot_cwd" ] || printf '%s\n' "$runner_boot_cwd"
    done)
  [ -z "$runner_boot_missing" ] ||
    runner_die "bootstrap names a lane working directory that does not exist: $(printf '%s' "$runner_boot_missing" | tr '\n' ' ')"
}

# ------------------------------------------------------------------- start ---

runner_audit_recompute() {
  # A run option that changes the audit decision has to change the decision, not
  # only the word `mode` beside it. The shipped override rewrote the mode and
  # left `eligible: no, reason: audit disabled` untouched, so a run switched on
  # by hand carried a frozen "no" through every later check.
  #
  # Eligibility is a table over the classes the batch already froze, so it is
  # recomputed from those rather than from the PRDs again: re-reading a PRD here
  # would let the runner and the bootstrap disagree about the same batch.
  runner_recompute_dir="$1"
  runner_recompute_mode="$2"
  runner_recompute_classes=$(runner_state_read "$runner_recompute_dir" '.prds[]?.class // empty' | tr '\n' ' ')
  if [ -n "$(printf '%s' "$runner_recompute_classes" | tr -d ' ')" ]; then
    # shellcheck disable=SC2086
    runner_recompute_verdict=$(sh "$runner_script_dir/audit-policy.sh" eligible \
      "$runner_recompute_mode" $runner_recompute_classes) ||
      runner_die "run --audit $runner_recompute_mode could not be resolved against the frozen PRD classifications"
    runner_recompute_eligible=$(printf '%s' "$runner_recompute_verdict" | cut -f1 | sed 's/^eligible=//')
    runner_recompute_reason=$(printf '%s' "$runner_recompute_verdict" | cut -f2 | sed 's/^reason=//')
  else
    # A bootstrap that froze no classifications cannot be re-decided by the auto
    # table. `on` and `off` still say what they say; `auto` has nothing to
    # recompute from and is refused rather than guessed.
    case "$runner_recompute_mode" in
      on) runner_recompute_eligible=yes
          runner_recompute_reason='audit is on for this run (run option); one batch audit is required at its checkpoint' ;;
      off) runner_recompute_eligible=no
           runner_recompute_reason='audit is off for this run (run option); no auditor capability check, probe, launch, or audit gate' ;;
      *) runner_die 'run --audit auto needs the PRD classifications the bootstrap freezes; run linchpin.sh audit --out first' ;;
    esac
  fi
  [ "$runner_recompute_eligible" != unresolved ] ||
    runner_die "run --audit $runner_recompute_mode leaves eligibility unresolved: assess the PRDs with linchpin.sh audit --assess before overriding here"
  runner_state_update "$runner_recompute_dir" \
    '.audit = (.audit + {mode: $mode, mode_source: "run-option", eligible: $eligible, reason: $reason})' \
    --arg mode "$runner_recompute_mode" --arg eligible "$runner_recompute_eligible" \
    --arg reason "$runner_recompute_reason"
  runner_event "$runner_recompute_dir" audit_mode_overridden '' \
    "run --audit $runner_recompute_mode recomputed eligibility to $runner_recompute_eligible: $runner_recompute_reason"
}

runner_start() {
  runner_bootstrap=''
  runner_audit_override=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --bootstrap) [ "$#" -ge 2 ] || runner_die 'run --bootstrap needs a path'; runner_bootstrap="$2"; shift 2 ;;
      --bootstrap=*) runner_bootstrap="${1#--bootstrap=}"; shift ;;
      --audit) [ "$#" -ge 2 ] || runner_die 'run --audit needs on, off, or auto'; runner_audit_override="$2"; shift 2 ;;
      --audit=*) runner_audit_override="${1#--audit=}"; shift ;;
      *) runner_die "unknown run option: $1" ;;
    esac
  done
  [ -n "$runner_bootstrap" ] ||
    runner_die 'usage: linchpin.sh run --bootstrap PATH [--audit on|off|auto] | run --resume RUN_ID'
  [ -f "$runner_bootstrap" ] || runner_die "missing file: $runner_bootstrap"
  case "$runner_audit_override" in
    ''|on|off|auto) ;;
    *) runner_die "run --audit is on, off, or auto: $runner_audit_override" ;;
  esac
  runner_bootstrap_validate "$runner_bootstrap"
  runner_repo=$(jq -r '.repo' "$runner_bootstrap")
  runner_run="run-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  runner_run_dir=$(run_dir_for "$runner_repo" "$runner_run")
  mkdir -p "$runner_run_dir/operations" "$runner_run_dir/evidence"
  : > "$runner_run_dir/events.jsonl"
  cp "$runner_bootstrap" "$runner_run_dir/bootstrap.json"

  # The frozen decisions become state. Nothing downstream re-derives them; that
  # is what frozen is for.
  jq --arg run "$runner_run" --arg at "$(runner_now)" '
    {
      state_contract: "v1",
      run: $run,
      revision: 1,
      status: "pending",
      created_at: $at,
      repo: .repo,
      base: .base,
      delivery: .delivery,
      max_lanes: .max_lanes,
      audit: .audit,
      roles: (.roles // {}),
      prds: (.prds // []),
      gates: .gates,
      gate_results: [],
      groups: [ .groups[] | {
        id: .id,
        mode: .mode,
        lanes: [ .lanes[] | {
          id: .id, prd: .prd, cwd: (.cwd // ""), stdin: (.stdin // ""),
          command: .command, state: "PENDING", operation: "", attempts: 0, exit: null
        } ]
      } ],
      counters: {launch_attempts: 0, completed_reviews: 0, failed_repairs: 0, audit_attempts: 0}
    }' "$runner_bootstrap" | runner_state_write "$runner_run_dir"
  runner_event "$runner_run_dir" run_started '' "bootstrap accepted from $runner_bootstrap"
  [ -z "$runner_audit_override" ] || runner_audit_recompute "$runner_run_dir" "$runner_audit_override"
  runner_projection "$runner_run_dir"
  runner_supervise_detached "$runner_run_dir"
  printf 'RUN-STARTED run=%s cursor=%s dir=%s\n' "$runner_run" \
    "$(runner_cursor_now "$runner_run_dir")" "$runner_run_dir"
}

runner_resume() {
  runner_run="$1"
  shift
  runner_repo="$PWD"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) [ "$#" -ge 2 ] || runner_die 'resume --repo needs a directory'; runner_repo="$2"; shift 2 ;;
      --repo=*) runner_repo="${1#--repo=}"; shift ;;
      *) runner_die "unknown resume option: $1" ;;
    esac
  done
  runner_run_dir=$(run_dir_for "$runner_repo" "$runner_run")
  [ -f "$runner_run_dir/state.json" ] || runner_die "no such run: $runner_run (looked in $runner_run_dir)"
  runner_status=$(runner_state_read "$runner_run_dir" '.status')
  case "$runner_status" in
    complete|blocked|awaiting_audit)
      printf 'RUN-TERMINAL run=%s status=%s cursor=%s\n' "$runner_run" "$runner_status" \
        "$(runner_cursor_now "$runner_run_dir")"
      return 0
      ;;
  esac
  # Two resumes racing each other must not launch the same paid operation
  # twice. The supervisor is the only writer, so the second resume finds one
  # already alive and reconnects rather than starting a second.
  runner_supervisor_pid=$(runner_state_read "$runner_run_dir" '.supervisor.pid // ""')
  runner_supervisor_identity=$(runner_state_read "$runner_run_dir" '.supervisor.identity // ""')
  if [ -n "$runner_supervisor_pid" ] && process_alive "$runner_supervisor_pid" "$runner_supervisor_identity"; then
    runner_event "$runner_run_dir" run_reconnected '' \
      "a supervisor is already running (pid $runner_supervisor_pid); no second one started"
    printf 'RUN-RECONNECTED run=%s cursor=%s supervisor=%s\n' "$runner_run" \
      "$(runner_cursor_now "$runner_run_dir")" "$runner_supervisor_pid"
    return 0
  fi
  runner_event "$runner_run_dir" run_resumed '' 'no live supervisor; reconciling recorded operations'
  runner_supervise_detached "$runner_run_dir"
  printf 'RUN-RESUMED run=%s cursor=%s dir=%s\n' "$runner_run" \
    "$(runner_cursor_now "$runner_run_dir")" "$runner_run_dir"
}

runner_supervise_detached() {
  # `setsid` for the same reason `linchpin.sh launch` uses it: the agent tool
  # call that started this takes its whole process group down when it returns,
  # and a supervisor reaped at launch looks exactly like a run that finished.
  runner_detach_dir="$1"
  runner_detach='setsid'
  command -v setsid >/dev/null 2>&1 || runner_detach=''
  $runner_detach sh "$runner_self" supervise "$runner_detach_dir" \
    >> "$runner_detach_dir/supervisor.log" 2>&1 < /dev/null &
  # Long enough for the supervisor to claim the lock and record its identity, so
  # a resume issued immediately after sees it.
  runner_detach_waited=0
  while [ "$runner_detach_waited" -lt 15 ]; do
    [ -z "$(runner_state_read "$runner_detach_dir" '.supervisor.pid // ""')" ] || break
    sleep 1
    runner_detach_waited=$((runner_detach_waited + 1))
  done
}

# -------------------------------------------------------------- operations ---

runner_launch_operation() {
  # Intent before launch, always. A crash between "intent recorded" and "child
  # started" is recoverable because the intent is on disk; a crash the other way
  # round leaves a paid provider call nothing knows about.
  runner_op="$1"
  runner_op_lane="$2"
  runner_op_group="$3"
  shift 3
  runner_op_dir="$run_dir/operations/$runner_op"
  mkdir -p "$runner_op_dir"
  jq -n --arg operation "$runner_op" --arg lane "$runner_op_lane" --arg group "$runner_op_group" \
    --arg at "$(runner_now)" --arg cwd "$runner_op_cwd" --arg stdin "$runner_op_stdin" \
    --argjson command "$runner_op_command" \
    '{operation: $operation, lane: $lane, group: $group, recorded_at: $at,
      cwd: $cwd, stdin: $stdin, command: $command}' > "$runner_op_dir/intent.json"
  runner_event "$run_dir" operation_intent "$runner_op" "recorded before launch for lane $runner_op_lane"

  # The child writes its own pid before it changes directory and its own exit
  # code after the provider returns, for the reason `launch` documents: `$!` is
  # not reliably the process to watch once `setsid` may or may not have forked.
  runner_child='printf "%s\n" "$$" > "$LINCHPIN_OP_DIR/pid"
[ -z "$LINCHPIN_OP_CWD" ] || cd "$LINCHPIN_OP_CWD" || exit 1
"$@" >> "$LINCHPIN_OP_DIR/log" 2>&1
printf "%s\n" "$?" > "$LINCHPIN_OP_DIR/exit"'
  runner_child_detach='setsid'
  command -v setsid >/dev/null 2>&1 || runner_child_detach=''
  : > "$runner_op_dir/log"
  if [ -n "$runner_op_stdin" ] && [ -f "$runner_op_stdin" ]; then
    LINCHPIN_OP_DIR="$runner_op_dir" LINCHPIN_OP_CWD="$runner_op_cwd" \
      $runner_child_detach sh -c "$runner_child" sh "$@" \
      < "$runner_op_stdin" > /dev/null 2>&1 &
  else
    LINCHPIN_OP_DIR="$runner_op_dir" LINCHPIN_OP_CWD="$runner_op_cwd" \
      $runner_child_detach sh -c "$runner_child" sh "$@" \
      < /dev/null > /dev/null 2>&1 &
  fi

  runner_op_waited=0
  while [ "$runner_op_waited" -lt 10 ]; do
    [ ! -s "$runner_op_dir/pid" ] || break
    sleep 1
    runner_op_waited=$((runner_op_waited + 1))
  done
  if [ ! -s "$runner_op_dir/pid" ]; then
    # The ambiguous window. The child may have died before writing anything, or
    # it may have reached the provider and be spending money right now. Neither
    # a relaunch nor a completion may be assumed from here.
    jq -n --arg operation "$runner_op" --arg at "$(runner_now)" \
      '{operation: $operation, state: "launch_uncertain", at: $at}' > "$runner_op_dir/receipt.json"
    runner_event "$run_dir" operation_launch_uncertain "$runner_op" \
      'the child recorded no pid; reconcile the provider session before relaunching'
    return 1
  fi
  runner_op_pid=$(tr -dc '0-9' < "$runner_op_dir/pid")
  runner_op_identity=$(process_identity "$runner_op_pid" 2>/dev/null || printf 'unknown')
  jq -n --arg operation "$runner_op" --arg at "$(runner_now)" --arg pid "$runner_op_pid" \
    --arg identity "$runner_op_identity" \
    '{operation: $operation, state: "running", at: $at, pid: $pid, process_identity: $identity}' \
    > "$runner_op_dir/receipt.json"
  runner_event "$run_dir" operation_launched "$runner_op" "pid $runner_op_pid identity $runner_op_identity"
  return 0
}

runner_operation_live() {
  runner_live_dir="$run_dir/operations/$1"
  [ -f "$runner_live_dir/receipt.json" ] || return 1
  [ "$(jq -r '.state' "$runner_live_dir/receipt.json")" = running ] || return 1
  [ ! -f "$runner_live_dir/exit" ] || return 1
  runner_live_pid=$(jq -r '.pid // ""' "$runner_live_dir/receipt.json")
  [ -n "$runner_live_pid" ] || return 1
  process_alive "$runner_live_pid" "$(jq -r '.process_identity // ""' "$runner_live_dir/receipt.json")"
}

runner_collect_exit() {
  [ -f "$run_dir/operations/$1/exit" ] || return 1
  tr -dc '0-9' < "$run_dir/operations/$1/exit"
}

runner_record_exit() {
  # A completed result is accepted once, by operation id. The second intake is a
  # recorded no-op rather than a second event, because a duplicate intake is
  # exactly how one provider call gets counted twice.
  runner_exit_group="$1"
  runner_exit_lane="$2"
  runner_exit_op="$3"
  runner_exit_code="$4"
  if [ -f "$run_dir/operations/$runner_exit_op/exit-receipt.json" ]; then
    runner_event "$run_dir" operation_result_duplicate "$runner_exit_op" \
      "already accepted with exit $(jq -r '.exit' "$run_dir/operations/$runner_exit_op/exit-receipt.json"); the second intake changed nothing"
    return 0
  fi
  runner_exit_state=DONE
  [ "$runner_exit_code" = 0 ] || runner_exit_state=PARTIAL
  runner_state_update "$run_dir" '
    (.groups[] | select(.id == $g) | .lanes[] | select(.id == $l)) |= (
      .state = $state | .exit = $code
    )' --arg g "$runner_exit_group" --arg l "$runner_exit_lane" \
       --arg state "$runner_exit_state" --argjson code "$runner_exit_code"
  jq -n --arg operation "$runner_exit_op" --arg at "$(runner_now)" --argjson code "$runner_exit_code" \
    '{operation: $operation, state: "exited", at: $at, exit: $code}' \
    > "$run_dir/operations/$runner_exit_op/exit-receipt.json"
  runner_event "$run_dir" operation_exited "$runner_exit_op" \
    "lane $runner_exit_lane exit $runner_exit_code state $runner_exit_state"
}

runner_still_running() {
  for runner_check in $1; do
    [ -n "$runner_check" ] || continue
    if runner_operation_live "$runner_check"; then
      printf '%s ' "$runner_check"
    fi
  done
  printf '\n'
}

runner_await_operations() {
  # The wait itself. No model is consulted, no log is read, and the interval is
  # not a turn: this is the 954-poll batch replaced by one sleep loop.
  [ -n "$(printf '%s\n' $1 | awk 'NF')" ] || return 0
  runner_await_interval="${LINCHPIN_RUNNER_INTERVAL:-5}"
  while :; do
    [ -n "$(printf '%s\n' "$(runner_still_running "$1")" | awk 'NF')" ] || return 0
    sleep "$runner_await_interval"
  done
}

runner_reconcile_lane() {
  # One recorded lane, brought up to date without launching anything. Returns 0
  # when the lane needs no launch.
  runner_rec_group="$1"
  runner_rec_lane="$2"
  runner_rec_op="$3"
  [ -n "$runner_rec_op" ] || return 1
  if runner_operation_live "$runner_rec_op"; then
    runner_event "$run_dir" operation_reconnected "$runner_rec_op" \
      "lane $runner_rec_lane is already running; no second launch"
    runner_reconnected="$runner_rec_op"
    return 0
  fi
  runner_reconnected=''
  if runner_rec_exit=$(runner_collect_exit "$runner_rec_op"); then
    runner_record_exit "$runner_rec_group" "$runner_rec_lane" "$runner_rec_op" "$runner_rec_exit"
    return 0
  fi
  if [ "$(jq -r '.state // ""' "$run_dir/operations/$runner_rec_op/receipt.json" 2>/dev/null)" = launch_uncertain ]; then
    # Never relaunch out of the ambiguous window. Exactly-once remote execution
    # is not something a local runner can promise without a provider
    # idempotency guarantee, and a duplicate paid call is worse than a run that
    # stops and says what it needs.
    runner_state_update "$run_dir" \
      '(.groups[] | select(.id == $g) | .lanes[] | select(.id == $l) | .state) = "BLOCKED"' \
      --arg g "$runner_rec_group" --arg l "$runner_rec_lane"
    runner_event "$run_dir" decision_required "$runner_rec_op" \
      "lane $runner_rec_lane crashed in its launch window; reconcile the provider session, then record the operation result or abandon it"
    return 0
  fi
  # A receipt that says running with no live process and no exit code: the
  # provider call is over and its outcome was never recorded.
  if [ -f "$run_dir/operations/$runner_rec_op/receipt.json" ]; then
    runner_state_update "$run_dir" \
      '(.groups[] | select(.id == $g) | .lanes[] | select(.id == $l) | .state) = "BLOCKED"' \
      --arg g "$runner_rec_group" --arg l "$runner_rec_lane"
    runner_event "$run_dir" decision_required "$runner_rec_op" \
      "lane $runner_rec_lane left no exit receipt; its recorded process is gone and its result was never accepted"
    return 0
  fi
  return 1
}

# -------------------------------------------------------------- supervisor ---

runner_supervise() {
  run_dir="$1"
  [ -f "$run_dir/state.json" ] || runner_die "no run state in $run_dir"
  if ! runner_lock_acquire "$run_dir" 30; then
    runner_event "$run_dir" supervisor_declined '' 'another writer holds the run lock; this one exits rather than double-launch'
    exit 0
  fi
  trap 'runner_lock_release "$run_dir"' EXIT HUP INT TERM
  runner_state_update "$run_dir" '.supervisor = {pid: $pid, identity: $identity, since: $at} | .status = "running"' \
    --arg pid "$$" --arg identity "$(process_identity $$)" --arg at "$(runner_now)"
  runner_event "$run_dir" supervisor_started '' "pid $$ owns this run"
  runner_projection "$run_dir"

  runner_max_lanes=$(runner_state_read "$run_dir" '.max_lanes')
  case "$runner_max_lanes" in ''|*[!0-9]*|0) runner_max_lanes=4 ;; esac

  for runner_group in $(runner_state_read "$run_dir" '.groups[].id'); do
    runner_group_mode=$(jq -r --arg g "$runner_group" \
      '.groups[] | select(.id == $g) | .mode' "$run_dir/state.json")
    runner_group_limit="$runner_max_lanes"
    [ "$runner_group_mode" != sequential ] || runner_group_limit=1
    runner_inflight=''
    runner_inflight_count=0
    for runner_lane in $(jq -r --arg g "$runner_group" \
        '.groups[] | select(.id == $g) | .lanes[].id' "$run_dir/state.json"); do
      # Bounded scheduling. The limit is the group's own when it is sequential
      # and the run's max_lanes otherwise; either way nothing launches past it.
      while [ "$runner_inflight_count" -ge "$runner_group_limit" ]; do
        runner_await_operations "$runner_inflight"
        runner_drain "$runner_group"
        runner_inflight=$(runner_still_running "$runner_inflight")
        runner_inflight_count=$(printf '%s\n' $runner_inflight | awk 'NF' | wc -l | tr -d ' ')
      done
      runner_lane_json=$(jq -c --arg g "$runner_group" --arg l "$runner_lane" \
        '.groups[] | select(.id == $g) | .lanes[] | select(.id == $l)' "$run_dir/state.json")
      case "$(printf '%s' "$runner_lane_json" | jq -r '.state')" in
        DONE|PARTIAL|BLOCKED) continue ;;
      esac
      runner_reconnected=''
      if runner_reconcile_lane "$runner_group" "$runner_lane" \
           "$(printf '%s' "$runner_lane_json" | jq -r '.operation')"; then
        if [ -n "$runner_reconnected" ]; then
          runner_inflight="$runner_inflight $runner_reconnected"
          runner_inflight_count=$((runner_inflight_count + 1))
        fi
        continue
      fi
      runner_op_cwd=$(printf '%s' "$runner_lane_json" | jq -r '.cwd')
      runner_op_stdin=$(printf '%s' "$runner_lane_json" | jq -r '.stdin')
      runner_op_command=$(printf '%s' "$runner_lane_json" | jq -c '.command')
      runner_attempts=$(printf '%s' "$runner_lane_json" | jq -r '.attempts')
      runner_op_id="op-$runner_lane-$((runner_attempts + 1))"
      runner_state_update "$run_dir" '
        (.groups[] | select(.id == $g) | .lanes[] | select(.id == $l)) |= (
          .state = "RUNNING" | .operation = $op | .attempts = (.attempts + 1)
        ) | .counters.launch_attempts = (.counters.launch_attempts + 1)' \
        --arg g "$runner_group" --arg l "$runner_lane" --arg op "$runner_op_id"
      # The argv comes out of state as a JSON array and is reassembled with
      # shell quoting jq produced, so a brief path with a space in it is one
      # argument rather than two.
      eval "set -- $(printf '%s' "$runner_lane_json" | jq -r '.command | @sh')"
      if runner_launch_operation "$runner_op_id" "$runner_lane" "$runner_group" "$@"; then
        runner_inflight="$runner_inflight $runner_op_id"
        runner_inflight_count=$((runner_inflight_count + 1))
      else
        runner_state_update "$run_dir" \
          '(.groups[] | select(.id == $g) | .lanes[] | select(.id == $l) | .state) = "BLOCKED"' \
          --arg g "$runner_group" --arg l "$runner_lane"
        runner_event "$run_dir" decision_required "$runner_op_id" \
          "lane $runner_lane could not be confirmed launched; reconcile before any relaunch"
      fi
      runner_projection "$run_dir"
    done
    while [ -n "$(printf '%s\n' $runner_inflight | awk 'NF')" ]; do
      runner_await_operations "$runner_inflight"
      runner_drain "$runner_group"
      runner_inflight=$(runner_still_running "$runner_inflight")
    done
    runner_event "$run_dir" group_complete '' "group $runner_group has no running operations left"
    runner_projection "$run_dir"
  done

  runner_settle "$run_dir"
}

# ------------------------------------------------------------------- gates ---

runner_run_gates() {
  # The gate list arrived frozen in the bootstrap and was stored and never run.
  # A run that never executed the checks its own plan named cannot report
  # anything about them, and `complete` was read as though it had.
  #
  # A gate is `{id, command: [argv...], cwd?, required?}`; a bare argv array is
  # the same gate with a generated id, because a plan that lists two commands
  # should not have to invent names for them.
  runner_gate_dir="$1"
  runner_gate_repo=$(runner_state_read "$runner_gate_dir" '.repo')
  runner_gate_count=$(runner_state_read "$runner_gate_dir" '(.gates // []) | length')
  [ "$runner_gate_count" -gt 0 ] || return 0
  # Gates run once. A resume that re-ran them would spend the run's own
  # verification budget on a question already answered, and a flaky gate would
  # decide the run by whichever attempt came last.
  if [ "$(runner_state_read "$runner_gate_dir" '(.gate_results // []) | length')" -gt 0 ]; then
    runner_event "$runner_gate_dir" gates_already_recorded '' \
      'this run already has gate results; they are not re-run on resume'
    return 0
  fi
  mkdir -p "$runner_gate_dir/evidence/gates"
  runner_gate_index=0
  runner_gate_failed=0
  while [ "$runner_gate_index" -lt "$runner_gate_count" ]; do
    runner_gate_json=$(jq -c --argjson i "$runner_gate_index" '
      (.gates[$i]) as $g |
      (if ($g | type) == "array" then {command: $g} else $g end) |
      {id: (.id // ("gate-" + (($i + 1) | tostring))),
       command: (.command // []),
       cwd: (.cwd // ""),
       required: (if .required == false then false else true end)}' "$runner_gate_dir/state.json")
    runner_gate_id=$(printf '%s' "$runner_gate_json" | jq -r '.id')
    runner_gate_required=$(printf '%s' "$runner_gate_json" | jq -r '.required')
    runner_gate_cwd=$(printf '%s' "$runner_gate_json" | jq -r '.cwd')
    [ -n "$runner_gate_cwd" ] || runner_gate_cwd="$runner_gate_repo"
    if [ "$(printf '%s' "$runner_gate_json" | jq -r '.command | length')" -eq 0 ]; then
      runner_die "gate $runner_gate_id carries no command argv"
    fi
    runner_gate_log="$runner_gate_dir/evidence/gates/$runner_gate_id.log"
    eval "set -- $(printf '%s' "$runner_gate_json" | jq -r '.command | @sh')"
    runner_gate_exit=0
    ( cd "$runner_gate_cwd" && "$@" ) > "$runner_gate_log" 2>&1 || runner_gate_exit=$?
    runner_state_update "$runner_gate_dir" '
      .gate_results = ((.gate_results // []) + [{
        id: $id, exit: $exit, required: $required, cwd: $cwd, log: $log, at: $at
      }])' --arg id "$runner_gate_id" --argjson exit "$runner_gate_exit" \
      --argjson required "$runner_gate_required" --arg cwd "$runner_gate_cwd" \
      --arg log "$runner_gate_log" --arg at "$(runner_now)"
    if [ "$runner_gate_exit" -eq 0 ]; then
      runner_event "$runner_gate_dir" gate_passed '' "gate $runner_gate_id exit 0"
    elif [ "$runner_gate_required" = true ]; then
      runner_gate_failed=$((runner_gate_failed + 1))
      runner_event "$runner_gate_dir" gate_failed '' \
        "gate $runner_gate_id exit $runner_gate_exit; evidence in $runner_gate_log"
    else
      runner_event "$runner_gate_dir" gate_failed_advisory '' \
        "gate $runner_gate_id exit $runner_gate_exit (not required); evidence in $runner_gate_log"
    fi
    runner_gate_index=$((runner_gate_index + 1))
  done
  [ "$runner_gate_failed" -eq 0 ] || return 1
  return 0
}

# ------------------------------------------------------- delivery readiness ---

runner_settle() {
  # Process completion is not task readiness, and the shipped runner reported
  # one as the other: it declared `complete` as soon as no lane was pending or
  # running, with the gate list unexecuted, a nonzero lane exit parked in
  # `PARTIAL`, and `audit_attempts: 0` on an audit-eligible batch. Twelve saved
  # field states said `complete` that way.
  #
  # Readiness is decided here, in order, and each step is refused rather than
  # assumed: every lane finished cleanly, then the run's own gates, then the
  # audit receipt an eligible batch requires.
  runner_settle_dir="$1"
  runner_settle_open=$(jq -r '[.groups[].lanes[] | select(.state == "PENDING" or .state == "RUNNING")] | length' "$runner_settle_dir/state.json")
  runner_settle_blocked=$(jq -r '[.groups[].lanes[] | select(.state == "BLOCKED")] | length' "$runner_settle_dir/state.json")
  # A lane whose command exited nonzero is unfinished. `PARTIAL` was a terminal
  # word that still permitted completion, which is how a FOLLOWUP run whose lane
  # exited 1 reported itself finished.
  runner_settle_partial=$(jq -r '[.groups[].lanes[] | select(.state == "PARTIAL")] | length' "$runner_settle_dir/state.json")
  if [ "$runner_settle_blocked" -gt 0 ]; then
    runner_state_update "$runner_settle_dir" '.status = "blocked"'
    runner_event "$runner_settle_dir" run_blocked '' \
      "$runner_settle_blocked lane(s) need a decision before this run can continue"
    runner_projection "$runner_settle_dir"
    return 0
  fi
  if [ "$runner_settle_open" -gt 0 ]; then
    runner_state_update "$runner_settle_dir" '.status = "blocked"'
    runner_event "$runner_settle_dir" run_blocked '' \
      "$runner_settle_open lane(s) are neither done nor blocked; the supervisor stopped without finishing them"
    runner_projection "$runner_settle_dir"
    return 0
  fi
  if [ "$runner_settle_partial" -gt 0 ]; then
    runner_state_update "$runner_settle_dir" '.status = "blocked"'
    runner_event "$runner_settle_dir" run_blocked '' \
      "$runner_settle_partial lane(s) exited nonzero; a PARTIAL lane is unfinished work, not a finished run"
    runner_projection "$runner_settle_dir"
    return 0
  fi
  if ! runner_run_gates "$runner_settle_dir"; then
    runner_state_update "$runner_settle_dir" '.status = "blocked"'
    runner_event "$runner_settle_dir" run_blocked '' \
      'a required gate failed; the run is not deliverable on its own declared checks'
    runner_projection "$runner_settle_dir"
    return 0
  fi
  if [ "$(runner_state_read "$runner_settle_dir" '.audit.eligible')" = yes ] &&
     [ "$(runner_state_read "$runner_settle_dir" '.audit.receipt.verdict // ""')" = '' ]; then
    runner_state_update "$runner_settle_dir" '.status = "awaiting_audit"'
    runner_event "$runner_settle_dir" audit_required '' \
      "this batch is audit-eligible and has no audit receipt: launch the auditor with linchpin.sh role-command auditor, then record it with linchpin.sh audit-receipt $(runner_state_read "$runner_settle_dir" '.run')"
    runner_projection "$runner_settle_dir"
    return 0
  fi
  if [ "$(runner_state_read "$runner_settle_dir" '.audit.receipt.verdict // ""')" = fail ]; then
    runner_state_update "$runner_settle_dir" '.status = "blocked"'
    runner_event "$runner_settle_dir" run_blocked '' 'the recorded audit verdict is fail'
    runner_projection "$runner_settle_dir"
    return 0
  fi
  runner_state_update "$runner_settle_dir" '.status = "complete"'
  runner_event "$runner_settle_dir" run_complete '' \
    'every lane exited clean, every required gate passed, and any required audit is receipted'
  runner_projection "$runner_settle_dir"
}

runner_audit_receipt() {
  # The audit was launched outside the runner in every field batch that had one,
  # so the durable state neither required nor recorded it. A receipt is how the
  # work gets back into the record: it names the session that produced it, so
  # "an auditor ran" is a checkable claim rather than a remembered one.
  runner_receipt_run="$1"
  shift
  runner_repo="$PWD"
  runner_receipt_session=''
  runner_receipt_verdict=''
  runner_receipt_evidence=''
  runner_receipt_extend=no
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) [ "$#" -ge 2 ] || runner_die 'audit-receipt --repo needs a directory'; runner_repo="$2"; shift 2 ;;
      --repo=*) runner_repo="${1#--repo=}"; shift ;;
      --session) [ "$#" -ge 2 ] || runner_die 'audit-receipt --session needs a session id'; runner_receipt_session="$2"; shift 2 ;;
      --session=*) runner_receipt_session="${1#--session=}"; shift ;;
      --verdict) [ "$#" -ge 2 ] || runner_die 'audit-receipt --verdict needs pass or fail'; runner_receipt_verdict="$2"; shift 2 ;;
      --verdict=*) runner_receipt_verdict="${1#--verdict=}"; shift ;;
      --evidence) [ "$#" -ge 2 ] || runner_die 'audit-receipt --evidence needs a path'; runner_receipt_evidence="$2"; shift 2 ;;
      --evidence=*) runner_receipt_evidence="${1#--evidence=}"; shift ;;
      --extend) runner_receipt_extend=yes; shift ;;
      *) runner_die "unknown audit-receipt option: $1" ;;
    esac
  done
  [ -n "$runner_receipt_session" ] ||
    runner_die 'audit-receipt --session ID: an audit nothing can identify is an audit nobody can check'
  case "$runner_receipt_verdict" in
    pass|fail) ;;
    *) runner_die 'audit-receipt --verdict is pass or fail' ;;
  esac
  [ -z "$runner_receipt_evidence" ] || [ -f "$runner_receipt_evidence" ] ||
    runner_die "audit-receipt --evidence names no file: $runner_receipt_evidence"
  runner_run_dir=$(run_dir_for "$runner_repo" "$runner_receipt_run")
  [ -f "$runner_run_dir/state.json" ] ||
    runner_die "no such run: $runner_receipt_run (looked in $runner_run_dir)"
  [ "$(runner_state_read "$runner_run_dir" '.audit.eligible')" = yes ] ||
    runner_die "this run is not audit-eligible, so an audit receipt has nothing to close: $runner_receipt_run"
  # One audit per batch. One FOLLOWUP manager launched three at the same batch;
  # the allowance is the same kind of budget as the lane review cap, and a
  # second one is spent on purpose or not at all.
  runner_receipt_attempts=$(runner_state_read "$runner_run_dir" '.counters.audit_attempts // 0')
  if [ "$runner_receipt_attempts" -ge 1 ] && [ "$runner_receipt_extend" != yes ]; then
    runner_die "this batch has already recorded $runner_receipt_attempts audit(s) (session $(runner_state_read "$runner_run_dir" '.audit.receipt.session // "unknown"')). One audit per batch: pass --extend to say you are deliberately spending another, or read the one you have."
  fi
  runner_state_update "$runner_run_dir" '
    .audit.receipt = {session: $session, verdict: $verdict, evidence: $evidence, at: $at}
    | .audit.receipts = ((.audit.receipts // []) + [{session: $session, verdict: $verdict, at: $at}])
    | .counters.audit_attempts = ((.counters.audit_attempts // 0) + 1)' \
    --arg session "$runner_receipt_session" --arg verdict "$runner_receipt_verdict" \
    --arg evidence "$runner_receipt_evidence" --arg at "$(runner_now)"
  runner_event "$runner_run_dir" audit_recorded '' \
    "session $runner_receipt_session verdict $runner_receipt_verdict"
  runner_settle "$runner_run_dir"
  printf 'AUDIT-RECEIPT-RECORDED run=%s session=%s verdict=%s status=%s\n' \
    "$runner_receipt_run" "$runner_receipt_session" "$runner_receipt_verdict" \
    "$(runner_state_read "$runner_run_dir" '.status')"
}

runner_drain() {
  # Accept the outcome of every operation that is no longer live, once.
  for runner_drain_op in $runner_inflight; do
    [ -n "$runner_drain_op" ] || continue
    runner_operation_live "$runner_drain_op" && continue
    runner_drain_lane=$(jq -r '.lane' "$run_dir/operations/$runner_drain_op/intent.json")
    if runner_drain_exit=$(runner_collect_exit "$runner_drain_op"); then
      runner_record_exit "$1" "$runner_drain_lane" "$runner_drain_op" "$runner_drain_exit"
    elif [ ! -f "$run_dir/operations/$runner_drain_op/exit-receipt.json" ]; then
      runner_state_update "$run_dir" \
        '(.groups[] | select(.id == $g) | .lanes[] | select(.id == $l) | .state) = "BLOCKED"' \
        --arg g "$1" --arg l "$runner_drain_lane"
      runner_event "$run_dir" decision_required "$runner_drain_op" \
        "lane $runner_drain_lane left no exit receipt; its provider session needs reconciling"
    fi
  done
}

# ------------------------------------------------------------ events reader ---

runner_events() {
  runner_run="$1"
  shift
  runner_repo="$PWD"
  runner_after=0
  runner_wait=no
  runner_timeout=60
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) [ "$#" -ge 2 ] || runner_die 'events --repo needs a directory'; runner_repo="$2"; shift 2 ;;
      --repo=*) runner_repo="${1#--repo=}"; shift ;;
      --after) [ "$#" -ge 2 ] || runner_die 'events --after needs a cursor'; runner_after="$2"; shift 2 ;;
      --after=*) runner_after="${1#--after=}"; shift ;;
      --timeout) [ "$#" -ge 2 ] || runner_die 'events --timeout needs seconds'; runner_timeout="$2"; shift 2 ;;
      --timeout=*) runner_timeout="${1#--timeout=}"; shift ;;
      --wait) runner_wait=yes; shift ;;
      *) runner_die "unknown events option: $1" ;;
    esac
  done
  case "$runner_after" in ''|*[!0-9]*) runner_die "events --after is a whole cursor: $runner_after" ;; esac
  case "$runner_timeout" in ''|*[!0-9]*) runner_die "events --timeout is whole seconds: $runner_timeout" ;; esac
  runner_run_dir=$(run_dir_for "$runner_repo" "$runner_run")
  [ -f "$runner_run_dir/state.json" ] || runner_die "no such run: $runner_run (looked in $runner_run_dir)"

  runner_waited=0
  runner_interval="${LINCHPIN_RUNNER_INTERVAL:-5}"
  while :; do
    runner_new=$(jq -c --argjson after "$runner_after" 'select(.cursor > $after)' \
      "$runner_run_dir/events.jsonl" 2>/dev/null || true)
    runner_status=$(runner_state_read "$runner_run_dir" '.status')
    if [ -n "$runner_new" ]; then
      printf '%s\n' "$runner_new"
      printf 'EVENTS-CURSOR run=%s cursor=%s status=%s\n' "$runner_run" \
        "$(printf '%s\n' "$runner_new" | jq -r '.cursor' | tail -1)" "$runner_status"
      return 0
    fi
    case "$runner_status" in
      complete|blocked|awaiting_audit)
        # `awaiting_audit` is terminal for the waiter and not for the run: the
        # supervisor has nothing left to do and the next move is a person's, so
        # blocking here would be a wait on an event that cannot arrive.
        printf 'EVENTS-TERMINAL run=%s status=%s cursor=%s\n' "$runner_run" "$runner_status" "$runner_after"
        return 0
        ;;
    esac
    if [ "$runner_wait" != yes ]; then
      printf 'EVENTS-NONE run=%s cursor=%s status=%s\n' "$runner_run" "$runner_after" "$runner_status"
      return 0
    fi
    if [ "$runner_waited" -ge "$runner_timeout" ]; then
      # A heartbeat, not a question. Nothing here asks a model to decide
      # anything: the run is unchanged and the correct next action is the same
      # call again. Where the host cannot deliver a background notification this
      # is its bounded tool-wait — it is not zero host turns, and claiming
      # otherwise is the one thing this design refuses to say.
      printf 'EVENTS-HEARTBEAT run=%s cursor=%s status=%s running=%s waited=%ss (bounded host wait; nothing to decide, call again)\n' \
        "$runner_run" "$runner_after" "$runner_status" \
        "$(jq -r '[.groups[].lanes[] | select(.state == "RUNNING")] | length' "$runner_run_dir/state.json")" \
        "$runner_waited"
      return 0
    fi
    sleep "$runner_interval"
    runner_waited=$((runner_waited + runner_interval))
  done
}

command -v jq >/dev/null 2>&1 || runner_die 'jq is required by the runner'
runner_command="${1:-}"
[ "$#" -eq 0 ] || shift
case "$runner_command" in
  start) runner_start "$@" ;;
  resume) [ "$#" -ge 1 ] || runner_die 'usage: runner.sh resume RUN_ID [--repo DIR]'; runner_resume "$@" ;;
  supervise) [ "$#" -eq 1 ] || runner_die 'usage: runner.sh supervise RUN_DIR'; runner_supervise "$1" ;;
  events) [ "$#" -ge 1 ] || runner_die 'usage: runner.sh events RUN_ID [--repo DIR] [--after N] [--wait] [--timeout S]'; runner_events "$@" ;;
  audit-receipt)
    [ "$#" -ge 1 ] || runner_die 'usage: runner.sh audit-receipt RUN_ID --session ID --verdict pass|fail [--repo DIR] [--evidence PATH] [--extend]'
    runner_audit_receipt "$@" ;;
  *) runner_die 'usage: runner.sh start|resume|supervise|events|audit-receipt ...' ;;
esac
