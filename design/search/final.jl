# PractRand on the shipped generator. The search harness has its own copy of the step so it
# can vary wiring and clock. This lane feeds the package's own `rand_fill!`, so the evidence
# covers the exact code path users get, row and bit laws included. Start Julia with
# `--project=CHECKOUT` before including this file.
include(joinpath(@__DIR__, "harness.jl"))

module TandemFinal

using TandemRNG
using ..TandemHarness: Gen, run_matrix
import ..TandemHarness: fill_words!, steps_per_chunk, transform, source_paths

const RNG_TEST = get(ENV, "TANDEM_RNG_TEST", "RNG_test")
# Separate from the historical D20 logs, which run_matrix would otherwise reuse.
const LOGDIR = get(ENV, "TANDEM_LOGDIR", joinpath(@__DIR__, "logs", "final-row-bit-v2"))

# Sequential UInt32 stream of a `Tandem8x32{K}` through the package fill.
mutable struct PackageGen{K,D} <: Gen
    rng::Tandem8x32{K,D}
end

PackageGen(K::Int, seed::Integer) = PackageGen(Tandem8x32{K}(seed))

source_paths(::PackageGen) = [
    @__FILE__,
    joinpath(@__DIR__, "streams.jl"),
    joinpath(@__DIR__, "harness.jl"),
    joinpath(@__DIR__, "step.jl"),
    filter(
        p -> endswith(p, ".jl"),
        readdir(joinpath(pkgdir(TandemRNG), "src"); join = true),
    )...,
]

steps_per_chunk(::PackageGen{K}) where {K} = K

function fill_words!(words::Vector{UInt32}, g::PackageGen)
    length(words) % (32 * steps_per_chunk(g)) == 0 ||
        error("package buffer must hold whole groups of eight chunks")
    g.rng = rand_fill!(g.rng, words; nthreads = 4)
    return words
end

# A row contains one four-word block from each of eight chunks. A group has K rows.
# The search harness's original transforms instead assume contiguous single chunks.
function row_transform(words::Vector{UInt32}, stream::Symbol, K::Int)
    groups = length(words) ÷ (32K)
    if stream === :xorstep && K == 1
        error("same-chunk step XOR needs K > 1")
    elseif stream === :chunkstart
        return [words[32K*g+q] for g = 0:(groups-1) for q = 1:32]
    elseif stream === :xorstep
        return [
            words[32K*g+32s+q] ⊻ words[32K*g+32(s-1)+q] for g = 0:(groups-1) for s =
                1:(K-1) for q = 1:32
        ]
    end
    return transform(words, stream, K)
end

function transform(words::Vector{UInt32}, stream::Symbol, g::PackageGen{K}) where {K}
    start = rngposition(g.rng) - UInt64(32length(words))
    if stream in (:chunkstart, :xorstep)
        iszero(start % UInt64(1024K)) || error("row projections need a group-aligned start")
    end
    return row_transform(words, stream, K)
end

const STREAMS =
    (:sequential, :chunkstart, :word0, :word1, :word2, :word3, :xorstep, :lowbyte, :bit0)

lane(K; seed = 42) =
    [(Symbol("final-k$K-seed$seed-$s"), PackageGen(K, seed), s) for s in STREAMS]

const LANES = Dict(
    :k32 => lane(32),
    :k1 => [(:"final-k1-seed42-sequential", PackageGen(1, 42), :sequential)],
    :k64 => [(:"final-k64-seed42-sequential", PackageGen(64, 42), :sequential)],
    :seed0 => [(:"final-k32-seed0-sequential", PackageGen(32, 0), :sequential)],
)

run_lane(name::Symbol; tlmax = 36, kwargs...) =
    run_matrix(LANES[name]; logdir = LOGDIR, tlmax = tlmax, rng_test = RNG_TEST, kwargs...)

end # module
