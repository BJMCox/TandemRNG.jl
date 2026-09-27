# Bridge to the `Random` API. `Stateful` owns one generator value, a position, and a copy of
# the current row's output words. The value is held at the start of the row of the position
# and replaced only when a draw leaves that row. A draw inside the row indexes the copied
# words to avoid copying the generator value on every indexed load. `rand`, `rand!`, `randn`, and
# every sampler that builds on `rand(rng, UInt64)` work unchanged. Floats keep the stream
# law: Float64 takes the top 53 bits of a 64-bit draw, Float32 the top 24 bits of a 32-bit
# draw, and a Bool is one bit.

"""
    Stateful(rng::Tandem8x32) <: Random.AbstractRNG
    Stateful(seed::Integer)
    Stateful{K}(seed::Integer)

Mutable wrapper for the `Random` API. It explicitly rebinds device generators to the CPU.
`Tandem8x32(st)` and `parent(st)` return the current immutable CPU generator.
"""
mutable struct Stateful{K} <: Random.AbstractRNG
    value::Tandem8x32{K,_CPUBackend}
    pos::UInt64
    row::Vector{UInt32}   # the 32 words of `value.o`, word-major: word w of lane ℓ at 8w + ℓ + 1

    function Stateful(value::Tandem8x32{K}, pos::UInt64) where {K}
        r = new{K}(_bind(value, _CPUBackend()), pos, Vector{UInt32}(undef, 4 * LANES))
        _copy_row!(r)
        return r
    end
end

Base.parent(rng::Stateful) = Tandem8x32(rng)

@inline _row_start(pos::UInt64) = pos & ~UInt64(ROW_BITS - 1)

Stateful(rng::Tandem8x32) = Stateful(_advance(rng, _row_start(rng.pos)), rng.pos)
Stateful(seed::Integer) = Stateful(Tandem8x32(seed))
Stateful{K}(seed::Integer) where {K} = Stateful(Tandem8x32{K}(seed))
Stateful() = Stateful(rand(Random.RandomDevice(), UInt128))

Tandem8x32(r::Stateful) = _advance(r.value, r.pos)

Base.copy(r::Stateful) = Stateful(r.value, r.pos)
Base.:(==)(a::Stateful, b::Stateful) = Tandem8x32(a) == Tandem8x32(b)
Base.hash(r::Stateful, h::UInt) = hash(Tandem8x32(r), hash(:TandemStateful, h))

Random.rng_native_52(::Stateful) = UInt64

function _copy_row!(r::Stateful)
    o = r.value.o
    for w = 1:4, ℓ = 1:LANES
        @inbounds r.row[LANES*(w-1)+ℓ] = lane(o[w], ℓ)
    end
    return r
end

# Move the value to the row start `pos`: one T from the previous row inside a group,
# otherwise the general move. Out of line so a draw inlines as a check and four loads.
@noinline function _move_row!(r::Stateful{K}, pos::UInt64) where {K}
    rng = r.value
    row = _row(pos)
    if row == _row(rng.pos) + 1 && row & UInt64(K - 1) != 0
        o, h = step(rng.o, rng.h)
        r.value = _rebuild(rng, pos, o, h)
    else
        r.value = _advance(rng, pos)
    end
    _copy_row!(r)
    return nothing
end

@inline function _draw!(r::Stateful, ::Type{T}) where {T}
    nb = draw_bits(T)
    pos = _align_up(r.pos, nb)
    _row(pos) == _row(r.value.pos) || _move_row!(r, _row_start(pos))
    ℓ = _lane(pos)
    block = @inbounds (r.row[ℓ+1], r.row[ℓ+9], r.row[ℓ+17], r.row[ℓ+25])
    r.pos = pos + UInt64(nb)
    return _element(T, block, pos)
end

@inline _draw!(r::Stateful, ::Type{Complex{T}}) where {T<:FloatTypes} =
    Complex{T}(_draw!(r, T), _draw!(r, T))

function _fill!(r::Stateful, A)
    v = rand_fill!(Tandem8x32(r), A)
    r.value = _advance(v, _row_start(v.pos))
    r.pos = v.pos
    _copy_row!(r)
    return A
end

for T in (
    Bool,
    UInt8,
    Int8,
    UInt16,
    Int16,
    UInt32,
    Int32,
    UInt64,
    Int64,
    UInt128,
    Int128,
    Char,
    Complex{Float16},
    Complex{Float32},
    Complex{Float64},
)
    @eval @inline Random.rand(r::Stateful, ::Random.SamplerType{$T}) = _draw!(r, $T)
    @eval Random.rand!(r::Stateful, A::Array{$T}, ::Random.SamplerType{$T}) = _fill!(r, A)
end

for T in (Float16, Float32, Float64)
    @eval @inline Random.rand(
        r::Stateful,
        ::Random.SamplerTrivial{Random.CloseOpen01{$T}},
    ) = _draw!(r, $T)
    @eval Random.rand!(
        r::Stateful,
        A::Array{$T},
        ::Random.SamplerTrivial{Random.CloseOpen01{$T}},
    ) = _fill!(r, A)
end

function Random.seed!(r::Stateful{K}, seed::Integer) where {K}
    r.value = Tandem8x32{K}(seed)
    r.pos = 0
    _copy_row!(r)
    return r
end

Random.seed!(r::Stateful) = Random.seed!(r, rand(Random.RandomDevice(), UInt128))
