include(joinpath(@__DIR__, "../design/search/streams.jl"))
include(joinpath(@__DIR__, "../design/search/reference_v2.jl"))

# Resolve each UInt32 address through the independent scalar F/T reference.
function validation_words(key, K, position, n)
    blocks = Dict{Tuple{UInt64,Int},Vector{UInt64}}()
    return map(0:(n-1)) do i
        p = UInt128(position) + 32i
        row = p ÷ 1024
        c = UInt64(8 * (row ÷ K) + (p % 1024) ÷ 128)
        j = Int(row % K)
        block = get!(blocks, (c, j)) do
            TandemReferenceV2.block(key, c, j)
        end
        block[Int((p%128)÷32)+1] % UInt32
    end
end

function validation_output(gen, stream, sizes)
    result = UInt32[]
    for n in sizes
        words = zeros(UInt32, n)
        TandemHarness.fill_words!(words, gen)
        append!(result, TandemHarness.transform(words, stream, gen))
    end
    return result
end

@testset "validation stream feeds" begin
    for family in (:keys, :counters)
        for (_, gen, stream) in TandemStreams.cases(family)
            initial = gen.rng
            n = 2 * 32 * 32
            expected = validation_words(rngkey(initial), 32, rngposition(initial), n)
            @test validation_output(gen, stream, (n,)) == expected
        end
    end

    # An independent F computes every sibling key, including the selected output half.
    parent_key = TandemReferenceV2.key(UInt128(42))
    for (label, gen, stream) in TandemStreams.cases(:siblings)
        keys = map(0:7) do i
            state = if occursin("split8", String(label))
                TandemReferenceV2.seed(parent_key, UInt64(i ÷ 2), UInt64(0xbb67ae85), UInt64(0))
            elseif occursin("fork8", String(label))
                TandemReferenceV2.seed(
                    parent_key,
                    UInt64(13),
                    UInt64(0xd2511f53),
                    UInt64(i ÷ 2),
                )
            else
                TandemReferenceV2.seed(parent_key, UInt64(i), UInt64(0xcd9e8d57), UInt64(0))
            end
            half = occursin("subrng8", String(label)) ? 0 : i % 2
            state[(4half+1):(4half+4)]
        end
        per_child = 2 * 32 * 32 + 3
        draws = [validation_words(key, 32, 0, per_child) for key in keys]
        expected = [draws[j][i] for i = 1:per_child for j = 1:8]
        @test validation_output(gen, stream, (8 * 13, 8 * (per_child - 13))) == expected
    end

    # Check each word boundary against keys assembled with arbitrary-precision integers.
    key_integer = sum(BigInt(parent_key[i]) << (32(i-1)) for i = 1:4)
    for (b, (_, gen, stream)) in
        zip((0, 31, 32, 63, 64, 95, 96, 127), TandemStreams.cases(:onebit))
        changed = key_integer ⊻ (BigInt(1) << b)
        key = [UInt64((changed >> (32i)) & 0xffffffff) for i = 0:3]
        a = validation_words(parent_key, 32, 0, 12)
        c = validation_words(key, 32, 0, 12)
        expected = [isodd(i) ? a[(i+1)÷2] : c[i÷2] for i = 1:24]
        @test validation_output(gen, stream, (8, 16)) == expected
    end

    # Word projections follow row/lane/word order. Row projections stay inside each chunk.
    rng = Tandem8x32{32}(42)
    raw = validation_words(parent_key, 32, 0, 2 * 32 * 32)
    for (j, stream) in enumerate((:word0, :word1, :word2, :word3))
        @test validation_output(TandemFinal.PackageGen(rng), stream, (32 * 32, 32 * 32)) ==
              raw[j:4:end]
    end
    starts = [raw[1024g+q] for g = 0:1 for q = 1:32]
    xors = [raw[1024g+32s+q] ⊻ raw[1024g+32(s-1)+q] for g = 0:1 for s = 1:31 for q = 1:32]
    @test validation_output(TandemFinal.PackageGen(rng), :chunkstart, (1024, 1024)) ==
          starts
    @test validation_output(TandemFinal.PackageGen(rng), :xorstep, (1024, 1024)) == xors

    for bit in (0, 17, 31)
        expected = [
            UInt32(sum(BigInt((raw[32i+j] >> bit) & 1) << (j-1) for j = 1:32)) for i = 0:63
        ]
        @test validation_output(
            TandemFinal.PackageGen(rng),
            Symbol("bit$bit"),
            (1024, 1024),
        ) == expected
    end
    bytes = [UInt32(sum(BigInt(raw[4i+j] & 0xff) << (8(j-1)) for j = 1:4)) for i = 0:511]
    @test validation_output(TandemFinal.PackageGen(rng), :lowbyte, (1024, 1024)) == bytes

    # Non-power-of-two strides expose a phase reset at the refill boundary.
    decimated = TandemStreams.DecimatedGen(TandemFinal.PackageGen(rng), 3; offset = 2)
    @test validation_output(decimated, :sequential, (1024, 1024)) == raw[3:3:end]

    # Random123's all-zero Philox4x32-10 known-answer vector validates the control feed.
    control = TandemHarness.PhiloxGen(10; key = (0x00000000, 0x00000000))
    @test validation_output(control, :sequential, (4,)) ==
          UInt32[0x6627e8d5, 0xe169c58d, 0xbc57ac4c, 0x9b00dbd8]
end
