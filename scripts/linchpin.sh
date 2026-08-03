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
  awk 'NR == 1 && $0 != "---" { exit 1 }
       NR == 2 && $0 != "prd_contract: v1" { exit 1 }
       NR == 3 { if ($0 != "---") exit 1; found = 1; exit }
       END { if (!found) exit 1 }' "$1"
}

section_line() {
  # The first argument is a basic extended regular expression.
  grep -En "$1" "$2" | sed -n '1s/:.*//p'
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

ledger_block() {
  awk '
    /^## ([0-9]+[.] )?Integration Ledger[[:space:]]*$/ { active = 1 }
    active && /^## / && $0 !~ /^## ([0-9]+[.] )?Integration Ledger/ { exit }
    active { print }
  ' "$1"
}

negative_block() {
  awk '
    /^## ([0-9]+[.] )?Negative Controls[[:space:]]*$/ { active = 1 }
    active && /^## / && $0 !~ /^## ([0-9]+[.] )?Negative Controls/ { exit }
    active { print }
  ' "$1"
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
  printf '%s\n' "$clean_field" |
    sed -n 's/^command:[[:space:]]*\([^;][^;]*\);[[:space:]]*result:.*/\1/p' |
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
    [ -n "$expected_result" ] || die "Negative Controls has no result: $gate"
    case "$expected_result" in
      *'RED observed:'*) ;;
      *) die "Negative Controls result lacks RED observed marker: $gate" ;;
    esac
    case "$expected_exit" in
      ''|0|*[!0-9]*) die "Negative Controls result must declare a non-zero exit: $gate" ;;
    esac
    [ "$expected_exit" -gt 0 ] || die "Negative Controls result must declare a non-zero exit: $gate"
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
  prd="$1"
  rows=$(table_row_count "$prd")
  [ "$rows" -gt 0 ] || die "Integration Ledger has no data rows: $prd"
  ledger_block "$prd" | awk -F '|' '
    /^\|[[:space:]]*[0-9]+[[:space:]]*\|/ {
      for (i = 1; i <= NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        gsub(/`/, "", $i)
      }
      if ($4 == "" || $4 ~ /TBD|pending|test\// || ($4 !~ /optional\/unbuilt/ && $4 !~ /:[0-9]+$/)) bad = 1
      if ($7 == "" || $7 ~ /TBD|pending/) bad = 1
    }
    END { if (bad) exit 1 }
  ' || die "ledger row lacks a real caller or negative control: $prd"
}

contract_check() {
  prd="$1"
  require_file "$prd"
  marker_is_valid "$prd" || die "missing or invalid prd_contract: v1 marker: $prd"

  integration_line=$(section_line '^([#][#]) ([0-9]+[.] )?Integration Ledger[[:space:]]*$' "$prd" || true)
  phases_line=$(section_line '^([#][#]) ([0-9]+[.] )?Execution Phases[[:space:]]*$' "$prd" || true)
  negative_line=$(section_line '^([#][#]) ([0-9]+[.] )?Negative Controls[[:space:]]*$' "$prd" || true)
  acceptance_line=$(section_line '^([#][#]) ([0-9]+[.] )?Acceptance Criteria[[:space:]]*$' "$prd" || true)
  checkpoint_line=$(section_line '^([#][#]) ([0-9]+[.] )?Checkpoint [Pp]rotocol[[:space:]]*$' "$prd" || true)
  [ -n "$integration_line" ] || die "missing Integration Ledger: $prd"
  [ -n "$phases_line" ] || die "missing Execution Phases: $prd"
  [ -n "$negative_line" ] || die "missing Negative Controls: $prd"
  [ -n "$acceptance_line" ] || die "missing Acceptance Criteria: $prd"
  [ -n "$checkpoint_line" ] || die "missing Checkpoint Protocol: $prd"

  if [ "$integration_line" -ge "$phases_line" ] ||
     [ "$phases_line" -ge "$negative_line" ] ||
     [ "$negative_line" -ge "$acceptance_line" ] ||
     [ "$acceptance_line" -ge "$checkpoint_line" ]; then
    die "required sections are out of order: $prd"
  fi

  files_list "$prd" >/dev/null || die "one or more Files (N) lists are malformed: $prd"
  validate_ledger "$prd"
  validate_negative_controls "$prd"
  printf 'CONFORMING %s\n' "$prd"
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
  printf '%s\n' "$lane_id" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$' || die 'lane identity is malformed'
  case "$lane_mode" in parallel|sequential) ;; *) die "lane mode must be parallel or sequential: $lane_mode" ;; esac
  case "$delivery_mode" in pr|branch) ;; *) die "delivery mode must be pr or branch: $delivery_mode" ;; esac
  contract_check "$prd" >/dev/null
  runtime_metadata
  printf '%s\n' 'WORKER BRIEF: contract-preserving lane'
  printf 'Source PRD: %s\n' "$prd"
  printf 'Lane identity: %s\n' "$lane_id"
  printf '%s\n' 'Files (N) parsed:'
  files_list "$prd" | sed 's/^/- /'
  printf '%s\n' '' '## Integration Ledger (verbatim)'
  ledger_block "$prd"
  printf '%s\n' '' '## Negative Controls (verbatim)'
  negative_block "$prd"
  printf '%s\n' '' '## Acceptance Criteria (verbatim)'
  awk '
    /^## ([0-9]+[.] )?Acceptance Criteria[[:space:]]*$/ { active = 1 }
    active && /^## / && $0 !~ /^## ([0-9]+[.] )?Acceptance Criteria/ { exit }
    active { print }
  ' "$prd"
  printf '%s\n' '' '## Checkpoint Protocol (verbatim)'
  awk '
    /^## ([0-9]+[.] )?Checkpoint [Pp]rotocol[[:space:]]*$/ { active = 1 }
    active && /^## / && $0 !~ /^## ([0-9]+[.] )?Checkpoint [Pp]rotocol/ { exit }
    active { print }
  ' "$prd"
  printf '%s\n' '' '## Resolved Lane Metadata'
  printf 'Worker runtime: %s\n' "$worker_runtime"
  printf 'Reviewer runtime: %s\n' "$reviewer_runtime"
  printf 'Runtime invocation: worker=%s; reviewer=%s\n' "$worker_invocation" "$reviewer_invocation"
  printf 'Lane mode: %s\n' "$lane_mode"
  printf 'Delivery mode: %s\n' "$delivery_mode"
  printf '%s\n' 'Prohibited actions: native Luna spawning; runtime tier changes; unsafe external install/swap actions'
  printf '%s\n' 'Gate rule: every negative control needs observed-red evidence before delivery.'
}

brief_check() {
  prd="$1"
  brief_file="$2"
  contract_check "$prd" >/dev/null
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
  for metadata_prefix in 'Worker runtime:' 'Reviewer runtime:' 'Runtime invocation:' 'Prohibited actions:'; do
    metadata_count=$(grep -Fc "$metadata_prefix" "$brief_file" || true)
    [ "$metadata_count" -eq 1 ] || die "worker brief metadata is missing or duplicated: $metadata_prefix"
  done
  require_exact_line "Worker runtime: $worker_runtime" "$brief_file" || die 'worker brief Worker runtime metadata is missing or stale'
  require_exact_line "Reviewer runtime: $reviewer_runtime" "$brief_file" || die 'worker brief Reviewer runtime metadata is missing or stale'
  require_exact_line "Runtime invocation: worker=$worker_invocation; reviewer=$reviewer_invocation" "$brief_file" || die 'worker brief runtime invocation is missing or stale'
  require_exact_line 'Prohibited actions: native Luna spawning; runtime tier changes; unsafe external install/swap actions' "$brief_file" || die 'worker brief prohibited-actions metadata is missing or malformed'

  brief_temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/linchpin-brief-check.XXXXXX")
  trap 'rm -rf -- "$brief_temp_dir"' EXIT HUP INT TERM
  ledger_block "$prd" > "$brief_temp_dir/ledger"
  negative_block "$prd" > "$brief_temp_dir/negative"
  awk '
    /^## ([0-9]+[.] )?Acceptance Criteria[[:space:]]*$/ { active = 1 }
    active && /^## / && $0 !~ /^## ([0-9]+[.] )?Acceptance Criteria/ { exit }
    active { print }
  ' "$prd" > "$brief_temp_dir/acceptance"
  awk '
    /^## ([0-9]+[.] )?Checkpoint [Pp]rotocol[[:space:]]*$/ { active = 1 }
    active && /^## / && $0 !~ /^## ([0-9]+[.] )?Checkpoint [Pp]rotocol/ { exit }
    active { print }
  ' "$prd" > "$brief_temp_dir/checkpoint"
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

route() {
  intent=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  [ -n "$intent" ] || die 'route needs an intent'
  shift
  score=
  if printf '%s' "$intent" | grep -Eq 'build|implement'; then
    score="${1:-}"
    [ "$#" -gt 0 ] && shift
  elif printf '%s' "$intent" | grep -Eq 'run|execute' &&
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
  if printf '%s' "$intent" | grep -Eq 'write[[:space:]]+a[[:space:]]+prd'; then
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
  if printf '%s' "$intent" | grep -Eq 'run|execute'; then
    count=$(wc -l < "$prd_list" | tr -d ' ')
    if [ "$count" -eq 0 ]; then
      printf '%s\n' 'ROUTE-EXECUTE-NONE -> ask-once'
      return
    fi
    while IFS= read -r prd; do
      if ! sh "$script_dir/linchpin.sh" contract "$prd" >/dev/null 2>&1; then
        printf '%s\n' 'ROUTE-EXECUTE-UPGRADE -> prd-creator-upgrade'
        return
      fi
    done < "$prd_list"
    printf '%s\n' 'ROUTE-EXECUTE-CONFORMING -> prd-swarm-coordinator'
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
  while IFS= read -r prd; do
    contract_check "$prd" >/dev/null
    files_list "$prd" | sort -u > "$temp_dir/files-$index"
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
  case "$worktree_status" in ok|fail) ;; *) die "worktree status must be ok or fail" ;; esac
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
  if [ "$worktree_status" = fail ]; then
    if [ "$forced_parallel" -eq 1 ]; then
      die 'execution=parallel forced worktrees, but git worktree add failed'
    fi
    printf '%s\n' 'ANNOUNCE: git worktree add failed; this lane group runs sequentially in the shared working tree.'
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
  contract_check "$prd" >/dev/null
  require_file "$report"
  expected_rows=$(negative_data "$prd")
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

command_name="${1:-}"
shift || true
case "$command_name" in
  contract) [ "$#" -eq 1 ] || die 'usage: linchpin.sh contract PRD'; contract_check "$1" ;;
  brief) [ "$#" -ge 1 ] || die 'usage: linchpin.sh brief PRD [LANE_ID LANE_MODE DELIVERY_MODE] [--config-dir DIR]'; brief "$@" ;;
  brief-check) [ "$#" -eq 2 ] || die 'usage: linchpin.sh brief-check PRD BRIEF'; brief_check "$1" "$2" ;;
  files) [ "$#" -eq 1 ] || die 'usage: linchpin.sh files PRD'; files_list "$1" ;;
  config) [ "$#" -le 1 ] || die 'usage: linchpin.sh config [repo]'; config_values "${1:-${LINCHPIN_CONFIG_DIR:-$PWD}}" ;;
  route) [ "$#" -ge 1 ] || die 'usage: linchpin.sh route INTENT [SCORE] [PRD ...] [--config-dir DIR]'; route "$@" ;;
  mode) [ "$#" -ge 2 ] || die 'usage: linchpin.sh mode EXECUTION PRD...'; mode_selection "$@" ;;
  schedule) [ "$#" -ge 3 ] || die 'usage: linchpin.sh schedule EXECUTION WORKTREE_STATUS LANE...'; schedule "$@" ;;
  gate) [ "$#" -eq 2 ] || die 'usage: linchpin.sh gate PRD REPORT'; gate_evidence "$1" "$2" ;;
  preflight) [ "$#" -le 1 ] || die 'usage: linchpin.sh preflight [models_cache.json]'; preflight_model "${1:-}" ;;
  *) die 'commands: contract, brief, files, config, route, mode, schedule, gate, preflight' ;;
esac
