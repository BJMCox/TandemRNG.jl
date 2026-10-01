# Detached release-battery worker. Run through an owned Kaimon session with:
# julia --threads=4 --project=CHECKOUT release.jl CHECKOUT EVIDENCE MODE [ARGS...]
# TANDEM_TEST_ENV supplies RNGTest, TANDEM_COMMIT names the frozen source revision.
# Freeze release.jl, quick.jl, streams.jl, final.jl, harness.jl, and step.jl together
# in EVIDENCE/tools before launching a campaign. Never edit active helpers.
using Dates
using Libdl
using Random
using SHA
using TOML

const CHECKOUT = abspath(ARGS[1])
const EVIDENCE = abspath(ARGS[2])
const MODE = ARGS[3]
haskey(ENV, "TANDEM_TEST_ENV") && push!(LOAD_PATH, ENV["TANDEM_TEST_ENV"])
using TandemRNG
pkgdir(TandemRNG) == CHECKOUT || error("worker loaded the wrong TandemRNG checkout")

function record(path; fields...)
    mkpath(dirname(path))
    open(path * ".tmp", "w") do io
        TOML.print(io, Dict(string(k) => v for (k, v) in fields); sorted = true)
    end
    mv(path * ".tmp", path; force = true)
end

function provenance()
    paths = [joinpath(CHECKOUT, "Project.toml"), @__FILE__, joinpath(@__DIR__, "quick.jl")]
    for dir in ("src", "design/search"),
        (root, _, files) in walkdir(joinpath(CHECKOUT, dir))

        append!(paths, [joinpath(root, f) for f in files if endswith(f, ".jl")])
    end
    return (
        commit = ENV["TANDEM_COMMIT"],
        julia = string(VERSION),
        threads = Threads.nthreads(),
        machine = Sys.MACHINE,
        sources = Dict(p => bytes2hex(sha256(read(p))) for p in paths),
    )
end

function testu01_protocol(battery, kind, K, reverse)
    lib = Libdl.dlpath(TandemQuick.LIB)
    return (;
        provenance()...,
        battery,
        kind,
        K,
        reverse,
        seed = 42,
        block = TandemQuick.BLOCK,
        library = lib,
        library_sha256 = bytes2hex(sha256(read(lib))),
        reversal = kind == "Float64" ? "reverse raw UInt64 before selecting high 53 bits" :
                   "reverse each UInt32 word",
        diagnostic_tail = 1e-3,
        strong_tail = 1e-10,
    )
end

MODE in ("testu01", "bigcrush-queue") && include(joinpath(@__DIR__, "quick.jl"))

