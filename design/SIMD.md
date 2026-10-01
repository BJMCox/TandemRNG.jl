# Native Julia SIMD, 2026-09-21

Float32 and Float64 conversion now use native Julia tuple expressions. Float64 forms
outputs in final store order, removing `_vfloat64` and its intermediate 16-word shuffle.
The Float32 replacement also removes the unused `_vand` primitive. These conversion edits introduce no production dependency
or change to the stream law. The later v2 feedback revision changes
streams separately; its measurements are in SEARCH's final section.
Paired measurements and validation are in [SEARCH.md](SEARCH.md).

## Compiler support

`NTuple{N,VecElement{T}}` maps to an LLVM vector. `ntuple(f, Val(N))` expands constant tuple
expressions. LLVM's SLP pass can combine independent scalar expressions, but Julia does
not promise that transformation. Inspect the complete caller and measure the public fill.
[Julia SIMD docs](https://docs.julialang.org/en/v1/base/simd-types/),
[Base ntuple](https://github.com/JuliaLang/julia/blob/master/base/ntuple.jl),
[LLVM vectorizers](https://llvm.org/docs/Vectorizers.html).

`@simd` permits iteration reordering. It does not force tuple vectorization, and the K
successive RNG steps depend on their predecessors. Independent conversion/store loops
can qualify. [Base contract](https://github.com/JuliaLang/julia/blob/master/base/simdloop.jl).

SLP already runs at Julia's default `-O2`. `Base.Experimental.@optlevel 3` alone cannot
raise the process setting: Julia takes the lower module/process level, subject to
`--min-optlevel`. A fresh `-O3` probe did not repair the slower isolated-helper layout.
[Compiler pipeline](https://github.com/JuliaLang/julia/blob/master/src/pipeline.cpp),
[optimization-level rule](https://github.com/JuliaLang/julia/blob/master/base/experimental.jl).

## Measured choices

Development probes measure single-thread Float64 fill over 2^20 elements in GiB/s.
The minima from these exploratory measurements determined the design. The repeated exact-base comparisons in SEARCH.md support final claims.

| conversion/layout | EPYC AVX2 | M4 |
|---|---|---|
| baseline handwritten UInt64 conversion | 4.09 | 14.1 |
| handwritten LLVM split conversion | 6.85–6.87 | 11.5 |
| native split tuple helper, old store layout | 4.94–4.96 | not measured |
| native signed split, final store order | 5.44 | 15.33 |
| native unsigned 32-bit halves, final store order | 6.07 | 9.34 |
| native high 52 bits plus restored bit 53 | 6.99 | 12.44 |

The chosen code uses the last construction on x86 and direct UInt64 conversion elsewhere.
Each four-double store is formed directly, giving SLP adjacent outputs and removing the
previous convert/reinterpret/shuffle sequence. An isolated helper generated vector instructions
but still reduced throughput when inlined into the full fill. Its assembly alone was therefore
insufficient to assess performance.
The final EPYC group-fill assembly contains eight `vaddpd` instructions. Scalar conversions
remain only in the partial-row path. LLVM folds subtraction of one into vector addition.

For x86, let `m = raw >> 12` and `b = (raw >> 11) & 1`. Reinterpreting
`0x3ff0000000000000 | m` as Float64 and subtracting one gives exactly `m * 2^-52`.
Adding `b * 2^-53` gives `(raw >> 11) * 2^-53`, including zero and the largest output.
This retains 53 random bits. No fast-math flag or approximate conversion is used.
AArch64's native UInt64 vector conversion avoids the measured cost of that construction.

## Portability limits

Generic and `skylake-avx512` code-generation probes pass. AVX-512DQ supplies unsigned
64-bit-to-double conversion, so the x86 choice is not proven optimal on every x86 CPU.
No AVX-512 hardware timing was available.
[Intel instruction reference](https://cdrdv2-public.intel.com/782156/325383-sdm-vol-2abcd.pdf).

A precompile-time host-feature constant should be avoided. Base's internal CPUID helpers inspect the
host, not a stable compiler-target contract. Target-specific tuning should remain based on measurements.
[Base CPU source](https://github.com/JuliaLang/julia/blob/master/base/cpuid.jl),
[Julia multiversioning](https://docs.julialang.org/en/v1/devdocs/llvm-passes/).

SIMD.jl provides a Julia vector API but implements its intrinsics through LLVM. It can
reduce local IR maintenance at the cost of a dependency. It does not make SIMD automatically
compiler-discovered. [SIMD.jl](https://github.com/eschnett/SIMD.jl),
[implementation](https://github.com/eschnett/SIMD.jl/blob/master/src/LLVM_intrinsics.jl).

The remaining local LLVM primitives use generic arithmetic and shuffles, not processor
assembly. Their earlier native tuple forms failed to preserve vector rotations or the row transpose.
Future changes should prefer native Julia and use complete-fill measurements on both CPU families.

## Remaining primitives, measured on both hosts

Eight isolated native replacements and three combinations were checked against full public
fills for four output types. Each exploratory measurement used 2^20 elements, one thread, BenchmarkTools, and
zero allocations. These selection probes do not support claims of repeatable speedups. Source:
[`search/native_simd.jl`](search/native_simd.jl). Raw results:
[`search/performance-2026-09-21/`](search/performance-2026-09-21/).

| replacement | EPYC result | M4 result | decision |
|---|---|---|---|
| tuple xor/add/or/multiply | UInt32 10.80 → 3.50 GiB/s | 18.29 → 12.36 | retain LLVM |
| shared wide product | UInt32 10.80 → 7.51 | 18.29 → 11.74 | retain LLVM |
| rotate via shifts or bitrotate | similar to baseline | UInt32 18.29 → 9.43–10.17 | retain LLVM |
| constant tuple shuffle | UInt32 10.80 → 8.63 | similar to baseline | retain LLVM |
| Float32 conversion | similar to baseline | similar to baseline | native Julia |
| Bool byte expansion | 30.28 → 7.09 GiB/s | 36.00 → 7.82 | retain LLVM |
| Bool scalar shifts | 30.28 → 0.17 | 36.00 → 12.61 | retain LLVM |

Combining shuffle and Float32 still reduces EPYC throughput. Replacing the entire core
also reduces throughput on both hosts, so the isolated LLVM/native boundary does not explain
the reduction.

The final paired Float32 check uses the exact source immediately before the replacement.
EPYC: 10.90–10.92 → 10.91–10.92 GiB/s. M4: 14.05–14.07 → 14.04–16.09, with similar variation
in the unchanged UInt32 control. The simpler native code is retained without a speedup claim.
CPU suites pass on both hosts, including Julia 1.10.12 on M4.
