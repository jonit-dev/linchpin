#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
contract_reference="$repo_root/references/prd-contract.md"
intake_reference="$repo_root/references/intake.md"
runtime_reference="$repo_root/references/runtime.md"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || die "missing file: $1"
}

absolute_path() {
  # A brief is read from inside a lane worktree, never from the directory the
  # manager typed it in. A repo-relative path resolves to nothing there whenever
  # the PRD is not committed on the lane's base ref, which is the ordinary case
  # for a PRD written in the same sitting as the run that executes it.
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)
      absolute_dir=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd) ||
        die "path does not resolve against an existing directory: $1"
      printf '%s/%s\n' "${absolute_dir%/}" "$(basename -- "$1")"
      ;;
  esac
}

runtime_value() {
  runtime_role="$1"
  runtime_column="$2"
  # Scoped to its own table. runtime.md holds several tables with the same
  # column shape, so an unscoped scan makes every table a lookup source for
  # every other one.
  awk -F '|' -v target="$runtime_role" -v column="$runtime_column" '
    /^## / { in_table = ($0 ~ /^## Role pins/); next }
    !in_table { next }
    {
      role = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", role)
      if (role == target) {
        value = $column
        gsub(/`/, "", value)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  ' "$runtime_reference"
}

models_local_file() {
  # The repo-local alias table. `assign` mints a row here when it verifies a
  # model the shipped table does not list, so a name the user typed is still
  # referred to by alias everywhere downstream. It lives in the target
  # repository, not in the plugin, because the plugin is overwritten on upgrade.
  printf '%s/.linchpin-models.toml\n' "${models_config_dir:-${LINCHPIN_CONFIG_DIR:-$PWD}}"
}

resolve_shipped_alias() {
  # The Model aliases table in runtime.md. Scoped to that one table: the Role
  # pins table has the same column shape, so an unscoped scan would let
  # `worker = "Manager"` resolve to a real model that the alias allowlist was
  # supposed to reject.
  awk -F '|' -v target="$1" '
    /^## / { in_table = ($0 ~ /^## Model aliases/); next }
    !in_table { next }
    {
      name = $2
      gsub(/`/, "", name)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name != target) next
      provider = $3
      slug = $4
      gsub(/`/, "", provider)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", provider)
      gsub(/`/, "", slug)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", slug)
      # A provider cell has no default. A row that lost it must fail to resolve
      # rather than quietly fall back to whichever provider shipped first.
      if (provider != "codex" && provider != "claude") exit
      if (slug !~ /^(gpt-|codex-|claude-)/) exit
      printf "%s\t%s\n", provider, slug
      exit
    }
  ' "$runtime_reference"
}

resolve_local_alias() {
  # `<alias> = "<provider>:<slug>"`, one per line. The key may be quoted: a bare
  # TOML key cannot hold the dot in a name like `opus-4.8`.
  [ -f "$2" ] || return 0
  awk -v target="$1" '
    { sub(/[[:space:]]*#.*$/, "") }
    !/=/ { next }
    {
      key = $0
      sub(/=.*$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^"|"$/, "", key)
      gsub(/^'"'"'|'"'"'$/, "", key)
      if (key != target) next
      value = $0
      sub(/^[^=]*=/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      gsub(/^'"'"'|'"'"'$/, "", value)
      split(value, parts, ":")
      provider = parts[1]
      slug = parts[2]
      if (provider != "codex" && provider != "claude") exit
      if (slug !~ /^(gpt-|codex-|claude-)/) exit
      printf "%s\t%s\n", provider, slug
      exit
    }
  ' "$2"
}

resolve_model() {
  # Prints `provider<TAB>slug`. Empty output means the name has no row, which is
  # a configuration failure rather than a model request to pass along — the same
  # signal the single-provider resolver used, so every caller keeps its refusal.
  # The shipped table is read first and always wins: a repo-local row must not
  # redefine a verified name out from under a run.
  resolve_row=$(resolve_shipped_alias "$1")
  [ -n "$resolve_row" ] || resolve_row=$(resolve_local_alias "$1" "$(models_local_file)")
  [ -z "$resolve_row" ] || printf '%s\n' "$resolve_row"
}

resolve_field() {
  # 1 = provider, 2 = slug, out of a `provider<TAB>slug` row.
  printf '%s\n' "$1" | cut -f"$2"
}

provider_cell() {
  # One cell of the Provider mechanisms table: the row labelled "$1", in the
  # column for provider "$2". This table is the only place the four accepted
  # mechanism strings and the two effort domains are written down.
  awk -F '|' -v label="$1" -v provider="$2" '
    /^## / { in_table = ($0 ~ /^## Provider mechanisms/); next }
    !in_table { next }
    {
      name = $2
      gsub(/`/, "", name)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name != label) next
      column = (provider == "claude") ? 4 : 3
      value = $column
      gsub(/`/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$runtime_reference"
}

effort_domain() {
  provider_cell 'Effort domain' "$1"
}

runtime_mechanisms_valid() {
  # Four cells, one per provider per role, and none of them missing. The check
  # that earns its keep is the one a plausible edit actually produces: a worker
  # mechanism that is really a reviewer's. That reads as a hardening improvement
  # and ends every lane PARTIAL, because a read-only worker cannot commit.
  for mechanism_provider in codex claude; do
    for mechanism_role in Worker Reviewer; do
      [ -n "$(provider_cell "$mechanism_role mechanism" "$mechanism_provider")" ] ||
        die "references/runtime.md Provider mechanisms has no $mechanism_provider $mechanism_role mechanism"
    done
    [ -n "$(effort_domain "$mechanism_provider")" ] ||
      die "references/runtime.md Provider mechanisms has no $mechanism_provider effort domain"
    # The access flag is the whole reason a worker mechanism is not just a
    # launcher name. A codex worker under the default sandbox cannot write the
    # worktree's git metadata and so cannot commit; a claude worker that has to
    # ask before each write cannot run unattended. Both end the lane PARTIAL
    # after the worker time is spent, so a mechanism cell that lost its flag is
    # refused here.
    mechanism_write=$(provider_cell 'Write access' "$mechanism_provider")
    mechanism_read=$(provider_cell 'Read-only access' "$mechanism_provider")
    [ -n "$mechanism_write" ] ||
      die "references/runtime.md Provider mechanisms has no $mechanism_provider write access flag"
    [ -n "$mechanism_read" ] ||
      die "references/runtime.md Provider mechanisms has no $mechanism_provider read-only access flag"
    mechanism_worker=$(provider_cell 'Worker mechanism' "$mechanism_provider")
    case "$mechanism_worker" in
      *"$mechanism_write"*) ;;
      *) die "references/runtime.md $mechanism_provider Worker mechanism does not carry its write access flag ($mechanism_write); that worker cannot commit and every lane ends PARTIAL" ;;
    esac
    case "$mechanism_worker" in
      *"$mechanism_read"*) die "references/runtime.md $mechanism_provider Worker mechanism carries the read-only access flag ($mechanism_read); that worker cannot commit and every lane ends PARTIAL" ;;
    esac
    case "$(provider_cell 'Reviewer mechanism' "$mechanism_provider")" in
      *"$mechanism_read"*) ;;
      *) die "references/runtime.md $mechanism_provider Reviewer mechanism does not carry its read-only access flag ($mechanism_read); a reviewer that can edit what it judges is not a review" ;;
    esac
  done
  for mechanism_provider in codex claude; do
    mechanism_worker=$(provider_cell 'Worker mechanism' "$mechanism_provider")
    for mechanism_other in codex claude; do
      [ "$mechanism_worker" != "$(provider_cell 'Reviewer mechanism' "$mechanism_other")" ] ||
        die "references/runtime.md gives the $mechanism_provider Worker the $mechanism_other Reviewer mechanism; a worker that cannot write ends every lane PARTIAL"
    done
  done
}

role_invocation() {
  # ROLE PROVIDER MECHANISM MODEL EFFORT. The shape is decided by the provider,
  # never by the manager: codex takes its lane with -C and its prompt as an
  # argument, claude takes the lane as its cwd and its prompt on stdin.
  case "$2:$1" in
    codex:worker)
      printf "%s --model %s -c 'model_reasoning_effort=\"%s\"' -C <lane> <brief>\n" "$3" "$4" "$5" ;;
    codex:reviewer)
      printf "codex exec --model %s -c 'model_reasoning_effort=\"%s\"' --sandbox read-only -C <lane> <review>\n" "$4" "$5" ;;
    claude:worker)
      printf '%s --model %s --effort %s --session-id <session> [cwd=<lane>, brief on stdin]\n' "$3" "$4" "$5" ;;
    claude:reviewer)
      printf '%s --model %s --effort %s --session-id <session> [cwd=<lane>, review on stdin]\n' "$3" "$4" "$5" ;;
    *) die "no invocation shape for provider '$2' in role '$1'" ;;
  esac
}

runtime_metadata() {
  require_file "$runtime_reference"
  runtime_mechanisms_valid
  worker_provider=$(runtime_value Worker 3)
  worker_model=$(runtime_value Worker 4)
  worker_effort=$(runtime_value Worker 5)
  worker_mechanism_pin=$(runtime_value Worker 6)
  reviewer_provider=$(runtime_value Reviewer 3)
  reviewer_model=$(runtime_value Reviewer 4)
  reviewer_effort=$(runtime_value Reviewer 5)
  reviewer_mechanism_pin=$(runtime_value Reviewer 6)
  [ -n "$worker_provider" ] || die 'runtime.md has no Worker provider pin'
  [ -n "$reviewer_provider" ] || die 'runtime.md has no Reviewer provider pin'
  # The mechanism a role carries is derived from its provider, not copied by
  # hand. The Role pins cell still has to agree with the provider it names, or
  # the table describes a role nothing can launch. The worker mechanism carries
  # its write access for the reason runtime.md records: under codex's default
  # workspace-write sandbox a worker cannot write the worktree's git metadata,
  # so it cannot commit, and cannot bind the unix socket its own toolchain
  # needs; a claude worker that has to ask before each write cannot run
  # unattended. Both were reproduced.
  [ "$worker_mechanism_pin" = "$(provider_cell 'Worker mechanism' "$worker_provider")" ] ||
    die "runtime.md Worker mechanism is not the $worker_provider Worker mechanism"
  [ "$reviewer_mechanism_pin" = "$(provider_cell 'Reviewer mechanism' "$reviewer_provider")" ] ||
    die "runtime.md Reviewer mechanism is not the $reviewer_provider Reviewer mechanism"
  # A repo-local effort override, declared before the run starts, is the user's
  # call. It is not the forbidden thing: what the delegation rules prohibit is
  # the MANAGER changing tier mid-run to get past a gate that failed. The model
  # itself stays pinned — preflight verifies each resolved role, and
  # substituting one is how a run silently stops being the run that was checked.
  [ -z "${cfg_worker_effort:-}" ] || worker_effort="$cfg_worker_effort"
  [ -z "${cfg_reviewer_effort:-}" ] || reviewer_effort="$cfg_reviewer_effort"
  if [ -n "${cfg_worker_model:-}" ]; then
    runtime_row=$(resolve_model "$cfg_worker_model")
    [ -n "$runtime_row" ] || die "unknown worker alias: $cfg_worker_model (see the Model aliases table in references/runtime.md)"
    worker_provider=$(resolve_field "$runtime_row" 1)
    worker_model=$(resolve_field "$runtime_row" 2)
  fi
  if [ -n "${cfg_reviewer_model:-}" ]; then
    runtime_row=$(resolve_model "$cfg_reviewer_model")
    [ -n "$runtime_row" ] || die "unknown reviewer alias: $cfg_reviewer_model (see the Model aliases table in references/runtime.md)"
    reviewer_provider=$(resolve_field "$runtime_row" 1)
    reviewer_model=$(resolve_field "$runtime_row" 2)
  fi
  [ -n "$worker_model" ] || die 'runtime.md has no Worker model pin'
  [ -n "$worker_effort" ] || die 'runtime.md has no Worker effort pin'
  [ -n "$reviewer_model" ] || die 'runtime.md has no Reviewer model pin'
  [ -n "$reviewer_effort" ] || die 'runtime.md has no Reviewer effort pin'
  worker_mechanism=$(provider_cell 'Worker mechanism' "$worker_provider")
  reviewer_mechanism=$(provider_cell 'Reviewer mechanism' "$reviewer_provider")
  [ -n "$worker_mechanism" ] || die "no Worker mechanism for provider: $worker_provider"
  [ -n "$reviewer_mechanism" ] || die "no Reviewer mechanism for provider: $reviewer_provider"
  worker_runtime="model=$worker_model; effort=$worker_effort; mechanism=$worker_mechanism"
  reviewer_runtime="model=$reviewer_model; effort=$reviewer_effort; mechanism=$reviewer_mechanism"
  worker_invocation=$(role_invocation worker "$worker_provider" "$worker_mechanism" "$worker_model" "$worker_effort")
  reviewer_invocation=$(role_invocation reviewer "$reviewer_provider" "$reviewer_mechanism" "$reviewer_model" "$reviewer_effort")
}

marker_is_valid() {
  # The marker lives in the opening front-matter block. Other front-matter keys
  # are allowed; the exact `prd_contract: v1` line is not optional.
  awk 'NR == 1 && $0 != "---" { exit 1 }
       NR > 1 && $0 == "---" { if (found) ok = 1; exit }
       NR > 1 && $0 == "prd_contract: v1" { found = 1 }
       NR > 50 { exit }
       END { if (!ok) exit 1 }' "$1"
}

section_pattern() {
  # A required heading may carry a leading number and trailing context, but the
  # named section itself is never renamed. `references/prd-contract.md` owns this
  # rule; every reader below builds its regex here so they cannot drift.
  printf '^## ([0-9]+[.] )?%s([[:space:]].*)?$\n' "$1"
}

section_line() {
  # The first argument is a section name, not a regular expression.
  grep -En "$(section_pattern "$1")" "$2" | sed -n '1s/:.*//p'
}

section_block() {
  awk -v name="$2" '
    BEGIN {
      start = "^## ([0-9]+[.] )?" name "([[:space:]].*)?$"
      prefix = "^## ([0-9]+[.] )?" name
    }
    $0 ~ start { active = 1 }
    active && /^## / && $0 !~ prefix { exit }
    active { print }
  ' "$1"
}

files_list() {
  require_file "$1"
  awk '
    function clear_seen(   item) {
      for (item in seen) delete seen[item]
    }
    function finish(   item) {
      if (active && count != expected) bad = 1
      for (item in seen) if (seen[item] > 1) bad = 1
      active = 0
      count = 0
      expected = 0
      clear_seen()
    }
    /^\*\*Files \([0-9][0-9]*\):\*\*$/ {
      if (active) finish()
      header = $0
      sub(/^\*\*Files \(/, "", header)
      sub(/\).*$/, "", header)
      expected = header + 0
      if (expected < 1) bad = 1
      active = 1
      count = 0
      clear_seen()
      next
    }
    active && /^- / {
      entry = $0
      if (entry !~ /^- `[^`]+`[[:space:]]+(- (NEW|EDIT|DELETE):|—[[:space:]]+(NEW|EDIT|DELETE))/) {
        bad = 1
        next
      }
      sub(/^- `/, "", entry)
      sub(/`.*/, "", entry)
      if (entry ~ /^\// || entry ~ /^\.\.\// || entry ~ /[[:space:]]/) bad = 1
      seen[entry]++
      count++
      total++
      print entry
      next
    }
    active && NF == 0 { if (count > 0) finish(); next }
    END {
      if (active) finish()
      if (bad || total == 0) exit 1
    }
  ' "$1"
}

prose_files() {
  # A user's PRD often declares its files in a prose `**Files:**` paragraph
  # instead of a machine-readable `Files (N)` list. The author still named the
  # paths, so read them rather than declaring the whole batch unknowable. This
  # is a derived set: it is announced as advisory and never silently trusted as
  # a conformance result.
  require_file "$1"
  awk '
    /^\*\*Files:\*\*/ { buffer = buffer " " $0; active = 1; next }
    active && NF == 0 { active = 0; next }
    active { buffer = buffer " " $0; next }
    { next }
    END { print buffer }
  ' "$1" |
    tr '`' '\n' |
    awk 'NR % 2 == 0' |
    grep -E '^[A-Za-z0-9_.][A-Za-z0-9_./-]*\.[A-Za-z0-9]+$' |
    sort -u
}

ledger_block() {
  section_block "$1" 'Integration Ledger'
}

negative_block() {
  section_block "$1" 'Negative Controls'
}

acceptance_block() {
  section_block "$1" 'Acceptance Criteria'
}

checkpoint_block() {
  section_block "$1" 'Checkpoint [Pp]rotocol'
}

brief_section() {
  # A user's PRD is executed as written, so a section it never had is reported
  # as absent instead of blocking the lane. Whatever is present is verbatim, and
  # a legacy heading for the same content is transferred under its own name.
  if [ -n "$(section_line "$2" "$1" || true)" ]; then
    section_block "$1" "$2"
  elif [ -n "${3:-}" ] && [ -n "$(section_line "$3" "$1" || true)" ]; then
    printf 'The PRD declares this as `%s`, transferred verbatim:\n\n' "$3"
    section_block "$1" "$3"
  else
    printf 'NOT DECLARED in this PRD. Follow the PRD as written; do not invent a %s section.\n' "$2"
  fi
}

negative_data() {
  negative_block "$1" | awk -F '|' '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    /^\|/ {
      gate = trim($2)
      if (gate != "" && gate != "Gate" && gate !~ /^-+$/) {
        field = (NF == 6 ? trim($5) : "__MALFORMED__")
        print gate "\t" field
      }
    }
  '
}

clean_evidence_field() {
  printf '%s\n' "$1" | sed 's/`//g'
}

