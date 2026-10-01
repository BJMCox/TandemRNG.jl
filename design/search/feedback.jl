# Isolated candidate for D24. This changes F and T together within a private module.
# Loading this file never changes the package's production methods or stream.
module TandemFeedback

include("../../src/TandemRNG.jl")

@eval TandemRNG begin
    @inline function step(o::NTuple{4,W}, h::NTuple{4,W}) where {W<:Word}
        o, h = mix(o, h), clock(h)
        return o, (h[1] ⊻ o[1], h[2], h[3], h[4])
    end
end

end
