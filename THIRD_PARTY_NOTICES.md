# Third-party software in Matinee

Matinee is licensed under the GNU General Public License, version 3 or later (see `LICENSE`). Release builds of Matinee.app include the software below, each under its own license. FFmpeg in these builds is configured with `--enable-gpl --enable-version3`, which makes it GPL-3.0-or-later; that is why Matinee as a whole is GPL-3.0-or-later.

Every GitHub release has a `Matinee-sources.tar` next to `Matinee.zip`. It holds the exact source of each GPL and LGPL library in that release, the Homebrew build recipe each was built with, and mpv's source together with Matinee's patches (`Scripts/mpv/`). `Scripts/collect_sources.sh` builds it.

## Video playback (Mpv.bundle)

Built by `Scripts/build_mpv.sh` and `Scripts/bundle_ffmpeg.sh` from mpv's source and Homebrew's libraries.

| Component | License | Project |
|---|---|---|
| mpv (libmpv, built with Matinee's patches) | GPL-2.0-or-later | https://mpv.io |
| FFmpeg (libraries and the `ffmpeg` tool) | GPL-3.0-or-later as configured | https://ffmpeg.org |
| x264 | GPL-2.0-or-later | https://www.videolan.org/developers/x264.html |
| x265 | GPL-2.0-or-later | https://github.com/Multicorewareinc/x265 |
| libplacebo | LGPL-2.1-or-later | https://code.videolan.org/videolan/libplacebo |
| GLib | LGPL-2.1-or-later | https://docs.gtk.org/glib/ |
| GNU gettext (libintl) | LGPL-2.1-or-later | https://www.gnu.org/software/gettext/ |
| GNU FriBidi | LGPL-2.1-or-later | https://github.com/fribidi/fribidi |
| mpg123 | LGPL-2.1-only | https://www.mpg123.de |
| LAME | LGPL-2.0-or-later | https://lame.sourceforge.io |
| Graphite2 | LGPL-2.1-or-later, MPL-2.0, MIT or GPL-2.0-or-later | https://graphite.sil.org |
| libass | ISC | https://github.com/libass/libass |
| HarfBuzz | MIT | https://github.com/harfbuzz/harfbuzz |
| FreeType | FreeType License | https://freetype.org |
| libunibreak | Zlib | https://github.com/adah1972/libunibreak |
| Little CMS | MIT | https://www.littlecms.com |
| zimg | WTFPL | https://github.com/sekrit-twc/zimg |
| dav1d | BSD-2-Clause | https://code.videolan.org/videolan/dav1d |
| SVT-AV1 | BSD-3-Clause | https://gitlab.com/AOMediaCodec/SVT-AV1 |
| libvpx | BSD-3-Clause | https://www.webmproject.org/code/ |
| Opus | BSD-3-Clause | https://opus-codec.org |
| libvmaf | BSD-2-Clause-Patent | https://github.com/Netflix/vmaf |
| libjpeg-turbo | IJG, BSD-3-Clause and Zlib | https://libjpeg-turbo.org |
| libpng | libpng-2.0 | https://www.libpng.org/pub/png/libpng.html |
| PCRE2 | BSD-3-Clause | https://www.pcre.org |
| XZ Utils (liblzma) | 0BSD | https://tukaani.org/xz/ |
| Brotli | MIT | https://github.com/google/brotli |
| OpenSSL | Apache-2.0 | https://openssl-library.org |
| MoltenVK | Apache-2.0 | https://github.com/KhronosGroup/MoltenVK |
| Vulkan Loader | Apache-2.0 | https://github.com/KhronosGroup/Vulkan-Loader |
| shaderc | Apache-2.0 | https://github.com/google/shaderc |

## Worker runtime (Runtime.bundle)

Fetched by `Scripts/fetch_runtime.sh` at the versions pinned in `Scripts/runtime.lock` and `Scripts/runtime-requirements.txt`.

| Component | License | Project |
|---|---|---|
| CPython, from python-build-standalone | PSF-2.0 (the libraries it links in are listed by that project) | https://github.com/astral-sh/python-build-standalone |
| Deno | MIT | https://deno.com |
| yt-dlp | Unlicense | https://github.com/yt-dlp/yt-dlp |
| yt-dlp-ejs | Unlicense, MIT and ISC | https://github.com/yt-dlp/ejs |
| mutagen | GPL-2.0-or-later | https://github.com/quodlibet/mutagen |
| requests | Apache-2.0 | https://github.com/psf/requests |
| urllib3 | MIT | https://github.com/urllib3/urllib3 |
| charset-normalizer | MIT | https://github.com/jawah/charset_normalizer |
| idna | BSD-3-Clause | https://github.com/kjd/idna |
| certifi | MPL-2.0 | https://github.com/certifi/python-certifi |
| Brotli (Python) | MIT | https://github.com/google/brotli |
| pycryptodomex | BSD-2-Clause and public domain | https://www.pycryptodome.org |
| websockets | BSD-3-Clause | https://github.com/python-websockets/websockets |

## Swift packages

| Component | License | Project |
|---|---|---|
| MLX Swift | MIT | https://github.com/ml-explore/mlx-swift |
| MLX Swift LM | MIT | https://github.com/ml-explore/mlx-swift-lm |
| swift-transformers | Apache-2.0 | https://github.com/huggingface/swift-transformers |
| swift-huggingface | Apache-2.0 | https://github.com/huggingface/swift-huggingface |
| swift-jinja | Apache-2.0 | https://github.com/huggingface/swift-jinja |
| EventSource | MIT | https://github.com/mattt/EventSource |
| yyjson | MIT | https://github.com/ibireme/yyjson |
| Swift Collections | Apache-2.0 | https://github.com/apple/swift-collections |
| Swift Numerics | Apache-2.0 | https://github.com/apple/swift-numerics |
| Swift Crypto | Apache-2.0 | https://github.com/apple/swift-crypto |
| Swift ASN.1 | Apache-2.0 | https://github.com/apple/swift-asn1 |
| swift-syntax (build time only) | Apache-2.0 | https://github.com/swiftlang/swift-syntax |

## Downloaded at run time, not included

With Local AI ranking on, Matinee downloads two models from Hugging Face: multilingual-e5-large (MIT) and JevK5 (Apache-2.0). SponsorBlock and DeArrow data comes from their public APIs and is licensed CC BY-NC-SA 4.0 by https://sponsor.ajay.app.
