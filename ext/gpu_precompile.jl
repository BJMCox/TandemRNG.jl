# These releases load both strict-subset extensions before this workload. Their
# parent packages and triggers must occur explicitly in this extension's trigger list.
@static if (v"1.10.11" <= VERSION < v"1.11") || VERSION >= v"1.11.2"
    # Record the dependency on the extension that defines the GPU fill methods.
    const KAExt = Base.get_extension(TandemRNG, :TandemRNGKernelAbstractionsExt)
    const DeviceExt = Base.get_extension(TandemRNG.MLDataDevices, _DeviceExt)

    @setup_workload let
        types = filter(Base.uniontypes(TandemRNG.DrawTypes)) do T
            !(T <: TandemRNG.WideTypes) &&
                (_Float64 || !(T <: Union{Float64,Complex{Float64}}))
        end
        @compile_workload begin
            # Concrete host signatures also help machines without a working device.
            for ArrayFamily in _ArrayFamilies, T in types, N in (1, 2), K in (1, 32, 64)
                R = Tandem8x32{K,_Backend}
                A = ArrayFamily{T,N}
                precompile(rand_fill!, (R, A))
                precompile(rand_next, (R, Type{T}, NTuple{N,Int}))
                precompile(
                    Core.kwcall,
                    (NamedTuple{(:nthreads,),Tuple{Int}}, typeof(rand_fill!), R, A),
                )
            end

            # Earlier Julia releases can leak device intrinsics into native package images.
            @static if VERSION >= v"1.12"
                # Instrumented AMDGPU kernels can fail during precompilation.
                instrumented =
                    Base.JLOptions().code_coverage != 0 ||
                    Base.JLOptions().check_bounds == 1
                if !instrumented && _precompile_device()
                    ArrayFamily = first(_ArrayFamilies)
                    for T in types, K in (1, 32, 64), dims in ((513,), (17, 19))
                        A = ArrayFamily{T,length(dims)}(undef, dims)
                        backend = KernelAbstractions.get_backend(A)
                        try
                            rng = TandemRNG._bind(Tandem8x32{K}(42), _Backend())
                            rand_fill!(rng, A)
                            _, shifted = rand_next(rng, T)
                            rand_fill!(shifted, A)
                        finally
                            KernelAbstractions.synchronize(backend)
                            _unsafe_free!(A)
                        end
                    end
                end
            end
        end
    end
end
