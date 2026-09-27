# Streams and reproducibility

## Derive streams

Children start at position zero and retain the parent's chunk length and device binding.
Choose the derivation by what identifies the work:

| Operation | Input beyond the parent key | Parent position |
|:--|:--|:--|
| [`splitrng(rng, n)`](@ref splitrng) | Child index | Ignored and unchanged |
| [`subrng(rng, purpose)`](@ref subrng) | Integer purpose ID | Ignored and unchanged |
| [`forkrng(rng, n)`](@ref forkrng) | Current block and child index | Returned parent advances to the next 128-bit block |

`splitrng(rng, n)` returns a vector. `splitrng(rng, Val(N))` returns a tuple.
`splitrng(rng)` returns two children. Requesting more children preserves the existing
prefix. Julia's first child corresponds to internal index zero.

Assign streams to stable logical job IDs to make results independent of scheduling:

```@example jobs
using TandemRNG
children = splitrng(Tandem8x32(42), 8)
results = Vector{Float64}(undef, length(children))
Threads.@threads for job in eachindex(children)
    samples, _ = rand_next(children[job], Float64, 16)
    results[job] = sum(samples)
end
results
```

`subrng` assigns one stream to a stable integer purpose ID. IDs are reduced modulo
`2^64`, so IDs differing by `2^64` produce the same child. Reusing a key and purpose
repeats the stream.

```@example roles
using TandemRNG
root = Tandem8x32(42)
proposal_rng = subrng(root, 1)
acceptance_rng = subrng(root, 2)
(rngkey(proposal_rng), rngkey(acceptance_rng))
```

Forks depend on the current 128-bit block. Continue from the returned parent for
successive forks. Even requesting zero children advances it to the next block.

```@example forks
using TandemRNG
parent_rng = Tandem8x32(42)
parent_rng, first_child = forkrng(parent_rng)
parent_rng, next_children = forkrng(parent_rng, Val(2))
(rngposition(parent_rng), length(next_children))
```

The single-child form returns one child. Integer counts return vectors, and `Val(N)`
counts return tuples. A fork supports at most `2^33` children.
Derivation uses 128-bit keys. It does not guarantee collision-free keys or prove
independence between streams.

## Bit positions and draw order

[`rngposition`](@ref) counts consumed bits, including alignment gaps. Each scalar
component rounds the position up to a multiple of its width, then consumes that width.

| Type | Bits consumed |
|:--|--:|
| `Bool` | 1 |
| `UInt8`, `Int8` | 8 |
| `UInt16`, `Int16`, `Float16` | 16 |
| `UInt32`, `Int32`, `Float32` | 32 |
| `UInt64`, `Int64`, `Float64`, `Char` | 64 |
| `UInt128`, `Int128` | 128 |

Float16, Float32, and Float64 use the top 11, 24, and 53 bits respectively.
Char maps a 64-bit candidate to Unicode scalar values using PureRNGs' fixed-work
reduction. Complex values draw the real component before the imaginary component
and align to the real component width. A complex value can cross a 128-bit block.
Mixing types can skip bits. An empty fill can also advance to its alignment boundary.

```@example alignment
using TandemRNG
rng = Tandem8x32(42)
_, rng = rand_next(rng, Bool)
after_bool = rngposition(rng)
_, rng = rand_next(rng, UInt32)
(after_bool, rngposition(rng))
```

## Save and restore

Record the algorithm version, chunk length, seed or raw key, bit position, draw types
and order, and logical job IDs. Keep the package revision and environment too.
Supported backends share the primitive draw stream for types they all support.
Higher-level Random samplers can change algorithms or bit consumption across Julia versions.

```@example restore
using TandemRNG
rng = Tandem8x32(42)
_, rng = rand_next(rng, Float64, 10)
key, position, K = rngkey(rng), rngposition(rng), chunk_length(rng)
restored = Tandem8x32{K}(key, position)
@assert rand_at(restored, UInt64, 1) == rand_at(rng, UInt64, 1)
(key, position, K)
```

The raw-key constructor restores CPU binding and accepts starting positions below
`2^63`. Reapply the intended device binding after reconstruction. Generator values
can advance beyond `2^63`, but this constructor cannot restore those positions.

## Chunk length and stream limits

`Tandem8x32{K}(seed)` selects an `Int` power of two from 1 through 65536.
The default is 32. Changing `K` changes the stream and reseeding interval.
It does not change the seeding round count, which is fixed at eight.

The stream contains `2^64` bits. Keep every resulting position strictly below `2^64`.
CPU and GPU array fills check this limit before writing. Scalar draws, addressed
reads, fork advancement, and compiled Reactant operations do not provide an
exhaustion check. Their position arithmetic can wrap if the caller exceeds the limit.
