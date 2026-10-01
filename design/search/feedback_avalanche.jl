# Bounded diffusion screen of the exact feedback recurrence, including all four T quadrants.
module FeedbackAvalanche
using Random, Statistics, SHA
const F = Main.TandemRNG
const State = NTuple{8,UInt32}
@inline advance(x) = ((o, h) = F.step(x[1:4], x[5:8]); (o..., h...))
@inline flip(x, bit) =
    ntuple(i -> i == (bit>>5)+1 ? x[i] ⊻ (UInt32(1)<<(bit&31)) : x[i], Val(8))
@inline function seed(x, ::Val{R}) where {R}
    o, h=x[1:4], x[5:8]
    Base.Cartesian.@nexprs 8 r -> if r <= R
        o, h=F.step(o, h)
        o=(o[1]⊻F.RC[r], o[2], o[3], o[4])
        o, h=h, o
    end
    return (o..., h...)
end

function positive_control()
    rng=Xoshiro(9)
    for _ = 1:64, bit = 0:31
        x=ntuple(_->rand(rng, UInt32), Val(8))
        delta=advance(x) .⊻ advance(flip(x, 32+bit))
        @assert delta == ntuple(i -> i in (1, 5) ? UInt32(1)<<bit : UInt32(0), Val(8))
    end
    return true
end

function counts(f, N)
    rng=Xoshiro(2)
    bases=[ntuple(_->rand(rng, UInt32), Val(8)) for _ = 1:N]
    outputs=f.(bases)
    counts=zeros(Int32, 256, 256)
    Threads.@threads for j = 0:255
        for n = 1:N
            delta=f(flip(bases[n], j)) .⊻ outputs[n]
            for w = 1:8, bit = 0:31
                @inbounds counts[(w-1)*32+bit+1, j+1] += (delta[w]>>bit)&1
            end
        end
    end
    return counts
end

function summarize(c, N)
    p=c ./ N
    return (
        zeros = count(iszero, c),
        ones = count(==(N), c),
        minimum = minimum(p),
        maximum = maximum(p),
        maxbias = maximum(abs.(p .- 0.5)),
        rms = sqrt(mean((p .- 0.5) .^ 2)),
    )
end

function report(io)
    F.step(ntuple(UInt32, 4), ntuple(i->UInt32(i+4), 4))[2][1] == 0x9e377ca9 ||
        error("This screen requires the v2 feedback recurrence")
    positive_control()
    println(
        io,
        "Feedback diffusion screen. Julia ",
        VERSION,
        ". Xoshiro(2) bases, all input/output bits.",
    )
    for path in (@__FILE__, joinpath(@__DIR__, "../../src/core.jl"))
        println(io, basename(path), " SHA256 ", bytes2hex(sha256(read(path))))
    end
    println(io, "Exact exposed-b positive control passed on 64 states × 32 bits.")
    println(io, "F: joint 1% Hoeffding/union bound across four matrices")
    for (r, N) in ((6, 4096), (8, 4096), (7, 4096), (8, 16384))
        threshold=sqrt(log(2*4*256^2/0.01)/(2N))
        c=counts(x->seed(x, Val(r)), N)
        println(
            io,
            "F rounds=",
            r,
            " N=",
            N,
            " ",
            summarize(c, N),
            " threshold=",
            threshold,
            " exceedances=",
            count(x->abs(x/N-0.5)>threshold, c),
        )
        flush(io)
    end
    N=1024
    for steps in (1, 2, 4, 8, 16, 32)
        c=counts(N) do x
            for _ = 1:steps
                x=advance(x)
            end
            x
        end
        for (input, cols) in (("o", 1:128), ("h", 129:256)),
            (output, rows) in (("o", 1:128), ("h", 129:256))

            println(
                io,
                "T steps=",
                steps,
                " ",
                input,
                "→",
                output,
                " ",
                summarize(view(c, rows, cols), N),
            )
        end
        flush(io)
    end
end
end
