# Overall assessment

**Tandem8x32 is an interesting bulk-oriented, pure PRNG design, but the current specification and evidence do not yet justify treating it as a replacement for Philox or Threefry.**

Its strongest idea is the separation between:

* a relatively expensive 256-bit initialization permutation `F`, and
* a much cheaper recurrent permutation `T`, amortized over a chunk.

That could produce excellent throughput for long CPU/GPU fills. The eight-lane row layout is also thoughtfully matched to SIMD and coalesced GPU stores.

The central risk is that almost all generated blocks are separated by only **one application of a lightly analysed `T`**, whose hidden half evolves autonomously. Eight-round avalanche in `F` does not compensate for weaknesses in the long `T` trajectory. The statistical and structural burden therefore rests primarily on `T` and `clock`, not on `F`.

My verdict would be:

* **Specification quality:** promising, but several claims and edge cases need correction.
* **Ergonomics:** pure and thread-safe, but not a true block-level CBRNG; it is a chunked stateful generator with bounded random access.
* **Performance prospects:** potentially excellent for bulk generation, especially GPUs; more mixed on CPUs because it still requires multiply-high.
* **Statistical confidence:** insufficiently established from the specification.
* **Cryptographic strength:** should explicitly be disclaimed.
* **Production readiness:** experimental pending substantially more analysis, testing, and independent review.

---

# 1. What the design does well

## 1.1 It has a genuinely pure transport representation

Representing a generator by:

```text
(key, K, byte_position)
```

is clean. It supports:

* Immutable APIs.
* Thread-safe copies.
* Serialization and checkpointing.
* Deterministic replay.
* Reconstruction of working state.
* CPU/GPU portability.
* Indexed splitting independent of mutable parent state.

This satisfies functional-programming purity even though the efficient implementation caches recurrent state.

## 1.2 The bulk layout is carefully engineered

The eight-lane row interleaving is a good systems design.

On a GPU:

* One logical thread owns one chunk.
* A group of eight threads emits the eight adjacent 16-byte blocks of a row.
* Each thread carries only one 256-bit state rather than all eight lanes.
* Stores can be naturally coalesced.

On a CPU:

* Eight chunks can be represented as structure-of-arrays vectors.
* Each state word becomes one eight-lane vector under AVX2.
* Lane-independent products and clock operations vectorize.
* The output is already arranged for contiguous stores.

This is more thoughtful than specifying only a scalar generator and hoping ports discover the same transposition.

## 1.3 The initialization map is injective before truncation

`F` is a permutation if `T` is a permutation, since the round constant addition and half swap are also bijections.

Consequently, distinct complete inputs

```text
(counter, domain, aux, key)
```

map to distinct complete 256-bit `F` outputs. That is useful. It means chunk initial states cannot be identical when their complete initialization tuples differ.

This does **not** imply that:

* exposed halves cannot collide,
* child keys cannot collide,
* trajectories cannot occupy the same permutation cycle, or
* streams are statistically independent,

but it is still a good foundational property.

## 1.4 The specification fixes important portability details

The explicit definitions of:

* word width,
* overflow,
* byte order,
* rotate direction,
* product halves,
* signed reinterpretation,
* float construction, and
* test vectors

are all valuable. They avoid many cross-language reproducibility failures.

The float mappings are conventional exact power-of-two mappings and should be reproducible if implementations avoid accidentally introducing alternate rounding expressions.

## 1.5 The splitting API recognizes different use cases

The distinction between:

* position-independent indexed splitting,
* position-dependent forking,
* purpose/domain derivation, and
* seed whitening

is useful. In particular, having `split(i)` depend only on the key avoids a common defect where adding a random draw changes every subsequently derived child.

---

# 2. Tandem is not quite in the same category as Philox

The specification presents a pure indexed byte stream, but internally Tandem is not a direct block CBRNG of the form

\[
B_i = G_K(i).
\]

Instead, it is approximately:

\[
S_c = F_K(c),\qquad
B(c,j)=\operatorname{exposed}(T^{j+1}(S_c)).
\]

This has important consequences.

## 2.1 Random access is bounded but not constant-cost

Access to a block costs:

* one `F`,
* plus between 1 and `K` applications of `T`.

