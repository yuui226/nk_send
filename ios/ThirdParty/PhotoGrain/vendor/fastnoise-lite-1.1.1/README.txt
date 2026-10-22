FastNoiseLite v1.1.1 — MIT license
Upstream: https://github.com/Auburn/FastNoiseLite/tree/v1.1.1
Header: https://raw.githubusercontent.com/Auburn/FastNoiseLite/v1.1.1/Cpp/FastNoiseLite.h
SHA-256: 47a29750dfe13d15651febd235f3c26b1cc57af7c6e26583b838fd7ab5215dc2
LICENSE SHA-256: c08da3239b919c12f4ec616b457a8dd0fc923c8102c8a742c4006fcb5de28fb0

The upstream header is unmodified. Only its 2D OpenSimplex2S generator is used.
No build tools, examples, textures or other language ports are bundled.
Compile the consuming translation unit with -fwrapv (intentional integer hash
wraparound), -ffp-contract=off and -fno-fast-math for stable rendering.
The iOS app includes the MIT notice from ZTransfer/Resources/licenses/FastNoiseLite-MIT.txt.
Copied from Android 1f804ab8; the kernel, upstream header and LICENSE are unchanged.
