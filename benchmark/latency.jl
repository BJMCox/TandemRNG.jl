# Run in a fresh process after Pkg.precompile(). Compare identical Julia flags and threads.
# julia --startup-file=no --threads=2 --project=CHECKOUT benchmark/latency.jl
# Add --trace-compile=PATH to inspect remaining compilation.
using Printf

function report(label, stats)
    compile = hasproperty(stats, :compile_time) ? stats.compile_time : NaN
    @printf("%s\t%.9f\t%d\t%.9f\n", label, stats.time, stats.bytes, compile)
    return stats.value
end

println("case\tseconds\tbytes\tcompile_seconds")
report("load", @timed @eval using TandemRNG, Random)

for K in (32, 1, 64)
    rng = report("K$K/construct", @timed Tandem8x32{K}(42))
    for T in
        (Float64, Float32, UInt32, UInt64, Bool, UInt8, Int8, UInt16, Int16, Int32, Int64)
        tag = "K$K/$T"
        report("$tag/next", @timed rand_next(rng, T))
        report("$tag/at", @timed rand_at(rng, T, 19))
        A = Vector{T}(undef, 32771)
        report("$tag/fill", @timed rand_fill!(rng, A; nthreads = 1))
        report("$tag/tasks", @timed rand_fill!(rng, A; nthreads = 2))
        st = Stateful(rng)
        report("$tag/rand", @timed rand(st, T))
        report("$tag/rand!", @timed rand!(st, A))
    end
    report("K$K/split", @timed splitrng(rng, 8))
    report("K$K/split-tuple", @timed splitrng(rng, Val(2)))
    report("K$K/fork", @timed forkrng(rng, 8))
    report("K$K/fork-tuple", @timed forkrng(rng, Val(2)))
    report("K$K/subrng", @timed subrng(rng, 7))
    st = Stateful(rng)
    report("K$K/randn", @timed randn(st))
    report("K$K/randexp", @timed randexp(st))
    report("K$K/range", @timed rand(st, 1:100))
    report("K$K/seed!", @timed Random.seed!(st, 77))
    report("K$K/split-tasks", @timed splitrng(rng, 1024))
    report("K$K/fork-tasks", @timed forkrng(rng, 1024))
end

rng = Tandem8x32(42)
st = Stateful(rng)
for T in (Float64, Float32, UInt32, Bool)
    A = Matrix{T}(undef, 17, 19)
    report("matrix/$T/fill", @timed rand_fill!(rng, A; nthreads = 1))
    report("view/$T/fill", @timed rand_fill!(rng, view(A, 1:2:17, 2); nthreads = 1))
    report("allocate/$T/rand", @timed rand(st, T, 17))
    report("allocate/$T/matrix", @timed rand(st, T, 4, 4))
end
for T in (Float64, Float32)
    A = Vector{T}(undef, 17)
    report("$T/randn!", @timed randn!(st, A))
    report("$T/randexp!", @timed randexp!(st, A))
end
