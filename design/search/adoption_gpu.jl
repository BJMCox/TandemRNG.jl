# Load the pre-adoption package as Main.FrozenV1.TandemRNG, then the candidate and extension as
# Main.Adopted.TandemRNG. See before-feedback.patch for the exact source baseline.
module AdoptionGPU
using CUDA
using Main.GPUBench: idle_check, idle, describe, best_seconds, gibps
const Old = Main.FrozenV1.TandemRNG
const New = Main.Adopted.TandemRNG

function fills(io; n = 1<<27, gpu = 0)
    Old.step(ntuple(UInt32, 4), ntuple(i->UInt32(i+4), 4))[2][1] == 0x9e377cbe ||
        error("Load the pre-feedback package first")
    before=idle_check(gpu)
    idle(before) || error("GPU busy: $(describe(before))")
    CUDA.device!(gpu)
    println(io, "pass\ttype\tvariant\tGiB/s")
    for T in (Float32, UInt32, Float64, Bool)
        A=CuVector{T}(undef, n)
        old, new = Old.Tandem8x32(42), New.Tandem8x32(42)
        cases=(("v1", ()->Old.rand_fill!(old, A)), ("v2", ()->New.rand_fill!(new, A)))
        for pass = 1:3, (name, f) in (isodd(pass) ? cases : reverse(cases))
            println(
                io,
                join((pass, T, name, gibps(n*sizeof(T), best_seconds(f, 30))), '\t'),
            )
            flush(io)
        end
        CUDA.unsafe_free!(A)
    end
    println(io, "before: ", describe(before))
    println(io, "after: ", describe(idle_check(gpu)))
end
end
