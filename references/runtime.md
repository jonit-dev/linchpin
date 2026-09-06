# Linchpin runtime contract

This file is the only source of provider, model, effort, role, and delegation
pins for the plugin. Skills refer here; they do not copy these values into their
own bodies.

## Role pins

| Role | Provider | Model | Effort | Mechanism | Responsibility |
|---|---|---|---|---|---|
| Manager | current session | current session | current session | the session you are already in | intake, briefs, scheduling, evidence, integration |
| Worker | `codex` | `gpt-5.6-luna` | `max` | `codex exec --sandbox danger-full-access` | implementation, repair, tests, conflict resolution |
| Reviewer | `codex` | `gpt-5.6-sol` | `medium` | `codex exec --sandbox read-only` | one independent review per lane |
| Auditor | `codex` | `gpt-6-astra` | `medium` | `codex exec --sandbox read-only` | one independent audit of the combined batch |

The Manager row pins nothing because there is nothing to pin. The manager is
the interactive session that read the request; this plugin never launches it,
preflight cannot verify it, and no code path could substitute it. The row used
to name `gpt-5.6-sol` at `medium`, and nineteen matched field orchestration
sessions ran something else — not because anything overrode a user's choice,
but because the pin described a launch that does not exist. `preflight` now
reports the manager as the current session instead, so a run records the
session that orchestrated it without claiming to have chosen it.

The Auditor is the batch's last broad independent review, and it is spent by
declared complexity rather than per run — `references/intake.md` owns the
`on`/`off`/`auto` table. It runs on `astra` at `medium` because it reads the
combined result against the original intent, not the code line by line: it
verifies cross-lane behavior, scope completeness, baseline assumptions, and
evidence provenance. It never repeats the lane reviewer's work, never repairs
code, and never approves code written after it ran. There is no automatic model
escalation into it and none out of it — a role that is not resolving is a
refusal by name, exactly as a missing default would be.

Its provider, model, and effort resolve through the same Model aliases table and
the same `.linchpin.toml` keys (`auditor`, `auditor_effort`) as every other
role. Being the auditor is not a licence to pick a model outside the registry.

PRD authoring uses the current session's selected model and effort directly.
There is no separate Author pin or authoring subprocess. Upgrade mode and
gap-filling passes also stay in the current session.

The shipped pins are all `codex`, so a zero-config run is byte-identical to the
single-provider one. A repository puts a different provider on a role by naming
a claude alias in `.linchpin.toml`; the provider is a property of the alias, not
a separate key to keep in sync.

## Model aliases

A repository selects a model by alias, never by raw slug. The alias is the
stable name; the slug moves when the class does, and a slug typed into a config
file is a pin that silently goes stale. The provider travels with the alias:
naming `opus-5` as the worker is what makes that role a Claude Code role.

| Alias | Provider | Model | Effort domain | Native spawning |
|---|---|---|---|---|
| `luna` | `codex` | `gpt-5.6-luna` | `low` `medium` `high` `max` | forbidden — reports `multi_agent_version: "v1"` |
| `sol` | `codex` | `gpt-5.6-sol` | `low` `medium` `high` `max` | permitted by the model; linchpin still uses `codex exec` |
| `terra` | `codex` | `gpt-5.6-terra` | `low` `medium` `high` `max` | permitted by the model; linchpin still uses `codex exec` |
| `astra` | `codex` | `gpt-6-astra` | `low` `medium` `high` `max` | permitted by the model; linchpin still uses `codex exec` |
| `opus-5` | `claude` | `claude-opus-5` | `low` `medium` `high` `xhigh` `max` | not used — linchpin drives `claude -p` |
| `opus-4.8` | `claude` | `claude-opus-4-8` | `low` `medium` `high` `xhigh` `max` | not used — linchpin drives `claude -p` |
| `sonnet-5` | `claude` | `claude-sonnet-5` | `low` `medium` `high` `xhigh` `max` | not used — linchpin drives `claude -p` |
| `haiku-4.5` | `claude` | `claude-haiku-4-5` | `low` `medium` `high` `xhigh` `max` | not used — linchpin drives `claude -p` |
| `fable-5.1` | `claude` | `claude-fable-5-1` | `low` `medium` `high` `xhigh` `max` | not used — linchpin drives `claude -p` |

