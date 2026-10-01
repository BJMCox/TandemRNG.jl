# Feed checks use the separate UInt64/mask step, not the tuple implementation.
include(joinpath(@__DIR__, "margin_direct.jl"))

module TandemDirectMarginCheck

using Test
import TandemRNG as TR
using ..TandemDirectMargin: PROBES, probe, block, swap32
using ..TandemHarness: fill_words!, transform
using ..TandemReferenceV2: step, RC, MASK
import ..TandemReferenceV2
import ..TandemMargin

function oracle(key, index, rounds, kind)
    name = string(kind)
    counter = endswith(name, "_high") ? (index >> 32) + (index << 32) : index
    chunk = startswith(name, "chunkstart")
    domain, aux = chunk ? (0x9e3779b9, 0x94d049bb) : (0xbb67ae85, 0x00000000)
    function evaluate(k)
        state = UInt64[counter & MASK, counter >> 32, domain, aux, k...]
        for r = 1:rounds
            state = step(state)
            state[1] ⊻= RC[r]
            state = vcat(state[5:8], state[1:4])
        end
        chunk && (state = step(state))
        return startswith(name, "split_h_") ? state[5:8] : state[1:4]
    end
    result = evaluate(key)
    if endswith(name, "_xor")
        paired = collect(UInt64, key)
        word, bit = occursin("keybit127", name) ? (4, 31) : (1, 0)
        paired[word] ⊻= UInt64(1) << bit
        result .⊻= evaluate(paired)
    end
    return UInt32.(result)
end

function check(; seeds = UInt64[42, 0x25ddc9d20ab7cb4b, 0x9f2c4624a9689212])
    result = @testset "Reduced-round margin feeds" begin
        @test TandemMargin.verify() == 184
        for seed in seeds
            parent = TR.Tandem8x32(seed)
            key = TR.rngkey(parent)
            @test UInt64[key...] == TandemReferenceV2.key(UInt128(seed))
            children = TR.splitrng(parent, 32; threaded = false)
            for i = 0:15
                @test block(probe(8, :split_o_seq; seed), UInt64(i)) ==
                      TR.rngkey(children[2i+1])
                @test block(probe(8, :split_h_seq; seed), UInt64(i)) ==
                      TR.rngkey(children[2i+2])
            end
            for rounds = 4:8, kind in PROBES
                g = probe(rounds, kind; seed)
                for i in UInt64[0, 7, (1<<32)-2, 1<<32, 1<<48, typemax(UInt64)-2]
                    @test collect(@inferred block(g, i)) == oracle(key, i, rounds, kind)
                end
                # Cross the low-word rollover in several refills and one whole fill.
                g.index = (UInt64(1)<<32)-3
                whole = deepcopy(g)
                pieces = [fill_words!(zeros(UInt32, n), g) for n in (4, 8, 20, 64)]
                @test reduce(vcat, pieces) == fill_words!(zeros(UInt32, 96), whole)
                @test g.index == whole.index == (UInt64(1)<<32)+21
                words = zeros(UInt32, 16384)
                @test (@inferred fill_words!(words, g)) === words
                @test (@allocated fill_words!(words, g)) == 0
                @test transform(words, :sequential, g) === words
            end
        end
        @test swap32(UInt64(1)<<32) == 1
        @test swap32((UInt64(1)<<32)-1) == 0xffffffff00000000
        @test swap32(UInt64(1)) == 0x0000000100000000
        @test_throws ArgumentError probe(0, :split_o_seq)
        @test_throws ArgumentError probe(9, :split_o_seq)
        @test_throws ArgumentError probe(8, :unknown)
        g = probe(8, :split_o_seq)
        @test_throws ArgumentError fill_words!(zeros(UInt32, 3), g)
        @test_throws ArgumentError transform(zeros(UInt32, 4), :chunkstart, g)
    end
    return Test.get_test_counts(result)
end

end
