# Independent scalar reference for SPEC draft 4. Uses UInt64 intermediates and explicit masks.
module TandemReferenceV2
using Random
const MASK = UInt64(0xffffffff)
const RC = UInt64[
    0xd17cc1b7,
    0xa7220a94,
    0xfe13abe8,
    0xfa9a6ee0,
    0xedb14acc,
    0x9e21c820,
    0xff28b1d5,
    0xef5de2b0,
]
rot(x, r) = ((x<<r)|(x>>(32-r))) & MASK
function step(state)
    a, b, c, d, x, y, z, w=UInt64.(state)
    p=a*(x|1)
    q=c*(y|1)
    exposed=[
        b ⊻ (q>>32) ⊻ (q&MASK),
        rot(q&MASK, 16) ⊻ z,
        d ⊻ (p>>32) ⊻ (p&MASK),
        rot(p&MASK, 16) ⊻ w,
    ]
    t=x ⊻ rot(y, 7)
    hidden=[
        ((t+0x9e3779b9)&MASK) ⊻ exposed[1],
        y ⊻ rot(z, 13),
        z ⊻ rot(w, 22),
        w ⊻ rot(t, 3),
    ]
    return vcat(exposed, hidden)
end
function seed(key, counter, domain, aux)
    state=UInt64[counter&MASK, counter>>32, domain, aux, key...]
    for rc in RC
        state=step(state)
        state[1] ⊻= rc
        state=vcat(state[5:8], state[1:4])
    end
    return state
end
key(z) =
    seed(UInt64[(z>>(32i))&MASK for i = 0:3], UInt64(0), UInt64(0xa54ff53a), UInt64(0))[1:4]
function block(key, c, j)
    state=seed(key, UInt64(c), UInt64(0x9e3779b9), UInt64(0x94d049bb))
    for _ = 0:j
        state=step(state)
    end
    return state[1:4]
end
f64(words, i) = Float64(((words[2i+2]<<32)|words[2i+1])>>11)*0x1p-53
hex(words) = join(string.(words; base = 16, pad = 8), ' ')
function verify(F)
    rng=Xoshiro(173)
    for _ = 1:256
        s=rand(rng, UInt32, 8)
        o, h=F.step(Tuple(s[1:4]), Tuple(s[5:8]))
        @assert UInt64[o..., h...] == step(s)
        c=rand(rng, UInt64)
        dom, aux=rand(rng, UInt32, 2)
        o, h=F.seed(Tuple(s[5:8]), c, dom, aux)
        @assert UInt64[o..., h...] == seed(s[5:8], c, dom, aux)
    end
    return true
end
function report(io)
    k=UInt64[1, 2, 3, 4]
    println(io, "T structured: ", hex(step(UInt64[1, 2, 3, 4, 5, 6, 7, 8])))
    for c = 0:1
        println(
            io,
            "F stream c=",
            c,
            ": ",
            hex(seed(k, UInt64(c), UInt64(0x9e3779b9), UInt64(0x94d049bb))),
        )
    end
    for (c, j) in ((0, 0), (1, 0), (0, 1))
        println(io, "block c=", c, " j=", j, ": ", hex(block(k, c, j)))
    end
    a, b=block(k, 0, 0), block(k, 0, 1)
    println(
        io,
        "draws: f64[0]=",
        f64(a, 0),
        " f64[16]=",
        f64(b, 0),
        " f32[2]=",
        Float32(a[3]>>8)*Float32(0x1p-24),
    )
    println(
        io,
        "bool[0:7]=",
        [isodd(a[1]>>i) for i = 0:7],
        " bool[128]=",
        isodd(block(k, 1, 0)[1]),
    )
    println(io, "split halves: ", hex(seed(k, UInt64(0), UInt64(0xbb67ae85), UInt64(0))))
    println(io, "fork 0: ", hex(seed(k, UInt64(0), UInt64(0xd2511f53), UInt64(0))[1:4]))
    println(io, "purpose 7: ", hex(seed(k, UInt64(7), UInt64(0xcd9e8d57), UInt64(0))[1:4]))
    k=key(UInt128(42))
    println(io, "seed42 key: ", hex(k))
    a, b, c=block(k, 0, 0), block(k, 1, 0), block(k, 0, 1)
    println(
        io,
        "seed42: f64[0]=",
        f64(a, 0),
        " u32[0]=",
        hex(a[1:1]),
        " bool[0]=",
        isodd(a[1]),
        " f64[2]=",
        f64(b, 0),
        " f64[16]=",
        f64(c, 0),
        " u32[4]=",
        hex(b[1:1]),
    )
end
end
