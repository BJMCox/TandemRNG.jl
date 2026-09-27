# TandemRNG

[![Build Status](https://github.com/BJMCox/TandemRNG.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/BJMCox/TandemRNG.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/BJMCox/TandemRNG.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/BJMCox/TandemRNG.jl)
[![Documentation](https://img.shields.io/badge/docs-guide-blue.svg)](docs/src/index.md)
[![Julia 1.10+](https://img.shields.io/badge/Julia-1.10%2B-9558B2?logo=julia)](https://julialang.org/downloads/)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache_2.0-blue.svg)](LICENSE)

Tandem is a random number generator designed for GPUs first: **T**wo-half **A**symmetric
**N**onlinear **D**uplex with **E**volving **M**ultipliers.

- Eight 32-bit words, using 32x32→64 multiplication, xor, rotate, and add.
- A hidden half runs a bijective clock and receives feedback from the new exposed half.
  The exposed half is a Philox-shaped Feistel whose multipliers and masks come from the hidden half.
- The stream is cut into chunks of `K` steps. A keyed seeding function starts every chunk, so
  splitting and forking cost one seeding per pair of children. Random access adds at most
  `K` steps after seeding.
- Chunks come in groups of eight, and the stream is a sequence of 128-byte rows: the eight
  16-byte blocks of a group at one step. On a GPU each work-item owns one chunk and eight
  adjacent work-items write one contiguous row per step, direct 16-byte stores, no shared
  memory. On a CPU the eight chunks step together, with one eight-lane vector per state word.
- A bit-aligned stream law. Scalar components stay inside 128-bit blocks. Complex draws
  compose two real draws. Fills and scalar loops agree on every supported backend.
- All 18 PureRNGs result types: Bool, 8–128-bit integers, Float16/32/64, their complex
  types, and Char. Device fills exclude 128-bit integers. Metal also excludes Float64
  and ComplexF64. Reactant supports Bool, 8–64-bit integers, and Float16/32/64.
- The transport form of a generator is its 128-bit key plus a 64-bit bit position.

[SPEC.md](SPEC.md) defines the algorithms, stream order, draw mappings, and test vectors.

## Status

Research software under active development. Version `Tandem8x32-v2-K32` adds feedback
on 2026-09-21, changing seeded keys and streams. Its eight-round seeding function
passes the bounded diffusion screen. Default PractRand runs complete 1 TiB each for
K1/K32/K64. All 19 derived streams complete 256 GiB with expanded filters and 4 TiB
with default filters. Reviewed statistical flags remain in the record. HWD completes
three 1 TiB runs. BigCrush completes all 12 cases with no strong flags. gjrand completes
10 TiB with overall p=0.588 (`ok`). The fixed F5–F8 margin campaign completes 72 runs
at 256 GiB each. F5 fails repeatedly across three keys. F8 has no suspicious or FAIL
labels in its 18 runs. Release assessment remains separate. Values may still change
before 0.1.0.
The prepared evidence assets retain logs, protocols, input hashes, and flagged results.

CI runs on pushes to `main`, version tags, and pull requests. Coverage reports the CPU package tests.
GPU validation and optional integration suites run separately.

## Use

```julia
using TandemRNG

rng = Tandem8x32(42)                    # chunks of 32 steps, seed whitened through F
x, rng = rand_next(rng, Float64)        # pure: value and advanced generator
A = Vector{Float32}(undef, 1_000_000)
rng = rand_fill!(rng, A)                # threaded fill, same values as scalar draws
rand_at(rng, Float64, 17)               # 17th Float64 from here, without advancing

children = splitrng(rng, 1000)          # by index, from the key alone
rng, forks = forkrng(rng, 8)            # at the current step, parent moves on
proposals = subrng(rng, 1)              # by purpose id

st = Stateful(42)                       # Random.AbstractRNG for rand, rand!, randn, ...
rand(st, 1:6)
```

GPU fills load with `using KernelAbstractions, GPUArraysCore` and any backend array:

```julia
using CUDA, KernelAbstractions, GPUArraysCore, MLDataDevices
rng = rng |> CUDADevice()
B = CUDA.zeros(Float32, 1 << 24)
rng = rand_fill!(rng, B)               # one work-item per chunk, equals the CPU fill
```

MLDataDevices is a core dependency. Binding preserves the key and position.
Allocating draws use the bound backend, and fills reject destinations on another backend,
including empty arrays. `rng |> CPUDevice()` restores CPU binding. Tokens name a backend;
select a physical GPU through the backend before allocation and execution.

Beyond the `Random` bridge, a `Stateful` keeps a copy of the current row's words, so `rand`
costs a check and four loads per draw.

Reactant supports compiled uniform draws, fills, random access, and static derivations.
Convert the generator with `Reactant.to_rarray(rng)` before compilation to keep its key
and position as runtime inputs. See [the integration guide](docs/src/index.md#reactant).
TandemRNG provides an optional PureRNGs extension for its uniform draw and split interface.

## Precompilation

PrecompileTools caches scalar draws, fills, splitting, forking, and the `Random` bridge.
The core workload covers every supported chunk length and draw type.

Optional CUDA, AMDGPU, and Metal extensions precompile concrete GPU array methods when
installed with KernelAbstractions and GPUArraysCore. On Julia 1.12 or later, CUDA and
AMDGPU also compile small device fills when a working GPU is available. Metal coverage
is host-only. No GPU is required to load or precompile TandemRNG.

See the [precompilation notes](docs/src/index.md#precompilation) for coverage and version
limits. Use `benchmark/latency.jl` in fresh Julia processes to measure first-use latency.

## Speed

Tandem v2 on AMD EPYC 7702P (AVX2), Julia 1.13, 2026-09-26. One task, 2^20 elements,
three BenchmarkTools passes with alternating generator order. Scalar chains include
at least two complete reseeding periods. Every case below allocates zero bytes.

| generator | chain, ns/draw | Float64 fill, GiB/s | Float32 fill, GiB/s | UInt32 fill, GiB/s |
|---|---|---|---|---|
| Tandem native | 2.49–2.50 | 7.65–7.66 | 10.70–10.72 | 14.75–14.76 |
| Tandem bridge | 2.48–2.50 | 7.65–7.66 | 10.70–10.71 | 14.75–14.76 |
| PureRNGs Philox4x32 | 7.72–7.77 | 1.27–1.27 | 1.58–1.59 | 1.53–1.53 |
| PureRNGs Philox4x64 | 6.21–6.23 | 1.28–1.30 | 1.77–1.78 | 1.47–1.48 |
| Random123 Philox4x32 | 10.50–10.52 | 0.77–0.77 | 0.68–0.68 | 0.72–0.72 |
| Random123 Philox4x64 | 7.10–7.13 | 1.40–1.40 | 0.71–0.71 | 0.76–0.78 |
| Xoshiro | 1.29–1.29 | 6.41–6.41 | 14.23–14.23 | 16.61–16.62 |

Random123 1.7.1 supplies 23/52 random bits for these Float32/Float64 APIs; the other
generators supply 24/53. Both hosts use the same PureRNGs source revision.

Earlier Apple M4 measurements (2026-09-21), before the current scalar changes: Tandem's Float64 fill reaches 13.81–15.09 GiB/s against
Xoshiro's 19.60–20.46. Its scalar chain costs 0.98–1.00 ns against 0.64–0.72.

Native Julia loops for complete groups improve EPYC UInt32 fills by 37% and Float64 by
13% against the initial feedback prototype. M4 Bool fills improve by 12–15%; other M4
ranges overlap. Small fills can lose speed with many tasks.

Earlier NVIDIA A100 40 GB core measurements (2026-09-21), idle GPU, three passes. Compilation precedes a 0.5-second
warm-up; each figure uses the minimum of 30 CUDA event timings.

| | Tandem v2 K=32 | PureRNGs Philox4x32 | Random123 Philox4x32 |
|---|---|---|---|
| core draws, one chain/thread, GiB/s generated | 4657–4682 | 2891–2895 | 2861–2901 |

The core comparison calls both libraries' actual Philox functions in identical kernels,
folding all generated words into one stored checksum per chunk. Tandem includes seeding.
Its core throughput is about 1.6× either reference. Full Float32 fills reach 1257–1294
GiB/s, overlapping v1's paired range despite feedback's roughly 6% core cost.

The current public A100 APIs reach about 1,280 GiB/s for packed Float64 fills and
597 GiB/s for chained scalar Float64 calls. These measure different work.
Use the [public reproduction guide](benchmark/README.md) to benchmark supported result types.

## License and contact

Copyright 2026 Jessica Cox <jmcox@posteo.de>

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE).

Report bugs and request features through [GitHub issues](https://github.com/BJMCox/TandemRNG.jl/issues).
