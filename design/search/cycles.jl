# Cycle structure of the original v1 hidden clock and full step at reduced word widths,
# by exhaustive enumeration. These historical maps have no feedback, unlike v2. They use a generic
# word width so that whole state spaces fit in memory and time.
#
# Reduced-width rule. Word width w in bits, arithmetic modulo 2^w, rotations modulo w. The
# clock ring rotations (7, 13, 22, 3) scale as r_w = max(1, round(r * w / 32)), round half to
# even. The lo rotation of `mix` is w ÷ 2. The Weyl constant is the top w bits of 0x9e3779b9
# with the lowest bit forced to 1, so the add keeps an odd stride. Products are exact 2w-bit
# products of w-bit values, hi = product >> w, lo = product mod 2^w. At w = 32 the rule gives
# the production constants, and `selfcheck` pins that on the spec test vectors.
# F keeps eight rounds. Its round, domain, and aux constants use their top w bits without
# forcing a bit. The production domains stay distinct for w >= 4. These are scaled analogues,
# not quotients of the production maps, so reduced F reachability does not lift to w = 32.
#
# Cycles are counted by the least-element rule: the walk from state s continues while every
# visited state exceeds s, and s owns its cycle only when the walk returns to s. That needs
# no visited bitmap, so the starts split over all threads. On a random-like permutation of N
# states the total work is about N ln N steps, and the longest single walk is one cycle.
#
# Run in the tandem-quick environment (Printf) on batserv01:
#     include("/mnt/scratch/bcox/TandemRNG.jl/design/search/cycles.jl")
#     open(io -> TandemCycles.report(io), "/mnt/scratch/bcox/tandem-quick/cycles.md", "w")
module TandemCycles

using Printf

export report, selfcheck

# --- the maps over a generic word width ---------------------------------------------------

const CLOCK_ROT = (7, 13, 22, 3)
const CLOCK_WEYL = 0x9e3779b9
const KEY = UInt32.((1, 2, 3, 4))
const RC = (
    0xd17cc1b7,
    0xa7220a94,
    0xfe13abe8,
    0xfa9a6ee0,
    0xedb14acc,
    0x9e21c820,
    0xff28b1d5,
    0xef5de2b0,
)
const DOMAIN_STREAM = 0x9e3779b9
const AUX_STREAM = 0x94d049bb

struct Width
    w::Int
    mask::UInt32
    rot::NTuple{4,Int}
    lorot::Int
    weyl::UInt32
end

# `weyl = false` drops the add and leaves the GF(2)-linear ring for comparison.
function Width(w::Integer; weyl::Bool = true)
    4 <= w <= 32 || throw(ArgumentError("width $w outside 4:32"))
    rot = map(r -> max(1, round(Int, r * w / 32)), CLOCK_ROT)
    all(r -> r < w, rot) || throw(ArgumentError("rotation $rot reaches the width $w"))
    c = weyl ? (CLOCK_WEYL >> (32 - w)) | UInt32(1) : UInt32(0)
    return Width(w, UInt32((1 << w) - 1), rot, w ÷ 2, c)
end

@inline rotl(x::UInt32, r::Int, W::Width) = ((x << r) | (x >> (W.w - r))) & W.mask

@inline function mulwide(x::UInt32, m::UInt32, W::Width)
    p = UInt64(x) * UInt64(m)
    return (p >> W.w) % UInt32, (p % UInt32) & W.mask
end

@inline function clock(h::NTuple{4,UInt32}, W::Width)
    h0, h1, h2, h3 = h
    h0 ⊻= rotl(h1, W.rot[1], W)
    h1 ⊻= rotl(h2, W.rot[2], W)
    h2 ⊻= rotl(h3, W.rot[3], W)
    h3 ⊻= rotl(h0, W.rot[4], W)
    return ((h0 + W.weyl) & W.mask, h1, h2, h3)
end

