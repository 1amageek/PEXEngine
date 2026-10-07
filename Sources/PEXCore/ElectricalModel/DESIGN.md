# ElectricalModel

## Purpose and Scope

Explicit SI electrical inputs for calibrated rectilinear-sheet extraction.
Parent: [PEXCore](../DESIGN.md). No children.

## Responsibilities and Boundaries

Owns model law, exact process/corner/PVT identity, declared dimensional applicability,
coefficient admission and calibration artifact identity. Does not load calibration
files, invent coefficients, qualify a process, solve a field, or select a fallback.
Calibration identity alone is not evidence of calibration correctness: retained bytes,
independent correlation and trust admission remain runtime/ToolQualification concerns.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [PEXCore](../DESIGN.md) | parent | TechnologyIR, PEXCorner | Exact model selection | Legacy temperature is Celsius; convert explicitly to kelvin |
| [PEXEngine](../../../DESIGN.md) | used by | Captured inputs and request hash | Decode and retain model inputs | A model is not a successful extraction |

## Architecture

```mermaid
flowchart LR
  Input["TechnologyIR.electricalModels"] --> Admission["Identity / topology / SI / evidence admission"]
  Admission --> Selection["Exact corner + PVT + parameters"]
  Selection --> Dimensions["Declared width / length / cut / gap ranges"]
  Dimensions --> Calculation["RC calculation owner"]
  Admission --> Failure["Typed failure; no fallback"]
```

## Contracts and Invariants

The law is selected explicitly. `analyticalRectilinearV1` declares isotropic sheet
resistance `rho / thickness`, independent ground area/perimeter capacitance,
per-cut via resistance, and visible interlayer overlap/facing-patch fringe
`areaCoefficient * overlapArea + sidewallCoefficient * exposedPatchPerimeter / verticalGap`.
Its coplanar coupling is `sidewallCoefficient * parallelLength / gap`.
This is an analytical approximation without substrate shielding by other planes.

`singlePlaneCoplanarGroundV1` has exactly one conductor, one self pair with a zero
area coefficient, no cut/via, and a continuous implicit reference. It requires
explicit `coplanarScreening` SI parameters: nonnegative offset, positive interaction
halo, and nonnegative ground-fringe inverse length. The caller supplies retained
calibration identities; source-derived coefficients remain an approximation, not
foundry qualification. This version owns the Magic 8.3.652 source algebra
`s(g) = 0.6366 * atan(groundFringeInverseMeters * g)` for an interacting exposed
edge. The owner retains `perimeterCoefficient * length * s(g)` ground fringe,
while the unordered edge pair adds `sidewallCoefficient * length / (g + offset)`.
Outside the strictly open halo (`g < halo`) there is no pair operator or fringe
consumption. Unblocked edges retain full ground fringe. Area ground capacitance
is counted once. The full pair coefficient is not halved; directional accumulation
in the reference implementation accounts for its own half coefficients.

`coplanarScreening` is present only for the single-plane law; the analytical law
requires explicit nil at the Swift construction boundary. Decoding the former law
without its parameters, or combining either law with incompatible parameters,
fails admission. The removed `rectilinearSheetV1` spelling has no alias.
Calculation additionally rejects any reachable source shape outside the modeled
plane and all via records, including geometry excluded from selected footprints.
Unknown source roles are unsupported rather than inferred as noninteracting.
The approximation is not an electromagnetic solver.

`PEXElectricalModel.domainDigest()` owns the per-model numerical domain identity.
It SHA-256 hashes sorted-key JSON of the same model value after sorting conductors,
vias, calibration content identities, and unordered layer pairs with canonical
orientation. Every law/SI parameter, process/corner/PVT/parameter/reference,
coefficient/applicability interval and calibration identity participates. Layout,
run, corner-subset selection and native configuration do not. The existing Core
SHA-256 primitive is reused; callers do not copy the normalization/hash algorithm.
Catalog admission validates TechnologyIR before comparing this identity. Digest
equality proves model membership, not foundry accuracy or process calibration.
Qualified rule-deck and process-profile scope digests remain raw-file SHA-256 values;
they are not replaced by this numerical identity.
Calculation must use exact union coverage, distinguish exposed from internal edges,
respect the calibrated dimensional ranges and reject unsupported geometries. These
calculation obligations are B3.2.3-owned and not established by this input component.

