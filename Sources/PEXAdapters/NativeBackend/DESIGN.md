# NativeBackend

## Purpose and Scope
Composes captured standard layout and admitted configuration through actual native geometry, RC, electrodes and canonical projection. Parent: [PEXAdapters](../DESIGN.md). No children. Default registration and standard exporters are separate work.

## Responsibilities and Boundaries
Owns backend invocation, measured image stability, bounded input loading, asynchronous cancellation delivery into synchronous calculation and retained typed physical-topology evidence. Persistence and run orchestration consume the existing PEXExtracting result/failure contracts. Process calibration identity is required but never self-qualified.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [PEXAdapters](../DESIGN.md) | parent | Backend ownership | Native CPU implementation | No external fallback |
| [PEXNative](../../PEXNative/DESIGN.md) | depends on | Input preparation, numerical/electrode/projection contracts | Actual calculation | Preserve complete operators and opens/shorts |
| [CodeImage](../../PEXNative/CodeImage/DESIGN.md) | depends on | Actual loaded implementation backing identity | SHA-256 and UUID observation | Not relocated memory attestation |
| [NativeInputCapture](../../PEXPersistence/NativeInputCapture/DESIGN.md) | depends on | Bounded captured configuration/calibration | Exact run inputs | Content identity is not physical qualification |
| [PEXRuntime](../../PEXRuntime/DESIGN.md) | used by | Typed canonical result and retained failure artifacts | Public run lifecycle | Required output exporters remain separately owned |

## Architecture
```mermaid
flowchart LR
  Context[Captured execution context] --> Identity[Measure loaded native code image]
  Identity --> Inputs[Bounded configuration + standard layout]
  Inputs --> Capture[Exact conductor capture]
  Capture --> RC[Native calculation]
  RC --> Electrode[Explicit electrode construction]
  Electrode --> Project[Exact scoped canonical projection]
  Project --> Evidence[Physical topology + identity evidence]
  Evidence --> Stability[Recheck implementation image]
  Stability --> Result[Validated canonical result]
  Failure[Failure or cancellation] --> Retain[Observed identity + completed evidence only]
```

## Contracts and Invariants
The default adapter constructor uses a statically admitted positive policy. Configurable construction validates all byte ceilings and polling duration. PEXDefaultBackends registers this actual adapter without requiring CLI callers to construct a private registry. Backend selection remains explicit; registration does not assign process trust.

No success fallback exists. Unsupported formats/options fail explicitly. Initial implementation admits exact GDS/OASIS, full RC with coupling, and no operator threshold reduction; other modes remain unsupported until meaningfully implemented. Exact selected model calibration IDs must be present and hash/count verified even for direct adapter invocation. Native topology version 3 retains the exact LayoutVerify-owned electrical context; configuration version 3 binds the same interpretation and explicit durable net selectors through captured content identity before publication. [InputPreparation](../../PEXNative/InputPreparation/DESIGN.md) resolves selectors after actual standard import and capture; this adapter passes only prepared snapshot-local bindings to projection. Legacy topology and configuration versions fail decoding. Native evidence preserves occurrence indices/source paths, physical component footprint membership, pin incidence, opens/shorts, numeric node-to-canonical references, explicit electrode contacts and operator identity mapping. Imported transient UUIDs are observations, not semantic request identity. The canonical IR retains every native operator.
The runtime compiler identity is explicitly unavailable, not inferred from the numerical law; verification build provenance records the actual toolchain. The producer build is the measured native backing-file digest, invocation is in-process, and before/after image observations must agree. Caller executable/environment overrides are rejected because no external process is invoked. Failure retains the actual measured identity and already completed artifacts, with no partial canonical result.
The producer version is `3.0.0`; its algorithm-environment fingerprint is
`native-device-aware-contact-admission-v3`. The captured model and canonical `nativeLaw`
select either `analyticalRectilinearV1` or `singlePlaneCoplanarGroundV1`, with no old
law alias or automatic selection. Algorithm changes invalidate prior execution
identity. The screened law's source-derived fringe multiplier is an approximation
and does not confer foundry qualification.

## State, Ownership, and Lifecycle
All geometry/numerical/projection state is call-local immutable publication. A short Mutex protects cancellation/stage observations shared between one calculation child and one async monitor. No callback, I/O or await occurs under its lock. A structured task group cancels and joins the monitor on calculation termination, and cancels/joins calculation on callback cancellation/error. Lower phases inspect the same flag plus Task cancellation; no detached task or continuation escapes. Native/MacOS storage and accesses are identical; this host target is not WASM/Embedded-qualified.

