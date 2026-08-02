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
      if (entry !~ /^- `[^`]+`[[:space:]]+(- (NEW|EDIT|DELETE|IMPORT):|—[[:space:]]+(NEW|EDIT|DELETE|IMPORT))/) {
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

table_row_count() {
  awk -F '|' '
    /^\|[[:space:]]*[0-9]+[[:space:]]*\|/ { count++ }
    END { print count + 0 }
  ' "$1"
}

negative_row_count() {
  negative_block "$1" | awk -F '|' '
    /^\|/ {
      gsub(/[[:space:]]/, "", $2)
      if ($2 != "" && $2 != "Gate" && $2 !~ /^-+$/) count++
    }
    END { print count + 0 }
  '
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
  [ "$(negative_row_count "$prd")" -gt 0 ] || die "Negative Controls has no data rows: $prd"
  printf 'CONFORMING %s\n' "$prd"
}

brief() {
  prd="$1"
  contract_check "$prd" >/dev/null
  printf '%s\n' 'WORKER BRIEF: contract-preserving lane'
  printf 'Source PRD: %s\n' "$prd"
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
  printf '%s\n' '' 'Gate rule: every negative control needs observed-red evidence before delivery.'
}

brief_check() {
  prd="$1"
  brief_file="$2"
  contract_check "$prd" >/dev/null
  require_file "$brief_file"
  ledger_block "$prd" | while IFS= read -r row; do
    case "$row" in
      \|[[:space:]][0-9]*\|*)
        if ! grep -Fqx "$row" "$brief_file"; then
          die "worker brief omitted ledger row: $row"
        fi
        ;;
    esac
  done
  printf 'BRIEF-PASS all ledger rows transferred\n'
}

config_values() {
  config_dir="${1:-$PWD}"
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
      [ -n "$key" ] || continue
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
  case "$base" in auto|*) ;; esac
  case "$review" in true|false) ;; *) die "review must be true or false" ;; esac
  case "$max_lanes" in *[!0-9]*|0|"") die "max_lanes must be a positive integer" ;; esac
  case "$prd_floor" in *[!0-9]*|"") die "prd_floor must be a non-negative integer" ;; esac
  printf 'execution=%s\ndelivery=%s\nbase=%s\nreview=%s\nmax_lanes=%s\nprd_floor=%s\n' \
    "$execution" "$delivery" "$base" "$review" "$max_lanes" "$prd_floor"
}

route() {
  intent=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  score="${2:-}"
  shift 2 || true
  if printf '%s' "$intent" | grep -Eq 'write[[:space:]]+a[[:space:]]+prd'; then
    printf '%s\n' 'ROUTE-WRITE-PRD -> prd-creator'
    return
  fi
  if printf '%s' "$intent" | grep -Eq 'build|implement'; then
    case "$score" in ''|*[!0-9]*) die 'build intent requires a numeric complexity score' ;; esac
    if [ "$score" -le 2 ]; then
      printf '%s\n' 'ROUTE-BUILD-SMALL -> direct-edit-refusal'
    else
      printf '%s\n' 'ROUTE-BUILD-LARGE -> prd-creator-confirm'
    fi
    return
  fi
  if printf '%s' "$intent" | grep -Eq 'run|execute'; then
    count=$#
    if [ "$count" -eq 0 ]; then
      printf '%s\n' 'ROUTE-EXECUTE-NONE -> ask-once'
      return
    fi
    for prd in "$@"; do
      if ! sh "$script_dir/linchpin.sh" contract "$prd" >/dev/null 2>&1; then
        printf '%s\n' 'ROUTE-EXECUTE-UPGRADE -> prd-creator-upgrade'
        return
      fi
    done
    printf '%s\n' 'ROUTE-EXECUTE-CONFORMING -> prd-swarm-coordinator'
    return
  fi
  printf '%s\n' 'ROUTE-AMBIGUOUS -> ask-once'
}

mode_selection() {
  execution="$1"
  shift
  count=$#
  [ "$count" -gt 0 ] || die 'mode selection needs at least one PRD'
  case "$execution" in auto|parallel|sequential) ;; *) die "invalid execution: $execution" ;; esac

  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/linchpin-mode.XXXXXX")
  trap 'rm -rf "$temp_dir"' EXIT HUP INT TERM
  index=1
  for prd in "$@"; do
    contract_check "$prd" >/dev/null
    files_list "$prd" | sort -u > "$temp_dir/files-$index"
    printf '%s\n' "$prd" > "$temp_dir/label-$index"
    index=$((index + 1))
  done

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
  for root in $roots; do
    member_count=$(awk -v root="$root" '$2 == root { count++ } END { print count + 0 }' "$temp_dir/groups")
    case "$execution" in
      sequential) selected=sequential ;;
      parallel) selected=parallel ;;
      auto) if [ "$member_count" -gt 1 ]; then selected=sequential; else selected=parallel; fi ;;
    esac
    lanes=
    for member in $(awk -v root="$root" '$2 == root { print $1 }' "$temp_dir/groups" | sort -n); do
      label=$(sed -n '1p' "$temp_dir/label-$member")
      if [ -n "$lanes" ]; then lanes="$lanes,$label"; else lanes="$label"; fi
    done
    printf 'group=%s mode=%s lanes=%s\n' "$root" "$selected" "$lanes"
  done
}

schedule() {
  execution="$1"
  worktree_status="$2"
  shift 2
  [ "$#" -gt 0 ] || die 'schedule needs at least one lane'
  case "$execution" in auto|parallel|sequential) ;; *) die "invalid execution: $execution" ;; esac
  case "$worktree_status" in ok|fail) ;; *) die "worktree status must be ok or fail" ;; esac
  if [ "$worktree_status" = fail ] && [ "$execution" = parallel ]; then
    die 'execution=parallel forced worktrees, but git worktree add failed'
  fi
  selected="$execution"
  if [ "$worktree_status" = fail ]; then
    printf '%s\n' 'ANNOUNCE: git worktree add failed; this lane group runs sequentially in the shared working tree.'
    selected=sequential
  elif [ "$execution" = sequential ]; then
    printf '%s\n' 'ANNOUNCE: sequential execution was selected by configuration or collision analysis.'
  fi
  printf 'group=1 mode=%s lanes=%s\n' "$selected" "$(printf '%s,' "$@" | sed 's/,$//')"
}

gate_evidence() {
  prd="$1"
  report="$2"
  contract_check "$prd" >/dev/null
  require_file "$report"
  expected=$(negative_row_count "$prd")
  actual=$(awk -F '|' '
    /^## Gate Evidence[[:space:]]*$/ { active = 1; next }
    active && /^## / { active = 0 }
    active && /^\|/ {
      gate = $2; result = $3; evidence = $4
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", gate)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", result)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", evidence)
      if (gate != "" && gate != "Gate" && gate !~ /^-+$/) {
        count++
        if (result != "PASS" || evidence !~ /RED observed|red evidence|failed as expected|exit [1-9]/) bad = 1
      }
    }
    END { if (count == 0 || bad) exit 1; print count }
  ' "$report" 2>/dev/null) || die 'gate evidence is absent, green-only, or malformed'
  [ "$actual" -eq "$expected" ] || die "gate evidence count $actual does not match negative-control count $expected"
  printf 'GATES-PASS %s controls with observed-red evidence\n' "$actual"
}

preflight_model() {
  require_file "$runtime_reference"
  worker_model=$(awk -F '|' '$2 ~ /Worker/ { value = $3; gsub(/`/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value }' "$runtime_reference")
  worker_mechanism=$(awk -F '|' '$2 ~ /Worker/ { value = $5; gsub(/`/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value }' "$runtime_reference")
  [ -n "$worker_model" ] || die 'runtime.md has no Worker model pin'
  [ "$worker_mechanism" = 'codex exec' ] || die 'runtime.md Worker mechanism is not codex exec'
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
  printf 'PREFLIGHT-PASS worker=%s mechanism=%s cache=%s\n' "$worker_model" "$worker_mechanism" "$cache_path"
}

