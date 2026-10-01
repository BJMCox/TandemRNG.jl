# D8 search notes

This record documents the screen, search, and gate of D8. The ledger records decisions,
while this file records candidates and measurements.

The adopted v2 recurrence and current measurements are in the section
"2026-09-21: feedback adopted as v2, native Julia speed work". Earlier sections preserve
the historical search and v1 evidence.

## Candidates

State: exposed o = (a, b, c, d), hidden h = (h0, h1, h2, h3), all UInt32. A step computes o'
from (o, h), then advances h. Multipliers are m = h | 0x80000001 (F12).

### Clock variants (h' = A·h + W)

- `weyl`: h_i += W_i. Four adds. Multipliers form arithmetic progressions.
- `ring`: h0 ^= rotl(h1, r1), h1 ^= rotl(h2, r2), h2 ^= rotl(h3, r3), h3 ^= rotl(h0, r4),
  then h0 += W0. Sequential single-word updates, so bijective. About 9 ops.
- `xoshiro`: the xoshiro128 linear recurrence, then h0 += W0. Primitive characteristic
  polynomial, about 10 ops.

### Feistel wirings

- `w2` (one layer, bijective, the target): with (hi0, lo0) = a × m0 and (hi1, lo1) = c × m1,
  a' = b ⊕ hi0, b' = lo0 ⊕ h2, c' = d ⊕ hi1, d' = lo1 ⊕ h3, then output order (b', c', d', a')
  so the next step multiplies the former products and pairs cross. Bijective in o for fixed h
  because lo is a bijection of a and b is recoverable from a'. The clock words h2 and h3 hide the
  low bit of lo (F11). This is the Philox4x32 round with (M, key) replaced by hidden words.
  2 IMAD.WIDE, 4 xor, 2 or. Depth about 5 cycles (F14).
- `w1` (one layer, cross xor, not bijective): b' = lo0 ⊕ hi1, d' = lo1 ⊕ hi0, otherwise as w2.
  Comparison point for the cost of bijectivity.
- `w3` (two layers): w2, then w2 again with multipliers from h2, h3 and keys h0, h1. The
  fallback. 4 IMAD.WIDE, depth about 9 cycles.

### F (chunk seed)

o = (pos_lo, pos_hi, domain, aux), h = key. Rf rounds of: step, then o[1] ⊕= RC[r], then swap
o and h. RC are distinct nonzero constants with the top bit set.

## Screen protocol

Strict avalanche over N random states. For T: flip each of the 256 state bits, run S steps,
record the flip probability of each exposed output bit at every step. For F: flip each of the
256 input bits (key, position, domain, aux) and record the flip probability of each of the 256
output bits after Rf rounds, for Rf = 1 to 10.

Report per configuration: fraction of (input bit, output bit) pairs whose flip probability lies
outside 0.5 ± 3σ with σ = sqrt(0.25 / N), the number of pairs with probability exactly 0 (no
dependence), and the minimum and maximum probability.

Pass rule for the screen: no zero pairs from any exposed input bit, and the outside-3σ fraction
at the level expected by chance (about 0.3 %) by step 2 for T and by the chosen Rf for F.
Hidden bits flipped by an exposed flip are always zero by design (h never sees o), so they are
excluded from the T summary.

## Measurements

### 2026-09-18 avalanche and bias screen (`design/search/step.jl`)

The first version of the step had two defects, both corrected before these measurements:

1. The word permutation sent lo back to the multiplied slot and kept the L word in the L slot,
   so roles never alternated. The corrected version uses the Philox4x32 shuffle:
   L ⊕ fold(other pair) goes to the next multiplied slot, and lo ⊕ clock word goes to the next L slot.
2. `a' = b ⊕ hi` with b exposed leaked the hi top-bit bias (F12): the consecutive-xor bit
   frequency deviated by 0.19 (w1 row below). Fold `L ⊕ hi ⊕ lo` removes it. With the fold
   the multiplier fixup only needs oddness (`m | 1`), so the two forced bits are removed.

Hidden-bit avalanche into exposed words, N = 4096, 3σ = 0.023, fraction outside and exact-zero
pairs of 16384:

| config | step 1 | step 2 | step 3 | step 4 |
|---|---|---|---|---|
| ring w2 (1 layer) | 0.82 / 13344 | 0.48 / 7712 | 0.26 / 3939 | 0.048 / 564 |
| ring w3 (2 layers) | 0.52 / 8382 | 0.008 / 70 | 0.0026 / 0 | 0.0026 / 0 |
| xoshiro w2 | 0.83 / 13410 | 0.40 / 6515 | 0.13 / 2016 | |
| weyl w2 | 0.83 / 13410 | 0.58 / 8775 | 0.34 / 4132 | |

Chance level is 0.0027. One layer needs about 5 steps for every hidden bit to reach every
output bit, and two layers need 3. PractRand tests assess whether the slower diffusion matters.

Bias (N = 2^17, σ = 0.0014, worst deviation over 512 word cells and 1536 consecutive-xor
cells, chance-level maximum about 0.005): ring w2 0.0045 / 0.0049, ring w3 0.0044 / 0.0045,
ring w1 (no fold) 0.005 / **0.19**.

F avalanche (all 256 input bits to all 256 output bits, N = 1024, 3σ = 0.047):

| Rf | ring w2 | ring w3 | xoshiro w2 |
|---|---|---|---|
| 3 | 0.27 / 16111 | 0.0022 / 0, min 0.24 | 0.24 / 13224 |
| 4 | 0.071 / 3716 | 0.0023 / 0, min 0.44 | 0.056 / 2010 |
| 5 | 0.010 / 276 | clean | 0.0054 / 31 |
| 6 | 0.0027 / 0 | clean | 0.0025 / 0 |

Full F avalanche at Rf = 6 for one layer per round and Rf = 4 for two layers. Cost is equal
(about 115 ops). Margin candidates: Rf = 8 (w2) or 6 (w3).

Interpretation fixed here: F seeds chunk c from the step index of its first step, pos = c·k,
so chunk starts at k = 32 coincide with every 32nd chunk start at k = 1.

### 2026-09-19 PractRand round 1 (`design/search/matrix.jl`, 2^35 bytes, default test set)

Harness validation: Philox4x32 R4 fails at 2^20 (24 flags), R5 fails at 2^20 (5 flags, FPF),
R6 and R7 pass 2^35, R10 passes.

| case | result |
|---|---|
| ring w2 Rf6 k32 sequential | pass 2^35 |
| ring w2 Rf6 k1 sequential (F alone) | pass 2^35 |
| ring w2 Rf6 k64 sequential | pass 2^35 |
| ring w3 Rf4 k32 sequential | pass 2^35 |
| ring w2 Rf6 k32 key = 0 sequential | pass 2^34 and running |
| **weyl w2 Rf6 k32 sequential** | **FAIL at 2^20**: `[Low1/32]BRank(12)`, `Gap-16`, `DC6` |
| **xoshiro w2 Rf6 k32 sequential** | **FAIL at 2^20**: `[Low1/32]BRank(12)` |

