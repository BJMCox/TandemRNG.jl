module TaskSweep
using BenchmarkTools, TandemRNG
function run(io; counts = (1, 2, 4, 8, Threads.nthreads()), sizes = (1<<16, 1<<20, 1<<24))
    println(io, "type\tn\ttasks\tns\tGiB/s\tbytes\tallocs")
    rng = Tandem8x32(42)
    for T in (Float64, UInt32, Bool), n in sizes
        A = Vector{T}(undef, n)
        for nt in unique(counts)
            rand_fill!(rng, A; nthreads = nt)
            b = minimum(
                @benchmark rand_fill!($rng, $A; nthreads = $nt) evals=1 samples=50 seconds=0.15
            )
            println(
                io,
                join(
                    (T, n, nt, b.time, sizeof(A)/2.0^30/(b.time/1e9), b.memory, b.allocs),
                    '\t',
                ),
            )
            flush(io)
        end
    end
end
end
