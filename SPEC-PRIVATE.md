# Tandem8x32 specification

Draft 4, 2026-09-21. This specification is normative for `TandemRNG.jl` and every port.
`design/LEDGER.md` records the rationale for each choice (decisions D1 to D24). Sections marked *non-normative*
describe implementation strategies and may be ignored by a conforming implementation.
Draft 4 adds exposed-to-hidden feedback (D24), changing F, derived keys, and all streams.
Draft 3 introduced bit positions and one-bit Bool draws (D22); draft 2 counted bytes.
The 2026-09-26 type addendum adds Float16, 128-bit integers, complex floats, and Char
without changing any existing draw stream.

**Tandem8x32 is a noncryptographic pseudorandom number generator.** It is not for key
generation, encryption, authentication, nonces that must be unpredictable, password
processing, or any randomness an adversary may observe. Half of the state is exposed at
every step and one light transition separates consecutive blocks. The words *key*, *hidden*,
and *whitening* below name roles in the construction
and imply no secrecy.

**Algorithm identity.** The stream depends on the key, the chunk length `K`, and the position,
and on the version of this specification. The canonical variant is `Tandem8x32-v2-K32`, with
`K = 32`. Other chunk lengths are named variants `Tandem8x32-v2-K<k>`, and a port may support
the canonical variant only. A serialized generator or a cross-language reference to a
stream must carry the variant name, the key, and the position. Two generators with the same
key and different `K` produce different streams.

## 1. Notation

- A *word* is a 32-bit unsigned integer. `+` is addition modulo 2^32, `⊕` is xor, `|` is
  bitwise or, `rotl(x, r)` rotates left by `r` bits, `x · y` for words is the 64-bit product,
  `hi(p)` and `lo(p)` are the upper and lower 32 bits of a 64-bit value.
- Bytes of a word are little-endian: word `w` occupies bytes `w mod 256`, `(w >> 8) mod 256`,
  `(w >> 16) mod 256`, `w >> 24`.
- A *state* is a pair `(o, h)` of four words each, `o = (o0, o1, o2, o3)` the exposed half and
  `h = (h0, h1, h2, h3)` the hidden half.
- A *block* consists of the 16 bytes of an exposed half `o`, with the bytes of `o0` first.

## 2. Constants

| name | value | use |
|---|---|---|
| `CLOCK_ROT` | (7, 13, 22, 3) | rotations of the clock |
| `CLOCK_WEYL` | 0x9e3779b9 | Weyl increment of the clock |
| `LO_ROTATION` | 16 | rotation of the low product word |
| `RF` | 8 | rounds of F |
| `RC[1..8]` | 0xd17cc1b7, 0xa7220a94, 0xfe13abe8, 0xfa9a6ee0, 0xedb14acc, 0x9e21c820, 0xff28b1d5, 0xef5de2b0 | round constants of F |
| `DOMAIN_STREAM` | 0x9e3779b9 | stream chunks |
| `DOMAIN_SPLIT` | 0xbb67ae85 | split children |
| `DOMAIN_FORK` | 0xd2511f53 | fork children |
| `DOMAIN_FOLD` | 0xcd9e8d57 | purpose children |
| `DOMAIN_SEED` | 0xa54ff53a | seed whitening |
| `AUX_STREAM` | 0x94d049bb | aux word of stream chunks |

## 3. The step T

Evaluate both functions on the input state, then apply feedback:

```
o' = mix(o, h)
q = clock(h)
h' = (q0 ⊕ o'0, q1, q2, q3)
return (o', h')
```

The feedback xor follows the clock's modular addition.

`clock(h)` with `h = (h0, h1, h2, h3)`, evaluated in this order:

```
h0 ← h0 ⊕ rotl(h1, 7)
h1 ← h1 ⊕ rotl(h2, 13)
h2 ← h2 ⊕ rotl(h3, 22)
h3 ← h3 ⊕ rotl(h0, 3)        (the updated h0)
return (h0 + 0x9e3779b9, h1, h2, h3)
```

`mix(o, h)` with `o = (a, b, c, d)` and the input `h` (before the clock):

```
p0 = a · (h0 | 1)
p1 = c · (h1 | 1)
return (b ⊕ hi(p1) ⊕ lo(p1),
        rotl(lo(p1), 16) ⊕ h2,
        d ⊕ hi(p0) ⊕ lo(p0),
        rotl(lo(p0), 16) ⊕ h3)
```