For fixed maximum `K ≤ 65536`, this is technically bounded, but not comparable to Philox’s constant-cost direct indexing. With `K = 65536`, an unlucky random access requires tens of thousands of serial state transitions.

At the default `K = 32`, this may be entirely acceptable. It should nevertheless be described as **chunked random access**, not simply random access.

## 2.2 Performance depends strongly on access pattern

The design should be excellent when:

* generating large contiguous fills,
* consuming most or all of each chunk,
* mapping one chunk to each GPU work-item,
* amortizing `F` over many `T` steps.

It is less attractive when:

* drawing a few values from many independent generators,
* repeatedly seeking,
* using highly sparse coordinates,
* rejection sampling causes irregular access,
* a kernel needs only one random block per logical item.

Philox’s cost is almost independent of those patterns. Tandem’s headline throughput should therefore be reported separately for:

1. large aligned fills,
2. steady-state sequential scalar draws,
3. cold one-block draws,
4. random block access,
5. split-then-one-draw workloads.

## 2.3 `K` changes the semantic stream

This is a significant ergonomic difference.

Changing `K` for performance tuning changes which chunk supplies later rows, and therefore changes the random stream. That means `K` is not merely an implementation parameter; it is part of the algorithm identity.

I recommend one of two approaches:

### Preferred: fix a canonical `K`

Specify something like:

```text
Tandem8x32-K32-v1
```

with `K = 32` normative. Other values become separately named variants.

### Alternative: retain variable `K`, but make the identity explicit

Transport and metadata should identify:

```text
algorithm = Tandem8x32
version   = 1
K         = 32
```

Saying "`K` is part of the type" is adequate inside Julia but not sufficient for language-neutral files, RPC protocols, databases, or model checkpoints.

A user should not obtain different scientific results merely because an implementation chooses a larger chunk for a different GPU.

---

# 3. Review of `T`

## 3.1 The permutation argument appears correct

The clock’s sequential xor-rotate assignments are individually invertible, as is the final addition. They can be inverted in reverse order:

1. subtract the constant from `h0`,
2. undo the `h3` update using recovered `h0`,
3. undo `h2`,
4. undo `h1`,
5. undo the original `h0`.

For fixed `h`, `mix` is also invertible:

* `h1 | 1` is odd, so multiplication by it modulo \(2^{32}\) is invertible.
* The second output word determines `lo(c·(h1|1))`, hence `c`.
* The first then determines `b`.
* Similarly, the fourth determines `a`, and the third determines `d`.

Therefore `T` is a permutation of the 256-bit state.

## 3.2 “Affine bijection” is not the right description

This sentence should be corrected:

> `clock` is an affine bijection of the hidden half

The xor/rotation part is linear over the vector space \(GF(2)^{128}\). Addition of `0x9e3779b9` modulo \(2^{32}\) is not a translation under that same xor-vector-space operation because of carries. Conversely, the xor-rotate map is not generally linear over the \(\mathbb Z/2^{32}\mathbb Z\) module structure.

The safe statement is:

> `clock` is a bijection: it is the composition of invertible xor-rotate updates and an invertible modular translation.

Unless a specific algebraic structure is defined under which the whole map is affine, “affine” is misleading.

## 3.3 The autonomous hidden clock is the main structural concern

The hidden state evolves as:

\[
h_{n+1}=\operatorname{clock}(h_n),
\]

independently of `o`. The full system is therefore a skew product:

\[
(o_{n+1},h_{n+1})
=
(\operatorname{mix}(o_n,h_n),\operatorname{clock}(h_n)).
\]

This is much easier to analyse or attack than a fully coupled 256-bit permutation. It has several implications.

### Hidden evolution receives no feedback from exposed state

No matter how nonlinear `mix` is, it cannot improve the period or structural quality of the hidden driver.

### The period of `clock` becomes especially important

Showing that `clock` is bijective does not show that it has a long cycle. A permutation can contain many short cycles.

The specification needs evidence about:

* fixed points,
* short cycles,
* cycle lengths,
* invariant subsets,
* weak differences,
* behaviour from low-Hamming-weight states,
* behaviour of reduced word-size analogues,
* whether any usable lower bound on period can be established.

### Statistical testing of `F` avalanche does not address this

Every chunk begins with a scrambled hidden value, but then takes up to `K` consecutive steps under the autonomous clock. Any recurring or low-complexity property of that sequence can appear in all chunks.

