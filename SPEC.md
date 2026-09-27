# Tandem8x32 specification

Use Tandem8x32 for noncryptographic pseudorandom number generation.
Implement the canonical variant `Tandem8x32-K32` with `K = 32`.
Identify other supported chunk lengths as `Tandem8x32-K<k>`.

## 1. Words and state

Use unsigned 32-bit words and the following operations:

| Notation | Operation |
| --- | --- |
| `+` on words | Addition modulo 2^32 |
| `⊕` | Bitwise xor |
| `\|` | Bitwise or |
| `&` | Bitwise and |
| `~` | Bitwise complement |
| `>>` | Logical right shift |
| `rotl(x, r)` | Rotate the 32-bit word `x` left by `r` bits |
| `x · y` on words | Full unsigned 64-bit product |
| `hi(p)` | Upper 32 bits of a 64-bit product |
| `lo(p)` | Lower 32 bits of a 64-bit product |
| `÷` | Integer division |
| `mod` | Nonnegative remainder |

Represent a state as `(o, h)`, with four words in each half.
Name the exposed words `o = (o0, o1, o2, o3)`.
Name the hidden words `h = (h0, h1, h2, h3)`.
Use zero-based word, bit, block, lane, row, and child indices.

Encode each word `w` as four little-endian bytes:

```
w mod 256, (w >> 8) mod 256, (w >> 16) mod 256, w >> 24
```

Form a 16-byte block by concatenating the bytes of `o0`, `o1`, `o2`, and `o3`.
Number each word's bits from its least significant bit.

## 2. Constants

Use these constants:

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


## 3. Building blocks

### Clock

Evaluate `clock(h)` in the following order:

```
h0 ← h0 ⊕ rotl(h1, 7)
h1 ← h1 ⊕ rotl(h2, 13)
h2 ← h2 ⊕ rotl(h3, 22)
h3 ← h3 ⊕ rotl(h0, 3)        (the updated h0)
return (h0 + 0x9e3779b9, h1, h2, h3)
```

### Mix

Evaluate `mix(o, h)` with `o = (a, b, c, d)`:

```
p0 = a · (h0 | 1)
p1 = c · (h1 | 1)
return (b ⊕ hi(p1) ⊕ lo(p1),
        rotl(lo(p1), 16) ⊕ h2,
        d ⊕ hi(p0) ⊕ lo(p0),
        rotl(lo(p0), 16) ⊕ h3)
```

### Step T

Evaluate both building blocks on the input state.
Apply feedback after the clock's modular addition:

```
o' = mix(o, h)
q = clock(h)
h' = (q0 ⊕ o'0, q1, q2, q3)
return (o', h')
```

### Seeding function F

Evaluate `F(o, h)` with exactly eight rounds.
Index the round constants from 1 through 8:

```
for r = 1 to 8:
    (o, h) ← T(o, h)
    o0 ← o0 ⊕ RC[r]
    (o, h) ← (h, o)
return (o, h)
```

For `F(key, counter, domain, aux)`, use a four-word key and an unsigned 64-bit counter.
Use 32-bit words for `domain` and `aux`.
Initialize the state, then evaluate `F(o, h)`:

```
o = (counter mod 2^32, counter >> 32, domain, aux)
h = key
```

## 4. Chunks and stream order

Choose a power-of-two chunk length `K` with `1 ≤ K ≤ 65536`.
Use `K = 32` by default.
Represent the chunk index `c` as an unsigned 64-bit integer.

Initialize each chunk with `(o, h) = F(key, c, DOMAIN_STREAM, AUX_STREAM)`.
Advance the state with T before emitting each of its `K` blocks:

```
B(c, j) = exposed half of T^(j+1)(o, h),   j = 0, …, K − 1
```

Arrange the stream into 1024-bit rows.
For row `r`, set `g = r ÷ K` and `j = r mod K`.
Concatenate the eight 128-bit blocks in this order:

```
B(8g + 0, j), B(8g + 1, j), …, B(8g + 7, j)
```

Read bit `t` of a block from bit `t mod 32` of word `o(t ÷ 32)`.
Use `0 ≤ t < 128`.
For a stream bit position `p` with `0 ≤ p < 2^64`, locate its block as follows:

```
r = p >> 10
g = r ÷ K
j = r mod K
lane = (p >> 7) & 7
c = 8g + lane
t = p & 127
block = B(c, j)
```

