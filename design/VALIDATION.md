# V2 validation

This record separates completed checks from release qualification. The original campaigns
use cf29af0546eafe9ae7cf8aac9fb8322675e63c4d. Precompilation commit a41c007 changes no RNG
algorithm. The later margin campaign uses 7a6a3f16436464f806263470a458f44f8ba95df7 plus
the frozen analysis patch. All long tests record source hashes and tool versions.
Final campaign results were checked on 2026-09-27.

Commit IDs identify the original development snapshots. The first release uses a
squashed history. Each evidence asset includes its frozen reproduction sources,
so reproduction does not depend on those commits remaining reachable in Git.

## D16 and F23 coverage audit, updated 2026-09-27

The fixed statistical campaigns meet their scheduled depths. This completes the matrix,
while preserving its flagged results and the limits below.

| Requirement | Recorded coverage | Status |
| --- | --- | --- |
| D16 BigCrush | K1/K32/K64, UInt32/Float64, normal/reversed, 12 complete cases | Complete, two mild diagnostics |
| D16 sequential PractRand | K1/K32/K64, 1 TiB each | Complete |
| D16 derived PractRand and D8 depth | 19 cases at 256 GiB expanded and 4 TiB default | Complete, retained flags reviewed below |
| D16 HWD | Sequential and chunk starts, 1 TiB each, plus Philox control | Complete |
| D16 gjrand | Largest 10 TiB tier, all 13 tests | Complete, retained grade-1 results |
| F23 structured screens | 203 cases, each at least 256 MiB | Complete bounded screen |
| F23 cycle and invariant analysis | Full four-bit v2 census and exact production fixed points | Bounded, longer production periods open |
| F23 search/validation separation | Fixed fresh-seed replication matrix and recorded discovery data | Present, deep seed-42 prefixes overlap discovery |
| F23 conformance | Updated v2 vectors and independent UInt64 oracle | Present, independent language ports open |
| D8 statistical round margin | RF2–RF8 diagnostic at 1 GiB; fixed F5–F8 campaign, 72 cases at 256 GiB | Complete bounded campaign, repeated F5 failures |
| D16 dieharder comparison | Paper comparison only | Not run |
| D16 evidence publication | Records archive, structural audit, and margin supplement prepared with hashes and sources | Upload waits for release |

The 203 screens comprise 128 one-bit key pairs, 31 additional bit planes, eight
projections including bit zero, six decimations, three sibling streams, 15 raw-key
cases, and 12 counter cases. Coverage includes continuations after queues stopped
for review. Counting only the first queue outputs would miss completed cases.

These cover the accepted F23 families at the stated depths. They do not exhaust every
axis suggested in the unpublished specification review, such as every within-chunk step, additional word
slices, Gray-code counters, or recursive split trees. Those remain possible follow-ups,
not measurements supplied by this campaign.

The structural audit recovers three original reports: the four-bit cycle histogram,
the F/T diffusion screen, and the exact fixed-point census. These reports and their
reproduction sources are retained with the statistical archive. The separate
`tandemrng-validation-audit-20260926.tar.zst` contains 30 files in 51,512 bytes.
Its SHA-256 is `9108b2a1c91b3c3b6a20604b2304de500b3a3d41131d5333078aa71af6378fef`.
Extraction and all 29 content hashes pass. The histogram covers all 2^32
states in 26 cycles. No cycle of length at most 32 contains a legal reduced stream seed.
Neither production fixed point has a valid stream-domain preimage. Reduced maps are
not quotients of the production map and establish no production period bound.

The frozen core hash differs from current integration sources because the latter
remove the `Word` type bound for Reactant. The operation bodies and constants remain
unchanged. Integration conformance remains separate from frozen statistical evidence.
AMDGPU hardware validation remains deferred by user decision.

## Evidence assets

Three assets are prepared for the first release, totaling 5,736,148 bytes (5.47 MiB).
They contain matrices, protocols, seeds, input hashes, frozen sources, full logs,
flag reviews, and failed attempts. They remain outside Git history.

