# Parametric Tandem step for the D8 screen. Not the package API: every wiring and clock
# variant lives here so one harness compares them.
module TandemSearch

using Random

const M_FIX = 0x80000001 % UInt32
const O4 = NTuple{4,UInt32}

# Round constants for F: distinct, nonzero, top bit set. Digits of 1/pi in hex, top bit forced.
const RC =
    (
        0x517cc1b7,
        0x27220a94,
        0xfe13abe8,
        0xfa9a6ee0,
        0x6db14acc,
        0x9e21c820,
        0xff28b1d5,
        0xef5de2b0,
        0xdb92371d,
        0x2126e970,
        0x03249775,
        0x04e8c90e,
    ) .| M_FIX

struct Config
    clock::Symbol    # :weyl, :ring, :xoshiro
    wiring::Symbol   # :w1 (no fold), :w2 (fold, one layer), :w3 (fold, two layers)
    fix::UInt32      # or-mask on every multiplier: 0x1 (odd) or 0x80000001 (odd, top bit)
    lorot::Int       # rotation of lo before the key xor: 0 leaves bit 0 of lo linear (F11)
    rot::NTuple{4,Int}
    weyl::NTuple{4,UInt32}
end

Config(clock, wiring; fix = 0x00000001, lorot = 16) = Config(
    clock,
    wiring,
    UInt32(fix),
    lorot,
    (7, 13, 22, 3),
    (0x9e3779b9, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a) .| 0x00000001,
)

@inline function mulwide(x::UInt32, m::UInt32)
    p = UInt64(x) * UInt64(m)
    return (p >> 32) % UInt32, p % UInt32
end

@inline function clock(h::O4, cfg::Config)
    h0, h1, h2, h3 = h
    if cfg.clock === :weyl
        w = cfg.weyl
        return (h0 + w[1], h1 + w[2], h2 + w[3], h3 + w[4])
    elseif cfg.clock === :ring
        r = cfg.rot
        h0 ⊻= bitrotate(h1, r[1])
        h1 ⊻= bitrotate(h2, r[2])
        h2 ⊻= bitrotate(h3, r[3])
        h3 ⊻= bitrotate(h0, r[4])
        return (h0 + cfg.weyl[1], h1, h2, h3)
    elseif cfg.clock === :xoshiro
        t = h1 << 9
        h2 ⊻= h0
        h3 ⊻= h1
        h1 ⊻= h2
        h0 ⊻= h3
        h2 ⊻= t
        h3 = bitrotate(h3, 11)
        return (h0 + cfg.weyl[1], h1, h2, h3)
    end
    error("unknown clock $(cfg.clock)")
end

# One Feistel layer in the Philox4x32 shape. The multiplied words a and c produce (hi, lo).
# The L words b and d take hi of the other pair and move to the next multiplied slots, the
# lo words move to the L slots. `fold` xors lo into the L update so the hi top-bit bias (F12)
# never meets an exposed word alone. The clock words k0, k1 hide the low bit of lo (F11).
@inline function layer(o::O4, m0, m1, k0, k1, fold::Bool, fix::UInt32, lorot::Int)
    a, b, c, d = o
    hi0, lo0 = mulwide(a, m0 | fix)
    hi1, lo1 = mulwide(c, m1 | fix)
    # Bit 0 of lo equals bit 0 of the multiplied word (F11). Rotating lo before the key xor
    # puts a carry-dependent product bit at bit 0 so the low-bit stream is not GF(2)-linear
    # whatever the clock does. Without it the weyl and xoshiro clocks fail BRank at 2^20.
    r0 = bitrotate(lo0, lorot)
    r1 = bitrotate(lo1, lorot)
    if fold
        return (b ⊻ hi1 ⊻ lo1, r1 ⊻ k0, d ⊻ hi0 ⊻ lo0, r0 ⊻ k1)
    else
        return (b ⊻ hi1, r1 ⊻ k0, d ⊻ hi0, r0 ⊻ k1)
    end
end

@inline function mix(o::O4, h::O4, cfg::Config)
    h0, h1, h2, h3 = h
    if cfg.wiring === :w2
        return layer(o, h0, h1, h2, h3, true, cfg.fix, cfg.lorot)
    elseif cfg.wiring === :w1
        return layer(o, h0, h1, h2, h3, false, cfg.fix, cfg.lorot)
    elseif cfg.wiring === :w3
        o = layer(o, h0, h1, h2, h3, true, cfg.fix, cfg.lorot)
        return layer(o, h2, h3, h0, h1, true, cfg.fix, cfg.lorot)
    end
    error("unknown wiring $(cfg.wiring)")
end

# T: one step. Output is the new exposed half.
@inline step(o::O4, h::O4, cfg::Config) = (mix(o, h, cfg), clock(h, cfg))

# F: seed a chunk. Swap halves after each round so every word gets nonlinear mixing.
@inline function seed(
    key::O4,
    pos::UInt64,
    domain::UInt32,
    aux::UInt32,
    cfg::Config,
    Rf::Int,
)
    o = (pos % UInt32, (pos >> 32) % UInt32, domain, aux)
    h = key
    for r = 1:Rf
        o, h = step(o, h, cfg)
        o = (o[1] ⊻ RC[r], o[2], o[3], o[4])
        o, h = h, o
    end
    return o, h
end

# --- screens ------------------------------------------------------------------------------

