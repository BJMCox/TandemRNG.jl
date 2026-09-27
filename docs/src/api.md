```@meta
CurrentModule = TandemRNG
```

# API reference

## Generator and state

```@docs
TandemRNG
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

## Child streams

```@docs
splitrng
forkrng
subrng
```

## Random wrapper

```@docs
Stateful
```