This table is the shipped, verified list, and the only place in the plugin where
a slug appears. Every Claude id above was probed against the installed Claude
Code CLI on 2026-09-04 with
`claude -p --model <id> --effort low --max-turns 1` and returned normally. The
bare aliases `opus` and `sonnet` also resolve and are deliberately **excluded**:
a floating alias is exactly the stale-pin failure this table exists to prevent.
`gpt-6-astra` was confirmed present in the local codex model cache.

`worker` and `reviewer` in `.linchpin.toml` accept these aliases, and an alias
with no row here is a configuration failure rather than a model request that
reaches the API.

### Hardcoded is the floor, not the ceiling

A name in this table has been checked against a real CLI, so a run that uses it
cannot fail on a slug typo. A user naming a model that is *not* here is still a
normal request, not an error. `scripts/linchpin.sh assign` resolves an unknown
name live — a cache lookup for codex, one probe for claude — and, when it
verifies, mints a row in the repository's `.linchpin-models.toml` so the model
is referred to by alias everywhere downstream. A shipped row always wins over a
repo-local row of the same name.

The invariant that survives is the one that matters: **a slug appears only in an
alias table, and no unverified model ever reaches a lane.** A term that verifies
on neither provider is refused by name; it is never guessed at and never
silently replaced with a fallback model.

## Provider mechanisms

A provider is a launcher plus two mechanisms — one that may write, one that may
not — plus a way to verify a model exists before the run starts. Nothing else
about a role changes.

| | `codex` | `claude` |
|---|---|---|
| Worker mechanism | `codex exec --sandbox danger-full-access` | `claude -p --permission-mode bypassPermissions` |
| Reviewer mechanism | `codex exec --sandbox read-only` | `claude -p --permission-mode plan --disallowed-tools "Edit Write NotebookEdit"` |
| Auditor mechanism | `codex exec --sandbox read-only` | `claude -p --permission-mode plan --disallowed-tools "Edit Write NotebookEdit"` |
| Write access | `--sandbox danger-full-access` | `--permission-mode bypassPermissions` |
| Read-only access | `--sandbox read-only` | `--disallowed-tools "Edit Write NotebookEdit"` |
| Working directory | `-C <lane>` | process cwd (`launch --cwd`) |
| Prompt transport | `"$(cat <brief>)"` argument | stdin (`launch --stdin`) |
| Effort flag | `-c 'model_reasoning_effort="<effort>"'` | `--effort <effort>` |
| Effort domain | `low` `medium` `high` `max` | `low` `medium` `high` `xhigh` `max` |
| Continuation | `codex exec resume <id> -c sandbox_mode="danger-full-access"` | `claude --resume <id> -p` |
| Session id | read out of the subprocess output | pre-generated by the manager (`--session-id`) |
| Preflight | `models_cache.json` lookup | one live `--max-turns 1` probe |

Only these four mechanism strings are accepted. `runtime_metadata` asserts each
role's mechanism cell against the mechanism its resolved provider allows for
that role, so a Worker row carrying a reviewer's mechanism — or a claude role
carrying a codex mechanism — fails before a lane exists rather than at the first
commit.

The Write access and Read-only access rows are what those assertions compare
against, and they are the reason a mechanism cell cannot be quietly "hardened".
A worker mechanism must carry its provider's write-access flag and must not
carry the read-only one; a reviewer mechanism must carry the read-only flag.
Dropping `--sandbox danger-full-access` from the codex Worker cell, or
`--permission-mode bypassPermissions` from the claude one, is refused here
rather than discovered when the lane cannot commit.

Two consequences are worth stating here, because both are otherwise discovered
the expensive way:

1. **Claude Code has no `-C`.** A worker must be started with its cwd already
   inside the lane worktree. `launch --cwd <worktree>` is how; a coordinator
   must not improvise it with a `cd &&` string.
2. **A review packet must not be interpolated.** The run recorded under
   "Invocation shapes" below shell-escaped a packet by hand and read `Reading
   additional input from stdin...` as a review verdict. Claude Code reads its
   prompt from stdin, which removes the hazard entirely for this provider;
   `launch --stdin <review>` is how the packet gets there.

## Delegation rules

