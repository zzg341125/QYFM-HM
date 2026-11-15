# FFmpeg HarmonyOS build

Source: `ffmpeg-7.1.1.tar.xz`

The bundled static libraries are a full built-in FFmpeg component build
cross-compiled for `aarch64-linux-ohos` with the HarmonyOS native sysroot.
QYFM links `libavcodec`, `libavutil` and `libswresample`; the output is
48 kHz stereo 32-bit floating-point PCM.

The build keeps the normal FFmpeg component set, ARMv8-A NEON, DOTPROD and
I8MM optimizations. Only command-line programs, documentation, shared
libraries and debug symbols are disabled. Optional third-party libraries are
not auto-detected so the result stays reproducible and LGPL-compatible.

```sh
unset ARCH CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
../ffmpeg-7.1.1/configure \
  --enable-cross-compile \
  --arch=aarch64 \
  --cpu=armv8-a \
  --target-os=linux \
  --cc='clang --target=aarch64-linux-ohos --sysroot=/mnt/f/command-line-tools/sdk/default/openharmony/native/sysroot' \
  --cxx='clang++ --target=aarch64-linux-ohos --sysroot=/mnt/f/command-line-tools/sdk/default/openharmony/native/sysroot' \
  --ar=llvm-ar \
  --ranlib=llvm-ranlib \
  --nm=llvm-nm \
  --strip=llvm-strip \
  --enable-static \
  --disable-shared \
  --enable-pic \
  --disable-programs \
  --disable-doc \
  --disable-autodetect \
  --disable-debug \
  --extra-cflags='-O3 -fPIC -resource-dir=/mnt/f/command-line-tools/sdk/default/openharmony/native/llvm/lib/clang/15.0.4' \
  --extra-ldflags='-fuse-ld=lld -resource-dir=/mnt/f/command-line-tools/sdk/default/openharmony/native/llvm/lib/clang/15.0.4 -B/tmp/ohos-clang-bin -L/mnt/f/command-line-tools/sdk/default/openharmony/native/llvm/lib/aarch64-linux-ohos'
```

`ARCH` must be unset before configuring. Some build shells export
`ARCH=c`, which overrides the requested architecture and silently disables
the AArch64 sources. The configure summary must report:

```text
ARCH                      aarch64 (armv8-a)
NEON enabled              yes
DOTPROD enabled           yes
I8MM enabled              yes
optimize for size         no
```
