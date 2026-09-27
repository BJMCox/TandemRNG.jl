# Eight-lane vector primitives. `V8` is an LLVM `<8 x i32>`.
# LLVM operations express packed arithmetic, products, rotations, shuffles, and Bool expansion.
# Float conversion uses native Julia.

const V8 = NTuple{8,VecElement{UInt32}}

for (name, op) in ((:_vxor, "xor"), (:_vadd, "add"), (:_vor, "or"), (:_vmul, "mul"))
    ir = "%r = $op <8 x i32> %0, %1\nret <8 x i32> %r"
    @eval @inline $name(a::V8, b::V8) = Base.llvmcall($ir, V8, Tuple{V8,V8}, a, b)
end

@inline _vsplat(x::UInt32) = ntuple(_ -> VecElement(x), Val(8))

@inline _vmulhi(a::V8, b::V8) = Base.llvmcall(
    """
    %a = zext <8 x i32> %0 to <8 x i64>
    %b = zext <8 x i32> %1 to <8 x i64>
    %p = mul <8 x i64> %a, %b
    %s = lshr <8 x i64> %p, <i64 32, i64 32, i64 32, i64 32, i64 32, i64 32, i64 32, i64 32>
    %r = trunc <8 x i64> %s to <8 x i32>
    ret <8 x i32> %r""",
    V8,
    Tuple{V8,V8},
    a,
    b,
)

@generated function _vrotl(a::V8, ::Val{R}) where {R}
    left = join(("i32 $R" for _ = 1:8), ", ")
    right = join(("i32 $(32 - R)" for _ = 1:8), ", ")
    ir = """
        %s = shl <8 x i32> %0, <$left>
        %t = lshr <8 x i32> %0, <$right>
        %r = or <8 x i32> %s, %t
        ret <8 x i32> %r"""
    return :(Base.llvmcall($ir, V8, Tuple{V8}, a))
end

# Lane permutations. `M` is the LLVM mask: indices 0 to 7 pick from `a`, 8 to 15 from `b`.
@generated function _vshuffle(a::V8, b::V8, ::Val{M}) where {M}
    mask = join(("i32 $m" for m in M), ", ")
    ir = "%r = shufflevector <8 x i32> %0, <8 x i32> %1, <8 x i32> <$mask>\nret <8 x i32> %r"
    return :(Base.llvmcall($ir, V8, Tuple{V8,V8}, a, b))
end

@inline _vrotate1(a::V8) = _vshuffle(a, a, Val((1, 2, 3, 4, 5, 6, 7, 0)))

# Word-major row (word w of lanes 0 to 7) to memory order (lanes 0 to 7, each its four
# words): a 4×8 register transpose in eight two-source shuffles. Output vector k holds
# blocks 2k and 2k + 1.
@inline function _vtranspose(w0::V8, w1::V8, w2::V8, w3::V8)
    lo = Val((0, 8, 1, 9, 2, 10, 3, 11))
    hi = Val((4, 12, 5, 13, 6, 14, 7, 15))
    p0 = _vshuffle(w0, w1, lo)
    p1 = _vshuffle(w0, w1, hi)
    q0 = _vshuffle(w2, w3, lo)
    q1 = _vshuffle(w2, w3, hi)
    pair_lo = Val((0, 1, 8, 9, 2, 3, 10, 11))
    pair_hi = Val((4, 5, 12, 13, 6, 7, 14, 15))
    return (
        _vshuffle(p0, q0, pair_lo),
        _vshuffle(p0, q0, pair_hi),
        _vshuffle(p1, q1, pair_lo),
        _vshuffle(p1, q1, pair_hi),
    )
end

# The 32 bits of one word as 32 bytes of 0 or 1, bit i in byte i. A Bool consumes one bit.
# Each source byte is repeated eight times, masked with the eight bit weights, and compared.
const V32 = NTuple{32,VecElement{UInt8}}

@inline _vexpand(x::UInt32) = Base.llvmcall(
    """
    %b = bitcast i32 %0 to <4 x i8>
    %e = shufflevector <4 x i8> %b, <4 x i8> poison, <32 x i32> <i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 0, i32 1, i32 1, i32 1, i32 1, i32 1, i32 1, i32 1, i32 1, i32 2, i32 2, i32 2, i32 2, i32 2, i32 2, i32 2, i32 2, i32 3, i32 3, i32 3, i32 3, i32 3, i32 3, i32 3, i32 3>
    %m = and <32 x i8> %e, <i8 1, i8 2, i8 4, i8 8, i8 16, i8 32, i8 64, i8 -128, i8 1, i8 2, i8 4, i8 8, i8 16, i8 32, i8 64, i8 -128, i8 1, i8 2, i8 4, i8 8, i8 16, i8 32, i8 64, i8 -128, i8 1, i8 2, i8 4, i8 8, i8 16, i8 32, i8 64, i8 -128>
    %c = icmp ne <32 x i8> %m, zeroinitializer
    %r = zext <32 x i1> %c to <32 x i8>
    ret <32 x i8> %r""",
    V32,
    Tuple{UInt32},
    x,
)

# Keep float lanes together until the final bitcast so Julia can vectorize the conversion.
@inline _vfloat32(a::V8) = reinterpret(
    V8,
    ntuple(i -> VecElement(Float32(a[i].value >> 8) * Float32(0x1p-24)), Val(8)),
)