| Input | Unit / admission |
|---|---|
| Temperature / supply | kelvin > 0 / volts >= 0, finite; exact requested PVT when supplied |
| Metal thickness / resistivity | meters / ohm meters > 0, finite, finite positive quotient |
| Metal bottom height | meters >= 0, finite; nonoverlapping height intervals in stack order |
| Ground area / perimeter coefficients | farads per square meter / farads per meter >= 0, finite |
| Via coefficient | ohms per individual cut > 0, finite; no aggregate-via shortcut |
| Pair area / sidewall coefficients | farads per square meter / farads >= 0, finite |
| Coplanar offset / interaction halo | meters >= 0 / meters > 0, finite; halo is distinct from gap applicability |
| Ground-fringe multiplier | inverse meters >= 0, finite; never inferred from another SI coefficient |
| Dimensional interval | closed meter interval, finite positive ordered endpoints |
| Calibration artifacts | distinct nonempty SHA-256 ArtifactID content identities with nonzero byte counts |

Models must name exactly the technology process and a unique nonempty corner.
Every stack layer is either a modeled conductor or a declared cut layer; each via
names an existing cut strictly between its bottom and top conductors in stack order.
Every declared technology via has exactly one electrical model. One cut layer may register alternative bottom materials with the same top conductor; conflicting top conductors fail admission. Model admission does not choose an alternative from geometry: SheetExtraction owns actual contacted material-set equality, full electrode coverage and unique per-cut law selection. Every unordered
conductor pair, including self pairs, declares coefficients explicitly; zero is a
declared coefficient, never a missing-value substitute. Parameter dictionaries match
the requested corner exactly. Unknown pairs, layers, vias, corners or ranges fail.

`TechnologyIRValidator` exposes semantic issues to the CLI; `TechnologyResolver`
admits supplied electrical models on both inline and captured JSON paths; native
selection repeats admission for direct library callers. Missing models remain valid
external-deck metadata but cannot satisfy native selection. Unused ambiguous thickness,
resistivity and aggregate via-resistance APIs are removed; JSON containing those keys
fails decoding. There is no automatic unit conversion or compatibility fallback.
The Xcircuite/studio callers still pinned to the previous PEX revision migrate with
the exact dependency update during B3.3 composition, before cumulative integration.

## State, Ownership, and Lifecycle

All public model values are immutable and Sendable. Validation sets and dictionaries
are call-local. No shared mutable state, target-conditioned isolation or lifecycle
resource is introduced. Calibration artifact identities are content values, not paths.

## Failure, Concurrency, and Constraints

Admission returns typed errors with model/field identity. No partially admitted model
or default corner escapes. Pair completeness is checked by counting unique known
unordered pairs, avoiding an additional quadratic enumeration. Input collection and
calculation work limits are enforced by their execution owners, not inferred here.

## Verification and Change Impact

`PEXCoreTests/PEXElectricalModelTests` covers SI arithmetic, PVT/parameter selection,
missing models, duplicate/unknown topology, invalid coefficients/ranges, explicit
pair coverage, JSON round-trip and coefficient/calibration request-hash invalidation.
`PEXRuntimeTests/PEXElectricalModelResolutionTests` rejects invalid inline and JSON
models before backend execution. Verification is native CPU only. This evidence does
not qualify a foundry process, WASM/Embedded target or native extraction backend.
`PEXNativeTests/NativePEXScreenedCapacitanceTests` owns source-law positive and
negative behavior, nearest-neighbor ownership, halo boundary, exact geometry units,
mesh refinement, same-net distinct nodes, and bounded atomic failure. Law/schema
changes require fixture migration and adapter producer/algorithm identity updates.
