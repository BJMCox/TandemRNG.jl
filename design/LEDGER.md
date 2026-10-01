# Tandem RNG: design ledger

This ledger has resided in `TandemRNG.jl/design/LEDGER.md` since 2026-09-18 (D19).
It began on the PureRNGs.jl branch `design/gpu-duplex` as
`design/gpu-duplex/LEDGER.md`, which now points here.

Each entry records a decision, its alternatives, and its rationale. Facts that constrain
decisions appear separately with their sources. Open questions appear at the end in
resolution order. Dates are absolute.

## Goal

The goal is a new RNG algorithm designed primarily for native GPU execution, with these properties:

- extremely GPU compatible (portable across NVIDIA, AMD, Apple through KernelAbstractions)
- low-cost splitting into an arbitrary number of child streams
- a working state that may be large, with a small representation for transport
- extremely fast generation
- passes BigCrush and PractRand

## Facts

F1. PureRNGs `main` 0aac36d, A100 GPU 1, 2^27 elements: Philox4x32 Float32 fill 1312 GiB/s
against a memory ceiling of about 1450 GiB/s. Bulk GPU fill is memory-bound and cannot improve.

F2. CPU chained Float64 draw (64 chained draws, min time / 64): Philox4x64 2.1 ns, Threefry4x64
2.9 ns, ChaCha 5.2 ns, Xoshiro256 0.66 ns. A Philox4x32 block costs 5 to 6 ns.

F3. `splitrng` per child in PureRNGs is 0.34 to 0.60x of the ImmutableRNGs 2be98fa reference.

F4. Native one-instruction ops on NVIDIA, AMD, and Apple GPUs: 32x32→64 multiply-add
(IMAD.WIDE), any 3-input boolean (LOP3), rotate (SHF funnel shift), byte permute (PRMT).
No native 64-bit integer multiply (3 to 4 IMADs). 64-bit add or rotate is 2 ops.

F5. On CPU the wide multiply is one instruction. LOP3 is two scalar ops or one AVX-512
`vpternlog`. Rotate and byte permute are one op each.

F6. SIMT executes a warp in lockstep. Data-dependent branches inside a step diverge.

F7. GPUs hide serial latency with occupancy, so only op count per output bit matters there.
CPU chain cost is dependency depth. A shallow round serves both.

F8. One 128-bit vector store per thread per step is the coalesced unit on all three vendors.

F9. Cross-lane shuffles: KernelAbstractions has no portable shuffle, and shuffle throughput is
about a quarter of ALU throughput. Excluded from the design.

F10. Op counts per 128 output bits: Philox4x32-10 about 80 (8 per round, 10 rounds).
ChaCha20 about 240. xoshiro256** about 24 in 64-bit ops, which is 2x on GPU (F4).

F11. lo(x × m) for odd m has bit 0 equal to bit 0 of x. An exposed lo half that is not xored
with a hi half leaves one bit constant across a chunk. (Derived 2026-09-18.)

F12. For uniform x and a multiplier m, hi(x × m) is uniform on [0, m), not on [0, 2^32). Force
the top bit of every multiplier (m | 0x80000001) and xor every hi half with an independent word.
(Derived 2026-09-18.)

F13. If the hidden half ever becomes exposed within T (a swap of halves), the output at step
t+2 is a known function of the outputs at t and t+1: the multipliers at t+2 are the output at
t+1 and the operand is a linear image of the output at t. (Derived 2026-09-18.)

F14. CPU chain budget to match xoshiro256** at 0.66 ns per Float64: about 3 cycles per draw,
so with rate 4 (two Float64 per step) the o recurrence must be at most 6 cycles deep. One
IMAD layer (mul 3 cycles, xor 1, multiplier fixup 1) fits. Two layers do not.

F15. Both machines carry other development work during this design. The user noted on
2026-09-18 that timings might vary. Every benchmark interleaves candidate and baseline in one
process, takes the minimum of many samples, and reports ratios against a baseline measured in the
same run. Absolute numbers from different sessions are not comparable. batserv01 GPU 0 carries a
long Python job, so GPU work uses GPU 1 only.

F16. CUDA.jl 6.4 (CUDA 13.4 ptxas) stopped unrolling `for r = 1:R` round loops in the Philox
cores (SASS had 6 instead of 23 IMAD.WIDE). The fix was `Base.Cartesian.@nexprs`. Every round
loop and every k-step loop in this design unrolls through `@nexprs` or `ntuple` with `Val`.

F17. Reactant traces scalar `Reactant.Ops` only. `map` over a range becomes a traced while loop,
so loops use `ntuple` with `Val`. Fill-sized constants are capped at 100 MB, so index vectors
come from `Ops.iota`. A traced scalar draw has a dynamic position, so the chunk boundary cannot
branch: the trace computes both T(state) and F(key, next chunk) and selects. Cost per traced
draw is F + T, about 9 rounds, against Philox's two blocks of 10. The byte law (D12) removes
the two-block window, so a fill lane produces a [chunks, 4k words] array with no gathers.

F18. Extensions in PureRNGs: `PureRNGsKernelAbstractionsExt.jl` holds the portable kernels
(18 KernelAbstractions sites), `PureRNGsCUDAExt.jl` CUDA-only kernels, plus AMDGPU, Metal,
Reactant, Enzyme, and Distributions extensions. A portable fill kernel through
KernelAbstractions covers all three GPU vendors at once.

F19. Bit 0 of a lo-output word is bit 0 of the multiplied word xor bit 0 of the hidden key
word (F11). Bit 0 of an addition has no carry, so a clock whose carries never rotate into bit 0
keeps that key bit GF(2)-linear in the state, and PractRand's BRank on the low bit of each
word fails at 2^20 bytes. Measured 2026-09-19 with one layer: the Weyl clock and the xoshiro128
clock fail, the ring clock passes 2^35 only because its Weyl carry reaches bit 0 through a
rotation two steps later. The correction applies to the layer rather than the clock: rotate lo by 16 before the key xor.
Then bit 0 is a carry-dependent product bit under any clock. One rotate per lo word, a byte
permute on GPU.

F20. PractRand default settings (`-tf 1 -te 0 -multithreaded`) run at about 190 MB/s on
batserv01 through the Julia feed: 2^35 bytes in about 3 minutes, 2^40 in about 1.5 hours. The
expanded set (`-tf 2 -te 1`) costs 15 to 25x. The harness validation shows that Philox4x32 with 4 or 5
rounds fails at 2^20, while 6 and 7 rounds pass 2^35.

F21. The D20 GPU gap was the store instruction shape, not arithmetic. PureRNGs' Philox
CUDA kernel writes each 16-byte block as one `NTuple{4,VecElement{UInt32}}` store, one thread
per block, into a reinterpreted array. The D20 tile write phase issued four 4-byte stores per
block (sixteen for Bool) with adjacent lanes 16 bytes apart, so each warp store instruction
covered a quarter of the lines it touched, four times the L1 and L2 transactions per byte.
Measured: 905 / 982 / 1040 / 64 GiB/s (Float32 / UInt32 / Float64 / Bool) against 1312 /
1287 / – / 929 for PureRNGs Philox4x32 on the same A100, with the compute phase alone at
2176 GiB/s equivalent. Both GPUs on batserv01 were shared with other jobs during those runs,
so the figures are indicative only.

