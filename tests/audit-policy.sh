#!/bin/sh
. "$(dirname -- "$0")/testlib.sh"

# Whether a batch is worth an expensive independent audit used to be a manager's
# judgement call, made from prose and recorded nowhere. Two runs of the same PRD
# could answer differently, and a batch that shipped without an audit could not
# say afterwards whether it was ineligible or merely forgotten. These are the
# controls for the decision table that replaced the judgement call.

linchpin="$repo_root/scripts/linchpin.sh"
complexity="$fixture_dir/complexity"
config_dir="$tmp_dir/audit-repo"
mkdir -p "$config_dir"

# The shipped default is `auto`, and `auto` is the whole reason the score is read
# at all: one point under the floor is ordinary review, one point over it is an
# audit. This is the pair that decides it.
medium=$(sh "$linchpin" audit "$complexity/medium-score.md" --config-dir "$config_dir")
assert_contains "$medium" 'AUDIT-PRD path='
assert_contains "$medium" 'score=6 class=MEDIUM source=declared-score'
assert_contains "$medium" 'AUDIT-MODE mode=auto source=default'
assert_contains "$medium" 'AUDIT-ELIGIBLE eligible=no'
high=$(sh "$linchpin" audit "$complexity/high-score.md" --config-dir "$config_dir")
assert_contains "$high" 'score=7 class=HIGH source=declared-score'
assert_contains "$high" 'AUDIT-ELIGIBLE eligible=yes'

# The count is per batch, not per PRD: one HIGH lane pulls its interacting
# lower-complexity lanes into the same combined audit.
mixed=$(sh "$linchpin" audit "$complexity/medium-score.md" "$complexity/high-score.md" --config-dir "$config_dir")
assert_contains "$mixed" 'AUDIT-ELIGIBLE eligible=yes'
[ "$(printf '%s\n' "$mixed" | grep -c '^AUDIT-PRD ')" -eq 2 ] ||
  fail 'a two-PRD batch did not report both classifications'

# The creator writes the declaration in bold with an arrow glyph. A PRD written
# by hand writes the same sentence in plain text, and refusing that form would
# send a correctly labelled PRD to an assessment it does not need.
plain=$(sh "$linchpin" audit "$complexity/plain-score.md" --config-dir "$config_dir")
assert_contains "$plain" 'score=8 class=HIGH source=declared-score'
assert_contains "$plain" 'AUDIT-ELIGIBLE eligible=yes'

# A recognized label with no number still classifies the PRD, and the report
# says plainly that no score was supplied.
label=$(sh "$linchpin" audit "$complexity/label-only.md" --config-dir "$config_dir")
assert_contains "$label" 'score=none class=HIGH source=declared-label'
assert_contains "$label" 'AUDIT-DISCREPANCY'
assert_contains "$label" 'a label was declared without a numeric score'
assert_contains "$label" 'AUDIT-ELIGIBLE eligible=yes'

# The score is the evidence and the label is a summary of it, so the score wins
# — visibly. A score-3 PRD labelled HIGH must drop out of `auto` *and* say why.
inconsistent=$(sh "$linchpin" audit "$complexity/inconsistent-label.md" --config-dir "$config_dir")
assert_contains "$inconsistent" 'score=3 class=LOW source=declared-score'
assert_contains "$inconsistent" 'the score wins'
assert_contains "$inconsistent" 'AUDIT-ELIGIBLE eligible=no'

# Malformed, contradictory, and absent declarations are one outcome: the
# orchestrator scores the PRD during bootstrap. None of them is a question for
# the user, and none of them may be frozen as a decision.
for unresolved_fixture in malformed contradictory absent; do
  unresolved_status=0
  unresolved=$(sh "$linchpin" audit "$complexity/$unresolved_fixture.md" \
    --config-dir "$config_dir" --out "$tmp_dir/never-frozen.json") || unresolved_status=$?
  [ "$unresolved_status" -eq 3 ] ||
    fail "$unresolved_fixture complexity did not exit 3 for bootstrap assessment: exit $unresolved_status"
  assert_contains "$unresolved" 'AUDIT-ELIGIBLE eligible=unresolved'
  assert_contains "$unresolved" 'BOOTSTRAP-NEEDS-COMPLEXITY'
  assert_contains "$unresolved" 'do not ask the user to classify routine work'
  [ ! -f "$tmp_dir/never-frozen.json" ] ||
    fail "$unresolved_fixture froze an unresolved eligibility into bootstrap state"
