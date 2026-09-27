```@meta
CurrentModule = TandemRNG
```

# TandemRNG

```@docs
TandemRNG
```

The repository's `SPEC.md` defines the algorithms and provides test vectors.

## Generator

```@docs
Tandem8x32
Tandem8x32{K}(::NTuple{4,UInt32}, ::Integer)
Tandem8x32{K}(::Integer)
rngkey
rngposition
chunk_length
```

## Draws

```@docs
rand_next
rand_at
rand_fill!
```

## Split disciplines

```@docs
splitrng
forkrng
subrng
```

## Random API

```@docs
Stateful
```

## Precompilation

TandemRNG uses PrecompileTools automatically during package precompilation.
Its CPU workload covers all 17 supported chunk lengths, all draw types, scalar and
threaded fills, splitting, forking, and `Stateful` operations. The default chunk length
also covers matrices, contiguous and strided views, allocating draws, and bulk normal
and exponential draws. Workloads use local seeded generators and join their tasks.

Backend packages remain optional. Install a backend together with KernelAbstractions
and GPUArraysCore to enable its precompile extension:

| Backend | Versions | Coverage |
|---|---|---|
| CUDA | 5.8 or later in 5.x, 6.x | Device and unified memory host methods; device fills when available |
| AMDGPU | 2.x | HIP array host methods; device fills when available |
| Metal | 1.7 or later in 1.x | Private and shared storage host methods |

Backend workloads cover vectors and matrices, all supported draw types, and chunk
lengths 1, 32, and 64. Device fills exclude 128-bit integers. Metal also excludes
Float64 and ComplexF64. Device fills cover aligned and shifted
starts, including the two-pass Bool path. Device workloads use the first listed memory
family in the extension; the other memory families receive host precompile directives.

Backend precompilation requires Julia 1.10.11 or later in 1.10, or Julia 1.11.2 or later,
which guarantee extension dependency ordering. Earlier supported Julia versions retain
runtime GPU support. Device compilation additionally requires Julia 1.12 or later and
skips coverage and forced bounds-checking builds. Metal skips device initialization
during downstream package precompilation, so this extension caches only host methods.
GPU availability determines whether device workloads run. Persistent device-code reuse
also depends on the backend/compiler version and target. Other devices and backend
versions can still require compilation at first use.

Aggressive coverage increases package precompile time and cache size. The
`benchmark/latency.jl` script measures a sequential first-use API sweep in a fresh
process. Compare the same script, Julia version, flags, and thread count between
checkouts after `Pkg.precompile()`. Its `load` row records package import separately.
Later rows can reuse code compiled by earlier rows, so they are not independent cold
measurements. The script excludes process startup and sustained throughput.

## Device binding

MLDataDevices is a core dependency. A generator carries a concrete backend token.
Bind it before allocating or filling device arrays:

```julia
using TandemRNG, MLDataDevices, CUDA

rng = Tandem8x32(42) |> CUDADevice()
values, rng = rand_next(rng, Float32, 1024)
cpu_rng = rng |> CPUDevice()
```

Binding preserves the key, position, and cached stream state. Draws and derivations
retain the binding. Allocating draws use that backend. Fills check the destination
backend before mutation, including for empty arrays. Unsupported operations do not
fall back to CPU execution. Device fills exclude 128-bit integers. Metal also excludes
device Float64 and ComplexF64 draws.

These are the same residence rules as PureRNGs. Tokens identify a backend, not a physical
GPU. Use `CUDA.device!` or the backend equivalent before allocation and execution.
Keep the active device and arrays consistent. Host scalar calls run on the host;
scalar calls inside a kernel run on the device. `Stateful(rng)` explicitly rebinds to CPU.

## Reactant

Reactant 0.2.280 or later in the 0.2 series enables the optional extension.
Select a backend, then convert the generator before compiling:

```julia
using TandemRNG, Reactant

Reactant.set_default_backend("cpu")
rng = Reactant.to_rarray(Tandem8x32(42))
destination = Reactant.to_rarray(zeros(Float32, 1024))
compiled_fill = Reactant.@compile rand_fill!(rng, destination)
rng = compiled_fill(rng, destination)
values = Array(destination)
cpu_rng = Tandem8x32(rng)
```

