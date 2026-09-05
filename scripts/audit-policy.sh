#!/bin/sh
# Audit eligibility, as deterministic code rather than a manager's judgement.
#
# The behavior this replaces: a manager decided per run whether an expensive
# independent auditor was worth launching, from prose, with no record of why.
# Two runs of the same PRD got different answers, and a batch that skipped the
# audit could not say afterwards whether it was ineligible or merely forgotten.
# Eligibility is a decision table over one number the PRD already declares, so
# it belongs here, where it costs nothing and can be tested.
#
# Subcommands, so a caller reads one answer instead of this file's source:
#   declaration PRD          score/label/source/discrepancy out of a PRD
#   classify SCORE           LOW | MEDIUM | HIGH, on the creator's thresholds
#   assess SCORE FACTORS     validate a bootstrap assessment against the rubric
#   eligible MODE CLASS...   the mode table, over a whole batch
set -eu

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# The creator's rubric, in one place: `skills/prd-creator/SKILL.md` Step 0 and
# `references/prd-contract.md` state the same thresholds in prose. A second
# hardcoded copy of "7 or greater is HIGH" is how the shipped default and the
# documented default stop agreeing.
audit_high_floor=7
audit_medium_floor=4

classify_score() {
  case "$1" in
    ''|*[!0-9]*) die "complexity score is not a non-negative integer: $1" ;;
  esac
  if [ "$1" -ge "$audit_high_floor" ]; then
    printf 'HIGH\n'
  elif [ "$1" -ge "$audit_medium_floor" ]; then
    printf 'MEDIUM\n'
  else
    printf 'LOW\n'
  fi
}

declaration_lines() {
  # The creator writes `**Complexity: 7 → HIGH mode**`. A hand-written PRD
  # writes the same sentence without the bold markers, and one that was pasted
  # out of a terminal writes `->` for the arrow. All three are the same
  # declaration; refusing two of them would send a correctly labelled PRD to a
  # bootstrap assessment it does not need.
  sed -n 's/^[[:space:]]*\*\{0,2\}[Cc]omplexity:[[:space:]]*//p' "$1" |
    sed 's/\*\{1,2\}[[:space:]]*$//; s/[[:space:]]*$//'
}

normalize_declaration() {
  # `7 → HIGH mode`, `7 -> high`, and `7 → HIGH` all normalize to `7 HIGH`, so
  # two declarations are compared on what they say and not on how they are
  # punctuated.
  # The trailing newline is not cosmetic: this is called once per declaration
  # inside a loop whose output is deduplicated, and without it two declarations
  # concatenate into one line that reads as a single malformed value.
  printf '%s\n' "$1" |
    sed 's/→/ /g; s/->/ /g' |
    tr '[:lower:]' '[:upper:]' |
    sed 's/[[:space:]]\{1,\}/ /g; s/ MODE$//; s/^ //; s/ $//'
}

emit_declaration() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
}

declaration() {
  [ -f "$1" ] || die "missing file: $1"
  declaration_raw=$(declaration_lines "$1")
  if [ -z "$declaration_raw" ]; then
    emit_declaration none none absent 'no complexity declaration in the PRD'
    return 0
  fi
  # Contradiction is its own answer. A PRD that declares 7 in its header and 4
  # in a later section has no declared complexity, and picking the first one
  # would freeze whichever the author edited last.
  declaration_distinct=$(
    printf '%s\n' "$declaration_raw" | while IFS= read -r declaration_one; do
      [ -n "$declaration_one" ] || continue
      normalize_declaration "$declaration_one"
    done | sort -u
  )
  declaration_count=$(printf '%s\n' "$declaration_distinct" | awk 'NF' | wc -l | tr -d ' ')
  if [ "$declaration_count" -gt 1 ]; then
    emit_declaration none none malformed "the PRD declares complexity more than once and the declarations disagree: $(printf '%s' "$declaration_distinct" | tr '\n' '/' | sed 's#/$##')"
    return 0
  fi
  declaration_value=$(printf '%s\n' "$declaration_distinct" | awk 'NF { print; exit }')
  declaration_score=$(printf '%s' "$declaration_value" | awk '{ print $1 }')
  declaration_label=$(printf '%s' "$declaration_value" | awk '{ print $2 }')
  case "$declaration_score" in
    ''|*[!0-9]*)
      # A word where the score should be is not a score. `Complexity: HIGH` is
      # the one exception: a recognized label with no number is a declared
      # classification, recorded as one that supplied no score.
      case "$declaration_score" in
        LOW|MEDIUM|HIGH)
          [ -z "$declaration_label" ] ||
            {
              emit_declaration none none malformed "complexity declaration is not a score or a bare label: $declaration_value"
              return 0
            }
          emit_declaration none "$declaration_score" declared-label 'a label was declared without a numeric score'
          return 0
          ;;
        *)
          emit_declaration none none malformed "complexity declaration is not a number or a LOW/MEDIUM/HIGH label: $declaration_value"
          return 0
          ;;
      esac
      ;;
  esac
  declaration_class=$(classify_score "$declaration_score")
  if [ -z "$declaration_label" ]; then
    emit_declaration "$declaration_score" "$declaration_class" declared-score 'none'
    return 0
  fi
  case "$declaration_label" in
    LOW|MEDIUM|HIGH) ;;
    *)
      emit_declaration "$declaration_score" "$declaration_class" declared-score \
        "score $declaration_score classifies $declaration_class; the declared label '$declaration_label' is not LOW, MEDIUM, or HIGH"
      return 0
      ;;
  esac
  if [ "$declaration_label" != "$declaration_class" ]; then
    # The number is the evidence and the label is the summary of it, so the
    # number wins. Silently preferring it is the part that would go wrong: a
    # score-4 PRD labelled HIGH would drop out of `auto` with no trace of why.
    emit_declaration "$declaration_score" "$declaration_class" declared-score \
      "score $declaration_score classifies $declaration_class but the PRD label says $declaration_label; the score wins"
    return 0
  fi
  emit_declaration "$declaration_score" "$declaration_class" declared-score 'none'
}