@inline function mix(o::NTuple{4,UInt32}, h::NTuple{4,UInt32}, W::Width)
    a, b, c, d = o
    h0, h1, h2, h3 = h
    hi0, lo0 = mulwide(a, h0 | UInt32(1), W)
    hi1, lo1 = mulwide(c, h1 | UInt32(1), W)
    return (
        b ⊻ hi1 ⊻ lo1,
        rotl(lo1, W.lorot, W) ⊻ h2,
        d ⊻ hi0 ⊻ lo0,
        rotl(lo0, W.lorot, W) ⊻ h3,
    )
end

@inline step(o::NTuple{4,UInt32}, h::NTuple{4,UInt32}, W::Width) =
    (mix(o, h, W), clock(h, W))

# Equality of words 2, 3, and 4 forces h2 = h3 = 0 and the updated h0 before the add to 0.
# The first word then forces h0 = c, hence rotl(h1, r1) = c. This is the unique fixed point.
clock_fixed_point(W::Width) =
    (W.weyl, rotl(W.weyl, W.w - W.rot[1], W), UInt32(0), UInt32(0))

project_constant(x::UInt32, W::Width) = x >> (32 - W.w)

function seed(o::NTuple{4,UInt32}, h::NTuple{4,UInt32}, W::Width)
    for rc in RC
        o, h = step(o, h, W)
        o = (o[1] ⊻ project_constant(rc, W), o[2], o[3], o[4])
        o, h = h, o
    end
    return o, h
end

function seed(key::NTuple{4,UInt32}, counter::UInt64, W::Width)
    o = (
        (counter % UInt32) & W.mask,
        ((counter >> W.w) % UInt32) & W.mask,
        project_constant(DOMAIN_STREAM, W),
        project_constant(AUX_STREAM, W),
    )
    return seed(o, key, W)
end

function unclock(h::NTuple{4,UInt32}, W::Width)
    h0, h1, h2, h3 = h
    h0 = (h0 - W.weyl) & W.mask
    h3 ⊻= rotl(h0, W.rot[4], W)
    h2 ⊻= rotl(h3, W.rot[3], W)
    h1 ⊻= rotl(h2, W.rot[2], W)
    h0 ⊻= rotl(h1, W.rot[1], W)
    return h0, h1, h2, h3
end

# Newton iteration doubles the correct low bits of the inverse of an odd UInt32.
function odd_inverse(m::UInt32)
    x = m
    for _ = 1:5
        x *= UInt32(2) - m * x
    end
    return x
end

function unmix(o::NTuple{4,UInt32}, h::NTuple{4,UInt32}, W::Width)
    m0, m1 = h[1] | UInt32(1), h[2] | UInt32(1)
    lo1 = rotl(o[2] ⊻ h[3], W.w - W.lorot, W)
    lo0 = rotl(o[4] ⊻ h[4], W.w - W.lorot, W)
    a, c = (lo0 * odd_inverse(m0)) & W.mask, (lo1 * odd_inverse(m1)) & W.mask
    hi0, _ = mulwide(a, m0, W)
    hi1, _ = mulwide(c, m1, W)
    return a, o[1] ⊻ hi1 ⊻ lo1, c, o[3] ⊻ hi0 ⊻ lo0
end

function unseed(o::NTuple{4,UInt32}, h::NTuple{4,UInt32}, W::Width)
    for rc in reverse(RC)
        o, h = h, o
        o = (o[1] ⊻ project_constant(rc, W), o[2], o[3], o[4])
        h = unclock(h, W)
        o = unmix(o, h, W)
    end
    return o, h
end

# Packed states: four w-bit words in the low 4w bits, word 1 lowest. A full state puts the
# exposed half low and the hidden half above it.
@inline pack4(t::NTuple{4,UInt32}, W::Width) =
    UInt64(t[1]) | UInt64(t[2]) << W.w | UInt64(t[3]) << 2W.w | UInt64(t[4]) << 3W.w

