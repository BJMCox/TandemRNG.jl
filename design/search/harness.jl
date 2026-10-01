# PractRand harness for the D8 search. Streams the sequential Tandem stream, its derived
# streams, and a constant-multiplier Philox4x32 baseline into `RNG_test stdin32`.
include(joinpath(@__DIR__, "step.jl"))

module TandemHarness

using ..TandemSearch: Config, step, seed, mulwide, O4
using SHA

# Cooperative hooks when running inside a Kaimon session, no-ops elsewhere.
const GATE = isdefined(Main, :KaimonGate) ? Main.KaimonGate : nothing
cancelled() = GATE === nothing ? false : GATE.is_cancelled()
progress(msg) = GATE === nothing ? nothing : GATE.progress(msg)

# --- generators -----------------------------------------------------------------------------

abstract type Gen end

source_paths(::Gen) = [@__FILE__, joinpath(@__DIR__, "step.jl")]

# Tandem sequential stream: chunk c is F(key, c·k) followed by k steps of T, 4 words per step.
mutable struct TandemGen <: Gen
    cfg::Config
    Rf::Int
    k::Int
    key::O4
    domain::UInt32
    aux::UInt32
    chunk::UInt64
end

TandemGen(cfg, Rf, k; key = (0x1, 0x0, 0x0, 0x0), domain = 0x54444d53, aux = 0xa5a5a5a5) =
    TandemGen(cfg, Rf, k, UInt32.(key), UInt32(domain), UInt32(aux), UInt64(0))

steps_per_chunk(g::TandemGen) = g.k

function fill_words!(words::Vector{UInt32}, g::TandemGen)
    n = length(words)
    n % (4 * g.k) == 0 || error("buffer must hold whole chunks")
    i = 1
    @inbounds while i <= n
        o, h = seed(g.key, g.chunk * UInt64(g.k), g.domain, g.aux, g.cfg, g.Rf)
        for _ = 1:g.k
            o, h = step(o, h, g.cfg)
            words[i], words[i+1], words[i+2], words[i+3] = o
            i += 4
        end
        g.chunk += 1
    end
    return words
end

# Philox4x32-R baseline in counter mode, Random123 constants. Validates the harness: a known
# weak round count must fail early, the standard 10 rounds must pass.
mutable struct PhiloxGen <: Gen
    R::Int
    key::NTuple{2,UInt32}
    counter::UInt64
end

PhiloxGen(R; key = (0x1, 0x0)) = PhiloxGen(R, UInt32.(key), UInt64(0))

steps_per_chunk(::PhiloxGen) = 1

const PHILOX_M0 = 0xD2511F53 % UInt32
const PHILOX_M1 = 0xCD9E8D57 % UInt32
const PHILOX_W0 = 0x9E3779B9 % UInt32
const PHILOX_W1 = 0xBB67AE85 % UInt32

@inline function philox4x32(ctr::O4, key::NTuple{2,UInt32}, R::Int)
    c0, c1, c2, c3 = ctr
    k0, k1 = key
    for _ = 1:R
        hi0, lo0 = mulwide(c0, PHILOX_M0)
        hi1, lo1 = mulwide(c2, PHILOX_M1)
        c0, c1, c2, c3 = hi1 ⊻ c1 ⊻ k0, lo1, hi0 ⊻ c3 ⊻ k1, lo0
        k0 += PHILOX_W0
        k1 += PHILOX_W1
    end
    return (c0, c1, c2, c3)
end

function fill_words!(words::Vector{UInt32}, g::PhiloxGen)
    n = length(words)
    n % 4 == 0 || error("buffer must hold whole blocks")
    i = 1
    @inbounds while i <= n
        ctr = (g.counter % UInt32, (g.counter >> 32) % UInt32, UInt32(0), UInt32(0))
        words[i], words[i+1], words[i+2], words[i+3] = philox4x32(ctr, g.key, g.R)
        g.counter += 1
        i += 4
    end
    return words
end

# --- derived streams ------------------------------------------------------------------------

