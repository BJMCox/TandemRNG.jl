# Test purpose ledger

Each entry describes a test in `test/`, the public behaviour or invariant it checks,
and its rationale under the coding styleguide: contract, invariant, algorithm claim,
regression, recurrence or RNG or device invariant, or boundary.

| test | purpose | reason |
|---|---|---|
| `stream law: fill equals scalar loop` | For the original eleven draw types and K in (1, 32), from a fresh generator and from offsets of one bit and one byte, `rand_fill!` and a loop of `rand_next` give the same values and the same end position. | public contract (D12, D22), covers the vector, expansion, and partial-row store paths |
| `stream law: natural alignment` | After a 1-bit draw, a 64-bit draw reads bits 64 to 127, so it equals the second element of a fresh Float64 stream; eight Bools are the eight bits of the byte a UInt8 draw returns. | public contract (D12, D22) |
| `stream law: mixed scalar boundaries` | Alternate all eleven types near bit, block, row, and group boundaries at K1/K32/K64. Compare values with random access and the full cache with reconstruction. | Scalar advance, alignment, and inference invariants |
| `result types` | Cover all 18 PureRNGs result types across scalar, addressed, allocated, strided, and Stateful draws. Check Float16, wide integer, complex, and Char mappings with separate oracles; exhaust all 65,536 half-word inputs for packed Float16 stores. | Result-type parity, component order, and device limits |
| `All native and bridge CUDA scalar types` | Compare values and full successor states for every device result type across block and group boundaries. | Device scalar and bridge contracts |
| `stream law: random access` | `rand_at(T, i)` equals element i of a fill across three groups for Float64, UInt32, Bool. | public contract (D2) |
| `stream law: position round-trip` | Rebuilding from `(rngkey, rngposition)` at a mid-block position and at block, row, and group boundaries continues the same stream. | public contract (D10, transport form) |
| `stream law: fixture` | Pinned first draws for seed 42 for Float64, UInt32, Bool, plus block 1 and row 1 values and two Bool bits of pinned words. | RNG invariant: a stream-law change must be deliberate |
| `stream law: block words equal elements` | The 16-byte image of a block that the block stores write equals the element sequence for every draw type but Bool, whose block expands to 128 bytes and is covered by the fill test. | algorithm claim (D21 block store, byte order) |
| `split: index law` | Children are deterministic, equal for an advanced parent, distinct, and the `Val` form equals the vector form. | public contract (D11) |
| `fork: step law` | The parent moves to the next block boundary (128 bits), two successive forks give distinct children, `Val` form equals vector form. | public contract (D13) |
| `derive: domain separation` | `splitrng`, `forkrng`, and `subrng` at the same index give three distinct keys. | public contract (D10 domain words) |
| `fill: thread invariance` | `rand_fill!` with one task equals three tasks over four groups, including unequal task ranges and partial boundary chunks. | RNG and threading invariant |
| `Random API` | `rand(st)` equals the first pure draw, the wrapper tracks the pure chain across a row change and a fill, `rand!` equals `rand_fill!`, `seed!` resets, range and `randn` draw through the generic samplers. | public compatibility contract |
| `seed whitening` | Seeds 1 and 2 give keys that differ in at least 32 of 128 bits, and the raw-key constructor keeps the key. | public contract (D14) |
| `bounds: start position` | The constructor rejects a start position at or above 2^63. | public boundary (D15) |
| `statistics: smoke` | Byte frequencies of 2^20 draws pass a chi-square test at 0.001, and the Float64 mean lies within 5σ of 0.5. | statistical invariant, catches a broken extraction path |
| `Aqua` | Method ambiguities, unbound arguments, stale dependencies, and method piracy. | code quality (PkgTemplates default) |
| `cuda: device fill` (env `test/cuda`) | `rand_fill!` on a `CuArray` equals the CPU fill for every draw type at K = 1 and 32, for an aligned start at 0 and at block 1 (vector stores, Bool block expansion), a start offset by one element (scalar stores), a fill that ends inside a block, one that ends at a group boundary, and two over many workgroups (Float32, Bool). | device invariant, each store path |
| `validation stream feeds` | Compare raw-key and counter starts, sibling interleaving, one-bit key pairs, projections, and decimation across refills with the independent scalar reference. Verify the Philox control against its published vector. | Statistical input and stream-order invariants |
| `device residence` | Preserve key, position, and backend through binding, scalar draws, splitting, forking, and subrng. Check allocating draws, explicit Stateful CPU rebinding, and mismatch rejection before mutation, including empty arrays. | Public residence and type-inference contracts |
| `cuda: device residence` | Compare allocating and strided-view GPU fills with CPU output and end state. Reject both mismatch directions for Bool and UInt32, including empty arrays. | Device execution and storage invariants |
| Reactant conformance (`test/reactant`) | Reuse one executable with changed keys and positions. Match all draw types, array order, high positions, empty-fill alignment, and derived keys with CPU results. | Runtime-state and recurrence invariants |