@inline function unpack4(x::UInt64, W::Width)
    w, m = W.w, W.mask
    return (
        (x % UInt32) & m,
        ((x >> w) % UInt32) & m,
        ((x >> 2w) % UInt32) & m,
        ((x >> 3w) % UInt32) & m,
    )
end

@inline pack8(o, h, W::Width) = pack4(o, W) | pack4(h, W) << 4W.w
@inline unpack8(x::UInt64, W::Width) = (unpack4(x, W), unpack4(x >> 4W.w, W))

clock_packed(W::Width) = x -> pack4(clock(unpack4(x, W), W), W)

function step_packed(W::Width)
    return function (x)
        o, h = step(unpack8(x, W)..., W)
        return pack8(o, h, W)
    end
end

function selfcheck()
    W = Width(32)
    W.rot == CLOCK_ROT && W.lorot == 16 && W.weyl == CLOCK_WEYL ||
        error("w = 32 constants differ from core.jl: $W")
    h = UInt32.((5, 6, 7, 8))
    o = UInt32.((1, 2, 3, 4))
    clock(h, W) == (0x9e377cbe, 0x0000e006, 0x02000007, 0x00001820) ||
        error("clock(5, 6, 7, 8) differs from the spec vector")
    step(o, h, W)[1] == (0x00000017, 0x00150007, 0x00000001, 0x00050008) ||
        error("step((1, 2, 3, 4), (5, 6, 7, 8)) differs from the spec vector")
    initial = ((UInt32(0), UInt32(0), DOMAIN_STREAM, AUX_STREAM), KEY)
    seeded = (
        (0xe6c1f63d, 0xb512b070, 0x30ce0101, 0x912986d6),
        (0x754a4a56, 0xf1fb8115, 0xe4bd6da3, 0x512576eb),
    )
    seed(KEY, UInt64(0), W) == seeded || error("F differs from the spec vector")
    unseed(seeded..., W) == initial || error("inverse F differs from the spec input")
    zero = ntuple(_ -> UInt32(0), 4)
    for w in (4, 5, 32)
        WW = Width(w)
        fixed = clock_fixed_point(WW)
        step(zero, fixed, WW) == (zero, fixed) ||
            error("analytic fixed point failed at w = $w")
        source = (UInt32.((1, 2, 3, 4)), UInt32.((5, 6, 7, 8)))
        unseed(seed(source..., WW)..., WW) == source || error("inverse F failed at w = $w")
    end
    # Independent tiny permutations exercise least-element ownership, fixed points, and ties.
    permutation = UInt64[3, 6, 4, 5, 7, 0, 1, 2]
    cycles(x -> permutation[x+1], 3).hist == Dict(3 => 2, 2 => 1) ||
        error("cycle census failed")
    cycles(identity, 3).hist == Dict(1 => 8) || error("fixed-point census failed")
    return true
end

# --- cycle enumeration ----------------------------------------------------------------------

struct Cycles
    n::Int                          # log2 of the state count
    hist::Dict{Int,Int}             # cycle length => number of cycles
    reps::Vector{Tuple{UInt64,Int}} # (least state, length), retained when requested
end

# The walk from start s takes about N / (s + 1) steps on a random-like permutation, so the
# start ranges double in length and each carries about N ln 2 steps, cut into pieces for the
# dynamic scheduler.
function chunks(N::UInt64)
    out = [UInt64(0):UInt64(0)]
    lo = UInt64(1)
    while lo < N
        hi = min(2lo, N)
        len = cld(hi - lo, min(hi - lo, UInt64(64)))
        for a = lo:len:(hi-1)
            push!(out, a:min(a+len-1, hi-1))
        end
        lo = hi
    end
    return out
end