command_from_field() {
  clean_field=$(clean_evidence_field "$1")
  # The command may stand alone (plan time) or precede a result/exit triple
  # (delivery evidence). Both forms yield the same comparable command string.
  printf '%s\n' "$clean_field" |
    sed -n 's/^command:[[:space:]]*\([^;][^;]*\).*/\1/p' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

result_from_field() {
  clean_field=$(clean_evidence_field "$1")
  printf '%s\n' "$clean_field" |
    sed -n 's/^command:[[:space:]]*[^;][^;]*;[[:space:]]*result:[[:space:]]*\(.*\);[[:space:]]*exit:[[:space:]]*[0-9][0-9]*$/\1/p' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

exit_from_field() {
  clean_field=$(clean_evidence_field "$1")
  printf '%s\n' "$clean_field" |
    sed -n 's/^command:[[:space:]]*[^;][^;]*;[[:space:]]*result:.*;[[:space:]]*exit:[[:space:]]*\([0-9][0-9]*\)$/\1/p'
}

validate_negative_controls() {
  prd="$1"
  negative_block "$prd" | awk -F '|' '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    /^\|/ {
      gate = trim($2)
      if (gate == "Gate" || gate == "" || gate ~ /^-+$/) next
      rows++
      if (NF != 6 || trim($3) == "" || trim($4) == "" || trim($5) == "") bad = 1
    }
    END { if (rows == 0 || bad) exit 1 }
  ' || die "Negative Controls must have one exact command/result field per gate: $prd"

  negative_rows=$(negative_data "$prd")
  [ -n "$negative_rows" ] || die "Negative Controls has no data rows: $prd"
  duplicate_gate=$(printf '%s\n' "$negative_rows" | cut -f1 | sort | uniq -d)
  [ -z "$duplicate_gate" ] || die "Negative Controls has duplicate gate id: $duplicate_gate"
  while IFS="$(printf '\t')" read -r gate field; do
    [ -n "$gate" ] || continue
    [ "$field" != '__MALFORMED__' ] || die "Negative Controls has a malformed row: $gate"
    expected_command=$(command_from_field "$field")
    expected_result=$(result_from_field "$field")
    expected_exit=$(exit_from_field "$field")
    [ -n "$expected_command" ] || die "Negative Controls has no exact command: $gate"
    # The PRD declares the gate, its control, and the exact command. `RED
    # observed` and the non-zero exit are what a worker observes; `gate` requires
    # them in the report. A PRD that already carries them must still be honest.
    if [ -n "$expected_result" ]; then
      case "$expected_result" in
        *'RED observed:'*) ;;
        *) die "Negative Controls result lacks RED observed marker: $gate" ;;
      esac
    fi
    if [ -n "$expected_exit" ]; then
      case "$expected_exit" in
        0|*[!0-9]*) die "Negative Controls result must declare a non-zero exit: $gate" ;;
      esac
      [ "$expected_exit" -gt 0 ] || die "Negative Controls result must declare a non-zero exit: $gate"
    fi
  done <<EOF
$negative_rows
EOF
}

table_row_count() {
  awk -F '|' '
    /^\|[[:space:]]*[0-9]+[[:space:]]*\|/ { count++ }
    END { print count + 0 }
  ' "$1"
}

negative_row_count() {
  negative_data "$1" | awk 'NF { count++ } END { print count + 0 }'
}

validate_ledger() {
  # A PRD is written before its code exists, so the plan-time contract requires
  # a named non-test caller file, not a line number that cannot exist yet. The
  # `file:line` form is enforced at delivery by `gate`, where it is checkable.
  prd="$1"
  ledger_mode="${2:-plan}"
  rows=$(table_row_count "$prd")
  [ "$rows" -gt 0 ] || die "Integration Ledger has no data rows: $prd"
  ledger_block "$prd" | awk -F '|' -v mode="$ledger_mode" '
    /^\|[[:space:]]*[0-9]+[[:space:]]*\|/ {
      for (i = 1; i <= NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        gsub(/`/, "", $i)
      }
      caller = $4
      if (caller == "" || caller ~ /TBD|pending/) bad = 1
      else if (caller ~ /optional\/unbuilt/) { }
      else if (caller ~ /(^|[[:space:],(\/])(__tests__|tests?|spec|specs)\//) bad = 1
      else if (caller !~ /[A-Za-z0-9_.\/-]+\.[A-Za-z0-9]+/) bad = 1
      else if (mode == "delivered" && caller !~ /:[0-9]+/) bad = 1
      if ($7 == "" || $7 ~ /TBD|pending/) bad = 1
    }
    END { if (bad) exit 1 }
  ' || die "ledger row lacks a real caller or negative control: $prd"
}

problem() {
  printf '%s\n' "$*" >> "$problem_file"
}

collect_problem() {
  # Run a validator that dies on failure and record its message instead of
  # exiting, so one contract run names every gap the author still has to close.
  if ! validator_message=$("$@" 2>&1 >/dev/null); then
    problem "$(printf '%s\n' "$validator_message" | sed 's/^ERROR: //' | sed -n '1p')"
  fi
}

contract_problems() {
  # Callers rely on this reporting every gap at once; it never exits early and
  # never reuses the shared `prd` variable its callers still need.
  contract_prd="$1"
  problem_file=$(mktemp "${TMPDIR:-/tmp}/linchpin-contract.XXXXXX")
  marker_is_valid "$contract_prd" || problem "missing or invalid prd_contract: v1 marker: $contract_prd"

  integration_line=$(section_line 'Integration Ledger' "$contract_prd" || true)
  phases_line=$(section_line 'Execution Phases' "$contract_prd" || true)
  negative_line=$(section_line 'Negative Controls' "$contract_prd" || true)
  acceptance_line=$(section_line 'Acceptance Criteria' "$contract_prd" || true)
  checkpoint_line=$(section_line 'Checkpoint [Pp]rotocol' "$contract_prd" || true)
  [ -n "$integration_line" ] || problem "missing Integration Ledger: $contract_prd"
  [ -n "$phases_line" ] || problem "missing Execution Phases: $contract_prd"
  [ -n "$negative_line" ] || problem "missing Negative Controls: $contract_prd"
  [ -n "$acceptance_line" ] || problem "missing Acceptance Criteria: $contract_prd"
  [ -n "$checkpoint_line" ] || problem "missing Checkpoint Protocol: $contract_prd"

  if [ -n "$integration_line" ] && [ -n "$phases_line" ] && [ -n "$negative_line" ] &&
     [ -n "$acceptance_line" ] && [ -n "$checkpoint_line" ]; then
    if [ "$integration_line" -ge "$phases_line" ] ||
       [ "$phases_line" -ge "$negative_line" ] ||
       [ "$negative_line" -ge "$acceptance_line" ] ||
       [ "$acceptance_line" -ge "$checkpoint_line" ]; then
      problem "required sections are out of order: $contract_prd"
    fi
  fi

  ( files_list "$contract_prd" ) >/dev/null 2>&1 ||
    problem "one or more Files (N) lists are malformed: $contract_prd"
  collect_problem validate_ledger "$contract_prd"
  collect_problem validate_negative_controls "$contract_prd"

  cat "$problem_file"
  problem_count=$(awk 'END { print NR + 0 }' "$problem_file")
  rm -f -- "$problem_file"
  [ "$problem_count" -eq 0 ]
}

contract_check() {
  prd="$1"
  require_file "$prd"
  if ! reported=$(contract_problems "$prd"); then
    printf '%s\n' "$reported" | sed 's/^/ERROR: /' >&2
    exit 1
  fi
  printf 'CONFORMING %s\n' "$prd"
}

migrate_body() {
  # Mechanical legacy -> v1 normalization. It renames the required headings,
  # rewrites prose `**Files:**` paragraphs into parseable `Files (N)` lists, and
  # scaffolds the sections a legacy artifact never had. Anything it cannot
  # convert without inventing content is emitted as a MIGRATION-TODO line so the
  # contract stays red until an author fills it in.
  awk -v has_phases="$1" -v has_acceptance="$2" -v has_negative="$3" -v has_checkpoint="$4" '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    function emit_negative_controls() {
      print "## Negative Controls"
      print ""
      print "<!-- MIGRATION-TODO: one row per gate named in the phases above."
      print "     The fourth column is machine-checked and must read exactly:"
      print "     `command: <cmd>`; result: RED observed: <what broke>; exit: <non-zero> -->"
      print ""
      print "| Gate | Negative control | Expected red | Exact command/result |"
      print "|---|---|---|---|"
      print "| MIGRATION-TODO | MIGRATION-TODO | MIGRATION-TODO | MIGRATION-TODO |"
      print ""
    }
    function emit_checkpoint() {
      print "## Checkpoint Protocol"
      print ""
      print "MIGRATION-TODO: name the automated and manual checks, the evidence"
      print "format, and the condition that blocks delivery. A gate may not be"
      print "declared passed from a green-only run."
      print ""
    }
    function flush_files(   parts, count, i, entry, path, kind, description, lines, total) {
      if (files_buffer == "") return
      total = split(files_buffer, parts, "·")
      count = 0
      lines = ""
      for (i = 1; i <= total; i++) {
        entry = trim(parts[i])
        sub(/[.]$/, "", entry)
        entry = trim(entry)
        if (entry == "") continue
        count++
        path = ""
        if (match(entry, /`[^`]+`/)) {
          path = substr(entry, RSTART + 1, RLENGTH - 2)
        }
        kind = ""
        if (entry ~ /(^|[^A-Za-z])DELETE([^A-Za-z]|$)/) kind = "DELETE"
        else if (entry ~ /(^|[^A-Za-z])NEW([^A-Za-z]|$)/) kind = "NEW"
        else if (entry ~ /(^|[^A-Za-z])EDIT([^A-Za-z]|$)/) kind = "EDIT"
        if (path == "" || kind == "" || path ~ /[[:space:]]/) {
          lines = lines "- MIGRATION-TODO: legacy file entry needs one backtick path and one NEW/EDIT/DELETE kind: " entry "\n"
          continue
        }
        description = entry
        sub(/`[^`]+`/, "", description)
        gsub(/\*\*/, "", description)
        sub(/(^|[^A-Za-z])(NEW|EDIT|DELETE)([^A-Za-z]|$)/, " ", description)
        description = trim(description)
        gsub(/^[(]|[)]$/, "", description)
        description = trim(description)
        if (description == "") description = "migrated from the legacy file list"
        lines = lines "- `" path "` - " kind ": " description "\n"
      }
      if (count > 0) {
        print "**Files (" count "):**"
        print ""
        printf "%s", lines
      }
      files_buffer = ""
      in_files = 0
    }
    in_files {
      if (trim($0) == "") { flush_files(); print ""; next }
      files_buffer = files_buffer " " $0
      next
    }
    /^\*\*Files:\*\*/ {
      files_buffer = $0
      sub(/^\*\*Files:\*\*/, "", files_buffer)
      in_files = 1
      next
    }
    /^## / {
      heading = $0
      body = heading
      sub(/^##[[:space:]]+/, "", body)
      number = ""
      if (match(body, /^[0-9]+[.][[:space:]]+/)) {
        number = substr(body, RSTART, RLENGTH)
        body = substr(body, RSTART + RLENGTH)
      }
      if (!has_phases && body ~ /^Phases([[:space:]]|$)/) {
        print "## " number "Execution Phases"
        next
      }
      if (body ~ /^Acceptance([[:space:]]|$)/ || body ~ /^Acceptance Criteria([[:space:]]|$)/) {
        if (!has_negative && !negative_done) { emit_negative_controls(); negative_done = 1 }
        if (!has_acceptance) { print "## " number "Acceptance Criteria"; next }
      }
      print
      next
    }
    { print }
    END {
      flush_files()
      if (!has_negative && !negative_done) { print ""; emit_negative_controls() }
      if (!has_checkpoint) { print ""; emit_checkpoint() }
    }
  '
}

migrate() {
  [ "$#" -ge 1 ] || die 'usage: linchpin.sh migrate PRD [--out PATH] [--force]'
  prd="$1"
  shift
  migrate_out=
  migrate_force=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) [ "$#" -ge 2 ] || die '--out needs a path'; migrate_out="$2"; shift 2 ;;
      --out=*) migrate_out=${1#*=}; shift ;;
      --force) migrate_force=1; shift ;;
      *) die "unknown migrate option: $1" ;;
    esac
  done
  require_file "$prd"
  if contract_problems "$prd" >/dev/null 2>&1; then
    printf 'ALREADY-CONFORMING %s\n' "$prd"
    return 0
  fi
  [ -n "$migrate_out" ] || migrate_out=$(printf '%s' "$prd" | sed 's/\.md$//').v1.md
  [ "$migrate_out" != "$prd" ] || die 'migrate never writes over the original PRD'
  if [ -e "$migrate_out" ] && [ "$migrate_force" -eq 0 ]; then
    die "migration target already exists: $migrate_out (pass --force to replace it)"
  fi

  migrate_dir=$(mktemp -d "${TMPDIR:-/tmp}/linchpin-migrate.XXXXXX")
  has_phases=0
  has_acceptance=0
  has_negative=0
  has_checkpoint=0
  [ -z "$(section_line 'Execution Phases' "$prd" || true)" ] || has_phases=1
  [ -z "$(section_line 'Acceptance Criteria' "$prd" || true)" ] || has_acceptance=1
  [ -z "$(section_line 'Negative Controls' "$prd" || true)" ] || has_negative=1
  [ -z "$(section_line 'Checkpoint [Pp]rotocol' "$prd" || true)" ] || has_checkpoint=1

  migrate_body "$has_phases" "$has_acceptance" "$has_negative" "$has_checkpoint" \
    < "$prd" > "$migrate_dir/body"
  if [ "$(sed -n '1p' "$migrate_dir/body")" = '---' ]; then
    # Keep an existing front-matter block and add the marker to it.
    awk 'NR == 1 { print; print "prd_contract: v1"; next } { print }' \
      "$migrate_dir/body" > "$migrate_dir/candidate"
  else
    { printf -- '---\nprd_contract: v1\n---\n\n'; cat "$migrate_dir/body"; } > "$migrate_dir/candidate"
  fi

  printf 'ORIGINAL-PRESERVED %s\n' "$prd"
  cp "$migrate_dir/candidate" "$migrate_out"
  if migrate_problems=$(contract_problems "$migrate_out"); then
    rm -rf -- "$migrate_dir"
    printf 'MIGRATED %s -> %s\n' "$prd" "$migrate_out"
    printf '%s\n' 'REVIEW: every converted Files (N) entry is a mechanical rewrite of legacy prose; confirm the paths before scheduling lanes.'
    printf 'NEXT: sh scripts/linchpin.sh route execute %s\n' "$migrate_out"
    return 0
  fi
  # A candidate that still needs an author must not claim conformance.
  cp "$migrate_dir/body" "$migrate_out"
  rm -rf -- "$migrate_dir"
  printf 'MIGRATION-INCOMPLETE %s -> %s\n' "$prd" "$migrate_out"
  printf '%s\n' 'The marker was withheld. Remaining gaps need an author, not a parser:'
  printf '%s\n' "$migrate_problems" | sed 's/^/- /'
  todo_lines=$(grep -n 'MIGRATION-TODO' "$migrate_out" | sed -n '1,20p' || true)
  if [ -n "$todo_lines" ]; then
    printf '%s\n' 'MIGRATION-TODO markers to resolve:'
    printf '%s\n' "$todo_lines" | sed 's/^/- /'
  fi
  printf 'NEXT: fill the gaps above in %s, then rerun: sh scripts/linchpin.sh contract %s\n' \
    "$migrate_out" "$migrate_out"
  return 1
}

require_exact_line() {
  expected_line="$1"
  target_file="$2"
  [ "$(grep -Fxc "$expected_line" "$target_file" || true)" -eq 1 ]
}

block_has_exact_sequence() {
  expected_file="$1"
  target_file="$2"
  awk '
    FNR == NR {
      expected[FNR] = $0
      expected_count = FNR
      next
    }
    {
      if (matched) next
      if ($0 == expected[1]) position = 1
      if (position > 0) {
        if ($0 == expected[position]) {
          position++
          if (position > expected_count) {
            matched = 1
            exit
          }
        } else if ($0 == expected[1]) {
          position = 2
        } else {
          position = 0
        }
      }
    }
    END { if (!matched) exit 1 }
  ' "$expected_file" "$target_file"
}

config_directory() {
  if [ "$#" -gt 0 ] && [ -n "$1" ]; then
    printf '%s\n' "$1"
  elif [ -n "${LINCHPIN_CONFIG_DIR:-}" ]; then
    printf '%s\n' "$LINCHPIN_CONFIG_DIR"
  else
    printf '%s\n' "$PWD"
  fi
}

load_config() {
  config_dir=$(config_directory "${1:-}")
  # `resolve_model` reads the repo-local alias table out of this directory, and
  # it is reached from runtime_metadata as well as from here. Record it once.
  models_config_dir="$config_dir"
  resolved_config=$(config_values "$config_dir")
  while IFS='=' read -r config_key config_value; do
    case "$config_key" in
      execution) execution="$config_value" ;;
      delivery) delivery="$config_value" ;;
      base) base="$config_value" ;;
      review) review="$config_value" ;;
      max_lanes) max_lanes="$config_value" ;;
      prd_floor) prd_floor="$config_value" ;;
      worker) cfg_worker_model="$config_value" ;;
      reviewer) cfg_reviewer_model="$config_value" ;;
      worker_effort) cfg_worker_effort="$config_value" ;;
      reviewer_effort) cfg_reviewer_effort="$config_value" ;;
    esac
  done <<EOF
$resolved_config
EOF
}

brief() {
  [ "$#" -gt 0 ] || die 'usage: linchpin.sh brief PRD [LANE_ID LANE_MODE DELIVERY_MODE] [--config-dir DIR]'
  prd="$1"
  shift
  config_dir="${LINCHPIN_CONFIG_DIR:-$PWD}"
  lane_id="${LINCHPIN_LANE_ID:-lane-1}"
  lane_mode="${LINCHPIN_LANE_MODE:-}"
  delivery_mode="${LINCHPIN_DELIVERY_MODE:-}"
  brief_out=
  positional_count=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config-dir)
        [ "$#" -ge 2 ] || die '--config-dir needs a directory'
        config_dir="$2"
        shift 2
        ;;
      --config-dir=*)
        config_dir=${1#*=}
        shift
        ;;
      --out)
        [ "$#" -ge 2 ] || die '--out needs a path'
        brief_out="$2"
        shift 2
        ;;
      --out=*)
        brief_out=${1#*=}
        shift
        ;;
      --lane-id)
        [ "$#" -ge 2 ] || die '--lane-id needs a value'
        lane_id="$2"
        shift 2
        ;;
      --lane-id=*)
        lane_id=${1#*=}
        shift
        ;;
      --lane-mode)
        [ "$#" -ge 2 ] || die '--lane-mode needs a value'
        lane_mode="$2"
        shift 2
        ;;
      --lane-mode=*)
        lane_mode=${1#*=}
        shift
        ;;
      --delivery-mode)
        [ "$#" -ge 2 ] || die '--delivery-mode needs a value'
        delivery_mode="$2"
        shift 2
        ;;
      --delivery-mode=*)
        delivery_mode=${1#*=}
        shift
        ;;
      --)
        shift
        while [ "$#" -gt 0 ]; do
          positional_count=$((positional_count + 1))
          case "$positional_count" in
            1) lane_id="$1" ;;
            2) lane_mode="$1" ;;
            3) delivery_mode="$1" ;;
            *) die 'brief accepts at most three metadata arguments' ;;
          esac
          shift
        done
        ;;
      *)
        positional_count=$((positional_count + 1))
        case "$positional_count" in
          1) lane_id="$1" ;;
          2) lane_mode="$1" ;;
          3) delivery_mode="$1" ;;
          *) die 'brief accepts at most three metadata arguments' ;;
        esac
        shift
        ;;
    esac
  done
  load_config "$config_dir"
  if [ -z "$lane_mode" ]; then
    case "$execution" in
      sequential) lane_mode=sequential ;;
      auto|parallel) lane_mode=parallel ;;
    esac
  fi
  [ -n "$delivery_mode" ] || delivery_mode="$delivery"
  # An error that names no value cannot be acted on inside a batch loop: the
  # caller cannot tell which lane failed, and abandons the loop for hand-unrolled
  # invocations. Every rejection echoes the offending value.
  [ -n "$lane_id" ] || die "lane identity is empty for $prd; pass LANE_ID as the first metadata argument"
  printf '%s\n' "$lane_id" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$' ||
    die "lane identity is malformed: '$lane_id' (allowed: alphanumeric start, then A-Z a-z 0-9 . _ / -)"
  case "$lane_mode" in parallel|sequential) ;; *) die "lane mode must be parallel or sequential: $lane_mode" ;; esac
  case "$delivery_mode" in pr|branch) ;; *) die "delivery mode must be pr or branch: $delivery_mode" ;; esac
  require_file "$prd"
  prd=$(absolute_path "$prd")
  runtime_metadata
  if [ -n "$brief_out" ]; then
    # A brief the manager has to retype into a prompt is a brief that gets
    # dropped. Write it to a file the worker invocation can read.
    brief_emit "$prd" "$lane_id" "$lane_mode" "$delivery_mode" > "$brief_out"
    printf 'BRIEF-WRITTEN %s\n' "$brief_out"
    return
  fi
  brief_emit "$prd" "$lane_id" "$lane_mode" "$delivery_mode"
}

brief_rules() {
  # One definition, read by both the emitter and the checker. Two copies of a
  # rule string is how the check silently stops matching what ships.
  # A lane worker inherits the same plugin the manager is running, so the word
  # "PRD" in its brief is enough to make it open the linchpin router and re-run
  # intake on the PRD it was already handed. One field run spent a Luna/max turn
  # printing `ROUTE-EXECUTE-CONFORMING` for a decision the manager had already
  # made. Worse, a worker that reaches the coordinator starts scheduling lanes of
  # its own inside a lane.
  rule_prohibited='Prohibited actions: native Luna spawning; runtime tier changes; unsafe external install/swap actions; re-entering linchpin (do not read the linchpin router or coordinator skills, and do not run linchpin.sh route, mode, schedule, or brief — routing already happened and this brief is its result)'
  rule_scope='Scope rule: change only the files this PRD covers. Do not delete, move, or edit an unrelated file, do not bump an unrelated dependency, and do not bundle unrelated work into this lane. Something outside scope that looks wrong is a note in your report, not an edit. This rule bounds WHAT you change; it never forbids committing what you did change.'
  # The Source PRD line resolves outside the lane worktree, and the worker holds
  # `--sandbox danger-full-access`. Naming a path the lane can reach without
  # bounding it trades a PRD the lane cannot read for a PRD the lane can edit
  # under the manager, and a ticked acceptance checkbox in the source tree is
  # exactly the edit a worker reaches for.
  rule_source='Source rule: the Source PRD named above sits outside your lane worktree. Read it — it is the document this brief was cut from and the excerpts here are not a substitute for it — and never write to it. Everything you change belongs inside your own working directory.'
  rule_gate='Gate rule: every negative control this PRD declares needs observed-red evidence before delivery. A control the PRD never declared is not invented here.'
  # Workers told only what to change left the result uncommitted in the working
  # tree, and each of those lanes cost a second worker whose only task was `git
  # commit`. Two things caused it: the requirement lived in the manager's skill
  # and never reached the worker's prompt, and the only sentence containing the
  # word "commit" was a prohibition, which workers read as "do not commit".
  rule_commit='Commit rule: your lane is not done until your work is committed on this lane branch, inside your own working directory. An uncommitted working tree is PARTIAL, not a delivery, however complete the code is. Stage the in-scope files by explicit path (never `git add -A`), commit them, and report the resulting commit sha in your final summary. Do not push, open a PR, merge, rebase, or switch branches; the manager owns delivery.'
  # One PRD in the field declared "Nothing was committed or pushed" as its own
  # acceptance criterion. The worker correctly abstained and was handed a
  # pointless repair round for it. The PRD outranks this default.
  rule_commit_exception='Commit rule exception: if this PRD explicitly requires that nothing be committed or pushed, follow the PRD. Say plainly in your summary that you left the tree uncommitted and quote the criterion that required it. That is a completed lane, not a partial one.'
  rule_environment='Environment rule: your working directory may be a fresh git worktree with no installed dependencies and no editor tooling. Before concluding that a declared gate cannot run, bootstrap what the repository already specifies (its lockfile install, its pinned runtime version) and name the exact command you ran. Report a gate blocked by a sandbox restriction or an unbuilt environment as a setup result, with the exact error, and never as a verification result. If the repository test config excludes the directory you are working in, say so and report the override you used.'
}

brief_emit() {
  prd="$1"
  lane_id="$2"
  lane_mode="$3"
  delivery_mode="$4"
  printf '%s\n' 'WORKER BRIEF: contract-preserving lane'
  printf 'Source PRD: %s\n' "$prd"
  printf 'Lane identity: %s\n' "$lane_id"
  printf '%s\n' 'Files (N) parsed:'
  # `files_list` still prints paths on the way to a non-zero exit, so a non-empty
  # `brief_files` does not mean the set resolved. Record which branch actually
  # ran; anything downstream that asks "was there a file set?" must read this.
  if brief_files=$(files_list "$prd" 2>/dev/null) && [ -n "$brief_files" ]; then
    brief_files_resolved=yes
    printf '%s\n' "$brief_files" | sed 's/^/- /'
  else
    brief_files_resolved=no
    printf '%s\n' '- UNPARSED: this PRD does not use machine-readable `Files (N)` lists.' \
      '- Read the phase file lists in the PRD itself and follow them as written.' \
      '- Its lane is grouped from the paths it names in prose, or alone if it names none.'
    if brief_derived=$(prose_files "$prd" 2>/dev/null) && [ -n "$brief_derived" ]; then
      printf '%s\n' '- Derived from prose (grouping only, not a substitute for the PRD):'
      printf '%s\n' "$brief_derived" | sed 's/^/  - /'
    fi
  fi
  printf '%s\n' '' '## Integration Ledger (verbatim)'
  brief_section "$prd" 'Integration Ledger'
  printf '%s\n' '' '## Negative Controls (verbatim)'
  brief_section "$prd" 'Negative Controls' 'Verification'
  printf '%s\n' '' '## Acceptance Criteria (verbatim)'
  brief_section "$prd" 'Acceptance Criteria' 'Acceptance'
  printf '%s\n' '' '## Checkpoint Protocol (verbatim)'
  brief_section "$prd" 'Checkpoint [Pp]rotocol'
  printf '%s\n' '' '## Resolved Lane Metadata'
  printf 'Worker provider: %s\n' "$worker_provider"
  printf 'Reviewer provider: %s\n' "$reviewer_provider"
  printf 'Worker runtime: %s\n' "$worker_runtime"
  printf 'Reviewer runtime: %s\n' "$reviewer_runtime"
  printf 'Runtime invocation: worker=%s; reviewer=%s\n' "$worker_invocation" "$reviewer_invocation"
  printf 'Lane mode: %s\n' "$lane_mode"
  printf 'Delivery mode: %s\n' "$delivery_mode"
  brief_rules
  printf '%s\n' "$rule_prohibited" "$rule_scope" "$rule_source" "$rule_gate" "$rule_commit" "$rule_commit_exception" "$rule_environment"
  if [ "$brief_files_resolved" = no ]; then
    printf '%s\n' 'File-set rule: this PRD declares no machine-readable file set, so establish your own from the PRD prose before you start and list every path you touched in your final summary. Without a resolved file set there is nothing definite to stage, and lanes in that position have ended with correct work left uncommitted.'
  fi
}

# One review per lane, and at most one more if the manager spends it on purpose.
# Until now that was prose in the coordinator and nothing else. A run that broke
# it launched seven reviewers at a single PRD across nine and a half hours: each
# repair exposed a fresh defect, each fresh defect justified one more round, and
# the files left on disk were named review4, review5, review-final, review-final2,
# review-final3. The ledger recorded `repair_rounds: 1` throughout, so the run
# read from the outside as one review that had not come back yet. A rule that
# only a well-behaved manager obeys is not a rule; the count lives in the ledger
# and the cap is enforced at the one command that can start a reviewer.
review_round_cap=2

review_brief() {
  prd=''
  lane_id=''
  review_config_dir=''
  commit_sha=''
  gates_file=''
  brief_out=''
  ledger_file=''
  round_requested=''
  positional_count=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --gates) [ "$#" -ge 2 ] || die 'review-brief --gates needs a path'; gates_file="$2"; shift 2 ;;
      --commit) [ "$#" -ge 2 ] || die 'review-brief --commit needs a sha'; commit_sha="$2"; shift 2 ;;
      --out) [ "$#" -ge 2 ] || die 'review-brief --out needs a path'; brief_out="$2"; shift 2 ;;
      --ledger) [ "$#" -ge 2 ] || die 'review-brief --ledger needs a path'; ledger_file="$2"; shift 2 ;;
      --ledger=*) ledger_file="${1#--ledger=}"; shift ;;
      --round) [ "$#" -ge 2 ] || die 'review-brief --round needs a number'; round_requested="$2"; shift 2 ;;
      --config-dir) [ "$#" -ge 2 ] || die 'review-brief --config-dir needs a path'; review_config_dir="$2"; shift 2 ;;
      --config-dir=*) review_config_dir="${1#--config-dir=}"; shift ;;
      *)
        positional_count=$((positional_count + 1))
        case "$positional_count" in
          1) prd="$1" ;;
          2) lane_id="$1" ;;
          *) die "review-brief accepts at most two positional arguments: got '$1'" ;;
        esac
        shift
        ;;
    esac
  done
  [ -n "$prd" ] || die 'usage: linchpin.sh review-brief PRD LANE_ID --gates PATH --commit SHA --ledger PATH [--round N] [--out PATH]'
  [ -n "$lane_id" ] || die "lane identity is empty for $prd; pass LANE_ID as the second argument"
  printf '%s\n' "$lane_id" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$' ||
    die "lane identity is malformed: '$lane_id' (allowed: alphanumeric start, then A-Z a-z 0-9 . _ / -)"
  # The reviewer runs read-only and cannot install dependencies or run the
  # repository's gates. A review launched without the manager's gate evidence
  # can only report what it was unable to do, so the evidence is required here
  # rather than left to the manager to remember.
  [ -n "$gates_file" ] ||
    die 'review-brief requires --gates PATH: run the gates yourself and pass the Gate Evidence table, or the read-only reviewer can only report what it could not run'
  require_file "$gates_file"
  # A reviewer cannot review a working tree it cannot see. An uncommitted lane
  # is a worker-contract failure; it is not a question to put to the reviewer.
  [ -n "$commit_sha" ] ||
    die 'review-brief requires --commit SHA: an uncommitted lane is PARTIAL, not reviewable — get the worker commit first'
  require_file "$prd"
  prd=$(absolute_path "$prd")

  # The round cap and the ledger row are the same fact. A reviewer launched
  # without the ledger is the review that goes unrecorded, and an unrecorded
  # review is the one there is always room for another of.
  [ -n "$ledger_file" ] ||
    die 'review-brief requires --ledger PATH: the review count lives in the run ledger, and a review the ledger never saw is the one that repeats'
  require_file "$ledger_file"
  review_tmp=$(mktemp -d "${TMPDIR:-/tmp}/linchpin-review.XXXXXX")
  trap 'rm -rf -- "$review_tmp"' EXIT HUP INT TERM
  run_ledger_block "$ledger_file" "$lane_id" > "$review_tmp/row"
  [ -s "$review_tmp/row" ] ||
    die "run ledger has no row for lane $lane_id: $ledger_file (record the lane with linchpin.sh lane before you review it)"
  round_recorded=$(ledger_value review_rounds "$review_tmp/row")
  [ -n "$round_recorded" ] || round_recorded=0
  printf '%s\n' "$round_recorded" | grep -Eq '^[0-9]+$' ||
    die "ledger review_rounds is not a number for lane $lane_id: $round_recorded"
  round_next=$((round_recorded + 1))
  if [ "$round_next" -gt "$review_round_cap" ]; then
    die "review round $round_next refused: lane $lane_id has already had $round_recorded reviews and the cap is $review_round_cap. A defect that survives $review_round_cap reviews is a specification problem, not a repair problem — record the lane BLOCKED with its reason and resume command, or narrow the PRD and start a new lane. Another round finds another defect; that is what the last $round_recorded did."
  fi
  if [ "$round_next" -gt 1 ] && [ "$round_requested" != "$round_next" ]; then
    die "lane $lane_id already has $round_recorded review(s) recorded, so a further one is not automatic: pass --round $round_next to say you are deliberately spending the last review on this lane"
  fi
  # Record before emitting. A brief that exists against a count that was never
  # incremented is the same unbounded loop with one extra step in it.
  ( lane_record "$ledger_file" "$lane_id" \
      --set review_rounds="$round_next" --set review_used=true >/dev/null ) ||
    die "review-brief could not record round $round_next in $ledger_file: fix the lane row first"

  # The packet names the providers that ran the lane, so it has to resolve the
  # same config the worker brief did.
  load_config "$review_config_dir"
  runtime_metadata

  if [ -n "$brief_out" ]; then
    review_brief_emit "$prd" "$lane_id" "$commit_sha" "$gates_file" > "$brief_out"
    printf 'REVIEW-BRIEF-WRITTEN %s round=%s/%s\n' "$brief_out" "$round_next" "$review_round_cap"
    return
  fi
  review_brief_emit "$prd" "$lane_id" "$commit_sha" "$gates_file"
}

