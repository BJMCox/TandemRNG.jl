module FeedbackSpeed
using Random, BenchmarkTools
const F = Main.TandemFeedback.TandemRNG

@inline encode(o, h) = (o, (h[1] ⊻ o[1], h[2], h[3], h[4]))

@inline function encoded_step(o, z)
    h = (z[1] ⊻ o[1], z[2], z[3], z[4])
    return F.mix(o, h), F.clock(h)
end

@inline function encoded_seed(o, h)
    o, z = encode(o, h)
    Base.Cartesian.@nexprs 8 r -> begin
        m, q = encoded_step(o, z)
        o = (q[1] ⊻ m[1], q[2], q[3], q[4])
        z = (q[1] ⊻ F.RC[r], m[2], m[3], m[4])
    end
    return o, z
end

@inline function clockfirst(o, h)
    q = F.clock(h)
    m = F.mix(o, h)
    return m, (q[1] ⊻ m[1], q[2], q[3], q[4])
end

@inline start(o, h, ::Val{1}) = F.seed(o, h)
@inline start(o, h, ::Val{2}) = F.seed(o, h)
@inline start(o, h, ::Val{3}) = encode(F.seed(o, h)...)
@inline start(o, h, ::Val{4}) = encoded_seed(o, h)
@inline next(o, h, ::Val{1}) = F.step(o, h)
@inline next(o, h, ::Val{2}) = clockfirst(o, h)
@inline next(o, h, ::Val{3}) = encoded_step(o, h)
@inline next(o, h, ::Val{4}) = encoded_step(o, h)
@inline canonical(o, h, ::Val{M}) where {M} = M <= 2 ? (o, h) : encode(o, h)
@inline startkey(key, c, mode) =
    start((c % UInt32, (c >> 32) % UInt32, F.DOMAIN_STREAM, F.AUX_STREAM), key, mode)

function verify()
    rng = Xoshiro(42)
    for i = 1:256
        o, h = ntuple(_ -> rand(rng, UInt32), 4), ntuple(_ -> rand(rng, UInt32), 4)
        for mode in (Val(1), Val(2), Val(3), Val(4))
            x, y = start(o, h, mode)
            a, b = F.seed(o, h)
            @assert canonical(x, y, mode) == (a, b)
            for _ = 1:64
                x, y = next(x, y, mode)
                a, b = F.step(a, b)
                @assert canonical(x, y, mode) == (a, b)
            end
        end
    end
    return true
end

function fill!(A::Array, key, mode, ::Val{K}) where {K}
    rows = length(A) * F.draw_bits(eltype(A)) ÷ F.ROW_BITS
    @assert rows % K == 0
    for g = UInt64(0):UInt64(rows÷K-1)
        c0 = g << 3
        o = (
            F.Lane8(ntuple(i -> (c0 + UInt64(i-1)) % UInt32, Val(8))),
            F.Lane8(ntuple(i -> ((c0 + UInt64(i-1)) >> 32) % UInt32, Val(8))),
            F.Lane8(F.DOMAIN_STREAM),
            F.Lane8(F.AUX_STREAM),
        )
        h = ntuple(i -> F.Lane8(key[i]), Val(4))
        o, h = start(o, h, mode)
        for j = 0:(K-1)
            o, h = next(o, h, mode)
            F._write_row!(A, o, (g * UInt64(K) + UInt64(j)) * UInt64(F.ROW_BITS), UInt64(0))
        end
    end
    return A
end

function cpu(io; n = 1<<20)
    key = F.Tandem8x32(42).key
    println(io, "pass\ttype\tmode\tGiB/s\tallocations")
    for T in (UInt32, Float64)
        A = Vector{T}(undef, n)
        expected = similar(A)
        F.rand_fill!(F.Tandem8x32(key), expected; nthreads = 1)
        for mode in (Val(1), Val(2), Val(3), Val(4))
            fill!(A, key, mode, Val(32))
            @assert A == expected
        end
        for pass = 1:3, m in (isodd(pass) ? (1, 2, 3, 4) : (4, 3, 2, 1))
            mode = Val(m)
            trial =
                @benchmark fill!($A, $key, $mode, Val(32)) evals=1 samples=80 seconds=0.25
            b = minimum(trial)
            println(io, join((pass, T, m, sizeof(A)/(b.time*1e-9)/2.0^30, b.allocs), '\t'))
        end
    end
end
end
