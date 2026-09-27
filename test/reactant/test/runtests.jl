get!(ENV, "XLA_REACTANT_GPU_PREALLOCATE", "false")

using Test, TandemRNG, Reactant

Reactant.set_default_backend(get(ENV, "TANDEM_REACTANT_BACKEND", "cpu"))

function mixed_fill(rng, destination)
    bit, rng = rand_next(rng, Bool)
    value, rng = rand_next(rng, eltype(destination))
    addressed = rand_at(rng, eltype(destination), 3)
    return bit, value, addressed, rand_fill!(rng, destination)
end

function derived(rng)
    children = splitrng(rng, Val(3))
    parent, forks = forkrng(rng, Val(3))
    return children, parent, forks, subrng(rng, 17)
end

@testset "Reactant stream law" begin
    key = rngkey(Tandem8x32(42))
    # Every type has a distinct bit width or extraction/conversion contract.
    for T in (
        Bool,
        UInt8,
        Int8,
        UInt16,
        Int16,
        UInt32,
        Int32,
        UInt64,
        Int64,
        Float16,
        Float32,
        Float64,
    )
        base = Tandem8x32{32}(key, 32735)
        input = Reactant.to_rarray(base)
        output = Reactant.to_rarray(zeros(T, 17, 3))
        compiled = Reactant.@compile mixed_fill(input, output)
        for rng in (base, Tandem8x32{32}(rngkey(Tandem8x32(43)), 127))
            expected = zeros(T, size(output))
            wanted = mixed_fill(rng, expected)
            actual = compiled(Reactant.to_rarray(rng), output)
            @test Bool(actual[1]) == wanted[1]
            @test T(actual[2]) == wanted[2]
            @test T(actual[3]) == wanted[3]
            @test Array(output) == expected
            @test Tandem8x32(actual[4]) == wanted[4]
        end
    end

    @testset "K=1 group changes and high positions" begin
        for K in (1, 64)
            rng = Tandem8x32{K}(key, (UInt64(1) << 63) - 65)
            input = Reactant.to_rarray(rng)
            output = Reactant.to_rarray(zeros(UInt64, 133))
            compiled = Reactant.@compile mixed_fill(input, output)
            expected = zeros(UInt64, size(output))
            wanted = mixed_fill(rng, expected)
            actual = compiled(input, output)
            @test Array(output) == expected
            @test Tandem8x32(actual[4]) == wanted[4]
        end
    end

    @testset "empty fill alignment" begin
        rng = last(rand_next(Tandem8x32(42), Bool))
        input = Reactant.to_rarray(rng)
        output = Reactant.to_rarray(zeros(UInt64, 0, 3))
        compiled = Reactant.@compile rand_fill!(input, output)
        @test Tandem8x32(compiled(input, output)) == rand_fill!(rng, zeros(UInt64, 0, 3))
    end

    @testset "derive runtime keys and positions" begin
        rng = Tandem8x32{32}(key, 129)
        input = Reactant.to_rarray(rng)
        compiled = Reactant.@compile derived(input)
        for parent in (rng, Tandem8x32{32}(rngkey(Tandem8x32(99)), 1023))
            actual = compiled(Reactant.to_rarray(parent))
            wanted = derived(parent)
            @test map(Tandem8x32, actual[1]) == wanted[1]
            @test Tandem8x32(actual[2]) == wanted[2]
            @test map(Tandem8x32, actual[3]) == wanted[3]
            @test Tandem8x32(actual[4]) == wanted[4]
        end
    end
end
