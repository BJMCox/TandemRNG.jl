module TandemRNGMetalExt

using TandemRNG
using Metal
using KernelAbstractions
using GPUArraysCore
using PrecompileTools: @setup_workload, @compile_workload

const _ArrayFamilies = (
    Metal.MtlArray{T,N,Metal.PrivateStorage} where {T,N},
    Metal.MtlArray{T,N,Metal.SharedStorage} where {T,N},
)
const _Float64 = false
const _Backend = TandemRNG._MetalBackend
const _DeviceExt = :MetalExt
TandemRNG._allocate_array(::_Backend, ::Type{T}, dims::Dims) where {T} =
    Metal.MtlArray{T}(undef, dims)
# Metal skips device initialization while precompiling downstream packages.
_precompile_device() = false

_unsafe_free!(A) = Metal.unsafe_free!(A)

include("gpu_precompile.jl")

end