@inline getbit(o::O4, i::Int) = (o[(i>>5)+1] >> (i & 31)) & 0x1
@inline function flipbit(o::O4, i::Int)
    w = (i >> 5) + 1
    return ntuple(j -> j == w ? o[j] ⊻ (UInt32(1) << (i & 31)) : o[j], Val(4))
end

@inline function addbits!(counts, row, col0, words::O4)
    for i = 0:127
        counts[row, col0+i] += getbit(words, i)
    end
end

"""
    avalanche_T(cfg, S, N) -> counts[128, S, 128]

Flip each hidden bit, run S steps, count exposed output bit flips. Exposed-bit flips are not
measured: a Feistel passes L bits through xored, so those rows are structurally 0 or 1.
"""
function avalanche_T(cfg::Config, S::Int, N::Int; rng = Xoshiro(1))
    counts = zeros(Int32, 128, S, 128)
    base = Vector{O4}(undef, S)
    for _ = 1:N
        o = ntuple(_ -> rand(rng, UInt32), Val(4))
        h = ntuple(_ -> rand(rng, UInt32), Val(4))
        oo, hh = o, h
        for s = 1:S
            oo, hh = step(oo, hh, cfg)
            base[s] = oo
        end
        for j = 0:127
            oo, hh = o, flipbit(h, j)
            for s = 1:S
                oo, hh = step(oo, hh, cfg)
                for i = 0:127
                    counts[j+1, s, i+1] += getbit(oo .⊻ base[s], i)
                end
            end
        end
    end
    return counts
end

"""
    avalanche_F(cfg, Rf, N) -> counts[256, 256]

Flip each input bit (key 0..127, pos 128..191, domain 192..223, aux 224..255), count flips of
the 256 output bits after Rf rounds.
"""
function avalanche_F(cfg::Config, Rf::Int, N::Int; rng = Xoshiro(2))
    counts = zeros(Int32, 256, 256)
    for _ = 1:N
        key = ntuple(_ -> rand(rng, UInt32), Val(4))
        pos = rand(rng, UInt64)
        dom = rand(rng, UInt32)
        aux = rand(rng, UInt32)
        bo, bh = seed(key, pos, dom, aux, cfg, Rf)
        for j = 0:255
            k, p, d, x = key, pos, dom, aux
            if j < 128
                k = flipbit(key, j)
            elseif j < 192
                p ⊻= UInt64(1) << (j - 128)
            elseif j < 224
                d ⊻= UInt32(1) << (j - 192)
            else
                x ⊻= UInt32(1) << (j - 224)
            end
            fo, fh = seed(k, p, d, x, cfg, Rf)
            addbits!(counts, j + 1, 1, fo .⊻ bo)
            addbits!(counts, j + 1, 129, fh .⊻ bh)
        end
    end
    return counts
end

"""
    bias_T(cfg, S, N) -> (word = counts[S, 128], xor = counts[S-1, 4, 4, 32])

Bit frequencies of the exposed words at each step, and of every cross-word xor between
consecutive steps, over N random states. A frequency far from 0.5 is a defect that no
avalanche count shows.
"""
function bias_T(cfg::Config, S::Int, N::Int; rng = Xoshiro(3))
    word = zeros(Int32, S, 128)
    xor = zeros(Int32, S - 1, 4, 4, 32)
    for _ = 1:N
        o = ntuple(_ -> rand(rng, UInt32), Val(4))
        h = ntuple(_ -> rand(rng, UInt32), Val(4))
        prev = o
        for s = 1:S
            o, h = step(o, h, cfg)
            for i = 0:127
                word[s, i+1] += getbit(o, i)
            end
            if s > 1
                for wi = 1:4, wj = 1:4
                    x = o[wi] ⊻ prev[wj]
                    for bit = 0:31
                        xor[s-1, wi, wj, bit+1] += (x >> bit) & 0x1
                    end
                end
            end
            prev = o
        end
    end
    return (word = word, xor = xor)
end

# Summary of a count array against N trials: fraction outside 3σ, exact zeros, min and max.
function summarize(counts::AbstractArray{Int32}, N::Int)
    p = counts ./ N
    σ = sqrt(0.25 / N)
    outside = count(x -> abs(x - 0.5) > 3σ, p) / length(p)
    return (
        outside = round(outside; digits = 4),
        zeros = count(iszero, counts),
        min = round(minimum(p); digits = 3),
        max = round(maximum(p); digits = 3),
    )
end

function screen_T(cfg::Config; S = 3, N = 4096)
    c = avalanche_T(cfg, S, N)
    return [(step = s, hidden = summarize(view(c, :, s, :), N)) for s = 1:S]
end

function screen_F(cfg::Config; Rfs = 1:8, N = 2048)
    return [(Rf = r, all = summarize(avalanche_F(cfg, r, N), N)) for r in Rfs]
end

function screen_bias(cfg::Config; S = 4, N = 1 << 17)
    b = bias_T(cfg, S, N)
    σ = sqrt(0.25 / N)
    worst_word = maximum(abs.(b.word ./ N .- 0.5))
    worst_xor = maximum(abs.(b.xor ./ N .- 0.5))
    return (
        sigma = round(σ; digits = 4),
        worst_word = round(worst_word; digits = 4),
        worst_xor = round(worst_xor; digits = 4),
    )
end

end # module
