module FeedbackGPU
using CUDA, TandemRNG
using Main.GPUBench:
    KA, gibps, best_seconds, idle_check, idle, describe, draws_tandem!, fold
using .KA: @kernel, @index
const F = Main.TandemFeedback.TandemRNG

@kernel function draws_feedback!(out, key, ::Val{K}, ::Val{C}) where {K,C}
    i = @index(Global, Linear)
    base = UInt64(i - 1) * UInt64(C)
    chains = ntuple(
        @inline(c -> F.seed(key, base + UInt64(c-1), F.DOMAIN_STREAM, F.AUX_STREAM)),
        Val(C),
    )
    accs = ntuple(_ -> UInt32(0), Val(C))
    for _ = 1:K
        chains = map(oh -> F.step(oh[1], oh[2]), chains)
        accs = map((acc, oh)->fold(acc, oh[1]), accs, chains)
    end
    for c = 1:C
        @inbounds out[(i-1)*C+c] = accs[c]
    end
end

function run(io; gpu = 0, n = 1<<20, K = 32)
    TandemRNG.step(ntuple(UInt32, 4), ntuple(i -> UInt32(i+4), 4))[2][1] == 0x9e377cbe ||
        error("Historical paired benchmark requires the pre-feedback source snapshot")
    before = idle_check(gpu)
    idle(before) || error("GPU busy: $(describe(before))")
    CUDA.device!(gpu)
    key = Tandem8x32{K}(1).key
    A = CuVector{UInt32}(undef, 1024)
    expected = map(0:1023) do j
        o, h = F.seed(key, UInt64(j), F.DOMAIN_STREAM, F.AUX_STREAM)
        acc = UInt32(0)
        for _ = 1:K
            o, h = F.step(o, h)
            acc = fold(acc, o)
        end
        acc
    end
    draws_feedback!(CUDABackend(), 256)(A, key, Val(K), Val(1); ndrange = length(A))
    Array(A)==expected || error("Feedback GPU differs from CPU")
    A = CuVector{UInt32}(undef, n)
    cases = (("original", draws_tandem!), ("feedback", draws_feedback!))
    println(io, "pass\tvariant\tGiB/s")
    for pass = 1:3, (name, kernel) in (isodd(pass) ? cases : reverse(cases))
        f = () -> kernel(CUDABackend(), 256)(A, key, Val(K), Val(1); ndrange = n)
        println(io, join((pass, name, gibps(n*K*16, best_seconds(f, 30))), '\t'))
    end
    println(io, "before: ", describe(before))
    println(io, "after: ", describe(idle_check(gpu)))
end
end
