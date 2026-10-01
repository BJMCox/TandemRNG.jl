# Reproduce the v2 one-pair NS3 score at the first 1 MiB checkpoint.
# Run with: julia --project=CHECKOUT CHECKOUT/design/search/ns3_pair.jl
# The binomial tail below describes an independent pair, not the whole adaptive test.
using SHA
using TandemRNG

function ns3_pair()
    seed = UInt64(14109313052779560181)
    words = Vector{UInt32}(undef, 1 << 18)
    rand_fill!(Tandem8x32{32}(seed), words; nthreads = 1)
    bytes = UInt8.(words .& 0xff)

    # NearSeq3 size 4 uses 1024-bit cores with this initial weight threshold.
    threshold = trunc(Int, 512 - sqrt(160) * 4)
    positions = [
        i for i = 513:128:(length(bytes)-512) if
        sum(count_ones, view(bytes, i:(i+127))) <= threshold
    ]
    length(positions) == 2 || error("expected exactly two selected v2 cores")
    a, b = positions
    pre = sum(count_ones(bytes[a-k] ⊻ bytes[b-k]) for k = 1:128)
    post = sum(count_ones(bytes[a+127+k] ⊻ bytes[b+127+k]) for k = 1:128)
    distance = pre + post

    # Exact binomial probabilities and moments of the folded log-tail score.
    moments = setprecision(256) do
        n = 2048
        pdf = Vector{BigFloat}(undef, n + 1)
        pdf[1] = BigFloat(2)^(-n)
        for k = 1:n
            pdf[k+1] = pdf[k] * (n-k+1) / k
        end
        cdf = cumsum(pdf)
        scores = [-log(cdf[min(k, n-k)+1]) for k = 0:n]
        mean = sum(pdf .* scores)
        variance = sum(pdf .* (scores .- mean) .^ 2)
        return (
            R = Float64((scores[distance+1] - mean) / sqrt(variance)),
            independent_pair_tail = Float64(2cdf[min(distance, n-distance)+1]),
        )
    end
    return (;
        seed,
        sha256 = bytes2hex(sha256(reinterpret(UInt8, words))),
        threshold,
        positions,
        weights = [sum(count_ones, view(bytes, i:(i+127))) for i in positions],
        pair_count = 1,
        pre,
        post,
        distance,
        moments...,
    )
end

println(ns3_pair())
