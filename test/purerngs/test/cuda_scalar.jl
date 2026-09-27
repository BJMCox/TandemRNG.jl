# Public scalar calls inside a kernel must retain the bound generator's stream.
function tandem_scalar_kernel!(integers, floats, states)
    i = Int(CUDA.threadIdx().x)
    if i <= length(states)
        rng = states[i]
        integers[i], rng = PR.rand_next(rng, UInt32)
        floats[i], rng = PR.rand_next(rng, Float64)
        states[i] = rng
    end
    return nothing
end

function tandem_typed_kernel!(output, states, draw::F) where {F}
    i = Int(CUDA.threadIdx().x)
    if i <= length(states)
        rng = states[i]
        for j in axes(output, 1)
            output[j, i], rng = draw(rng, eltype(output))
        end
        states[i] = rng
    end
    return nothing
end

@testset "All native and bridge CUDA scalar types" begin
    types = (
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
        Complex{Float16},
        Complex{Float32},
        Complex{Float64},
        Char,
    )
    device = TR.MLDataDevices.CUDADevice()
    to_cpu = TR.MLDataDevices.CPUDevice()
    for K in (1, 32), T in types, draw in (TR.rand_next, PR.rand_next)
        cpu = [
            TR.Tandem8x32{K}(TR.rngkey(TR.Tandem8x32(i)), p) for
            (i, p) in enumerate((1, 127, 1023, 32767))
        ]
        states = CuArray(device.(cpu))
        output = CuArray{T}(undef, 8, length(cpu))
        CUDA.@sync CUDA.@cuda threads=length(cpu) tandem_typed_kernel!(output, states, draw)
        expected = Matrix{T}(undef, size(output))
        for i in eachindex(cpu), j in axes(expected, 1)
            expected[j, i], cpu[i] = draw(cpu[i], T)
        end
        @test Array(output) == expected
        @test to_cpu.(Array(states)) == cpu
    end
end

@testset "Tandem bridge in a CUDA kernel" begin
    device = TR.MLDataDevices.CUDADevice()
    to_cpu = TR.MLDataDevices.CPUDevice()
    for K in (1, 32)
        # The first draw leaves a row or group and forces a cached-state update.
        cpu = [
            TR.Tandem8x32{K}(TR.rngkey(TR.Tandem8x32(seed)), position) for
            (seed, position) in ((42, 992), (99, 32736))
        ]
        states = CuArray(device.(cpu))
        integers = CUDA.zeros(UInt32, 2)
        floats = CUDA.zeros(Float64, 2)
        CUDA.@sync CUDA.@cuda threads=2 tandem_scalar_kernel!(integers, floats, states)
        actual_integers, actual_floats, after =
            Array(integers), Array(floats), Array(states)
        for i in eachindex(cpu)
            x, rng = PR.rand_next(cpu[i], UInt32)
            y, rng = PR.rand_next(rng, Float64)
            @test actual_integers[i] == x
            @test actual_floats[i] == y
            @test to_cpu(after[i]) == rng
        end
    end
end
