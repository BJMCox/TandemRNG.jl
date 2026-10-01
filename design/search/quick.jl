# Native TestU01 batteries on the sequential `Stateful` stream. RNGTest.jl supplies
# `libtestu01` and silences the per-test output; the generator and battery calls are made
# here. SmallCrush takes about a minute per stream, so this is the lane for iteration.
# `final.jl` drives PractRand for the long runs.
#
# Run in an environment with RNGTest and TandemRNG:
#     include("design/search/quick.jl"); TandemQuick.report()
module TandemQuick

using Printf
using Random
using RNGTest
using TandemRNG

export smallcrush, crush, bigcrush, report

const LIB = RNGTest.libtestu01

# Elements per `rand!` block. Large enough that one fill amortizes the task spawns of
# `rand_fill!` on a many-core host.
const BLOCK = 1 << 18

# TestU01's extern generator calls a zero-argument function returning a Float64 in [0, 1).
# RNGTest.jl 1.6 dropped its `wrap`, so this is the block-buffered replacement. Integers are
# consumed as 32-bit words, low word first.
mutable struct Feed{T,K,V<:AbstractVector,Reverse}
    rng::Stateful{K}
    buf::Vector{T}
    vals::V
    i::Int
end

_words(buf::Vector{Float64}) = buf
_words(buf::Vector{<:Union{UInt32,UInt64}}) = reinterpret(UInt32, buf)

function Feed(rng::Stateful{K}, ::Type{T}; reverse::Bool = false) where {K,T}
    T in (UInt32, UInt64, Float64) || throw(ArgumentError("unsupported feed type $T"))
    # Reverse raw 64-bit words before selecting the 53 Float64 bits. Reversing the
    # Float64 representation, or only its retained bits, tests a different stream.
    W = T === Float64 && reverse ? UInt64 : T
    buf = Vector{W}(undef, BLOCK)
    vals = T === Float64 && reverse ? buf : _words(buf)
    return Feed{W,K,typeof(vals),reverse}(rng, buf, vals, length(vals))
end

# A 32-bit word scaled by 2^-32 is exact in Float64, and TestU01 recovers the word as
# `trunc(u * 2^32)`, so the integer path loses no bits.
@inline _u01(x::Float64) = x
@inline _u01(x::UInt32) = Float64(x) * 0x1p-32
@inline _u01(x::UInt64) = Float64(x >> 11) * 0x1p-53

function (f::Feed{T,K,V,Reverse})() where {T,K,V,Reverse}
    if f.i >= length(f.vals)
        rand!(f.rng, f.buf)
        f.i = 0
    end
    @inbounds x = f.vals[f.i+=1]
    return _u01(Reverse ? bitreverse(x) : x)
end

# RNGTest's battery functions return nothing. TestU01 leaves the p-values in these globals.
function battery_results()
    n = unsafe_load(cglobal((:bbattery_NTests, LIB), Cint))
    pvals = cglobal((:bbattery_pVal, LIB), Float64)
    names = cglobal((:bbattery_TestNames, LIB), Ptr{Cchar})
    return [unsafe_string(unsafe_load(names, i)) => unsafe_load(pvals, i) for i = 1:n]
end

battery(run, K, seed, T; reverse = false) = battery(
    run,
    Feed(Stateful(Tandem8x32{K}(seed)), T; reverse),
    "Tandem8x32{$K} $T seed=$seed reverse=$reverse",
)

# `@cfunction` compiles a static call only when the closure type is concrete at the call
# site, otherwise every call dispatches dynamically and boxes the result. So the feed
# arrives here as a typed argument. `RNGTest.Unif01` has that problem, and it also drops
# the `CFunction` handle whose collection frees the trampoline while TestU01 still calls it
# (segfault after ~1e9 calls), so the extern generator is built here instead.
function battery(run, feed::F, name::String) where {F}
    cf = @cfunction($feed, Float64, ())
    GC.@preserve cf begin
        gen = ccall(
            (:unif01_CreateExternGen01, LIB),
            Ptr{Cvoid},
            (Cstring, Ptr{Cvoid}),
            name,
            cf,
        )
        try
            run(gen)
        finally
            ccall((:unif01_DeleteExternGen01, LIB), Cvoid, (Ptr{Cvoid},), gen)
        end
    end
    return battery_results()
end

_smallcrush(gen) = ccall((:bbattery_SmallCrush, LIB), Cvoid, (Ptr{Cvoid},), gen)
_crush(gen) = ccall((:bbattery_Crush, LIB), Cvoid, (Ptr{Cvoid},), gen)
_bigcrush(gen) = ccall((:bbattery_BigCrush, LIB), Cvoid, (Ptr{Cvoid},), gen)

"""
    smallcrush(; K = 32, seed = 42, T = UInt32, reverse = false)

TestU01 SmallCrush on the sequential stream of `Stateful(Tandem8x32{K}(seed))` drawn as `T`
values, `T` one of `UInt32`, `UInt64`, `Float64`. Returns test name => p-value.
With `reverse=true`, reverse each 32-bit integer word, or reverse the raw 64-bit
word before converting its high 53 bits to Float64.
"""
smallcrush(; K = 32, seed = 42, T = UInt32, reverse = false) =
    battery(_smallcrush, K, seed, T; reverse)

"""
    crush(; K = 32, seed = 42, T = UInt32, reverse = false)

TestU01 Crush on the same stream as [`smallcrush`](@ref). Takes about an hour.
"""
crush(; K = 32, seed = 42, T = UInt32, reverse = false) =
    battery(_crush, K, seed, T; reverse)

"""
    bigcrush(; K = 32, seed = 42, T = UInt32, reverse = false)

Native TestU01 BigCrush on the same stream as [`smallcrush`](@ref).
"""
bigcrush(; K = 32, seed = 42, T = UInt32, reverse = false) =
    battery(_bigcrush, K, seed, T; reverse)

# TestU01's own suspect level, `gofw_Suspectp`.
const SUSPECT = 1e-3
suspect(p) = !isfinite(p) || p < SUSPECT || p > 1 - SUSPECT

"""
    report([io]; Ks = (32, 1), Ts = (UInt32, Float64), seed = 42)

SmallCrush for every `(K, T)` pair. Prints one table of p-values, `*` marking those outside
`[1e-3, 1 - 1e-3]`, and the wall seconds of each run. Returns the flagged tests as
`(K, T, test, p)` tuples.
"""
function report(io::IO = stdout; Ks = (32, 1), Ts = (UInt32, Float64), seed = 42)
    runs = [(K, T) for K in Ks for T in Ts]
    results = Vector{Vector{Pair{String,Float64}}}(undef, length(runs))
    seconds = zeros(length(runs))
    for (i, (K, T)) in enumerate(runs)
        seconds[i] = @elapsed results[i] = smallcrush(; K, seed, T)
    end
    names = first.(results[1])
    width = maximum(length, names)
    print(io, rpad("seed=$seed", width))
    for (K, T) in runs
        @printf(io, "  %14s", "K=$K $T")
    end
    println(io)
    for (j, name) in enumerate(names)
        print(io, rpad(name, width))
        for res in results
            p = last(res[j])
            @printf(io, "  %13.4g%s", p, suspect(p) ? "*" : " ")
        end
        println(io)
    end
    print(io, rpad("seconds", width))
    for s in seconds
        @printf(io, "  %13.1f ", s)
    end
    println(io)
    return [
        (K = K, T = T, test = name, p = p) for ((K, T), res) in zip(runs, results) for
        (name, p) in res if suspect(p)
    ]
end

end # module