# Each transform maps a buffer of whole chunks (4k words per chunk) to the bytes fed to
# RNG_test. `:sequential` is the identity. The others target one structural risk each.
function transform(words::Vector{UInt32}, stream::Symbol, k::Int)
    if stream === :sequential
        return words
    elseif stream === :chunkstart
        # First step of every chunk: F strength alone.
        return [words[i] for c = 0:(length(words)÷(4k)-1) for i = (4k*c+1):(4k*c+4)]
    elseif stream in (:word0, :word1, :word2, :word3)
        w = Dict(:word0 => 1, :word1 => 2, :word2 => 3, :word3 => 4)[stream]
        return words[w:4:end]
    elseif stream === :xorstep
        # Consecutive steps xored within a chunk, k−1 steps per chunk.
        out = UInt32[]
        sizehint!(out, length(words))
        for c = 0:(length(words)÷(4k)-1)
            base = 4k * c
            for s = 1:(k-1), w = 1:4
                push!(out, words[base+4s+w] ⊻ words[base+4(s-1)+w])
            end
        end
        return out
    elseif stream === :lowbyte
        # Low byte of every word packed four to a word.
        n = length(words) ÷ 4
        return [
            reduce(|, (words[4i+j] & 0xff) << (8 * (j - 1)) for j = 1:4) for i = 0:(n-1)
        ]
    elseif startswith(String(stream), "bit")
        bit = parse(Int, String(stream)[4:end])
        0 <= bit < 32 || error("bit projection must be in 0:31")
        # Earlier source bits occupy the lower bits of each packed word.
        n = length(words) ÷ 32
        return [
            reduce(|, ((words[32i+j] >> bit) & 0x1) << (j - 1) for j = 1:32) for i = 0:(n-1)
        ]
    end
    error("unknown stream $stream")
end

transform(words::Vector{UInt32}, stream::Symbol, g::Gen) =
    transform(words, stream, steps_per_chunk(g))

# --- runner ---------------------------------------------------------------------------------

"""
    run_practrand(g, stream; tlmax = 36, tlmin = 20, log, rng_test = "RNG_test", chunks_per_block, tf = 1, te = 0)

Feed `g` through `stream` into `RNG_test stdin32` up to 2^tlmax bytes. RNG_test's report is
written to `log` and returned. Cooperative with Kaimon: reports progress every 2^30 bytes and
stops at cancel_eval.
"""
function run_practrand(
    g::Gen,
    stream::Symbol;
    tlmax::Int = 36,
    tlmin::Int = 20,
    log::AbstractString = tempname() * ".practrand.txt",
    rng_test::AbstractString = "RNG_test",
    chunks_per_block::Int = 4096,
    multithreaded::Bool = true,
    tf::Int = 1,
    te::Int = 0,
    all_results::Bool = false,
)
    # PractRand defaults are -tf 1 -te 0. The expanded set (-tf 2 -te 1) costs 15 to 25x on
    # batserv01 (64 MB: 0.9 s against 10.4 s single-threaded), so it is for the release gate.
    k = steps_per_chunk(g)
    args = [
        rng_test,
        "stdin32",
        "-tlmin",
        string(tlmin),
        "-tlmax",
        string(tlmax),
        "-tf",
        string(tf),
        "-te",
        string(te),
    ]
    multithreaded && push!(args, "-multithreaded")
    all_results && push!(args, "-a")
    words = Vector{UInt32}(undef, 4 * k * chunks_per_block)
    # Reject empty-output configurations before starting a child process.
    fill_words!(words, g)
    data = transform(words, stream, g)
    isempty(data) && error("stream produces no test input")
    total = 0
    next_report = 1 << 30
    successful = open(log, "w") do io
        proc = open(pipeline(Cmd(args); stdout = io, stderr = io), "w")
        aborted = true
        cancelled_run = false
        try
            while process_running(proc)
                if cancelled()
                    cancelled_run = true
                    progress("cancelled after $(total >> 20) MiB")
                    break
                end
                try
                    write(proc, data)
                catch e
                    # RNG_test closes stdin after its target or an early failure.
                    e isa Base.IOError || rethrow()
                    break
                end
                total += sizeof(data)
                if total >= next_report
                    progress("$(stream): 2^$(round(log2(total); digits = 1)) bytes fed")
                    next_report *= 2
                end
                fill_words!(words, g)
                data = transform(words, stream, g)
            end
            aborted = false
        finally
            close(proc.in)
            (aborted || cancelled_run) && process_running(proc) && kill(proc)
            wait(proc)
        end
        return success(proc) && !cancelled_run
    end
    report = read(log, String)
    complete = successful && occursin("(2^$tlmax bytes)", report)
    open(log, "a") do io
        println(
            io,
            complete ? "\n# TandemHarness completed 2^$tlmax bytes" :
            "\n# TandemHarness incomplete",
        )
    end
    return read(log, String)
