# This file is a part of Julia. License is MIT: https://julialang.org/license

## RandomDevice


"""
    RandomDevice()

Create a `RandomDevice` RNG object.
Two such objects will always generate different streams of random numbers.
The entropy is obtained from the operating system.
"""
struct RandomDevice <: AbstractRNG; end
RandomDevice(seed::Nothing) = RandomDevice()
seed!(rng::RandomDevice, ::Nothing) = rng

rand(rd::RandomDevice, sp::SamplerBoolBitInteger) = Libc.getrandom!(Ref{sp[]}())[]
rand(rd::RandomDevice, ::SamplerType{Bool}) = rand(rd, UInt8) % Bool

# specialization for homogeneous tuple types of builtin integers, to avoid
# repeated system calls
rand(rd::RandomDevice, sp::SamplerTag{Ref{Tuple{Vararg{T, N}}}, Tuple{S}}
     ) where {T, N, S <: SamplerUnion(Base.BitInteger_types...)} =
         Libc.getrandom!(Ref{gentype(sp)}())[]

function rand!(rd::RandomDevice, A::Array{Bool}, ::SamplerType{Bool})
    Libc.getrandom!(A)
    # we need to mask the result so that only the LSB in each byte can be non-zero
    GC.@preserve A begin
        p = Ptr{UInt8}(pointer(A))
        for i = 1:length(A)
            unsafe_store!(p, unsafe_load(p) & 0x1)
            p += 1
        end
    end
    return A
end
for T in BitInteger_types
    @eval rand!(rd::RandomDevice, A::Array{$T}, ::SamplerType{$T}) = Libc.getrandom!(A)
end

# RandomDevice produces natively UInt64
rng_native_52(::RandomDevice) = UInt64


## MersenneTwister

const MT_CACHE_F = 501 << 1 # number of Float64 in the cache
const MT_CACHE_I = 501 << 4 # number of bytes in the UInt128 cache

@assert dsfmt_get_min_array_size() <= MT_CACHE_F

mutable struct MersenneTwister <: AbstractRNG
    seed::Any
    state::DSFMT_state
    vals::Vector{Float64}
    ints::Vector{UInt128}
    idxF::Int
    idxI::Int

    # counters for show
    adv::Int64          # state of advance at the DSFMT_state level
    adv_jump::BigInt    # number of skipped Float64 values via randjump
    adv_vals::Int64     # state of advance when vals is filled-up
    adv_ints::Int64     # state of advance when ints is filled-up

    function MersenneTwister(seed, state, vals, ints, idxF, idxI,
                             adv, adv_jump, adv_vals, adv_ints)
        length(vals) == MT_CACHE_F && 0 <= idxF <= MT_CACHE_F ||
            throw(DomainError((length(vals), idxF),
                      "`length(vals)` and `idxF` must be consistent with $MT_CACHE_F"))
        length(ints) == MT_CACHE_I >> 4 && 0 <= idxI <= MT_CACHE_I ||
            throw(DomainError((length(ints), idxI),
                      "`length(ints)` and `idxI` must be consistent with $MT_CACHE_I"))
        new(seed, state, vals, ints, idxF, idxI,
            adv, adv_jump, adv_vals, adv_ints)
    end
end

MersenneTwister(seed, state::DSFMT_state) =
    MersenneTwister(seed, state,
                    Vector{Float64}(undef, MT_CACHE_F),
                    Vector{UInt128}(undef, MT_CACHE_I >> 4),
                    MT_CACHE_F, 0, 0, 0, -1, -1)

"""
    MersenneTwister(seed)
    MersenneTwister()

Create a `MersenneTwister` RNG object. Different RNG objects can have
their own seeds, which may be useful for generating different streams
of random numbers.
The `seed` may be an integer, a string, or a vector of `UInt32` integers.
If no seed is provided, a randomly generated one is created (using entropy from the system).
See the [`seed!`](@ref) function for reseeding an already existing `MersenneTwister` object.

!!! compat "Julia 1.11"
    Passing a negative integer seed requires at least Julia 1.11.

# Examples
```jldoctest
julia> rng = MersenneTwister(123);

julia> x1 = rand(rng, 2)
2-element Vector{Float64}:
 0.37453777969575874
 0.8735343642013971

julia> x2 = rand(MersenneTwister(123), 2)
2-element Vector{Float64}:
 0.37453777969575874
 0.8735343642013971

julia> x1 == x2
true
```
"""
MersenneTwister(seed=nothing) =
    seed!(MersenneTwister(Vector{UInt32}(), DSFMT_state()), seed)