For random access, initialize chunk `c`, apply T `j + 1` times, and read its exposed half.

## 5. Draws and fills

Use these scalar component widths:

| Type | Width w, bits |
| --- | --- |
| Bool | 1 |
| UInt8, Int8 | 8 |
| UInt16, Int16, Float16 | 16 |
| UInt32, Int32, Float32 | 32 |
| UInt64, Int64, Float64, Char | 64 |
| UInt128, Int128 | 128 |

For a scalar draw at position `p`, align to its width `w`:

```
p' = (p + w − 1) & ~(w − 1)
```

Read `w` bits starting at `p'`.
Set the successor position to `p' + w`.
For `w ≥ 8`, read `w / 8` bytes at block byte offset `(p' >> 3) & 15`.
Interpret these bytes as the little-endian unsigned integer `raw`.

Convert the input to the requested type:

- Integers: reinterpret `raw` at the requested width, using two's complement for signed types.
- Bool: return `true` for a set bit and `false` for a clear bit.
- Float64: return `(raw >> 11) · 2^−53` as Float64.
- Float32: return `(raw >> 8) · 2^−24` as Float32.
- Float16: return `(raw >> 5) · 2^−11` as Float16.
- Char: compute `u = floor(raw · 1112064 / 2^64)` using the full mathematical product.
  Return Unicode scalar `u` when `u < 0xd800`, and `u + 0x800` otherwise.

Evaluate each float mapping as an exact integer scaling by a power of two.
Store Char in four output bytes and advance its stream position by 64 bits.

For `Complex{T}`, with T in Float16/Float32/Float64, draw the real component followed by the imaginary component.
Apply the scalar rule separately to each component.
Allow the pair to span adjacent blocks.

For a fill of `n` scalar values, align the initial position to obtain `p'`.
Read element `i` at `p' + w·i` for `i = 0, …, n − 1`.
Return position `p' + w·n`.
For complex fills, emit real and imaginary components in alternating order.
Use a real fill of length `2n` to determine the component sequence.
For an empty fill, return the initial position aligned to the scalar component width.

### Position bounds

Accept initial constructor positions satisfying `0 ≤ p < 2^63`.
Represent successor positions as unsigned 64-bit integers.
Compute alignment and endpoint checks with mathematical integer arithmetic.
Require `p' + w < 2^64` for a scalar draw and `p' + w·n < 2^64` for a scalar fill.
Apply the same endpoint bound to the complete component sequence of a complex draw or fill.
Validate a fill's alignment and endpoint before writing output.
Keep unchecked scalar draws within these bounds.

## 6. Seeds and child keys

Define `half(0)` of an F output as its exposed half `o`.
Define `half(1)` as its hidden half `h`.
Start each child at position 0 with its parent's `K`.

### Integer seeds

Accept integer seeds `z` with `0 ≤ z < 2^128`.
Initialize:

```
o = (0, 0, DOMAIN_SEED, 0)
h = (z mod 2^32, (z >> 32) mod 2^32, (z >> 64) mod 2^32, z >> 96)
key = half(0) of F(o, h)
```

For a raw-key constructor, use the supplied four words as the key.

### Split by index

For child index `i` in the unsigned 64-bit range, derive:

```
child_key = half(i & 1) of F(key, i >> 1, DOMAIN_SPLIT, 0)
```

Use the parent key for every child.
Preserve the parent position.

### Fork at the current block

Accept a batch size `n` with `0 ≤ n ≤ 2^33`.
Capture `b = p >> 7` from the parent position.
Derive every child from that captured block:

```
for i = 0 to n − 1:
    child_key[i] = half(i & 1) of F(key, b, DOMAIN_FORK, (i >> 1) mod 2^32)
parent_position = (b + 1) · 128
```

Advance the parent once per batch, including an empty batch.
Use `n = 1` for a single-child fork.
At an exact block boundary, advance the parent to the following block boundary.

### Purpose

For an unsigned 64-bit purpose identifier `u`, derive:

```
child_key = half(0) of F(key, u, DOMAIN_FOLD, 0)
```

Preserve the parent position.

## 7. Transport

Transport the variant name, four-word key, and unsigned 64-bit bit position.
Use the variant name to identify the algorithm and its chunk length `K`.
Represent the key with 128 bits and the position with 64 bits.
Reconstruct cached working state from the key, chunk length, and position.

## 8. Test vectors

Check an implementation against these vectors.

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
