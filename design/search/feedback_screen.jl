# Short, paired screening of the unchanged recurrence and the isolated D24 alternative.
# This does not replace the release matrix or authorize changing the production stream.
module TandemFeedbackScreen

include("final.jl")
include("feedback.jl")
using .TandemHarness: Gen, run_matrix
import .TandemHarness: steps_per_chunk, fill_words!, transform, source_paths
const F = TandemFeedback.TandemRNG

mutable struct FeedbackGen{K} <: Gen
    rng::F.Tandem8x32{K}
end

FeedbackGen(K, seed) = FeedbackGen{K}(F.Tandem8x32{K}(seed))
steps_per_chunk(::FeedbackGen{K}) where {K} = K

function fill_words!(words::Vector{UInt32}, g::FeedbackGen{K}) where {K}
    length(words) % (32K) == 0 || error("feedback buffer must hold whole groups")
    g.rng = F.rand_fill!(g.rng, words; nthreads = 4)
    return words
end

transform(words::Vector{UInt32}, stream::Symbol, ::FeedbackGen{K}) where {K} =
    TandemFinal.row_transform(words, stream, K)

source_paths(::FeedbackGen) = [
    source_paths(TandemFinal.PackageGen(32, 42))...,
    @__FILE__,
    joinpath(@__DIR__, "feedback.jl"),
]

function run(; logdir, tlmax = 28)
    TandemFinal.TandemRNG.step(ntuple(UInt32, 4), ntuple(i -> UInt32(i+4), 4))[2][1] ==
    0x9e377cbe || error(
        "Historical paired screen requires the pre-feedback source snapshot; use final.jl for v2",
    )
    cases = []
    for (name, ctor) in (("original", TandemFinal.PackageGen), ("feedback", FeedbackGen))
        for stream in (:sequential, :chunkstart, :xorstep, :bit0)
            push!(cases, (Symbol("$name-k32-$stream"), ctor(32, 42), stream))
        end
        for K in (1, 64)
            push!(cases, (Symbol("$name-k$K-sequential"), ctor(K, 42), :sequential))
        end
    end
    return run_matrix(cases; logdir, tlmax, rng_test = TandemFinal.RNG_TEST)
end

end