F22. FPGA mapping. One step is two 32×32→64 multiplies plus xor, one add, and fixed rotations
(wiring). A 32×32 multiply takes three to four DSP blocks (Xilinx 27×18, Intel 27×27), so one
step engine costs six to eight DSP blocks and a few hundred LUTs and emits one 128-bit block
per clock, 6 to 10 GB/s at 400 to 600 MHz. Philox4x32-10 needs twenty multiplies per block.
The multiplier pipeline (three to five cycles) makes one chunk advance only every few cycles,
so several chunks share a pipeline round-robin (C-slow): with eight lanes interleaved (D21)
the engine emits the stream in stream order. F reuses the datapath with a mode bit for eight
cycles per chunk. No tables, division, or floating point, so the C reference (D19) is also the
HLS source and the spec's test vectors check bit-exactness.

F23. External review of SPEC.md draft 1 (unpublished review, 2026-09-19). Accepted and applied
in draft 2: `clock` is a bijection, not "affine"; domain words separate input encodings, not
outputs; the child-key birthday bound is conditional on F's halves behaving pseudorandomly;
access is chunked random access with cost up to K steps; fork is a batch operation from one
captured block; exhaustion semantics and the 2^63 construction bound are defined; the
generator is marked noncryptographic; `K` and the specification version are part of the
algorithm identity for any cross-language transport. Accepted as evidence work after the
speed gate (D16 extension): cycle and invariant analysis of `clock` and T at reduced word
widths, output projections per word and bit plane, time-decimated and cross-chunk streams,
structured key and counter families, split and fork sibling cross-streams, BigCrush and
gjrand, separation of search and validation test sets, more conformance vectors. Two design
suggestions are open for the user: coupling `o` back into `h` (one more op per step, gives up
the autonomous clock) and fixing K = 32 as the only canonical variant. Not accepted: a
separate cryptographic KDF for splitting (D19 keeps one primitive) and a low-product-only
round (the fold of `hi` and `lo` is the source of the nonlinearity, D7).

F24. GPU compute accounting (A100, SASS, `design/SEARCH.md`). One Tandem step is 21.5 SASS
instructions (2 `IMAD.WIDE.U32`, 6 funnel shifts, 12 `LOP3`, 1 `IADD3`, half a loop op) and
one Philox4x32-10 block is 49, a 2.3x ratio. Both kernels run at the integer issue limit of
64 thread-instructions per SM-cycle, so instruction count is time. In-thread parallelism
(two or four independent chains per work-item) changes nothing within 2 %, so the kernels
are not latency-bound. F costs 8.4 step-equivalents per chunk, which makes the whole-kernel
draw advantage 1.7x at K = 32, 1.9x at K = 64, and 2.2x asymptotically. The clock is 9 of
the 19.5 generator instructions per step (4 rotate-xors and the Weyl add), so a cheaper
hidden update is the only remaining opportunity to reduce GPU computation, at the cost of repeating the D8
search and statistical tests.

F25. Cycle analysis corrects D14 and leaves D24 open. The clock has exactly one fixed point
`(c, rotr(c, r1), 0, 0)` at every width. The full step fixes exposed zero there, including at
32 bits. Its known production fixed-state preimage under F has the wrong stream domain and
aux, which excludes that fixed state only. At four bits, inverse F finds 258 legal stream seeds
on the fixed-hidden slice, though neither full-step fixed point is directly stream-seeded.
The eight-bit clock has 622 cycles. Changing one equally rounded rotation reduces that to
16, so the scaled rotations materially affect the evidence. Complete full-step censuses at
four and five bits cover 2^32 and 2^40 states and find 148 and 190 cycles. These analogues
do not prove production seed reachability or safety. Proofs, control, and raw histograms:
`design/SEARCH.md`, `design/search/cycles-2026-09-21.md` (2026-09-21).

F26. Native Julia Float64 row construction removes the handwritten conversion LLVM and
preserves all 53 output bits. Against c33e4ec on EPYC 7702P, one-thread throughput rises
from 4.00–4.09 to 6.83–7.00 GiB/s at 2^20 elements. M4 ranges overlap. Contiguous task
ranges raise the EPYC 64 MiB UInt32 fill at 32 tasks from 46.90–48.93 to 71.17–73.82 GiB/s.
Small Bool fills still suffer task overhead. No dependency or stream-law change. AVX-512
code generation succeeds, but hardware throughput remains unmeasured. See SEARCH.md and
SIMD.md for the protocol and native Julia alternatives (2026-09-21).

F27. Fair comparisons now use matching PureRNGs source and Random123 1.7.1, with both
Philox4x32 and Philox4x64. Chains cover 1024 draws, correcting the old short-burst reseed
bias. EPYC one-thread Float64: Tandem 7.00 GiB/s, Xoshiro 6.41; chains 3.11 versus 1.28–1.30
ns. Xoshiro has higher Float32 and UInt32 fill throughput. A100 core throughput is about 1.7× both libraries'
actual Philox4x32 functions. Random123's float precision is 23/52 bits rather than 24/53.
SEARCH.md records all references, source versions, protocols, and raw data (2026-09-21).

F28. Eight native Julia primitive replacements and three combinations were measured on
M4 and EPYC. Native Float32 conversion matches the prior mapping and speed, so it replaces
the LLVM helper. Arithmetic, multiplication, rotation, transpose, and Bool alternatives
reduce throughput on at least one host. Their generic LLVM helpers remain. No production dependency
was added. CPU suites, Julia 1.10 compatibility, and CUDA checks pass (2026-09-21).

F29. Exact production fixed-point analysis reduces to 2^32 first-word trials. Original T
has exactly one fixed state; feedback to the first hidden word has two. All inverse-F inputs
fail stream domain/aux and canonical counter constraints. Bijectivity excludes later entry.
This closes period-one reachability, not longer cycles or the whole fixed-hidden slice.
The isolated feedback prototype removes that slice for nonzero exposed states within four
steps, costs about 6% A100 core throughput, and changes F and the stream. D24 remained open
at this stage; F30 and D24 below record its later adoption.
See SEARCH.md and search/fixedpoints-2026-09-21.md (2026-09-21).

F30. Feedback is adopted as v2 after user approval (D24). Native Julia complete-group loops
recover the CPU cost: EPYC UInt32 gains 37%, Float64 13%, and M4 Bool 12–15% against the
feedback prototype. Other M4 ranges overlap. Float32 retains its old loop. Encoded-state and
unrolling experiments show no broad improvement, so the direct feedback equation is retained. A100 full-fill
ranges overlap v1 despite the roughly 6% core cost. Eight-round F passes the 16,384-base
diffusion screen; six rounds show bias. Six production PractRand cases complete 2^28 bytes
with no suspicious/FAIL flags and three transient unusual flags. This is not D16 release
qualification. Boundary review also repairs CPU/GPU end-position overflow and GPU Bool
staging. CPU suites pass 216/216 on both hosts, Julia 1.10 passes, and CUDA passes 119/119.

