---
name: linchpin
description: Route PRD creation, upgrade, and execution requests through the linchpin intake contract.
---

# linchpin router

Read `references/intake.md` before dispatch. This skill is a thin entry point;
the intake reference owns the rules. The runtime pins are in
`references/runtime.md`, and the manager uses `scripts/linchpin.sh` for the
machine-checkable preflight, contract, and mode decisions.

## Dispatch table

| Route id | User intent | Precondition | Dispatch |
|---|---|---|---|
| `ROUTE-WRITE-PRD` | "write a PRD for X" | none | `prd-creator` |
| `ROUTE-BUILD-SMALL` | "build/implement X" | complexity score <= 2 | refuse pipeline; offer direct edit |
| `ROUTE-BUILD-LARGE` | "build/implement X" | complexity score >= 3 | `prd-creator`, then stop for confirmation |
| `ROUTE-EXECUTE-CONFORMING` | "run/execute" | one or more conforming PRDs | `prd-swarm-coordinator` |
| `ROUTE-EXECUTE-UPGRADE` | any execute intent | at least one PRD is non-conforming | `prd-creator` upgrade mode, then re-route |
| `ROUTE-EXECUTE-NONE` | "run/execute" | no PRD supplied or found | ask once for the PRD path |
| `ROUTE-AMBIGUOUS` | intent cannot be classified | any | ask one short question; never guess |

## Dispatch procedure

1. Identify the user's intent before looking at repository state.
2. Compute the complexity score for build/implement requests. Route scores 1–2
   to a direct edit refusal; route scores 3+ to creator and stop for explicit
   confirmation.
3. For execute requests, validate every supplied PRD. Route a non-conforming
   artifact to creator upgrade mode and return to this table only after a
   durable `prd_contract: v1` artifact exists.
4. For conforming inputs, invoke `prd-swarm-coordinator` with all PRDs. One
   input is still one coordinator lane; there is no separate single path.
5. Announce any sequential worktree or delivery fallback before it takes effect.

The direct creator and coordinator skills remain independently discoverable if
this router is removed. The router is not a gate.