let
    if MODE in ("practrand", "streams")
        include(joinpath(@__DIR__, "streams.jl"))
        tf, te, tlmax = parse.(Int, ARGS[4:6])
        family = MODE == "streams" ? Symbol(ARGS[7]) : :sequential
        seed = MODE == "streams" ? parse(UInt64, ARGS[8]) : UInt64(42)
        Ks = MODE == "streams" ? [parse(Int, ARGS[9])] : [32, 1, 64]
        label = "practrand-tf$tf-te$te-2p$tlmax"
        MODE == "streams" && (label *= "-$family-k$(only(Ks))-seed$seed")
        dir = joinpath(EVIDENCE, label)
        mkpath(dir)
        lock = joinpath(dir, "active")
        # Acquire ownership before changing any evidence. Inspect stale locks explicitly.
        mkdir(lock)
        try
            record(
                joinpath(dir, "status.toml");
                state = "running",
                pid = getpid(),
                started = string(now(UTC)),
            )
            binary = something(Sys.which(TandemFinal.RNG_TEST), TandemFinal.RNG_TEST)
            record(
                joinpath(dir, "protocol.toml");
                provenance()...,
                tf,
                te,
                tlmin = 20,
                tlmax,
                seed = string(seed),
                Ks,
                family = string(family),
                all_results = MODE == "streams",
                executable = binary,
                executable_sha256 = bytes2hex(sha256(read(binary))),
            )
            for K in Ks, case in TandemStreams.cases(family; K, seed)
                result = only(
                    TandemHarness.run_matrix(
                        [case];
                        logdir = dir,
                        tlmax,
                        tf,
                        te,
                        rng_test = binary,
                        all_results = MODE == "streams",
                    ),
                )
                println(result)
                flush(stdout)
                result.verdict == :incomplete && error("incomplete PractRand case: $result")
                # Leave suspicious or failed streams for review before testing further cases.
                result.verdict in (:suspicious, :fail) &&
                    error("PractRand review required: $result")
            end
            record(
                joinpath(dir, "status.toml");
                state = "completed",
                pid = getpid(),
                finished = string(now(UTC)),
            )
        catch err
            record(
                joinpath(dir, "status.toml");
                state = "error",
                pid = getpid(),
                error = sprint(showerror, err),
            )
            rethrow()
        finally
            rm(lock; recursive = true)
        end
    elseif MODE == "testu01"
        battery, kind, Kstr, reversed = ARGS[4:7]
        K, reverse = parse(Int, Kstr), parse(Bool, reversed)
        T = kind == "UInt32" ? UInt32 : Float64
        kind in ("UInt32", "Float64", "xoshiro", "truncated8") ||
            error("unknown feed $kind")
        reverse && kind in ("xoshiro", "truncated8") && error("controls are unreversed")
        battery in ("smallcrush", "bigcrush") || error("unknown battery $battery")
        label = "$battery-$kind-k$K-reverse$reverse"
        dir = joinpath(EVIDENCE, label)
        # RNGTest 1.6.1's initializer uses a wider pointer store. Set this C int correctly.
        unsafe_store!(cglobal((:swrite_Basic, TandemQuick.LIB), Cint), Cint(0))
        rm(joinpath(dir, "exit.toml"); force = true)
        record(
            joinpath(dir, "status.toml");
            state = "running",
            pid = getpid(),
            started = string(now(UTC)),
        )
        try
            record(
                joinpath(dir, "protocol.toml");
                testu01_protocol(battery, kind, K, reverse)...,
            )
            battery_run =
                battery == "smallcrush" ? TandemQuick._smallcrush : TandemQuick._bigcrush
            feed = if kind in ("xoshiro", "truncated8")
                let rng = Xoshiro(42), truncate = kind == "truncated8"
                    () -> truncate ? Float64(rand(rng, UInt8)) * 0x1p-8 : rand(rng)
                end
            else
                TandemQuick.Feed(Stateful(Tandem8x32{K}(42)), T; reverse)
            end
            seconds = @elapsed values = TandemQuick.battery(battery_run, feed, label)
            ccall(:fflush, Cint, (Ptr{Cvoid},), C_NULL)
            expected = battery == "smallcrush" ? 15 : 160
            length(values) == expected ||
                error("expected $expected p-values, got $(length(values))")
            all(p -> isfinite(last(p)) && 0 <= last(p) <= 1, values) ||
                error("invalid p-value")
            open(joinpath(dir, "pvalues.tsv"), "w") do io
                println(io, "ordinal\ttest\tp\tdiagnostic\tstrong")
                for (i, (name, p)) in enumerate(values)
                    println(
                        io,
                        i,
                        '\t',
                        name,
                        '\t',
                        repr(p),
                        '\t',
                        TandemQuick.suspect(p),
                        '\t',
                        p < 1e-10 || p > 1 - 1e-10,
                    )
                end
            end
            strong = count(p -> last(p) < 1e-10 || last(p) > 1 - 1e-10, values)
            record(
                joinpath(dir, "status.toml");
                state = "completed",
                pid = getpid(),
                finished = string(now(UTC)),
                seconds,
                count = length(values),
                diagnostic = count(p -> TandemQuick.suspect(last(p)), values),
                strong,
                pvalues_sha256 = bytes2hex(sha256(read(joinpath(dir, "pvalues.tsv")))),
            )
            # Controls have separate expectations. Completion is not statistical acceptance.
            kind == "truncated8" &&
                strong == 0 &&
                error("defective control was not flagged")
            kind != "truncated8" &&
                strong != 0 &&
                error("strong TestU01 result needs review")
            println("# TandemRelease completed ", label)
            flush(stdout)
        catch err
            ccall(:fflush, Cint, (Ptr{Cvoid},), C_NULL)
            record(
                joinpath(dir, "status.toml");
                state = "error",
                pid = getpid(),
                error = sprint(showerror, err),
            )
            rethrow()
        end
    elseif MODE == "bigcrush-queue"
        kind = ARGS[4]
        kind in ("UInt32", "Float64") || error("unknown queue $kind")
        dir = joinpath(EVIDENCE, "queue-$kind")
        mkpath(dir)
        lock = joinpath(dir, "active")
        # mkdir is atomic. A hard-killed worker leaves this lock for explicit inspection.
        mkdir(lock)
        try
            record(
                joinpath(dir, "status.toml");
                state = "running",
                pid = getpid(),
                started = string(now(UTC)),
            )
            for K in (32, 1, 64), reverse in (false, true)
                label = "bigcrush-$kind-k$K-reverse$reverse"
                case_dir = joinpath(EVIDENCE, label)
                mkpath(case_dir)
                status_file = joinpath(case_dir, "status.toml")
                protocol_file = joinpath(case_dir, "protocol.toml")
                exit_file = joinpath(case_dir, "exit.toml")
                pvalues_file = joinpath(case_dir, "pvalues.tsv")
                log_file = joinpath(case_dir, "worker.log")
                expected_protocol = Dict(
                    string(k) => v for
                    (k, v) in pairs(testu01_protocol("bigcrush", kind, K, reverse))
                )
                if all(
                    isfile,
                    (status_file, protocol_file, exit_file, pvalues_file, log_file),
                )
                    status, protocol, exit_status =
                        TOML.parsefile.((status_file, protocol_file, exit_file))
                    if get(status, "state", "") == "completed" &&
                       get(status, "count", 0) == 160 &&
                       get(status, "strong", -1) == 0 &&
                       get(exit_status, "code", -1) == 0 &&
                       protocol == expected_protocol &&
                       get(status, "pvalues_sha256", "") ==
                       bytes2hex(sha256(read(pvalues_file))) &&
                       occursin("# TandemRelease completed $label", read(log_file, String))
                        continue
                    end
                end
                rm(exit_file; force = true)
                cmd = `$(Base.julia_cmd()) --startup-file=no --threads=4 --project=$CHECKOUT $(@__FILE__) $CHECKOUT $EVIDENCE testu01 bigcrush $kind $K $reverse`
                open(joinpath(case_dir, "worker.log"), "w") do io
                    run(pipeline(cmd; stdout = io, stderr = io))
                end
                record(exit_file; code = 0, finished = string(now(UTC)))
            end
            record(
                joinpath(dir, "status.toml");
                state = "completed",
                pid = getpid(),
                finished = string(now(UTC)),
            )
        catch err
            record(
                joinpath(dir, "status.toml");
                state = "error",
                pid = getpid(),
                error = sprint(showerror, err),
            )
            rethrow()
        finally
            rm(lock; recursive = true)
        end
    else
        error("unknown release mode $MODE")
    end
end
