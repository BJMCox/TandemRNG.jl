module FeedbackBench
using BenchmarkTools, TandemRNG

function chain1024(draw, rng)
    acc = 0.0
    for _ = 1:1024
        x, rng = draw(rng, Float64)
        acc += x
    end
    return acc, rng
end

function verify(M)
    for T in (UInt32, Float32, Float64, Bool)
        n = 2 * 1024 * 32 ÷ M.draw_bits(T) + 3
        rng = M.Tandem8x32(42)
        A = Vector{T}(undef, n)
        B = similar(A)
        final = M.rand_fill!(rng, A; nthreads = 3)
        for i in eachindex(B)
            B[i], rng = M.rand_next(rng, T)
        end
        A == B || error("feedback fill and scalar stream disagree for $T")
        M.rngposition(final) == M.rngposition(rng) ||
            error("feedback final position differs")
    end
    return true
end

function run(io, feedback)
    TandemRNG.step(ntuple(UInt32, 4), ntuple(i -> UInt32(i+4), 4))[2][1] == 0x9e377cbe ||
        error("Historical paired benchmark requires the pre-feedback source snapshot")
    verify(feedback)
    cases = (("original", TandemRNG), ("feedback", feedback))
    println(io, "pass\ttype\tvariant\tGiB/s_or_ns\tbytes\tallocs")
    for T in (Float64, Float32, UInt32, Bool), pass = 1:3
        A = Vector{T}(undef, 1 << 20)
        for (name, M) in (isodd(pass) ? cases : reverse(cases))
            rng, f = M.Tandem8x32(42), M.rand_fill!
            f(rng, A; nthreads = 1)
            b = minimum(
                @benchmark $f($rng, $A; nthreads = 1) evals=1 samples=80 seconds=0.3
            )
            println(
                io,
                join(
                    (pass, T, name, sizeof(A)/2.0^30/(b.time/1e9), b.memory, b.allocs),
                    '\t',
                ),
            )
        end
    end
    for pass = 1:3, (name, M) in (isodd(pass) ? cases : reverse(cases))
        rng, f = M.Tandem8x32(42), M.rand_next
        chain1024(f, rng)
        b = minimum(@benchmark chain1024($f, $rng) evals=100 samples=1000 seconds=0.3)
        println(io, join((pass, "chain1024", name, b.time/1024, b.memory, b.allocs), '\t'))
    end
end
end