function copy!(dst::MersenneTwister, src::MersenneTwister)
    dst.seed = src.seed
    copy!(dst.state, src.state)
    copyto!(dst.vals, src.vals)
    copyto!(dst.ints, src.ints)
    dst.idxF = src.idxF
    dst.idxI = src.idxI
    dst.adv = src.adv
    dst.adv_jump = src.adv_jump
    dst.adv_vals = src.adv_vals
    dst.adv_ints = src.adv_ints
    dst
end

copy(src::MersenneTwister) =
    MersenneTwister(src.seed, copy(src.state), copy(src.vals), copy(src.ints),
                    src.idxF, src.idxI, src.adv, src.adv_jump, src.adv_vals, src.adv_ints)


==(r1::MersenneTwister, r2::MersenneTwister) =
    r1.seed == r2.seed && r1.state == r2.state &&
    isequal(r1.vals, r2.vals) &&
    isequal(r1.ints, r2.ints) &&
    r1.idxF == r2.idxF && r1.idxI == r2.idxI

hash(r::MersenneTwister, h::UInt) =
    foldr(hash, (r.seed, r.state, r.vals, r.ints, r.idxF, r.idxI); init=h)

function show(io::IO, rng::MersenneTwister)
    # seed
    if rng.adv_jump == 0 && rng.adv == 0
        return print(io, MersenneTwister, "(", repr(rng.seed), ")")
    end
    print(io, MersenneTwister, "(", repr(rng.seed), ", (")
    # state
    sep = ", "
    show(io, rng.adv_jump)
    print(io, sep)
    show(io, rng.adv)
    if rng.adv_vals != -1 || rng.adv_ints != -1
        # "(0, 0)" is nicer on the eyes than (-1, 1002)
        s = rng.adv_vals != -1
        print(io, sep)
        show(io, s ? rng.adv_vals : zero(rng.adv_vals))
        print(io, sep)
        show(io, s ? rng.idxF : zero(rng.idxF))
    end
    if rng.adv_ints != -1
        idxI = (length(rng.ints)*16 - rng.idxI) / 8 # 8 represents one Int64
        idxI = Int(idxI) # idxI should always be an integer when using public APIs
        print(io, sep)
        show(io, rng.adv_ints)
        print(io, sep)
        show(io, idxI)
    end
    print(io, "))")
end

### low level API

function reset_caches!(r::MersenneTwister)
    # zeroing the caches makes comparing two MersenneTwister RNGs easier
    fill!(r.vals, 0.0)
    fill!(r.ints, zero(UInt128))
    mt_setempty!(r)
    mt_setempty!(r, UInt128)
    r.adv_vals = -1
    r.adv_ints = -1
    r
end

#### floats

mt_avail(r::MersenneTwister) = MT_CACHE_F - r.idxF
mt_empty(r::MersenneTwister) = r.idxF == MT_CACHE_F
mt_setfull!(r::MersenneTwister) = r.idxF = 0
mt_setempty!(r::MersenneTwister) = r.idxF = MT_CACHE_F
mt_pop!(r::MersenneTwister) = @inbounds return r.vals[r.idxF+=1]

@noinline function gen_rand(r::MersenneTwister)
    r.adv_vals = r.adv
    GC.@preserve r fill_array!(r, pointer(r.vals), length(r.vals), CloseOpen12())
    mt_setfull!(r)
end

reserve_1(r::MersenneTwister) = (mt_empty(r) && gen_rand(r); nothing)
# `reserve` allows one to call `rand_inbounds` n times
# precondition: n <= MT_CACHE_F
reserve(r::MersenneTwister, n::Int) = (mt_avail(r) < n && gen_rand(r); nothing)

#### ints

logsizeof(::Type{<:Union{Bool,Int8,UInt8}}) = 0
logsizeof(::Type{<:Union{Int16,UInt16}}) = 1
logsizeof(::Type{<:Union{Int32,UInt32}}) = 2
logsizeof(::Type{<:Union{Int64,UInt64}}) = 3
logsizeof(::Type{<:Union{Int128,UInt128}}) = 4

idxmask(::Type{<:Union{Bool,Int8,UInt8}}) = 15
idxmask(::Type{<:Union{Int16,UInt16}}) = 7
idxmask(::Type{<:Union{Int32,UInt32}}) = 3
idxmask(::Type{<:Union{Int64,UInt64}}) = 1
idxmask(::Type{<:Union{Int128,UInt128}}) = 0


mt_avail(r::MersenneTwister, ::Type{T}) where {T<:BitInteger} =
    r.idxI >> logsizeof(T)