command_name="${1:-}"
shift || true
case "$command_name" in
  contract) [ "$#" -eq 1 ] || die 'usage: linchpin.sh contract PRD'; contract_check "$1" ;;
  brief) [ "$#" -eq 1 ] || die 'usage: linchpin.sh brief PRD'; brief "$1" ;;
  brief-check) [ "$#" -eq 2 ] || die 'usage: linchpin.sh brief-check PRD BRIEF'; brief_check "$1" "$2" ;;
  files) [ "$#" -eq 1 ] || die 'usage: linchpin.sh files PRD'; files_list "$1" ;;
  config) [ "$#" -le 1 ] || die 'usage: linchpin.sh config [repo]'; config_values "${1:-$PWD}" ;;
  route) [ "$#" -ge 2 ] || die 'usage: linchpin.sh route INTENT SCORE [PRD ...]'; route "$@" ;;
  mode) [ "$#" -ge 2 ] || die 'usage: linchpin.sh mode EXECUTION PRD...'; mode_selection "$@" ;;
  schedule) [ "$#" -ge 3 ] || die 'usage: linchpin.sh schedule EXECUTION WORKTREE_STATUS LANE...'; schedule "$@" ;;
  gate) [ "$#" -eq 2 ] || die 'usage: linchpin.sh gate PRD REPORT'; gate_evidence "$1" "$2" ;;
  preflight) [ "$#" -le 1 ] || die 'usage: linchpin.sh preflight [models_cache.json]'; preflight_model "${1:-}" ;;
  *) die 'commands: contract, brief, files, config, route, mode, schedule, gate, preflight' ;;
esac
