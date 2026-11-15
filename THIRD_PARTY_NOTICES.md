# Third-party notices

## FFmpeg 7.1.1

QYFM HM bundles a full built-in FFmpeg component build for HarmonyOS
arm64-v8a. The application links:

- `libavcodec`
- `libavutil`
- `libswresample`

The static build includes FFmpeg's built-in decoders, encoders, parsers,
demuxers, muxers, protocols and filters, with ARMv8-A NEON/DOTPROD/I8MM
optimizations and 32-bit floating-point audio output. Command-line programs,
documentation and debug symbols are not bundled. App execution uses the
MP3/AAC decoding and resampling paths; unused linked components are present
because this is intentionally a full build rather than a size-trimmed build.

FFmpeg is licensed under the GNU Lesser General Public License version 2.1 or later.
The complete FFmpeg source is available from:

https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz

The license text is included at
`entry/src/main/cpp/ffmpeg/COPYING.LGPLv2.1`.

The library was configured without GPL components or optional external codec
libraries, so it remains LGPL version 2.1 or later.