I would regard period and invariant analysis of `clock` as a release blocker.

## 3.4 The output transition is extremely light

One `T` step uses only two data-dependent 32×32→64 products for a 128-bit output block. At `K = 32`, including eight initialization rounds, the amortized count is approximately:

\[
2\frac{K+8}{K}=2.5
\]

wide products per 128-bit block, ignoring child derivation and boundary effects.

That is the source of the promising performance, but it also means the design is relying on very little nonlinear work between adjacent exposed blocks.

The key question is not whether eight rounds of `F` avalanche well. It is whether sequences of:

```text
exposed(T(S)), exposed(T²(S)), exposed(T³(S)), ...
```

are robust when every intermediate exposed half is emitted.

A permutation that is an adequate round function inside an eight-round construction is not automatically an adequate output transition after one round.

## 3.5 Multiplication by `h | 1` has useful invertibility but special cases

Making the multiplier odd is mathematically clean. Nevertheless, the design should specifically test:

* multiplier `1`,
* multipliers near `1`,
* low-Hamming-weight multipliers,
* multipliers with repeated byte patterns,
* multipliers with long runs of zero or one,
* hidden states for which either multiplier remains weak over adjacent steps.

When `h0` or `h1` is zero, the corresponding multiplier is exactly one, reducing that branch to little more than copies, xor, and rotation. `F` may make such hidden values rare in ordinary use, but a public noncryptographic permutation should not rely solely on their rarity without testing structured and adversarial keys.

## 3.6 Diffusion should be reported by output position and time lag

The relevant avalanche measurements include:

* Each input bit of `o` and `h` against each output bit after one `T`.
* After 2, 3, 4, and 8 consecutive `T` steps.
* Differences in the counter, key, domain, and auxiliary word after `F`.
* Adjacent counters after `F`, then after the first emitted `T`.
* Correlations between block \(n\) and blocks \(n+1,n+2,\ldots\).
* Each of the four exposed words separately.
* Only high halves, only low halves, and low output bits.
* Lane-transposed and row-concatenated streams.

An aggregate “avalanche score” can hide weak word-to-word or bit-to-bit paths.

---

# 4. Period and stream separation

## 4.1 No useful period guarantee is currently stated

`T` being a permutation means every complete state is on a cycle. It does not establish:

* a period near \(2^{256}\),
* a minimum period of \(2^{128}\),
* a minimum period exceeding `K`,
* or even absence of small cycles for reachable initialized states.

Because `h` evolves autonomously, start with the cycle structure of `clock`. If `clock` has period \(L\) from a particular hidden state, the exposed dynamics are periodically driven with period \(L\). The full state may still have a larger period, but that requires separate analysis.

At minimum, the release documentation should avoid implying a 256-bit period merely because the state is 256 bits.

## 4.2 Distinct chunk initial states do not prove disjoint trajectories

Since `F` is a permutation, distinct initialization inputs produce distinct initial full states. However, two distinct states of a permutation can lie on the same cycle at different offsets.

For practical finite chunks, accidental overlap may be negligibly likely if `T` behaves like a random permutation. But that is a heuristic, not a theorem supplied by the construction.

Document the intended guarantee precisely:

> Different initialization tuples produce different initial full states. No claim is made that their subsequent state trajectories or exposed blocks are mathematically disjoint.

That would be accurate.

## 4.3 Domain separation is syntactic, not yet pseudorandom separation

The distinct domain words make the complete inputs to `F` different under the same key. That is good domain encoding.

The statement:

> The domain words keep chunk seeds and the four derivation families disjoint under one key.

is too strong if “disjoint” refers to outputs. They keep the **input namespaces** disjoint. They do not prove disjoint output halves or statistically independent families.

Suggested wording:

> The distinct domain words give the initialization and derivation families disjoint input encodings under a fixed key. Output halves may collide, and statistical independence depends on the mixing quality of `F`.

## 4.4 The child-key birthday statement is conditional

This statement:

> Child keys collide at the birthday rate over 128 bits.

is a design expectation, not a proved property. Since child keys are truncated halves of a fixed public permutation, birthday-like behaviour requires those halves to act like pseudorandom 128-bit functions over the relevant input families.

Use:

> If the selected halves of `F` behave as pseudorandom 128-bit outputs, child-key collisions occur at the usual 128-bit birthday scale. No collision-freedom is guaranteed.

That distinction matters, particularly because split siblings expose both halves of a single `F` output.

---

# 5. Review of `F` and key derivation

## 5.1 Eight rounds may be enough, but avalanche alone is insufficient

`F` alternates the role of the two halves, so both halves are eventually subjected to `clock` and `mix`. That is sensible.

Still, eight rounds need justification against more than average avalanche:

* Related counters.
* Related keys.
* Related domains.
* Truncated output.
* Both output halves.
* Differential trails.
* Rotational relations.
* Fixed or slowly varying multipliers.
* Meet-in-the-middle structure caused by alternating halves.
* Symmetries created by swap plus round constants.
* Inverse-direction properties.

Because `F` is also the key derivation function, weaknesses in truncated outputs matter even if stream initialization remains acceptable.

## 5.2 Round constants need a reproducible provenance

The constants appear search-selected. That is not automatically bad, but it raises two concerns:

1. selection bias from optimizing against a finite test set;
2. inability for reviewers to distinguish principled constants from hidden tuning.

The design record should specify:

* the candidate generation procedure,
* the objective function,
* rejected candidates,
* whether statistical suites were used during selection,
* whether final validation data were kept separate from search data,
* and why eight constants are sufficient.

Ideally, constants should be generated from a simple reproducible process, with search limited to structural constraints rather than optimizing directly against PractRand.

## 5.3 Seed whitening is not a cryptographic KDF

The term “whitening” is reasonable, but document that it:

* does not increase seed entropy,
* does not make small seeds secret,
* does not provide password hashing,
* and is not guaranteed to resist inversion or related-seed analysis.

Because `F` is a public permutation and only half its output is retained, inversion from the 128-bit key is not trivially unique, but that is not a security argument.

## 5.4 Splitting both halves is economical but needs dedicated tests

For:

```text
split(2q)   = exposed half of F(...)
split(2q+1) = hidden half of F(...)
```

an ideal 256-bit permutation would make the pair behave well. In this concrete design, however, sibling keys are exactly the two internally related halves after eight rounds.

Test explicitly:

* sibling stream cross-correlations,
* sibling key xor and modular differences,
* recursively split trees,
* streams under `split(2q)` versus `split(2q+1)`,
* the same tests for fork siblings,
* and whether one child key helps predict distinguishable properties of the other.

A more conservative derivation would use a separate `F` invocation per child. That doubles derivation cost but makes the API less dependent on both halves being jointly pseudorandom. Since splitting usually occurs far less often than drawing, the cost may be acceptable.

## 5.5 Consider a stronger control-plane KDF

A practical conservative option is:

* Tandem for bulk generation.
* BLAKE3, ChaCha, or AES-based derivation for keys and purpose labels.

That would complicate the standalone specification, but key derivation is not usually performance-critical. If the goal is an extremely small all-in-one primitive, retaining `F` is defensible, but it then needs stronger truncated-permutation analysis.

---

# 6. Fork semantics need clarification

The current text defines child `i` from the parent’s current block and then says:

> The parent moves to position `(b + 1) · 16`.

This is ambiguous for repeated API calls.

Suppose the caller performs:

```text
fork(parent, 0)
fork(parent, 1)
```

If the first call advances the parent, the second child is derived from a different `b`. They are not the two halves of the same `F` result.

Clarify whether the primitive operation is:

```text
fork(parent, count) -> (children, advanced_parent)
```

where all `children[i]` use the same original `b`, or:

```text
fork(parent, i) -> (child, advanced_parent)
```

where every call consumes a block and therefore changes `b`.

I recommend specifying a batch operation:

```text
fork(parent, n)
```

* Capture `b = position >> 4`.
* Derive children `0 ... n-1` using that `b`.
* Advance the parent once to `(b+1)·16`.

Then define any single-child operation as `fork(parent, 1)`.

Also specify what happens when the parent is exactly block-aligned:

* Does forking consume the entire block beginning at `p`?
* That appears to be the current intent, but it should be explicit.

---

# 7. Draw and stream semantics

## 7.1 The alignment rule is deterministic but surprising

A heterogeneous sequence such as:

```text
UInt8
UInt64
UInt8
```