review_brief_emit() {
  prd="$1"
  lane_id="$2"
  commit_sha="$3"
  gates_file="$4"
  printf '%s\n' 'REVIEW BRIEF: read-only lane review'
  printf 'Source PRD: %s\n' "$prd"
  printf 'Lane identity: %s\n' "$lane_id"
  printf 'Lane commit under review: %s\n' "$commit_sha"
  printf 'Worker provider: %s\n' "$worker_provider"
  printf 'Reviewer provider: %s\n' "$reviewer_provider"
  printf '%s\n' '' '## Acceptance Criteria (verbatim)'
  brief_section "$prd" 'Acceptance Criteria' 'Acceptance'
  printf '%s\n' '' '## Negative Controls (verbatim)'
  brief_section "$prd" 'Negative Controls' 'Verification'
  printf '%s\n' '' '## Manager Gate Evidence (already run; treat as established fact)'
  cat "$gates_file"
  printf '%s\n' '' '## Review rules'
  printf '%s\n' 'You are read-only by design. You cannot install dependencies, write files, or run this repository'"'"'s gates. That is the expected condition of this role, not a finding. The gate results above were run by the manager in a writable tree; do not re-derive them and do not report their absence.'
  printf '%s\n' 'Review the committed diff by reading it. The findings that matter here are the ones only a reader can reach: a negative control that stays green when the feature is removed, a field the code accepts and never maps, a document that claims behavior the code contradicts, an acceptance criterion nothing actually satisfies.'
  printf '%s\n' 'Label every finding exactly one of DEFECT or EVIDENCE-GAP. DEFECT: something is wrong in the diff and you can name it with a file:line. EVIDENCE-GAP: the work may be correct but a result you would want was not supplied. Give every DEFECT a file:line and the concrete consequence.'
  printf '%s\n' 'Verdict is APPROVE or REQUEST_CHANGES on the last line as `VERDICT: <value>`. REQUEST_CHANGES requires at least one DEFECT. An EVIDENCE-GAP never blocks delivery on its own; record it and APPROVE.'
  printf '%s\n' 'Facts stated in this brief are context, not findings. Do not treat a fact you were handed as a defect you discovered, and do not open a finding merely to have one. APPROVE with zero findings is a valid and useful review.'
}

brief_check() {
  prd=''
  brief_file=''
  config_dir=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config-dir) [ "$#" -ge 2 ] || die 'brief-check --config-dir needs a path'; config_dir="$2"; shift 2 ;;
      # `brief` accepts the joined form, so `brief-check` must too; otherwise the
      # same flag typed the same way fails on one command and not the other.
      --config-dir=*) config_dir="${1#--config-dir=}"; shift ;;
      --*) die "brief-check does not accept the option: $1" ;;
      *)
        if [ -z "$prd" ]; then prd="$1"
        elif [ -z "$brief_file" ]; then brief_file="$1"
        else die "brief-check accepts at most two positional arguments: got '$1'"
        fi
        shift
        ;;
    esac
  done
  [ -n "$prd" ] && [ -n "$brief_file" ] || die 'usage: linchpin.sh brief-check PRD BRIEF [--config-dir DIR]'
  require_file "$prd"
  require_file "$brief_file"
  # The checker must resolve the same effort overrides the emitter used, or a
  # brief built under a repo-local override fails its own verification.
  load_config "$config_dir"
  runtime_metadata
  metadata_count=$(grep -Ec '^Lane identity:' "$brief_file" || true)
  [ "$metadata_count" -eq 1 ] || die 'worker brief lane identity is missing or duplicated'
  metadata_count=$(grep -Ec '^Lane identity: [A-Za-z0-9][A-Za-z0-9._/-]*$' "$brief_file" || true)
  [ "$metadata_count" -eq 1 ] || die 'worker brief lane identity is malformed'
  metadata_count=$(grep -Ec '^Lane mode:' "$brief_file" || true)
  [ "$metadata_count" -eq 1 ] || die 'worker brief lane mode is missing or duplicated'
  metadata_count=$(grep -Ec '^Lane mode: (parallel|sequential)$' "$brief_file" || true)
  [ "$metadata_count" -eq 1 ] || die 'worker brief lane mode is malformed'
  metadata_count=$(grep -Ec '^Delivery mode:' "$brief_file" || true)
  [ "$metadata_count" -eq 1 ] || die 'worker brief delivery mode is missing or duplicated'
  metadata_count=$(grep -Ec '^Delivery mode: (pr|branch)$' "$brief_file" || true)
  [ "$metadata_count" -eq 1 ] || die 'worker brief delivery mode is malformed'
  for metadata_prefix in 'Worker provider:' 'Reviewer provider:' 'Worker runtime:' 'Reviewer runtime:' 'Runtime invocation:' 'Prohibited actions:' 'Scope rule:' 'Source rule:' 'Commit rule:' 'Commit rule exception:' 'Environment rule:'; do
    metadata_count=$(grep -Fc "$metadata_prefix" "$brief_file" || true)
    [ "$metadata_count" -eq 1 ] || die "worker brief metadata is missing or duplicated: $metadata_prefix"
  done
  require_exact_line "Worker provider: $worker_provider" "$brief_file" || die 'worker brief Worker provider metadata is missing or stale'
  require_exact_line "Reviewer provider: $reviewer_provider" "$brief_file" || die 'worker brief Reviewer provider metadata is missing or stale'
  require_exact_line "Worker runtime: $worker_runtime" "$brief_file" || die 'worker brief Worker runtime metadata is missing or stale'
  require_exact_line "Reviewer runtime: $reviewer_runtime" "$brief_file" || die 'worker brief Reviewer runtime metadata is missing or stale'
  require_exact_line "Runtime invocation: worker=$worker_invocation; reviewer=$reviewer_invocation" "$brief_file" || die 'worker brief runtime invocation is missing or stale'
  brief_rules
  require_exact_line "$rule_prohibited" "$brief_file" || die 'worker brief prohibited-actions metadata is missing or malformed'
  require_exact_line "$rule_scope" "$brief_file" || die 'worker brief scope rule is missing or malformed'
  require_exact_line "$rule_source" "$brief_file" || die 'worker brief source rule is missing or malformed'
  require_exact_line "$rule_gate" "$brief_file" || die 'worker brief gate rule is missing or malformed'
  require_exact_line "$rule_commit" "$brief_file" || die 'worker brief commit rule is missing or malformed'
  require_exact_line "$rule_commit_exception" "$brief_file" || die 'worker brief commit-rule exception is missing or malformed'
  require_exact_line "$rule_environment" "$brief_file" || die 'worker brief environment rule is missing or malformed'

  brief_temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/linchpin-brief-check.XXXXXX")
  trap 'rm -rf -- "$brief_temp_dir"' EXIT HUP INT TERM
  brief_section "$prd" 'Integration Ledger' > "$brief_temp_dir/ledger"
  brief_section "$prd" 'Negative Controls' 'Verification' > "$brief_temp_dir/negative"
  brief_section "$prd" 'Acceptance Criteria' 'Acceptance' > "$brief_temp_dir/acceptance"
  brief_section "$prd" 'Checkpoint [Pp]rotocol' > "$brief_temp_dir/checkpoint"
  for block_name in ledger negative acceptance checkpoint; do
    block_has_exact_sequence "$brief_temp_dir/$block_name" "$brief_file" || die "worker brief omitted or changed the verbatim $block_name block"
  done
  printf 'BRIEF-PASS metadata and verbatim contract blocks transferred\n'
}

