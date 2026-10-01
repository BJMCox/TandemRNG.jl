module NativeSIMDProbe

using BenchmarkTools, TandemRNG

const VARIANTS = (
    "arithmetic" => quote
        @inline _vxor(a::V8, b::V8) =
            ntuple(i -> VecElement(a[i].value ⊻ b[i].value), Val(8))
        @inline _vadd(a::V8, b::V8) =
            ntuple(i -> VecElement(a[i].value + b[i].value), Val(8))
        @inline _vor(a::V8, b::V8) =
            ntuple(i -> VecElement(a[i].value | b[i].value), Val(8))
        @inline _vmul(a::V8, b::V8) =
            ntuple(i -> VecElement(a[i].value * b[i].value), Val(8))
    end,
    "wide_product" => quote
        @inline function mulwide(x::Lane8, m::Lane8)
            p = ntuple(i -> UInt64(x.v[i].value) * UInt64(m.v[i].value), Val(8))
            hi = Lane8(ntuple(i -> VecElement((p[i] >> 32) % UInt32), Val(8)))
            lo = Lane8(ntuple(i -> VecElement(p[i] % UInt32), Val(8)))
            return hi, lo
        end
    end,
    "rotate_shifts" => quote
        @inline _vrotl(a::V8, ::Val{R}) where {R} = ntuple(
            i -> VecElement((a[i].value << R) | (a[i].value >> (32 - R))),
            Val(8),
        )
    end,
    "rotate_bitrotate" => quote
        @inline _vrotl(a::V8, ::Val{R}) where {R} =
            ntuple(i -> VecElement(bitrotate(a[i].value, R)), Val(8))
    end,
    "shuffle" => quote
        @inline _vshuffle(a::V8, b::V8, ::Val{M}) where {M} =
            ntuple(i -> M[i] < 8 ? a[M[i]+1] : b[M[i]-7], Val(length(M)))
    end,
    "float32" => quote
        @inline _vfloat32(a::V8) = reinterpret(
            V8,
            ntuple(i -> VecElement(Float32(a[i].value >> 8) * Float32(0x1p-24)), Val(8)),
        )
    end,
    "bool_bytes" => quote
        @inline function _vexpand(x::UInt32)
            bytes = reinterpret(NTuple{4,VecElement{UInt8}}, x)
            ntuple(Val(32)) do i
                b = bytes[(i-1)÷8+1].value
                VecElement(UInt8(!iszero(b & (UInt8(1) << ((i - 1) & 7)))))
            end
        end
    end,
    "bool_shifts" => quote
        @inline _vexpand(x::UInt32) =
            ntuple(i -> VecElement(UInt8((x >> (i - 1)) & UInt32(1))), Val(32))
    end,
)

function chain1024(draw, rng)
    acc = 0.0
    for _ = 1:1024
        x, rng = draw(rng, Float64)
        acc += x
    end
    return acc, rng
end

function measure(io, M, name)
    f = M.rand_fill!
    rng = M.Tandem8x32(42)
    for T in (Float64, Float32, UInt32, Bool)
        expected = Vector{T}(undef, 65539)
        actual = similar(expected)
        TandemRNG.rand_fill!(TandemRNG.Tandem8x32(42), expected; nthreads = 1)
        f(rng, actual; nthreads = 1)
        actual == expected || error("$name changes $T output")
        A = Vector{T}(undef, 1 << 20)
        f(rng, A; nthreads = 1)
        best =
            minimum(@benchmark $f($rng, $A; nthreads = 1) evals=1 samples=40 seconds=0.15)
        println(
            io,
            join((name, T, sizeof(A)/2^30/(best.time/1e9), best.memory, best.allocs), '\t'),
        )
        flush(io)
    end
    draw = M.rand_next
    chain1024(draw, rng)
    best = minimum(@benchmark chain1024($draw, $rng) evals=100 samples=1000 seconds=0.15)
    println(io, join((name, "chain1024", best.time/1024, best.memory, best.allocs), '\t'))
    flush(io)
    println(stderr, "Native probe complete: ", name)
    return nothing
end

function run(io, source)
    println(io, "variant\ttype\tGiB/s_or_ns_per_draw\tbytes_allocated\tallocations")
    measure(io, TandemRNG, "baseline")
    for (name, changes) in VARIANTS
        container = Module(Symbol("Probe_", name))
        Base.include(container, source)
        M = getfield(container, :TandemRNG)
        Core.eval(M, changes)
        Base.invokelatest(measure, io, M, name)
    end
    return nothing
end

end