function mt_setfull!(r::MersenneTwister, ::Type{<:BitInteger})
    r.adv_ints = r.adv
    ints = r.ints

    @assert length(ints) == 501
    # dSFMT natively randomizes 52 out of 64 bits of each UInt64 words,
    # i.e. 12 bits are missing;
    # by generating 5 words == 5*52 == 260 bits, we can fully
    # randomize 4 UInt64 = 256 bits; IOW, at the array level, we must
    # randomize ceil(501*1.25) = 627 UInt128 words (with 2*52 bits each),
    # which we then condense into fully randomized 501 UInt128 words

    len = 501 + 126 # 126 == ceil(501 / 4)
    resize!(ints, len)
    p = pointer(ints) # must be *after* resize!
    GC.@preserve r fill_array!(r, Ptr{Float64}(p), len*2, CloseOpen12_64())

    k = 501
    n = 0
    @inbounds while n != 500
        u = ints[k+=1]
        ints[n+=1] ⊻= u << 48
        ints[n+=1] ⊻= u << 36
        ints[n+=1] ⊻= u << 24
        ints[n+=1] ⊻= u << 12
    end
    @assert k == len - 1
    @inbounds ints[501] ⊻= ints[len] << 48
    resize!(ints, 501)
    r.idxI = MT_CACHE_I
end

mt_setempty!(r::MersenneTwister, ::Type{<:BitInteger}) = r.idxI = 0

function reserve1(r::MersenneTwister, ::Type{T}) where T<:BitInteger
    r.idxI < sizeof(T) && mt_setfull!(r, T)
    nothing
end

function mt_pop!(r::MersenneTwister, ::Type{T}) where T<:BitInteger
    reserve1(r, T)
    r.idxI -= sizeof(T)
    i = r.idxI
    @inbounds x128 = r.ints[1 + i >> 4]
    i128 = (i >> logsizeof(T)) & idxmask(T) # 0-based "indice" in x128
    (x128 >> (i128 * (sizeof(T) << 3))) % T
end

function mt_pop!(r::MersenneTwister, ::Type{T}) where {T<:Union{Int128,UInt128}}
    reserve1(r, T)
    idx = r.idxI >> 4
    r.idxI = idx << 4 - 16
    @inbounds r.ints[idx] % T
end


### seeding

"""
    Random.SeedHasher(seed=nothing)

Create a `Random.SeedHasher` RNG object, which generates random bytes with the help
of a cryptographic hash function (SHA2), via calls to [`Random.hash_seed`](@ref).

Given two seeds `s1` and `s2`, the random streams generated by
`SeedHasher(s1)` and `SeedHasher(s2)` should be distinct if and only if
`s1` and `s2` are distinct.

This RNG is used by default in `Random.seed!(::AbstractRNG, seed::Any)`, such that
RNGs usually need only to implement `seed!(rng, ::AbstractRNG)`.

This is an internal type, subject to change.
"""
mutable struct SeedHasher <: AbstractRNG
    bytes::Vector{UInt8}
    idx::Int
    cnt::Int64

    SeedHasher(seed=nothing) = seed!(new(), seed)
end

seed!(rng::SeedHasher, seeder::AbstractRNG) = seed!(rng, rand(seeder, UInt64, 4))
seed!(rng::SeedHasher, ::Nothing) = seed!(rng, RandomDevice())

function seed!(rng::SeedHasher, seed)
    # typically, no more than 256 bits will be needed, so use
    # SHA2_256 because it's faster
    ctx = SHA2_256_CTX()
    hash_seed(seed, ctx)
    rng.bytes = SHA.digest!(ctx)::Vector{UInt8}
    rng.idx = 0
    rng.cnt = 0
    rng
end

@noinline function rehash!(rng::SeedHasher)
    # more random bytes are necessary, from now on use SHA2_512 to generate
    # more bytes at once
    ctx = SHA2_512_CTX()
    SHA.update!(ctx, rng.bytes)
    # also hash the counter, just for the extremely unlikely case where the hash of
    # rng.bytes is equal to rng.bytes (i.e. rng.bytes is a "fixed point"), or more generally
    # if there is a small cycle
    SHA.update!(ctx, reinterpret(NTuple{8, UInt8}, rng.cnt += 1))
    rng.bytes = SHA.digest!(ctx)
    rng.idx = 0
    rng
end

function rand(rng::SeedHasher, ::SamplerType{UInt8})
    rng.idx < length(rng.bytes) || rehash!(rng)
    rng.bytes[rng.idx += 1]
end