end

"""
    run_matrix(cases; logdir, tlmax, rng_test, kwargs...) -> Vector{NamedTuple}

Run each `(name, gen, stream)` case in order, log to `logdir/<name>.txt`, and return the
worst verdict per case: `:fail`, `:suspicious`, `:unusual`, `:pass`, or `:incomplete`.
Reuse requires a completed log and matching protocol, source, executable, and initial state.
An incomplete case restarts from the supplied generator's initial state.
"""
function run_matrix(
    cases;
    logdir::AbstractString,
    tlmax::Int = 36,
    rng_test::AbstractString = "RNG_test",
    tlmin::Int = 20,
    tf::Int = 1,
    te::Int = 0,
    multithreaded::Bool = true,
    kwargs...,
)
    mkpath(logdir)
    results = NamedTuple[]
    for (name, gen, stream) in cases
        cancelled() && break
        log = joinpath(logdir, string(name, ".txt"))
        binary = isfile(rng_test) ? rng_test : something(Sys.which(rng_test), rng_test)
        protocol = repr((;
            julia = VERSION,
            stream,
            generator = repr(gen),
            tlmin,
            tlmax,
            tf,
            te,
            multithreaded,
            kwargs,
            sources = [bytes2hex(sha256(read(p))) for p in source_paths(gen)],
            executable = bytes2hex(sha256(read(binary))),
        ))
        metadata = log * ".protocol"
        prior = isfile(log) ? read(log, String) : ""
        report =
            if isfile(metadata) &&
               read(metadata, String) == protocol &&
               occursin("# TandemHarness completed 2^$tlmax bytes", prior)
                prior
            else
                progress("matrix: starting $name")
                # Invalidate before replacing the log, including interruption before the
                # new protocol is written after completion.
                rm(metadata; force = true)
                result = run_practrand(
                    deepcopy(gen),
                    stream;
                    tlmax = tlmax,
                    tlmin = tlmin,
                    tf = tf,
                    te = te,
                    multithreaded = multithreaded,
                    log = log,
                    rng_test = rng_test,
                    kwargs...,
                )
                write(metadata, protocol)
                result
            end
        w = worst_verdict(report)
        push!(results, (name = name, verdict = w.verdict, at = w.at))
    end
    return results
end

function worst_verdict(report::AbstractString)
    rank = Dict(:pass => 0, :unusual => 1, :suspicious => 2, :fail => 3)
    worst, at = :pass, ""
    for v in verdicts(report)
        for f in v.flags
            level =
                occursin("fail", lowercase(f)) ? :fail :
                occursin("suspicious", lowercase(f)) ? :suspicious : :unusual
            if rank[level] > rank[worst]
                worst, at = level, v.length
            end
        end
    end
    complete = occursin(r"(?m)^# TandemHarness completed 2\^\d+ bytes$", report)
    return (verdict = complete || worst === :fail ? worst : :incomplete, at = at)
end

"""
    verdicts(report) -> Vector{NamedTuple}

One entry per tested length: the length line and every test line flagged unusual,
suspicious, or FAIL. An empty `flags` vector means "no anomalies" at that length.
"""
function verdicts(report::AbstractString)
    out = NamedTuple{(:length, :flags),Tuple{String,Vector{String}}}[]
    current = nothing
    flags = String[]
    for line in eachline(IOBuffer(report))
        if occursin("length=", line)
            current === nothing || push!(out, (length = current, flags = flags))
            current = strip(line)
            flags = String[]
        elseif occursin(r"unusual|suspicious|fail"i, line)
            push!(flags, strip(line))
        end
    end
    current === nothing || push!(out, (length = current, flags = flags))
    return out
end

end # module