Diagnosis (ledger F19): bit 0 of a lo-output word is bit 0 of the multiplied word xor bit 0 of
the hidden key word. Under a clock whose carries never rotate into bit 0 that key bit is
GF(2)-linear, so the low-bit stream has bounded rank. The ring clock passed because of its
rotation amounts. The correction rotates lo by 16 before the key xor (`lorot = 16`), in every layer.

### 2026-09-19 PractRand round 2 (lorot = 16, 2^35 bytes)

| case | result |
|---|---|
| ring w2 Rf6 k32 sequential | pass 2^35 |
| ring w3 Rf4 k32 sequential | pass 2^35 |
| ring w2 Rf6 k1 sequential | pass 2^34 and running |
| derived streams, weyl and xoshiro clocks, key 0, Rf 4 | running, `logs/matrix-2026-09-19` |

### 2026-09-19 shipped generator (`design/search/final.jl`, 2^36 bytes)

The feed uses `TandemRNG.rand_fill!` itself (RF = 8, lo rotation 16, ring clock), so the evidence
covers the released code path. Streams: sequential at k = 1, 32, 64 and seed 0, plus
chunkstart, word0, word1, xorstep, lowbyte, bit0 at k = 32. Results in `logs/final` on
batserv01.

Result (2026-09-19, package at commit 0b9054a, seed 42 unless noted): all ten streams pass
2^36 bytes.

| stream | k | flags at 2^36 | wall time (s) |
|---|---|---|---|
| sequential | 1 | 0 | 803 |
| sequential | 32 | 0 | 537 |
| sequential | 64 | 0 | 521 |
| sequential, seed 0 | 32 | 0 | 532 |
| chunkstart | 32 | 1 transient | 2982 |
| word0 | 32 | 0 | 1576 |
| word1 | 32 | 0 | 1410 |
| xorstep | 32 | 0 | 1138 |
| lowbyte | 32 | 0 | 1618 |
| bit0 | 32 | 0 | 3153 |

The chunkstart flag is one `[Low8/32]DC6-9x1Bytes-1` at p = 1 − 2.6e-4 ("mildly suspicious")
at 2^33 that does not recur at 2^34, 2^35, or 2^36. PractRand reports a value at that level
about once per thousand tests, and the run covers several hundred, so it is chance.

### 2026-09-19 A100 fill throughput (GPU 1, 2^27 elements, best of 10, GiB/s written)

Kernel `ext/TandemRNGKernelAbstractionsExt.jl`, K = 32, through KernelAbstractions on CUDA.

| kernel variant | Float32 | UInt32 | Float64 | Bool |
|---|---|---|---|---|
| direct chunk stores (one work-item writes its own 512-byte chunk, scalar stores) | 61 | 64 | 101 | 15 |
| store-only kernel, same layout, no computation | 29 | | | |
| compute-only kernel, one word per work-item | 2176 (equivalent) | | | |
| shared-memory tile, element-wise write phase (S = 32) | 228 | 229 | 389 | 61 |
| shared-memory tile, block-wise write phase (S = 32, W = 64) | 797 | 806 | 865 | 81 |
| block-wise, W = 64, S = 8 (default) | 905 | 982 | 1040 | 64 |
| block-wise, W = 64, S = 16 | 912 | | | |
| block-wise, W = 64, S = 4 | 374 | | | |
| CUDA.jl `rand!` (native Philox2x32, GPUArrays.RNG) | 318 | 700 | 722 | 181 |
| PureRNGs Philox4x32 (F1, reference) | 1312 | 1287 | | 929 |

The store pattern rather than the arithmetic determined throughput. The compute phase alone would reach
2176 GiB/s equivalent. The remaining gap to Philox comes from four scalar 4-byte stores per block where a
single 16-byte vector store would suffice, and 16 byte stores per block for Bool. Vector stores
need a reinterpreted view whose length is a multiple of the block, which the generic
KernelAbstractions path does not offer portably yet.

### 2026-09-19 quick lane: TestU01 SmallCrush (`design/search/quick.jl`, RNGTest.jl's TestU01)

Seed 42, sequential stream through `Stateful` and `rand!`, about 9 s per run on batserv01.
Flag rule p < 1e-3 or p > 1 − 1e-3.

| stream | D20 law | D21 row law |
|---|---|---|
| K = 32, UInt32 | clean, min p 0.10 | clean, min p 0.107 |
| K = 32, Float64 | clean, min p 0.034 | clean, min p 0.016 |
| K = 1, UInt32 | clean, min p 0.094 | identical p-values to D20 |
| K = 1, Float64 | clean, min p 0.074 | identical p-values to D20 |

At K = 1 both laws give the same byte stream (row r holds chunks 8r to 8r + 7 at step 0,
and the D20 seed counter c·K equals c), and the identical p-values confirm the port. Pitfalls
of RNGTest.jl v1.6.1 (no `wrap`, a segfaulting `Unif01` closure, p-values only through the
TestU01 globals) are recorded in `quick.jl`.

### 2026-09-19 D21 row law, A100 (GPU 1, `benchmark/gpu.jl`, warmed, power-capped steady state)

Protocol: `nvidia-smi` shows no other process on GPU 1 except the idle context of the test
session and five zero utilization samples before each pass; 0.5 s warm-up per cell because
the SM clock idles at 765 MHz and operates at 1110 to 1320 MHz under the 250 W cap; minimum of
30 event timings; 2^27 elements. CUDA.jl 6.4 (CUDACore), KernelAbstractions 0.9.42, driver
570.124.06, Julia 1.13. The direct-store kernel `fill_lanes!`, no host synchronize. HBM2 peak
of this card is 1448 GiB/s.

Fill, GiB/s written:

| type | Tandem K = 32 | PureRNGs Philox4x32 | CUDA.jl native | cuRAND NativeRNG | CURAND |
|---|---|---|---|---|---|
| Float32 | 1295 | 1375 | 621 | 89 | 581 |
| UInt32 | 1262 | 1200 | 1112 | 160 | 932 |
| Float64 | 1295 | 1209 | 1079 | 319 | 458 |
| Bool | 1009 | 946 | 338 | 40 | – |

The Philox reference varies between passes (UInt32 1200 here, 1415 in the K sweep below,
Float64 1209 and 1419), while Tandem varies within 3 %. Both generators therefore reach 85
to 98 % of the HBM peak, and the difference lies within the pass-to-pass spread. The run
with the host synchronize still in place gave Tandem 1239 / 1242 / 1270 / 950 against Philox
1376 / 1315 / 1203 / 932, and the kernel alone 1296 / 1273 / 1305 / 995: synchronization cost
2 to 7 %, so `rand_fill!` no longer waits.

Fill against K (Tandem, same protocol, Philox in the same pass):

