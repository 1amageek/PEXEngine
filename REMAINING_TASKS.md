# PEXEngine Remaining Tasks

Updated: 2026-10-01

Parser, Magic/OpenRCX adapter, correlation, retry, lineage and artifact-verification
slices are implemented. The default engine registers only external extractors;
it does not implement standalone native extraction. The active cross-package
graph is [LSI PROGRESS.md](../PROGRESS.md).

## Remaining tasks

| ID | Priority | Owner | Task | Exit criteria |
|---|---|---|---|---|
| PEX-N1 | P1 | PEXEngine | Implement native process/corner-bound extraction. | Native geometry/connectivity produces canonical RC with analytical success/failure fixtures, exact input provenance, bounded resource behavior and independent extractor correlation. |

## Completed P1 work

| ID | Completed | Evidence |
|---|---|---|
| PEX-1 | 2026-07-26 | Historical parser/adapter verification: workspace run `20260725T212810865980Z` passed 371 tests in 27.6 seconds. This is not current native extraction or production qualification evidence. |

## External prerequisites

Installed OpenROAD/OpenRCX and Magic executables plus exact foundry-authorized
LEF and extraction-rule views are external assets. Their absence remains a
typed blocked state.

| Former ID | Owner | Required evidence |
|---|---|---|
| PEX-2 | PEX qualification workflow | Same-design Magic and OpenRCX corpus reports for selected processes and corners, retaining exact inputs, executable identities, PDK/deck identities, raw outputs, canonical reports, tolerances, and independent backend classification for ToolQualification. |

## Evidence reviewed

- `GOAL_STATUS.md`
- `README.md`, including `Real Data Validation` and `Qualification boundary`
- Parser, adapter, correlation, and artifact contracts
- `Sources` incomplete-implementation marker scan
