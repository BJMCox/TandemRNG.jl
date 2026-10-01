# Exact fixed-point census for the production step and a feedback alternative.
# Fixed hidden equations reduce the entire search to one w-bit exposed word.
# This analysis does not alter the production generator.
module TandemFixedPoints

include("cycles.jl")
using .TandemCycles: Width, rotl, mulwide, mix, clock, unmix, unclock, project_constant
using .TandemCycles: RC, DOMAIN_STREAM, AUX_STREAM

const State = NTuple{2,NTuple{4,UInt32}}

@inline function step(o, h, W, ::Val{feedback}) where {feedback}
    o, h = mix(o, h, W), clock(h, W)
    feedback && (h = (h[1] ⊻ o[1], h[2], h[3], h[4]))
    return o, h
end

function seed(o, h, W, mode)
    for rc in RC
        o, h = step(o, h, W, mode)
        o = (o[1] ⊻ project_constant(rc, W), o[2], o[3], o[4])
        o, h = h, o
    end
    return o, h
end

function unseed(o, h, W, ::Val{feedback}) where {feedback}
    for rc in reverse(RC)
        o, h = h, o
        o = (o[1] ⊻ project_constant(rc, W), o[2], o[3], o[4])
        feedback && (h = (h[1] ⊻ o[1], h[2], h[3], h[4]))
        h = unclock(h, W)
        o = unmix(o, h, W)
    end
    return o, h
end

@inline function folded_product(x, m, W)
    hi, lo = mulwide(x, m, W)
    r = rotl(lo, W.lorot, W)
    return r ⊻ hi ⊻ lo, r
end

# h2=h3=0 and h0 xor rotl(h1,r1)=0 follow from the last three hidden equations.
# The first equation gives u=C (original) or u=C xor a (feedback).
# Exposed equations then force c=Q_(u|1)(a), a=Q_(v|1)(c), and determine b,d.
@inline function fixed_state(a::UInt32, W, ::Val{feedback}) where {feedback}
    u = feedback ? W.weyl ⊻ a : W.weyl
    v = rotl(u, W.w - W.rot[1], W)
    c, d = folded_product(a, u | UInt32(1), W)
    check, b = folded_product(c, v | UInt32(1), W)
    return a == check ? ((a, b, c, d), (u, v, UInt32(0), UInt32(0))) : nothing
end

function census(W::Width, mode)
    n = UInt64(1) << W.w
    count = min(n, UInt64(4096))
    span = n ÷ count
    hits = [State[] for _ = 1:count]
    Threads.@threads for j in eachindex(hits)
        first = UInt64(j - 1) * span
        for a = first:(first+span-1)
            state = fixed_state(UInt32(a), W, mode)
            state === nothing || push!(hits[j], state)
        end
    end
    return sort!(reduce(vcat, hits); by = s -> s[1][1])
end

# Exhaustive independent oracle on all 2^16 full states of a two-bit algebraic model.
# This is a proof check, not the scaled-width model used for statistical conclusions.
function selfcheck()
    W = Width(2, UInt32(3), (1, 1, 1, 1), 1, UInt32(3))
    for mode in (Val(false), Val(true))
        brute = State[]
        for x = UInt64(0):UInt64(65535)
            state = TandemCycles.unpack8(x, W)
            step(state..., W, mode) == state && push!(brute, state)
        end
        Set(census(W, mode)) == Set(brute) ||
            error("fixed-point reduction differs from brute force")
    end
    return true
end

hexwords(t) = "(" * join(("0x" * string(x; base = 16, pad = 8) for x in t), ", ") * ")"

function report(io; widths = (4, 32))
    selfcheck()
    println(
        io,
        "# Exact fixed-point census\n\nJulia $VERSION, $(Sys.CPU_NAME), $(Threads.nthreads()) threads.",
    )
    for w in widths, feedback in (false, true)
        W, mode = Width(w), Val(feedback)
        elapsed = @elapsed states = census(W, mode)
        println(
            io,
            "\n## w=$w, feedback=$feedback\n\n$(length(states)) fixed states, $(elapsed) seconds.",
        )
        for state in states
            step(state..., W, mode) == state || error("reported state is not fixed")
            input = unseed(state..., W, mode)
            seed(input..., W, mode) == state || error("inverse F failed")
            o, h = input
            stream =
                o[3] == project_constant(DOMAIN_STREAM, W) &&
                o[4] == project_constant(AUX_STREAM, W)
            counter = UInt64(o[1]) | (UInt64(o[2]) << w)
            # For K=32, 2^64 bit positions address 2^49 groups of eight chunks.
            addressable = counter < UInt64(1) << 52
            println(io, "\n- o = ", hexwords(state[1]), ", h = ", hexwords(state[2]))
            println(io, "- inverse F: o = ", hexwords(o), ", key = ", hexwords(h))
            println(
                io,
                "- stream domain/aux = $stream, counter = $counter, canonical K=32 counter = $addressable, reachable = $(stream && addressable)",
            )
        end
        flush(io)
    end
    return nothing
end

# Coupling removes the hidden/exposed decomposition. Enumerate the complete four-bit map.
function feedback_cycles(io)
    W, mode = Width(4), Val(true)
    f = x -> TandemCycles.pack8(step(TandemCycles.unpack8(x, W)..., W, mode)..., W)
    elapsed = @elapsed c = TandemCycles.cycles(f, 32; keep_reps = true)
    println(io, "# Four-bit feedback cycles\n\nElapsed: $elapsed seconds.\n")
    TandemCycles.histogram_section(io, c, "Feedback T, 2^32 full states")
    println(io, "## Legal stream seeds on cycles of length at most K=32\n")
    for (s, L) in sort(c.reps)
        L <= 32 || continue
        hits = 0
        x = s
        for _ = 1:L
            o, _ = unseed(TandemCycles.unpack8(x, W)..., W, mode)
            hits +=
                o[3] == project_constant(DOMAIN_STREAM, W) &&
                o[4] == project_constant(AUX_STREAM, W)
            x = f(x)
        end
        println(io, "- representative $s, period $L: $hits legal stream seeds")
    end
    flush(io)
    return c
end

end