## Decisions

### D1 (2026-09-18): hard targets and constraints

Hard targets: CPU scalar chain cost (below 2.1 ns per Float64, approaching 0.66 ns) and GPU
compute-bound paths (transforms, small fills, Reactant compile size).

Constraints, not goals: split cost at or under Philox (amended by D11 to within 2x per child). Working state may exceed Philox4x32's
192 bits, but the transport representation must be small and cheap to serialize.

Rejected: aiming at bulk GPU fill throughput (F1, already at the ceiling).

### D2 (2026-09-18): two-level chunked architecture

The stream is a sequence of chunks of k steps. An expensive keyed function F(key, chunk index)
seeds a working state. A cheap step T advances the working state and emits output, k times per
chunk. Chunk index is the counter, so:

- split is a key derivation, O(1)
- `rand_at(i)` costs one F plus at most k−1 steps of T
- GPU fill is one thread per chunk, one F then k steps, k vector stores
- transport state is (key, chunk index, offset in chunk). The working state re-derives on load.

Rejected: pure counter-based with a faster F (incremental on Philox, cannot approach Xoshiro
chain cost). Key-in-increment (SplitMix style, inter-stream correlation risk at scale).
Stateful iterate (Xoshiro style, no O(1) split, no random access).

Statistical risk: T must mix a fresh seed well within the first outputs, and chunk seeds must
appear independent. F determines the second property. T's structure determines the first.

### D3 (2026-09-18): 32-bit words throughout

All arithmetic on 32-bit words (F4). T emits at least 64 bits per step so a Float64 draw costs
one step on the CPU chain. The wider working state is acceptable because the transport form
does not carry it (D1).

Rejected: 64-bit throughout (2 to 4x per op on GPU, Metal fill may leave the memory ceiling).
Mixed widths (two sets of operations to tune and test).

### D4 (2026-09-18): duplex with one permutation, own design

One permutation P on a state of W 32-bit words, built from the ops in F4.

- F: state = P^Rf(key, chunk index, domain constant). Full rounds.
- T: state = P^Rt(state). Output = the first 4 state words, read directly. Reduced rounds. The
  hidden words are the per-chunk secret, so no output scrambler.
- Split: child key = P^Rf(key, child index, split constant), truncated.
- Compute per 128 output bits: Rf/k + Rt rounds.

This is a sponge with a reduced-round permutation between squeezes (the KangarooTwelve pattern),
aimed at statistical rather than cryptographic strength.

P is designed here, not reused. Reusing xoshiro128** or a Philox round was considered and
rejected because the user wants a design of their own. Round counts Rf and Rt are measured
parameters, not design choices.

Rejected: two separate primitives for F and T (two round functions to tune and test).

### D5 (2026-09-18): ledger and branch

This file is the durable record. It lives on branch `design/gpu-duplex` in PureRNGs.jl,
worktree `PureRNGs-gpu-duplex`, path `design/gpu-duplex/LEDGER.md`. The algorithm is not part
of PureRNGs.jl until a later decision says so.

### D6 (2026-09-18): W = 8 words, rate 4, capacity 4

State 256 bits. Each step exposes the first 4 words (128 bits, one vector store, F8) and hides
4. One step yields two Float64 draws.

GPU reasoning: bulk fill is memory-bound at every W. For compute-bound and small fills, ops per
output bit are equal between W = 8 rate 4 and W = 16 rate 8, but the 8-word round is shallower
and gives twice the threads per element, so small latency-bound fills favour W = 8. Register counts are
about 20 versus 35. Both are near full occupancy, but W = 8 leaves capacity for transform code.

Rejected: W = 16 rate 8 (improves only the CPU chain, through more draws per step). W = 12 or 16 with
rate 4 (3 to 4 state words of work per output word).

Fallback: W = 16 rate 8 if the Q6 round cannot diffuse across 8 words in 2 rounds.

### D7 (2026-09-18): asymmetric duplex round

The 8 words split into an exposed half o (words 0 to 3, the output) and a hidden half h
(words 4 to 7). The two halves have different update rules.

- **h is a linear clock.** h' = A·h, A a full-rank linear map on 128 bits (xor and rotate, 4 to
  8 ops). h never depends on o. It starts random (from F) and only has to stay random and change
  every step. It acts as a key schedule with 128 bits of full-rank state, reseeded per chunk.
- **o is a multiplicative Feistel keyed by h.** Each step multiplies exposed words by hidden
  words (IMAD.WIDE) and xors the product halves into the other exposed words, subject to F11,
  F12, F13. The multipliers are data, so one round is quadratic in the state bits. Claim under
  test: this needs 1 or 2 layers where the constant-multiplier Philox Feistel needs 10 rounds.
- **F** absorbs (key, chunk index, constants) and runs Rf rounds of the same step with the
  halves swapped after each round and a round constant xored in. T is the step without swap.