1. **Every role runs as a subprocess.** Worker, reviewer, and auditor are all
   started through `scripts/linchpin.sh role-command`, which emits the argv and
   the sandbox together. No role is launched through a native subagent
   mechanism: `agent_type:`, `fork_turns:`, `fork_context:`, `spawn_agent`, and
   any `multi_agent_v<n>__` call are forbidden, and `scripts/verify.sh` fails on
   them appearing in a skill.

   Two independent reasons. Luna reports `multi_agent_version: "v1"` while
   native spawning speaks v2. And a native child inherits the parent's context
   and access: one field manager spawned three `gpt-6-astra` auditors with
   `fork_context: true`, whose prompts said read-only and whose first turn
   contexts said `danger-full-access`. The prompt is not the sandbox.
2. The manager reads this table when launching a worker; it must not substitute
   a different provider, model, effort, or tier of its own accord. The
   legitimate change is a repo-local `worker`, `reviewer`, `worker_effort`, or
   `reviewer_effort` in `.linchpin.toml`, declared by the user before the run
   starts and applied uniformly to every lane, or the same keys written by
   `scripts/linchpin.sh assign --write` from the user's own sentence. That is
   configuration, and preflight verifies every resolved role before any branch
   is created. What this rule forbids is the manager moving a provider, model,
   or tier *during* a run — above all to get past a gate that failed. A run
   reports the providers and models it actually used.
3. A reviewer is launched read-only for its provider: `codex exec --sandbox
   read-only`, or `claude -p --permission-mode plan` with `Edit`, `Write`, and
   `NotebookEdit` denied outright. Either way the reviewer cannot edit, commit,
   push, merge, or repair the lane.
4. Worker, repair, integration, and conflict processes all use the Worker row.
   A failed attempt changes the specification or narrows the handoff; it never
   changes the model tier.
5. The sanctioned continuation is `role-command <role> --resume <session-id>`,
   which emits `codex exec resume <session-id>` for codex and
   `claude --resume <session-id> -p` for claude. A manager records the session
   id and the corrected handoff before continuing. A Claude session id is
   generated by the manager and passed with `--session-id` at launch, so it is
   recorded in the ledger *before* the lane starts rather than scraped out of
   subprocess output afterwards.

   A continuation carries its model and its effort explicitly, not only its
   sandbox. `exec resume` accepts no `--model` flag, so both travel as `-c`
   overrides beside `sandbox_mode`; the shape below shows all three. Resuming
   with a sandbox alone is how one field worker identity recorded Luna at `max`,
   then `gpt-6-astra` at `medium` across implementation and commits, then Luna
   again, inside a single lane — nothing compared the resumed session's runtime
   against the role it was supposed to be.

## Invocation shapes

The role values above are substituted into these shapes at runtime. Which shape
a role takes is decided by its resolved provider, never by the manager.

```text
codex:
<codex> exec --sandbox danger-full-access --model <Worker.Model> -c 'model_reasoning_effort="<Worker.Effort>"' -C <lane> "$(cat <brief-file>)"
<codex> exec --model <Reviewer.Model> -c 'model_reasoning_effort="<Reviewer.Effort>"' --sandbox read-only -C <lane> "$(cat <review-file>)"
<codex> exec --model <Auditor.Model> -c 'model_reasoning_effort="<Auditor.Effort>"' --sandbox read-only -C <repo> "$(cat <audit-file>)"
<codex> exec resume <session-id> -c sandbox_mode="danger-full-access" -c model="<Worker.Model>" -c model_reasoning_effort="<Worker.Effort>"

claude:
<claude> -p --permission-mode bypassPermissions --model <Worker.Model> --effort <Worker.Effort> --session-id <session>   # cwd=<lane>, brief on stdin
<claude> -p --permission-mode plan --disallowed-tools "Edit Write NotebookEdit" --model <Reviewer.Model> --effort <Reviewer.Effort> --session-id <session>   # cwd=<lane>, review packet on stdin
<claude> --resume <session-id> -p
```

`exec resume` has no `--sandbox` flag and no `--model` flag, so a continued
codex worker takes its access, its model, and its effort through `-c`. Resuming
without the sandbox drops the worker back into the default sandbox mid-lane,
where its next commit fails; resuming without the model lets the lane finish as
a different runtime than the one preflight verified.

These shapes are what `scripts/linchpin.sh role-command` emits. Read them here;
do not retype them into a launch. The command prints the resolved provider,
model, effort, and enforced sandbox on a `ROLE-COMMAND` line and the exact argv
as JSON on an `ARGV` line, so a lane's launch and its record are the same
object.