function cycles(f::F, n::Int; keep_reps::Bool = n <= 24) where {F}
    N = UInt64(1) << n
    ranges = chunks(N)
    hists = Vector{Dict{Int,Int}}(undef, length(ranges))
    reps = Vector{Vector{Tuple{UInt64,Int}}}(undef, length(ranges))
    Threads.@threads :dynamic for c in eachindex(ranges)
        hist = Dict{Int,Int}()
        rep = Tuple{UInt64,Int}[]
        for s in ranges[c]
            x = f(s)
            L = 1
            while x > s
                x = f(x)
                L += 1
            end
            x == s || continue
            hist[L] = get(hist, L, 0) + 1
            keep_reps && push!(rep, (s, L))
        end
        hists[c] = hist
        reps[c] = rep
    end
    total = Dict{Int,Int}()
    for h in hists, (L, k) in h
        total[L] = get(total, L, 0) + k
    end
    c = Cycles(n, total, reduce(vcat, reps))
    check_state_count(c)
    return c
end

function check_state_count(c::Cycles)
    states = sum(big(L) * k for (L, k) in c.hist; init = big(0))
    states == big(1) << c.n ||
        error("cycle histogram covers $states states, expected 2^$(c.n)")
    return states
end

# Length of the cycle through s, or 0 when it does not close within `cap` steps.
function cycle_length(f::F, s::UInt64, cap::Int) where {F}
    x = f(s)
    L = 1
    while x != s && L < cap
        x = f(x)
        L += 1
    end
    return x == s ? L : 0
end

function threaded_map(f::F, xs::AbstractVector) where {F}
    out = Vector{Int}(undef, length(xs))
    Threads.@threads :dynamic for i in eachindex(xs)
        out[i] = f(xs[i])
    end
    return out
end

ncycles(c::Cycles) = sum(values(c.hist))
longest(c::Cycles) = maximum(keys(c.hist))
fixed_points(c::Cycles) = get(c.hist, 1, 0)
short_cycles(c::Cycles) = sum(k for (L, k) in c.hist if L <= 16; init = 0)

function longest_five(c::Cycles)
    out = Int[]
    for L in sort!(collect(keys(c.hist)); rev = true), _ = 1:c.hist[L]
        push!(out, L)
        length(out) == 5 && return out
    end
    return out
end

# Uniform random permutation of N elements: E[cycles] = H_N, E[longest] = λN with the
# Golomb-Dickman constant, E[cycles of length <= k] = H_k.
const EULER_GAMMA = 0.5772156649015329
const GOLOMB_DICKMAN = 0.6243299885435508
expected_cycles(N) = log(N) + EULER_GAMMA + 1 / (2N)
harmonic(k::Int) = sum(1 / i for i = 1:k)

# SplitMix64, so random starts need no Random stdlib and stay reproducible.
@inline function splitmix(x::UInt64)
    x += 0x9e3779b97f4a7c15
    z = (x ⊻ (x >> 30)) * 0xbf58476d1ce4e5b9
    z = (z ⊻ (z >> 27)) * 0x94d049bb133111eb
    return x, z ⊻ (z >> 31)
end

function random_states(k::Int, n::Int, seed::UInt64)
    out = Vector{UInt64}(undef, k)
    for i = 1:k
        seed, r = splitmix(seed)
        out[i] = r & ((UInt64(1) << n) - 1)
    end
    return out
end

# --- the exposed half along one hidden cycle -----------------------------------------------

# g_h: the exposed half after one trip around the hidden cycle of length L through s. Blocks
# of independent exposed states share one pass over the cycle, which keeps the multiply
# pipeline full and the cycle in cache.
const BLOCK = 16

function exposed_map(W::Width, s::UInt64, L::Int)
    hs = Vector{NTuple{4,UInt32}}(undef, L)
    h = unpack4(s, W)
    for i = 1:L
        hs[i] = h
        h = clock(h, W)
    end
    n = 4W.w
    tab = Vector{UInt32}(undef, 1 << n)
    Threads.@threads :dynamic for blk = 0:((1<<n)÷BLOCK-1)
        base = blk * BLOCK
        os = ntuple(j -> unpack4(UInt64(base + j - 1), W), Val(BLOCK))
        for hh in hs
            os = map(o -> mix(o, hh, W), os)
        end
        for j = 1:BLOCK
            tab[base+j] = pack4(os[j], W) % UInt32
        end
    end
    return tab
