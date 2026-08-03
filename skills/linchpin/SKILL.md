---
name: linchpin
description: Route PRD creation, upgrade, and execution requests through the linchpin intake contract.
---

# linchpin router

The `references/` directory is at the plugin root, beside `skills/`; from this
file resolve it as `../../references/`. Read `references/intake.md` before dispatch. This skill is a thin entry point;
the intake reference owns the rules. The runtime pins are in
`references/runtime.md`, and the manager uses `scripts/linchpin.sh` for the
machine-checkable preflight, contract, and mode decisions.

## Dispatch table

| Route id | User intent | Precondition | Dispatch |
|---|---|---|---|
| `ROUTE-WRITE-PRD` | "write/draft/author a PRD for X" | none | `prd-creator` |
| `ROUTE-BUILD-SMALL` | "build/implement X" | complexity score <= 2 | refuse pipeline; offer direct edit |
| `ROUTE-BUILD-LARGE` | "build/implement X" | complexity score >= 3 | `prd-creator`, then stop for confirmation |
| `ROUTE-EXECUTE-CONFORMING` | "run/execute/start/begin/launch/resume" | every supplied PRD path exists | `prd-swarm-coordinator` |
| `ROUTE-EXECUTE-UPGRADE` | user explicitly asks to standardize a PRD | any | `migrate`, then `prd-creator` upgrade mode |
| `ROUTE-EXECUTE-NONE` | "run/execute/start" | no PRD supplied, or a supplied path is not on disk | ask once for the PRD path |
| `ROUTE-AMBIGUOUS` | intent cannot be classified | any | ask one short question; never guess |

## Dispatch procedure

1. Identify the user's intent before looking at repository state. `start`,
   `begin`, `launch`, and `resume` are execution verbs. A request naming PRDs
   that already exist is never an authoring request; do not draft a new PRD, a
   companion, or a corrected copy of one. Classify with
   `scripts/linchpin.sh route "<intent>" <prd-path>...` instead of guessing.
2. Compute the complexity score for build/implement requests. Route scores 1–2
   to a direct edit refusal; route scores 3+ to creator and stop for explicit
   confirmation.
3. For execute requests, **run the PRDs the user pointed at, as written.** The
   `prd_contract: v1` standard applies to PRDs Linchpin authors, not to the
   user's own document. A missing marker, a legacy heading, a prose file list, or
   an absent ledger is an `ADVISORY` line — not a blocker, and not a reason to
   rewrite, migrate, or re-draft anything. Hand every supplied path to the
   coordinator. Only run `scripts/linchpin.sh migrate` when the user explicitly
   asks to standardize an artifact. The one real blocker is a path that is not on
   disk: report it and ask once. Never answer an execution request with a
   standards complaint.
4. For conforming inputs, invoke `prd-swarm-coordinator` with all PRDs. One
   input is still one coordinator lane; there is no separate single path.
5. Announce any sequential worktree or delivery fallback before it takes effect.

The direct creator and coordinator skills remain independently discoverable if
this router is removed. The router is not a gate.
