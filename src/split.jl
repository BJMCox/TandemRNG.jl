# The three split disciplines derive child keys with F under distinct domain words.
# The domains separate seeding inputs under one parent key. Truncated child keys can collide.

const MAX_FORK_CHILDREN = UInt64(1) << 33

@inline function _child_key(
    key::O4,
    index::UInt64,
    domain::UInt32,
    aux::UInt32,
    half::Integer,
)
    o, h = seed(key, index, domain, aux)
    return iszero(half) ? o : h
end

"""
    splitrng(rng, n) -> Vector{Tandem8x32{K}}
    splitrng(rng, Val(N)) -> NTuple{N,Tandem8x32{K}}
    splitrng(rng) -> two children

Children of `rng` by index. Child `i` (0-based) has key half `i & 1` of
`F(key, i >> 1, SPLIT)`. Derivation reads only the parent key and starts every child at
position zero, so an advanced parent gives the same children. Use stable indices.
Child keys have 128 bits; derivation does not guarantee collision-free keys.
"""
splitrng(rng::Tandem8x32) = splitrng(rng, Val(2))

@inline function splitrng(rng::Tandem8x32{K}, ::Val{N}) where {K,N}
    (N isa Int && N >= 0) || throw(ArgumentError("N must be a non-negative Int"))
    return ntuple(i -> _split_child(rng, UInt64(i - 1)), Val(N))
end

function splitrng(rng::Tandem8x32{K}, n::Integer; threaded::Bool = true) where {K}
    0 <= n <= typemax(Int) || throw(ArgumentError("n must satisfy 0 <= n <= typemax(Int)"))
    children = Vector{typeof(rng)}(undef, n)
    _foreach_index(n, threaded) do i
        children[i] = _split_child(rng, UInt64(i - 1))
    end
    return children
end

@inline _split_child(rng::Tandem8x32{K}, i::UInt64) where {K} = _bind(
    Tandem8x32{K}(_child_key(rng.key, i >> 1, DOMAIN_SPLIT, UInt32(0), i & 1), 0),
    rng.device,
)

"""
    forkrng(rng, n) -> (rng′, children::Vector)
    forkrng(rng, Val(N)) -> (rng′, children::NTuple)
    forkrng(rng) -> (rng′, child)

Children of `rng` at its current block, and the parent moved to the start of the next block.
All children of one call use the same block `b = position >> 7`: child `i` has key half
`i & 1` of `F(key, b, FORK, aux = i >> 1)`. Successive calls using the returned parent
use distinct blocks. Child-key collisions remain possible. `n` is at most 2^33.
"""
function forkrng(rng::Tandem8x32{K}) where {K}
    rng′, children = forkrng(rng, Val(1))
    return rng′, children[1]
end

@inline function forkrng(rng::Tandem8x32{K}, ::Val{N}) where {K,N}
    (N isa Int && N >= 0) || throw(ArgumentError("N must be a non-negative Int"))
    b = rng.pos >> 7
    children = ntuple(i -> _fork_child(rng, b, UInt64(i - 1)), Val(N))
    return _advance(rng, (b + 1) << 7), children
end

function forkrng(rng::Tandem8x32{K}, n::Integer) where {K}
    0 <= n <= MAX_FORK_CHILDREN || throw(ArgumentError("n must satisfy 0 <= n <= 2^33"))
    b = rng.pos >> 7
    children = Vector{typeof(rng)}(undef, n)
    _foreach_index(n) do i
        children[i] = _fork_child(rng, b, UInt64(i - 1))
    end
    return _advance(rng, (b + 1) << 7), children
end

@inline _fork_child(rng::Tandem8x32{K}, b::UInt64, i::UInt64) where {K} = _bind(
    Tandem8x32{K}(_child_key(rng.key, b, DOMAIN_FORK, (i >> 1) % UInt32, i & 1), 0),
    rng.device,
)

"""
    subrng(rng, purpose) -> Tandem8x32{K}

One child for a stable integer `purpose`, from `F(key, purpose, FOLD)`. Use fixed purpose
ids for independent roles. `purpose` is reduced modulo 2^64.
"""
subrng(rng::Tandem8x32{K}, purpose::Integer) where {K} = _bind(
    Tandem8x32{K}(
        _child_key(rng.key, UInt64(purpose % UInt64), DOMAIN_FOLD, UInt32(0), 0),
        0,
    ),
    rng.device,
)

# Derive children in parallel when there are enough of them to pay for the threads.
function _foreach_index(f, n::Integer, threaded::Bool = true)
    if threaded && n >= 1024 && Threads.nthreads() > 1
        Threads.@threads :dynamic for i = 1:n
            f(i)
        end
    else
        for i = 1:n
            f(i)
        end
    end
    return nothing
end