for TT = Base.BitInteger_types
    TT === UInt8 && continue
    @eval function rand(rng::SeedHasher, ::SamplerType{$TT})
        xx = zero($TT)
        for ii = 0:sizeof($TT)-1
            xx |= (rand(rng, UInt8) % $TT) << (8 * ii)
        end
        xx
    end
end

rand(rng::SeedHasher, ::SamplerType{Bool}) = rand(rng, UInt8) % Bool

rng_native_52(::SeedHasher) = UInt64


#### hash_seed()

function hash_seed(seed::Integer, ctx::SHA_CTX)
    neg = signbit(seed)
    if neg
        seed = ~seed
    end
    @assert seed >= 0
    while true
        word = (seed % UInt32) & 0xffffffff
        seed >>>= 32
        SHA.update!(ctx, reinterpret(NTuple{4, UInt8}, word))
        iszero(seed) && break
    end
    # make sure the hash of negative numbers is different from the hash of positive numbers
    neg && SHA.update!(ctx, (0x01,))
    nothing
end

function hash_seed(seed::Union{AbstractArray{UInt32}, AbstractArray{UInt64}}, ctx::SHA_CTX)
    for xx in seed
        SHA.update!(ctx, reinterpret(NTuple{8, UInt8}, UInt64(xx)))
    end
    # discriminate from hash_seed(::Integer)
    SHA.update!(ctx, (0x10,))
end

function hash_seed(str::AbstractString, ctx::SHA_CTX)
    # convert to String such that `codeunits(str)` below is consistent between equal
    # strings of different types
    str = String(str)
    SHA.update!(ctx, codeunits(str))
    # signature for strings: so far, all hash_seed functions end-up hashing a multiple
    # of 4 bytes of data, and add the signature (1 byte) at the end; so hash as many
    # bytes as necessary to have a total number of hashed bytes equal to 0 mod 4 (padding),
    # and then hash the signature 0x05; in order for strings of different lengths to have
    # different hashes, padding bytes are set equal to the number of padding bytes
    pad = 4 - mod(ncodeunits(str), 4)
    for _=1:pad
        SHA.update!(ctx, (pad % UInt8,))
    end
    SHA.update!(ctx, (0x05,))
end


"""
    Random.hash_seed(seed, ctx::SHA_CTX)::AbstractVector{UInt8}

Update `ctx` via `SHA.update!` with the content of `seed`.
This function is used by the [`SeedHasher`](@ref) RNG to produce
random bytes.

`seed` can currently be of type
`Union{Integer, AbstractString, AbstractArray{UInt32}, AbstractArray{UInt64}}`,
but modules can extend this function for types they own.

`hash_seed` is "injective" : for two equivalent context objects `cn` and `cm`,
if `n != m`, then `cn` and `cm` will be distinct after calling
`hash_seed(n, cn); hash_seed(m, cm)`.
Moreover, if `n == m`, then `cn` and `cm` remain equivalent after calling
`hash_seed(n, cn); hash_seed(m, cm)`.
"""
hash_seed


#### seed!()

function initstate!(r::MersenneTwister, data::StridedVector, seed)
    # we deepcopy `seed` because the caller might mutate it, and it's useful
    # to keep it constant inside `MersenneTwister`; but multiple instances
    # can share the same seed without any problem (e.g. in `copy`)
    r.seed = deepcopy(seed)
    dsfmt_init_by_array(r.state, reinterpret(UInt32, data))
    reset_caches!(r)
    r.adv = 0
    r.adv_jump = 0
    return r
end

# When a seed is not provided, we generate one via `RandomDevice()` rather
# than calling directly `initstate!` with `rand(RandomDevice(), UInt32, 8)` because the
# seed is printed in `show(::MersenneTwister)`, so we need one; the cost of `hash_seed` is a
# small overhead compared to `initstate!`.
# A random seed with 128 bits is a good compromise for almost surely getting distinct
# seeds, while having them printed reasonably tersely.
seed!(r::MersenneTwister, seeder::AbstractRNG) = seed!(r, rand(seeder, UInt128))
seed!(r::MersenneTwister, ::Nothing) = seed!(r, RandomDevice())
seed!(r::MersenneTwister, seed) = initstate!(r, rand(SeedHasher(seed), UInt32, 8), seed)


### Global RNG

