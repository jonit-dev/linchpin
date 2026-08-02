---
prd_contract: v1
---

# Fixture PRD

## Integration Ledger

| # | New thing | Live caller (`file:line`, non-test) | Replaces | Old path removed? | Negative control |
|---|---|---|---|---|---|
| 1 | contract parser | `scripts/linchpin.sh:100` | ad-hoc parsing | deleted | remove marker; parser exits non-zero |
| 2 | brief transfer | `skills/prd-swarm-coordinator/SKILL.md:60` | short checklist | delegated | remove a ledger row; brief exits non-zero |

## 4. Execution Phases

### Phase 1: Contract

**Files (2):**

- `src/alpha.md` - NEW: fixture subject
- `src/shared.md` - EDIT: fixture caller

**Implementation:**

- [ ] Add the contract.
- [ ] Verify the transfer.

### Phase 2: Runtime

**Files (1):**

- `scripts/linchpin.sh` - EDIT: run the parser

**Implementation:**

- [ ] Run the helper.

## Negative Controls

| Gate | Negative control | Expected red | Exact command/result |
|---|---|---|---|
| contract | remove the marker | parser exits non-zero | `command: sh tests/contract-conformance.sh`; result: RED observed: removed marker; exit: 1 |
| brief | remove ledger row 2 | brief generation exits non-zero | `command: sh tests/brief-contains-ledger.sh`; result: RED observed: removed ledger row; exit: 1 |

## Acceptance Criteria

- [ ] The marker and required sections parse.
- [ ] The complete ledger appears in the worker brief.

## Checkpoint Protocol

Run the contract, brief, and gate commands. Record every expected non-zero
negative-control result before declaring the fixture delivered.