| K | Float32 | UInt32 | Float64 | Bool |
|---|---|---|---|---|
| 4 | 948 | 1403 | 1393 | 977 |
| 8 | 1364 | 1364 | 1353 | 1001 |
| 16 | 1338 | 1338 | 1334 | 1017 |
| 32 | 1285 | 1292 | 1277 | 1009 |
| 64 | 1275 | 1282 | 1273 | 932 |
| 128 | 1230 | 1209 | 1252 | 819 |
| Philox | 1391 | 1415 | 1419 | 946 |

A warp writes four rows 128·K bytes apart, so smaller K reduces the spacing of writes and
gains about 7 % from K = 32 to K = 8. K = 4 is compute-bound for Float32 (F costs eight steps
per four blocks plus the conversions). Workgroup size (64 to 1024) changes nothing within
2.5 %.

In-kernel draws, no array output (one work-item per chunk, K steps, all words folded into one
accumulator, GiB/s generated), against an inline Philox4x32-10 of the same kernel shape that
matches the Random123 known-answer vectors:

| K | Tandem | Philox4x32-10 | ratio |
|---|---|---|---|
| 8 | 2348 | 1969 | 1.19 |
| 16 | 4069 | 2743 | 1.48 |
| 32 | 4932 | 2889 | 1.71 |
| 64 | 5744 | 2986 | 1.92 |

Independent chains per work-item (draw kernel, GPU 1 idle, min of 30, GiB/s generated), to
test whether one serial step chain per thread leaves multiplication and clock execution stalled:

| chains | Tandem K = 32 | Philox | ratio | Tandem K = 64 | Philox | ratio | Tandem K = 32, 2^22 chunks | Philox | ratio |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 4906 | 2897 | 1.69 | 5729 | 2985 | 1.92 | 5232 | 2984 | 1.75 |
| 2 | 5014 | 2964 | 1.69 | 5717 | 3112 | 1.84 | 5299 | 3102 | 1.71 |
| 4 | 4754 | 2894 | 1.64 | 5387 | 2970 | 1.81 | 5268 | 3146 | 1.67 |

Registers per thread: Tandem 26, 32, 48 for 1, 2, 4 chains (48 registers cut occupancy to
62 %), Philox 30 to 32. The kernel is not latency-bound: 64 warps per SM already hide the
dependency chains, and in-thread parallelism gains at most 2 %. (In the first run of this table,
the benchmark's seed closure was not inlined, which cost Tandem 6 to 10 %.
Adding `@inline` to the closure corrected this without changing outputs.)

SASS of the draw kernels (CC 8.0, per step of the rolled loop body):

| mnemonic | Tandem | Philox4x32-10 |
|---|---|---|
| LOP3.LUT | 12 (10 generator, 2 fold) | 22 |
| SHF.L.W.U32.HI (funnel shift, the rotations) | 6 | 0 |
| IMAD.WIDE.U32 | 2 | 18 |
| IMAD.X | 0 | 3 |
| IADD3 | 1 | 2 |
| LEA | 0 | 1 |
| loop control | 0.5 | 3 |
| total per step | 21.5 | 49 |