"""
    Random.default_rng() -> rng

Return the default global random number generator (RNG), which is used by `rand`-related functions when
no explicit RNG is provided.

When the `Random` module is loaded, the default RNG is _randomly_ seeded, via [`Random.seed!()`](@ref):
this means that each time a new julia session is started, the first call to `rand()` produces a different
result, unless `seed!(seed)` is called first.

It is thread-safe: distinct threads can safely call `rand`-related functions on `default_rng()` concurrently,
e.g. `rand(default_rng())`.

!!! note
    The type of the default RNG is an implementation detail. Across different versions of
    Julia, you should not expect the default RNG to always have the same type, nor that it will
    produce the same stream of random numbers for a given seed.

!!! compat "Julia 1.3"
    This function was introduced in Julia 1.3.
"""
@inline default_rng() = TaskLocalRNG()
@inline default_rng(tid::Int) = TaskLocalRNG()

# defined only for backward compatibility with pre-v1.3 code when `default_rng()` didn't exist;
# `GLOBAL_RNG` was never really documented, but was appearing in the docstring of `rand`
const GLOBAL_RNG = default_rng()

# In v1.0, the GLOBAL_RNG was storing the seed which was used to initialize it; this seed was used to implement
# the following feature of `@testset`:
# > Before the execution of the body of a `@testset`, there is an implicit
# > call to `Random.seed!(seed)` where `seed` is the current seed of the global RNG.
# But the global RNG is now `TaskLocalRNG()` and doesn't store its seed; in order to not break `@testset`,
# in a call like `seed!(seed)` *without* an explicit RNG, we now store the state of `TaskLocalRNG()` in
# `task_local_storage()`

# GLOBAL_SEED is used as a fall-back when no tls seed is found
# only `Random.__init__` is allowed to set it
const GLOBAL_SEED = Xoshiro(0, 0, 0, 0, 0)

get_tls_seed() = get!(() -> copy(GLOBAL_SEED), task_local_storage(),
                      :__RANDOM_GLOBAL_RNG_SEED_uBlmfA8ZS__)::Xoshiro

# seed the default RNG
function seed!(seed=nothing)
    seed!(default_rng(), seed)
    copy!(get_tls_seed(), default_rng())
    default_rng()
end

function __init__()
    # do not call no-arg `seed!()` to not update `task_local_storage()` unnecessarily at startup
    seed!(default_rng())
    copy!(GLOBAL_SEED, TaskLocalRNG())
    ccall(:jl_gc_init_finalizer_rng_state, Cvoid, ())
end


### generation

# MersenneTwister produces natively Float64
rng_native_52(::MersenneTwister) = Float64

#### helper functions

# precondition: !mt_empty(r)
rand_inbounds(r::MersenneTwister, ::CloseOpen12_64) = mt_pop!(r)
rand_inbounds(r::MersenneTwister, ::CloseOpen01_64=CloseOpen01()) =
    rand_inbounds(r, CloseOpen12()) - 1.0

rand_inbounds(r::MersenneTwister, ::UInt52Raw{T}) where {T<:BitInteger} =
    reinterpret(UInt64, rand_inbounds(r, CloseOpen12())) % T

function rand(r::MersenneTwister, x::SamplerTrivial{UInt52Raw{UInt64}})
    reserve_1(r)
    rand_inbounds(r, x[])
end

function rand(r::MersenneTwister, ::SamplerTrivial{UInt2x52Raw{UInt128}})
    reserve(r, 2)
    rand_inbounds(r, UInt52Raw(UInt128)) << 64 | rand_inbounds(r, UInt52Raw(UInt128))
end

function rand(r::MersenneTwister, ::SamplerTrivial{UInt104Raw{UInt128}})
    reserve(r, 2)
    rand_inbounds(r, UInt52Raw(UInt128)) << 52 ⊻ rand_inbounds(r, UInt52Raw(UInt128))
end

#### floats

rand(r::MersenneTwister, sp::SamplerTrivial{CloseOpen12_64}) =
    (reserve_1(r); rand_inbounds(r, sp[]))

#### integers

rand(r::MersenneTwister, T::SamplerUnion(Int64, UInt64, Int128, UInt128)) =
    mt_pop!(r, T[])

rand(r::MersenneTwister, T::SamplerUnion(Bool, Int8, UInt8, Int16, UInt16, Int32, UInt32)) =
    rand(r, UInt52Raw()) % T[]

#### arrays of floats

##### AbstractArray

function rand!(r::MersenneTwister, A::AbstractArray{Float64},
               I::SamplerTrivial{<:FloatInterval_64})
    region = LinearIndices(A)
    # what follows is equivalent to this simple loop but more efficient:
    # for i=region
    #     @inbounds A[i] = rand(r, I[])
    # end
    m = Base.checked_sub(first(region), 1)
    n = last(region)
    while m < n
        s = mt_avail(r)
        if s == 0
            gen_rand(r)
            s = mt_avail(r)
        end
        m2 = min(n, m+s)
        for i=m+1:m2
            @inbounds A[i] = rand_inbounds(r, I[])
        end
        m = m2
    end
    A
