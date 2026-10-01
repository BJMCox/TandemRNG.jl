module FeedbackFull
include("feedback.jl")
const F = TandemFeedback.TandemRNG
@eval F begin
    @noinline function _fill_full_group!(A, key, g, p0, ::Val{K}) where {K}
        o, h = seed_row(key, g)
        prow = g * (UInt64(ROW_BITS) * UInt64(K))
        for _ = 1:K
            o, h = step(o, h)
            _write_row!(A, o, prow, p0)
            prow += ROW_BITS
        end
        return nothing
    end

    function _fill_group!(
        A::AbstractArray{T},
        key::O4,
        g::UInt64,
        p0::UInt64,
        pend::UInt64,
        ::Val{K},
    ) where {T,K}
        prow = g * (UInt64(ROW_BITS) * UInt64(K))
        if p0 <= prow && UInt64(ROW_BITS) * UInt64(K) <= pend - prow
            return _fill_full_group!(A, key, g, p0, Val(K))
        end
        o, h = seed_row(key, g)
        for _ = 1:K
            prow >= pend && break
            o, h = step(o, h)
            if prow >= p0 && prow + ROW_BITS <= pend
                _write_row!(A, o, prow, p0)
            elseif prow + ROW_BITS > p0
                _write_partial_row!(A, o, prow, p0, pend)
            end
            prow += ROW_BITS
        end
        return nothing
    end
end

using BenchmarkTools
function compare(io; n = 1<<20, candidate = F)
    println(io, "pass\ttype\tvariant\tGiB/s\tallocations")
    for T in (UInt32, Float32, Float64, Bool)
        A = Vector{T}(undef, n)
        base = Main.TandemFeedback.TandemRNG
        expected = similar(A)
        base.rand_fill!(base.Tandem8x32(42), expected; nthreads = 1)
        cases = (
            ("feedback", base.rand_fill!, base.Tandem8x32(42)),
            ("full_groups", candidate.rand_fill!, candidate.Tandem8x32(42)),
        )
        for (_, f, rng) in cases
            f(rng, A; nthreads = 1)
            @assert A==expected
        end
        for pass = 1:3, (name, f, rng) in (isodd(pass) ? cases : reverse(cases))
            b=minimum(@benchmark $f($rng, $A; nthreads = 1) evals=1 samples=80 seconds=0.3)
            println(
                io,
                join((pass, T, name, sizeof(A)/(b.time*1e-9)/2.0^30, b.allocs), '\t'),
            )
        end
    end
end
end