`clock` is a bijection of the hidden half: the four xor-rotate updates are invertible when
undone in reverse order, and the addition modulo 2^32 is invertible. The xor-rotate part is
linear over GF(2), whereas the addition is not. Thus `clock` is neither linear nor affine
over one structure, and the all-zero hidden half is not a fixed point. For fixed `h`, `mix` is a
bijection of the exposed half (the odd multipliers are invertible modulo 2^32, the second
and fourth output words determine `lo(p1)` and `lo(p0)` and so `c` and `a`, then the first
and third determine `b` and `d`). Given T's output, undo feedback with `q0 = h'0 ⊕ o'0`,
invert the clock to recover `h`, then invert `mix`. T is a permutation of the 256-bit state. No
lower bound on stream-seeded production periods is established (see section 10).

## 4. The seeding function F

`F(o, h)` applies eight rounds to a state:

```
for r = 1 to 8:
    (o, h) ← T(o, h)
    o0 ← o0 ⊕ RC[r]
    (o, h) ← (h, o)
return (o, h)
```

`F(key, counter, domain, aux)` for a key of four words, a 64-bit `counter`, and words
`domain`, `aux` is `F(o, h)` with

```
o = (counter mod 2^32, counter >> 32, domain, aux)
h = key
```

## 5. Chunks and the stream

A generator has a *key* of four words and a *chunk length* `K`, a power of two with
`1 ≤ K ≤ 65536` (default 32). Chunk `c` (a 64-bit index) has the initial state
`(o, h) = F(key, c, DOMAIN_STREAM, AUX_STREAM)` and produces `K` blocks:

```
B(c, j) = exposed half of T^(j+1)(o, h),   j = 0, …, K − 1
```

The stream is a sequence of 1024-bit *rows*. Row `r` (0-based, 64-bit) belongs to group
`g = r ÷ K` at step `j = r mod K` and is the concatenation of the eight 128-bit blocks

```
B(8g + 0, j), B(8g + 1, j), …, B(8g + 7, j)
```

Bit `t` of a block (0 ≤ t < 128) is bit `t mod 32` of word `o(t ÷ 32)`, so the block's bits
in stream order are the bits of `o0` from bit 0 upward, followed by `o1`, `o2`, `o3`. Bit position `p`
(0 ≤ p < 2^64) therefore lies in row `p >> 10`, in lane `(p >> 7) & 7` of that row, at bit
`p & 127` of block `B(8·((p >> 10) ÷ K) + ((p >> 7) & 7), (p >> 10) mod K)`.

The stream depends on `K`. Two generators with the same key and different `K` produce
different streams.

Access is *chunked random access*: any block is reconstructible from `(key, K, position)`
without earlier chunks, at the cost of one F and between 1 and `K` applications of T. The
cost is bounded by `K`, not constant.

Distinct `(key, counter, domain, aux)` inputs give distinct F outputs, because F is a
permutation, so two chunks never start in the same full state. No claim is made that their
trajectories under T are disjoint or that their blocks are independent beyond the
statistical evidence of section 10.

## 6. Draws

Each scalar component has a fixed width `w` in bits and is aligned to it:

| type | w |
|---|---|
| Bool | 1 |
| UInt8, Int8 | 8 |
| UInt16, Int16, Float16 | 16 |
| UInt32, Int32, Float32 | 32 |
| UInt64, Int64, Float64, Char | 64 |
| UInt128, Int128 | 128 |

A draw of width `w` from position `p` first rounds the position up to a multiple of `w`,
`p' = (p + w − 1) & ~(w − 1)`, reads the `w` bits at `p'`, and leaves the position at
`p' + w`. A block is 128 bits and every `w` divides 128, so a draw never crosses a block. For
`w ≥ 8` the bits read are the `w / 8` bytes at byte offset `(p' >> 3) & 15` of the block,
taken as a little-endian unsigned integer `raw`; a block's bytes in stream order are the
little-endian bytes of `o0`, then `o1`, `o2`, `o3`.

The value is

