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

runtime_value() {
  runtime_role="$1"
  runtime_column="$2"
  awk -F '|' -v target="$runtime_role" -v column="$runtime_column" '
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

runtime_metadata() {
  require_file "$runtime_reference"
  worker_model=$(runtime_value Worker 3)
  worker_effort=$(runtime_value Worker 4)
  worker_mechanism=$(runtime_value Worker 5)
  reviewer_model=$(runtime_value Reviewer 3)
  reviewer_effort=$(runtime_value Reviewer 4)
  reviewer_mechanism=$(runtime_value Reviewer 5)
  [ -n "$worker_model" ] || die 'runtime.md has no Worker model pin'
  [ -n "$worker_effort" ] || die 'runtime.md has no Worker effort pin'
  [ "$worker_mechanism" = 'codex exec' ] || die 'runtime.md Worker mechanism is not codex exec'
  [ -n "$reviewer_model" ] || die 'runtime.md has no Reviewer model pin'
  [ -n "$reviewer_effort" ] || die 'runtime.md has no Reviewer effort pin'
  [ "$reviewer_mechanism" = 'codex exec --sandbox read-only' ] || die 'runtime.md Reviewer mechanism is not read-only codex exec'
  worker_runtime="model=$worker_model; effort=$worker_effort; mechanism=$worker_mechanism"
  reviewer_runtime="model=$reviewer_model; effort=$reviewer_effort; mechanism=$reviewer_mechanism"
  worker_invocation="$worker_mechanism --model $worker_model -c 'model_reasoning_effort=\"$worker_effort\"' -C <lane> <brief>"
  reviewer_invocation="codex exec --model $reviewer_model -c 'model_reasoning_effort=\"$reviewer_effort\"' --sandbox read-only -C <lane> <review>"
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
  resolved_config=$(config_values "$config_dir")
  while IFS='=' read -r config_key config_value; do
    case "$config_key" in
      execution) execution="$config_value" ;;
      delivery) delivery="$config_value" ;;
      base) base="$config_value" ;;
      review) review="$config_value" ;;
      max_lanes) max_lanes="$config_value" ;;
      prd_floor) prd_floor="$config_value" ;;
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
  rule_prohibited='Prohibited actions: native Luna spawning; runtime tier changes; unsafe external install/swap actions'
  rule_scope='Scope rule: change only the files this PRD covers. Do not delete, move, or edit an unrelated file, do not bump an unrelated dependency, and do not bundle unrelated work into this lane. Something outside scope that looks wrong is a note in your report, not an edit. This rule bounds WHAT you change; it never forbids committing what you did change.'
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
  printf 'Worker runtime: %s\n' "$worker_runtime"
  printf 'Reviewer runtime: %s\n' "$reviewer_runtime"
  printf 'Runtime invocation: worker=%s; reviewer=%s\n' "$worker_invocation" "$reviewer_invocation"
  printf 'Lane mode: %s\n' "$lane_mode"
  printf 'Delivery mode: %s\n' "$delivery_mode"
  brief_rules
  printf '%s\n' "$rule_prohibited" "$rule_scope" "$rule_gate" "$rule_commit" "$rule_commit_exception" "$rule_environment"
  if [ "$brief_files_resolved" = no ]; then
    printf '%s\n' 'File-set rule: this PRD declares no machine-readable file set, so establish your own from the PRD prose before you start and list every path you touched in your final summary. Without a resolved file set there is nothing definite to stage, and lanes in that position have ended with correct work left uncommitted.'
  fi
}

review_brief() {
  prd=''
  lane_id=''
  commit_sha=''
  gates_file=''
  brief_out=''
  positional_count=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --gates) [ "$#" -ge 2 ] || die 'review-brief --gates needs a path'; gates_file="$2"; shift 2 ;;
      --commit) [ "$#" -ge 2 ] || die 'review-brief --commit needs a sha'; commit_sha="$2"; shift 2 ;;
      --out) [ "$#" -ge 2 ] || die 'review-brief --out needs a path'; brief_out="$2"; shift 2 ;;
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
  [ -n "$prd" ] || die 'usage: linchpin.sh review-brief PRD LANE_ID --gates PATH --commit SHA [--out PATH]'
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
  if [ -n "$brief_out" ]; then
    review_brief_emit "$prd" "$lane_id" "$commit_sha" "$gates_file" > "$brief_out"
    printf 'REVIEW-BRIEF-WRITTEN %s\n' "$brief_out"
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
  prd="$1"
  brief_file="$2"
  require_file "$prd"
  require_file "$brief_file"
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
  for metadata_prefix in 'Worker runtime:' 'Reviewer runtime:' 'Runtime invocation:' 'Prohibited actions:' 'Scope rule:' 'Commit rule:' 'Commit rule exception:' 'Environment rule:'; do
    metadata_count=$(grep -Fc "$metadata_prefix" "$brief_file" || true)
    [ "$metadata_count" -eq 1 ] || die "worker brief metadata is missing or duplicated: $metadata_prefix"
  done
  require_exact_line "Worker runtime: $worker_runtime" "$brief_file" || die 'worker brief Worker runtime metadata is missing or stale'
  require_exact_line "Reviewer runtime: $reviewer_runtime" "$brief_file" || die 'worker brief Reviewer runtime metadata is missing or stale'
  require_exact_line "Runtime invocation: worker=$worker_invocation; reviewer=$reviewer_invocation" "$brief_file" || die 'worker brief runtime invocation is missing or stale'
  brief_rules
  require_exact_line "$rule_prohibited" "$brief_file" || die 'worker brief prohibited-actions metadata is missing or malformed'
  require_exact_line "$rule_scope" "$brief_file" || die 'worker brief scope rule is missing or malformed'
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
  config_file="$config_dir/.linchpin.toml"
  execution=auto
  delivery=pr
  base=auto
  review=true
  max_lanes=4
  prd_floor=3
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
  printf 'execution=%s\ndelivery=%s\nbase=%s\nreview=%s\nmax_lanes=%s\nprd_floor=%s\n' \
    "$execution" "$delivery" "$base" "$review" "$max_lanes" "$prd_floor"
}