Development checks outside `test/`, recorded on 2026-09-21:

| check | purpose | reason |
|---|---|---|
| Float64 conversion boundary probe | Compare 128 values spanning zero, bit 53, the sign boundary, and the maximum word against a BigInt extraction oracle on ARM and x86. | Exact 53-bit stream mapping |
| `TandemCycles.selfcheck` | Match historical v1 clock, step, and F vectors, check inverse F, and count independently specified tiny permutations. | Original cycle analysis oracle and inverse invariant |
| Complete cycle histograms | Check that the sum of cycle lengths times their counts equals the full state count. | Exhaustive census invariant |
| Seeded fixed-hidden census | Replay inverse-F witnesses through F and measure their full-step periods. | Seed reachability and period claims |
| GPU workgroup sweep | Compare every complete GPU result with CPU output after timing. | Prevent stale byte units from timing a partial fill |
| Final PractRand projections | Compare chunk-start and consecutive-step projections with independently seeded scalar chunks. | Preserve the D21 row order in statistical test inputs |
| Fixed-point reduction | Compare the one-word reduction with every state of a two-bit model, then forward-check production hits and inverse-F inputs. | Exact census and seed-reachability claims |
| PractRand completion and reuse | Require a successful process and target-length report before passing, invalidate changed protocols/sources, and retain the initial generator across retries. | Statistical evidence and resume invariants |
| `check_practrand.jl` | Kill and reap a child after a feed error, invalidate prior completion evidence, and reject an empty feed before launch. | Subprocess lifecycle and evidence ownership |
| `reference_v2.jl` | Generate SPEC draft 4 vectors with UInt64 scalar arithmetic and check 256 random T/F states against the feedback implementation. | Independent recurrence oracle |
| `check_feeds.jl` | Compare normal/reversed UInt32 and Float64 feeds with raw UInt32 assembly across refills for K=1/32/64; probe C GetU01/GetBits while GC runs. | Native TestU01 adapter correctness, 87 checks |
| Release battery controls | Native SmallCrush gives 15 valid p-values for Xoshiro and each K32 Tandem feed; an eight-bit truncated control triggers 15 strong flags. | Detect feed or battery failures before long tests |
| Feedback diffusion | Flip all input bits and measure all output bits of F and all four T quadrants, including an exact one-step exposed-b control. | Detect feedback diffusion defects without reusing v1 evidence |
| Final partial row | Preserve a padded CPU destination beyond a one-word fill, reject alignment wrap, and compare GPU edge fills with scalar output. | Prevent end-position arithmetic from selecting oversized stores |
| GPU Bool tail | Cover a one-bit tail at offset 31, an advanced position beyond 2^63, and the final partial word. | Bound staging reads and avoid constructor and rounded-end limits |
| `margin.jl` | Check RF8 against production across refills and against the independent oracle before a fixed RF2–RF8 statistical diagnostic. | Reduced-round input and positive-control invariants |
| `margin_direct_check.jl` | Compare direct split halves and chunk starts against the UInt64/mask oracle at boundary counters, across refills, and through public F8 split keys. Check all reserved seeds, inference, and allocations. | Fixed F5–F8 campaign feed invariants, 1,428 checks |