config_values() {
  config_dir=$(config_directory "${1:-}")
  models_config_dir="$config_dir"
  config_file="$config_dir/.linchpin.toml"
  execution=auto
  delivery=pr
  base=auto
  review=true
  max_lanes=4
  prd_floor=3
  # Empty means "use the pin in runtime.md" — the zero-config default.
  worker_effort_override=
  reviewer_effort_override=
  worker_override=
  reviewer_override=
  if [ -f "$config_file" ]; then
    while IFS= read -r raw || [ -n "$raw" ]; do
      line=$(printf '%s' "$raw" | sed 's/[[:space:]]*#.*$//')
      key=$(printf '%s' "$line" | sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z_0-9]*\)[[:space:]]*=.*/\1/p')
      if [ -z "$key" ]; then
        [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ] && continue
        die "malformed .linchpin.toml line: $raw"
      fi
      value=$(printf '%s' "$line" | sed -n 's/^[^=]*=[[:space:]]*//p' | sed 's/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')
      case "$key" in
        execution) execution="$value" ;;
        delivery) delivery="$value" ;;
        base) base="$value" ;;
        review) review="$value" ;;
        max_lanes) max_lanes="$value" ;;
        prd_floor) prd_floor="$value" ;;
        worker) worker_override="$value" ;;
        reviewer) reviewer_override="$value" ;;
        worker_effort) worker_effort_override="$value" ;;
        reviewer_effort) reviewer_effort_override="$value" ;;
        *) die "unknown .linchpin.toml key: $key" ;;
      esac
    done < "$config_file"
  fi
  case "$execution" in auto|parallel|sequential) ;; *) die "invalid execution: $execution" ;; esac
  case "$delivery" in pr|branch) ;; *) die "invalid delivery: $delivery" ;; esac
  case "$base" in
    ''|*[!A-Za-z0-9._/-]*) die "base must be auto or a branch name: $base" ;;
  esac
  case "$review" in true|false) ;; *) die "review must be true or false" ;; esac
  case "$max_lanes" in *[!0-9]*|0|"") die "max_lanes must be a positive integer" ;; esac
  case "$prd_floor" in *[!0-9]*|"") die "prd_floor must be a non-negative integer" ;; esac
  # Validate the alias against the table that actually resolves it, so adding a
  # model to runtime.md is one edit rather than two that can disagree. The
  # effort domain then belongs to the provider that alias names, not to
  # linchpin: codex has no `xhigh` and Claude Code does, so one shared list
  # either rejects a word Claude accepts or passes one codex rejects once per
  # lane, after the run is already underway.
  for role_pair in "worker=$worker_override" "reviewer=$reviewer_override"; do
    role_name=${role_pair%%=*}
    role_alias=${role_pair#*=}
    case "$role_name" in
      worker) role_pin=Worker; role_effort="$worker_effort_override" ;;
      *) role_pin=Reviewer; role_effort="$reviewer_effort_override" ;;
    esac
    if [ -n "$role_alias" ]; then
      role_row=$(resolve_model "$role_alias")
      [ -n "$role_row" ] ||
        die "$role_name must be an alias in the Model aliases table in references/runtime.md: $role_alias"
      role_provider=$(resolve_field "$role_row" 1)
    else
      role_provider=$(runtime_value "$role_pin" 3)
      [ -n "$role_provider" ] ||
        die "references/runtime.md has no $role_pin provider pin"
    fi
    [ -n "$role_effort" ] || continue
    role_domain=$(effort_domain "$role_provider")
    [ -n "$role_domain" ] ||
      die "references/runtime.md declares no effort domain for provider: $role_provider"
    role_effort_ok=no
    for domain_word in $role_domain; do
      if [ "$domain_word" = "$role_effort" ]; then role_effort_ok=yes; fi
    done
    [ "$role_effort_ok" = yes ] ||
      die "${role_name}_effort must be one of: $role_domain (the $role_provider effort domain): $role_effort"
  done
  printf 'execution=%s\ndelivery=%s\nbase=%s\nreview=%s\nmax_lanes=%s\nprd_floor=%s\nworker=%s\nreviewer=%s\nworker_effort=%s\nreviewer_effort=%s\n' \
    "$execution" "$delivery" "$base" "$review" "$max_lanes" "$prd_floor" \
    "$worker_override" "$reviewer_override" \
    "$worker_effort_override" "$reviewer_effort_override"
}

execute_intent='run|execute|start|begin|launch|resume|continue|kick off'

route_announce_assignment() {
  # A role word alone is not an assignment: "run the reviewer on PRD-007" names
  # no model and no effort. Announce only when something actually resolves — an
  # effort word, or a term that already has an alias row — so the advisory never
  # points a manager at `assign` for a sentence assign would refuse.
  models_config_dir="$2"
  route_assignment=no
  # A tab is IFS white space: `read` would collapse an empty effort field and
  # shift the candidate list into it. The separator has to be one nothing in a
  # role, alias, effort, provider, or slug can contain.
  while IFS='|' read -r route_role route_effort route_candidates; do
    [ -n "$route_role" ] || continue
    if [ -n "$route_effort" ]; then route_assignment=yes; fi
    for route_candidate in $route_candidates; do
      if [ -n "$(assign_lookup "$route_candidate")" ]; then route_assignment=yes; fi
    done
  done <<ROUTE_ASSIGN_EOF
$(assign_parse "$1")
ROUTE_ASSIGN_EOF
  [ "$route_assignment" = yes ] || return 0
  printf '%s\n' 'ROUTE-ASSIGN-MODELS -> assign --write (run it before the execution route; it never replaces one)'
}

route() {
  intent=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  [ -n "$intent" ] || die 'route needs an intent'
  shift
  score=
  if printf '%s' "$intent" | grep -Eq 'build|implement'; then
    score="${1:-}"
    [ "$#" -gt 0 ] && shift
  elif printf '%s' "$intent" | grep -Eq "$execute_intent" &&
       [ "$#" -gt 0 ] && printf '%s' "$1" | grep -Eq '^[0-9]+$'; then
    # Keep compatibility with the old helper shape while allowing the
    # documented execute form: route execute PRD [PRD ...].
    score="$1"
    shift
  fi
  config_dir="${LINCHPIN_CONFIG_DIR:-$PWD}"
  prd_list=$(mktemp "${TMPDIR:-/tmp}/linchpin-route.XXXXXX")
  trap 'rm -f -- "$prd_list"' EXIT HUP INT TERM
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config-dir)
        [ "$#" -ge 2 ] || die '--config-dir needs a directory'
        config_dir="$2"
        shift 2
        ;;
      --config-dir=*)
        config_dir=${1#*=}
        shift
        ;;
      *)
        printf '%s\n' "$1" >> "$prd_list"
        shift
        ;;
    esac
  done
  load_config "$config_dir"
  # Assignment is not a route. It runs first, changes two config keys, and then
  # the request takes whichever route it was always going to take: "use Astra as
  # reviewer and run PRD-007" is an execute intent. Announcing it here is what
  # keeps a manager from noticing the assignment by reading, or not at all.
  route_announce_assignment "$intent" "$config_dir"
  if printf '%s' "$intent" | grep -Eq '(writ(e|ing)|draft(ing)?|author(ing)?|creat(e|ing))([[:space:]]+[a-z]+){0,3}[[:space:]]+prd'; then
    printf '%s\n' 'ROUTE-WRITE-PRD -> prd-creator'
    return
  fi
  if printf '%s' "$intent" | grep -Eq 'build|implement'; then
    case "$score" in ''|*[!0-9]*) die 'build intent requires a numeric complexity score' ;; esac
    built_in_floor=3
    floor="$prd_floor"
    [ "$floor" -ge "$built_in_floor" ] || floor="$built_in_floor"
    if [ "$score" -lt "$floor" ]; then
      printf '%s\n' 'ROUTE-BUILD-SMALL -> direct-edit-refusal'
    else
      printf '%s\n' 'ROUTE-BUILD-LARGE -> prd-creator-confirm'
    fi
    return
  fi
  if printf '%s' "$intent" | grep -Eq "$execute_intent"; then
    count=$(wc -l < "$prd_list" | tr -d ' ')
    if [ "$count" -eq 0 ]; then
      printf '%s\n' 'ROUTE-EXECUTE-NONE -> ask-once'
      return
    fi
    # A PRD the user points at is executed as written. The contract is a creator
    # standard for artifacts Linchpin authors, never an admission gate on the
    # user's own document. The only execution blocker is a path that is not there
    # — and it blocks that one path, not the batch beside it.
    found_list=$(mktemp "${TMPDIR:-/tmp}/linchpin-route-found.XXXXXX")
    missing=0
    while IFS= read -r prd; do
      [ -n "$prd" ] || continue
      if [ -d "$prd" ]; then
        # A directory in an execute argv is a target-repository hint, not a PRD.
        printf 'ADVISORY %s is a directory, not a PRD; read as the target repository.\n' "$prd"
        continue
      fi
      if [ -f "$prd" ]; then
        printf '%s\n' "$prd" >> "$found_list"
      else
        printf 'MISSING-PRD-PATH %s (resolved from %s)\n' "$prd" "$PWD"
        missing=1
      fi
    done < "$prd_list"
    found_count=$(wc -l < "$found_list" | tr -d ' ')
    if [ "$found_count" -eq 0 ]; then
      rm -f -- "$found_list"
      printf '%s\n' 'ROUTE-EXECUTE-NONE -> ask-once'
      return
    fi
    printf '%s\n' 'ROUTE-EXECUTE-CONFORMING -> prd-swarm-coordinator'
    if [ "$missing" -eq 1 ]; then
      printf '%s\n' 'ADVISORY route the paths above that exist; ask once about the missing one instead of stopping the batch.'
    fi
    while IFS= read -r prd; do
      [ -n "$prd" ] || continue
      if ! sh "$script_dir/linchpin.sh" contract "$prd" >/dev/null 2>&1; then
        printf 'ADVISORY %s does not carry prd_contract: v1; execute it as written. Do not rewrite it, and do not migrate it unless the user asks.\n' "$prd"
      fi
    done < "$found_list"
    rm -f -- "$found_list"
    return
  fi
  printf '%s\n' 'ROUTE-AMBIGUOUS -> ask-once'
}

mode_selection() {
  requested_execution="$1"
  shift
  case "$requested_execution" in auto|parallel|sequential) ;; *) die "invalid execution: $requested_execution" ;; esac
  config_dir="${LINCHPIN_CONFIG_DIR:-$PWD}"
  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/linchpin-mode.XXXXXX")
  trap 'rm -rf -- "$temp_dir"' EXIT HUP INT TERM
  : > "$temp_dir/prds"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config-dir)
        [ "$#" -ge 2 ] || die '--config-dir needs a directory'
        config_dir="$2"
        shift 2
        ;;
      --config-dir=*)
        config_dir=${1#*=}
        shift
        ;;
      *)
        printf '%s\n' "$1" >> "$temp_dir/prds"
        shift
        ;;
    esac
  done
  count=$(wc -l < "$temp_dir/prds" | tr -d ' ')
  [ "$count" -gt 0 ] || die 'mode selection needs at least one PRD'
  load_config "$config_dir"
  if [ "$requested_execution" != auto ]; then
    execution="$requested_execution"
  fi
  index=1
  unparsed_any=0
  while IFS= read -r prd; do
    require_file "$prd"
    if files_list "$prd" 2>/dev/null | sort -u > "$temp_dir/files-$index" &&
       [ -s "$temp_dir/files-$index" ]; then
      printf '0\n' > "$temp_dir/unparsed-$index"
    elif prose_files "$prd" > "$temp_dir/files-$index" 2>/dev/null &&
         [ -s "$temp_dir/files-$index" ]; then
      # The author named the paths in prose instead of a `Files (N)` list. Read
      # them for grouping only; the file on disk is never rewritten.
      printf '0\n' > "$temp_dir/unparsed-$index"
      printf 'ANNOUNCE: %s has no machine-readable Files (N) list; its file set was derived from its prose **Files:** paragraphs for grouping only.\n' "$prd"
    else
      # No declared file set at all. The lane cannot be proved disjoint from
      # anything, so it takes its own group instead of dragging every other
      # lane into one queue behind it.
      : > "$temp_dir/files-$index"
      printf '1\n' > "$temp_dir/unparsed-$index"
      unparsed_any=1
      printf 'ANNOUNCE: %s declares no file set; its lane runs alone in its own group and its isolation is unproven.\n' "$prd"
    fi
    printf '%s\n' "$prd" > "$temp_dir/label-$index"
    index=$((index + 1))
  done < "$temp_dir/prds"

  : > "$temp_dir/edges"
  i=1
  while [ "$i" -le "$count" ]; do
    j=$((i + 1))
    while [ "$j" -le "$count" ]; do
      if comm -12 "$temp_dir/files-$i" "$temp_dir/files-$j" | grep -q .; then
        printf '%s %s\n' "$i" "$j" >> "$temp_dir/edges"
      fi
      j=$((j + 1))
    done
    i=$((i + 1))
  done

  if [ "$execution" = parallel ] && [ -s "$temp_dir/edges" ]; then
    die 'execution=parallel forced parallelism but Files (N) lists intersect'
  fi
  if [ "$execution" = parallel ] && [ "$unparsed_any" -eq 1 ]; then
    die 'execution=parallel forced parallelism but a PRD declares no file set, so disjointness cannot be proved'
  fi

  awk -v n="$count" '
    BEGIN { for (i = 1; i <= n; i++) parent[i] = i }
    function root(x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]]
        x = parent[x]
      }
      return x
    }
    { left = root($1); right = root($2); if (left != right) parent[right] = left }
    END { for (i = 1; i <= n; i++) print i, root(i) }
  ' "$temp_dir/edges" > "$temp_dir/groups"
  if [ ! -s "$temp_dir/edges" ]; then
    awk -v n="$count" 'BEGIN { for (i = 1; i <= n; i++) print i, i }' > "$temp_dir/groups"
  fi

  roots=$(awk '{ print $2 }' "$temp_dir/groups" | sort -nu)
  active_count=0
  if [ "$execution" = sequential ]; then
    concurrency_limit=1
  else
    concurrency_limit="$max_lanes"
  fi
  for root in $roots; do
    member_count=$(awk -v root="$root" '$2 == root { count++ } END { print count + 0 }' "$temp_dir/groups")
    case "$execution" in
      sequential) selected=sequential ;;
      parallel) selected=parallel ;;
      auto) if [ "$member_count" -gt 1 ]; then selected=sequential; else selected=parallel; fi ;;
    esac
    lanes=
    active_lanes=
    queued_lanes=
    group_active_count=0
    if [ "$selected" = sequential ]; then
      group_limit=1
    else
      group_limit="$member_count"
    fi
    for member in $(awk -v root="$root" '$2 == root { print $1 }' "$temp_dir/groups" | sort -n); do
      label=$(sed -n '1p' "$temp_dir/label-$member")
      if [ -n "$lanes" ]; then lanes="$lanes,$label"; else lanes="$label"; fi
      if [ "$active_count" -lt "$concurrency_limit" ] && [ "$group_active_count" -lt "$group_limit" ]; then
        if [ -n "$active_lanes" ]; then active_lanes="$active_lanes,$label"; else active_lanes="$label"; fi
        active_count=$((active_count + 1))
        group_active_count=$((group_active_count + 1))
      else
        if [ -n "$queued_lanes" ]; then queued_lanes="$queued_lanes,$label"; else queued_lanes="$label"; fi
      fi
    done
    [ -n "$active_lanes" ] || active_lanes=-
    [ -n "$queued_lanes" ] || queued_lanes=-
    printf 'group=%s mode=%s lanes=%s active=%s queued=%s\n' "$root" "$selected" "$lanes" "$active_lanes" "$queued_lanes"
  done
}