Structural constraints: every exposed word changes every step (a Feistel that updates 2 of 4
words leaves two words equal to the previous step's). No raw lo exposure (F11). No swap in T
(F13). Multiplier top bit forced (F12).

Cost per 128 output bits: one IMAD layer (2 multiplies) 12 to 14 GPU ops, 2 to 3 CPU cycles per
Float64. Two layers (4 multiplies) 18 to 20 ops, 4 to 5 cycles. Philox4x32-10: 80 ops, 2.1 ns.
One layer is the target, two layers the fallback. Both beat Philox on ops by 4x or more.

Precedents to cite: IDEA (key-dependent multiply), MUM and wyhash (folded variable products),
Keccak duplex and KangarooTwelve (reduced-round squeeze), Philox (mulhi Feistel), filter
generators (linear driver, nonlinear filter). The combination, the statistical target, the GPU
op budget, and chunk reseeding to drop the period constraint are new.

Rejected: symmetric constant-multiplier Feistel over 8 words (incremental, stays as the harness
baseline). Fully symmetric data-dependent design (twice the multiplies, fallback if the linear
clock shows in tests).

### D7a (2026-09-19): rotate lo before the key xor

Amendment to D7 from the first PractRand round (F19). In every layer the lo half of each
product rotates by 16 before the xor with the clock word. The fold `L ⊕ hi ⊕ lo` stays
unrotated. Cost: one rotate per lo word, two per step, a byte permute on GPU. Reason: it makes
the low output bit a carry-dependent product bit under any clock instead of relying on the
clock to rotate a carry into bit 0. Measured: without it the Weyl and xoshiro128 clocks fail
PractRand `BRank` on the low bit at 2^20 bytes, with the ring clock passing 2^35 coincidentally.

### D8 (2026-09-18): screen, search, gate

1. **Screen.** Parametric step in Julia through Kaimon. Avalanche metrics per candidate wiring
   and clock (flip one state bit over random states, measure output flip rates and bit
   independence). Prune to the cheapest wirings with full avalanche.
2. **Search.** PractRand on survivors to find the minimum passing layer count and Rf, on the
   sequential stream and on derived streams that target this design: chunk-start interleave
   (word 0 of every chunk, tests F alone), each output word position alone, bit-0 and low-byte
   streams (F11), xor of consecutive steps (additive keystream structure), k = 1 (every step a
   chunk start), interleaved streams from keys that differ in one bit (split correlation).
3. **Gate.** BigCrush through the existing RNGTest harness on batserv01.

Harness validation: run the constant-multiplier baseline at rounds 1 to 10 first and check it
reproduces Philox's known minimum of about 7 passing rounds.

Margin rule: record the largest PractRand size at which the configuration one layer or one round
below the chosen one fails. Choose the smallest configuration whose reduced form fails, plus one.
For a 1-layer T the reduced form is the bare clock, so the margin is evidence depth instead:
2^42 bytes or more on every derived stream.

**2026-09-27 addendum.** The agreed v2 margin protocol fixes F5–F8, eight probes,
256 GiB per run, and two reserved replication keys before output. It does not require
F7 to fail or select the production round count from the results. All 72 runs finish.
Three F5 probes fail on all three keys. F8 has no suspicious/FAIL labels in 18 runs.
This completes the bounded campaign and supersedes the earlier adjacent-round failure
rule for this release assessment. It establishes neither a minimum passing round count
nor a period bound. The separate 4 TiB derived-stream depth requirement is complete.
See [the dated margin record](search/margin-2026-09-27.md) for flags and limits.

Rejected: analytic only (avalanche misses structural flaws like F11). Empirical only (slow, and
blind to why a candidate fails).

### D9 (2026-09-18): k is a type parameter, power of two, working default 32

Different k give different streams, as Philox4x32 and Philox2x32 do. Offset arithmetic is
shifts and masks. The default is settled by the D8 chain and fill measurements, with 32 as the
working hypothesis.

Trade-off table (Rf ≈ 8 rounds, about 40 CPU cycles for F, 5-cycle one-layer step):

| k | F amortized per Float64 on CPU chain | `rand_at` worst case | GPU threads at 2^27 | bytes per thread |
|---|---|---|---|---|
| 8 | 2.5 cycles | 8 steps, about 10 ns | 4M | 128 |
| 16 | 1.25 cycles | 16 steps, about 20 ns | 2M | 256 |
| 32 | 0.6 cycles | 32 steps, about 40 ns | 1M | 512 |
| 64 | 0.3 cycles | 64 steps, about 80 ns | 512K | 1024 |

Statistical evidence at k = 1, the default, and 64 covers the family, because the derived
streams in D8 test F and T separately.

Rejected: k fixed by the stream law (one test matrix, no user choice for random-access-heavy
workloads).

Consequences to carry forward:

- **GPU store coalescing.** Thread t writes its own chunk, so adjacent threads are 16k bytes
  apart and a warp store touches 32 half-used sectors. L2 merges halves before DRAM, so DRAM
  traffic stays 1x but L1 and L2 transactions double. Measure. The fix, if needed, is a
  shared-memory transpose (KernelAbstractions `@localmem`). An interleaved layout is out because
  it would put the interleave into the stream law and force the CPU chain to carry many chunks.
- **GPU kernel pattern is one chunk per thread.** Seeding at chunk = thread id pays F only,
  the same as Philox now, and then draws with cheap T steps. Q10 and Q11 must make chunk-granular
  addressing the natural GPU call. Word-level `rand_at` into a chunk pays up to k−1 steps.
- **Small fills.** A fill may split a chunk across threads (each runs F plus a prefix of
  steps) to raise parallelism when n/(4k) is small. Extra compute is free when latency-bound.
  Implementation option, not a stream-law change.

### D10 (2026-09-18): key 128 bits, 64-bit step counter, two constant words

F input, 8 words:

- **Key:** 4 words (128 bits). A 64-bit key collides with probability near 1/2 among 2^32
  children, 128 bits pushes that to 2^64.
- **Position:** 2 words, one 64-bit step counter. chunk = pos >> log2(k), offset = pos & (k−1).
  Stream length 2^64 steps, 2^71 bytes.
- **Domain word:** distinct nonzero values for stream seeding, split derivation, and reserved
  future uses. Stream and split F share the key, so without it a child key could equal words of
  a chunk seed.
- **Aux word** (amended by D13): the fixed nonzero constant with top bit set for STREAM
  seeding, the child pair index for FORK, zero otherwise. Together with the domain word it
  breaks the all-zero and all-equal states for key = 0 and small positions, the hardest F inputs.

Placement: key words start in the hidden half so they are the first multipliers. Position and
constants start in the exposed half. The F rounds swap halves, so every word takes both roles.

Transport form: key plus position, 192 bits, the same size as Philox4x32's key plus counter.

Rejected: 96-bit position (length nobody needs). 64-bit key with 128-bit position (Philox's
layout, weak for large split trees). 192-bit key with no constant words (domain separation
from the round constant schedule alone, fragile).

### D11 (2026-09-18): split law mirrors PureRNGs, two children per F call

- Child i key = half (i & 1) of F(key, i >> 1, SPLIT domain). The 64-bit index takes the
  position slot.
- `subrng(purpose)` = words 0 to 3 of F(key, purpose, FOLD domain).
- Children start at position zero. Derivation reads only the parent key, so splitting an
  advanced parent returns the same children (the PureRNGs law in `src/derive.jl`).
- Splitting n children is n/2 independent F calls, so it parallelizes and runs as a GPU kernel.
- Child keys are F output and collide at the birthday rate over 128 bits (D10).

D1 amendment: the split constraint becomes "within 2x of Philox per child". Philox4x32 spends
about 40 ops per child, this design 50 to 80 at Rf = 8. A child derivation is a one-time cost
per stream, and a Philox child's first draw also pays a full block.

Rejected: one child per F call (twice the cost). Consuming split in the JAX style (children
would depend on parent position, a different semantic from PureRNGs). A separate lower round
count for the split F (one more parameter to measure, kept as a fallback if the 2x bound fails).

### D12 (2026-09-18): natural-alignment byte law, own stream law

The PureRNGs bit law (exact bit thrift, straddling draws, two-block window) spends about 1 ns
per Bool draw on bookkeeping. When a step costs 5 cycles, wasting bits is cheaper than counting
them. The user chose speed over compatibility.

- Each type has a fixed size and alignment inside the 16-byte step: Bool 1 byte, Float32,
  UInt32, Int32 4 bytes, Float64, UInt64, Int64 8 bytes.
- A draw rounds the position up to its alignment, reads its bytes, advances by its size.
- Every size divides 16, so **no draw ever straddles a step**.
- Position is one UInt64 byte counter: step = pos >> 4, byte = pos & 15,
  chunk = step >> log2(k), offset in chunk = step & (k−1).
- Fill element i of a type of size s sits at byte s·i. Fills and scalar draws agree by
  construction. No two-block window anywhere, including the Reactant path.
- Float64 takes the top 53 of its 64 bits, Float32 the top 24 of 32.
- Bookkeeping per draw: one round-up (add, and), one step-index compare, one shift by a
  multiple of 8. Bool costs 8 bits, 16 per step, about 0.5 ns against 1 ns today.
- Capacity 2^64 bytes, 2^60 steps. The F position slot (D10) takes step directly, top 4 bits
  zero.

Rejected: PureRNGs bit law (bookkeeping). Word law (4 Bools per step, CPU Bool fills about 5x
slower than the bit law). One step per draw (1.25 ns per Float64).

### D13 (2026-09-18): two split disciplines from one F

- **Index split.** `split(rng, n)`: child i key = half (i & 1) of F(key, i >> 1, SPLIT). Ignores
  position. Children start at position zero. Cheap, stable, GPU-parallel. This is D11.
- **Fork.** `fork(rng, n)`: child i key = half (i & 1) of F(key, step, FORK, aux = i >> 1). The
  parent moves to the start of step + 1, so the remainder of the current step is dropped and
  repeated forks use distinct steps. The JAX discipline, with n children per call (user,
  2026-09-18: "allow parallel forking"). n/2 independent F calls, GPU-parallel like the split.
  n up to 2^33 per call.
- **Purpose.** `subrng(rng, purpose)`: words 0 to 3 of F(key, purpose, FOLD). This is D11.

The domain word distinguishes uses of the same F, with no core cost. D11's rationale changes
from matching PureRNGs to selecting index split as the primary discipline, with fork
provided by the domain word at no additional core cost.

D10 amendment: the eighth word is an **aux word**, not a fixed constant. It holds the fixed
nonzero constant for STREAM seeding, the child pair index for FORK, and zero for SPLIT, FOLD,
and SEED. Distinct domain values keep the F inputs of every discipline disjoint, so fork
children never coincide with split children of the same key.

Rejected: consuming n/2 parent steps per fork (parent advance would depend on n, and the F
input format stays fixed anyway).

### D14 (2026-09-18, corrected 2026-09-21): seed whitening and Weyl clock

- **Seed whitening.** The integer constructor sets key = F(seed words, 0, SEED)[0:3]. One F
  call at construction. Seeds 0, 1, 2 become unrelated keys instead of small multipliers that
  differ in one bit (F12). A tuple constructor sets the raw key for reproducing a published key.
- **Weyl term in the clock.** h0 += odd constant each step. The map remains bijective, but
  carries make it nonlinear over GF(2). The original claims of an affine, fixed-point-free
  clock and a primitive linear recurrence were incorrect. The clock has one fixed point,
  and T has at least one, even at production width (F25). Keep the add: without it, the
  production linear ring has order only 480. One op inside the clock, off the o critical
  path (F14), one IADD on GPU.

Rejected: no whitening (rely on Rf alone). The original rejection of fixed points did not
constitute a proof. Seed reachability and feedback remain open under D23.

### D15 (2026-09-18): no exhaustion check on the hot path

Capacity 2^64 bytes, 2^60 steps. The constructor rejects a starting position at or above 2^63
bytes. A fill checks start + length ≤ 2^64 once per call. A scalar chain has no check: from any
accepted start it needs 2^59 steps to reach the end, 18 years at 1 ns per step on one thread.

Rejected: a compare and branch at every step boundary (one op per step for a case that cannot
occur). Silent wrap with no constructor bound.

### D16 (2026-09-18): release evidence matrix

- **BigCrush** on k = 1, the default k, and k = 64, each with a Float64 lane and a UInt32
  lane, plus both lanes bit-reversed (TestU01 weights high bits, Vigna's practice): 12 cases,
  using native TestU01 (160 p-values per case). The earlier six-hour estimate came from
  a modified Julia battery; native runtime must be measured separately.
- **PractRand** 2^40 bytes on the sequential stream for each of the three k. 2^38 on every
  derived stream from D8: split8, fork8, subrng8, chunk-start interleave, each word position
  alone, bit-0 and low-byte, xor of consecutive steps, one-bit-apart keys.
- **Hamming-weight dependency test** (Vigna and Blackman's hwd) to 2^40 bytes or more on the
  sequential stream and the chunk-start interleave. It targets long-range Hamming-weight
  structure, the failure mode a linear clock could leak into the exposed words.
- **gjrand mcp** at its largest tier on the sequential stream at the default k.
- **dieharder** once on the default k, for the paper's comparison table only. It is weaker than
  the suites above.
- **Margin record** per D8: the largest size at which the reduced configuration fails.
- Evidence archived under the commit as the existing releases are (`PureRNGs-RNGTest-evidence`,
  `PureRNGs-PractRand-evidence` on batserv01) and attached to a GitHub prerelease.

Not run: NIST SP 800-22 (crypto-oriented and weak, mentioned in the paper only). BigCrush on
derived streams (PractRand covers them at greater depth).

Rejected: BigCrush on the default k only (no evidence that k does not matter). Everything
through BigCrush (days of runtime).

### D17 (2026-09-18): CPU and KernelAbstractions first, Reactant after the round freezes

The design search (D8) runs on CPU through Kaimon. One portable fill kernel through
KernelAbstractions covers CUDA, AMD, and Metal (F18) and gives the paper's GPU numbers on the
A100. The Reactant extension waits until Rt, Rf, and the wiring are fixed, because every wiring
change changes the trace. All backends ship in the same release. Constraints F16 and F17 apply
to every backend.

Rejected: all backends from the start (a compile cycle per wiring candidate). CPU and CUDA only
(loses the portability claim).

### D18 (2026-09-18): name Tandem

Type `Tandem8x32{k}`, Philox-style suffix. Backronym: **T**wo-half **A**symmetric **N**onlinear
**D**uplex with **E**volving **M**ultipliers. Every word describes the design: two halves with
different jobs (D7), asymmetric, nonlinear through the multiply, a duplex (D4), multipliers that
evolve with the clock.

Collision check 2026-09-18: no `Tandem*` package in the Julia General registry, no `Tandem.jl`
or `TandemRNG` repository on GitHub, no RNG named Tandem in a GitHub description search.
A keyword search for a "Tandem" pseudorandom generator in OpenAlex and Semantic Scholar found
nothing. The related-work review will repeat these checks.

Rejected: evocative names (Descant, Orrery, Escapement, Lockstep), which did not match the
user's naming preference. The descriptive name `Duplex8x32` lacked distinctiveness.

### D19 (2026-09-18): TandemRNG.jl, a PureRNGs extension, and reference implementations

- **Primary:** Julia package `TandemRNG.jl` (BJMCox), own API on the byte law (D12), split
  disciplines (D13), KernelAbstractions kernels, Reactant extension later (D17). Registered in
  General as `TandemRNG`. The ledger and design notes move to `TandemRNG.jl/design/` when the
  repo exists. This branch keeps the record until then.
- **PureRNGs bridge:** a package extension in PureRNGs (`PureRNGsTandemRNGExt`, weak dependency
  `TandemRNG`) so PureRNGs users get Tandem through the PureRNGs entry points. It bridges the
  byte law to PureRNGs' fill hooks rather than teaching PureRNGs a second position model. Built
  once the TandemRNG.jl API is stable. D26 moves ownership into TandemRNG.
- **Language-agnostic spec repo** `tandem-rng`: `SPEC.md` (normative), test vectors generated by
  the Julia implementation (the conformance oracle for every port), a single-header reference C
  implementation `tandem.h`, a C++ `UniformRandomBitGenerator` wrapper, and a CUDA C++ header
  for a direct cuRAND Philox comparison in the paper. The PractRand and TestU01 harnesses
  consume the C reference.
- **Python** `tandem-rng-py`: a NumPy `BitGenerator` (C extension over `tandem.h`, the
  `randomgen` pattern) and a JAX PRNG implementation through `jax.extend.random`, in pure
  `jax.numpy`. JAX's key-splitting model matches D13 and its default is Threefry2x32, so it is
  the natural showcase.
- **Rust** `tandem-rng-rs`: crate `tandem_rng` implementing `rand_core::RngCore` and
  `SeedableRng`.
- **Later, on demand:** Java `SplittableGenerator` (its interface matches D13 exactly), Go
  `math/rand/v2` Source, JavaScript or WASM.

Order: Julia (design search and paper), C reference (harness input and normative form), Python
(NumPy and JAX), Rust, then the PureRNGs extension when the API settles.

Precedent to add for the paper: the LXM family (Steele and Vigna, 2021, Java's
`L64X128MixRandom`) combines a linear congruential generator and an xorshift generator with a
mixing output function. Tandem differs by feeding the nonlinear output back into the exposed
half and by using the linear part as multipliers instead of as summands into a mixer.

Rejected: a tenth family inside PureRNGs (two position models through every code path). A
subpackage in the PureRNGs repo (two laws in one repo, no citable repo of its own).

### D20 (2026-09-19): Julia implementation, first complete version

`TandemRNG.jl` at this commit implements D2 to D15 and D17:

- `src/core.jl`: the permutation with the ring clock (rotations 7, 13, 22, 3, Weyl add on
  h0), one Feistel layer per step with the lo rotation of D7a, F with `RF = 8` rounds (six
  give full avalanche, two are margin), domain words for STREAM, SPLIT, FORK, FOLD, SEED.
- `src/generator.jl`: `Tandem8x32{K}` as an immutable value holding key, byte position, and
  the working state of the held step. `rand_next`, `rand_at`, seed whitening, position
  round-trip, start bound 2^63.
- `src/split.jl`: `splitrng` (index), `forkrng(rng, n)` (step, parent advances), `subrng`.
- `src/fill.jl`: threaded CPU fill, one task stripe per chunk set, result independent of the
  thread count.
- `src/random.jl`: `Stateful <: Random.AbstractRNG` bridge.
- `ext/TandemRNGKernelAbstractionsExt.jl`: portable GPU fill, one work-item per chunk, output
  staged through a shared-memory tile (64 chunks × 8 steps) and written block-wise so warp
  stores coalesce. Equal to the CPU fill on an A100 (test env `test/cuda`, 17 of 17). A100
  GPU 1, 2^27 elements: Float32 905 GiB/s, UInt32 982, Float64 1040, Bool 64, against CUDA.jl's
  native RNG at 318 / 700 / 722 / 181 and PureRNGs Philox4x32 at 1312 (F1). Direct chunk
  stores ran at 61 GiB/s: the D9 coalescing concern was real and the transpose was the fix.
- 102 tests in the core suite (ledger `design/TESTS.md`), Aqua clean, formatted with the
  PureRNGs JuliaFormatter config.

Measured on the development Mac (noisy, F15; ratios within one run): pure chain 1.07 ns per
Float64 draw against Xoshiro 0.74 ns and the raw step 1.32 ns; `Stateful` 2.4 ns; CPU fill
single thread about 2.4x slower than `Random`'s SIMD Xoshiro fill, ten threads about level;
Bool fill 4x slower (byte law, no SIMD).

### D21 (2026-09-19): lane-interleaved stream law, eight lanes

Decision: the stream is a sequence of 128-byte rows. Row r holds the 16-byte blocks of lanes
0 to 7 of group g = r ÷ K at step j = r mod K (0-based). Lane ℓ of group g is chunk
c = 8g + ℓ, seeded by F from (key, c, DOMAIN_STREAM, AUX_STREAM), and its block at step j is
o after j + 1 applications of T. Block b = position >> 4 is lane b & 7 of row b >> 3. The byte
law inside a block (D12) and K as a type parameter (D9) stand. The seed counter is the chunk
number c, not c·K as in D20.

Why: D2 and D9 made a chunk's bytes contiguous, the CPU-first choice, since a scalar chain
then walks one chunk and never touches another. On a GPU it puts adjacent work-items 16K
bytes apart, so the D20 fill needed a shared-memory transpose and still trailed PureRNGs'
Philox4x32 by a quarter (F21). With rows, adjacent work-items write adjacent blocks and one
row fills a whole 128-byte line: the fill is one work-item per chunk with direct 16-byte
stores, no shared memory, no barrier, one kernel for every backend. On the CPU the eight
lanes of a group step in lockstep, one AVX2 vector per state word, which is the vectorized
fill from the D20 open items. The chain holds the eight lane states (256 bytes of working
state, transport unchanged at key and position) and pays one 8-wide T per 128 bytes, so it
should pass Xoshiro. On an FPGA the row order is the C-slow pipeline order (F22).

Rejected: (a) K = 1 counter mode, a Philox-shaped kernel, but F per block is about twice
Philox4x32-10's arithmetic and the chain reseeds every 16 bytes. (b) Word-major rows
(structure of arrays), which spare the CPU a 4×8 register transpose but scatter each GPU
work-item's four words 32 bytes apart, the F21 problem again. (c) Four or 32 lanes: four
gives 64-byte runs, half a line per warp store, and 32 makes the CPU working state 1 KB.
Eight matches AVX2 width and one full line.

Consequences: `Tandem8x32{K}` holds `o` and `h` as word-major lane tuples for the held row.
`_advance` does nothing inside a row, one 8-wide T for the next row of the same group, and a
reseed otherwise. `rand_at` seeds one lane. `Stateful` keeps the position apart from the
value and touches the value only at a row change, which also removes the D20 copy cost.
`rand_fill!` stripes groups over threads. The GPU kernel becomes `fill_lanes!`. The core is
written once over a word type, `UInt32` for the scalar and GPU paths and an 8-lane `Lane8`
for CPU rows. The permutation (D7, D7a, D10, D13, D14) is unchanged, so the search evidence
and the per-chunk PractRand runs stand, but the sequential stream now interleaves eight
chunks, so the D16 matrix reruns on the new law once the speed gates hold. Fixtures change.

Gates, set by the user on 2026-09-19: throughput figures only from a GPU with no other
process on it, checked with nvidia-smi before and after the run and recorded beside the
numbers. SmallCrush (`design/search/quick.jl`, RNGTest.jl) and the avalanche screen while
the code changes. PractRand and BigCrush only after the speed targets hold. Speed targets:
CPU chain and fill above `Random`'s Xoshiro and PureRNGs Philox4x32, GPU fill at or above
PureRNGs Philox4x32 on every draw type, and in-kernel draws (no store) well above it, which
is the GPU-native figure of merit.

Spec: `SPEC.md` in this repository, normative, written once D21 passes its tests, with test
vectors for the permutation, F, the stream law, and the split laws. The language-agnostic
repository of D19 takes it over later.

Implementation record (2026-09-19): changes that improved the eight-lane value's performance:

- The lane word `Lane8` wraps an LLVM `<8 x i32>` (`NTuple{8,VecElement{UInt32}}`) and its
  operations are `llvmcall` IR (`src/vector.jl`). The element-wise tuple form left the
  rotations scalar: eight extracts, eight funnel shifts, eight inserts per word.
- Runtime lane indexing forces the whole 288-byte value onto the stack on every draw (15 to
  18 ns per draw, 1100 stores per loop body). The value keeps `o` rotated so the current
  block is lane index 1 and extraction uses constant indices. The hidden state `h` stays in
  natural order because eight rotations are the identity exactly when the next step is due.
  The only runtime-indexed path (`_state_at`) is out of line.
- A tuple argument travels by pointer in Julia's calling convention. Passing `rng.key` to an
  out-of-line function pinned the whole value to the stack. The out-of-line builders take
  the key as one `UInt128`.
- `Stateful` copies the current row's 32 output words into a small array once per row. Reading
  a lane of the value's row at runtime made Julia copy the 288-byte value out of the mutable
  on every draw (6 ns). The draw is now a row check and four indexed loads.
- The CPU row store is a 4×8 register transpose in eight two-source shuffles plus four
  32-byte unaligned stores, with the Float32 and Float64 conversions applied to whole word
  vectors before the transpose. LLVM did not find the transpose from the element-wise store.
  A first version had the Float32 scale constant one binade off (LLVM spells float constants
  as double bit patterns); the fill-equals-loop test caught it.
- The first row store computed the element index with a shift that is only right for
  16-byte aligned starts. The thread-invariance test caught it through uninitialized memory,
  and the fill-equals-loop test now starts one byte in for every type.

CPU result (Apple M4, table in `design/SEARCH.md`): chain 0.96 to 1.07 ns per Float64 against
Philox4x32 3.16 and Xoshiro 0.64; `Stateful` 1.75 ns; single-thread fill 14 to 18 GiB/s
against Philox 4.7 to 5.1 and Xoshiro 20 to 26; fourteen threads 84 to 97 GiB/s against
Philox 41 to 44. Bool fill trails PureRNGs (16.8 against 23.0) because of the byte law. The
CPU targets against Philox hold; Xoshiro remains faster on this ARM core by 1.3 to 1.5x on fills
and 1.5x on the chain. Reducing this gap remains an optimization task (AVX2 and AVX-512 not measured yet,
two groups per iteration, rotate as shift-insert on NEON).

GPU result (A100, tables in `design/SEARCH.md`): the direct-store kernel fills at 1262 to
1295 GiB/s (Bool 1009) at K = 32 against PureRNGs Philox4x32 at 1200 to 1375 (Bool 946),
both 85 to 98 % of the 1448 GiB/s HBM peak and inside the pass-to-pass spread of the
reference. In-kernel draws with no store run 1.71x Philox4x32-10 at K = 32 (1.92x at K = 64),
which is the GPU-native figure of merit. The fill gains 7 % at K = 8 (a warp's four rows are
128·K bytes apart) but K = 8 costs 30 % of the CPU fill and of the draw advantage, so K = 32
stays the default. The host synchronize after the kernel cost 2 to 7 % and was removed. The
CUDA test env passes on the final tree, SmallCrush is clean on the row law.

Verdict against the D21 gates: CPU chain and fill above Philox4x32 by 3 to 4x, GPU fill at
parity with Philox4x32 at the memory wall, in-kernel draws 1.7x. Not met: Xoshiro's CPU
fill (20 to 26 GiB/s against 14 to 20 on NEON) and chain (0.64 ns against 0.96), and Bool
fill against PureRNGs on the CPU (byte law).

### D22 (2026-09-19): bit positions, a Bool is one bit

Decision: the position counts bits. A draw of type T consumes `w` bits, `w = 1` for Bool and
`8·sizeof(T)` otherwise, aligned to `w`. Blocks are 128 bits, rows 1024 bits, the stream
holds 2^64 bits (2^61 bytes), a generator may start below 2^63 bits. A Bool is bit `p & 127`
of its block (bit `t & 31` of word `t >> 5`). Everything else keeps its bytes and its values.

Why: under D12 a Bool consumed a byte and kept bit 0, so a Bool fill ran at the generator's
byte rate (16.8 GiB/s of Bools on the M4, 1009 on the A100) while PureRNGs and `Random`,
which count bits, deliver 23 and 65 GiB/s of Bools from far slower word rates. The reviewer
(F23, review section 7.2) noted the eight-for-one cost. Counting bits removes it: a Bool
fill needs eight times fewer generator bytes and becomes store-bound, PureRNGs' position
semantics match, and no other type changes speed or values. Rejected: a packed-Bool fill
only, which would break "fill equals a loop of scalar draws" (D12); keeping the byte law
and telling users to unpack `UInt64` fills themselves.

Consequences: `rngposition` is in bits (the transport form grows by three low bits), block
index `pos >> 7`, row `pos >> 10`, fork at block `pos >> 7`. The CPU Bool row expands each
word to 32 bytes with a byte shuffle, a bit-weight mask, and a compare (`_vexpand`), 32
stores of 32 bytes per row. The GPU Bool fill is two passes: the word fill into a temporary
array of `n / 32` words from the 32-bit boundary at or before the position, then
`expand_bools!`, one work-item per 16 Bools, four bits to four bytes by one multiply by
0x00204081 and a mask (`_spread4`), adjacent work-items on adjacent 16-byte pieces. A first
version expanded inside the chunk kernel and ran at 347 GiB/s (from 1009 under the byte law)
because each lane wrote its own 128-byte block and a warp's store instruction touched 32
lines. Fixtures for Float64 and UInt32 are unchanged, Bool fixtures are bits of the same
words. 210 CPU tests, including fills that start one bit in for every type, and the CUDA env
passes with a Bool fill over many workgroups.

### D23 (2026-09-19): K = 32 canonical, coupling decided on evidence

The following decisions were made with the user's authorization. K = 32 remains the
default and becomes the canonical variant of the spec, `Tandem8x32-v1-K32`. The type
parameter stays, other values are named variants `Tandem8x32-v1-K<k>` and ports may support
only K = 32. The K sweep (SEARCH.md) shows that K = 8 increases GPU fill throughput by
6 % and reduces CPU fill throughput and the in-kernel draw advantage by 30 %.
K = 64 increases CPU throughput by 1 % and reduces GPU fill throughput by
1 %. One canonical stream keeps results reproducible across languages.
Coupling the exposed half back into the clock (F23, review 14.1) is not adopted now: it costs
about 5 % of the step and reopens the D7 and D8 search. It is decided after the reduced-width
cycle analysis of `clock` and T (exact 4-bit and 8-bit word analogues with scaled rotations,
exhaustive cycle enumeration, fixed points, invariant subsets); short cycles or invariant
subsets reachable from seeded states would trigger the change.

### D24 (2026-09-21): exposed feedback, stream identity v2

The user approved feedback in principle and requested performance optimization. The adopted
recurrence is the one measured: compute `O = mix(o,h)` and `H = clock(h)`, then xor `O[1]` into `H[1]` after
the modular addition. F uses this step too. Undoing that xor before the original inverse
preserves bijectivity. This removes the fixed-hidden invariant for nonzero exposed states
without claiming a production period bound. Both production fixed states are unseedable.

Use SPEC draft 4 and `Tandem8x32-v2-K<k>` identities. Regenerate all vectors with the
independent UInt64 oracle. Keep RF=8: F7 is the first tested passing round count, and F8
passes the larger screen. Do not retain the v1 claim that six rounds suffice.

Keep the native Julia complete-group CPU loop except for Float32, where it regresses.
The encoded hidden-state experiment adds complexity without a broad speed gain. The new
feedback itself uses native Julia and adds no LLVM helper or dependency. Retain the
existing measured generic SIMD helpers from F28. D16 remains required before release.

### D25 (2026-09-22): core device binding and thin integrations

MLDataDevices is a core dependency, as requested by the user. `Tandem8x32{K,D}`
stores a concrete backend token. Binding preserves the key, bit position, and cache.
Allocating draws use the bound backend. Fills reject mismatched destinations before
mutation, including empty arrays. Tokens do not pin physical GPUs. `Stateful` explicitly
rebinds to CPU. These are PureRNGs' residence rules, which matter because PureRNGs is
the expected main entry point. Device binding changes no stream or transport identity.

The PureRNGs extension delegates uniform draws, state access, and key derivation.
It owns no allocation or stream implementation. Reactant converts the key and position
to runtime array data and uses the shared v2 recurrence for scalar and vector operations.
Static derivations and bulk fills preserve CPU values and end positions.

Backend precompile triggers explicitly include the MLDataDevices parent and its backend
triggers. This makes the device-query extension load before a device workload. Merely
depending on MLDataDevices transitively allowed CUDA arrays to be classified as CPU arrays
during precompilation. CUDA device workloads and the 334-check A100 integration suite pass
with the explicit ordering. AMD hardware validation remains deferred.

### D26 (2026-09-22): Tandem owns the PureRNGs bridge

This revises D19's bridge placement. `TandemRNGPureRNGsExt` lives in TandemRNG,
with PureRNGs as a weak dependency. Forwarding methods, precompile workloads, and
conformance tests stay with the generator types and Reactant carrier they use.
PureRNGs contains no Tandem-specific implementation. The bridge keeps its public
API, stream law, residence checks, and Bool-only `threaded` keyword contract.

### D27 (2026-09-26): PureRNGs result types and scalar costs

All 18 PureRNGs uniform result types are supported. Float16, UInt128, Int128,
ComplexF16/F32/F64, and Char are added to scalar, addressed, allocating, destination, Stateful,
and bridge APIs. Every supported type is precompiled. Complex values compose two real
draws. Char consumes a 64-bit candidate using PureRNGs' fixed-work Unicode mapping.
These additions preserve every existing v2 stream. SPEC.md defines their mappings.

Device limits match PureRNGs: 128-bit integer device draws are CPU-only, Metal excludes
Float64 and ComplexF64, and Reactant supports the 12 primitive types through 64 bits.
CPU, CUDA, Metal, and Reactant conformance pass. AMD hardware checks remain deferred.

Scalar bridge forwarding is inlined. The scalar cache advances through its single possible
next-block transition, and 64-bit values are extracted through fixed word choices. Both changes
use native Julia. EPYC Float64 falls from 3.16–3.17 to 2.49–2.51 ns per draw against
the frozen base. All 18 native and bridge scalar chains infer and allocate zero bytes.
Dense complex fills reuse real vector stores. Float16 rows use an exact vectorized
bit encoding, checked over every half-word input. These changes raise EPYC Float16
fills from about 2.2 to 4.6 GiB/s and ComplexF32 from 4.2 to 10.6 GiB/s.
See `search/performance-2026-09-26.md` for the full type matrix and public comparisons.

## Open items after D27 (updated 2026-09-27)

- Extend v2 cycle evidence beyond the bounded analyses.
  Production fixed points are excluded from seeded streams; longer periods remain open.
- GPU draws: the independent-chain experiment is complete (F24). Measure any proposed
  step change before repeating the fill search. D22 Bool measurements are in SEARCH.md.
- CPU: native Julia Float32/Float64 conversion and contiguous task ranges are measured (F26/F28).
  Adaptive task counts, two groups per iteration, NEON shift-insert, and AVX-512 hardware
  measurements remain open. Small Bool fills still lose speed with too many tasks.
- D16 and F23 coverage is audited in VALIDATION.md. The fixed PractRand, BigCrush, HWD,
  and gjrand campaigns complete. All 203 structured screens reach 256 MiB, including
  continuations. Retained flags, bounded structural analyses, and untested review axes
  remain explicit. Publication waits for release; dieharder remains a paper-only task.
  The production adapter's chunk-start and same-chunk XOR projections now follow row order;
  use the new final-row-bit-v2 logs, not the historical final or final-row-bit-v1 directories.
- GPU: a shared-memory tile variant of `fill_lanes!` that writes 512 contiguous bytes per warp
  at K = 32 (the D20 tile reached 1316 to 1358 under the same protocol), Metal and AMD runs.
- C reference and other ports (D19), conformance vectors per F23. Public bound scalar
  GPU draws are measured by `benchmark/run.jl`; correctness is checked in kernels.
- Publish the prepared evidence assets with the first release. The fixed F5–F8 margin
  campaign is complete, and all 19 specified derived streams meet D8's 4 TiB depth target.
  VALIDATION.md retains the flags, bounded claims, and possible research follow-ups.

## Open questions, in resolution order

The original sixteen questions and D24 are resolved. The scheduled statistical matrix
and bounded margin campaign are complete. Evidence publication waits for release.
