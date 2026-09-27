# Check device fills on a machine with an NVIDIA
# GPU through this environment: `Pkg.test()` is not wired to it, use
# `julia --project=test/cuda test/cuda/runtests.jl` or a Kaimon session on this directory.

using TandemRNG
using CUDA
using KernelAbstractions
using GPUArraysCore
using Test
using TandemRNG.MLDataDevices: CUDADevice, CPUDevice

const DRAW_TYPES = (
    Bool,
    UInt8,
    Int8,
    UInt16,
    Int16,
    UInt32,
    Int32,
    Float16,
    Float32,
    UInt64,
    Int64,
    Float64,
    Complex{Float16},
    Complex{Float32},
    Complex{Float64},
    Char,
)

bits(::Type{T}) where {T} = T === Bool ? 1 : T === Char ? 64 : 8 * sizeof(T)

function device_equals_cpu(rng, ::Type{T}, n) where {T}
    cpu = Vector{T}(undef, n)
    rng_cpu = rand_fill!(rng, cpu)
    gpu = CuVector{T}(undef, n)
    rng_gpu = rand_fill!(CUDADevice()(rng), gpu)
    return Array(gpu) == cpu && rngposition(rng_gpu) == rngposition(rng_cpu)
end

@testset "cuda: device fill" begin
    @test CUDA.functional()
    for K in (1, 32), T in DRAW_TYPES
        rng = Tandem8x32{K}(77)
        n = 5 * 1024 * K ÷ bits(T) + 3   # five rows of this type and a partial block
        # Aligned start at 0 and at block 1 (vector stores, the second is a fill after a
        # fill), and a start one element in (blocks straddle array blocks, scalar stores).
        @test device_equals_cpu(rng, T, n)
        at_block_1 = Tandem8x32{K}(rngkey(rng), 128)
        @test device_equals_cpu(at_block_1, T, n)
        _, shifted = rand_next(rng, T)
        @test device_equals_cpu(shifted, T, n)
        # A fill that ends inside a block, and one that ends at an exact group boundary.
        @test device_equals_cpu(rng, T, 1024 ÷ bits(T) + 1)
        @test device_equals_cpu(rng, T, 3 * 1024 * K ÷ bits(T))
    end
    # Many workgroups, so tile segments and edge blocks appear in every position.
    @test device_equals_cpu(Tandem8x32{32}(5), Float32, 4 * 64 * 32 * 4 + 17)
    @test device_equals_cpu(Tandem8x32{32}(5), Bool, 1 << 20 + 3)
    # The short tail must not read a second staging word. Advanced positions remain
    # valid beyond the constructor limit, and the final partial word must not wrap.
    for (p, n) in ((UInt64(31), 1), (UInt64(1) << 63, 65), (typemax(UInt64) - 63, 33))
        rng = TandemRNG._advance(Tandem8x32(42), p)
        @test device_equals_cpu(rng, Bool, n)
    end
    rng = TandemRNG._advance(Tandem8x32(42), typemax(UInt64) - 1023)
    @test device_equals_cpu(rng, UInt32, 1)
    tail = CUDADevice()(TandemRNG._advance(rng, typemax(UInt64)))
    @test_throws ArgumentError rand_fill!(tail, CuVector{UInt32}(undef, 1))
    @test_throws ArgumentError rand_fill!(tail, CuVector{Bool}(undef, 1))
end

@testset "cuda: device residence" begin
    cpu = last(rand_next(Tandem8x32(42), Bool))
    rng = CUDADevice()(cpu)
    values, after = rand_next(rng, Float64, 17, 3)
    expected, expected_rng = rand_next(cpu, Float64, 17, 3)
    @test values isa CuArray
    @test Array(values) == expected
    @test CPUDevice()(after) == expected_rng
    @test TandemRNG.MLDataDevices.get_device_type(after) == CUDADevice
    for T in (Bool, UInt32)
        storage = CUDA.zeros(T, 137)
        expected = zeros(T, 137)
        device_after = rand_fill!(rng, view(storage, 1:2:137))
        cpu_after = rand_fill!(cpu, view(expected, 1:2:137))
        @test Array(storage) == expected
        @test CPUDevice()(device_after) == cpu_after
    end
    for T in (Bool, UInt32), n in (0, 17)
        host = fill(zero(T), n)
        device = CuArray(host)
        @test_throws ArgumentError rand_fill!(cpu, device)
        @test_throws ArgumentError rand_fill!(rng, host)
        @test Array(device) == zeros(T, n)
        @test host == zeros(T, n)
    end
end