| Logical state | Native macOS storage/isolation | Read/mutation entry | Shutdown/release | WASM/Embedded |
|---|---|---|---|---|
| Cancellation + monitor reason + phase | Mutex<State> | withLock accessors/cancel/enter | Task group joins both users before call-local owner release | Host-only adapter; not compiled or runtime-qualified |
| Numerical state | Call-local immutable publication | Lower native component APIs | Retained by result/evidence owner | No additional target claim |

## Failure, Concurrency, and Constraints
Observed byte ceilings and polling duration are retained in topology and terminal evidence independently of physical model identity. Inputs use explicit positive byte ceilings; lower work ceilings come unchanged from configuration. One async monitor awaits the caller check and sleeps between checks; cancellation/error is propagated and always joined. The polling interval is an adapter-owned configurable duration; its latency excludes unbounded caller callback time and uninterruptible standard decoding/hash/encoding segments. The schema/evidence remains complete at admitted record ceilings; encoded evidence has an additional byte admission ceiling, not an independent bound on JSONEncoder allocation. Artifact publication is atomic. Failure evidence is a small terminal record, written without numerical/GPU allocation. Evidence persistence failure remains explicit rather than silently omitting the required artifact.

## Verification and Change Impact
NativePEXAdapterTests exercises actual standard bytes through direct PEXExtracting and public DefaultPEXEngine, analytical RC, actual image identity/reload, missing/bad configuration/calibration, lower budget failure, expected identity mismatch, physical opens/shorts and asynchronous cancellation/monitor teardown. Changes affect runtime provenance and artifact decoding; Default API/CLI, scoped standard export, required-output failure/reload and captured same-input retry are composed and verified in NativePEXAdapterTests and PEXParsers/PEXCLICore owners. These are macOS CPU observations, not process physics or target qualification.

### Independent ground-capacitance correlation
`NativeMagicGroundCapacitanceCorrelationTests` compares actual native full-RC execution with actual Magic capacitance extraction over identical captured GDSII bytes. Four isolated Sky130 nominal metal1 rectangles (10×10, 20×5, 20×10 and 100×1 micrometers), plus two 10×1 micrometer strip pairs at 1 and 2 micrometer gaps, separate area, exposed perimeter, aspect ratio, coplanar coupling and ground-fringe screening. Both runs retain the exact standard input, source netlist, configuration and technology-source calibration artifact. The native coefficients are translated from the installed nominal extraction style; the entire nonempty source deck is hash-verified calibration evidence, not a qualification certificate. Actual producer/image identity, captured model, raw Magic process log/output and native topology are attached to each comparison.

Admission requires agreement within the observed SPICE decimal quantization plus an operation-count-derived floating-point accumulation budget. No coefficients are fitted to the output. Native C-only/R-only requests remain unsupported; the shared observables are ground and coplanar capacitance from the admitted full-RC result. This establishes independent implementation correlation for these finite single-plane fixtures only. Foundry qualification, vias, multilayer screening, electromagnetic accuracy, other processes/corners and external terminal resistance remain unqualified.

`NativePEXTopologyEvidence.artifactFileName` owns the retained `native-topology.json` process-evidence filename. Consumers select exactly one record per corner using this public filename contract, then decode the public version-3 topology type with required `electricalContext`; missing, duplicate, or legacy records fail admission.

The ideal substrate reference is explicitly named `0` for native standard output and `VSUBS` by the installed Magic deck. This naming correspondence preserves the ground-capacitance observable; a native model naming `VSUBS` cannot pass the required SPEF implicit-reference export and is not reported as a successful public run.

Terminal resistance retains the existing independent Kirchhoff evidence at [ElectrodeConstruction](../../PEXNative/ElectrodeConstruction/DESIGN.md). A minimal installed-Magic probe produced aliased duplicate resistor networks from painted ports; reimporting its exact standard GDSII through the current extraction driver produced no resistor network. This prevents a matched external terminal-resistance claim on that public path. Raw GDSII, `.ext`, `.res.ext`, SPICE and process logs are retained with the correlation verification; they are not repaired or fitted into agreement.
