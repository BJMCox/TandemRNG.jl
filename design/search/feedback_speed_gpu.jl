module FeedbackSpeedGPU
using CUDA
using Main.GPUBench: KA, gibps, best_seconds, idle_check, idle, describe, fold
using .KA: @kernel, @index
const S = Main.FeedbackSpeed

@kernel function draws!(out, key, ::Val{K}, ::Val{C}, mode, ::Val{U}) where {K,C,U}
    i = @index(Global, Linear)
    base = UInt64(i - 1) * UInt64(C)
    chains = ntuple(@inline(c -> S.startkey(key, base + UInt64(c-1), mode)), Val(C))
    accs = ntuple(_ -> UInt32(0), Val(C))
    for _ = 1:(K÷U)
        Base.Cartesian.@nexprs 4 u -> if u <= U
            chains = map(@inline(oh -> S.next(oh[1], oh[2], mode)), chains)
            accs = map((acc, oh) -> fold(acc, oh[1]), accs, chains)
        end
    end
    for c = 1:C
        @inbounds out[(i-1)*C+c] = accs[c]
    end
end

function gpu(
    io;
    cases = ((1, 1, 1), (2, 1, 1), (3, 1, 1), (4, 1, 1)),
    n = 1<<20,
    K = 32,
    gpu = 0,
)
    before = idle_check(gpu)
    idle(before) || error("GPU busy: $(describe(before))")
    CUDA.device!(gpu)
    key = S.F.Tandem8x32(42).key
    expected = map(0:1023) do j
        o, h = S.startkey(key, UInt64(j), Val(1))
        acc = UInt32(0)
        for _ = 1:K
            o, h = S.next(o, h, Val(1))
            acc = fold(acc, o)
        end
        acc
    end
    check = CuVector{UInt32}(undef, 1024)
    for (m, c, u) in cases
        draws!(CUDABackend(), 256)(
            check,
            key,
            Val(K),
            Val(c),
            Val(m),
            Val(u);
            ndrange = 1024÷c,
        )
        @assert Array(check) == expected
    end
    A = CuVector{UInt32}(undef, n)
    println(io, "pass\tmode\tchains\tunroll\tGiB/s")
    for pass = 1:3, (m, c, u) in (isodd(pass) ? cases : reverse(cases))
        f =
            () -> draws!(CUDABackend(), 256)(
                A,
                key,
                Val(K),
                Val(c),
                Val(m),
                Val(u);
                ndrange = n÷c,
            )
        println(io, join((pass, m, c, u, gibps(n*K*16, best_seconds(f, 30))), '\t'))
        flush(io)
    end
    println(io, "before: ", describe(before))
    println(io, "after: ", describe(idle_check(gpu)))
end
end
