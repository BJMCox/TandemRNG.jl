# Bounded release-adapter checks. Load the matching quick.jl first.
module TandemFeedChecks

using Random
using Test
using TandemRNG
using ..TandemQuick

function reverse_word(x::T) where {T<:Unsigned}
    result = zero(T)
    for _ = 1:(8sizeof(T))
        result = (result << 1) | (x & one(T))
        x >>= 1
    end
    return result
end

function oracle(words, T, reversed)
    if T === UInt32
        return [Float64(reversed ? reverse_word(x) : x) / 2.0^32 for x in words]
    end
    return map(1:2:(length(words)-1)) do i
        x = UInt64(words[i]) | (UInt64(words[i+1]) << 32)
        reversed && (x = reverse_word(x))
        Float64(x >> 11) / 2.0^53
    end
end

function check()
    @testset "release feeds" begin
        for K in (1, 32, 64), T in (UInt32, Float64), reversed in (false, true)
            # Cross one full buffer refill and many row/group boundaries.
            n = TandemQuick.BLOCK + 33
            words = Vector{UInt32}(undef, T === UInt32 ? n : 2n)
            rand!(Stateful(Tandem8x32{K}(42)), words)
            expected = oracle(words, T, reversed)
            feed = TandemQuick.Feed(Stateful(Tandem8x32{K}(42)), T; reverse = reversed)
            @test [feed() for _ = 1:n] == expected
        end
        for T in (UInt32, Float64), reversed in (false, true)
            feed = TandemQuick.Feed(Stateful(Tandem8x32{32}(42)), T; reverse = reversed)
            W = eltype(feed.buf)
            if W <: Unsigned
                feed.buf[1:3] .= (0, 1, typemax(W))
                feed.i = 0
                actual = [feed() for _ = 1:3]
                @test actual[1] == 0
                @test actual[2] == (reversed ? 0.5 : 2.0^-32)
                @test actual[3] == (W === UInt32 ? 1 - 2.0^-32 : 1 - 2.0^-53)
            end
        end
        @test TandemQuick.suspect(NaN)
        @test TandemQuick.suspect(Inf)
        # Test the actual C GetU01 and GetBits routes while GC runs. Each consumes
        # the next value. Ignore battery_results(), since no battery runs here.
        for T in (UInt32, Float64), reversed in (false, true)
            words = Vector{UInt32}(undef, 32)
            rand!(Stateful(Tandem8x32{32}(42)), words)
            expected = oracle(words, T, reversed)
            feed = TandemQuick.Feed(Stateful(Tandem8x32{32}(42)), T; reverse = reversed)
            TandemQuick.battery(feed, "adapter probe") do gen
                GC.gc(true)
                for i = 1:2:15
                    u = ccall(
                        (:unif01_StripD, TandemQuick.LIB),
                        Cdouble,
                        (Ptr{Cvoid}, Cint),
                        gen,
                        0,
                    )
                    w = ccall(
                        (:unif01_StripB, TandemQuick.LIB),
                        Culong,
                        (Ptr{Cvoid}, Cint, Cint),
                        gen,
                        0,
                        32,
                    )
                    @test u == expected[i]
                    @test w == trunc(Culong, expected[i+1] * 2.0^32)
                end
            end
        end
    end
end

end # module