discards up to seven bytes before the `UInt64`. This is legitimate, but users may expect a random stream to be packed rather than naturally aligned.

Document prominently that:

* changing draw types changes byte consumption,
* alignment gaps are skipped permanently,
* a typed fill equals repeated draws of the same type,
* but reinterpretation of an untyped byte fill need not equal a heterogeneous draw sequence.

## 7.2 Bool consumes eight random bits but uses one

This is acceptable and preserves the one-byte type size, but it is worth calling out. It also means:

* `fill(Bool, n)` consumes `n` bytes,
* not \(\lceil n/8\rceil\) bytes,
* and only the lowest bit of each byte is tested.

Low-bit quality is therefore particularly important. Test the stream formed solely from bit 0 of every output byte and, separately, bit 0 of each word.

## 7.3 Floating-point wording should constrain implementation

For strict reproducibility, specify the operation conceptually as exact scaling of an integer by a power of two. Implementations should not use alternate mappings such as:

* constructing a `[1,2)` mantissa and subtracting one unless proven identical,
* division by `2^53` using a lower-precision intermediate,
* inclusive-one mappings,
* or conversion through signed integers.

It may be helpful to add reference pseudocode and hexadecimal floating-point test values.

## 7.4 End-of-stream behaviour is underspecified

The stream has \(2^{64}\) bytes, but alignment and fill arithmetic can exceed it.

For example:

```text
p' = (p + s - 1) & ~(s - 1)
```

will wrap if performed in 64-bit arithmetic near \(2^{64}\).

The constructor restriction `position < 2^63` does not fully define later behaviour. Specify:

* arithmetic is mathematically unbounded for checking purposes;
* a draw is valid only if `p' + s ≤ 2^64`;
* a fill is valid only if `p' + s·n ≤ 2^64`;
* advancing beyond the end throws, traps, or returns an explicit exhaustion result;
* transport forms at exactly `2^64` are either allowed as exhausted states or forbidden.

“No exhaustion check is required of the hot path” is an implementation note, not semantic behaviour. A refill boundary can check that enough range remains before entering the hot loop.

## 7.5 The `position < 2^63` constructor restriction needs rationale

If positions are unsigned 64-bit values and the stream is \(2^{64}\) bytes, excluding the upper half is surprising.

If this restriction exists to simplify signed host-language indexing, say so. Otherwise, either:

* support the complete range, or
* define the stream as only \(2^{63}\) constructible bytes plus possible forward traversal.

At present, “the stream holds \(2^{64}\) bytes” and “construction below \(2^{63}\)” feel inconsistent.

---

# 8. Performance assessment

## 8.1 GPU prospects are strong

The arithmetic is attractive for contemporary GPUs:

* two 32-bit low products,
* two 32-bit high products,
* xor,
* rotates,
* a small hidden-state update,
* eight 32-bit state words per work-item.

The row layout should support coalesced stores without shared memory. Compared with Philox4x32-10, the amortized nonlinear instruction count could be much lower.

Important measurements include:

* register count after compilation,
* occupancy,
* instructions per block,
* integer multiply-pipe utilization,
* store throughput,
* chunk-boundary overhead,
* partial fills,
* one-block-per-thread kernels,
* and performance under divergent consumption.

The actual generated machine code matters. A source-level “two 64-bit products” may become four or more instructions, though that is still likely favorable relative to ten Philox rounds.

## 8.2 CPU prospects are less straightforward

The design still requires both halves of unsigned 32×32→64 products.

On x86:

* low 32-bit vector multiplication is easy with `VPMULLD`;
* unsigned high-half 32-bit multiplication is less convenient;
* AVX2 generally needs `VPMULUDQ` on alternating lanes plus shuffling or separate handling of odd lanes;
* AVX-512 capabilities vary by subset and may still require nontrivial lane handling.

This is precisely one of Philox’s main CPU weaknesses. Tandem uses far fewer products, so it may still win decisively, but the primitive is not as universally cheap as the notation suggests.

On ARM NEON and SVE, widening multiply and high-half extraction may be more natural in some formulations, but packing and lane organization still need measurement.

Benchmark against:

* optimized vector Philox, not only scalar Random123 headers;
* Threefry;
* Squares;
* AES-CTR with hardware AES;
* ChaCha8;
* xoshiro or LXM for stateful throughput context.