end

# --- the full step on random starts --------------------------------------------------------

function sample_step(W::Width, samples::Int, cap::Int)
    starts = random_states(samples, 8W.w, UInt64(0x7461_6e64_656d))
    periods = Vector{Int}(undef, samples)
    Threads.@threads :dynamic for i in eachindex(starts)
        o0, h0 = unpack8(starts[i], W)
        o, h = step(o0, h0, W)
        k = 1
        while !(h == h0 && o == o0) && k < cap
            o, h = step(o, h, W)
            k += 1
        end
        periods[i] = h == h0 && o == o0 ? k : 0
    end
    return starts, periods
end

# --- report -----------------------------------------------------------------------------------

fmt(x::Real, d::Int = 3) = string(round(Float64(x); digits = d))
hex(x::UInt64, n::Int) = "0x" * string(x; base = 16, pad = cld(n, 4))
seconds(t0::UInt64) = fmt((time_ns() - t0) / 1e9, 1)

function progress(message)
    println(stderr, message)
    flush(stderr)
end

function table_header(io::IO, header)
    println(io, "| ", join(header, " | "), " |")
    println(io, "|", repeat(" --- |", length(header)))
    flush(io)
end

function table_row(io::IO, row)
    println(io, "| ", join(string.(row), " | "), " |")
    flush(io)
end

function table(io::IO, header, rows)
    table_header(io, header)
    for r in rows
        table_row(io, r)
    end
    println(io)
    flush(io)
end

function histogram_section(io::IO, c::Cycles, label::AbstractString)
    N = check_state_count(c)
    println(io, "### $label: complete cycle histogram\n")
    rows = [(L, c.hist[L], big(L) * c.hist[L]) for L in sort!(collect(keys(c.hist)))]
    table(io, ["cycle length", "cycles", "states"], rows)
    println(io, "State count checked: sum(length × cycles) = $N = 2^$(c.n).\n")
    flush(io)
end

function constants_section(io::IO, widths)
    println(io, "## Scaled constants\n")
    rows = map(widths) do w
        W = Width(w)
        (w, W.rot, W.lorot, "0x" * string(W.weyl; base = 16), "2^$(4w)", "2^$(8w)")
    end
    table(
        io,
        ["w", "ring rotations", "lo rotation", "Weyl", "hidden states", "full states"],
        rows,
    )
end

function clock_section(io::IO, widths; weyl::Bool)
    println(
        io,
        weyl ? "## Hidden clock with the Weyl add\n" :
        "## Hidden clock, GF(2)-linear part only\n",
    )
    table_header(
        io,
        [
            "w",
            "N",
            "cycles",
            "E[cycles]",
            "longest",
            "longest / N",
            "fixed points",
            "cycles ≤ 16",
            "from h = 0",
            "from h = (1,2,3,4)",
            "s",
        ],
    )
    fives = []
    out = Dict{Int,Cycles}()
    for w in widths
        progress("Hidden clock: w = $w, Weyl = $weyl")
        W = Width(w; weyl)
        f = clock_packed(W)
        n = 4w
        N = UInt64(1) << n
        t0 = time_ns()
        c = cycles(f, n)
        from = threaded_map(s -> cycle_length(f, s, Int(N)), [UInt64(0), pack4(KEY, W)])
        out[w] = c
        table_row(
            io,
            (
                w,
                N,
                ncycles(c),
                fmt(expected_cycles(N), 1),
                longest(c),
                fmt(longest(c) / N),
                fixed_points(c),
                short_cycles(c),
                from[1],
                from[2],
                seconds(t0),
            ),
        )
        push!(fives, (w, join(longest_five(c), ", ")))
        progress("Hidden clock: w = $w complete, $(ncycles(c)) cycles, $(seconds(t0)) s")
    end
    println(io)
    println(
        io,
        "Random permutation: E[longest / N] = ",
        fmt(GOLOMB_DICKMAN),
        ", E[fixed points] = 1, E[cycles ≤ 16] = ",
        fmt(harmonic(16)),
        ".\n",
    )
    table(io, ["w", "five longest cycles"], fives)
    for w in widths
        histogram_section(io, out[w], "Hidden clock, w = $w, Weyl = $weyl")
    end
    return out