| Asset | Bytes | Contents |
| --- | ---: | --- |
| `tandemrng-validation-records-cf29af0-20260926.7z` | 4,766,111 | Original statistical campaigns and reproduction sources |
| `tandemrng-validation-audit-20260926.tar.zst` | 51,512 | Structural reports, frozen analysis sources, and coverage audit |
| `tandemrng-validation-margin-7a6a3f1-20260927.7z` | 918,525 | F5–F8 campaign, all 73 cases, and fresh replay preparation |

Each asset has an adjacent `.sha256` file. The selected assets also have a combined
`SHA256SUMS` manifest. Their SHA-256 hashes, in table order, are:

```text
e614efedf891ec2208b16423aab16f60e5febfad6e5a9f072f6e6d0362ee0ce9
9108b2a1c91b3c3b6a20604b2304de500b3a3d41131d5333078aa71af6378fef
dba2040642d9729b280a0d1c22d966fa435aca0a2e32c537b9b7f3a22f3588bf
```

Verify the downloaded assets with `shasum -a 256 -c SHA256SUMS` or GNU
`sha256sum -c SHA256SUMS`. Extract `.7z` files with `7zz x FILE.7z`.
Extract `.tar.zst` with `zstd -dc FILE.tar.zst | tar -xf -`. Then verify each
bundle's internal `SHA256SUMS` from its root and follow its reproduction guide.

The original records archive omits byte samples and compiled binaries, with hashes
and reasons retained. The margin supplement also omits redundant compressed source,
macOS metadata, and private working notes. The frozen checkout remains included.
Full original snapshots remain retained separately. Both compressed margin formats
were extracted and all 367 files verified. Its 7z form is smaller than the 1,092,160-byte
Zstandard alternative. The two earlier selected assets retain their original hashes.

## Completed checks

