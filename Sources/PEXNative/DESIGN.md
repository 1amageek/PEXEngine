# PEXNative

## Purpose and Scope

Native CPU sheet/cut electrical calculation over owned, occurrence-exact layout facts.
Parent: [PEXEngine](../../DESIGN.md). Children: [SheetExtraction](SheetExtraction/DESIGN.md) and [ElectrodeConstruction](ElectrodeConstruction/DESIGN.md).
The module boundary keeps layout dependencies out of PEXCore.

## Responsibilities and Boundaries

Owns conforming discretization, numeric graph construction and explicit electrode contact construction. Canonical net assignment and ParasiticIR projection compose these lower contracts; standard file loading, adapter execution, artifact persistence, process qualification and release gates remain separately owned.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [PEXEngine](../../DESIGN.md) | parent | Domain extraction ownership | Native calculation product | Calculation alone is not a successful backend run |
| [PEXCore](../PEXCore/DESIGN.md) | depends on | Exact-corner electrical inputs | Admitted SI law | Calibration identity does not establish trust |
| [ConductorCapture](../../../semiconductor-layout/Sources/LayoutVerify/ConductorCapture/DESIGN.md) | depends on | Owned integer coverage, units and contacts | Actual geometry input | No aggregate-via or net-label shortcut |
| [ElectrodeConstruction](ElectrodeConstruction/DESIGN.md) | child | Explicit exposed electrode faces and contact operators | Terminal boundary construction | Pin annotation alone cannot impose a potential |
| [SheetExtraction](SheetExtraction/DESIGN.md) | child | Bounded graph calculation | Numeric implementation | Resolution is an explicit input |

## Architecture

```mermaid
flowchart LR
  Capture[Conductor snapshot] --> SheetExtraction
  Model[PEXCore admitted SI model] --> SheetExtraction
  Resolution[Explicit mesh span and resource limits] --> SheetExtraction
  SheetExtraction --> Network[Nodes, resistors, capacitors, pin incidence]
  Network --> Electrodes[Explicit sheet electrode construction]
  Electrodes --> Adapter[Canonical projection and backend composition]
```

## Contracts and Invariants

The graph contains the actual union of captured metal and individual cut regions.
Coordinate scale comes from `snapshot.coordinateUnits`, not caller-supplied units
or the raw hierarchy grid. The capture owner may refine the band grid for stroke
half-width boundaries while retaining the original hierarchy units.
Every floating region and disconnected labeled component remains distinct. A graph
does not invent physical connections to satisfy a net label or pin name.

## Verification and Change Impact

[PEXNativeTests](../../Tests/PEXNativeTests) owns numerical operators and admission behavior. Runtime composition
and terminal observables remain B3.3-owned; independent correlation is B3.4/B8-owned.
All verification is native CPU. No Metal/WASM/Embedded or production trust is inferred.