## 8.3 Scalar working state is relatively large

An efficient row-oriented scalar generator may cache eight complete lane states:

\[
8 \times 8 \times 4 = 256\ \text{bytes}.
\]

Under AVX2 this maps elegantly to eight YMM registers in a structure-of-arrays representation. In truly scalar code it is a substantial working state, especially if several generators are live.

Measure:

* compiler spills,
* cost of copying immutable generator values,
* context-switch/cache behaviour,
* cold initialization,
* and performance when only one lane’s block is consumed.

The compact 24-byte transport form should not be confused with the hot working-state footprint.

## 8.4 `K = 32` seems plausible, but should be justified quantitatively

There are competing effects:

* Larger `K` amortizes `F`.
* Larger `K` worsens random-access latency.
* Larger `K` lengthens exposure to one `T` trajectory.
* Larger `K` increases possible wasted work for partial chunks.
* Smaller `K` changes chunk-boundary frequency and stream mapping.

Publish throughput and latency curves for at least:

```text
K = 1, 2, 4, 8, 16, 32, 64, 256, 65536
```

Statistical testing should also cover the maximum `K`, since that places the greatest reliance on repeated `T`.

---

# 9. Statistical and structural validation required

PractRand alone is not enough, particularly for a searched construction.

## 9.1 Standard batteries

Run at least:

* TestU01 SmallCrush, Crush, and BigCrush.
* PractRand to multi-terabyte scales.
* gjrand.
* Hamming-weight dependency tests.
* Linear-complexity and binary-rank tests beyond their standard battery appearances.

Report all suspicious p-values, not only an overall pass/fail label.

## 9.2 Output projections

Test separately:

* Each of `o0`, `o1`, `o2`, and `o3`.
* Low 8 and high 8 bits of each word.
* Low 16 and high 16 bits.
* Bit 0 of every byte, because `Bool` uses it.
* Every individual bit plane.
* `hi ⊕ lo` and adjacent-word xor combinations.
* Forward and reversed streams.
* Every other word and every fourth word.
* Each GPU lane/chunk separately.
* The row-concatenated stream.
* The untransposed chunk streams.

A generator can pass when all words are interleaved while one output position is weak.

## 9.3 Time-decimated streams

Test:

\[
B(c,j), B(c,j+d), B(c,j+2d),\ldots
\]

for various `d`, especially powers of two and values related to possible clock structure.

Also test fixed step positions across chunks:

```text
B(0,j), B(1,j), B(2,j), ...
```

for every `j` of interest. This directly targets relations created by nearby counters under the same number of transitions.

## 9.4 Key and counter families

Use:

* all-zero key,
* all-one key,
* one-hot keys,
* low-Hamming-weight keys,
* repeated-word keys,
* arithmetic progressions,
* keys differing by one bit,
* sequential counters,
* counters differing in high bits only,
* sparse counters,
* Gray-code counters,
* and selected weak multiplier states.

Seed 42 is useful as a conformance vector, not as meaningful evidence.

## 9.5 Split-tree tests

Generate and interleave output from:

* sequential split children,
* even and odd sibling pairs,
* deep binary split trees,
* purpose-derived children,
* fork children,
* children from related parent keys.

Test matrices in which rows are streams and columns are corresponding output positions. Cross-stream weaknesses are often missed by testing each stream independently.

## 9.6 Reduced-width exhaustive analysis

Construct exact analogues with word widths such as 4, 5, 6, 7, and 8 bits, scaling rotations and constants according to a documented rule.

Exhaustively examine:

* clock cycle distributions,
* complete `T` cycle distributions,
* fixed points,
* short cycles,
* invariant subsets,
* differential transitions,
* output-period distributions,
* and whether analogous weak structures persist across widths.

Reduced-width results do not prove the 32-bit design, but they are especially informative for a novel permutation with an autonomous substate.

## 9.7 Search/validation separation

If `SEARCH.md` records a search over structures or constants, final evidence should use tests not used as the search objective.

Otherwise the process risks overfitting to:

* avalanche metrics,
* a particular PractRand length,
* selected keys,
* selected output orderings,
* or selected rotation combinations.

Publish the number of candidates tried. A result selected from millions of candidates requires more stringent holdout validation than one derived analytically.

