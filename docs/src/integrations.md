# Integrations

## [Random](@id random-integration)

[`Stateful`](@ref) implements `Random.AbstractRNG`. It supports `rand`, `rand!`,
`randn`, `randexp`, ranges, and samplers built on the standard primitive draw methods.

```@example random
using TandemRNG, Random
rng = Stateful(42)
die = rand(rng, 1:6)
normal = randn(rng)
values = rand(rng, Float32, 4)
immutable_rng = parent(rng)
(die, normal, values, rngposition(immutable_rng))
```

`Stateful()` obtains a seed from `RandomDevice`. `Stateful{K}(seed)` selects the
chunk length. `copy(rng)` duplicates the stream, and `Random.seed!(rng, seed)` resets it.
`parent(rng)` and `Tandem8x32(rng)` recover the current immutable CPU generator.
Constructing a wrapper from a device-bound generator explicitly binds it to the CPU.

Give each concurrent task its own mutable wrapper. Sharing one wrapper across tasks
does not provide synchronized stream advancement. Julia's higher-level samplers
need not retain identical output across Julia versions.

## PureRNGs

Loading both packages enables TandemRNG's PureRNGs extension.
Use qualified names to avoid conflicts between their exported functions.

```julia
import PureRNGs, TandemRNG
rng = TandemRNG.Tandem8x32(42)
values, rng = PureRNGs.rand_next(rng, Float64, 17, 3)
buffer = similar(values)
buffer, rng = PureRNGs.rand_next!(rng, buffer; threaded = false)
stateful = PureRNGs.StatefulRNG(rng)
```

| PureRNGs operation | Tandem behavior |
|:--|:--|
| `rand_next`, `rand_at` | Uniform scalar, addressed, and allocating draws |
| `rand_next!` | Destination fill returning `(destination, next_rng)` |
| `rngkey`, `rngposition` | Current immutable state |
| `splitrng`, `subrng` | Child derivations with the same stream rules |
| `StatefulRNG` | A CPU-bound `TandemRNG.Stateful` |

The bridge preserves alignment, final positions, allocation backend, and residence
checks. Bind with MLDataDevices before array calls. `threaded = false` requests
a single-threaded CPU fill. Native `rand_fill!` returns only the generator.

Use `TandemRNG.forkrng` for forks. PureRNGs distribution and continuation methods
are outside this bridge's scope. The same uniform and static derivation methods
work with the converted Reactant state.

## [Reactant](@id reactant-integration)

Reactant 0.2.280 or later in the 0.2 series enables the optional extension.
Select a backend, convert the generator and destination, then compile:

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

The converted state carries its key and position as runtime data. The executable
accepts changed keys and positions with matching chunk length, backend, and array
shape. `Tandem8x32(rng)` restores the CPU generator, including positions above `2^63`.

Compiled operations include `rand_next`, one-based `rand_at`, `rand_fill!`,
`splitrng`, `forkrng`, and `subrng`. Child counts use `Val(N)`. Addressed indices
and purpose IDs must be static. Supported result types appear in [Devices](@ref).
Fills replace the traced array's value and preserve CPU stream order and final position.

Bulk fills seed each covered chunk once. Scalar draws reconstruct their block,
so prefer fills for many draws. Compiled operations omit exhaustion checks.
Keep the final bit position below `2^64`.
