# Production stream families for the D16 statistical batteries.
include(joinpath(@__DIR__, "final.jl"))

module TandemStreams

using TandemRNG
using ..TandemFinal: PackageGen
using ..TandemHarness: Gen, PhiloxGen
import ..TandemHarness: fill_words!, steps_per_chunk, source_paths, transform

# One UInt32 from each child in turn. Derive children once, then advance them separately.
mutable struct InterleavedGen{K,D} <: Gen
    children::Vector{Tandem8x32{K,D}}
    scratch::Vector{UInt32}
end
InterleavedGen(children::Vector{Tandem8x32{K,D}}) where {K,D} =
    InterleavedGen{K,D}(children, UInt32[])
steps_per_chunk(::InterleavedGen{K}) where {K} = K
source_paths(g::InterleavedGen) = [@__FILE__; source_paths(PackageGen(first(g.children)))]

function fill_words!(words::Vector{UInt32}, g::InterleavedGen)
    m = length(g.children)
    n, rem = divrem(length(words), m)
    rem == 0 || error("interleaved buffers must contain complete sibling rounds")
    resize!(g.scratch, length(words))
    for j = 1:m
        A = view(g.scratch, ((j-1)*n+1):(j*n))
        g.children[j] = rand_fill!(g.children[j], A; nthreads = 1)
    end
    @inbounds for i = 1:n, j = 1:m
        words[(i-1)*m+j] = g.scratch[(j-1)*n+i]
    end
    return words
end

function transform(words::Vector{UInt32}, stream::Symbol, ::InterleavedGen)
    stream === :sequential || error("row projections do not apply to interleaved siblings")
    return words
end

# The phase counts source words before the next selected word, including across refills.
mutable struct DecimatedGen{G<:Gen} <: Gen
    source::G
    stride::Int
    phase::Int
end
function DecimatedGen(source::Gen, stride::Int; offset::Int = 0)
    0 <= offset < stride || error("decimation needs 0 <= offset < stride")
    return DecimatedGen(source, stride, offset)
end
steps_per_chunk(g::DecimatedGen) = steps_per_chunk(g.source)
source_paths(g::DecimatedGen) = [@__FILE__; source_paths(g.source)]
fill_words!(words::Vector{UInt32}, g::DecimatedGen) = fill_words!(words, g.source)
function transform(words::Vector{UInt32}, stream::Symbol, g::DecimatedGen)
    stream === :sequential || error("decimation emits its selected words directly")
    result = words[(g.phase+1):g.stride:end]
    g.phase = mod(g.phase - length(words), g.stride)
    return result
end

source_paths(::PhiloxGen) =
    [@__FILE__, joinpath(@__DIR__, "harness.jl"), joinpath(@__DIR__, "step.jl")]

const KEY_BITS = (0, 31, 32, 63, 64, 95, 96, 127)
const PROJECTIONS = (:chunkstart, :word0, :word1, :word2, :word3, :bit0, :lowbyte, :xorstep)
rawkey(x::UInt128) = ntuple(i -> (x >> (32(i-1))) % UInt32, 4)
package(K, key, position = UInt64(0)) = PackageGen(Tandem8x32{K}(key, position))

"""
    cases(family; K=32, seed=42)

Fresh `(name, generator, transform)` cases. Names identify the exact stream protocol.
Sibling streams interleave UInt32 draws. Structured keys bypass integer-seed whitening.
Counter starts use group boundaries. Decimation selects every nth emitted UInt32.
"""
function cases(family::Symbol; K::Int = 32, seed::Integer = 42)
    parent = Tandem8x32{K}(seed)
    prefix = "k$K-seed$seed"
    if family === :sequential
        return [(Symbol("$prefix-sequential"), PackageGen(parent), :sequential)]
    elseif family === :control
        key = (seed % UInt32, (seed >> 32) % UInt32)
        return [(Symbol("philox10-seed$seed"), PhiloxGen(10; key), :sequential)]
    elseif family === :siblings
        # Fork at block 13 to distinguish its counter from split's child index.
        at_block = Tandem8x32{K}(rngkey(parent), UInt64(13 * 128))
        _, forks = forkrng(at_block, 8)
        return [
            (Symbol("$prefix-split8"), InterleavedGen(splitrng(parent, 8)), :sequential),
            (Symbol("$prefix-fork8-block13"), InterleavedGen(forks), :sequential),
            (
                Symbol("$prefix-subrng8"),
                InterleavedGen([subrng(parent, i) for i = 0:7]),
                :sequential,
            ),
        ]
    elseif family === :projections
        return [
            (Symbol("$prefix-$s"), PackageGen(parent), s) for
            s in PROJECTIONS if K > 1 || s !== :xorstep
        ]
    elseif family === :bitplanes
        return [(Symbol("$prefix-bit$b"), PackageGen(parent), Symbol("bit$b")) for b = 1:31]
    elseif family === :decimation
        return [
            (
                Symbol("$prefix-decimate$d"),
                DecimatedGen(PackageGen(parent), d),
                :sequential,
            ) for d in (2, 3, 5, 8, 17, 32)
        ]
    elseif family === :keys
        keys = (
            :zero => zero(UInt128),
            :ones => typemax(UInt128),
            :alternating55 => UInt128(0x55555555555555555555555555555555),
            :alternatingaa => UInt128(0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa),
            :ascending => UInt128(0x00000003000000020000000100000000),
        )
        return [
            (Symbol("k$K-rawkey-$name"), package(K, rawkey(key)), :sequential) for
            (name, key) in keys
        ]
    elseif family in (:onebit, :onebit_screen)
        bits = family === :onebit ? KEY_BITS : Tuple(0:127)
        key = rngkey(parent)
        return [
            (
                Symbol("$prefix-keybit$b"),
                InterleavedGen([
                    parent,
                    Tandem8x32{K}(key .⊻ rawkey(UInt128(1) << b), UInt64(0)),
                ]),
                :sequential,
            ) for b in bits
        ]
    elseif family === :counters
        # Include both sides of the low-word carry and the constructor's highest group.
        positions = (
            UInt64(1024K) * (((UInt64(1) << 32) - 8) >> 3),
            UInt64(1024K) * ((UInt64(1) << 32) >> 3),
            (UInt64(1) << 62),
            (UInt64(1) << 63) - UInt64(1024K),
        )
        return [
            (Symbol("$prefix-position$p"), package(K, rngkey(parent), p), :sequential) for
            p in positions
        ]
    end
    error("unknown stream family $family")
end

end # module