end

function step_section(io::IO)
    W = Width(4)
    f = step_packed(W)
    n = 32
    N = UInt64(1) << n
    println(io, "## Full step, w = 4, exhaustive\n")
    progress("Full step: w = 4, exhaustive")
    t0 = time_ns()
    c = cycles(f, n)
    vec = pack8(UInt32.((1, 2, 3, 4)), UInt32.((5, 6, 7, 8)), W)
    from = threaded_map(s -> cycle_length(f, s, Int(N)), [UInt64(0), vec])
    table(
        io,
        [
            "N",
            "cycles",
            "E[cycles]",
            "longest",
            "longest / N",
            "fixed points",
            "cycles ≤ 16",
            "from state 0",
            "from o = (1,2,3,4), h = (5,6,7,8)",
            "s",
        ],
        [(
            N,
            ncycles(c),
            fmt(expected_cycles(N), 1),
            longest(c),
            fmt(longest(c) / N),
            fixed_points(c),
            short_cycles(c),
            from[1],
            from[2],
            seconds(t0),
        )],
    )
    println(io, "Five longest cycles: ", join(longest_five(c), ", "), ".\n")
    histogram_section(io, c, "Full step, w = 4")
    return c
end

function sample_section(io::IO, samples::Int, cap::Int)
    W = Width(5)
    N = 2.0^40
    println(io, "## Full step, w = 5, sample of $samples random states (not exhaustive)\n")
    progress("Full-step sample: w = 5, at most $(big(samples) * cap) steps")
    t0 = time_ns()
    starts, periods = sample_step(W, samples, cap)
    closed = [i for i in eachindex(periods) if periods[i] > 0]
    @printf(
        io,
        "%d of %d starts returned within the cap of %d steps, %d did not. For a random permutation of 2^40 states a start closes within the cap with chance min(cap / N, 1) = %.4f, so %.1f closures are expected. Wall time %s s.\n\n",
        length(closed),
        samples,
        cap,
        samples - length(closed),
        min(cap / N, 1),
        samples * min(cap / N, 1),
        seconds(t0),
    )
    flush(io)
    isempty(closed) && return
    g = clock_packed(W)
    rows = map(closed) do i
        h = starts[i] >> 4W.w
        L = cycle_length(g, h, 1 << 20)
        (hex(starts[i], 40), periods[i], L, periods[i] ÷ L)
    end
    table(io, ["start", "period", "hidden cycle L", "period / L"], rows)
end

