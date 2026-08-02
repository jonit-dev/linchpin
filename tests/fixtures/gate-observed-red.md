Mode: parallel

## Gate Evidence

| Gate | Result | Observed-red evidence | Exact command/result |
|---|---|---|---|
| contract | PASS | RED observed: marker removed | `command: sh tests/contract-conformance.sh`; result: RED observed: marker removed; exit: 1 |
| brief | PASS | RED observed: ledger row removed | `command: sh tests/brief-contains-ledger.sh`; result: RED observed: ledger row removed; exit: 1 |
