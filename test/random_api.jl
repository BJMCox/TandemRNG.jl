# Check the Random API against the pure generator's values and successor state.

@testset "Random API" begin
    st = Stateful(42)
    pure = Tandem8x32(42)
    x, pure2 = rand_next(pure, Float64)
    @test rand(st) == x
    @test Tandem8x32(st) == pure2
    # A row change inside a draw loop, then a fill, then a draw: the wrapper stays on the
    # same stream as the pure chain throughout.
    for _ = 1:40
        rand(st)
        _, pure2 = rand_next(pure2, Float64)
    end
    @test Tandem8x32(st) == pure2
    @test rand(st, UInt32) == rand_next(pure2, UInt32)[1]

    Random.seed!(st, 42)
    A = rand!(st, zeros(Float64, 70))
    B = zeros(Float64, 70)
    rand_fill!(pure, B)
    @test A == B

    Random.seed!(st, 42)
    for T in (UInt32, Int64, Float32, Bool)
        v = rand(st, T)
        @test v isa T
    end
    @test all(in(1:10), rand(st, 1:10, 50))
    @test isfinite(randn(st))
    @test isfinite(randexp(st))

    st2 = Stateful{8}(42)
    @test chunk_length(Tandem8x32(st2)) == 8
    @test copy(st2) == st2 && copy(st2) !== st2
end
