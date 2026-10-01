# Reduced-round feeds for direct split keys and historical chunk-start outputs.
include(joinpath(@__DIR__, "margin.jl"))

module TandemDirectMargin

import TandemRNG as TR
import ..TandemHarness: Gen, fill_words!, steps_per_chunk, source_paths, transform
using ..TandemMargin: first_block, ChunkStarts

const PROBES = (
    :split_o_seq,
    :split_h_seq,
    :split_o_high,
    :split_h_high,
    :split_o_keybit0_xor,
    :split_h_keybit127_xor,
    :chunkstart_seq,
    :chunkstart_keybit0_xor,
)

mutable struct Probe{R,P} <: Gen
    key::NTuple{4,UInt32}
    index::UInt64
end

function probe(
    rounds::Int,
    kind::Symbol;
    seed::UInt64 = UInt64(42),
    index::UInt64 = UInt64(0),
)
    1 <= rounds <= 8 || throw(ArgumentError("rounds must be in 1:8"))
    kind in PROBES || throw(ArgumentError("unknown margin probe: $kind"))
    return Probe{rounds,kind}(TR.rngkey(TR.Tandem8x32(seed)), index)
end

steps_per_chunk(::Probe) = 1
source_paths(g::Probe) = [
    @__FILE__,
    source_paths(ChunkStarts{8,false}(g.key, UInt64(0)))...,
]

# Exchange the two counter words. Unlike a shift, this remains injective past 2^32.
@inline swap32(i::UInt64) = (i << 32) | (i >> 32)

@inline function split_halves(key, counter, ::Val{R}) where {R}
    o = (counter % UInt32, (counter >> 32) % UInt32, TR.DOMAIN_SPLIT, UInt32(0))
    h = key
    Base.Cartesian.@nexprs 8 r -> if r <= R
        o, h = TR.step(o, h)
        o = (o[1] ⊻ TR.RC[r], o[2], o[3], o[4])
        o, h = h, o
    end
    return o, h
end

@inline function base_block(key, index::UInt64, ::Val{R}, ::Val{P}) where {R,P}
    if P in (:chunkstart_seq, :chunkstart_keybit0_xor)
        return first_block(key, index, Val(R))
    end
    counter = P in (:split_o_high, :split_h_high) ? swap32(index) : index
    o, h = split_halves(key, counter, Val(R))
    return P in (:split_h_seq, :split_h_high, :split_h_keybit127_xor) ? h : o
end

@inline function block(g::Probe{R,P}, index::UInt64) where {R,P}
    result = base_block(g.key, index, Val(R), Val(P))
    if P in (:split_o_keybit0_xor, :chunkstart_keybit0_xor)
        paired = (g.key[1] ⊻ UInt32(1), g.key[2], g.key[3], g.key[4])
        result = result .⊻ base_block(paired, index, Val(R), Val(P))
    elseif P === :split_h_keybit127_xor
        paired = (g.key[1], g.key[2], g.key[3], g.key[4] ⊻ UInt32(0x80000000))
        result = result .⊻ base_block(paired, index, Val(R), Val(P))
    end
    return result
end

function fill_words!(words::Vector{UInt32}, g::Probe)
    length(words) % 4 == 0 || throw(ArgumentError("margin buffers need complete blocks"))
    for i = 1:4:length(words)
        result = block(g, g.index)
        @inbounds for j = 1:4
            words[i+j-1] = result[j]
        end
        g.index += 1
    end
    return words
end

function transform(words::Vector{UInt32}, stream::Symbol, ::Probe)
    stream === :sequential || throw(ArgumentError("margin probes emit their final bytes"))
    return words
end

function case(rounds::Int, kind::Symbol; seed::UInt64 = UInt64(42))
    name = Symbol(
        "f$rounds-",
        replace(string(kind), '_' => '-'),
        "-seed",
        string(seed; base = 16, pad = 16),
    )
    return name, probe(rounds, kind; seed), :sequential
end

end