The converted state holds the key and bit position as runtime data. The same executable
accepts changed keys and positions with matching chunk length, backend, and array shape.
`Tandem8x32(rng)` restores the CPU generator, including positions reached above 2^63.

Compiled operations cover Bool, 8–64-bit integers, and Float16/32/64, matching
PureRNGs' Reactant result types. They include `rand_next`, one-based `rand_at`,
`rand_fill!`, `splitrng`, `forkrng`, and `subrng`. Child counts use `Val(N)`.
Addressed indices and purpose IDs must be static. Destination fills replace the traced
array's value and preserve the CPU stream order and final position.

The extension uses Tandem's shared recurrence. A fill seeds each covered chunk once and
steps it in a compiled loop. A scalar draw rebuilds its block from the key and position.
Use a bulk fill for many draws. Compiled operations omit stream exhaustion checks;
keep draws within the 2^64-bit stream, with the final position below 2^64.

Package precompilation covers Julia conversion and tracing entry points for K1/K32/K64,
all supported traced draw types, vectors, matrices, and static derivations. It creates no device client.
The first `Reactant.@compile` still builds an executable for the concrete backend and shape.

## PureRNGs

Loading PureRNGs and TandemRNG enables `TandemRNGPureRNGsExt`, owned by TandemRNG.
PureRNGs is a weak dependency and needs no Tandem-specific code.
The extension delegates uniform scalar, addressed, allocating, and destination draws,
state access, `splitrng`, and `subrng` to Tandem. For example:

```julia
import PureRNGs, TandemRNG

rng = TandemRNG.Tandem8x32(42)
values, rng = PureRNGs.rand_next(rng, Float64, 17, 3)
stateful = PureRNGs.StatefulRNG(rng)
```

The bridge delegates allocation and residence checks to Tandem. Bind with MLDataDevices
before calling PureRNGs array methods. It retains Tandem's alignment and position law.
`StatefulRNG(rng)` returns
`TandemRNG.Stateful`; `parent(stateful)` recovers its current immutable generator.
The same uniform and static split methods work on a converted Reactant state.
PureRNGs distribution and continuation methods are outside this bridge's scope.

The bridge precompile workload covers K1/K32/K64, all uniform draw types, vector and
matrix draws, addressed draws, derivations, and the stateful constructor. Its conformance
suite lives in `test/purerngs`, including CUDA residence and Reactant checks.

## Stream law

A generator position counts bits. The stream is a sequence of 1024-bit rows. Row
`position >> 10` holds the 128-bit blocks of lanes 0 to 7 of group `row ÷ K` at step
`row mod K`. Lane `ℓ` of group `g` is chunk `8g + ℓ`, seeded once by the permutation's
seeding function, and its block at step `j` is the exposed half after `j + 1` steps. Block
`position >> 7` is lane `(position >> 7) & 7` of its row. Each scalar component has a
fixed width and is aligned to it inside the block:

| type | bits |
|---|---|
| `Bool` | 1 |
| `UInt8`, `Int8` | 8 |
| `UInt16`, `Int16`, `Float16` | 16 |
| `UInt32`, `Int32`, `Float32` | 32 |
| `UInt64`, `Int64`, `Float64`, `Char` | 64 |
| `UInt128`, `Int128` | 128 |

A draw rounds the position up to its width, reads its bits, and advances by its width.
Element `i` of a fill sits at bit `align_up(position, w) + w·(i − 1)`. `Float64` takes the
top 53 bits of its 64, `Float32` the top 24 bits of its 32, and `Float16` the top 11
bits of its 16. Bool takes one bit. Char maps a 64-bit candidate across the Unicode
scalars with PureRNGs' fixed-work reduction. It occupies four output bytes.
Complex Float16/32/64 values compose two real draws and align to the real component
width. A complex value may span two blocks. Fills preserve that component order.
The stream holds 2^64 bits. A generator may start at any position below 2^63.

The row layout is what makes one kernel serve every backend: on a GPU each work-item owns
one chunk and the eight work-items of a group write one contiguous row per step, and on the
CPU the eight lanes of a group step together as four vectors. `Stateful` keeps its position
apart from the value and replaces the value only when a draw leaves the current row.
```
