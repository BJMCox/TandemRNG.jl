# Fixed reduced-F diagnostic. Vary only F's round count, retaining the v2 step,
# round constants, and the raw key obtained from production seed 42.
include(joinpath(@__DIR__, "harness.jl"))
include(joinpath(@__DIR__, "reference_v2.jl"))

module TandemMargin

import TandemRNG as TR
using ..TandemHarness: Gen, run_matrix
import ..TandemHarness: fill_words!, steps_per_chunk, source_paths, transform
using ..TandemReferenceV2

mutable struct ChunkStarts{R,Paired} <: Gen
    key::NTuple{4,UInt32}
    counter::UInt64
end
steps_per_chunk(::ChunkStarts) = 1
source_paths(::ChunkStarts) = [
    @__FILE__,
    joinpath(@__DIR__, "harness.jl"),
    joinpath(@__DIR__, "step.jl"),
    joinpath(@__DIR__, "reference_v2.jl"),
    filter(p -> endswith(p, ".jl"), readdir(joinpath(pkgdir(TR), "src"); join = true))...,
]

@inline function first_block(key, counter, ::Val{R}) where {R}
    o = (counter % UInt32, (counter >> 32) % UInt32, TR.DOMAIN_STREAM, TR.AUX_STREAM)
    h = key
    Base.Cartesian.@nexprs 8 r -> if r <= R
        o, h = TR.step(o, h)
        o = (o[1] ⊻ TR.RC[r], o[2], o[3], o[4])
        o, h = h, o
    end
    return first(TR.step(o, h))
end

function fill_words!(words::Vector{UInt32}, g::ChunkStarts{R,P}) where {R,P}
    length(words) % 4 == 0 || error("chunk-start buffers need complete blocks")
    paired_key = (g.key[1] ⊻ UInt32(1), g.key[2], g.key[3], g.key[4])
    for i = 1:4:length(words)
        block = first_block(g.key, g.counter, Val(R))
        if P
            block = block .⊻ first_block(paired_key, g.counter, Val(R))
        end
        @inbounds for j = 1:4
            words[i+j-1] = block[j]
        end
        g.counter += 1
    end
    return words
end

function transform(words::Vector{UInt32}, stream::Symbol, ::ChunkStarts)
    stream === :sequential || error("chunk-start diagnostics emit their final bytes")
    return words
end

function verify()
    TandemReferenceV2.verify(TR)
    checks = 0
    for seed in (42, 99), counter in (UInt64(0), UInt64(7), UInt64(1)<<32, UInt64(1)<<48)
        key = TR.rngkey(TR.Tandem8x32(seed))
        source = ChunkStarts{8,false}(key, counter)
        paired = ChunkStarts{8,true}(key, counter)
        cpu = TR.Tandem8x32{1}(key, counter * 128)
        for n in (32, 64, 16384)
            actual = fill_words!(zeros(UInt32, n), source)
            expected = similar(actual)
            cpu = TR.rand_fill!(cpu, expected; nthreads = 1)
            @assert actual == expected
            @assert source.counter * 128 == TR.rngposition(cpu)
            checks += 2
        end
        for c = counter:(counter+15)
            @assert UInt64.(first_block(key, c, Val(8))) ==
                    Tuple(TandemReferenceV2.block(key, c, 0))
            checks += 1
        end
        expected_pair =
            first_block(key, counter, Val(8)) .⊻
            first_block((key[1]⊻UInt32(1), key[2], key[3], key[4]), counter, Val(8))
        @assert Tuple(fill_words!(zeros(UInt32, 4), paired)) == expected_pair
        checks += 1
    end
    return checks
end

function cases()
    key = TR.rngkey(TR.Tandem8x32(42))
    return [
        (
            Symbol("f$(R)-chunkstart-$(P ? "keybit0-xor" : "plain")"),
            ChunkStarts{R,P}(key, UInt64(0)),
            :sequential,
        ) for R = 2:8 for P in (false, true)
    ]
end

function run(; logdir, rng_test)
    verify()
    return run_matrix(
        cases();
        logdir,
        rng_test,
        tlmin = 20,
        tlmax = 30,
        tf = 1,
        te = 0,
        multithreaded = true,
        all_results = true,
    )
end

end