end


##### Array : internal functions

# internal array-like type to circumvent the lack of flexibility with reinterpret
struct UnsafeView{T} <: DenseArray{T,1}
    ptr::Ptr{T}
    len::Int
end

Base.length(a::UnsafeView) = a.len
Base.getindex(a::UnsafeView, i::Int) = unsafe_load(a.ptr, i)
Base.setindex!(a::UnsafeView, x, i::Int) = unsafe_store!(a.ptr, x, i)
Base.pointer(a::UnsafeView) = a.ptr
Base.size(a::UnsafeView) = (a.len,)
Base.elsize(::Type{UnsafeView{T}}) where {T} = sizeof(T)

# this is essentially equivalent to rand!(r, ::AbstractArray{Float64}, I) above, but due to
# optimizations which can't be done currently when working with pointers, we have to re-order
# manually the computation flow to get the performance
# (see https://discourse.julialang.org/t/unsafe-store-sometimes-slower-than-arrays-setindex)
function _rand_max383!(r::MersenneTwister, A::UnsafeView{Float64}, I::FloatInterval_64)
    n = length(A)
    @assert n <= dsfmt_get_min_array_size()+1 # == 383
    mt_avail(r) == 0 && gen_rand(r)
    # from now on, at most one call to gen_rand(r) will be necessary
    m = min(n, mt_avail(r))
    GC.@preserve r unsafe_copyto!(A.ptr, pointer(r.vals, r.idxF+1), m)
    if m == n
        r.idxF += m
    else # m < n
        gen_rand(r)
        GC.@preserve r unsafe_copyto!(A.ptr+m*sizeof(Float64), pointer(r.vals), n-m)
        r.idxF = n-m
    end
    if I isa CloseOpen01
        for i=1:n
            A[i] -= 1.0
        end
    end
    A
end

function fill_array!(rng::MersenneTwister, A::Ptr{Float64}, n::Int, I)
    rng.adv += n
    fill_array!(rng.state, A, n, I)
end

fill_array!(s::DSFMT_state, A::Ptr{Float64}, n::Int, ::CloseOpen01_64) =
    dsfmt_fill_array_close_open!(s, A, n)

fill_array!(s::DSFMT_state, A::Ptr{Float64}, n::Int, ::CloseOpen12_64) =
    dsfmt_fill_array_close1_open2!(s, A, n)


function rand!(r::MersenneTwister, A::UnsafeView{Float64},
               I::SamplerTrivial{<:FloatInterval_64})
    # depending on the alignment of A, the data written by fill_array! may have
    # to be left-shifted by up to 15 bytes (cf. unsafe_copyto! below) for
    # reproducibility purposes;
    # so, even for well aligned arrays, fill_array! is used to generate only
    # the n-2 first values (or n-3 if n is odd), and the remaining values are
    # generated by the scalar version of rand
    n = length(A)
    n2 = (n-2) ÷ 2 * 2
    n2 < dsfmt_get_min_array_size() && return _rand_max383!(r, A, I[])

    pA = A.ptr
    align = Csize_t(pA) % 16
    if align > 0
        pA2 = pA + 16 - align
        fill_array!(r, pA2, n2, I[]) # generate the data in-place, but shifted
        unsafe_copyto!(pA, pA2, n2) # move the data to the beginning of the array
    else
        fill_array!(r, pA, n2, I[])
    end
    for i=n2+1:n
        A[i] = rand(r, I[])
    end
    A
end

# fills up A reinterpreted as an array of Float64 with n64 values
function _rand!(r::MersenneTwister, A::Array{T}, n64::Int, I::FloatInterval_64) where T
    # n64 is the length in terms of `Float64` of the target
    @assert sizeof(Float64)*n64 <= sizeof(T)*length(A) && isbitstype(T)
    GC.@preserve A rand!(r, UnsafeView{Float64}(pointer(A), n64), SamplerTrivial(I))
    A
end

##### Array: Float64, Float16, Float32

rand!(r::MersenneTwister, A::Array{Float64}, I::SamplerTrivial{<:FloatInterval_64}) =
    _rand!(r, A, length(A), I[])

mask128(u::UInt128, ::Type{Float16}) =
    (u & 0x03ff03ff03ff03ff03ff03ff03ff03ff) | 0x3c003c003c003c003c003c003c003c00

mask128(u::UInt128, ::Type{Float32}) =
    (u & 0x007fffff007fffff007fffff007fffff) | 0x3f8000003f8000003f8000003f800000