execute_intent='run|execute|start|begin|launch|resume|continue|kick off'

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

preflight_model() {
  runtime_metadata
  cache_path="${1:-${LINCHPIN_MODELS_CACHE:-}}"
  if [ -z "$cache_path" ]; then
    codex_home="${CODEX_HOME:-${HOME:?HOME is required for model preflight}/.codex}"
    cache_path="$codex_home/models_cache.json"
  fi
  require_file "$cache_path"
  command -v jq >/dev/null 2>&1 || die 'jq is required for model preflight'
  jq -e --arg model "$worker_model" '
    .. | objects | select(.slug? == $model) |
    (.multi_agent_version? == "v1")
  ' "$cache_path" >/dev/null || die "worker model or v1 capability missing from $cache_path"
  printf 'PREFLIGHT-PASS worker=%s mechanism=%s reviewer=%s cache=%s\n' "$worker_model" "$worker_mechanism" "$reviewer_mechanism" "$cache_path"
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

usage() {
  cat <<'USAGE'
linchpin.sh COMMAND [ARGS]

  route INTENT [SCORE] [PRD ...] [--config-dir DIR]  classify a request
  contract PRD                                       report every contract problem
  migrate PRD [--out PATH] [--force]                 write a v1 copy; never edits PRD
  brief PRD [LANE_ID LANE_MODE DELIVERY_MODE]        emit the worker brief
        [--out PATH] [--config-dir DIR]
  brief-check PRD BRIEF                              verify a brief against its PRD
  review-brief PRD LANE_ID --gates PATH --commit SHA emit the read-only review brief
        [--out PATH]
  files PRD                                          print the parsed Files (N) list
  mode EXECUTION PRD... [--config-dir DIR]           group lanes by file collision
  schedule EXECUTION STATUS LANE... [--config-dir DIR]
        STATUS: ok | worktree-fail | dirty-tree | unparsed-files | config
  gate PRD REPORT                                    check observed-red evidence
  config [REPO]                                      print resolved .linchpin.toml
  workspace [REPO]                                   make .linchpin/ and ignore run output
  preflight [MODELS_CACHE.json]                      check the worker model
  help                                               this text

EXECUTION is auto, parallel, or sequential.
USAGE
}

command_name="${1:-}"
shift || true
case "$command_name" in
  contract) [ "$#" -eq 1 ] || die 'usage: linchpin.sh contract PRD'; contract_check "$1" ;;
  migrate) [ "$#" -ge 1 ] || die 'usage: linchpin.sh migrate PRD [--out PATH] [--force]'; migrate "$@" ;;
  brief) [ "$#" -ge 1 ] || die 'usage: linchpin.sh brief PRD [LANE_ID LANE_MODE DELIVERY_MODE] [--config-dir DIR]'; brief "$@" ;;
  brief-check) [ "$#" -eq 2 ] || die 'usage: linchpin.sh brief-check PRD BRIEF'; brief_check "$1" "$2" ;;
  review-brief) [ "$#" -ge 1 ] || die 'usage: linchpin.sh review-brief PRD LANE_ID --gates PATH --commit SHA [--out PATH]'; review_brief "$@" ;;
  files)
    [ "$#" -eq 1 ] || die 'usage: linchpin.sh files PRD'
    if ! files_list "$1"; then
      # Silence plus exit 1 reads as a broken helper. Say which of the two it is.
      printf 'NO-FILES-LIST %s has no machine-readable `Files (N)` list; run `mode` for its derived set.\n' "$1" >&2
      exit 1
    fi
    ;;
  help|--help|-h) usage; exit 0 ;;
  config) [ "$#" -le 1 ] || die 'usage: linchpin.sh config [repo]'; config_values "${1:-${LINCHPIN_CONFIG_DIR:-$PWD}}" ;;
  workspace) [ "$#" -le 1 ] || die 'usage: linchpin.sh workspace [repo]'; workspace "${1:-}" ;;
  route) [ "$#" -ge 1 ] || die 'usage: linchpin.sh route INTENT [SCORE] [PRD ...] [--config-dir DIR]'; route "$@" ;;
  mode) [ "$#" -ge 2 ] || die 'usage: linchpin.sh mode EXECUTION PRD...'; mode_selection "$@" ;;
  schedule) [ "$#" -ge 3 ] || die 'usage: linchpin.sh schedule EXECUTION WORKTREE_STATUS LANE...'; schedule "$@" ;;
  gate) [ "$#" -eq 2 ] || die 'usage: linchpin.sh gate PRD REPORT'; gate_evidence "$1" "$2" ;;
  preflight) [ "$#" -le 1 ] || die 'usage: linchpin.sh preflight [models_cache.json]'; preflight_model "${1:-}" ;;
  *) usage >&2; exit 1 ;;
esac