- integers: `raw` reinterpreted as the type (two's complement for signed types),
- Bool: the single bit at `p'`, `true` when set,
- Float64: `(raw >> 11) · 2^−53`, uniform on [0, 1) with 53 random bits,
- Float32: `(raw >> 8) · 2^−24`, uniform on [0, 1) with 24 random bits,
- Float16: `(raw >> 5) · 2^−11`, uniform on [0, 1) with 11 random bits,
- Char: set `u = floor(raw · 1112064 / 2^64)` and return Unicode scalar `u` when
  `u < 0xd800`, otherwise `u + 0x800`. This is PureRNGs' fixed-work mapping, with
  absolute probability error below 2^−64 per scalar. Char occupies four output bytes
  but consumes 64 stream bits.

A `Complex{T}` draw, for T in Float16/Float32/Float64, is one real draw followed by
one imaginary draw of T. It aligns to T's width and consumes twice that width.
The pair may cross a block boundary. Complex fills have exactly the component order
of a real fill of twice the length. Empty complex fills align to T's width.

The `i`-th element (0-based) of a fill of `n` values of width `w` from position `p` is the
draw at `p' + w·i`, and the fill leaves the position at `p' + w·n`. A fill and a sequence of
single draws of the same type from the same position give the same values.

Consequences of the alignment rule: a change of draw type may skip up to 127 bits, and
skipped bits are never revisited. Eight consecutive Bool draws from a byte boundary are the
eight bits, low first, of the byte a UInt8 draw would return there. A typed fill equals
repeated draws of that type, but reinterpreting a byte fill does not equal a mixed sequence
of draws. The float mappings are exact scalings of an integer by a power of two, so an
implementation must not substitute a `[1, 2)` mantissa construction, a division, a signed
conversion, or any mapping that can produce 1.0.

The stream holds 2^64 bits, positions 0 to 2^64 − 1. A draw is valid when `p' + w < 2^64`
and a fill when `p' + w·n < 2^64`, with the arithmetic taken without wrap. The returned
position must fit UInt64; ending exactly at 2^64 is rejected, so this API cannot consume
the stream's final bit. This clarifies the implementation's existing limit. An implementation
must reject an invalid fill before it starts and must reject a generator constructed at or
above 2^63. It may leave scalar draws unchecked: a generator constructed below 2^63 has at
least 2^63 bits (2^60 bytes) ahead of it, more than any process draws, and the check would
sit on the one instruction the draw loop carries. Behaviour of an unchecked draw reaching 2^64 is
undefined.

## 7. Transport form and parameters

A generator is fully determined by `(key, K, position)` under one specification version.
Within a typed language, `K` may be encoded in the type, and the transport form consists
of the key (128 bits) and the bit position (64 bits). Across languages, files, and protocols the algorithm
identity from the preamble must accompany them. Any working state is a cache.

## 8. Key derivation

Children are keys. Each child starts at position 0 with the parent's `K`. `half(0)` of an F
output is its exposed half `o`, `half(1)` its hidden half `h`.

- **Split by index.** Child `i` (64-bit) of key `k`:
  `half(i & 1) of F(k, i >> 1, DOMAIN_SPLIT, 0)`. Derivation reads only the key, so an
  advanced parent gives the same children.
- **Fork at the current block.** A batch operation `fork(parent, n)`. Let `b = p >> 7` for
  the parent's position `p`. Children `i = 0, …, n − 1` (`n ≤ 2^33`) are
  `half(i & 1) of F(k, b, DOMAIN_FORK, (i >> 1) mod 2^32)`, all from the same `b`, and the
  parent then moves once to position `(b + 1) · 128`. A single-child fork is
  `fork(parent, 1)`. A parent exactly at a block boundary consumes that whole block. Two
  successive forks use different `b` and give unrelated children.
- **Purpose.** For a 64-bit purpose id `u`: `half(0) of F(k, u, DOMAIN_FOLD, 0)`.
- **Seed whitening.** An integer seed `0 ≤ z < 2^128` gives the key
  `half(0) of F(o, h)` with `o = (0, 0, DOMAIN_SEED, 0)` and
  `h = (z mod 2^32, (z >> 32) mod 2^32, (z >> 64) mod 2^32, z >> 96)`. Whitening distributes
  the bits of small or related seeds across the key. It adds no entropy, provides no secrecy,
  and is not a password hash.

The domain words give chunk initialization and the four derivation families distinct input
encodings under one key. They do not guarantee distinct output halves. Child keys are 128
bits: if the selected halves of F behave as pseudorandom functions of their inputs,
collisions follow the 128-bit birthday bound, and no collision freedom is guaranteed. The two
split children of one index are the two halves of one F output.

## 9. Test vectors

All words are hexadecimal.

**T on a structured state.** `T((1, 2, 3, 4), (5, 6, 7, 8))`:

```
o' = (00000017, 00150007, 00000001, 00050008)
h' = (9e377ca9, 0000e006, 02000007, 00001820)
```

**T on the zero state.** `T(0, 0) = (0, (9e3779b9, 0, 0, 0))`.

**F for the stream**, key `k = (00000001, 00000002, 00000003, 00000004)`:

```
F(k, 0, DOMAIN_STREAM, AUX_STREAM):
  o = (472bef12, c0977c66, d330ac3a, b11a020d)
  h = (bfa0b6ba, ecdbc48e, f1989116, c2374d96)
F(k, 1, DOMAIN_STREAM, AUX_STREAM):
  o = (b777c10c, 2f6b5a5d, 67a9ce03, 7de06a50)
  h = (d0c2dc4f, e1e50e0f, 89efc72c, 6e82b062)
```

**Stream under `k`, K = 32**, as UInt32 words from position 0:

```
words 0–3   (row 0, lane 0 = B(0, 0)): 0a5bcb90 6dfe98bc 9612198a ac115fd8
words 4–7   (row 0, lane 1 = B(1, 0)): 33f598d7 b5c280ca 7a8e7b99 8c362290
words 32–35 (row 1, lane 0 = B(0, 1)): 9da7bac0 4aca79eb beb1f65a e2f0d5a1
```

Derived draws from position 0: Float64 element 0 = 0.4296660861094629, Float64 element 16
(bit 1024, row 1) = 0.2921520424112306, Float32 element 2 = 0.58621365. Bool elements 0 to 7
are bits 0 to 7 of word 0 (low byte 0x90): 0, 0, 0, 0, 1, 0, 0, 1. Bool element 128 is bit 0
of word 4 (0x33f598d7): 1.

**Derived keys of `k`:**

```
split child 0:            e256e9a1 5020f806 3bd3f7dc 5328763d
split child 1:            a9ea3f0b 47f97af0 d1844c53 97e9cee2
fork child 0 at block 0:  67fd37c5 9dc0b8c6 4e3bd55e af3f2216
purpose 7:                8048398f 1678e814 d8823983 c4b1045c
```

**Seed whitening.** Seed 42 gives the key `421d21eb 32d31777 62e7564b df2bdf82`. From that
key at K = 32: Float64 element 0 = 0.9829130398628935, UInt32 element 0 = 0x05e80cec, Float64
element 2 = 0.47759300283385586, Float64 element 16 = 0.9692135305890753.

These vectors come from the independent UInt64 scalar oracle `design/search/reference_v2.jl`.

## 10. Implementation notes (non-normative)

- **GPU fill.** One work-item per chunk: F once, then K steps, each block stored at the
  position defined by the stream. The eight work-items of a group write one contiguous 128-byte row per step,
  so a warp's stores fill whole cache lines with no shared memory and no barrier. Interior
  blocks are one 16-byte vector store. A Bool fill runs in two passes, a word fill into a
  temporary array of one bit per Bool and an expansion kernel in which adjacent work-items
  write adjacent 16-byte pieces (four bits to four bytes by one multiply by 0x00204081 and
  a mask), because expanding inside the chunk kernel scatters each lane's 128 bytes.
- **CPU fill.** The eight chunks of a group step in lockstep with one 8-lane vector per state
  word (AVX2, NEON as two halves). Each task writes a contiguous range of groups.
  A Bool row is 1024 bytes: each word expands to 32 bytes by a byte shuffle, a bit-weight
  mask, and a compare.
- **Scalar chain.** A value holds the eight lane states of its row. The exposed row is stored
  in rotated order so the current block occupies a fixed lane, with one constant shuffle per
  block. The hidden row remains in natural order because eight rotations are the identity
  exactly when the next step is due. Runtime lane indexing instead forces the state through memory.
- **Random access.** `B(c, j)` costs one F and `j + 1` steps of T on a single lane.
- **FPGA.** One step is two 32×32→64 multiplies plus xor, add, and wiring. The row order is
  the natural order for an eight-lane C-slow pipeline, and F reuses the same datapath.
- **Cycle limits.** The clock is bijective, not GF(2)-affine. With Weyl constant `c`, its
  unique fixed point is `(c, rotr(c, 7), 0, 0)`. Exhaustive production analysis finds exactly
  two full-step fixed points for v2. Both unique inverse-F inputs have the wrong stream
  domain and aux, so no stream seed reaches either. Bijectivity excludes later entry.
  Feedback makes every nonzero exposed state leave v1's fixed-hidden slice within four
  steps. The four-bit feedback map has 26 cycles covering all 2^32 states; none of its
  cycles of period at most 32 contains a legal reduced stream seed. Scaled maps are not
  quotients of this specification. Longer production periods remain open. See `design/SEARCH.md`.
- **Statistical evidence.** V2's F passes the eight-round diffusion screen on 16,384 bases,
  flipping all 256 input bits and testing all output bits. Six rounds show bias.
  The fixed D16 campaigns are complete: 12 BigCrush cases, sequential PractRand at
  1 TiB for K = 1, 32, 64, 19 derived streams at 4 TiB default and 256 GiB expanded,
  sequential and chunk-start HWD at 1 TiB, and gjrand's 10 TiB tier. The 203 structured
  screens each reach 256 MiB. Flags, replication protocols, and coverage limits remain
  in [`design/VALIDATION.md`](design/VALIDATION.md). These finite tests do not prove
  randomness or a production period. The fixed F5–F8 margin campaign completes 72 runs
  at 256 GiB each. F5 fails repeatedly across three keys. F8 has no suspicious or FAIL
  labels in its 18 runs. This establishes bounded separation, not a minimum round count.
  Longer production cycle analysis remains open. The generator remains experimental.
