# PractRand ranking matrix for the D8 search. Each lane is a list of (name, generator, stream)
# cases run in order by one Kaimon session on batserv01. Lanes are independent, so one
# session per lane runs them in parallel.
include(joinpath(@__DIR__, "harness.jl"))

module TandemMatrix

using ..TandemSearch: Config
using ..TandemHarness: TandemGen, PhiloxGen, run_matrix

const RNG_TEST = "/home/users01/bcox/.local/bin/RNG_test"
const LOGDIR = "/mnt/scratch/bcox/tandem-search/logs/matrix-2026-09-19"

# Second round (2026-09-19): every layer rotates lo by 16 before the key xor (lorot = 16).
ring_w2(; k = 32, Rf = 6, kwargs...) = TandemGen(Config(:ring, :w2), Rf, k; kwargs...)
ring_w3(; k = 32, Rf = 4, kwargs...) = TandemGen(Config(:ring, :w3), Rf, k; kwargs...)

const STREAMS = (:sequential, :chunkstart, :word0, :xorstep, :lowbyte, :bit0)

const LANES = Dict(
    # Harness validation: a known weak round count must fail early, the standard count pass.
    :philox =>
        [(Symbol("philox-R$R"), PhiloxGen(R), :sequential) for R in (4, 5, 6, 7, 10)],
    # One-layer candidate, all derived streams.
    :w2 => [(Symbol("ring-w2-Rf6-k32-$s"), ring_w2(), s) for s in STREAMS],
    # Two-layer fallback, all derived streams.
    :w3 => [(Symbol("ring-w3-Rf4-k32-$s"), ring_w3(), s) for s in STREAMS],
    # Chunk length, clock, and key variants for the one-layer candidate.
    :variants => [
        (:"ring-w2-Rf6-k1-sequential", ring_w2(; k = 1), :sequential),
        (:"ring-w2-Rf6-k64-sequential", ring_w2(; k = 64), :sequential),
        (
            :"xoshiro-w2-Rf6-k32-sequential",
            TandemGen(Config(:xoshiro, :w2), 6, 32),
            :sequential,
        ),
        (:"weyl-w2-Rf6-k32-sequential", TandemGen(Config(:weyl, :w2), 6, 32), :sequential),
        (
            :"ring-w2-Rf6-k32-key0-sequential",
            ring_w2(; key = (0x0, 0x0, 0x0, 0x0)),
            :sequential,
        ),
        (:"ring-w2-Rf4-k32-sequential", ring_w2(; Rf = 4), :sequential),
    ],
)

run_lane(lane::Symbol; tlmax = 35, kwargs...) =
    run_matrix(LANES[lane]; logdir = LOGDIR, tlmax = tlmax, rng_test = RNG_TEST, kwargs...)

end # module
