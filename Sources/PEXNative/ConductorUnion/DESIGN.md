# Exact Conductor Union

## Purpose and Scope

This component owns checked, geometry-only rectilinear metal coverage shared by
the sheet-resistance and ground-capacitance components. Its parent is
[PEXNative](../DESIGN.md). It has no child components.

## Responsibilities and Boundaries

The builder admits source rectangles, preserves every source identity and fact,
rejects physical shorts, and produces disjoint bands and exposed boundaries.
Artifact bytes and source grammar are admitted by the host. A source declaration
does not itself establish those external facts. This component has no material,
resistance, capacitance, preferred-direction, or terminal-potential policy.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [PEXNative](../DESIGN.md) | parent | composition | numerical owner | no old analytical-model fabrication |
| [Sheet network](../RectilinearSheetNetwork/DESIGN.md) | used by | checked union | finite sheet/cut network | mesh cuts never become physical perimeter |
| [Ground C](../GroundCapacitance/DESIGN.md) | used by | bands and exposed boundaries | area counted once | geometry independent of provenance and mesh span |
| [Mask decomposition](../../../../swift-mask-data/Sources/MaskGeometry/RectilinearDecomposition/DESIGN.md) | depends on | bounded rectilinear union | exact integer coverage | source attribution is owned here |

## Architecture

```text
source rectangles + explicit finite ledger
    -> identity/range/short admission
    -> owned bounded MaskGeometry union, grouped by net/layer
    -> canonical bands + all overlapping source contributors
    -> exposed boundary subtraction
    -> immutable checked union -> sheet R / ground C
```

## Contracts and Invariants

`NativeConductorUnionBuilding` is the public interface;
`RectilinearConductorUnionBuilder` is its implementation. The returned union has
an internal initializer and is not Codable. It retains source facts by immutable
COW value. Source IDs are unique and nonblank. Exact duplicate geometry with
different source IDs is admitted. Every source fact has SHA-256 identity and a
positive byte range within that artifact. Positive units are caller-supplied.

Bands are canonical physical coverage, independent of input order, record
subdivision, duplicate geometry, and contributor-set boundaries. Each band
retains all source indices having positive area overlap. Contributors do not
claim that each source covers the whole band. Boundaries reference their owning
band and retain that band's contributors. Shared internal faces are absent;
holes and ends remain. Positive-area or positive-length edge contact between
different nets on the same layer is a short. Corner-only contact is not.

## Runtime Flows

Every input traversal, comparison, incidence probe, and boundary fragment is
charged before execution or retained growth. The owned lower union uses finite
input, edge, intermediate, sweep, and output caps; its spent sweep/output counts
are transferred on both success and failure. Standalone calls create one local
ledger. Routed composition borrows one cumulative ledger without reset.

## State, Ownership, and Lifecycle

All mutation is invocation-local value state. No global cache, shared mutable
state, unsafe storage, target-dependent synchronization, or asynchronous owner
is introduced. Checked results retain input source values for their lifetime.

## Failure, Concurrency, and Constraints

Invalid geometry/facts, overflow, shorts, quota exhaustion, and cooperative
cancellation are typed failures. No partial result is published. Logical record,
string, coordinate, contributor, band, boundary, and work caps bound this
algorithm; they are not a process RSS or allocator-wide measurement. Cancellation
is polled at admitted traversal/lower-operation boundaries.

## Verification and Change Impact

`NativeConductorUnionTests` owns analytic rectangle/L area and perimeter, an
independent unit-cell/exposed-edge oracle, holes, shorts, corner contact,
subdivision/order/duplicate invariance, all provenance, quotas, and cancellation.
Sheet and ground consumers must be rechecked when band or boundary semantics
change. Independent numerical qualification remains a separate full-pipeline
obligation.