---

# 10. Cryptographic status

The specification should contain an explicit statement near the beginning:

> Tandem8x32 is a noncryptographic pseudorandom number generator. It is not intended for key generation, encryption, authentication, nonce generation where unpredictability is required, password processing, or adversarially observable randomness.

At present, terms such as “key,” “domain,” “hidden,” and “seed whitening” may lead users to infer security.

Reasons not to claim cryptographic strength include:

* only one light transition between emitted blocks,
* autonomous hidden evolution,
* full exposure of half the state each step,
* unestablished resistance to state recovery,
* unestablished related-key resistance,
* truncated use of a novel permutation as a KDF,
* and search-driven rather than cryptanalytic design evidence.

Even if state recovery proves difficult, it should remain explicitly noncryptographic unless subjected to a very different level of analysis.

---

# 11. Specification issues and suggested wording changes

## 11.1 Correct the affine claim

Replace:

> `clock` is an affine bijection of the hidden half

with:

> `clock` is a bijection of the hidden half. Each xor-rotate update is invertible when undone in reverse order, and addition of `CLOCK_WEYL` modulo \(2^{32}\) is invertible.

## 11.2 Weaken the domain-disjointness claim

Replace:

> The domain words keep chunk seeds and the four derivation families disjoint under one key.

with:

> The domain words give chunk initialization and the derivation families distinct input encodings under a fixed key. This does not guarantee disjoint output values.

## 11.3 Qualify the birthday claim

Replace:

> Child keys collide at the birthday rate over 128 bits.

with:

> Child keys are 128 bits. If the selected halves of `F` behave pseudorandomly over the relevant inputs, collision probability follows the usual 128-bit birthday bound; no collision-freedom is guaranteed.

## 11.4 Call the access model chunked random access

Suggested language:

> A block is reconstructible from `(key, K, position)` without preceding chunks. Access within a chunk requires recomputing at most `K` applications of `T` after initialization and is therefore bounded rather than constant-cost in `K`.

## 11.5 Specify algorithm identity

Add an identifier such as:

```text
Tandem8x32-v1-K32
```

or require serialized metadata to include:

* algorithm name,
* specification version,
* `K`,
* key,
* position.

The current transport form omits `K` on the assumption that the receiving type supplies it. That is unsafe for language-neutral transport.

## 11.6 Define invalid range behaviour

Specify overflow and exhaustion semantically, even if implementations optimize checks outside the hot loop.

## 11.7 Clarify fork as a batch or single operation

The parent-advance semantics must make it unambiguous whether several child indices refer to one captured block or different blocks.

---

# 12. Test-vector coverage

The existing vectors are a good start but not sufficient for port conformance.

Add vectors for:

## Primitive operations

* `clock(0)`.
* `clock` on all-ones and structured words.
* `mix` where multipliers are `1`.
* Product cases with nonzero high halves.
* Inputs that catch signed-versus-unsigned multiply-high errors.
* Rotate values crossing byte and word boundaries.
* `T⁻¹(T(x)) = x` examples if an inverse is documented.

## `F`

* All-zero state.
* All-ones state.
* High counter word nonzero.
* Counter `2^32-1`, `2^32`, and `2^64-1`.
* Every domain.
* Nonzero `aux`.
* Both output halves.

## Stream boundaries

* Last block of a chunk.
* First block of the next chunk.
* Last row of a group.
* First row of the next group.
* `K = 1`.
* `K = 2`.
* `K = 65536`, at least around the boundary.
* Positions 15, 16, 127, 128, `128K-1`, and `128K`.

## Draw alignment

* Draws beginning at every offset 0–15.
* Mixed draw types.
* Signed minimum and maximum reinterpretations.
* Float values whose retained integer is zero and near maximum.
* Bool values from bytes with high bits set but low bit clear.

## Derivation

* Split children 2 and 3.
* High-bit split indices.
* Both halves of the same split output.
* Fork from an unaligned position.
* Multiple fork children from one captured block.
* Purpose IDs 0, `2^32`, and `2^64-1`.
* Seeds 0, `2^32`, `2^64`, and `2^128-1`.

A digest of the first several kilobytes for selected keys and each supported `K` would make port validation much easier.

---

# 13. Recommended release criteria

Before presenting Tandem as production-quality, I would require the following.

