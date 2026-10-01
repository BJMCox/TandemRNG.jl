# Optional process checks. Requires PractRand and pgrep:
# julia --project=CHECKOUT check_practrand.jl /absolute/path/to/RNG_test
using Test
include(joinpath(@__DIR__, "streams.jl"))

mutable struct FaultFeed <: TandemHarness.Gen
    calls::Int
end
TandemHarness.steps_per_chunk(::FaultFeed) = 1
function TandemHarness.fill_words!(words::Vector{UInt32}, g::FaultFeed)
    g.calls += 1
    g.calls == 2 && error("intentional feed fault")
    return fill!(words, 0x12345678)
end

children() = strip(read(ignorestatus(`pgrep -P $(getpid()) -x RNG_test`), String))
mktempdir() do dir
    @testset "PractRand child lifecycle" begin
        @test isempty(children())
        log = joinpath(dir, "fault.txt")
        # An old sidecar must not survive a failed rerun and make its log reusable.
        write(log * ".protocol", "old protocol")
        @test_throws ErrorException TandemHarness.run_matrix(
            [(:fault, FaultFeed(0), :sequential)];
            rng_test = ARGS[1],
            logdir = dir,
            tlmax = 20,
        )
        @test isempty(children())
        @test !isfile(log * ".protocol")
        @test !occursin("# TandemHarness completed", read(log, String))
        empty_log = joinpath(dir, "empty.txt")
        @test_throws ErrorException TandemHarness.run_practrand(
            TandemFinal.PackageGen(1, 42),
            :xorstep;
            rng_test = ARGS[1],
            log = empty_log,
            tlmax = 20,
        )
        @test !isfile(empty_log)
        @test isempty(children())
    end
end
