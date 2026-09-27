# PureRNGs' public uniform result types, including its Unicode scalar draws.
const PARITY_TYPES = (
    Bool,
    UInt8,
    Int8,
    UInt16,
    Int16,
    UInt32,
    Int32,
    UInt64,
    Int64,
    UInt128,
    Int128,
    Float16,
    Float32,
    Float64,
    Complex{Float16},
    Complex{Float32},
    Complex{Float64},
    Char,
)

@testset "result types: scalar, fill, and stateful agreement" begin
    for T in PARITY_TYPES, K in (1, 32, 64), pos in (0, 1, 63, 127, 1023)
        rng = Tandem8x32{K}(rngkey(Tandem8x32(42)), pos)
        expected, after = scalar_loop(rng, T, 37)
        values, filled = rand_next(rng, T, 37)
        @test values == expected
        @test filled == after
        @test [rand_at(rng, T, i) for i = 1:37] == expected
        stateful = Stateful(rng)
        @test [rand(stateful, T) for _ = 1:37] == expected
        @test parent(stateful) == after
        storage = Vector{T}(undef, 74)
        @test rand_fill!(rng, view(storage, 1:2:74); nthreads = 1) == after
        @test storage[1:2:74] == expected
        matrix, matrix_after = rand_next(rng, T, 1, 37)
        @test vec(matrix) == expected
        @test matrix_after == after
    end
end

@testset "result types: independent mappings" begin
    rng = Tandem8x32(42)
    words, _ = rand_next(rng, UInt16, 513)
    halves, _ = rand_next(rng, Float16, 513)
    @test halves == [Float16(Int(w >> 5) // 2048) for w in words]
    @test all(x -> 0 <= x < 1, halves)
    # Exhaust every half-word input, including zero, for the vector-store encoding.
    @test all(0:65535) do i
        raw = UInt32(i) | (UInt32(65535 - i) << 16)
        lo = Float16((i >> 5) // 2048)
        hi = Float16(((65535 - i) >> 5) // 2048)
        TandemRNG._half_row_word(raw) == reinterpret(UInt32, (lo, hi))
    end
    words, _ = rand_next(rng, UInt32, 4)
    wide = sum(BigInt(words[i]) << (32 * (i - 1)) for i = 1:4)
    @test first(rand_next(rng, UInt128)) == wide
    @test reinterpret(UInt128, first(rand_next(rng, Int128))) == wide
    for T in (Float16, Float32, Float64), pos in (1, 16, 32, 64, 96, 127, 1023)
        start = Tandem8x32(rngkey(rng), pos)
        re, next = rand_next(start, T)
        im, after = rand_next(next, T)
        @test (@inferred rand_next(start, Complex{T})) == (Complex{T}(re, im), after)
    end
    for _ = 1:513
        raw, after = rand_next(rng, UInt64)
        offset = Int((BigInt(raw) * 0x10f800) >> 64)
        expected = Char(offset < 0xd800 ? offset : offset + 0x800)
        value, next = @inferred rand_next(rng, Char)
        @test value == expected && isvalid(value)
        @test next == after
        rng = after
    end
end

@testset "result types: empty and zero-dimensional arrays" begin
    for T in PARITY_TYPES
        rng = last(rand_next(Tandem8x32(42), Bool))
        value, after = rand_next(rng, T)
        array, array_after = rand_next(rng, T, ())
        @test array[] == value && array_after == after
        empty, empty_after = rand_next(rng, T, (0, 3))
        width =
            T === Char ? 64 :
            T === Bool ? 1 : T <: Complex ? 8sizeof(real(zero(T))) : 8sizeof(T)
        @test size(empty) == (0, 3)
        @test empty_after == Tandem8x32(rngkey(rng), width)
    end
end

@testset "result types: device limits" begin
    rng = Tandem8x32(42)
    for device in (
            TandemRNG.MLDataDevices.CUDADevice(),
            TandemRNG.MLDataDevices.AMDGPUDevice(),
            TandemRNG.MLDataDevices.MetalDevice(),
        ),
        T in (UInt128, Int128)

        @test_throws ArgumentError rand_next(device(rng), T, 0)
    end
    metal = TandemRNG.MLDataDevices.MetalDevice()(rng)
    @test_throws ArgumentError rand_next(metal, Complex{Float64}, 0)
end
