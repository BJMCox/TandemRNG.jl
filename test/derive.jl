# Check split, fork, purpose derivation, and seed-whitening contracts.

@testset "split: index law" begin
    rng = Tandem8x32(21)
    kids = splitrng(rng, 6)
    @test length(unique(rngkey.(kids))) == 6
    @test all(rngposition(k) == 0 for k in kids)
    @test splitrng(rng, Val(6)) == Tuple(kids)
    @test collect(splitrng(rng)) == kids[1:2]
    _, advanced = rand_next(rng, Float64)
    @test splitrng(advanced, 6) == kids
end

@testset "fork: step law" begin
    rng = Tandem8x32(22)
    _, rng = rand_next(rng, Bool)           # position 1 bit, inside block 0
    parent, kids = forkrng(rng, 5)
    @test rngposition(parent) == 128
    @test length(unique(rngkey.(kids))) == 5
    @test forkrng(rng, Val(5))[2] == Tuple(kids)
    parent2, kids2 = forkrng(parent, 5)
    @test rngposition(parent2) == 256
    @test isempty(intersect(rngkey.(kids), rngkey.(kids2)))
    only_parent, only_child = forkrng(rng)
    @test only_parent == parent && only_child == kids[1]
end

@testset "derive: domain separation" begin
    rng = Tandem8x32(23)
    s = rngkey(splitrng(rng, 1)[1])
    _, f = forkrng(rng)
    u = rngkey(subrng(rng, 0))
    @test length(unique((s, rngkey(f), u))) == 3
end

@testset "seed whitening" begin
    k1 = rngkey(Tandem8x32(1))
    k2 = rngkey(Tandem8x32(2))
    @test sum(count_ones, k1 .⊻ k2) >= 32
    raw = (0x01234567, 0x89abcdef, 0xdeadbeef, 0x00000001)
    @test rngkey(Tandem8x32(raw)) == raw
end
