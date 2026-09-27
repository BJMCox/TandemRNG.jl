# Check basic extraction statistics. These smoke tests are separate from the full
# statistical campaigns.

@testset "statistics: smoke" begin
    n = 1 << 20
    rng = Tandem8x32(2026)
    bytes = Vector{UInt8}(undef, n)
    rand_fill!(rng, bytes)
    counts = zeros(Int, 256)
    for b in bytes
        counts[Int(b)+1] += 1
    end
    expected = n / 256
    chi2 = sum((c - expected)^2 / expected for c in counts)
    # 255 degrees of freedom: the 0.001 quantile pair is about (190, 331).
    @test 190 < chi2 < 331

    floats = Vector{Float64}(undef, n)
    rand_fill!(rng, floats)
    @test all(x -> 0 <= x < 1, floats)
    σ = sqrt(1 / 12 / n)
    @test abs(sum(floats) / n - 0.5) < 5σ

    bits = Vector{Bool}(undef, n)
    rand_fill!(rng, bits)
    @test abs(count(bits) / n - 0.5) < 5 * sqrt(0.25 / n)
end