schedule() {
  requested_execution="$1"
  worktree_status="$2"
  shift 2
  case "$requested_execution" in auto|parallel|sequential) ;; *) die "invalid execution: $requested_execution" ;; esac
  # The announced reason must be the reason that actually happened. `fail` stays
  # for the worktree case it has always meant; the named statuses cover the other
  # degradations without claiming a `git worktree add` that was never attempted.
  case "$worktree_status" in
    ok) ;;
    fail|worktree-fail) fallback_reason='git worktree add failed' ;;
    dirty-tree) fallback_reason='the working tree could not be safely stashed' ;;
    unparsed-files) fallback_reason='the lane group declares no separable file set' ;;
    config) fallback_reason='execution = "sequential" was configured' ;;
    *) die 'worktree status must be ok, worktree-fail, dirty-tree, unparsed-files, or config' ;;
  esac
  config_dir="${LINCHPIN_CONFIG_DIR:-$PWD}"
  lane_file=$(mktemp "${TMPDIR:-/tmp}/linchpin-schedule.XXXXXX")
  trap 'rm -f -- "$lane_file"' EXIT HUP INT TERM
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config-dir)
        [ "$#" -ge 2 ] || die '--config-dir needs a directory'
        config_dir="$2"
        shift 2
        ;;
      --config-dir=*)
        config_dir=${1#*=}
        shift
        ;;
      *)
        printf '%s\n' "$1" >> "$lane_file"
        shift
        ;;
    esac
  done
  lane_count=$(wc -l < "$lane_file" | tr -d ' ')
  [ "$lane_count" -gt 0 ] || die 'schedule needs at least one lane'
  load_config "$config_dir"
  forced_parallel=0
  if [ "$requested_execution" = auto ]; then
    selected="$execution"
    [ "$execution" = parallel ] && forced_parallel=1
    [ "$execution" = auto ] && selected=parallel
  else
    selected="$requested_execution"
    [ "$requested_execution" = parallel ] && forced_parallel=1
  fi
  if [ "$worktree_status" != ok ]; then
    if [ "$forced_parallel" -eq 1 ]; then
      die "execution=parallel forced worktrees, but $fallback_reason"
    fi
    printf 'ANNOUNCE: %s; this lane group runs sequentially in the shared working tree.\n' "$fallback_reason"
    selected=sequential
  elif [ "$selected" = sequential ]; then
    printf '%s\n' 'ANNOUNCE: sequential execution was selected by configuration or collision analysis.'
  fi
  if [ "$selected" = sequential ]; then
    concurrency_limit=1
  else
    concurrency_limit="$max_lanes"
  fi
  lanes=
  active_lanes=
  queued_lanes=
  active_count=0
  while IFS= read -r lane; do
    if [ -n "$lanes" ]; then lanes="$lanes,$lane"; else lanes="$lane"; fi
    if [ "$active_count" -lt "$concurrency_limit" ]; then
      if [ -n "$active_lanes" ]; then active_lanes="$active_lanes,$lane"; else active_lanes="$lane"; fi
      active_count=$((active_count + 1))
    else
      if [ -n "$queued_lanes" ]; then queued_lanes="$queued_lanes,$lane"; else queued_lanes="$lane"; fi
    fi
  done < "$lane_file"
  [ -n "$active_lanes" ] || active_lanes=-
  [ -n "$queued_lanes" ] || queued_lanes=-
  printf 'group=1 mode=%s lanes=%s active=%s queued=%s\n' "$selected" "$lanes" "$active_lanes" "$queued_lanes"
}

gate_evidence() {
  prd="$1"
  report="$2"
  require_file "$prd"
  # The contract governs artifacts Linchpin authored. A user's own PRD is
  # executed as written, so conformance is never an admission gate on delivery.
  # What a PRD declares is still binding; what it never declared is not.
  if marker_is_valid "$prd"; then
    contract_check "$prd" >/dev/null
    require_file "$report"
    # Delivery is the point where the planned caller must have become a real one.
    validate_ledger "$prd" delivered
  else
    require_file "$report"
  fi
  expected_rows=$(negative_data "$prd")
  if [ -z "$expected_rows" ] && ! marker_is_valid "$prd"; then
    printf 'GATES-NOT-DECLARED %s declares no Negative Controls; deliver on the verification it does declare\n' "$prd"
    return 0
  fi
  actual_rows=$(awk -F '|' '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    /^## Gate Evidence[[:space:]]*$/ { active = 1; next }
    active && /^## / { exit }
    active && /^\|/ {
      gate = trim($2)
      if (gate != "" && gate != "Gate" && gate !~ /^-+$/) {
        result = (NF >= 3 ? trim($3) : "")
        evidence = (NF >= 4 ? trim($4) : "")
        exact = (NF == 6 ? trim($5) : "__MALFORMED__")
        print gate "\t" result "\t" evidence "\t" exact
      }
    }
  ' "$report")
  [ -n "$expected_rows" ] || die 'PRD has no expected gate identifiers'
  [ -n "$actual_rows" ] || die 'gate evidence is absent, green-only, or malformed'
  expected=$(printf '%s\n' "$expected_rows" | awk 'NF { count++ } END { print count + 0 }')
  actual=$(printf '%s\n' "$actual_rows" | awk 'NF { count++ } END { print count + 0 }')
  [ "$actual" -eq "$expected" ] || die "gate evidence count $actual does not match negative-control count $expected"
  expected_ids=$(printf '%s\n' "$expected_rows" | cut -f1 | sort)
  actual_ids=$(printf '%s\n' "$actual_rows" | cut -f1 | sort)
  duplicate_gate=$(printf '%s\n' "$actual_ids" | uniq -d)
  [ -z "$duplicate_gate" ] || die "gate evidence has duplicate gate id: $duplicate_gate"
  [ "$actual_ids" = "$expected_ids" ] || die 'gate evidence gate identifiers do not exactly match the PRD'
  while IFS="$(printf '\t')" read -r gate result evidence actual_field; do
    [ -n "$gate" ] || continue
    expected_field=$(printf '%s\n' "$expected_rows" | awk -F '\t' -v target="$gate" '$1 == target { print $2; exit }')
    expected_command=$(command_from_field "$expected_field")
    actual_command=$(command_from_field "$actual_field")
    actual_result=$(result_from_field "$actual_field")
    actual_exit=$(exit_from_field "$actual_field")
    [ "$result" = PASS ] || die "gate evidence result is not PASS: $gate"
    case "$evidence" in
      *'RED observed:'*) ;;
      *) die "gate evidence lacks an observed-red marker: $gate" ;;
    esac
    [ -n "$actual_command" ] || die "gate evidence lacks exact command/result field: $gate"
    [ "$actual_command" = "$expected_command" ] || die "gate evidence command does not match PRD: $gate"
    case "$actual_result" in
      *'RED observed:'*) ;;
      *) die "gate evidence result lacks observed-red evidence: $gate" ;;
    esac
    case "$actual_exit" in
      ''|0|*[!0-9]*) die "gate evidence exit is not non-zero: $gate" ;;
    esac
    [ "$actual_exit" -gt 0 ] || die "gate evidence exit is not non-zero: $gate"
  done <<EOF
$actual_rows
EOF
  printf 'GATES-PASS %s controls with exact observed-red evidence\n' "$actual"
}

assign_normalize() {
  # Case-folded, with spaces and dots turned into hyphens, so "Opus 5",
  # "opus-5" and "OPUS 5" are one term — and so is "Opus 4.8" against the
  # `opus-4.8` row, because the alias name is normalized the same way.
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ' .' '--' |
    sed 's/--*/-/g; s/^-//; s/-$//'
}

assign_scan_shipped() {
  awk -F '|' -v target="$1" '
    function norm(v) {
      v = tolower(v)
      gsub(/[ .]/, "-", v)
      gsub(/--+/, "-", v)
      sub(/^-/, "", v)
      sub(/-$/, "", v)
      return v
    }
    /^## / { in_table = ($0 ~ /^## Model aliases/); next }
    !in_table { next }
    {
      name = $2; provider = $3; slug = $4
      gsub(/`/, "", name); gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      gsub(/`/, "", provider); gsub(/^[[:space:]]+|[[:space:]]+$/, "", provider)
      gsub(/`/, "", slug); gsub(/^[[:space:]]+|[[:space:]]+$/, "", slug)
      if (name == "" || slug == "") next
      if (provider != "codex" && provider != "claude") next
      if (norm(name) != target && norm(slug) != target) next
      printf "%s\t%s\t%s\n", name, provider, slug
      exit
    }
  ' "$runtime_reference"
}

assign_scan_local() {
  [ -f "$2" ] || return 0
  awk -v target="$1" '
    function norm(v) {
      v = tolower(v)
      gsub(/[ .]/, "-", v)
      gsub(/--+/, "-", v)
      sub(/^-/, "", v)
      sub(/-$/, "", v)
      return v
    }
    { sub(/[[:space:]]*#.*$/, "") }
    !/=/ { next }
    {
      key = $0; sub(/=.*$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^"|"$/, "", key)
      value = $0; sub(/^[^=]*=/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      split(value, parts, ":")
      provider = parts[1]; slug = parts[2]
      if (provider != "codex" && provider != "claude") next
      if (slug !~ /^(gpt-|codex-|claude-)/) next
      if (norm(key) != target && norm(slug) != target) next
      printf "%s\t%s\t%s\n", key, provider, slug
      exit
    }
  ' "$2"
}

assign_lookup() {
  # A normalized term against every alias table, shipped first. Prints
  # `alias<TAB>provider<TAB>slug`; empty output means no row matched.
  assign_row=$(assign_scan_shipped "$1")
  [ -n "$assign_row" ] || assign_row=$(assign_scan_local "$1" "$(models_local_file)")
  [ -z "$assign_row" ] || printf '%s\n' "$assign_row"
}

assign_model_shaped() {
  # A term worth spending a live verification on. A bare English word is not a
  # model name, and probing one costs a request to learn nothing.
  case "$1" in
    gpt-*|codex-*|claude-*|o[0-9]*) return 0 ;;
  esac
  if printf '%s' "$1" | grep -Eq '[0-9]'; then
    return 0
  fi
  return 1
}

assign_verify_live() {
  # A name in no alias table is a normal request, not an error. Infer the
  # provider from the name's shape, verify it the way that provider is verified
  # — cache lookup for codex, one probe for claude — and print
  # `provider<TAB>slug` only if it actually came back. Never a guess, never a
  # fallback model.
  assign_term="$1"
  case "$assign_term" in
    claude-*) assign_providers='claude' ;;
    gpt-*|codex-*) assign_providers='codex' ;;
    *) assign_providers='codex claude' ;;
  esac
  for assign_provider in $assign_providers; do
    case "$assign_provider" in
      codex)
        assign_cache="${LINCHPIN_MODELS_CACHE:-${CODEX_HOME:-$HOME/.codex}/models_cache.json}"
        [ -f "$assign_cache" ] || continue
        command -v jq >/dev/null 2>&1 || continue
        if jq -e --arg model "$assign_term" \
          '[.. | objects | select(.slug? == $model)] | length > 0' "$assign_cache" >/dev/null 2>&1; then
          printf 'codex\t%s\n' "$assign_term"
          return 0
        fi
        ;;
      claude)
        assign_claude="${LINCHPIN_CLAUDE_BIN:-claude}"
        command -v "$assign_claude" >/dev/null 2>&1 || continue
        assign_probe=$("$assign_claude" -p --model "$assign_term" --effort low --max-turns 1 \
          'Reply with the single word ok.' < /dev/null 2>/dev/null) || continue
        if [ -n "$assign_probe" ]; then
          printf 'claude\t%s\n' "$assign_term"
          return 0
        fi
        ;;
    esac
  done
  return 1
}

assign_parse() {
  # One line per role named in the text: `role<TAB>effort<TAB>candidate ...`.
  # Candidates are normalized n-grams from the words beside the role word,
  # longest and nearest first, so "Opus 5 medium as executor" offers `opus-5`
  # before `opus`.
  printf '%s\n' "$1" | awk '
    function norm(v) {
      v = tolower(v)
      gsub(/[ .]/, "-", v)
      gsub(/--+/, "-", v)
      sub(/^-/, "", v)
      sub(/-$/, "", v)
      return v
    }
    function rolename(w) {
      if (w == "executor" || w == "worker" || w == "implementer" || w == "builder") return "worker"
      if (w == "reviewer" || w == "review" || w == "reviewers" || w == "critic") return "reviewer"
      return ""
    }
    function iseffort(w) {
      return (w == "low" || w == "medium" || w == "high" || w == "xhigh" || w == "max")
    }
    function isstop(w) {
      return (w == "as" || w == "the" || w == "a" || w == "an" || w == "and" || w == "with" ||
              w == "use" || w == "using" || w == "run" || w == "set" || w == "to" || w == "for" ||
              w == "on" || w == "at" || w == "in" || w == "by" || w == "of" || w == "model" ||
              w == "models" || w == "please" || w == "linchpin" || w == "effort" || w == "be" ||
              w == "make" || w == "put" || w == "is" || w == "my" || w == "our" || w == "then")
    }
    function emit_ngrams(lo, hi, filtered,   len, start, j, term, ok) {
      for (len = 3; len >= 1; len--) {
        for (start = hi - len + 1; start >= lo; start--) {
          if (start < lo || start + len - 1 > hi) continue
          ok = 1
          term = ""
          for (j = start; j < start + len; j++) {
            if (iseffort(tok[j]) || isstop(tok[j]) || tok[j] == "") { ok = 0; break }
            term = (term == "") ? tok[j] : term "-" tok[j]
          }
          if (!ok) continue
          term = norm(term)
          if (term == "") continue
          # A term an earlier role already took is offered to this one only
          # after every fresh term is exhausted. "Sonnet 5 high as reviewer and
          # terra high as the executor" puts both models between the two role
          # words, and without this the second role claims the earlier model.
          if (filtered && (term in claimed)) continue
          if (term in line_seen) continue
          line_seen[term] = 1
          if (filtered) claimed[term] = 1
          out = (out == "") ? term : out " " term
        }
      }
    }
    {
      line = tolower($0)
      gsub(/[,;:"'"'"'()\[\]!?]/, " ", line)
      n = split(line, raw, /[[:space:]]+/)
      count = 0
      for (i = 1; i <= n; i++) {
        w = raw[i]
        gsub(/^[^a-z0-9]+|[^a-z0-9]+$/, "", w)
        if (w == "") continue
        tok[++count] = w
      }
      k = 0
      for (i = 1; i <= count; i++) if (rolename(tok[i]) != "") pos[++k] = i
      for (r = 1; r <= k; r++) {
        p = pos[r]
        lo = (r == 1) ? 1 : pos[r - 1] + 1
        hi = (r == k) ? count : pos[r + 1] - 1
        effort = ""
        for (i = p - 1; i >= lo; i--) if (iseffort(tok[i])) { effort = tok[i]; break }
        if (effort == "") for (i = p + 1; i <= hi; i++) if (iseffort(tok[i])) { effort = tok[i]; break }
        delete line_seen
        out = ""
        emit_ngrams(lo, p - 1, 1)
        emit_ngrams(p + 1, hi, 1)
        emit_ngrams(lo, p - 1, 0)
        emit_ngrams(p + 1, hi, 0)
        printf "%s|%s|%s\n", rolename(tok[p]), effort, out
      }
    }
  '
}

assign_apply_config() {
  # Rewrite only the keys this assignment set, keeping every other key, comment,
  # and blank line, and creating the file when it is absent.
  assign_config_file="$1"
  assign_pairs_file="$2"
  [ -f "$assign_config_file" ] || : > "$assign_config_file"
  assign_config_tmp="$assign_config_file.linchpin-assign"
  awk -v pairsfile="$assign_pairs_file" '
    BEGIN {
      order_count = 0
      while ((getline pair < pairsfile) > 0) {
        if (pair == "") continue
        pkey = pair; sub(/=.*$/, "", pkey)
        pval = pair; sub(/^[^=]*=/, "", pval)
        want[pkey] = pval
        order[++order_count] = pkey
      }
    }
    {
      stripped = $0
      sub(/[[:space:]]*#.*$/, "", stripped)
      key = ""
      if (match(stripped, /^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*[[:space:]]*=/)) {
        key = substr(stripped, RSTART, RLENGTH)
        sub(/[[:space:]]*=$/, "", key)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      }
      if (key != "" && (key in want)) {
        printf "%s = \"%s\"\n", key, want[key]
        seen[key] = 1
        next
      }
      print
    }
    END {
      for (i = 1; i <= order_count; i++) {
        k = order[i]
        if (!(k in seen)) { printf "%s = \"%s\"\n", k, want[k]; seen[k] = 1 }
      }
    }
  ' "$assign_config_file" > "$assign_config_tmp" &&
    mv "$assign_config_tmp" "$assign_config_file"
}

assign() {
  # `references/intake.md:150` promised that natural-language overrides are
  # written to `.linchpin.toml` before scheduling, and nothing implemented it:
  # the manager was left to improvise the mapping from "Astra medium as
  # reviewer" to two config keys. An improvised mapping is the one thing this
  # repository does not accept anywhere else, so the mapping is a command.
  assign_text=''
  assign_config_dir=''
  assign_do_write=no
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config-dir) [ "$#" -ge 2 ] || die 'assign --config-dir needs a path'; assign_config_dir="$2"; shift 2 ;;
      --config-dir=*) assign_config_dir="${1#--config-dir=}"; shift ;;
      --write) assign_do_write=yes; shift ;;
      --*) die "assign does not accept the option: $1" ;;
      *)
        [ -z "$assign_text" ] || die "assign accepts one quoted sentence: got '$1'"
        assign_text="$1"
        shift
        ;;
    esac
  done
  [ -n "$assign_text" ] || die 'usage: linchpin.sh assign "<text>" [--config-dir DIR] [--write]'
  assign_config_dir=$(config_directory "$assign_config_dir")
  [ -d "$assign_config_dir" ] || die "assign --config-dir is not a directory: $assign_config_dir"
  models_config_dir="$assign_config_dir"

  assign_tmp=$(mktemp -d "${TMPDIR:-/tmp}/linchpin-assign.XXXXXX")
  trap 'rm -rf -- "$assign_tmp"' EXIT HUP INT TERM
  assign_parse "$assign_text" > "$assign_tmp/roles"

  : > "$assign_tmp/resolved"
  while IFS='|' read -r assign_role assign_effort assign_candidates; do
    [ -n "$assign_role" ] || continue
    grep -q "^$assign_role|" "$assign_tmp/resolved" 2>/dev/null && continue
    assign_alias=''
    assign_provider=''
    assign_slug=''
    for assign_candidate in $assign_candidates; do
      assign_hit=$(assign_lookup "$assign_candidate")
      if [ -n "$assign_hit" ]; then
        assign_alias=$(printf '%s\n' "$assign_hit" | cut -f1)
        assign_provider=$(printf '%s\n' "$assign_hit" | cut -f2)
        assign_slug=$(printf '%s\n' "$assign_hit" | cut -f3)
        break
      fi
    done
    if [ -z "$assign_alias" ]; then
      # Nothing in a table matched. A model-shaped term still gets verified
      # live, and only a term that verifies on neither provider is refused.
      for assign_candidate in $assign_candidates; do
        if assign_model_shaped "$assign_candidate"; then
          if assign_live=$(assign_verify_live "$assign_candidate"); then
            assign_alias="$assign_candidate"
            assign_provider=$(printf '%s\n' "$assign_live" | cut -f1)
            assign_slug=$(printf '%s\n' "$assign_live" | cut -f2)
            printf '%s = "%s:%s"\n' "$assign_alias" "$assign_provider" "$assign_slug" \
              >> "$assign_config_dir/.linchpin-models.toml"
            printf 'ASSIGN-ALIAS-MINTED %s = "%s:%s" %s\n' \
              "$assign_alias" "$assign_provider" "$assign_slug" \
              "$assign_config_dir/.linchpin-models.toml"
            break
          fi
          printf 'ASSIGN-UNRESOLVED %s\n' "$assign_candidate" >&2
          die "no provider verified the model term '$assign_candidate' for the $assign_role role; name a model that exists rather than accepting a substitute"
        fi
      done
    fi
    [ -n "$assign_alias" ] || [ -n "$assign_effort" ] || continue
    printf '%s|%s|%s|%s|%s\n' \
      "$assign_role" "$assign_alias" "$assign_effort" "$assign_provider" "$assign_slug" \
      >> "$assign_tmp/resolved"
  done < "$assign_tmp/roles"

  if [ ! -s "$assign_tmp/resolved" ]; then
    # Text naming no assignment is not an error: a caller runs `assign` on every
    # request so the conversational and file paths converge, and most requests
    # assign nothing.
    printf 'ASSIGN-NONE no role assignment in the supplied text\n'
    return 0
  fi

  # What the run resolves to today, so a role the text only re-efforts still
  # reports the provider and model it will actually use.
  load_config "$assign_config_dir"
  runtime_metadata
  models_config_dir="$assign_config_dir"

  : > "$assign_tmp/pairs"
  while IFS='|' read -r assign_role assign_alias assign_effort assign_provider assign_slug; do
    [ -n "$assign_role" ] || continue
    case "$assign_role" in
      worker) assign_current_alias="${cfg_worker_model:-}"; assign_current_effort="$worker_effort"
              assign_current_provider="$worker_provider"; assign_current_slug="$worker_model" ;;
      *) assign_current_alias="${cfg_reviewer_model:-}"; assign_current_effort="$reviewer_effort"
         assign_current_provider="$reviewer_provider"; assign_current_slug="$reviewer_model" ;;
    esac
    if [ -z "$assign_alias" ]; then
      assign_alias="$assign_current_alias"
      assign_provider="$assign_current_provider"
      assign_slug="$assign_current_slug"
    fi
    [ -n "$assign_effort" ] || assign_effort="$assign_current_effort"
    assign_domain=$(effort_domain "$assign_provider")
    assign_effort_ok=no
    for assign_word in $assign_domain; do
      if [ "$assign_word" = "$assign_effort" ]; then assign_effort_ok=yes; fi
    done
    [ "$assign_effort_ok" = yes ] ||
      die "$assign_role effort '$assign_effort' is outside the $assign_provider effort domain ($assign_domain)"
    printf 'ASSIGN role=%s alias=%s effort=%s provider=%s model=%s\n' \
      "$assign_role" "$assign_alias" "$assign_effort" "$assign_provider" "$assign_slug"
    [ -z "$assign_alias" ] || printf '%s=%s\n' "$assign_role" "$assign_alias" >> "$assign_tmp/pairs"
    printf '%s_effort=%s\n' "$assign_role" "$assign_effort" >> "$assign_tmp/pairs"
  done < "$assign_tmp/resolved"

  if [ "$assign_do_write" = yes ]; then
    assign_apply_config "$assign_config_dir/.linchpin.toml" "$assign_tmp/pairs"
    printf 'ASSIGN-WRITTEN %s\n' "$assign_config_dir/.linchpin.toml"
    # The file has to survive the validation every other command applies to it.
    config_values "$assign_config_dir" >/dev/null
  fi
}

preflight_model() {
  # The configured roles may not be the shipped pins, so resolve config before
  # deciding what to verify. Verifying the default while the run uses another
  # model is a preflight that proves nothing. A malformed config must fail here
  # rather than be swallowed: preflight exists to refuse before any branch is
  # created, and a PASS naming a model the config never asked for is worse than
  # no preflight at all. An ABSENT config is the zero-config default, not an
  # error.
  load_config "${LINCHPIN_CONFIG_DIR:-$PWD}"
  runtime_metadata
  # Every role that will actually run gets checked, not just the worker. A
  # reviewer model that cannot be verified fails at the first lane's review,
  # after the run has already spent its worker time.
  preflight_worker_verified=''
  preflight_reviewer_verified=''

  if [ "$worker_provider" = codex ] || [ "$reviewer_provider" = codex ]; then
    cache_path="${1:-${LINCHPIN_MODELS_CACHE:-}}"
    if [ -z "$cache_path" ]; then
      codex_home="${CODEX_HOME:-${HOME:?HOME is required for model preflight}/.codex}"
      cache_path="$codex_home/models_cache.json"
    fi
    require_file "$cache_path"
    command -v jq >/dev/null 2>&1 || die 'jq is required for codex model preflight'
    # Every `codex exec` child writes its own session state under CODEX_HOME
    # before the model is ever contacted. When the manager itself runs under a
    # sandbox that leaves CODEX_HOME read-only, the child dies with `failed to
    # initialize in-process app-server client: Read-only file system` — and the
    # run discovers it at the *reviewer*, after every lane has already been
    # built and committed. That run ended "committed but review-gated" with no
    # review at all. A directory write test costs nothing and moves the
    # discovery here.
    preflight_home=$(dirname -- "$cache_path")
    preflight_probe="$preflight_home/.linchpin-preflight-write"
    if ! (: > "$preflight_probe") 2>/dev/null; then
      die "CODEX_HOME is not writable: $preflight_home — every codex exec worker and reviewer fails at app-server init before the model starts; run linchpin from a session that can write it, or set CODEX_HOME to a writable directory"
    fi
    rm -f "$preflight_probe"
  fi

  for preflight_role in worker reviewer; do
    case "$preflight_role" in
      worker) preflight_provider="$worker_provider"; preflight_slug="$worker_model" ;;
      *) preflight_provider="$reviewer_provider"; preflight_slug="$reviewer_model" ;;
    esac
    case "$preflight_provider" in
      codex)
        jq -e --arg model "$preflight_slug" '
          [.. | objects | select(.slug? == $model)] | length > 0
        ' "$cache_path" >/dev/null || die "model missing from $cache_path: $preflight_slug"
        # A model that declares no multi-agent capability is not one this plugin
        # knows how to drive. Absent is a refusal; the specific version is not.
        jq -e --arg model "$preflight_slug" '
          [.. | objects | select(.slug? == $model) | select(.multi_agent_version? != null)] | length > 0
        ' "$cache_path" >/dev/null || die "model declares no multi_agent_version in $cache_path: $preflight_slug"
        # Luna speaks v1 while native spawning speaks v2, so it must never be
        # started through a native subagent. Linchpin always uses `codex exec`,
        # and `scripts/verify.sh` greps the skills for `agent_type`/`fork_turns`
        # to keep it that way; this records which model carries the constraint.
        preflight_multi_agent=$(jq -r --arg model "$preflight_slug" '
          [.. | objects | select(.slug? == $model) | .multi_agent_version?] | map(select(. != null)) | first // "unknown"
        ' "$cache_path")
        preflight_verified="cache=$cache_path,multi_agent=$preflight_multi_agent"
        ;;
      claude)
        # Claude Code ships no capability cache, so there is nothing to read.
        # One live trivial request per distinct slug is the only honest check,
        # and a session that cannot reach the API fails here rather than
        # discovering it at the first lane. There is no fallback model.
        preflight_claude="${LINCHPIN_CLAUDE_BIN:-claude}"
        command -v "$preflight_claude" >/dev/null 2>&1 ||
          die "claude role requires the Claude Code CLI on PATH: $preflight_claude (set LINCHPIN_CLAUDE_BIN to point at it)"
        if [ "$preflight_slug" = "${preflight_probed_slug:-}" ]; then
          preflight_verified="probed"
        else
          preflight_out=$("$preflight_claude" -p --model "$preflight_slug" --effort low --max-turns 1 \
            'Reply with the single word ok.' < /dev/null 2>/dev/null) ||
            die "claude model probe failed: $preflight_slug — preflight refuses the run rather than falling back to another model"
          [ -n "$preflight_out" ] ||
            die "claude model probe returned no output: $preflight_slug — preflight refuses the run rather than falling back to another model"
          preflight_probed_slug="$preflight_slug"
          preflight_verified="probed"
        fi
        ;;
      *) die "unknown provider for $preflight_role: $preflight_provider" ;;
    esac
    case "$preflight_role" in
      worker) preflight_worker_verified="$preflight_verified" ;;
      *) preflight_reviewer_verified="$preflight_verified" ;;
    esac
  done

  printf 'PREFLIGHT-PASS worker[provider=%s model=%s mechanism=%s verified=%s] reviewer[provider=%s model=%s mechanism=%s verified=%s]\n' \
    "$worker_provider" "$worker_model" "$worker_mechanism" "$preflight_worker_verified" \
    "$reviewer_provider" "$reviewer_model" "$reviewer_mechanism" "$preflight_reviewer_verified"
}