done

# The orchestrator resolves it by scoring with the creator rubric and handing the
# factors back. The assessment is validated, not trusted.
assessed=$(sh "$linchpin" audit "$complexity/absent.md" --config-dir "$config_dir" \
  --assess "$complexity/absent.md=7:files-10-plus,new-module,concurrency-state")
assert_contains "$assessed" 'score=7 class=HIGH source=assessed'
assert_contains "$assessed" 'AUDIT-ASSESSED'
assert_contains "$assessed" 'bootstrap assessment: files-10-plus,new-module,concurrency-state'
assert_contains "$assessed" 'AUDIT-ELIGIBLE eligible=yes'
assessed_low=$(sh "$linchpin" audit "$complexity/absent.md" --config-dir "$config_dir" \
  --assess "$complexity/absent.md=3:files-1-5,new-module")
assert_contains "$assessed_low" 'score=3 class=LOW source=assessed'
assert_contains "$assessed_low" 'AUDIT-ELIGIBLE eligible=no'
expect_failure 'an assessment whose factors do not add up to its score' \
  sh "$linchpin" audit "$complexity/absent.md" --config-dir "$config_dir" \
    --assess "$complexity/absent.md=7:files-1-5,new-module"
# Counting the file set twice is how a single conceptual change is inflated into
# an audited one.
expect_failure 'an assessment counting two file-count factors' \
  sh "$linchpin" audit "$complexity/absent.md" --config-dir "$config_dir" \
    --assess "$complexity/absent.md=4:files-1-5,files-10-plus"
expect_failure 'an assessment naming a factor the rubric does not have' \
  sh "$linchpin" audit "$complexity/absent.md" --config-dir "$config_dir" \
    --assess "$complexity/absent.md=2:feels-hard"

# `on` audits regardless of complexity; `off` is a real refusal and says so, so
# that nothing downstream probes an auditor model this run will never use.
explicit_on=$(sh "$linchpin" audit "$complexity/medium-score.md" --mode on --config-dir "$config_dir")
assert_contains "$explicit_on" 'AUDIT-MODE mode=on source=request'
assert_contains "$explicit_on" 'AUDIT-ELIGIBLE eligible=yes'
explicit_off=$(sh "$linchpin" audit "$complexity/high-score.md" --mode off --config-dir "$config_dir")
assert_contains "$explicit_off" 'AUDIT-MODE mode=off source=request'
assert_contains "$explicit_off" 'AUDIT-ELIGIBLE eligible=no'
assert_contains "$explicit_off" 'no auditor capability check, probe, launch, or audit gate'
# `off` never needs a bootstrap assessment: a run that will not audit does not
# have to classify anything first.
off_absent=$(sh "$linchpin" audit "$complexity/absent.md" --mode off --config-dir "$config_dir")
assert_contains "$off_absent" 'AUDIT-ELIGIBLE eligible=no'

# Precedence: this run's override, then the repository setting, then the shipped
# default. A run-local override never rewrites the repository.
printf '%s\n' 'audit = "off"' > "$config_dir/.linchpin.toml"
config_before=$(cat "$config_dir/.linchpin.toml")
from_config=$(sh "$linchpin" audit "$complexity/high-score.md" --config-dir "$config_dir")
assert_contains "$from_config" 'AUDIT-MODE mode=off source=config'
assert_contains "$from_config" 'AUDIT-ELIGIBLE eligible=no'
override=$(sh "$linchpin" audit "$complexity/high-score.md" --mode on --config-dir "$config_dir")
assert_contains "$override" 'AUDIT-MODE mode=on source=request'
[ "$config_before" = "$(cat "$config_dir/.linchpin.toml")" ] ||
  fail 'a run-local audit override rewrote the repository configuration'