for T in (Float16, Float32)
    @eval function rand!(r::MersenneTwister, A::Array{$T}, ::SamplerTrivial{CloseOpen12{$T}})
        n = length(A)
        n128 = n * sizeof($T) ÷ 16
        _rand!(r, A, 2*n128, CloseOpen12())
        GC.@preserve A begin
            A128 = UnsafeView{UInt128}(pointer(A), n128)
            for i in 1:n128
                u = A128[i]
                u ⊻= u << 26
                # at this point, the 64 low bits of u, "k" being the k-th bit of A128[i] and "+"
                # the bit xor, are:
                # [..., 58+32,..., 53+27, 52+26, ..., 33+7, 32+6, ..., 27+1, 26, ..., 1]
                # the bits needing to be random are
                # [1:10, 17:26, 33:42, 49:58] (for Float16)
                # [1:23, 33:55] (for Float32)
                # this is obviously satisfied on the 32 low bits side, and on the high side,
                # the entropy comes from bits 33:52 of A128[i] and then from bits 27:32
                # (which are discarded on the low side)
                # this is similar for the 64 high bits of u
                A128[i] = mask128(u, $T)
            end
        end
        for i in 16*n128÷sizeof($T)+1:n
            @inbounds A[i] = rand(r, $T) + one($T)
        end
        A
    end

    @eval function rand!(r::MersenneTwister, A::Array{$T}, ::SamplerTrivial{CloseOpen01{$T}})
        rand!(r, A, CloseOpen12($T))
        I32 = one(Float32)
        for i in eachindex(A)
            @inbounds A[i] = Float32(A[i])-I32 # faster than "A[i] -= one(T)" for T==Float16
        end
        A
    end
end

#### arrays of integers

function rand!(r::MersenneTwister, A::UnsafeView{UInt128}, ::SamplerType{UInt128})
    n::Int=length(A)
    i = n
    while true
        rand!(r, UnsafeView{Float64}(A.ptr, 2i), CloseOpen12())
        n < 5 && break
        i = 0
        while n-i >= 5
            u = A[i+=1]
            A[n]    ⊻= u << 48
            A[n-=1] ⊻= u << 36
            A[n-=1] ⊻= u << 24
            A[n-=1] ⊻= u << 12
            n-=1
        end
    end
    if n > 0
        u = rand(r, UInt2x52Raw())
        for i = 1:n
            A[i] ⊻= u << (12*i)
        end
    end
    A
end

for T in BitInteger_types
    @eval function rand!(r::MersenneTwister, A::Array{$T}, sp::SamplerType{$T})
        GC.@preserve A rand!(r, UnsafeView(pointer(A), length(A)), sp)
        A
    end

    T == UInt128 && continue

    @eval function rand!(r::MersenneTwister, A::UnsafeView{$T}, ::SamplerType{$T})
        n = length(A)
        n128 = n * sizeof($T) ÷ 16
        rand!(r, UnsafeView{UInt128}(pointer(A), n128))
        for i = 16*n128÷sizeof($T)+1:n
            @inbounds A[i] = rand(r, $T)
        end
        A
    end
end


#### arrays of Bool

# similar to Array{UInt8}, but we need to mask the result so that only the LSB
# in each byte can be non-zero

function rand!(r::MersenneTwister, A1::Array{Bool}, sp::SamplerType{Bool})
    n1 = length(A1)
    n128 = n1 ÷ 16

    if n128 == 0
        bits = rand(r, UInt52Raw())
    else
        GC.@preserve A1 begin
            A = UnsafeView{UInt128}(pointer(A1), n128)
            rand!(r, UnsafeView{Float64}(A.ptr, 2*n128), CloseOpen12())
            # without masking, non-zero bits could be observed in other
            # positions than the LSB of each byte
            mask = 0x01010101010101010101010101010101
            # we need up to 15 bits of entropy in `bits` for the final loop,
            # which we will extract from x = A[1] % UInt64;
            # let y = x % UInt32; y contains 32 bits of entropy, but 4
            # of them will be used for A[1] itself (the first of
            # each byte). To compensate, we xor with (y >> 17),
            # which gets the entropy from the second bit of each byte
            # of the upper-half of y, and sets it in the first bit
            # of each byte of the lower half; the first two bytes
            # now contain 16 usable random bits
            x = A[1] % UInt64
            bits = x ⊻ x >> 17
            for i = 1:n128
                # << 5 to randomize the first bit of the 8th & 16th byte
                # (i.e. we move bit 52 (resp. 52 + 64), which is unused,
                # to position 57 (resp. 57 + 64))
                A[i] = (A[i] ⊻ A[i] << 5) & mask
            end
        end
    end
    for i = 16*n128+1:n1
        @inbounds A1[i] = bits % Bool
        bits >>= 1
    end
    A1