Both kernels issue about 65 thread-instructions per SM-cycle, the documented integer rate of
64, so no mnemonic costs more than another and the step-time ratio (2.23 from the K = 32 and
K = 64 pair) matches the instruction ratio (2.28, 2.41 without the benchmark's fold). The
whole-kernel ratio is 1.7x at K = 32 because F costs 8.4 step-equivalents per chunk (20 % of
the work), 1.9x at K = 64, and 2.2x asymptotically. Philox's key schedule is hoisted out of
the loop and its first round's zero multiply folds away, so it runs 18 wide multiplies and
22 xors per block, not the 20 and 40 of the source. Tandem's step is 2 multiplies, 6
rotations, 10 xor/or, 1 add. The clock accounts for 9 of the 19.5 generator instructions,
so reducing hidden-update cost would improve performance.

CPU against K (Apple M4, one thread): K = 8 chain 1.11 ns, UInt32 fill 13.8 GiB/s, Float64
11.5; K = 16 1.01 / 17.4 / 13.9; K = 32 0.96 / 20.1 / 15.6; K = 64 0.94 / 21.9 / 16.5. K = 32
remains the default: K = 8 increases GPU fill throughput by 6 % and reduces CPU fill
throughput by 30 % and the draw advantage by 30 %.

### 2026-09-19 D22 bit positions, Bool fill

CPU (Apple M4, 2^22 Bools, BenchmarkTools): one thread 36.6 GiB/s of Bools (D21 byte law
16.8, PureRNGs Philox4x32 23.0, Xoshiro 65.1), 14 threads 178 (PureRNGs 97). The row expands
in registers (`_vexpand`) and the cost is the 32 stores of 32 bytes per 1024-bit row, so the
Bool fill runs at twice the word fill's byte rate instead of one times. `Stateful` Bool draw
2.25 ns (Float64 1.75, the bit index adds a shift).

GPU (A100, GPU 1, idle): expanding inside the chunk kernel gave 322 GiB/s at 2^27 Bools and
347 at 2^30, down from 1009 under the byte law, because each work-item wrote its own 128-byte
block and consecutive lanes sat 128 bytes apart, one line per lane per store instruction.
The two-pass fill (word fill into a temporary array, then `expand_bools!` with adjacent
work-items on adjacent 16-byte pieces):

| | GiB/s of Bools |
|---|---|
| two-pass `rand_fill!`, 2^27 Bools | 860 |
| two-pass `rand_fill!`, 2^30 Bools | 932 |
| `expand_bools!` alone, 2^30, workgroup 256 / 512 / 1024 | 1034 / 1052 / 935 |
| word pass alone (32 MB of words for 2^30 Bools) | 9300 equivalent |
| pieces per work-item strided by the grid, 2 / 4 / 8 | 1000 / 970 / 951 |
| pieces per work-item adjacent, 2 / 4 / 8 | 886 / 483 / 285 |
| `fill!(A, true)` (CUDA.jl byte fill) | 220 |
| `Random.rand!(CUDA.default_rng(), A)` | 342 |
| `fill!(UInt32)` (driver memset, the card's write ceiling) | 1430 |
| PureRNGs Philox4x32 Bool (from the D21 table) | 946 |

One 16-byte store per work-item and nothing else reaches 72 % of the memset ceiling, and
more stores per work-item lose either coalescing (adjacent) or nothing (strided). The
difference between the expansion alone and the two-pass total is the temporary array:
KernelAbstractions 0.9 has no early free on CUDA, so a tight loop leaves 32 MB per call to
the collector. Bool on the GPU is therefore level with PureRNGs, and eight times cheaper per
Bool in generator work than before.

### 2026-09-19 D21 lane-interleaved law, CPU (Apple M4, NEON, 14 threads, BenchmarkTools)

Same process, minimum over samples, 2^20 elements for fills. Xoshiro is `Random`'s SIMD
fill and scalar `rand`, Philox4x32 is PureRNGs at `main` (6a416c1).

| | Tandem | Philox4x32 | Xoshiro |
|---|---|---|---|
| chain, ns per Float64 draw | 0.96 to 1.07 | 3.16 | 0.64 |
| `Stateful`, ns per Float64 draw | 1.75 | | |
| fill Float64, 1 thread, GiB/s | 14.0 | 4.8 | 19.8 |
| fill Float32, 1 thread | 14.5 | 5.1 | 19.8 |
| fill UInt32, 1 thread | 18.1 | 4.7 | 26.4 |
| fill UInt64, 1 thread | 18.1 | | 26.4 |
| fill UInt8, 1 thread | 18.1 | | 26.3 |
| fill Bool, 1 thread | 16.8 | 23.0 | 65.3 |
| fill Float64, 14 threads | 84 | 44 | |
| fill UInt32, 14 threads | 97 | 41 | |
| fill Bool, 14 threads | 68 | 97 | |

The optimization sequence began with an eight-lane value whose chain cost was 9.6 ns.
`VecElement` storage increased this to 15 ns. Lane rotation with constant indices and
the key as a `UInt128` reduced it to 0.96 ns. The row copy reduced `Stateful` from
6.1 ns to 1.75 ns. The vector row store increased Float64 throughput from 7.5 to
14.0 GiB/s and left the 32-bit types at 18.1. The eight-lane step therefore limits fill throughput on NEON (about 23 cycles per 128-byte row, the multiplies as `umull`
pairs and every rotation as two shifts and an or). PureRNGs has higher Bool throughput because it packs one
bit per Bool, while the byte law (D12) consumes eight.

### 2026-09-21 CPU continuation: native Julia Float64 and contiguous task ranges

The earlier EPYC measurements ran at load averages 78–102. They are provisional and
support no speed claim. Quiet-host measurements below supersede them. No statistical or
cycle jobs ran during benchmarks. Julia 1.13, BenchmarkTools minima, fixtures allocated
before timing. Baseline is exact commit c33e4ec, loaded beside the candidate in the same
process. Three passes alternate order. Ranges are the three minima, not confidence intervals.
EPYC load averages were 6.18 / 4.93 / 2.77 after the paired runs, on 128 logical CPUs.

The AVX2 baseline's `_vfloat64` converts eight UInt64 values with scalar `vcvtsi2sd`. Its Float32 path
already uses vector conversion. Native Julia now forms four adjacent doubles in final
store order. On x86, exponent construction produces the high 52 bits and an exact addition
restores bit 53. AArch64 keeps native UInt64 conversion. Both implement the spec's exact
`Float64(raw >> 11) * 2^-53` mapping. See [SIMD.md](SIMD.md) for alternatives and sources.

Tasks now own contiguous group ranges. The previous cyclic assignment scattered each
task's writes. This improves large threaded fills on both tested CPUs. It does not remove
task overhead or select a good task count for every size.

AMD EPYC 7702P, AVX2, GiB/s written:

| type | elements | tasks | c33e4ec | candidate |
|---|---|---|---|---|
| Float64 | 2^20 | 1 | 4.00–4.09 | 6.83–7.00 |
| Float64 | 2^24 | 1 | 3.98–4.03 | 6.46–6.54 |
| Float64 | 2^20 | 16 | 25.80–28.55 | 33.23–38.62 |
| Float64 | 2^24 | 16 | 31.56–35.58 | 49.33–73.00 |
| Float64 | 2^24 | 32 | 34.13–43.96 | 48.79–53.47 |
| UInt32 | 2^20 | 1 | 10.66–10.73 | 10.61–10.64 |
| UInt32 | 2^24 | 16 | 42.35–43.62 | 63.54–66.90 |
| UInt32 | 2^24 | 32 | 46.90–48.93 | 71.17–73.82 |
| Bool | 2^20 | 1 | 28.84–29.27 | 29.29–29.42 |
| Bool | 2^20 | 16 | 13.27–14.42 | 12.48–14.25 |
| Bool | 2^24 | 16 | 58.46–66.64 | 58.76–62.44 |
| Bool | 2^24 | 32 | 49.01–50.14 | 52.70–56.78 |

Single-thread fills allocate zero bytes. Threaded ranges remain noisy, especially Float64
at 16 tasks. Overlapping ranges do not support a claim of improved Bool throughput.
At 2^20 Bools, one task outperforms both 16 and 32 tasks. Adaptive task sizing remains open.

Apple M4, same paired protocol, GiB/s:

| type | elements | tasks | c33e4ec | candidate |
|---|---|---|---|---|
| Float64 | 2^20 | 1 | 14.21–15.55 | 14.17–15.32 |
| UInt32 | 2^24 | 14 | 93.25–102.74 | 111.62–116.67 |
| Bool | 2^24 | 14 | 185.92–189.78 | 201.18–203.47 |

Fresh EPYC references, same process, one thread, 2^20 elements, zero allocations:

| workload | Tandem | PureRNGs Philox4x32 | Xoshiro |
|---|---|---|---|
| Float64 fill, GiB/s | 7.00 | 1.27 | 6.41 |
| Float32 fill, GiB/s | 10.90 | 1.58 | 14.24 |
| UInt32 fill, GiB/s | 10.94 | 1.54 | 16.62 |
| Bool fill, GiB/s | 29.96 | 4.85 | 39.08 |
| 64-draw chain, ns/Float64 | 3.27 | 8.50 | 1.31 |

Stateful takes 4.69 ns/draw. Tandem does not meet every Xoshiro speed target. Compilation
of the complete Float64 group fill succeeds for `generic` and `skylake-avx512` targets.
No AVX-512 hardware timing was performed. No long statistical campaign was launched.

### 2026-09-21 cycle census and correction of D14

The reviewed script is [search/cycles.jl](search/cycles.jl). New complete histograms and
seed witnesses were recorded in the working file `search/cycles-2026-09-21.md`.
An unpublished working record preserves the earlier partial output. The earlier report
misidentified the interrupted section: exposed maps only covered widths four and five.
The expensive part was a capped random sample, now opt-in. Complete return maps give
the full-step histogram without that sample. Every histogram checks total state mass.
Earlier named-state probes were raw states, not F-seeded states. They do not always reach
the longest cycle: hidden zero at width five and `(1,2,3,4)` at width seven are counterexamples.

The clock's unique fixed point follows directly from its recurrence. Equality of the last
three words forces `h2 = h3 = 0` and the updated first word before addition to zero.
The first word then forces `h0 = c` and `h1 = rotr(c, r1)`. At 32 bits this is
`(0x9e3779b9, 0x733c6ef3, 0, 0)`. Exposed zero is fixed under mix at that hidden state,
so the full step has a production fixed point. D14's fixed-point-free claim was false.

Inverting F at that full fixed state gives input exposed words
`(0x0f3efdab, 0x43903cd5, 0xa38fc1bc, 0x0d80eef1)` and input hidden words
`(0xad44d497, 0xb4f8cb25, 0xacc5b692, 0x6b4ae2b0)`. Forward production F reproduces it.
The domain and aux differ from the stream constants, so this particular state cannot be
seeded directly. This excludes neither other fixed points nor other states on the hidden
fixed slice. It is not a probability bound for production seeds.

At width four, all 65,536 exposed states on the fixed-hidden slice were inverted through F.
Exactly 258 preimages have the stream domain and aux among 2^24 legal raw-key/counter
inputs. Neither of the two full-step fixed points has such a preimage. One witness is raw
key `(13, 0, 13, 7)`, counter 97, yielding exposed `(6, 4, 0, 0)` and hidden `(9, 12, 0, 0)`.
Its full-step period is 50,000 while its hidden period is one. The reduced domains remain
distinct. These scaled maps are not quotients of production F, so reachability does not
lift to 32 bits.

| full step | states | cycles | fixed points | longest cycle |
|---|---|---|---|---|
| four-bit words | 2^32 | 148 | 2 | 1,842,819,640 |
| five-bit words | 2^40 | 190 | 2 | 507,745,310,952 |

These are exact histograms reconstructed from every hidden cycle's exposed return map.
A return-map cycle of length m over a hidden cycle of length L gives one full cycle of
length mL. The four-bit result agrees with the earlier direct full-step census.

The eight-bit hidden clock has 622 cycles. Its five longest cover 99.2252% of the states.
Of the 622 cycles, 598 have lengths 15, 30, 60, or 240, together covering 94,320 states.
Describing this as random-permutation-like would conceal a real structural excess.

A rotation change of coordinates reduces the full clock to
`x0' = (x0 xor x1) + c`, `x1' = x1 xor x2`, `x2' = x2 xor x3`,
`x3' = x3 xor rotl(x0 xor x1, S)`, where S is the sum of ring rotations modulo w.
Thus the cycle structure depends on that sum, even with the Weyl add. The default eight-bit
rounding gives S = 12, gcd(S, 8) = 4. Replacing rotation 6 by the equally close scaled value
5 gives S = 11, gcd(S, 8) = 1. That control has only 16 cycles, with longest 3,663,068,075.
The 15/30/60/240 family disappears. This implicates reduced-width rounding, not a production
failure or proof of safety. Production S = 45 is coprime to 32.

Without the Weyl add, the linear ring has exact order 30 at eight bits and 480 at 32 bits.
Checking all basis vectors at the claimed order and at order/p for each prime divisor
proves these orders. Keep the Weyl add. D24 remains open: the reduced seeded invariant
slice contradicts the earlier report's proposed closure, while its production significance needs
further analysis or a measured feedback alternative.

### 2026-09-21 GPU benchmark repair and validation

`GPUBench.sweep` still passed byte positions to the D22 bit-position kernel. It filled only
one eighth of the requested Float32/UInt32 output while reporting the whole array's size.
The sweep now computes bit positions and checks complete output against the CPU stream
after timing. Earlier results from this sweep are invalid under D22. This does not affect
the public `rand_fill!` benchmarks or the independent-chain draw kernel.

On an idle A100, all ten sweep cases match CPU output: Float32/UInt32, workgroup sizes
64–1024, and a partial final row. Independent draw chains C = 1, 2, 4 also match CPU folds.
The CUDA suite passes 113 tests. These small validation runs support no new GPU speed claim.

### 2026-09-21 fair CPU and GPU references

`benchmark/benchmarks.jl:compare_cpu` now compares Tandem, Xoshiro, and both 32-bit and
64-bit Philox variants from PureRNGs and Random123. Random123 1.7.1 is a benchmark-only
dependency. Both hosts use PureRNGs commit `ee4ceab563511bd64768aa2757e860dbba1032fe`,
with the same 26-file source hash
`0e0aae31d21b4ea47efc6b75681229445a178183a8f64bdcc91962ce472d62e7`.
An older remote PureRNGs copy was replaced before this comparison.

Julia 1.13, one task per fill, 2^20 and 2^24 elements, three passes with alternating order.
Each type/size uses the same preallocated array. Setup, compilation, and first touch are
untimed. Fill samples use `evals=1`; chains use `evals=100`. Reported values are the minimum
per pass. Every timed CPU reference case allocates zero bytes. EPYC load averages were
2.91/4.76/4.19 before and 9.39/6.21/4.71 after, on 128 logical CPUs. No cycle or statistical
jobs overlapped these benchmarks.

The former 64-draw chain did not cover Tandem's reseeding boundary when starting from its
immutable fixture, while mutable references advanced. Historical 64-draw results above are
short-burst measurements and are superseded for sustained comparisons. The current chain
covers 1024 Float64 draws: two complete K=32 groups, including reseeding.

EPYC, 2^20 elements, ranges across three passes:

| generator | Float64 GiB/s | Float32 GiB/s | UInt32 GiB/s | Bool GiB/s | chain ns/Float64 |
|---|---|---|---|---|---|
| Tandem | 7.00 | 10.92 | 10.74–10.80 | 29.96–30.09 | 3.110–3.114 |
| PureRNGs Philox4x32 | 1.27 | 1.58 | 1.53 | 4.82–4.85 | 7.674–7.691 |
| PureRNGs Philox4x64 | 1.30–1.31 | 1.77–1.78 | 1.47 | 3.19 | 6.222–6.226 |
| Random123 Philox4x32 | 0.77 | 0.68 | 0.72 | 0.177 | 10.540–10.562 |
| Random123 Philox4x64 | 1.34 | 0.69 | 0.75 | 0.186–0.187 | 7.260–7.323 |
| Xoshiro | 6.41 | 14.24–14.26 | 16.60–16.61 | 39.16–39.25 | 1.276–1.301 |

M4, same protocol:

| generator | Float64 GiB/s | Float32 GiB/s | UInt32 GiB/s | Bool GiB/s | chain ns/Float64 |
|---|---|---|---|---|---|
| Tandem | 13.77–15.13 | 14.31–14.48 | 18.31–19.15 | 35.46–37.38 | 0.979–1.092 |
| PureRNGs Philox4x32 | 4.81–4.96 | 5.02–5.46 | 4.67–4.74 | 22.22–22.39 | 2.826–2.827 |
| PureRNGs Philox4x64 | 3.98–4.19 | 5.13–5.54 | 4.21–4.25 | 14.44–15.05 | 1.893–2.129 |
| Random123 Philox4x32 | 1.80–1.83 | 1.74–1.82 | 1.79–1.80 | 0.454 | 3.622–3.994 |
| Random123 Philox4x64 | 3.05–3.11 | 1.51–1.53 | 1.56–1.59 | 0.395–0.400 | 2.205–2.420 |
| Xoshiro | 19.57–22.12 | 20.59–21.16 | 25.93–26.04 | 64.39–72.34 | 0.638–0.710 |

`Stateful` costs 4.746–4.753 ns/draw on EPYC and 1.924–1.984 on M4.
Random123's array/sampler APIs use 23 Float32 bits and 52 Float64 bits. Tandem, PureRNGs,
and Xoshiro use 24/53. The chain explicitly uses Random's sampler: Random123's direct
Float64 call on its UInt32 generator supplies only 32 bits. Random123 also consumes a
whole native word for each Bool, whereas Tandem and PureRNGs pack bits. Bool throughput
therefore measures their API choices as well as arithmetic. All GiB/s figures count bytes
written, not random-bit entropy.

GPU: A100 40 GB device 0, CUDA 6.4.0, three passes, 2^27 elements for public fills.
Compilation now precedes the 0.5-second warm interval. Each minimum covers 30 CUDA events.
The sweep removes its redundant synchronization inside the timed closure. Idle checks
find no other process before or after each run. An initial 100% reading after a run is
followed by four zero readings and reflects the benchmark's own work.

| workload, GiB/s | Tandem | PureRNGs Philox4x32 | PureRNGs Philox4x64 | Random123 Philox4x32 |
|---|---|---|---|---|
| Float32 fill | 1277–1285 | 1231–1371 | 858–892 | no CUDA fill API |
| UInt32 fill | 1235–1252 | 1146–1268 | 833–858 | no CUDA fill API |
| Float64 fill | 1282–1293 | 1172–1235 | 906–928 | no CUDA fill API |
| Bool fill | 861–882 | 932–947 | 344–349 | no CUDA fill API |
| core, one chain/thread | 4924–4954 | 2831–2905 | not measured | 2836–2888 |
| core, two chains/thread | 4973–5045 | 2963–3030 | not measured | 2959–2992 |
| core, four chains/thread | 4736–4764 | 2846–2872 | not measured | 2785–2902 |

The core benchmark uses PureRNGs' `_philox4x32` and Random123's exported `philox`, each
with ten rounds. Both run the same counter schedule and kernel shape. Each case generates
2^20 chunks × 32 blocks × 16 bytes, including Tandem seeding, and stores one XOR checksum
per chunk. CPU/GPU checksum agreement is checked before timing for all chain counts.
Checksums do not establish within-block word order. They validate this benchmark's folded
workload. The package CUDA suite separately checks complete ordered output, 113/113 passing.
The CUDA default RNG type is `GPUArrays.RNG{CuArray}` and the separate native RNG is
`cuRAND.NativeRNG`; the historical assumption that every CUDA default means Philox2x32
was removed.

Historical working directory for raw CPU/GPU tables and native/prototype experiments:
`search/performance-2026-09-21/`.

### 2026-09-21 remaining CPU task overhead

`search/task_sweep.jl` measures explicit task counts. A single exploratory measurement,
which does not establish a final tuning claim, gives the following: 65,536 UInt32 elements on EPYC take 21.5 μs with one task and 326.6 μs with 64;
M4 takes 13.6 μs with one and 6.4 μs with four. A 1 MiB Bool fill favors one task on EPYC
(33.5 μs versus 55.8 μs with four), but four or eight on M4 (about 10 μs versus 24.5 μs).
Large EPYC UInt32 fills favor about 32 tasks. A byte threshold fitted to one host reduces performance on
the other. Automatic task sizing remains open. Explicit `nthreads` already permits tuning.

### 2026-09-21 exact production fixed points and feedback prototype

At a fixed point, the last three hidden equations force `h2=h3=0` and
`h0 xor rotl(h1,7)=0`. Write `u=h0`, `v=rotr(u,7)`, and
`Q_m(x)=rotl(lo(x*m),16) xor hi(x*m) xor lo(x*m)`. For exposed state `(a,b,c,d)`,
the remaining equations are `c=Q_(u|1)(a)`, `a=Q_(v|1)(c)`,
`b=rotl(lo(c*(v|1)),16)`, and `d=rotl(lo(a*(u|1)),16)`.
The original step forces `u=C`. The feedback step below forces `u=C xor a`.
Enumerating all 2^32 values of a is necessary and sufficient for every full-state fixed point.

`search/fixedpoints.jl` checks this reduction against every state of a two-bit model, then
enumerates production words. The original has exactly one fixed point, the previously
known zero-exposed state. The feedback alternative has exactly two. Every inverse-F input
has the wrong stream domain and aux, and a counter outside canonical K=32's range `<2^52`.
All hits and inverse inputs also replay through the actual original/prototype Julia code.
Since T is bijective, a different state cannot enter a fixed point later. This closes
production period-one stream reachability for both recurrences. It proves nothing about
longer cycles or reachability of the whole fixed-hidden slice. Complete inputs and outputs
are in `reports/fixedpoints-2026-09-21.md` in the
[structural audit asset](VALIDATION.md#d16-and-f23-coverage-audit-updated-2026-09-27).

The isolated prototype in `search/feedback.jl` replaces one step by:

```julia
o, h = mix(o, h), clock(h)
return o, (h[1] ⊻ o[1], h[2], h[3], h[4])
```

F uses this same step. The production methods remain unchanged. Inversion first removes
the exposed-word XOR, then applies inverse clock and inverse mix. Every nonzero exposed
state on the old fixed-hidden slice leaves that slice within four steps: remaining there
forces four successive first output words to zero, which forces all exposed words to zero.
Bijectivity prevents a nonzero state from entering the surviving zero fixed point.

Paired original/prototype BenchmarkTools measurements, three alternating passes, 2^20
elements, one task, no allocations:

| workload | original | feedback |
|---|---|---|
| EPYC Float64 GiB/s | 6.98–7.01 | 6.77–6.78 |
| EPYC Float32 GiB/s | 10.90–10.92 | 10.75–10.78 |
| EPYC UInt32 GiB/s | 10.76–10.88 | 10.73–10.75 |
| EPYC scalar ns/Float64 | 3.110–3.127 | 3.140–3.144 |
| M4 Float64 GiB/s | 13.97–15.30 | 13.19–14.07 |
| M4 UInt32 GiB/s | 17.92–19.73 | 17.14–17.24 |
| M4 scalar ns/Float64 | 0.979–1.024 | 0.983–1.021 |
| A100 core GiB/s, one chain/thread | 4917–4920 | 4627–4639 |

The GPU loss is about 6%. M4 ranges are noisy. Prototype fills match their scalar stream
across two reseeding groups for UInt32, Float32, Float64, and Bool. Its GPU checksum matches
the prototype CPU recurrence. This is a measured candidate, not an adopted or statistically
qualified generator. Adoption would change F, all seeds, derived keys, and stream vectors.

The complete four-bit feedback census contains 26 cycles, versus the original's 148.
Its longest has 2,159,917,971 states. The sum of all lengths is exactly 2^32. Its four
cycles of length at most 32 have periods 1, 1, 12, and 23. None contains a legal reduced
stream seed. The raw histogram is `reports/feedback-cycles-2026-09-21.md` in the
[structural audit asset](VALIDATION.md#d16-and-f23-coverage-audit-updated-2026-09-27).
This reduced model is not a quotient of the production map.

Both recurrences also completed a short PractRand 0.96 screen through 2^28 bytes, standard
tests/folding (`-tf 1 -te 0`). Each uses seed 42, K=32 sequential/chunk-start/same-chunk XOR/
bit-zero projections, plus sequential K=1 and K=64. Neither produces a suspicious or FAIL
label. Each has three cases with transient `unusual` labels. All final 2^28 sections have
no anomalies. These are screening results, not a release qualification. Raw reports and
protocol hashes were recorded in the working directory `search/feedback-screen-2026-09-21/`.

### 2026-09-21 statistical projection repair

The production PractRand adapter still inherited the search harness's contiguous-chunk
projection rules. Under D21, `chunkstart` selected some later rows, and `xorstep` XORed
neighboring lanes rather than consecutive steps of one chunk. The adapter now dispatches
row-aware projections, requires complete groups in each input buffer, and writes to a new
`final-row-bit-v1` log directory so old D20 results cannot satisfy a resumed matrix.
An independent scalar-chunk oracle checks 64 chunk-start words and 1,984 same-chunk XOR
words across two groups. Both old projections fail that oracle; both corrected ones pass.
Historical D20 statistical results remain valid for D20. The final-layout D16 matrix is pending.

Review also found that the runner could label empty logs as passing, reuse weaker test flags,
and restart an interrupted lane from its already advanced generator. It now requires a
successful child exit plus the requested target-length report, records an explicit completion
marker, and reports incomplete runs as `:incomplete`. Reuse checks test flags, executable
and source hashes, Julia version, projection, and initial generator. Each run receives a
deep copy of that generator. Old metadata is invalidated before replacing a log, closing
the interruption window between a new log and its matching metadata.

Runtime checks use real 2^20-byte standard and expanded PractRand runs: identical calls
reuse their completed log, changed flags rerun, and the template remains at position zero.
An empty report and a successfully exited child with no test output both remain incomplete.
The final runner also passes the current generator and rejects a known weak three-round
Philox control at 2^20 bytes. Uppercase suspicious labels retain their severity.

## 2026-09-21: feedback adopted as v2, native Julia speed work

D24 is approved. SPEC draft 4 names `Tandem8x32-v2-K32` and the other v2 K variants.
The new first exposed word is xored into the first hidden word after the clock addition.
F uses the same step. Constants, eight F rounds, K, row order, and bit extraction stay fixed.
Seed whitening, derived keys, and stream vectors change. The independent UInt64 scalar
oracle in `search/reference_v2.jl` supplies the new vectors and matches 256 random T/F
states. A separate BigInt review matches the principal vectors. Old cycle-return-map
analysis in `cycles.jl` remains explicitly v1 analysis.

### Performance experiments and selected change

All candidates preserve the approved feedback recurrence. `feedback_speed.jl` checks 256
random states through seeding and 64 steps for each form. CPU experiments compare complete,
aligned fills. These experiments omit public boundary work and do not establish API throughput claims.

- Computing the clock first gives no broad gain.
- Carrying `z = h0 xor o0` can move feedback into GPU three-input logic, but the compiled
  loop does not become smaller. Saved canonical and encoded SASS both unroll eight steps,
  with 181 loop instructions: 104 LOP3, 48 SHF, 16 IMAD, and loop/add control. Registers
  rise from 24 to 26, with no local-memory spills. A100 gains only about 1–2%; EPYC UInt32
  loses about 7%. Encoding F as well does not recover that loss.
- Explicit two/four-step unrolling gives no stable A100 gain. Two independent chains gain
  about 2–2.6% in the draw experiment. That is a kernel workload choice, not a recurrence change.
- A separate native Julia loop for a complete CPU group removes repeated row-boundary
  decisions. Float32 retains the bounded loop because the separate loop regresses on
  both measured CPUs. No new LLVM call, assembly, dependency, or encoded state is adopted.

Paired public fills, initial feedback prototype versus adopted v2, 2^20 elements, one task,
three alternating BenchmarkTools passes. All cases allocate zero bytes:

| host/type | initial feedback, GiB/s | adopted v2, GiB/s |
|---|---|---|
| EPYC UInt32 | 10.697–10.720 | 14.643–14.674 |
| EPYC Float64 | 6.776–6.779 | 7.641–7.647 |
| EPYC Float32 | 10.764–10.792 | 10.711–10.736 |
| EPYC Bool | 29.846–30.010 | 30.923–31.111 |
| M4 UInt32 | 17.786–19.203 | 18.517–19.231 |
| M4 Float64 | 13.191–14.474 | 13.408–13.723 |
| M4 Float32 | 13.938–14.287 | 13.907–15.633 |
| M4 Bool | 36.337–37.026 | 41.556–41.630 |

EPYC UInt32 improves about 37%, Float64 13%, and M4 Bool 12–15%. Other M4 ranges overlap.
The small EPYC Float32 difference includes the corrected terminal-row bounds. It does not
support a claim that the complete-group path improves Float32 throughput. Raw pairs are `feedback-adopted-{m4,epyc}.tsv`
in `search/performance-2026-09-21/`. Earlier exploratory tables use the `feedback-speed`,
`feedback-full`, and `feedback-unroll` prefixes there.

### Current fair comparisons

Fresh v2 runs use `benchmark/benchmarks.jl`, one thread, 2^20 elements, 1024-draw chains,
three alternating passes. PureRNGs has the same source revision on both hosts, as recorded
above. Random123 1.7.1 uses 23/52 random bits for its float APIs versus 24/53 for the others.

| EPYC generator | chain, ns/draw | Float64, GiB/s | Float32, GiB/s | UInt32, GiB/s | Bool, GiB/s |
|---|---|---|---|---|---|
| Tandem v2 | 3.155–3.171 | 7.639–7.645 | 10.730–10.750 | 14.687–14.700 | 30.933–30.991 |
| PureRNGs Philox4x32 | 7.743 | 1.274 | 1.583–1.587 | 1.533–1.534 | 4.836–4.847 |
| PureRNGs Philox4x64 | 6.203–6.204 | 1.295–1.296 | 1.786–1.792 | 1.475–1.512 | 3.229–3.232 |
| Random123 Philox4x32 | 10.540–10.545 | 0.769 | 0.683–0.684 | 0.717–0.719 | 0.177 |
| Random123 Philox4x64 | 7.100–7.101 | 1.378–1.383 | 0.702–0.704 | 0.745–0.747 | 0.185 |
| Xoshiro | 1.293–1.294 | 6.410–6.412 | 14.231–14.242 | 16.607–16.624 | 39.109–39.219 |

M4 v2 Float64 fills reach 13.811–15.089 GiB/s versus Xoshiro's 19.603–20.463. Chains cost
0.982–1.003 ns versus 0.638–0.719. All figures and other types are in `v2-fair-{m4,epyc}.tsv`.

A100 v2 core draws reach 4657–4682 GiB/s generated for one chain per thread, versus
2891–2895 for PureRNGs Philox4x32 and 2861–2901 for Random123 Philox4x32. Both references
use their actual library cores and fold all words. Two-chain v2 reaches 4756–4787. These
are the usual 2^20 chunks, K=32, minimum of 30 CUDA events after compilation and 0.5 seconds
of warm-up. Every draw shape matches the CPU checksum. Raw results: `v2-core-a100.md`.

Public GPU fills compare a frozen v1 source snapshot with the adopted v2 extension, including
its boundary fixes. Three alternating passes, 2^27 elements, the same warm-up/event protocol:

| type | v1, GiB/s | v2, GiB/s |
|---|---|---|
| Float32 | 1284.0–1288.9 | 1257.0–1294.4 |
| UInt32 | 1251.7–1294.6 | 1238.3–1290.1 |
| Float64 | 1292.8–1306.0 | 1298.6–1304.9 |
| Bool | 846.2–857.8 | 843.5–855.3 |

Ranges overlap. The roughly 6% recurrence core cost is not a measured 6% full-fill penalty.
`adoption_gpu.jl` and `adoption-fills-a100.tsv` preserve the comparison. GPU 0 had no other
process and all five utilization samples were zero before each run. No CPU statistics or
cycle jobs ran during timings. Native SIMD and task-count limits from earlier sections remain.

### Diffusion, statistical screen, and boundary checks

`feedback_avalanche.jl` measures all 256 input/output bits. F6 on 4096 bases has four cells
outside the conservative joint 1% Hoeffding/union bound, with one flip rate near 0.25.
F7 passes on 4096 bases. F8 passes on both 4096 and 16,384 bases. The four-matrix thresholds
are 0.0465811 and 0.0232905 respectively; F8's largest bias at 16,384 is 0.0164795. Thus the
v1 claim that six rounds suffice no longer applies. Eight rounds are retained without a claim of a proved
safety margin. This screen does not establish statistical independence.

T is measured in all four half-to-half quadrants at 1, 2, 4, 8, 16, and 32 steps, with
1024 bases. The one-step exposed-b positive control checks its exact two-bit output pattern.
All quadrants lose their exact zero/one cells by eight steps. Early-step structure is expected
from the light Feistel. Full count summaries, seed, sample sizes, and source hashes are in
`search/feedback-avalanche-2026-09-21.txt`.

The production v2 path completes six PractRand cases through 2^28 bytes: K32 sequential,
chunk starts, same-chunk adjacent-step XOR, bit 0, plus K1/K64 sequential. There are no
suspicious or FAIL flags. Sequential K32, XOR, and K64 each have transient unusual flags;
all final-length reports have no anomalies. This repeats the prototype result. Reports and
source/protocol sidecars are in `search/v2-screen-2026-09-21/`. The D16 release matrix still
needs full-length runs and the other batteries. Historical v1 2^36-byte evidence does not
qualify v2.

Review found inherited boundary defects while checking the full-group path. CPU and GPU
row/block end addition could wrap and select an oversized store. Both now use differences,
and typed fills reject alignment wrap. GPU Bool staging queues the required bit range
directly, including a partial final word, and reads a second word only when needed. This
also avoids the constructor's 2^63 start restriction for already advanced streams. SPEC
now states the existing representable endpoint limit explicitly: checked fills cannot end
at 2^64 because the returned position is UInt64. Scalar hot paths stay unchecked as specified.

Julia 1.13 CPU suites pass 216/216 on M4 and EPYC; Julia 1.10.12 passes 216/216. CUDA passes
119/119. The added checks cover a padded one-word destination in the final row, alignment
wrap, a one-bit GPU Bool tail, advanced positions above 2^63, and the final partial word.
No CUDA compute-sanitizer is installed on this host, so the short-tail read bound also rests
on direct index analysis. Independent review covers the recurrence, oracle vectors, bounds,
diffusion interpretation, SASS, and benchmark ranges. JuliaFormatter and `git diff --check` pass.

### Reproducing the frozen CPU comparison

`performance-2026-09-21/before-feedback-source.tar.gz` contains the exact source before D24,
and its old GPU extension. `before-feedback.patch` records the source delta from c33e4ec.
Extract the archive outside the watched worktree. Main package imports can reload edited
source, so historical comparisons must use this separate path. The old paired benchmark
and screen entry points now reject a v2 package instead of silently comparing v2 with itself.

In a fresh owned Kaimon session, load BenchmarkTools and the current package, then create
`Main.TandemFeedback` from the extracted source and override only its step:

```julia
module TandemFeedback
include("/path/to/extracted/tandem-before-feedback-src/TandemRNG.jl")
@eval TandemRNG begin
    @inline function step(o::NTuple{4,W}, h::NTuple{4,W}) where {W<:Word}
        o, h = mix(o, h), clock(h)
        return o, (h[1] ⊻ o[1], h[2], h[3], h[4])
    end
end
end
include("design/search/feedback_full.jl")
open("paired.tsv", "w") do io
    FeedbackFull.compare(io; candidate=TandemRNG)
end
```

For the GPU pair, load the same extracted source as `Main.FrozenV1`, load its archived
extension with `using ..TandemRNG`, and load the current source/extension as `Main.Adopted`.
Then run `AdoptionGPU.fills(io)`. The CPU paired baseline was checked in the measured session:
its `_fill_group!` had no full-group helper and its step had the approved feedback equation.

## 2026-09-26: completed coverage audit and public API benchmarks

The historical pending D16 matrix above is complete at its specified depths. The
[validation audit](VALIDATION.md) maps all requirements to retained records, including
203 structured screens and their continuations. Original flags and limits remain explicit.
The structural reports and frozen reproduction sources form a separate audit supplement.

The [current performance record](search/performance-2026-09-26.md) compares native and
bridge calls with PureRNGs, Random123, and Xoshiro on idle EPYC and A100 hardware.
The public runner in `benchmark/run.jl` records hashes, environments, and run status.
D27 adds all PureRNGs result types and reduces native scalar cache and extraction costs.

## 2026-09-27: completed bounded F-round campaign

The [dated margin record](search/margin-2026-09-27.md) completes the fixed F5–F8 matrix:
32 discovery and 40 triggered replication runs at 256 GiB each, plus the F4 control.
Three F5 probes fail on the discovery key and both reserved keys. F6 and F7 each
retain one mild flag. F8 has no suspicious or FAIL labels in its 18 runs.

The campaign adds direct split halves and a bijective high-counter mapping to the
earlier chunk-start diagnostic. The independent oracle checks all feeds, boundary
indices, and refill behavior. All 1,428 checks pass on macOS and Linux. All 97 input
prefix hashes match across hosts. Full logs and failed starts accompany the frozen
protocol and sources in a separate margin evidence asset. D8 records the bounded
interpretation. Production remains F8 and gains no configurable-round API.