assert_contains "$(sh "$linchpin" config "$config_dir")" 'audit=off'

# An unknown mode fails before anything is launched, from either direction it
# can arrive.
printf '%s\n' 'audit = "sometimes"' > "$config_dir/.linchpin.toml"
expect_failure 'an unknown audit mode in the repository configuration' \
  sh "$linchpin" config "$config_dir"
rm -f "$config_dir/.linchpin.toml"
expect_failure 'an unknown audit mode requested for one run' \
  sh "$linchpin" audit "$complexity/high-score.md" --mode sometimes --config-dir "$config_dir"
# "use an auditor but leave it off" has no defensible reading. One clarification
# beats guessing, in either direction.
expect_failure 'contradictory on and off instructions for the same run' \
  sh "$linchpin" audit "$complexity/high-score.md" --mode on --mode off --config-dir "$config_dir"
contradiction=$(sh "$linchpin" audit "$complexity/high-score.md" --mode on --mode off \
  --config-dir "$config_dir" 2>&1 || true)
assert_contains "$contradiction" 'contradictory audit instructions'
# The same instruction twice is not a contradiction.
sh "$linchpin" audit "$complexity/high-score.md" --mode on --mode on --config-dir "$config_dir" >/dev/null

# A resolved decision is frozen where the runner can read it back, so nothing
# downstream re-derives eligibility from the PRD a second time.
frozen="$tmp_dir/bootstrap.json"
sh "$linchpin" audit "$complexity/high-score.md" "$complexity/medium-score.md" \
  --config-dir "$config_dir" --out "$frozen" >/dev/null
if command -v jq >/dev/null 2>&1; then
  jq -e '.bootstrap_contract == "v1" and .audit.mode == "auto" and .audit.eligible == "yes" and
         (.prds | length) == 2 and (.prds[0].class == "HIGH")' "$frozen" >/dev/null ||
    fail 'frozen bootstrap state does not carry the resolved audit decision'
fi

# A PRD path that is not on disk is the one real blocker, here as everywhere.
expect_failure 'an audit decision for a PRD that is not on disk' \
  sh "$linchpin" audit "$tmp_dir/not-a-prd.md" --config-dir "$config_dir"

# NEGATIVE CONTROL. The decisions above have to come from the wired policy
# module, not from anything the CLI could be printing on its own. Disabling the
# dispatch in an isolated copy must break these same public cases.
disabled="$tmp_dir/policy-disabled"
copy_repo "$disabled"
rm -f "$disabled/scripts/audit-policy.sh"
expect_failure 'the auto decision with policy dispatch removed' \
  sh "$disabled/scripts/linchpin.sh" audit "$complexity/high-score.md" --config-dir "$config_dir"

# The second half of the control: a dispatch that answers without reading the
# mode. `off` is the case that matters, because a wrong answer there spends a
# paid audit the user declined.
ignored="$tmp_dir/policy-mode-ignored"
copy_repo "$ignored"
sed -i.bak 's/audit_policy eligible "\$audit_mode"/audit_policy eligible on/' "$ignored/scripts/linchpin.sh"
rm -f "$ignored/scripts/linchpin.sh.bak"
grep -Fq 'audit_policy eligible on' "$ignored/scripts/linchpin.sh" ||
  fail 'the mode-ignoring control did not patch the audit dispatch'
ignored_off=$(sh "$ignored/scripts/linchpin.sh" audit "$complexity/high-score.md" --mode off --config-dir "$config_dir")
if printf '%s\n' "$ignored_off" | grep -Fq 'eligible=no'; then
  fail 'the mode-ignoring control still refused the audit; the control proves nothing'
fi
printf 'OBSERVED-RED %s\n' 'audit dispatch that ignores the requested mode reports an off run as eligible'

pass 'audit eligibility is a decision table over the declared complexity, with malformed declarations sent to bootstrap assessment'