## Blockers

1. **Correct the specification claims** about affinity, output disjointness, and birthday collisions.
2. **Define exhaustion and fork semantics.**
3. **Explicitly mark the generator noncryptographic.**
4. **Analyse the cycle structure of `clock`**, including exhaustive reduced-width models.
5. **Test repeated `T` output directly**, not only avalanche of `F`.
6. **Run BigCrush, PractRand, gjrand, and HWD-style tests** over many projections, keys, and split families.
7. **Publish optimized CPU and GPU benchmarks** against optimized Philox and Threefry.
8. **Treat `K` and the specification version as part of the external algorithm identity.**

## Strongly recommended

9. Independent review by someone not involved in the search.
10. Separate candidate-selection and final-validation test sets.
11. Differential and rotational analysis of `F`.
12. State-recovery and distinguishability attempts even though the generator is noncryptographic.
13. Cross-stream testing of split and fork children.
14. More comprehensive conformance vectors.
15. A written statement of what is and is not guaranteed about period and stream overlap.

---

# 14. Potential design changes

I would investigate, rather than immediately adopt, the following changes.

## 14.1 Couple the exposed half back into the hidden half

The autonomous clock is the largest structural concern. A modified transition in which `h'` incorporates an invertible function of `o` could:

* make the full state genuinely coupled,
* prevent the hidden period from independently controlling the system,
* improve diffusion across consecutive outputs,
* and make structural decomposition harder.

The challenge is preserving invertibility and inexpensive reconstruction.

For example, an invertible Feistel-like arrangement could update one half using the other, then update the other using the new first half. This would add arithmetic but may buy substantially more confidence.

## 14.2 Apply two lighter transitions per emitted block

If one-step output is found marginal, two `T`-like half-rounds with complementary lane pairing may still be much cheaper than Philox4x32-10.

The important point is to ensure every output word has recently depended nonlinearly on all relevant state branches, rather than merely increasing a nominal round count.

## 14.3 Consider low-product-only multiplication

The use of high product words impairs CPU SIMD ergonomics. A design based on:

* multiplication by odd constants modulo \(2^{32}\),
* rotations,
* additions,
* xor,
* and invertible cross-lane mixing

could map more directly to `VPMULLD` and ordinary GPU multiplication.

However, deleting `hi(p)` from the current design without redesigning the diffusion layer would likely weaken it. This is a direction for a new round construction, not a local optimization.

## 14.4 Fix `K`

A fixed `K = 32` would make:

* streams stable across implementations,
* testing simpler,
* algorithm naming simpler,
* and scientific reproducibility less sensitive to performance tuning.

If larger chunks are useful for bulk kernels, expose them as distinct algorithm variants rather than silent tuning options.

## 14.5 Use a conservative KDF for splitting

If splitting is central to the intended functional-programming use case, deriving child keys with BLAKE3 or ChaCha would remove one major analysis burden from `F`. Tandem could remain the fast data-plane generator.

---

# 15. Final judgment

Tandem8x32 has a credible performance concept:

* pure compact transport state,
* chunk-amortized initialization,
* only two products per recurrent block,
* an SIMD-friendly eight-lane layout,
* coalesced GPU output,
* deterministic splitting and seeking.

Those are real advantages, and the design may prove considerably faster than Philox in long contiguous fills.

The current confidence gap is also substantial:

* it is not a direct CBRNG in the Philox sense;
* random access is \(O(j)\) within a chunk;
* changing `K` changes the stream;
* `clock` has no stated period analysis;
* the hidden state is autonomous;
* every post-initialization block is exposed after only one light transition;
* key derivation relies on truncated halves of a novel permutation;
* and several assurance claims are stronger than the construction currently proves.

I would describe Draft 1 as an **experimental, bulk-oriented, splittable pure PRNG candidate**, not yet a SOTA replacement. The next design effort should focus less on additional ordinary PractRand volume and more on:

1. clock cycle and invariant analysis,
2. one-step and multi-step structural distinguishers,
3. output projection and cross-stream testing,
4. independent analysis,
5. exact optimized CPU/GPU comparisons,
6. and tightening the normative specification.

If those results are favorable, Tandem’s amortized architecture could occupy a useful niche between direct CBRNGs such as Philox and conventional stateful generators.