function exposed_section(io::IO, w::Int, c::Cycles)
    W = Width(w)
    n = 4w
    Nx = 1 << n
    reps = sort(c.reps; by = last, rev = true)
    println(io, "## Exposed half per hidden cycle, w = $w\n")
    println(
        io,
        "g_h is the exposed map after one trip around a hidden cycle of length L, so the full period from (o, h) is m × L with m the cycle length of o under g_h. The exposed cycle structure is exhaustive over the 2^$n exposed states; the m columns take 20 random exposed starts. E[cycles] = ",
        fmt(expected_cycles(Nx), 1),
        " and E[longest m / 2^$n] = 0.624 for a random permutation.\n",
    )
    length(reps) > 64 &&
        println(io, "Only the 64 longest of ", length(reps), " hidden cycles are shown.\n")
    table_header(
        io,
        [
            "hidden L",
            "exposed cycles",
            "longest m",
            "longest m / 2^$n",
            "m = 1 states",
            "sample min m",
            "sample median m",
            "sample max m",
            "sample min period",
            "sample max period",
            "s",
        ],
    )
    full_hist = Dict{Int,Int}()
    for (s, L) in first(reps, 64)
        progress("Exposed map: w = $w, hidden cycle $s, length $L")
        t0 = time_ns()
        tab = exposed_map(W, s, L)
        g = x -> UInt64(tab[x+1])
        cg = cycles(g, n)
        ms = sort!([cycle_length(g, o, Nx) for o in random_states(20, n, s)])
        table_row(
            io,
            (
                L,
                ncycles(cg),
                longest(cg),
                fmt(longest(cg) / Nx),
                fixed_points(cg),
                ms[1],
                (ms[10] + ms[11]) / 2,
                ms[end],
                ms[1] * L,
                ms[end] * L,
                seconds(t0),
            ),
        )
        for (m, k) in cg.hist
            full_hist[L*m] = get(full_hist, L*m, 0) + k
        end
        progress("Exposed map: w = $w, hidden cycle $s complete, $(seconds(t0)) s")
    end
    println(io)
    # A length-m return-map cycle is one full cycle of length mL across all L hidden phases.
    if length(reps) <= 64
        full = Cycles(8w, full_hist, Tuple{UInt64,Int}[])
        histogram_section(
            io,
            full,
            "Full step reconstructed from every hidden cycle, w = $w",
        )
    end
end

function structured_section(io::IO, c::Cycles)
    W = Width(8)
    f = clock_packed(W)
    N = 1 << 32
    ones = [UInt64(1) << i for i = 0:31]
    twos = [UInt64(1) << i | UInt64(1) << j for i = 0:31 for j = (i+1):31]
    classes = [
        ("weight 0", [UInt64(0)]),
        ("weight 1", ones),
        ("weight 2", twos),
        ("all ones", [UInt64(0xffffffff)]),
        ("h = (1,2,3,4)", [pack4(KEY, W)]),
    ]
    states = reduce(vcat, last.(classes))
    println(io, "## Structured hidden states, w = 8, clock with the Weyl add\n")
    progress("Structured hidden states: w = 8, $(length(states)) starts")
    t0 = time_ns()
    lens = threaded_map(s -> cycle_length(f, s, N), states)
    Lmax = longest(c)
    at = Dict(zip(states, lens))
    rows = map(classes) do (name, ss)
        ls = [at[s] for s in ss]
        short = [hex(s, 32) * " (" * string(at[s]) * ")" for s in ss if at[s] <= 16]
        (
            name,
            length(ss),
            count(==(Lmax), ls),
            minimum(ls),
            isempty(short) ? "none" : join(short, ", "),
        )
    end
    table(
        io,
        [
            "class",
            "states",
            "on the longest cycle",
            "shortest cycle",
            "states on cycles ≤ 16 (length)",
        ],
        rows,
    )
    @printf(
        io,
        "The longest cycle has length %d and occurs %d time(s) in the histogram. Wall time %s s.\n\n",
        Lmax,
        c.hist[Lmax],
        seconds(t0)
    )
    # A uniformly random state lands on a cycle of length L with chance L k_L / N, k_L cycles of
    # that length, so this column shows whether low-weight states favour particular cycles.
    hist = Dict{Int,Int}()
    for L in lens
        hist[L] = get(hist, L, 0) + 1
    end
    rows = map(sort!(collect(keys(hist)); rev = true)) do L
        (L, get(c.hist, L, 0), hist[L], fmt(length(states) * L * get(c.hist, L, 0) / N, 1))
    end
    table(
        io,
        [
            "cycle length",
            "cycles of this length",
            "structured states on them",
            "expected for random states",
        ],
        rows,
    )
end