end


### randjump

# Old randjump methods are deprecated, the scalar version is in the Future module.

function _randjump(r::MersenneTwister, jumppoly::DSFMT.GF2X)
    adv = r.adv
    adv_jump = r.adv_jump
    s = MersenneTwister(r.seed, DSFMT.dsfmt_jump(r.state, jumppoly))
    reset_caches!(s)
    s.adv = adv
    s.adv_jump = adv_jump
    s
end

# NON-PUBLIC
function jump(r::MersenneTwister, steps::Integer)
    iseven(steps) || throw(DomainError(steps, "steps must be even"))
    # steps >= 0 checked in calc_jump (`steps >> 1 < 0` if `steps < 0`)
    j = _randjump(r, Random.DSFMT.calc_jump(steps >> 1))
    j.adv_jump += steps
    j
end

# NON-PUBLIC
jump!(r::MersenneTwister, steps::Integer) = copy!(r, jump(r, steps))


### constructors matching show (EXPERIMENTAL)

# parameters in the tuples are:
# 1: .adv_jump (jump steps)
# 2: .adv (number of generated floats at the DSFMT_state level since seeding, besides jumps)
# 3, 4: .adv_vals, .idxF (counters to reconstruct the float cache, optional if 5-6 not shown))
# 5, 6: .adv_ints, .idxI (counters to reconstruct the integer cache, optional)

Random.MersenneTwister(seed, advance::NTuple{6,Integer}) =
    advance!(MersenneTwister(seed), advance...)

Random.MersenneTwister(seed, advance::NTuple{4,Integer}) =
    MersenneTwister(seed, (advance..., 0, 0))

Random.MersenneTwister(seed, advance::NTuple{2,Integer}) =
    MersenneTwister(seed, (advance..., 0, 0, 0, 0))

# advances raw state (per fill_array!) of r by n steps (Float64 values)
function _advance_n!(r::MersenneTwister, n::Int64, work::Vector{Float64})
    n == 0 && return
    n < 0 && throw(DomainError(n, "can't advance $r to the specified state"))
    ms = dsfmt_get_min_array_size() % Int64
    @assert n >= ms
    lw = ms + n % ms
    resize!(work, lw)
    GC.@preserve work fill_array!(r, pointer(work), lw, CloseOpen12())
    c::Int64 = lw
    GC.@preserve work while n > c
        fill_array!(r, pointer(work), ms, CloseOpen12())
        c += ms
    end
    @assert n == c
end

function _advance_to!(r::MersenneTwister, adv::Int64, work)
    _advance_n!(r, adv - r.adv, work)
    @assert r.adv == adv
end

function _advance_F!(r::MersenneTwister, adv_vals, idxF, work)
    _advance_to!(r, adv_vals, work)
    gen_rand(r)
    @assert r.adv_vals == adv_vals
    r.idxF = idxF
end

function _advance_I!(r::MersenneTwister, adv_ints, idxI, work)
    _advance_to!(r, adv_ints, work)
    mt_setfull!(r, Int) # sets r.adv_ints
    @assert r.adv_ints == adv_ints
    r.idxI = 16*length(r.ints) - 8*idxI
end

function advance!(r::MersenneTwister, adv_jump, adv, adv_vals, idxF, adv_ints, idxI)
    adv_jump = BigInt(adv_jump)
    adv, adv_vals, adv_ints = Int64.((adv, adv_vals, adv_ints))
    idxF, idxI = Int.((idxF, idxI))

    ms = dsfmt_get_min_array_size() % Int
    work = sizehint!(Vector{Float64}(), 2ms)

    adv_jump != 0 && jump!(r, adv_jump)
    advF = (adv_vals, idxF) != (0, 0)
    advI = (adv_ints, idxI) != (0, 0)

    if advI && advF
        @assert adv_vals != adv_ints
        if adv_vals < adv_ints
            _advance_F!(r, adv_vals, idxF, work)
            _advance_I!(r, adv_ints, idxI, work)
        else
            _advance_I!(r, adv_ints, idxI, work)
            _advance_F!(r, adv_vals, idxF, work)
        end
    elseif advF
        _advance_F!(r, adv_vals, idxF, work)
    elseif advI
        _advance_I!(r, adv_ints, idxI, work)
    else
        @assert adv == 0
    end
    _advance_to!(r, adv, work)
    r
end