A claude role takes its lane through `launch --cwd <worktree> --stdin <brief>`:
there is no `-C`, and the prompt is never an argument.

Every prompt is a file read at invocation time, the reviewer's included. The
worker prompt is what `scripts/linchpin.sh brief ... --out <brief-file>` wrote
and the reviewer prompt is what `scripts/linchpin.sh review-brief ... --out
<review-file>` wrote. Do not retype or summarize either into a prompt of your
own: a hand-written prompt drops the ledger, the controls, and the scope rule
the brief exists to carry. Do not interpolate the text into the command line
either — a review packet contains backticks, quotes, and pipes, and a manager
that shell-escaped one by hand sent it to `codex` as a mangled argument and then
read `Reading additional input from stdin...` as a model response.

The reviewer is never the worker's continuation. There is exactly one fresh
review per PRD; the worker's row repairs findings and the manager verifies
closure.

## Why the worker is not sandboxed

The codex Worker row carries `--sandbox danger-full-access` because the two
things a lane is *defined* by — a git worktree and a commit — are both
impossible under `codex exec`'s default `workspace-write` sandbox. That sandbox
makes the working directory writable; a worktree's git metadata does not live
there. It lives in the parent repository at `<repo>/.git/worktrees/<slug>/`,
which is outside the writable root, so every lane ends the same way:

```text
fatal: Unable to create '<repo>/.git/worktrees/<slug>/index.lock': Read-only file system
```

The same sandbox denies `bind`/`listen` on a unix socket, including one under
`/tmp`, which is how `tsx` and other Node toolchains talk to their own child
processes:

```text
SOCK_FAIL EPERM listen EPERM: operation not permitted /tmp/probe-5.sock
```

Both were reproduced directly, not inferred: the same probe under
`--sandbox danger-full-access` commits and binds successfully. A worker that
cannot commit produces `PARTIAL` on every lane it is given, and a worker whose
gate commands cannot start reports setup failures where the run needs
verification results. Widening `sandbox_workspace_write.writable_roots` fixes
neither: the socket denial is not a path rule.

The claude Worker row carries `--permission-mode bypassPermissions` for the same
reason and no other: a lane worker that stops to ask about each write cannot
run unattended, and one that is refused a write cannot commit. Its claude
reviewer counterpart runs `--permission-mode plan` with `Edit`, `Write`, and
`NotebookEdit` denied outright, which is the read-only guarantee `--sandbox
read-only` gives on the codex side — a reviewer that can edit what it judges is
not a review.

The bound on the worker is therefore the lane, not the sandbox — its own
worktree, its own branch, the file list in its brief, and a reviewer that cannot
edit what it judges. Do not "harden" a lane by putting a codex worker back under
`workspace-write`, or by dropping a claude worker to `acceptEdits`; that does
not make the run safer, it makes it fail later and less honestly.

## Capability preflight

Preflight branches on each role's resolved provider, and both branches are hard
refusals with no fallback.

**codex.** The preflight reads `$CODEX_HOME/models_cache.json` (or the
explicitly supplied test cache) and looks up each codex role's model. It must
confirm the model exists and declares the `multi_agent_version` capability the
role requires. A missing cache, model, or capability is a refusal.

Preflight also confirms `$CODEX_HOME` is writable whenever a codex role will
run. Every `codex exec` child writes its own session state there before the
model is contacted, so a read-only `$CODEX_HOME` kills the reviewer with `failed
to initialize in-process app-server client` — at the end of a lane, after all
the worker time is already spent. `--sandbox read-only` bounds what the reviewer
may do to the *repository*; it never means the reviewer can run without a
writable `$CODEX_HOME`.

**claude.** Claude Code ships no capability cache, so there is nothing to read.
Preflight instead requires the binary (`${LINCHPIN_CLAUDE_BIN:-claude}`) to be
on PATH and runs exactly one live probe per distinct model slug:

```text
<claude> -p --model <slug> --effort low --max-turns 1 <trivial prompt>
```

A non-zero exit or empty output is a refusal. The probe spends one trivial
request per distinct Claude model in the run; a session that cannot reach the
API fails preflight rather than falling back, and that refusal is the expected
result, not a defect.

`PREFLIGHT-PASS` names every role's provider, model, mechanism, and how it was
verified — `cache=<path>` for a codex role, `probed` for a claude one — so the
line itself says what was checked rather than implying it.