function seeded_fixed_section(io::IO)
    W = Width(4)
    h = clock_fixed_point(W)
    N = 1 << 4W.w
    domain, aux = project_constant(DOMAIN_STREAM, W), project_constant(AUX_STREAM, W)
    hits = 0
    fixed = 0
    seeded_fixed = 0
    witnesses = Tuple{NTuple{4,UInt32},UInt64,NTuple{4,UInt32}}[]
    progress("Seeded fixed-hidden slice: w = 4, $N inverse F evaluations")
    for s = UInt64(0):UInt64(N-1)
        o = unpack4(s, W)
        initial, key = unseed(o, h, W)
        isfixed = mix(o, h, W) == o
        fixed += isfixed
        initial[3] == domain && initial[4] == aux || continue
        hits += 1
        seeded_fixed += isfixed
        if length(witnesses) < 3
            counter = UInt64(initial[1]) | UInt64(initial[2]) << W.w
            seed(key, counter, W) == (o, h) || error("seeded witness failed forward replay")
            push!(witnesses, (key, counter, o))
        end
    end
    println(io, "## Seeded fixed-hidden slice, w = 4\n")
    println(
        io,
        "F projects every round, domain, and aux constant to its top four bits, without forcing a bit. The stream domain and aux both become 9 in separate fields. The five domains stay distinct (9, 11, 13, 12, 10). These scaled maps are not quotients of production F, so this result does not establish production reachability.\n",
    )
    println(
        io,
        "The unique hidden fixed point is $(Tuple(Int.(h))). All $N exposed states on this invariant slice were inverted through F. Exactly $hits preimages have the stream domain and aux, among 2^24 possible raw-key and two-word-counter inputs.\n",
    )
    println(
        io,
        "The slice contains $fixed full-step fixed points, of which $seeded_fixed have a stream preimage. A fixed hidden half need not imply a short full-step period.\n",
    )
    g = x -> pack4(mix(unpack4(x, W), h, W), W)
    rows = map(witnesses) do (key, counter, o)
        period = cycle_length(g, pack4(o, W), N)
        (Tuple(Int.(key)), counter, Tuple(Int.(o)), Tuple(Int.(h)), period)
    end
    table(
        io,
        [
            "raw key",
            "counter",
            "seeded exposed half",
            "seeded hidden half",
            "full-step period",
        ],
        rows,
    )
    return hits
end

# Select sections and append each completed invocation to resume a report. The capped sample
# is opt-in: its original 200 × 2^34 budget permits 3.4 trillion full steps. Exposed maps at
# w = 4 and 5 cost 2^32 and 2^40 mixes across all hidden cycles; w = 6 would cost 2^48.
function report(
    io::IO;
    sections = (:clock, :linear, :seeded, :structured, :step, :exposed),
    widths = 4:8,
    exposed_widths = (4, 5),
    samples::Int = 200,
    cap::Int = 1 << 34,
)
    allowed = (:clock, :linear, :seeded, :structured, :step, :exposed, :sample)
    all(s -> s in allowed, sections) || throw(ArgumentError("unknown report section"))
    selfcheck()
    println(io, "# Tandem cycle structure at reduced widths\n")
    println(
        io,
        "Julia ",
        VERSION,
        ", ",
        Threads.nthreads(),
        " threads, ",
        Sys.CPU_NAME,
        ". `selfcheck` at w = 32 passed.\n",
    )
    constants_section(io, widths)
    clocks =
        :clock in sections ? clock_section(io, widths; weyl = true) : Dict{Int,Cycles}()
    :linear in sections && clock_section(io, widths; weyl = false)
    :seeded in sections && seeded_fixed_section(io)
    if :structured in sections
        c = get!(clocks, 8) do
            progress("Hidden clock prerequisite: w = 8")
            cycles(clock_packed(Width(8)), 32)
        end
        structured_section(io, c)
    end
    :step in sections && step_section(io)
    if :exposed in sections
        for w in exposed_widths
            c = get!(clocks, w) do
                progress("Hidden clock prerequisite: w = $w")
                cycles(clock_packed(Width(w)), 4w)
            end
            exposed_section(io, w, c)
        end
    end
    :sample in sections && sample_section(io, samples, cap)
    return nothing
end

end # module