These counts describe the frozen statistical implementation. Current API conformance
and the added result types are recorded in [the performance audit](search/performance-2026-09-26.md#conformance).

- CPU: 248 checks pass in isolated `Pkg.test()` on Julia 1.13, including 32 validation-feed
  checks. CI passes Julia 1.10, stable, and prerelease on Linux, macOS, and Windows.
- Harness: 87 native callback checks and eight PractRand process checks pass.
- CUDA: 119 tests pass on A100. Cached extension loading and both import orders pass.
- Native SmallCrush: all four K32 feed modes complete, with 15 valid p-values each.
  Xoshiro completes the same control. An eight-bit truncated control triggers 15 strong flags.
- Default PractRand: seed 42, K1/K32/K64 each complete 1 TiB. No suspicious or FAIL
  labels occur at any checkpoint. Earlier unusual flags remain part of the record.
- Expanded PractRand: seed 42, K1/K32/K64 each complete 64 GiB. Six unusual flags occur.
  K64 retains `[Low1/32][C8]DC6-9x1Bytes-1`, p = 1 - 2.5e-4, at its final checkpoint.
  No suspicious or FAIL labels occur in these completed reports.
- Expanded derived streams: all 19 specified cases complete 256 GiB. One split case
  has a FAIL label and four related-key cases have suspicious labels, reviewed below.
- Default derived streams: all 19 specified cases complete 4 TiB with seed 42.
  No FAIL labels occur. One suspicious BCFN result at 8 GiB matches the earlier
  keybit96 discovery on the overlapping prefix, reviewed below. All unusual labels remain.
- HWD: sequential output, chunk starts, and the Philox control each complete 1 TiB.
  Final p-values are 0.44, 0.088, and 0.336. Minimum checkpoint p-values are
  0.0339, 0.0637, and 0.0571. Word counts, exits, and log hashes match.
- Native BigCrush, completed 2026-09-22: all 12 cases finish, with 1,920 p-values,
  zero strong flags, and two mild diagnostics.
  UInt32 K32 reversed has MaxOft t=16, p=0.0005377636768720654.
  Float64 K64 normal has SerialOver r=0, p=0.0008184236356049146.
- gjrand 4.3.0.0, PMCP version 13: the 10 TiB tier completes on 2026-09-22.
  All 13 tests finish. The overall one-sided p-value is 0.588, with verdict `ok`.
  PMCP reports two `grade 1 failures`: `rda`, p=0.0906, and `nda`, p=0.0659.
  It labels this count `probably ok`. The process exits zero, and the
  exact target byte count and recorded output-log hash match.

A clean final checkpoint does not remove earlier flags from the record. Labels from many correlated tests
and checkpoints do not form an independent set of p-values. These results alone do not
qualify v2 for release. All scheduled long runs, including the bounded round-margin
campaign below, are complete. AMDGPU hardware validation is deferred until an AMD
device is available.

## Integration conformance, 2026-09-22

The MLDataDevices binding and PureRNGs/Reactant integration changes retain the v2
stream. These checks run locally on the integration sources, separately from the
frozen statistical campaigns above. They do not consume hosted CI minutes.

| Check | Result |
| --- | --- |
| Tandem CPU, Julia 1.10.12 and 1.13.0 | 341/341 on each, including Aqua |
| PureRNGs core | 16,769/16,769 |
| PureRNGs Distributions extension | 1,200/1,200 |
| Native Reactant, CPU | 123/123 |
| PureRNGs bridge and Reactant, CPU | 31/31 |
| Combined native and bridge conformance, A100 | 334/334 |
| Native and bridge residence checks, Metal | 38/38 |
| Strict docs builds and JuliaFormatter | Pass for both packages |

The A100 run covers CUDA allocation, mismatched destinations, strided views,
scalar calls inside kernels, and Reactant executables reused with different keys
and positions. Automatic CUDA device precompilation passes. Fresh minimal-import
checks also pass for CUDA and Metal. AMD hardware validation remains deferred.

Warm PureRNGs chains of 1,024 draws and single-thread fills of two 1,048,576-element
Float64 arrays allocate zero bytes.
JET 0.12.1 finds no package reports in the checked scalar, addressed, derivation,
stateful, and fill paths. Its fill optimization report encounters a `Base.BottomRF`
reporting bug; filtering that callable exposes three Base task-scheduler reports.
The separate call report has no errors. PProf attributes the sampled computational work to
Tandem's scalar and fill implementation; the bridge inlines. These are inference,
allocation, and profile checks. Throughput comparisons wait for statistical jobs
to finish.

After moving bridge ownership into `TandemRNGPureRNGsExt` (D26), fresh checks pass:
341/341 core checks, 31/31 bridge/Reactant CPU checks, and 68/68 bridge checks on
the A100. Both import orders, extension precompilation, and a Julia 1.10.12 bridge
smoke test pass. Scalar inference and zero-allocation checks also pass. PureRNGs
is restored to its pre-bridge tree. The moved tests retain the residence and
stream contracts above.

## Replication and screen results

The eight fresh-seed default runs complete 1 GiB each: four Tandem K32 runs and four
Philox controls. Both preselected Gap cells have normal labels in all eight runs.
The 16-run expanded matrix completes 64 GiB per case, including a separate continuation
of the early-stop case. One K1 run, seed `8fd2c6c50bc04c45`,
reports `[Low1/32]NS3[5:hw:both]`, p approximately 2.5e-7, labelled suspicious at 128 MiB.
That result shares the NS3 calibration issue below. Two sequential Philox controls
also report short-prefix NS3 flags. They are not matched related-key controls.

The 256 MiB screens retain these results for review:

| Stream | Checkpoint | Test | p | Label |
| --- | --- | --- | --- | --- |
| K1, raw key alternating 0x55 | 128 MiB | `[Low1/32]DC6-9x1Bytes-1` | 1 - 1.9e-4 | mildly suspicious |
| K1, seed 42, bit position 2^62 | 64 MiB | `DC6-9x1Bytes-1` | 1 - 7.8e-5 | mildly suspicious |
| K32, seed 42, interleaved key-bit-11 pair | 64 MiB | `[Low1/32]mod3n(5):(2,9-5)` | 2.1e-5 | mildly suspicious |

The complete 203-case screen reaches 256 MiB per case, including recorded continuations
after family queues stop for review. Nine cases contain mildly suspicious labels: the
three above, bit plane 24, and one-bit pairs 16,27,33,37,114. No screen has a FAIL label.
Split, fork, and subrng sibling screens complete with unusual labels and no suspicious/FAIL
labels. All raw logs remain part of the evidence, including unusual labels in controls.

A fixed follow-up extends the first three cases to 1 GiB once. Their prefixes overlap
discovery data. Separately, it tests the high counter start and key-bit-11 pair with each
of the four fresh seeds, and raw alternating-55 at bit offsets i*2^40 for i=1:4, all to
1 GiB. The latter are disjoint segments of one key, not independent seeds. The three
preselected cells do not recur at a tail distance at most 1e-3 in any of these 12 probes.
One fresh key-bit-11 pair reports a different mildly suspicious Gap-A result at 1 GiB.
It remains part of the review. The sequential Philox controls are not matched related-key
controls. These follow-ups do not establish release qualification.

### Reviewed one-pair NS3 result

Expanded K32 with seed `c3ce597797b53cf5` stops at 1 MiB on
`[Low8/32]NS3[4:pd:both]`: R = 8.2, p approximately 8.7e-17, labelled FAIL.
Replaying the saved bytes reproduces it. The bytes match the independent scalar reference
and agree between ARM and x86. The original FAIL report stays in the record.

Inspection of PractRand 0.96's `NearSeq3` calculation finds exactly two selected cores,
with weights 460 and 460, and one pair. The surrounding blocks have Hamming distances
556 and 556, totaling 1112 of 2048 bits. The score transforms a folded binomial tail and
standardizes it, then reports a normal-tail approximation despite having only one pair.

`design/search/ns3_pair.jl` reconstructs R = 8.2375948027. For one independent pair,
the exact two-sided binomial distance tail is 0.0001091968137. This explains the extreme
reported p-value as a one-sample normal-approximation error. That distance tail is not
a corrected p-value for the whole adaptive test, and does not establish stream quality.
The same NS3 cell has normal labels at 2, 4, 8, and 16 MiB in a fixed prefix extension.
The separate 64 GiB continuation completes and retains the original FAIL.

### Split and related-key NS3 review

The split8 case reports `[Low8/32]NS3[5:pd:both]` at 4 MiB: R=7.3,
p approximately 1.5e-13, FAIL. Saved bytes reproduce the result with the unchanged
PractRand binary. Two selected cores yield one pair with distance 1931/4096.
Exact binomial arithmetic reconstructs R=7.288286001324105 and an independent-pair
tail of 0.0002710186316247191. This is the same one-pair normal-approximation error.

The four related-key primary flags also use very few selected samples:

| Changed key bit | Checkpoint | NS3 samples | Reported p | Independent-score tail |
| --- | --- | --- | --- | --- |
| 64 | 32 MiB | 3 cores | 7.5e-8 | 4.92e-4, Monte Carlo |
| 96 | 32 MiB | 1 core | 8.3e-8 | 2.0506e-3 |
| 0 | 128 MiB | 4 cores | 1.7e-6 | 8.51e-4, Monte Carlo |
| 32 | 1/2/4 MiB | the same core | 2.4e-9 | 1.1559e-3 |

The score is `-log(P(Binomial(n, 0.5) <= min(h, n-h)))`, centered and scaled.
It remains skewed with one sample. Matching its mean and variance does not make its
distribution normal. Reconstructions match the reported R for 15 primary flagged
cell/checkpoint combinations, including sequential Tandem and Philox controls.
The repeated keybit32 flags reuse one core at position 62465, with weight 1098.

The three-core and four-core estimates use one million fixed independent-score draws
with Xoshiro seed `0x4e53335f72657631`. They give 492 and 851 exceedances.
Their Monte Carlo standard errors are approximately 2.2e-5 and 2.9e-5.
These tails describe the independent-score model, not the complete adaptive NS3
procedure or an adjustment for the whole battery. No stream-independence proof follows.

### Separate BCFN review

Keybit96 also reports `[Low1/32]BCFN(0+4,13-3U)` at 8 GiB: R=13.8, p=2.6e-6.
The NS3 diagnosis does not explain this separate test. A focused Low1/32 replay
with the expanded base battery reproduces that score and p-value exactly.

The 4 TiB default-filter campaign retains the same score and p-value at the same
8 GiB prefix, labelled `[Low1/32]BCFN(2+2,13-3U)`: R=13.8, p=2.6e-6, suspicious.
This is its only suspicious label, and no FAIL label occurs through 4 TiB.
Both campaigns use seed 42 and overlapping input prefixes. They do not provide
independent replications of the discovery.

A fixed follow-up tests all four preregistered fresh seeds at 8 and 16 GiB of raw
stream input. Their target p-values are:

| Seed, in preregistered order | 8 GiB | 16 GiB |
| --- | --- | --- |
| 1 | 0.625 | 0.817 |
| 2 | 0.0092 | 0.440 |
| 3 | 0.972 | 0.809 |
| 4 | 0.119 | 0.832 |

None meets the fixed review trigger of p<1e-3 or p>1-1e-3. The four focused runs
have no other suspicious/FAIL labels. All finish with matching log hashes.
This supports an isolated fluctuation and leaves the original flag in the record.

## Margin audit

F6 fails the v2 diffusion screen. F7 passes 4096 bases. F8 passes 16,384 bases.
Those measurements establish diffusion at those sample sizes, not a statistical
round margin. A reduced-round PractRand record must identify its generator, stream,
test depth, first failure, and strongest result. Historical v1 results do not apply.

The fixed [2026-09-22 diagnostic](search/margin-2026-09-22.md) completes 14 runs
of 1 GiB. It varies F from two through eight rounds on chunk starts and a paired-key
XOR probe. RF2–RF4 have failures; RF5–RF8 have no suspicious/FAIL labels at this depth.
RF8 feed checks match production and the independent oracle. Unusual labels remain
recorded. RF6's separate diffusion failure remains.

The fixed [2026-09-27 margin campaign](search/margin-2026-09-27.md) adds 32 discovery
and 40 triggered replication runs, each at 256 GiB. The eight probes cover direct
split halves, high counters, related-key XORs, and chunk starts. Two replication
keys and the stopping rule were fixed before output. Three F5 probes fail on all
three keys and retain FAIL labels at 256 GiB. F6 and F7 each have one mild flag,
which does not recur in the matched cells on other keys. F8 has no suspicious or
FAIL labels in 18 runs. Its 28 unusual labels remain in the record.

The 18 TiB total spans different probes and keys. Each run is capped at 256 GiB.
This closes the agreed bounded margin campaign without claiming a minimum passing
round count or requiring F7 to fail. The dated report records first failures,
strongest reported results, matched comparisons, and reproduction steps.
The separate `tandemrng-validation-margin-7a6a3f1-20260927.7z` asset preserves the
full matrix, logs, protocol, source, input hashes, failed starts, and feed checks.

D8 imposes a separate depth requirement for a one-layer step: at least 2^42 bytes
(4 TiB) on every derived stream. V2 still has one mixing layer per step. Its feedback
removes the known fixed-hidden invariant but does not waive that depth requirement.
All 19 specified derived streams now meet that depth target. This production depth
requirement is separate from the reduced-round campaign's 256 GiB cap per run.
Dieharder remains a comparison-table task, not the strongest gate.

The fixed deeper campaign ran on 2026-09-22–23: the same 19 derived production streams,
seed 42, each reached 4 TiB with default PractRand filters (`-tf 1 -te 0`). All 19 logs
contain completion markers, and all four workers record completion. The last worker
finished on 2026-09-23 at 15:25 UTC. This adds depth to the completed 256 GiB
expanded-filter runs. The prefixes overlap, and all flags remain in the record.

## Fixed replication protocol

The following four seeds came from `RandomDevice`, independently of TandemRNG, before
examining replication output:

```
5ef88bdb8ee22395
3e45c78f3083f6b4
8fd2c6c50bc04c45
c3ce597797b53cf5
```

Interpret each line as a hexadecimal UInt64. Keep seed 42 as discovery data.
For each fresh seed:

1. Test K1/K32/K64 and Philox4x32-10 through 64 GiB with `-tf 2 -te 1`.
2. Test K32 and Philox4x32-10 through 1 GiB with default `-tf 1 -te 0`.

Use PractRand 0.96, `stdin32`, `-tlmin 20`, one checkpoint per doubling, and `-a` to retain
all results. This is 24 runs and 1 TiB + 8 GiB. Record source and executable hashes.
Philox uses the fresh seed's low/high UInt32 words as its key and starts at counter zero.
Its all-zero known-answer vector matches Random123's published vector.

Preserve every result. Review any suspicious/FAIL label, or the same preselected test,
checkpoint, and tail reaching a two-sided tail distance at most 1e-3 in two fresh seeds.
The preselected cells are K32 `[Low8/32]Gap-16:B` at 64 MiB, K32
`[Low8/32]Gap-16:A` at 128 MiB, and the K64 final DC6 cell above. All three target
the upper tail, matching the discovery results.
Compare the corresponding controls. This rule triggers investigation. It is not a combined
significance test or a release acceptance threshold. Complete the fixed matrix without
rerunning cases until their flags disappear.

## Stream coverage

`streams.jl` emits public package draws. Siblings interleave one UInt32 per child, in order.
Split derives children 0:7 once. Fork derives eight children in one call at block 13.
Subrng uses purposes 0:7. Each child then advances independently.

Raw-key cases bypass seed whitening: zero, ones, both alternating patterns, and ascending
words. One-bit pairs differ in one raw-key bit. The full screen covers all 128 bit positions.
The deep matrix fixes boundary bits 0,31,32,63,64,95,96,127 before examining the screen.
Counter cases cross the low-word carry and use high legal group starts.

Projections cover all four words, every bit plane, low bytes, all first-step chunk words,
and same-chunk adjacent-step XOR. Word decimation uses strides 2,3,5,8,17,32 and keeps its
phase across refills. Sibling interleaving and decimation do not accept row projections.
Tests compare these feeds with the independent UInt64 reference across buffer boundaries.

Start with 256 MiB per structured/sibling/projection case. This is a bounded screen.
Use the default battery, seed 42, and K32 for every listed family. Also screen the raw-key
and counter families at K1 and K64. Record all checkpoints and labels.
D16 requires 256 GiB per specified derived stream. Do not label the screen as that gate.

## Reproduction

Use an environment containing TandemRNG and RNGTest for native TestU01. Set
`TANDEM_TEST_ENV` to a separate environment only when needed. Install PractRand's
`RNG_test` on PATH or set `TANDEM_RNG_TEST` to its absolute path.

```
julia --threads=4 --project=CHECKOUT CHECKOUT/design/search/release.jl CHECKOUT EVIDENCE practrand 1 0 40
julia --threads=4 --project=CHECKOUT CHECKOUT/design/search/release.jl CHECKOUT EVIDENCE streams 2 1 36 sequential SEED 32
julia --threads=4 --project=CHECKOUT CHECKOUT/design/search/release.jl CHECKOUT EVIDENCE streams 2 1 36 control SEED 32
julia --threads=4 --project=CHECKOUT CHECKOUT/design/search/release.jl CHECKOUT EVIDENCE streams 1 0 28 siblings 42 32
julia --threads=4 --project=CHECKOUT CHECKOUT/design/search/release.jl CHECKOUT EVIDENCE bigcrush-queue UInt32
```

Set `TANDEM_COMMIT` to the frozen source commit. Use decimal UInt64 seeds in the commands.
Keep separate evidence directories for distinct campaigns. Native BigCrush uses a fresh
process per case. Reuse requires matching protocols, artifact hashes, completion markers,
and successful child exits. Never change sources or helpers in an active campaign.
If helpers live outside `CHECKOUT`, freeze `release.jl`, `quick.jl`, `streams.jl`,
`final.jl`, `harness.jl`, and `step.jl` together in one directory. The worker holds
an atomic directory lock. Inspect a stale lock before removing it.

The native adapter also supports Float64 and reversal of each raw word before conversion.
`check_feeds.jl` checks both native callbacks under GC. TestU01's 0.001 diagnostic band and
1e-10 strong-result rule record evidence and stop for review. They do not prove randomness.
`check_practrand.jl` checks cleanup after a feed error and rejection of an empty feed.

## References

- [PractRand interpretation](https://pracrand.sourceforge.net/Tests_overview.txt)
- [PractRand 0.96 source](https://sourceforge.net/projects/pracrand/files/PractRand_0.96.zip/download)
- [Random123 known-answer vectors](https://github.com/DEShawResearch/random123/blob/main/tests/kat_vectors)
- [Hamming-weight dependency test](https://prng.di.unimi.it/hwd.php)