workspace_ignore_one() {
  # `git check-ignore` is the only honest test: a repo that already ignores the
  # path through any mechanism needs no second entry.
  workspace_path="$1"
  if git -C "$workspace_repo" check-ignore -q "$workspace_path" 2>/dev/null; then
    printf 'WORKSPACE-ALREADY-IGNORED %s\n' "$workspace_path"
    return
  fi
  # `.git/info/exclude`, not `.gitignore`. Ignoring our own scratch output must
  # not itself show up as a modified tracked file in the user's `git status`,
  # and must not ride along in a lane commit.
  workspace_exclude="$workspace_git_dir/info/exclude"
  mkdir -p "$workspace_git_dir/info"
  [ -f "$workspace_exclude" ] || : > "$workspace_exclude"
  if [ -s "$workspace_exclude" ] && [ "$(tail -c 1 "$workspace_exclude" | od -An -c | tr -d ' \n')" != '\n' ]; then
    printf '\n' >> "$workspace_exclude"
  fi
  printf '%s\n' "$workspace_path" >> "$workspace_exclude"
  printf 'WORKSPACE-IGNORED %s .git/info/exclude\n' "$workspace_path"
}

workspace() {
  workspace_repo="${1:-${LINCHPIN_CONFIG_DIR:-$PWD}}"
  [ -d "$workspace_repo" ] || die "workspace target is not a directory: $workspace_repo"
  command -v git >/dev/null 2>&1 || die 'git is required to prepare a linchpin workspace'
  git -C "$workspace_repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "workspace target is not a Git repository: $workspace_repo"
  # The COMMON git dir, not the per-worktree one. Inside a linked worktree
  # `--absolute-git-dir` resolves to `.git/worktrees/<name>`, whose `info/exclude`
  # git never reads — the entry would be written to a file with no effect, which
  # is worse than not writing it. Linchpin runs lanes in worktrees, so this is
  # the common case, not the edge case.
  workspace_git_dir=$(git -C "$workspace_repo" rev-parse --git-common-dir)
  case "$workspace_git_dir" in
    /*) ;;
    # Older git returns this relative to the working directory.
    *) workspace_git_dir=$(CDPATH= cd -- "$workspace_repo/$workspace_git_dir" && pwd) ;;
  esac
  # Claim the ignore entries BEFORE the first write. A run directory that
  # appears in `git status` is leftover the user has to clean up by hand.
  workspace_ignore_one '.linchpin/'
  workspace_ignore_one '.worktrees/'
  mkdir -p "$workspace_repo/.linchpin"
  printf 'WORKSPACE-READY %s\n' "$workspace_repo/.linchpin"
}

lane_worktree() {
  # Linchpin used to describe lane isolation and leave the mechanism to the
  # manager. Managers filled the gap with whatever worktree helper the user
  # happened to have installed. One of those helpers ran `git pull` in the
  # source tree on the way to creating the worktree, left an unresolved merge
  # in twenty modified files the user had not committed, and the run spent its
  # first minutes on `git merge --abort` instead of on the PRD. Lane isolation
  # is linchpin's job, so linchpin ships the command.
  worktree_repo=''
  worktree_slug=''
  worktree_base=''
  worktree_path=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --path) [ "$#" -ge 2 ] || die 'worktree --path needs a directory'; worktree_path="$2"; shift 2 ;;
      --*) die "unknown worktree option: $1" ;;
      *)
        if [ -z "$worktree_repo" ]; then worktree_repo="$1"
        elif [ -z "$worktree_slug" ]; then worktree_slug="$1"
        elif [ -z "$worktree_base" ]; then worktree_base="$1"
        else die "unexpected worktree argument: $1"
        fi
        shift ;;
    esac
  done
  [ -n "$worktree_repo" ] && [ -n "$worktree_slug" ] && [ -n "$worktree_base" ] ||
    die 'usage: linchpin.sh worktree REPO LANE_SLUG BASE_REF [--path DIR]'
  printf '%s\n' "$worktree_slug" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' ||
    die "lane slug is malformed: '$worktree_slug' (allowed: alphanumeric start, then A-Z a-z 0-9 . _ -)"
  command -v git >/dev/null 2>&1 || die 'git is required to create a lane worktree'
  [ -d "$worktree_repo" ] || die "worktree target is not a directory: $worktree_repo"
  git -C "$worktree_repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "worktree target is not a Git repository: $worktree_repo"

  # Refuse to build a lane from inside another lane. A manager that had already
  # moved into a worktree created the next lane relative to *that* directory and
  # produced `.worktrees/<lane-a>/.worktrees/<lane-b>`, branched off lane A
  # rather than off the base. Both nesting and lane-from-lane branching are
  # forbidden by the coordinator; this is where they are actually prevented.
  if [ "$(git -C "$worktree_repo" rev-parse --is-inside-work-tree 2>/dev/null)" = 'true' ] &&
     [ "$(git -C "$worktree_repo" rev-parse --git-dir)" != "$(git -C "$worktree_repo" rev-parse --git-common-dir)" ]; then
    printf 'WORKTREE-FAIL nested %s is itself a linked worktree; create lanes from the main worktree\n' "$worktree_repo" >&2
    exit 1
  fi

  worktree_branch="linchpin/$worktree_slug"
  if git -C "$worktree_repo" show-ref --verify --quiet "refs/heads/$worktree_branch"; then
    printf 'WORKTREE-FAIL branch-exists %s already exists; resume it or pick another lane slug\n' "$worktree_branch" >&2
    exit 1
  fi

  # Branch from the remote base after a fetch. A local base that sits ahead of
  # its remote carries the user's unrelated committed work into every lane, and
  # delivery then merges that work under a PR title that never mentions it.
  # `git fetch` is safe in a dirty tree; `git pull` is not, and is never run.
  worktree_resolved="$worktree_base"
  if git -C "$worktree_repo" remote get-url origin >/dev/null 2>&1; then
    git -C "$worktree_repo" fetch --quiet origin "$worktree_base" 2>/dev/null || true
    if git -C "$worktree_repo" rev-parse --verify --quiet "origin/$worktree_base" >/dev/null; then
      worktree_resolved="origin/$worktree_base"
    fi
  fi
  if ! git -C "$worktree_repo" rev-parse --verify --quiet "$worktree_resolved" >/dev/null; then
    printf 'WORKTREE-FAIL missing-base %s does not resolve in %s\n' "$worktree_resolved" "$worktree_repo" >&2
    exit 1
  fi
  worktree_base_sha=$(git -C "$worktree_repo" rev-parse "$worktree_resolved")

  [ -n "$worktree_path" ] || worktree_path="$worktree_repo/.worktrees/$worktree_slug"
  if [ -e "$worktree_path" ]; then
    printf 'WORKTREE-FAIL path-exists %s\n' "$worktree_path" >&2
    exit 1
  fi

  # The failure text is the announcement the user reads, so it carries git's own
  # reason rather than a summary of it. `schedule auto worktree-fail` is only
  # honest when the attempt actually happened.
  if ! worktree_error=$(git -C "$worktree_repo" worktree add -b "$worktree_branch" "$worktree_path" "$worktree_resolved" 2>&1); then
    printf 'WORKTREE-FAIL add %s\n' "$(printf '%s' "$worktree_error" | tr '\n' ' ')" >&2
    exit 1
  fi
  printf 'WORKTREE-READY path=%s branch=%s base=%s sha=%s\n' \
    "$worktree_path" "$worktree_branch" "$worktree_resolved" "$worktree_base_sha"
}

lane_launch() {
  # The coordinator told the manager to detach a worker by hand:
  # `codex exec ... > log 2>&1 & echo $! > pid`. In a real run that line
  # launched, reported a pid, and the process was dead two seconds later with a
  # zero-byte log: the agent tool call that ran it takes its whole process group
  # down when the call returns. `await` then printed `AWAIT-DONE exit=exited`
  # after waiting 0s, which reads exactly like a lane that finished. The manager
  # retried with `nohup`, lost that one the same way, gave up on detaching, ran
  # the worker in the foreground, and spent the next hour polling it — 600 turns
  # of keepalive for one lane. Detaching is a mechanism, so linchpin ships it:
  # a new session so nothing reaps the lane, a recorded exit code so `await`
  # reports the truth, and a liveness check so a lane that died at launch says
  # so instead of being mistaken for one that finished.
  # Claude Code has no `-C` and takes its prompt on stdin, so a claude lane
  # needs its working directory and its brief supplied here. Both are optional
  # and omitting them keeps the codex behavior exactly: `-C <lane>` and the
  # brief as an argument. They are options rather than something a coordinator
  # improvises with a `cd &&` string, because a lane started in the wrong
  # directory commits to the wrong repository.
  launch_pid_file=''
  launch_log=''
  launch_settle=5
  launch_cwd=''
  launch_stdin=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pid) [ "$#" -ge 2 ] || die 'launch --pid needs a path'; launch_pid_file="$2"; shift 2 ;;
      --log) [ "$#" -ge 2 ] || die 'launch --log needs a path'; launch_log="$2"; shift 2 ;;
      --settle) [ "$#" -ge 2 ] || die 'launch --settle needs seconds'; launch_settle="$2"; shift 2 ;;
      --cwd) [ "$#" -ge 2 ] || die 'launch --cwd needs a directory'; launch_cwd="$2"; shift 2 ;;
      --stdin) [ "$#" -ge 2 ] || die 'launch --stdin needs a path'; launch_stdin="$2"; shift 2 ;;
      --) shift; break ;;
      *) die 'usage: linchpin.sh launch --pid PATH --log PATH [--settle SECONDS] [--cwd DIR] [--stdin FILE] -- COMMAND...' ;;
    esac
  done
  [ -n "$launch_pid_file" ] && [ -n "$launch_log" ] ||
    die 'usage: linchpin.sh launch --pid PATH --log PATH [--settle SECONDS] [--cwd DIR] [--stdin FILE] -- COMMAND...'
  if [ -n "$launch_cwd" ]; then
    [ -d "$launch_cwd" ] || die "launch --cwd is not a directory: $launch_cwd"
    launch_cwd=$(CDPATH= cd -- "$launch_cwd" && pwd)
  fi
  if [ -n "$launch_stdin" ]; then
    [ -f "$launch_stdin" ] && [ -r "$launch_stdin" ] ||
      die "launch --stdin is not a readable file: $launch_stdin"
    launch_stdin=$(absolute_path "$launch_stdin")
  fi
  # The child records its pid before it changes directory and appends its log
  # after, so both paths are resolved here rather than left relative to a cwd
  # the lane is about to leave.
  launch_pid_file=$(absolute_path "$launch_pid_file")
  launch_log=$(absolute_path "$launch_log")
  [ "$#" -ge 1 ] || die 'launch needs a command after --'
  printf '%s\n' "$launch_settle" | grep -Eq '^[0-9]+$' ||
    die "launch --settle is whole seconds: $launch_settle"
  command -v "$1" >/dev/null 2>&1 || die "launch command is not executable: $1"

  rm -f "$launch_pid_file" "$launch_pid_file.exit"
  : > "$launch_log" || die "launch cannot write its log: $launch_log"
  : > "$launch_pid_file" || die "launch cannot write its pid file: $launch_pid_file"

  # The child writes its own pid rather than the parent recording `$!`. `setsid`
  # may or may not fork depending on whether the caller is already a process
  # group leader, so `$!` is not reliably the process `await` must watch; `$$`
  # inside the child always is.
  launch_runner='printf "%s\n" "$$" > "$LINCHPIN_LAUNCH_PID"
[ -z "$LINCHPIN_LAUNCH_CWD" ] || cd "$LINCHPIN_LAUNCH_CWD" || exit 1
"$@" >> "$LINCHPIN_LAUNCH_LOG" 2>&1
printf "%s\n" "$?" > "$LINCHPIN_LAUNCH_PID.exit"'
  launch_detach='setsid'
  command -v setsid >/dev/null 2>&1 || launch_detach=''

  if [ -n "$launch_stdin" ]; then
    LINCHPIN_LAUNCH_PID="$launch_pid_file" LINCHPIN_LAUNCH_LOG="$launch_log" \
      LINCHPIN_LAUNCH_CWD="$launch_cwd" \
      $launch_detach sh -c "$launch_runner" sh "$@" < "$launch_stdin" > /dev/null 2>&1 &
  else
    LINCHPIN_LAUNCH_PID="$launch_pid_file" LINCHPIN_LAUNCH_LOG="$launch_log" \
      LINCHPIN_LAUNCH_CWD="$launch_cwd" \
      $launch_detach sh -c "$launch_runner" sh "$@" < /dev/null > /dev/null 2>&1 &
  fi

  # Give the child a moment to record its pid before reading it back.
  launch_waited=0
  while [ "$launch_waited" -lt 5 ]; do
    [ -s "$launch_pid_file" ] && break
    sleep 1
    launch_waited=$((launch_waited + 1))
  done
  launch_pid=$(tr -dc '0-9' < "$launch_pid_file")
  [ -n "$launch_pid" ] || {
    printf 'LAUNCH-FAIL no-pid the lane process never started; %s is empty\n' "$launch_pid_file" >&2
    exit 1
  }

  [ "$launch_settle" -gt 0 ] && sleep "$launch_settle"
  if ! kill -0 "$launch_pid" 2>/dev/null; then
    # A worker that ran a PRD does not finish in seconds. Whatever this was, it
    # is a launch failure, and the log tail is the reason the manager needs.
    launch_exit='unknown'
    [ -f "$launch_pid_file.exit" ] && launch_exit=$(tr -dc '0-9' < "$launch_pid_file.exit")
    printf 'LAUNCH-FAIL died-immediately pid=%s exit=%s after=%ss log=%s\n' \
      "$launch_pid" "$launch_exit" "$launch_settle" "$launch_log" >&2
    if [ -s "$launch_log" ]; then
      tail -n 20 "$launch_log" >&2
    else
      printf 'LAUNCH-LOG-EMPTY the lane produced no output at all, which is what a reaped process group looks like\n' >&2
    fi
    exit 1
  fi

  printf 'LAUNCH-READY lane=%s pid=%s log=%s\n' \
    "$(basename "$launch_pid_file" .pid)" "$launch_pid" "$launch_log"
}

lane_await() {
  # A lane takes tens of minutes. Managers waited on them by polling a live
  # subprocess every few seconds: one field batch spent 954 thirty-second polls
  # and 739 one-second polls restating that lanes were still running. Polling
  # once per lane per interval makes waiting cost turns in proportion to lane
  # *duration*; this waits on a whole group in one call, so it costs turns in
  # proportion to the number of groups.
  await_interval=30
  await_timeout=0
  await_pidfiles=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval) [ "$#" -ge 2 ] || die 'await --interval needs seconds'; await_interval="$2"; shift 2 ;;
      --timeout) [ "$#" -ge 2 ] || die 'await --timeout needs seconds'; await_timeout="$2"; shift 2 ;;
      --*) die "unknown await option: $1" ;;
      *) await_pidfiles="$await_pidfiles $1"; shift ;;
    esac
  done
  [ -n "$await_pidfiles" ] || die 'usage: linchpin.sh await PIDFILE... [--interval SECONDS] [--timeout SECONDS]'
  for await_arg in $await_interval $await_timeout; do
    printf '%s\n' "$await_arg" | grep -Eq '^[0-9]+$' || die "await interval and timeout are whole seconds: $await_arg"
  done
  [ "$await_interval" -gt 0 ] || die 'await --interval must be greater than zero'
  for await_file in $await_pidfiles; do
    require_file "$await_file"
  done

  await_waited=0
  while :; do
    await_running=0
    for await_file in $await_pidfiles; do
      await_pid=$(tr -dc '0-9' < "$await_file")
      [ -n "$await_pid" ] || continue
      kill -0 "$await_pid" 2>/dev/null && await_running=$((await_running + 1))
    done
    [ "$await_running" -eq 0 ] && break
    if [ "$await_timeout" -gt 0 ] && [ "$await_waited" -ge "$await_timeout" ]; then
      # A timeout is not a delivery result. Say which lanes are still alive and
      # leave them running: the manager inspects the real diff from here.
      printf 'AWAIT-TIMEOUT running=%d waited=%ds\n' "$await_running" "$await_waited" >&2
      exit 1
    fi
    sleep "$await_interval"
    await_waited=$((await_waited + await_interval))
  done

  for await_file in $await_pidfiles; do
    await_pid=$(tr -dc '0-9' < "$await_file")
    await_status='exited'
    [ -f "$await_file.exit" ] && await_status=$(tr -dc '0-9' < "$await_file.exit")
    printf 'AWAIT-DONE lane=%s pid=%s exit=%s\n' \
      "$(basename "$await_file" .pid)" "${await_pid:-unknown}" "$await_status"
  done
  printf 'AWAIT-COMPLETE lanes=%d waited=%ds\n' "$(printf '%s\n' $await_pidfiles | wc -l | tr -d ' ')" "$await_waited"
}

# Every other invariant in this plugin is enforced by a command: briefs are
# checked, gates are checked, worktrees are created, models are preflighted. The
# run ledger was the exception. The coordinator demands fifteen fields per lane,
# calls a run without one unresumable, and then leaves a manager model to type
# those fields from memory at the end of an eight-lane batch. That is exactly
# where a row reading `DELIVERED` against a sha nobody created gets written —
# a failure the skill names and had no way to catch. These two commands make the
# ledger the artifact it was always described as: written by a helper that
# refuses a claim it cannot verify, and read back by a command rather than
# recalled.
ledger_lane_valid() {
  printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$'
}

run_ledger_block() {
  # Every `- key: value` line of one lane's block, in file order. A block ends at
  # the next heading of any kind, so prose a manager adds between lanes is never
  # absorbed into the row above it.
  awk -v target="$2" '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    /^## / {
      current = ($0 ~ /^## Lane: /) ? trim(substr($0, 10)) : ""
      next
    }
    current == target && /^- [a-z][a-z0-9_]*:/ {
      entry = substr($0, 3)
      split_at = index(entry, ":")
      print substr(entry, 1, split_at - 1) "\t" trim(substr(entry, split_at + 1))
    }
  ' "$1"
}

ledger_value() {
  # Empty output means absent: a value is never allowed to be empty, so the two
  # cases cannot be confused by a caller.
  awk -F '\t' -v key="$1" '$1 == key { value = $2 } END { print value }' "$2"
}

lane_record() {
  lane_file=''
  lane_id=''
  lane_repo=''
  lane_sets_seen=0
  lane_tmp=$(mktemp -d "${TMPDIR:-/tmp}/linchpin-lane.XXXXXX")
  trap 'rm -rf -- "$lane_tmp"' EXIT HUP INT TERM
  : > "$lane_tmp/sets"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --set)
        [ "$#" -ge 2 ] || die 'lane --set needs key=value'
        case "$2" in
          *=*) ;;
          *) die "lane --set needs key=value: $2" ;;
        esac
        lane_key=${2%%=*}
        lane_value=${2#*=}
        printf '%s\n' "$lane_key" | grep -Eq '^[a-z][a-z0-9_]*$' ||
          die "lane field name is not a lowercase identifier: $lane_key"
        [ -n "$lane_value" ] || die "lane field has an empty value: $lane_key (write an explicit value such as none)"
        case "$lane_value" in
          *"$(printf '\t')"*) die "lane field value contains a tab: $lane_key" ;;
        esac
        [ "$(printf '%s' "$lane_value" | wc -l | tr -d ' ')" -eq 0 ] ||
          die "lane field value spans more than one line: $lane_key"
        printf '%s\t%s\n' "$lane_key" "$lane_value" >> "$lane_tmp/sets"
        lane_sets_seen=$((lane_sets_seen + 1))
        shift 2 ;;
      --repo) [ "$#" -ge 2 ] || die 'lane --repo needs a directory'; lane_repo="$2"; shift 2 ;;
      --*) die "unknown lane option: $1" ;;
      *)
        if [ -z "$lane_file" ]; then lane_file="$1"
        elif [ -z "$lane_id" ]; then lane_id="$1"
        else die "unexpected lane argument: $1"
        fi
        shift ;;
    esac
  done
  [ -n "$lane_file" ] || die 'usage: linchpin.sh lane LEDGER LANE_ID --set key=value...'
  [ -n "$lane_id" ] || die 'usage: linchpin.sh lane LEDGER LANE_ID --set key=value...'
  ledger_lane_valid "$lane_id" || die "lane id is malformed: $lane_id"
  [ "$lane_sets_seen" -gt 0 ] || die 'lane needs at least one --set key=value'
  # The ledger lives at <repo>/.linchpin/run-<timestamp>.md, so the repository
  # that holds the lane's commit is two levels up unless the caller says otherwise.
  [ -n "$lane_repo" ] || lane_repo=$(CDPATH= cd -- "$(dirname -- "$(dirname -- "$lane_file")")" && pwd)

  if [ -e "$lane_file" ]; then
    [ -f "$lane_file" ] || die "run ledger is not a file: $lane_file"
    run_ledger_block "$lane_file" "$lane_id" > "$lane_tmp/existing"
  else
    lane_dir=$(dirname -- "$lane_file")
    [ -d "$lane_dir" ] || die "run ledger directory does not exist: $lane_dir (run linchpin.sh workspace first)"
    printf '%s\n' '# Linchpin run ledger' '' > "$lane_file"
    : > "$lane_tmp/existing"
  fi

  # Merge: an existing field keeps its position and takes the new value, a new
  # field is appended. Rewriting the row from the --set list alone would silently
  # drop every field an earlier call recorded.
  : > "$lane_tmp/merged"
  while IFS="$(printf '\t')" read -r lane_key lane_value; do
    [ -n "$lane_key" ] || continue
    lane_override=$(ledger_value "$lane_key" "$lane_tmp/sets")
    [ -z "$lane_override" ] || lane_value="$lane_override"
    printf '%s\t%s\n' "$lane_key" "$lane_value" >> "$lane_tmp/merged"
  done < "$lane_tmp/existing"
  while IFS="$(printf '\t')" read -r lane_key lane_value; do
    [ -n "$lane_key" ] || continue
    [ -z "$(ledger_value "$lane_key" "$lane_tmp/existing")" ] || continue
    [ -z "$(ledger_value "$lane_key" "$lane_tmp/merged")" ] || continue
    # Read the value back rather than trusting this line: a field set twice in
    # one call must land on the same last-wins value an existing field would.
    printf '%s\t%s\n' "$lane_key" "$(ledger_value "$lane_key" "$lane_tmp/sets")" >> "$lane_tmp/merged"
  done < "$lane_tmp/sets"

  lane_state=$(ledger_value state "$lane_tmp/merged")
  [ -n "$lane_state" ] || die "lane row has no state: $lane_id (--set state=PENDING|RUNNING|PARTIAL|BLOCKED|'DELIVERED(pr)'|'DELIVERED(branch)')"
  case "$lane_state" in
    MERGED|merged)
      # The coordinator forbids this word as a product state on purpose: it bakes
      # pr delivery into the ledger's vocabulary and makes branch delivery a
      # redesign instead of a config value.
      die "MERGED is not a lane state; use DELIVERED(pr) or DELIVERED(branch)" ;;
    PENDING|RUNNING|PARTIAL|BLOCKED|'DELIVERED(pr)'|'DELIVERED(branch)') ;;
    *) die "unknown lane state: $lane_state (PENDING, RUNNING, PARTIAL, BLOCKED, DELIVERED(pr), DELIVERED(branch))" ;;
  esac

  # PARTIAL is what `status` counts as "still open", so a lane left there after
  # its last review gives a manager reading exit codes a standing reason to start
  # one more round. That is the loop the review cap ends, and this is the other
  # half of it: once the reviews are spent the lane is delivered on its evidence
  # or blocked on a named reason someone can act on. The call that bumps the
  # counter is exempt, or the last permitted review could never be recorded.
  lane_review_rounds=$(ledger_value review_rounds "$lane_tmp/merged")
  if [ "$lane_state" = PARTIAL ] &&
     [ -z "$(ledger_value review_rounds "$lane_tmp/sets")" ] &&
     printf '%s\n' "$lane_review_rounds" | grep -Eq '^[0-9]+$' &&
     [ "$lane_review_rounds" -ge "$review_round_cap" ]; then
    die "lane $lane_id has spent its $review_round_cap reviews and cannot stay PARTIAL: record BLOCKED with reason and resume, or DELIVERED with its evidence. PARTIAL after the last review is the state a run repeats forever."
  fi

  lane_commit=$(ledger_value commit "$lane_tmp/merged")
  if [ -n "$lane_commit" ]; then
    # A recorded sha the worker never created is the false ledger row the
    # coordinator names and could not catch. Resolving it costs one git call.
    printf '%s\n' "$lane_commit" | grep -Eq '^[0-9a-f]{7,40}$' ||
      die "lane commit is not a git object id: $lane_commit"
    command -v git >/dev/null 2>&1 || die 'git is required to verify a recorded lane commit'
    git -C "$lane_repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
      die "lane commit cannot be verified: $lane_repo is not a Git repository (pass --repo)"
    git -C "$lane_repo" cat-file -e "$lane_commit^{commit}" 2>/dev/null ||
      die "recorded lane commit does not exist in $lane_repo: $lane_commit"
  fi

  case "$lane_state" in
    'DELIVERED(pr)'|'DELIVERED(branch)')
      for lane_required in prd branch commit gates review; do
        [ -n "$(ledger_value "$lane_required" "$lane_tmp/merged")" ] ||
          die "a delivered lane needs $lane_required: $lane_id"
      done
      lane_gates=$(ledger_value gates "$lane_tmp/merged")
      # Either the evidence file exists or the PRD declared no controls, which is
      # what `gate` reports. An asserted evidence path that is not on disk is the
      # same claim-without-evidence the gate rule exists to reject.
      if [ "$lane_gates" != 'NOT-DECLARED' ] && [ ! -f "$lane_gates" ]; then
        case "$lane_gates" in
          /*) die "gate evidence file does not exist: $lane_gates" ;;
          *) [ -f "$lane_repo/$lane_gates" ] || die "gate evidence file does not exist: $lane_gates (relative to $lane_repo)" ;;
        esac
      fi
      ;;
    BLOCKED)
      for lane_required in reason resume; do
        [ -n "$(ledger_value "$lane_required" "$lane_tmp/merged")" ] ||
          die "a blocked lane needs $lane_required: $lane_id"
      done
      ;;
  esac

  {
    printf '## Lane: %s\n' "$lane_id"
    while IFS="$(printf '\t')" read -r lane_key lane_value; do
      [ -n "$lane_key" ] || continue
      printf '%s\n' "- $lane_key: $lane_value"
    done < "$lane_tmp/merged"
  } > "$lane_tmp/block"

  awk -v target="$lane_id" -v blockfile="$lane_tmp/block" '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    # The trailing blank line is emitted here, not by the caller: an update
    # consumes the blank line that followed the old block, and without this every
    # re-record would jam the next lane heading against the row above it.
    function emit(   i) { for (i = 1; i <= block_lines; i++) print block[i]; print "" }
    BEGIN { while ((getline block_line < blockfile) > 0) block[++block_lines] = block_line }
    /^## / {
      if ($0 ~ /^## Lane: / && trim(substr($0, 10)) == target) {
        emit(); replaced = 1; inside = 1; next
      }
      inside = 0; print; next
    }
    inside { next }
    { print }
    END { if (!replaced) emit() }
  ' "$lane_file" > "$lane_tmp/ledger"
  cat "$lane_tmp/ledger" > "$lane_file"
  printf 'LANE-RECORDED %s state=%s fields=%s\n' \
    "$lane_id" "$lane_state" "$(awk 'NF' "$lane_tmp/merged" | wc -l | tr -d ' ')"
}

run_status() {
  status_file="${1:-}"
  [ -n "$status_file" ] || die 'usage: linchpin.sh status LEDGER'
  require_file "$status_file"
  status_lines=$(awk '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    function flush(   line, i, key) {
      if (lane == "") return
      line = (value["state"] == "" ? "UNRECORDED" : value["state"]) " lane=" lane
      for (i = 1; i <= reported; i++) {
        key = report[i]
        if (value[key] != "") line = line " " key "=" value[key]
      }
      print line
      lane = ""
      split("", value)
    }
    BEGIN {
      reported = split("prd branch commit gates review reason resume", report, " ")
    }
    /^## / {
      flush()
      if ($0 ~ /^## Lane: /) lane = trim(substr($0, 10))
      next
    }
    lane != "" && /^- [a-z][a-z0-9_]*:/ {
      entry = substr($0, 3)
      split_at = index(entry, ":")
      value[substr(entry, 1, split_at - 1)] = trim(substr(entry, split_at + 1))
    }
    END { flush() }
  ' "$status_file")
  [ -n "$status_lines" ] || die "run ledger has no lane rows: $status_file"
  printf '%s\n' "$status_lines"
  status_count() {
    printf '%s\n' "$status_lines" | grep -c "$1" || true
  }
  status_delivered=$(status_count '^DELIVERED(')
  status_partial=$(status_count '^PARTIAL ')
  status_blocked=$(status_count '^BLOCKED ')
  status_pending=$(status_count '^PENDING ')
  status_running=$(status_count '^RUNNING ')
  status_unrecorded=$(status_count '^UNRECORDED ')
  status_open=$((status_partial + status_pending + status_running + status_unrecorded))
  printf 'RUN-STATUS delivered=%s partial=%s blocked=%s pending=%s running=%s unrecorded=%s\n' \
    "$status_delivered" "$status_partial" "$status_blocked" "$status_pending" \
    "$status_running" "$status_unrecorded"
  # Three outcomes, not two. A goal loop needs "keep going" and "stop, a human is
  # required" to be different answers, and a summary that says done while a lane
  # is still PARTIAL is the prose claim this command replaces.
  [ "$status_open" -eq 0 ] || exit 1
  [ "$status_blocked" -eq 0 ] || exit 2
}

prune_worktree_path() {
  # The path git actually has checked out for a lane branch, not the path the
  # convention predicts. A lane created with `worktree --path` lives somewhere
  # else, and removing the predicted directory would leave that one behind.
  git -C "$prune_repo" worktree list --porcelain | awk -v want="refs/heads/$1" '
    /^worktree / { path = substr($0, 10) }
    /^branch / { if (substr($0, 8) == want) { print path; exit } }
  '
}

prune_safe_reason() {
  # Prints why a lane branch is safe to delete, or nothing. Deleting a lane
  # branch throws away the only local reference to its commits, so this asks the
  # three ways that work survives instead of trusting the ledger's word for it:
  # the base already contains the commits; the base contains the same change
  # under a different sha, which is what a squash merge leaves behind and what
  # makes `git branch -d` call a merged lane unmerged; or the branch is on the
  # remote, where the PR that carries it lives.
  prune_check_branch="$1"
  prune_check_sha=$(git -C "$prune_repo" rev-parse --verify --quiet "refs/heads/$prune_check_branch") || return 0
  for prune_base_ref in $prune_base_refs; do
    if git -C "$prune_repo" merge-base --is-ancestor "$prune_check_sha" "$prune_base_ref" 2>/dev/null; then
      printf 'merged-into-%s\n' "$prune_base_ref"
      return 0
    fi
  done
  for prune_base_ref in $prune_base_refs; do
    prune_merge_base=$(git -C "$prune_repo" merge-base "$prune_base_ref" "$prune_check_sha" 2>/dev/null) || continue
    # The lane's whole change as one commit on the merge base, which is the shape
    # a squash merge produced on the base. `git cherry` compares patch ids, so
    # `-` means the base already carries this change under another sha.
    prune_probe=$(git -C "$prune_repo" commit-tree "$prune_check_sha^{tree}" -p "$prune_merge_base" -m 'linchpin prune probe' 2>/dev/null) || continue
    case "$(git -C "$prune_repo" cherry "$prune_base_ref" "$prune_probe" 2>/dev/null | head -n 1)" in
      -*) printf 'squashed-onto-%s\n' "$prune_base_ref"; return 0 ;;
    esac
  done
  prune_remote_sha=$(git -C "$prune_repo" rev-parse --verify --quiet "refs/remotes/origin/$prune_check_branch") || prune_remote_sha=''
  if [ -n "$prune_remote_sha" ] && [ "$prune_remote_sha" = "$prune_check_sha" ]; then
    printf 'pushed-to-origin/%s\n' "$prune_check_branch"
  fi
}

prune_run() {
  # Closing a run used to be prose: the coordinator told the manager to remove
  # each terminal lane's worktree and delete the merged branches by hand. What
  # that produced after a batch was a `.worktrees/` directory of finished lanes
  # and a `git branch` listing where the user could not tell which lanes were
  # already shipped, because the ordinary squash merge leaves a lane branch
  # looking unmerged. Cleanup is a mechanism, so linchpin ships it: terminal
  # lanes go, unfinished lanes stay with the command that resumes them, and
  # nothing is deleted before its commits are proven to exist somewhere else.
  prune_ledger=''
  prune_repo=''
  prune_base=''
  prune_dry=0
  prune_force=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) [ "$#" -ge 2 ] || die 'prune --repo needs a directory'; prune_repo="$2"; shift 2 ;;
      --base) [ "$#" -ge 2 ] || die 'prune --base needs a ref'; prune_base="$2"; shift 2 ;;
      --dry-run) prune_dry=1; shift ;;
      --force) prune_force=1; shift ;;
      --*) die "unknown prune option: $1" ;;
      *)
        [ -z "$prune_ledger" ] || die "unexpected prune argument: $1"
        prune_ledger="$1"
        shift ;;
    esac
  done
  [ -n "$prune_ledger" ] || die 'usage: linchpin.sh prune LEDGER [--repo DIR] [--base REF] [--dry-run] [--force]'
  require_file "$prune_ledger"
  command -v git >/dev/null 2>&1 || die 'git is required to prune a run'
  [ -n "$prune_repo" ] || prune_repo=$(CDPATH= cd -- "$(dirname -- "$(dirname -- "$prune_ledger")")" && pwd)
  [ -d "$prune_repo" ] || die "prune target is not a directory: $prune_repo"
  git -C "$prune_repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "prune target is not a Git repository: $prune_repo (pass --repo)"
  # A lane cannot remove the worktree it is standing in, and a manager that
  # closed the run from inside the last lane would get one confusing git error
  # instead of the list of what was cleaned.
  if [ "$(git -C "$prune_repo" rev-parse --git-dir)" != "$(git -C "$prune_repo" rev-parse --git-common-dir)" ]; then
    die "prune target is itself a linked worktree: $prune_repo (run it from the main worktree)"
  fi

  if [ -z "$prune_base" ]; then
    prune_base=$(git -C "$prune_repo" symbolic-ref --quiet --short HEAD 2>/dev/null) || prune_base=''
    [ -n "$prune_base" ] || prune_base='HEAD'
  fi
  # The remote base first, for the same reason lane creation branches from it:
  # the merge that retired these lanes landed there, and a local base that never
  # pulled would call every shipped lane unmerged.
  if [ "$prune_base" != 'HEAD' ] && git -C "$prune_repo" remote get-url origin >/dev/null 2>&1; then
    git -C "$prune_repo" fetch --quiet origin "$prune_base" 2>/dev/null || true
  fi
  prune_base_refs=''
  for prune_candidate in "origin/$prune_base" "$prune_base"; do
    git -C "$prune_repo" rev-parse --verify --quiet "$prune_candidate" >/dev/null || continue
    prune_base_refs="$prune_base_refs $prune_candidate"
  done
  [ -n "$prune_base_refs" ] || die "prune base does not resolve in $prune_repo: $prune_base"

  prune_tmp=$(mktemp -d "${TMPDIR:-/tmp}/linchpin-prune.XXXXXX")
  trap 'rm -rf -- "$prune_tmp"' EXIT HUP INT TERM
  awk '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    function flush() {
      if (lane != "") print (value["state"] == "" ? "UNRECORDED" : value["state"]) "\t" lane "\t" value["branch"] "\t" value["resume"]
      lane = ""
      split("", value)
    }
    /^## / {
      flush()
      if ($0 ~ /^## Lane: /) lane = trim(substr($0, 10))
      next
    }
    lane != "" && /^- [a-z][a-z0-9_]*:/ {
      entry = substr($0, 3)
      split_at = index(entry, ":")
      value[substr(entry, 1, split_at - 1)] = trim(substr(entry, split_at + 1))
    }
    END { flush() }
  ' "$prune_ledger" > "$prune_tmp/lanes"
  [ -s "$prune_tmp/lanes" ] || die "run ledger has no lane rows: $prune_ledger"

  prune_worktrees=0
  prune_branches=0
  prune_kept=0
  while IFS="$(printf '\t')" read -r prune_state prune_lane prune_branch prune_resume; do
    [ -n "$prune_lane" ] || continue
    case "$prune_branch" in
      ''|none|NONE) prune_branch='' ;;
    esac
    [ -z "$prune_branch" ] || prune_path=$(prune_worktree_path "$prune_branch")
    [ -n "$prune_branch" ] || prune_path=''

    case "$prune_state" in
      'DELIVERED(pr)'|'DELIVERED(branch)') ;;
      *)
        # Everything that is not delivered keeps both its worktree and its
        # branch. A run that cleaned up a BLOCKED lane would delete the state
        # its own resume command needs.
        printf 'PRUNE-KEPT lane=%s state=%s' "$prune_lane" "$prune_state"
        [ -z "$prune_branch" ] || printf ' branch=%s' "$prune_branch"
        [ -z "$prune_path" ] || printf ' worktree=%s' "$prune_path"
        printf ' reason=not-delivered'
        [ -z "$prune_resume" ] || printf ' resume=%s' "$prune_resume"
        printf '\n'
        prune_kept=$((prune_kept + 1))
        continue ;;
    esac

    if [ -n "$prune_path" ]; then
      prune_dirty=$(git -C "$prune_path" status --porcelain 2>/dev/null || true)
      if [ -n "$prune_dirty" ] && [ "$prune_force" -eq 0 ]; then
        # Delivery is recorded against a commit, so anything still uncommitted
        # here is work nobody reviewed and nothing carries. Deleting it is the
        # one thing cleanup must never do quietly.
        printf 'PRUNE-KEPT lane=%s state=%s worktree=%s reason=uncommitted-changes next=git -C %s status\n' \
          "$prune_lane" "$prune_state" "$prune_path" "$prune_path"
        prune_kept=$((prune_kept + 1))
        continue
      fi
      if [ "$prune_dry" -eq 1 ]; then
        printf 'PRUNE-WOULD-REMOVE lane=%s worktree=%s\n' "$prune_lane" "$prune_path"
      elif prune_error=$(git -C "$prune_repo" worktree remove --force "$prune_path" 2>&1); then
        printf 'PRUNE-WORKTREE lane=%s path=%s\n' "$prune_lane" "$prune_path"
        prune_worktrees=$((prune_worktrees + 1))
      else
        printf 'PRUNE-KEPT lane=%s state=%s worktree=%s reason=%s\n' \
          "$prune_lane" "$prune_state" "$prune_path" "$(printf '%s' "$prune_error" | tr '\n' ' ')"
        prune_kept=$((prune_kept + 1))
        continue
      fi
    fi

    [ -n "$prune_branch" ] || continue
    git -C "$prune_repo" show-ref --verify --quiet "refs/heads/$prune_branch" || continue
    prune_reason=$(prune_safe_reason "$prune_branch")
    if [ -z "$prune_reason" ]; then
      printf 'PRUNE-KEPT-BRANCH lane=%s branch=%s reason=commits-only-here next=git -C %s branch -D %s\n' \
        "$prune_lane" "$prune_branch" "$prune_repo" "$prune_branch"
      prune_kept=$((prune_kept + 1))
      continue
    fi
    if [ "$prune_dry" -eq 1 ]; then
      printf 'PRUNE-WOULD-DELETE lane=%s branch=%s reason=%s\n' "$prune_lane" "$prune_branch" "$prune_reason"
      continue
    fi
    # `-D`, not `-d`, and only after the reason above proved where the commits
    # live: `-d` refuses the squash-merged branch that is the ordinary case here.
    git -C "$prune_repo" branch -D "$prune_branch" >/dev/null 2>&1 ||
      die "lane branch could not be deleted: $prune_branch"
    printf 'PRUNE-BRANCH lane=%s branch=%s reason=%s\n' "$prune_lane" "$prune_branch" "$prune_reason"
    prune_branches=$((prune_branches + 1))
  done < "$prune_tmp/lanes"

  if [ "$prune_dry" -eq 0 ]; then
    git -C "$prune_repo" worktree prune
    # Only when it is empty: an empty `.worktrees/` is leftover, a populated one
    # is a lane the run decided to keep.
    rmdir "$prune_repo/.worktrees" 2>/dev/null || true
  fi
  printf 'PRUNE-DONE worktrees=%s branches=%s kept=%s\n' "$prune_worktrees" "$prune_branches" "$prune_kept"
}

usage() {
  cat <<'USAGE'
linchpin.sh COMMAND [ARGS]

  route INTENT [SCORE] [PRD ...] [--config-dir DIR]  classify a request
  contract PRD                                       report every contract problem
  migrate PRD [--out PATH] [--force]                 write a v1 copy; never edits PRD
  brief PRD [LANE_ID LANE_MODE DELIVERY_MODE]        emit the worker brief
        [--out PATH] [--config-dir DIR]
  brief-check PRD BRIEF [--config-dir DIR]           verify a brief against its PRD
  review-brief PRD LANE_ID --gates PATH --commit SHA emit the read-only review brief
        --ledger PATH [--round N] [--out PATH] [--config-dir DIR]
        counts the round in the ledger; at most 2 per lane, the 2nd only with --round 2
  files PRD                                          print the parsed Files (N) list
  mode EXECUTION PRD... [--config-dir DIR]           group lanes by file collision
  schedule EXECUTION STATUS LANE... [--config-dir DIR]
        STATUS: ok | worktree-fail | dirty-tree | unparsed-files | config
  gate PRD REPORT                                    check observed-red evidence
  assign "TEXT" [--config-dir DIR] [--write]         read role/model/effort out of a sentence
        role words: executor|worker|implementer|builder, reviewer|review|critic
        prints one ASSIGN line per role; --write updates .linchpin.toml in place
        a model in no alias table is verified live and recorded in
        .linchpin-models.toml; one that verifies nowhere is ASSIGN-UNRESOLVED
  config [REPO]                                      print resolved .linchpin.toml
  workspace [REPO]                                   make .linchpin/ and ignore run output
  lane LEDGER LANE_ID --set key=value... [--repo DIR] record one run-ledger row
        state: PENDING | RUNNING | PARTIAL | BLOCKED | DELIVERED(pr) | DELIVERED(branch)
        a recorded commit must resolve in the repository; DELIVERED needs
        prd, branch, commit, gates, review; BLOCKED needs reason, resume
  status LEDGER                                      read the ledger back
        exit 0 every lane delivered; 1 a lane is still open; 2 only blocked lanes remain
  worktree REPO LANE_SLUG BASE_REF [--path DIR]      create one isolated lane worktree
  prune LEDGER [--repo DIR] [--base REF]              clean up after a finished run
        [--dry-run] [--force]
        removes each delivered lane's worktree and branch; keeps every lane that
        is not delivered, has uncommitted changes, or whose commits exist nowhere
        but that branch, and names what it kept
  launch --pid PATH --log PATH [--settle S] -- CMD   detach one lane and prove it is alive
        [--cwd DIR] [--stdin FILE]
        --cwd starts the lane inside its worktree and --stdin feeds the brief on
        stdin; a claude role needs both, a codex role needs neither
  await PIDFILE... [--interval S] [--timeout S]      block until a group's lanes exit
  preflight [MODELS_CACHE.json]                      check every role's model
        codex roles by cache lookup, claude roles by one live probe
  help                                               this text

EXECUTION is auto, parallel, or sequential.
USAGE
}

command_usage() {
  # The usage screen is the only description of an argument order, so it is also
  # the answer to `<command> --help`. Reading it back beats a second copy per
  # command, which is how the two drift apart. An entry is its own line plus any
  # deeper-indented continuation lines under it.
  usage | awk -v want="$1" '
    $0 ~ "^  " want "( |$)" { entry = 1; print; next }
    entry && /^ {8}/ { print; next }
    entry { exit }
  '
}

command_name="${1:-}"
[ "$#" -eq 0 ] || shift
# A manager asks the tool before it guesses. Answering `lane --help` with
# `ERROR: usage: linchpin.sh lane ...` at exit 1 reads as a broken command, and
# the guess that follows is the ledger row nothing writes.
case "${1:-}" in
  --help|-h)
    command_help=$(command_usage "$command_name")
    [ -n "$command_help" ] || die "no such command: $command_name (run linchpin.sh help)"
    printf '%s\n' "$command_help"
    exit 0
    ;;
esac
case "$command_name" in
  contract) [ "$#" -eq 1 ] || die 'usage: linchpin.sh contract PRD'; contract_check "$1" ;;
  migrate) [ "$#" -ge 1 ] || die 'usage: linchpin.sh migrate PRD [--out PATH] [--force]'; migrate "$@" ;;
  brief) [ "$#" -ge 1 ] || die 'usage: linchpin.sh brief PRD [LANE_ID LANE_MODE DELIVERY_MODE] [--config-dir DIR]'; brief "$@" ;;
  brief-check) [ "$#" -ge 2 ] || die 'usage: linchpin.sh brief-check PRD BRIEF [--config-dir DIR]'; brief_check "$@" ;;
  review-brief) [ "$#" -ge 1 ] || die 'usage: linchpin.sh review-brief PRD LANE_ID --gates PATH --commit SHA --ledger PATH [--round N] [--out PATH]'; review_brief "$@" ;;
  files)
    [ "$#" -eq 1 ] || die 'usage: linchpin.sh files PRD'
    if ! files_list "$1"; then
      # Silence plus exit 1 reads as a broken helper. Say which of the two it is.
      printf 'NO-FILES-LIST %s has no machine-readable `Files (N)` list; run `mode` for its derived set.\n' "$1" >&2
      exit 1
    fi
    ;;
  help|--help|-h) usage; exit 0 ;;
  assign) [ "$#" -ge 1 ] || die 'usage: linchpin.sh assign "TEXT" [--config-dir DIR] [--write]'; assign "$@" ;;
  config) [ "$#" -le 1 ] || die 'usage: linchpin.sh config [repo]'; config_values "${1:-${LINCHPIN_CONFIG_DIR:-$PWD}}" ;;
  workspace) [ "$#" -le 1 ] || die 'usage: linchpin.sh workspace [repo]'; workspace "${1:-}" ;;
  lane) [ "$#" -ge 3 ] || die 'usage: linchpin.sh lane LEDGER LANE_ID --set key=value... [--repo DIR]'; lane_record "$@" ;;
  status) [ "$#" -eq 1 ] || die 'usage: linchpin.sh status LEDGER'; run_status "$1" ;;
  prune) [ "$#" -ge 1 ] || die 'usage: linchpin.sh prune LEDGER [--repo DIR] [--base REF] [--dry-run] [--force]'; prune_run "$@" ;;
  worktree) [ "$#" -ge 3 ] || die 'usage: linchpin.sh worktree REPO LANE_SLUG BASE_REF [--path DIR]'; lane_worktree "$@" ;;
  launch) [ "$#" -ge 5 ] || die 'usage: linchpin.sh launch --pid PATH --log PATH [--settle SECONDS] [--cwd DIR] [--stdin FILE] -- COMMAND...'; lane_launch "$@" ;;
  await) [ "$#" -ge 1 ] || die 'usage: linchpin.sh await PIDFILE... [--interval SECONDS] [--timeout SECONDS]'; lane_await "$@" ;;
  route) [ "$#" -ge 1 ] || die 'usage: linchpin.sh route INTENT [SCORE] [PRD ...] [--config-dir DIR]'; route "$@" ;;
  mode) [ "$#" -ge 2 ] || die 'usage: linchpin.sh mode EXECUTION PRD...'; mode_selection "$@" ;;
  schedule) [ "$#" -ge 3 ] || die 'usage: linchpin.sh schedule EXECUTION WORKTREE_STATUS LANE...'; schedule "$@" ;;
  gate) [ "$#" -eq 2 ] || die 'usage: linchpin.sh gate PRD REPORT'; gate_evidence "$1" "$2" ;;
  preflight) [ "$#" -le 1 ] || die 'usage: linchpin.sh preflight [models_cache.json]'; preflight_model "${1:-}" ;;
  *) usage >&2; exit 1 ;;
esac