factor_weight() {
  # The creator rubric, with the file-count contributions mutually exclusive.
  # Counting `files-1-5` beside `files-10-plus` is the "same category twice"
  # inflation the PRD names, so the caller may name at most one of them.
  case "$1" in
    files-1-5) printf '1\n' ;;
    files-6-10) printf '2\n' ;;
    files-10-plus) printf '3\n' ;;
    new-module) printf '2\n' ;;
    concurrency-state) printf '2\n' ;;
    multi-package) printf '2\n' ;;
    database-schema) printf '1\n' ;;
    external-api) printf '1\n' ;;
    *) return 1 ;;
  esac
}

assess() {
  [ "$#" -ge 2 ] || die 'usage: audit-policy.sh assess SCORE FACTOR[,FACTOR...]'
  assess_score="$1"
  assess_factors=$(printf '%s' "$2" | tr ',' ' ')
  case "$assess_score" in
    ''|*[!0-9]*) die "assessed complexity score is not a non-negative integer: $assess_score" ;;
  esac
  [ -n "$(printf '%s' "$assess_factors" | tr -d '[:space:]')" ] ||
    die 'a bootstrap assessment records the factors that justified its score; none were supplied'
  assess_total=0
  assess_files=0
  assess_seen=''
  for assess_factor in $assess_factors; do
    assess_weight=$(factor_weight "$assess_factor") ||
      die "unknown complexity factor: $assess_factor (files-1-5, files-6-10, files-10-plus, new-module, concurrency-state, multi-package, database-schema, external-api)"
    for assess_previous in $assess_seen; do
      [ "$assess_previous" != "$assess_factor" ] ||
        die "complexity factor counted twice: $assess_factor"
    done
    assess_seen="$assess_seen $assess_factor"
    case "$assess_factor" in
      files-*) assess_files=$((assess_files + 1)) ;;
    esac
    assess_total=$((assess_total + assess_weight))
  done
  [ "$assess_files" -le 1 ] ||
    die 'the file-count contribution is mutually exclusive; name exactly one of files-1-5, files-6-10, files-10-plus'
  [ "$assess_total" -eq "$assess_score" ] ||
    die "assessed score $assess_score is not the sum of its factors ($assess_total); an assessment that does not add up is not evidence"
  printf 'ASSESS-OK score=%s class=%s factors=%s\n' \
    "$assess_score" "$(classify_score "$assess_score")" "$(printf '%s' "$assess_seen" | sed 's/^ //; s/ /,/g')"
}

eligible() {
  [ "$#" -ge 1 ] || die 'usage: audit-policy.sh eligible MODE [CLASS ...]'
  eligible_mode="$1"
  shift
  case "$eligible_mode" in
    on|off|auto) ;;
    *) die "audit mode must be on, off, or auto: $eligible_mode" ;;
  esac
  eligible_high=0
  eligible_unknown=0
  eligible_total=0
  for eligible_class in "$@"; do
    eligible_total=$((eligible_total + 1))
    case "$eligible_class" in
      HIGH) eligible_high=$((eligible_high + 1)) ;;
      MEDIUM|LOW) ;;
      UNKNOWN) eligible_unknown=$((eligible_unknown + 1)) ;;
      *) die "unknown complexity classification: $eligible_class" ;;
    esac
  done
  [ "$eligible_total" -gt 0 ] || die 'eligibility is decided over a batch; no PRD classification was supplied'
  case "$eligible_mode" in
    off)
      # Off is a real refusal, not a low threshold: nothing downstream may probe
      # the auditor model, so an unavailable auditor cannot fail this run.
      printf 'eligible=no\treason=audit is off for this run; no auditor capability check, probe, launch, or audit gate\n'
      ;;
    on)
      printf 'eligible=yes\treason=audit is on for this run; one batch audit is required at its checkpoint regardless of complexity\n'
      ;;
    auto)
      if [ "$eligible_unknown" -gt 0 ]; then
        # Not a question for the user. The orchestrator scores the PRD with the
        # creator rubric during bootstrap and records the factors; defaulting to
        # LOW here is the silent miss this mode exists to prevent.
        printf 'eligible=unresolved\treason=%s of %s PRD(s) declare no usable complexity; assess them during bootstrap before freezing eligibility\n' \
          "$eligible_unknown" "$eligible_total"
        return 0
      fi
      if [ "$eligible_high" -gt 0 ]; then
        printf 'eligible=yes\treason=%s of %s PRD(s) classify HIGH (score %s or greater); audit the eligible lanes and their interacting integration scope together\n' \
          "$eligible_high" "$eligible_total" "$audit_high_floor"
      else
        printf 'eligible=no\treason=no PRD in this batch classifies HIGH (score %s or greater); ordinary review only\n' \
          "$audit_high_floor"
      fi
      ;;
  esac
}

audit_policy_command="${1:-}"
[ "$#" -eq 0 ] || shift
case "$audit_policy_command" in
  declaration) [ "$#" -eq 1 ] || die 'usage: audit-policy.sh declaration PRD'; declaration "$1" ;;
  classify) [ "$#" -eq 1 ] || die 'usage: audit-policy.sh classify SCORE'; classify_score "$1" ;;
  assess) assess "$@" ;;
  eligible) eligible "$@" ;;
  high-floor) printf '%s\n' "$audit_high_floor" ;;
  *) die "usage: audit-policy.sh declaration|classify|assess|eligible|high-floor ..." ;;
esac
